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
    /// A show or season waiting for "Mark all as watched?" confirmation.
    @State private var confirmWatched: PlexMetadata?
    @State private var actionError: String?
    /// Which page section ↑/↓ last scrolled to (index into `sectionIDs`).
    @State private var section = 0
    private static let sectionLead: CGFloat = 24

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if let item {
                    // Each section after the hero carries its own lead-in, so ↑/↓ land it
                    // with clear space under the toolbar instead of flush against it.
                    VStack(alignment: .leading, spacing: Theme.Space.xl - Self.sectionLead) {
                        DetailHero(item: item, nextEpisode: nextEpisode, play: { play(nextEpisode ?? item, from: heroFrame) },
                                   playTrailer: trailer.map { t in { play(t, from: heroFrame) } },
                                   toggleWatched: { requestToggleWatched(item) },
                                   playVersion: { i in Task { await playback.play(item, from: heroFrame, mediaIndex: i) } },
                                   chooseArtwork: { kind in commands.artworkRequest = ArtworkRequest(item: item, kind: kind) },
                                   season: season)
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { heroFrame = $0 }
                            .id("hero")
                        about(item).padding(.top, Self.sectionLead).id("about")
                        if item.kind == .show || item.kind == .season {
                            seasonsAndEpisodes(proxy: proxy).padding(.top, Self.sectionLead).id("episodes")
                        }
                        if !item.roles.isEmpty { CastStrip(roles: Array(item.roles.prefix(20))).padding(.top, Self.sectionLead).id("cast") }
                        if !item.extras.isEmpty { extrasRow(item.extras).padding(.top, Self.sectionLead).id("extras") }
                        ForEach(relatedHubs) { hub in
                            ShelfView(shelf: Shelf(id: hub.hubIdentifier, title: hub.title, items: hub.items), row: 0,
                                      focusedColumn: nil, scrollsToFocus: false,
                                      onFocus: { _ in }, onPlay: { item, frame in play(item, from: frame) },
                                      onOpen: { commands.open($0) })
                                .padding(.top, Self.sectionLead)
                                .id("related-\(hub.hubIdentifier)")
                        }
                    }
                    .padding(.bottom, Theme.Space.xxl)
                }
            }
            .scrollIndicators(.never)
            .onChange(of: section) { _, i in
                guard sectionIDs.indices.contains(i), sectionIDs[i] != "episodes" || focusedEpisode == nil else { return }
                withAnimation(Theme.Motion.object(reduceMotion)) { proxy.scrollTo(sectionIDs[i], anchor: .top) }
            }
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
            // On a show, W means the episode in hand (focused, else the one Play would start),
            // never the whole series on a stray key; the hero button covers that, with a confirmation.
            let focused = focusedEpisode.flatMap { episodes.indices.contains($0) ? episodes[$0] : nil }
            guard let target = focused ?? (episodes.isEmpty ? item : nextEpisode) else { return .ignored }
            requestToggleWatched(target)
            return .handled
        }
        .onMoveCommand(perform: move)
        .navigationTitle(item.map(Format.displayTitle) ?? "")
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirmWatched != nil }, set: { if !$0 { confirmWatched = nil } }),
                            titleVisibility: .visible) {
            Button(confirmWatched?.isWatched == true ? "Mark as Unwatched" : "Mark as Watched") {
                if let target = confirmWatched { Task { await toggleWatched(target) } }
                confirmWatched = nil
            }
            Button("Cancel", role: .cancel) { confirmWatched = nil }
        } message: {
            Text("This changes your watch history on the server, which Plex apps, Tautulli and Trakt all read.")
        }
        .alert("Couldn’t change watched state", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: { Text(actionError ?? "") }
        .task(id: route) { await load() }
        // View ▸ Choose Poster / Background act on this page's title.
        .onChange(of: item?.ratingKey, initial: true) { _, _ in
            commands.currentDetailItem = item.flatMap { [.movie, .show, .season].contains($0.kind) ? $0 : nil }
        }
        .onDisappear { if commands.currentDetailItem?.ratingKey == item?.ratingKey { commands.currentDetailItem = nil } }
        .onChange(of: library.revision) { _, _ in Task { await refreshEpisodes() } }
    }

    // MARK: Sections

    private func about(_ item: PlexMetadata) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.xxl) {
            if let summary = item.summary, !summary.isEmpty {
                Text(summary)
                    .font(Theme.Typeface.reading)
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
                        }
                    }
                    .padding(.horizontal, Theme.Space.gutter)
                }
                .scrollIndicators(.never)
                .help("Seasons (⌥← / ⌥→)")
            }
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(Array(episodes.enumerated()), id: \.element.ratingKey) { i, episode in
                    EpisodeRow(episode: episode, isFocused: focusedEpisode == i,
                               onFocus: { focusedEpisode = i; if let e = sectionIDs.firstIndex(of: "episodes") { section = e } },
                               onPlay: { frame in play(episode, from: frame) },
                               onToggleWatched: { requestToggleWatched(episode) },
                               onPlayVersion: { v in Task { await playback.play(episode, from: nil, mediaIndex: v) } })
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
                        .accessibilityValue([extra.subtype?.capitalized, extra.duration.map(Format.duration)].compactMap { $0 }.joined(separator: ", "))
                    }
                }
                .padding(.horizontal, Theme.Space.gutter)
            }
            .scrollIndicators(.never)
        }
    }

    // MARK: Data

    private var relatedHubs: [PlexHub] { related.filter { !$0.items.isEmpty } }

    /// The page's sections in scroll order, for ↑/↓.
    private var sectionIDs: [String] {
        guard let item else { return [] }
        var ids = ["hero", "about"]
        if (item.kind == .show || item.kind == .season) && !episodes.isEmpty { ids.append("episodes") }
        if !item.roles.isEmpty { ids.append("cast") }
        if !item.extras.isEmpty { ids.append("extras") }
        ids += relatedHubs.map { "related-\($0.hubIdentifier)" }
        return ids
    }

    private var trailer: PlexMetadata? { item?.extras.first { $0.subtype == "trailer" } }

    /// For shows: the episode Play starts (in progress, else first unwatched).
    private var nextEpisode: PlexMetadata? {
        guard item?.kind == .show || item?.kind == .season else { return nil }
        return episodes.first { ($0.viewOffset ?? 0) > 0 } ?? episodes.first { !$0.isWatched }
    }

    private func load() async {
        guard let client = session.client else { return }
        error = nil
        section = 0
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
            #if DEBUG
            // -DetailSection cast: land scrolled to a section, for review captures.
            if let id = UserDefaults.standard.string(forKey: "DetailSection"), let i = sectionIDs.firstIndex(of: id) {
                try? await Task.sleep(for: .milliseconds(600))
                section = i
            }
            #endif
        } catch is CancellationError {
        } catch {
            self.error = (error as? PlexError)?.userMessage ?? "\(error)"
        }
    }

    private func choose(season s: PlexMetadata) async {
        season = s
        focusedEpisode = nil
        if let e = sectionIDs.firstIndex(of: "episodes"), section > e { section = e }
        guard let client = session.client else { return }
        let list = (try? await client.children(s.ratingKey)) ?? []
        // Another season was chosen while this one loaded: its list is the one to show.
        guard season?.ratingKey == s.ratingKey else { return }
        episodes = list
    }

    private func refreshEpisodes() async {
        guard let s = season, let client = session.client else { return }
        let list = (try? await client.children(s.ratingKey)) ?? episodes
        guard season?.ratingKey == s.ratingKey else { return }
        episodes = list
    }

    private var confirmTitle: String {
        guard let t = confirmWatched else { return "" }
        let n = t.leafCount ?? 0
        let what = t.kind == .show ? "all \(n) episodes of \(t.title)" : "all \(n) episodes of \(t.title)"
        return t.isWatched ? "Mark \(what) as unwatched?" : "Mark \(what) as watched?"
    }

    /// Shows and seasons ask first (they change many episodes); single titles don't.
    private func requestToggleWatched(_ target: PlexMetadata) {
        if target.kind == .show || target.kind == .season { confirmWatched = target }
        else { Task { await toggleWatched(target) } }
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
            actionError = (error as? PlexError)?.userMessage ?? "The server didn’t accept the change."
        }
    }

    // MARK: Keys

    private func move(_ direction: MoveCommandDirection) {
        let optionDown = NSEvent.modifierFlags.contains(.option)
        switch direction {
        case .left where optionDown || episodes.isEmpty: stepSeason(-1)
        case .right where optionDown || episodes.isEmpty: stepSeason(1)
        case .up: stepVertical(-1)
        case .down: stepVertical(1)
        default: break
        }
    }

    /// ↑/↓ walk the page: section by section, and episode by episode inside the episode list.
    private func stepVertical(_ delta: Int) {
        let ids = sectionIDs
        guard !ids.isEmpty else { return }
        let episodesAt = ids.firstIndex(of: "episodes")
        if let i = focusedEpisode {
            let next = i + delta
            if episodes.indices.contains(next) { focusedEpisode = next; return }
            focusedEpisode = nil
            if delta < 0 { section = 0 }
            else if let e = episodesAt, ids.indices.contains(e + 1) { section = e + 1 }
            return
        }
        // A show's first ↓ goes straight to its episodes; the summary is already on screen.
        if delta > 0, let e = episodesAt, section < e { section = e; focusedEpisode = 0; return }
        let next = min(max(0, section + delta), ids.count - 1)
        if let e = episodesAt, next == e, delta < 0 { section = e; focusedEpisode = episodes.count - 1; return }
        section = next
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
