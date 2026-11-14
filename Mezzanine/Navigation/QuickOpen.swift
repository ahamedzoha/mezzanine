import SwiftUI
import MezzanineKit

/// ⌘K: open a title, a place or an action by name.
///
/// A solid panel dropping from under the toolbar on the content gutter (never centred), over
/// a scrim that closes it. Titles come from the local index (instant); Go To and Actions are
/// the app's own places and commands. ↑/↓ select, Return runs, ⌘Return plays a title, Esc
/// closes.
struct QuickOpen: View {
    @Environment(AppCommandCenter.self) private var commands
    @Environment(LibraryStore.self) private var library
    @Environment(SessionStore.self) private var session
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(\.openSettings) private var openSettings
    @State private var query = ""
    @State private var rows: [Row] = []
    @State private var selected = 0
    @State private var search: Task<Void, Never>?
    /// The pointer's last position over the list: hover selects only when the pointer moves,
    /// not when rows scroll under a resting pointer.
    @State private var lastPointer: CGPoint?
    @FocusState private var fieldFocused: Bool

    struct Row: Identifiable {
        enum Kind { case title(PlexMetadata), play(PlexMetadata), go(SidebarItem), settings, editShelves, newSmartShelf }
        let id: String
        let section: String
        let title: String
        let caption: String
        let symbol: String?
        let kind: Kind

        var item: PlexMetadata? {
            switch kind {
            case .title(let m), .play(let m): m
            default: nil
            }
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { close() }
                .accessibilityHidden(true)
            panel
                .padding(.leading, Theme.Space.gutter)
                .padding(.top, Theme.Space.m)
        }
        .onExitCommand { close() }
        .onAppear {
            fieldFocused = true
            #if DEBUG
            if let q = UserDefaults.standard.string(forKey: "QuickOpenQuery"), q != "_" { query = q }
            #endif
            Task { await refresh() }
        }
        .onChange(of: query) { _, _ in
            search?.cancel()
            search = Task {
                try? await Task.sleep(for: .milliseconds(60))
                guard !Task.isCancelled else { return }
                await refresh()
            }
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.inkSecondary)
                    .accessibilityHidden(true)
                TextField("Open a title, a library or an action", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(.title3))
                    .focused($fieldFocused)
                    .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                        step(press.key == .upArrow ? -1 : 1)
                        return .handled
                    }
                    .onKeyPress(keys: [.return]) { press in
                        run(play: press.modifiers.contains(.command))
                        return .handled
                    }
                    .onKeyPress(.escape) { close(); return .handled }
                    .accessibilityLabel("Quick Open")
            }
            .padding(.horizontal, Theme.Space.l)
            .frame(height: 52)
            Rectangle().fill(Theme.rule).frame(height: 1)
            if rows.isEmpty {
                Text(query.isEmpty ? "Type to find a title." : "Nothing called “\(query)” in your libraries.")
                    .font(Theme.Typeface.body).foregroundStyle(Theme.inkSecondary)
                    .padding(Theme.Space.l)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                                if i == 0 || rows[i - 1].section != row.section {
                                    Text(row.section)
                                        .font(Theme.Typeface.cardMeta.weight(.semibold))
                                        .foregroundStyle(Theme.inkSecondary)
                                        .padding(.horizontal, Theme.Space.m)
                                        .padding(.top, i == 0 ? Theme.Space.s : Theme.Space.m)
                                        .padding(.bottom, 2)
                                        .accessibilityAddTraits(.isHeader)
                                }
                                rowView(row, selected: i == selected)
                                    .id(row.id)
                                    .onTapGesture { selected = i; run(play: false) }
                                    .onContinuousHover(coordinateSpace: .global) { phase in
                                        guard case .active(let point) = phase else { return }
                                        if let last = lastPointer, last != point, selected != i { selected = i }
                                        lastPointer = point
                                    }
                                    .accessibilityAction { selected = i; run(play: false) }
                                    .modifier(PlayAction(enabled: row.item != nil) { selected = i; run(play: true) })
                            }
                        }
                        .padding(Theme.Space.s)
                    }
                    .frame(maxHeight: 420)
                    .fixedSize(horizontal: false, vertical: true)
                    .onChange(of: selected) { _, i in
                        guard rows.indices.contains(i) else { return }
                        proxy.scrollTo(rows[i].id)
                    }
                }
            }
        }
        .frame(width: 620, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous).fill(Theme.raised))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous).strokeBorder(Theme.rule, lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    private func rowView(_ row: Row, selected: Bool) -> some View {
        HStack(spacing: Theme.Space.m) {
            if let item = row.item {
                RemoteImage(url: session.posterURL(library.posterPath(for: item), pixelWidth: 84), pixelWidth: 84)
                    .frame(width: 28, height: 42)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            } else {
                Image(systemName: row.symbol ?? "arrow.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.raisedHover))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(Theme.Typeface.cardTitle)
                    .foregroundStyle(selected ? Theme.lilac : Theme.ink)
                    .lineLimit(1)
                if !row.caption.isEmpty {
                    Text(row.caption).font(Theme.Typeface.cardMeta).foregroundStyle(Theme.inkSecondary).lineLimit(1)
                }
            }
            Spacer(minLength: Theme.Space.m)
            if selected {
                Text(hint(row)).font(Theme.Typeface.cardMeta).foregroundStyle(Theme.inkTertiary)
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(minHeight: 48)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
            .fill(selected ? Theme.raisedHover : .clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func hint(_ row: Row) -> String {
        switch row.kind {
        case .title: "↩ Open · ⌘↩ Play"
        case .play: "↩ Play"
        default: "↩"
        }
    }

    // MARK: Results

    private func refresh() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        defer {
            if !Task.isCancelled {
                AccessibilityNotification.Announcement(rows.isEmpty ? "No results" : (rows.count == 1 ? "1 result" : "\(rows.count) results")).post()
            }
        }
        var out: [Row] = []
        if q.isEmpty {
            for item in inProgress(limit: 3) {
                out.append(Row(id: "resume-\(item.ratingKey)", section: "Continue", title: "Resume \(Format.displayTitle(item))",
                               caption: Format.cardSubtitle(item), symbol: nil, kind: .play(item)))
            }
        } else {
            // Titles that contain the words first; summary and cast matches after them.
            let found = await library.search(q)
            // A newer query is already on its way.
            guard !Task.isCancelled, q == query.trimmingCharacters(in: .whitespaces) else { return }
            let hits = found.filter { $0.title.localizedCaseInsensitiveContains(q) }
                + found.filter { !$0.title.localizedCaseInsensitiveContains(q) }
            for item in hits.prefix(6) {
                out.append(Row(id: "title-\(item.ratingKey)", section: "Titles", title: item.kind == .episode ? item.title : Format.displayTitle(item),
                               caption: caption(item), symbol: nil, kind: .title(item)))
            }
            for show in hits.filter({ $0.kind == .show }).prefix(2) {
                out.append(Row(id: "next-\(show.ratingKey)", section: "Actions", title: "Play Next Episode of \(show.title)",
                               caption: "Resumes where you left off", symbol: "play.fill", kind: .play(show)))
            }
        }
        out += places(matching: q)
        rows = out
        selected = 0
    }

    private func inProgress(limit: Int) -> [PlexMetadata] {
        guard let index = library.index else { return [] }
        let rule = SmartRule(kinds: ["movie", "episode"], conditions: [.watch(.inProgress)], sort: .lastWatched, limit: limit)
        return ((try? index.items(rule)) ?? []).compactMap { $0.metadata() }
    }

    /// Go To and Actions whose names match (all of them for an empty query).
    private func places(matching q: String) -> [Row] {
        var all: [Row] = [
            Row(id: "go-home", section: "Go To", title: "Home", caption: "⌘1", symbol: "house", kind: .go(.home)),
        ]
        for (i, section) in commands.sections.enumerated() {
            all.append(Row(id: "go-\(section.key)", section: "Go To", title: section.title,
                           caption: i < 8 ? "⌘\(i + 2)" : "", symbol: section.kind == .show ? "tv" : "film", kind: .go(.library(section.key))))
        }
        all.append(Row(id: "settings", section: "Go To", title: "Settings", caption: "⌘,", symbol: "gearshape", kind: .settings))
        all.append(Row(id: "edit", section: "Actions", title: "Edit Shelves", caption: "Home · ⌘E", symbol: "rectangle.stack", kind: .editShelves))
        all.append(Row(id: "smart", section: "Actions", title: "New Smart Shelf…", caption: "Home · ⌘N", symbol: "wand.and.stars", kind: .newSmartShelf))
        guard !q.isEmpty else { return all }
        return all.filter { $0.title.localizedCaseInsensitiveContains(q) }
    }

    private func caption(_ item: PlexMetadata) -> String {
        switch item.kind {
        case .movie: return ["Movie", item.year.map(String.init)].compactMap { $0 }.joined(separator: " · ")
        case .show: return ["Show", item.childCount.map { $0 == 1 ? "1 season" : "\($0) seasons" }].compactMap { $0 }.joined(separator: " · ")
        case .episode: return [item.grandparentTitle, Format.episodeCode(item)].compactMap { $0 }.joined(separator: " · ")
        default: return Format.cardSubtitle(item)
        }
    }

    // MARK: Running

    private func step(_ delta: Int) {
        guard !rows.isEmpty else { return }
        selected = min(max(0, selected + delta), rows.count - 1)
        let row = rows[selected]
        AccessibilityNotification.Announcement([row.title, row.caption, row.section].filter { !$0.isEmpty }.joined(separator: ", ")).post()
    }

    private func run(play: Bool) {
        guard rows.indices.contains(selected) else { return }
        let row = rows[selected]
        close()
        switch row.kind {
        case .title(let item):
            if play { Task { await playback.play(item, from: nil) } } else { commands.open(item) }
        case .play(let item):
            Task { await playback.play(item, from: nil) }
        case .go(let place):
            commands.go(to: place)
        case .settings:
            openSettings()
        case .editShelves:
            openOnHome(.startEditing)
        case .newSmartShelf:
            openOnHome(.newSmartShelf)
        }
    }

    /// Runs a shelf action on Home: now if Home is showing, else once it appears.
    private func openOnHome(_ action: AppCommandCenter.ShelfAction) {
        if commands.isHomeVisible && commands.path.isEmpty {
            commands.shelf(action)
        } else {
            commands.pendingHomeAction = action
            commands.go(to: .home)
        }
    }

    private func close() {
        commands.isQuickOpenShown = false
    }
}

/// "Play" for VoiceOver on rows that hold a title.
private struct PlayAction: ViewModifier {
    let enabled: Bool
    let action: () -> Void
    func body(content: Content) -> some View {
        if enabled { content.accessibilityAction(named: "Play", action) } else { content }
    }
}
