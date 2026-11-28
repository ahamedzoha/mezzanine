import Foundation

/// Keeps the local index in step with the server.
///
/// - First sync of a section pages through everything.
/// - After that, two cheap incremental queries per type: items changed
///   (`updatedAt>`) and items watched (`lastViewedAt>`) since the last sync.
/// - A full pass reconciles deletions and unwatched marks: when the server's
///   count differs from the index, or once a day.
public actor LibrarySync {
    public struct Progress: Sendable {
        public let section: String
        public let done: Int
        public let total: Int
    }

    let client: PlexServerClient
    let index: LibraryIndex
    static let pageSize = 300
    static let fullSyncInterval: TimeInterval = 24 * 3600

    public init(client: PlexServerClient, index: LibraryIndex) {
        self.client = client
        self.index = index
    }

    /// Plex type numbers to index per section kind: movies, or shows + episodes.
    public static func types(for section: PlexLibrarySection) -> [(type: Int, kind: String)] {
        switch section.kind {
        case .movie: return [(1, "movie")]
        case .show: return [(2, "show"), (4, "episode")]
        case .artist: return [(8, "artist"), (9, "album"), (10, "track")]
        default: return []
        }
    }

    /// Syncs one section. Returns true when anything changed.
    @discardableResult
    public func sync(_ section: PlexLibrarySection, force: Bool = false,
                     progress: (@Sendable (Progress) -> Void)? = nil) async throws -> Bool {
        let types = Self.types(for: section)
        guard !types.isEmpty else { return false }
        let state = try index.syncState(section: section.key)
        let now = Date()
        let needsFull = force || state == nil
            || now.timeIntervalSince1970 - (state?.lastFullSyncAt ?? 0) > Self.fullSyncInterval
        if needsFull {
            try await fullSync(section, types: types, progress: progress)
            try index.recordSync(section: section.key, at: now, full: true)
            try await musicDetailPass(section)
            return true
        }
        // Incremental, with a small overlap for clock skew.
        let since = Int((state?.lastSyncedAt ?? 0) - 120)
        var changed = false
        for (type, kind) in types {
            for filter in ["updatedAt>", "lastViewedAt>"] {
                let page = try await client.rawItems(section: section.key, type: type, offset: 0, limit: 2000,
                                                     filters: [URLQueryItem(name: filter, value: String(since))])
                if !page.items.isEmpty {
                    try index.upsert(page.items, section: section.key)
                    changed = true
                }
            }
            // Counts disagree: something was added or removed that the filters missed.
            let serverCount = try await client.count(section: section.key, type: type)
            let local = try index.count(section: section.key, kinds: [kind])
            if serverCount != local {
                try await fullSync(section, types: types, progress: progress)
                try index.recordSync(section: section.key, at: now, full: true)
                try await musicDetailPass(section)
                return true
            }
        }
        try index.recordSync(section: section.key, at: now, full: false)
        if try await musicDetailPass(section) > 0 { changed = true }
        return changed
    }

    /// Fetches the detail a music listing lacks (streams with loudness, ramps and lyrics, moods,
    /// styles, album formats, guids), 100 items a call, only for rows that are new or changed
    /// since their detail was stored. A first pass over a few thousand tracks is a few dozen
    /// calls (about 12 s on a LAN). Returns how many items it filled; does nothing for video.
    @discardableResult
    public func musicDetailPass(_ section: PlexLibrarySection,
                                progress: (@Sendable (Progress) -> Void)? = nil) async throws -> Int {
        guard section.kind == .artist else { return 0 }
        let pending = try index.musicKeysNeedingDetail(section: section.key)
        guard !pending.isEmpty else { return 0 }
        var done = 0
        for batch in pending.chunked(into: PlexServerClient.musicBatchSize) {
            try Task.checkCancellation()
            let rows = try await client.rawMusicMetadata(keys: batch)
            try index.storeMusicDetail(rows)
            done += batch.count
            progress?(Progress(section: section.title, done: done, total: pending.count))
        }
        return done
    }

    /// Drops libraries the server no longer lists (deleted, or no longer shared with this
    /// user). `keys` must come from a successful answer. Returns true when any titles went.
    public func dropMissingSections(listed keys: Set<String>) throws -> Bool {
        try index.pruneSections(keeping: keys) > 0
    }

    /// Reads one title again after its watch state changed: its own row, its show's (the watched
    /// count), and a show's or season's episodes. The incremental sync misses unwatched marks.
    public func refresh(_ item: PlexMetadata) async throws {
        var keys = [item.ratingKey]
        if let show = item.kind == .season ? item.parentRatingKey : item.grandparentRatingKey { keys.append(show) }
        guard let section = try keys.lazy.compactMap({ try index.item($0)?.section }).first
            ?? item.librarySectionID.map(String.init) else { return }
        var rows = try await client.rawMetadata(keys)
        rows += try await client.rawEpisodes(of: item)
        try index.upsert(rows.filter { [.movie, .show, .episode, .artist, .album, .track].contains($0.0.kind) }, section: section)
    }

    private func fullSync(_ section: PlexLibrarySection, types: [(type: Int, kind: String)],
                          progress: (@Sendable (Progress) -> Void)?) async throws {
        for (type, kind) in types {
            var offset = 0
            var keys = Set<String>()
            var total = 0
            repeat {
                try Task.checkCancellation()
                let page = try await client.rawItems(section: section.key, type: type, offset: offset, limit: Self.pageSize)
                total = page.totalSize ?? (offset + page.items.count)
                try index.upsert(page.items, section: section.key)
                keys.formUnion(page.items.map(\.0.ratingKey))
                offset += page.items.count
                progress?(Progress(section: section.title, done: offset, total: total))
                if page.items.isEmpty { break }
            } while offset < total
            try index.prune(section: section.key, keeping: keys, kinds: [kind])
        }
    }
}
