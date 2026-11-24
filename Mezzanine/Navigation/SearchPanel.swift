import SwiftUI
import AppKit
import MezzanineKit

/// Search as you type, without leaving the page (the owner asked for Trove's search): a solid
/// panel hanging under the toolbar field, over a light scrim, with the best titles, people
/// and episodes. The page stays where it was; "See all" opens the full results grid.
///
/// Keys while the field has focus: ↓/↑ walk the rows, Return opens (a person narrows the
/// search to them), ⌘Return plays, Esc closes the panel (a second Esc clears the field).
struct SearchPanel: View {
    @Environment(AppCommandCenter.self) private var commands
    @Environment(LibraryStore.self) private var library
    @Environment(SessionStore.self) private var session
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var titles: [PlexMetadata] = []
    @State private var episodes: [PlexMetadata] = []
    @State private var people: [PlexHub.Person] = []
    @State private var total = 0
    @State private var searched = ""
    @State private var selection: Int?
    @State private var monitor: Any?
    /// The pointer's last position: hover selects only when the pointer moves, not when rows
    /// change under a resting pointer.
    @State private var lastPointer: CGPoint?

    enum Hit: Hashable {
        case title(PlexMetadata.ID), person(String), episode(PlexMetadata.ID), seeAll, recent(String), clearRecents
    }

    private var query: String { commands.query.trimmingCharacters(in: .whitespaces) }

    /// Every row in reading order, for the arrow keys.
    private var hits: [Hit] {
        if query.isEmpty { return commands.recentSearches.map { .recent($0) } + [.clearRecents] }
        return titles.map { .title($0.id) } + people.map { .person($0.id) } + episodes.map { .episode($0.id) } + [.seeAll]
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }
                .accessibilityHidden(true)
            panel
                .padding(.trailing, Theme.Space.m)
                .padding(.top, Theme.Space.s)
        }
        .task(id: query) { await search() }
        .onAppear {
            installKeys()
            #if DEBUG
            print("SEARCHPANEL appeared (page: \(commands.path.last?.ratingKey ?? "section"))")
            #endif
        }
        .onDisappear {
            removeKeys()
            #if DEBUG
            print("SEARCHPANEL disappeared")
            #endif
        }
    }

    // MARK: Panel

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        content
                    }
                    .padding(Theme.Space.s)
                    .padding(.top, Theme.Space.xs)
                }
                .scrollIndicators(.never)
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 480)
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: selection) { _, i in
                    if let i, hits.indices.contains(i) { proxy.scrollTo(hits[i]) }
                }
            }
            Rectangle().fill(Theme.rule).frame(height: 1)
            if query.isEmpty { recentsFooter } else { footer }
        }
        .frame(width: 560, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous).fill(Theme.raised))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous).strokeBorder(Theme.rule, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Search results")
    }

    private var recents: some View {
        group("Recent Searches") {
            ForEach(commands.recentSearches, id: \.self) { text in
                row(.recent(text)) { selected in
                    HStack(spacing: Theme.Space.s) {
                        Image(systemName: "clock").foregroundStyle(Theme.inkTertiary).accessibilityHidden(true)
                        Text(text).foregroundStyle(selected ? Theme.lilac : Theme.ink).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .font(Theme.Typeface.body)
                    .padding(.horizontal, Theme.Space.s)
                    .frame(minHeight: 34)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .fill(selected ? Theme.raisedHover : .clear))
                } open: { commands.query = text }
            }
        }
    }

    private var recentsFooter: some View {
        HStack {
            Spacer()
            row(.clearRecents) { selected in
                Text("Clear")
                    .font(Theme.Typeface.cardMeta.weight(.semibold))
                    .foregroundStyle(selected ? Theme.lilac : Theme.ink)
                    .padding(.horizontal, Theme.Space.m)
                    .frame(minHeight: 28)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .fill(selected ? Theme.raisedHover : .clear))
            } open: { commands.clearRecentSearches() }
                .accessibilityLabel("Clear recent searches")
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
    }

    @ViewBuilder private var content: some View {
        if query.isEmpty { recents } else { results }
    }

    @ViewBuilder private var results: some View {
        if titles.isEmpty && people.isEmpty && episodes.isEmpty {
            Text(searched == query ? "Nothing called “\(query)” in your libraries." : "Searching…")
                .font(Theme.Typeface.body).foregroundStyle(Theme.inkSecondary)
                .padding(Theme.Space.s)
        }
        if !titles.isEmpty {
            group("Titles") {
                ForEach(titles) { item in
                    row(.title(item.id)) { selected in titleRow(item, selected: selected) } open: { open(item, play: false) }
                }
            }
        }
        if !people.isEmpty {
            group("People") {
                FlowRow(spacing: 6) {
                    ForEach(people) { person in
                        row(.person(person.id)) { selected in chip(person, selected: selected) } open: { narrow(to: person) }
                    }
                }
                .padding(.horizontal, Theme.Space.xs)
            }
        }
        if !episodes.isEmpty {
            group("Episodes") {
                ForEach(episodes) { item in
                    row(.episode(item.id)) { selected in episodeRow(item, selected: selected) } open: { open(item, play: false) }
                }
            }
        }
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ rows: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(Theme.Typeface.cardMeta.weight(.semibold))
                .foregroundStyle(Theme.inkSecondary)
                .padding(.horizontal, Theme.Space.s)
                .padding(.bottom, 2)
                .accessibilityAddTraits(.isHeader)
            rows()
        }
    }

    /// A row that opens on click, follows the keyboard selection and takes it when the pointer
    /// actually moves over it.
    private func row<Label: View>(_ hit: Hit, @ViewBuilder label: (Bool) -> Label, open: @escaping () -> Void) -> some View {
        let index = hits.firstIndex(of: hit)
        let selected = index != nil && index == selection
        return Button(action: open) { label(selected).contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .id(hit)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .onContinuousHover(coordinateSpace: .global) { phase in
                guard case .active(let point) = phase else { return }
                if let last = lastPointer, last != point, selection != index { selection = index }
                lastPointer = point
            }
    }

    private func titleRow(_ item: PlexMetadata, selected: Bool) -> some View {
        HStack(spacing: Theme.Space.m) {
            RemoteImage(url: session.posterURL(library.posterPath(for: item), pixelWidth: 84), pixelWidth: 84)
                .frame(width: 28, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                highlighted(Format.displayTitle(item), selected: selected).lineLimit(1)
                Text(caption(item)).font(Theme.Typeface.cardMeta).foregroundStyle(Theme.inkSecondary).lineLimit(1)
            }
            Spacer(minLength: Theme.Space.m)
            if selected { Text("↩ Open · ⌘↩ Play").font(Theme.Typeface.cardMeta).foregroundStyle(Theme.inkTertiary) }
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(minHeight: 50)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
            .fill(selected ? Theme.raisedHover : .clear))
    }

    private func episodeRow(_ item: PlexMetadata, selected: Bool) -> some View {
        HStack(spacing: Theme.Space.m) {
            RemoteImage(url: session.backdropURL(item.thumb, pixelWidth: 128), pixelWidth: 128)
                .frame(width: 64, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                highlighted(item.title, selected: selected).lineLimit(1)
                Text([item.grandparentTitle, Format.episodeCode(item)].compactMap { $0 }.joined(separator: " · "))
                    .font(Theme.Typeface.cardMeta).foregroundStyle(Theme.inkSecondary).lineLimit(1)
            }
            Spacer(minLength: Theme.Space.m)
            if selected { Text("↩ Open · ⌘↩ Play").font(Theme.Typeface.cardMeta).foregroundStyle(Theme.inkTertiary) }
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(minHeight: 46)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
            .fill(selected ? Theme.raisedHover : .clear))
    }

    private func chip(_ person: PlexHub.Person, selected: Bool) -> some View {
        HStack(spacing: 6) {
            RemoteImage(url: personImage(person), pixelWidth: 64)
                .frame(width: 22, height: 22)
                .clipShape(Circle())
            highlighted(person.name, selected: selected).lineLimit(1)
        }
        .padding(.leading, 4).padding(.trailing, 10).padding(.vertical, 4)
        .background(Capsule().fill(selected ? Theme.raisedHover : Theme.ink.opacity(0.06)))
        .accessibilityHint("Shows titles with \(person.name)")
    }

    private var footer: some View {
        let selected = selection == hits.count - 1
        return HStack(spacing: Theme.Space.m) {
            row(.seeAll) { selected in
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").accessibilityHidden(true)
                    Text(total > 0 ? "See all \(total >= 80 ? "80+" : "\(total)") results for “\(query)”" : "Search the libraries for “\(query)”")
                        .lineLimit(1)
                }
                .font(Theme.Typeface.cardMeta.weight(.semibold))
                .foregroundStyle(selected ? Theme.lilac : Theme.ink)
                .padding(.horizontal, Theme.Space.s).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(selected ? Theme.raisedHover : .clear))
            } open: { seeAll() }
            Spacer(minLength: 0)
            Text("↑↓ move · ↩ open · ⌘↩ play · esc close")
                .font(Theme.Typeface.cardMeta).foregroundStyle(Theme.inkTertiary)
                .lineLimit(1)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, 6)
    }

    // MARK: Text

    /// The text with the typed words set heavier (no colour: lilac is only for the selection).
    private func highlighted(_ text: String, selected: Bool) -> Text {
        var attributed = AttributedString(text)
        attributed.font = Theme.Typeface.cardTitle.weight(.regular)
        attributed.foregroundColor = selected ? Theme.lilac : Theme.ink
        for word in query.split(separator: " ") where !word.isEmpty {
            var from = text.startIndex
            while let range = text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive], range: from..<text.endIndex) {
                if let lower = AttributedString.Index(range.lowerBound, within: attributed),
                   let upper = AttributedString.Index(range.upperBound, within: attributed) {
                    attributed[lower..<upper].font = Theme.Typeface.cardTitle.weight(.bold)
                }
                from = range.upperBound
            }
        }
        return Text(attributed)
    }

    private func caption(_ item: PlexMetadata) -> String {
        let kind = item.kind == .show ? "Show" : "Film"
        let library = item.librarySectionID.flatMap { id in commands.sections.first { $0.key == String(id) }?.title }
        return [kind, item.year.map(String.init), library].compactMap { $0 }.joined(separator: " · ")
    }

    private func personImage(_ person: PlexHub.Person) -> URL? {
        guard let thumb = person.thumb else { return nil }
        if thumb.hasPrefix("http") { return URL(string: thumb) }
        return session.posterURL(thumb, pixelWidth: 64)
    }

    // MARK: Results

    private func search() async {
        let q = query
        guard !q.isEmpty else { return }
        selection = nil
        // The index answers at once; a newer keystroke cancels this one.
        let local = await library.search(q)
        guard !Task.isCancelled else { return }
        if !local.isEmpty || library.index != nil {
            titles = Array(local.filter { $0.kind == .movie || $0.kind == .show }.prefix(6))
            episodes = Array(local.filter { $0.kind == .episode }.prefix(4))
            total = local.count
        }
        searched = q
        // People (and, before the index exists, titles) come from the server once typing settles.
        guard q.count >= 3, let client = session.client else { people = []; return }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled, let hubs = try? await client.search(q, limit: 12), !Task.isCancelled else { return }
        people = Array(hubs.flatMap(\.people).reduce(into: [PlexHub.Person]()) { list, p in
            if !list.contains(where: { $0.name == p.name }) { list.append(p) }
        }.prefix(8))
        if library.index == nil {
            let found = hubs.flatMap(\.items)
            titles = Array(found.filter { $0.kind == .movie || $0.kind == .show }.prefix(6))
            episodes = Array(found.filter { $0.kind == .episode }.prefix(4))
            total = found.count
        }
        let n = titles.count + people.count + episodes.count
        AccessibilityNotification.Announcement(n == 0 ? "No results" : "\(n) results").post()
        #if DEBUG
        print("SEARCHPANEL q=\(q) titles=\(titles.map(\.title)) people=\(people.map(\.name)) episodes=\(episodes.map(\.title)) total=\(total)")
        #endif
    }

    // MARK: Actions

    private func open(_ item: PlexMetadata, play: Bool) {
        commands.recordSearch(query)
        commands.query = ""
        commands.recentsShown = false
        if play {
            Task { await playback.play(item, from: nil) }
        } else {
            commands.open(item)
        }
    }

    /// A person narrows the search to their titles (the index searches cast and crew).
    private func narrow(to person: PlexHub.Person) {
        commands.query = person.name
        selection = nil
    }

    private func seeAll() {
        guard !query.isEmpty else { return }
        commands.recordSearch(query)
        commands.showsAllResults = true
    }

    private func dismiss() {
        if query.isEmpty { commands.recentsShown = false; return }
        commands.searchPanelDismissedFor = commands.query
    }

    private func activate(play: Bool) {
        guard let i = selection, hits.indices.contains(i) else { seeAll(); return }
        switch hits[i] {
        case .title(let id): if let item = titles.first(where: { $0.id == id }) { open(item, play: play) }
        case .episode(let id): if let item = episodes.first(where: { $0.id == id }) { open(item, play: play) }
        case .person(let id): if let person = people.first(where: { $0.id == id }) { narrow(to: person) }
        case .seeAll: seeAll()
        case .clearRecents: commands.clearRecentSearches()
        case .recent(let text): commands.query = text; selection = nil
        }
    }

    private func move(_ delta: Int) {
        let count = hits.count
        guard count > 0 else { return }
        selection = selection.map { min(max($0 + delta, 0), count - 1) } ?? (delta > 0 ? 0 : count - 1)
    }

    // MARK: Keys

    /// The toolbar field is AppKit's: arrows, Return and Esc are read here while it has focus.
    private func installKeys() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard commands.isSearchFieldFocused, commands.mainWindowIsKey else { return event }
            switch event.keyCode {
            case 125: move(1); return nil
            case 126: move(-1); return nil
            case 36, 76: activate(play: event.modifierFlags.contains(.command)); return nil
            case 53: dismiss(); return nil
            default: return event
            }
        }
    }

    private func removeKeys() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// Chips that wrap onto as many lines as they need.
private struct FlowRow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 520
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
        }
        return CGSize(width: width, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}
