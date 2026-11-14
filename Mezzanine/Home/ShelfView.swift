import SwiftUI
import MezzanineKit

/// One horizontal row of posters.
struct ShelfView: View {
    let shelf: Shelf
    let row: Int
    /// The focused column when this shelf holds focus.
    let focusedColumn: Int?
    let onFocus: (Int) -> Void
    let onPlay: (PlexMetadata) -> Void

    static let posterWidth: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(shelf.title)
                .font(Theme.Typeface.shelfTitle)
                .foregroundStyle(Theme.ink)
                .padding(.leading, Theme.Space.gutter)
                .accessibilityAddTraits(.isHeader)

            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: Theme.Space.l) {
                        ForEach(Array(shelf.items.enumerated()), id: \.element.ratingKey) { column, item in
                            PosterCard(item: item, width: Self.posterWidth, isFocused: focusedColumn == column,
                                       onFocus: { onFocus(column) }, onPlay: { onPlay(item) })
                                .id(column)
                        }
                    }
                    .padding(.horizontal, Theme.Space.gutter)
                    // Room for the focused card's lift and shadow.
                    .padding(.vertical, Theme.Space.m)
                }
                .scrollIndicators(.never)
                .scrollClipDisabled()
                .onChange(of: focusedColumn) { _, column in
                    guard let column else { return }
                    withAnimation(Theme.Motion.object) { proxy.scrollTo(column) }
                }
            }
            .padding(.vertical, -Theme.Space.m)
        }
    }
}

/// A poster with its title and one line of facts below it.
///
/// Focus (keyboard, or the pointer resting on it) lifts the card and sets
/// its title in lilac; the room's light follows. Double-click plays.
struct PosterCard: View {
    let item: PlexMetadata
    let width: CGFloat
    let isFocused: Bool
    let onFocus: () -> Void
    let onPlay: () -> Void

    @Environment(SessionStore.self) private var session
    @State private var dwell: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            poster
            VStack(alignment: .leading, spacing: 2) {
                Text(Format.displayTitle(item))
                    .font(Theme.Typeface.cardTitle)
                    .foregroundStyle(isFocused ? Theme.lilac : Theme.ink)
                    .lineLimit(1)
                Text(Format.cardSubtitle(item))
                    .font(Theme.Typeface.cardMeta)
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1)
            }
            .frame(width: width, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onHover { inside in
            dwell?.cancel()
            guard inside, !isFocused else { return }
            dwell = Task {
                try? await Task.sleep(for: Theme.Motion.hoverDwell)
                if !Task.isCancelled { onFocus() }
            }
        }
        .onTapGesture(count: 2) { onPlay() }
        .onTapGesture { onFocus() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Play") { onPlay() }
        .contextMenu {
            Button("Play") { onPlay() }
        }
    }

    private var poster: some View {
        let pixelWidth = Int(width * 2)
        return RemoteImage(url: session.posterURL(item.posterPath, pixelWidth: pixelWidth), pixelWidth: pixelWidth)
            .frame(width: width, height: width * 1.5)
            .overlay(alignment: .bottom) { progress }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous)
                    .strokeBorder(Theme.ink.opacity(isFocused ? 0.28 : 0.06), lineWidth: 1)
            }
            .shadow(color: .black.opacity(isFocused ? 0.55 : 0.25), radius: isFocused ? 22 : 8, y: isFocused ? 14 : 4)
            .scaleEffect(isFocused ? 1.045 : 1, anchor: .bottom)
            .offset(y: isFocused ? -4 : 0)
            .animation(Theme.Motion.object, value: isFocused)
    }

    @ViewBuilder private var progress: some View {
        if let p = item.progress {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.black.opacity(0.55))
                    Capsule().fill(Theme.ink).frame(width: max(4, geo.size.width * p))
                }
            }
            .frame(height: 3)
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
    }
}
