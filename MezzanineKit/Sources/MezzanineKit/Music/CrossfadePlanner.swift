import Foundation

// MARK: - Settings

/// User-facing crossfade setting.
public enum CrossfadeSetting: Sendable, Hashable, Codable {
    case off
    /// Requested fade length, 1–12 seconds.
    case seconds(Double)

    /// Convenience: the requested fade length, or nil when off.
    public var length: Double? {
        switch self {
        case .off: return nil
        case .seconds(let s): return s
        }
    }
}

// MARK: - Curve

/// Volume-ramp shape for a fade.
public enum FadeCurve: String, Sendable, Hashable, Codable, CaseIterable {
    /// Equal-power (√ law): the two fades together keep constant energy.
    case equalPower
    /// Linear amplitude: simpler but dips in perceived loudness at mid-point.
    case linear
}

// MARK: - Plan

/// What the engine should do at the boundary between two tracks.
public enum CrossfadePlan: Sendable, Hashable, Codable {
    /// Schedule the next track right after the current one ends; no volume ramps.
    case gapless

    /// Overlap the two tracks with volume ramps.
    ///
    /// All times are in seconds.
    case crossfade(CrossfadeParameters)
}

/// Parameters for a crossfade between two tracks.
public struct CrossfadeParameters: Sendable, Hashable, Codable {
    /// Duration of the outgoing track in seconds.
    public var outgoingDuration: Double
    /// Seconds into the outgoing track where the fade-out starts.
    public var outgoingFadeStart: Double
    /// Length of the fade-out ramp in seconds.
    public var outgoingFadeLength: Double
    /// Absolute start time of the incoming track on the outgoing track's clock.
    public var incomingStart: Double
    /// Duration for which the tracks overlap.
    public var overlap: Double { outgoingDuration - incomingStart }
    /// Length of the fade-in ramp in seconds (0 means no ramp — incoming plays full from the start).
    public var incomingFadeLength: Double
    /// Shape of both ramps.
    public var curve: FadeCurve

    public init(outgoingDuration: Double, outgoingFadeStart: Double, outgoingFadeLength: Double,
                incomingStart: Double, incomingFadeLength: Double,
                curve: FadeCurve = .equalPower) {
        self.outgoingDuration = outgoingDuration
        self.outgoingFadeStart = outgoingFadeStart
        self.outgoingFadeLength = outgoingFadeLength
        self.incomingStart = incomingStart
        self.incomingFadeLength = incomingFadeLength
        self.curve = curve
    }
}

// MARK: - Planner

/// Decides how to join two consecutive tracks.
///
/// Call `plan(outgoing:incoming:setting:inAlbumOrder:)` once per track pair. The result is a
/// pure value with no side effects; the engine applies it when scheduling the next buffer.
public struct CrossfadePlanner: Sendable {

    // MARK: Thresholds — all in one place with rationale

    /// End-ramp level considered "already quiet". Below this the tail is treated as silence that
    /// the fade can absorb for free, so the applied fade is shortened rather than layered on top.
    /// −20 dB ≈ one-tenth the reference amplitude; clearly audible but not "loud".
    static let quietTailThreshold: Double = -20.0

    /// Start-ramp level considered "already quiet". Below this the intro is itself a fade-in, so
    /// we shorten or skip the applied fade-in. Same value for symmetry.
    static let quietIntroThreshold: Double = -20.0

    /// A track whose duration is unknown (0) or shorter than this multiple of the requested fade
    /// length gets `.gapless`. Factor of 2 means each track contributes at least half its length
    /// before any fade. Prevents fading a 3-second track that is itself the whole experience.
    static let minimumDurationFactor: Double = 2.0

    /// How much of a track's duration is the most we will ever use for the overlap. Clamps the
    /// overlap start so the fade never consumes more than half the track.
    static let maximumOverlapFraction: Double = 0.5

    /// Maximum quiet-tail or quiet-intro duration credited toward the fade.
    static let maximumRampCredit: Double = 12.0

    public init() {}

    // MARK: - Public API

    /// Produces a crossfade plan for the outgoing / incoming pair.
    ///
    /// - Parameters:
    ///   - outgoing: The track that is currently playing.
    ///   - incoming: The track that will play next.
    ///   - setting: The user's crossfade preference.
    ///   - inAlbumOrder: `true` when both tracks belong to the same album and the incoming track
    ///     is the consecutive successor (same albumKey, next index/disc), and the queue context
    ///     is that album playing in its own order without shuffle. When true, the result is always
    ///     `.gapless` regardless of the setting.
    /// - Returns: `.gapless` or `.crossfade(_:)`.
    public func plan(
        outgoing: QueuedTrack,
        incoming: QueuedTrack,
        setting: CrossfadeSetting,
        inAlbumOrder: Bool
    ) -> CrossfadePlan {

        // 1. Setting is off → gapless.
        guard let requestedLength = setting.length else { return .gapless }

        // 2. In album order → gapless (live albums and segued records must stay seamless).
        if inAlbumOrder { return .gapless }

        // 3. Unknown or too-short durations → gapless.
        let outDur = outgoing.duration
        let inDur = incoming.duration
        guard outDur > 0, inDur > 0,
              outDur >= requestedLength * Self.minimumDurationFactor,
              inDur  >= requestedLength * Self.minimumDurationFactor
        else { return .gapless }

        // 4. Ramp-aware fade calculation.
        let endRamp   = outgoing.endLoudnessRamp
        let startRamp = incoming.startLoudnessRamp

        // --- Outgoing side ---
        // If the end ramp shows a quiet tail, work out how long it is.
        let quietTailLength: Double
        if let tailDist = endRamp.distance(reaching: Self.quietTailThreshold) {
            // `tailDist` is seconds-before-the-end where the ramp first reaches the threshold.
            quietTailLength = tailDist
        } else {
            quietTailLength = 0
        }

        let quietIntroLength = startRamp.distance(reaching: Self.quietIntroThreshold) ?? 0

        // Quiet tail (Q) and quiet intro (I), capped at maximumRampCredit and half their track.
        // Total overlap region spans max(L, Q) before the end of the outgoing track.
        let quietTail = min(quietTailLength, Self.maximumRampCredit, outDur * Self.maximumOverlapFraction)
        let quietIntro = min(quietIntroLength, Self.maximumRampCredit, inDur * Self.maximumOverlapFraction)
        let totalOverlap = max(requestedLength, quietTail)

        // Applied fade-out lasts max(0, L − Q), ending where the tail goes quiet.
        // When Q ≥ L, there is no applied fade and the tail plays out.
        let appliedOutLength = max(0, requestedLength - quietTail)

        // Outgoing fade starts at overlapStart (outDur − max(L, Q)), clamped to
        // >= half of the outgoing duration and >= 0 so overlap never exceeds half the track.
        let earliestStart = outDur * (1.0 - Self.maximumOverlapFraction)
        let rawFadeStart = outDur - totalOverlap
        let fadeOutStart = max(earliestStart, max(0, rawFadeStart))

        // --- Incoming side ---
        // Applied fade-in lasts max(0, L − I), shortened or skipped when the intro is already quiet.
        let appliedInLength = max(0, requestedLength - quietIntro)

        // Incoming track starts earlier by min(I, L) so its quiet intro sits under the
        // outgoing track (incomingStart = overlapStart − min(I, L)), clamped to >= half of
        // the outgoing duration and >= 0.
        let incomingStart = max(outDur * Self.maximumOverlapFraction, max(0, fadeOutStart - min(quietIntro, requestedLength)))

        // Clamp applied fades so neither exceeds half its own track duration.
        let maxInLength = inDur * Self.maximumOverlapFraction
        let clampedInLength = min(appliedInLength, maxInLength)

        let maxOutLength = outDur * Self.maximumOverlapFraction
        let clampedOutLength = min(appliedOutLength, maxOutLength)

        let params = CrossfadeParameters(
            outgoingDuration: outDur,
            outgoingFadeStart: fadeOutStart,
            outgoingFadeLength: clampedOutLength,
            incomingStart: incomingStart,
            incomingFadeLength: clampedInLength,
            curve: .equalPower
        )

        return .crossfade(params)
    }
}

// MARK: - In-album-order helper

extension CrossfadePlanner {
    /// Convenience: derives `inAlbumOrder` from the two tracks and the queue.
    ///
    /// Returns `true` when both tracks share an `albumKey`, the incoming track is the immediate
    /// next index (or first track of the next disc), and the queue is playing that album in its
    /// own order without shuffle.
    public func plan(
        outgoing: QueuedTrack,
        incoming: QueuedTrack,
        setting: CrossfadeSetting,
        queue: MusicQueue
    ) -> CrossfadePlan {
        plan(
            outgoing: outgoing,
            incoming: incoming,
            setting: setting,
            inAlbumOrder: CrossfadePlanner.tracksAreInAlbumOrder(outgoing, incoming, queue: queue)
        )
    }

    /// Returns `true` when the two tracks are consecutive in their shared album and the queue
    /// is playing in album order.
    public static func tracksAreInAlbumOrder(
        _ outgoing: QueuedTrack,
        _ incoming: QueuedTrack,
        queue: MusicQueue
    ) -> Bool {
        // Both must share a known album.
        guard let outAlbum = outgoing.albumKey,
              let inAlbum  = incoming.albumKey,
              outAlbum == inAlbum else { return false }

        // Queue context must be the album playing in order.
        guard queue.isPlayingContextInOrder,
              queue.context?.kind == .album else { return false }

        // Incoming must be the consecutive track after outgoing.
        return isConsecutive(after: outgoing, track: incoming)
    }

    // MARK: Private

    static func isConsecutive(after prev: QueuedTrack, track: QueuedTrack) -> Bool {
        guard let prevDisc = prev.discIndex, let prevIdx = prev.index,
              let nextDisc = track.discIndex, let nextIdx = track.index else {
            // No position data — can't confirm order.
            return false
        }
        if prevDisc == nextDisc {
            return nextIdx == prevIdx + 1
        }
        // First track of the next disc.
        return nextDisc == prevDisc + 1 && nextIdx == 1
    }
}
