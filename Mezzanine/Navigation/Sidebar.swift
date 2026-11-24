import SwiftUI
import MezzanineKit

enum SidebarItem: Hashable {
    case home
    case library(String)
    /// A useful cut of a library.
    case slice(String, LibrarySlice)
    case pinned(String)
    /// A title in Continue: its page, as the window's root.
    case title(String)
    case downloads

    var storageKey: String? {
        switch self {
        case .home: "home"
        case .downloads: "downloads"
        case .library(let key): "library:\(key)"
        case .slice(let key, let slice): "slice:\(slice.rawValue):\(key)"
        case .pinned(let id): "pinned:\(id)"
        // Titles aren't restored.
        case .title: nil
        }
    }

    init?(storageKey raw: String) {
        func rest(_ prefix: String) -> String? { raw.hasPrefix(prefix) ? String(raw.dropFirst(prefix.count)) : nil }
        if raw == "home" { self = .home }
        else if raw == "downloads" { self = .downloads }
        else if let key = rest("library:") { self = .library(key) }
        else if let id = rest("pinned:") { self = .pinned(id) }
        else if let tail = rest("slice:") {
            let parts = tail.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let slice = LibrarySlice(rawValue: parts[0]) else { return nil }
            self = .slice(parts[1], slice)
        } else { return nil }
    }
}

/// The cuts of a library the sidebar offers.
enum LibrarySlice: String, CaseIterable, Hashable {
    case unwatched, inProgress, recentlyAdded, collections

    var label: String {
        switch self {
        case .unwatched: "Unwatched"
        case .inProgress: "In Progress"
        case .recentlyAdded: "Recently Added"
        case .collections: "Collections"
        }
    }

    var symbol: String {
        switch self {
        case .unwatched: "circle"
        case .inProgress: "circle.lefthalf.filled"
        case .recentlyAdded: "clock"
        case .collections: "rectangle.stack"
        }
    }

    var filters: LibraryFilters {
        var f = LibraryFilters()
        switch self {
        case .unwatched: f.watch = .unwatched
        case .inProgress: f.watch = .inProgress
        default: break
        }
        return f
    }

    var sort: LibraryQuery.Sort { self == .recentlyAdded ? .addedNewest : (self == .inProgress ? .lastWatched : .title) }
}

/// The sidebar: what you were watching, what's in each library, what you pinned, what's on this
/// Mac, and the server and profile in use. Artwork is its only colour.
///
/// Keys: ↑/↓ walk the rows; → opens a closed library, else moves into the content; ← closes an
/// open one.
struct Sidebar: View {
    let isOffline: Bool
    let sectionsError: String?
    let retrySections: () -> Void
    let enterContent: () -> Void

    @Environment(SessionStore.self) private var session
    @Environment(AppCommandCenter.self) private var commands
    @Environment(LibraryStore.self) private var library
    @Environment(DownloadStore.self) private var downloads
    @Environment(PinnedStore.self) private var pins
    @Environment(HomeLayoutStore.self) private var layouts
    /// Closed sections and open libraries, remembered.
    @AppStorage("sidebar.continue") private var continueOpen = true
    @AppStorage("sidebar.libraries") private var librariesOpen = true
    @AppStorage("sidebar.pinned") private var pinnedOpen = true
    @AppStorage("sidebar.mac") private var macOpen = true
    @AppStorage("sidebar.openLibraries") private var openLibraries = ""

    private static let continueLimit = 3

    var body: some View {
        @Bindable var commands = commands
        List(selection: $commands.selection) {
            if isOffline { offline } else { rows }
        }
        // A bar, not an inset: rows scroll under it without showing through the words.
        .safeAreaBar(edge: .bottom, spacing: 0) { footer }
        .scrollEdgeEffectStyle(.hard, for: .bottom)
        // A slice reached some other way (restored at launch): its library opens to show it.
        .onChange(of: commands.selection, initial: true) { _, item in
            if case .slice(let key, _) = item { setOpen(key, true) }
        }
        .onKeyPress(.rightArrow) {
            // A library with nothing inside it doesn't open: → goes straight to the content.
            if case .library(let key) = commands.selection, !isOpen(key), hasSlices(key) { setOpen(key, true) } else { enterContent() }
            return .handled
        }
        .onKeyPress(.leftArrow) {
            switch commands.selection {
            case .library(let key) where isOpen(key): setOpen(key, false); return .handled
            case .slice(let key, _): commands.selection = .library(key); return .handled
            default: return .ignored
            }
        }
        .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 300)
    }

    // MARK: Rows

    private static func tag(_ item: PlexMetadata) -> SidebarItem { .title(TitleActions.showKey(item) ?? item.ratingKey) }

    /// The first few titles in progress, one per page they open, and the selected one if it has
    /// slipped further down (its row shouldn't vanish while its page is open).
    private var watching: [PlexMetadata] {
        var seen = Set<SidebarItem>()
        let unique = library.continueItems.filter { seen.insert(Self.tag($0)).inserted }
        var rows = Array(unique.prefix(Self.continueLimit))
        if let selected = unique.first(where: { Self.tag($0) == commands.selection }), !rows.contains(where: { $0.ratingKey == selected.ratingKey }) {
            rows.append(selected)
        }
        return rows
    }

    private func slices(_ section: PlexLibrarySection) -> [LibrarySlice] {
        LibrarySlice.allCases.filter { offers($0, section, library.sliceCounts[section.key]) }
    }

    private func hasSlices(_ key: String) -> Bool {
        commands.sections.first { $0.key == key }.map { !slices($0).isEmpty } ?? false
    }

    @ViewBuilder private var rows: some View {
        Label("Home", systemImage: "house").tag(SidebarItem.home)
        if !watching.isEmpty {
            Section("Continue", isExpanded: $continueOpen) {
                ForEach(watching) { item in
                    ContinueRow(item: item).tag(Self.tag(item))
                }
            }
        }
        Section("Libraries", isExpanded: $librariesOpen) {
            ForEach(commands.sections) { section in libraryRows(section) }
            if let sectionsError {
                Button("Libraries didn’t load. Try Again", action: retrySections).help(sectionsError)
            }
        }
        if !pins.pins.isEmpty {
            Section("Pinned", isExpanded: $pinnedOpen) {
                ForEach(pins.pins) { pin in
                    Label(pin.title, systemImage: symbol(pin))
                        .lineLimit(1)
                        .badge(library.pinCounts[pin.id] ?? 0)
                        .tag(SidebarItem.pinned(pin.id))
                        .help(pin.title)
                        .contextMenu {
                            Button("Open") { commands.go(to: .pinned(pin.id)) }
                            Divider()
                            Button("Move Up") { movePin(pin.id, -1) }.disabled(pins.pins.first?.id == pin.id)
                            Button("Move Down") { movePin(pin.id, 1) }.disabled(pins.pins.last?.id == pin.id)
                            Divider()
                            Button("Unpin from Sidebar") { unpin(pin.id) }
                        }
                        .accessibilityAction(named: "Move Up") { movePin(pin.id, -1) }
                        .accessibilityAction(named: "Move Down") { movePin(pin.id, 1) }
                }
                .onMove { pins.move(from: $0, to: $1) }
            }
        }
        Section("On This Mac", isExpanded: $macOpen) { downloadsRow }
    }

    @ViewBuilder private func libraryRows(_ section: PlexLibrarySection) -> some View {
        let counts = library.sliceCounts[section.key]
        let slices = slices(section)
        let title = Label(section.title, systemImage: icon(section))
            .badge(counts?.total ?? 0)
            .tag(SidebarItem.library(section.key))
        if slices.isEmpty {
            title
        } else {
            DisclosureGroup(isExpanded: Binding(get: { isOpen(section.key) }, set: { setOpen(section.key, $0) })) {
                ForEach(slices, id: \.self) { slice in
                    Label(slice.label, systemImage: slice.symbol)
                        .badge(count(slice, counts))
                        .tag(SidebarItem.slice(section.key, slice))
                }
            } label: { title }
        }
    }

    private func offers(_ slice: LibrarySlice, _ section: PlexLibrarySection, _ counts: LibraryStore.SliceCounts?) -> Bool {
        guard !section.isPersonalMedia, let counts, counts.total > 0 else { return false }
        switch slice {
        case .unwatched: return counts.unwatched > 0
        case .inProgress: return counts.inProgress > 0
        case .recentlyAdded: return true
        case .collections: return counts.hasCollections
        }
    }

    private func count(_ slice: LibrarySlice, _ counts: LibraryStore.SliceCounts?) -> Int {
        switch slice {
        case .unwatched: counts?.unwatched ?? 0
        case .inProgress: counts?.inProgress ?? 0
        default: 0
        }
    }

    private var downloadsRow: some View {
        let running = downloads.visible.filter { $0.state == .downloading || $0.state == .queued }
        let total = running.reduce(Int64(0)) { $0 + $1.totalBytes }
        let got = running.reduce(Int64(0)) { $0 + $1.receivedBytes }
        let status: String? = running.isEmpty
            ? (downloads.bytesOnDisk > 0 ? downloads.bytesOnDisk.formatted(.byteCount(style: .file)) : nil)
            : ["\(running.count) left", total > 0 ? DownloadWords.percent(Double(got) / Double(total)) : nil].compactMap { $0 }.joined(separator: ", ")
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("Downloads", systemImage: "arrow.down.circle")
                Spacer(minLength: 4)
                if let status {
                    Text(status).font(.callout.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if !running.isEmpty, total > 0 {
                Capsule().fill(Theme.rule).frame(height: 2)
                    .overlay(alignment: .leading) {
                        GeometryReader { geo in
                            Capsule().fill(Theme.ink).frame(width: geo.size.width * min(1, Double(got) / Double(total)))
                        }
                    }
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .tag(SidebarItem.downloads)
    }

    @ViewBuilder private var offline: some View {
        // Offline: only what's on this Mac.
        Label("Downloads", systemImage: "arrow.down.circle").tag(SidebarItem.downloads)
        Section {
            Text("Plex can’t be reached. Downloads still play.")
                .font(Theme.Typeface.cardMeta).foregroundStyle(Theme.inkSecondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try Again") { Task { await session.restore() } }
        } header: {
            Text("Offline")
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !isOffline, let server = session.currentServer { ServerLine(name: server.name) }
            if session.homeUsers.count > 1 { SidebarProfileButton() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: State

    private var openKeys: Set<String> { Set(openLibraries.split(separator: ",").map(String.init)) }
    private func isOpen(_ key: String) -> Bool { openKeys.contains(key) }

    private func setOpen(_ key: String, _ open: Bool) {
        var keys = openKeys
        if open { keys.insert(key) } else { keys.remove(key) }
        openLibraries = keys.sorted().joined(separator: ",")
        // A closed library's selected row would vanish: the library takes the selection.
        if !open, case .slice(key, _) = commands.selection { commands.selection = .library(key) }
    }

    private func movePin(_ id: String, _ delta: Int) {
        guard let i = pins.pins.firstIndex(where: { $0.id == id }), pins.pins.indices.contains(i + delta) else { return }
        pins.move(from: IndexSet(integer: i), to: delta > 0 ? i + 2 : i - 1)
    }

    private func unpin(_ id: String) {
        if commands.selection == .pinned(id) { commands.selection = .home }
        pins.remove(id)
    }

    private func icon(_ section: PlexLibrarySection) -> String {
        if section.isPersonalMedia { return "folder" }
        return section.kind == .show ? "tv" : "film"
    }

    private func symbol(_ pin: ShelfSpec) -> String {
        switch pin.source {
        case .smart: "wand.and.stars"
        case .playlist: "list.bullet"
        default: "rectangle.stack"
        }
    }
}

/// One title in progress: poster, name, where you are. The row opens its page; the disc plays.
private struct ContinueRow: View {
    let item: PlexMetadata

    @Environment(SessionStore.self) private var session
    @Environment(LibraryStore.self) private var library
    @Environment(AppCommandCenter.self) private var commands
    @Environment(TitleActions.self) private var actions
    @State private var hovering = false
    /// Follows Text Size with the words beside it.
    @ScaledMetric(relativeTo: .body) private var posterWidth: CGFloat = 28

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            RemoteImage(url: session.posterURL(library.posterPath(for: item), pixelWidth: 72), pixelWidth: 72)
                .frame(width: posterWidth, height: posterWidth * 1.5)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous))
                .overlay {
                    if hovering {
                        Button { actions.play(item) } label: {
                            Image(systemName: "play.fill").font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Theme.graphite)
                                .frame(width: 24, height: 24)
                                .background(Circle().fill(Theme.ink))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Play")
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(Format.displayTitle(item)).lineLimit(1)
                Text(Format.cardSubtitle(item)).font(.callout.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                if let progress = item.progress {
                    Capsule().fill(Theme.rule).frame(height: 2)
                        .overlay(alignment: .leading) {
                            GeometryReader { geo in Capsule().fill(Theme.ink).frame(width: max(2, geo.size.width * progress)) }
                        }
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(Format.displayTitle(item))
        .task(id: item.ratingKey) { await library.resolveCleanPoster(for: item) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Format.displayTitle(item)), \(Format.cardSubtitle(item))")
        .accessibilityAction(named: "Play") { actions.play(item) }
        .contextMenu { TitleMenuItems(item: item, actions: actions, library: library, commands: commands) }
    }
}

/// The server and how it's reached, in words; the dot only repeats them.
private struct ServerLine: View {
    let name: String
    @Environment(SessionStore.self) private var session

    var body: some View {
        HStack(spacing: 6) {
            dot.frame(width: 7, height: 7).accessibilityHidden(true)
            Text("\(name) · \(session.routeWords)")
                .font(Theme.Typeface.cardMeta).foregroundStyle(Theme.inkSecondary)
                .lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, 4)
        .help("\(name): \(session.routeWords)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Server \(name), \(session.routeWords)")
    }

    @ViewBuilder private var dot: some View {
        switch session.phase == .ready ? session.connection?.connection.route : nil {
        case .local: Circle().fill(Theme.ink)
        case .remote: Circle().strokeBorder(Theme.ink, lineWidth: 1.5)
        default: Circle().fill(Theme.inkTertiary)
        }
    }
}

extension SessionStore {
    /// How the server is reached: "home", "away", "relay", "connecting".
    var routeWords: String {
        guard phase == .ready, let route = connection?.connection.route else { return "connecting" }
        switch route {
        case .local: return "home"
        case .remote: return "away"
        case .relay: return "relay"
        }
    }
}
