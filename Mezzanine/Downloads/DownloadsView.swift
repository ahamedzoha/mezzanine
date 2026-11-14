import SwiftUI
import MezzanineKit

/// Downloads, by title (owner's pick): downloaded films and shows on the left, the selected
/// title on the right with its files, sizes and (shows) the keep rule.
///
/// Keys: ↑/↓ choose a title, Return or Space plays (a show plays its next unwatched download),
/// Delete removes the title's downloads (asks first).
struct DownloadsView: View {
    var contentFocus: FocusState<Bool>.Binding

    @Environment(DownloadStore.self) private var downloads
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selected: String?
    @State private var confirmRemove: String?

    /// One entry per film or show, newest activity first.
    struct Group: Identifiable {
        let id: String
        let records: [DownloadRecord]
        var first: DownloadRecord { records[0] }
        var isShow: Bool { first.showKey != nil }
        var title: String { first.showTitle ?? first.title }
        var bytes: Int64 { records.reduce(0) { $0 + max($1.totalBytes, $1.receivedBytes) } }
        var inFlight: [DownloadRecord] { records.filter { !$0.isDone } }
        var progress: Double {
            let total = records.reduce(Int64(0)) { $0 + $1.totalBytes }
            return total > 0 ? Double(records.reduce(Int64(0)) { $0 + ($1.isDone ? $1.totalBytes : $1.receivedBytes) }) / Double(total) : 0
        }
    }

    private var groups: [Group] {
        Dictionary(grouping: downloads.visible, by: \.groupKey)
            .map { key, records in
                Group(id: key, records: records.sorted {
                    ($0.seasonIndex ?? 0, $0.episodeIndex ?? 0) < ($1.seasonIndex ?? 0, $1.episodeIndex ?? 0)
                })
            }
            .sorted { ($0.records.map(\.addedAt).max() ?? .distantPast) > ($1.records.map(\.addedAt).max() ?? .distantPast) }
    }

    private var current: Group? { groups.first { $0.id == selected } ?? groups.first }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if groups.isEmpty {
                RoomMessage(title: "Nothing downloaded yet",
                            detail: "Choose Download on a film or show’s page. Downloads play without the server, here and when you’re away.")
            } else {
                titleList
                    .frame(width: 320)
                if let current {
                    TitleDetail(group: current, play: play, confirmRemove: { confirmRemove = current.id })
                        .id(current.id)
                        .transition(.opacity)
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused(contentFocus)
        .onKeyPress(keys: [.upArrow, .downArrow]) { press in
            step(press.key == .upArrow ? -1 : 1)
            return .handled
        }
        .onKeyPress(keys: [.return, .space]) { _ in
            guard let current, let record = nextToPlay(current) else { return .ignored }
            play(record)
            return .handled
        }
        .onKeyPress(keys: [.delete, .deleteForward]) { _ in
            guard let current else { return .ignored }
            confirmRemove = current.id
            return .handled
        }
        .confirmationDialog(removeTitle, isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } })) {
            Button("Remove Downloads", role: .destructive) {
                if let key = confirmRemove { downloads.removeAll(inGroup: key) }
                confirmRemove = nil
            }
            Button("Cancel", role: .cancel) { confirmRemove = nil }
        } message: {
            Text("The files are deleted from this Mac. Nothing changes on the Plex server.")
        }
        .navigationTitle("Downloads")
        .navigationSubtitle(storageLine)
        .onAppear {
            if selected == nil { selected = groups.first?.id }
            #if DEBUG
            // -DownloadsPlayFirst YES plays the first title (offline tests).
            if UserDefaults.standard.bool(forKey: "DownloadsPlayFirst"), let g = groups.first, let r = nextToPlay(g) {
                Task { try? await Task.sleep(for: .seconds(1)); play(r) }
            }
            #endif
        }
    }

    private var removeTitle: String {
        guard let key = confirmRemove, let g = groups.first(where: { $0.id == key }) else { return "" }
        return g.isShow ? "Remove the \(g.records.count) downloaded episodes of \(g.title)?" : "Remove \(g.title) from this Mac?"
    }

    /// "38 GB on this Mac · 112 GB free".
    private var storageLine: String {
        let fmt = ByteCountFormatter()
        fmt.countStyle = .file
        var parts = [downloads.bytesOnDisk > 0 ? "\(fmt.string(fromByteCount: downloads.bytesOnDisk)) on this Mac" : "Nothing on this Mac yet"]
        if let free = downloads.freeBytes { parts.append("\(fmt.string(fromByteCount: free)) free") }
        return parts.joined(separator: " · ")
    }

    // MARK: Left: titles

    private var titleList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(groups) { group in
                        TitleRow(group: group, isSelected: group.id == current?.id)
                            .id(group.id)
                            .onTapGesture { selected = group.id; contentFocus.wrappedValue = true }
                            .simultaneousGesture(TapGesture(count: 2).onEnded {
                                if let r = nextToPlay(group) { play(r) }
                            })
                            .contextMenu {
                                if let r = nextToPlay(group) { Button("Play") { play(r) } }
                                Button(group.isShow ? "Remove Downloaded Episodes…" : "Remove Download…", role: .destructive) {
                                    confirmRemove = group.id
                                }
                            }
                    }
                }
                .padding(.leading, Theme.Space.gutter - Theme.Space.s)
                .padding(.trailing, Theme.Space.s)
                .padding(.vertical, Theme.Space.l)
            }
            .scrollIndicators(.never)
            .onChange(of: selected) { _, id in
                guard let id else { return }
                withAnimation(Theme.Motion.object(reduceMotion)) { proxy.scrollTo(id) }
            }
        }
    }

    private func step(_ delta: Int) {
        let list = groups
        guard !list.isEmpty else { return }
        let i = list.firstIndex { $0.id == current?.id } ?? 0
        let next = list[min(max(0, i + delta), list.count - 1)]
        selected = next.id
        AccessibilityNotification.Announcement(next.title).post()
    }

    /// A film's file, or a show's first unwatched downloaded episode (else its first).
    private func nextToPlay(_ group: Group) -> DownloadRecord? {
        let ready = group.records.filter(\.isDone)
        return ready.first { !($0.decoded()?.isWatched ?? false) } ?? ready.first
    }

    private func play(_ record: DownloadRecord) {
        guard let meta = record.decoded() else { return }
        Task { await playback.play(meta, from: nil) }
    }
}

/// A downloaded title in the left column: poster, name, one meta line, a progress line while
/// anything is still arriving.
private struct TitleRow: View {
    let group: DownloadsView.Group
    let isSelected: Bool
    @Environment(DownloadStore.self) private var downloads
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            LocalImage(url: downloads.url(group.first.posterFile))
                .frame(width: 32, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(group.title)
                    .font(Theme.Typeface.cardTitle)
                    .foregroundStyle(isSelected ? Theme.lilac : Theme.ink)
                    .lineLimit(1)
                Text(meta)
                    .font(Theme.Typeface.cardMeta)
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1)
                // The signature: arriving is an ink line; arrived, it settles into the hairline.
                ZStack(alignment: .leading) {
                    Rectangle().fill(Theme.rule)
                    Rectangle().fill(group.inFlight.isEmpty ? Theme.rule : Theme.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .scaleEffect(x: group.inFlight.isEmpty ? 1 : max(0.02, group.progress), anchor: .leading)
                }
                .frame(width: group.inFlight.isEmpty ? 48 : nil, height: group.inFlight.isEmpty ? 1 : 2)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: group.inFlight.isEmpty)
                .accessibilityHidden(true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, Theme.Space.s)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
            .fill(isSelected ? Theme.raisedHover : (hovering ? Theme.raised : .clear)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var meta: String {
        let fmt = ByteCountFormatter()
        fmt.countStyle = .file
        if let r = group.inFlight.first(where: { $0.state == .downloading }) {
            let left = downloads.rates[r.id].flatMap { rate -> String? in
                guard rate > 0 else { return nil }
                let secs = Double(r.totalBytes - r.receivedBytes) / rate
                return secs < 60 ? "under a minute left" : "\(Int(secs / 60)) min left"
            }
            return ["Downloading", "\(fmt.string(fromByteCount: r.receivedBytes)) of \(fmt.string(fromByteCount: r.totalBytes))", left]
                .compactMap { $0 }.joined(separator: " · ")
        }
        if group.inFlight.contains(where: { $0.state == .queued }) { return "Waiting · \(group.inFlight.count) to go" }
        if group.inFlight.contains(where: { if case .failed = $0.state { true } else { false } }) { return "Download failed · open to retry" }
        if let paused = group.inFlight.first(where: { $0.state == .paused }) { return "Paused · \(Int(paused.progress * 100)) %" }
        let count = group.isShow ? (group.records.count == 1 ? "1 episode" : "\(group.records.count) episodes") : "Film"
        return "\(count) · \(fmt.string(fromByteCount: group.bytes))"
    }
}

/// The selected title: backdrop strip, caption, keep rule (shows), its files.
private struct TitleDetail: View {
    let group: DownloadsView.Group
    let play: (DownloadRecord) -> Void
    let confirmRemove: () -> Void
    @Environment(DownloadStore.self) private var downloads

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                header
                if group.isShow, let showKey = group.first.showKey {
                    Picker("Keep downloaded", selection: Binding(
                        get: { downloads.keepRule(for: showKey) ?? 0 },
                        set: { downloads.setKeepRule($0 == 0 ? nil : $0, showKey: showKey) })) {
                        Text("Only what I choose").tag(0)
                        ForEach([1, 3, 5, 10], id: \.self) { Text($0 == 1 ? "The next unwatched episode" : "The next \($0) unwatched episodes").tag($0) }
                    }
                    .fixedSize()
                    .help("Mezzanine downloads the next unwatched episodes as you watch and clears the ones you’ve finished")
                }
                VStack(spacing: 2) {
                    ForEach(group.records) { record in FileRow(record: record, play: { play(record) }) }
                }
                Button(group.isShow ? "Remove All Episodes…" : "Remove Download…", action: confirmRemove)
                    .buttonStyle(SecondaryButtonStyle())
                    .focusEffectDisabled(false)
                    .help("Delete the files from this Mac (Delete)")
            }
            .padding(.trailing, Theme.Space.gutter)
            .padding(.leading, Theme.Space.xl)
            .padding(.vertical, Theme.Space.l)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .scrollIndicators(.never)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            LocalImage(url: downloads.url(group.first.backdropFile))
                .frame(height: 160)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.still, style: .continuous))
                .overlay(alignment: .bottomLeading) {
                    LinearGradient(colors: [.clear, Theme.graphite.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.still, style: .continuous))
                }
                .overlay(alignment: .bottomLeading) {
                    Text(group.title)
                        .font(Theme.Typeface.messageTitle)
                        .foregroundStyle(Theme.ink)
                        .padding(Theme.Space.l)
                        .accessibilityAddTraits(.isHeader)
                }
            Rectangle().fill(Theme.rule).frame(width: 48, height: 1).padding(.top, Theme.Space.s)
            Text(caption).font(Theme.Typeface.caption).foregroundStyle(Theme.inkSecondary)
        }
    }

    private var caption: String {
        let fmt = ByteCountFormatter()
        fmt.countStyle = .file
        var parts: [String] = []
        if group.isShow { parts.append(group.records.count == 1 ? "1 episode" : "\(group.records.count) episodes") }
        else if let y = group.first.year { parts.append(String(y)) }
        parts.append(fmt.string(fromByteCount: group.bytes))
        parts.append("Original quality")
        return parts.joined(separator: " · ")
    }
}

/// One file: code and title, size, status or progress, Play, Remove.
private struct FileRow: View {
    let record: DownloadRecord
    let play: () -> Void
    @Environment(DownloadStore.self) private var downloads
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(Theme.Typeface.cardTitle).foregroundStyle(Theme.ink).lineLimit(1)
                Text(status).font(Theme.Typeface.cardMeta).foregroundStyle(Theme.inkSecondary).lineLimit(1)
                if !record.isDone {
                    ProgressView(value: record.progress).tint(Theme.ink).frame(maxWidth: 240)
                        .accessibilityHidden(true)
                }
            }
            Spacer(minLength: Theme.Space.m)
            switch record.state {
            case .downloading, .queued:
                iconButton("pause.fill", "Pause") { downloads.pause(record.id) }
            case .paused, .failed:
                iconButton("arrow.clockwise", "Resume") { downloads.resume(record.id) }
            case .done:
                iconButton("play.fill", "Play") { play() }
            }
            iconButton("trash", record.isDone ? "Remove download" : "Cancel download") { downloads.remove(record.id) }
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(minHeight: 56)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
            .fill(hovering ? Theme.raised : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .simultaneousGesture(TapGesture(count: 2).onEnded { if record.isDone { play() } })
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(name), \(status)")
    }

    private var name: String {
        if record.kind == "episode" {
            let code = "S\(record.seasonIndex ?? 0) E\(record.episodeIndex ?? 0)"
            return "\(code) · \(record.title)"
        }
        return record.title
    }

    private var status: String {
        let fmt = ByteCountFormatter()
        fmt.countStyle = .file
        switch record.state {
        case .done: return fmt.string(fromByteCount: record.totalBytes)
        case .queued: return "Waiting"
        case .downloading: return "\(fmt.string(fromByteCount: record.receivedBytes)) of \(fmt.string(fromByteCount: record.totalBytes))"
        case .paused: return "Paused · \(Int(record.progress * 100)) %"
        case .failed(let message): return "Failed · \(message)"
        }
    }

    private func iconButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Theme.raised))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.ink)
        .focusEffectDisabled(false)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// A picture from a file on this Mac (downloaded artwork); graphite when missing.
struct LocalImage: View {
    let url: URL?
    var body: some View {
        if let url, let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        } else {
            Rectangle().fill(Theme.raised)
        }
    }
}
