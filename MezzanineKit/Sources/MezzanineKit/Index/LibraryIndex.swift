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
    /// "plex://movie/5d77…", shared with Plex's watchlist.
    public var guid: String?
    public var index: Int?
    public var parentIndex: Int?
    /// The clean (pre-overlay) poster, resolved lazily when the clean-poster setting is on.
    public var cleanPosterPath: String?

    // Music (also filled for video where Plex sends them: episodes carry their show's title).
    /// A track's album, an album's artist, an episode's season.
    public var parentTitle: String?
    /// A track's artist, an episode's show.
    public var grandparentTitle: String?
    /// A track's own artist when it differs from the album artist.
    public var originalTitle: String?
    /// An album's label (a track's comes from its album).
    public var studio: String?
    /// `AlbumType` raw value, on albums (needs the detail pass).
    public var albumType: String?
    /// "|Mellow|Dark|", pipe-wrapped like genres (moods, styles and countries need the detail pass).
    public var moods: String
    public var styles: String
    public var countries: String
    /// Artist, album, track artist and label as plain words, for search.
    public var credits: String
    public var userRating: Double?
    public var skipCount: Int?
    public var ratingCount: Int?
    // A track's audio, from the detail pass.
    public var audioCodec: String?
    public var bitDepth: Int?
    public var samplingRate: Int?
    public var gainDB: Double?
    public var albumGainDB: Double?
    public var peak: Double?
    public var loudness: Double?
    public var hasLyrics: Bool
    /// MusicBrainz id (also in `external_id`).
    public var mbid: String?
    public var json: Data

    public var isWatched: Bool {
        if kind == "artist" || kind == "album" { return false }
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
        // Music
        case mostPlayed, artist, album, year, recentlyPlayed

        public var label: String {
            switch self {
            case .title: return "Title"
            case .addedNewest: return "Recently Added"
            case .releasedNewest: return "Newest Release"
            case .releasedOldest: return "Oldest Release"
            case .rating: return "Rating"
            case .lastWatched: return "Recently Watched"
            case .duration: return "Longest"
            case .mostPlayed: return "Most Played"
            case .artist: return "Artist"
            case .album: return "Album"
            case .year: return "Year"
            case .recentlyPlayed: return "Recently Played"
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
    // Music
    /// Children of one artist or album (`parentRatingKey`), or of an artist's albums for tracks (`grandparentRatingKey`).
    public var parentRatingKey: String?
    public var grandparentRatingKey: String?
    /// `AlbumType` raw value.
    public var albumType: String?
    public var mood: String?
    public var style: String?

    public init(section: String, kinds: [String], sort: Sort = .title) {
        self.section = section
        self.kinds = kinds
        self.sort = sort
    }

    public var hasFilters: Bool {
        unwatchedOnly || inProgressOnly || watchedOnly || genre != nil || decade != nil || resolution != nil || hdrOnly || minAudioChannels != nil
            || parentRatingKey != nil || grandparentRatingKey != nil || albumType != nil || mood != nil || style != nil
    }
}

/// Watch state as SQL over `item`: shows and seasons by their episodes' counts, the rest by
/// their own. Library filters, smart shelves and sidebar counts share these.
enum WatchSQL {
    /// Artists and albums are containers of music: they never read as watched, unwatched or in
    /// progress (their tracks do, as played and unplayed).
    static let unwatched = "(item.kind NOT IN ('artist','album') AND ((item.kind IN ('show','season') AND COALESCE(item.viewedLeafCount,0) < COALESCE(item.leafCount,0)) OR (item.kind NOT IN ('show','season') AND item.viewCount = 0)))"
    static let inProgress = "(item.kind NOT IN ('artist','album') AND (item.viewOffset > 0 OR (item.kind IN ('show','season') AND COALESCE(item.viewedLeafCount,0) > 0 AND COALESCE(item.viewedLeafCount,0) < COALESCE(item.leafCount,0))))"
    static let watched = "(item.kind NOT IN ('artist','album') AND ((item.kind IN ('show','season') AND COALESCE(item.leafCount,0) > 0 AND COALESCE(item.viewedLeafCount,0) >= item.leafCount) OR (item.kind NOT IN ('show','season') AND item.viewCount > 0 AND item.viewOffset = 0)))"
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
        // v3: films' and shows' guids, for the watchlist; read out of the JSON already kept.
        m.registerMigration("v3") { db in
            try db.alter(table: "item") { t in t.add(column: "guid", .text) }
            try db.create(indexOn: "item", columns: ["guid"])
            try db.execute(sql: "UPDATE item SET guid = json_extract(CAST(json AS TEXT), '$.guid') WHERE kind IN ('movie','show')")
        }
        // v4: music. Item columns for artists, albums and tracks (backfilled from the stored JSON
        // like v3), a search column for credits (artist, album, label), the external-id table
        // (MusicBrainz now; TMDB/TVDB later) and the detail table the music detail pass fills.
        m.registerMigration("v4") { db in
            try db.alter(table: "item") { t in
                t.add(column: "parentTitle", .text)
                t.add(column: "grandparentTitle", .text)
                t.add(column: "originalTitle", .text)
                t.add(column: "studio", .text)
                t.add(column: "albumType", .text)
                t.add(column: "moods", .text).notNull().defaults(to: "")
                t.add(column: "styles", .text).notNull().defaults(to: "")
                t.add(column: "countries", .text).notNull().defaults(to: "")
                t.add(column: "credits", .text).notNull().defaults(to: "")
                t.add(column: "userRating", .double)
                t.add(column: "skipCount", .integer)
                t.add(column: "ratingCount", .integer)
                t.add(column: "audioCodec", .text)
                t.add(column: "bitDepth", .integer)
                t.add(column: "samplingRate", .integer)
                t.add(column: "gainDB", .double)
                t.add(column: "albumGainDB", .double)
                t.add(column: "peak", .double)
                t.add(column: "loudness", .double)
                t.add(column: "hasLyrics", .boolean).notNull().defaults(to: false)
                t.add(column: "mbid", .text)
            }
            try db.create(indexOn: "item", columns: ["mbid"])
            try db.create(indexOn: "item", columns: ["section", "kind"])
            try db.execute(sql: """
                UPDATE item SET
                    parentTitle = json_extract(CAST(json AS TEXT), '$.parentTitle'),
                    grandparentTitle = json_extract(CAST(json AS TEXT), '$.grandparentTitle'),
                    originalTitle = json_extract(CAST(json AS TEXT), '$.originalTitle'),
                    studio = COALESCE(json_extract(CAST(json AS TEXT), '$.studio'), json_extract(CAST(json AS TEXT), '$.parentStudio')),
                    userRating = json_extract(CAST(json AS TEXT), '$.userRating'),
                    skipCount = json_extract(CAST(json AS TEXT), '$.skipCount'),
                    ratingCount = json_extract(CAST(json AS TEXT), '$.ratingCount')
                """)
            try db.execute(sql: """
                UPDATE item SET
                    credits = trim(COALESCE(grandparentTitle, '') || ' ' || COALESCE(parentTitle, '') || ' ' ||
                                   COALESCE(originalTitle, '') || ' ' || COALESCE(studio, ''))
                WHERE kind IN ('artist', 'album', 'track')
                """)
            try db.create(table: "external_id", options: .withoutRowID) { t in
                t.column("ratingKey", .text).notNull().references("item", onDelete: .cascade)
                t.column("scheme", .text).notNull()
                t.column("value", .text).notNull()
                t.primaryKey(["ratingKey", "scheme", "value"])
            }
            try db.create(indexOn: "external_id", columns: ["scheme", "value"])
            try db.execute(sql: """
                INSERT OR IGNORE INTO external_id (ratingKey, scheme, value)
                SELECT ratingKey, substr(g, 1, instr(g, '://') - 1), substr(g, instr(g, '://') + 3)
                FROM (SELECT item.ratingKey AS ratingKey, json_extract(j.value, '$.id') AS g
                      FROM item, json_each(CAST(item.json AS TEXT), '$.Guid') j)
                WHERE g LIKE '%://%'
                """)
            try db.execute(sql: """
                UPDATE item SET mbid = (SELECT value FROM external_id e WHERE e.ratingKey = item.ratingKey AND e.scheme = 'mbid' LIMIT 1)
                """)
            try db.create(table: "musicDetail") { t in
                t.primaryKey("ratingKey", .text).references("item", onDelete: .cascade)
                t.column("updatedAt", .double).notNull()
                t.column("json", .blob).notNull()
            }
            // Search gains the credits column: rebuild the FTS table (and its triggers) around it.
            for trigger in ["__item_ft_ai", "__item_ft_ad", "__item_ft_au"] {
                try db.execute(sql: "DROP TRIGGER IF EXISTS \(trigger)")
            }
            try db.drop(table: "item_ft")
            try db.create(virtualTable: "item_ft", using: FTS5()) { t in
                t.synchronize(withTable: "item")
                t.tokenizer = .unicode61(diacritics: .remove)
                t.column("title")
                t.column("people")
                t.column("collections")
                t.column("summary")
                t.column("credits")
            }
        }
        return m
    }

    // MARK: Writes

    /// Columns the detail pass owns: a listing row (which lacks them) must not blank what the
    /// pass stored. Text columns keep the old value when the new one is empty, numbers when it is NULL.
    static let detailText: Set<String> = ["moods", "styles", "countries"]
    static let detailNumber: Set<String> = ["albumType", "audioCodec", "bitDepth", "samplingRate", "gainDB", "albumGainDB", "peak", "loudness"]

    /// Inserts items or updates them in one statement each (no read first), keeping any clean
    /// poster already resolved and the music detail a plain listing doesn't carry.
    public func upsert(_ entries: [(PlexMetadata, Data)], section: String) throws {
        try pool.write { db in
            var sql: String?
            for (meta, json) in entries {
                let row = IndexedItem(meta, json: json, section: section)
                let values = try row.databaseDictionary
                let columns = values.keys.sorted()
                if sql == nil {
                    let names = columns.map { "\"\($0)\"" }.joined(separator: ", ")
                    let marks = columns.map { _ in "?" }.joined(separator: ", ")
                    let updates = columns.compactMap { c -> String? in
                        let q = "\"\(c)\""
                        switch c {
                        case "ratingKey", "cleanPosterPath": return nil
                        case _ where Self.detailText.contains(c): return "\(q) = CASE WHEN excluded.\(q) = '' THEN item.\(q) ELSE excluded.\(q) END"
                        case _ where Self.detailNumber.contains(c): return "\(q) = COALESCE(excluded.\(q), item.\(q))"
                        case "hasLyrics": return "\(q) = MAX(excluded.\(q), item.\(q))"
                        default: return "\(q) = excluded.\(q)"
                        }
                    }.joined(separator: ", ")
                    sql = "INSERT INTO item (\(names)) VALUES (\(marks)) ON CONFLICT(ratingKey) DO UPDATE SET \(updates)"
                }
                let statement = try db.cachedStatement(sql: sql!)
                try statement.execute(arguments: StatementArguments(columns.map { values[$0] ?? .null }))
                try Self.syncExternalIDs(db, ratingKey: meta.ratingKey, guids: meta.externalGuids)
            }
        }
    }

    /// `scheme://value` guids into `external_id`, replacing what the item had.
    static func syncExternalIDs(_ db: Database, ratingKey: String, guids: [String]) throws {
        let pairs: [(String, String)] = guids.compactMap { guid in
            guard let r = guid.range(of: "://") else { return nil }
            return (String(guid[..<r.lowerBound]), String(guid[r.upperBound...]))
        }
        guard !pairs.isEmpty else { return }
        let insert = try db.cachedStatement(sql: "INSERT OR IGNORE INTO external_id (ratingKey, scheme, value) VALUES (?, ?, ?)")
        for (scheme, value) in pairs { try insert.execute(arguments: [ratingKey, scheme, value]) }
        // Plex re-matched the title: drop ids it no longer lists.
        let keep = pairs.map { "\($0.0)\u{1F}\($0.1)" }
        try db.execute(sql: "DELETE FROM external_id WHERE ratingKey = ? AND scheme || char(31) || value NOT IN (\(keep.map { _ in "?" }.joined(separator: ",")))",
                       arguments: StatementArguments([ratingKey] + keep))
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

    /// Removes every section not in `keys`, titles and sync state, and returns how many titles
    /// went. An empty list removes nothing: it's more likely a bad answer than an empty server.
    public func pruneSections(keeping keys: Set<String>) throws -> Int {
        guard !keys.isEmpty else { return 0 }
        return try pool.write { db in
            let marks = keys.map { _ in "?" }.joined(separator: ",")
            let arguments = StatementArguments(Array(keys))
            try db.execute(sql: "DELETE FROM item WHERE section NOT IN (\(marks))", arguments: arguments)
            let removed = db.changesCount
            try db.execute(sql: "DELETE FROM sectionSync WHERE section NOT IN (\(marks))", arguments: arguments)
            return removed
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
        let (from, args) = Self.from(q)
        return try pool.read { db in
            try IndexedItem.fetchAll(db, sql: "SELECT item.* \(from) ORDER BY \(Self.order(q.sort))", arguments: StatementArguments(args))
        }
    }

    /// How many titles `items` would return. Counted in SQLite: loading and sorting the rows
    /// spills to disk.
    public func count(_ q: LibraryQuery) throws -> Int {
        let (from, args) = Self.from(q)
        return try pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) \(from)", arguments: StatementArguments(args)) ?? 0
        }
    }

    /// A random title of these sections and kinds (Surprise Me); nil when none match.
    public func random(sections: [String], kinds: [String], unwatchedOnly: Bool = true) throws -> IndexedItem? {
        guard !sections.isEmpty, !kinds.isEmpty else { return nil }
        func marks(_ list: [String]) -> String { list.map { _ in "?" }.joined(separator: ",") }
        var clauses = ["item.section IN (\(marks(sections)))", "item.kind IN (\(marks(kinds)))"]
        if unwatchedOnly { clauses.append(WatchSQL.unwatched) }
        // The key alone is shuffled; the row (with its JSON) is read for the one chosen.
        return try pool.read { db in
            try IndexedItem.fetchOne(db, sql: """
                SELECT * FROM item WHERE ratingKey =
                    (SELECT ratingKey FROM item WHERE \(clauses.joined(separator: " AND ")) ORDER BY RANDOM() LIMIT 1)
                """, arguments: StatementArguments(sections + kinds))
        }
    }

    /// "FROM item … WHERE …" for a query, shared by the rows and their count.
    private static func from(_ q: LibraryQuery) -> (String, [any DatabaseValueConvertible]) {
        var sql = "FROM item"
        var args: [any DatabaseValueConvertible] = []
        var clauses: [String] = ["item.section = ?"]
        if let text = q.text?.trimmingCharacters(in: .whitespaces), !text.isEmpty,
           let pattern = FTS5Pattern(matchingAllPrefixesIn: text) {
            sql += " JOIN item_ft ON item_ft.rowid = item.rowid AND item_ft MATCH ?"
            args.append(pattern.rawPattern)
        }
        args.append(q.section)
        if !q.kinds.isEmpty {
            clauses.append("item.kind IN (\(q.kinds.map { _ in "?" }.joined(separator: ",")))")
            args += q.kinds
        }
        if q.unwatchedOnly { clauses.append(WatchSQL.unwatched) }
        if q.inProgressOnly { clauses.append(WatchSQL.inProgress) }
        if q.watchedOnly { clauses.append(WatchSQL.watched) }
        if let genre = q.genre { clauses.append("item.genres LIKE ?"); args.append("%|\(genre)|%") }
        if let decade = q.decade { clauses.append("item.year BETWEEN ? AND ?"); args += [decade, decade + 9] }
        if let res = q.resolution { clauses.append("item.resolution = ?"); args.append(res) }
        if let key = q.parentRatingKey { clauses.append("item.parentRatingKey = ?"); args.append(key) }
        if let key = q.grandparentRatingKey { clauses.append("item.grandparentRatingKey = ?"); args.append(key) }
        if let type = q.albumType { clauses.append("item.albumType = ?"); args.append(type) }
        if let mood = q.mood { clauses.append("item.moods LIKE ?"); args.append("%|\(mood)|%") }
        if let style = q.style { clauses.append("item.styles LIKE ?"); args.append("%|\(style)|%") }
        if q.hdrOnly { clauses.append("item.isHDR = 1") }
        if let ch = q.minAudioChannels { clauses.append("item.audioChannels >= ?"); args.append(ch) }
        return (sql + " WHERE " + clauses.joined(separator: " AND "), args)
    }

    /// Whole-library search across every section (titles, people, collections, summaries).
    /// Titles matching every typed word as a prefix (titles, people, collections, summaries).
    /// Ranked the way people expect: titles that start with the text, then titles with a word
    /// that starts with it, then the rest; within each, titles from `demotedSections` (personal
    /// media such as lessons) come after films and shows, then by relevance. Episodes last.
    public func search(_ text: String, kinds: [String] = ["movie", "show", "episode"], limit: Int = 80,
                       demotedSections: [String] = []) throws -> [IndexedItem] {
        guard let pattern = FTS5Pattern(matchingAllPrefixesIn: text) else { return [] }
        let typed = text.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: "%", with: "").replacingOccurrences(of: "_", with: "")
        let demoted = demotedSections.isEmpty ? "''" : demotedSections.map { _ in "?" }.joined(separator: ",")
        return try pool.read { db in
            try IndexedItem.fetchAll(db, sql: """
                SELECT item.* FROM item JOIN item_ft ON item_ft.rowid = item.rowid AND item_ft MATCH ?
                WHERE item.kind IN (\(kinds.map { _ in "?" }.joined(separator: ",")))
                ORDER BY CASE item.kind WHEN 'episode' THEN 1 ELSE 0 END,
                         CASE WHEN lower(item.title) LIKE ? || '%' THEN 0
                              WHEN lower(item.title) LIKE '% ' || ? || '%' OR lower(item.title) LIKE '%-' || ? || '%'
                                OR lower(item.title) LIKE '%.' || ? || '%' OR lower(item.title) LIKE '%:' || ? || '%'
                                OR lower(item.title) LIKE '%(' || ? || '%' THEN 1 ELSE 2 END,
                         CASE WHEN item.section IN (\(demoted)) THEN 1 ELSE 0 END,
                         bm25(item_ft, 10.0, 3.0, 2.0, 1.0, 4.0)
                LIMIT ?
                """, arguments: StatementArguments([pattern.rawPattern] + kinds + Array(repeating: typed, count: 6) + demotedSections + [limit]))
        }
    }

    /// Unwatched episodes added after `since` (seconds since 1970) to shows being watched: at
    /// least one episode seen, the last within `activeWithin` seconds. Grouped by show, in
    /// season and episode order.
    public func newEpisodes(since: Double, activeWithin: Double = 365 * 86_400,
                            now: Double = Date().timeIntervalSince1970) throws -> [(show: IndexedItem, episodes: [IndexedItem])] {
        try pool.read { db in
            let episodes = try IndexedItem.fetchAll(db, sql: """
                SELECT e.* FROM item e JOIN item s ON s.ratingKey = e.grandparentRatingKey
                WHERE e.kind = 'episode' AND e.addedAt > ? AND e.viewCount = 0
                  AND s.kind = 'show' AND COALESCE(s.viewedLeafCount, 0) > 0
                  AND COALESCE(s.lastViewedAt, 0) > ?
                ORDER BY s.titleSort, e.parentIndex, e.\"index\"
                """, arguments: [since, now - activeWithin])
            var order: [String] = []
            var groups: [String: [IndexedItem]] = [:]
            for e in episodes {
                guard let key = e.grandparentRatingKey else { continue }
                if groups[key] == nil { order.append(key) }
                groups[key, default: []].append(e)
            }
            return try order.compactMap { key in
                guard let show = try IndexedItem.fetchOne(db, key: key) else { return nil }
                return (show, groups[key] ?? [])
            }
        }
    }

    /// Films and shows by guid (the watchlist's titles that are on this server).
    public func items(guids: [String]) throws -> [IndexedItem] {
        guard !guids.isEmpty else { return [] }
        return try pool.read { db in
            try IndexedItem.fetchAll(db, sql: "SELECT * FROM item WHERE kind IN ('movie','show') AND guid IN (\(guids.map { _ in "?" }.joined(separator: ",")))",
                                     arguments: StatementArguments(guids))
        }
    }

    /// Every film and show of these sections, without their JSON (Spotlight).
    public func spotlightTitles(sections: [String]) throws -> [(ratingKey: String, kind: String, title: String, year: Int?, summary: String, genres: [String])] {
        guard !sections.isEmpty else { return [] }
        return try pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT ratingKey, kind, title, year, summary, genres FROM item
                WHERE kind IN ('movie','show') AND section IN (\(sections.map { _ in "?" }.joined(separator: ","))) ORDER BY ratingKey
                """, arguments: StatementArguments(sections)).map { row in
                let genres: String = row["genres"]
                return (row["ratingKey"], row["kind"], row["title"], row["year"], row["summary"],
                        genres.split(separator: "|").map(String.init))
            }
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

    public func count(section: String, kinds: [String]) throws -> Int {
        guard !kinds.isEmpty else { return 0 }
        return try count(LibraryQuery(section: section, kinds: kinds))
    }

    /// The artist a row belongs to: a track's, an album's, an artist's own name.
    private static let artistSortKey = "CASE item.kind WHEN 'track' THEN item.grandparentTitle WHEN 'album' THEN item.parentTitle ELSE item.titleSort END"
    private static let albumSortKey = "CASE item.kind WHEN 'track' THEN item.parentTitle WHEN 'album' THEN item.titleSort ELSE '' END"

    static func order(_ sort: LibraryQuery.Sort) -> String {
        switch sort {
        case .title: return "item.titleSort COLLATE NOCASE ASC"
        case .addedNewest: return "item.addedAt DESC"
        case .releasedNewest: return "COALESCE(item.originallyAvailableAt, item.year) DESC"
        case .releasedOldest: return "COALESCE(item.originallyAvailableAt, item.year) ASC"
        case .rating: return "COALESCE(item.audienceRating, item.rating, 0) DESC"
        case .lastWatched: return "COALESCE(item.lastViewedAt, 0) DESC"
        case .duration: return "COALESCE(item.duration, 0) DESC"
        case .mostPlayed: return "item.viewCount DESC, COALESCE(item.lastViewedAt, 0) DESC, item.titleSort COLLATE NOCASE ASC"
        case .artist:
            return "\(artistSortKey) COLLATE NOCASE ASC, \(albumSortKey) COLLATE NOCASE ASC, COALESCE(item.parentIndex, 0), COALESCE(item.\"index\", 0)"
        case .album: return "\(albumSortKey) COLLATE NOCASE ASC, COALESCE(item.parentIndex, 0), COALESCE(item.\"index\", 0)"
        case .year: return "COALESCE(item.year, 0) DESC, \(artistSortKey) COLLATE NOCASE ASC, \(albumSortKey) COLLATE NOCASE ASC"
        case .recentlyPlayed: return "COALESCE(item.lastViewedAt, 0) DESC"
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
        guid = m.kind == .movie || m.kind == .show ? m.guid : nil
        index = m.index
        parentIndex = m.parentIndex
        cleanPosterPath = nil
        parentTitle = m.parentTitle
        grandparentTitle = m.grandparentTitle
        originalTitle = m.originalTitle
        studio = m.studio ?? m.parentStudio
        let isMusic = m.kind == .artist || m.kind == .album || m.kind == .track
        albumType = m.kind == .album && !(m.formats.isEmpty && m.subformats.isEmpty) ? AlbumType(m).rawValue : nil
        moods = Self.wrapped(m.moods.map(\.tag))
        styles = Self.wrapped(m.styles.map(\.tag))
        countries = Self.wrapped(m.countries.map(\.tag))
        credits = isMusic ? [m.grandparentTitle, m.parentTitle, m.originalTitle, m.studio ?? m.parentStudio]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ") : ""
        userRating = m.userRating
        skipCount = m.skipCount
        ratingCount = m.ratingCount
        let audio = m.kind == .track ? media?.parts.first?.streams.first { $0.streamType == .audio } : nil
        audioCodec = audio?.codec ?? (m.kind == .track ? media?.audioCodec : nil)
        bitDepth = audio?.bitDepth
        samplingRate = audio?.samplingRate
        gainDB = audio?.gain
        albumGainDB = audio?.albumGain
        peak = audio?.peak
        loudness = audio?.loudness
        hasLyrics = m.kind == .track && (media?.parts.first?.streams.contains { $0.streamType == .lyrics } ?? false)
        mbid = m.mbid
        if m.kind == .track, year == nil { year = m.parentYear }
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
