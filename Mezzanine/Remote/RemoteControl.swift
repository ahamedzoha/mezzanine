import AppKit
import SystemConfiguration
import MezzanineKit
import MezzaninePlayback

/// Plex Companion: Mezzanine appears as a player to the Plex apps on this network (the iPhone and
/// Android apps, Plex Web), which can start a title here and control it: play, pause, seek, skip,
/// volume, audio and subtitles. Like casting to a TV, the phone browses and the Mac plays.
///
/// Discovery is GDM on the LAN (`CompanionGDM`); commands arrive over HTTP (`CompanionHTTPServer`)
/// and each controller that subscribes gets the timeline (`CompanionService`). Controllers talk to
/// the player directly, so the phone must be able to reach the Mac (Wi-Fi client isolation blocks
/// it). Settings ▸ Playback ▸ Plex apps can control Mezzanine.
@MainActor @Observable
final class RemoteControl: CompanionPlayer {
    var enabled = UserDefaults.standard.object(forKey: "remoteControlEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "remoteControlEnabled")
            Task { await apply() }
        }
    }
    private(set) var isRunning = false
    private(set) var name = RemoteControl.computerName()
    /// The app that sent the last command ("iPhone", "Plex Web"), for Settings.
    private(set) var lastController: String?
    private(set) var problem: String?

    @ObservationIgnored private weak var playback: PlaybackCoordinator?
    @ObservationIgnored private weak var session: SessionStore?
    @ObservationIgnored private var gdm: CompanionGDM?
    @ObservationIgnored private var http: CompanionHTTPServer?
    @ObservationIgnored private var service: CompanionService?
    @ObservationIgnored private var applying = false

    func start(playback: PlaybackCoordinator, session: SessionStore) {
        self.playback = playback
        self.session = session
        Task { await apply() }
    }

    /// Runs while enabled and signed in (a controller's titles come from the signed-in server).
    func apply() async {
        guard !applying else { return }
        applying = true
        defer { applying = false }
        if enabled, session?.client != nil {
            if !isRunning { await startServices() }
        } else {
            stop()
        }
    }

    /// BYE to the network and close everything (quit, sign-out, switched off).
    func stop() {
        gdm?.stop()
        gdm = nil
        http?.stop()
        http = nil
        if let service { Task { await service.stop() } }
        service = nil
        isRunning = false
    }

    private func startServices() async {
        guard let session else { return }
        let identifier = session.identity.clientIdentifier
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        #if DEBUG
        let shown = "\(name) (Debug)"
        #else
        let shown = name
        #endif
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let service = CompanionService(identity: .init(identifier: identifier, name: shown, version: version,
                                                       platformVersion: "\(os.majorVersion).\(os.minorVersion)"),
                                       player: self)
        #if DEBUG
        await service.setLog { print("REMOTE \($0)") }
        #endif
        let http = CompanionHTTPServer(identifier: identifier)
        do {
            // 32500 is the usual Companion port; Plexamp on this Mac may hold it, then any port does
            // (GDM tells controllers which).
            let port = try await http.start(preferredPort: 32_500) { request in await service.handle(request) }
            let gdm = CompanionGDM(advert: .init(name: shown, port: port, identifier: identifier, version: version))
            #if DEBUG
            gdm.onSearch = { print("REMOTE search from \($0)") }
            #endif
            try gdm.start()
            await service.startPushing()
            self.http = http
            self.gdm = gdm
            self.service = service
            isRunning = true
            problem = nil
            #if DEBUG
            print("REMOTE listening on \(port) as \(shown)")
            #endif
        } catch {
            http.stop()
            problem = "Couldn’t listen for Plex apps (\(error))."
        }
    }

    // MARK: CompanionPlayer

    nonisolated func perform(_ command: CompanionCommand, from controller: String) async {
        await handle(command, from: controller)
    }

    nonisolated func timeline() async -> CompanionTimeline {
        await snapshot()
    }

    private func handle(_ command: CompanionCommand, from controller: String) async {
        guard let playback, let session else { return }
        lastController = controller
        let player = playback.player
        switch command {
        case .playMedia(let media):
            guard let client = session.client, let key = media.ratingKey else { return }
            // Titles from another of the account's servers: not yet (the app plays one server at a time).
            if let machine = media.machineIdentifier, let current = session.currentServer?.clientIdentifier, machine != current {
                problem = "A Plex app asked for a title from another server."
                return
            }
            guard let item = try? await client.metadata(key) else { return }
            NSApp.activate()
            await playback.play(item, from: nil, mediaIndex: media.mediaIndex ?? 0, startAt: media.offset)
        case .play:
            player.play()
        case .pause:
            player.pause()
        case .stop:
            if playback.item != nil { playback.close() }
        case .seek(let time):
            await player.seek(to: time)
        case .stepForward:
            await player.seek(by: 30)
        case .stepBack:
            await player.seek(by: -15)
        case .skipNext:
            await playback.playNext(autoplayed: false)
        case .skipPrevious:
            await playback.playPrevious()
        case .setVolume(let percent):
            player.volume = VolumeLevel(percent: Double(percent))
        case .setStreams(let audio, let subtitle):
            let streams = currentStreams()
            if let audio, let index = streams.first(where: { $0.id == audio && $0.streamType == .audio })?.index {
                playback.selectAudio(trackID: index)
            }
            if let subtitle {
                if subtitle == 0 {
                    playback.selectSubtitle(trackID: nil)
                } else if let index = streams.first(where: { $0.id == subtitle && $0.streamType == .subtitle })?.index {
                    playback.selectSubtitle(trackID: index)
                }
            }
        }
    }

    private func snapshot() -> CompanionTimeline {
        guard let playback, let session, let item = playback.item, !playback.cast.isCasting else { return .stopped }
        let player = playback.player
        let state: CompanionTimeline.State
        switch player.status {
        case .playing: state = player.isBuffering ? .buffering : .playing
        case .paused: state = .paused
        case .loading, .seeking: state = .buffering
        default: return .stopped
        }
        let base = session.connection?.baseURL
        let streams = currentStreams()
        let audio = streams.first { $0.streamType == .audio && $0.index == player.selectedAudioID }?.id
        let subtitle = player.selectedSubtitleID.flatMap { id in streams.first { $0.streamType == .subtitle && $0.index == id }?.id }
        return CompanionTimeline(state: state, ratingKey: item.ratingKey, time: player.currentTime, duration: player.duration,
                                 volume: Int(min(100, player.volume.percent).rounded()), machineIdentifier: session.currentServer?.clientIdentifier,
                                 address: base?.host(), port: base?.port ?? (base?.scheme == "https" ? 443 : 32400),
                                 scheme: base?.scheme, audioStreamID: audio, subtitleStreamID: subtitle,
                                 canSkipNext: playback.nextEpisode != nil, canSkipPrevious: playback.previousEpisode != nil)
    }

    private func currentStreams() -> [PlexStream] {
        guard let playback, let item = playback.item, item.media.indices.contains(playback.mediaIndex) else { return [] }
        return item.media[playback.mediaIndex].parts.first?.streams ?? []
    }

    /// The Mac's name (System Settings ▸ General ▸ Sharing), without a slow host lookup.
    static func computerName() -> String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
    }
}
