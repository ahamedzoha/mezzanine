import SwiftUI
import AppKit

/// Hides the window's title bar chrome while a film plays. SwiftUI can hide the
/// toolbar's items and background, but AppKit still draws the title bar strip
/// (and the content column's scroll-edge material) above SwiftUI content, so
/// the player would show a band across its top. This reaches the hosting
/// NSWindow and makes the title bar fully transparent for the duration.
struct WindowChrome: NSViewRepresentable {
    let hidden: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        // The window is attached after the first layout pass.
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titlebarAppearsTransparent = hidden
            window.titleVisibility = hidden ? .hidden : .visible
            window.toolbar?.isVisible = !hidden
            window.titlebarSeparatorStyle = hidden ? .none : .automatic
        }
    }
}
