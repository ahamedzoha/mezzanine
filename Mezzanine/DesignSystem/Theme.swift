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
    /// Increase Contrast resolves it to full ink at draw time.
    static let inkSecondary = contrastAware(normal: NSColor(white: 0.949, alpha: 0.66), increased: NSColor(white: 0.949, alpha: 1))
    static let inkTertiary = contrastAware(normal: NSColor(white: 0.949, alpha: 0.46), increased: NSColor(white: 0.949, alpha: 0.85))
    /// The one accent: primary action and current selection only.
    static let lilac = Color(hex: 0xA08CFF)
    /// Type set on lilac.
    static let onLilac = Color(hex: 0x0E0F11)
    /// Hairlines (the ruled caption, separators).
    static let rule = contrastAware(normal: NSColor(white: 0.949, alpha: 0.14), increased: NSColor(white: 0.949, alpha: 0.4))

    /// A colour that follows Increase Contrast when it is drawn (AppKit's
    /// high-contrast appearances), so nothing has to rebuild to pick it up.
    private static func contrastAware(normal: NSColor, increased: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua, .darkAqua, .aqua])
                .map { $0.rawValue.contains("HighContrast") } == true ? increased : normal
        })
    }

    // MARK: Shape & space

    enum Radius {
        static let badge: CGFloat = 4
        static let control: CGFloat = 8
        static let poster: CGFloat = 12
        static let still: CGFloat = 12
        /// Floating control panels (the player HUD).
        static let panel: CGFloat = 16
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

    /// Text styles, so the type follows macOS's Text Size setting (Accessibility ▸
    /// Display); sizes in comments are the defaults. Glyphs inside fixed-size discs keep
    /// point sizes.
    enum Typeface {
        /// Room messages (empty, error, loading states). 22 pt.
        static let messageTitle = Font.system(.title, weight: .semibold)
        /// Shelf and section titles. 17 pt.
        static let shelfTitle = Font.system(.title2, weight: .semibold)
        /// Card and row titles. 13 pt.
        static let cardTitle = Font.system(.body, weight: .semibold)
        /// Facts under titles. 12 pt, tabular digits.
        static let cardMeta = Font.system(.callout).monospacedDigit()
        /// Ruled captions. 13 pt, tabular digits.
        static let caption = Font.system(.body, weight: .medium).monospacedDigit()
        /// Summaries and running text. 13 pt.
        static let body = Font.system(.body)
        /// Long-form reading (a title's summary, taglines). 15 pt.
        static let reading = Font.system(.title3)
        static let button = Font.system(.body, weight: .semibold)
        /// A card's headline (Up Next, failure panels). 17 pt.
        static let cardHeadline = Font.system(.title2, weight: .semibold)
    }

    // MARK: Motion

    enum Motion {
        /// The room's light following focus.
        static let light = Animation.easeOut(duration: 0.32)
        /// Objects moving (posters lifting, the stage opening). No bounce.
        static let object = Animation.spring(response: 0.26, dampingFraction: 1)
        static let quick = Animation.easeOut(duration: 0.16)
        /// Pointer lift: immediate, short, no bounce.
        static let lift = Animation.spring(response: 0.18, dampingFraction: 1)
        /// How long the pointer rests on a poster before the room and hero follow it.
        /// The card itself lifts at once; only the expensive change waits.
        static let hoverDwell: Duration = .milliseconds(120)

        /// Object motion, or a plain crossfade when Reduce Motion is on.
        static func object(_ reduceMotion: Bool) -> Animation {
            reduceMotion ? .easeOut(duration: 0.2) : object
        }
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
