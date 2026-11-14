import SwiftUI
import AppKit

/// Hides the window's title bar chrome (title, toolbar, toolbar material)
/// while a film plays and during onboarding. SwiftUI can hide toolbar items,
/// but AppKit still draws the title bar strip above SwiftUI content, so this
/// reaches the hosting NSWindow directly. Applied when the view joins its
/// window and on every change.
struct WindowChrome: NSViewRepresentable {
    let hidden: Bool
    /// Also hide the toolbar (and with it the window buttons). Only the player does this.
    var hidesToolbar = false

    func makeNSView(context: Context) -> ChromeView { ChromeView() }

    func updateNSView(_ view: ChromeView, context: Context) {
        view.hidesToolbar = hidesToolbar
        view.chromeHidden = hidden
    }

    final class ChromeView: NSView {
        var hidesToolbar = false
        var chromeHidden = false { didSet { if chromeHidden != oldValue { apply() } } }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        private func apply() {
            guard let window else { return }
            window.titlebarAppearsTransparent = chromeHidden
            window.titleVisibility = chromeHidden ? .hidden : .visible
            window.toolbar?.isVisible = !(chromeHidden && hidesToolbar)
            window.titlebarSeparatorStyle = chromeHidden ? .none : .automatic
        }
    }
}
