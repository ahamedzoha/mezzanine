import Foundation
import GRDB

/// One title in the local index: the columns browsing sorts and filters on,
/// plus the item's original Plex JSON so the full `PlexMetadata` (art,
/// UltraBlur, media, people) decodes without a network round trip.
public struct IndexedItem: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "item"

    public var ratingKey: String
    public var section: String
    public var kind: String
    public var title: String
    public var titleSort: String
    public var year: Int?
    public var addedAt: Double?
    public var updatedAt: Double?
    public var lastViewedAt: Double?
    public var originallyAvailableAt: String?
    public var viewCount: Int
    public var viewOffset: Int
    public var duration: Int?
    public var leafCount: Int?
    public var viewedLeafCount: Int?
    public var rating: Double?
    public var audienceRating: Double?
    public var contentRating: String?
    public var resolution: String?
    public var isHDR: Bool
    public var audioChannels: Int?
    /// "|Drama|Crime|" — pipe-wrapped so `LIKE '%|Drama|%'` matches whole names.
    public var genres: String
    /// "|Tom Hanks|Nora Ephron|" (directors, writers, first 15 cast), pipe-wrapped like genres.
    public var people: String
    /// "|IMDb Top 250|Action Movies|", pipe-wrapped like genres.
    public var collections: String
    public var summary: String
    public var parentRatingKey: String?
    public var grandparentRatingKey: String?
    public var index: Int?
    public var parentIndex: Int?
    /// The clean (pre-overlay) poster, resolved lazily when the clean-poster setting is on.
    public var cleanPosterPath: String?
    public var json: Data

    public var isWatched: Bool {
        if kind == "show" || kind == "season" {
            guard let leafCount, leafCount > 0 else { return false }
            return (viewedLeafCount ?? 0) >= leafCount
        }
        return viewCount > 0 && viewOffset == 0
    }

    public var isInProgress: Bool { viewOffset > 0 }

    public func metadata() -> PlexMetadata? {
        try? JSONDecoder().decode(PlexMetadata.self, from: json)
    }
}

/// Per-section sync bookkeeping.
struct SectionSyncState: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "sectionSync"
    var section: String
    var lastSyncedAt: Double
    var lastFullSyncAt: Double
    var itemCount: Int
}

/// What a library page asks the index for. Everything here is answered from
/// SQLite in milliseconds; the server is never asked while browsing.
public struct LibraryQuery: Sendable, Equatable, Hashable {
    public enum Sort: String, Sendable, CaseIterable, Codable {
        case title, addedNewest, releasedNewest, releasedOldest, rating, lastWatched, duration

        public var label: String {
            switch self {
            case .title: return "Title"
            case .addedNewest: return "Recently Added"
            case .releasedNewest: return "Newest Release"
            case .releasedOldest: return "Oldest Release"
            case .rating: return "Rating"
            case .lastWatched: return "Recently Watched"
            case .duration: return "Longest"
            }
        }
    }

    public var section: String
    public var kinds: [String]
    public var sort: Sort = .title
    public var unwatchedOnly = false
    public var inProgressOnly = false
    public var watchedOnly = false
    public var genre: String?
    public var decade: Int?
    public var resolution: String?
    public var hdrOnly = false
    public var minAudioChannels: Int?
    public var text: String?

    public init(section: String, kinds: [String], sort: Sort = .title) {
        self.section = section
        self.kinds = kinds
        self.sort = sort
    }

    public var hasFilters: Bool {
        unwatchedOnly || inProgressOnly || watchedOnly || genre != nil || decade != nil || resolution != nil || hdrOnly || minAudioChannels != nil
    }
}

/// The local mirror of one server's libraries for one Plex user.
public final class LibraryIndex: Sendable {
    let pool: DatabasePool

    /// `Application Support/Mezzanine/Index/<server>-<user>.sqlite` (inside the sandbox container).
    public static func open(serverID: String, userID: String) throws -> LibraryIndex {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
            .appendingPathComponent("Mezzanine/Index", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let safe = "\(serverID)-\(userID)".replacingOccurrences(of: "/", with: "_")
        return try LibraryIndex(path: base.appendingPathComponent("\(safe).sqlite").path)
    }

    public init(path: String) throws {
        var config = Configuration()
        config.label = "mezzanine.index"
        pool = try DatabasePool(path: path, configuration: config)
        try Self.migrator.migrate(pool)
    }

    /// In-memory index for tests.
    public init(inMemory: Void = ()) throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("idx-\(UUID().uuidString).sqlite").path
        pool = try DatabasePool(path: path)
        try Self.migrator.migrate(pool)
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "item") { t in
                t.primaryKey("ratingKey", .text)
                t.column("section", .text).notNull().indexed()
                t.column("kind", .text).notNull().indexed()
                t.column("title", .text).notNull()
                t.column("titleSort", .text).notNull()
                t.column("year", .integer)
                t.column("addedAt", .double)
                t.column("updatedAt", .double)
                t.column("lastViewedAt", .double)
                t.column("originallyAvailableAt", .text)
                t.column("viewCount", .integer).notNull().defaults(to: 0)
                t.column("viewOffset", .integer).notNull().defaults(to: 0)
                t.column("duration", .integer)
                t.column("leafCount", .integer)
                t.column("viewedLeafCount", .integer)
                t.column("rating", .double)
                t.column("audienceRating", .double)
                t.column("contentRating", .text)
                t.column("resolution", .text)
                t.column("isHDR", .boolean).notNull().defaults(to: false)
                t.column("audioChannels", .integer)
                t.column("genres", .text).notNull().defaults(to: "")
                t.column("people", .text).notNull().defaults(to: "")
                t.column("collections", .text).notNull().defaults(to: "")
                t.column("summary", .text).notNull().defaults(to: "")
                t.column("parentRatingKey", .text).indexed()
                t.column("grandparentRatingKey", .text).indexed()
                t.column("index", .integer)
                t.column("parentIndex", .integer)
                t.column("cleanPosterPath", .text)
                t.column("json", .blob).notNull()
            }
            try db.create(virtualTable: "item_ft", using: FTS5()) { t in
                t.synchronize(withTable: "item")
                t.tokenizer = .unicode61(diacritics: .remove)
                t.column("title")
                t.column("people")
                t.column("collections")
                t.column("summary")
            }
            try db.create(table: "sectionSync") { t in
                t.primaryKey("section", .text)
                t.column("lastSyncedAt", .double).notNull()
                t.column("lastFullSyncAt", .double).notNull()
                t.column("itemCount", .integer).notNull()
            }
        }
        // v2: people and collections became pipe-wrapped for exact smart-shelf matches; the
        // next sync of each section runs in full to rewrite them.
        m.registerMigration("v2") { db in
            try db.execute(sql: "UPDATE sectionSync SET lastFullSyncAt = 0")
        }
        return m
    }

    // MARK: Writes

    /// Inserts or replaces items, keeping any clean poster already resolved.
    public func upsert(_ entries: [(PlexMetadata, Data)], section: String) throws {
        try pool.write { db in
            for (meta, json) in entries {
                var row = IndexedItem(meta, json: json, section: section)
                row.cleanPosterPath = try String.fetchOne(db, sql: "SELECT cleanPosterPath FROM item WHERE ratingKey = ?",
                                                          arguments: [meta.ratingKey])
                try row.save(db)
            }
        }
    }

    /// Removes items of a section that the server no longer lists.
    public func prune(section: String, keeping keys: Set<String>, kinds: [String]) throws {
        try pool.write { db in
            let existing = try String.fetchAll(db, sql: "SELECT ratingKey FROM item WHERE section = ? AND kind IN (\(kinds.map { _ in "?" }.joined(separator: ",")))",
                                               arguments: StatementArguments([section] + kinds))
            let gone = existing.filter { !keys.contains($0) }
            for key in gone { _ = try IndexedItem.deleteOne(db, key: key) }
        }
    }

    public func setCleanPoster(_ path: String, for ratingKey: String) throws {
        try pool.write { db in
            try db.execute(sql: "UPDATE item SET cleanPosterPath = ? WHERE ratingKey = ?", arguments: [path, ratingKey])
        }
    }

    /// Applies a watch-state change seen live (websocket or after playback).
    public func updateProgress(ratingKey: String, viewOffset: Int, viewCount: Int?) throws {
        try pool.write { db in
            if let viewCount {
                try db.execute(sql: "UPDATE item SET viewOffset = ?, viewCount = ? WHERE ratingKey = ?", arguments: [viewOffset, viewCount, ratingKey])
            } else {
                try db.execute(sql: "UPDATE item SET viewOffset = ? WHERE ratingKey = ?", arguments: [viewOffset, ratingKey])
            }
        }
    }

    func recordSync(section: String, at date: Date, full: Bool) throws {
        try pool.write { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item WHERE section = ?", arguments: [section]) ?? 0
            var state = try SectionSyncState.fetchOne(db, key: section)
                ?? SectionSyncState(section: section, lastSyncedAt: 0, lastFullSyncAt: 0, itemCount: 0)
            state.lastSyncedAt = date.timeIntervalSince1970
            if full { state.lastFullSyncAt = date.timeIntervalSince1970 }
            state.itemCount = count
            try state.save(db)
        }
    }

    func syncState(section: String) throws -> SectionSyncState? {
        try pool.read { db in try SectionSyncState.fetchOne(db, key: section) }
    }

    // MARK: Reads

    public func items(_ q: LibraryQuery) throws -> [IndexedItem] {
        try pool.read { db in
            var sql = "SELECT item.* FROM item"
            var args: [any DatabaseValueConvertible] = []
            var clauses: [String] = ["item.section = ?"]
            args.append(q.section)
            if let text = q.text?.trimmingCharacters(in: .whitespaces), !text.isEmpty,
               let pattern = FTS5Pattern(matchingAllPrefixesIn: text) {
                sql += " JOIN item_ft ON item_ft.rowid = item.rowid AND item_ft MATCH ?"
                args.append(pattern.rawPattern)
            }
            if !q.kinds.isEmpty {
                clauses.append("item.kind IN (\(q.kinds.map { _ in "?" }.joined(separator: ",")))")
                args += q.kinds
            }
            if q.unwatchedOnly {
                clauses.append("((item.kind IN ('show','season') AND COALESCE(item.viewedLeafCount,0) < COALESCE(item.leafCount,0)) OR (item.kind NOT IN ('show','season') AND item.viewCount = 0))")
            }
            if q.inProgressOnly { clauses.append("item.viewOffset > 0") }
            if q.watchedOnly {
                clauses.append("((item.kind IN ('show','season') AND COALESCE(item.leafCount,0) > 0 AND COALESCE(item.viewedLeafCount,0) >= item.leafCount) OR (item.kind NOT IN ('show','season') AND item.viewCount > 0 AND item.viewOffset = 0))")
            }
            if let genre = q.genre { clauses.append("item.genres LIKE ?"); args.append("%|\(genre)|%") }
            if let decade = q.decade { clauses.append("item.year BETWEEN ? AND ?"); args += [decade, decade + 9] }
            if let res = q.resolution { clauses.append("item.resolution = ?"); args.append(res) }
            if q.hdrOnly { clauses.append("item.isHDR = 1") }
            if let ch = q.minAudioChannels { clauses.append("item.audioChannels >= ?"); args.append(ch) }
            sql += " WHERE " + clauses.joined(separator: " AND ")
            sql += " ORDER BY " + Self.order(q.sort)
            return try IndexedItem.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }
    }

    /// Whole-library search across every section (titles, people, collections, summaries).
    public func search(_ text: String, kinds: [String] = ["movie", "show", "episode"], limit: Int = 80) throws -> [IndexedItem] {
        guard let pattern = FTS5Pattern(matchingAllPrefixesIn: text) else { return [] }
        return try pool.read { db in
            try IndexedItem.fetchAll(db, sql: """
                SELECT item.* FROM item JOIN item_ft ON item_ft.rowid = item.rowid AND item_ft MATCH ?
                WHERE item.kind IN (\(kinds.map { _ in "?" }.joined(separator: ",")))
                ORDER BY CASE item.kind WHEN 'episode' THEN 1 ELSE 0 END, bm25(item_ft, 10.0, 3.0, 2.0, 1.0)
                LIMIT ?
                """, arguments: StatementArguments([pattern.rawPattern] + kinds + [limit]))
        }
    }

    public func item(_ ratingKey: String) throws -> IndexedItem? {
        try pool.read { db in try IndexedItem.fetchOne(db, key: ratingKey) }
    }

    /// Genres in a section with how many titles carry each, most common first.
    public func genres(section: String, kinds: [String]) throws -> [(String, Int)] {
        try pool.read { db in
            let rows = try String.fetchAll(db, sql: "SELECT genres FROM item WHERE section = ? AND kind IN (\(kinds.map { _ in "?" }.joined(separator: ",")))",
                                           arguments: StatementArguments([section] + kinds))
            var counts: [String: Int] = [:]
            for row in rows { for g in row.split(separator: "|") where !g.isEmpty { counts[String(g), default: 0] += 1 } }
            return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        }
    }

    public func count(section: String) throws -> Int {
        try pool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item WHERE section = ?", arguments: [section]) ?? 0 }
    }

    static func order(_ sort: LibraryQuery.Sort) -> String {
        switch sort {
        case .title: return "item.titleSort COLLATE NOCASE ASC"
        case .addedNewest: return "item.addedAt DESC"
        case .releasedNewest: return "COALESCE(item.originallyAvailableAt, item.year) DESC"
        case .releasedOldest: return "COALESCE(item.originallyAvailableAt, item.year) ASC"
        case .rating: return "COALESCE(item.audienceRating, item.rating, 0) DESC"
        case .lastWatched: return "COALESCE(item.lastViewedAt, 0) DESC"
        case .duration: return "COALESCE(item.duration, 0) DESC"
        }
    }
}

extension IndexedItem {
    init(_ m: PlexMetadata, json: Data, section: String) {
        let media = m.media.first
        let video = media?.parts.first?.streams.first { $0.streamType == .video }
        ratingKey = m.ratingKey
        self.section = section
        kind = m.kind.rawValue
        title = m.title
        titleSort = Self.sortKey(m.titleSort ?? m.title)
        year = m.year
        addedAt = m.addedAt?.timeIntervalSince1970
        updatedAt = m.updatedAt?.timeIntervalSince1970
        lastViewedAt = m.lastViewedAt?.timeIntervalSince1970
        originallyAvailableAt = m.originallyAvailableAt
        viewCount = m.viewCount ?? 0
        viewOffset = m.viewOffset ?? 0
        duration = m.duration
        leafCount = m.leafCount
        viewedLeafCount = m.viewedLeafCount
        rating = m.rating
        audienceRating = m.audienceRating
        contentRating = m.contentRating
        resolution = media?.videoResolution
        isHDR = video?.isHDR == true || video?.isDolbyVision == true
        audioChannels = media?.audioChannels
        genres = m.genres.isEmpty ? "" : "|" + m.genres.map(\.tag).joined(separator: "|") + "|"
        people = Self.wrapped((m.directors + m.writers).map(\.tag) + m.roles.prefix(15).map(\.tag))
        collections = Self.wrapped(m.collections.map(\.tag))
        summary = m.summary ?? ""
        parentRatingKey = m.parentRatingKey
        grandparentRatingKey = m.grandparentRatingKey
        index = m.index
        parentIndex = m.parentIndex
        cleanPosterPath = nil
        self.json = json
    }

    /// "|A|B|", or "" for none: whole-name matching with `LIKE '%|A|%'`.
    static func wrapped(_ names: [String]) -> String {
        names.isEmpty ? "" : "|" + names.joined(separator: "|") + "|"
    }

    /// "The Uprising" sorts under U, like Plex.
    static func sortKey(_ title: String) -> String {
        let lowered = title.lowercased()
        for article in ["the ", "a ", "an "] where lowered.hasPrefix(article) {
            return String(title.dropFirst(article.count))
        }
        return title
    }
}
