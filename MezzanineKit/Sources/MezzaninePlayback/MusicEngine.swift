import Foundation
import AVFAudio
import AudioToolbox
import Observation
import MezzanineKit

/// Plays music: two `AVAudioPlayerNode` decks into one graph, plus a second AetherEngine deck
/// for what `AVAudioFile` can't play well.
///
/// ```
/// deck A player → mixer A ─┐
///                           ├→ bus → EQ → peak limiter → main mixer → output
/// deck B player → mixer B ─┘
/// ```
/// - Native tracks are whole local files (`TrackCache`). Consecutive tracks in the same format
///   and at the same leveling gain are scheduled back to back on one player: sample-exact
///   gapless (measured zero-frame gaps for FLAC, MP3 and AAC). When the next track differs
///   (sample rate, channels, gain) it is scheduled on the idle deck and started at the first
///   deck's end time, so the join is aligned to the engine clock instead of sample-exact.
/// - Each deck has its own mixer, which carries the track's leveling gain (`LoudnessPlan`) and,
///   later, crossfade ramps. The EQ (flat, bypassed) and the limiter after the bus are the
///   seams for M2's EQ and crossfade; the limiter catches inter-sample overs after any gain.
/// - Anything `AVAudioFile` refuses, and Vorbis, WMA and surround, plays on `EngineDeck`.
///   Joins to and from it are not gapless.
///
/// macOS 27 deprecates `connect(_:to:format:)` and `play()` / `play(at:)`; see
/// `AudioGraphCompat.swift` for how the macOS 26 target stays warning-free.
///
/// `scheduleSegment` completion handlers run on a private queue. Closures made inside this
/// main-actor class would inherit its isolation and trap there (the artwork-handler crash), so
/// every handler is built by a nonisolated helper and hops back with a `Task`.
@MainActor
@Observable
public final class MusicEngine {
    public enum Mode: Sendable {
        /// The real output device.
        case live
        /// No device: the owner pulls rendered audio with `renderOffline` (tests and the Lab).
        case offline(sampleRate: Double)
    }

    // MARK: Published state

    public private(set) var status: MusicStatus = .idle
    public private(set) var current: MusicTrackRequest?
    /// The follower the owner queued; scheduled for a gapless join when it can be.
    public private(set) var upcoming: MusicTrackRequest?
    public private(set) var activeRoute: MusicRoute = .native
    public private(set) var duration: TimeInterval = 0
    /// How long the last `play` took to put its first audio into the graph (native deck).
    public private(set) var firstAudioLatency: Duration?

    /// 0…1, in front of the output.
    public var volume: Float = 1 { didSet { applyVolume() } }
    public var isMuted = false { didSet { applyVolume() } }
    @ObservationIgnored public var onEvent: (@MainActor (MusicEvent) -> Void)?

    // MARK: Graph

    @ObservationIgnored let engine = AVAudioEngine()
    @ObservationIgnored private let decks = [Deck(), Deck()]
    @ObservationIgnored private let bus = AVAudioMixerNode()
    /// Flat and bypassed. M2 sets bands here.
    @ObservationIgnored public let eq = AVAudioUnitEQ(numberOfBands: 10)
    @ObservationIgnored let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
    @ObservationIgnored private let graphFormat: AVAudioFormat
    @ObservationIgnored private let mode: Mode

    @ObservationIgnored private var slots: [Slot] = []
    @ObservationIgnored private var nextSlotID = 1
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var pausedPosition: TimeInterval = 0
    @ObservationIgnored private var engineDeck: EngineDeck?
    @ObservationIgnored private var firstAudioTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var configObserver: NSObjectProtocol?

    private final class Deck {
        let player = AVAudioPlayerNode()
        let mixer = AVAudioMixerNode()
        var connectedFormat: AVAudioFormat?
    }

    /// One scheduled stretch of a file. `startSample` is where it begins on its deck's player
    /// timeline (0 for the first thing after the deck started).
    private struct Slot {
        var id: Int
        var request: MusicTrackRequest
        var file: AVAudioFile
        var deck: Int
        var startFrame: AVAudioFramePosition
        var frames: AVAudioFrameCount
        var startSample: AVAudioFramePosition
        var sampleRate: Double { file.processingFormat.sampleRate }
    }

    public init(mode: Mode = .live, bypassLimiter: Bool = false) throws {
        self.mode = mode
        switch mode {
        case .live:
            let hardware = engine.outputNode.outputFormat(forBus: 0)
            graphFormat = hardware.channelCount > 0 && hardware.sampleRate > 0
                ? AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate, channels: 2)!
                : AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        case .offline(let sampleRate):
            graphFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        }
        for deck in decks {
            engine.attach(deck.player)
            engine.attach(deck.mixer)
        }
        engine.attach(bus)
        engine.attach(eq)
        engine.attach(limiter)
        for deck in decks { try engine.connectNodes(deck.mixer, to: bus, format: graphFormat) }
        try engine.connectNodes(bus, to: eq, format: graphFormat)
        try engine.connectNodes(eq, to: limiter, format: graphFormat)
        try engine.connectNodes(limiter, to: engine.mainMixerNode, format: graphFormat)
        eq.bypass = true
        limiter.bypass = bypassLimiter
        if case .offline = mode {
            try engine.enableManualRenderingMode(.offline, format: graphFormat, maximumFrameCount: 4096)
        } else {
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.handleConfigurationChange() }
            }
        }
        applyVolume()
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    }

    // MARK: Transport

    /// Starts a track, replacing whatever plays. `startAt` seeks before the first sample;
    /// `autoplay: false` leaves it loaded and paused.
    public func play(_ request: MusicTrackRequest, startAt: TimeInterval = 0, autoplay: Bool = true) async throws {
        let began = ContinuousClock.now
        resetTransport()
        status = .loading
        current = request
        duration = request.track.duration
        var route = request.route
        if route == .native {
            do {
                try startNative(request, startAt: startAt, autoplay: autoplay)
            } catch {
                guard request.streamURL != nil else {
                    fail(request, error)
                    throw error
                }
                // `AVAudioFile` refused the file: the engine deck takes it.
                route = .engine
            }
        }
        if route == .engine {
            do {
                try await startOnEngineDeck(request, startAt: startAt, autoplay: autoplay)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                fail(request, error)
                throw error
            }
        }
        activeRoute = route
        measureFirstAudio(since: began)
        onEvent?(.trackStarted(request.track, route: route))
        if upcoming == nil { onEvent?(.needsNext) }
    }

    public func pause() {
        guard status == .playing else { return }
        if activeRoute == .engine {
            engineDeck?.pause()
        } else {
            pausedPosition = position
            // A follower on the other deck waits for its start time; pausing would let it
            // start on resume. It is scheduled again on resume.
            cancelCrossDeckFollower()
            for deck in decks { deck.player.pause() }
        }
        status = .paused
    }

    public func resume() {
        guard status == .paused else { return }
        if activeRoute == .engine {
            engineDeck?.play()
        } else if let slot = slots.first {
            do {
                try startEngineIfNeeded()
                try decks[slot.deck].player.startPlaying()
            } catch {
                fail(slot.request, error)
                return
            }
        }
        status = .playing
        scheduleUpcomingIfPossible()
    }

    public func togglePlayPause() {
        switch status {
        case .playing: pause()
        case .paused: resume()
        default: break
        }
    }

    public func stop() {
        resetTransport()
        current = nil
        upcoming = nil
        duration = 0
        status = .idle
    }

    /// Moves within the current track. Exact on the native deck (frames, not time estimates).
    public func seek(to seconds: TimeInterval) async {
        let target = min(max(0, seconds), max(0, duration - 0.05))
        if activeRoute == .engine {
            await engineDeck?.seek(to: target)
            return
        }
        guard let slot = slots.first, current != nil else { return }
        let wasPlaying = status == .playing
        cancelFollower()
        let deck = decks[slot.deck]
        deck.player.stop()
        let sr = slot.sampleRate
        let start = min(AVAudioFramePosition(target * sr), max(0, slot.file.length - 1))
        slots = []
        do {
            try schedule(slot.request, file: slot.file, deck: slot.deck, startFrame: start, startSample: 0)
            pausedPosition = Double(start) / sr
            if wasPlaying {
                try startEngineIfNeeded()
                try deck.player.startPlaying()
                scheduleUpcomingIfPossible()
            }
        } catch {
            fail(slot.request, error)
        }
    }

    /// Where the current track is, in seconds.
    public var position: TimeInterval {
        if activeRoute == .engine { return engineDeck?.position ?? 0 }
        guard status == .playing, let slot = slots.first else { return pausedPosition }
        let player = decks[slot.deck].player
        guard let node = player.lastRenderTime, let time = player.playerTime(forNodeTime: node) else { return pausedPosition }
        let played = Double(time.sampleTime - slot.startSample) / time.sampleRate
        return min(duration, max(0, Double(slot.startFrame) / slot.sampleRate + max(0, played)))
    }

    // MARK: Gapless follower

    /// Sets the track that follows the current one (nil clears it). On the native deck it is
    /// scheduled now so the join is gapless; otherwise it starts when the current track ends.
    public func enqueueNext(_ request: MusicTrackRequest?) {
        // A different follower replaces any scheduled one.
        if let scheduled = slots.dropFirst().first, scheduled.request.track.id != request?.track.id { cancelFollower() }
        upcoming = request
        scheduleUpcomingIfPossible()
    }

    private func scheduleUpcomingIfPossible() {
        guard status == .playing, activeRoute == .native, slots.count == 1, let next = upcoming,
              next.route == .native, let url = next.fileURL, let first = slots.first,
              let file = try? AVAudioFile(forReading: url), file.length > 0 else { return }
        let sameFormat = Self.sameFormat(file.processingFormat, first.file.processingFormat)
        let sameGain = abs(next.gainDB - first.request.gainDB) < 0.05
        do {
            if sameFormat && sameGain {
                // Back to back on one player: sample-exact.
                try schedule(next, file: file, deck: first.deck, startFrame: 0,
                             startSample: first.startSample + AVAudioFramePosition(first.frames))
            } else {
                let other = 1 - first.deck
                decks[other].player.stop()
                let endsAt = AVAudioTime(sampleTime: first.startSample + AVAudioFramePosition(first.frames), atRate: first.sampleRate)
                try schedule(next, file: file, deck: other, startFrame: 0, startSample: 0)
                if let node = decks[first.deck].player.nodeTime(forPlayerTime: endsAt) {
                    let when: AVAudioTime = node.isHostTimeValid
                        ? AVAudioTime(hostTime: node.hostTime)
                        : AVAudioTime(sampleTime: node.sampleTime, atRate: node.sampleRate)
                    try decks[other].player.startPlaying(at: when)
                } else {
                    try decks[other].player.startPlaying()
                }
            }
        } catch {
            // The follower can't be pre-scheduled; it starts when the current track ends.
            slots = Array(slots.prefix(1))
        }
    }

    // MARK: Scheduling

    private func startNative(_ request: MusicTrackRequest, startAt: TimeInterval, autoplay: Bool) throws {
        guard let url = request.fileURL else { throw MusicEngineError.noSource }
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw MusicEngineError.cannotOpen(String(describing: error)) }
        guard file.length > 0 else { throw MusicEngineError.cannotOpen("empty file") }
        let sr = file.processingFormat.sampleRate
        duration = Double(file.length) / sr
        let start = min(AVAudioFramePosition(max(0, startAt) * sr), max(0, file.length - 1))
        try schedule(request, file: file, deck: 0, startFrame: start, startSample: 0)
        try startEngineIfNeeded()
        pausedPosition = Double(start) / sr
        if autoplay {
            try decks[0].player.startPlaying()
            status = .playing
        } else {
            status = .paused
        }
        activeRoute = .native
        scheduleUpcomingIfPossible()
    }

    private func schedule(_ request: MusicTrackRequest, file: AVAudioFile, deck index: Int,
                          startFrame: AVAudioFramePosition, startSample: AVAudioFramePosition) throws {
        let deck = decks[index]
        let format = file.processingFormat
        if let connected = deck.connectedFormat, Self.sameFormat(connected, format) {} else {
            try engine.connectNodes(deck.player, to: deck.mixer, format: format)
            deck.connectedFormat = format
        }
        deck.mixer.outputVolume = request.gainLinear
        let frames = AVAudioFrameCount(max(0, file.length - startFrame))
        let slot = Slot(id: nextSlotID, request: request, file: file, deck: index, startFrame: startFrame,
                        frames: frames, startSample: startSample)
        nextSlotID += 1
        slots.append(slot)
        let id = slot.id
        let gen = generation
        deck.player.scheduleSegment(file, startingFrame: startFrame, frameCount: frames, at: nil,
                                    completionCallbackType: .dataPlayedBack,
                                    completionHandler: Self.completion { [weak self] in
            Task { @MainActor in self?.slotFinished(id: id, generation: gen) }
        })
    }

    /// Built outside the main actor on purpose (see the type's notes).
    nonisolated private static func completion(_ body: @escaping @Sendable () -> Void) -> @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void {
        { _ in body() }
    }

    nonisolated private static func sameFormat(_ a: AVAudioFormat, _ b: AVAudioFormat) -> Bool {
        a.sampleRate == b.sampleRate && a.channelCount == b.channelCount && a.commonFormat == b.commonFormat
    }

    private func slotFinished(id: Int, generation gen: Int) {
        guard gen == generation, let finished = slots.first, finished.id == id else { return }
        slots.removeFirst()
        onEvent?(.trackEnded(finished.request.track))
        if let follower = slots.first {
            // Gapless: the follower is already sounding.
            current = follower.request
            duration = Double(follower.file.length) / follower.sampleRate
            upcoming = nil
            pausedPosition = 0
            if follower.deck != finished.deck { decks[finished.deck].player.stop() }
            onEvent?(.trackStarted(follower.request.track, route: .native))
            onEvent?(.needsNext)
            scheduleUpcomingIfPossible()
        } else if let next = upcoming {
            upcoming = nil
            Task { @MainActor in
                do { try await self.play(next) } catch { /* `play` already reported it */ }
            }
        } else {
            status = .ended
            onEvent?(.finished)
        }
    }

    // MARK: Engine deck

    private func startOnEngineDeck(_ request: MusicTrackRequest, startAt: TimeInterval, autoplay: Bool) async throws {
        guard let url = request.streamURL ?? request.fileURL else { throw MusicEngineError.noSource }
        let deck: EngineDeck
        if let engineDeck { deck = engineDeck } else {
            deck = try EngineDeck()
            deck.onEnded = { [weak self] failure in self?.engineDeckEnded(failure: failure) }
            engineDeck = deck
        }
        activeRoute = .engine
        try await deck.load(url: url, headers: request.headers, startAt: startAt, autoplay: autoplay, volume: engineVolume(for: request))
        duration = deck.duration > 0 ? deck.duration : request.track.duration
        status = autoplay ? .playing : .paused
    }

    private func engineVolume(for request: MusicTrackRequest) -> Float {
        isMuted ? 0 : min(1, volume * request.gainLinear)
    }

    private func engineDeckEnded(failure: String?) {
        guard activeRoute == .engine, let finished = current else { return }
        if let failure {
            status = .failed(failure)
            onEvent?(.failed(finished.track, failure))
            return
        }
        onEvent?(.trackEnded(finished.track))
        if let next = upcoming {
            upcoming = nil
            Task { @MainActor in
                do { try await self.play(next) } catch { /* reported by `play` */ }
            }
        } else {
            status = .ended
            onEvent?(.finished)
        }
    }

    // MARK: Plumbing

    private func startEngineIfNeeded() throws {
        guard !engine.isRunning else { return }
        engine.prepare()
        try engine.start()
    }

    /// Drops everything scheduled and silences both decks. Late completion handlers are
    /// ignored through the generation.
    private func resetTransport() {
        generation += 1
        firstAudioTask?.cancel()
        slots = []
        for deck in decks { deck.player.stop() }
        engineDeck?.stop()
        activeRoute = .native
        pausedPosition = 0
    }

    /// Removes a scheduled follower, keeping it as `upcoming` to schedule again.
    private func cancelFollower() {
        guard slots.count > 1 else { return }
        let follower = slots[1]
        upcoming = upcoming ?? follower.request
        slots = Array(slots.prefix(1))
        if follower.deck != slots[0].deck { decks[follower.deck].player.stop() }
        else {
            // Same player: its queue holds the follower; rebuild the current stretch alone.
            rescheduleCurrentAlone()
        }
    }

    private func cancelCrossDeckFollower() {
        guard slots.count > 1, slots[1].deck != slots[0].deck else { return }
        cancelFollower()
    }

    /// A follower scheduled on the same player can only be removed by stopping the player, so
    /// the current track is scheduled again from where it is.
    private func rescheduleCurrentAlone() {
        guard let slot = slots.first else { return }
        let now = position
        let wasPlaying = status == .playing
        let deck = decks[slot.deck]
        deck.player.stop()
        slots = []
        let start = min(AVAudioFramePosition(now * slot.sampleRate), max(0, slot.file.length - 1))
        do {
            try schedule(slot.request, file: slot.file, deck: slot.deck, startFrame: start, startSample: 0)
            pausedPosition = Double(start) / slot.sampleRate
            if wasPlaying { try deck.player.startPlaying() }
        } catch {
            fail(slot.request, error)
        }
    }

    private func applyVolume() {
        engine.mainMixerNode.outputVolume = isMuted ? 0 : volume
        if let request = current { engineDeck?.volume = engineVolume(for: request) }
    }

    private func fail(_ request: MusicTrackRequest, _ error: Error) {
        let message = String(describing: error)
        status = .failed(message)
        onEvent?(.failed(request.track, message))
    }

    private func measureFirstAudio(since began: ContinuousClock.Instant) {
        firstAudioLatency = nil
        guard activeRoute == .native, status == .playing, let slot = slots.first else { return }
        let player = decks[slot.deck].player
        firstAudioTask = Task { @MainActor [weak self] in
            for _ in 0..<600 {
                if Task.isCancelled { return }
                if player.lastRenderTime != nil {
                    self?.firstAudioLatency = ContinuousClock.now - began
                    return
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    /// The output device changed (sample rate, route): the engine stopped itself. Restart it
    /// and put the track back where it was. Best effort; M2's rate matching builds on this.
    private func handleConfigurationChange() async {
        guard activeRoute == .native, current != nil else { return }
        let wasPlaying = status == .playing
        let at = pausedPosition == 0 ? position : max(position, pausedPosition)
        try? startEngineIfNeeded()
        // Scheduled audio is gone after the stop: schedule the current track again.
        if let slot = slots.first {
            slots = []
            generation += 1
            let start = min(AVAudioFramePosition(at * slot.sampleRate), max(0, slot.file.length - 1))
            do {
                try schedule(slot.request, file: slot.file, deck: slot.deck, startFrame: start, startSample: 0)
                pausedPosition = Double(start) / slot.sampleRate
                if wasPlaying { try decks[slot.deck].player.startPlaying() }
            } catch {
                fail(slot.request, error)
            }
        }
        scheduleUpcomingIfPossible()
    }

    // MARK: Offline rendering (tests, Lab)

    /// Renders the next `frames` of the graph (offline mode only). Completion handlers fire as
    /// the rendered audio passes their data, so the engine plays through as it is pulled.
    public func renderOffline(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        guard case .offline = mode else { throw MusicEngineError.cannotOpen("not an offline engine") }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: frames) else {
            throw MusicEngineError.cannotOpen("buffer")
        }
        let status = try engine.renderOffline(frames, to: buffer)
        if status == .error { throw MusicEngineError.cannotOpen("render failed") }
        return buffer
    }

    public var offlineSampleRate: Double { graphFormat.sampleRate }
}
