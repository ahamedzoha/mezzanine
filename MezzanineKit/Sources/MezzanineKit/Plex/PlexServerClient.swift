import Foundation

/// Sort orders the library listing understands (`sort=` values).
public enum PlexSort: String, Sendable, CaseIterable {
    case titleAscending = "titleSort"
    case titleDescending = "titleSort:desc"
    case addedNewest = "addedAt:desc"
    case releasedNewest = "originallyAvailableAt:desc"
    case releasedOldest = "originallyAvailableAt"
    case rating = "rating:desc"
    case audienceRating = "audienceRating:desc"
    case lastViewed = "lastViewedAt:desc"
    case duration = "duration:desc"
}

/// Talks to one Plex Media Server over one resolved address.
///
/// Reads retry transient failures twice; writes never retry, so a timed-out
/// scrobble can't be applied twice.
public actor PlexServerClient {
    public nonisolated let baseURL: URL
    public nonisolated let machineIdentifier: String
    nonisolated let token: String
    nonisolated let identity: PlexIdentity
    private let session: URLSession

    public init(baseURL: URL, token: String, machineIdentifier: String, identity: PlexIdentity,
                session: URLSession = Transport.makeAPISession()) {
        self.baseURL = baseURL
        self.token = token
        self.machineIdentifier = machineIdentifier
        self.identity = identity
        self.session = session
    }

    public nonisolated var urls: PlexURLs { PlexURLs(baseURL: baseURL, token: token) }

    /// Headers for requests the app makes outside this client (the playback
    /// engine fetching a part, the image pipeline). The token travels as a
    /// header, never in a URL that could end up in a log.
    public nonisolated var requestHeaders: [String: String] {
        var h = identity.headers
        h["X-Plex-Token"] = token
        return h
    }

    // MARK: Library

    public func sections() async throws -> [PlexLibrarySection] {
        let c: DirectoryContainer<PlexLibrarySection> = try await get("/library/sections")
        return c.directories
    }

    /// One page of a section. `type` picks the level for show libraries
    /// (2 shows, 3 seasons, 4 episodes); nil lists the section's top level.
    public func items(section: String, type: Int? = nil, sort: PlexSort? = nil,
                      offset: Int = 0, limit: Int = 200, filters: [URLQueryItem] = []) async throws -> Page<PlexMetadata> {
        var q = [URLQueryItem(name: "includeGuids", value: "1")]
        if let type { q.append(URLQueryItem(name: "type", value: String(type))) }
        if let sort { q.append(URLQueryItem(name: "sort", value: sort.rawValue)) }
        q += filters
        let c: MetadataContainer = try await get("/library/sections/\(section)/all", query: q, offset: offset, limit: limit)
        return Page(items: c.metadata, offset: c.offset ?? offset, totalSize: c.totalSize)
    }

    /// Items changed since a moment, for incremental index sync.
    public func itemsUpdated(section: String, type: Int? = nil, since: Date, offset: Int = 0, limit: Int = 200) async throws -> Page<PlexMetadata> {
        try await items(section: section, type: type, offset: offset, limit: limit, filters: [
            URLQueryItem(name: "updatedAt>", value: String(Int(since.timeIntervalSince1970))),
        ])
    }

    /// Full detail: markers, chapters, extras, every stream.
    public func metadata(_ ratingKey: String) async throws -> PlexMetadata {
        let c: MetadataContainer = try await get("/library/metadata/\(ratingKey)", query: [
            URLQueryItem(name: "includeMarkers", value: "1"),
            URLQueryItem(name: "includeChapters", value: "1"),
            URLQueryItem(name: "includeExtras", value: "1"),
            URLQueryItem(name: "includeOnDeck", value: "1"),
            URLQueryItem(name: "includeGuids", value: "1"),
        ])
        guard let item = c.metadata.first else { throw PlexError.notFound }
        return item
    }

    /// "More like this": collection siblings and similar titles, as hubs.
    public func related(_ ratingKey: String, count: Int = 16) async throws -> [PlexHub] {
        let c: HubContainer = try await get("/library/metadata/\(ratingKey)/related", query: [URLQueryItem(name: "count", value: String(count))])
        return c.hubs
    }

    public func children(_ ratingKey: String) async throws -> [PlexMetadata] {
        let c: MetadataContainer = try await get("/library/metadata/\(ratingKey)/children")
        return c.metadata
    }

    /// Every episode of a show, in order.
    public func allLeaves(_ showRatingKey: String) async throws -> [PlexMetadata] {
        let c: MetadataContainer = try await get("/library/metadata/\(showRatingKey)/allLeaves")
        return c.metadata
    }

    public func collections(section: String) async throws -> [PlexMetadata] {
        let c: MetadataContainer = try await get("/library/sections/\(section)/collections")
        return c.metadata
    }

    /// A collection's titles, in the collection's own order.
    public func collectionItems(_ ratingKey: String) async throws -> [PlexMetadata] {
        let c: MetadataContainer = try await get("/library/collections/\(ratingKey)/children")
        return c.metadata
    }

    /// A playlist's entries, in order.
    public func playlistItems(_ ratingKey: String) async throws -> [PlexMetadata] {
        let c: MetadataContainer = try await get("/playlists/\(ratingKey)/items")
        return c.metadata
    }

    public func playlists() async throws -> [PlexMetadata] {
        let c: MetadataContainer = try await get("/playlists", query: [URLQueryItem(name: "playlistType", value: "video")])
        return c.metadata
    }

    // MARK: Hubs & search

    public func homeHubs(count: Int = 20) async throws -> [PlexHub] {
        let c: HubContainer = try await get("/hubs", query: [URLQueryItem(name: "count", value: String(count))])
        return c.hubs
    }

    public func sectionHubs(_ section: String, count: Int = 20) async throws -> [PlexHub] {
        let c: HubContainer = try await get("/hubs/sections/\(section)", query: [URLQueryItem(name: "count", value: String(count))])
        return c.hubs
    }

    public func search(_ query: String, limit: Int = 30) async throws -> [PlexHub] {
        let c: HubContainer = try await get("/hubs/search", query: [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "includeCollections", value: "1"),
        ])
        return c.hubs
    }

    // MARK: Subtitles

    /// Plex's own on-demand subtitle search (OpenSubtitles through the server).
    public func searchSubtitles(ratingKey: String, language: String, hearingImpaired: Bool = false,
                                forced: Bool = false) async throws -> [PlexStream] {
        let c: StreamContainer = try await get("/library/metadata/\(ratingKey)/subtitles", query: [
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "hearingImpaired", value: hearingImpaired ? "1" : "0"),
            URLQueryItem(name: "forced", value: forced ? "1" : "0"),
        ])
        return c.streams.sorted { ($0.score ?? 0) > ($1.score ?? 0) }
    }

    // MARK: Raw pages (for the local index)

    /// One page of a section with each item's own JSON kept, so the index can
    /// store it and decode the full model later without the network.
    public func rawItems(section: String, type: Int, offset: Int, limit: Int,
                         filters: [URLQueryItem] = []) async throws -> (items: [(PlexMetadata, Data)], totalSize: Int?) {
        var q = [URLQueryItem(name: "type", value: String(type)), URLQueryItem(name: "includeGuids", value: "1")]
        q += filters
        var request = makeRequest("GET", "/library/sections/\(section)/all", query: q)
        request.setValue(String(offset), forHTTPHeaderField: "X-Plex-Container-Start")
        request.setValue(String(limit), forHTTPHeaderField: "X-Plex-Container-Size")
        let data = try await perform(request)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let container = root["MediaContainer"] as? [String: Any] else {
            throw PlexError.decoding("section \(section) page")
        }
        let total = (container["totalSize"] as? Int) ?? (container["totalSize"] as? String).flatMap(Int.init)
        let rows = container["Metadata"] as? [[String: Any]] ?? []
        var out: [(PlexMetadata, Data)] = []
        out.reserveCapacity(rows.count)
        let decoder = JSONDecoder()
        for row in rows {
            let json = try JSONSerialization.data(withJSONObject: row)
            if let meta = try? decoder.decode(PlexMetadata.self, from: json) { out.append((meta, json)) }
        }
        return (out, total)
    }

    /// How many items of a type a section holds, without fetching them.
    public func count(section: String, type: Int) async throws -> Int {
        try await rawItems(section: section, type: type, offset: 0, limit: 0).totalSize ?? 0
    }

    // MARK: Activity (writes: resume points, watched state, "now playing")

    public enum TimelineState: String, Sendable { case playing, paused, stopped, buffering }

    /// Reports where playback is. Plex stores the resume point from it, shows the
    /// session in Now Playing (and Tautulli), and marks the item watched when a
    /// stop lands past ~90 %. `sessionID` identifies this playback session.
    public func reportTimeline(ratingKey: String, state: TimelineState, time: TimeInterval,
                               duration: TimeInterval, sessionID: String) async throws {
        var request = makeRequest("GET", "/:/timeline", query: [
            URLQueryItem(name: "ratingKey", value: ratingKey),
            URLQueryItem(name: "key", value: "/library/metadata/\(ratingKey)"),
            URLQueryItem(name: "state", value: state.rawValue),
            URLQueryItem(name: "time", value: String(Int(time * 1000))),
            URLQueryItem(name: "duration", value: String(Int(duration * 1000))),
            URLQueryItem(name: "hasMDE", value: "1"),
        ])
        request.setValue(sessionID, forHTTPHeaderField: "X-Plex-Session-Identifier")
        _ = try await perform(request)
    }

    /// Remembers the chosen audio and subtitle streams for a file on the server
    /// (every Plex app then starts with them). `subtitleStreamID` 0 means off.
    public func setStreams(partID: Int, audioStreamID: Int? = nil, subtitleStreamID: Int? = nil) async throws {
        var q = [URLQueryItem(name: "allParts", value: "1")]
        if let audioStreamID { q.append(URLQueryItem(name: "audioStreamID", value: String(audioStreamID))) }
        if let subtitleStreamID { q.append(URLQueryItem(name: "subtitleStreamID", value: String(subtitleStreamID))) }
        try await write("PUT", "/library/parts/\(partID)", query: q)
    }

    /// Marks watched.
    /// Asks Plex to decide on a transcode session before it starts (Plex refuses `start.m3u8`
    /// for a session without a decision). Throws when Plex can neither play nor convert it.
    public func decideTranscode(_ url: URL) async throws {
        var request = URLRequest(url: url)
        for (k, v) in requestHeaders { request.setValue(v, forHTTPHeaderField: k) }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await perform(request)
        struct Decision: Decodable { let generalDecisionCode: Int? }
        struct Envelope: Decodable { let MediaContainer: Decision }
        if let code = (try? JSONDecoder().decode(Envelope.self, from: data))?.MediaContainer.generalDecisionCode, code >= 2000 {
            throw PlexError.http(status: 415)
        }
    }

    /// Ends a transcode session (best effort; Plex also reaps idle ones).
    public func stopTranscode(session id: String) async {
        _ = try? await write("GET", "/video/:/transcode/universal/stop", query: [URLQueryItem(name: "session", value: id)])
    }

    public func scrobble(ratingKey: String) async throws {
        try await write("GET", "/:/scrobble", query: [
            URLQueryItem(name: "key", value: ratingKey),
            URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
        ])
    }

    /// Marks unwatched (and clears the resume point).
    public func unscrobble(ratingKey: String) async throws {
        try await write("GET", "/:/unscrobble", query: [
            URLQueryItem(name: "key", value: ratingKey),
            URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
        ])
    }

    // MARK: Artwork

    /// The poster an agent chose, before any overlay tool (Kometa) replaced it
    /// with an uploaded copy: the agent's own stored poster when there is one,
    /// else the first provider poster. Read-only; nothing changes on the server.
    public func cleanPosterPath(ratingKey: String) async throws -> String? {
        struct Container: Decodable {
            struct Poster: Decodable { let key: String?; let provider: String?; let ratingKey: String? }
            let posters: [Poster]
            enum CodingKeys: String, CodingKey { case posters = "Metadata" }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                posters = c.list(Poster.self, .posters)
            }
        }
        let c: Container = try await get("/library/metadata/\(ratingKey)/posters")
        let agentStored = c.posters.first { ($0.ratingKey ?? "").hasPrefix("metadata://posters/") }
        let firstProvider = c.posters.first { $0.provider != nil }
        return (agentStored ?? firstProvider)?.key
    }

    // MARK: Folders (personal-media libraries such as Courses)

    public struct FolderListing: Sendable {
        public struct Folder: Sendable, Hashable, Identifiable {
            public let key: String
            public let title: String
            public var id: String { key }
        }
        public let folders: [Folder]
        public let items: [PlexMetadata]
    }

    /// The root of a section's folders, or a folder's contents (`key` from a previous listing).
    public func folder(section: String, key: String? = nil) async throws -> FolderListing {
        struct Raw: Decodable {
            let metadata: [Entry]
            enum CodingKeys: String, CodingKey { case metadata = "Metadata" }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                metadata = c.list(Entry.self, .metadata)
            }
        }
        struct Entry: Decodable {
            let item: PlexMetadata?
            let key: String?
            let title: String?
            let ratingKey: String?
            enum CodingKeys: String, CodingKey { case key, title, ratingKey }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                key = try? c.decodeIfPresent(String.self, forKey: .key)
                title = try? c.decodeIfPresent(String.self, forKey: .title)
                ratingKey = c.lenientString(.ratingKey)
                item = ratingKey == nil ? nil : try? PlexMetadata(from: decoder)
            }
        }
        let path: String
        var query: [URLQueryItem] = []
        if let key, let comps = URLComponents(string: key) {
            path = comps.path
            query = comps.queryItems ?? []
        } else {
            path = "/library/sections/\(section)/folder"
        }
        let raw: Raw = try await get(path, query: query)
        var folders: [FolderListing.Folder] = []
        var items: [PlexMetadata] = []
        for entry in raw.metadata {
            if let item = entry.item { items.append(item) }
            else if let key = entry.key { folders.append(.init(key: key, title: entry.title ?? "Folder")) }
        }
        return FolderListing(folders: folders, items: items)
    }

    /// Downloads a subtitle found by `searchSubtitles` and stores it on the server
    /// as a sidecar for the item (every Plex app sees it afterwards).
    public func downloadSubtitle(ratingKey: String, result: PlexStream) async throws {
        var q = [URLQueryItem(name: "key", value: result.key ?? "")]
        if let codec = result.codec { q.append(URLQueryItem(name: "codec", value: codec)) }
        if let language = result.languageCode { q.append(URLQueryItem(name: "language", value: language)) }
        q.append(URLQueryItem(name: "hearingImpaired", value: result.hearingImpaired ? "1" : "0"))
        q.append(URLQueryItem(name: "forced", value: result.forced ? "1" : "0"))
        if let provider = result.providerTitle { q.append(URLQueryItem(name: "providerTitle", value: provider)) }
        try await write("PUT", "/library/metadata/\(ratingKey)/subtitles", query: q)
    }

    // MARK: Plumbing

    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], offset: Int? = nil, limit: Int? = nil) async throws -> T {
        var request = makeRequest("GET", path, query: query)
        if let offset { request.setValue(String(offset), forHTTPHeaderField: "X-Plex-Container-Start") }
        if let limit { request.setValue(String(limit), forHTTPHeaderField: "X-Plex-Container-Size") }
        var attempt = 0
        while true {
            do {
                let data = try await perform(request)
                do {
                    return try JSONDecoder().decode(MediaContainerEnvelope<T>.self, from: data).container
                } catch {
                    throw PlexError.decoding("\(path): \(error)")
                }
            } catch let error as PlexError where error.isTransient && attempt < 2 {
                attempt += 1
                try await Task.sleep(for: .milliseconds(400 * attempt))
            }
        }
    }

    /// A write (PUT/POST/DELETE). Never retried.
    @discardableResult
    func write(_ method: String, _ path: String, query: [URLQueryItem] = []) async throws -> Data {
        try await perform(makeRequest(method, path, query: query))
    }

    func makeRequest(_ method: String, _ path: String, query: [URLQueryItem]) -> URLRequest {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        // `appending(path:)` percent-encodes ":" in "/:/timeline"; Plex wants it literal.
        components.percentEncodedPath = components.percentEncodedPath.replacingOccurrences(of: "%3A", with: ":")
        if !query.isEmpty {
            components.percentEncodedQueryItems = query.map {
                URLQueryItem(name: $0.name.addingPercentEncoding(withAllowedCharacters: .plexQueryAllowed) ?? $0.name,
                             value: $0.value?.addingPercentEncoding(withAllowedCharacters: .plexQueryAllowed))
            }
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        for (k, v) in requestHeaders { request.setValue(v, forHTTPHeaderField: k) }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    func perform(_ request: URLRequest) async throws -> Data {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw PlexError.from(error, localNetworkSuspected: NetworkPath.shared.isSatisfied)
        }
        let http = response as? HTTPURLResponse
        if let failure = PlexError.from(status: http?.statusCode ?? 0, location: http?.value(forHTTPHeaderField: "Location")) {
            throw failure
        }
        return data
    }
}

extension CharacterSet {
    /// Query-value characters left unescaped. Excludes `&`, `=`, `+`, `?` and
    /// `#` so filter values (`updatedAt>`) and URLs passed as values survive.
    static let plexQueryAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+?#")
        return set
    }()
}
