import SwiftUI
import MezzanineKit

/// One library as a poster grid. Density and sort are remembered per library.
/// M1 adds the local index, view modes, filters and the folder view for Courses;
/// this is the first cut in the Bias Light world.
struct LibraryView: View {
    let section: PlexLibrarySection
    var contentFocus: FocusState<Bool>.Binding

    @Environment(SessionStore.self) private var session
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(AppCommandCenter.self) private var commands
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var items: [PlexMetadata] = []
    @State private var loading = true
    @State private var error: String?
    @State private var focused: Int?
    @State private var keyboardMoved = false
    @State private var columns = 1
    @AppStorage private var density: Double
    @AppStorage private var sortRaw: String

    static let densityRange: ClosedRange<Double> = 110...260

    init(section: PlexLibrarySection, contentFocus: FocusState<Bool>.Binding) {
        self.section = section
        self.contentFocus = contentFocus
        _density = AppStorage(wrappedValue: 160, "library.\(section.key).density")
        _sortRaw = AppStorage(wrappedValue: PlexSort.titleAscending.rawValue, "library.\(section.key).sort")
    }

    private var sort: PlexSort { PlexSort(rawValue: sortRaw) ?? .titleAscending }

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    PosterGrid(items: items, density: density, focused: focused,
                               onFocus: { setFocus($0, byKeyboard: false) },
                               onPlay: { item, frame in play(item, from: frame) })
                }
                .scrollIndicators(.automatic)
                .onChange(of: focused) { _, index in
                    guard let index, keyboardMoved else { return }
                    withAnimation(Theme.Motion.object(reduceMotion)) { proxy.scrollTo(index) }
                }
            }
            .onChange(of: geo.size.width, initial: true) { _, w in columns = PosterGrid.columnCount(width: w, density: density) }
            .onChange(of: density) { _, _ in columns = PosterGrid.columnCount(width: geo.size.width, density: density) }
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
        .navigationTitle(section.title)
        .navigationSubtitle(items.isEmpty ? "" : (items.count == 1 ? "1 title" : "\(items.count) titles"))
        .toolbar {
            ToolbarItem(id: "sort") {
                Menu {
                    Picker("Sort", selection: $sortRaw) {
                        Text("Title").tag(PlexSort.titleAscending.rawValue)
                        Text("Recently Added").tag(PlexSort.addedNewest.rawValue)
                        Text("Release Date").tag(PlexSort.releasedNewest.rawValue)
                        Text("Rating").tag(PlexSort.audienceRating.rawValue)
                        Text("Recently Watched").tag(PlexSort.lastViewed.rawValue)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .help("Sort")
            }
            ToolbarItem(id: "posterSize") {
                Slider(value: $density, in: Self.densityRange) { Text("Poster Size") }
                    .labelsHidden()
                    .frame(width: 110)
                    .help("Poster size (View ▸ Larger Posters ⌘=, Smaller Posters ⌘−)")
                    .accessibilityLabel("Poster size")
            }
        }
        .tint(Theme.ink)
        .task(id: "\(section.key)|\(sortRaw)") { await load() }
    }

    @ViewBuilder private var state: some View {
        if items.isEmpty {
            if loading { RoomMessage { ProgressView().controlSize(.small).accessibilityLabel("Loading") } }
            else if let error { RoomMessage(title: "Couldn’t load \(section.title)", detail: error, retry: { Task { await load() } }) }
            else { RoomMessage(title: "\(section.title) is empty", detail: "Add media to this library in Plex and it appears here.") }
        }
    }

    private func load() async {
        guard let client = session.client else { return }
        loading = true
        defer { loading = false }
        do {
            var all: [PlexMetadata] = []
            var offset = 0
            while true {
                let page = try await client.items(section: section.key, sort: sort, offset: offset, limit: 200)
                all += page.items
                offset += page.items.count
                if !page.hasMore || page.items.isEmpty { break }
            }
            items = all
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = (error as? PlexError)?.userMessage ?? "\(error)"
        }
    }

    private func setFocus(_ index: Int, byKeyboard: Bool) {
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

/// A grid cell: poster sized by the column, title below.
struct GridPoster: View {
    let item: PlexMetadata
    let isFocused: Bool
    let onFocus: () -> Void
    let onPlay: (CGRect) -> Void

    @Environment(SessionStore.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dwell: Task<Void, Never>?
    @State private var frame: CGRect = .zero
    @State private var hovering = false

    private var lifted: Bool { isFocused || hovering }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            GeometryReader { geo in
                let px = Int(geo.size.width * 2)
                RemoteImage(url: session.posterURL(item.posterPath, pixelWidth: px), pixelWidth: px)
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
        .accessibilityValue(item.progress.map { "\(Int($0 * 100)) percent watched" } ?? "")
        .accessibilityHint("Plays")
        .accessibilityAction { onPlay(frame) }
        .contextMenu { Button("Play") { onPlay(frame) } }
    }
}
