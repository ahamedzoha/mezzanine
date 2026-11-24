import SwiftUI
import MezzanineKit

/// A page of titles that isn't a library: a collection, a pinned shelf, a library's collections.
/// The same grid, keys and Item menu as a library.
struct TitlesPage: View {
    let title: String
    /// Counted in the subtitle: ("title", "titles").
    var noun = ("title", "titles")
    /// Changes when the titles should be read again.
    let reloadKey: String
    /// The shelf this page can pin, if any.
    var pin: ShelfSpec? = nil
    var filterable = false
    /// Set when the page is pushed over another.
    var route: DetailRoute? = nil
    var contentFocus: FocusState<Bool>.Binding
    let load: () async throws -> [PlexMetadata]

    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(AppCommandCenter.self) private var commands
    @Environment(TitleActions.self) private var titleActions
    @Environment(PinnedStore.self) private var pins
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var all: [PlexMetadata] = []
    @State private var filter = ""
    @State private var loaded = false
    @State private var error: String?
    @State private var focused: Int?
    @State private var keyboardMoved = false
    @State private var columns = 1
    @State private var attempt = 0
    @AppStorage("titlesPage.density") private var density: Double = 160

    private var items: [PlexMetadata] {
        filter.isEmpty ? all : all.filter { $0.title.localizedCaseInsensitiveContains(filter) }
    }
    private var isTop: Bool { commands.path.last == route }
    private var focusedItem: PlexMetadata? { focused.flatMap { items.indices.contains($0) ? items[$0] : nil } }

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    if filterable && all.count > 12 {
                        TextField("Filter \(title)", text: $filter)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 280)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Theme.Space.gutter)
                            .padding(.top, Theme.Space.l)
                    }
                    PosterGrid(items: items, density: density, focused: focused,
                               actions: CardActions(focus: { setFocus($0, byKeyboard: false) }, open: { commands.open($0) },
                                                    play: { item, frame in start(item, from: frame) }))
                }
                .onChange(of: focused) { _, _ in
                    guard keyboardMoved, let item = focusedItem else { return }
                    withAnimation(Theme.Motion.object(reduceMotion)) { proxy.scrollTo(item.ratingKey) }
                }
            }
            .onChange(of: geo.size.width, initial: true) { _, w in columns = PosterGrid.columnCount(width: w, density: density) }
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
            start(item, from: nil)
            return .handled
        }
        .onKeyPress(.escape) {
            guard commands.canGoBack else { return .ignored }
            commands.goBack()
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "wW")) { _ in
            guard let item = focusedItem, TitleActions.canMark(item) else { return .ignored }
            titleActions.toggleWatched(item)
            return .handled
        }
        .onChange(of: filter) { _, _ in focused = nil }
        .onChange(of: focusedItem, initial: true) { _, _ in report() }
        // Back on top after a pushed page closed over it.
        .onChange(of: isTop) { _, top in if top { report() } }
        .onDisappear { if route != nil, commands.detailFocusedItem?.ratingKey == focusedItem?.ratingKey { commands.detailFocusedItem = nil } }
        .onChange(of: commands.playFocusedRequests) { _, _ in if isTop, let item = focusedItem { start(item, from: nil) } }
        .navigationTitle(title)
        .navigationSubtitle(loaded ? "\(items.count.formatted()) \(items.count == 1 ? noun.0 : noun.1)" : "")
        .toolbar {
            if let pin {
                ToolbarItem(placement: .primaryAction) {
                    let pinned = pins.contains(pin.id)
                    Button { pins.toggle(pin) } label: {
                        Label(pinned ? "Unpin from Sidebar" : "Pin to Sidebar", systemImage: pinned ? "pin.slash" : "pin")
                    }
                    .help(pinned ? "Unpin from the sidebar" : "Pin to the sidebar")
                    .disabled(!pins.isReady)
                }
            }
        }
        .task(id: "\(reloadKey)|\(attempt)") {
            do {
                let list = try await load()
                // A newer request (another page, a sync) started meanwhile.
                guard !Task.isCancelled else { return }
                all = list
                error = nil
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.error = (error as? PlexError)?.userMessage ?? "The server didn’t answer."
            }
            loaded = true
            if let f = focused, f >= items.count { focused = nil }
        }
    }

    @ViewBuilder private var state: some View {
        if items.isEmpty {
            if !loaded { RoomMessage { ProgressView().controlSize(.small).accessibilityLabel("Loading") } }
            else if let error { RoomMessage(title: "\(title) didn’t load", detail: error, retry: { attempt += 1 }) }
            else if !filter.isEmpty { RoomMessage(title: "Nothing matches “\(filter)”", detail: "Clear the filter to see everything.").padding(.top, 60) }
            else { RoomMessage(title: "\(title) is empty", detail: "Titles appear here when Plex has them.") }
        }
    }

    /// A collection has nothing to play by itself: it opens.
    private func start(_ item: PlexMetadata, from frame: CGRect?) {
        if item.kind == .collection { commands.open(item) } else { Task { await playback.play(item, from: frame) } }
    }

    /// The title in hand, for the Item menu and Play.
    private func report() {
        if route == nil {
            commands.hasFocusedTitle = focusedItem != nil
            commands.focusedItem = focusedItem
        } else if isTop {
            commands.detailFocusedItem = focusedItem
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
            if current % max(1, columns) == 0 { commands.focusSidebar(); return }
            next = current - 1
        case .right: next = current + 1
        case .up: next = current - columns
        case .down: next = current + columns
        @unknown default: break
        }
        setFocus(min(max(0, next), items.count - 1), byKeyboard: true)
    }
}

/// A library's collections.
struct CollectionsView: View {
    let section: PlexLibrarySection
    var contentFocus: FocusState<Bool>.Binding
    @Environment(SessionStore.self) private var session

    var body: some View {
        TitlesPage(title: "\(section.title) Collections", noun: ("collection", "collections"), reloadKey: "collections|\(section.key)",
                   filterable: true, contentFocus: contentFocus) {
            guard let client = session.client else { throw CancellationError() }
            // Kometa's folder-style parents hold no titles of their own.
            return try await client.collections(section: section.key).filter { ($0.childCount ?? 1) > 0 }
        }
    }
}

/// One collection, in its own order.
struct CollectionPage: View {
    let route: DetailRoute
    var contentFocus: FocusState<Bool>.Binding
    @Environment(SessionStore.self) private var session
    @Environment(LibraryStore.self) private var library
    private var ratingKey: String { route.ratingKey }
    @State private var collection: PlexMetadata?

    var body: some View {
        TitlesPage(title: collection?.title ?? "Collection", reloadKey: "\(ratingKey)|\(library.revision)",
                   pin: collection.flatMap { c in c.librarySectionID.map { PinnedStore.spec(for: c, section: String($0)) } },
                   filterable: true, route: route, contentFocus: contentFocus) {
            guard let client = session.client else { throw CancellationError() }
            return try await client.collectionItems(ratingKey)
        }
        .task(id: ratingKey) { collection = try? await session.client?.metadata(ratingKey) }
    }
}

/// A pinned collection, playlist or smart shelf.
struct PinnedPage: View {
    let pin: ShelfSpec
    var contentFocus: FocusState<Bool>.Binding
    @Environment(SessionStore.self) private var session
    @Environment(LibraryStore.self) private var library

    var body: some View {
        TitlesPage(title: pin.title, reloadKey: "\(pin.id)|\(library.revision)", pin: pin, filterable: true, contentFocus: contentFocus) {
            guard let client = session.client else { throw CancellationError() }
            switch pin.source {
            case .collection(let key, _): return try await client.collectionItems(key)
            case .playlist(let key): return try await client.playlistItems(key)
            case .smart(var rule):
                // The page holds every match, not just the shelf's worth.
                rule.limit = 0
                return await library.items(rule)
            case .hub: return []
            }
        }
    }
}
