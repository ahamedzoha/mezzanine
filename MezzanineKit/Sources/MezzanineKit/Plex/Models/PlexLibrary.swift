import Foundation

/// A library section (Movies, TV Shows, Courses…).
public struct PlexLibrarySection: Decodable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        case movie, show, artist, photo, unknown
    }

    public let key: String
    public let kind: Kind
    public let title: String
    public let agent: String?
    public let scanner: String?
    public let language: String?
    public let uuid: String?
    public let updatedAt: Date?
    public let scannedAt: Date?
    public let thumb: String?
    public let art: String?

    public var id: String { key }

    /// "Plex Video Files" + no agent: a folder of files, not a matched movie
    /// library (the user's Courses). Shown with a folder-first layout.
    public var isPersonalMedia: Bool { agent == "tv.plex.agents.none" || agent == "com.plexapp.agents.none" }

    enum CodingKeys: String, CodingKey {
        case key, type, title, agent, scanner, language, uuid, updatedAt, scannedAt, thumb, art
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = c.lenientString(.key) ?? ""
        kind = Kind(rawValue: (try? c.decode(String.self, forKey: .type)) ?? "") ?? .unknown
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        agent = try? c.decodeIfPresent(String.self, forKey: .agent)
        scanner = try? c.decodeIfPresent(String.self, forKey: .scanner)
        language = try? c.decodeIfPresent(String.self, forKey: .language)
        uuid = try? c.decodeIfPresent(String.self, forKey: .uuid)
        updatedAt = Date(plexSeconds: c.lenientInt(.updatedAt))
        scannedAt = Date(plexSeconds: c.lenientInt(.scannedAt))
        thumb = try? c.decodeIfPresent(String.self, forKey: .thumb)
        art = try? c.decodeIfPresent(String.self, forKey: .art)
    }
}

/// A hub (a shelf the server computes: Continue Watching, On Deck, Recently Added…).
public struct PlexHub: Decodable, Sendable, Identifiable {
    public let hubIdentifier: String
    public let title: String
    public let type: String?
    public let context: String?
    public let key: String?
    public let size: Int
    public let more: Bool
    public let style: String?
    public let promoted: Bool
    public let items: [PlexMetadata]
    /// People a search found (actor and director hubs list them as directories).
    public let people: [Person]

    public var id: String { hubIdentifier }

    public struct Person: Decodable, Sendable, Hashable, Identifiable {
        public let id: String
        public let name: String
        /// An absolute URL (Plex's metadata images) or a server path.
        public let thumb: String?
        enum CodingKeys: String, CodingKey { case id, tag, thumb }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = (try? c.decode(String.self, forKey: .tag)) ?? ""
            id = c.lenientString(.id) ?? name
            thumb = try? c.decodeIfPresent(String.self, forKey: .thumb)
        }
    }

    enum CodingKeys: String, CodingKey {
        case hubIdentifier, title, type, context, key, size, more, style, promoted
        case metadata = "Metadata", directory = "Directory"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hubIdentifier = (try? c.decode(String.self, forKey: .hubIdentifier)) ?? UUID().uuidString
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        type = try? c.decodeIfPresent(String.self, forKey: .type)
        context = try? c.decodeIfPresent(String.self, forKey: .context)
        key = try? c.decodeIfPresent(String.self, forKey: .key)
        size = c.lenientInt(.size) ?? 0
        more = c.lenientBool(.more) ?? false
        style = try? c.decodeIfPresent(String.self, forKey: .style)
        promoted = c.lenientBool(.promoted) ?? false
        items = c.list(PlexMetadata.self, .metadata)
        let kind = type ?? ""
        people = ["actor", "director", "writer", "producer"].contains(kind)
            ? c.list(Person.self, .directory).filter { !$0.name.isEmpty } : []
    }
}
