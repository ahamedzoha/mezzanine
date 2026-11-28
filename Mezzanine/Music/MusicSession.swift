import Foundation
import AppKit
import Observation
import MezzanineKit
import MezzaninePlayback

/// App-level coordinator for music playback: owns the `MusicQueue`, `MusicEngine`,
/// `TrackCache`, `NowPlayingPublisher`, and `MusicActivityReporter`, and coordinates
/// with `MediaFocus`.
@MainActor
@Observable
final class MusicSession {
    private(set) var queue = MusicQueue()
    private(set) var status: MusicStatus = .idle
    private(set) var position: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var activeRoute: MusicRoute = .native
    private(set) var currentArtwork: NSImage?
    private(set) var error: String?

    var volume: Float = 1 {
        didSet {
            let clamped = min(1, max(0, volume))
            if volume != clamped { volume = clamped; return }
            engine?.volume = clamped
        }
    }
    var isMuted = false {
        didSet { engine?.isMuted = isMuted }
    }
    var loudnessMode: LoudnessMode = .auto

    var isPlaying: Bool { status == .playing }
    var isActive: Bool { status.isActive || queue.current != nil }

    @ObservationIgnored private var engine: MusicEngine?
    @ObservationIgnored private var cache: TrackCache?
    @ObservationIgnored private var cacheServerID: String?
    @ObservationIgnored private let nowPlaying = NowPlayingPublisher()
    @ObservationIgnored private var reporter: MusicActivityReporter?
    @ObservationIgnored private var positionTask: Task<Void, Never>?
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var nowPlayingActive = false

    @ObservationIgnored private weak var session: SessionStore?
    @ObservationIgnored weak var mediaFocus: MediaFocus?

    init() {}

    func configure(session: SessionStore, mediaFocus: MediaFocus) {
        self.session = session
        self.mediaFocus = mediaFocus
        syncServerState()
    }

    /// Refreshes `TrackCache` and restores the saved `MusicQueue` when server/profile changes.
    func syncServerState() {
        guard let serverID = session?.currentServer?.clientIdentifier else { return }
        if cacheServerID != serverID {
            cacheServerID = serverID
            let bundle = Bundle.main.bundleIdentifier ?? "com.mezzanine.mac"
            if let dir = try? TrackCache.defaultDirectory(bundleID: bundle, serverID: serverID) {
                cache = TrackCache(directory: dir)
            }
            let userID = session?.account.map { String($0.id) } ?? "default"
            if let saved = MusicQueueStore.load(serverID: serverID, userID: userID), queue.isEmpty {
                queue = saved
            }
        }
    }

    // MARK: Queue & Playback

    func play(_ track: QueuedTrack, in tracks: [QueuedTrack] = [], contextTitle: String = "",
              contextKind: QueueContext.Kind = .album, ratingKey: String? = nil, shuffled: Bool = false) {
        let list = tracks.isEmpty ? [track] : tracks
        let index = list.firstIndex(where: { $0.id == track.id }) ?? 0
        play(tracks: list, startAt: index, contextTitle: contextTitle,
             contextKind: contextKind, ratingKey: ratingKey, shuffled: shuffled)
    }

    func play(tracks: [QueuedTrack], startAt index: Int = 0, contextTitle: String = "",
              contextKind: QueueContext.Kind = .album, ratingKey: String? = nil, shuffled: Bool = false) {
        guard !tracks.isEmpty else { return }
        syncServerState()
        mediaFocus?.musicWillStart()
        let context = QueueContext(kind: contextKind, ratingKey: ratingKey, title: contextTitle)
        queue.start(context: context, tracks: tracks, at: index, shuffled: shuffled)
        saveQueue()
        if let current = queue.current {
            startTrack(current)
        }
    }

    func enqueueNext(_ track: QueuedTrack) {
        syncServerState()
        queue.playNext([track])
        saveQueue()
        Task { await prepareNextTrack() }
    }

    func enqueueLater(_ track: QueuedTrack) {
        syncServerState()
        queue.playLater([track])
        saveQueue()
        Task { await prepareNextTrack() }
    }

    func next() {
        guard let nextTrack = queue.advance(userInitiated: true) else {
            stop()
            return
        }
        saveQueue()
        mediaFocus?.musicWillStart()
        startTrack(nextTrack)
    }

    func previous() {
        if position > 3, let engine {
            Task {
                await engine.seek(to: 0)
                position = 0
                publishNowPlaying()
            }
            return
        }
        guard let prevTrack = queue.goBack() else {
            Task { await seek(to: 0) }
            return
        }
        saveQueue()
        mediaFocus?.musicWillStart()
        startTrack(prevTrack)
    }

    func togglePlayPause() {
        switch status {
        case .playing:
            pause()
        case .paused:
            resume()
        case .idle, .ended, .failed:
            if let current = queue.current {
                mediaFocus?.musicWillStart()
                startTrack(current)
            }
        case .loading:
            break
        }
    }

    func pause() {
        guard status == .playing else { return }
        engine?.pause()
        status = .paused
        position = engine?.position ?? position
        reporter?.statusChanged(to: .paused, time: position)
        publishNowPlaying()
    }

    func resume() {
        mediaFocus?.musicWillStart()
        activateNowPlaying()
        if engine?.status == .paused {
            engine?.resume()
            status = .playing
            reporter?.statusChanged(to: .playing, time: position)
            publishNowPlaying()
        } else if let current = queue.current {
            startTrack(current)
        }
    }

    func seek(to seconds: TimeInterval) async {
        guard let engine else { return }
        await engine.seek(to: seconds)
        position = engine.position
        publishNowPlaying()
    }

    func adjustVolume(by delta: Float) {
        volume = min(1, max(0, volume + delta))
    }

    func stop() {
        loadTask?.cancel()
        positionTask?.cancel()
        artworkTask?.cancel()
        let currentPos = position
        let activeReporter = reporter
        reporter = nil
        if let activeReporter {
            Task { await activeReporter.stop(at: currentPos) }
        }
        engine?.stop()
        status = .idle
        position = 0
        duration = 0
        deactivateNowPlaying()
        mediaFocus?.musicDidStop()
    }

    func setShuffle(_ enabled: Bool) {
        queue.setShuffled(enabled)
        saveQueue()
        Task { await prepareNextTrack() }
    }

    func cycleRepeat() {
        queue.repeatMode = queue.repeatMode.next
        saveQueue()
        Task { await prepareNextTrack() }
    }

    func rateCurrent(_ stars: Int) {
        guard let track = queue.current, let client = session?.client else { return }
        Task { await MusicActivityReporter.rate(ratingKey: track.ratingKey, stars: stars, client: client) }
    }

    // MARK: MediaFocus hooks

    func pauseForVideo() {
        if status == .playing {
            engine?.pause()
            status = .paused
            position = engine?.position ?? position
            reporter?.statusChanged(to: .paused, time: position)
        }
        deactivateNowPlaying()
    }

    func resumeFromMediaFocus() {
        resume()
    }

    func deactivateNowPlaying() {
        nowPlayingActive = false
        nowPlaying.deactivate()
    }

    func reactivateNowPlaying() {
        guard isActive else { return }
        activateNowPlaying()
        publishNowPlaying()
    }

    func flushBeforeQuit() async {
        loadTask?.cancel()
        positionTask?.cancel()
        saveQueue()
        if let activeReporter = reporter {
            reporter = nil
            await activeReporter.stop(at: position)
        }
        engine?.stop()
        nowPlaying.deactivate()
    }

    // MARK: Engine & Reporting

    private func ensureEngine() -> MusicEngine? {
        if let engine { return engine }
        guard let created = try? MusicEngine(mode: .live) else { return nil }
        created.volume = volume
        created.isMuted = isMuted
        created.onEvent = { [weak self] event in
            self?.handleEngineEvent(event)
        }
        engine = created
        return created
    }

    private func startTrack(_ track: QueuedTrack) {
        loadTask?.cancel()
        // Take the previous track's reporter and its position before the state resets,
        // or it would be stopped at 0 s.
        let previousReporter = reporter
        let prevPos = position
        reporter = nil
        error = nil
        status = .loading
        position = 0
        duration = track.duration
        activateNowPlaying()
        loadArtwork(for: track)

        loadTask = Task { [weak self] in
            guard let self else { return }
            if let previousReporter {
                await previousReporter.stop(at: prevPos)
            }
            guard !Task.isCancelled else { return }

            guard let engine = self.ensureEngine(),
                  let request = await self.buildRequest(for: track, allowNetworkFetch: true) else {
                self.status = .failed("Unable to prepare track")
                return
            }
            guard !Task.isCancelled else { return }

            do {
                try await engine.play(request, startAt: 0, autoplay: true)
                // A newer start replaced this one while it loaded: its answer is stale.
                guard !Task.isCancelled else { return }
                self.status = engine.status
                self.duration = engine.duration
                self.activeRoute = engine.activeRoute
                self.startPositionTimer()
                // `trackStarted` (fired inside `play`) already made this track's reporter.
                if self.reporter == nil, let client = self.session?.client {
                    let rep = MusicActivityReporter(client: client, track: track)
                    rep.currentPositionProvider = { [weak self] in
                        guard let self else { return (0, .idle) }
                        return (self.position, self.status)
                    }
                    self.reporter = rep
                    rep.start(time: 0, isPlaying: self.status == .playing)
                }
                self.publishNowPlaying()
                self.prefetchUpcoming()
                await self.prepareNextTrack()
            } catch is CancellationError {
            } catch {
                self.error = "\(error)"
                self.status = .failed(String(describing: error))
            }
        }
    }

    private func buildRequest(for track: QueuedTrack, allowNetworkFetch: Bool) async -> MusicTrackRequest? {
        guard let client = session?.client,
              let partKey = track.partKey,
              let streamURL = client.urls.part(key: partKey) else { return nil }

        var route = MusicRoute.choose(codec: track.codec, channels: track.channels)
        var fileURL: URL?

        if route == .native, let partID = track.partID, let cache {
            if let cached = await cache.cachedFile(partID: partID) {
                fileURL = cached
            } else if allowNetworkFetch {
                let ext = (partKey as NSString).pathExtension
                let source = TrackCache.Source(partID: partID, url: streamURL, headers: client.requestHeaders, fileExtension: ext)
                fileURL = try? await cache.fetch(source)
                if fileURL == nil { route = .engine }
            } else {
                route = .engine
            }
        }

        let plan = LoudnessPlan(mode: loudnessMode)
        let gainDB = plan.gain(for: track.loudness, inAlbumOrder: queue.isPlayingContextInOrder).gainDB
        return MusicTrackRequest(
            track: track,
            route: route,
            fileURL: fileURL,
            streamURL: streamURL,
            headers: client.requestHeaders,
            gainDB: gainDB
        )
    }

    private func prepareNextTrack() async {
        guard let engine, let nextTrack = queue.peekNext else {
            engine?.enqueueNext(nil)
            return
        }
        guard let partID = nextTrack.partID,
              let cache,
              let _ = await cache.cachedFile(partID: partID),
              let request = await buildRequest(for: nextTrack, allowNetworkFetch: false) else {
            return
        }
        engine.enqueueNext(request)
    }

    private func prefetchUpcoming() {
        guard let client = session?.client, let cache else { return }
        var pinIDs: Set<Int> = []
        if let id = queue.current?.partID { pinIDs.insert(id) }
        var sources: [TrackCache.Source] = []
        for track in queue.upNext.prefix(2) {
            guard let partID = track.partID, let partKey = track.partKey,
                  let url = client.urls.part(key: partKey) else { continue }
            pinIDs.insert(partID)
            if MusicRoute.choose(codec: track.codec, channels: track.channels) == .native {
                let ext = (partKey as NSString).pathExtension
                sources.append(TrackCache.Source(partID: partID, url: url, headers: client.requestHeaders, fileExtension: ext))
            }
        }
        Task {
            await cache.pin(pinIDs)
            await cache.prefetch(sources)
        }
    }

    private func handleEngineEvent(_ event: MusicEvent) {
        switch event {
        case .trackStarted(let started, let route):
            activeRoute = route
            status = engine?.status ?? .playing
            duration = engine?.duration ?? started.duration
            position = engine?.position ?? 0
            if queue.current?.id != started.id {
                _ = queue.advance(userInitiated: false)
                saveQueue()
            }
            if let client = session?.client, reporter == nil {
                let rep = MusicActivityReporter(client: client, track: started)
                rep.currentPositionProvider = { [weak self] in
                    guard let self else { return (0, .idle) }
                    return (self.position, self.status)
                }
                reporter = rep
                rep.start(time: 0, isPlaying: status == .playing)
            }
            loadArtwork(for: started)
            publishNowPlaying()
            prefetchUpcoming()
            Task { await prepareNextTrack() }
        case .trackEnded(let ended):
            let activeReporter = reporter
            reporter = nil
            if let activeReporter {
                Task { await activeReporter.stop(at: ended.duration) }
            }
            if let nextTrack = queue.advance(userInitiated: false) {
                saveQueue()
                if engine?.upcoming?.track.id != nextTrack.id {
                    startTrack(nextTrack)
                }
            }
        case .needsNext:
            Task { await prepareNextTrack() }
        case .finished:
            status = .ended
            position = 0
            nowPlaying.clear()
            mediaFocus?.musicDidStop()
        case .failed(_, let message):
            error = message
            status = .failed(message)
        }
    }

    private func startPositionTimer() {
        positionTask?.cancel()
        positionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, let engine = self.engine else { continue }
                self.position = engine.position
                self.status = engine.status
                self.publishNowPlaying()
            }
        }
    }

    private func activateNowPlaying() {
        guard !nowPlayingActive else { return }
        nowPlayingActive = true
        nowPlaying.activate(handlers: NowPlayingPublisher.Handlers(
            play: { [weak self] in self?.resume() },
            pause: { [weak self] in self?.pause() },
            togglePlayPause: { [weak self] in self?.togglePlayPause() },
            nextTrack: { [weak self] in self?.next() },
            previousTrack: { [weak self] in self?.previous() },
            seek: { [weak self] seconds in Task { await self?.seek(to: seconds) } }
        ))
    }

    private func publishNowPlaying() {
        guard nowPlayingActive, let track = queue.current else { return }
        let count = queue.history.count + 1 + queue.upNext.count
        let index = queue.history.count
        nowPlaying.setNavigationEnabled(next: queue.peekNext != nil, previous: !queue.history.isEmpty || position > 0)
        nowPlaying.publish(
            track: track,
            position: position,
            duration: duration,
            isPlaying: status == .playing,
            queueIndex: index,
            queueCount: count,
            artwork: currentArtwork
        )
    }

    private func loadArtwork(for track: QueuedTrack) {
        artworkTask?.cancel()
        currentArtwork = nil
        guard let session, let url = session.posterURL(track.thumb, pixelWidth: 600) else { return }
        artworkTask = Task { [weak self] in
            guard let cg = try? await session.images.image(for: url, pixelSize: 600),
                  !Task.isCancelled else { return }
            self?.currentArtwork = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            self?.publishNowPlaying()
        }
    }

    private func saveQueue() {
        guard let serverID = session?.currentServer?.clientIdentifier else { return }
        let userID = session?.account.map { String($0.id) } ?? "default"
        MusicQueueStore.save(queue, serverID: serverID, userID: userID)
    }
}
