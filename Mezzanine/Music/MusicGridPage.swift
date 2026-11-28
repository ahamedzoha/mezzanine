import SwiftUI
import MezzanineKit

/// Albums (square sleeves) or Artists (round photos) as one grid, answered from the local index.
///
/// Keys: arrows move (← at the first column returns to the sidebar), Home/End jump, Return opens,
/// Space plays. A click opens; the play disc plays.
struct MusicGridPage: View {
    let section: PlexLibrarySection
    let slice: MusicSlice
    var contentFocus: FocusState<Bool>.Binding

    @Environment(SessionStore.self) private var session
    @Environment(AppCommandCenter.self) private var commands
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(MusicActions.self) private var actions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var items: [PlexMetadata] = []
    @State private var loaded = false
    /// The focused card by its key, so a new sort never moves focus onto another item.
    @State private var focusedKey: String?
    @State private var keyboardMoved = false
    @State private var columns = 1
    @AppStorage private var sortRaw: String
    @AppStorage private var reversed: Bool

    private static let minimum: CGFloat = 170
    private static let spacing: CGFloat = 20

    init(section: PlexLibrarySection, slice: MusicSlice, contentFocus: FocusState<Bool>.Binding) {
        self.section = section
        self.slice = slice
        self.contentFocus = contentFocus
        _sortRaw = AppStorage(wrappedValue: LibraryQuery.Sort.title.rawValue, "music.\(section.key).\(slice.rawValue).sort")
        _reversed = AppStorage(wrappedValue: false, "music.\(section.key).\(slice.rawValue).reversed")
    }

    private var sort: LibraryQuery.Sort {
        LibraryQuery.Sort(rawValue: sortRaw).flatMap { slice.sorts.contains($0) ? $0 : nil } ?? .title
    }
    /// Ascending or descending as the menu says it: against the sort's own natural order.
    private var descending: Bool { reversed != sort.isNaturallyDescending }
    private var descendingBinding: Binding<Bool> {
        Binding(get: { descending }, set: { reversed = $0 != sort.isNaturallyDescending })
    }
    private var query: LibraryQuery { LibraryQuery(section: section.key, kinds: [slice.kind ?? "album"], sort: sort) }
    private var isSyncingEmpty: Bool { slice != .playlists && library.count(section: section.key) == 0 }
    private var focused: Int? { focusedKey.flatMap { key in items.firstIndex { $0.ratingKey == key } } }
    private var focusedItem: PlexMetadata? { focused.map { items[$0] } }

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.minimum, maximum: 220), spacing: Self.spacing, alignment: .top)],
                              alignment: .leading, spacing: 22) {
                        ForEach(Array(items.enumerated()), id: \.element.ratingKey) { index, item in
                            MusicCard(item: item, isFocused: focusedKey == item.ratingKey,
                                      onFocus: { setFocus(index, byKeyboard: false) },
                                      onOpen: { commands.open(item) },
                                      onPlay: { actions.play(item) })
                        }
                    }
                    .padding(.horizontal, Theme.Space.gutter)
                    .padding(.top, Theme.Space.l)
                    .padding(.bottom, Theme.Space.xl)
                }
                .onChange(of: focusedKey) { _, key in
                    // By the item's key, never by position (see CLAUDE.md).
                    guard let key, keyboardMoved else { return }
                    withAnimation(Theme.Motion.object(reduceMotion)) { proxy.scrollTo(key) }
                }
            }
            .onChange(of: geo.size.width, initial: true) { _, w in columns = columnCount(w) }
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
        .onKeyPress(.home) { jump(to: 0) }
        .onKeyPress(.end) { jump(to: items.count - 1) }
        .navigationTitle(slice.label)
        .navigationSubtitle([section.title, loaded ? "\(items.count.formatted()) \(noun)" : nil]
            .compactMap { $0 }.joined(separator: " · "))
        .toolbar {
            if !slice.sorts.isEmpty { ToolbarItem { MusicSortMenu(sorts: slice.sorts, selection: $sortRaw, descending: descendingBinding) } }
        }
        .task(id: "\(section.key)|\(sortRaw)|\(reversed)|\(library.revision)") { await load() }
        .onChange(of: sortRaw, initial: true) { _, raw in
            commands.musicSorts = slice.sorts
            commands.musicSort = raw
        }
        .onChange(of: descending, initial: true) { _, down in commands.musicDescending = down }
        // A new sort starts in its own natural order.
        .onChange(of: sortRaw) { _, _ in reversed = false }
        .onChange(of: commands.directionRequest.count) { _, _ in descendingBinding.wrappedValue = commands.directionRequest.descending }
        .onChange(of: commands.sortRequest.count) { _, _ in
            let raw = commands.sortRequest.sort
            if slice.sorts.contains(where: { $0.rawValue == raw }) { sortRaw = raw }
        }
        .onChange(of: focusedItem, initial: true) { _, item in
            commands.hasFocusedTitle = item != nil
            commands.focusedItem = item
        }
        .onChange(of: commands.playFocusedRequests) { _, _ in
            if commands.path.isEmpty, let item = focusedItem { actions.play(item) }
        }
        .onDisappear {
            commands.musicSorts = []
            commands.musicSort = nil
            if commands.path.isEmpty { commands.hasFocusedTitle = false; commands.focusedItem = nil }
        }
    }

    @ViewBuilder private var state: some View {
        if items.isEmpty {
            if case .syncing(let name, let done, let total) = library.syncState, isSyncingEmpty {
                RoomMessage(title: "Reading \(name)", detail: total > 0 ? "\(done.formatted()) of \(total.formatted())" : nil)
            } else if case .failed(let message) = library.syncState, isSyncingEmpty {
                RoomMessage(title: "Couldn’t read \(section.title)", detail: message, retry: { Task { await library.syncAll() } })
            } else if loaded {
                RoomMessage(title: slice == .playlists ? "No Music Playlists" : "No Music Yet",
                            detail: slice == .playlists ? "Playlists you make in Plex appear here." : "Add music to this library in Plex and it appears here.")
            }
        }
    }

    private var noun: String {
        let one = items.count == 1
        switch slice {
        case .albums: return one ? "album" : "albums"
        case .artists: return one ? "artist" : "artists"
        case .playlists: return one ? "playlist" : "playlists"
        case .songs: return one ? "song" : "songs"
        }
    }

    private func load() async {
        // Playlists live on the server (they aren't indexed); albums and artists come from the index.
        if slice == .playlists {
            guard let client = session.client, let lists = try? await client.audioPlaylists() else { loaded = true; return }
            guard !Task.isCancelled else { return }
            items = reversed ? lists.reversed() : lists
            loaded = true
            return
        }
        let result = await library.items(query)
        // A newer sort or sync asked again meanwhile: its answer is the one to show.
        guard !Task.isCancelled else { return }
        items = reversed ? result.reversed() : result
        loaded = library.count(section: section.key) > 0 || library.syncState == .idle
        if let key = focusedKey, !items.contains(where: { $0.ratingKey == key }) { focusedKey = nil }
    }

    private func columnCount(_ width: CGFloat) -> Int {
        let usable = width - Theme.Space.gutter * 2
        return max(1, Int((usable + Self.spacing) / (Self.minimum + Self.spacing)))
    }

    private func setFocus(_ index: Int, byKeyboard: Bool) {
        guard items.indices.contains(index) else { return }
        keyboardMoved = byKeyboard
        focusedKey = items[index].ratingKey
        playback.roomPalette = RoomPalette(items[index].ultraBlur) ?? .dark
    }

    private func move(_ direction: MoveCommandDirection) {
        guard !items.isEmpty else { return }
        guard let current = focused else { setFocus(0, byKeyboard: true); return }
        var next = current
        switch direction {
        case .left:
            if current % max(1, columns) == 0 { commands.focusSidebar(); return }
            next = current - 1
        case .right: next = current + 1
        case .up:
            // The first row has nothing above it.
            if current < columns { return }
            next = current - columns
        case .down: next = current + columns
        @unknown default: break
        }
        setFocus(min(max(0, next), items.count - 1), byKeyboard: true)
    }

    private func jump(to index: Int) -> KeyPress.Result {
        guard !items.isEmpty else { return .ignored }
        setFocus(max(0, min(index, items.count - 1)), byKeyboard: true)
        return .handled
    }
}

/// The page's sort, in its toolbar (and View ▸ Sort Music By).
struct MusicSortMenu: View {
    let sorts: [LibraryQuery.Sort]
    @Binding var selection: String
    @Binding var descending: Bool

    var body: some View {
        Menu {
            Picker("Sort By", selection: $selection) {
                ForEach(sorts, id: \.self) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.inline)
            Picker("Order", selection: $descending) {
                Text("Ascending").tag(false)
                Text("Descending").tag(true)
            }
            .pickerStyle(.inline)
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .help("Sort")
        .accessibilityValue([LibraryQuery.Sort(rawValue: selection)?.label, descending ? "Descending" : "Ascending"]
            .compactMap { $0 }.joined(separator: ", "))
    }
}
