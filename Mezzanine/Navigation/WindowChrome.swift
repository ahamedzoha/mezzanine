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
        var hidesToolbar = false { didSet { if hidesToolbar != oldValue { apply() } } }
        var chromeHidden = false { didSet { if chromeHidden != oldValue { apply() } } }
        private var observers: [NSObjectProtocol] = []
        private var toolbarWatch: NSKeyValueObservation?
        private weak var watchedToolbar: NSToolbar?
        private weak var watchedStrip: NSWindow?
        private var stripObservers: [NSObjectProtocol] = []
        private var watchdog: Timer?

        /// The film owns the window: no toolbar, no title bar strip.
        private var playerOwns: Bool { chromeHidden && hidesToolbar }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers = []
            if window == nil { stopWatching() }
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
            #if DEBUG
            // -ChromeTrace YES: logs the full-screen title-bar strip twice a second.
            if UserDefaults.standard.bool(forKey: "ChromeTrace"), window != nil, trace == nil {
                trace = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
                    guard self != nil else { timer.invalidate(); return }
                    MainActor.assumeIsolated { self?.logStrip() }
                }
            }
            // -ToolbarDriftAfter 14: re-shows the toolbar (and the strip's contents) behind the
            // player's back, as SwiftUI or AppKit sometimes do; the watch should undo it.
            let drift = UserDefaults.standard.integer(forKey: "ToolbarDriftAfter")
            if drift > 0, window != nil {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(drift))
                    guard let window = self?.window else { return }
                    print("CHROME drift: toolbar shown")
                    window.toolbar?.isVisible = true
                    let button = window.standardWindowButton(.closeButton)
                    button?.superview?.superview?.isHidden = false
                    if let strip = button?.window, strip !== window { strip.alphaValue = 1; strip.ignoresMouseEvents = false }
                    window.titlebarAppearsTransparent = false
                    window.titleVisibility = .visible
                }
            }
            #endif
        }

        #if DEBUG
        private var trace: Timer?
        private var lastTrace = ""
        private func logStrip() {
            guard let window, let button = window.standardWindowButton(.closeButton) else { return }
            let strip = button.window
            let container = button.superview?.superview
            let line = "CHROME fs=\(window.styleMask.contains(.fullScreen)) hidden=\(chromeHidden) tb=\(window.toolbar?.isVisible ?? false) "
                + "strip=\(strip === window ? "self" : String(describing: type(of: strip!))) alpha=\(strip?.alphaValue ?? -1) "
                + "vis=\(strip?.isVisible ?? false) occl=\(strip?.occlusionState.contains(.visible) ?? false) frame=\(strip.map { NSStringFromRect($0.frame) } ?? "-") "
                + "container=\(container.map { String(describing: type(of: $0)) } ?? "-") cHidden=\(container?.isHidden ?? false) "
                + "opts=\(NSApp.presentationOptions.rawValue) cur=\(NSApp.currentSystemPresentationOptions.rawValue)"
            if line != lastTrace { print(line); lastTrace = line }
        }
        #endif

        private func apply() {
            guard let window else { return }
            window.titlebarAppearsTransparent = chromeHidden
            window.titleVisibility = chromeHidden ? .hidden : .visible
            if let toolbar = window.toolbar, toolbar.isVisible == playerOwns { toolbar.isVisible = !playerOwns }
            window.titlebarSeparatorStyle = chromeHidden ? .none : .automatic
            applyFullScreenOptions(window)
            hideFullScreenTitleBar(window)
            watch(window)
            #if DEBUG
            if trace != nil { print("CHROME apply opts=\(NSApp.presentationOptions.rawValue)"); lastTrace = "" }
            #endif
        }

        // MARK: Keeping it hidden

        /// SwiftUI and AppKit both re-show the toolbar on their own schedule (a toolbar rebuild,
        /// a full-screen transition, the menu bar sliding in). In full screen a shown toolbar is
        /// pinned as an opaque 52 pt band over the top of the film, covering the logo, until
        /// something re-applies (switching Spaces did). So while the film owns the window in
        /// full screen, re-apply when the toolbar's visibility or the full-screen strip
        /// changes, and check once a second besides.
        private func watch(_ window: NSWindow) {
            if watchedToolbar !== window.toolbar {
                watchedToolbar = window.toolbar
                toolbarWatch = window.toolbar?.observe(\.isVisible) { [weak self] _, _ in
                    // After AppKit's own update finishes, never inside it.
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.reapplyIfDrifted() } }
                }
            }
            let strip = window.standardWindowButton(.closeButton)?.window
            let stripWindow = strip === window ? nil : strip
            if watchedStrip !== stripWindow {
                stripObservers.forEach { NotificationCenter.default.removeObserver($0) }
                stripObservers = []
                watchedStrip = stripWindow
                if let stripWindow {
                    let names = [NSWindow.didResizeNotification, NSWindow.didMoveNotification, NSWindow.didChangeOcclusionStateNotification]
                    for name in names {
                        stripObservers.append(NotificationCenter.default.addObserver(forName: name, object: stripWindow, queue: .main) { [weak self] _ in
                            MainActor.assumeIsolated { self?.reapplyIfDrifted() }
                        })
                    }
                }
            }
            if playerOwns, watchdog == nil {
                watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
                    guard self != nil else { timer.invalidate(); return }
                    MainActor.assumeIsolated { self?.reapplyIfDrifted() }
                }
            } else if !playerOwns {
                watchdog?.invalidate()
                watchdog = nil
            }
        }

        /// Full screen only: in a window the re-shown toolbar is masked (transparent, items
        /// hidden), and hiding it again there would resize the window by 20 pt each time.
        private func reapplyIfDrifted() {
            guard playerOwns, let window, window.styleMask.contains(.fullScreen) else { return }
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "ChromeWatchOff") { return }  // shows the bug, for comparison
            #endif
            let button = window.standardWindowButton(.closeButton)
            let toolbarShown = window.toolbar?.isVisible == true
            let stripShown = button?.superview?.superview?.isHidden == false
                || !window.titlebarAppearsTransparent || window.titleVisibility != .hidden
            // AppKit or SwiftUI swapped in a new strip window or toolbar: it starts out shown.
            let replaced = window.toolbar !== watchedToolbar || (button?.window === window ? nil : button?.window) !== watchedStrip
            guard toolbarShown || stripShown || replaced else { return }
            #if DEBUG
            if trace != nil { print("CHROME drifted toolbar=\(toolbarShown) strip=\(stripShown) replaced=\(replaced): re-applying") }
            #endif
            apply()
        }

        private func stopWatching() {
            watchdog?.invalidate()
            watchdog = nil
            toolbarWatch = nil
            watchedToolbar = nil
            stripObservers.forEach { NotificationCenter.default.removeObserver($0) }
            stripObservers = []
            watchedStrip = nil
            #if DEBUG
            trace?.invalidate()
            trace = nil
            #endif
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

/// Tells the app when the main window becomes or stops being key, and when it closes, so
/// bare-letter player shortcuts never fire while typing in Settings or a sheet, and closing
/// the window stops a playing film instead of leaving it playing with no window.
struct MainWindowWatcher: NSViewRepresentable {
    let keyChanged: (Bool) -> Void
    let willClose: () -> Void

    func makeNSView(context: Context) -> WatcherView { WatcherView() }

    func updateNSView(_ view: WatcherView, context: Context) {
        view.keyChanged = keyChanged
        view.willClose = willClose
    }

    final class WatcherView: NSView {
        var keyChanged: ((Bool) -> Void)?
        var willClose: (() -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers = []
            guard let window else { return }
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.keyChanged?(true) }
            })
            observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.keyChanged?(false) }
            })
            observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.willClose?() }
            })
            keyChanged?(window.isKeyWindow)
        }
    }
}
