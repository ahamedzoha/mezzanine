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

    /// The room's light: the focused title's colours (set by Home and the
    /// library), dimmed to nothing while a film plays.
    var roomPalette: RoomPalette = .dark

    let player: MezzaninePlayer
    private let session: SessionStore
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
    /// Episodes played in this sitting (for "skip intro after the first episode").
    private(set) var episodesThisSession = 0
    /// Episodes started by autoplay in a row (for "Still watching?").
    private(set) var autoplayedInARow = 0
    private(set) var sessionStart = Date()
    private var episodesCache: [String: [PlexMetadata]] = [:]

    init(player: MezzaninePlayer, session: SessionStore) {
        self.player = player
        self.session = session
    }

    /// Plays a movie or episode (resuming), or the next unwatched episode of
    /// a season or show.
    func play(_ item: PlexMetadata, from origin: CGRect?) async {
        await play(item, from: origin, autoplayed: false)
    }

    /// Starts the next episode (Up Next, or N while playing).
    func playNext(autoplayed: Bool) async {
        guard let next = nextEpisode else { return }
        await play(next, from: nil, autoplayed: autoplayed)
    }

    private func play(_ item: PlexMetadata, from origin: CGRect?, autoplayed: Bool) async {
        guard let client = session.client else { return }
        if self.item == nil { sessionStart = Date(); episodesThisSession = 0 }
        lastRequest = item
        autoplayedInARow = autoplayed ? autoplayedInARow + 1 : 0
        error = nil
        do {
            let playable = try await resolvePlayable(item, client: client)
            let detail = try await client.metadata(playable.ratingKey)
            guard let key = detail.media.first?.parts.first?.key, let url = client.urls.part(key: key) else {
                error = "This item has no playable file."
                return
            }
            self.origin = origin
            withAnimation(Theme.Motion.object) { self.item = detail }
            if let reporter { await reporter.stop(at: player.currentTime, duration: player.duration) }
            let start = detail.viewOffset.map { Double($0) / 1000 }
            let streams = detail.media.first?.parts.first?.streams ?? []
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
            try await player.load(PlaybackRequest(url: url, headers: client.requestHeaders, startPosition: start,
                                                  preferredAudioLanguages: audio.map { [$0] } ?? [],
                                                  preferredSubtitleLanguages: subtitle.map { [$0] } ?? [],
                                                  externalSubtitles: sidecars))
            let reporter = ActivityReporter(client: client, item: detail, player: player)
            self.reporter = reporter
            reporter.start()
            publishNowPlaying(detail)
            if detail.kind == .episode { episodesThisSession += 1 }
            nextEpisode = nil
            await resolveNext(after: detail, client: client)
        } catch is CancellationError {
        } catch {
            self.error = (error as? PlexError)?.userMessage ?? "Couldn’t start playback."
        }
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
        player.selectSubtitle(id: trackID)
        guard let part = item?.media.first?.parts.first else { return }
        guard let trackID else { remember(partID: part.id, audio: nil, subtitle: 0); return }
        let externalBase = 100_000
        let streamID: Int?
        if trackID >= externalBase {
            let n = trackID - externalBase
            streamID = sidecarStreamIDs.indices.contains(n) ? sidecarStreamIDs[n] : nil
        } else {
            streamID = part.streams.first { $0.streamType == .subtitle && $0.index == trackID }?.id
        }
        if let streamID { remember(partID: part.id, audio: nil, subtitle: streamID) }
    }

    private func remember(partID: Int, audio: Int?, subtitle: Int?) {
        guard !ActivityReporter.isDisabled, let client = session.client else { return }
        Task { try? await client.setStreams(partID: partID, audioStreamID: audio, subtitleStreamID: subtitle) }
    }

    func close() {
        let item = self.item
        let time = player.currentTime, duration = player.duration
        let reporter = self.reporter
        self.reporter = nil
        Task {
            await reporter?.stop(at: time, duration: duration)
            if let item { onStopped?(item, time, duration) }
        }
        player.stop()
        withAnimation(Theme.Motion.object) { self.item = nil }
    }

    /// For app quit: the final report, waited for (at most ~2 s).
    func finishForQuit() async {
        await reporter?.stop()
        reporter = nil
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
        guard let next = BingePlanner.nextEpisode(after: episode, in: episodesCache[show] ?? []) else { return }
        nextEpisode = next
    }

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
