import SwiftUI
import AppKit
import CoreText

/// Bias Light: a near-black graphite room lit by the film on screen.
///
/// Chrome carries no colour of its own except one lilac, reserved for the
/// primary action and the current selection. Every other hue on screen
/// belongs to the films (artwork, and the room light derived from it).
enum Theme {
    // MARK: Colour

    /// The room: matte graphite, never pure black (pure black crushes the
    /// room light and makes posters look pasted on).
    static let graphite = Color(hex: 0x0E0F11)
    /// Raised surfaces: placeholders, menus, the poster well.
    static let raised = Color(hex: 0x1A1C20)
    static let raisedHover = Color(hex: 0x24272C)
    /// Type and icons.
    static let ink = Color(hex: 0xF2F2F0)
    /// Secondary type. 66 % ink on graphite ≈ 7:1, still AA over the room light.
    static let inkSecondary = Color(hex: 0xF2F2F0).opacity(0.66)
    static let inkTertiary = Color(hex: 0xF2F2F0).opacity(0.46)
    /// The one accent: primary action and current selection only.
    static let lilac = Color(hex: 0xA08CFF)
    /// Type set on lilac.
    static let onLilac = Color(hex: 0x0E0F11)
    /// Hairlines (the ruled caption, separators).
    static let rule = Color(hex: 0xF2F2F0).opacity(0.14)

    // MARK: Shape & space

    enum Radius {
        static let badge: CGFloat = 4
        static let control: CGFloat = 8
        static let poster: CGFloat = 12
        static let still: CGFloat = 12
    }

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 14
        static let l: CGFloat = 20
        static let xl: CGFloat = 32
        static let xxl: CGFloat = 48
        /// Leading inset of the content column (hero text and shelves align on it).
        static let gutter: CGFloat = 40
    }

    // MARK: Type

    enum Typeface {
        static let shelfTitle = Font.system(size: 17, weight: .semibold)
        static let cardTitle = Font.system(size: 13, weight: .semibold)
        static let cardMeta = Font.system(size: 12, weight: .regular).monospacedDigit()
        static let caption = Font.system(size: 13, weight: .medium).monospacedDigit()
        static let body = Font.system(size: 14, weight: .regular)
        static let button = Font.system(size: 14, weight: .semibold)
    }

    // MARK: Motion

    enum Motion {
        /// The room's light following focus.
        static let light = Animation.easeOut(duration: 0.45)
        /// Objects moving (posters lifting, the stage opening). No bounce.
        static let object = Animation.spring(response: 0.38, dampingFraction: 1)
        static let quick = Animation.easeOut(duration: 0.16)
        /// How long the pointer rests on a poster before the room follows it.
        static let hoverDwell: Duration = .milliseconds(220)
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }

    /// `"492013"` or `"#492013"` → Color. Plex's UltraBlur values.
    init?(hexString: String) {
        let s = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(hex: v)
    }
}

/// The display face for titles that have no clear logo: Big Shoulders
/// Display (OFL), bundled, used heavy and in capitals like a title card.
enum TitleFont {
    private static let postScriptName = "BigShouldersDisplay-Thin"
    private static let wghtAxis = 0x7767_6874 // 'wght'

    static func register() {
        guard let url = Bundle.main.url(forResource: "BigShouldersDisplay", withExtension: "ttf") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }

    static func font(size: CGFloat, weight: CGFloat = 800) -> Font {
        let descriptor = NSFontDescriptor(fontAttributes: [
            .name: postScriptName,
            .variation: [NSNumber(value: wghtAxis): NSNumber(value: Double(weight))],
        ])
        guard let font = NSFont(descriptor: descriptor, size: size) else {
            return .system(size: size, weight: .heavy, design: .default).width(.compressed)
        }
        return Font(font)
    }
}
