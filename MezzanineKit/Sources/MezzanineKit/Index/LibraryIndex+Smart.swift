import Foundation
import GRDB

extension LibraryIndex {
    /// The titles a smart shelf holds, in its order, up to its limit (0 = no limit).
    public func items(_ rule: SmartRule, limit: Int? = nil) throws -> [IndexedItem] {
        let (whereSQL, args) = Self.clauses(rule)
        let cap = limit ?? rule.limit
        return try pool.read { db in
            var sql = "SELECT item.* FROM item WHERE \(whereSQL) ORDER BY \(Self.order(rule.sort)), item.titleSort COLLATE NOCASE"
            var all = args
            if cap > 0 { sql += " LIMIT ?"; all.append(cap) }
            return try IndexedItem.fetchAll(db, sql: sql, arguments: StatementArguments(all))
        }
    }

    /// How many titles match, ignoring the shelf's limit (the rule sheet's "38 titles").
    public func count(_ rule: SmartRule) throws -> Int {
        let (whereSQL, args) = Self.clauses(rule)
        return try pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item WHERE \(whereSQL)", arguments: StatementArguments(args)) ?? 0
        }
    }

    /// Every genre across the given sections (all when empty), most common first.
    public func genres(sections: [String]) throws -> [String] {
        try names(column: "genres", sections: sections)
    }

    /// Every collection name across the given sections, most common first.
    public func collectionNames(sections: [String]) throws -> [String] {
        try names(column: "collections", sections: sections)
    }

    private func names(column: String, sections: [String]) throws -> [String] {
        try pool.read { db in
            var sql = "SELECT \(column) FROM item WHERE kind IN ('movie','show')"
            var args: [any DatabaseValueConvertible] = []
            if !sections.isEmpty {
                sql += " AND section IN (\(sections.map { _ in "?" }.joined(separator: ",")))"
                args += sections
            }
            let rows = try String.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            var counts: [String: Int] = [:]
            for row in rows { for g in row.split(separator: "|") where !g.isEmpty { counts[String(g), default: 0] += 1 } }
            return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
        }
    }

    static func clauses(_ rule: SmartRule, now: Date = Date()) -> (String, [any DatabaseValueConvertible]) {
        var clauses: [String] = []
        var args: [any DatabaseValueConvertible] = []
        if !rule.sections.isEmpty {
            clauses.append("item.section IN (\(rule.sections.map { _ in "?" }.joined(separator: ",")))")
            args += rule.sections
        }
        let kinds = rule.effectiveKinds
        clauses.append("item.kind IN (\(kinds.map { _ in "?" }.joined(separator: ",")))")
        args += kinds
        for condition in rule.conditions where condition.isComplete {
            switch condition {
            case .genre(let g, let excluded):
                clauses.append(excluded ? "item.genres NOT LIKE ?" : "item.genres LIKE ?")
                args.append("%|\(g)|%")
            case .decade(let d):
                clauses.append("item.year BETWEEN ? AND ?"); args += [d, d + 9]
            case .years(let a, let b):
                clauses.append("item.year BETWEEN ? AND ?"); args += [min(a, b), max(a, b)]
            case .watch(.unwatched):
                clauses.append("((item.kind IN ('show','season') AND COALESCE(item.viewedLeafCount,0) < COALESCE(item.leafCount,0)) OR (item.kind NOT IN ('show','season') AND item.viewCount = 0))")
            case .watch(.inProgress):
                clauses.append("(item.viewOffset > 0 OR (item.kind = 'show' AND COALESCE(item.viewedLeafCount,0) > 0 AND COALESCE(item.viewedLeafCount,0) < COALESCE(item.leafCount,0)))")
            case .watch(.watched):
                clauses.append("((item.kind IN ('show','season') AND COALESCE(item.leafCount,0) > 0 AND COALESCE(item.viewedLeafCount,0) >= item.leafCount) OR (item.kind NOT IN ('show','season') AND item.viewCount > 0 AND item.viewOffset = 0))")
            case .addedWithin(let days):
                clauses.append("item.addedAt >= ?"); args.append(now.timeIntervalSince1970 - Double(days) * 86_400)
            case .minRating(let r):
                clauses.append("COALESCE(item.audienceRating, item.rating, 0) >= ?"); args.append(r)
            case .resolution(let r):
                if r == "sd" { clauses.append("item.resolution IN ('sd','480','576')") }
                else { clauses.append("item.resolution = ?"); args.append(r) }
            case .hdr:
                clauses.append("item.isHDR = 1")
            case .minChannels(let c):
                clauses.append("COALESCE(item.audioChannels, 0) >= ?"); args.append(c)
            case .collection(let c):
                clauses.append("item.collections LIKE ?"); args.append("%|\(c)|%")
            case .person(let p):
                clauses.append("item.people LIKE ?"); args.append("%|\(p.trimmingCharacters(in: .whitespaces))|%")
            }
        }
        return (clauses.joined(separator: " AND "), args)
    }
}
