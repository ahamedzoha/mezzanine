import SwiftUI
import MezzanineKit

/// The detail page's hero: full-width backdrop dissolving into the room,
/// the logo, one ruled caption, and the actions.
struct DetailHero: View {
    let item: PlexMetadata
    let nextEpisode: PlexMetadata?
    let play: () -> Void
    let playTrailer: (() -> Void)?
    let toggleWatched: () -> Void
    /// Plays one file of a multi-version title (shown only when there's a choice).
    var playVersion: ((Int) -> Void)? = nil
    var chooseArtwork: ((ArtworkKind) -> Void)? = nil
    /// The season on screen, for the Download menu's "All of Season N".
    var season: PlexMetadata? = nil

    @Environment(SessionStore.self) private var session
    @Environment(LibraryStore.self) private var library
    @State private var width: CGFloat = 1200

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            LogoImage(url: session.logoURL(item.clearLogoPath), pixelWidth: 1400) {
                Text(Format.displayTitle(item).uppercased())
                    .font(TitleFont.font(size: 96))
                    .tracking(-1)
                    .lineLimit(2)
                    .minimumScaleFactor(0.5)
                    .foregroundStyle(Theme.ink)
            }
            .frame(maxWidth: min(620, width * 0.55), maxHeight: 170, alignment: .bottomLeading)
            .accessibilityLabel(Format.displayTitle(item))
            .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Rectangle().fill(Theme.rule).frame(width: 48, height: 1)
                Text(caption).font(Theme.Typeface.caption).foregroundStyle(Theme.inkSecondary).lineLimit(1)
                if let tagline = item.tagline, !tagline.isEmpty {
                    Text(tagline).font(Theme.Typeface.reading.weight(.medium)).foregroundStyle(Theme.ink.opacity(0.9)).lineLimit(2)
                }
            }

            HStack(spacing: Theme.Space.m) {
                Button(action: play) { Label(primaryLabel, systemImage: "play.fill") }
                    .buttonStyle(PrimaryButtonStyle())
                    .focusEffectDisabled(false)
                    .help("Play (Space)")
                if let playVersion, item.media.count > 1 {
                    Menu {
                        ForEach(Array(item.media.enumerated()), id: \.offset) { i, media in
                            Button(Format.versionLabel(media)) { playVersion(i) }
                        }
                    } label: {
                        Label("Version", systemImage: "square.stack")
                    }
                    .menuStyle(.button)
                    .buttonStyle(SecondaryButtonStyle())
                    .fixedSize()
                    .help("This title has \(item.media.count) files. Play a particular one.")
                    .accessibilityLabel("Play a version, \(item.media.count) available")
                }
                if let playTrailer {
                    Button("Trailer", action: playTrailer)
                        .buttonStyle(SecondaryButtonStyle())
                        .focusEffectDisabled(false)
                        .accessibilityLabel("Play trailer")
                }
                Button(action: toggleWatched) {
                    Label(watchedLabel, systemImage: item.isWatched ? "checkmark.circle.fill" : "checkmark.circle")
                }
                .buttonStyle(SecondaryButtonStyle())
                .focusEffectDisabled(false)
                .help(watchedHelp)
                DownloadButton(item: item, season: season)
                if let chooseArtwork {
                    Menu {
                        Button("Choose Poster…") { chooseArtwork(.poster) }
                        Button("Choose Background…") { chooseArtwork(.background) }
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 14)
                    }
                    .menuStyle(.button)
                    .buttonStyle(SecondaryButtonStyle())
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .focusEffectDisabled(false)
                    .help("More: choose the poster or background")
                    .accessibilityLabel("More for \(Format.displayTitle(item))")
                }
            }
            if let target = Optional(nextEpisode ?? item), let progress = target.progress, progress > 0 {
                HStack(spacing: Theme.Space.s) {
                    ProgressView(value: progress).tint(Theme.ink).frame(width: 160)
                    Text(progressCaption(target)).font(Theme.Typeface.cardMeta).foregroundStyle(Theme.inkSecondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(progressCaption(target))
                .accessibilityValue("\(Int(progress * 100)) percent watched")
            }
        }
        .padding(.leading, Theme.Space.gutter)
        .padding(.top, 220)
        .padding(.bottom, Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .top) {
            GeometryReader { geo in
                RemoteImage(url: session.backdropURL(library.backdropPath(for: item), pixelWidth: Int(geo.size.width * 2)),
                            pixelWidth: Int(geo.size.width * 2), placeholder: .clear, alignment: .top)
                    .frame(width: geo.size.width, height: geo.size.height + 80)
                    .mask(LinearGradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.12),
                        .init(color: .black.opacity(0.85), location: 0.5),
                        .init(color: .clear, location: 1),
                    ], startPoint: .top, endPoint: .bottom))
                    .mask(LinearGradient(stops: [
                        .init(color: .black.opacity(0.35), location: 0),
                        .init(color: .black, location: 0.55),
                    ], startPoint: .leading, endPoint: .trailing))
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private var primaryLabel: String {
        if let next = nextEpisode, let code = Format.episodeCode(next) {
            return ((next.viewOffset ?? 0) > 0 ? "Resume " : "Play ") + code
        }
        return (item.viewOffset ?? 0) > 0 ? "Resume" : "Play"
    }

    /// Shows and seasons say what they cover; the button marks every episode in them.
    private var watchedLabel: String {
        let scope = item.kind == .show ? " Show" : (item.kind == .season ? " Season" : "")
        return (item.isWatched ? "Mark\(scope) Unwatched" : "Mark\(scope) Watched")
    }

    private var watchedHelp: String {
        switch item.kind {
        case .show, .season: return item.isWatched ? "Mark every episode as unwatched" : "Mark every episode as watched"
        default: return item.isWatched ? "Mark as unwatched (W)" : "Mark as watched (W)"
        }
    }

    /// "S2 E4 · 26 min left" for a show, "26 min left" for a film.
    private func progressCaption(_ target: PlexMetadata) -> String {
        [target.kind == .episode ? Format.episodeCode(target) : nil, Format.timeLeft(target)]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private var caption: String {
        var parts = [Format.heroCaption(item)]
        if item.kind == .show, let left = item.unwatchedLeafCount, left > 0 { parts.append("\(left) unwatched") }
        return parts.joined(separator: " · ")
    }
}

/// One episode: still, number and title, facts, two lines of summary.
struct EpisodeRow: View {
    let episode: PlexMetadata
    let isFocused: Bool
    let onFocus: () -> Void
    let onPlay: (CGRect) -> Void
    let onToggleWatched: () -> Void
    var onPlayVersion: ((Int) -> Void)? = nil

    @Environment(DownloadStore.self) private var downloads
    @Environment(SessionStore.self) private var session
    @State private var hovering = false
    @State private var frame: CGRect = .zero

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.l) {
            RemoteImage(url: session.backdropURL(episode.thumb, pixelWidth: 440), pixelWidth: 440)
                .frame(width: 220, height: 124)
                .overlay(alignment: .bottom) {
                    if let p = episode.progress {
                        // Flush along the bottom edge so the play disc never sits on it.
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.black.opacity(0.45))
                            Rectangle().fill(Theme.ink).frame(width: max(4, 220 * p))
                        }
                        .frame(height: 3)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if hovering || isFocused { PlayDisc { onPlay(frame) }.padding(.trailing, 8).padding(.bottom, 12) }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.still, style: .continuous))
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: Theme.Space.s) {
                    Text("\(episode.index.map { "\($0). " } ?? "")\(episode.title)")
                        .font(Theme.Typeface.cardTitle)
                        .foregroundStyle(isFocused ? Theme.lilac : Theme.ink)
                        .lineLimit(1)
                    if episode.isWatched {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.inkTertiary)
                            .accessibilityLabel("Watched")
                    }
                    DownloadMark(ratingKey: episode.ratingKey)
                }
                Text([episode.duration.map(Format.duration), episode.originallyAvailableAt, Format.timeLeft(episode)]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(Theme.Typeface.cardMeta).foregroundStyle(Theme.inkSecondary)
                if let summary = episode.summary, !summary.isEmpty {
                    Text(summary).font(Theme.Typeface.body).foregroundStyle(Theme.ink.opacity(0.75)).lineLimit(2)
                        .frame(maxWidth: 620, alignment: .leading)
                }
            }
            .padding(.top, 4)
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.m)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous)
            .fill(isFocused || hovering ? Theme.raised : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // One click plays, like the rest of the app's titles; focus follows so the keys pick up from here.
        .onTapGesture { onFocus(); onPlay(frame) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(episode.isWatched ? "Watched" : (episode.progress.map { "\(Int($0 * 100)) percent watched" } ?? ""))
        .accessibilityAction { onPlay(frame) }
        .accessibilityAction(named: episode.isWatched ? "Mark as unwatched" : "Mark as watched") { onToggleWatched() }
        .contextMenu {
            Button("Play") { onPlay(frame) }
            if let onPlayVersion, episode.media.count > 1 {
                Menu("Play Version") {
                    ForEach(Array(episode.media.enumerated()), id: \.offset) { i, media in
                        Button(Format.versionLabel(media)) { onPlayVersion(i) }
                    }
                }
            }
            Button(episode.isWatched ? "Mark as Unwatched" : "Mark as Watched", action: onToggleWatched)
            Divider()
            if let record = downloads.record(episode.ratingKey) {
                Button(record.isDone ? "Remove Download" : "Cancel Download", role: .destructive) { downloads.remove(record.id) }
            } else {
                Button("Download Episode") { downloads.download(episode) }
            }
        }
    }
}

/// Cast photos in a row: circle, name, role.
struct CastStrip: View {
    let roles: [PlexRole]
    @Environment(SessionStore.self) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Cast").font(Theme.Typeface.shelfTitle).foregroundStyle(Theme.ink).padding(.leading, Theme.Space.gutter)
                .accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: Theme.Space.l) {
                    ForEach(Array(roles.enumerated()), id: \.offset) { _, role in
                        VStack(spacing: Theme.Space.s) {
                            RemoteImage(url: role.thumb.flatMap { URL(string: $0) }, pixelWidth: 200)
                                .frame(width: 84, height: 84)
                                .clipShape(Circle())
                            Text(role.tag).font(Theme.Typeface.cardTitle).foregroundStyle(Theme.ink).lineLimit(1)
                            if let r = role.role {
                                Text(r).font(Theme.Typeface.cardMeta).foregroundStyle(Theme.inkSecondary).lineLimit(1)
                            }
                        }
                        .frame(width: 104)
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.horizontal, Theme.Space.gutter)
            }
            .scrollIndicators(.never)
        }
    }
}
