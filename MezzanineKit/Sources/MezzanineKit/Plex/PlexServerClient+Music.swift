import Foundation

/// One row of the server's play history (`/status/sessions/history/all`).
public struct PlexHistoryEntry: Decodable, Sendable, Hashable, Identifiable {
    public let historyKey: String
    public let ratingKey: String
    public let title: String
    public let kind: PlexMetadata.Kind
    public let viewedAt: Date?
    public let accountID: Int?
    public let deviceID: Int?
    /// A track's artist and album.
    public let grandparentTitle: String?
    public let parentTitle: String?
    public let grandparentRatingKey: String?
    public let parentRatingKey: String?
    public let thumb: String?
    public let librarySectionID: Int?

    public var id: String { historyKey }

    enum CodingKeys: String, CodingKey {
        case historyKey, ratingKey, title, type, viewedAt, accountID, deviceID, grandparentTitle, parentTitle
        case grandparentRatingKey, parentRatingKey, thumb, librarySectionID, grandparentKey, parentKey
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        historyKey = c.lenientString(.historyKey) ?? ""
        ratingKey = c.lenientString(.ratingKey) ?? ""
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        kind = PlexMetadata.Kind(rawValue: (try? c.decode(String.self, forKey: .type)) ?? "") ?? .unknown
        viewedAt = Date(plexSeconds: c.lenientInt(.viewedAt))
        accountID = c.lenientInt(.accountID)
        deviceID = c.lenientInt(.deviceID)
        grandparentTitle = try? c.decodeIfPresent(String.self, forKey: .grandparentTitle)
        parentTitle = try? c.decodeIfPresent(String.self, forKey: .parentTitle)
        grandparentRatingKey = c.lenientString(.grandparentRatingKey) ?? Self.lastComponent(c, .grandparentKey)
        parentRatingKey = c.lenientString(.parentRatingKey) ?? Self.lastComponent(c, .parentKey)
        thumb = try? c.decodeIfPresent(String.self, forKey: .thumb)
        librarySectionID = c.lenientInt(.librarySectionID)
    }

    /// `/library/metadata/123` → "123" (history rows give keys, not rating keys, for parents).
    private static func lastComponent(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> String? {
        (try? c.decodeIfPresent(String.self, forKey: key)).flatMap { $0.split(separator: "/").last.map(String.init) }
    }
}

/// Everything Music needs from the server beyond what video uses. Reads are GETs; the two
/// writes (`rate`, and `reportTimeline` with a music type) are never retried. There are no play
/// queue calls here on purpose: the queue and radio live on this Mac.
extension PlexServerClient {
    /// Plex answers at most this many ids per `/library/metadata/k1,k2,…` call.
    public static let musicBatchSize = 100

    // MARK: Metadata

    /// Full detail for artists, albums and tracks by key, in batches of 100 (each batch one
    /// call): streams with loudness, gain and ramps, moods, styles, formats, guids. An artist
    /// also gets its popular tracks when `popularLeaves` is set. Order follows the server's
    /// answers (not necessarily `keys`); unknown keys are simply absent.
    public func musicMetadata(keys: [String], popularLeaves: Bool = false) async throws -> [PlexMetadata] {
        try await rawMusicMetadata(keys: keys, popularLeaves: popularLeaves).map(\.0)
    }

    /// The same, each with its own JSON (for the index's detail table).
    public func rawMusicMetadata(keys: [String], popularLeaves: Bool = false) async throws -> [(PlexMetadata, Data)] {
        var out: [(PlexMetadata, Data)] = []
        for chunk in keys.chunked(into: Self.musicBatchSize) {
            try Task.checkCancellation()
            out += try await musicRows("/library/metadata/\(chunk.joined(separator: ","))",
                                       query: Self.musicDetailQuery(popularLeaves: popularLeaves))
        }
        return out
    }

    static func musicDetailQuery(popularLeaves: Bool) -> [URLQueryItem] {
        var q = [URLQueryItem(name: "includeLoudnessRamps", value: "1"), URLQueryItem(name: "includeGuids", value: "1")]
        if popularLeaves { q.append(URLQueryItem(name: "includePopularLeaves", value: "1")) }
        return q
    }

    private func musicRows(_ path: String, query: [URLQueryItem]) async throws -> [(PlexMetadata, Data)] {
        let data = try await perform(makeRequest("GET", path, query: query))
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let container = root["MediaContainer"] as? [String: Any] else { throw PlexError.decoding(path) }
        let decoder = JSONDecoder()
        return try (container["Metadata"] as? [[String: Any]] ?? []).compactMap { row in
            let json = try JSONSerialization.data(withJSONObject: row)
            return (try? decoder.decode(PlexMetadata.self, from: json)).map { ($0, json) }
        }
    }

    // MARK: Playlists

    /// Audio playlists (regular and smart). The video `playlists()` keeps asking for video.
    public func audioPlaylists() async throws -> [PlexMetadata] {
        let c: MetadataContainer = try await get("/playlists", query: [URLQueryItem(name: "playlistType", value: "audio")])
        return c.metadata
    }

    // MARK: Sonic and similar

    /// Tracks that sound like `track`, nearest first (`distance` on each). `maxDistance` is
    /// Plex's sonic distance (smaller is closer; about 0.25 is a tight match).
    public func nearest(track ratingKey: String, limit: Int = 50, maxDistance: Double? = nil) async throws -> [PlexMetadata] {
        var q = [URLQueryItem(name: "limit", value: String(limit))]
        if let maxDistance { q.append(URLQueryItem(name: "maxDistance", value: String(maxDistance))) }
        let c: MetadataContainer = try await get("/library/metadata/\(ratingKey)/nearest", query: q)
        return c.metadata
    }

    /// Artists Plex considers similar to an artist (`/similar`; albums and tracks answer too).
    public func similar(_ ratingKey: String, limit: Int = 30) async throws -> [PlexMetadata] {
        let c: MetadataContainer = try await get("/library/metadata/\(ratingKey)/similar",
                                                 query: [URLQueryItem(name: "limit", value: String(limit))])
        return c.metadata
    }

    /// A path of tracks that drifts from one track's sound to another's (needs sonic analysis).
    public func computePath(section: String, start: String, end: String) async throws -> [PlexMetadata] {
        let c: MetadataContainer = try await get("/library/sections/\(section)/computePath", query: [
            URLQueryItem(name: "startID", value: start),
            URLQueryItem(name: "endID", value: end),
        ])
        return c.metadata
    }

    // MARK: Lyrics

    /// The lyrics behind a track's lyric stream (`key` like `/library/streams/123` or just
    /// `123`; `format` is the stream's `lrc` or `txt`). Plex's lyric service is often empty,
    /// so a nil answer is normal: the caller moves on to the next source.
    public func lyrics(streamKey: String, format: String = "lrc") async throws -> Lyrics? {
        let id = streamKey.split(separator: "/").last.map(String.init) ?? streamKey
        let path = id.contains(".") ? "/library/streams/\(id)" : "/library/streams/\(id).\(format)"
        let data = try await perform(makeRequest("GET", path, query: []))
        return Self.decodeLyrics(data)
    }

    /// Reads either answer shape: Plex's JSON (`Lyrics[].Line[]`, each with its own text or
    /// `Span[]`, millisecond offsets) or plain LRC / text. Empty answers give nil.
    static func decodeLyrics(_ data: Data) -> Lyrics? {
        guard !data.isEmpty else { return nil }
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            guard let container = root["MediaContainer"] as? [String: Any],
                  let blocks = container["Lyrics"] as? [[String: Any]] else { return nil }
            for block in blocks {
                let lines = (block["Line"] as? [[String: Any]] ?? []).compactMap(Self.lyricLine)
                guard lines.contains(where: { !$0.text.isEmpty }) else { continue }
                let timed = lines.contains { $0.start != nil }
                return Lyrics(lines: lines, isTimed: timed, provider: block["provider"] as? String)
            }
            return nil
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return LRC.parse(text) ?? LRC.plain(text)
    }

    private static func lyricLine(_ row: [String: Any]) -> LyricLine? {
        func ms(_ v: Any?) -> Double? {
            if let i = v as? Int { return Double(i) / 1000 }
            if let d = v as? Double { return d / 1000 }
            if let s = v as? String, let d = Double(s) { return d / 1000 }
            return nil
        }
        var text = row["text"] as? String
        var start = ms(row["startOffset"]) ?? ms(row["start"])
        if text == nil, let spans = row["Span"] as? [[String: Any]] {
            text = spans.compactMap { $0["text"] as? String }.joined()
            start = start ?? spans.compactMap { ms($0["startOffset"]) }.first
        }
        guard let text else { return nil }
        return LyricLine(start: start, text: text)
    }

    // MARK: History

    /// Every music listen the server remembers for a section, newest first. `accountID` limits
    /// it to one account (the server's history holds everyone's).
    public func musicHistory(section: String, accountID: Int? = nil, limit: Int? = nil) async throws -> [PlexHistoryEntry] {
        struct Container: Decodable {
            let rows: [PlexHistoryEntry]
            enum CodingKeys: String, CodingKey { case rows = "Metadata" }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                rows = c.list(PlexHistoryEntry.self, .rows)
            }
        }
        var q = [URLQueryItem(name: "librarySectionID", value: section), URLQueryItem(name: "sort", value: "viewedAt:desc")]
        if let accountID { q.append(URLQueryItem(name: "accountID", value: String(accountID))) }
        let c: Container = try await get("/status/sessions/history/all", query: q, offset: limit == nil ? nil : 0, limit: limit)
        return c.rows
    }

    // MARK: Writes

    /// Rates an item 0…10 (stars × 2); −1 clears the rating.
    public func rate(ratingKey: String, rating: Int) async throws {
        let clamped = min(10, max(-1, rating))
        try await write("PUT", "/:/rate", query: [
            URLQueryItem(name: "key", value: ratingKey),
            URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
            URLQueryItem(name: "rating", value: String(clamped)),
        ])
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
