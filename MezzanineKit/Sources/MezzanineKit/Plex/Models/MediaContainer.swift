import Foundation

/// The envelope every Plex Media Server JSON response sits in.
struct MediaContainerEnvelope<Content: Decodable>: Decodable {
    let container: Content
    enum CodingKeys: String, CodingKey { case container = "MediaContainer" }
}

/// One page of a list endpoint: the items plus paging info.
public struct Page<Item: Sendable>: Sendable {
    public var items: [Item]
    /// Index of the first item in the full list.
    public var offset: Int
    /// Size of the full list, when the server says (`totalSize`).
    public var totalSize: Int?

    public init(items: [Item], offset: Int, totalSize: Int?) {
        self.items = items
        self.offset = offset
        self.totalSize = totalSize
    }

    public var hasMore: Bool {
        guard let totalSize else { return false }
        return offset + items.count < totalSize
    }
}

/// `MediaContainer` holding `Metadata` items (library listings, children, detail).
struct MetadataContainer: Decodable {
    let metadata: [PlexMetadata]
    let offset: Int?
    let totalSize: Int?
    let size: Int?
    let librarySectionID: Int?

    enum CodingKeys: String, CodingKey {
        case metadata = "Metadata", offset, totalSize, size, librarySectionID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        metadata = c.list(PlexMetadata.self, .metadata)
        offset = c.lenientInt(.offset)
        totalSize = c.lenientInt(.totalSize)
        size = c.lenientInt(.size)
        librarySectionID = c.lenientInt(.librarySectionID)
    }
}

struct DirectoryContainer<D: Decodable>: Decodable {
    let directories: [D]
    enum CodingKeys: String, CodingKey { case directories = "Directory" }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        directories = c.list(D.self, .directories)
    }
}

struct HubContainer: Decodable {
    let hubs: [PlexHub]
    enum CodingKeys: String, CodingKey { case hubs = "Hub" }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hubs = c.list(PlexHub.self, .hubs)
    }
}

struct StreamContainer: Decodable {
    let streams: [PlexStream]
    enum CodingKeys: String, CodingKey { case streams = "Stream" }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        streams = c.list(PlexStream.self, .streams)
    }
}
