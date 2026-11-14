import SwiftUI
import MezzanineKit

/// An image from the Plex server, decoded at the size it's shown.
///
/// An image already in memory shows on the first frame (no flash when
/// scrolling back). Otherwise the placeholder shows until it loads, then the
/// image resolves in (a short blur-to-sharp fade). No spinners: hundreds of
/// animating spinners cost real CPU in a grid.
struct RemoteImage: View {
    let url: URL?
    var pixelWidth: Int
    var contentMode: ContentMode = .fill
    var placeholder: Color = Theme.raised
    var alignment: Alignment = .center

    @Environment(SessionStore.self) private var session
    @State private var loaded: CGImage?
    @State private var loadedURL: URL?
    @State private var arrived = false

    var body: some View {
        let image = shownImage
        ZStack(alignment: alignment) {
            placeholder
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: contentMode)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
                    .blur(radius: arrived ? 0 : 6)
                    .opacity(arrived ? 1 : 0)
            }
        }
        .clipped()
        .task(id: url) { await load() }
    }

    private var shownImage: CGImage? {
        if let loaded, loadedURL == url { return loaded }
        guard let url else { return nil }
        return session.images.cachedImage(for: url, pixelSize: pixelWidth)
    }

    private func load() async {
        guard let url else { return }
        if session.images.cachedImage(for: url, pixelSize: pixelWidth) != nil {
            arrived = true
            return
        }
        arrived = false
        do {
            let image = try await session.images.image(for: url, pixelSize: pixelWidth)
            loaded = image
            loadedURL = url
            withAnimation(.easeOut(duration: 0.28)) { arrived = true }
        } catch {
            // Missing art (404) leaves the placeholder.
        }
    }
}

/// A clear logo (transparent PNG) drawn without a placeholder fill.
struct LogoImage<Fallback: View>: View {
    let url: URL?
    var pixelWidth: Int
    @ViewBuilder var fallback: () -> Fallback

    @Environment(SessionStore.self) private var session
    @State private var loaded: CGImage?
    @State private var loadedURL: URL?
    @State private var failed = false

    var body: some View {
        Group {
            if let image = shown {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .transition(.opacity)
            } else if failed || url == nil {
                fallback()
            } else {
                Color.clear
            }
        }
        .task(id: url) { await load() }
    }

    private var shown: CGImage? {
        if let loaded, loadedURL == url { return loaded }
        guard let url else { return nil }
        return session.images.cachedImage(for: url, pixelSize: pixelWidth)
    }

    private func load() async {
        failed = false
        guard let url, session.images.cachedImage(for: url, pixelSize: pixelWidth) == nil else { return }
        do {
            let image = try await session.images.image(for: url, pixelSize: pixelWidth)
            withAnimation(.easeOut(duration: 0.2)) {
                loaded = image
                loadedURL = url
            }
        } catch is CancellationError {
        } catch {
            failed = true
        }
    }
}
