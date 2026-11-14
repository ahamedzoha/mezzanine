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
                // Full screen moves the title bar into a window of its own, and AppKit resets
                // presentation options on its own schedule: re-apply whenever either can change.
                let names: [(Notification.Name, AnyObject?)] = [
                    (NSWindow.didEnterFullScreenNotification, window), (NSWindow.didExitFullScreenNotification, window),
                    (NSWindow.didBecomeKeyNotification, window), (NSWindow.didChangeScreenNotification, window),
                    (NSApplication.didBecomeActiveNotification, NSApp),
                ]
                for (name, object) in names {
                    observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.apply() }
                    })
                }
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
            hideFullScreenTitleBar(window)
        }

        /// In full screen the title bar lives in a separate AppKit window over the top of the
        /// screen. With the toolbar hidden it's an empty strip (from the sidebar's edge
        /// across), shown whenever AppKit pins it or the pointer reveals the menu bar. While
        /// the player owns the window it's hidden outright; the menu bar still slides in alone.
        private func hideFullScreenTitleBar(_ window: NSWindow) {
            let hide = chromeHidden && hidesToolbar && window.styleMask.contains(.fullScreen)
            guard let button = window.standardWindowButton(.closeButton) else { return }
            if let strip = button.window, strip !== window {
                strip.alphaValue = hide ? 0 : 1
                strip.ignoresMouseEvents = hide
            }
            if let container = button.superview?.superview, container.isHidden != hide, window.styleMask.contains(.fullScreen) || !hide {
                container.isHidden = hide
            }
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
