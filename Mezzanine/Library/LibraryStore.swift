import SwiftUI
import MezzanineKit

/// The local library for the connected server and Plex user: the index, its
/// sync, and per-title extras (clean posters). Browsing reads the index only.
@MainActor
@Observable
final class LibraryStore {
    enum SyncState: Equatable {
        case idle
        case syncing(section: String, done: Int, total: Int)
        case failed(String)
    }

    private(set) var index: LibraryIndex?
    private(set) var syncState: SyncState = .idle
    /// Bumped whenever the index changed; views reload on it.
    private(set) var revision = 0
    /// Resolved clean (pre-Kometa) poster paths, by rating key.
    private(set) var cleanPosters: [String: String] = [:]
    /// Per-library reading progress for onboarding, by section title.
    private(set) var progress: [String: (done: Int, total: Int)] = [:]
    /// Libraries fully read at least once this session.
    private(set) var finishedSections: Set<String> = []
    var sectionTitles: [String] { sections.filter { !LibrarySync.types(for: $0).isEmpty }.map(\.title) }

    /// Show the agent's original posters instead of the server's selected
    /// (overlaid) ones. Display only: nothing changes on the server.
    var prefersCleanPosters: Bool = UserDefaults.standard.bool(forKey: "cleanPosters") {
        didSet { UserDefaults.standard.set(prefersCleanPosters, forKey: "cleanPosters") }
    }

    private var sync: LibrarySync?
    private var client: PlexServerClient?
    private var sections: [PlexLibrarySection] = []
    /// Artwork chosen for Mezzanine only (never written to Plex): owner ratingKey → kind → path.
    private(set) var artworkOverrides: [String: [String: String]] = [:]
    private var overridesKey: String?
    private var timer: Task<Void, Never>?
    private var resolving = Set<String>()
    private var openedFor: String?

    /// Opens (or reopens) the index for a server + user and starts syncing.
    func connect(client: PlexServerClient, serverID: String, userID: String, sections: [PlexLibrarySection]) {
        self.client = client
        self.sections = sections
        let key = "\(serverID)-\(userID)"
        if openedFor != key {
            do {
                let index = try LibraryIndex.open(serverID: serverID, userID: userID)
                self.index = index
                openedFor = key
                cleanPosters = [:]
                overridesKey = "artworkOverrides.v1.\(key)"
                artworkOverrides = (UserDefaults.standard.dictionary(forKey: overridesKey!) as? [String: [String: String]]) ?? [:]
            } catch {
                syncState = .failed("The local library couldn’t open: \(error.localizedDescription)")
                return
            }
        }
        guard let index else { return }
        sync = LibrarySync(client: client, index: index)
        revision += 1
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncAll()
                try? await Task.sleep(for: .seconds(600))
            }
        }
    }

    func syncAll(force: Bool = false) async {
        guard let sync else { return }
        for section in sections where !LibrarySync.types(for: section).isEmpty {
            do {
                let changed = try await sync.sync(section, force: force) { progress in
                    Task { @MainActor [weak self] in
                        self?.syncState = .syncing(section: progress.section, done: progress.done, total: progress.total)
                        self?.progress[progress.section] = (progress.done, progress.total)
                        self?.revision += 1
                    }
                }
                finishedSections.insert(section.title)
                if progress[section.title] == nil {
                    let n = count(section: section.key)
                    progress[section.title] = (n, n)
                }
                if changed { revision += 1 }
            } catch is CancellationError {
                return
            } catch {
                syncState = .failed((error as? PlexError)?.userMessage ?? "\(error)")
                return
            }
        }
        syncState = .idle
    }

    /// Items for a library page, decoded off the main actor.
    func items(_ query: LibraryQuery) async -> [PlexMetadata] {
        guard let index else { return [] }
        return await Task.detached(priority: .userInitiated) {
            ((try? index.items(query)) ?? []).compactMap { $0.metadata() }
        }.value
    }

    func search(_ text: String) async -> [PlexMetadata] {
        guard let index else { return [] }
        // Lessons and home videos come after films and shows that match as well.
        let personal = sections.filter(\.isPersonalMedia).map(\.key)
        return await Task.detached(priority: .userInitiated) {
            ((try? index.search(text, demotedSections: personal)) ?? []).compactMap { $0.metadata() }
        }.value
    }

    /// Posters for the onboarding wall: recently added films and shows, mixed.
    func wallItems(limit: Int) async -> [PlexMetadata] {
        guard let index else { return [] }
        let keys = sections.filter { !LibrarySync.types(for: $0).isEmpty && !$0.isPersonalMedia }
        return await Task.detached(priority: .userInitiated) {
            var all: [IndexedItem] = []
            for section in keys {
                var q = LibraryQuery(section: section.key, kinds: section.kind == .show ? ["show"] : ["movie"], sort: .addedNewest)
                q.text = nil
                all += (try? index.items(q))?.prefix(limit) ?? []
            }
            return all.sorted { ($0.addedAt ?? 0) > ($1.addedAt ?? 0) }.prefix(limit).compactMap { $0.metadata() }
        }.value
    }

    func genres(section: String, kinds: [String]) -> [String] {
        ((try? index?.genres(section: section, kinds: kinds)) ?? []).map(\.0)
    }

    func count(section: String) -> Int { (try? index?.count(section: section)) ?? 0 }

    /// "275 films", "65 shows · 4,352 episodes", for a library by title.
    func summary(sectionTitle: String) -> String? {
        guard let index, let section = sections.first(where: { $0.title == sectionTitle }) else { return nil }
        func n(_ kind: String) -> Int { (try? index.items(LibraryQuery(section: section.key, kinds: [kind])).count) ?? 0 }
        let f = { (v: Int) in v.formatted(.number) }
        if section.kind == .show {
            let shows = n("show"), episodes = n("episode")
            return "\(f(shows)) \(shows == 1 ? "show" : "shows") · \(f(episodes)) \(episodes == 1 ? "episode" : "episodes")"
        }
        let films = n("movie")
        let noun = section.isPersonalMedia ? (films == 1 ? "video" : "videos") : (films == 1 ? "film" : "films")
        return "\(f(films)) \(noun)"
    }

    /// Applies a finished playback session to the index (resume point, or watched past 90 %).
    func recordStop(_ item: PlexMetadata, at time: TimeInterval, duration: TimeInterval) {
        guard let index, duration > 0 else { return }
        let watched = time / duration >= 0.9
        try? index.updateProgress(ratingKey: item.ratingKey,
                                  viewOffset: watched ? 0 : Int(time * 1000),
                                  viewCount: watched ? (item.viewCount ?? 0) + 1 : nil)
        revision += 1
    }

    // MARK: Posters

    /// The poster path to draw for an item: a Mezzanine-only choice first, then the
    /// clean-poster setting, then Plex's.
    func posterPath(for item: PlexMetadata) -> String? {
        let key = Self.artworkOwner(item)
        if let chosen = artworkOverrides[key]?[ArtworkKind.poster.rawValue] { return chosen }
        guard prefersCleanPosters else { return item.posterPath }
        return cleanPosters[key] ?? item.posterPath
    }

    /// The background to draw for an item: a Mezzanine-only choice first, then Plex's.
    func backdropPath(for item: PlexMetadata) -> String? {
        let key = Self.artworkOwner(item)
        return artworkOverrides[key]?[ArtworkKind.background.rawValue] ?? item.backdropPath
    }

    /// Whose artwork an item shows: an episode's show, else the item itself.
    static func artworkOwner(_ item: PlexMetadata) -> String {
        item.kind == .episode ? (item.grandparentRatingKey ?? item.ratingKey) : item.ratingKey
    }

    func artworkOverride(_ kind: ArtworkKind, for ratingKey: String) -> String? {
        artworkOverrides[ratingKey]?[kind.rawValue]
    }

    /// Sets (or with nil, clears) a Mezzanine-only poster or background.
    func setArtworkOverride(_ kind: ArtworkKind, for ratingKey: String, path: String?) {
        var entry = artworkOverrides[ratingKey] ?? [:]
        entry[kind.rawValue] = path
        artworkOverrides[ratingKey] = entry.isEmpty ? nil : entry
        if let overridesKey { UserDefaults.standard.set(artworkOverrides, forKey: overridesKey) }
    }

    /// Looks up (once) and caches the clean poster for an item's poster owner.
    func resolveCleanPoster(for item: PlexMetadata) async {
        guard prefersCleanPosters, let client, let index else { return }
        let key = item.kind == .episode ? (item.grandparentRatingKey ?? item.ratingKey) : item.ratingKey
        guard cleanPosters[key] == nil, !resolving.contains(key) else { return }
        if let stored = try? index.item(key)?.cleanPosterPath {
            cleanPosters[key] = stored
            return
        }
        resolving.insert(key)
        defer { resolving.remove(key) }
        guard let path = try? await client.cleanPosterPath(ratingKey: key) else { return }
        try? index.setCleanPoster(path, for: key)
        cleanPosters[key] = path
    }
}
