import SwiftUI
import MezzanineKit

/// The four corner colours of a title's artwork (Plex's UltraBlur), as the
/// light that title throws into the room.
struct RoomPalette: Equatable {
    var topLeft: Color
    var topRight: Color
    var bottomLeft: Color
    var bottomRight: Color

    /// The room with nothing on screen.
    static let dark = RoomPalette(topLeft: Theme.graphite, topRight: Theme.graphite,
                                  bottomLeft: Theme.graphite, bottomRight: Theme.graphite)

    init(topLeft: Color, topRight: Color, bottomLeft: Color, bottomRight: Color) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomLeft = bottomLeft
        self.bottomRight = bottomRight
    }

    init?(_ colors: UltraBlurColors?) {
        guard let colors,
              let tl = Color(hexString: colors.topLeft), let tr = Color(hexString: colors.topRight),
              let bl = Color(hexString: colors.bottomLeft), let br = Color(hexString: colors.bottomRight) else { return nil }
        // Bias light, not neon: pull every corner a quarter of the way back to
        // the room's graphite so saturated art tints the room instead of flooding it.
        let calm = { (c: Color) in c.mix(with: Theme.graphite, by: 0.25) }
        self.init(topLeft: calm(tl), topRight: calm(tr), bottomLeft: calm(bl), bottomRight: calm(br))
    }
}

/// Bias lighting behind the whole window: the focused title's corner colours
/// washed across graphite, crossfading as focus moves.
///
/// Kept deliberately low: it is the light a film throws on a wall, not a
/// glow. The lower part of the room falls back to graphite so posters and
/// type always sit on a dark, steady ground. Reduce Transparency lowers it
/// further; Reduce Motion keeps the crossfade (a fade is not motion).
struct RoomLight: View {
    var palette: RoomPalette
    /// 0…1. The player turns the lights down to 0.
    var intensity: Double = 1

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            Theme.graphite
            MeshGradient(width: 2, height: 2,
                         points: [[0, 0], [1, 0], [0, 1], [1, 1]],
                         colors: [palette.topLeft, palette.topRight, palette.bottomLeft, palette.bottomRight])
                .opacity((reduceTransparency ? 0.36 : 0.74) * intensity)
            // The floor of the room stays graphite: shelves read on a steady ground.
            LinearGradient(stops: [
                .init(color: Theme.graphite.opacity(0), location: 0),
                .init(color: Theme.graphite.opacity(0.12), location: 0.5),
                .init(color: Theme.graphite.opacity(0.62), location: 1),
            ], startPoint: .top, endPoint: .bottom)
        }
        .animation(Theme.Motion.light, value: palette)
        .animation(.easeInOut(duration: 0.6), value: intensity)
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}
