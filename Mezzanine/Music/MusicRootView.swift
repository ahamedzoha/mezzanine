import SwiftUI
import MezzanineKit

/// The Music library's front page, Sleeve's "Root is a Wall": the eight most recent covers lead in
/// a 4 × 2 wall (no video-style hero), the one in focus names itself in a ruled caption under the
/// wall, and Plex's own music rows follow as shelves.
///
/// Keys: arrows move across the wall and the shelves (← at the first column returns to the
/// sidebar), Return opens, Space plays.
struct MusicRootView: View {
    let section: PlexLibrarySection
    var contentFocus: FocusState<Bool>.Binding

    @Environment(SessionStore.self) private var session
    @Environment(AppCommandCenter.self) private var commands
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(MusicActions.self) private var actions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A row of the page: the two rows of the wall, then each Plex row.
    struct Row: Identifiable, Equatable {
        let id: String
        let title: String
        var items: [PlexMetadata]
        var isWall = false
    }

    @State private var rows: [Row] = []
    @State private var loaded = false
    @State private var failure: String?
    @State private var focus = ShelfFocus(row: 0, column: 0)
    @State private var hasFocus = false
    @State private var keyboardMoved = false

    private static let wallColumns = 4

    private var shelves: [Row] { rows.filter { !$0.isWall } }
    private var wall: [PlexMetadata] { rows.filter(\.isWall).flatMap(\.items) }
    private var focusedItem: PlexMetadata? {
        guard hasFocus, rows.indices.contains(focus.row), rows[focus.row].items.indices.contains(focus.column) else { return nil }
        return rows[focus.row].items[focus.column]
    }
    /// What the caption under the wall names: the focused wall tile, else the first.
    private var captioned: PlexMetadata? {
        if let item = focusedItem, wall.contains(where: { $0.ratingKey == item.ratingKey }) { return item }
        return wall.first
    }

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.l) {
                        header(width: geo.size.width)
                        ForEach(shelves) { shelf in
                            let row = rows.firstIndex { $0.id == shelf.id } ?? 0
                            MusicShelf(title: shelf.title, items: shelf.items, rowID: shelf.id,
                                       focusedColumn: hasFocus && focus.row == row ? focus.column : nil,
                                       scrollsToFocus: keyboardMoved,
                                       onFocus: { setFocus(row: row, column: $0, byKeyboard: false) },
                                       onOpen: { commands.open($0) }, onPlay: { actions.play($0) })
                        }
                    }
                    .padding(.top, Theme.Space.l)
                    .padding(.bottom, Theme.Space.xl)
                }
                .onChange(of: focus) { _, _ in
                    guard keyboardMoved, let item = focusedItem, rows.indices.contains(focus.row) else { return }
                    withAnimation(Theme.Motion.object(reduceMotion)) { proxy.scrollTo("\(rows[focus.row].id)|\(item.ratingKey)") }
                }
            }
        }
        .overlay { state }
        .focusable()
        .focusEffectDisabled()
        .focused(contentFocus)
        .onMoveCommand(perform: move)
        .onKeyPress(.return) {
            guard let item = focusedItem else { return .ignored }
            commands.open(item)
            return .handled
        }
        .onKeyPress(.space) {
            guard let item = focusedItem else { return .ignored }
            actions.playOrToggle(item)
            return .handled
        }
        .navigationTitle(section.title)
        // The header beside the wall already says the facts: the toolbar keeps only the name.
        .navigationSubtitle("")
        .task(id: "\(section.key)|\(library.lastSyncedAt?.timeIntervalSince1970 ?? 0)") { await load() }
        .onChange(of: focusedItem, initial: true) { _, item in
            commands.hasFocusedTitle = item != nil
            commands.focusedItem = item
        }
        .onChange(of: commands.playFocusedRequests) { _, _ in
            if commands.path.isEmpty, let item = focusedItem { actions.play(item) }
        }
        .onDisappear {
            if commands.path.isEmpty { commands.hasFocusedTitle = false; commands.focusedItem = nil }
        }
    }

    // MARK: Wall

    /// Wall and caption on the left, the page's name and its one action beside them (under them
    /// when the window is narrow).
    private func header(width: CGFloat) -> some View {
        let usable = width - Theme.Space.gutter * 2
        let wide = usable >= 824 + 40 + 220
        let tile = wide ? 200 : max(90, min(200, (usable - 3 * 8) / 4))
        return Group {
            if wide {
                HStack(alignment: .top, spacing: 40) {
                    wallBlock(tile: tile)
                    aside.padding(.top, 4)
                }
            } else {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    aside
                    wallBlock(tile: tile)
                }
            }
        }
        .padding(.horizontal, Theme.Space.gutter)
    }

    private func wallBlock(tile: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(0..<2, id: \.self) { r in
                    GridRow {
                        ForEach(0..<Self.wallColumns, id: \.self) { c in
                            let i = r * Self.wallColumns + c
                            if wall.indices.contains(i) { wallTile(wall[i], index: i, tile: tile) } else { Color.clear.frame(width: tile, height: tile) }
                        }
                    }
                }
            }
            if let item = captioned { wallCaption(item).frame(width: tile * 4 + 24, alignment: .leading) }
        }
    }

    private func wallTile(_ item: PlexMetadata, index: Int, tile: CGFloat) -> some View {
        let row = index / Self.wallColumns, column = index % Self.wallColumns
        let focused = hasFocus && focus.row == row && focus.column == column
        return WallTile(item: item, isFocused: focused, size: tile,
                        onFocus: { setFocus(row: row, column: column, byKeyboard: false) },
                        onOpen: { commands.open(item) }, onPlay: { actions.play(item) })
            .id("\(rows.indices.contains(row) ? rows[row].id : "wall")|\(item.ratingKey)")
    }

    private func wallCaption(_ item: PlexMetadata) -> some View {
        let facts = [item.parentTitle, item.year.map(String.init), item.leafCount.map(MusicFormat.songs)].compactMap { $0 }
        return VStack(alignment: .leading, spacing: 2) {
            Text(item.title).font(Theme.Typeface.caption).foregroundStyle(Theme.lilac).lineLimit(1)
            FactsLine(facts: facts, font: Theme.Typeface.caption, color: Theme.inkSecondary)
        }
        .padding(.top, Theme.Space.m)
        .overlay(alignment: .topLeading) { Rectangle().fill(Theme.rule).frame(width: 48, height: 1) }
        .id(item.ratingKey)
        .transition(.opacity)
        .animation(Theme.Motion.light, value: item.ratingKey)
    }

    private var aside: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(section.title).font(.system(.title, weight: .semibold)).foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            FactsLine(facts: facts, font: Theme.Typeface.body, color: Theme.inkSecondary).frame(maxWidth: 260, alignment: .leading)
            Button { actions.shuffleAll(section: section.key) } label: {
                Label("Shuffle All", systemImage: "shuffle").labelStyle(.titleAndIcon)
            }
            .buttonStyle(PrimaryButtonStyle())
            .help("Play random songs from the whole library")
        }
    }

    private var facts: [String] {
        guard let c = library.musicCounts[section.key] else { return [] }
        return [c.artists > 0 ? "\(c.artists.formatted()) artists" : nil, c.albums > 0 ? "\(c.albums.formatted()) albums" : nil,
                c.songs > 0 ? "\(c.songs.formatted()) songs" : nil, c.playlists > 0 ? "\(c.playlists.formatted()) playlists" : nil]
            .compactMap { $0 }
    }

    @ViewBuilder private var state: some View {
        if rows.isEmpty {
            if let failure {
                RoomMessage(title: "Couldn’t read \(section.title)", detail: failure, retry: { Task { await load() } })
            } else if loaded {
                RoomMessage(title: "No Music Yet", detail: "Add music to this library in Plex and it appears here.")
            } else if case .syncing(let name, let done, let total) = library.syncState {
                RoomMessage(title: "Reading \(name)", detail: total > 0 ? "\(done.formatted()) of \(total.formatted())" : nil)
            }
        }
    }

    // MARK: Loading

    private func load() async {
        guard let client = session.client else { return }
        do {
            let hubs = try await client.sectionHubs(section.key, count: 24)
            guard !Task.isCancelled else { return }
            let playable = hubs.map { hub -> (PlexHub, [PlexMetadata]) in
                (hub, hub.items.filter { [.artist, .album, .track, .playlist].contains($0.kind) })
            }.filter { !$0.1.isEmpty }
            // The wall: recent albums first (Recently Added), topped up from the other rows.
            var seen = Set<String>()
            var covers: [PlexMetadata] = []
            let ordered = playable.sorted { a, _ in a.0.hubIdentifier.hasPrefix("music.recent.added") }
            for (_, items) in ordered {
                for item in items where item.kind == .album && seen.insert(item.ratingKey).inserted && covers.count < 8 { covers.append(item) }
            }
            var out: [Row] = []
            out.append(Row(id: "wall1", title: "", items: Array(covers.prefix(4)), isWall: true))
            out.append(Row(id: "wall2", title: "", items: Array(covers.dropFirst(4).prefix(4)), isWall: true))
            out = out.filter { !$0.items.isEmpty }
            for (hub, items) in playable {
                out.append(Row(id: hub.hubIdentifier, title: hub.title, items: items))
            }
            rows = out
            loaded = true
            failure = nil
            clampFocus()
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            failure = (error as? PlexError)?.userMessage ?? "Plex didn’t answer."
        }
    }

    // MARK: Focus

    private func setFocus(row: Int, column: Int, byKeyboard: Bool) {
        guard rows.indices.contains(row), rows[row].items.indices.contains(column) else { return }
        keyboardMoved = byKeyboard
        hasFocus = true
        focus = ShelfFocus(row: row, column: column)
        playback.roomPalette = RoomPalette(rows[row].items[column].ultraBlur) ?? .dark
    }

    private func clampFocus() {
        guard hasFocus else { return }
        guard !rows.isEmpty else { hasFocus = false; return }
        let row = min(max(0, focus.row), rows.count - 1)
        focus = ShelfFocus(row: row, column: min(max(0, focus.column), max(0, rows[row].items.count - 1)))
    }

    private func move(_ direction: MoveCommandDirection) {
        guard !rows.isEmpty else { return }
        guard hasFocus else { setFocus(row: 0, column: 0, byKeyboard: true); return }
        var row = focus.row, column = focus.column
        switch direction {
        case .left:
            // At the first column, ← hands focus back to the sidebar.
            if column == 0 { commands.focusSidebar(); return }
            column -= 1
        case .right: column = min(rows[row].items.count - 1, column + 1)
        case .up: row = max(0, row - 1)
        case .down: row = min(rows.count - 1, row + 1)
        @unknown default: break
        }
        column = min(column, max(0, rows[row].items.count - 1))
        setFocus(row: row, column: column, byKeyboard: true)
    }
}

/// One cover on the wall: no title under it (the caption below the wall names the focused one),
/// lifts and shows the play disc like any sleeve.
private struct WallTile: View {
    let item: PlexMetadata
    let isFocused: Bool
    let size: CGFloat
    let onFocus: () -> Void
    let onOpen: () -> Void
    let onPlay: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var dwell: Task<Void, Never>?
    private var lifted: Bool { isFocused || hovering }

    var body: some View {
        MusicArt(path: item.posterPath, pixelWidth: Int(size * 2))
            .frame(width: size, height: size)
            .overlay(alignment: .bottomTrailing) {
                if lifted { PlayDisc(action: onPlay).padding(10).transition(.opacity) }
            }
            .contrastFocusOutline(isFocused)
            .shadow(color: .black.opacity(lifted ? 0.6 : 0.4), radius: lifted ? 22 : 8, y: lifted ? 14 : 4)
            .scaleEffect(lifted && !reduceMotion ? 1.04 : 1, anchor: .bottom)
            .offset(y: lifted && !reduceMotion ? -4 : 0)
            .animation(reduceMotion ? .easeOut(duration: 0.15) : Theme.Motion.lift, value: lifted)
            .zIndex(lifted ? 1 : 0)
            .contentShape(Rectangle())
            .onHover { inside in
                withAnimation(Theme.Motion.lift) { hovering = inside }
                dwell?.cancel()
                guard inside, !isFocused else { return }
                dwell = Task {
                    try? await Task.sleep(for: Theme.Motion.hoverDwell)
                    if !Task.isCancelled { onFocus() }
                }
            }
            .onTapGesture(perform: onOpen)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(MusicFormat.spokenCard(item))
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Opens")
            .accessibilityAction { onOpen() }
            .accessibilityAction(named: "Play") { onPlay() }
            .contextMenu { MusicContextMenu(item: item) }
    }
}
