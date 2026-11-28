import SwiftUI
import MezzanineKit

/// Square album art, a round artist photo, or a playlist cover, drawn from the server at the size
/// it's shown. Fills the width it is given; clipped to the shape.
struct MusicArt: View {
    let path: String?
    var round = false
    var pixelWidth = 400
    var radius: CGFloat = Theme.Radius.poster

    @Environment(SessionStore.self) private var session

    var body: some View {
        RemoteImage(url: session.squareURL(path, pixelWidth: pixelWidth), pixelWidth: pixelWidth)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                // No picture on the server: a quiet note on the raised well, never a coloured stand-in.
                if path == nil {
                    Image(systemName: round ? "music.mic" : "music.note")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(Theme.inkTertiary)
                        .accessibilityHidden(true)
                }
            }
            .clipShape(round ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: radius, style: .continuous)))
    }
}

/// A sleeve in a grid or on a shelf: the cover, its title, and its facts when it is lifted.
///
/// The pointer lifts it at once; resting 120 ms (or the arrow keys) focuses it, which sets the title
/// in lilac, shows the play disc and moves the room's light to its colours. No ring. A click opens
/// the page; the disc plays. Artists are round, everything else square.
struct MusicCard: View {
    let item: PlexMetadata
    /// Nil fills the grid column.
    var width: CGFloat? = nil
    var pixelWidth = 420
    let isFocused: Bool
    let onFocus: () -> Void
    let onOpen: () -> Void
    let onPlay: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var dwell: Task<Void, Never>?

    private var lifted: Bool { isFocused || hovering }
    private var round: Bool { item.kind == .artist }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MusicArt(path: item.posterPath, round: round, pixelWidth: pixelWidth)
                .overlay(alignment: .bottomTrailing) {
                    if lifted { PlayDisc(action: onPlay).padding(10).transition(.opacity) }
                }
                .contrastFocusOutline(isFocused, radius: round ? 200 : Theme.Radius.poster)
                .shadow(color: .black.opacity(lifted ? 0.6 : 0.3), radius: lifted ? 22 : 8, y: lifted ? 14 : 4)
                .scaleEffect(lifted && !reduceMotion ? 1.04 : 1, anchor: .bottom)
                .offset(y: lifted && !reduceMotion ? -4 : 0)
                .animation(reduceMotion ? .easeOut(duration: 0.15) : Theme.Motion.lift, value: lifted)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.kind == .track ? MusicFormat.songTitle(item.title) : item.title)
                    .font(.system(.callout, weight: .semibold))
                    .foregroundStyle(isFocused ? Theme.lilac : Theme.inkSecondary)
                    .lineLimit(1)
                // At rest: whose it is. Lifted: every fact. The line's space is always kept.
                Text(lifted ? MusicFormat.cardMeta(item) : MusicFormat.cardRest(item))
                    .font(Theme.Typeface.cardMeta)
                    .foregroundStyle(Theme.inkTertiary)
                    .lineLimit(1)
                    .frame(minHeight: 14, alignment: .topLeading)
            }
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
        .help(([item.title] + MusicFormat.cardFacts(item)).joined(separator: " · "))
        .onHover { inside in
            withAnimation(Theme.Motion.lift) { hovering = inside }
            dwell?.cancel()
            guard inside, !isFocused else { return }
            dwell = Task {
                try? await Task.sleep(for: Theme.Motion.hoverDwell)
                if !Task.isCancelled { onFocus() }
            }
        }
        .onTapGesture(perform: onOpen)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(MusicFormat.spokenCard(item))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens")
        .accessibilityAction { onOpen() }
        .accessibilityAction(named: "Play") { onPlay() }
        .contextMenu { MusicContextMenu(item: item) }
    }
}

/// Play, Shuffle, Play Next, Play Later and the way to the artist: the pointer's path to every
/// Item menu entry, on any card or row.
struct MusicContextMenu: View {
    let item: PlexMetadata
    @Environment(MusicActions.self) private var actions

    var body: some View {
        Button("Play Now") { actions.play(item) }
        if item.kind != .track { Button("Play Shuffled") { actions.play(item, shuffled: true) } }
        Divider()
        Button("Play Next") { actions.playNext(item) }
        Button("Play Later") { actions.playLater(item) }
        if item.kind == .album || item.kind == .track {
            Divider()
            Button("Go to Artist") { actions.goToArtist(of: item) }
        }
        if item.kind == .track { Button("Go to Album") { actions.goToAlbum(of: item) } }
    }
}

/// One horizontal row of sleeves with a heading (a Plex row on the root, a discography group).
struct MusicShelf: View {
    let title: String
    let items: [PlexMetadata]
    /// Names this row for scrolling (a card's scroll id is the row and the item's key).
    let rowID: String
    var level: Level = .section
    var inset: CGFloat = Theme.Space.gutter
    var cardWidth: CGFloat = 150
    /// The page names the row itself (Similar Artists sits under its own section heading).
    var hidesTitle = false
    let focusedColumn: Int?
    var scrollsToFocus = false
    let onFocus: (Int) -> Void
    let onOpen: (PlexMetadata) -> Void
    let onPlay: (PlexMetadata) -> Void

    enum Level { case section, group }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: level == .section ? Theme.Space.s : 4) {
            if !hidesTitle {
                Text(title)
                    .font(level == .section ? Theme.Typeface.shelfTitle : .system(.body, weight: .medium))
                    .foregroundStyle(level == .section ? Theme.ink : Theme.inkSecondary)
                    .padding(.leading, inset)
                    .accessibilityAddTraits(.isHeader)
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: Theme.Space.l) {
                        ForEach(Array(items.enumerated()), id: \.element.ratingKey) { column, item in
                            MusicCard(item: item, width: cardWidth, pixelWidth: Int(cardWidth * 2), isFocused: focusedColumn == column,
                                      onFocus: { onFocus(column) }, onOpen: { onOpen(item) }, onPlay: { onPlay(item) })
                                .id("\(rowID)|\(item.ratingKey)")
                        }
                    }
                    .padding(.horizontal, inset)
                    // Room for the lifted card's shadow.
                    .padding(.vertical, Theme.Space.m)
                }
                .scrollIndicators(.never)
                .scrollClipDisabled()
                .onChange(of: focusedColumn) { _, column in
                    guard let column, scrollsToFocus, items.indices.contains(column) else { return }
                    withAnimation(Theme.Motion.object(reduceMotion)) { proxy.scrollTo("\(rowID)|\(items[column].ratingKey)") }
                }
            }
            .padding(.vertical, -Theme.Space.m)
        }
    }
}

/// A play glyph in the ink, for the playing song: the level meter that moves while it plays and
/// holds still when paused or when Reduce Motion is on.
struct PlayingGlyph: View {
    let isPlaying: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: "waveform")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.ink)
            .symbolEffect(.variableColor.iterative, isActive: isPlaying && !reduceMotion)
            .accessibilityLabel(isPlaying ? "Playing" : "Paused")
    }
}

/// What the page's play button, Shuffle and ⋯ look like on an album, artist or playlist page.
struct MusicPageButtons: View {
    let item: PlexMetadata
    var showsMenu = true
    /// The sleeve column's width. Shuffle shows its word when the whole row fits it, else only
    /// its icon (measured, not guessed from the window).
    let width: CGFloat
    @Environment(MusicActions.self) private var actions

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(compact: false)
            row(compact: true)
        }
        .frame(width: width, alignment: .leading)
    }

    private func row(compact: Bool) -> some View {
        HStack(spacing: 6) {
            Button { actions.play(item) } label: {
                Label("Play", systemImage: "play.fill").labelStyle(.titleAndIcon).lineLimit(1)
            }
            .buttonStyle(PrimaryButtonStyle())
            .help("Play (⌘↩)")
            Button { actions.play(item, shuffled: true) } label: {
                if compact { Image(systemName: "shuffle") } else { Label("Shuffle", systemImage: "shuffle").labelStyle(.titleAndIcon).lineLimit(1) }
            }
            .buttonStyle(SecondaryButtonStyle())
            .help("Play Shuffled (\(MusicShortcuts.shared.display(.shufflePlay)))")
            .accessibilityLabel("Shuffle")
            if showsMenu {
                Menu {
                    MusicContextMenu(item: item)
                } label: {
                    Image(systemName: "ellipsis").frame(width: 34, height: 34).contentShape(Circle())
                        .background(Circle().fill(Theme.raised))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More Actions")
                .accessibilityLabel("More Actions")
            }
        }
        .fixedSize()
    }
}

/// The ruled caption: a 48 pt hairline, then lines of facts joined by " · " in tabular figures.
/// A fact never breaks inside; a line wraps only between facts.
struct MusicCaption: View {
    let lines: [[String]]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.filter { !$0.isEmpty }.enumerated()), id: \.offset) { _, facts in
                FactsLine(facts: facts, font: Theme.Typeface.caption, color: Theme.inkSecondary)
            }
        }
        .padding(.top, Theme.Space.m)
        .overlay(alignment: .topLeading) { Rectangle().fill(Theme.rule).frame(width: 48, height: 1) }
    }
}

/// Facts joined by " · " that wrap only between facts, and never leave a "·" at the end of a line
/// or the start of the next: where a line breaks, the separator is not drawn.
struct FactsLine: View {
    let facts: [String]
    var font: Font = Theme.Typeface.caption
    var color: Color = Theme.inkSecondary

    var body: some View {
        FactsFlowLayout {
            ForEach(Array(facts.enumerated()), id: \.offset) { index, fact in
                if index > 0 {
                    Text("·").padding(.horizontal, 5).layoutValue(key: FactSeparatorKey.self, value: true)
                        .accessibilityHidden(true)
                }
                Text(fact).fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(font)
        .foregroundStyle(color)
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(facts.joined(separator: ", "))
    }
}

private struct FactSeparatorKey: LayoutValueKey {
    nonisolated static let defaultValue = false
}

private nonisolated struct FactsFlowLayout: Layout {
    private struct Arrangement {
        var frames: [CGRect] = []
        var size: CGSize = .zero
    }

    private func arrange(_ subviews: Subviews, width maxWidth: CGFloat) -> Arrangement {
        var out = Arrangement()
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        var index = 0
        out.frames = Array(repeating: .zero, count: subviews.count)
        while index < subviews.count {
            let view = subviews[index]
            if view[FactSeparatorKey.self] {
                // A separator and the fact after it travel together, or the separator is dropped at a wrap.
                let sep = view.sizeThatFits(.unspecified)
                let fact = subviews[index + 1].sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
                if x + sep.width + fact.width <= maxWidth + 0.5 {
                    out.frames[index] = CGRect(origin: CGPoint(x: x, y: y), size: sep)
                    x += sep.width
                } else {
                    // Off to the side and clipped: not drawn at a wrap.
                    out.frames[index] = CGRect(x: -10_000, y: y, width: sep.width, height: sep.height)
                    widest = max(widest, x)
                    x = 0
                    y += lineHeight
                    lineHeight = 0
                }
                out.frames[index + 1] = CGRect(origin: CGPoint(x: x, y: y), size: fact)
                x += fact.width
                lineHeight = max(lineHeight, fact.height)
                index += 2
            } else {
                let fact = view.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
                out.frames[index] = CGRect(origin: CGPoint(x: x, y: y), size: fact)
                x += fact.width
                lineHeight = max(lineHeight, fact.height)
                index += 1
            }
        }
        out.size = CGSize(width: max(widest, x), height: y + lineHeight)
        return out
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrange(subviews, width: bounds.width)
        for (view, frame) in zip(subviews, layout.frames) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                       proposal: ProposedViewSize(frame.size))
        }
    }
}
