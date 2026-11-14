import SwiftUI
import AetherEngine

/// The video picture. The engine swaps the hosted layer per session
/// (`AVPlayerLayer` on the native path, `AVSampleBufferDisplayLayer` on the
/// software path), so this view never needs to know which is active.
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
