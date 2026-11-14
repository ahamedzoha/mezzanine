import SwiftUI
import AetherEngine

/// The video picture. The engine swaps the hosted layer per session
/// (`AVPlayerLayer` on the native path, `AVSampleBufferDisplayLayer` on the
/// software path), so this view never needs to know which is active.
///
/// The picture is an AppKit layer; a rounded picture paints `PictureCorners`
/// over it in the backdrop colour instead of relying on SwiftUI clipping.
public struct PlayerSurface: View {
    let player: MezzaninePlayer

    public init(player: MezzaninePlayer) {
        self.player = player
    }

    public var body: some View {
        AetherPlayerSurface(engine: player.engine)
            .background(Color.black)
    }
}

/// The four corners outside a continuous rounded rectangle, for painting over the
/// video in the colour behind it (fill with `eoFill`).
public struct PictureCorners: Shape {
    public var radius: CGFloat

    public init(radius: CGFloat) { self.radius = radius }

    public var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    public func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        path.addRoundedRect(in: rect, cornerSize: CGSize(width: radius, height: radius), style: .continuous)
        return path
    }
}
