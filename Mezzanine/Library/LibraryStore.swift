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
    /// "server-user" of the open index (per-profile state such as the new-episode check).
    var indexKey: String? { openedFor }
    /// Called after every completed sync (the new-episode check).
    @ObservationIgnored var onSynced: (() -> Void)?

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
                continueItems = []
                sliceCounts = [:]
                pinCounts = [:]
                newThisWeek = 0
                lastSyncedAt = nil
                removedFromContinue = [:]
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
            await self?.dropMissingSections()
            while !Task.isCancelled {
                await self?.syncAll()
                try? await Task.sleep(for: .seconds(600))
            }
        }
    }

    /// Titles of a library that's gone would otherwise stay in search and smart shelves.
    private func dropMissingSections() async {
        guard let sync, (try? await sync.dropMissingSections(listed: Set(sections.map(\.key)))) == true,
              sync === self.sync else { return }
        revision += 1
    }

    /// One sync at a time. A request while one runs makes it go round once more when it ends
    /// (so a change made meanwhile, like a watched mark, is picked up), instead of a second sync
    /// writing an older page over a newer one.
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var again = false
    @ObservationIgnored private var forceAgain = false

    func syncAll(force: Bool = false) async {
        if let running {
            again = true
            forceAgain = forceAgain || force
            await running.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.syncPass(force: force)
            while self.again {
                let force = self.forceAgain
                self.again = false
                self.forceAgain = false
                await self.syncPass(force: force)
            }
        }
        running = task
        isSyncing = true
        await task.value
        running = nil
        isSyncing = false
        onSynced?()
    }

    private func syncPass(force: Bool) async {
        guard let sync else { return }
        for section in sections where !LibrarySync.types(for: section).isEmpty {
            // A profile or server switch replaced the sync: this pass belongs to the old one.
            guard sync === self.sync else { return }
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
                AppLog.library.error("sync failed in section \(section.key, privacy: .public): \(String(describing: error), privacy: .private)")
                return
            }
        }
        syncState = .idle
        lastSyncedAt = Date()
        AppLog.library.info("synced")
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
        func n(_ kind: String) -> Int { (try? index.count(section: section.key, kinds: [kind])) ?? 0 }
        let f = { (v: Int) in v.formatted(.number) }
        if section.kind == .show {
            let shows = n("show"), episodes = n("episode")
            return "\(f(shows)) \(shows == 1 ? "show" : "shows") · \(f(episodes)) \(episodes == 1 ? "episode" : "episodes")"
        }
        let films = n("movie")
        let noun = section.isPersonalMedia ? (films == 1 ? "video" : "videos") : (films == 1 ? "film" : "films")
        return "\(f(films)) \(noun)"
    }

    // MARK: Sidebar

    struct SliceCounts: Equatable, Sendable {
        var total = 0, unwatched = 0, inProgress = 0
        var hasCollections = false
    }

    private(set) var sliceCounts: [String: SliceCounts] = [:]
    private(set) var pinCounts: [String: Int] = [:]
    /// Unwatched films and episodes added in the last seven days.
    private(set) var newThisWeek = 0
    private(set) var lastSyncedAt: Date?
    private(set) var isSyncing = false
    @ObservationIgnored private var countGeneration = 0

    /// "7 in progress · 3 new this week", under Home's title.
    var homeFacts: String {
        let watching = continueItems.filter { $0.progress != nil }.count
        return [watching > 0 ? "\(watching) in progress" : nil, newThisWeek > 0 ? "\(newThisWeek) new this week" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// Counts what the sidebar shows, with the same queries its pages run.
    func loadCounts(pins: [ShelfSpec]) async {
        guard let index else { return }
        countGeneration += 1
        let generation = countGeneration
        let indexed = sections.filter { !LibrarySync.types(for: $0).isEmpty }
        let result = await Task.detached(priority: .utility) {
            var slices: [String: SliceCounts] = [:]
            for section in indexed {
                var q = LibraryQuery(section: section.key, kinds: section.kind == .show ? ["show"] : ["movie"])
                var counts = SliceCounts()
                counts.total = (try? index.count(q)) ?? 0
                q.unwatchedOnly = true
                counts.unwatched = (try? index.count(q)) ?? 0
                q.unwatchedOnly = false
                q.inProgressOnly = true
                counts.inProgress = (try? index.count(q)) ?? 0
                counts.hasCollections = !((try? index.collectionNames(sections: [section.key])) ?? []).isEmpty
                slices[section.key] = counts
            }
            var pinned: [String: Int] = [:]
            for pin in pins {
                switch pin.source {
                case .smart(let rule): pinned[pin.id] = try? index.count(rule)
                case .collection(_, let section):
                    pinned[pin.id] = try? index.count(SmartRule(sections: [section], conditions: [.collection(pin.title)]))
                default: break
                }
            }
            let libraries = indexed.filter { !$0.isPersonalMedia }.map(\.key)
            let fresh = libraries.isEmpty ? 0 : (try? index.count(SmartRule(sections: libraries, kinds: ["movie", "episode"],
                conditions: [.watch(.unwatched), .addedWithin(days: 7)]))) ?? 0
            return (slices, pinned, fresh)
        }.value
        guard generation == countGeneration else { return }
        (sliceCounts, pinCounts, newThisWeek) = result
    }

    /// A random unwatched film or show from these libraries (all video libraries when nil).
    func surprise(section: String?, kinds: [String]) async -> PlexMetadata? {
        guard let index else { return nil }
        let keys = section.map { [$0] } ?? sections.filter { !LibrarySync.types(for: $0).isEmpty && !$0.isPersonalMedia }.map(\.key)
        return await Task.detached(priority: .userInitiated) {
            ((try? index.random(sections: keys, kinds: kinds)) ?? nil)?.metadata()
        }.value
    }

    /// Every title a smart shelf matches, decoded off the main actor.
    func items(_ rule: SmartRule) async -> [PlexMetadata] {
        guard let index else { return [] }
        return await Task.detached(priority: .userInitiated) {
            ((try? index.items(rule)) ?? []).compactMap { $0.metadata() }
        }.value
    }

    // MARK: Continue Watching

    /// What's in progress, in Plex's order (the sidebar, and whether a title can be taken out).
    private(set) var continueItems: [PlexMetadata] = []
    /// Titles taken out of Continue Watching by hand, and when, until Plex has caught up.
    private(set) var removedFromContinue: [String: Date] = [:]
    @ObservationIgnored private var continueGeneration = 0

    func isInContinue(_ ratingKey: String) -> Bool { continueItems.contains { $0.ratingKey == ratingKey } }

    func setRemovedFromContinue(_ ratingKey: String, _ removed: Bool) {
        removedFromContinue[ratingKey] = removed ? Date() : nil
        if removed { continueItems.removeAll { $0.ratingKey == ratingKey } }
        revision += 1
    }

    /// Reads the row again. A newer request's answer wins.
    func loadContinue() async {
        guard let client else { return }
        continueGeneration += 1
        let generation = continueGeneration
        guard let items = try? await client.continueWatching(limit: 40) else { return }
        guard generation == continueGeneration else { return }
        continueItems = ContinueWatching.applying(recentStops, removed: removedFromContinue, to: items)
    }

    /// Reads one title again after its watch state changed, so every page shows the server's copy.
    func refresh(_ item: PlexMetadata) async {
        try? await sync?.refresh(item)
        revision += 1
    }

    /// Playbacks that stopped in the last two minutes, for Home's Continue Watching while Plex
    /// catches up (`ContinueWatching`).
    private(set) var recentStops: [PlaybackStop] = []

    /// Applies a finished playback session to the index (resume point, or watched past 90 %),
    /// and has Home read Plex again now and once more a few seconds later, when Plex has
    /// processed the last reports.
    func recordStop(_ item: PlexMetadata, at time: TimeInterval, duration: TimeInterval) {
        guard duration > 0 else { return }
        let now = Date()
        recentStops = recentStops.filter { now.timeIntervalSince($0.at) < ContinueWatching.window }
            + [PlaybackStop(item: item, time: time, duration: duration, at: now)]
        if let index {
            let watched = time / duration >= 0.9
            try? index.updateProgress(ratingKey: item.ratingKey,
                                      viewOffset: watched ? 0 : Int(time * 1000),
                                      viewCount: watched ? (item.viewCount ?? 0) + 1 : nil)
        }
        revision += 1
        followUp?.cancel()
        followUp = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.revision += 1
        }
    }
    @ObservationIgnored private var followUp: Task<Void, Never>?

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
