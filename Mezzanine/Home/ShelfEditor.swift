import SwiftUI
import UniformTypeIdentifiers
import MezzanineKit

/// Edit Shelves: every shelf folded into a strip you can drag, hide, rename or open, with Add
/// Shelf at the end. Changes save as they happen (HomeView debounces) and every change can be
/// undone (⌘Z); Done (or ⌘E) unfolds the strips back into poster rows in the new order.
///
/// Keys: ↑/↓ select, ⌥↑/⌥↓ move, Space shows or hides, Return renames (or edits a smart
/// shelf's rules), ⌫ removes, ⌘N new smart shelf, Esc or ⌘E done. Every key is also in
/// View ▸ (while editing) and every action is in the strip's ⋯ menu and VoiceOver actions.
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
    /// What Restore Default Shelves returns to.
    let defaults: [ShelfSpec]
    /// Bumped by HomeView when a sheet closes, to take keyboard focus back.
    let refocus: Int
    let done: () -> Void

    @Environment(PinnedStore.self) private var pins
    @Environment(WatchlistStore.self) private var watchlist
    @Environment(AppCommandCenter.self) private var commands
    @Environment(\.undoManager) private var undoManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selected: String?
    @State private var renaming: ShelfSpec?
    @State private var renameText = ""
    @State private var confirmingReset = false
    @State private var dragging: String?
    /// The order before a drag, so the drag can be undone as one move.
    @State private var dragStart: [ShelfSpec]?
    @State private var addHovering = false
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
                        Button("Restore Default Shelves…") { confirmingReset = true }
                            .buttonStyle(.borderless)
                            .foregroundStyle(Theme.inkSecondary)
                            .focusEffectDisabled(false)
                            .disabled(specs == defaults)
                            .help("Go back to Plex’s own rows (asks first; ⌘Z undoes it)")
                    }
                    .padding(.bottom, Theme.Space.s)
                    ForEach(specs) { spec in
                        ShelfStrip(spec: spec, shelf: model.resolved[spec.id], sourceLine: sourceLine(spec),
                                   isSelected: selected == spec.id, isDragging: dragging == spec.id,
                                   peek: reduceMotion ? nil : peek,
                                   select: { selected = spec.id },
                                   toggleHidden: { toggleHidden(spec.id) },
                                   actions: actions(spec),
                                   menu: { stripMenu(spec) })
                            .id(spec.id)
                            .onTapGesture { selected = spec.id; focused = true }
                            .simultaneousGesture(TapGesture(count: 2).onEnded { open(spec) })
                            .onDrag {
                                beginDrag(spec.id)
                                let provider = NSItemProvider()
                                provider.registerDataRepresentation(forTypeIdentifier: UTType.mezzanineShelf.identifier,
                                                                    visibility: .ownProcess) { done in
                                    done(Data(spec.id.utf8), nil)
                                    return nil
                                }
                                return provider
                            }
                            .onDrop(of: [.mezzanineShelf], delegate: StripDrop(target: spec.id, specs: $specs, dragging: $dragging,
                                                                               animation: Theme.Motion.object(reduceMotion)))
                    }
                    addStrip
                }
                .padding(.horizontal, Theme.Space.gutter)
                .padding(.top, Theme.Space.l)
                .padding(.bottom, Theme.Space.xxl)
                .frame(maxWidth: 980, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                // A drop anywhere else ends the drag cleanly.
                .onDrop(of: [.mezzanineShelf], isTargeted: nil) { _ in endDrag(); return true }
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
        .onChange(of: refocus) { _, _ in focused = true }
        .onChange(of: specs.map(\.id)) { old, new in
            // A shelf added from a menu, sheet or picker: select it and say so.
            guard let added = new.first(where: { !old.contains($0) }) else { return }
            selected = added
            let title = title(of: specs.first { $0.id == added })
            AccessibilityNotification.Announcement("\(title) added").post()
        }
        .onChange(of: renaming != nil || confirmingReset) { _, up in
            commands.isModalShown = up
            if !up { focused = true }
        }
        .onChange(of: commands.shelfRequests.count) { _, _ in handle(commands.shelfRequests.action) }
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
        .onExitCommand { done() }
        .alert("Rename Shelf", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") { commitRename() }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("Leave it empty to use the shelf’s own name.")
        }
        .confirmationDialog("Restore the default shelves?", isPresented: $confirmingReset) {
            Button("Restore Defaults", role: .destructive) { reset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your own shelves and order are replaced by Plex’s rows. Edit ▸ Undo brings them back.")
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
                if isMain, watchlist.isAvailable, !specs.contains(where: { $0.source == .watchlist }) {
                    Button("Watchlist") { add(.watchlist, title: "") }
                }
                Button("New Smart Shelf…") { editRules(nil) }
            }
        } label: {
            Label("Add Shelf", systemImage: "plus")
                .font(Theme.Typeface.cardTitle)
                .foregroundStyle(addHovering ? Theme.ink : Theme.inkSecondary)
                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                .padding(.horizontal, Theme.Space.m)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .focusEffectDisabled(false)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous)
            .fill(addHovering ? Theme.raised : .clear))
        .background(RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous)
            .strokeBorder(Theme.rule, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
        .onHover { addHovering = $0 }
        .padding(.top, Theme.Space.s)
        .help("Add a Plex row, a collection, a playlist or a smart shelf (File ▸ New Smart Shelf ⌘N)")
    }

    /// Plex rows not already on this Home.
    private func availableHubs(_ section: String?) -> [PlexHub] {
        let used = Set(specs.compactMap { spec -> String? in
            if case .hub(let id, _) = spec.source { return id }
            return nil
        })
        return (model.hubCatalog[section] ?? []).filter { !used.contains($0.hubIdentifier) && (section != nil || HomeModel.offersGlobal($0)) }
    }

    // MARK: Strip menu and actions

    @ViewBuilder private func stripMenu(_ spec: ShelfSpec) -> some View {
        Button("Rename…") { beginRename(spec) }
        if spec.smartRule != nil { Button("Edit Rules…") { editRules(spec) } }
        Button("Duplicate") { duplicate(spec) }
        if let pin = PinnedStore.spec(for: spec) {
            Button(pins.contains(pin.id) ? "Unpin from Sidebar" : "Pin to Sidebar") { pins.toggle(pin) }
        }
        Divider()
        Button("Move to Top") { move(spec.id, to: 0) }.disabled(specs.first?.id == spec.id)
        Button("Move Up") { selected = spec.id; moveSelected(-1) }.disabled(specs.first?.id == spec.id)
        Button("Move Down") { selected = spec.id; moveSelected(1) }.disabled(specs.last?.id == spec.id)
        Button("Move to Bottom") { move(spec.id, to: specs.count - 1) }.disabled(specs.last?.id == spec.id)
        Divider()
        Button(spec.hidden ? "Show on Home" : "Hide from Home") { toggleHidden(spec.id) }
        Button(spec.smartRule != nil ? "Delete Smart Shelf" : "Remove from Home", role: .destructive) { remove(spec.id) }
    }

    /// The same actions for VoiceOver, named on the strip itself.
    private func actions(_ spec: ShelfSpec) -> [(String, () -> Void)] {
        var list: [(String, () -> Void)] = [
            (spec.hidden ? "Show on Home" : "Hide from Home", { toggleHidden(spec.id) }),
            ("Move Up", { selected = spec.id; moveSelected(-1) }),
            ("Move Down", { selected = spec.id; moveSelected(1) }),
            ("Rename", { beginRename(spec) }),
        ]
        if spec.smartRule != nil { list.append(("Edit Rules", { editRules(spec) })) }
        list.append((spec.smartRule != nil ? "Delete Smart Shelf" : "Remove from Home", { remove(spec.id) }))
        return list
    }

    private func handle(_ action: AppCommandCenter.ShelfAction) {
        guard let id = selected, let spec = specs.first(where: { $0.id == id }) else { return }
        switch action {
        case .moveUp: moveSelected(-1)
        case .moveDown: moveSelected(1)
        case .toggleHidden: toggleHidden(id)
        case .rename: open(spec)
        case .remove: remove(id)
        default: break
        }
    }

    // MARK: Words

    private func title(of spec: ShelfSpec?) -> String {
        guard let spec else { return "Shelf" }
        if !spec.title.isEmpty { return spec.title }
        return model.resolved[spec.id]?.title ?? spec.smartRule?.summary ?? "Shelf"
    }

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
        case .watchlist:
            parts.append("Watchlist")
        case .smart(let rule):
            parts.append("Smart")
            parts.append(rule.summary)
        }
        if let n = shelf?.items.count, n > 0, spec.smartRule == nil { parts.append(n == 1 ? "1 title" : "\(n) titles") }
        return parts.joined(separator: " · ")
    }

    // MARK: Changes (each one undoable)

    /// Applies a change to the layout and registers its undo (and redo).
    private func change(_ name: String, animated: Bool = true, _ body: () -> Void) {
        let before = specs
        if animated { withAnimation(Theme.Motion.object(reduceMotion), body) } else { body() }
        registerUndo(name, restoring: before)
    }

    private func registerUndo(_ name: String, restoring snapshot: [ShelfSpec]) {
        let current = specs
        undoManager?.registerUndo(withTarget: UndoBox.shared) { _ in
            MainActor.assumeIsolated {
                withAnimation(Theme.Motion.object(reduceMotion)) { specs = snapshot }
                registerUndo(name, restoring: current)
            }
        }
        undoManager?.setActionName(name)
    }

    private func step(_ delta: Int) {
        guard !specs.isEmpty else { return }
        let i = specs.firstIndex { $0.id == selected } ?? (delta > 0 ? -1 : specs.count)
        selected = specs[min(max(0, i + delta), specs.count - 1)].id
        if let s = specs.first(where: { $0.id == selected }) {
            AccessibilityNotification.Announcement("\(title(of: s)), \(sourceLine(s))").post()
        }
    }

    private func moveSelected(_ delta: Int) {
        guard let id = selected, let i = specs.firstIndex(where: { $0.id == id }) else { return }
        move(id, to: min(max(0, i + delta), specs.count - 1))
    }

    private func move(_ id: String, to target: Int) {
        guard let i = specs.firstIndex(where: { $0.id == id }), i != target else { return }
        // One assignment: two mutations through a binding in one transaction read a stale array
        // (the second sees the first undone), which duplicated the shelf.
        var list = specs
        list.insert(list.remove(at: i), at: target)
        change("Move Shelf") { specs = list }
        AccessibilityNotification.Announcement("\(title(of: specs[target])) moved to position \(target + 1) of \(specs.count)").post()
    }

    private func toggleHidden(_ id: String) {
        guard let i = specs.firstIndex(where: { $0.id == id }) else { return }
        change(specs[i].hidden ? "Show Shelf" : "Hide Shelf") { specs[i].hidden.toggle() }
        AccessibilityNotification.Announcement(specs[i].hidden ? "\(title(of: specs[i])) hidden" : "\(title(of: specs[i])) shown").post()
    }

    private func remove(_ id: String) {
        guard let i = specs.firstIndex(where: { $0.id == id }) else { return }
        let name = title(of: specs[i])
        var list = specs
        list.remove(at: i)
        change("Remove Shelf") { specs = list }
        selected = specs.isEmpty ? nil : specs[min(i, specs.count - 1)].id
        AccessibilityNotification.Announcement("\(name) removed. Command-Z undoes it.").post()
    }

    private func add(_ source: ShelfSpec.Source, title: String) {
        let spec = ShelfSpec(title: title, source: source)
        change("Add Shelf") { specs = specs + [spec] }
    }

    private func duplicate(_ spec: ShelfSpec) {
        guard let i = specs.firstIndex(where: { $0.id == spec.id }) else { return }
        var copy = spec
        copy.id = UUID().uuidString
        copy.title = title(of: spec) + " Copy"
        var list = specs
        list.insert(copy, at: i + 1)
        change("Duplicate Shelf") { specs = list }
    }

    private func reset() {
        change("Restore Default Shelves") { specs = defaults }
        selected = specs.first?.id
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
        let name = renameText.trimmingCharacters(in: .whitespaces)
        change("Rename Shelf", animated: false) { specs[i].title = name }
        renaming = nil
    }

    // MARK: Drag

    /// SwiftUI gives a drag no end callback; a drag cancelled outside the strips (Esc, dropped
    /// on the desktop) would leave its strip lifted. Watch the mouse button instead.
    private func beginDrag(_ id: String) {
        dragging = id
        dragStart = specs
        selected = id
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            while NSEvent.pressedMouseButtons != 0 { try? await Task.sleep(for: .milliseconds(100)) }
            endDrag()
        }
    }

    private func endDrag() {
        withAnimation(Theme.Motion.quick) { dragging = nil }
        if let start = dragStart, start != specs { registerUndo("Move Shelf", restoring: start) }
        dragStart = nil
    }
}

/// The undo target: the layout lives in SwiftUI state, so undo closures capture it themselves.
@MainActor
private final class UndoBox {
    static let shared = UndoBox()
}

extension UTType {
    /// A shelf being dragged inside Edit Shelves (never leaves the app).
    static let mezzanineShelf = UTType(exportedAs: "com.mezzanine.mac.shelf", conformingTo: .data)
}

/// One folded shelf: grip, name and source, a peek of its first posters, show switch, menu.
private struct ShelfStrip<MenuContent: View>: View {
    let spec: ShelfSpec
    let shelf: Shelf?
    let sourceLine: String
    let isSelected: Bool
    let isDragging: Bool
    /// Nil under Reduce Motion: the fold becomes a plain crossfade.
    let peek: Namespace.ID?
    let select: () -> Void
    let toggleHidden: () -> Void
    let actions: [(String, () -> Void)]
    @ViewBuilder let menu: () -> MenuContent

    @Environment(SessionStore.self) private var session
    @Environment(LibraryStore.self) private var library
    @State private var hovering = false
    @State private var gripHovering = false
    /// A control inside the strip has keyboard focus (Full Keyboard Access): the strip is selected.
    @FocusState private var inner: Part?

    enum Part: Hashable { case toggle, menu }

    private var title: String {
        if !spec.title.isEmpty { return spec.title }
        return shelf?.title ?? spec.smartRule?.summary ?? "Shelf"
    }

    private var fill: Color {
        if isSelected || isDragging { return Theme.raisedHover }
        return hovering ? Theme.raised.mix(with: Theme.raisedHover, by: 0.5) : Theme.raised
    }

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(gripHovering ? Theme.inkSecondary : Theme.inkTertiary)
                .frame(width: 22, height: 44)
                .contentShape(Rectangle())
                .onHover { inside in
                    gripHovering = inside
                    if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
                }
                .help("Drag to reorder (or ⌥↑ / ⌥↓)")
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Theme.Typeface.cardTitle)
                    .foregroundStyle(isSelected ? Theme.lilac : Theme.ink)
                    .opacity(spec.hidden ? 0.6 : 1)
                    .lineLimit(1)
                Text(sourceLine)
                    .font(Theme.Typeface.cardMeta)
                    .foregroundStyle(spec.hidden ? Theme.inkTertiary : Theme.inkSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Theme.Space.l)
            HStack(spacing: 4) {
                ForEach(Array((shelf?.items ?? []).prefix(5))) { item in
                    RemoteImage(url: session.posterURL(library.posterPath(for: item), pixelWidth: 96), pixelWidth: 96)
                        .frame(width: 32, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .modifier(FoldMatch(fold: peek.map { FoldID(id: "\(spec.id)-\(item.ratingKey)", namespace: $0) }))
                }
            }
            .saturation(spec.hidden ? 0 : 1)
            .opacity(spec.hidden ? 0.45 : 1)
            .accessibilityHidden(true)
            Toggle("Show on Home", isOn: Binding(get: { !spec.hidden }, set: { _ in toggleHidden() }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .focusEffectDisabled(false)
                .focused($inner, equals: .toggle)
                .help(spec.hidden ? "Show on Home (Space)" : "Hide from Home (Space)")
            Menu(content: menu) {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .focusEffectDisabled(false)
            .focused($inner, equals: .menu)
            .foregroundStyle(Theme.inkSecondary)
            .help("Rename, move, edit rules or remove")
            .accessibilityLabel("More for \(title)")
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(height: 72)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous).fill(fill))
        // Lifted while dragged or selected, in the posters' own lift-and-shadow grammar.
        .shadow(color: .black.opacity(isDragging ? 0.6 : (isSelected ? 0.35 : 0)), radius: isDragging ? 22 : 10, y: isDragging ? 14 : 4)
        .scaleEffect(isDragging ? 1.02 : 1)
        .animation(Theme.Motion.lift, value: isDragging)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onChange(of: inner) { _, part in if part != nil { select() } }
        .contextMenu(menuItems: menu)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(sourceLine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .modifier(StripActions(actions: actions))
    }
}

/// Attaches each named action for VoiceOver (Move Up, Rename, Remove…).
private struct StripActions: ViewModifier {
    let actions: [(String, () -> Void)]
    func body(content: Content) -> some View {
        actions.reduce(AnyView(content)) { view, action in
            AnyView(view.accessibilityAction(named: Text(action.0), action.1))
        }
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
        var list = specs
        list.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        withAnimation(animation) { specs = list }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        withAnimation(Theme.Motion.quick) { dragging = nil }
        return true
    }
}
