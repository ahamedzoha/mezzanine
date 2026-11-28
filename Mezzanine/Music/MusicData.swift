import SwiftUI
import MezzanineKit

// MARK: - Kinds and routes

extension PlexMetadata {
    /// An artist, album, song or audio playlist (what the Music pages and the bar deal in).
    var isMusic: Bool { kind == .artist || kind == .album || kind == .track || isAudioPlaylist }
    var isAudioPlaylist: Bool { kind == .playlist && playlistType == "audio" }
}

extension LibraryQuery.Sort {
    /// Sorts the index answers newest or most first: "Ascending" for them means the reverse.
    var isNaturallyDescending: Bool {
        switch self {
        case .addedNewest, .mostPlayed, .year, .recentlyPlayed, .releasedNewest, .rating, .lastWatched, .duration: true
        default: false
        }
    }
}

/// The Music library's pages in the sidebar, under the library row.
enum MusicSlice: String, CaseIterable, Hashable {
    case artists, albums, songs, playlists

    var label: String {
        switch self {
        case .artists: "Artists"
        case .albums: "Albums"
        case .songs: "Songs"
        case .playlists: "Playlists"
        }
    }

    var symbol: String {
        switch self {
        case .artists: "music.mic"
        case .albums: "opticaldisc"
        case .songs: "music.note"
        case .playlists: "music.note.list"
        }
    }

    /// Sorts this page offers (the View menu and the toolbar list the same).
    var sorts: [LibraryQuery.Sort] {
        switch self {
        case .artists: [.title, .addedNewest, .mostPlayed, .recentlyPlayed]
        case .albums: [.title, .artist, .year, .addedNewest, .mostPlayed, .recentlyPlayed]
        case .songs: [.title, .artist, .album, .year, .addedNewest, .mostPlayed, .recentlyPlayed]
        case .playlists: []
        }
    }

    var kind: String? {
        switch self {
        case .artists: "artist"
        case .albums: "album"
        case .songs: "track"
        case .playlists: nil
        }
    }
}

/// Which music page a pushed route is.
enum MusicPageKind: String, Hashable {
    case album, artist, playlist
}

// MARK: - Words

/// The facts Music prints under things: quiet, tabular, joined by " · ".
enum MusicFormat {
    /// "3:48" (or "1:02:05"): a song's length.
    static func clock(ms: Int?) -> String { Format.clock(Double(ms ?? 0) / 1000) }

    /// What a song with no title in the library is called.
    static let untitledSong = "Untitled Song"

    /// A song's title, or "Untitled Song" when the server has none.
    static func songTitle(_ title: String?) -> String {
        guard let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return untitledSong }
        return title
    }

    /// "3 minutes, 48 seconds": a length as VoiceOver should say it.
    static func spoken(seconds: Double) -> String {
        Duration.seconds(Int(max(0, seconds).rounded())).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
    }

    static func spoken(ms: Int?) -> String { spoken(seconds: Double(ms ?? 0) / 1000) }

    /// "12 songs", "1 song".
    static func songs(_ n: Int) -> String { n == 1 ? "1 song" : "\(n.formatted()) songs" }
    static func albums(_ n: Int) -> String { n == 1 ? "1 album" : "\(n.formatted()) albums" }

    /// The facts under a card, in order.
    static func cardFacts(_ item: PlexMetadata) -> [String] {
        switch item.kind {
        case .album:
            let type = AlbumType(item)
            return [item.parentTitle, item.year.map(String.init), type == .album ? nil : type.label].compactMap { $0 }
        case .artist:
            return [item.childCount.map(albums)].compactMap { $0 }
        case .track:
            return [item.originalTitle ?? item.grandparentTitle, item.parentTitle].compactMap { $0 }
        case .playlist:
            return [item.leafCount.map(songs), item.duration.map(Format.duration)].compactMap { $0 }
        default:
            return []
        }
    }

    /// The line under a card while it is lifted: every fact, joined by " · ".
    static func cardMeta(_ item: PlexMetadata) -> String { cardFacts(item).joined(separator: " · ") }

    /// The line under a card at rest: whose it is (the artist of an album or song).
    static func cardRest(_ item: PlexMetadata) -> String {
        switch item.kind {
        case .album: item.parentTitle ?? ""
        case .track: item.originalTitle ?? item.grandparentTitle ?? ""
        default: ""
        }
    }

    /// A card as VoiceOver reads it: title, then its facts, separated by commas.
    static func spokenCard(_ item: PlexMetadata) -> String {
        ([item.kind == .track ? songTitle(item.title) : item.title] + cardFacts(item)).filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// "FLAC 24/96", "FLAC 16/44.1", "MP3 320": the short quality a list row carries.
    nonisolated static func quality(codec: String?, bitDepth: Int?, samplingRate: Int?, bitrate: Int?) -> String? {
        guard let codec else { return nil }
        let q = AudioQuality(codec: codec, bitDepth: bitDepth, samplingRate: samplingRate, bitrate: bitrate)
        if q.isLossless {
            guard let bitDepth, let samplingRate else { return q.codecLabel }
            let khz = Double(samplingRate) / 1000
            let rate = khz == khz.rounded() ? String(Int(khz)) : String(format: "%.1f", khz)
            return "\(q.codecLabel) \(bitDepth)/\(rate)"
        }
        if let bitrate, bitrate > 0 { return "\(q.codecLabel) \(bitrate)" }
        return q.codecLabel
    }

    /// The album's file quality as its caption names it: the most common one among its songs.
    static func albumQuality(_ tracks: [PlexMetadata]) -> String? {
        var counts: [String: Int] = [:]
        for track in tracks {
            if let caption = AudioQuality(track)?.caption { counts[caption, default: 0] += 1 }
        }
        return counts.max { $0.value < $1.value }?.key
    }

    /// Total length of songs: "53 min", "1 h 31 min".
    static func totalLength(_ tracks: [PlexMetadata]) -> String? {
        let ms = tracks.reduce(0) { $0 + ($1.duration ?? 0) }
        return ms > 0 ? Format.duration(ms) : nil
    }
}

extension AppCommandCenter {
    /// Opens an artist, album, song (its album) or audio playlist.
    func openMusic(_ item: PlexMetadata) {
        switch item.kind {
        case .artist: openMusic(item.ratingKey, .artist)
        case .album: openMusic(item.ratingKey, .album)
        case .track: if let album = item.parentRatingKey { openMusic(album, .album) }
        case .playlist: openMusic(item.ratingKey, .playlist)
        default: break
        }
    }

    func openMusic(_ key: String, _ page: MusicPageKind) {
        let route = DetailRoute(ratingKey: key, music: page)
        guard path.last != route else { return }
        path.append(route)
        focusContent()
    }
}

// MARK: - Index and library helpers

extension LibraryStore {
    /// Artists, albums and songs whose names match, best first (the index answers at once).
    func searchMusic(_ text: String, limit: Int = 60) async -> [PlexMetadata] {
        guard let index else { return [] }
        return await Task.detached(priority: .userInitiated) {
            ((try? index.search(text, kinds: ["artist", "album", "track"], limit: limit)) ?? []).compactMap { $0.metadata() }
        }.value
    }

    /// Queue entries for songs, each from its full detail (streams, loudness) when the index has it.
    func queuedTracks(_ items: [PlexMetadata]) async -> [QueuedTrack] {
        let index = index
        return await Task.detached(priority: .userInitiated) {
            items.compactMap { item in
                let detail = index.flatMap { try? $0.musicDetail(item.ratingKey) }
                return QueuedTrack(detail ?? item)
            }
        }.value
    }

    /// An artist's songs from the index, oldest album first.
    func songs(ofArtist key: String, section: String) async -> [PlexMetadata] {
        guard let index else { return [] }
        return await Task.detached(priority: .userInitiated) {
            var q = LibraryQuery(section: section, kinds: ["track"], sort: .album)
            q.grandparentRatingKey = key
            let songs = ((try? index.items(q)) ?? []).compactMap { $0.metadata() }
            return songs.sorted {
                ($0.parentYear ?? 0, $0.parentTitle ?? "", $0.parentIndex ?? 0, $0.index ?? 0)
                    < ($1.parentYear ?? 0, $1.parentTitle ?? "", $1.parentIndex ?? 0, $1.index ?? 0)
            }
        }.value
    }

    /// One list row of the Songs page: the song, and the quality the index knows.
    struct SongRow: Identifiable, Hashable {
        let item: PlexMetadata
        let quality: String?
        var id: String { item.ratingKey }
    }

    func songRows(_ query: LibraryQuery) async -> [SongRow] {
        guard let index else { return [] }
        return await Task.detached(priority: .userInitiated) {
            ((try? index.items(query)) ?? []).compactMap { row in
                guard let item = row.metadata() else { return nil }
                let quality = MusicFormat.quality(codec: row.audioCodec ?? item.media.first?.audioCodec, bitDepth: row.bitDepth,
                                                  samplingRate: row.samplingRate, bitrate: item.media.first?.bitrate)
                return SongRow(item: item, quality: quality)
            }
        }.value
    }
}

// MARK: - Actions

/// Starting and queueing music from any page, menu or panel. Holds no state of its own.
@MainActor
@Observable
final class MusicActions {
    @ObservationIgnored private weak var session: SessionStore?
    @ObservationIgnored private weak var library: LibraryStore?
    @ObservationIgnored private weak var music: MusicSession?
    @ObservationIgnored private weak var commands: AppCommandCenter?

    func configure(session: SessionStore, library: LibraryStore, music: MusicSession, commands: AppCommandCenter) {
        self.session = session
        self.library = library
        self.music = music
        self.commands = commands
    }

    struct Resolved {
        var tracks: [QueuedTrack]
        var title: String
        var kind: QueueContext.Kind
        var ratingKey: String?
    }

    /// The songs an artist, album, song or playlist stands for, in play order.
    func resolve(_ item: PlexMetadata) async -> Resolved? {
        guard let client = session?.client, let library else { return nil }
        switch item.kind {
        case .track:
            let tracks = await library.queuedTracks([item])
            return tracks.isEmpty ? nil : Resolved(tracks: tracks, title: item.title, kind: .songs, ratingKey: nil)
        case .album:
            guard let songs = try? await client.children(item.ratingKey) else { return nil }
            return Resolved(tracks: await library.queuedTracks(songs), title: item.title, kind: .album, ratingKey: item.ratingKey)
        case .artist:
            let section = item.librarySectionID.map(String.init) ?? commands?.musicSections.first?.key ?? ""
            var songs = await library.songs(ofArtist: item.ratingKey, section: section)
            if songs.isEmpty { songs = (try? await client.allLeaves(item.ratingKey)) ?? [] }
            return Resolved(tracks: await library.queuedTracks(songs), title: item.title, kind: .artist, ratingKey: item.ratingKey)
        case .playlist:
            guard let songs = try? await client.playlistItems(item.ratingKey) else { return nil }
            return Resolved(tracks: await library.queuedTracks(songs), title: item.title, kind: .playlist, ratingKey: item.ratingKey)
        default:
            return nil
        }
    }

    /// The newest request to play something. A slower, older answer that lands after a newer click
    /// must not win, so every play takes a number and drops its answer when a newer one exists.
    @ObservationIgnored private var playGeneration = 0
    /// Play Next and Play Later run one after the other, so what the owner queued first lands first.
    @ObservationIgnored private var queueTail: Task<Void, Never>?

    private func nextGeneration() -> Int {
        playGeneration += 1
        return playGeneration
    }

    /// Whether the queue is already playing this song, album, artist or playlist (Space then
    /// pauses or resumes instead of starting it over).
    func isNowPlaying(_ item: PlexMetadata) -> Bool {
        guard let music, let current = music.queue.current else { return false }
        switch item.kind {
        case .track: return current.ratingKey == item.ratingKey
        case .album: return music.queue.context?.kind == .album && music.queue.context?.ratingKey == item.ratingKey
        case .artist: return music.queue.context?.kind == .artist && music.queue.context?.ratingKey == item.ratingKey
        case .playlist: return music.queue.context?.kind == .playlist && music.queue.context?.ratingKey == item.ratingKey
        default: return false
        }
    }

    /// Space: pause or resume what is playing, or else start `item`.
    func playOrToggle(_ item: PlexMetadata) {
        if isNowPlaying(item), let music { music.togglePlayPause() } else { play(item) }
    }

    /// Plays an item from the top (shuffled when asked), or an album/playlist from one of its songs.
    func play(_ item: PlexMetadata, shuffled: Bool = false, from song: String? = nil) {
        let generation = nextGeneration()
        Task {
            guard let resolved = await resolve(item), generation == playGeneration, let music else { return }
            let start = song.flatMap { key in resolved.tracks.firstIndex { $0.ratingKey == key } } ?? 0
            music.play(tracks: resolved.tracks, startAt: start, contextTitle: resolved.title,
                       contextKind: resolved.kind, ratingKey: resolved.ratingKey, shuffled: shuffled)
        }
    }

    /// Plays one of a page's songs with the page's songs after it.
    func play(song: PlexMetadata, in list: [PlexMetadata], title: String, kind: QueueContext.Kind, ratingKey: String?, window: Int = 500) {
        let generation = nextGeneration()
        Task {
            guard let library, let music, let at = list.firstIndex(where: { $0.ratingKey == song.ratingKey }) else { return }
            let from = max(0, at - 100), to = min(list.count, at + window)
            let tracks = await library.queuedTracks(Array(list[from..<to]))
            guard generation == playGeneration, let start = tracks.firstIndex(where: { $0.ratingKey == song.ratingKey }) else { return }
            music.play(tracks: tracks, startAt: start, contextTitle: title, contextKind: kind, ratingKey: ratingKey)
        }
    }

    func playNext(_ item: PlexMetadata) {
        queue(item, later: false)
    }

    func playLater(_ item: PlexMetadata) {
        queue(item, later: true)
    }

    /// Each request waits for the one before it (their order is the order the owner asked in), and
    /// a new Play drops requests still resolving: the queue it would join is gone.
    private func queue(_ item: PlexMetadata, later: Bool) {
        let generation = playGeneration
        let previous = queueTail
        queueTail = Task {
            await previous?.value
            guard let resolved = await resolve(item), generation == playGeneration, let music else { return }
            if later { music.enqueueLater(resolved.tracks) } else { music.enqueueNext(resolved.tracks) }
            AccessibilityNotification.Announcement(later ? "Added to Up Next" : "Added to Play Next").post()
        }
    }

    func goToArtist(of item: PlexMetadata) {
        let key = item.kind == .artist ? item.ratingKey : item.kind == .album ? item.parentRatingKey : item.grandparentRatingKey
        if let key { commands?.openMusic(key, .artist) }
    }

    func goToAlbum(of item: PlexMetadata) {
        let key = item.kind == .album ? item.ratingKey : item.parentRatingKey
        if let key { commands?.openMusic(key, .album) }
    }

    /// Random songs from the whole Music library.
    func shuffleAll(section: String, limit: Int = 500) {
        let generation = nextGeneration()
        Task {
            guard let library, let music, let index = library.index else { return }
            let songs = await Task.detached(priority: .userInitiated) {
                Array(((try? index.items(LibraryQuery(section: section, kinds: ["track"], sort: .title))) ?? [])
                    .shuffled().prefix(limit)).compactMap { $0.metadata() }
            }.value
            let tracks = await library.queuedTracks(songs)
            guard generation == playGeneration else { return }
            music.play(tracks: tracks, contextTitle: "Music", contextKind: .songs, shuffled: true)
        }
    }

    /// Opens the page of whatever plays now (the Now Playing room itself is Music M3).
    func showPlaying() {
        guard let track = music?.queue.current else { return }
        if let album = track.albumKey { commands?.openMusic(album, .album) }
    }
}
