import SwiftUI
import MezzanineKit

/// Downloads, by title (owner's pick): downloaded films and shows on the left, the selected
/// title on the right with its files, sizes and (shows) the keep rule.
///
/// Keys: ↑/↓ choose a title, Return, Space or ⌘Return plays (a show plays its next unwatched
/// download), Delete or ⌘⌫ removes the title's downloads (asks first; files go to the Trash).
struct DownloadsView: View {
    var contentFocus: FocusState<Bool>.Binding

    @Environment(DownloadStore.self) private var downloads
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(AppCommandCenter.self) private var commands
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selected: String?

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
        var removal: DownloadRemoval { DownloadRemoval(ids: records.map(\.id), title: title, isShow: isShow) }
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
                    TitleDetail(group: current, play: play)
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
            playCurrent() ? .handled : .ignored
        }
        .onKeyPress(keys: [.delete, .deleteForward]) { _ in
            guard let current else { return .ignored }
            commands.downloadRemoval = current.removal
            return .handled
        }
        .onChange(of: commands.playFocusedRequests) { _, _ in _ = playCurrent() }
        .onChange(of: current?.id, initial: true) { _, id in
            commands.downloadsSelection = id
            commands.hasFocusedTitle = current.flatMap(nextToPlay) != nil
        }
        .onDisappear { commands.downloadsSelection = nil }
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
                        TitleRow(group: group, isSelected: group.id == current?.id,
                                 play: nextToPlay(group).map { r in { play(r) } })
                            .id(group.id)
                            .onTapGesture { selected = group.id; contentFocus.wrappedValue = true }
                            .simultaneousGesture(TapGesture(count: 2).onEnded {
                                if let r = nextToPlay(group) { play(r) }
                            })
                            .contextMenu {
                                if let r = nextToPlay(group) { Button("Play") { play(r) } }
                                Button(group.isShow ? DownloadWords.removeEpisodesEllipsis : DownloadWords.removeEllipsis, role: .destructive) {
                                    commands.downloadRemoval = group.removal
                                }
                            }
                            .accessibilityAction { selected = group.id }
                            .modifier(PlayRemoveActions(play: nextToPlay(group).map { r in { play(r) } },
                                                        remove: { commands.downloadRemoval = group.removal }))
                    }
                }
                .padding(.leading, Theme.Space.gutter - Theme.Space.s)
                .padding(.trailing, Theme.Space.s)
                .padding(.vertical, Theme.Space.l)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Downloaded titles, \(groups.count)")
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

    private func playCurrent() -> Bool {
        guard let current, let record = nextToPlay(current) else { return false }
        play(record)
        return true
    }

    private func play(_ record: DownloadRecord) {
        guard let meta = record.decoded() else { return }
        Task { await playback.play(meta, from: nil) }
    }
}

/// VoiceOver's Play and Remove on a downloaded title.
private struct PlayRemoveActions: ViewModifier {
    let play: (() -> Void)?
    let remove: () -> Void
    func body(content: Content) -> some View {
        if let play {
            content.accessibilityAction(named: "Play", play).accessibilityAction(named: "Remove Download", remove)
        } else {
            content.accessibilityAction(named: "Remove Download", remove)
        }
    }
}

/// A downloaded title in the left column: poster, name, one meta line, and the arrival line.
private struct TitleRow: View {
    let group: DownloadsView.Group
    let isSelected: Bool
    /// Nil until something is ready to play.
    let play: (() -> Void)?
    @Environment(DownloadStore.self) private var downloads
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            LocalImage(url: downloads.url(group.first.posterFile))
                .frame(width: 32, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(group.title)
                    .font(Theme.Typeface.cardTitle)
                    .foregroundStyle(isSelected ? Theme.lilac : Theme.ink)
                    .lineLimit(1)
                Text(meta)
                    .font(Theme.Typeface.cardMeta)
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1)
                arrival
            }
            Spacer(minLength: 0)
            // The pointer's way to play, as on posters.
            if let play, hovering || isSelected {
                PlayDisc(action: play).scaleEffect(0.8).transition(.opacity)
            }
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, Theme.Space.s)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
            .fill(isSelected ? Theme.raisedHover : (hovering ? Theme.raised : .clear)))
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(Theme.Motion.quick) { hovering = inside } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(group.title)
        .accessibilityValue(meta)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// The signature: while anything arrives, an ink line runs the row's width; when it's all
    /// here, the line shrinks into the app's 48 pt hairline (no colour, no checkmark).
    private var arrival: some View {
        let arriving = !group.inFlight.isEmpty
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.rule).opacity(arriving ? 1 : 0)
                Rectangle().fill(arriving ? Theme.ink : Theme.rule)
                    .frame(width: arriving ? max(2, geo.size.width * group.progress) : 48)
            }
        }
        .frame(height: arriving ? 2 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.6), value: arriving)
        .animation(reduceMotion ? nil : .linear(duration: 0.3), value: group.progress)
        .accessibilityHidden(true)
    }

    private var meta: String {
        let fmt = ByteCountFormatter()
        fmt.countStyle = .file
        let downloading = group.inFlight.filter { $0.state == .downloading }
        if !downloading.isEmpty {
            let received = group.inFlight.reduce(Int64(0)) { $0 + $1.receivedBytes }
            let total = group.inFlight.reduce(Int64(0)) { $0 + $1.totalBytes }
            let rate = downloading.compactMap { downloads.rates[$0.id] }.reduce(0, +)
            let left = rate > 0 ? DownloadWords.timeLeft(seconds: Double(total - received) / rate) : nil
            let count = group.inFlight.count > 1 ? "\(group.inFlight.count) files" : nil
            return ["Downloading", count, "\(fmt.string(fromByteCount: received)) of \(fmt.string(fromByteCount: total))", left]
                .compactMap { $0 }.joined(separator: " · ")
        }
        if group.inFlight.contains(where: { $0.state == .queued }) { return "Waiting · \(group.inFlight.count) to go" }
        if group.inFlight.contains(where: { if case .failed = $0.state { true } else { false } }) { return "Download failed · choose it to retry" }
        if let paused = group.inFlight.first(where: { $0.state == .paused }) { return "Paused · \(DownloadWords.percent(paused.progress))" }
        let count = group.isShow ? (group.records.count == 1 ? "1 episode" : "\(group.records.count) episodes") : "Film"
        return "\(count) · \(fmt.string(fromByteCount: group.bytes))"
    }
}

/// The selected title: backdrop dissolving into the room, caption, keep rule (shows), files.
private struct TitleDetail: View {
    let group: DownloadsView.Group
    let play: (DownloadRecord) -> Void
    @Environment(DownloadStore.self) private var downloads
    @Environment(AppCommandCenter.self) private var commands

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                header
                if group.isShow, let showKey = group.first.showKey {
                    Picker(DownloadWords.keepDownloaded, selection: Binding(
                        get: { downloads.keepRule(for: showKey) ?? 0 },
                        set: { downloads.setKeepRule($0 == 0 ? nil : $0, showKey: showKey) })) {
                        ForEach(DownloadWords.keepCounts, id: \.self) { Text(DownloadWords.keepOption($0)).tag($0) }
                    }
                    .fixedSize()
                    .help("Mezzanine downloads the next unwatched episodes as you watch and clears the ones you’ve finished")
                }
                VStack(spacing: 2) {
                    ForEach(group.records) { record in FileRow(record: record, play: { play(record) }) }
                }
                Button(group.isShow ? DownloadWords.removeEpisodesEllipsis : DownloadWords.removeEllipsis) {
                    commands.downloadRemoval = group.removal
                }
                .buttonStyle(SecondaryButtonStyle())
                .focusEffectDisabled(false)
                .help("The files go to the Trash (Delete or ⌘⌫)")
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
            ZStack(alignment: .bottomLeading) {
                // The backdrop dissolves down and left into the room, like the title pages.
                LocalImage(url: downloads.url(group.first.backdropFile))
                    .frame(height: 200)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .mask(LinearGradient(stops: [
                        .init(color: .black, location: 0), .init(color: .black.opacity(0.85), location: 0.45), .init(color: .clear, location: 1),
                    ], startPoint: .top, endPoint: .bottom))
                    .mask(LinearGradient(stops: [
                        .init(color: .black.opacity(0.35), location: 0), .init(color: .black, location: 0.5),
                    ], startPoint: .leading, endPoint: .trailing))
                    .accessibilityHidden(true)
                SwiftUI.Group {
                    if let logo = downloads.url(group.first.logoFile), FileManager.default.fileExists(atPath: logo.path) {
                        LocalImage(url: logo, fill: false)
                            .frame(maxWidth: 320, maxHeight: 90, alignment: .bottomLeading)
                    } else {
                        Text(group.title).font(Theme.Typeface.messageTitle).foregroundStyle(Theme.ink)
                    }
                }
                .shadow(color: .black.opacity(0.5), radius: 8, y: 2)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(group.title)
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

/// One file: code and title, size, status or progress, then Play (or pause/resume/retry) and
/// Remove. One click on a finished row plays it.
private struct FileRow: View {
    let record: DownloadRecord
    let play: () -> Void
    @Environment(DownloadStore.self) private var downloads
    @Environment(AppCommandCenter.self) private var commands
    @State private var hovering = false

    private var failed: Bool { if case .failed = record.state { true } else { false } }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(Theme.Typeface.cardTitle).foregroundStyle(Theme.ink).lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if failed {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).accessibilityHidden(true)
                    }
                    Text(status).lineLimit(failed ? 3 : 1).fixedSize(horizontal: false, vertical: true)
                }
                .font(Theme.Typeface.cardMeta)
                .foregroundStyle(Theme.inkSecondary)
                if !record.isDone {
                    // The same ink line as the title list.
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Theme.rule)
                            Rectangle().fill(Theme.ink).frame(width: max(2, geo.size.width * record.progress))
                        }
                    }
                    .frame(maxWidth: 240)
                    .frame(height: 2)
                    .animation(.linear(duration: 0.3), value: record.progress)
                    .accessibilityElement()
                    .accessibilityLabel("Download progress")
                    .accessibilityValue(DownloadWords.percent(record.progress))
                }
            }
            .padding(.vertical, Theme.Space.s)
            Spacer(minLength: Theme.Space.m)
            HStack(spacing: Theme.Space.m) {
                switch record.state {
                case .downloading, .queued:
                    iconButton("pause.fill", "Pause Download") { downloads.pause(record.id) }
                case .paused:
                    iconButton("arrow.clockwise", "Resume Download") { downloads.resume(record.id) }
                case .failed:
                    iconButton("arrow.clockwise", "Retry Download") { downloads.resume(record.id) }
                case .done:
                    iconButton("play.fill", "Play") { play() }
                }
                if record.isDone {
                    iconButton("trash", DownloadWords.removeEllipsis, hint: "Moves the file to the Trash, after asking") {
                        commands.downloadRemoval = DownloadRemoval(ids: [record.id], title: record.title, isShow: false)
                    }
                } else {
                    iconButton("xmark", DownloadWords.cancel, hint: "Stops and deletes the partial file") { downloads.remove(record.id) }
                }
            }
            .padding(.top, Theme.Space.s)
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(minHeight: 56)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
            .fill(hovering ? Theme.raised : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if record.isDone { play() } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(name)
        .accessibilityValue(status)
    }

    private var name: String {
        if record.kind == "episode" {
            return "S\(record.seasonIndex ?? 0) E\(record.episodeIndex ?? 0) · \(record.title)"
        }
        return record.title
    }

    private var status: String {
        let fmt = ByteCountFormatter()
        fmt.countStyle = .file
        switch record.state {
        case .done: return fmt.string(fromByteCount: record.totalBytes)
        case .queued: return "Waiting"
        case .downloading:
            let left = downloads.rates[record.id].flatMap { rate in
                rate > 0 ? DownloadWords.timeLeft(seconds: Double(record.totalBytes - record.receivedBytes) / rate) : nil
            }
            return ["\(fmt.string(fromByteCount: record.receivedBytes)) of \(fmt.string(fromByteCount: record.totalBytes))", left]
                .compactMap { $0 }.joined(separator: " · ")
        case .paused: return "Paused · \(DownloadWords.percent(record.progress))"
        case .failed(let message): return "Didn’t download: \(message)"
        }
    }

    private func iconButton(_ symbol: String, _ label: String, hint: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                .frame(width: 34, height: 34)
                .background(Circle().fill(Theme.raised))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.ink)
        .focusEffectDisabled(false)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityHint(hint ?? "")
    }
}

/// A picture from a file on this Mac (downloaded artwork), read off the main thread once;
/// graphite while loading or when missing.
struct LocalImage: View {
    let url: URL?
    /// Fill the frame (artwork) or fit inside it (a clear logo, no backing).
    var fill = true
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if fill { Rectangle().fill(Theme.raised) }
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: fill ? .fill : .fit)
            }
        }
        .task(id: url) {
            guard let url else { image = nil; return }
            image = await Task.detached(priority: .utility) { NSImage(contentsOf: url) }.value
        }
    }
}
