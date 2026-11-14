import SwiftUI
import MezzanineKit

/// The title page's Download control. Films: Download → "Downloading 42 %" → Downloaded (a
/// menu pauses, resumes or removes). Shows and seasons: a menu (next unwatched, this season,
/// keep N unwatched downloaded).
struct DownloadButton: View {
    let item: PlexMetadata
    /// The season on screen (a show page's selected season), for "This Season".
    var season: PlexMetadata? = nil

    @Environment(DownloadStore.self) private var downloads
    @Environment(AppCommandCenter.self) private var commands

    var body: some View {
        switch item.kind {
        case .movie, .episode: single
        case .show, .season: series
        default: EmptyView()
        }
    }

    // MARK: A film

    @ViewBuilder private var single: some View {
        if let record = downloads.record(item.ratingKey) {
            Menu {
                switch record.state {
                case .downloading, .queued: Button("Pause Download") { downloads.pause(record.id) }
                case .paused: Button("Resume Download") { downloads.resume(record.id) }
                case .failed: Button("Retry Download") { downloads.resume(record.id) }
                case .done: EmptyView()
                }
                if record.isDone {
                    Button(DownloadWords.removeEllipsis, role: .destructive) {
                        commands.downloadRemoval = DownloadRemoval(ids: [record.id], title: record.title, isShow: false)
                    }
                } else {
                    Button(DownloadWords.cancel, role: .destructive) { downloads.remove(record.id) }
                }
            } label: {
                Label(Self.status(record), systemImage: record.isDone ? "arrow.down.circle.fill" : "arrow.down.circle")
                    .contentTransition(.numericText())
            }
            .menuStyle(.button)
            .buttonStyle(SecondaryButtonStyle())
            .menuIndicator(.hidden)
            .fixedSize()
            .focusEffectDisabled(false)
            .help(record.isDone ? "Downloaded to this Mac. Plays without the server." : "Downloading for offline viewing")
            .accessibilityLabel(Self.status(record))
            .accessibilityHint(record.isDone ? "Opens a menu to remove the download" : "Opens a menu to pause, resume or cancel")
        } else {
            Button { downloads.download(item) } label: {
                Label(DownloadWords.download, systemImage: "arrow.down.circle")
            }
            .buttonStyle(SecondaryButtonStyle())
            .focusEffectDisabled(false)
            .help("Download to watch offline (⇧⌘D)")
        }
    }

    static func status(_ r: DownloadRecord) -> String {
        switch r.state {
        case .done: "Downloaded"
        case .queued: "Waiting to Download"
        case .downloading: "Downloading \(DownloadWords.percent(r.progress))"
        case .paused: "Paused \(DownloadWords.percent(r.progress))"
        case .failed: "Download Failed"
        }
    }

    // MARK: A show or season

    private var showKey: String { item.kind == .show ? item.ratingKey : (item.parentRatingKey ?? item.ratingKey) }
    private var downloadedCount: Int { downloads.visible.filter { $0.showKey == showKey }.count }

    private var series: some View {
        Menu {
            if item.kind == .show {
                ForEach([1, 3, 5], id: \.self) { n in
                    Button(n == 1 ? "Next Unwatched Episode" : "Next \(n) Unwatched Episodes") { downloads.downloadNext(n, of: item) }
                }
            }
            if let season = season ?? (item.kind == .season ? item : nil) {
                Button("All of \(season.title)") { downloads.downloadSeason(season) }
            }
            if item.kind == .show {
                Divider()
                Picker(DownloadWords.keepDownloaded, selection: Binding(get: { downloads.keepRule(for: item.ratingKey) ?? 0 },
                                                             set: { downloads.setKeepRule($0 == 0 ? nil : $0, showKey: item.ratingKey) })) {
                    ForEach(DownloadWords.keepCounts, id: \.self) { Text(DownloadWords.keepOption($0)).tag($0) }
                }
            }
        } label: {
            Label(downloadedCount > 0 ? "\(downloadedCount) Downloaded" : "Download",
                  systemImage: downloadedCount > 0 ? "arrow.down.circle.fill" : "arrow.down.circle")
        }
        .menuStyle(.button)
        .buttonStyle(SecondaryButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .focusEffectDisabled(false)
        .help("Download episodes to watch offline")
        .accessibilityLabel(downloadedCount > 0 ? "\(downloadedCount) episodes downloaded. Download more" : "Download episodes")
    }
}

/// An episode row's small download mark: a filled arrow when downloaded, an ink ring while
/// downloading. Hueless, like the watched check.
struct DownloadMark: View {
    let ratingKey: String
    @Environment(DownloadStore.self) private var downloads

    var body: some View {
        if let r = downloads.record(ratingKey) {
            Group {
                if r.isDone {
                    Image(systemName: "arrow.down.circle.fill").font(.system(size: 11, weight: .semibold))
                } else {
                    ZStack {
                        Circle().stroke(Theme.ink.opacity(0.25), lineWidth: 1.5)
                        Circle().trim(from: 0, to: r.progress).stroke(Theme.ink, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 11, height: 11)
                }
            }
            .foregroundStyle(Theme.inkTertiary)
            .help(DownloadButton.status(r))
            .accessibilityLabel(r.isDone ? "Downloaded" : "Downloading")
            .accessibilityValue(r.isDone ? "" : DownloadWords.percent(r.progress))
        }
    }
}

/// One set of words for downloads, everywhere (menus, buttons, pickers).
enum DownloadWords {
    static let download = "Download"
    static let cancel = "Cancel Download"
    static let removeEllipsis = "Remove Download…"
    static let removeEpisodesEllipsis = "Remove Downloaded Episodes…"
    static let keepDownloaded = "Keep Downloaded"
    static func keepOption(_ n: Int) -> String {
        n == 0 ? "Off" : (n == 1 ? "Next Unwatched Episode" : "Next \(n) Unwatched Episodes")
    }
    static let keepCounts = [0, 1, 3, 5, 10]

    /// "42 %", locale-aware.
    static func percent(_ p: Double) -> String { p.formatted(.percent.precision(.fractionLength(0))) }

    /// "3 min left", "1 hr 20 min left".
    static func timeLeft(seconds: Double) -> String {
        if seconds < 60 { return "under a minute left" }
        let f = DateComponentsFormatter()
        f.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
        f.unitsStyle = .short
        return (f.string(from: seconds) ?? "") + " left"
    }
}

/// Removing downloads: always asked, once, by the window. Finished files go to the Trash
/// (recoverable in Finder); unfinished ones are simply cancelled.
struct DownloadRemoval: Identifiable, Equatable {
    let id = UUID()
    let ids: [String]
    let title: String
    let isShow: Bool

    var question: String {
        isShow ? "Remove the \(ids.count == 1 ? "downloaded episode" : "\(ids.count) downloaded episodes") of \(title)?"
               : "Remove \(title) from this Mac?"
    }
    var confirm: String { ids.count == 1 ? "Remove Download" : "Remove Downloads" }
}
