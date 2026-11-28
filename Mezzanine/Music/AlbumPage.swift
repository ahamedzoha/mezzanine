import SwiftUI
import MezzanineKit

/// An album, in Sleeve's layout: the cover, name, ruled caption and Play / Shuffle / ⋯ stay on the
/// left while the songs scroll on the right, grouped by disc. One click plays a song and the
/// album carries on after it; the playing song's title is lilac and its number is the level glyph.
///
/// Keys: ↑/↓ move through the songs, Return or Space plays the one in hand (else the album),
/// ⌘[ or Esc goes back.
struct AlbumPage: View {
    let route: DetailRoute
    var contentFocus: FocusState<Bool>.Binding

    @Environment(SessionStore.self) private var session
    @Environment(AppCommandCenter.self) private var commands
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(MusicActions.self) private var actions
    @Environment(MusicSession.self) private var music
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var album: PlexMetadata?
    @State private var tracks: [PlexMetadata] = []
    @State private var loaded = false
    @State private var failure: String?
    @State private var focused: String?
    @State private var attempt = 0

    private var isTop: Bool { commands.path.last == route }
    private var focusedTrack: PlexMetadata? { focused.flatMap { key in tracks.first { $0.ratingKey == key } } }
    /// Songs grouped by disc, in disc order (one unnamed group for a single disc).
    private var discs: [(number: Int, songs: [PlexMetadata])] {
        Dictionary(grouping: tracks) { $0.parentIndex ?? 1 }.sorted { $0.key < $1.key }
            .map { (number: $0.key, songs: $0.value.sorted { ($0.index ?? 0) < ($1.index ?? 0) }) }
    }

    var body: some View {
        SleevePage { art in
            if let album { sleeve(album, art: art) }
        } right: { width in
            songs(width: width)
        }
        .overlay { state }
        .focusable()
        .focusEffectDisabled()
        .focused(contentFocus)
        .onMoveCommand { move($0) }
        .onKeyPress(.return) { playFocused() }
        .onKeyPress(.space) { spacePressed() }
        .onKeyPress(.escape) {
            guard commands.canGoBack else { return .ignored }
            commands.goBack()
            return .handled
        }
        .navigationTitle(album?.title ?? "")
        .navigationSubtitle(album?.parentTitle ?? "")
        .task(id: "\(route.ratingKey)|\(attempt)") { await load() }
        .onChange(of: reportedItem, initial: true) { _, _ in report() }
        .onChange(of: isTop) { _, top in if top { report() } }
        .onChange(of: commands.playFocusedRequests) { _, _ in
            if isTop { _ = playFocused() }
        }
        .onDisappear { if commands.detailFocusedItem?.ratingKey == reportedItem?.ratingKey { commands.detailFocusedItem = nil } }
    }

    // MARK: Left column

    private func sleeve(_ album: PlexMetadata, art: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SleeveArt(path: album.posterPath, size: art)
            Text(album.title)
                .font(.system(.title, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Theme.Space.l)
                .accessibilityAddTraits(.isHeader)
            if let artist = album.parentTitle {
                Button { actions.goToArtist(of: album) } label: {
                    Text(artist).font(Theme.Typeface.reading).foregroundStyle(Theme.inkSecondary).lineLimit(2)
                }
                .buttonStyle(.plain)
                .help("Go to Artist")
                .accessibilityHint("Opens the artist")
                .padding(.top, 2)
            }
            MusicCaption(lines: caption(album))
                .padding(.top, Theme.Space.l)
                .frame(width: art, alignment: .leading)
            MusicPageButtons(item: album, width: art)
                .padding(.top, Theme.Space.m)
        }
    }

    private func caption(_ album: PlexMetadata) -> [[String]] {
        let type = AlbumType(album)
        let facts = [type == .album ? nil : type.label, album.year.map(String.init),
                     tracks.isEmpty ? album.leafCount.map(MusicFormat.songs) : MusicFormat.songs(tracks.count),
                     MusicFormat.totalLength(tracks)].compactMap { $0 }
        let file = [MusicFormat.albumQuality(tracks), album.studio].compactMap { $0 }
        return [facts, file]
    }

    // MARK: Songs

    @ViewBuilder private func songs(width: CGFloat) -> some View {
        let columns = SongColumns.album(width: width)
        VStack(alignment: .leading, spacing: 0) {
            SongHeader(columns: columns).padding(.bottom, 6)
            ForEach(discs, id: \.number) { disc in
                if discs.count > 1 {
                    Text("Disc \(disc.number)")
                        .font(Theme.Typeface.cardMeta.weight(.semibold))
                        .foregroundStyle(Theme.inkTertiary)
                        .padding(.horizontal, 12)
                        .padding(.top, disc.number == discs.first?.number ? 4 : Theme.Space.l)
                        .padding(.bottom, 4)
                        .accessibilityAddTraits(.isHeader)
                }
                ForEach(disc.songs, id: \.ratingKey) { song in
                    SongRowView(song: song, columns: columns, isFocused: focused == song.ratingKey,
                                onSelect: { focused = song.ratingKey }) { play(song) }
                        .id(song.ratingKey)
                }
            }
        }
    }

    @ViewBuilder private var state: some View {
        if album == nil && !loaded {
            if let failure {
                RoomMessage(title: "Couldn’t open this album", detail: failure, retry: { attempt += 1 })
            }
        } else if loaded, tracks.isEmpty, let failure {
            RoomMessage(title: "Couldn’t read the songs", detail: failure, retry: { attempt += 1 })
        }
    }

    // MARK: Actions

    private func play(_ song: PlexMetadata) {
        guard let album else { return }
        focused = song.ratingKey
        actions.play(song: song, in: orderedTracks, title: album.title, kind: .album, ratingKey: album.ratingKey, window: orderedTracks.count)
    }

    /// Songs in play order (disc, then track).
    private var orderedTracks: [PlexMetadata] { discs.flatMap(\.songs) }

    private func playFocused() -> KeyPress.Result {
        if let song = focusedTrack { play(song) } else if let album { actions.play(album) } else { return .ignored }
        return .handled
    }

    /// Space: pause or resume when the song in hand (or, with none, this album) already plays.
    private func spacePressed() -> KeyPress.Result {
        if let song = focusedTrack {
            if actions.isNowPlaying(song) { music.togglePlayPause() } else { play(song) }
        } else if let album {
            actions.playOrToggle(album)
        } else { return .ignored }
        return .handled
    }

    private func move(_ direction: MoveCommandDirection) {
        let list = orderedTracks
        guard !list.isEmpty else { return }
        let current = focused.flatMap { key in list.firstIndex { $0.ratingKey == key } }
        switch direction {
        case .down: focused = list[min(list.count - 1, (current ?? -1) + 1)].ratingKey
        case .up: focused = list[max(0, (current ?? list.count) - 1)].ratingKey
        case .left: commands.focusSidebar()
        default: break
        }
    }

    /// What the Item menu and ⌘↩ act on: the song in hand, else the album.
    private var reportedItem: PlexMetadata? { focusedTrack ?? album }

    private func report() {
        guard isTop else { return }
        commands.detailFocusedItem = reportedItem
    }

    // MARK: Loading

    private func load() async {
        guard let client = session.client else { return }
        let key = route.ratingKey
        if album == nil, let cached = library.index.flatMap({ try? $0.item(key) })?.metadata() {
            album = cached
            playback.roomPalette = RoomPalette(cached.ultraBlur) ?? playback.roomPalette
        }
        do {
            // The list first (the page is usable at once), then the full detail: streams, formats, label.
            let listing = try await client.children(key)
            guard !Task.isCancelled else { return }
            tracks = listing
            loaded = true
            let detail = try await client.musicMetadata(keys: [key] + listing.map(\.ratingKey))
            guard !Task.isCancelled else { return }
            if let full = detail.first(where: { $0.ratingKey == key }) {
                album = full
                playback.roomPalette = RoomPalette(full.ultraBlur) ?? playback.roomPalette
            }
            let byKey = Dictionary(detail.map { ($0.ratingKey, $0) }, uniquingKeysWith: { a, _ in a })
            tracks = listing.map { byKey[$0.ratingKey] ?? $0 }
            failure = nil
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            failure = (error as? PlexError)?.userMessage ?? "Plex didn’t answer."
            loaded = true
        }
    }
}
