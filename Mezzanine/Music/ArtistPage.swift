import SwiftUI
import MezzanineKit

/// An artist, in Sleeve's layout: the round photo, name, facts and bio stay on the left; Popular,
/// the discography (one shelf per kind of release) and Similar Artists scroll on the right.
///
/// Keys: ↑/↓ move through Popular and then the shelves, ←/→ along a shelf, Return opens a sleeve
/// or plays a song, Space plays it, ⌘[ or Esc goes back.
struct ArtistPage: View {
    let route: DetailRoute
    var contentFocus: FocusState<Bool>.Binding

    @Environment(SessionStore.self) private var session
    @Environment(AppCommandCenter.self) private var commands
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(MusicActions.self) private var actions
    @Environment(MusicSession.self) private var music
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var artist: PlexMetadata?
    @State private var popular: [PlexMetadata] = []
    @State private var albums: [PlexMetadata] = []
    @State private var similar: [PlexMetadata] = []
    @State private var loaded = false
    @State private var failure: String?
    @State private var attempt = 0
    @State private var bioOpen = false
    /// Row 0… are Popular's songs (one column each), then the shelves.
    @State private var focus: ShelfFocus?
    @State private var keyboardMoved = false

    private var isTop: Bool { commands.path.last == route }

    /// A discography group or the similar artists: one shelf.
    private struct DiscoGroup: Identifiable {
        let id: String
        let title: String
        let items: [PlexMetadata]
    }

    private var groups: [DiscoGroup] {
        var out: [DiscoGroup] = []
        for type in AlbumType.discographyOrder {
            let items = albums.filter { AlbumType($0) == type }
                .sorted { ($0.year ?? 0, $0.title) < ($1.year ?? 0, $1.title) }
            if !items.isEmpty { out.append(DiscoGroup(id: "type-\(type.rawValue)", title: type.sectionTitle, items: items)) }
        }
        return out
    }

    private var similarGroup: DiscoGroup? { similar.isEmpty ? nil : DiscoGroup(id: "similar", title: "Similar Artists", items: similar) }
    private var shelfGroups: [DiscoGroup] { groups + (similarGroup.map { [$0] } ?? []) }
    private var rowCount: Int { popular.count + shelfGroups.count }

    private var focusedItem: PlexMetadata? {
        guard let focus else { return nil }
        if focus.row < popular.count { return popular[focus.row] }
        let shelf = focus.row - popular.count
        guard shelfGroups.indices.contains(shelf), shelfGroups[shelf].items.indices.contains(focus.column) else { return nil }
        return shelfGroups[shelf].items[focus.column]
    }

    var body: some View {
        SleevePage { art in
            if let artist { sleeve(artist, art: art) }
        } right: { width in
            ScrollViewReader { proxy in
                content(width: width)
                    .onChange(of: focus) { _, _ in
                        guard keyboardMoved, let spot = scrollID else { return }
                        withAnimation(Theme.Motion.object(reduceMotion)) { proxy.scrollTo(spot) }
                    }
            }
        }
        .overlay { state }
        .focusable()
        .focusEffectDisabled()
        .focused(contentFocus)
        .onMoveCommand(perform: move)
        .onKeyPress(.return) { activate(open: true) }
        .onKeyPress(.space) { activate(open: false) }
        .onKeyPress(.escape) {
            guard commands.canGoBack else { return .ignored }
            commands.goBack()
            return .handled
        }
        .navigationTitle(artist?.title ?? "")
        .task(id: "\(route.ratingKey)|\(attempt)") { await load() }
        .onChange(of: reportedItem, initial: true) { _, _ in report() }
        .onChange(of: isTop) { _, top in if top { report() } }
        .onChange(of: commands.playFocusedRequests) { _, _ in
            if isTop { _ = activate(open: false) }
        }
        .onChange(of: bioOpen, initial: true) { _, open in if isTop { commands.biography = (artist?.summary.map(bioIsLong) ?? false, open) } }
        .onChange(of: artist?.summary) { _, _ in if isTop { commands.biography = (artist?.summary.map(bioIsLong) ?? false, bioOpen) } }
        .onChange(of: isTop) { _, top in
            commands.biography = top ? (artist?.summary.map(bioIsLong) ?? false, bioOpen) : (false, false)
        }
        .onChange(of: commands.biographyRequests) { _, _ in
            if isTop, artist?.summary.map(bioIsLong) == true { toggleBio() }
        }
        .onDisappear {
            commands.biography = (false, false)
            if commands.detailFocusedItem?.ratingKey == reportedItem?.ratingKey { commands.detailFocusedItem = nil }
        }
    }

    // MARK: Left column

    private func sleeve(_ artist: PlexMetadata, art: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SleeveArt(path: artist.posterPath, round: true, size: art)
            Text(artist.title)
                .font(.system(.title, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Theme.Space.l)
                .accessibilityAddTraits(.isHeader)
            MusicCaption(lines: [facts(artist)])
                .padding(.top, Theme.Space.m)
                .frame(width: art, alignment: .leading)
            if let bio = artist.summary, !bio.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(bio)
                        .font(Theme.Typeface.body)
                        .foregroundStyle(Theme.inkSecondary)
                        .lineLimit(bioOpen ? nil : 4)
                        .fixedSize(horizontal: false, vertical: true)
                    if bioIsLong(bio) {
                        Button(bioOpen ? "Show Less" : "Show More") { toggleBio() }
                            .buttonStyle(.plain)
                            .font(Theme.Typeface.cardMeta.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                            .contentShape(Rectangle())
                            .help("View ▸ \(bioOpen ? "Show Less of Biography" : "Show More of Biography")")
                    }
                }
                .frame(width: art, alignment: .leading)
                .padding(.top, Theme.Space.m)
            }
            MusicPageButtons(item: artist, width: art)
                .padding(.top, Theme.Space.m)
        }
    }

    private func bioIsLong(_ bio: String) -> Bool { bio.count > 220 }

    private func toggleBio() {
        withAnimation(Theme.Motion.quick) { bioOpen.toggle() }
    }

    /// "Exampleland · Rock · 7 albums · 61 songs": only what the server knows.
    private func facts(_ artist: PlexMetadata) -> [String] {
        let albumCount = albums.isEmpty ? (artist.childCount ?? 0) : albums.filter { AlbumType($0) != .remix }.count
        return [artist.countries.first?.tag, artist.genres.first?.tag,
                albumCount > 0 ? MusicFormat.albums(albumCount) : nil,
                (artist.leafCount ?? 0) > 0 ? MusicFormat.songs(artist.leafCount ?? 0) : nil]
            .compactMap { $0 }
    }

    // MARK: Right column

    @ViewBuilder private func content(width: CGFloat) -> some View {
        let columns = SongColumns.popular(width: width)
        VStack(alignment: .leading, spacing: 0) {
            if !popular.isEmpty {
                Text("Popular").font(Theme.Typeface.shelfTitle).foregroundStyle(Theme.ink)
                    .padding(.leading, 12).padding(.bottom, Theme.Space.s)
                    .accessibilityAddTraits(.isHeader)
                SongHeader(columns: columns).padding(.bottom, 6)
                ForEach(Array(popular.enumerated()), id: \.element.ratingKey) { i, song in
                    SongRowView(song: song, number: i + 1, columns: columns, isFocused: focus?.row == i,
                                onSelect: { setFocus(row: i, column: 0, byKeyboard: false) }) { playPopular(song) }
                        .id("song|\(song.ratingKey)")
                }
            }
            if !groups.isEmpty {
                Text("Discography").font(Theme.Typeface.shelfTitle).foregroundStyle(Theme.ink)
                    .padding(.leading, 12).padding(.top, popular.isEmpty ? 0 : Theme.Space.xl)
                    .accessibilityAddTraits(.isHeader)
            }
            ForEach(Array(shelfGroups.enumerated()), id: \.element.id) { index, group in
                let row = popular.count + index
                if group.id == "similar" {
                    Text("Similar Artists").font(Theme.Typeface.shelfTitle).foregroundStyle(Theme.ink)
                        .padding(.leading, 12).padding(.top, Theme.Space.xl)
                        .accessibilityAddTraits(.isHeader)
                }
                MusicShelf(title: group.title, items: group.items, rowID: group.id, level: .group,
                           inset: 12,
                           hidesTitle: group.id == "similar",
                           focusedColumn: focus?.row == row ? focus?.column : nil,
                           onFocus: { column in setFocus(row: row, column: column, byKeyboard: false) },
                           onOpen: { commands.open($0) }, onPlay: { actions.play($0) })
                    .padding(.top, group.id == "similar" ? 0 : Theme.Space.m)
            }
        }
    }

    @ViewBuilder private var state: some View {
        if artist == nil, !loaded {
            if let failure { RoomMessage(title: "Couldn’t open this artist", detail: failure, retry: { attempt += 1 }) }
        }
    }

    // MARK: Focus and actions

    private var scrollID: String? {
        guard let focus else { return nil }
        if focus.row < popular.count { return "song|\(popular[focus.row].ratingKey)" }
        let shelf = focus.row - popular.count
        guard shelfGroups.indices.contains(shelf) else { return nil }
        let items = shelfGroups[shelf].items
        return items.indices.contains(focus.column) ? "\(shelfGroups[shelf].id)|\(items[focus.column].ratingKey)" : nil
    }

    private func setFocus(row: Int, column: Int, byKeyboard: Bool) {
        keyboardMoved = byKeyboard
        focus = ShelfFocus(row: row, column: column)
        if row >= popular.count, let item = focusedItem { playback.roomPalette = RoomPalette(item.ultraBlur) ?? playback.roomPalette }
    }

    private func move(_ direction: MoveCommandDirection) {
        guard rowCount > 0 else { return }
        guard let current = focus else { setFocus(row: 0, column: 0, byKeyboard: true); return }
        var row = current.row, column = current.column
        switch direction {
        case .up: row = max(0, row - 1)
        case .down: row = min(rowCount - 1, row + 1)
        case .left:
            if row < popular.count || column == 0 { commands.focusSidebar(); return }
            column -= 1
        case .right:
            if row >= popular.count { column = min(shelfGroups[row - popular.count].items.count - 1, column + 1) }
        @unknown default: break
        }
        if row < popular.count { column = 0 } else { column = min(column, shelfGroups[row - popular.count].items.count - 1) }
        setFocus(row: row, column: column, byKeyboard: true)
    }

    /// Return opens a sleeve (or plays a song); Space plays whatever is in hand, else the artist.
    private func activate(open: Bool) -> KeyPress.Result {
        guard let item = focusedItem else {
            guard let artist else { return .ignored }
            if open { actions.play(artist) } else { actions.playOrToggle(artist) }
            return .handled
        }
        // Space on what already plays pauses or resumes it instead of starting it over.
        if !open, actions.isNowPlaying(item) { music.togglePlayPause(); return .handled }
        if item.kind == .track { playPopular(item) }
        else if open { commands.open(item) }
        else { actions.play(item) }
        return .handled
    }

    private func playPopular(_ song: PlexMetadata) {
        guard let artist else { return }
        actions.play(song: song, in: popular, title: artist.title, kind: .artist, ratingKey: artist.ratingKey, window: popular.count)
    }

    private var reportedItem: PlexMetadata? { focusedItem ?? artist }

    private func report() {
        guard isTop else { return }
        commands.detailFocusedItem = reportedItem
    }

    // MARK: Loading

    private func load() async {
        guard let client = session.client else { return }
        let key = route.ratingKey
        let section = commands.musicSections.first?.key ?? ""
        if artist == nil, let cached = library.index.flatMap({ try? $0.item(key) })?.metadata() {
            artist = cached
            playback.roomPalette = RoomPalette(cached.ultraBlur) ?? playback.roomPalette
        }
        // The albums from the index (at once), the full detail and Popular from the server.
        var query = LibraryQuery(section: artist?.librarySectionID.map(String.init) ?? section, kinds: ["album"], sort: .year)
        query.parentRatingKey = key
        let indexed = await library.items(query)
        guard !Task.isCancelled else { return }
        if !indexed.isEmpty { albums = indexed }
        do {
            let detail = try await client.musicMetadata(keys: [key], popularLeaves: true)
            guard !Task.isCancelled else { return }
            if let full = detail.first {
                artist = full
                popular = Array(full.popularLeaves.filter { $0.kind == .track }.prefix(5))
                playback.roomPalette = RoomPalette(full.ultraBlur) ?? playback.roomPalette
            }
            loaded = true
            failure = nil
            if albums.isEmpty, let listed = try? await client.children(key), !Task.isCancelled { albums = listed.filter { $0.kind == .album } }
            if popular.isEmpty { popular = await mostPlayed(section: artist?.librarySectionID.map(String.init) ?? section) }
            if let found = try? await client.similar(key, limit: 12), !Task.isCancelled {
                similar = found.filter { $0.kind == .artist && $0.ratingKey != key }
            }
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            failure = (error as? PlexError)?.userMessage ?? "Plex didn’t answer."
            loaded = true
        }
    }

    private func mostPlayed(section: String) async -> [PlexMetadata] {
        var q = LibraryQuery(section: section, kinds: ["track"], sort: .mostPlayed)
        q.grandparentRatingKey = route.ratingKey
        return Array(await library.items(q).filter { ($0.viewCount ?? 0) > 0 }.prefix(5))
    }
}
