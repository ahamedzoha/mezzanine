import SwiftUI
import MezzanineKit

/// The focused title, large: its backdrop fading into the room, its logo,
/// one ruled caption naming every part, and the primary action.
struct HeroView: View {
    let item: PlexMetadata
    @Binding var showsDetails: Bool
    let play: () -> Void

    @Environment(SessionStore.self) private var session

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                backdrop(width: geo.size.width)
                    .frame(width: geo.size.width * 0.74, height: geo.size.height)
                    .mask(fade)
                    .frame(maxWidth: .infinity, alignment: .trailing)

                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    title
                        .frame(maxWidth: min(560, geo.size.width * 0.5), maxHeight: 150, alignment: .bottomLeading)
                    caption
                    actions
                    if showsDetails { details.transition(.opacity.combined(with: .move(edge: .bottom))) }
                }
                .padding(.leading, Theme.Space.gutter)
                .padding(.bottom, Theme.Space.s)
                .frame(maxWidth: geo.size.width * 0.62, alignment: .leading)
            }
        }
        .id(item.ratingKey)
        .transition(.opacity)
        .animation(Theme.Motion.light, value: item.ratingKey)
    }

    // MARK: Parts

    private func backdrop(width: CGFloat) -> some View {
        RemoteImage(url: session.backdropURL(item.backdropPath, pixelWidth: Int(width * 0.74 * 2)),
                    pixelWidth: Int(width * 0.74 * 2), placeholder: .clear, alignment: .top)
    }

    /// The backdrop dissolves leftwards into the room and downwards into the shelves.
    private var fade: some View {
        ZStack {
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black.opacity(0.55), location: 0.32),
                .init(color: .black, location: 0.62),
            ], startPoint: .leading, endPoint: .trailing)
        }
        .mask(LinearGradient(stops: [
            .init(color: .black, location: 0),
            .init(color: .black, location: 0.55),
            .init(color: .clear, location: 1),
        ], startPoint: .top, endPoint: .bottom))
    }

    @ViewBuilder private var title: some View {
        LogoImage(url: session.logoURL(item.clearLogoPath), pixelWidth: 1200) {
            Text(Format.displayTitle(item).uppercased())
                .font(TitleFont.font(size: 92))
                .tracking(-1)
                .lineLimit(2)
                .minimumScaleFactor(0.5)
                .foregroundStyle(Theme.ink)
        }
        .accessibilityLabel(Format.displayTitle(item))
        .accessibilityAddTraits(.isHeader)
    }

    /// One hairline over one line of facts: the programme caption.
    private var caption: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Rectangle().fill(Theme.rule).frame(width: 48, height: 1)
            Text(Format.heroCaption(item))
                .font(Theme.Typeface.caption)
                .foregroundStyle(Theme.inkSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var actions: some View {
        HStack(spacing: Theme.Space.m) {
            Button(action: play) {
                Label(primaryLabel, systemImage: "play.fill")
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
            .help("Play (Return)")

            Button {
                withAnimation(Theme.Motion.object) { showsDetails.toggle() }
            } label: {
                Text(showsDetails ? "Less" : "Details")
            }
            .buttonStyle(SecondaryButtonStyle())
            .help("Details (I)")
        }
    }

    private var primaryLabel: String {
        let resuming = (item.viewOffset ?? 0) > 0
        switch item.kind {
        case .episode:
            let code = Format.episodeCode(item) ?? ""
            return (resuming ? "Resume " : "Play ") + code
        case .show, .season:
            return "Play"
        default:
            return resuming ? "Resume" : "Play"
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if let summary = item.summary, !summary.isEmpty {
                Text(summary)
                    .font(Theme.Typeface.body)
                    .foregroundStyle(Theme.ink.opacity(0.86))
                    .lineLimit(5)
                    .frame(maxWidth: 560, alignment: .leading)
            }
            let facts = [
                item.genres.prefix(3).map(\.tag).joined(separator: ", "),
                item.directors.first.map { "Directed by \($0.tag)" } ?? "",
                item.roles.prefix(3).map(\.tag).joined(separator: ", "),
            ].filter { !$0.isEmpty }
            if !facts.isEmpty {
                Text(facts.joined(separator: " · "))
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(2)
            }
        }
    }
}

// MARK: - Buttons

/// Lilac capsule: the one primary action on a screen. The whole capsule is the target.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Typeface.button)
            .foregroundStyle(Theme.onLilac)
            .padding(.horizontal, 18)
            .frame(height: 34)
            .background(Capsule().fill(Theme.lilac.opacity(configuration.isPressed ? 0.82 : 1)))
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.5)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Theme.Motion.quick, value: configuration.isPressed)
    }
}

/// Solid raised capsule (never translucent over art).
struct SecondaryButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Typeface.button)
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 16)
            .frame(height: 34)
            .background(Capsule().fill(configuration.isPressed ? Theme.raisedHover : (hovering ? Theme.raisedHover : Theme.raised)))
            .contentShape(Capsule())
            .onHover { hovering = $0 }
            .animation(Theme.Motion.quick, value: hovering)
    }
}
