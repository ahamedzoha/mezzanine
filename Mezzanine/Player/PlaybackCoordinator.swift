import SwiftUI
import MezzanineKit
import MezzaninePlayback

/// What's on screen in the player, and the room around it.
///
/// Activity reporting (timeline, scrobble) arrives in M3 and will be gated
/// by `-MezzanineNoActivity`; until then nothing here writes to the server.
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

    init(player: MezzaninePlayer, session: SessionStore) {
        self.player = player
        self.session = session
    }

    /// Plays a movie or episode (resuming), or the next unwatched episode of
    /// a season or show.
    func play(_ item: PlexMetadata, from origin: CGRect?) async {
        guard let client = session.client else { return }
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
            let start = detail.viewOffset.map { Double($0) / 1000 }
            try await player.load(PlaybackRequest(url: url, headers: client.requestHeaders, startPosition: start,
                                                  preferredAudioLanguages: ["eng"], preferredSubtitleLanguages: ["eng"]))
        } catch is CancellationError {
        } catch {
            self.error = (error as? PlexError)?.userMessage ?? "Couldn’t start playback."
        }
    }

    func close() {
        player.stop()
        withAnimation(Theme.Motion.object) { item = nil }
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
