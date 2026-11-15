import Foundation

/// HTTP for the subtitle sites. No Plex token ever rides on these requests, so redirects are
/// allowed (download links bounce through CDNs).
enum SubtitleHTTP {
    static let userAgent = "Mezzanine v0.1"

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpAdditionalHeaders = ["User-Agent": userAgent]
        return URLSession(configuration: config)
    }()

    static func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// One path segment: a show called "Love/Hate" stays one segment.
    static let pathSegment = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#;"))

    static func json(_ data: Data) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }

    static func int(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let s = any as? String { return Int(s) }
        if let d = any as? Double { return Int(d) }
        return nil
    }
}

/// Language names and codes the sites use.
public enum SubtitleLanguage {
    /// "en" → "English" (Addic7ed's names are English names).
    public static func englishName(_ code: String) -> String? {
        Locale(identifier: "en").localizedString(forLanguageCode: code)
    }

    /// "english" → "en", for every two-letter ISO code.
    private static let byName: [String: String] = {
        var map: [String: String] = [:]
        for code in Locale.LanguageCode.isoLanguageCodes.map(\.identifier) where code.count == 2 {
            if let name = englishName(code)?.lowercased(), map[name] == nil { map[name] = code }
        }
        return map
    }()

    /// ISO 639-2/B codes (Plex and Matroska use them) that ICU doesn't map.
    private static let bibliographic = ["fre": "fr", "ger": "de", "chi": "zh", "cze": "cs", "dut": "nl", "gre": "el",
                                        "per": "fa", "rum": "ro", "slo": "sk", "alb": "sq", "arm": "hy", "baq": "eu",
                                        "bur": "my", "geo": "ka", "ice": "is", "mac": "mk", "mao": "mi", "may": "ms",
                                        "tib": "bo", "wel": "cy"]

    /// "pt-BR", "por", "English" → "pt".
    public static func code(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.count == 2 { return lower }
        if let code = bibliographic[lower] { return code }
        if let dash = lower.firstIndex(where: { $0 == "-" || $0 == "_" }) {
            let head = String(lower[..<dash])
            return head == "br" ? "pt" : head
        }
        if Locale.LanguageCode(lower).isISOLanguage, let code = Locale.LanguageCode(lower).identifier(.alpha2) { return code }
        if let code = byName[lower] { return code }
        if lower.hasPrefix("portuguese") { return "pt" }
        if lower.hasPrefix("spanish") { return "es" }
        if lower.hasPrefix("chinese") { return "zh" }
        return lower
    }
}

// MARK: - OpenSubtitles.com

/// OpenSubtitles.com's REST API with the owner's free API key. Signing in (optional) raises
/// the daily download allowance; the file hash finds subtitles made for exactly this file.
public actor OpenSubtitlesSource: SubtitleSource {
    public nonisolated let name = "OpenSubtitles"
    private let apiKey: String
    private let username: String
    private let password: String
    private var token: String?
    private var host = "api.opensubtitles.com"

    public init(apiKey: String, username: String = "", password: String = "") {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        self.password = password
    }

    private var signsIn: Bool { !username.isEmpty && !password.isEmpty }

    public func search(_ query: SubtitleQuery) async throws -> [SubtitleResult] {
        guard !apiKey.isEmpty else { throw SubtitleSourceError.needsKey }
        var params: [String: String] = ["languages": Self.languages(query.languages).joined(separator: ",")]
        if let hash = query.fileHash { params["moviehash"] = hash }
        switch query.kind {
        case .movie:
            if let imdb = Self.imdbNumber(query.imdbID) { params["imdb_id"] = imdb }
            else if let tmdb = query.tmdbID { params["tmdb_id"] = tmdb }
            else {
                params["query"] = query.title
                if let year = query.year { params["year"] = String(year) }
            }
            params["type"] = "movie"
        case .episode:
            if let imdb = Self.imdbNumber(query.imdbID) {
                params["imdb_id"] = imdb
            } else {
                if let show = Self.imdbNumber(query.showIMDbID) { params["parent_imdb_id"] = show }
                else { params["query"] = query.showTitle ?? query.title }
                if let season = query.season { params["season_number"] = String(season) }
                if let episode = query.episode { params["episode_number"] = String(episode) }
            }
            params["type"] = "episode"
        }
        let (data, status) = try await call("GET", "/subtitles", params: params, auth: false)
        try Self.check(status, data)
        guard let rows = SubtitleHTTP.json(data)?["data"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row -> SubtitleResult? in
            guard let a = row["attributes"] as? [String: Any],
                  let file = (a["files"] as? [[String: Any]])?.first, let fileID = SubtitleHTTP.int(file["file_id"]) else { return nil }
            let feature = a["feature_details"] as? [String: Any]
            let release = (a["release"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (file["file_name"] as? String) ?? (feature?["title"] as? String) ?? "Subtitle"
            return SubtitleResult(id: "os-\(fileID)", source: name, language: SubtitleLanguage.code(a["language"] as? String ?? "en"),
                                  release: release, hearingImpaired: a["hearing_impaired"] as? Bool ?? false,
                                  forced: a["foreign_parts_only"] as? Bool ?? false,
                                  hashMatch: a["moviehash_match"] as? Bool ?? false,
                                  downloads: SubtitleHTTP.int(a["download_count"]), format: "srt", payload: String(fileID))
        }
    }

    public func download(_ result: SubtitleResult, for query: SubtitleQuery) async throws -> SubtitleFile {
        guard !apiKey.isEmpty else { throw SubtitleSourceError.needsKey }
        if signsIn, token == nil { try await signIn() }
        var (data, status) = try await call("POST", "/download", body: ["file_id": Int(result.payload) ?? 0], auth: true)
        if status == 401, signsIn {
            token = nil
            try await signIn()
            (data, status) = try await call("POST", "/download", body: ["file_id": Int(result.payload) ?? 0], auth: true)
        }
        if status == 401 { throw SubtitleSourceError.rejected("sign in to OpenSubtitles in Settings ▸ Subtitles to download") }
        try Self.check(status, data)
        guard let json = SubtitleHTTP.json(data), let link = (json["link"] as? String).flatMap(URL.init(string:)) else {
            throw SubtitleSourceError.unreadable
        }
        let (body, fileStatus) = try await SubtitleHTTP.send(URLRequest(url: link))
        guard (200..<300).contains(fileStatus), !body.isEmpty else { throw SubtitleSourceError.notFound }
        let ext = ((json["file_name"] as? String).map { ($0 as NSString).pathExtension } ?? "").lowercased()
        return SubtitleFile(data: body, format: ext.isEmpty ? "srt" : ext)
    }

    /// For Settings: whether the key (and sign-in) work, and how many downloads are left today.
    public func check() async throws -> String {
        guard !apiKey.isEmpty else { throw SubtitleSourceError.needsKey }
        guard signsIn else {
            let (data, status) = try await call("GET", "/infos/formats", auth: false)
            try Self.check(status, data)
            return "Key works. Sign in to download more each day."
        }
        token = nil
        try await signIn()
        let (data, status) = try await call("GET", "/infos/user", auth: true)
        try Self.check(status, data)
        let info = SubtitleHTTP.json(data)?["data"] as? [String: Any]
        if let left = SubtitleHTTP.int(info?["remaining_downloads"]), let allowed = SubtitleHTTP.int(info?["allowed_downloads"]) {
            return "Signed in. \(left) of \(allowed) downloads left today."
        }
        return "Signed in."
    }

    private func signIn() async throws {
        let (data, status) = try await call("POST", "/login", body: ["username": username, "password": password], auth: false)
        if status == 401 || status == 400 { throw SubtitleSourceError.rejected("the OpenSubtitles username or password was refused") }
        try Self.check(status, data)
        guard let json = SubtitleHTTP.json(data), let token = json["token"] as? String else { throw SubtitleSourceError.unreadable }
        self.token = token
        if let base = json["base_url"] as? String, !base.isEmpty {
            host = base.replacingOccurrences(of: "https://", with: "").split(separator: "/").first.map(String.init) ?? host
        }
    }

    /// The API wants parameters sorted and lowercase (anything else is redirected).
    private func call(_ method: String, _ path: String, params: [String: String] = [:], body: [String: Any]? = nil,
                      auth: Bool) async throws -> (Data, Int) {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/api/v1" + path
        if !params.isEmpty {
            components.queryItems = params.keys.sorted().map { key in
                URLQueryItem(name: key, value: key == "query" ? params[key]!.lowercased() : params[key]!)
            }
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue(apiKey, forHTTPHeaderField: "Api-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if auth, let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return try await SubtitleHTTP.send(request)
    }

    static func check(_ status: Int, _ data: Data) throws {
        switch status {
        case 200..<300: return
        case 401, 403: throw SubtitleSourceError.rejected("the OpenSubtitles API key was refused")
        case 406: throw SubtitleSourceError.quotaReached
        case 404: throw SubtitleSourceError.notFound
        case 429: throw SubtitleSourceError.rejected("too many requests; try again in a moment")
        default:
            let message = SubtitleHTTP.json(data)?["message"] as? String
            throw SubtitleSourceError.rejected(message ?? "answered \(status)")
        }
    }

    /// "tt0111161" → "111161".
    static func imdbNumber(_ id: String?) -> String? {
        guard let id else { return nil }
        let digits = id.drop { !$0.isNumber }.drop { $0 == "0" }
        return digits.isEmpty ? nil : String(digits)
    }

    /// OpenSubtitles splits Portuguese and Chinese.
    static func languages(_ codes: [String]) -> [String] {
        codes.flatMap { code -> [String] in
            switch code {
            case "pt": ["pt-br", "pt-pt"]
            case "zh": ["zh-cn", "zh-tw"]
            default: [code]
            }
        }.sorted()
    }
}

// MARK: - Subdl

/// subdl.com with the owner's free API key. Downloads arrive as ZIP archives.
public struct SubdlSource: SubtitleSource {
    public let name = "Subdl"
    private let apiKey: String

    public init(apiKey: String) { self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }

    public func search(_ query: SubtitleQuery) async throws -> [SubtitleResult] {
        guard !apiKey.isEmpty else { throw SubtitleSourceError.needsKey }
        var items = [URLQueryItem(name: "api_key", value: apiKey),
                     URLQueryItem(name: "languages", value: Self.languages(query.languages).joined(separator: ",")),
                     URLQueryItem(name: "subs_per_page", value: "30")]
        let imdb = query.kind == .movie ? query.imdbID : query.showIMDbID
        if let imdb { items.append(URLQueryItem(name: "imdb_id", value: imdb)) }
        else { items.append(URLQueryItem(name: "film_name", value: query.kind == .movie ? query.title : (query.showTitle ?? query.title))) }
        if query.kind == .movie {
            items.append(URLQueryItem(name: "type", value: "movie"))
            if imdb == nil, let year = query.year { items.append(URLQueryItem(name: "year", value: String(year))) }
        } else {
            items.append(URLQueryItem(name: "type", value: "tv"))
            if let season = query.season { items.append(URLQueryItem(name: "season_number", value: String(season))) }
            if let episode = query.episode { items.append(URLQueryItem(name: "episode_number", value: String(episode))) }
        }
        var components = URLComponents(string: "https://api.subdl.com/api/v1/subtitles")!
        components.queryItems = items
        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, status) = try await SubtitleHTTP.send(request)
        let json = SubtitleHTTP.json(data)
        if status == 401 || status == 403 { throw SubtitleSourceError.rejected("the Subdl API key was refused") }
        guard (200..<300).contains(status) else {
            throw SubtitleSourceError.rejected((json?["error"] as? String) ?? "answered \(status)")
        }
        if json?["status"] as? Bool == false {
            let message = (json?["error"] as? String) ?? ""
            if message.lowercased().contains("api") && message.lowercased().contains("key") {
                throw SubtitleSourceError.rejected("the Subdl API key was refused")
            }
            return []   // "can't find movie or tv" and the like
        }
        guard let rows = json?["subtitles"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row -> SubtitleResult? in
            guard let path = row["url"] as? String, !path.isEmpty else { return nil }
            // A season pack only helps when the archive holds this episode.
            if query.kind == .episode, let episode = query.episode,
               let from = SubtitleHTTP.int(row["episode_from"]), let to = SubtitleHTTP.int(row["episode_end"]),
               from > 0, to > 0, !(from...to).contains(episode) { return nil }
            let language = SubtitleLanguage.code((row["language"] as? String) ?? (row["lang"] as? String) ?? "en")
            return SubtitleResult(id: "subdl-\(path)", source: name, language: language,
                                  release: (row["release_name"] as? String) ?? (row["name"] as? String) ?? "Subtitle",
                                  hearingImpaired: row["hi"] as? Bool ?? false, format: "zip", payload: path)
        }
    }

    /// Downloads the archive and picks the episode's file out of it.
    public func download(_ result: SubtitleResult, for query: SubtitleQuery) async throws -> SubtitleFile {
        let season = query.season, episode = query.episode
        let path = result.payload.hasPrefix("/") ? result.payload : "/" + result.payload
        guard let url = URL(string: "https://dl.subdl.com" + path) else { throw SubtitleSourceError.notFound }
        let (data, status) = try await SubtitleHTTP.send(URLRequest(url: url))
        guard (200..<300).contains(status) else { throw status == 404 ? SubtitleSourceError.notFound : SubtitleSourceError.rejected("answered \(status)") }
        let entries = (try? ZipReader.entries(data)) ?? []
        guard let file = SubtitleArchive.pick(entries, season: season, episode: episode) else { throw SubtitleSourceError.unreadable }
        return file
    }

    /// Subdl's codes are upper case, Brazilian Portuguese is "BR_PT".
    static func languages(_ codes: [String]) -> [String] {
        codes.flatMap { $0 == "pt" ? ["PT", "BR_PT"] : [$0.uppercased()] }
    }
}

// MARK: - Addic7ed through Gestdown

/// Addic7ed's TV subtitles through Gestdown's open API (no key). Episodes only.
public struct GestdownSource: SubtitleSource {
    public let name = "Addic7ed"
    private static let base = "https://api.gestdown.info"

    public init() {}

    public func search(_ query: SubtitleQuery) async throws -> [SubtitleResult] {
        guard query.kind == .episode, let season = query.season, let episode = query.episode,
              let showName = query.showTitle, !showName.isEmpty else { return [] }
        guard let showID = try await show(named: showName, tvdb: query.showTVDbID) else { return [] }
        var out: [SubtitleResult] = []
        for code in query.languages.prefix(3) {
            guard let language = SubtitleLanguage.englishName(code),
                  let escaped = language.addingPercentEncoding(withAllowedCharacters: SubtitleHTTP.pathSegment),
                  let url = URL(string: "\(Self.base)/subtitles/get/\(showID)/\(season)/\(episode)/\(escaped)") else { continue }
            let (data, status) = try await SubtitleHTTP.send(URLRequest(url: url))
            guard (200..<300).contains(status), let rows = SubtitleHTTP.json(data)?["matchingSubtitles"] as? [[String: Any]] else { continue }
            for row in rows {
                guard let uri = row["downloadUri"] as? String, row["completed"] as? Bool ?? true else { continue }
                let id = (row["subtitleId"] as? String) ?? uri
                out.append(SubtitleResult(id: "addic7ed-\(id)", source: name, language: code,
                                          release: (row["version"] as? String).map { "\(showName) \(String(format: "S%02dE%02d", season, episode)) · \($0)" }
                                              ?? "\(showName) \(String(format: "S%02dE%02d", season, episode))",
                                          hearingImpaired: row["hearingImpaired"] as? Bool ?? false,
                                          downloads: SubtitleHTTP.int(row["downloadCount"]), payload: uri))
            }
        }
        return out
    }

    public func download(_ result: SubtitleResult, for query: SubtitleQuery) async throws -> SubtitleFile {
        guard let url = URL(string: Self.base + result.payload) else { throw SubtitleSourceError.notFound }
        let (data, status) = try await SubtitleHTTP.send(URLRequest(url: url))
        guard (200..<300).contains(status), !data.isEmpty else {
            throw status == 404 ? SubtitleSourceError.notFound : SubtitleSourceError.rejected("answered \(status)")
        }
        return SubtitleFile(data: data, format: "srt")
    }

    /// Gestdown's show ID: the TVDB match, else the exact name, else the first hit.
    private func show(named name: String, tvdb: String?) async throws -> String? {
        guard let escaped = name.addingPercentEncoding(withAllowedCharacters: SubtitleHTTP.pathSegment),
              let url = URL(string: "\(Self.base)/shows/search/\(escaped)") else { return nil }
        let (data, status) = try await SubtitleHTTP.send(URLRequest(url: url))
        if status == 404 { return nil }
        guard (200..<300).contains(status) else { throw SubtitleSourceError.rejected("answered \(status)") }
        let shows = (SubtitleHTTP.json(data)?["shows"] as? [[String: Any]]) ?? []
        if let tvdb, let match = shows.first(where: { SubtitleHTTP.int($0["tvDbId"]).map(String.init) == tvdb }) {
            return match["id"] as? String
        }
        if let exact = shows.first(where: { ($0["name"] as? String)?.caseInsensitiveCompare(name) == .orderedSame }) {
            return exact["id"] as? String
        }
        return shows.first?["id"] as? String
    }
}

// MARK: - Plex

/// Plex's own search (the server asks OpenSubtitles with its own account). Choosing one is
/// done by the server (`PlexServerClient.downloadSubtitle`), so every Plex app sees it.
public struct PlexSubtitleSource: SubtitleSource {
    public static let sourceName = "Plex"
    public let name = PlexSubtitleSource.sourceName
    private let client: PlexServerClient
    private let ratingKey: String

    public init(client: PlexServerClient, ratingKey: String) { self.client = client; self.ratingKey = ratingKey }

    public func search(_ query: SubtitleQuery) async throws -> [SubtitleResult] {
        var out: [SubtitleResult] = []
        for code in query.languages.prefix(2) {
            let streams: [PlexStream]
            do { streams = try await client.searchSubtitles(ratingKey: ratingKey, language: code) }
            catch let error as PlexError { throw SubtitleSourceError.rejected(error.userMessage) }
            out += streams.compactMap { s in
                guard let key = s.key else { return nil }
                return SubtitleResult(id: "plex-\(key)", source: name, language: s.languageCode.map(SubtitleLanguage.code) ?? code,
                                      release: s.title ?? s.displayTitle ?? "Subtitle", hearingImpaired: s.hearingImpaired,
                                      forced: s.forced, hashMatch: s.perfectMatch ?? false, downloads: nil,
                                      format: s.codec ?? "srt", payload: key, via: s.providerTitle)
            }
        }
        return out
    }

    /// Not used: the app asks the server to fetch it (see the type's note).
    public func download(_ result: SubtitleResult, for query: SubtitleQuery) async throws -> SubtitleFile {
        throw SubtitleSourceError.unreadable
    }
}
