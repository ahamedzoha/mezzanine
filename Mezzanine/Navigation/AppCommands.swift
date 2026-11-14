import SwiftUI
import MezzanineKit

/// What the menu bar can ask the window to do, and what the window tells the
/// menu bar (so items enable only when they can act). Every keyboard shortcut
/// in Mezzanine has a menu item here (HIG); single-key aliases handled by the
/// views (J/K/L, arrows) are listed in the same menus.
@MainActor
@Observable
final class AppCommandCenter {
    /// Video libraries, for the Go menu (⌘2…⌘9).
    var sections: [PlexLibrarySection] = []
    var selection: SidebarItem? = .home {
        didSet { if selection != oldValue { query = ""; path = [] } }
    }
    /// Detail pages pushed over the current section.
    var path: [DetailRoute] = []
    /// Toolbar search text. Choosing a sidebar item or a Go item clears it.
    var query = ""

    // State reported by the window.
    var isSignedIn = false
    var isPlayerOpen = false
    var isSearchFieldFocused = false
    /// The visible content has a focused title that Play would start.
    var hasFocusedTitle = false
    var isLibraryVisible: Bool {
        if case .library = selection, query.isEmpty { return true }
        return false
    }
    var isHomeVisible: Bool { selection == .home && query.isEmpty }

    // Requests from the menu bar; views observe the counters.
    private(set) var searchRequests = 0
    private(set) var densitySteps: (count: Int, delta: Double) = (0, 0)
    private(set) var contentFocusRequests = 0
    private(set) var playFocusedRequests = 0
    private(set) var detailsRequests = 0
    private(set) var playerRequests: (count: Int, action: PlayerAction) = (0, .togglePlay)
    private(set) var sidebarFocusRequests = 0
    private(set) var enclosingFolderRequests = 0
    /// View ▸ Layout / Sort By, applied by the visible library.
    private(set) var layoutRequest: (count: Int, layout: String) = (0, "")
    private(set) var sortRequest: (count: Int, sort: String) = (0, "")
    /// The visible library's current layout and sort (for menu checkmarks).
    var currentLayout: String?
    var currentSort: String?
    var isFolderBrowserVisible = false

    enum PlayerAction { case togglePlay, back, forward, skipMarker, close }

    func requestSearch() { searchRequests += 1 }
    func focusContent() { contentFocusRequests += 1 }
    func stepDensity(_ delta: Double) { densitySteps = (densitySteps.count + 1, delta) }
    func playFocused() { playFocusedRequests += 1 }
    func toggleDetails() { detailsRequests += 1 }
    func player(_ action: PlayerAction) { playerRequests = (playerRequests.count + 1, action) }
    func focusSidebar() { sidebarFocusRequests += 1 }
    func enclosingFolder() { enclosingFolderRequests += 1 }
    func setLayout(_ raw: String) { layoutRequest = (layoutRequest.count + 1, raw) }
    func setSort(_ raw: String) { sortRequest = (sortRequest.count + 1, raw) }

    func go(to item: SidebarItem) {
        query = ""
        selection = item
        path = []
        focusContent()
    }

    /// Opens a title's page. Episodes open their show; seasons open as themselves.
    func open(_ item: PlexMetadata) {
        let key = item.kind == .episode ? (item.grandparentRatingKey ?? item.ratingKey) : item.ratingKey
        guard path.last?.ratingKey != key else { return }
        path.append(DetailRoute(ratingKey: key))
        focusContent()
    }

    func goBack() {
        guard !path.isEmpty else { return }
        path.removeLast()
        focusContent()
    }

    /// The visible content has a focused title that Open would show.
    var canGoBack: Bool { !path.isEmpty }
}

struct MezzanineCommands: Commands {
    let center: AppCommandCenter
    let sound: SoundSettings

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Find…") { center.requestSearch() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(!center.isSignedIn || center.isPlayerOpen)
        }
        CommandGroup(after: .toolbar) {
            Button("Show Details") { center.toggleDetails() }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(!center.isHomeVisible || center.isPlayerOpen)
            Button("Larger Posters") { center.stepDensity(20) }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(!center.isLibraryVisible || center.isPlayerOpen)
            Button("Smaller Posters") { center.stepDensity(-20) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(!center.isLibraryVisible || center.isPlayerOpen)
            Menu("Layout") {
                ForEach(Array(LibraryLayout.allCases.enumerated()), id: \.element) { i, layout in
                    Button(layout.label) { center.setLayout(layout.rawValue) }
                        .keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: [.control, .command])
                        .disabled(layout == .folders && center.currentLayout == nil)
                }
            }
            .disabled(!center.isLibraryVisible || center.isPlayerOpen)
            Menu("Sort By") {
                ForEach(LibraryQuery.Sort.allCases, id: \.self) { sort in
                    Button(sort.label) { center.setSort(sort.rawValue) }
                }
            }
            .disabled(!center.isLibraryVisible || center.isPlayerOpen || center.isFolderBrowserVisible)
            Divider()
        }
        CommandMenu("Go") {
            Button("Back") { center.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!center.canGoBack || center.isPlayerOpen)
            Button("Enclosing Folder") { center.enclosingFolder() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(!center.isFolderBrowserVisible || center.isPlayerOpen)
            Divider()
            Button("Home") { center.go(to: .home) }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(!center.isSignedIn || center.isPlayerOpen)
            ForEach(Array(center.sections.prefix(8).enumerated()), id: \.element.key) { index, section in
                Button(section.title) { center.go(to: .library(section.key)) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 2))), modifiers: .command)
                    .disabled(center.isPlayerOpen)
            }
        }
        CommandMenu("Playback") {
            if center.isPlayerOpen {
                Button("Play/Pause") { center.player(.togglePlay) }
                    .keyboardShortcut(.space, modifiers: [])
                Button("Back 10 Seconds") { center.player(.back) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button("Forward 10 Seconds") { center.player(.forward) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                Button("Skip Intro or Credits") { center.player(.skipMarker) }
                    .keyboardShortcut("s", modifiers: [])
                Divider()
                Button("Volume Up") { sound.stepVolume(10) }
                    .keyboardShortcut(.upArrow, modifiers: [])
                Button("Volume Down") { sound.stepVolume(-10) }
                    .keyboardShortcut(.downArrow, modifiers: [])
                Toggle("Dialogue Boost", isOn: Binding(get: { sound.current.profile.dialogueGainDB > 0 }, set: { _ in sound.toggleDialogue() }))
                    .keyboardShortcut("d", modifiers: [])
                Toggle("Night Mode", isOn: Binding(get: { sound.current.profile.nightMode }, set: { _ in sound.toggleNight() }))
                    .keyboardShortcut("n", modifiers: .option)
                Divider()
                Button("Close Player") { center.player(.close) }
                    .keyboardShortcut(.escape, modifiers: [])
                Divider()
                Text("Also: K play/pause · J back · L forward · F full screen · ↑ ↓ volume to 400 %")
            }
            Divider()
            Menu("Sound Profile for \(sound.deviceName)") {
                Picker("Profile", selection: Binding(get: { sound.current.kind }, set: { sound.setKind($0) })) {
                    ForEach([AudioOutputKind.builtInSpeakers, .headphones, .speakers21, .airPods, .hdmi, .other], id: \.self) {
                        Text($0.label).tag($0)
                    }
                }
                .pickerStyle(.inline)
            }
            if !center.isPlayerOpen {
                Button("Play") { center.playFocused() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!center.hasFocusedTitle || !center.isSignedIn)
                Divider()
                Text("Also: Space plays the focused title; Return opens it")
            }
        }
    }
}
