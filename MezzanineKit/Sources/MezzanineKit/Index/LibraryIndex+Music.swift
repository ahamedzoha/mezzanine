import Foundation
import GRDB

/// Music in the index: the detail the listing endpoints don't carry (streams with loudness,
/// moods, styles, album formats) and lookups by external id.
extension LibraryIndex {
    /// Artists, albums and tracks of a section whose detail was never fetched or is older than
    /// the row (the server changed it since).
    public func musicKeysNeedingDetail(section: String) throws -> [String] {
        try pool.read { db in
            try String.fetchAll(db, sql: """
                SELECT i.ratingKey FROM item i LEFT JOIN musicDetail d ON d.ratingKey = i.ratingKey
                WHERE i.section = ? AND i.kind IN ('artist', 'album', 'track')
                  AND (d.ratingKey IS NULL OR d.updatedAt < COALESCE(i.updatedAt, 0))
                ORDER BY i.kind, i.ratingKey
                """, arguments: [section])
        }
    }

    /// Stores fetched detail: the item's detail-only columns, and the full JSON in `musicDetail`
    /// (the item's own `json` stays the listing's, which watch-state refreshes keep current).
    /// Items no longer in the index are skipped.
    public func storeMusicDetail(_ entries: [(PlexMetadata, Data)]) throws {
        try pool.write { db in
            for (meta, json) in entries {
                guard let existing = try Row.fetchOne(db, sql: "SELECT section, updatedAt FROM item WHERE ratingKey = ?",
                                                      arguments: [meta.ratingKey]) else { continue }
                let section: String = existing["section"]
                let row = IndexedItem(meta, json: json, section: section)
                try db.execute(sql: """
                    UPDATE item SET
                        moods = ?, styles = ?,
                        countries = CASE WHEN ? = '' THEN countries ELSE ? END,
                        albumType = COALESCE(?, albumType),
                        audioCodec = COALESCE(?, audioCodec), bitDepth = ?, samplingRate = ?,
                        gainDB = ?, albumGainDB = ?, peak = ?, loudness = ?,
                        hasLyrics = ?, userRating = ?, mbid = COALESCE(?, mbid)
                    WHERE ratingKey = ?
                    """, arguments: [row.moods, row.styles, row.countries, row.countries, row.albumType, row.audioCodec,
                                     row.bitDepth, row.samplingRate, row.gainDB, row.albumGainDB, row.peak, row.loudness,
                                     row.hasLyrics, row.userRating, row.mbid, meta.ratingKey])
                let stamp = row.updatedAt ?? (existing["updatedAt"] as Double?) ?? 0
                try db.execute(sql: "INSERT OR REPLACE INTO musicDetail (ratingKey, updatedAt, json) VALUES (?, ?, ?)",
                               arguments: [meta.ratingKey, stamp, json])
                try Self.syncExternalIDs(db, ratingKey: meta.ratingKey, guids: meta.externalGuids)
            }
        }
    }

    /// An item with its detail when the pass has fetched it (streams, ramps, similar artists,
    /// popular tracks), else from the listing JSON.
    public func musicDetail(_ ratingKey: String) throws -> PlexMetadata? {
        try pool.read { db in
            if let json = try Data.fetchOne(db, sql: "SELECT json FROM musicDetail WHERE ratingKey = ?", arguments: [ratingKey]),
               let meta = try? JSONDecoder().decode(PlexMetadata.self, from: json) { return meta }
            return try IndexedItem.fetchOne(db, key: ratingKey)?.metadata()
        }
    }

    /// Items carrying an external id (`mbid`, `imdb`, `tmdb`, `tvdb`), optionally of one kind.
    public func items(scheme: String, value: String, kinds: [String] = []) throws -> [IndexedItem] {
        try pool.read { db in
            var sql = "SELECT item.* FROM item JOIN external_id e ON e.ratingKey = item.ratingKey WHERE e.scheme = ? AND e.value = ?"
            var args: [String] = [scheme, value]
            if !kinds.isEmpty {
                sql += " AND item.kind IN (\(kinds.map { _ in "?" }.joined(separator: ",")))"
                args += kinds
            }
            return try IndexedItem.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }
    }

    /// Moods in a section with how many items carry each, most common first.
    public func moods(section: String, kinds: [String] = ["album"]) throws -> [(String, Int)] {
        try tagCounts(column: "moods", section: section, kinds: kinds)
    }

    public func styles(section: String, kinds: [String] = ["album"]) throws -> [(String, Int)] {
        try tagCounts(column: "styles", section: section, kinds: kinds)
    }

    private func tagCounts(column: String, section: String, kinds: [String]) throws -> [(String, Int)] {
        try pool.read { db in
            let rows = try String.fetchAll(db, sql: "SELECT \(column) FROM item WHERE section = ? AND kind IN (\(kinds.map { _ in "?" }.joined(separator: ",")))",
                                           arguments: StatementArguments([section] + kinds))
            var counts: [String: Int] = [:]
            for row in rows { for t in row.split(separator: "|") where !t.isEmpty { counts[String(t), default: 0] += 1 } }
            return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        }
    }
}
