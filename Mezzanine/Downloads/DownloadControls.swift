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
                case .paused, .failed: Button("Resume Download") { downloads.resume(record.id) }
                case .done: EmptyView()
                }
                Button(record.isDone ? "Remove Download" : "Cancel Download", role: .destructive) { downloads.remove(record.id) }
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
        } else {
            Button { downloads.download(item) } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .buttonStyle(SecondaryButtonStyle())
            .focusEffectDisabled(false)
            .help("Download to watch offline (⌥⌘D)")
        }
    }

    static func status(_ r: DownloadRecord) -> String {
        switch r.state {
        case .done: "Downloaded"
        case .queued: "Waiting to Download"
        case .downloading: "Downloading \(Int(r.progress * 100)) %"
        case .paused: "Paused \(Int(r.progress * 100)) %"
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
                Picker("Keep Downloaded", selection: Binding(get: { downloads.keepRule(for: item.ratingKey) ?? 0 },
                                                             set: { downloads.setKeepRule($0 == 0 ? nil : $0, showKey: item.ratingKey) })) {
                    Text("Off").tag(0)
                    ForEach([1, 3, 5, 10], id: \.self) { Text($0 == 1 ? "Next unwatched episode" : "Next \($0) unwatched episodes").tag($0) }
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
            .accessibilityLabel(DownloadButton.status(r))
        }
    }
}
