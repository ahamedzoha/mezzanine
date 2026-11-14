import SwiftUI
import MezzanineKit

/// One library as a poster grid. Density and sort are remembered per library.
/// M1 adds the local index, view modes, filters and the folder view for Courses;
/// this is the first cut in the Bias Light world.
struct LibraryView: View {
    let section: PlexLibrarySection

    @Environment(SessionStore.self) private var session
    @Environment(PlaybackCoordinator.self) private var playback
    @State private var items: [PlexMetadata] = []
    @State private var loading = true
    @State private var error: String?
    @State private var focused: Int?
    @State private var columns = 1
    @AppStorage private var density: Double
    @AppStorage private var sortRaw: String
    @FocusState private var keyboardFocus: Bool

    init(section: PlexLibrarySection) {
        self.section = section
        _density = AppStorage(wrappedValue: 160, "library.\(section.key).density")
        _sortRaw = AppStorage(wrappedValue: PlexSort.titleAscending.rawValue, "library.\(section.key).sort")
    }

    private var sort: PlexSort { PlexSort(rawValue: sortRaw) ?? .titleAscending }

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: density, maximum: density * 1.25), spacing: Theme.Space.l, alignment: .top)],
                              alignment: .leading, spacing: Theme.Space.xl) {
                        ForEach(Array(items.enumerated()), id: \.element.ratingKey) { index, item in
                            GridPoster(item: item, isFocused: focused == index,
                                       onFocus: { setFocus(index) }, onPlay: { play(item) })
                                .id(index)
                        }
                    }
                    .padding(.horizontal, Theme.Space.gutter)
                    .padding(.vertical, Theme.Space.xl)
                }
                .scrollIndicators(.automatic)
                .onChange(of: focused) { _, index in
                    guard let index else { return }
                    withAnimation(Theme.Motion.object) { proxy.scrollTo(index) }
                }
            }
            .onChange(of: geo.size.width, initial: true) { _, w in columns = columnCount(width: w) }
            .onChange(of: density) { _, _ in columns = columnCount(width: geo.size.width) }
        }
        .overlay { state }
        .focusable()
        .focusEffectDisabled()
        .focused($keyboardFocus)
        .onMoveCommand(perform: move)
        .onKeyPress(.return) { playFocused() }
        .onKeyPress(.space) { playFocused() }
        .navigationTitle(section.title)
        .navigationSubtitle(items.isEmpty ? "" : "\(items.count) titles")
        .toolbar {
            ToolbarItem {
                Menu {
                    Picker("Sort", selection: $sortRaw) {
                        Text("Title").tag(PlexSort.titleAscending.rawValue)
                        Text("Recently added").tag(PlexSort.addedNewest.rawValue)
                        Text("Release date").tag(PlexSort.releasedNewest.rawValue)
                        Text("Rating").tag(PlexSort.audienceRating.rawValue)
                        Text("Recently watched").tag(PlexSort.lastViewed.rawValue)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .help("Sort")
            }
            ToolbarItem {
                Slider(value: $density, in: 110...260)
                    .frame(width: 110)
                    .help("Poster size (⌘+ / ⌘−)")
                    .accessibilityLabel("Poster size")
            }
        }
        .background {
            // ⌘+ / ⌘− change density from the keyboard.
            Group {
                Button("") { withAnimation(Theme.Motion.object) { density = min(260, density + 20) } }
                    .keyboardShortcut("+", modifiers: .command)
                Button("") { withAnimation(Theme.Motion.object) { density = max(110, density - 20) } }
                    .keyboardShortcut("-", modifiers: .command)
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
        .task(id: "\(section.key)|\(sortRaw)") { await load() }
        .onAppear { keyboardFocus = true }
    }

    @ViewBuilder private var state: some View {
        if items.isEmpty {
            if loading { ProgressView().controlSize(.large) }
            else if let error { ContentUnavailableView("Couldn’t load \(section.title)", systemImage: "exclamationmark.triangle", description: Text(error)) }
            else { ContentUnavailableView("\(section.title) is empty", systemImage: "film") }
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

    private func columnCount(width: CGFloat) -> Int {
        let usable = width - Theme.Space.gutter * 2
        return max(1, Int((usable + Theme.Space.l) / (density + Theme.Space.l)))
    }

    private func setFocus(_ index: Int) {
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
        setFocus(min(max(0, next), items.count - 1))
    }

    private func playFocused() -> KeyPress.Result {
        guard let focused, items.indices.contains(focused) else { return .ignored }
        play(items[focused])
        return .handled
    }

    private func play(_ item: PlexMetadata) {
        Task { await playback.play(item, from: nil) }
    }
}

/// A grid cell: poster sized by the column, title below.
private struct GridPoster: View {
    let item: PlexMetadata
    let isFocused: Bool
    let onFocus: () -> Void
    let onPlay: () -> Void

    @Environment(SessionStore.self) private var session
    @State private var dwell: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            GeometryReader { geo in
                let px = Int(geo.size.width * 2)
                RemoteImage(url: session.posterURL(item.posterPath, pixelWidth: px), pixelWidth: px)
                    .overlay(alignment: .bottom) {
                        if let p = item.progress {
                            Capsule().fill(Theme.ink).frame(width: max(4, (geo.size.width - 20) * p), height: 3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10).padding(.bottom, 10)
                        }
                    }
            }
            .aspectRatio(2 / 3, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous)
                    .strokeBorder(Theme.ink.opacity(isFocused ? 0.28 : 0.06), lineWidth: 1)
            }
            .shadow(color: .black.opacity(isFocused ? 0.55 : 0.25), radius: isFocused ? 22 : 8, y: isFocused ? 14 : 4)
            .scaleEffect(isFocused ? 1.04 : 1, anchor: .bottom)
            .animation(Theme.Motion.object, value: isFocused)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(Theme.Typeface.cardTitle)
                    .foregroundStyle(isFocused ? Theme.lilac : Theme.ink).lineLimit(1)
                Text(Format.cardSubtitle(item)).font(Theme.Typeface.cardMeta)
                    .foregroundStyle(Theme.inkSecondary).lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .onHover { inside in
            dwell?.cancel()
            guard inside, !isFocused else { return }
            dwell = Task {
                try? await Task.sleep(for: Theme.Motion.hoverDwell)
                if !Task.isCancelled { onFocus() }
            }
        }
        .onTapGesture(count: 2) { onPlay() }
        .onTapGesture { onFocus() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Play") { onPlay() }
        .contextMenu { Button("Play") { onPlay() } }
    }
}
