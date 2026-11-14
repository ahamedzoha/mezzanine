import SwiftUI
import MezzanineKit

/// What the menu bar can ask the window to do. Menu commands and views share
/// this object, so every keyboard shortcut also has a visible menu item (HIG).
@MainActor
@Observable
final class AppCommandCenter {
    /// Video libraries, for the Go menu (⌘2…⌘9).
    var sections: [PlexLibrarySection] = []
    var selection: SidebarItem? = .home
    /// Bumped by Edit ▸ Find (⌘F); the toolbar search field takes focus.
    private(set) var searchRequests = 0
    /// Bumped by View ▸ Larger/Smaller Posters; the visible grid applies it.
    private(set) var densitySteps: (count: Int, delta: Double) = (0, 0)
    /// Bumped when the content area should take keyboard focus.
    private(set) var contentFocusRequests = 0

    func requestSearch() { searchRequests += 1 }
    func focusContent() { contentFocusRequests += 1 }

    func stepDensity(_ delta: Double) {
        densitySteps = (densitySteps.count + 1, delta)
    }

    func go(to item: SidebarItem) {
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
        }
        CommandGroup(after: .toolbar) {
            Button("Larger Posters") { center.stepDensity(20) }
                .keyboardShortcut("=", modifiers: .command)
            Button("Smaller Posters") { center.stepDensity(-20) }
                .keyboardShortcut("-", modifiers: .command)
            Divider()
        }
        CommandMenu("Go") {
            Button("Home") { center.go(to: .home) }
                .keyboardShortcut("1", modifiers: .command)
            ForEach(Array(center.sections.prefix(8).enumerated()), id: \.element.key) { index, section in
                Button(section.title) { center.go(to: .library(section.key)) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 2))), modifiers: .command)
            }
        }
    }
}
