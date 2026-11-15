import SwiftUI
import MezzanineKit

/// How a library page lays its titles out. Remembered per library.
enum LibraryLayout: String, CaseIterable, Identifiable {
    case posters, wide, list, folders, shelves
    var id: String { rawValue }
    var label: String {
        switch self {
        case .posters: return "Posters"
        case .wide: return "Wide"
        case .list: return "List"
        case .folders: return "Folders"
        case .shelves: return "Shelves"
        }
    }
    var symbol: String {
        switch self {
        case .posters: return "rectangle.portrait.on.rectangle.portrait"
        case .wide: return "rectangle.grid.1x2"
        case .list: return "list.bullet"
        case .folders: return "folder"
        case .shelves: return "rectangle.stack"
        }
    }
}

/// One library, answered from the local index: instant sort, filter and
/// layout changes. Personal-media libraries (Courses) also browse by folder.
///
/// Keys: arrows move (← at the first column returns to the sidebar), Home/End
/// jump, Return opens, Space plays. Double-click opens; the play disc plays.
struct LibraryView: View {
    let section: PlexLibrarySection
    var contentFocus: FocusState<Bool>.Binding

    @Environment(SessionStore.self) private var session
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(AppCommandCenter.self) private var commands
    @Environment(LibraryStore.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var items: [PlexMetadata] = []
    @State private var loaded = false
    @State private var focused: Int?
    @State private var keyboardMoved = false
    @State private var columns = 1
    @State private var filters = LibraryFilters()
    @AppStorage private var density: Double
    @AppStorage private var sortRaw: String
    @AppStorage private var layoutRaw: String

    static let densityRange: ClosedRange<Double> = 110...260

    init(section: PlexLibrarySection, contentFocus: FocusState<Bool>.Binding) {
        self.section = section
        self.contentFocus = contentFocus
        _density = AppStorage(wrappedValue: 160, "library.\(section.key).density")
        _sortRaw = AppStorage(wrappedValue: LibraryQuery.Sort.title.rawValue, "library.\(section.key).sortIndex")
        _layoutRaw = AppStorage(wrappedValue: (section.isPersonalMedia ? LibraryLayout.folders : .posters).rawValue,
                                "library.\(section.key).layout")
    }

    private var sort: LibraryQuery.Sort { LibraryQuery.Sort(rawValue: sortRaw) ?? .title }
    private var layout: LibraryLayout { LibraryLayout(rawValue: layoutRaw) ?? .posters }
    private var kinds: [String] { section.kind == .show ? ["show"] : ["movie"] }
    private var layouts: [LibraryLayout] { section.isPersonalMedia ? LibraryLayout.allCases : [.posters, .wide, .list, .shelves] }

    private var query: LibraryQuery {
        var q = LibraryQuery(section: section.key, kinds: kinds, sort: sort)
        filters.apply(to: &q)
        return q
    }

    var body: some View {
        Group {
            if layout == .folders {
                FolderBrowser(section: section, contentFocus: contentFocus)
            } else if layout == .shelves {
                HomeView(contentFocus: contentFocus, scope: section.key)
            } else {
                titles
            }
        }
        .navigationTitle(section.title)
        .navigationSubtitle(subtitle)
        .toolbar(id: "library") { toolbar }
        .task(id: "\(section.key)|\(sortRaw)|\(filters.hashValue)|\(library.revision)") { await load() }
        .onChange(of: layoutRaw, initial: true) { _, raw in
            commands.currentLibraryKey = section.key
            commands.currentLayout = raw
            commands.availableLayouts = layouts.map(\.rawValue)
            commands.isFolderBrowserVisible = raw == LibraryLayout.folders.rawValue
        }
        .onChange(of: sortRaw, initial: true) { _, raw in commands.currentSort = raw }
        .onChange(of: commands.layoutRequest.count) { _, _ in
            let raw = commands.layoutRequest.layout
            if layouts.contains(where: { $0.rawValue == raw }) { layoutRaw = raw }
        }
        .onChange(of: commands.sortRequest.count) { _, _ in sortRaw = commands.sortRequest.sort }
        .onDisappear {
            if commands.currentLibraryKey == section.key { commands.currentLibraryKey = nil }
            commands.currentLayout = nil
            commands.availableLayouts = []
            commands.isFolderBrowserVisible = false
        }
    }

    // MARK: Titles (posters, wide, list)

    private var titles: some View {
        VStack(spacing: 0) {
            if filters.isActive {
                FilterChips(filters: $filters).padding(.horizontal, Theme.Space.gutter).padding(.top, Theme.Space.m)
            }
            GeometryReader { geo in
                ScrollViewReader { proxy in
                    ScrollView {
                        switch layout {
                        case .wide:
                            WideGrid(items: items, width: density * 1.6, focused: focused, actions: actions)
                        case .list:
                            TitleList(items: items, focused: focused, actions: actions)
                        default:
                            PosterGrid(items: items, density: density, focused: focused, actions: actions)
                        }
                    }
                    .onChange(of: focused) { _, index in
                        guard let index, keyboardMoved else { return }
                        withAnimation(Theme.Motion.object(reduceMotion)) { proxy.scrollTo(index) }
                    }
                }
                .onChange(of: geo.size.width, initial: true) { _, w in columns = columnCount(w) }
                .onChange(of: density) { _, _ in columns = columnCount(geo.size.width) }
                .onChange(of: layoutRaw) { _, _ in columns = columnCount(geo.size.width) }
            }
        }
        .overlay { state }
        .focusable()
        .focusEffectDisabled()
        .focused(contentFocus)
        .onMoveCommand(perform: move)
        .onKeyPress(.return) { openFocused() }
        .onKeyPress(.space) { playFocused() }
        .onKeyPress(.home) { jump(to: 0) }
        .onKeyPress(.end) { jump(to: items.count - 1) }
        .onChange(of: focused, initial: true) { _, index in commands.hasFocusedTitle = index != nil }
        .onChange(of: commands.playFocusedRequests) { _, _ in _ = playFocused() }
        .onChange(of: commands.densitySteps.count) { _, _ in
            withAnimation(Theme.Motion.object(reduceMotion)) {
                density = min(Self.densityRange.upperBound, max(Self.densityRange.lowerBound, density + commands.densitySteps.delta))
            }
        }
    }

    private var actions: CardActions {
        CardActions(focus: { setFocus($0, byKeyboard: false) },
                    open: { commands.open($0) },
                    play: { item, frame in Task { await playback.play(item, from: frame) } })
    }

    private var subtitle: String {
        guard layout != .folders, loaded else { return "" }
        let n = items.count
        let noun = section.kind == .show ? (n == 1 ? "show" : "shows") : (n == 1 ? "title" : "titles")
        return filters.isActive ? "\(n.formatted()) \(noun), filtered" : "\(n.formatted()) \(noun)"
    }

    @ViewBuilder private var state: some View {
        if items.isEmpty && layout != .folders {
            if case .syncing(let name, let done, let total) = library.syncState, library.count(section: section.key) == 0 {
                RoomMessage(title: "Reading \(name)", detail: total > 0 ? "\(done.formatted()) of \(total.formatted()) titles" : nil) {
                    ProgressView(value: total > 0 ? Double(done) / Double(total) : nil).frame(width: 220).accessibilityLabel("Reading library")
                }
            } else if case .failed(let message) = library.syncState, library.count(section: section.key) == 0 {
                RoomMessage(title: "Couldn’t read \(section.title)", detail: message, retry: { Task { await library.syncAll() } })
            } else if loaded && filters.isActive {
                RoomMessage(title: "Nothing matches these filters", detail: "Remove a filter above to see more.")
            } else if loaded {
                RoomMessage(title: "\(section.title) is empty", detail: "Add media to this library in Plex and it appears here.")
            }
        }
    }

    // MARK: Toolbar (a constant set, so nothing shifts when the layout changes)

    @ToolbarContentBuilder private var toolbar: some CustomizableToolbarContent {
        ToolbarItem(id: "layout") {
            Picker("Layout", selection: $layoutRaw) {
                ForEach(layouts) { Label($0.label, systemImage: $0.symbol).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .help("Layout (View ▸ Layout, ⌃⌘1–⌃⌘5)")
            .accessibilityLabel("Layout")
        }
        ToolbarItem(id: "filter") {
            FilterMenu(filters: $filters, genres: library.genres(section: section.key, kinds: kinds))
                .disabled(layout == .folders || layout == .shelves)
        }
        ToolbarItem(id: "sort") {
            Menu {
                Picker("Sort By", selection: $sortRaw) {
                    ForEach(LibraryQuery.Sort.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Sort: \(sort.label)", systemImage: "arrow.up.arrow.down")
            }
            .help("Sort (View ▸ Sort By)")
            .disabled(layout == .folders || layout == .shelves)
        }
        ToolbarItem(id: "posterSize") {
            // Small control and ink fill: a toolbar slider at regular size grows a glass knob
            // taller than its neighbours, and lilac is for selection and the primary action only.
            HStack(spacing: 6) {
                Image(systemName: "photo").font(.system(size: 9)).foregroundStyle(.secondary)
                Slider(value: $density, in: Self.densityRange) { Text("Poster Size") }
                    .labelsHidden()
                    .controlSize(.mini)
                    .tint(Theme.inkSecondary)
                    .frame(width: 96)
                Image(systemName: "photo").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
            .help("Poster size (View ▸ Larger Posters ⌘=, Smaller Posters ⌘−)")
            .disabled(layout == .list || layout == .folders || layout == .shelves)
        }
        ToolbarItem(id: "editShelves") {
            // Works from every layout: elsewhere it switches to Shelves and opens the editor.
            EditShelvesButton(editing: commands.isEditingShelves && layout == .shelves) { commands.editShelves() }
                .disabled(!layouts.contains(.shelves))
        }
    }

    // MARK: Data & keys

    private func load() async {
        let result = await library.items(query)
        items = result
        loaded = library.count(section: section.key) > 0 || library.syncState == .idle
        if let f = focused, f >= items.count { focused = nil }
    }

    private func columnCount(_ width: CGFloat) -> Int {
        switch layout {
        case .list, .folders, .shelves: return 1
        case .wide: return PosterGrid.columnCount(width: width, density: density * 1.6)
        case .posters: return PosterGrid.columnCount(width: width, density: density)
        }
    }

    private func setFocus(_ index: Int, byKeyboard: Bool) {
        guard items.indices.contains(index) else { return }
        keyboardMoved = byKeyboard
        focused = index
        playback.roomPalette = RoomPalette(items[index].ultraBlur) ?? .dark
    }

    private func move(_ direction: MoveCommandDirection) {
        guard !items.isEmpty else { return }
        guard let current = focused else { setFocus(0, byKeyboard: true); return }
        var next = current
        switch direction {
        case .left:
            // At the first column, ← hands focus back to the sidebar.
            if current % max(1, columns) == 0 { commands.focusSidebar(); return }
            next = current - 1
        case .right: next = current + 1
        case .up: next = current - columns
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

    private func openFocused() -> KeyPress.Result {
        guard let focused, items.indices.contains(focused) else { return .ignored }
        commands.open(items[focused])
        return .handled
    }

    private func playFocused() -> KeyPress.Result {
        guard let focused, items.indices.contains(focused) else { return .ignored }
        Task { await playback.play(items[focused], from: nil) }
        return .handled
    }
}

/// What a card can ask of its page.
struct CardActions {
    let focus: (Int) -> Void
    let open: (PlexMetadata) -> Void
    let play: (PlexMetadata, CGRect) -> Void
}

// MARK: - Filters

/// The filters a library page can apply; answered by the index.
struct LibraryFilters: Hashable {
    enum WatchState: String, CaseIterable, Hashable {
        case any, unwatched, inProgress, watched
        var label: String {
            switch self {
            case .any: return "Any"
            case .unwatched: return "Unwatched"
            case .inProgress: return "In Progress"
            case .watched: return "Watched"
            }
        }
    }

    var watch: WatchState = .any
    var genre: String?
    var decade: Int?
    var resolution: String?
    var hdr = false
    var surround = false

    var isActive: Bool { watch != .any || genre != nil || decade != nil || resolution != nil || hdr || surround }

    func apply(to q: inout LibraryQuery) {
        q.unwatchedOnly = watch == .unwatched
        q.inProgressOnly = watch == .inProgress
        q.watchedOnly = watch == .watched
        q.genre = genre
        q.decade = decade
        q.resolution = resolution
        q.hdrOnly = hdr
        q.minAudioChannels = surround ? 6 : nil
    }

    /// Labels for the chips row, each with the change that removes it.
    var chips: [(String, (inout LibraryFilters) -> Void)] {
        var out: [(String, (inout LibraryFilters) -> Void)] = []
        if watch != .any { out.append((watch.label, { $0.watch = .any })) }
        if let genre { out.append((genre, { $0.genre = nil })) }
        if let decade { out.append(("\(decade)s", { $0.decade = nil })) }
        if let resolution { out.append((Format.resolutionLabel(resolution), { $0.resolution = nil })) }
        if hdr { out.append(("HDR", { $0.hdr = false })) }
        if surround { out.append(("5.1 or More", { $0.surround = false })) }
        return out
    }
}

private struct FilterMenu: View {
    @Binding var filters: LibraryFilters
    let genres: [String]

    var body: some View {
        Menu {
            Picker("Watch State: \(filters.watch.label)", selection: $filters.watch) {
                ForEach(LibraryFilters.WatchState.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            Picker("Genre: \(filters.genre ?? "Any")", selection: $filters.genre) {
                Text("Any").tag(String?.none)
                ForEach(genres, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .pickerStyle(.menu)
            Picker("Decade: \(filters.decade.map { "\($0)s" } ?? "Any")", selection: $filters.decade) {
                Text("Any").tag(Int?.none)
                ForEach(Array(stride(from: 2020, through: 1920, by: -10)), id: \.self) { Text("\($0)s").tag(Int?.some($0)) }
            }
            .pickerStyle(.menu)
            Picker("Resolution: \(filters.resolution.map(Format.resolutionLabel) ?? "Any")", selection: $filters.resolution) {
                Text("Any").tag(String?.none)
                Text("4K").tag(String?.some("4k"))
                Text("1080p").tag(String?.some("1080"))
                Text("720p").tag(String?.some("720"))
                Text("SD").tag(String?.some("sd"))
            }
            .pickerStyle(.menu)
            Divider()
            Toggle("HDR", isOn: $filters.hdr)
            Toggle("5.1 or More", isOn: $filters.surround)
            if filters.isActive {
                Divider()
                Button("Clear Filters") { filters = LibraryFilters() }
            }
        } label: {
            Label("Filter", systemImage: filters.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .help("Filter")
        .accessibilityValue(filters.isActive ? "\(filters.chips.count) active" : "None")
    }
}

/// Active filters as removable chips under the toolbar; Clear All stays put.
private struct FilterChips: View {
    @Binding var filters: LibraryFilters

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            ScrollView(.horizontal) {
                HStack(spacing: Theme.Space.s) {
                    ForEach(filters.chips, id: \.0) { chip in
                        Button {
                            withAnimation(Theme.Motion.quick) { chip.1(&filters) }
                        } label: {
                            HStack(spacing: 6) {
                                Text(chip.0)
                                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                            }
                            .font(Theme.Typeface.caption)
                            .foregroundStyle(Theme.ink)
                            .padding(.horizontal, 12)
                            .frame(height: 28)
                            .background(Capsule().fill(Theme.raised))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled(false)
                        .help("Remove this filter")
                        .accessibilityLabel("Remove filter \(chip.0)")
                    }
                }
            }
            .scrollIndicators(.never)
            Button { withAnimation(Theme.Motion.quick) { filters = LibraryFilters() } } label: {
                Text("Clear All")
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.inkSecondary)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled(false)
            .help("Remove every filter")
        }
    }
}

// MARK: - Grids

/// The poster grid shared by libraries and search results.
struct PosterGrid: View {
    let items: [PlexMetadata]
    let density: Double
    let focused: Int?
    let actions: CardActions

    static func columnCount(width: CGFloat, density: Double) -> Int {
        let usable = width - Theme.Space.gutter * 2
        return max(1, Int((usable + Theme.Space.l) / (density + Theme.Space.l)))
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: density, maximum: density * 1.25), spacing: Theme.Space.l, alignment: .top)],
                  alignment: .leading, spacing: Theme.Space.xl) {
            ForEach(Array(items.enumerated()), id: \.element.ratingKey) { index, item in
                GridPoster(item: item, isFocused: focused == index, index: index, actions: actions)
                    .id(index)
            }
        }
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.vertical, Theme.Space.xl)
    }
}

/// Backdrop cards (16:9) with the title under them.
private struct WideGrid: View {
    let items: [PlexMetadata]
    let width: Double
    let focused: Int?
    let actions: CardActions

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: width, maximum: width * 1.3), spacing: Theme.Space.l, alignment: .top)],
                  alignment: .leading, spacing: Theme.Space.xl) {
            ForEach(Array(items.enumerated()), id: \.element.ratingKey) { index, item in
                WideCard(item: item, isFocused: focused == index, index: index, actions: actions)
                    .id(index)
            }
        }
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.vertical, Theme.Space.xl)
    }
}

/// A quiet, hueless watched mark for a card corner.
struct WatchedMark: View {
    let item: PlexMetadata
    var body: some View {
        if item.isWatched {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.ink)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Theme.graphite.opacity(0.82)))
                .padding(8)
                .accessibilityHidden(true)
        }
    }
}

private struct WideCard: View {
    let item: PlexMetadata
    let isFocused: Bool
    let index: Int
    let actions: CardActions

    @Environment(LibraryStore.self) private var library
    @Environment(SessionStore.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var dwell: Task<Void, Never>?
    @State private var frame: CGRect = .zero
    private var lifted: Bool { isFocused || hovering }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            GeometryReader { geo in
                let px = Int(geo.size.width * 2)
                ZStack(alignment: .bottomLeading) {
                    RemoteImage(url: session.backdropURL(library.backdropPath(for: item), pixelWidth: px), pixelWidth: px)
                    LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                    LogoImage(url: session.logoURL(item.clearLogoPath), pixelWidth: 600) { EmptyView() }
                        .frame(maxWidth: geo.size.width * 0.55, maxHeight: geo.size.height * 0.32, alignment: .bottomLeading)
                        .padding(12)
                    if let p = item.progress {
                        Capsule().fill(Theme.ink).frame(width: max(4, (geo.size.width - 24) * p), height: 3)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                            .padding(.horizontal, 12).padding(.bottom, 6)
                    }
                }
                .overlay(alignment: .topTrailing) { WatchedMark(item: item) }
                .overlay(alignment: .bottomTrailing) {
                    if lifted { PlayDisc { actions.play(item, frame) }.padding(10).transition(.opacity) }
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.still, style: .continuous))
            .contrastFocusOutline(isFocused, radius: Theme.Radius.still)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
            .shadow(color: .black.opacity(lifted ? 0.6 : 0.3), radius: lifted ? 22 : 8, y: lifted ? 14 : 4)
            .scaleEffect(lifted && !reduceMotion ? 1.03 : 1, anchor: .bottom)
            .animation(reduceMotion ? .easeOut(duration: 0.15) : Theme.Motion.lift, value: lifted)

            VStack(alignment: .leading, spacing: 2) {
                Text(Format.displayTitle(item)).font(Theme.Typeface.cardTitle)
                    .foregroundStyle(isFocused ? Theme.lilac : Theme.ink).lineLimit(1)
                Text(Format.cardSubtitle(item)).font(Theme.Typeface.cardMeta)
                    .foregroundStyle(Theme.inkSecondary).lineLimit(1)
            }
        }
        .modifier(CardInteraction(item: item, frame: frame, isFocused: isFocused, hovering: $hovering, dwell: $dwell,
                                  onFocus: { actions.focus(index) }, onOpen: { actions.open(item) },
                                  onPlay: { actions.play(item, $0) }))
    }
}

/// Rows: small poster, title and facts, then right-aligned columns.
private struct TitleList: View {
    let items: [PlexMetadata]
    let focused: Int?
    let actions: CardActions

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Space.m) {
                Text("Title").frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 44)
                Text("Year").frame(width: 48, alignment: .trailing)
                Text("Length").frame(width: 96, alignment: .trailing)
                Text("Rating").frame(width: 52, alignment: .trailing)
                Text("Quality").frame(width: 120, alignment: .trailing)
                Color.clear.frame(width: 34 + 20)
            }
            .font(Theme.Typeface.cardMeta)
            .foregroundStyle(Theme.inkTertiary)
            .padding(.horizontal, Theme.Space.m)
            .padding(.bottom, Theme.Space.s)
            .accessibilityHidden(true)
            ForEach(Array(items.enumerated()), id: \.element.ratingKey) { index, item in
                TitleRow(item: item, isFocused: focused == index, index: index, actions: actions)
                    .id(index)
            }
        }
        .padding(.horizontal, Theme.Space.gutter - Theme.Space.m)
        .padding(.vertical, Theme.Space.l)
    }
}

private struct TitleRow: View {
    let item: PlexMetadata
    let isFocused: Bool
    let index: Int
    let actions: CardActions

    @Environment(SessionStore.self) private var session
    @Environment(LibraryStore.self) private var library
    @State private var hovering = false
    @State private var dwell: Task<Void, Never>?
    @State private var frame: CGRect = .zero

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            RemoteImage(url: session.posterURL(library.posterPath(for: item), pixelWidth: 72), pixelWidth: 72)
                .frame(width: 32, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous))
            Text(Format.displayTitle(item)).font(Theme.Typeface.cardTitle)
                .foregroundStyle(isFocused ? Theme.lilac : Theme.ink).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                Text(item.year.map(String.init) ?? "—").frame(width: 48, alignment: .trailing)
                Text(length).frame(width: 96, alignment: .trailing)
                Text((item.audienceRating ?? item.rating).map { String(format: "%.1f", $0) } ?? "—").frame(width: 52, alignment: .trailing)
                Text(quality).frame(width: 120, alignment: .trailing)
            }
            .font(Theme.Typeface.cardMeta)
            .foregroundStyle(Theme.inkSecondary)
            ZStack {
                if hovering || isFocused { PlayDisc { actions.play(item, frame) } }
                else if let p = item.progress { ProgressView(value: p).frame(width: 34).tint(Theme.ink).accessibilityHidden(true) }
                else if item.isWatched { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.inkSecondary) }
            }
            .frame(width: 34, height: 34)
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(height: 56)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
            .fill(isFocused || hovering ? Theme.raised : .clear))
        .contrastFocusOutline(isFocused, radius: Theme.Radius.control)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
        .task(id: item.ratingKey) { await library.resolveCleanPoster(for: item) }
        .modifier(CardInteraction(item: item, frame: frame, isFocused: isFocused, hovering: $hovering, dwell: $dwell,
                                  onFocus: { actions.focus(index) }, onOpen: { actions.open(item) },
                                  onPlay: { actions.play(item, $0) }))
    }

    private var length: String {
        if item.kind == .show, let n = item.childCount { return n == 1 ? "1 season" : "\(n) seasons" }
        return item.duration.map(Format.duration) ?? "—"
    }

    private var quality: String {
        guard let m = item.media.first else { return "—" }
        return [m.videoResolution.map(Format.resolutionLabel), m.audioChannels.map(Format.channelLabel)].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Shared pointer, keyboard-state and accessibility behaviour for every card and row.
/// Single click focuses, double click opens, the play disc (or VoiceOver's
/// default action) plays.
struct CardInteraction: ViewModifier {
    @Environment(AppCommandCenter.self) private var commands
    let item: PlexMetadata
    let frame: CGRect
    let isFocused: Bool
    @Binding var hovering: Bool
    @Binding var dwell: Task<Void, Never>?
    let onFocus: () -> Void
    let onOpen: () -> Void
    let onPlay: (CGRect) -> Void

    func body(content: Content) -> some View {
        content
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
            .simultaneousGesture(TapGesture().onEnded { onFocus() })
            .simultaneousGesture(TapGesture(count: 2).onEnded { onOpen() })
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isFocused ? [.isButton, .isSelected] : .isButton)
            .accessibilityValue(item.progress.map { "\(Int($0 * 100)) percent watched" } ?? (item.isWatched ? "Watched" : ""))
            .accessibilityHint("Opens. Play with the Play action.")
            .accessibilityAction { onOpen() }
            .accessibilityAction(named: "Play") { onPlay(frame) }
            .contextMenu {
                Button("Play") { onPlay(frame) }
                Button("Open") { onOpen() }
                if item.kind != .episode {
                    Divider()
                    Button("Choose Poster…") { commands.artworkRequest = ArtworkRequest(item: item, kind: .poster) }
                    Button("Choose Background…") { commands.artworkRequest = ArtworkRequest(item: item, kind: .background) }
                }
            }
    }
}

/// A grid cell: poster sized by the column, title below.
struct GridPoster: View {
    let item: PlexMetadata
    let isFocused: Bool
    let index: Int
    let actions: CardActions

    @Environment(SessionStore.self) private var session
    @Environment(LibraryStore.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dwell: Task<Void, Never>?
    @State private var frame: CGRect = .zero
    @State private var hovering = false

    private var lifted: Bool { isFocused || hovering }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            GeometryReader { geo in
                let px = Int(geo.size.width * 2)
                RemoteImage(url: session.posterURL(library.posterPath(for: item), pixelWidth: px), pixelWidth: px)
                    .overlay(alignment: .bottom) {
                        if let p = item.progress {
                            Capsule().fill(Theme.ink).frame(width: max(4, (geo.size.width - 20) * p), height: 3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10).padding(.bottom, lifted ? 54 : 10)
                        }
                    }
                    .overlay(alignment: .topTrailing) { WatchedMark(item: item) }
                    .overlay(alignment: .bottomTrailing) {
                        if lifted { PlayDisc { actions.play(item, frame) }.padding(10).transition(.opacity) }
                    }
            }
            .aspectRatio(2 / 3, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous))
            .contrastFocusOutline(isFocused)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
            .shadow(color: .black.opacity(lifted ? 0.6 : 0.3), radius: lifted ? 22 : 8, y: lifted ? 14 : 4)
            .scaleEffect(lifted && !reduceMotion ? 1.045 : 1, anchor: .bottom)
            .offset(y: lifted && !reduceMotion ? -4 : 0)
            .animation(reduceMotion ? .easeOut(duration: 0.15) : Theme.Motion.lift, value: lifted)

            VStack(alignment: .leading, spacing: 2) {
                Text(Format.displayTitle(item)).font(Theme.Typeface.cardTitle)
                    .foregroundStyle(isFocused ? Theme.lilac : Theme.ink).lineLimit(1)
                Text(Format.cardSubtitle(item)).font(Theme.Typeface.cardMeta)
                    .foregroundStyle(Theme.inkSecondary).lineLimit(1)
            }
        }
        .task(id: item.ratingKey) { await library.resolveCleanPoster(for: item) }
        .modifier(CardInteraction(item: item, frame: frame, isFocused: isFocused, hovering: $hovering, dwell: $dwell,
                                  onFocus: { actions.focus(index) }, onOpen: { actions.open(item) },
                                  onPlay: { actions.play(item, $0) }))
    }
}
