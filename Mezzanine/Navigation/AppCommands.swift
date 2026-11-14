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
        didSet { if selection != oldValue { query = "" } }
    }
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

    enum PlayerAction { case togglePlay, back, forward, skipMarker, close }

    func requestSearch() { searchRequests += 1 }
    func focusContent() { contentFocusRequests += 1 }
    func stepDensity(_ delta: Double) { densitySteps = (densitySteps.count + 1, delta) }
    func playFocused() { playFocusedRequests += 1 }
    func toggleDetails() { detailsRequests += 1 }
    func player(_ action: PlayerAction) { playerRequests = (playerRequests.count + 1, action) }

    func go(to item: SidebarItem) {
        query = ""
        selection = item
        focusContent()
    }
}

struct MezzanineCommands: Commands {
    let center: AppCommandCenter

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
            Divider()
        }
        CommandMenu("Go") {
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
                Button("Close Player") { center.player(.close) }
                    .keyboardShortcut(.escape, modifiers: [])
                Divider()
                Text("Also: K play/pause · J back · L forward · F full screen")
            } else {
                Button("Play") { center.playFocused() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!center.hasFocusedTitle || !center.isSignedIn)
                Divider()
                Text("Also: Return or Space plays the focused title")
            }
        }
    }
}
