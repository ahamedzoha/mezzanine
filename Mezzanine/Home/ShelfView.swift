import SwiftUI
import MezzanineKit

/// One horizontal row of posters.
struct ShelfView: View {
    let shelf: Shelf
    let row: Int
    /// The focused column when this shelf holds focus.
    let focusedColumn: Int?
    /// Scroll the focused card into view (keyboard moves only; hovering never scrolls).
    let scrollsToFocus: Bool
    let onFocus: (Int) -> Void
    let onPlay: (PlexMetadata, CGRect) -> Void
    var onOpen: ((PlexMetadata) -> Void)? = nil
    /// Edit Home's fold: the first posters morph into the shelf strip's peek.
    var fold: Namespace.ID? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppCommandCenter.self) private var commands
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
                                       onFocus: { onFocus(column) }, onPlay: { frame in onPlay(item, frame) },
                                       onOpen: { (onOpen ?? commands.open)(item) },
                                       fold: column < 5 ? fold.map { FoldID(id: "\(shelf.id)-\(column)", namespace: $0) } : nil)
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
                    guard let column, scrollsToFocus else { return }
                    withAnimation(Theme.Motion.object(reduceMotion)) { proxy.scrollTo(column) }
                }
            }
            .padding(.vertical, -Theme.Space.m)
        }
    }
}

/// A poster with its title and one line of facts below it.
///
/// Focus (keyboard, or the pointer resting on it) lifts the card, sets its
/// title in lilac and shows a Play button on it; the room's light follows.
/// No ring: lift, shadow and the room carry focus. Double-click also plays.
struct PosterCard: View {
    let item: PlexMetadata
    let width: CGFloat
    let isFocused: Bool
    let onFocus: () -> Void
    let onPlay: (CGRect) -> Void
    let onOpen: () -> Void
    var fold: FoldID? = nil

    @Environment(SessionStore.self) private var session
    @Environment(LibraryStore.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dwell: Task<Void, Never>?
    @State private var frame: CGRect = .zero
    @State private var hovering = false

    /// Lifted while focused or under the pointer (the pointer gets an instant response).
    private var lifted: Bool { isFocused || hovering }

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
        .modifier(CardInteraction(item: item, frame: frame, isFocused: isFocused, hovering: $hovering, dwell: $dwell,
                                  onFocus: onFocus, onOpen: onOpen, onPlay: onPlay))
        .task(id: item.ratingKey) { await library.resolveCleanPoster(for: item) }
    }

    private var poster: some View {
        let pixelWidth = Int(width * 2)
        return RemoteImage(url: session.posterURL(library.posterPath(for: item), pixelWidth: pixelWidth), pixelWidth: pixelWidth)
            .frame(width: width, height: width * 1.5)
            .modifier(FoldMatch(fold: fold))
            .overlay(alignment: .bottom) { progress }
            .overlay(alignment: .bottomTrailing) {
                if lifted { PlayDisc { onPlay(frame) }.padding(10).transition(.opacity) }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous))
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
            .shadow(color: .black.opacity(lifted ? 0.6 : 0.3), radius: lifted ? 22 : 8, y: lifted ? 14 : 4)
            .scaleEffect(lifted && !reduceMotion ? 1.045 : 1, anchor: .bottom)
            .offset(y: lifted && !reduceMotion ? -4 : 0)
            .animation(reduceMotion ? .easeOut(duration: 0.15) : Theme.Motion.lift, value: lifted)
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
            .padding(.bottom, lifted ? 54 : 10)
        }
    }
}

/// Ties a poster to its peek in Edit Home's strip, so the shelf folds into the strip and back.
struct FoldID {
    let id: String
    let namespace: Namespace.ID
}

struct FoldMatch: ViewModifier {
    let fold: FoldID?
    func body(content: Content) -> some View {
        if let fold { content.matchedGeometryEffect(id: fold.id, in: fold.namespace) } else { content }
    }
}

/// The pointer's way to play a focused poster: a solid disc, fully clickable.
struct PlayDisc: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "play.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.graphite)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Theme.ink))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled(false)
        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
        .help("Play")
        .accessibilityLabel("Play")
    }
}
