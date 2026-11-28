import Testing
import Foundation
@testable import MezzanineKit

// MARK: - Fixtures

private extension QueuedTrack {
    /// A minimal invented track. All ids are made up (public repo).
    static func invented(
        ratingKey: String = "9001",
        title: String = "Invented Track",
        artist: String = "The Example Band",
        album: String = "Invented Album",
        albumKey: String? = "8001",
        duration: TimeInterval = 240,
        index: Int? = 1,
        discIndex: Int? = 1,
        startRamp: String? = nil,
        endRamp: String? = nil
    ) -> QueuedTrack {
        QueuedTrack(
            ratingKey: ratingKey,
            title: title,
            artist: artist,
            album: album,
            albumKey: albumKey,
            duration: duration,
            startRamp: startRamp,
            endRamp: endRamp,
            index: index,
            discIndex: discIndex
        )
    }

    /// Returns a copy with new positional metadata.
    func next(ratingKey: String = "9002", index: Int = 2, discIndex: Int = 1) -> QueuedTrack {
        var t = self
        t.ratingKey = ratingKey
        t.index = index
        t.discIndex = discIndex
        return t
    }
}

/// A `MusicQueue` playing an album in order (no shuffle, no manual entries).
private func albumQueue(tracks: [QueuedTrack]) -> MusicQueue {
    var q = MusicQueue()
    q.start(
        context: QueueContext(kind: .album, ratingKey: "8001", title: "Invented Album"),
        tracks: tracks,
        at: 0,
        shuffled: false
    )
    return q
}

// MARK: - Suite

@Suite struct CrossfadePlannerTests {

    let planner = CrossfadePlanner()
    // Two generic long tracks (4 min each).
    let out = QueuedTrack.invented(ratingKey: "9001", duration: 240, index: 1, discIndex: 1)
    let inc = QueuedTrack.invented(ratingKey: "9002", duration: 240, index: 2, discIndex: 1)

    // MARK: Gapless triggers

    @Test func settingOffGivesGapless() {
        let result = planner.plan(outgoing: out, incoming: inc, setting: .off, inAlbumOrder: false)
        #expect(result == .gapless)
    }

    @Test func inAlbumOrderGivesGaplessEvenWithCrossfadeOn() {
        // Even though crossfade is 8 s, album-order pair must be gapless.
        let result = planner.plan(outgoing: out, incoming: inc, setting: .seconds(8), inAlbumOrder: true)
        #expect(result == .gapless)
    }

    @Test func unknownDurationGivesGapless() {
        // duration == 0 means unknown.
        let unknownOut = QueuedTrack.invented(duration: 0)
        let unknownIn  = QueuedTrack.invented(duration: 0)
        #expect(planner.plan(outgoing: unknownOut, incoming: inc, setting: .seconds(5), inAlbumOrder: false) == .gapless)
        #expect(planner.plan(outgoing: out, incoming: unknownIn, setting: .seconds(5), inAlbumOrder: false) == .gapless)
    }

    @Test func shortDurationGivesGapless() {
        // Track shorter than 2× fade length (5 s fade, 8 s track < 10 s threshold).
        let shortTrack = QueuedTrack.invented(duration: 8)
        #expect(planner.plan(outgoing: shortTrack, incoming: inc, setting: .seconds(5), inAlbumOrder: false) == .gapless)
        #expect(planner.plan(outgoing: out, incoming: shortTrack, setting: .seconds(5), inAlbumOrder: false) == .gapless)
    }

    // MARK: Crossfade with empty ramps

    @Test func plainFadeWithEmptyRamps() {
        // No ramp data → plain fade of the requested length.
        let result = planner.plan(outgoing: out, incoming: inc, setting: .seconds(10), inAlbumOrder: false)
        guard case .crossfade(let p) = result else {
            Issue.record("expected .crossfade, got .gapless")
            return
        }
        // Fade-out starts 10 s before the end of a 240 s track.
        #expect(abs(p.outgoingFadeStart - 230) < 0.001)
        // Applied fade-out equals the full requested length (no quiet tail).
        #expect(abs(p.outgoingFadeLength - 10) < 0.001)
        // No quiet intro → incoming starts right at overlapStart (230).
        #expect(abs(p.incomingStart - 230) < 0.001)
        // Applied fade-in equals the full requested length.
        #expect(abs(p.incomingFadeLength - 10) < 0.001)
        #expect(abs(p.overlap - 10) < 0.001)
        #expect(p.curve == .equalPower)
    }

    // MARK: Ramp-aware: quiet outro

    @Test func quietOutroExtendsOverlapAndShortensAppliedFade() {
        // End ramp: the last 12 s of the track are below −20 dB (Q = 12).
        // With L = 10, Q > L: overlapStart = 240 − max(10, 12) = 228,
        // applied fade-out = max(0, 10 − 12) = 0, and incoming starts at 228 (overlap = 12).
        let endRampStr = "-40.00 0.00;-20.00 12.00;0.00 15.00;"
        let trackOut = QueuedTrack.invented(duration: 240, endRamp: endRampStr)
        let result = planner.plan(outgoing: trackOut, incoming: inc, setting: .seconds(10), inAlbumOrder: false)
        guard case .crossfade(let p) = result else {
            Issue.record("expected .crossfade"); return
        }
        #expect(abs(p.outgoingFadeLength - 0) < 0.001)
        #expect(abs(p.outgoingFadeStart - 228) < 0.001)
        #expect(abs(p.incomingStart - 228) < 0.001)
        #expect(abs(p.incomingFadeLength - 10) < 0.001)
        #expect(abs(p.overlap - 12) < 0.001)
    }

    @Test func quietOutroExceedingRequestedLengthExtendsOverlap() {
        // Q = 10, L = 4: overlapStart = outDur − max(4, 10) = 230, fade-out = 0.
        let endRampStr = "-40.00 0.00;-20.00 10.00;0.00 12.00;"
        let trackOut = QueuedTrack.invented(duration: 240, endRamp: endRampStr)
        let result = planner.plan(outgoing: trackOut, incoming: inc, setting: .seconds(4), inAlbumOrder: false)
        guard case .crossfade(let p) = result else {
            Issue.record("expected .crossfade"); return
        }
        #expect(abs(p.outgoingFadeStart - 230) < 0.001)
        #expect(abs(p.outgoingFadeLength - 0) < 0.001)
        #expect(abs(p.incomingStart - 230) < 0.001)
        #expect(abs(p.incomingFadeLength - 4) < 0.001)
        #expect(abs(p.overlap - 10) < 0.001)
    }

    @Test func quietOutroPartiallyShortensAppliedFade() {
        // Q = 4 < L = 8 → overlapStart = 240 − 8 = 232, applied fade-out = 4 s.
        let endRampStr = "-30.00 0.00;-20.00 4.00;0.00 10.00;"
        let trackOut = QueuedTrack.invented(duration: 240, endRamp: endRampStr)
        let result = planner.plan(outgoing: trackOut, incoming: inc, setting: .seconds(8), inAlbumOrder: false)
        guard case .crossfade(let p) = result else {
            Issue.record("expected .crossfade"); return
        }
        #expect(abs(p.outgoingFadeLength - 4) < 0.001)
        #expect(abs(p.outgoingFadeStart - 232) < 0.001) // 240 − 8
        #expect(abs(p.incomingStart - 232) < 0.001)
        #expect(abs(p.incomingFadeLength - 8) < 0.001)
        #expect(abs(p.overlap - 8) < 0.001)
    }

    // MARK: Ramp-aware: quiet intro

    @Test func quietIntroSkipsFadeIn() {
        // I = 10 >= L = 8: overlapStart = 240 − 8 = 232,
        // incomingStart = 232 − min(10, 8) = 224, fade-in = 0, overlap = 16 (> L).
        let startRampStr = "-40.00 0.00;-20.00 10.00;0.00 12.00;"
        let trackIn = QueuedTrack.invented(duration: 240, startRamp: startRampStr)
        let result = planner.plan(outgoing: out, incoming: trackIn, setting: .seconds(8), inAlbumOrder: false)
        guard case .crossfade(let p) = result else {
            Issue.record("expected .crossfade"); return
        }
        #expect(abs(p.outgoingFadeStart - 232) < 0.001)
        #expect(abs(p.outgoingFadeLength - 8) < 0.001)
        #expect(abs(p.incomingFadeLength - 0) < 0.001)
        #expect(abs(p.incomingStart - 224) < 0.001)
        #expect(abs(p.overlap - 16) < 0.001)
        #expect(p.overlap > 8)
    }

    @Test func quietIntroPartiallyShortensAppliedFadeIn() {
        // I = 4 < L = 8: overlapStart = 232, fade-in = 4, incomingStart = 232 − 4 = 228, overlap = 12.
        let startRampStr = "-30.00 0.00;-20.00 4.00;0.00 8.00;"
        let trackIn = QueuedTrack.invented(duration: 240, startRamp: startRampStr)
        let result = planner.plan(outgoing: out, incoming: trackIn, setting: .seconds(8), inAlbumOrder: false)
        guard case .crossfade(let p) = result else {
            Issue.record("expected .crossfade"); return
        }
        #expect(abs(p.outgoingFadeStart - 232) < 0.001)
        #expect(abs(p.outgoingFadeLength - 8) < 0.001)
        #expect(abs(p.incomingFadeLength - 4) < 0.001)
        #expect(abs(p.incomingStart - 228) < 0.001)
        #expect(abs(p.overlap - 12) < 0.001)
    }

    // MARK: Loud edges (both sides)

    @Test func loudEdgesOnBothSidesUseFullRequestedFades() {
        // Ramps that never reach −20 dB (track stays loud to the very edge).
        let loudEnd   = "-1.00 0.00;0.00 2.00;"
        let loudStart = "-1.00 0.00;0.00 2.00;"
        let loudOut = QueuedTrack.invented(duration: 240, endRamp: loudEnd)
        let loudIn  = QueuedTrack.invented(duration: 240, startRamp: loudStart)
        let result = planner.plan(outgoing: loudOut, incoming: loudIn, setting: .seconds(6), inAlbumOrder: false)
        guard case .crossfade(let p) = result else {
            Issue.record("expected .crossfade"); return
        }
        // No quiet tail/intro → full fades.
        #expect(abs(p.outgoingFadeLength - 6) < 0.001)
        #expect(abs(p.incomingFadeLength - 6) < 0.001)
        #expect(abs(p.incomingStart - 234) < 0.001)
    }

    // MARK: Clamping at short-ish tracks

    @Test func clampingKeepsFadeStartNonNegative() {
        // A 20 s track with a 12 s fade is shorter than 2 × 12 = 24 s → .gapless.
        let shortOut = QueuedTrack.invented(duration: 20)
        let shortIn  = QueuedTrack.invented(duration: 20)
        let result = planner.plan(outgoing: shortOut, incoming: shortIn, setting: .seconds(12), inAlbumOrder: false)
        #expect(result == .gapless)
    }

    @Test func shortTrackClampsIncomingStartAndRampCreditToHalfDuration() {
        // Outgoing 20 s, incoming 20 s, L = 8 (20 >= 16), I = 5:
        // overlapStart = 20 − 8 = 12; raw incomingStart = 12 − 5 = 7, clamped to >= 20 × 0.5 = 10.
        let startRampStr = "-30.00 0.00;-20.00 5.00;0.00 8.00;"
        let shortOut = QueuedTrack.invented(duration: 20)
        let shortIn  = QueuedTrack.invented(duration: 20, startRamp: startRampStr)
        let result = planner.plan(outgoing: shortOut, incoming: shortIn, setting: .seconds(8), inAlbumOrder: false)
        guard case .crossfade(let p) = result else {
            Issue.record("expected .crossfade"); return
        }
        #expect(abs(p.outgoingFadeStart - 12) < 0.001)
        #expect(abs(p.outgoingFadeLength - 8) < 0.001)
        #expect(abs(p.incomingStart - 10) < 0.001)
        #expect(abs(p.incomingFadeLength - 3) < 0.001)
        #expect(abs(p.overlap - 10) < 0.001)

        // With raw Q = 15 on a 20 s track and L = 9 (20 >= 18):
        // Q is capped at half the track (10 s), so overlapStart = 20 − 10 = 10, fade-out = 0.
        let longTail = QueuedTrack.invented(duration: 20, endRamp: "-40.00 0.00;-20.00 15.00;0.00 18.00;")
        let tailResult = planner.plan(outgoing: longTail, incoming: shortIn, setting: .seconds(9), inAlbumOrder: false)
        guard case .crossfade(let tp) = tailResult else {
            Issue.record("expected .crossfade"); return
        }
        #expect(abs(tp.outgoingFadeStart - 10) < 0.001)
        #expect(abs(tp.outgoingFadeLength - 0) < 0.001)
        #expect(abs(tp.incomingStart - 10) < 0.001)
        #expect(abs(tp.incomingFadeLength - 4) < 0.001)
    }

    @Test func rampCreditCappedAtMaximumRampCredit() {
        // Raw Q = 30 s, L = 8 s on 240 s tracks → Q capped at maximumRampCredit (12 s).
        // overlapStart = 240 − max(8, 12) = 228, fade-out = 0, incomingStart = 228, overlap = 12.
        let endRampStr = "-40.00 0.00;-20.00 30.00;0.00 35.00;"
        let trackOut = QueuedTrack.invented(duration: 240, endRamp: endRampStr)
        let result = planner.plan(outgoing: trackOut, incoming: inc, setting: .seconds(8), inAlbumOrder: false)
        guard case .crossfade(let p) = result else {
            Issue.record("expected .crossfade"); return
        }
        #expect(abs(p.outgoingFadeStart - 228) < 0.001)
        #expect(abs(p.outgoingFadeLength - 0) < 0.001)
        #expect(abs(p.incomingStart - 228) < 0.001)
        #expect(abs(p.incomingFadeLength - 8) < 0.001)
        #expect(abs(p.overlap - 12) < 0.001)

        // Raw I = 30 s, L = 14 s → I capped at 12 s:
        // overlapStart = 240 − 14 = 226, incomingStart = 226 − 12 = 214, fade-in = 14 − 12 = 2.
        let startRampStr = "-40.00 0.00;-20.00 30.00;0.00 35.00;"
        let trackIn = QueuedTrack.invented(duration: 240, startRamp: startRampStr)
        let inResult = planner.plan(outgoing: out, incoming: trackIn, setting: .seconds(14), inAlbumOrder: false)
        guard case .crossfade(let ip) = inResult else {
            Issue.record("expected .crossfade"); return
        }
        #expect(abs(ip.outgoingFadeStart - 226) < 0.001)
        #expect(abs(ip.incomingStart - 214) < 0.001)
        #expect(abs(ip.incomingFadeLength - 2) < 0.001)
        #expect(abs(ip.overlap - 26) < 0.001)
    }

    @Test func clampingWithJustLongEnoughTrack() {
        // Track = 30 s, fade = 10 s: 30 >= 10 × 2 = 20 ✓.
        // earliestStart = 30 × 0.5 = 15, rawStart = 30 − 10 = 20
        // fadeOutStart = max(15, max(0, 20)) = 20 (rawStart wins; no clamping needed).
        let shortOut = QueuedTrack.invented(duration: 30)
        let shortIn  = QueuedTrack.invented(duration: 30)
        let result = planner.plan(outgoing: shortOut, incoming: shortIn, setting: .seconds(10), inAlbumOrder: false)
        guard case .crossfade(let p) = result else {
            Issue.record("expected .crossfade"); return
        }
        #expect(abs(p.outgoingFadeStart - 20) < 0.001)
        // fade lengths also unclamped at 10 ≤ 15 (half of 30).
        #expect(abs(p.outgoingFadeLength - 10) < 0.001)
    }

    // MARK: Queue-based album-order detection

    @Test func shuffledSameAlbumGetsCrossfade() {
        // Same albumKey, but queue is shuffled → not in-order → crossfade.
        var queue = MusicQueue()
        let tracks = [
            QueuedTrack.invented(ratingKey: "9001", duration: 240, index: 1, discIndex: 1),
            QueuedTrack.invented(ratingKey: "9002", duration: 240, index: 2, discIndex: 1),
        ]
        var rng = SeededRNG(seed: 42)
        queue.start(
            context: QueueContext(kind: .album, ratingKey: "8001", title: "Invented Album"),
            tracks: tracks, at: 0, shuffled: true, using: &rng
        )
        let result = planner.plan(outgoing: tracks[0], incoming: tracks[1], setting: .seconds(5), queue: queue)
        // Shuffled queue → not in album order.
        // (crossfade expected unless clamping makes it gapless — both tracks 240 s, 5 s fade → fine)
        guard case .crossfade = result else {
            Issue.record("expected .crossfade for shuffled same-album pair"); return
        }
    }

    @Test func unshuffledAlbumContextGivesGapless() {
        let tracks = [
            QueuedTrack.invented(ratingKey: "9001", duration: 240, index: 1, discIndex: 1),
            QueuedTrack.invented(ratingKey: "9002", duration: 240, index: 2, discIndex: 1),
        ]
        let queue = albumQueue(tracks: tracks)
        let result = planner.plan(outgoing: tracks[0], incoming: tracks[1], setting: .seconds(8), queue: queue)
        #expect(result == .gapless)
    }

    @Test func differentAlbumsCrossfade() {
        let outTrack = QueuedTrack.invented(ratingKey: "9001", albumKey: "8001", duration: 240, index: 1, discIndex: 1)
        let inTrack  = QueuedTrack.invented(ratingKey: "9002", albumKey: "8002", duration: 240, index: 1, discIndex: 1)
        let queue = albumQueue(tracks: [outTrack])
        let result = planner.plan(outgoing: outTrack, incoming: inTrack, setting: .seconds(5), queue: queue)
        // Different albumKey → not in-order.
        guard case .crossfade = result else {
            Issue.record("expected .crossfade for different albums"); return
        }
    }

    // MARK: Multi-disc consecutive

    @Test func firstTrackOfNextDiscIsInOrder() {
        // Track 3 of disc 1 → track 1 of disc 2: consecutive.
        let tracks = [
            QueuedTrack.invented(ratingKey: "9010", duration: 240, index: 3, discIndex: 1),
            QueuedTrack.invented(ratingKey: "9011", duration: 240, index: 1, discIndex: 2),
        ]
        let queue = albumQueue(tracks: tracks)
        let result = planner.plan(outgoing: tracks[0], incoming: tracks[1], setting: .seconds(5), queue: queue)
        #expect(result == .gapless)
    }

    @Test func nonConsecutiveTracksFromSameAlbumAreNotInOrder() {
        // Track 1 → track 3 of the same album: a skip.
        let tracks = [
            QueuedTrack.invented(ratingKey: "9020", duration: 240, index: 1, discIndex: 1),
            QueuedTrack.invented(ratingKey: "9021", duration: 240, index: 3, discIndex: 1),
        ]
        let queue = albumQueue(tracks: tracks)
        let result = planner.plan(outgoing: tracks[0], incoming: tracks[1], setting: .seconds(5), queue: queue)
        // Not consecutive → crossfade.
        guard case .crossfade = result else {
            Issue.record("expected .crossfade for non-consecutive same-album tracks"); return
        }
    }

    // MARK: Both ramps active

    @Test func bothRampsActiveAdjustBothSides() {
        // Outgoing: Q = 6 s. Incoming: I = 3 s. Requested: L = 10 s.
        // overlapStart = 240 − max(10, 6) = 230, applied out = 10 − 6 = 4 s.
        // incomingStart = 230 − min(3, 10) = 227, applied in = 10 − 3 = 7 s, overlap = 13 s.
        let endRampStr   = "-35.00 0.00;-20.00 6.00;0.00 10.00;"
        let startRampStr = "-25.00 0.00;-20.00 3.00;0.00 6.00;"
        let trackOut = QueuedTrack.invented(duration: 240, endRamp: endRampStr)
        let trackIn  = QueuedTrack.invented(duration: 240, startRamp: startRampStr)
        let result = planner.plan(outgoing: trackOut, incoming: trackIn, setting: .seconds(10), inAlbumOrder: false)
        guard case .crossfade(let p) = result else {
            Issue.record("expected .crossfade"); return
        }
        #expect(abs(p.outgoingFadeStart - 230) < 0.001)
        #expect(abs(p.outgoingFadeLength - 4) < 0.001)
        #expect(abs(p.incomingFadeLength - 7) < 0.001)
        #expect(abs(p.incomingStart - 227) < 0.001)
        #expect(abs(p.overlap - 13) < 0.001)
    }

    // MARK: LoudnessRamp parsing integration

    @Test func rampStringInPlexTextFormatParsedThroughLoudnessRampInit() {
        // Verify that ramp parsing (via LoudnessRamp(parsing:)) feeds correctly into the planner.
        // Plex format: "-51.00 0.00;-8.03 0.10;0.49 84.10;"
        // end ramp: at 0.00 s from end: −51 dB; at 0.10 s: −8.03 dB; at 84.10 s: +0.49 dB.
        // The ramp reaches −20 dB somewhere between 0.00 s and 0.10 s from the end.
        let endRampStr = "-51.00 0.00;-8.03 0.10;0.49 84.10;"
        let ramp = LoudnessRamp(parsing: endRampStr)
        // Confirm the parsed ramp reaches our quiet threshold quickly (< 0.1 s from end).
        let dist = ramp.distance(reaching: CrossfadePlanner.quietTailThreshold)
        #expect(dist != nil)
        #expect((dist ?? 0) < 0.1)

        // Now confirm the planner uses it: a ramp that barely covers 0.05 s of silence means
        // applied fade ≈ requested − 0.05 (nearly full).
        let trackOut = QueuedTrack.invented(duration: 240, endRamp: endRampStr)
        let result = planner.plan(outgoing: trackOut, incoming: inc, setting: .seconds(8), inAlbumOrder: false)
        guard case .crossfade(let p) = result else {
            Issue.record("expected .crossfade"); return
        }
        // Applied fade-out is close to 8 s (almost no quiet tail at −20 dB).
        #expect(p.outgoingFadeLength > 7.9)
    }

    @Test func malformedRampStringFallsBackToFullFade() {
        // Garbage ramp → empty → no quiet tail → plain fade.
        let trackOut = QueuedTrack.invented(duration: 240, endRamp: "garbage;no_numbers;")
        let result = planner.plan(outgoing: trackOut, incoming: inc, setting: .seconds(6), inAlbumOrder: false)
        guard case .crossfade(let p) = result else {
            Issue.record("expected .crossfade"); return
        }
        #expect(abs(p.outgoingFadeLength - 6) < 0.001)
    }

    @Test func nilRampFallsBackToFullFade() {
        // No ramp strings at all → plain fade.
        let result = planner.plan(outgoing: out, incoming: inc, setting: .seconds(7), inAlbumOrder: false)
        guard case .crossfade(let p) = result else {
            Issue.record("expected .crossfade"); return
        }
        #expect(abs(p.outgoingFadeLength - 7) < 0.001)
        #expect(abs(p.incomingFadeLength - 7) < 0.001)
    }

    // MARK: Equatability and codability

    @Test func gaplessCasesAreEqual() {
        #expect(CrossfadePlan.gapless == CrossfadePlan.gapless)
    }

    @Test func crossfadeParametersRoundTripThroughCodable() throws {
        let params = CrossfadeParameters(
            outgoingDuration: 240,
            outgoingFadeStart: 230.5,
            outgoingFadeLength: 8.0,
            incomingStart: 2.5,
            incomingFadeLength: 7.0,
            curve: .equalPower
        )
        let plan = CrossfadePlan.crossfade(params)
        let data = try JSONEncoder().encode(plan)
        let decoded = try JSONDecoder().decode(CrossfadePlan.self, from: data)
        #expect(plan == decoded)
    }

    // MARK: Edge: very long fade relative to track

    @Test func fadeExceedingHalfDurationIsClamped() {
        // Track 60 s, fade 35 s: 60 >= 35 × 2 = 70? No → gapless.
        let t = QueuedTrack.invented(duration: 60)
        #expect(planner.plan(outgoing: t, incoming: t, setting: .seconds(35), inAlbumOrder: false) == .gapless)
    }

    @Test func fadeAtExactlyHalfDurationThreshold() {
        // Track 40 s, fade 20 s: 40 >= 20 × 2 = 40 ✓ (just at threshold).
        let t = QueuedTrack.invented(duration: 40)
        let result = planner.plan(outgoing: t, incoming: t, setting: .seconds(20), inAlbumOrder: false)
        guard case .crossfade(let p) = result else {
            Issue.record("expected .crossfade at exact threshold"); return
        }
        // rawStart = 40 − 20 = 20; maxStart = 40 × 0.5 = 20 → clamped = 20.
        #expect(abs(p.outgoingFadeStart - 20) < 0.001)
    }
}

// MARK: - Minimal seeded RNG for deterministic shuffle tests

private struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        // xorshift64
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
