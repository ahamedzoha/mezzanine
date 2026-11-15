import SwiftUI
import MezzanineKit
import MezzaninePlayback

/// Google Cast: the film plays on a TV with Chromecast built in, Mezzanine is the remote.
///
/// The TV fetches the stream from the Plex server itself: Plex's HLS of the title, copying the
/// video and sound it can play (no re-encode when they fit), opened with a short-lived token
/// so the account token never leaves this Mac. The film continues on the TV from where it was;
/// the Mac pauses. Stop Casting brings it back to the Mac at the TV's position. Plex hears the
/// TV's position as this player's (watch history stays right).
@MainActor @Observable
final class CastController {
    enum State: Equatable {
        case idle
        case connecting(String)
        case casting(String)
        case failed(String)
    }

    private(set) var devices: [CastDevice] = []
    private(set) var state: State = .idle {
        didSet {
            guard state != oldValue else { return }
            switch state {
            case .connecting(let name): AccessibilityNotification.Announcement("Connecting to \(name)").post()
            case .casting(let name): AccessibilityNotification.Announcement("Playing on \(name)").post()
            case .failed(let message): AccessibilityNotification.Announcement("Couldn’t cast. \(message)").post()
            case .idle: if case .casting = oldValue { AccessibilityNotification.Announcement("Playing on this Mac").post() }
            }
        }
    }
    private(set) var status: CastSession.Status?
    /// The device the film is on.
    private(set) var device: CastDevice?

    var isCasting: Bool {
        switch state {
        case .connecting, .casting: return true
        default: return false
        }
    }

    /// The TV's position: its last report, plus the time since while it plays.
    var position: Double {
        guard let status else { return 0 }
        guard status.playerState == "PLAYING" else { return status.currentTime }
        return status.currentTime + Date().timeIntervalSince(statusAt)
    }
    @ObservationIgnored private var statusAt = Date()
    var isPlaying: Bool { status?.playerState == "PLAYING" || status?.playerState == "BUFFERING" }

    @ObservationIgnored private var discovery: CastDiscovery?
    @ObservationIgnored private var session: CastSession?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var transcodeSession: String?
    @ObservationIgnored private var client: PlexServerClient?
    @ObservationIgnored private var castItem: PlexMetadata?
    @ObservationIgnored private var castMediaIndex = 0
    @ObservationIgnored private var castIsLocal = true
    /// Where the film was when the cast started (the Mac resumes here if the TV never played).
    @ObservationIgnored private(set) var startPosition: Double = 0
    @ObservationIgnored private var reachedPlay = false
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// This cast asks Plex for H.264 video.
    @ObservationIgnored private var convertsVideo = false
    /// Where the film was when casting stopped (the Mac picks up from here).
    @ObservationIgnored var onStopped: ((Double) -> Void)?
    /// The film ended on the TV (the next episode can follow there).
    @ObservationIgnored var onFinished: ((CastDevice) -> Void)?

    /// Starts looking for Cast devices (once; Bonjour browsing is cheap).
    func startDiscovery() {
        guard discovery == nil else { return }
        let discovery = CastDiscovery()
        self.discovery = discovery
        discovery.start()
        Task { [weak self] in
            for await found in discovery.devices { self?.devices = found }
        }
    }

    /// Casts `item` to `device` from `position` seconds. The TV first gets the file's own video
    /// and sound re-packaged (no re-encode); a TV that can't play that video (HEVC on many
    /// built-in Chromecasts) gets H.264 from Plex instead, remembered for that TV.
    func cast(_ item: PlexMetadata, mediaIndex: Int, at position: Double, to device: CastDevice,
              client: PlexServerClient, isLocal: Bool) async {
        await stop(resume: false)
        self.device = device
        self.client = client
        castItem = item
        castMediaIndex = mediaIndex
        castIsLocal = isLocal
        startPosition = position
        reachedPlay = false
        // A TV that refused a file's own streams before gets the compatible version at once,
        // unless this file is already H.264 with stereo sound.
        let media = item.media.indices.contains(mediaIndex) ? item.media[mediaIndex] : nil
        let plain = media?.videoCodec?.lowercased() == "h264" && (media?.audioChannels ?? 2) <= 2
        convertsVideo = !plain && UserDefaults.standard.bool(forKey: Self.noHEVCKey(device))
        state = .connecting(device.name)
        let task = Task { await load(at: position) }
        loadTask = task
        await task.value
    }

    /// Casts the last title to the last TV again (Try Again after a failure).
    func retry() async {
        guard case .failed = state, let device, let client, let item = castItem else { return }
        await cast(item, mediaIndex: castMediaIndex, at: reachedPlay ? position : startPosition, to: device,
                   client: client, isLocal: castIsLocal)
    }

    private func load(at position: Double) async {
        guard let device, let client, let item = castItem else { return }
        do {
            let token = try await client.transientToken()
            try Task.checkCancellation()
            // Compatible: Plex converts to H.264 with stereo AAC (no copying of what the TV refused).
            let options = TranscodeOptions(directStream: !convertsVideo, mediaIndex: castMediaIndex, isLocal: castIsLocal)
            let identity = client.identityHeaders
            let codecs = convertsVideo ? "h264+stereo" : "copy"
            if let decision = client.urls.castTranscode("decision", ratingKey: item.ratingKey, options, token: token,
                                                         identity: identity, compatible: convertsVideo) {
                try await client.decideTranscode(decision)
            }
            try Task.checkCancellation()
            guard let stream = client.urls.castTranscode("start.m3u8", ratingKey: item.ratingKey, options, token: token,
                                                         identity: identity, compatible: convertsVideo)
            else { throw PlexError.notFound }
            endTranscode()
            transcodeSession = options.session
            let artPath = item.kind == .episode ? (item.grandparentThumb ?? item.thumb) : item.thumb
            let image = artPath.flatMap { client.urls.castImage($0, width: 600, height: 900, token: token) }
            let session: CastSession
            if let existing = self.session {
                session = existing
            } else {
                session = CastSession(device: device)
                self.session = session
                try await session.start()
                try Task.checkCancellation()
                follow(session)
            }
            try await session.load(url: stream, contentType: "application/x-mpegURL", title: Format.displayTitle(item),
                                   subtitle: item.kind == .episode ? [Format.episodeCode(item), item.title].compactMap { $0 }.joined(separator: " · ") : nil,
                                   image: image, startTime: position)
            try Task.checkCancellation()
            state = .casting(device.name)
            #if DEBUG
            print("CAST loaded on \(device.name) video=\(codecs)")
            #endif
        } catch is CancellationError {
            // Cancelled while connecting (Cancel, Close, another TV): stop() has tidied up.
        } catch {
            #if DEBUG
            print("CAST failed: \(error)")
            #endif
            await fail(Self.message(error, device: device.name))
        }
    }

    private func follow(_ session: CastSession) {
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            for await status in session.statuses {
                guard let self, self.session === session else { return }
                #if DEBUG
                if status.playerState != self.status?.playerState || Int(status.currentTime) / 5 != Int(self.status?.currentTime ?? -5) / 5 {
                    print(String(format: "CAST status %@ %.1f / %.0f %@", status.playerState, status.currentTime, status.duration ?? 0, status.idleReason ?? ""))
                }
                #endif
                self.status = status
                self.statusAt = Date()
                if status.playerState == "PLAYING" { self.reachedPlay = true }
                guard status.playerState == "IDLE", let reason = status.idleReason, reason != "CANCELLED" else { continue }
                switch reason {
                case "FINISHED":
                    let device = self.device
                    await self.stop(resume: false)
                    if let device { self.onFinished?(device) }
                    return
                case "ERROR" where !self.reachedPlay && !self.convertsVideo:
                    // The TV couldn't play the file's own video: Plex converts it, once, and
                    // this TV gets converted video from now on (for anything but H.264).
                    if let device = self.device { UserDefaults.standard.set(true, forKey: Self.noHEVCKey(device)) }
                    self.convertsVideo = true
                    #if DEBUG
                    print("CAST retrying with H.264")
                    #endif
                    await self.load(at: self.startPosition)
                default:
                    await self.fail("\(self.device?.name ?? "The TV") stopped playing")
                    return
                }
            }
            // The connection closed without a word (the TV went away, Wi-Fi dropped).
            if let self, self.session === session, self.isCasting {
                await self.fail("\(self.device?.name ?? "The TV") disconnected")
            }
        }
    }

    /// Something went wrong: the TV is released, the failure shows, and OK resumes on the Mac.
    private func fail(_ message: String) async {
        let session = self.session
        self.session = nil
        await session?.stop()
        endTranscode()
        status = nil
        state = .failed(message)
    }

    private func endTranscode() {
        guard let id = transcodeSession, let client else { return }
        transcodeSession = nil
        // Its own task: a cancelled caller (the status loop) must not cancel the stop request.
        Task.detached { await client.stopTranscode(session: id) }
    }

    private static func noHEVCKey(_ device: CastDevice) -> String { "castConvertsVideo.\(device.id)" }

    // MARK: Remote

    func togglePlay() {
        guard let session else { return }
        let playing = isPlaying
        Task { if playing { await session.pause() } else { await session.play() } }
    }

    func seek(by delta: Double) {
        seek(to: position + delta)
    }

    func seek(to seconds: Double) {
        guard let session else { return }
        let seconds = min(max(0, seconds), max(0, (status?.duration ?? .infinity) - 5))
        status?.currentTime = seconds
        statusAt = Date()
        Task { await session.seek(to: seconds) }
    }

    func changeVolume(by delta: Double) {
        guard let session, let level = status?.volume else { return }
        let target = min(1, max(0, level + delta))
        status?.volume = target
        Task { await session.setVolume(target) }
    }

    /// Ends the cast: the TV stops, and (with `resume`) the Mac picks up at the TV's position
    /// (or where it left off, if the TV never got going).
    func stop(resume: Bool) async {
        let connecting: Bool
        if case .connecting = state { connecting = true } else { connecting = false }
        guard session != nil || connecting else { return }
        loadTask?.cancel()
        loadTask = nil
        let at = reachedPlay ? position : startPosition
        let session = self.session
        self.session = nil
        await session?.stop()
        endTranscode()
        state = .idle
        status = nil
        if resume { onStopped?(at) }
    }

    /// OK on a failure: back to the Mac where the film was.
    func clearFailure() {
        guard case .failed = state else { return }
        state = .idle
        onStopped?(reachedPlay ? position : startPosition)
    }

    static func message(_ error: Error, device: String) -> String {
        switch error as? CastSession.Failure {
        case .unreachable: return "\(device) can’t be reached. Is it on and on this network?"
        case .launchFailed: return "\(device) didn’t open its player"
        case .loadFailed(let reason): return "\(device) couldn’t play this (\(reason))"
        case .closed: return "\(device) disconnected"
        case nil: return (error as? PlexError)?.userMessage ?? "Casting didn’t start"
        }
    }
}

/// The player's Cast button: where the film plays. "This Mac" and every TV on the network,
/// the current one checked (as AirPlay's picker does); picking another TV moves the film there.
struct CastButton: View {
    @Environment(PlaybackCoordinator.self) private var playback

    var body: some View {
        let cast = playback.cast
        Menu {
            Section("Play On") {
                Toggle(isOn: Binding(get: { !cast.isCasting }, set: { on in
                    if on { Task { await playback.stopCasting() } }
                })) { Label("This Mac", systemImage: "laptopcomputer") }
                ForEach(cast.devices) { device in
                    Toggle(isOn: Binding(get: { cast.isCasting && cast.device == device }, set: { on in
                        if on { Task { await playback.startCasting(to: device) } }
                    })) { Label(device.name, systemImage: "tv") }
                }
            }
            if cast.devices.isEmpty {
                Text("Looking for TVs… (needs Local Network access in System Settings ▸ Privacy & Security)")
            }
        } label: {
            Image(systemName: cast.isCasting ? "tv.badge.wifi.fill" : "tv.badge.wifi")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.ink)
                .frame(width: 40, height: 40)
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .glassEffect(.regular.tint(.black.opacity(0.55)), in: Circle())
        .help(helpText(cast))
        .accessibilityLabel("Cast")
        .accessibilityValue(helpText(cast))
    }

    private func helpText(_ cast: CastController) -> String {
        switch cast.state {
        case .connecting(let name): return "Connecting to \(name)"
        case .casting(let name): return "Playing on \(name)"
        default: return "Play on a TV"
        }
    }
}

/// While the film is on the TV: the picture steps back, and the stage says where it's
/// playing, with the TV's position and the remote controls. Left on the gutter (never
/// centred), like every message in the app.
struct CastingPanel: View {
    let item: PlexMetadata
    @Environment(PlaybackCoordinator.self) private var playback

    var body: some View {
        let cast = playback.cast
        ZStack(alignment: .bottomLeading) {
            Color.black.opacity(0.82).allowsHitTesting(false)
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                switch cast.state {
                case .connecting(let name):
                    HStack(spacing: Theme.Space.s) {
                        ProgressView().controlSize(.small)
                        Text("Connecting to \(name)…").font(Theme.Typeface.cardTitle).foregroundStyle(Theme.ink)
                    }
                    Button("Cancel") { Task { await playback.stopCasting() } }
                        .buttonStyle(.bordered).controlSize(.large)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(Theme.Typeface.cardTitle).foregroundStyle(Theme.ink)
                    HStack(spacing: Theme.Space.s) {
                        Button("Resume on This Mac") { cast.clearFailure() }
                            .buttonStyle(.borderedProminent).tint(Theme.lilac)
                        Button("Try Again") { Task { await cast.retry() } }
                            .buttonStyle(.bordered)
                    }
                    .controlSize(.large)
                default:
                    Text("Playing on \(cast.device?.name ?? "the TV")")
                        .font(Theme.Typeface.cardMeta.weight(.semibold)).foregroundStyle(Theme.inkSecondary)
                    Text(Format.displayTitle(item)).font(.system(size: 28, weight: .bold)).foregroundStyle(Theme.ink)
                    if item.kind == .episode {
                        Text([Format.episodeCode(item), item.title].compactMap { $0 }.joined(separator: " · "))
                            .font(Theme.Typeface.body).foregroundStyle(Theme.inkSecondary)
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { _ in progress(cast) }
                    HStack(spacing: Theme.Space.s) {
                        Button {
                            cast.togglePlay()
                        } label: {
                            Label(cast.isPlaying ? "Pause" : "Play", systemImage: cast.isPlaying ? "pause.fill" : "play.fill")
                                .frame(minWidth: 84)
                        }
                        .buttonStyle(.borderedProminent).tint(Theme.lilac)
                        Button("Stop Casting") { Task { await playback.stopCasting() } }
                            .buttonStyle(.bordered)
                        Text(keyHint)
                            .font(Theme.Typeface.cardMeta).foregroundStyle(Theme.inkTertiary)
                    }
                    .controlSize(.large)
                }
            }
            .padding(Theme.Space.gutter)
            .padding(.bottom, 96)
            .frame(maxWidth: 640, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Casting to \(cast.device?.name ?? "a TV")")
    }

    /// The keys as bound now (they're rebindable).
    private var keyHint: String {
        let keys = PlayerShortcuts.shared
        return "\(keys.display(.playPause, separator: "/")) plays or pauses · \(keys.display(.back10, separator: "/")) / \(keys.display(.forward10, separator: "/")) skip · \(keys.display(.volumeUp, separator: "/")) / \(keys.display(.volumeDown, separator: "/")) TV volume"
    }

    private func progress(_ cast: CastController) -> some View {
        let duration = cast.status?.duration ?? playback.player.duration
        let fraction = duration > 0 ? min(1, cast.position / duration) : 0
        return VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.ink.opacity(0.25))
                    Capsule().fill(Theme.ink).frame(width: max(3, geo.size.width * fraction))
                }
                .contentShape(Rectangle())
                .onTapGesture { point in cast.seek(to: duration * Double(point.x / max(1, geo.size.width))) }
            }
            .frame(width: 420, height: 6)
            Text("\(Format.clock(cast.position)) of \(Format.clock(duration))")
                .font(Theme.Typeface.cardMeta.monospacedDigit()).foregroundStyle(Theme.inkSecondary)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Position on the TV")
        .accessibilityValue("\(Format.clock(cast.position)) of \(Format.clock(duration))")
        .accessibilityAdjustableAction { direction in
            cast.seek(by: direction == .increment ? 10 : -10)
        }
    }
}
