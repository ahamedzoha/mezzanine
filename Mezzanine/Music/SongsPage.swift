import SwiftUI
import MezzanineKit

/// Every song in the library as one tabular list (Sleeve keeps the idea of a sleeve only as the
/// 28 pt thumbnail; the page itself is a plain table). One click plays the song and the list
/// carries on after it.
///
/// Keys: ↑/↓ move, Return or Space plays, Home/End jump, ← returns to the sidebar.
struct SongsPage: View {
    let section: PlexLibrarySection
    var contentFocus: FocusState<Bool>.Binding

    @Environment(AppCommandCenter.self) private var commands
    @Environment(LibraryStore.self) private var library
    @Environment(MusicActions.self) private var actions
    @Environment(MusicSession.self) private var music
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rows: [LibraryStore.SongRow] = []
    @State private var loaded = false
    @State private var focused: String?
    @State private var keyboardMoved = false
    @AppStorage private var sortRaw: String
    @AppStorage private var reversed: Bool

    init(section: PlexLibrarySection, contentFocus: FocusState<Bool>.Binding) {
        self.section = section
        self.contentFocus = contentFocus
        _sortRaw = AppStorage(wrappedValue: LibraryQuery.Sort.title.rawValue, "music.\(section.key).songs.sort")
        _reversed = AppStorage(wrappedValue: false, "music.\(section.key).songs.reversed")
    }

    private var sort: LibraryQuery.Sort {
        LibraryQuery.Sort(rawValue: sortRaw).flatMap { MusicSlice.songs.sorts.contains($0) ? $0 : nil } ?? .title
    }
    /// Ascending or descending as the menu says it: against the sort's own natural order.
    private var descending: Bool { reversed != sort.isNaturallyDescending }
    private var descendingBinding: Binding<Bool> {
        Binding(get: { descending }, set: { reversed = $0 != sort.isNaturallyDescending })
    }
    private var query: LibraryQuery { LibraryQuery(section: section.key, kinds: ["track"], sort: sort) }
    private var focusedRow: LibraryStore.SongRow? { focused.flatMap { key in rows.first { $0.id == key } } }

    var body: some View {
        GeometryReader { geo in
            let columns = SongColumns.table(width: geo.size.width - Theme.Space.gutter * 2)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        SongHeader(columns: columns, sorting: SongSorting(current: sort, descending: descending, choose: chooseSort)).padding(.bottom, 4)
                        ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                            SongRowView(song: row.item, number: i + 1, quality: row.quality, columns: columns, height: 36,
                                        isFocused: focused == row.id, onSelect: { focused = row.id }) { play(row) }
                        }
                    }
                    .padding(.horizontal, Theme.Space.gutter)
                    .padding(.top, Theme.Space.l)
                    .padding(.bottom, Theme.Space.xl)
                }
                .onChange(of: focused) { _, key in
                    guard keyboardMoved, let key else { return }
                    withAnimation(Theme.Motion.object(reduceMotion)) { proxy.scrollTo(key) }
                }
            }
        }
        .overlay { state }
        .focusable()
        .focusEffectDisabled()
        .focused(contentFocus)
        .onMoveCommand(perform: move)
        .onKeyPress(.return) { playFocused() }
        .onKeyPress(.space) { spacePressed() }
        .onKeyPress(.home) { jump(to: 0) }
        .onKeyPress(.end) { jump(to: rows.count - 1) }
        .navigationTitle("Songs")
        .navigationSubtitle([section.title, loaded ? "\(rows.count.formatted()) \(rows.count == 1 ? "song" : "songs")" : nil]
            .compactMap { $0 }.joined(separator: " · "))
        .toolbar { ToolbarItem { MusicSortMenu(sorts: MusicSlice.songs.sorts, selection: $sortRaw, descending: descendingBinding) } }
        .task(id: "\(section.key)|\(sortRaw)|\(reversed)|\(library.revision)") { await load() }
        .onChange(of: sortRaw, initial: true) { _, raw in
            commands.musicSorts = MusicSlice.songs.sorts
            commands.musicSort = raw
        }
        .onChange(of: descending, initial: true) { _, down in commands.musicDescending = down }
        // A new sort starts in its own natural order.
        .onChange(of: sortRaw) { _, _ in reversed = false }
        .onChange(of: commands.directionRequest.count) { _, _ in descendingBinding.wrappedValue = commands.directionRequest.descending }
        .onChange(of: commands.sortRequest.count) { _, _ in
            let raw = commands.sortRequest.sort
            if MusicSlice.songs.sorts.contains(where: { $0.rawValue == raw }) { sortRaw = raw }
        }
        .onChange(of: focusedRow?.id, initial: true) { _, _ in
            commands.hasFocusedTitle = focusedRow != nil
            commands.focusedItem = focusedRow?.item
        }
        .onChange(of: commands.playFocusedRequests) { _, _ in
            if commands.path.isEmpty, let row = focusedRow { play(row) }
        }
        .onDisappear {
            commands.musicSorts = []
            commands.musicSort = nil
            if commands.path.isEmpty { commands.hasFocusedTitle = false; commands.focusedItem = nil }
        }
    }

    @ViewBuilder private var state: some View {
        if rows.isEmpty {
            if case .syncing(let name, let done, let total) = library.syncState, library.count(section: section.key) == 0 {
                RoomMessage(title: "Reading \(name)", detail: total > 0 ? "\(done.formatted()) of \(total.formatted())" : nil)
            } else if case .failed(let message) = library.syncState, library.count(section: section.key) == 0 {
                RoomMessage(title: "Couldn’t read \(section.title)", detail: message, retry: { Task { await library.syncAll() } })
            } else if loaded {
                RoomMessage(title: "No songs yet", detail: "Add music to this library in Plex and it appears here.")
            }
        }
    }

    private func load() async {
        let result = await library.songRows(query)
        // A newer sort or sync asked again meanwhile: its answer is the one to show.
        guard !Task.isCancelled else { return }
        rows = reversed ? result.reversed() : result
        loaded = library.count(section: section.key) > 0 || library.syncState == .idle
        if let f = focused, !rows.contains(where: { $0.id == f }) { focused = nil }
    }

    private func play(_ row: LibraryStore.SongRow) {
        focused = row.id
        actions.play(song: row.item, in: rows.map(\.item), title: "Songs", kind: .songs, ratingKey: nil)
    }

    private func playFocused() -> KeyPress.Result {
        guard let row = focusedRow else { return .ignored }
        play(row)
        return .handled
    }

    /// A column heading was clicked: that column's sort, or the other direction when it already rules.
    private func chooseSort(_ new: LibraryQuery.Sort) {
        if new == sort { reversed.toggle() } else { sortRaw = new.rawValue }
    }

    private func spacePressed() -> KeyPress.Result {
        guard let row = focusedRow else { return .ignored }
        if actions.isNowPlaying(row.item) { music.togglePlayPause() } else { play(row) }
        return .handled
    }

    private func jump(to index: Int) -> KeyPress.Result {
        guard !rows.isEmpty else { return .ignored }
        keyboardMoved = true
        focused = rows[max(0, min(index, rows.count - 1))].id
        return .handled
    }

    private func move(_ direction: MoveCommandDirection) {
        guard !rows.isEmpty else { return }
        let current = focused.flatMap { key in rows.firstIndex { $0.id == key } }
        keyboardMoved = true
        switch direction {
        case .down: focused = rows[min(rows.count - 1, (current ?? -1) + 1)].id
        case .up: focused = rows[max(0, (current ?? rows.count) - 1)].id
        case .left: commands.focusSidebar()
        default: break
        }
    }
}
