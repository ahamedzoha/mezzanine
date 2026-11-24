import SwiftUI
import MezzanineKit

/// What Home shows: everything, or one kind.
enum HomeKind: String, CaseIterable, Hashable {
    case all, films, shows

    var label: String {
        switch self {
        case .all: "All"
        case .films: "Films"
        case .shows: "Shows"
        }
    }

    func includes(_ item: PlexMetadata) -> Bool {
        switch self {
        case .all: true
        case .films: item.kind == .movie
        case .shows: [.show, .season, .episode].contains(item.kind)
        }
    }

    /// Plex kinds Surprise Me draws from.
    var kinds: [String] {
        switch self {
        case .all: ["movie", "show"]
        case .films: ["movie"]
        case .shows: ["show"]
        }
    }
}

/// Surprise Me and Activity, on every page of the window.
struct ShellToolbar: ToolbarContent {
    /// Offline there's nothing to surprise with or sync.
    let shown: Bool
    let canSurprise: Bool

    var body: some ToolbarContent {
        ToolbarItem {
            if shown { SurpriseButton().disabled(!canSurprise) }
        }
        ToolbarItem {
            if shown { ActivityButton() }
        }
    }
}

private struct SurpriseButton: View {
    @Environment(AppCommandCenter.self) private var commands
    var body: some View {
        Button { commands.surprise() } label: { Label("Surprise Me", systemImage: "dice") }
            .help("Open a random unwatched title (⇧⌘R)")
    }
}

/// What Mezzanine is doing: still when idle, a ring while the library is read or files download.
private struct ActivityButton: View {
    @Environment(AppCommandCenter.self) private var commands
    @Environment(LibraryStore.self) private var library
    @Environment(DownloadStore.self) private var downloads

    private var running: [DownloadRecord] { downloads.visible.filter { $0.state == .downloading } }
    private var isSyncing: Bool { library.isSyncing }

    var body: some View {
        @Bindable var commands = commands
        Button { commands.isActivityShown.toggle() } label: {
            if isSyncing || !running.isEmpty {
                ProgressView().controlSize(.small).accessibilityLabel("Activity, working")
            } else {
                Label("Activity", systemImage: failed ? "exclamationmark.circle" : "arrow.triangle.2.circlepath")
            }
        }
        .help("Library, downloads and server (⌥⌘A)")
        .popover(isPresented: $commands.isActivityShown, arrowEdge: .bottom) { ActivityPanel() }
    }

    private var failed: Bool { if case .failed = library.syncState { true } else { false } }
}

private struct ActivityPanel: View {
    @Environment(SessionStore.self) private var session
    @Environment(AppCommandCenter.self) private var commands
    @Environment(LibraryStore.self) private var library
    @Environment(DownloadStore.self) private var downloads

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Theme.Space.m, verticalSpacing: Theme.Space.m) {
            GridRow {
                Text("Library").font(Theme.Typeface.cardTitle)
                TimelineView(.everyMinute) { _ in Text(libraryLine).foregroundStyle(Theme.inkSecondary).lineLimit(3) }
                Button("Sync Now") { Task { await library.syncAll() } }
                    .disabled(library.isSyncing || library.index == nil)
            }
            GridRow {
                Text("Downloads").font(Theme.Typeface.cardTitle)
                Text(downloadLine).foregroundStyle(Theme.inkSecondary)
                Button("Show") { commands.isActivityShown = false; commands.go(to: .downloads) }
            }
            GridRow {
                Text("Server").font(Theme.Typeface.cardTitle)
                Text(serverLine).foregroundStyle(Theme.inkSecondary).lineLimit(2)
                    .gridCellColumns(2)
            }
        }
        .font(Theme.Typeface.cardMeta)
        .padding(Theme.Space.l)
        .frame(minWidth: 340, maxWidth: 440, alignment: .leading)
    }

    private var libraryLine: String {
        switch library.syncState {
        case .failed(let message): return message
        case .syncing(let section, let done, let total):
            return total > 0 ? "Reading \(section), \(done.formatted()) of \(total.formatted())" : "Reading \(section)"
        case .idle:
            if library.isSyncing { return "Checking for changes" }
            guard let at = library.lastSyncedAt else { return "Not checked yet" }
            return Date().timeIntervalSince(at) < 60 ? "Up to date, just now"
                : "Up to date, \(at.formatted(.relative(presentation: .named)))"
        }
    }

    private var downloadLine: String {
        let pending = downloads.visible.filter { $0.state == .downloading || $0.state == .queued }
        guard !pending.isEmpty else {
            return downloads.bytesOnDisk > 0 ? "\(downloads.bytesOnDisk.formatted(.byteCount(style: .file))) on this Mac" : "None"
        }
        let total = pending.reduce(Int64(0)) { $0 + $1.totalBytes }
        let got = pending.reduce(Int64(0)) { $0 + $1.receivedBytes }
        let files = pending.count == 1 ? "1 file" : "\(pending.count) files"
        return total > 0 ? "\(files), \(DownloadWords.percent(Double(got) / Double(total)))" : files
    }

    private var serverLine: String {
        guard let server = session.currentServer else { return "Not connected" }
        return "\(server.name) · \(session.routeWords)"
    }
}
