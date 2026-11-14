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

    @Environment(SessionStore.self) private var session
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
                    Text(tagline).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.ink.opacity(0.9)).lineLimit(2)
                }
            }

            HStack(spacing: Theme.Space.m) {
                Button(action: play) { Label(primaryLabel, systemImage: "play.fill") }
                    .buttonStyle(PrimaryButtonStyle())
                    .focusEffectDisabled(false)
                    .help("Play (Space)")
                if let playTrailer {
                    Button("Trailer", action: playTrailer)
                        .buttonStyle(SecondaryButtonStyle())
                        .focusEffectDisabled(false)
                }
                Button(action: toggleWatched) {
                    Label(item.isWatched ? "Watched" : "Mark Watched", systemImage: item.isWatched ? "checkmark.circle.fill" : "checkmark.circle")
                }
                .buttonStyle(SecondaryButtonStyle())
                .focusEffectDisabled(false)
                .help(item.isWatched ? "Mark as unwatched (W)" : "Mark as watched (W)")
            }
            if let progress = (nextEpisode ?? item).progress, progress > 0 {
                ProgressView(value: progress).tint(Theme.ink).frame(width: 220)
                    .accessibilityLabel("\(Int(progress * 100)) percent watched")
            }
        }
        .padding(.leading, Theme.Space.gutter)
        .padding(.top, 220)
        .padding(.bottom, Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .top) {
            GeometryReader { geo in
                RemoteImage(url: session.backdropURL(item.backdropPath, pixelWidth: Int(geo.size.width * 2)),
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

    @Environment(SessionStore.self) private var session
    @State private var hovering = false
    @State private var frame: CGRect = .zero

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.l) {
            RemoteImage(url: session.backdropURL(episode.thumb, pixelWidth: 440), pixelWidth: 440)
                .frame(width: 220, height: 124)
                .overlay(alignment: .bottom) {
                    if let p = episode.progress {
                        Capsule().fill(Theme.ink).frame(width: max(4, 200 * p), height: 3)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.bottom, 8)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if hovering || isFocused { PlayDisc { onPlay(frame) }.padding(8) }
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
        .simultaneousGesture(TapGesture().onEnded { onFocus() })
        .simultaneousGesture(TapGesture(count: 2).onEnded { onPlay(frame) })
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(episode.isWatched ? "Watched" : (episode.progress.map { "\(Int($0 * 100)) percent watched" } ?? ""))
        .accessibilityAction { onPlay(frame) }
        .contextMenu {
            Button("Play") { onPlay(frame) }
            Button(episode.isWatched ? "Mark as Unwatched" : "Mark as Watched", action: onToggleWatched)
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
