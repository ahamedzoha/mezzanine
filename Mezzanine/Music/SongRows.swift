import SwiftUI
import MezzanineKit

/// Which columns a list of songs shows, and how wide each is, fitted to the room it has.
/// Numbers and times are tabular; the playing song's number is the level glyph.
struct SongColumns: Equatable {
    var art = false
    var artist = false
    var album = false
    var plays = true
    var quality = false
    var width: CGFloat

    static let number: CGFloat = 32, artSize: CGFloat = 28, time: CGFloat = 52, playsWidth: CGFloat = 60, qualityWidth: CGFloat = 104
    static let gap: CGFloat = 12

    /// An album's list: number, title, plays, time.
    static func album(width: CGFloat) -> SongColumns { SongColumns(plays: width >= 340, width: width) }
    /// An artist's Popular list: the album's list with a thumbnail.
    static func popular(width: CGFloat) -> SongColumns { SongColumns(art: true, plays: width >= 340, width: width) }
    /// The full table (Songs, playlists): columns drop as the room narrows, quality first.
    static func table(width: CGFloat) -> SongColumns {
        SongColumns(art: true, artist: true, album: width >= 560, plays: width >= 700, quality: width >= 860, width: width)
    }

    /// Width left for the title and the text columns after the fixed ones, the gaps and the row's padding.
    private var flexible: CGFloat {
        var fixed = Self.number + Self.time
        var items = 3
        if art { fixed += Self.artSize; items += 1 }
        if plays { fixed += Self.playsWidth; items += 1 }
        if quality { fixed += Self.qualityWidth; items += 1 }
        if artist { items += 1 }
        if album { items += 1 }
        return max(120, width - fixed - Self.gap * CGFloat(items - 1) - 24)
    }

    var titleWidth: CGFloat { flexible * (artist || album ? 0.4 : 1) }
    var artistWidth: CGFloat { flexible * (album ? 0.25 : 0.6) }
    var albumWidth: CGFloat { flexible * 0.35 }
}

/// One song in a list: pointer and keys play it with one action.
struct SongRowView: View {
    let song: PlexMetadata
    /// The number shown; nil shows the song's place in its album.
    var number: Int?
    var quality: String?
    let columns: SongColumns
    var height: CGFloat = 40
    let isFocused: Bool
    /// A single click: the row is in hand (Return or Space then plays it).
    var onSelect: () -> Void = {}
    /// A double-click, Return, or the accessibility action.
    let onPlay: () -> Void

    @Environment(MusicSession.self) private var music
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovering = false

    private var isCurrent: Bool { music.queue.current?.ratingKey == song.ratingKey }
    private var title: Font { columns.artist || columns.album ? .system(.body, weight: .medium) : .system(.title3, weight: .medium) }

    var body: some View {
        HStack(spacing: SongColumns.gap) {
            Group {
                if isCurrent { PlayingGlyph(isPlaying: music.isPlaying) }
                else if hovering || isFocused { Image(systemName: "play.fill").font(.system(size: 11)).foregroundStyle(Theme.ink) }
                else { Text((number ?? song.index).map(String.init) ?? "") .foregroundStyle(Theme.inkTertiary) }
            }
            .font(Theme.Typeface.cardMeta)
            .frame(width: SongColumns.number)
            if columns.art {
                MusicArt(path: song.parentThumb ?? song.thumb, pixelWidth: 64, radius: 6)
                    .frame(width: SongColumns.artSize, height: SongColumns.artSize)
            }
            HStack(spacing: 6) {
                Text(MusicFormat.songTitle(song.title)).font(title).foregroundStyle(isCurrent ? Theme.lilac : Theme.ink).lineLimit(1)
                // A song by someone other than the album's artist, as the server names them.
                if !columns.artist, let credit = song.originalTitle, !credit.isEmpty {
                    Text(credit).font(Theme.Typeface.cardMeta).foregroundStyle(Theme.inkTertiary).lineLimit(1)
                }
            }
            .frame(maxWidth: columns.artist || columns.album ? columns.titleWidth : .infinity, alignment: .leading)
            if columns.artist {
                Text(song.originalTitle ?? song.grandparentTitle ?? "").font(Theme.Typeface.cardMeta).foregroundStyle(Theme.inkSecondary).lineLimit(1)
                    .frame(width: columns.artistWidth, alignment: .leading)
            }
            if columns.album {
                Text(song.parentTitle ?? "").font(Theme.Typeface.cardMeta).foregroundStyle(Theme.inkSecondary).lineLimit(1)
                    .frame(width: columns.albumWidth, alignment: .leading)
            }
            Text(MusicFormat.clock(ms: song.duration)).font(Theme.Typeface.cardMeta).foregroundStyle(Theme.inkSecondary)
                .frame(width: SongColumns.time, alignment: .trailing)
            if columns.plays {
                Text((song.viewCount ?? 0) > 0 ? (song.viewCount ?? 0).formatted() : "").font(Theme.Typeface.cardMeta).foregroundStyle(Theme.inkSecondary)
                    .frame(width: SongColumns.playsWidth, alignment: .trailing)
            }
            if columns.quality {
                Text(quality ?? "").font(Theme.Typeface.cardMeta).foregroundStyle(Theme.inkTertiary).lineLimit(1)
                    .frame(width: SongColumns.qualityWidth, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
            .fill(hovering || isFocused ? Theme.raised : .clear))
        .overlay {
            if isFocused && contrast == .increased {
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).strokeBorder(Theme.ink, lineWidth: 2)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: onPlay)
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel([MusicFormat.songTitle(song.title), song.originalTitle ?? song.grandparentTitle, MusicFormat.spoken(ms: song.duration)]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityValue(isCurrent ? (music.isPlaying ? "Playing" : "Paused") : "")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Plays")
        .accessibilityAction { onPlay() }
        .contextMenu { MusicContextMenu(item: song) }
    }
}

/// What the Songs table's headings sort by, and which way.
struct SongSorting {
    let current: LibraryQuery.Sort
    let descending: Bool
    let choose: (LibraryQuery.Sort) -> Void
}

/// The column names above a list, with a rule under them. With `sorting`, the headings of the
/// sortable columns are buttons and the current one carries an arrow.
struct SongHeader: View {
    let columns: SongColumns
    var sorting: SongSorting?

    var body: some View {
        HStack(spacing: SongColumns.gap) {
            Text("#").frame(width: SongColumns.number)
            if columns.art { Color.clear.frame(width: SongColumns.artSize, height: 1) }
            heading("Title", sort: .title).frame(maxWidth: columns.artist || columns.album ? columns.titleWidth : .infinity, alignment: .leading)
            if columns.artist { heading("Artist", sort: .artist).frame(width: columns.artistWidth, alignment: .leading) }
            if columns.album { heading("Album", sort: .album).frame(width: columns.albumWidth, alignment: .leading) }
            Text("Time").frame(width: SongColumns.time, alignment: .trailing)
            if columns.plays { heading("Plays", sort: .mostPlayed).frame(width: SongColumns.playsWidth, alignment: .trailing) }
            if columns.quality { Text("Quality").frame(width: SongColumns.qualityWidth, alignment: .leading) }
        }
        .font(Theme.Typeface.cardMeta)
        .foregroundStyle(Theme.inkTertiary)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.rule).frame(height: 1) }
        .accessibilityElement(children: sorting == nil ? .ignore : .contain)
        .accessibilityHidden(sorting == nil)
    }

    @ViewBuilder private func heading(_ name: String, sort: LibraryQuery.Sort) -> some View {
        if let sorting {
            let active = sorting.current == sort
            Button { sorting.choose(sort) } label: {
                HStack(spacing: 3) {
                    Text(name)
                    if active { Image(systemName: sorting.descending ? "chevron.down" : "chevron.up").font(.system(size: 9, weight: .bold)) }
                }
                .foregroundStyle(active ? Theme.inkSecondary : Theme.inkTertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Sort by \(name.lowercased())")
            .accessibilityLabel("Sort by \(name)")
            .accessibilityValue(active ? (sorting.descending ? "Descending" : "Ascending") : "")
        } else {
            Text(name)
        }
    }
}
