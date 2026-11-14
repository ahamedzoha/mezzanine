import SwiftUI
import MezzanineKit

/// How a library page lays its titles out. Remembered per library.
enum LibraryLayout: String, CaseIterable, Identifiable {
    case posters, wide, list, folders
    var id: String { rawValue }
    var label: String {
        switch self {
        case .posters: return "Posters"
        case .wide: return "Wide"
        case .list: return "List"
        case .folders: return "Folders"
        }
    }
    var symbol: String {
        switch self {
        case .posters: return "square.grid.3x2"
        case .wide: return "rectangle.grid.2x2"
        case .list: return "list.bullet"
        case .folders: return "folder"
        }
    }
}

/// One library, answered from the local index: instant sort, filter and
/// layout changes. Personal-media libraries (Courses) also browse by folder.
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

    private var query: LibraryQuery {
        var q = LibraryQuery(section: section.key, kinds: kinds, sort: sort)
        filters.apply(to: &q)
        return q
    }

    var body: some View {
        Group {
            if layout == .folders {
                FolderBrowser(section: section, contentFocus: contentFocus)
            } else {
                titles
            }
        }
        .navigationTitle(section.title)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .tint(Theme.ink)
        .task(id: "\(section.key)|\(sortRaw)|\(filters.hashValue)|\(library.revision)") { await load() }
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
                            WideGrid(items: items, width: density * 1.6, focused: focused,
                                     onFocus: { setFocus($0, byKeyboard: false) }, onPlay: play)
                        case .list:
                            TitleList(items: items, focused: focused,
                                      onFocus: { setFocus($0, byKeyboard: false) }, onPlay: play)
                        default:
                            PosterGrid(items: items, density: density, focused: focused,
                                       onFocus: { setFocus($0, byKeyboard: false) }, onPlay: play)
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
        .onKeyPress(.return) { playFocused() }
        .onKeyPress(.space) { playFocused() }
        .onChange(of: focused, initial: true) { _, index in commands.hasFocusedTitle = index != nil }
        .onChange(of: commands.playFocusedRequests) { _, _ in _ = playFocused() }
        .onChange(of: commands.densitySteps.count) { _, _ in
            withAnimation(Theme.Motion.object(reduceMotion)) {
                density = min(Self.densityRange.upperBound, max(Self.densityRange.lowerBound, density + commands.densitySteps.delta))
            }
        }
    }

    private var subtitle: String {
        guard layout != .folders, loaded else { return "" }
        let n = items.count
        let noun = section.kind == .show ? (n == 1 ? "show" : "shows") : (n == 1 ? "title" : "titles")
        return filters.isActive ? "\(n) \(noun), filtered" : "\(n) \(noun)"
    }

    @ViewBuilder private var state: some View {
        if items.isEmpty && layout != .folders {
            if case .syncing(let name, let done, let total) = library.syncState, library.count(section: section.key) == 0 {
                RoomMessage(title: "Reading \(name)", detail: total > 0 ? "\(done) of \(total) titles" : nil) {
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

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(id: "layout") {
            Picker("Layout", selection: $layoutRaw) {
                ForEach(layouts) { Label($0.label, systemImage: $0.symbol).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .help("Layout")
        }
        if layout != .folders {
            ToolbarItem(id: "filter") {
                FilterMenu(filters: $filters, genres: library.genres(section: section.key, kinds: kinds))
            }
            ToolbarItem(id: "sort") {
                Menu {
                    Picker("Sort", selection: $sortRaw) {
                        Text("Title").tag(LibraryQuery.Sort.title.rawValue)
                        Text("Recently Added").tag(LibraryQuery.Sort.addedNewest.rawValue)
                        Text("Newest Release").tag(LibraryQuery.Sort.releasedNewest.rawValue)
                        Text("Oldest Release").tag(LibraryQuery.Sort.releasedOldest.rawValue)
                        Text("Rating").tag(LibraryQuery.Sort.rating.rawValue)
                        Text("Recently Watched").tag(LibraryQuery.Sort.lastWatched.rawValue)
                        Text("Longest").tag(LibraryQuery.Sort.duration.rawValue)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .help("Sort")
            }
        }
        if layout == .posters || layout == .wide {
            ToolbarItem(id: "posterSize") {
                Slider(value: $density, in: Self.densityRange) { Text("Poster Size") }
                    .labelsHidden()
                    .frame(width: 100)
                    .help("Poster size (View ▸ Larger Posters ⌘=, Smaller Posters ⌘−)")
            }
        }
    }

    private var layouts: [LibraryLayout] {
        section.isPersonalMedia ? LibraryLayout.allCases : [.posters, .wide, .list]
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
        case .list, .folders: return 1
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
        let current = focused ?? 0
        var next = current
        switch direction {
        case .left: next = current - 1
        case .right: next = current + 1
        case .up: next = current - columns
        case .down: next = current + columns
        @unknown default: break
        }
        if focused == nil { next = 0 }
        setFocus(min(max(0, next), items.count - 1), byKeyboard: true)
    }

    private func playFocused() -> KeyPress.Result {
        guard let focused, items.indices.contains(focused) else { return .ignored }
        play(items[focused], from: nil)
        return .handled
    }

    private func play(_ item: PlexMetadata, from frame: CGRect?) {
        Task { await playback.play(item, from: frame) }
    }
}

// MARK: - Filters

/// The filters a library page can apply; answered by the index.
struct LibraryFilters: Hashable {
    var unwatched = false
    var inProgress = false
    var genre: String?
    var decade: Int?
    var resolution: String?
    var hdr = false
    var surround = false

    var isActive: Bool { unwatched || inProgress || genre != nil || decade != nil || resolution != nil || hdr || surround }

    func apply(to q: inout LibraryQuery) {
        q.unwatchedOnly = unwatched
        q.inProgressOnly = inProgress
        q.genre = genre
        q.decade = decade
        q.resolution = resolution
        q.hdrOnly = hdr
        q.minAudioChannels = surround ? 6 : nil
    }

    /// Labels for the chips row, each with the change that removes it.
    var chips: [(String, (inout LibraryFilters) -> Void)] {
        var out: [(String, (inout LibraryFilters) -> Void)] = []
        if unwatched { out.append(("Unwatched", { $0.unwatched = false })) }
        if inProgress { out.append(("In Progress", { $0.inProgress = false })) }
        if let genre { out.append((genre, { $0.genre = nil })) }
        if let decade { out.append(("\(decade)s", { $0.decade = nil })) }
        if let resolution { out.append((Format.resolutionLabel(resolution), { $0.resolution = nil })) }
        if hdr { out.append(("HDR", { $0.hdr = false })) }
        if surround { out.append(("5.1 or more", { $0.surround = false })) }
        return out
    }
}

private struct FilterMenu: View {
    @Binding var filters: LibraryFilters
    let genres: [String]

    var body: some View {
        Menu {
            Toggle("Unwatched", isOn: $filters.unwatched)
            Toggle("In Progress", isOn: $filters.inProgress)
            Divider()
            Picker("Genre", selection: $filters.genre) {
                Text("Any Genre").tag(String?.none)
                ForEach(genres, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            Picker("Decade", selection: $filters.decade) {
                Text("Any Decade").tag(Int?.none)
                ForEach(Array(stride(from: 2020, through: 1920, by: -10)), id: \.self) { Text("\($0)s").tag(Int?.some($0)) }
            }
            Picker("Resolution", selection: $filters.resolution) {
                Text("Any Resolution").tag(String?.none)
                Text("4K").tag(String?.some("4k"))
                Text("1080p").tag(String?.some("1080"))
                Text("720p").tag(String?.some("720"))
                Text("SD").tag(String?.some("sd"))
            }
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
    }
}

/// Active filters as removable chips under the toolbar.
private struct FilterChips: View {
    @Binding var filters: LibraryFilters

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Theme.Space.s) {
                ForEach(Array(filters.chips.enumerated()), id: \.offset) { _, chip in
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
                    .help("Remove filter")
                    .accessibilityLabel("Remove filter \(chip.0)")
                }
                Button("Clear All") { withAnimation(Theme.Motion.quick) { filters = LibraryFilters() } }
                    .buttonStyle(.plain)
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.inkSecondary)
                    .padding(.leading, Theme.Space.s)
            }
        }
        .scrollIndicators(.never)
    }
}

// MARK: - Grids

/// The poster grid shared by libraries and search results.
struct PosterGrid: View {
    let items: [PlexMetadata]
    let density: Double
    let focused: Int?
    let onFocus: (Int) -> Void
    let onPlay: (PlexMetadata, CGRect) -> Void

    static func columnCount(width: CGFloat, density: Double) -> Int {
        let usable = width - Theme.Space.gutter * 2
        return max(1, Int((usable + Theme.Space.l) / (density + Theme.Space.l)))
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: density, maximum: density * 1.25), spacing: Theme.Space.l, alignment: .top)],
                  alignment: .leading, spacing: Theme.Space.xl) {
            ForEach(Array(items.enumerated()), id: \.element.ratingKey) { index, item in
                GridPoster(item: item, isFocused: focused == index,
                           onFocus: { onFocus(index) }, onPlay: { frame in onPlay(item, frame) })
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
    let onFocus: (Int) -> Void
    let onPlay: (PlexMetadata, CGRect) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: width, maximum: width * 1.3), spacing: Theme.Space.l, alignment: .top)],
                  alignment: .leading, spacing: Theme.Space.xl) {
            ForEach(Array(items.enumerated()), id: \.element.ratingKey) { index, item in
                WideCard(item: item, isFocused: focused == index,
                         onFocus: { onFocus(index) }, onPlay: { frame in onPlay(item, frame) })
                    .id(index)
            }
        }
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.vertical, Theme.Space.xl)
    }
}

private struct WideCard: View {
    let item: PlexMetadata
    let isFocused: Bool
    let onFocus: () -> Void
    let onPlay: (CGRect) -> Void

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
                    RemoteImage(url: session.backdropURL(item.backdropPath, pixelWidth: px), pixelWidth: px)
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
                .overlay(alignment: .bottomTrailing) {
                    if lifted { PlayDisc { onPlay(frame) }.padding(10).transition(.opacity) }
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.still, style: .continuous))
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
        .modifier(CardInteraction(item: item, frame: frame, isFocused: isFocused, hovering: $hovering,
                                  dwell: $dwell, onFocus: onFocus, onPlay: onPlay))
    }
}

/// Rows: small poster, title, the ruled facts, watched state.
private struct TitleList: View {
    let items: [PlexMetadata]
    let focused: Int?
    let onFocus: (Int) -> Void
    let onPlay: (PlexMetadata, CGRect) -> Void

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.element.ratingKey) { index, item in
                TitleRow(item: item, isFocused: focused == index,
                         onFocus: { onFocus(index) }, onPlay: { frame in onPlay(item, frame) })
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
    let onFocus: () -> Void
    let onPlay: (CGRect) -> Void

    @Environment(SessionStore.self) private var session
    @Environment(LibraryStore.self) private var library
    @State private var hovering = false
    @State private var dwell: Task<Void, Never>?
    @State private var frame: CGRect = .zero

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            RemoteImage(url: session.posterURL(library.posterPath(for: item), pixelWidth: 96), pixelWidth: 96)
                .frame(width: 40, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(Format.displayTitle(item)).font(Theme.Typeface.cardTitle)
                    .foregroundStyle(isFocused ? Theme.lilac : Theme.ink).lineLimit(1)
                Text(Format.heroCaption(item)).font(Theme.Typeface.cardMeta)
                    .foregroundStyle(Theme.inkSecondary).lineLimit(1)
            }
            Spacer(minLength: Theme.Space.m)
            if let p = item.progress {
                ProgressView(value: p).frame(width: 60).tint(Theme.ink).accessibilityHidden(true)
            } else if item.isWatched {
                Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
                    .accessibilityLabel("Watched")
            }
            if hovering || isFocused { PlayDisc { onPlay(frame) } } else { Color.clear.frame(width: 34, height: 34) }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
            .fill(isFocused || hovering ? Theme.raised : .clear))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
        .task(id: item.ratingKey) { await library.resolveCleanPoster(for: item) }
        .modifier(CardInteraction(item: item, frame: frame, isFocused: isFocused, hovering: $hovering,
                                  dwell: $dwell, onFocus: onFocus, onPlay: onPlay))
    }
}

/// Shared pointer + accessibility behaviour for every card and row.
struct CardInteraction: ViewModifier {
    let item: PlexMetadata
    let frame: CGRect
    let isFocused: Bool
    @Binding var hovering: Bool
    @Binding var dwell: Task<Void, Never>?
    let onFocus: () -> Void
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
            .simultaneousGesture(TapGesture(count: 2).onEnded { onPlay(frame) })
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(item.progress.map { "\(Int($0 * 100)) percent watched" } ?? (item.isWatched ? "Watched" : ""))
            .accessibilityHint("Plays")
            .accessibilityAction { onPlay(frame) }
            .contextMenu { Button("Play") { onPlay(frame) } }
    }
}

/// A grid cell: poster sized by the column, title below.
struct GridPoster: View {
    let item: PlexMetadata
    let isFocused: Bool
    let onFocus: () -> Void
    let onPlay: (CGRect) -> Void

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
                    .overlay(alignment: .bottomTrailing) {
                        if lifted { PlayDisc { onPlay(frame) }.padding(10).transition(.opacity) }
                    }
            }
            .aspectRatio(2 / 3, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous))
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
        .modifier(CardInteraction(item: item, frame: frame, isFocused: isFocused, hovering: $hovering,
                                  dwell: $dwell, onFocus: onFocus, onPlay: onPlay))
    }
}
