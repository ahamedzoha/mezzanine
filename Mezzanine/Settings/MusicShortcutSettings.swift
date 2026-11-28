import SwiftUI
import AppKit

/// Settings ▸ Shortcuts ▸ Music: the keys of the Controls menu and the Music items of the Item
/// menu, each changeable the way the player's are (click a key, press the new one). Unlike the
/// player's, these are menu keys: they need ⌘ or ⌥ so they never fire while typing.
struct MusicShortcutSections: View {
    private var shortcuts: MusicShortcuts { .shared }
    @State private var recording: Recording?
    @State private var monitor: Any?
    @State private var windowObservers: [NSObjectProtocol] = []
    @State private var note: (action: MusicKey, text: String)?
    @State private var confirmRestore = false

    struct Recording: Equatable {
        let action: MusicKey
        let replacing: KeyBinding?
    }

    var body: some View {
        Section {
            LabeledContent {
                Button("Restore Defaults…") { confirmRestore = true }
                    .disabled(!shortcuts.isCustomized)
                    .confirmationDialog("Restore the default music keys?", isPresented: $confirmRestore) {
                        Button("Restore Defaults", role: .destructive) {
                            stopRecording()
                            note = nil
                            shortcuts.resetAll()
                        }
                    } message: {
                        Text("Every music key you changed goes back to how it came.")
                    }
            } label: {
                Text("Music")
                Text("Menu keys for the Music library and its Now Playing bar: they live in the Controls and Item menus and need ⌘ or ⌥. Click a key to change it; while it waits, ⌫ removes it and Esc cancels.")
            }
        }
        // Section ids repeat the player's group names ("Playback"): a Form drops the second one.
        ForEach(MusicKey.Group.allCases, id: \.title) { group in
            Section(group.title) {
                // Titled ids: the raw values repeat the player's own (play pause, volume), and a Form drops such rows.
                ForEach(MusicKey.allCases.filter { $0.group == group }, id: \.menuTitle) { row($0) }
            }
        }
    }

    // MARK: Rows

    private func row(_ action: MusicKey) -> some View {
        LabeledContent {
            HStack(spacing: 6) {
                ForEach(shortcuts.bindings(action), id: \.self) { keyCap($0, action: action) }
                addButton(action)
                Button { restore(action) } label: {
                    Image(systemName: "arrow.uturn.backward").font(.caption.weight(.semibold))
                        .frame(width: 24, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Restore the default (\(action.defaultBindings.map(\.display).joined(separator: " or ")))")
                .accessibilityLabel("Restore the default for \(action.menuTitle)")
                .opacity(shortcuts.isCustomized(action) ? 1 : 0)
                .disabled(!shortcuts.isCustomized(action))
                .accessibilityHidden(!shortcuts.isCustomized(action))
            }
        } label: {
            Text(action.menuTitle)
            if let note, note.action == action { Text(note.text) }
        }
        .contextMenu {
            Button("Restore Default") { restore(action) }.disabled(!shortcuts.isCustomized(action))
        }
    }

    private func keyCap(_ binding: KeyBinding, action: MusicKey) -> some View {
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
        .accessibilityLabel("\(action.menuTitle): \(binding.display)")
        .accessibilityValue(isRecording ? "Recording" : "")
        .accessibilityHint(isRecording ? "Press the new key, Delete to remove it, or Escape to cancel" : "Press to change this key")
        .accessibilityAddTraits(isRecording ? .isSelected : [])
    }

    private func addButton(_ action: MusicKey) -> some View {
        let target = Recording(action: action, replacing: nil)
        let isRecording = recording == target
        return Button { isRecording ? stopRecording() : startRecording(target) } label: {
            if isRecording { waitingLabel } else {
                Image(systemName: "plus").font(.caption.weight(.semibold)).frame(width: 24, height: 22)
                    .foregroundStyle(.secondary).contentShape(Rectangle())
            }
        }
        .buttonStyle(.borderless)
        .help(isRecording ? "Press the new key. Esc cancels." : "Add a key for \(action.menuTitle.lowercased())")
        .accessibilityLabel("Add a key for \(action.menuTitle)")
        .accessibilityValue(isRecording ? "Recording" : "")
        .accessibilityAddTraits(isRecording ? .isSelected : [])
    }

    private var waitingLabel: some View {
        Text("Press a key…")
            .font(.callout)
            .padding(.horizontal, 8)
            .frame(minHeight: 22)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor, lineWidth: 1.5))
    }

    private func restore(_ action: MusicKey) {
        stopRecording()
        note = nil
        let moved = shortcuts.restore(action)
        if !moved.isEmpty { say("Moved back from \(moved.map { "“\($0.menuTitle)”" }.formatted()).", on: action) }
    }

    // MARK: Recording

    private func startRecording(_ target: Recording) {
        stopRecording()
        note = nil
        guard let window = NSApp.keyWindow else { return }
        recording = target
        // The monitor sees the key before the menus do, so ⌘ keys are caught here while it waits.
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
        announce("\(verb) for \(target.action.menuTitle). Press the new key\(target.replacing == nil ? "" : ", Delete to remove it"), or Escape to cancel.")
    }

    private func stopRecording() {
        recording = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let target = recording else { return false }
        switch event.keyCode {
        case KeyBinding.escape: stopRecording(); return true
        case KeyBinding.tab: stopRecording(); return false
        case 51 where !event.modifierFlags.contains(.command), 117 where !event.modifierFlags.contains(.command):
            if let old = target.replacing { shortcuts.remove(old, from: target.action) }
            stopRecording(); return true
        default: break
        }
        guard let binding = KeyBinding(event, allowingCommand: true) else {
            say("That key can’t be used. Try a letter or an arrow with ⌘ or ⌥.", on: target.action)
            return true
        }
        if let reserved = MusicKey.reservation(binding) {
            say("\(binding.display): \(reserved).", on: target.action)
            return true
        }
        stopRecording()
        if let previous = shortcuts.assign(binding, to: target.action, replacing: target.replacing) {
            say("\(binding.display) moved here from “\(previous.menuTitle)”.", on: target.action)
        } else {
            announce("\(target.action.menuTitle): \(shortcuts.display(target.action))")
        }
        return true
    }

    private func say(_ text: String, on action: MusicKey) {
        note = (action, text)
        announce(text)
    }

    private func announce(_ text: String) { AccessibilityNotification.Announcement(text).post() }
}

/// The read-only list for the ⌘/ sheet.
struct MusicShortcutList: View {
    private var shortcuts: MusicShortcuts { .shared }

    var body: some View {
        // Section ids repeat the player's group names ("Playback"): a Form drops the second one.
        ForEach(MusicKey.Group.allCases, id: \.title) { group in
            Section(group.title) {
                ForEach(MusicKey.allCases.filter { $0.group == group }, id: \.menuTitle) { key in
                    LabeledContent(key.menuTitle) {
                        Text(shortcuts.display(key, separator: "  ")).font(.callout.weight(.medium)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
