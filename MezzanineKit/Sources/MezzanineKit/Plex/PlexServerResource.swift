import Foundation

/// A Plex Media Server the account can reach, as plex.tv lists it.
public struct PlexServerResource: Decodable, Sendable, Identifiable, Hashable {
    public let name: String
    public let product: String?
    public let productVersion: String?
    public let clientIdentifier: String
    public let provides: String
    public let owned: Bool
    public let home: Bool
    public let presence: Bool
    public let httpsRequired: Bool
    public let publicAddressMatches: Bool
    /// The token to use with this server (differs from the account token on
    /// shared servers).
    public let accessToken: String?
    public let connections: [PlexConnection]

    public var id: String { clientIdentifier }
    public var isServer: Bool { provides.split(separator: ",").contains("server") }

    enum CodingKeys: String, CodingKey {
        case name, product, productVersion, clientIdentifier, provides, owned, home, presence
        case httpsRequired, publicAddressMatches, accessToken, connections
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decode(String.self, forKey: .name)) ?? "Plex"
        product = try? c.decodeIfPresent(String.self, forKey: .product)
        productVersion = try? c.decodeIfPresent(String.self, forKey: .productVersion)
        clientIdentifier = (try? c.decode(String.self, forKey: .clientIdentifier)) ?? ""
        provides = (try? c.decode(String.self, forKey: .provides)) ?? ""
        owned = c.lenientBool(.owned) ?? false
        home = c.lenientBool(.home) ?? false
        presence = c.lenientBool(.presence) ?? false
        httpsRequired = c.lenientBool(.httpsRequired) ?? false
        publicAddressMatches = c.lenientBool(.publicAddressMatches) ?? false
        accessToken = try? c.decodeIfPresent(String.self, forKey: .accessToken)
        connections = c.list(PlexConnection.self, .connections)
    }

    public init(name: String, clientIdentifier: String, owned: Bool = true, accessToken: String? = nil,
                connections: [PlexConnection], httpsRequired: Bool = false) {
        self.name = name
        self.product = "Plex Media Server"
        self.productVersion = nil
        self.clientIdentifier = clientIdentifier
        self.provides = "server"
        self.owned = owned
        self.home = false
        self.presence = true
        self.httpsRequired = httpsRequired
        self.publicAddressMatches = true
        self.accessToken = accessToken
        self.connections = connections
    }

    /// Every address worth trying, best first: plex.tv's own list, plus a
    /// plain-http LAN address for each local connection when the server
    /// allows it (a fallback if plex.direct names don't resolve, e.g. a DNS
    /// resolver with rebinding protection).
    public var candidates: [PlexConnection] {
        var out = connections
        if !httpsRequired {
            for conn in connections where conn.local && !conn.relay && conn.protocolName == "https" {
                let plain = PlexConnection(protocolName: "http", address: conn.address, port: conn.port,
                                           uri: "http://\(conn.address):\(conn.port)", local: true, relay: false)
                if !out.contains(where: { $0.uri == plain.uri }) { out.append(plain) }
            }
        }
        return out.sorted { $0.rank < $1.rank }
    }
}

public struct PlexConnection: Decodable, Sendable, Hashable {
    public let protocolName: String
    public let address: String
    public let port: Int
    public let uri: String
    public let local: Bool
    public let relay: Bool

    public init(protocolName: String, address: String, port: Int, uri: String, local: Bool, relay: Bool) {
        self.protocolName = protocolName
        self.address = address
        self.port = port
        self.uri = uri
        self.local = local
        self.relay = relay
    }

    public var url: URL? { URL(string: uri) }

    public enum Route: String, Sendable, Hashable { case local, remote, relay }
    public var route: Route { relay ? .relay : (local ? .local : .remote) }

    /// Lower is better: LAN https (plex.direct), LAN http, remote, relay.
    public var rank: Int {
        switch route {
        case .local: return protocolName == "https" ? 0 : 1
        case .remote: return 2
        case .relay: return 3
        }
    }

    enum CodingKeys: String, CodingKey { case protocolName = "protocol", address, port, uri, local, relay }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        protocolName = (try? c.decode(String.self, forKey: .protocolName)) ?? "https"
        address = (try? c.decode(String.self, forKey: .address)) ?? ""
        port = c.lenientInt(.port) ?? 32400
        uri = (try? c.decode(String.self, forKey: .uri)) ?? ""
        local = c.lenientBool(.local) ?? false
        relay = c.lenientBool(.relay) ?? false
    }
}
