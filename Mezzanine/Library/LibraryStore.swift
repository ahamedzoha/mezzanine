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

    /// Show the agent's original posters instead of the server's selected
    /// (overlaid) ones. Display only: nothing changes on the server.
    var prefersCleanPosters: Bool = UserDefaults.standard.bool(forKey: "cleanPosters") {
        didSet { UserDefaults.standard.set(prefersCleanPosters, forKey: "cleanPosters") }
    }

    private var sync: LibrarySync?
    private var client: PlexServerClient?
    private var sections: [PlexLibrarySection] = []
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
                    }
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
        return await Task.detached(priority: .userInitiated) {
            ((try? index.search(text)) ?? []).compactMap { $0.metadata() }
        }.value
    }

    func genres(section: String, kinds: [String]) -> [String] {
        ((try? index?.genres(section: section, kinds: kinds)) ?? []).map(\.0)
    }

    func count(section: String) -> Int { (try? index?.count(section: section)) ?? 0 }

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

    /// The poster path to draw for an item, honouring the clean-poster setting.
    func posterPath(for item: PlexMetadata) -> String? {
        guard prefersCleanPosters else { return item.posterPath }
        let key = item.kind == .episode ? (item.grandparentRatingKey ?? item.ratingKey) : item.ratingKey
        return cleanPosters[key] ?? item.posterPath
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
