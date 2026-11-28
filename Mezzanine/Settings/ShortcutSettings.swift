import SwiftUI
import AppKit

/// Settings ▸ Shortcuts: every player key, each one changeable (click a key, press the
/// new one), then the fixed keys of the rest of the app for reference.
struct ShortcutSettings: View {
    private var shortcuts: PlayerShortcuts { .shared }
    @State private var recording: Recording?
    @State private var monitor: Any?
    @State private var windowObservers: [NSObjectProtocol] = []
    /// One line under the row just changed ("Moved from Mute").
    @State private var note: (action: PlayerKey, text: String)?
    @State private var confirmRestore = false

    struct Recording: Equatable {
        let action: PlayerKey
        /// The key being replaced; nil adds one.
        let replacing: KeyBinding?
    }

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Button("Restore Defaults…") { confirmRestore = true }
                        .disabled(!shortcuts.isCustomized)
                        .confirmationDialog("Restore the default player keys?", isPresented: $confirmRestore) {
                            Button("Restore Defaults", role: .destructive) {
                                stopRecording()
                                note = nil
                                shortcuts.restoreAll()
                            }
                        } message: {
                            Text("Every key you changed goes back to how it came.")
                        }
                } label: {
                    Text("Player")
                    Text("Click a key to change it; while it waits, ⌫ removes it and Esc cancels. Each key also appears in the Playback menu. On a MacBook, Page Up and Page Down are fn-↑ and fn-↓.")
                }
            }
            ForEach(PlayerKey.Group.allCases) { group in
                Section(group.rawValue) {
                    ForEach(PlayerKey.allCases.filter { $0.group == group }) { row($0) }
                    ForEach(ShortcutReference.fixedPlayerKeys(in: group), id: \.keys) { fixedRow($0.keys, $0.action) }
                }
            }
            MusicShortcutSections()
            ForEach(ShortcutReference.pages, id: \.title) { page in
                Section(page.title) {
                    ForEach(page.keys, id: \.keys) { fixedRow($0.keys, $0.action) }
                }
            }
            Section {
                ForEach(ShortcutReference.anywhere, id: \.keys) { fixedRow($0.keys, $0.action) }
            } header: {
                Text("Anywhere")
            } footer: {
                Text("Keys outside the player are fixed. Single keys never fire while you type in a field; Esc leaves the field.")
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 560, idealWidth: 640, minHeight: 480, idealHeight: 640)
        .onDisappear(perform: stopRecording)
    }

    // MARK: Rows

    private func row(_ action: PlayerKey) -> some View {
        LabeledContent {
            HStack(spacing: 6) {
                ForEach(shortcuts.bindings(action), id: \.self) { binding in
                    keyCap(binding, action: action)
                }
                addButton(action)
                Button { restore(action) } label: {
                    Image(systemName: "arrow.uturn.backward").font(.caption.weight(.semibold))
                        .frame(width: 24, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Restore the default (\(action.defaultBindings.map(\.display).joined(separator: " or ")))")
                .accessibilityLabel("Restore the default for \(action.label)")
                .opacity(shortcuts.isCustomized(action) ? 1 : 0)
                .disabled(!shortcuts.isCustomized(action))
                .accessibilityHidden(!shortcuts.isCustomized(action))
            }
        } label: {
            Text(action.label)
            if let note, note.action == action { Text(note.text) }
        }
        .contextMenu {
            Button("Restore Default") { restore(action) }
                .disabled(!shortcuts.isCustomized(action))
        }
    }

    /// One button per key: its label turns into "Press a key…" while it records, so
    /// VoiceOver and keyboard focus stay on it.
    private func keyCap(_ binding: KeyBinding, action: PlayerKey) -> some View {
        let target = Recording(action: action, replacing: binding)
        let isRecording = recording == target
        return Button { isRecording ? stopRecording() : startRecording(target) } label: {
            if isRecording { waitingLabel } else {
                Text(binding.display)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 8)
                    .frame(minWidth: 30, minHeight: 22)
                    .background(.quaternary, in: .rect(cornerRadius: 5))
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.primary)
        .help(isRecording ? "Press the new key. ⌫ removes it, Esc cancels." : "Click, then press a new key")
        .accessibilityLabel("\(action.label): \(binding.display)")
        .accessibilityValue(isRecording ? "Recording" : "")
        .accessibilityHint(isRecording ? "Press the new key, Delete to remove it, or Escape to cancel" : "Press to change this key")
        .accessibilityAddTraits(isRecording ? .isSelected : [])
    }

    private func addButton(_ action: PlayerKey) -> some View {
        let target = Recording(action: action, replacing: nil)
        let isRecording = recording == target
        return Button { isRecording ? stopRecording() : startRecording(target) } label: {
            if isRecording { waitingLabel } else {
                Image(systemName: "plus").font(.caption.weight(.semibold)).frame(width: 24, height: 22)
                    .foregroundStyle(.secondary).contentShape(Rectangle())
            }
        }
        .buttonStyle(.borderless)
        .help(isRecording ? "Press the new key. Esc cancels." : "Add a key for \(action.label.lowercased())")
        .accessibilityLabel("Add a key for \(action.label)")
        .accessibilityValue(isRecording ? "Recording" : "")
        .accessibilityHint(isRecording ? "Press the new key, or Escape to cancel" : "")
        .accessibilityAddTraits(isRecording ? .isSelected : [])
    }

    private var waitingLabel: some View {
        Text("Press a key…")
            .font(.callout)
            .padding(.horizontal, 8)
            .frame(minHeight: 22)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor, lineWidth: 1.5))
    }

    private func fixedRow(_ keys: String, _ action: String) -> some View {
        LabeledContent(action) {
            Text(keys).font(.callout.weight(.medium)).foregroundStyle(.secondary)
        }
    }

    private func restore(_ action: PlayerKey) {
        stopRecording()
        note = nil
        let moved = shortcuts.restore(action)
        if !moved.isEmpty {
            say("Moved back from \(moved.map { "“\($0.label)”" }.formatted()).", on: action)
        }
    }

    // MARK: Recording

    private func startRecording(_ target: Recording) {
        stopRecording()
        note = nil
        guard let window = NSApp.keyWindow else { return }
        recording = target
        // Only keys pressed in this window, and only while it's key: closing Settings
        // or clicking back into the player ends recording.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak window] event in
            nonisolated(unsafe) let event = event
            let used = MainActor.assumeIsolated { () -> Bool in
                guard let window, event.window === window, window.isKeyWindow else { return false }
                return handle(event)
            }
            return used ? nil : event
        }
        let center = NotificationCenter.default
        windowObservers = [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification].map { name in
            center.addObserver(forName: name, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { stopRecording() }
            }
        }
        let verb = target.replacing == nil ? "Adding a key" : "Recording a key"
        announce("\(verb) for \(target.action.label). Press the new key\(target.replacing == nil ? "" : ", Delete to remove it"), or Escape to cancel.")
    }

    private func stopRecording() {
        recording = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
    }

    /// - Returns: whether the key was used up here.
    private func handle(_ event: NSEvent) -> Bool {
        guard let target = recording else { return false }
        // ⌘ and ⌃ keys stay with the menus (⌘W still closes Settings).
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) { return false }
        switch event.keyCode {
        case KeyBinding.escape:
            stopRecording(); return true
        case KeyBinding.tab:
            stopRecording(); return false
        case 51, 117:                              // ⌫ ⌦
            if let old = target.replacing { shortcuts.remove(old, from: target.action) }
            stopRecording(); return true
        default: break
        }
        guard let binding = KeyBinding(event) else {
            say("That key can’t be used. Try a letter, an arrow, or one of those with ⌥ or ⇧.", on: target.action)
            return true
        }
        if let reserved = binding.reservation {
            say("\(binding.display) is taken: \(reserved).", on: target.action)
            return true
        }
        stopRecording()
        if let previous = shortcuts.assign(binding, to: target.action, replacing: target.replacing) {
            say("\(binding.display) moved here from “\(previous.label)”.", on: target.action)
        } else {
            announce("\(target.action.label): \(shortcuts.display(target.action))")
        }
        return true
    }

    private func say(_ text: String, on action: PlayerKey) {
        note = (action, text)
        announce(text)
    }

    private func announce(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }
}

/// The fixed keys, for Settings ▸ Shortcuts and Help ▸ Keyboard Shortcuts.
enum ShortcutReference {
    struct Entry { let keys: String; let action: String }
    struct Page { let title: String; let keys: [Entry] }

    static func fixedPlayerKeys(in group: PlayerKey.Group) -> [Entry] {
        switch group {
        case .playback: [.init(keys: "0 – 9", action: "Jump to 0–90 %")]
        case .episodes: [.init(keys: "Return", action: "Skip, or play Up Next now")]
        case .view: [.init(keys: "⌘⇧S", action: "Take a snapshot (Pictures ▸ Mezzanine)"),
                     .init(keys: "Esc", action: "Back out: panel, Up Next, full screen, then the player")]
        default: []
        }
    }

    static let pages: [Page] = [
        Page(title: "Home and libraries", keys: [
            .init(keys: "← → ↑ ↓", action: "Move between titles (with Full Keyboard Access too: Tab moves between the sidebar, toolbar and content)"),
            .init(keys: "Return", action: "Open"),
            .init(keys: "Space or ⌘Return", action: "Play"),
            .init(keys: "⌘I", action: "Show details (Home)"),
            .init(keys: "⌘= ⌘−", action: "Larger / smaller posters"),
            .init(keys: "⌃⌘1 – ⌃⌘5", action: "Posters, wide, list, folders, shelves"),
            .init(keys: "⌘↑", action: "Enclosing folder"),
        ]),
        Page(title: "Music pages", keys: [
            .init(keys: "← → ↑ ↓", action: "Move between covers and songs (← goes to the sidebar)"),
            .init(keys: "Return", action: "Open a cover; play the song in hand"),
            .init(keys: "Space", action: "Play the cover or song in hand; pause or resume what is playing"),
            .init(keys: "Home  End", action: "First / last"),
            .init(keys: "⌃⌘A  ⌃⌘B  ⌃⌘T  ⌃⌘P", action: "Artists, Albums, Songs, Playlists"),
            .init(keys: "Esc or ⌘[", action: "Back"),
        ]),
        Page(title: "Edit Shelves (⌘E)", keys: [
            .init(keys: "↑ ↓", action: "Select a shelf"),
            .init(keys: "⌥↑ ⌥↓", action: "Move it"),
            .init(keys: "Space", action: "Show or hide it"),
            .init(keys: "Return", action: "Rename, or edit a smart shelf’s rules"),
            .init(keys: "Delete", action: "Remove it (⌘Z undoes)"),
            .init(keys: "⌘N", action: "New smart shelf"),
            .init(keys: "Esc or ⌘E", action: "Done"),
        ]),
        Page(title: "Title pages", keys: [
            .init(keys: "↑ ↓", action: "Sections, and episodes in the list"),
            .init(keys: "⌥← ⌥→", action: "Previous / next season"),
            .init(keys: "Space", action: "Play or resume"),
            .init(keys: "Return", action: "Play the focused episode"),
            .init(keys: "W", action: "Watched (the focused or next episode)"),
            .init(keys: "⌥⌘P  ⌥⌘B", action: "Choose poster / background"),
            .init(keys: "Esc or ⌘[", action: "Back"),
        ]),
    ]

    static let anywhere: [Entry] = [
        .init(keys: "⌘K", action: "Quick Open: titles, places and actions"),
        .init(keys: "⌘F", action: "Find"),
        .init(keys: "⌘↩", action: "Play the focused title"),
        .init(keys: "W", action: "Watched or unwatched (the focused title on Home, in a library or in search)"),
        .init(keys: "⇧W", action: "Add to or remove from the watchlist"),
        .init(keys: "⌃⌘W", action: "Watchlist"),
        .init(keys: "⇧⌘R", action: "Surprise Me: a random unwatched title"),
        .init(keys: "⌥⌘A", action: "Show or hide activity"),
        .init(keys: "⌘[ ⌘]", action: "Back / forward"),
        .init(keys: "⌘1", action: "Home"),
        .init(keys: "⌘2 – ⌘9", action: "Libraries"),
        .init(keys: "⌥⌘L", action: "Downloads"),
        .init(keys: "⇧⌘D", action: "Download the title on screen"),
        .init(keys: "⌘⌫", action: "Remove its download"),
        .init(keys: "⌘/", action: "Keyboard shortcuts"),
        .init(keys: "⌘,", action: "Settings"),
        .init(keys: "⌘W  ⌘Q", action: "Close the window (stops a film) / quit"),
    ]
}

/// Help ▸ Keyboard Shortcuts (⌘/): every key on one page, read-only.
struct ShortcutsWindow: View {
    private var shortcuts: PlayerShortcuts { .shared }
    @Environment(\.openSettings) private var openSettings
    @AppStorage("settingsTab") private var settingsTab = "account"

    var body: some View {
        Form {
            ForEach(PlayerKey.Group.allCases) { group in
                Section("Player: \(group.rawValue)") {
                    ForEach(PlayerKey.allCases.filter { $0.group == group }) { key in
                        LabeledContent(key.label) {
                            Text(shortcuts.display(key, separator: "  ")).font(.callout.weight(.medium)).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(ShortcutReference.fixedPlayerKeys(in: group), id: \.keys) { entry in
                        LabeledContent(entry.action) { Text(entry.keys).font(.callout.weight(.medium)).foregroundStyle(.secondary) }
                    }
                }
            }
            MusicShortcutList()
            ForEach(ShortcutReference.pages, id: \.title) { page in
                Section(page.title) {
                    ForEach(page.keys, id: \.keys) { entry in
                        LabeledContent(entry.action) { Text(entry.keys).font(.callout.weight(.medium)).foregroundStyle(.secondary) }
                    }
                }
            }
            Section("Anywhere") {
                ForEach(ShortcutReference.anywhere, id: \.keys) { entry in
                    LabeledContent(entry.action) { Text(entry.keys).font(.callout.weight(.medium)).foregroundStyle(.secondary) }
                }
            }
        }
        .formStyle(.grouped)
        .toolbar {
            Button("Change Keys…") {
                settingsTab = "shortcuts"
                openSettings()
            }
            .help("Settings ▸ Shortcuts")
        }
        .frame(minWidth: 460, minHeight: 520)
    }
}
