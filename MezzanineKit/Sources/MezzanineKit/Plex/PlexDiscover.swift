import Foundation

/// The Plex account's watchlist, on Plex's own service rather than a server. Managed Home profiles
/// have none (Plex refuses them).
public struct PlexDiscover: Sendable {
    public static let baseURL = URL(string: "https://discover.provider.plex.tv")!
    static let pageSize = 100

    let identity: PlexIdentity
    let token: String
    let session: URLSession

    public init(identity: PlexIdentity, token: String, session: URLSession = Transport.makeAPISession()) {
        self.identity = identity
        self.token = token
        self.session = session
    }

    /// Every film and show on the watchlist, newest first.
    public func watchlist() async throws -> [PlexMetadata] {
        var out: [PlexMetadata] = []
        while true {
            let request = request("GET", "/library/sections/watchlist/all", query: [
                URLQueryItem(name: "sort", value: "watchlistedAt:desc"),
                URLQueryItem(name: "X-Plex-Container-Start", value: String(out.count)),
                URLQueryItem(name: "X-Plex-Container-Size", value: String(Self.pageSize)),
            ])
            let page = try Self.decode(try await perform(request))
            out += page.items
            if page.items.isEmpty || out.count >= page.total { break }
        }
        return out.filter { $0.kind == .movie || $0.kind == .show }
    }

    /// Adds or removes a title by its Discover id (`PlexMetadata.discoverID`). Never retried.
    public func setWatchlisted(_ id: String, _ on: Bool) async throws {
        _ = try await perform(request("PUT", on ? "/actions/addToWatchlist" : "/actions/removeFromWatchlist",
                                      query: [URLQueryItem(name: "ratingKey", value: id)]))
    }

    static func decode(_ data: Data) throws -> (items: [PlexMetadata], total: Int) {
        struct Envelope: Decodable {
            struct Container: Decodable {
                let items: [PlexMetadata]
                let total: Int
                enum CodingKeys: String, CodingKey { case items = "Metadata", totalSize, size }
                init(from decoder: Decoder) throws {
                    let c = try decoder.container(keyedBy: CodingKeys.self)
                    items = c.list(PlexMetadata.self, .items)
                    total = c.lenientInt(.totalSize) ?? items.count
                }
            }
            let MediaContainer: Container
        }
        do {
            let container = try JSONDecoder().decode(Envelope.self, from: data).MediaContainer
            return (container.items, container.total)
        } catch { throw PlexError.decoding("watchlist: \(error)") }
    }

    private func request(_ method: String, _ path: String, query: [URLQueryItem]) -> URLRequest {
        var components = URLComponents(url: Self.baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        components.queryItems = query
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        for (k, v) in identity.headers { request.setValue(v, forHTTPHeaderField: k) }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        return request
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) } catch {
            throw PlexError.from(error, localNetworkSuspected: false)
        }
        let http = response as? HTTPURLResponse
        if let failure = PlexError.from(status: http?.statusCode ?? 0, location: http?.value(forHTTPHeaderField: "Location")) { throw failure }
        return data
    }
}

extension PlexMetadata {
    /// The title's id on Plex's own service, from its guid ("plex://movie/5d77…"); nil for personal
    /// media and old agents.
    public var discoverID: String? {
        guard kind == .movie || kind == .show, let guid, let url = URL(string: guid), url.scheme == "plex",
              url.host() == kind.rawValue else { return nil }
        let id = url.lastPathComponent
        return id.isEmpty || id == "/" ? nil : id
    }

    /// A title known only to Plex's service: it isn't on this server, so there's nothing to play.
    public var isDiscoverOnly: Bool { discoverID == ratingKey }
}
