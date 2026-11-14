import Foundation

/// A sign-in PIN from plex.tv. The user approves it in the browser
/// (`authURL`) or by typing `code` at plex.tv/link; polling `pin(id:)` then
/// returns the account token.
public struct PlexPin: Decodable, Sendable, Equatable {
    public let id: Int
    public let code: String
    public let authToken: String?
    public let expiresIn: Int?
    public let expiresAt: String?

    public init(id: Int, code: String, authToken: String?, expiresIn: Int? = nil, expiresAt: String? = nil) {
        self.id = id
        self.code = code
        self.authToken = authToken
        self.expiresIn = expiresIn
        self.expiresAt = expiresAt
    }
}

/// The signed-in plex.tv account.
public struct PlexAccount: Decodable, Sendable, Equatable {
    public let id: Int
    public let uuid: String
    public let username: String?
    public let title: String?
    public let email: String?
    public let thumb: String?
    public let home: Bool?
    public let subscription: Subscription?

    public struct Subscription: Decodable, Sendable, Equatable {
        public let active: Bool?
        public let plan: String?
    }

    public var displayName: String { title ?? username ?? "Plex user" }
}

/// A member of the account's Plex Home.
public struct PlexHomeUser: Decodable, Sendable, Equatable, Identifiable {
    public let id: Int
    public let uuid: String
    public let title: String
    public let username: String?
    public let thumb: String?
    public let admin: Bool
    public let guest: Bool
    public let restricted: Bool
    /// The user has a PIN to enter when switching to them.
    public let protected: Bool

    enum CodingKeys: String, CodingKey { case id, uuid, title, username, thumb, admin, guest, restricted, protected }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenientInt(.id) ?? 0
        uuid = (try? c.decode(String.self, forKey: .uuid)) ?? ""
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        username = try? c.decodeIfPresent(String.self, forKey: .username)
        thumb = try? c.decodeIfPresent(String.self, forKey: .thumb)
        admin = c.lenientBool(.admin) ?? false
        guest = c.lenientBool(.guest) ?? false
        restricted = c.lenientBool(.restricted) ?? false
        protected = c.lenientBool(.protected) ?? false
    }
}

/// Talks to plex.tv: sign-in, the account, its servers and Home users.
public struct PlexTV: Sendable {
    public static let baseURL = URL(string: "https://plex.tv")!

    public let identity: PlexIdentity
    let session: URLSession

    public init(identity: PlexIdentity, session: URLSession = Transport.makeAPISession()) {
        self.identity = identity
        self.session = session
    }

    // MARK: Sign-in

    /// `strong` PINs are long and only work through `authURL`; short ones
    /// (4 characters) can also be typed at plex.tv/link.
    public func createPin(strong: Bool = true) async throws -> PlexPin {
        try await send("POST", "/api/v2/pins", query: [URLQueryItem(name: "strong", value: strong ? "true" : "false")], token: nil)
    }

    public func pin(id: Int) async throws -> PlexPin {
        try await send("GET", "/api/v2/pins/\(id)", token: nil)
    }

    /// The browser page where the user approves a strong PIN.
    public func authURL(for pin: PlexPin) -> URL {
        var c = URLComponents(string: "https://app.plex.tv/auth")!
        var f = URLComponents()
        f.queryItems = [
            URLQueryItem(name: "clientID", value: identity.clientIdentifier),
            URLQueryItem(name: "code", value: pin.code),
            URLQueryItem(name: "context[device][product]", value: identity.product),
            URLQueryItem(name: "context[device][platform]", value: identity.platform),
            URLQueryItem(name: "context[device][device]", value: identity.device),
        ]
        c.fragment = "?" + (f.percentEncodedQuery ?? "")
        return c.url!
    }

    /// Polls until the PIN is approved, expires, or the task is cancelled.
    public func waitForToken(pin: PlexPin, interval: Duration = .seconds(1.5)) async throws -> String {
        while true {
            try Task.checkCancellation()
            let current = try await self.pin(id: pin.id)
            if let token = current.authToken, !token.isEmpty { return token }
            try await Task.sleep(for: interval)
        }
    }

    // MARK: Account

    public func account(token: String) async throws -> PlexAccount {
        try await send("GET", "/api/v2/user", token: token)
    }

    public func resources(token: String) async throws -> [PlexServerResource] {
        let all: [PlexServerResource] = try await send("GET", "/api/v2/resources", query: [
            URLQueryItem(name: "includeHttps", value: "1"),
            URLQueryItem(name: "includeRelay", value: "1"),
            URLQueryItem(name: "includeIPv6", value: "0"),
        ], token: token)
        return all.filter(\.isServer)
    }

    public func homeUsers(token: String) async throws -> [PlexHomeUser] {
        let list: HomeUserList = try await send("GET", "/api/v2/home/users", token: token)
        return list.users
    }

    /// Switches to a Home user and returns that user's token.
    public func switchHomeUser(uuid: String, pin: String?, token: String) async throws -> String {
        struct Switched: Decodable { let authToken: String }
        var query: [URLQueryItem] = []
        if let pin { query.append(URLQueryItem(name: "pin", value: pin)) }
        let switched: Switched = try await send("POST", "/api/v2/home/users/\(uuid)/switch", query: query, token: token)
        return switched.authToken
    }

    // MARK: Plumbing

    func send<T: Decodable>(_ method: String, _ path: String, query: [URLQueryItem] = [], token: String?) async throws -> T {
        var components = URLComponents(url: Self.baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        for (k, v) in identity.headers { request.setValue(v, forHTTPHeaderField: k) }
        if let token { request.setValue(token, forHTTPHeaderField: "X-Plex-Token") }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw PlexError.from(error, localNetworkSuspected: false)
        }
        let http = response as? HTTPURLResponse
        if let failure = PlexError.from(status: http?.statusCode ?? 0, location: http?.value(forHTTPHeaderField: "Location")) {
            throw failure
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw PlexError.decoding("\(path): \(error)")
        }
    }
}

/// plex.tv answers `/api/v2/home/users` as `{ "users": [...] }` (older answers were a bare
/// array); accept both.
struct HomeUserList: Decodable {
    let users: [PlexHomeUser]
    enum CodingKeys: String, CodingKey { case users }
    init(from decoder: Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: CodingKeys.self), keyed.contains(.users) {
            users = keyed.list(PlexHomeUser.self, .users)
        } else {
            users = try [PlexHomeUser](from: decoder)
        }
    }
}
