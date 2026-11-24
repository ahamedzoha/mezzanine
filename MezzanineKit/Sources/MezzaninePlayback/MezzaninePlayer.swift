import Foundation
import Combine
import SwiftUI
import AVKit
import MediaPlayer
import AetherEngine
import MezzanineKit

/// Mezzanine's player, and the only place AetherEngine is touched.
///
/// The app reads Mezzanine's own types (`PlayerStatus`, `PlayerTrack`,
/// `PlayerCue`) and calls Mezzanine's own methods, so an engine upgrade with
/// API changes, or a swap to another engine, stays inside this file and
/// `PlayerSurface`. One instance lives for the app's lifetime, as the engine
/// asks: reloading a new title on the same engine keeps the audio session
/// and the display pipeline warm, which is what makes the next episode start
/// without a black flash.
@MainActor
@Observable
public final class MezzaninePlayer {
    // MARK: Published state (Mezzanine's types)

    public private(set) var status: PlayerStatus = .idle
    public private(set) var isBuffering = false
    public private(set) var currentTime: Double = 0
    public private(set) var duration: Double = 0
    public private(set) var firstFrameReady = false
    public private(set) var audioTracks: [PlayerTrack] = []
    public private(set) var subtitleTracks: [PlayerTrack] = []
    public private(set) var selectedAudioID: Int?
    public private(set) var selectedSubtitleID: Int?
    public private(set) var cues: [PlayerCue] = []
    public private(set) var diagnostics = PlayerDiagnostics()
    public private(set) var rate: Double = 1
    /// Picture in Picture can start (the route has a layer for it).
    public private(set) var canPictureInPicture = false
    public private(set) var isPictureInPicture = false
    /// The AVPlayer on the native route (for the AirPlay picker); nil on the software route.
    public private(set) var avPlayer: AVPlayer?
    /// Scrub thumbnails are available from data the session already holds.
    public var supportsScrubThumbnails: Bool { engine.supportsCacheBackedStills }
    /// Chapters embedded in the file (Plex's own chapter list is preferred when it has one).
    public private(set) var chapters: [PlayerChapter] = []
    public private(set) var isMuted = false

    /// 0…400 %. Above 100 % becomes gain in front of the engine's limiter.
    public var volume = VolumeLevel(percent: 100) {
        didSet { applyVolumeAndShaping() }
    }

    /// The sleep timer's fade, 1 to 0, over whatever the volume is. The player's own volume only,
    /// so it never rebuilds the session.
    public var fade = 1.0 {
        didSet { if fade != oldValue { applyPlayerVolume() } }
    }

    /// Fill the view, cropping the picture's edges, instead of fitting it whole.
    public var fillsView = false {
        didSet { if fillsView != oldValue { engine.videoGravity = fillsView ? .resizeAspectFill : .resizeAspect } }
    }

    /// The per-device profile in force (set by the audio route monitor).
    public var audioProfile: AudioProfile = .passthrough {
        didSet { if audioProfile != oldValue { applyVolumeAndShaping() } }
    }

    // MARK: Engine

    @ObservationIgnored let engine: AetherEngine
    @ObservationIgnored private var bag = Set<AnyCancellable>()
    @ObservationIgnored private var loadStartedAt: ContinuousClock.Instant?
    @ObservationIgnored private var seekStartedAt: ContinuousClock.Instant?
    /// Volume boost in the shaping last handed to the engine, and in the audio playing now.
    @ObservationIgnored private var requestedBoostDB = 0.0
    @ObservationIgnored private var playingBoostDB = 0.0
    @ObservationIgnored private var settling: Task<Void, Never>?
    @ObservationIgnored private var pip: AVPictureInPictureController?
    @ObservationIgnored private var pipDelegate: PiPDelegate?
    /// A second reader over the playing file, for scrub previews and snapshots far from
    /// the playhead (the engine's own stills only cover bytes it already holds).
    @ObservationIgnored private var stills: FrameExtractor?
    @ObservationIgnored private var stillsSource: (url: URL, headers: [String: String])?

    public init() throws {
        engine = try AetherEngine()
        // Mezzanine draws its own transport, so the engine owns system Now Playing and
        // answers media keys / Control Centre itself.
        engine.ownsVideoNowPlayingSession = true
        engine.ownsVideoNowPlayingCommands = true
        engine.ownsSoftwareNowPlaying = true
        bind()
    }

    // MARK: Now Playing, PiP, AirPlay, scrub thumbnails

    /// The title shown in Control Centre and on media-key HUDs.
    public func setNowPlaying(title: String, subtitle: String?, artwork: NSImage?) {
        var info: [String: Any] = [MPMediaItemPropertyTitle: title, MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue]
        if let subtitle { info[MPMediaItemPropertyArtist] = subtitle }
        if let artwork {
            info[MPMediaItemPropertyArtwork] = Self.nowPlayingArtwork(artwork)
        }
        engine.setNowPlayingInfo(info)
    }

    /// MediaPlayer calls the artwork handler on its own queue. Built here, outside the
    /// main actor, the closure carries no actor isolation (a main-actor closure traps there).
    nonisolated private static func nowPlayingArtwork(_ image: NSImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    public func togglePictureInPicture() {
        guard let pip else { return }
        if pip.isPictureInPictureActive { pip.stopPictureInPicture() } else { pip.startPictureInPicture() }
    }

    /// A frame near `seconds` for the scrub tooltip; nil means show the time only.
    public func scrubThumbnail(at seconds: Double) async -> CGImage? {
        guard engine.supportsCacheBackedStills else { return nil }
        return await engine.scrubThumbnail(atSeconds: seconds)
    }

    private func rebuildPiP() {
        pip?.delegate = nil
        if engine.videoRoute == .software {
            pip = engine.softwarePiPSource?.makePictureInPictureController()
        } else if let layer = engine.nativePlayerLayer {
            pip = AVPictureInPictureController(playerLayer: layer)
        } else {
            pip = nil
        }
        let delegate = PiPDelegate { [weak self] active in
            self?.isPictureInPicture = active
            self?.engine.pictureInPictureActive = active
        }
        pipDelegate = delegate
        pip?.delegate = delegate
        canPictureInPicture = pip != nil && AVPictureInPictureController.isPictureInPictureSupported()
    }

    /// The app's one player. Falls back to a crash with a clear message: an
    /// engine that can't initialise means the app can't play anything.
    public static func makeShared() -> MezzaninePlayer {
        do { return try MezzaninePlayer() } catch {
            fatalError("Couldn’t start the playback engine: \(error)")
        }
    }

    // MARK: Loading

    /// Plays one file. `headers` carry the Plex token, so it never sits in a URL.
    public func load(_ request: PlaybackRequest) async throws {
        let clock = ContinuousClock()
        loadStartedAt = clock.now
        diagnostics = PlayerDiagnostics()
        firstFrameReady = false
        resetStills(url: request.url, headers: request.headers)
        var options = LoadOptions(httpHeaders: request.headers)
        options.preferredAudioLanguages = request.preferredAudioLanguages
        options.preferredSubtitleLanguages = request.preferredSubtitleLanguages
        options.externalSubtitles = request.externalSubtitles.map {
            ExternalSubtitleTrack(url: $0.url, name: $0.name, language: $0.language,
                                  isForced: $0.isForced, isHearingImpaired: $0.isHearingImpaired,
                                  isDefault: false, httpHeaders: request.headers, formatHint: $0.format)
        }
        settling?.cancel()
        requestedBoostDB = volume.builtInBoostDB(current: 0, passthrough: audioProfile.isPassthrough)
        options.audioShaping = engineShaping(boostDB: requestedBoostDB)
        options.autoplay = request.autoplay
        do {
            try await engine.load(url: request.url, startPosition: request.startPosition, options: options)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            status = .failed(String(describing: error))
            throw error
        }
        playingBoostDB = requestedBoostDB
        applyPlayerVolume()
    }

    /// Fetches a file's opening bytes ahead of a `load` (the next episode), so it starts at once.
    public nonisolated static func prewarm(url: URL, headers: [String: String]) async {
        await AetherEngine.prewarm(url: url, httpHeaders: headers)
    }

    // MARK: Transport

    public func play() { engine.play() }
    public func pause() { engine.pause() }
    public func togglePlayPause() { engine.togglePlayPause() }

    public func stop() {
        engine.stop()
        cues = []
        resetStills(url: nil, headers: [:])
    }

    public func seek(to seconds: Double, exact: Bool = false) async {
        let clamped = max(0, duration > 0 ? min(seconds, duration - 0.5) : seconds)
        seekStartedAt = ContinuousClock().now
        await engine.seek(to: clamped, exact: exact)
    }

    public func seek(by delta: Double) async {
        await seek(to: currentTime + delta)
    }

    public func setRate(_ rate: Double) {
        let clamped = min(max(rate, 0.5), Double(engine.maxSupportedRate))
        engine.setRate(Float(clamped))
        self.rate = clamped
    }

    public func setAudioDelay(_ seconds: Double) {
        engine.setAudioDelay(seconds)
    }

    public func setMuted(_ muted: Bool) {
        isMuted = muted
        applyVolumeAndShaping()
    }

    /// One frame back or forward, paused (pauses first if playing).
    public func stepFrame(_ direction: Int) async {
        if status == .playing { pause() }
        let fps = diagnostics.frameRate ?? 24
        await seek(to: currentTime + Double(direction) / max(1, fps), exact: true)
    }

    // MARK: Stills (scrub previews, snapshots)

    /// A small frame near `seconds` for the scrub tooltip: the engine's cached segments when
    /// they cover it, else the nearest keyframe from the second reader. Nil means time only.
    public func previewFrame(at seconds: Double, maxWidth: Int = 320) async -> CGImage? {
        if supportsScrubThumbnails, let image = await engine.scrubThumbnail(atSeconds: seconds, maxWidth: maxWidth) {
            return image
        }
        return await stillsReader()?.thumbnail(at: seconds, maxWidth: maxWidth)
    }

    /// The exact frame on screen, full size, for Snapshot.
    public func snapshot() async -> CGImage? {
        await stillsReader()?.snapshot(at: currentTime)
    }

    private func stillsReader() -> FrameExtractor? {
        if let stills { return stills }
        guard let source = stillsSource else { return nil }
        let reader = FrameExtractor(url: source.url, httpHeaders: source.headers)
        stills = reader
        return reader
    }

    private func resetStills(url: URL?, headers: [String: String]) {
        if let old = stills { Task.detached(priority: .utility) { await old.shutdown() } }
        stills = nil
        stillsSource = url.map { ($0, headers) }
    }

    // MARK: Tracks

    public func selectAudio(id: Int) {
        engine.selectAudioTrack(index: id)
    }

    /// Adds a subtitle file to the playing session (for example one just
    /// downloaded) and returns its track.
    @discardableResult
    public func addExternalSubtitle(_ sub: ExternalSubtitle, headers: [String: String]) -> PlayerTrack {
        let info = engine.addExternalSubtitleTrack(ExternalSubtitleTrack(
            url: sub.url, name: sub.name, language: sub.language, isForced: sub.isForced,
            isHearingImpaired: sub.isHearingImpaired, isDefault: false, httpHeaders: headers, formatHint: sub.format))
        return PlayerTrack(info)
    }

    public func selectSubtitle(id: Int?) {
        if let id { engine.selectSubtitleTrack(index: id) } else { engine.clearSubtitle() }
    }

    /// Goes back with a subtitle track on (What did they say?). Neither the switch nor the seek
    /// rebuilds the session. The software route reads a track's lines from where it was chosen,
    /// so there it's chosen again once the seek has landed, or the earlier lines never come.
    public func goBack(_ seconds: Double, withSubtitle id: Int) async {
        selectSubtitle(id: id)
        await seek(by: -seconds)
        guard engine.videoRoute == .software else { return }
        try? await Task.sleep(for: .milliseconds(500))
        guard selectedSubtitleID == id else { return }
        selectSubtitle(id: nil)
        selectSubtitle(id: id)
    }

    // MARK: Speech audio (on-device subtitles)

    /// The playing audio for speech recognition: mono 48 kHz from the centre (dialogue)
    /// channel when the mix has one, else the downmix. On the native route it's read up to
    /// ~10 s ahead of the picture from data already fetched, so it costs no extra network.
    /// Nil when this session's audio can't be read. The stream ends on any reload (audio or
    /// subtitle track switch, quality change, next title): ask again to follow the new session.
    public func speechAudio() -> AsyncStream<SpeechAudio>? {
        let tap = engine.installAudioTap(channels: .dialogue)
        guard engine.audioTapHasDeliverySource else {
            engine.removeAudioTap()
            return nil
        }
        return AsyncStream(bufferingPolicy: .bufferingNewest(400)) { continuation in
            let pump = Task.detached {
                for await slice in tap {
                    continuation.yield(SpeechAudio(buffer: slice.buffer, time: slice.sourceTime, discontinuity: slice.discontinuity))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in pump.cancel() }
        }
    }

    public func stopSpeechAudio() {
        engine.removeAudioTap()
    }

    // MARK: Audio shaping

    /// How long sound changes must rest before they reach the engine. Each one rebuilds the
    /// session, so a run of volume keys or a slider drag becomes one rebuild.
    private static let settleTime: Duration = .milliseconds(400)

    /// Maps the device profile plus the built-in volume boost onto the engine.
    private func engineShaping(boostDB boost: Double) -> AudioShaping {
        var shaping = AudioShaping(maxChannels: audioProfile.maxChannels,
                                   dialogueGainDB: audioProfile.dialogueGainDB,
                                   loudnessTargetLUFS: audioProfile.loudnessTargetLUFS,
                                   lfeMixDB: audioProfile.lfeMixDB)
        if audioProfile.nightMode {
            var night = AudioShaping.Compressor.night
            night.makeupGainDB = min(24, night.makeupGainDB + boost)
            shaping.compressor = night
        } else if boost > 0 {
            // ratio 1 compresses nothing: a plain gain into the limiter.
            shaping.compressor = AudioShaping.Compressor(thresholdDB: 0, ratio: 1, makeupGainDB: min(24, boost))
        }
        return shaping
    }

    /// The player's volume follows at once; shaping follows when the changes have settled.
    private func applyVolumeAndShaping() {
        applyPlayerVolume()
        settling?.cancel()
        settling = Task { [weak self] in
            try? await Task.sleep(for: Self.settleTime)
            guard !Task.isCancelled else { return }
            self?.applyShaping()
        }
    }

    private func applyShaping() {
        let boost = volume.builtInBoostDB(current: requestedBoostDB, passthrough: audioProfile.isPassthrough)
        requestedBoostDB = boost
        let shaping = engineShaping(boostDB: boost)
        if shaping != engine.audioShaping { engine.setAudioShaping(shaping) }
    }

    /// Takes back the part of the built-in boost this level doesn't use. A session that can't
    /// be shaped (AVPlayer owns its audio) has none built in.
    private func applyPlayerVolume() {
        let builtIn = engine.audioShapingState == .applied ? playingBoostDB : 0
        engine.volume = isMuted ? 0 : Float(volume.playerVolume(builtInBoostDB: builtIn) * min(1, max(0, fade)))
    }

    // MARK: Engine → Mezzanine

    private func bind() {
        engine.$state.receive(on: DispatchQueue.main).sink { [weak self] state in
            guard let self else { return }
            // A rebuild starts and ends in `.loading`, silent: from here the audio carries the
            // boost last asked for.
            if state == .loading || self.status == .loading {
                self.playingBoostDB = self.requestedBoostDB
                self.applyPlayerVolume()
            }
            self.status = PlayerStatus(state)
        }.store(in: &bag)
        engine.$isBuffering.receive(on: DispatchQueue.main).sink { [weak self] in self?.isBuffering = $0 }.store(in: &bag)
        engine.$duration.receive(on: DispatchQueue.main).sink { [weak self] in self?.duration = $0 }.store(in: &bag)
        engine.clock.$currentTime.receive(on: DispatchQueue.main).sink { [weak self] in self?.currentTime = $0 }.store(in: &bag)
        engine.$hasFirstFrameReadyForDisplay.receive(on: DispatchQueue.main).sink { [weak self] ready in
            guard let self else { return }
            self.firstFrameReady = ready
            if ready, let started = self.loadStartedAt {
                self.diagnostics.timeToFirstFrame = ContinuousClock().now - started
                #if DEBUG
                print("PERF first frame \(Int((ContinuousClock().now - started) / .milliseconds(1))) ms after engine load")
                #endif
                self.loadStartedAt = nil
            }
        }.store(in: &bag)
        engine.$isSeeking.receive(on: DispatchQueue.main).sink { [weak self] seeking in
            guard let self, !seeking, let started = self.seekStartedAt else { return }
            self.diagnostics.lastSeekLatency = ContinuousClock().now - started
            self.seekStartedAt = nil
        }.store(in: &bag)
        engine.$audioTracks.receive(on: DispatchQueue.main).sink { [weak self] in
            self?.audioTracks = $0.map(PlayerTrack.init)
        }.store(in: &bag)
        engine.$subtitleTracks.receive(on: DispatchQueue.main).sink { [weak self] in
            self?.subtitleTracks = $0.map(PlayerTrack.init)
        }.store(in: &bag)
        engine.$activeAudioTrackIndex.receive(on: DispatchQueue.main).sink { [weak self] in self?.selectedAudioID = $0 }.store(in: &bag)
        engine.$activeSubtitleTrackIndex.receive(on: DispatchQueue.main).sink { [weak self] in self?.selectedSubtitleID = $0 }.store(in: &bag)
        engine.$subtitleCues.receive(on: DispatchQueue.main).sink { [weak self] in
            self?.cues = $0.map(PlayerCue.init)
        }.store(in: &bag)

        // Diagnostics for the stats overlay and the Lab matrix.
        engine.$videoRoute.receive(on: DispatchQueue.main).sink { [weak self] in self?.diagnostics.route = $0.rawValue }.store(in: &bag)
        engine.$audioDelivery.receive(on: DispatchQueue.main).sink { [weak self] in self?.diagnostics.audioDelivery = $0.rawValue }.store(in: &bag)
        engine.$audioShapingState.receive(on: DispatchQueue.main).sink { [weak self] in
            self?.diagnostics.audioShaping = $0.rawValue
            self?.applyPlayerVolume()
        }.store(in: &bag)
        engine.$videoFormat.receive(on: DispatchQueue.main).sink { [weak self] in self?.diagnostics.videoFormat = String(describing: $0) }.store(in: &bag)
        engine.$activeVideoDecoder.receive(on: DispatchQueue.main).sink { [weak self] in self?.diagnostics.videoDecoder = $0 }.store(in: &bag)
        engine.$activeAudioDecoder.receive(on: DispatchQueue.main).sink { [weak self] in self?.diagnostics.audioDecoder = $0 }.store(in: &bag)
        engine.$sourceVideoCodecName.receive(on: DispatchQueue.main).sink { [weak self] in self?.diagnostics.videoCodec = $0 }.store(in: &bag)
        engine.$sourceContainerFormat.receive(on: DispatchQueue.main).sink { [weak self] in self?.diagnostics.container = $0 }.store(in: &bag)
        engine.$sourceVideoBitrate.receive(on: DispatchQueue.main).sink { [weak self] in self?.diagnostics.videoBitrate = $0 }.store(in: &bag)
        engine.$sourceVideoFrameRate.receive(on: DispatchQueue.main).sink { [weak self] in self?.diagnostics.frameRate = $0 }.store(in: &bag)
        engine.$mediaChapters.receive(on: DispatchQueue.main).sink { [weak self] in
            self?.chapters = $0.map { PlayerChapter(title: $0.name, start: $0.startSeconds) }
        }.store(in: &bag)
        engine.$currentAVPlayer.receive(on: DispatchQueue.main).sink { [weak self] in self?.avPlayer = $0 }.store(in: &bag)
        engine.$hasFirstFrameReadyForDisplay.receive(on: DispatchQueue.main).sink { [weak self] ready in
            if ready { self?.rebuildPiP() }
        }.store(in: &bag)
        engine.$softwarePiPSource.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.rebuildPiP() }.store(in: &bag)
    }
}

// MARK: - Mezzanine-side types

public struct PlaybackRequest: Sendable {
    public var url: URL
    public var headers: [String: String]
    public var startPosition: Double?
    public var autoplay: Bool
    public var preferredAudioLanguages: [String]
    public var preferredSubtitleLanguages: [String]
    public var externalSubtitles: [ExternalSubtitle]

    public init(url: URL, headers: [String: String], startPosition: Double? = nil, autoplay: Bool = true,
                preferredAudioLanguages: [String] = [], preferredSubtitleLanguages: [String] = [],
                externalSubtitles: [ExternalSubtitle] = []) {
        self.url = url
        self.headers = headers
        self.startPosition = startPosition
        self.autoplay = autoplay
        self.preferredAudioLanguages = preferredAudioLanguages
        self.preferredSubtitleLanguages = preferredSubtitleLanguages
        self.externalSubtitles = externalSubtitles
    }
}

public struct ExternalSubtitle: Sendable, Hashable {
    public var url: URL
    public var name: String?
    public var language: String?
    public var format: String?
    public var isForced: Bool
    public var isHearingImpaired: Bool

    public init(url: URL, name: String? = nil, language: String? = nil, format: String? = nil,
                isForced: Bool = false, isHearingImpaired: Bool = false) {
        self.url = url
        self.name = name
        self.language = language
        self.format = format
        self.isForced = isForced
        self.isHearingImpaired = isHearingImpaired
    }
}

public enum PlayerStatus: Equatable, Sendable {
    case idle, loading, playing, paused, seeking, ended
    case failed(String)

    init(_ state: PlaybackState) {
        switch state {
        case .idle: self = .idle
        case .loading: self = .loading
        case .playing: self = .playing
        case .paused: self = .paused
        case .seeking: self = .seeking
        case .ended: self = .ended
        case .error(let message): self = .failed(message)
        }
    }

    public var isActive: Bool {
        switch self {
        case .playing, .paused, .seeking, .loading: return true
        default: return false
        }
    }
}

public struct PlayerTrack: Identifiable, Hashable, Sendable {
    public let id: Int
    public let name: String
    public let codec: String
    public let language: String?
    public let channels: Int
    public let isDefault: Bool
    public let isForced: Bool
    public let isHearingImpaired: Bool
    public let isCommentary: Bool
    public let isAtmos: Bool
    public let isExternal: Bool

    init(_ t: TrackInfo) {
        id = t.id
        name = t.name
        codec = t.codec
        language = t.language
        channels = t.channels
        isDefault = t.isDefault
        isForced = t.isForced
        isHearingImpaired = t.isHearingImpaired
        isCommentary = t.isCommentary
        isAtmos = t.isAtmos
        isExternal = t.isExternal
    }
}

/// One subtitle line or bitmap to draw over the video.
public struct PlayerCue: Identifiable, Sendable {
    public enum Content: Sendable {
        case text(String)
        case image(CGImage, CGRect)
    }
    public let id: Int
    public let start: Double
    public let end: Double
    public let content: Content

    init(_ cue: SubtitleCue) {
        id = cue.id
        start = cue.startTime
        end = cue.endTime
        switch cue.body {
        case .image(let image): content = .image(image.cgImage, image.position)
        default: content = .text(cue.text ?? "")
        }
    }
}

/// A chapter: where it starts and what it's called.
public struct PlayerChapter: Sendable, Equatable {
    public var title: String
    public var start: Double
    public init(title: String, start: Double) {
        self.title = title
        self.start = start
    }
}

/// What the stats overlay and the Lab matrix show.
public struct PlayerDiagnostics: Sendable, Equatable {
    public var route: String = "none"
    public var audioDelivery: String = "none"
    public var audioShaping: String = "off"
    public var videoFormat: String = "sdr"
    public var videoDecoder: String?
    public var audioDecoder: String?
    public var videoCodec: String?
    public var container: String?
    public var videoBitrate: Int64 = 0
    public var frameRate: Double?
    public var timeToFirstFrame: Duration?
    public var lastSeekLatency: Duration?
}

/// Reports PiP start/stop back to the player.
@MainActor
private final class PiPDelegate: NSObject, AVPictureInPictureControllerDelegate {
    let changed: (Bool) -> Void
    init(changed: @escaping (Bool) -> Void) { self.changed = changed }
    // AVKit calls these on the main thread.
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ c: AVPictureInPictureController) {
        MainActor.assumeIsolated { changed(true) }
    }
    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        MainActor.assumeIsolated { changed(false) }
    }
}

/// The system AirPlay picker, attached to the native route's AVPlayer.
public struct AirPlayButton: NSViewRepresentable {
    let player: MezzaninePlayer
    public init(player: MezzaninePlayer) { self.player = player }

    public func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.isRoutePickerButtonBordered = false
        view.setRoutePickerButtonColor(.white, for: .normal)
        view.setRoutePickerButtonColor(NSColor(red: 0.63, green: 0.55, blue: 1, alpha: 1), for: .active)
        view.player = player.avPlayer
        return view
    }

    public func updateNSView(_ view: AVRoutePickerView, context: Context) {
        view.player = player.avPlayer
    }
}
