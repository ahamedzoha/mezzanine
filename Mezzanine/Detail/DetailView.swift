import SwiftUI
import MezzanineKit

/// Where a detail page points.
struct DetailRoute: Hashable {
    let ratingKey: String
}

/// A title's page: the hero at full width, then what it is, who made it,
/// and (for shows) every season and episode.
///
/// Keys: Space plays (or resumes), ↑/↓ move through episodes and Return
/// plays the focused one, ⌥← / ⌥→ switch season, W toggles watched,
/// ⌘[ or Esc goes back.
struct DetailView: View {
    let route: DetailRoute
    var contentFocus: FocusState<Bool>.Binding

    @Environment(SessionStore.self) private var session
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(AppCommandCenter.self) private var commands
    @Environment(LibraryStore.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var item: PlexMetadata?
    @State private var seasons: [PlexMetadata] = []
    @State private var season: PlexMetadata?
    @State private var episodes: [PlexMetadata] = []
    @State private var related: [PlexHub] = []
    @State private var focusedEpisode: Int?
    @State private var error: String?
    @State private var heroFrame: CGRect = .zero

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if let item {
                    VStack(alignment: .leading, spacing: Theme.Space.xl) {
                        DetailHero(item: item, nextEpisode: nextEpisode, play: { play(nextEpisode ?? item, from: heroFrame) },
                                   playTrailer: trailer.map { t in { play(t, from: heroFrame) } },
                                   toggleWatched: { Task { await toggleWatched(item) } })
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { heroFrame = $0 }
                        about(item)
                        if item.kind == .show || item.kind == .season { seasonsAndEpisodes(proxy: proxy) }
                        if !item.roles.isEmpty { CastStrip(roles: Array(item.roles.prefix(20))) }
                        if !item.extras.isEmpty { extrasRow(item.extras) }
                        ForEach(related.filter { !$0.items.isEmpty }) { hub in
                            ShelfView(shelf: Shelf(id: hub.hubIdentifier, title: hub.title, items: hub.items), row: 0,
                                      focusedColumn: nil, scrollsToFocus: false,
                                      onFocus: { _ in }, onPlay: { item, frame in play(item, from: frame) },
                                      onOpen: { commands.open($0) })
                        }
                    }
                    .padding(.bottom, Theme.Space.xxl)
                }
            }
            .scrollIndicators(.never)
        }
        .overlay {
            if item == nil {
                if let error { RoomMessage(title: "Couldn’t open this title", detail: error, retry: { Task { await load() } }) }
                else { RoomMessage { ProgressView().controlSize(.small).accessibilityLabel("Loading") } }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused(contentFocus)
        .onKeyPress(.space) { playPrimary() }
        .onKeyPress(.return) { playFocusedEpisode() }
        .onKeyPress(.escape) { commands.goBack(); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "wW")) { _ in
            guard let item else { return .ignored }
            Task { await toggleWatched(focusedEpisode.flatMap { episodes.indices.contains($0) ? episodes[$0] : nil } ?? item) }
            return .handled
        }
        .onMoveCommand(perform: move)
        .navigationTitle(item.map(Format.displayTitle) ?? "")
        .task(id: route) { await load() }
        .onChange(of: library.revision) { _, _ in Task { await refreshEpisodes() } }
    }

    // MARK: Sections

    private func about(_ item: PlexMetadata) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.xxl) {
            if let summary = item.summary, !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 15))
                    .lineSpacing(3)
                    .foregroundStyle(Theme.ink.opacity(0.88))
                    .frame(maxWidth: 640, alignment: .leading)
                    .textSelection(.enabled)
            }
            Grid(alignment: .leading, horizontalSpacing: Theme.Space.m, verticalSpacing: Theme.Space.s) {
                fact("Directed by", item.directors.map(\.tag))
                fact("Written by", item.writers.prefix(3).map(\.tag))
                fact("Genre", item.genres.map(\.tag))
                fact("Studio", item.studio.map { [$0] } ?? [])
                fact("Rated", item.contentRating.map { [$0] } ?? [])
                if let rating = item.audienceRating ?? item.rating {
                    fact("Rating", [String(format: "%.1f", rating)])
                }
            }
            .font(Theme.Typeface.caption)
            .frame(minWidth: 220, alignment: .leading)
        }
        .padding(.horizontal, Theme.Space.gutter)
    }

    @ViewBuilder private func fact(_ label: String, _ values: [String]) -> some View {
        if !values.isEmpty {
            GridRow {
                Text(label).foregroundStyle(Theme.inkTertiary)
                Text(values.joined(separator: ", ")).foregroundStyle(Theme.inkSecondary).lineLimit(2)
            }
        }
    }

    @ViewBuilder private func seasonsAndEpisodes(proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if seasons.count > 1 {
                ScrollView(.horizontal) {
                    HStack(spacing: Theme.Space.s) {
                        ForEach(seasons) { s in
                            let selected = s.ratingKey == season?.ratingKey
                            Button { Task { await choose(season: s) } } label: {
                                HStack(spacing: 6) {
                                    Text(s.title)
                                    if s.isWatched { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)) }
                                }
                                .font(Theme.Typeface.button)
                                .foregroundStyle(selected ? Theme.onLilac : Theme.ink)
                                .padding(.horizontal, 14)
                                .frame(height: 30)
                                .background(Capsule().fill(selected ? Theme.lilac : Theme.raised))
                                .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .focusEffectDisabled(false)
                            .accessibilityAddTraits(selected ? .isSelected : [])
                            .help("⌥← / ⌥→ switch season")
                        }
                    }
                    .padding(.horizontal, Theme.Space.gutter)
                }
                .scrollIndicators(.never)
            }
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(Array(episodes.enumerated()), id: \.element.ratingKey) { i, episode in
                    EpisodeRow(episode: episode, isFocused: focusedEpisode == i,
                               onFocus: { focusedEpisode = i },
                               onPlay: { frame in play(episode, from: frame) },
                               onToggleWatched: { Task { await toggleWatched(episode) } })
                        .id("ep-\(i)")
                }
            }
            .padding(.horizontal, Theme.Space.gutter - Theme.Space.m)
        }
        .onChange(of: focusedEpisode) { _, i in
            guard let i else { return }
            withAnimation(Theme.Motion.object(reduceMotion)) { proxy.scrollTo("ep-\(i)", anchor: nil) }
        }
    }

    private func extrasRow(_ extras: [PlexMetadata]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Extras").font(Theme.Typeface.shelfTitle).foregroundStyle(Theme.ink).padding(.leading, Theme.Space.gutter)
                .accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: Theme.Space.l) {
                    ForEach(extras) { extra in
                        Button { play(extra, from: nil) } label: {
                            VStack(alignment: .leading, spacing: Theme.Space.s) {
                                RemoteImage(url: session.backdropURL(extra.thumb, pixelWidth: 480), pixelWidth: 480)
                                    .frame(width: 240, height: 135)
                                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.still, style: .continuous))
                                    .overlay(alignment: .bottomTrailing) {
                                        Image(systemName: "play.fill").font(.system(size: 11, weight: .bold))
                                            .foregroundStyle(Theme.graphite).frame(width: 28, height: 28)
                                            .background(Circle().fill(Theme.ink)).padding(8)
                                    }
                                Text(extra.title).font(Theme.Typeface.cardTitle).foregroundStyle(Theme.ink).lineLimit(1)
                                Text([extra.subtype?.capitalized, extra.duration.map(Format.duration)].compactMap { $0 }.joined(separator: " · "))
                                    .font(Theme.Typeface.cardMeta).foregroundStyle(Theme.inkSecondary)
                            }
                            .frame(width: 240, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled(false)
                        .accessibilityLabel("Play \(extra.title)")
                    }
                }
                .padding(.horizontal, Theme.Space.gutter)
            }
            .scrollIndicators(.never)
        }
    }

    // MARK: Data

    private var trailer: PlexMetadata? { item?.extras.first { $0.subtype == "trailer" } }

    /// For shows: the episode Play starts (in progress, else first unwatched).
    private var nextEpisode: PlexMetadata? {
        guard item?.kind == .show || item?.kind == .season else { return nil }
        return episodes.first { ($0.viewOffset ?? 0) > 0 } ?? episodes.first { !$0.isWatched }
    }

    private func load() async {
        guard let client = session.client else { return }
        error = nil
        do {
            let detail = try await client.metadata(route.ratingKey)
            item = detail
            playback.roomPalette = RoomPalette(detail.ultraBlur) ?? playback.roomPalette
            if detail.kind == .show {
                seasons = try await client.children(detail.ratingKey).filter { $0.kind == .season }
                let start = seasons.first { !$0.isWatched && ($0.index ?? 0) > 0 } ?? seasons.first { ($0.index ?? 0) > 0 } ?? seasons.first
                if let start { await choose(season: start) }
            } else if detail.kind == .season {
                seasons = [detail]
                await choose(season: detail)
            }
            related = (try? await client.related(detail.ratingKey)) ?? []
        } catch is CancellationError {
        } catch {
            self.error = (error as? PlexError)?.userMessage ?? "\(error)"
        }
    }

    private func choose(season s: PlexMetadata) async {
        season = s
        focusedEpisode = nil
        guard let client = session.client else { return }
        episodes = (try? await client.children(s.ratingKey)) ?? []
    }

    private func refreshEpisodes() async {
        guard let s = season, let client = session.client else { return }
        episodes = (try? await client.children(s.ratingKey)) ?? episodes
    }

    private func toggleWatched(_ target: PlexMetadata) async {
        guard let client = session.client else { return }
        do {
            if target.isWatched { try await client.unscrobble(ratingKey: target.ratingKey) }
            else { try await client.scrobble(ratingKey: target.ratingKey) }
            await library.syncAll()
            let fresh = try await client.metadata(route.ratingKey)
            item = fresh
            await refreshEpisodes()
        } catch {
            self.error = (error as? PlexError)?.userMessage
        }
    }

    // MARK: Keys

    private func move(_ direction: MoveCommandDirection) {
        let optionDown = NSEvent.modifierFlags.contains(.option)
        switch direction {
        case .left where optionDown || episodes.isEmpty: stepSeason(-1)
        case .right where optionDown || episodes.isEmpty: stepSeason(1)
        case .up: if !episodes.isEmpty { focusedEpisode = max(0, (focusedEpisode ?? 0) - 1) }
        case .down: if !episodes.isEmpty { focusedEpisode = min(episodes.count - 1, (focusedEpisode ?? -1) + 1) }
        default: break
        }
    }

    private func stepSeason(_ delta: Int) {
        guard let current = season, let i = seasons.firstIndex(where: { $0.ratingKey == current.ratingKey }) else { return }
        let next = i + delta
        guard seasons.indices.contains(next) else { return }
        Task { await choose(season: seasons[next]) }
    }

    private func playPrimary() -> KeyPress.Result {
        guard let item else { return .ignored }
        play(nextEpisode ?? item, from: heroFrame)
        return .handled
    }

    private func playFocusedEpisode() -> KeyPress.Result {
        guard let i = focusedEpisode, episodes.indices.contains(i) else { return playPrimary() }
        play(episodes[i], from: nil)
        return .handled
    }

    private func play(_ target: PlexMetadata, from frame: CGRect?) {
        Task { await playback.play(target, from: frame) }
    }
}
