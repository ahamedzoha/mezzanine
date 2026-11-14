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
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers = []
            if let window {
                observers.append(NotificationCenter.default.addObserver(
                    forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main
                ) { [weak self] _ in MainActor.assumeIsolated { self?.apply() } })
            }
            apply()
        }

        private func apply() {
            guard let window else { return }
            window.titlebarAppearsTransparent = chromeHidden
            window.titleVisibility = chromeHidden ? .hidden : .visible
            window.toolbar?.isVisible = !(chromeHidden && hidesToolbar)
            window.titlebarSeparatorStyle = chromeHidden ? .none : .automatic
            applyFullScreenOptions(window)
        }

        /// In full screen AppKit keeps the title/toolbar strip as an opaque band over the
        /// top of the content, even with the toolbar hidden. While the player owns the
        /// window, let it slide away with the menu bar (pointer at the top edge shows both).
        private func applyFullScreenOptions(_ window: NSWindow) {
            guard window.styleMask.contains(.fullScreen) else { return }
            var options = NSApp.presentationOptions
            guard options.contains(.fullScreen) else { return }
            if chromeHidden && hidesToolbar {
                options.formUnion([.autoHideMenuBar, .autoHideToolbar])
            } else {
                options.remove(.autoHideToolbar)
            }
            if options != NSApp.presentationOptions { NSApp.presentationOptions = options }
        }
    }
}
