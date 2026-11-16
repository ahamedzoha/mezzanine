import SwiftUI
import MezzanineKit
import MezzaninePlayback

/// What's on screen in the player, and the room around it.
///
/// Reports activity through `ActivityReporter` (off under `-MezzanineNoActivity`).
@MainActor
@Observable
final class PlaybackCoordinator {
    /// The item playing, with full detail (markers, chapters, streams).
    private(set) var item: PlexMetadata?
    /// Where the stage opened from, in window coordinates, so the player can
    /// grow out of it and shrink back into it.
    private(set) var origin: CGRect?
    private(set) var error: String?
    var isPresented: Bool { item != nil }
    /// The film plays in a corner tile while the window goes back to browsing.
    private(set) var isMini = false
    /// The film fills the window (the player owns keys, toolbar and focus).
    var ownsWindow: Bool { item != nil && !isMini }

    /// Shrinks the playing film into the corner tile; browsing comes back around it.
    func shrink() {
        // The film is on a TV: the remote stays on the full player.
        guard item != nil, !isMini, !cast.isCasting else { return }
        player.fillsView = false
        withAnimation(Theme.Motion.object) { isMini = true }
    }

    /// Grows the corner tile back into the full player, from where it sits (`from`).
    func expand(from rect: CGRect?) {
        guard isMini else { return }
        origin = rect
        player.fillsView = pictureMode == .fill
        withAnimation(Theme.Motion.object) { isMini = false }
    }

    /// The room's light: the focused title's colours (set by Home and the
    /// library), dimmed to nothing while a film plays.
    var roomPalette: RoomPalette = .dark

    let player: MezzaninePlayer
    private let session: SessionStore
    /// Downloaded copies play instead of the server's file (set at launch).
    weak var downloads: DownloadStore?
    /// The title on screen is playing from its download (Playback info says so).
    private(set) var playingDownload = false
    /// Find Subtitles files on this Mac: track ID → saved entry ID.
    @ObservationIgnored private var savedTracks: [Int: String] = [:]
    /// Server sidecars added during playback: track ID → Plex stream ID.
    @ObservationIgnored private var addedSidecars: [Int: Int] = [:]
    @ObservationIgnored private var savedServerID: String?
    private(set) var reporter: ActivityReporter?
    /// Called after a session ends with the item and where it stopped, so the
    /// local library reflects the new resume point at once.
    var onStopped: ((PlexMetadata, TimeInterval, TimeInterval) -> Void)?

    // MARK: Binge state

    /// How binges behave (Settings ▸ Playback); persisted.
    var binge: BingeSettings = {
        guard let data = UserDefaults.standard.data(forKey: "bingeSettings.v1"),
              let s = try? JSONDecoder().decode(BingeSettings.self, from: data) else { return BingeSettings() }
        return s
    }() {
        didSet { if let data = try? JSONEncoder().encode(binge) { UserDefaults.standard.set(data, forKey: "bingeSettings.v1") } }
    }
    /// The episode after the one playing (episodes only), resolved at load.
    private(set) var nextEpisode: PlexMetadata?
    /// The episode before it, for ⇧N.
    private(set) var previousEpisode: PlexMetadata?
    /// After a film: what to watch next (Plex's related rows), and the row's own name.
    private(set) var suggestions: [PlexMetadata] = []
    private(set) var suggestionsTitle = "More Like This"
    /// Post-play after films (Settings ▸ Playback).
    var showsPostPlay: Bool {
        get { UserDefaults.standard.object(forKey: "postPlayMovies") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "postPlayMovies") }
    }
    /// Episodes played in this sitting (for "skip intro after the first episode").
    private(set) var episodesThisSession = 0
    /// Episodes started by autoplay in a row (for "Still watching?").
    private(set) var autoplayedInARow = 0
    private(set) var sessionStart = Date()
    private var episodesCache: [String: [PlexMetadata]] = [:]

    // MARK: Delivery

    /// How the file reaches the engine. Direct play always comes first; Plex remuxes or
    /// converts only when direct play fails, or when a quality cap is picked.
    private(set) var mode: PlaybackMode = .direct
    /// Set when direct play failed and Mezzanine fell back on its own (shown once).
    private(set) var fallbackNotice: String?
    /// Which file of a multi-version title plays (index into `media`).
    private(set) var mediaIndex = 0
    private var transcodeSession: String?

    /// Subtitles made on this Mac: generated from speech, translated, timing matched (M12).
    let onDevice: OnDeviceSubtitles
    /// Google Cast to a TV.
    let cast = CastController()

    /// Sends the film to a Cast device from where it is; the Mac pauses.
    func startCasting(to device: CastDevice) async {
        guard let item, let client = session.client else { return }
        // From one TV to another, the film carries on from the TV's position.
        let at = cast.isCasting ? cast.position : player.currentTime
        player.pause()
        await cast.cast(item, mediaIndex: mediaIndex, at: at, to: device, client: client,
                        isLocal: session.connection?.connection.route == .local)
    }

    /// Brings the film back to the Mac at the TV's position.
    func stopCasting() async {
        await cast.stop(resume: true)
    }

    /// Fit, fill or zoom, remembered per film and per show.
    var pictureMode: PictureMode = .fit {
        didSet {
            player.fillsView = pictureMode == .fill
            guard let key = pictureKey else { return }
            var saved = UserDefaults.standard.dictionary(forKey: "pictureModes.v1") as? [String: String] ?? [:]
            saved[key] = pictureMode == .fit ? nil : pictureMode.rawValue
            UserDefaults.standard.set(saved, forKey: "pictureModes.v1")
        }
    }

    /// Films keep their own; every episode of a show shares the show's.
    private var pictureKey: String? { item.map { $0.kind == .episode ? ($0.grandparentRatingKey ?? $0.ratingKey) : $0.ratingKey } }

    private func restorePictureMode() {
        let saved = UserDefaults.standard.dictionary(forKey: "pictureModes.v1") as? [String: String] ?? [:]
        let mode = pictureKey.flatMap { saved[$0] }.flatMap(PictureMode.init(rawValue:)) ?? .fit
        if mode != pictureMode { pictureMode = mode } else { player.fillsView = mode == .fill }
    }

    init(player: MezzaninePlayer, session: SessionStore) {
        self.player = player
        self.session = session
        onDevice = OnDeviceSubtitles(player: player)
        onDevice.selectTrack = { [weak self] id in self?.selectSubtitle(trackID: id) }
        cast.onStopped = { [weak self] at in
            guard let self, self.item != nil else { return }
            Task {
                await self.player.seek(to: at)
                self.player.play()
            }
        }
        // An episode that ends on the TV hands over to the next one there (Up Next autoplay).
        cast.onFinished = { [weak self] device in
            guard let self, self.nextEpisode != nil, self.binge.upNextCountdown > 0 else { return }
            Task {
                await self.playNext(autoplayed: true)
                await self.startCasting(to: device)
            }
        }
    }

    /// After a title loads: its generated subtitles come back. An episode keeps generating
    /// when the one before it, from the same show, was.
    private func beginOnDevice(_ detail: PlexMetadata, carryFrom previous: (show: String?, generating: Bool)) {
        let carry = previous.generating && detail.kind == .episode && previous.show != nil && previous.show == detail.grandparentRatingKey
        onDevice.begin(ratingKey: detail.ratingKey, serverID: savedServerID, carry: carry)
    }

    /// Plays a movie or episode (resuming), or the next unwatched episode of
    /// a season or show.
    func play(_ item: PlexMetadata, from origin: CGRect?, mediaIndex: Int = 0) async {
        self.mediaIndex = mediaIndex
        // Choosing a title to play opens the full player, even from the corner tile.
        if isMini { isMini = false }
        await play(item, from: origin, autoplayed: false)
    }

    /// Starts the next episode (Up Next, or N while playing).
    func playNext(autoplayed: Bool) async {
        guard let next = nextEpisode else { return }
        await play(next, from: nil, autoplayed: autoplayed)
    }

    /// Starts the episode before this one, from its resume point.
    func playPrevious() async {
        guard let previous = previousEpisode else { return }
        await play(previous, from: nil, autoplayed: false)
    }

    /// Bumped by every play request and by close: an older request that's still looking its
    /// title up stops at the next check instead of loading over the newer one.
    @ObservationIgnored private var requestGeneration = 0

    private func play(_ item: PlexMetadata, from origin: CGRect?, autoplayed: Bool) async {
        #if DEBUG
        PerfLog.mark("play requested \(item.ratingKey) autoplayed=\(autoplayed)")
        #endif
        requestGeneration += 1
        let generation = requestGeneration
        // Offline: a downloaded film or episode still plays, from its saved details.
        guard let client = session.client else {
            await playOffline(item, from: origin)
            return
        }
        if self.item == nil { sessionStart = Date(); episodesThisSession = 0 }
        lastRequest = item
        autoplayedInARow = autoplayed ? autoplayedInARow + 1 : 0
        error = nil
        do {
            let playable = try await resolvePlayable(item, client: client)
            let detail = try await client.metadata(playable.ratingKey)
            guard generation == requestGeneration else { return }
            if detail.ratingKey != item.ratingKey || !detail.media.indices.contains(mediaIndex) { mediaIndex = 0 }
            guard detail.media.indices.contains(mediaIndex), detail.media[mediaIndex].parts.first?.key != nil else {
                error = "This item has no playable file."
                return
            }
            self.origin = origin
            let previous = (show: self.item?.grandparentRatingKey, generating: onDevice.showsGenerated)
            // What was playing (the episode that just ended, before Up Next): its final report,
            // and the same bookkeeping a close does, so the index and Home know it's done.
            let stopped = self.item.map { (item: $0, time: stopTime, duration: player.duration) }
            onDevice.end()
            withAnimation(Theme.Motion.object) { self.item = detail }
            if let reporter { await reporter.stop(at: stopped?.time, duration: stopped?.duration) }
            if let stopped, stopped.item.ratingKey != detail.ratingKey {
                onStopped?(stopped.item, stopped.time, stopped.duration)
            }
            guard generation == requestGeneration else { return }
            let start = detail.viewOffset.map { Double($0) / 1000 }
            fallbackNotice = nil
            // Direct play first; if the file won't open, let Plex remux it, then convert it.
            var lastError: Error?
            for candidate in [PlaybackMode.direct, .remux, .convert(nil)] {
                do {
                    try await load(detail, mode: candidate, start: start, client: client)
                    lastError = nil
                    if candidate != .direct { fallbackNotice = "Direct play failed · \(candidate.label.lowercased())" }
                    break
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    lastError = error
                }
            }
            if let lastError { throw lastError }
            guard generation == requestGeneration else { return }
            beginOnDevice(detail, carryFrom: previous)
            restorePictureMode()
            let reporter = ActivityReporter(client: client, item: detail, player: player)
            reporter.castPosition = { [weak self] in
                guard let self, self.cast.isCasting, let status = self.cast.status else { return nil }
                return (status.currentTime, status.duration ?? self.player.duration, self.cast.isPlaying)
            }
            self.reporter = reporter
            reporter.start()
            publishNowPlaying(detail)
            if detail.kind == .episode { episodesThisSession += 1 }
            nextEpisode = nil
            previousEpisode = nil
            suggestions = []
            await resolveNext(after: detail, client: client)
        } catch is CancellationError {
        } catch {
            self.error = (error as? PlexError)?.userMessage ?? "Couldn’t start playback."
        }
    }

    /// Loads `detail` into the engine as `mode` asks, at `start`.
    private func load(_ detail: PlexMetadata, mode: PlaybackMode, start: Double?, client: PlexServerClient) async throws {
        let media = detail.media[mediaIndex]
        let streams = media.parts.first?.streams ?? []
        // Follow what Plex has stored for this title (the owner's last choices),
        // and pass sidecar subtitle files so the engine can show them too.
        let audio = streams.first { $0.streamType == .audio && $0.selected == true }?.languageCode
        let subtitle = streams.first { $0.streamType == .subtitle && $0.selected == true }?.languageCode
        sidecarStreamIDs = streams.filter { $0.streamType == .subtitle && $0.key != nil }.map(\.id)
        let sidecars: [ExternalSubtitle] = streams.compactMap { stream in
            guard stream.streamType == .subtitle, let key = stream.key,
                  let url = client.urls.subtitle(streamKey: key) else { return nil }
            return ExternalSubtitle(url: url, name: stream.label, language: stream.languageCode,
                                    format: stream.codec, isForced: stream.forced, isHearingImpaired: stream.hearingImpaired)
        }
        let previousSession = transcodeSession
        var url: URL?
        var headers = client.requestHeaders
        let saved = SavedSubtitles.available(serverID: session.currentServer?.clientIdentifier, ratingKey: detail.ratingKey)
        var subtitleFiles = sidecars + saved.map(\.subtitle)
        switch mode {
        case .direct:
            if let local = downloads?.localFile(for: detail.ratingKey), let record = downloads?.record(detail.ratingKey) {
                // Downloaded: the server does nothing at all.
                url = local
                headers = [:]
                subtitleFiles = Self.localSubtitles(record, downloads: downloads) + saved.map(\.subtitle)
                playingDownload = true
            } else {
                url = media.parts.first?.key.flatMap { client.urls.part(key: $0) }
                playingDownload = false
            }
            transcodeSession = nil
        case .remux, .convert:
            let options = mode.transcodeOptions(mediaIndex: mediaIndex,
                                                isLocal: session.connection?.connection.route == .local)
            if let decision = client.urls.transcodeDecision(ratingKey: detail.ratingKey, options) {
                try await client.decideTranscode(decision)
            }
            url = client.urls.transcode(ratingKey: detail.ratingKey, options)
            transcodeSession = options.session
        }
        guard let url else { throw PlexError.notFound }
        #if DEBUG
        // -ForceDirectFail YES: direct play "fails", to exercise the fallback ladder.
        if mode == .direct, UserDefaults.standard.bool(forKey: "ForceDirectFail") { throw PlexError.http(status: 415) }
        #endif
        if let previousSession, previousSession != transcodeSession {
            Task { await client.stopTranscode(session: previousSession) }
        }
        #if DEBUG
        PerfLog.mark("engine load \(mode)")
        #endif
        do {
            try await player.load(PlaybackRequest(url: url, headers: headers, startPosition: start,
                                                  preferredAudioLanguages: audio.map { [$0] } ?? [],
                                                  preferredSubtitleLanguages: subtitle.map { [$0] } ?? [],
                                                  externalSubtitles: subtitleFiles))
            restoreSavedSubtitle(saved, after: subtitleFiles.count - saved.count)
        } catch {
            #if DEBUG
            print("LOADFAIL mode=\(mode) url=\(PlexURLs.redacted(url)) error=\(error)")
            #endif
            throw error
        }
        self.mode = mode
    }

    /// A downloaded title with no server: its saved details, the local file, no activity
    /// reports (Plex can't hear them).
    private func playOffline(_ item: PlexMetadata, from origin: CGRect?) async {
        guard let downloads, let record = downloads.record(item.ratingKey), let file = downloads.localFile(for: item.ratingKey),
              let detail = record.decoded() else {
            error = "Not connected to the server, and this title isn’t downloaded."
            return
        }
        lastRequest = item
        error = nil
        self.origin = origin
        let previous = (show: self.item?.grandparentRatingKey, generating: onDevice.showsGenerated)
        onDevice.end()
        withAnimation(Theme.Motion.object) { self.item = detail }
        let streams = detail.media.first?.parts.first?.streams ?? []
        let subtitle = streams.first { $0.streamType == .subtitle && $0.selected == true }?.languageCode
        let local = Self.localSubtitles(record, downloads: downloads)
        let saved = SavedSubtitles.available(serverID: record.serverID, ratingKey: detail.ratingKey)
        do {
            try await player.load(PlaybackRequest(
                url: file, headers: [:], startPosition: detail.viewOffset.map { Double($0) / 1000 },
                preferredAudioLanguages: streams.first { $0.streamType == .audio && $0.selected == true }?.languageCode.map { [$0] } ?? [],
                preferredSubtitleLanguages: subtitle.map { [$0] } ?? [],
                externalSubtitles: local + saved.map(\.subtitle)))
            restoreSavedSubtitle(saved, after: local.count)
            beginOnDevice(detail, carryFrom: previous)
            restorePictureMode()
            mode = .direct
            playingDownload = true
            reporter = nil
            nextEpisode = nil
            previousEpisode = nil
            publishNowPlaying(detail)
        } catch is CancellationError {
        } catch {
            self.error = "This download couldn’t be played."
        }
    }

    /// A download's subtitle files, for the engine.
    private static func localSubtitles(_ record: DownloadRecord, downloads: DownloadStore?) -> [ExternalSubtitle] {
        record.subtitles.compactMap { sub in
            guard let url = downloads?.url(sub.file), FileManager.default.fileExists(atPath: url.path) else { return nil }
            return ExternalSubtitle(url: url, name: sub.name, language: sub.language, format: sub.codec,
                                    isForced: sub.forced, isHearingImpaired: sub.hearingImpaired)
        }
    }

    /// Switches delivery for the playing title (Quality in the ⋯ panel, or the failure
    /// panel's Convert), keeping the position.
    func setMode(_ newMode: PlaybackMode) async {
        guard let item, let client = session.client, newMode != mode || isFailed else { return }
        let at = player.currentTime > 1 ? player.currentTime : item.viewOffset.map { Double($0) / 1000 }
        error = nil
        fallbackNotice = nil
        do {
            try await load(item, mode: newMode, start: at, client: client)
            // Generated subtitles stay on screen across the reload.
            if onDevice.showsGenerated { player.selectSubtitle(id: nil) }
        } catch is CancellationError {
        } catch {
            self.error = (error as? PlexError)?.userMessage ?? "Couldn’t switch to \(newMode.label.lowercased())."
        }
    }

    private var isFailed: Bool {
        if case .failed = player.status { return true }
        return error != nil
    }

    private func stopTranscode() {
        guard let id = transcodeSession, let client = session.client else { return }
        transcodeSession = nil
        Task { await client.stopTranscode(session: id) }
    }

    // MARK: Tracks (remembered on the server)

    /// Sidecar subtitle streams in the order they were handed to the engine.
    private var sidecarStreamIDs: [Int] = []

    func selectAudio(trackID: Int) {
        player.selectAudio(id: trackID)
        guard let part = item?.media.first?.parts.first,
              let stream = part.streams.first(where: { $0.streamType == .audio && $0.index == trackID }) else { return }
        remember(partID: part.id, audio: stream.id, subtitle: nil)
    }

    func selectSubtitle(trackID: Int?) {
        onDevice.hideGenerated()
        onDevice.trackChanged()
        player.selectSubtitle(id: trackID)
        if let item {
            SavedSubtitles.setActive(trackID.flatMap { savedTracks[$0] }, serverID: savedServerID, ratingKey: item.ratingKey)
        }
        guard let part = item?.media.first?.parts.first else { return }
        guard let trackID else { remember(partID: part.id, audio: nil, subtitle: 0); return }
        let externalBase = 100_000
        let streamID: Int?
        if let added = addedSidecars[trackID] {
            streamID = added
        } else if trackID >= externalBase {
            let n = trackID - externalBase
            streamID = sidecarStreamIDs.indices.contains(n) ? sidecarStreamIDs[n] : nil
        } else {
            streamID = part.streams.first { $0.streamType == .subtitle && $0.index == trackID }?.id
        }
        if let streamID { remember(partID: part.id, audio: nil, subtitle: streamID) }
    }

    /// A subtitle Find Subtitles just added: a file kept on this Mac (`savedEntry`) or a
    /// sidecar the server fetched (`plexStream`). Selects it and remembers the choice.
    func adoptFoundSubtitle(trackID: Int, savedEntry: String?, plexStream: Int?) {
        if let savedEntry { savedTracks[trackID] = savedEntry }
        if let plexStream { addedSidecars[trackID] = plexStream }
        selectSubtitle(trackID: trackID)
    }

    /// After a load: maps the saved files' track IDs (they follow the other external files)
    /// and puts the one last on screen back on.
    private func restoreSavedSubtitle(_ saved: [(entry: SavedSubtitles.Entry, subtitle: ExternalSubtitle)], after offset: Int) {
        savedTracks = [:]
        addedSidecars = [:]
        savedServerID = session.currentServer?.clientIdentifier ?? item.flatMap { downloads?.record($0.ratingKey)?.serverID }
        for (i, s) in saved.enumerated() { savedTracks[100_000 + offset + i] = s.entry.id }
        guard let active = saved.first(where: { $0.entry.active == true }),
              let trackID = savedTracks.first(where: { $0.value == active.entry.id })?.key,
              player.subtitleTracks.contains(where: { $0.id == trackID }) else { return }
        player.selectSubtitle(id: trackID)
    }

    private func remember(partID: Int, audio: Int?, subtitle: Int?) {
        guard !ActivityReporter.isDisabled, let client = session.client else { return }
        Task { try? await client.setStreams(partID: partID, audioStreamID: audio, subtitleStreamID: subtitle) }
    }

    /// Where playback stopped, for reports: an item that played to its end counts as its full
    /// length (the engine's clock may already have moved off the end).
    private var stopTime: TimeInterval {
        player.status == .ended && player.duration > 0 ? player.duration : player.currentTime
    }

    func close() {
        requestGeneration += 1
        isMini = false
        // Closing the player while casting stops the TV too.
        if cast.isCasting { Task { await cast.stop(resume: false) } }
        let item = self.item
        let time = stopTime, duration = player.duration
        let reporter = self.reporter
        self.reporter = nil
        // Played offline: nothing could reach Plex; keep the position to send later.
        if reporter == nil, playingDownload, session.client == nil, let item,
           let serverID = downloads?.record(item.ratingKey)?.serverID, !ActivityReporter.isDisabled {
            OfflineProgress.record(ratingKey: item.ratingKey, serverID: serverID, time: time, duration: duration)
        }
        Task {
            await reporter?.stop(at: time, duration: duration)
            if let item { onStopped?(item, time, duration) }
        }
        onDevice.end()
        player.stop()
        stopTranscode()
        mode = .direct
        withAnimation(Theme.Motion.object) { self.item = nil }
    }

    /// For app quit: the final report, waited for (at most ~2 s).
    func finishForQuit() async {
        // Generated subtitles written since the last save are kept.
        onDevice.end()
        // Quitting while casting stops the TV too (as closing the player does).
        if cast.isCasting { await cast.stop(resume: false) }
        await reporter?.stop()
        reporter = nil
        if let id = transcodeSession, let client = session.client { await client.stopTranscode(session: id) }
    }

    /// Control Centre / media-key title, with the poster as artwork.
    private func publishNowPlaying(_ detail: PlexMetadata) {
        let title = Format.displayTitle(detail)
        let subtitle = detail.kind == .episode ? [Format.episodeCode(detail), detail.title].compactMap { $0 }.joined(separator: " · ") : detail.year.map(String.init)
        player.setNowPlaying(title: title, subtitle: subtitle, artwork: nil)
        guard let url = session.posterURL(detail.posterPath, pixelWidth: 600) else { return }
        Task { [session, player] in
            guard let cg = try? await session.images.image(for: url, pixelSize: 600) else { return }
            player.setNowPlaying(title: title, subtitle: subtitle, artwork: NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)))
        }
    }

    /// The last item the user tried to play, for Retry.
    private var lastRequest: PlexMetadata?

    func retry() async {
        guard let lastRequest else { return }
        error = nil
        await play(lastRequest, from: nil)
    }

    func clearError() { error = nil }

    /// Finds the next episode, and warms its first bytes so it starts at once.
    private func resolveNext(after episode: PlexMetadata, client: PlexServerClient) async {
        guard episode.kind == .episode, let show = episode.grandparentRatingKey else { return }
        if episodesCache[show] == nil { episodesCache[show] = try? await client.allLeaves(show) }
        // Another title (or none) took the screen meanwhile: this Up Next isn't for it.
        guard item?.ratingKey == episode.ratingKey else { return }
        let all = episodesCache[show] ?? []
        previousEpisode = BingePlanner.previousEpisode(before: episode, in: all)
        nextEpisode = BingePlanner.nextEpisode(after: episode, in: all)
    }

    /// Loads a film's post-play suggestions: the first related rows, unwatched first, never
    /// the film itself.
    func loadSuggestions() async {
        guard let item, item.kind == .movie, suggestions.isEmpty, let client = session.client else { return }
        let hubs = (try? await client.related(item.ratingKey, count: 12)) ?? []
        guard self.item?.ratingKey == item.ratingKey else { return }
        var seen: Set<String> = [item.ratingKey]
        var picks: [PlexMetadata] = []
        for hub in hubs where !hub.items.isEmpty {
            for candidate in hub.items where candidate.kind == .movie && seen.insert(candidate.ratingKey).inserted {
                picks.append(candidate)
            }
            if picks.count >= 6 { break }
        }
        suggestionsTitle = hubs.first { !$0.items.isEmpty }?.title ?? "More Like This"
        suggestions = Array((picks.filter { !$0.isWatched } + picks.filter(\.isWatched)).prefix(6))
    }

    /// Plays a suggestion from post-play (from the start, or its resume point).
    func playSuggestion(_ next: PlexMetadata) async {
        await play(next, from: nil, autoplayed: false)
    }

    /// Warms a title the viewer is likely to play next (its page is open, its poster has had
    /// focus a moment): the file's opening bytes are fetched now, so Play starts without those
    /// round trips. Home network only (8 MB each), never for a downloaded copy, once per file.
    func prewarm(_ target: PlexMetadata) {
        guard target.kind == .movie || target.kind == .episode, item == nil,
              session.connection?.connection.route == .local,
              downloads?.localFile(for: target.ratingKey) == nil,
              let client = session.client, let key = target.media.first?.parts.first?.key,
              let url = client.urls.part(key: key), !warmed.contains(url) else { return }
        warmed.append(url)
        if warmed.count > 12 { warmed.removeFirst() }
        let headers = client.requestHeaders
        Task.detached(priority: .utility) {
            await MezzaninePlayer.prewarm(url: url, headers: headers)
            #if DEBUG
            print("PERF prewarmed \(target.ratingKey)")
            #endif
        }
    }

    @ObservationIgnored private var warmed: [URL] = []

    /// Warms the next episode's file (called when Up Next appears).
    func prewarmNext() {
        guard let next = nextEpisode, let client = session.client,
              let key = next.media.first?.parts.first?.key, let url = client.urls.part(key: key) else { return }
        let headers = client.requestHeaders
        Task.detached(priority: .utility) { await MezzaninePlayer.prewarm(url: url, headers: headers) }
    }

    /// Whether this episode's intro should be skipped without asking.
    var autoSkipsIntro: Bool {
        guard let item, item.kind == .episode else { return false }
        return BingePlanner.shouldAutoSkipIntro(settings: binge, showKey: item.grandparentRatingKey,
                                                episodesThisSession: episodesThisSession - 1)
    }

    var shouldAskStillWatching: Bool {
        BingePlanner.shouldAskStillWatching(settings: binge, autoplayedInARow: autoplayedInARow,
                                            sessionStart: sessionStart, now: Date())
    }

    /// Seasons and shows play their next unwatched episode.
    private func resolvePlayable(_ item: PlexMetadata, client: PlexServerClient) async throws -> PlexMetadata {
        switch item.kind {
        case .movie, .episode, .clip:
            return item
        case .season:
            let episodes = try await client.children(item.ratingKey)
            return episodes.first { !$0.isWatched } ?? episodes.first ?? item
        case .show:
            let episodes = try await client.allLeaves(item.ratingKey)
            return episodes.first { ($0.viewOffset ?? 0) > 0 } ?? episodes.first { !$0.isWatched } ?? episodes.first ?? item
        default:
            return item
        }
    }
}

/// How the playing file reaches the engine.
enum PlaybackMode: Hashable {
    /// The original file, untouched (the server does nothing).
    case direct
    /// Plex copies the streams into HLS (cheap; for files the engine can't open directly).
    case remux
    /// Plex re-encodes, optionally capped (kbps) for slow links.
    case convert(Int?)

    var label: String {
        switch self {
        case .direct: "Original"
        case .remux: "Remuxed by the server"
        case .convert(nil): "Converted by the server"
        case .convert(let kbps?): "\(Self.bitrateLabel(kbps)) · \(kbps >= 8000 ? "1080p" : "720p")"
        }
    }

    static func bitrateLabel(_ kbps: Int) -> String {
        kbps >= 1000 ? String(format: "%g Mbps", Double(kbps) / 1000) : "\(kbps) kbps"
    }

    /// The quality caps offered in the ⋯ panel, best first.
    static let caps: [Int] = [20000, 12000, 8000, 4000, 2000]

    func transcodeOptions(mediaIndex: Int, isLocal: Bool) -> TranscodeOptions {
        switch self {
        case .direct, .remux:
            return TranscodeOptions(directStream: true, mediaIndex: mediaIndex, isLocal: isLocal)
        case .convert(let kbps):
            return TranscodeOptions(directStream: false, maxVideoBitrate: kbps,
                                    videoResolution: kbps.map { $0 >= 8000 ? "1920x1080" : "1280x720" },
                                    mediaIndex: mediaIndex, isLocal: isLocal)
        }
    }
}

/// How the picture meets the window: whole (fit), filling it (edges cropped), or zoomed past
/// black bars that are part of the picture itself (a wide film in a 16:9 frame).
enum PictureMode: String, CaseIterable, Codable {
    case fit, fill, zoom

    var label: String {
        switch self {
        case .fit: "Fit"
        case .fill: "Fill"
        case .zoom: "Zoom"
        }
    }

    var detail: String {
        switch self {
        case .fit: "The whole picture"
        case .fill: "Fills the window; the edges are cropped"
        case .zoom: "Removes black bars that are part of the picture"
        }
    }

    /// How much larger than the window the picture is laid out (Zoom).
    var scale: CGFloat { self == .zoom ? 1.33 : 1 }

    var next: PictureMode {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}
