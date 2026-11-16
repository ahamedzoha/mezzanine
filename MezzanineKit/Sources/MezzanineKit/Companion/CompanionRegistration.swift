import Foundation

/// Puts the player on the account's plex.tv device list, so the Plex mobile apps show it in their
/// cast sheet. They list only players plex.tv knows (`provides` with `player`, plus a connection
/// address); a player only heard on the LAN through GDM never appears there.
///
/// How (Plex's own PIN flow, as Music Assistant's "Link with plex.tv" does):
/// 1. A PIN is created under the player's identity, with `X-Plex-Provides: client,player,pubsub-player`.
/// 2. The owner approves it in the browser (`app.plex.tv/auth`, the same page as signing in). That
///    creates the device record and gives the player its own token. Never linked without the owner.
/// 3. With that token, the player's device id comes from `/devices.xml`, and its LAN address is
///    published with `PUT /devices/<id>?Connection[][uri]=…`, again on every start (the address
///    can change).
public struct CompanionRegistration: Sendable {
    public static let provides = "client,player,pubsub-player"

    public struct Device: Sendable, Equatable {
        public let id: String
        public let clientIdentifier: String
        public let provides: String
        public let connections: [String]
    }

    private let identity: PlexIdentity
    private let session: URLSession

    public init(identity: PlexIdentity, session: URLSession = Transport.makeAPISession()) {
        var identity = identity
        identity.provides = Self.provides
        self.identity = identity
        self.session = session
    }

    /// Step 1: a PIN for the player and the page where the owner approves it.
    public func beginLink() async throws -> (pin: PlexPin, approvalURL: URL) {
        let tv = PlexTV(identity: identity, session: session)
        let pin = try await tv.createPin(strong: true)
        return (pin, tv.authURL(for: pin))
    }

    /// Step 2: waits (until cancelled) for the owner's approval; the player's own token.
    public func finishLink(_ pin: PlexPin) async throws -> String {
        try await PlexTV(identity: identity, session: session).waitForToken(pin: pin)
    }

    /// The account's devices (`/devices.xml`).
    public func devices(token: String) async throws -> [Device] {
        let data = try await raw("GET", "/devices.xml", token: token)
        return Self.parseDevices(data)
    }

    /// Publishes where controllers reach the player (replaces the previous addresses).
    public func publish(connections: [URL], token: String) async throws {
        guard !connections.isEmpty else { return }
        guard let device = try await devices(token: token).first(where: { $0.clientIdentifier == identity.clientIdentifier }) else {
            throw PlexError.decoding("the player isn't on the account's device list")
        }
        let query = connections.map { URLQueryItem(name: "Connection[][uri]", value: $0.absoluteString) }
        _ = try await raw("PUT", "/devices/\(device.id)", query: query, token: token)
    }

    // MARK: Plumbing

    private func raw(_ method: String, _ path: String, query: [URLQueryItem] = [], form: [(String, String)] = [],
                     token: String) async throws -> Data {
        var components = URLComponents(url: PlexTV.baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        for (k, v) in identity.headers { request.setValue(v, forHTTPHeaderField: k) }
        request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        if !form.isEmpty {
            var body = URLComponents()
            body.queryItems = form.map { URLQueryItem(name: $0.0, value: $0.1) }
            request.httpBody = Data((body.percentEncodedQuery ?? "").utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw PlexError.decoding("\(method) \(path): HTTP \(status)") }
        return data
    }

    static func parseDevices(_ data: Data) -> [Device] {
        let parser = DevicesParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        xml.parse()
        return parser.devices
    }
}

private final class DevicesParser: NSObject, XMLParserDelegate {
    var devices: [CompanionRegistration.Device] = []
    private var current: [String: String]?
    private var connections: [String] = []

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        if name == "Device" {
            current = attributes
            connections = []
        } else if name == "Connection", current != nil, let uri = attributes["uri"] {
            connections.append(uri)
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard name == "Device", let a = current else { return }
        devices.append(.init(id: a["id"] ?? "", clientIdentifier: a["clientIdentifier"] ?? "",
                             provides: a["provides"] ?? "", connections: connections))
        current = nil
    }
}
