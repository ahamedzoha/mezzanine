import SwiftUI
import UniformTypeIdentifiers
import MezzanineKit

/// Edit Home: every shelf folded into a strip you can drag, hide, rename or open, with Add
/// Shelf at the end. Changes save as they happen; Done (or ⌘E) unfolds the strips back into
/// poster rows in the new order.
///
/// Keys: ↑/↓ select, ⌥↑/⌥↓ move, Space shows or hides, Return renames (or edits a smart
/// shelf's rules), ⌫ removes, ⌘N new smart shelf, Esc or ⌘E done.
struct ShelfEditor: View {
    let scope: String
    let model: HomeModel
    @Binding var specs: [ShelfSpec]
    /// Libraries, for naming library rows and the Add Shelf submenus.
    let sections: [PlexLibrarySection]
    let peek: Namespace.ID
    let editRules: (ShelfSpec?) -> Void
    let addCollection: () -> Void
    let addPlaylist: (PlexMetadata) -> Void
    let playlists: [PlexMetadata]
    let resetLayout: () -> Void
    let done: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selected: String?
    @State private var renaming: ShelfSpec?
    @State private var renameText = ""
    @State private var dragging: String?
    @FocusState private var focused: Bool

    private var isMain: Bool { scope == HomeLayout.mainScope }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Drag to reorder. Hidden shelves stay here, dimmed.")
                            .font(Theme.Typeface.body).foregroundStyle(Theme.inkSecondary)
                        Spacer()
                        Button("Restore Default Shelves", action: resetLayout)
                            .buttonStyle(.borderless)
                            .foregroundStyle(Theme.inkSecondary)
                            .help("Go back to Plex’s own rows")
                    }
                    .padding(.bottom, Theme.Space.s)
                    ForEach(specs) { spec in
                        ShelfStrip(spec: spec, shelf: model.resolved[spec.id], sourceLine: sourceLine(spec),
                                   isSelected: selected == spec.id, peek: peek,
                                   toggleHidden: { toggleHidden(spec.id) },
                                   menu: { stripMenu(spec) })
                            .id(spec.id)
                            .opacity(dragging == spec.id ? 0.4 : 1)
                            .onTapGesture { selected = spec.id; focused = true }
                            .simultaneousGesture(TapGesture(count: 2).onEnded { open(spec) })
                            .onDrag {
                                dragging = spec.id
                                return NSItemProvider(object: spec.id as NSString)
                            }
                            .onDrop(of: [.text], delegate: StripDrop(target: spec.id, specs: $specs, dragging: $dragging,
                                                                     animation: Theme.Motion.object(reduceMotion)))
                    }
                    addStrip
                }
                .padding(.horizontal, Theme.Space.gutter)
                .padding(.top, Theme.Space.l)
                .padding(.bottom, Theme.Space.xxl)
                .frame(maxWidth: 980, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            .onChange(of: selected) { _, id in
                guard let id else { return }
                withAnimation(Theme.Motion.object(reduceMotion)) { proxy.scrollTo(id) }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear {
            focused = true
            if selected == nil { selected = specs.first?.id }
        }
        .onKeyPress(keys: [.upArrow, .downArrow]) { press in
            let up = press.key == .upArrow
            if press.modifiers.contains(.option) { moveSelected(up ? -1 : 1) } else { step(up ? -1 : 1) }
            return .handled
        }
        .onKeyPress(.space) {
            guard let selected else { return .ignored }
            toggleHidden(selected)
            return .handled
        }
        .onKeyPress(.return) {
            guard let spec = specs.first(where: { $0.id == selected }) else { return .ignored }
            open(spec)
            return .handled
        }
        .onKeyPress(keys: [.delete, .deleteForward]) { _ in
            guard let selected else { return .ignored }
            remove(selected)
            return .handled
        }
        .onKeyPress(.escape) { done(); return .handled }
        .alert("Rename Shelf", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") { commitRename() }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("Leave it empty to use the shelf’s own name.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Edit shelves")
    }

    // MARK: Add Shelf

    private var addStrip: some View {
        Menu {
            Section("Plex") {
                ForEach(availableHubs(isMain ? nil : scope), id: \.hubIdentifier) { hub in
                    Button(hub.title) { add(.hub(identifier: hub.hubIdentifier, section: isMain ? nil : scope), title: "") }
                }
                if isMain {
                    ForEach(sections) { section in
                        let hubs = availableHubs(section.key)
                        if !hubs.isEmpty {
                            Menu(section.title) {
                                ForEach(hubs, id: \.hubIdentifier) { hub in
                                    Button(hub.title) { add(.hub(identifier: hub.hubIdentifier, section: section.key), title: "") }
                                }
                            }
                        }
                    }
                }
            }
            Section {
                Button("Collection…", action: addCollection)
                if !playlists.isEmpty {
                    Menu("Playlist") {
                        ForEach(playlists) { playlist in Button(playlist.title) { addPlaylist(playlist) } }
                    }
                }
                Button("New Smart Shelf…") { editRules(nil) }
            }
        } label: {
            Label("Add Shelf", systemImage: "plus")
                .font(Theme.Typeface.cardTitle)
                .foregroundStyle(Theme.inkSecondary)
                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                .padding(.horizontal, Theme.Space.m)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous)
            .strokeBorder(Theme.rule, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
        .padding(.top, Theme.Space.s)
        .help("Add a Plex row, a collection, a playlist or a smart shelf")
    }

    /// Plex rows not already on this Home.
    private func availableHubs(_ section: String?) -> [PlexHub] {
        let used = Set(specs.compactMap { spec -> String? in
            if case .hub(let id, _) = spec.source { return id }
            return nil
        })
        return (model.hubCatalog[section] ?? []).filter { !used.contains($0.hubIdentifier) && (section != nil || HomeModel.offersGlobal($0)) }
    }

    // MARK: Strip menu

    @ViewBuilder private func stripMenu(_ spec: ShelfSpec) -> some View {
        Button("Rename…") { beginRename(spec) }
        if spec.smartRule != nil {
            Button("Edit Rules…") { editRules(spec) }
            Button("Duplicate") { duplicate(spec) }
        }
        Divider()
        Button("Move to Top") { move(spec.id, to: 0) }.disabled(specs.first?.id == spec.id)
        Button("Move Up") { selected = spec.id; moveSelected(-1) }.disabled(specs.first?.id == spec.id)
        Button("Move Down") { selected = spec.id; moveSelected(1) }.disabled(specs.last?.id == spec.id)
        Divider()
        Button(spec.hidden ? "Show on Home" : "Hide from Home") { toggleHidden(spec.id) }
        Button("Remove", role: .destructive) { remove(spec.id) }
    }

    // MARK: Words

    private func sourceLine(_ spec: ShelfSpec) -> String {
        let shelf = model.resolved[spec.id]
        var parts: [String] = []
        if spec.hidden { parts.append("Hidden") }
        switch spec.source {
        case .hub(_, let section):
            if shelf?.isMissing == true { return "Not on this server" }
            parts.append("Plex")
            if isMain, let section, let title = sections.first(where: { $0.key == section })?.title { parts.append(title) }
        case .collection:
            parts.append("Collection")
        case .playlist:
            parts.append("Playlist")
        case .smart(let rule):
            parts.append("Smart")
            parts.append(rule.summary)
        }
        if let n = shelf?.items.count, n > 0, spec.smartRule == nil { parts.append(n == 1 ? "1 title" : "\(n) titles") }
        return parts.joined(separator: " · ")
    }

    // MARK: Changes

    private func step(_ delta: Int) {
        guard !specs.isEmpty else { return }
        let i = specs.firstIndex { $0.id == selected } ?? (delta > 0 ? -1 : specs.count)
        selected = specs[min(max(0, i + delta), specs.count - 1)].id
    }

    private func moveSelected(_ delta: Int) {
        guard let id = selected, let i = specs.firstIndex(where: { $0.id == id }) else { return }
        move(id, to: min(max(0, i + delta), specs.count - 1))
    }

    private func move(_ id: String, to target: Int) {
        guard let i = specs.firstIndex(where: { $0.id == id }), i != target else { return }
        withAnimation(Theme.Motion.object(reduceMotion)) {
            let spec = specs.remove(at: i)
            specs.insert(spec, at: target)
        }
        let title = model.resolved[id]?.title ?? "Shelf"
        AccessibilityNotification.Announcement("\(title) moved to position \(target + 1) of \(specs.count)").post()
    }

    private func toggleHidden(_ id: String) {
        guard let i = specs.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(Theme.Motion.quick) { specs[i].hidden.toggle() }
        let title = model.resolved[id]?.title ?? "Shelf"
        AccessibilityNotification.Announcement(specs[i].hidden ? "\(title) hidden" : "\(title) shown").post()
    }

    private func remove(_ id: String) {
        guard let i = specs.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(Theme.Motion.object(reduceMotion)) { _ = specs.remove(at: i) }
        if !specs.isEmpty { selected = specs[min(i, specs.count - 1)].id } else { selected = nil }
    }

    private func add(_ source: ShelfSpec.Source, title: String) {
        let spec = ShelfSpec(title: title, source: source)
        withAnimation(Theme.Motion.object(reduceMotion)) { specs.append(spec) }
        selected = spec.id
    }

    private func duplicate(_ spec: ShelfSpec) {
        guard let i = specs.firstIndex(where: { $0.id == spec.id }) else { return }
        var copy = spec
        copy.id = UUID().uuidString
        copy.title = spec.title.isEmpty ? "" : spec.title + " Copy"
        withAnimation(Theme.Motion.object(reduceMotion)) { specs.insert(copy, at: i + 1) }
        selected = copy.id
    }

    private func open(_ spec: ShelfSpec) {
        if spec.smartRule != nil { editRules(spec) } else { beginRename(spec) }
    }

    private func beginRename(_ spec: ShelfSpec) {
        renameText = spec.title
        renaming = spec
    }

    private func commitRename() {
        guard let target = renaming, let i = specs.firstIndex(where: { $0.id == target.id }) else { return }
        specs[i].title = renameText.trimmingCharacters(in: .whitespaces)
        renaming = nil
    }
}

/// One folded shelf: grip, name and source, a peek of its first posters, show switch, menu.
private struct ShelfStrip<MenuContent: View>: View {
    let spec: ShelfSpec
    let shelf: Shelf?
    let sourceLine: String
    let isSelected: Bool
    let peek: Namespace.ID
    let toggleHidden: () -> Void
    @ViewBuilder let menu: () -> MenuContent

    @Environment(SessionStore.self) private var session
    @Environment(LibraryStore.self) private var library
    @State private var hovering = false

    private var title: String {
        if !spec.title.isEmpty { return spec.title }
        return shelf?.title ?? spec.smartRule?.summary ?? "Shelf"
    }

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.inkTertiary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Theme.Typeface.cardTitle)
                    .foregroundStyle(isSelected ? Theme.lilac : Theme.ink)
                    .lineLimit(1)
                Text(sourceLine)
                    .font(Theme.Typeface.cardMeta)
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1)
            }
            .opacity(spec.hidden ? 0.55 : 1)
            Spacer(minLength: Theme.Space.l)
            HStack(spacing: 4) {
                ForEach(Array((shelf?.items ?? []).prefix(5).enumerated()), id: \.offset) { i, item in
                    RemoteImage(url: session.posterURL(library.posterPath(for: item), pixelWidth: 96), pixelWidth: 96)
                        .frame(width: 32, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .matchedGeometryEffect(id: "\(spec.id)-\(i)", in: peek)
                }
            }
            .saturation(spec.hidden ? 0 : 1)
            .opacity(spec.hidden ? 0.45 : 1)
            .accessibilityHidden(true)
            Toggle("Show on Home", isOn: Binding(get: { !spec.hidden }, set: { _ in toggleHidden() }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .help(spec.hidden ? "Show on Home (Space)" : "Hide from Home (Space)")
            Menu(content: menu) {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .foregroundStyle(Theme.inkSecondary)
            .help("Rename, move, edit rules or remove")
            .accessibilityLabel("More for \(title)")
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(height: 72)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous)
            .fill(isSelected || hovering ? Theme.raisedHover : Theme.raised))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu(menuItems: menu)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(sourceLine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: spec.hidden ? "Show on Home" : "Hide from Home", toggleHidden)
    }
}

/// Live reordering: the dragged strip takes the target's place as it passes over it.
private struct StripDrop: DropDelegate {
    let target: String
    @Binding var specs: [ShelfSpec]
    @Binding var dragging: String?
    let animation: Animation

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target,
              let from = specs.firstIndex(where: { $0.id == dragging }),
              let to = specs.firstIndex(where: { $0.id == target }) else { return }
        withAnimation(animation) {
            specs.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}
