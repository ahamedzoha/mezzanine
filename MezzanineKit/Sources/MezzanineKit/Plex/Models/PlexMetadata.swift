import Foundation

/// One library item of any kind: movie, show, season, episode, collection,
/// clip, playlist. Plex uses one `Metadata` shape for all of them and leaves
/// out what doesn't apply, so most fields are optional.
public struct PlexMetadata: Decodable, Sendable, Identifiable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case movie, show, season, episode, collection, clip, playlist, artist, album, track, photo, unknown
    }

    public let ratingKey: String
    public let key: String
    public let guid: String?
    public let kind: Kind
    public let subtype: String?
    public let title: String
    public let titleSort: String?
    public let originalTitle: String?
    public let summary: String?
    public let tagline: String?
    public let year: Int?
    public let originallyAvailableAt: String?
    public let contentRating: String?
    public let studio: String?
    /// Milliseconds.
    public let duration: Int?
    public let addedAt: Date?
    public let updatedAt: Date?
    public let lastViewedAt: Date?
    public private(set) var viewCount: Int?
    /// Resume position in milliseconds.
    public private(set) var viewOffset: Int?
    public let leafCount: Int?
    public let viewedLeafCount: Int?
    public let childCount: Int?
    public let index: Int?
    public let parentIndex: Int?
    public let parentRatingKey: String?
    public let parentTitle: String?
    public let grandparentRatingKey: String?
    public let grandparentTitle: String?
    public let librarySectionID: Int?
    public let librarySectionTitle: String?

    public let thumb: String?
    public let art: String?
    public let parentThumb: String?
    public let grandparentThumb: String?
    public let grandparentArt: String?
    public let theme: String?
    public let images: [PlexImage]
    public let ultraBlur: UltraBlurColors?

    public let rating: Double?
    public let audienceRating: Double?
    public let userRating: Double?

    public let genres: [PlexTag]
    public let directors: [PlexTag]
    public let writers: [PlexTag]
    public let roles: [PlexRole]
    public let countries: [PlexTag]
    public let collections: [PlexTag]
    public let externalGuids: [String]

    public let media: [PlexMedia]
    public let markers: [PlexMarker]
    public let chapters: [PlexChapter]
    /// Trailers, featurettes, scenes (present on detail fetches with includeExtras).
    public let extras: [PlexMetadata]

    public var id: String { ratingKey }

    // MARK: Derived

    public var isWatched: Bool {
        switch kind {
        case .show, .season:
            if let leafCount, let viewedLeafCount { return leafCount > 0 && viewedLeafCount >= leafCount }
            return false
        default:
            return (viewCount ?? 0) > 0 && (viewOffset ?? 0) == 0
        }
    }

    /// The same title as it reads once marked watched or unwatched (for showing the change at
    /// once, before the server's copy arrives). The resume point goes either way, as Plex does.
    public func markedWatched(_ watched: Bool) -> PlexMetadata {
        var copy = self
        copy.viewCount = watched ? max(1, viewCount ?? 0) : 0
        copy.viewOffset = nil
        return copy
    }

    /// 0…1 progress for a partly watched movie or episode.
    public var progress: Double? {
        guard let viewOffset, viewOffset > 0, let duration, duration > 0 else { return nil }
        return min(1, Double(viewOffset) / Double(duration))
    }

    public var unwatchedLeafCount: Int? {
        guard let leafCount else { return nil }
        return max(0, leafCount - (viewedLeafCount ?? 0))
    }

    public func image(_ type: PlexImage.Kind) -> String? {
        images.first { $0.kind == type }?.url
    }

    /// The poster to show for this item in a grid (episodes fall back to the show).
    public var posterPath: String? {
        image(.coverPoster) ?? thumb ?? parentThumb ?? grandparentThumb
    }

    public var backdropPath: String? {
        image(.background) ?? art ?? grandparentArt
    }

    public var clearLogoPath: String? { image(.clearLogo) }

    public var intro: PlexMarker? { markers.first { $0.kind == .intro } }
    /// The credits marker that ends the programme (`final`), else the last one.
    public var credits: PlexMarker? {
        markers.last { $0.kind == .credits && $0.isFinal } ?? markers.last { $0.kind == .credits }
    }

    // MARK: Decoding

    enum CodingKeys: String, CodingKey {
        case ratingKey, key, guid, type, subtype, title, titleSort, originalTitle, summary, tagline, year
        case originallyAvailableAt, contentRating, studio, duration, addedAt, updatedAt, lastViewedAt
        case viewCount, viewOffset, leafCount, viewedLeafCount, childCount, index, parentIndex
        case parentRatingKey, parentTitle, grandparentRatingKey, grandparentTitle
        case librarySectionID, librarySectionTitle
        case thumb, art, parentThumb, grandparentThumb, grandparentArt, theme
        case images = "Image", ultraBlur = "UltraBlurColors"
        case rating, audienceRating, userRating
        case genres = "Genre", directors = "Director", writers = "Writer", roles = "Role"
        case countries = "Country", collections = "Collection", guids = "Guid"
        case media = "Media", markers = "Marker", chapters = "Chapter", extras = "Extras"
    }

    struct ExtrasContainer: Decodable {
        let items: [PlexMetadata]
        enum CodingKeys: String, CodingKey { case items = "Metadata" }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            items = c.list(PlexMetadata.self, .items)
        }
    }

    struct GuidEntry: Decodable { let id: String }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ratingKey = c.lenientString(.ratingKey) ?? ""
        key = (try? c.decode(String.self, forKey: .key)) ?? ""
        guid = try? c.decodeIfPresent(String.self, forKey: .guid)
        kind = Kind(rawValue: (try? c.decode(String.self, forKey: .type)) ?? "") ?? .unknown
        subtype = try? c.decodeIfPresent(String.self, forKey: .subtype)
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        titleSort = try? c.decodeIfPresent(String.self, forKey: .titleSort)
        originalTitle = try? c.decodeIfPresent(String.self, forKey: .originalTitle)
        summary = try? c.decodeIfPresent(String.self, forKey: .summary)
        tagline = try? c.decodeIfPresent(String.self, forKey: .tagline)
        year = c.lenientInt(.year)
        originallyAvailableAt = try? c.decodeIfPresent(String.self, forKey: .originallyAvailableAt)
        contentRating = try? c.decodeIfPresent(String.self, forKey: .contentRating)
        studio = try? c.decodeIfPresent(String.self, forKey: .studio)
        duration = c.lenientInt(.duration)
        addedAt = Date(plexSeconds: c.lenientInt(.addedAt))
        updatedAt = Date(plexSeconds: c.lenientInt(.updatedAt))
        lastViewedAt = Date(plexSeconds: c.lenientInt(.lastViewedAt))
        viewCount = c.lenientInt(.viewCount)
        viewOffset = c.lenientInt(.viewOffset)
        leafCount = c.lenientInt(.leafCount)
        viewedLeafCount = c.lenientInt(.viewedLeafCount)
        childCount = c.lenientInt(.childCount)
        index = c.lenientInt(.index)
        parentIndex = c.lenientInt(.parentIndex)
        parentRatingKey = c.lenientString(.parentRatingKey)
        parentTitle = try? c.decodeIfPresent(String.self, forKey: .parentTitle)
        grandparentRatingKey = c.lenientString(.grandparentRatingKey)
        grandparentTitle = try? c.decodeIfPresent(String.self, forKey: .grandparentTitle)
        librarySectionID = c.lenientInt(.librarySectionID)
        librarySectionTitle = try? c.decodeIfPresent(String.self, forKey: .librarySectionTitle)
        thumb = try? c.decodeIfPresent(String.self, forKey: .thumb)
        art = try? c.decodeIfPresent(String.self, forKey: .art)
        parentThumb = try? c.decodeIfPresent(String.self, forKey: .parentThumb)
        grandparentThumb = try? c.decodeIfPresent(String.self, forKey: .grandparentThumb)
        grandparentArt = try? c.decodeIfPresent(String.self, forKey: .grandparentArt)
        theme = try? c.decodeIfPresent(String.self, forKey: .theme)
        images = c.list(PlexImage.self, .images)
        ultraBlur = try? c.decodeIfPresent(UltraBlurColors.self, forKey: .ultraBlur)
        rating = c.lenientDouble(.rating)
        audienceRating = c.lenientDouble(.audienceRating)
        userRating = c.lenientDouble(.userRating)
        genres = c.list(PlexTag.self, .genres)
        directors = c.list(PlexTag.self, .directors)
        writers = c.list(PlexTag.self, .writers)
        roles = c.list(PlexRole.self, .roles)
        countries = c.list(PlexTag.self, .countries)
        collections = c.list(PlexTag.self, .collections)
        externalGuids = c.list(GuidEntry.self, .guids).map(\.id)
        media = c.list(PlexMedia.self, .media)
        markers = c.list(PlexMarker.self, .markers)
        chapters = c.list(PlexChapter.self, .chapters)
        extras = (try? c.decodeIfPresent(ExtrasContainer.self, forKey: .extras))?.items ?? []
    }

    public static func == (lhs: PlexMetadata, rhs: PlexMetadata) -> Bool {
        lhs.ratingKey == rhs.ratingKey && lhs.updatedAt == rhs.updatedAt
            && lhs.viewOffset == rhs.viewOffset && lhs.viewCount == rhs.viewCount
            && lhs.viewedLeafCount == rhs.viewedLeafCount
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(ratingKey) }
}

public struct PlexTag: Decodable, Sendable, Hashable {
    public let id: Int?
    public let tag: String
    enum CodingKeys: String, CodingKey { case id, tag }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenientInt(.id)
        tag = (try? c.decode(String.self, forKey: .tag)) ?? ""
    }
}

public struct PlexRole: Decodable, Sendable, Hashable {
    public let id: Int?
    public let tag: String
    public let role: String?
    public let thumb: String?
    enum CodingKeys: String, CodingKey { case id, tag, role, thumb }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenientInt(.id)
        tag = (try? c.decode(String.self, forKey: .tag)) ?? ""
        role = try? c.decodeIfPresent(String.self, forKey: .role)
        thumb = try? c.decodeIfPresent(String.self, forKey: .thumb)
    }
}

public struct PlexImage: Decodable, Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case coverPoster, background, clearLogo, backgroundSquare, snapshot, unknown
    }
    public let kind: Kind
    public let url: String
    public let alt: String?
    enum CodingKeys: String, CodingKey { case type, url, alt }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = Kind(rawValue: (try? c.decode(String.self, forKey: .type)) ?? "") ?? .unknown
        url = (try? c.decode(String.self, forKey: .url)) ?? ""
        alt = try? c.decodeIfPresent(String.self, forKey: .alt)
    }
}

/// Four corner colours Plex extracts from the artwork ("UltraBlur"), hex RGB.
public struct UltraBlurColors: Decodable, Sendable, Hashable {
    public let topLeft: String
    public let topRight: String
    public let bottomRight: String
    public let bottomLeft: String
}

public struct PlexMarker: Decodable, Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable { case intro, credits, commercial, unknown }
    public let id: Int?
    public let kind: Kind
    /// Milliseconds.
    public let startTimeOffset: Int
    public let endTimeOffset: Int
    /// The credits marker that ends the programme (Plex sets it on the last one).
    public let isFinal: Bool

    public var start: TimeInterval { TimeInterval(startTimeOffset) / 1000 }
    public var end: TimeInterval { TimeInterval(endTimeOffset) / 1000 }

    public init(id: Int? = nil, kind: Kind, startTimeOffset: Int, endTimeOffset: Int, isFinal: Bool = false) {
        self.id = id
        self.kind = kind
        self.startTimeOffset = startTimeOffset
        self.endTimeOffset = endTimeOffset
        self.isFinal = isFinal
    }

    enum CodingKeys: String, CodingKey { case id, type, startTimeOffset, endTimeOffset, final }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenientInt(.id)
        kind = Kind(rawValue: (try? c.decode(String.self, forKey: .type)) ?? "") ?? .unknown
        startTimeOffset = c.lenientInt(.startTimeOffset) ?? 0
        endTimeOffset = c.lenientInt(.endTimeOffset) ?? 0
        isFinal = c.lenientBool(.final) ?? false
    }
}

public struct PlexChapter: Decodable, Sendable, Hashable {
    public let id: Int?
    public let index: Int?
    public let tag: String?
    public let startTimeOffset: Int
    public let endTimeOffset: Int
    public let thumb: String?

    public var start: TimeInterval { TimeInterval(startTimeOffset) / 1000 }
    public var end: TimeInterval { TimeInterval(endTimeOffset) / 1000 }

    enum CodingKeys: String, CodingKey { case id, index, tag, startTimeOffset, endTimeOffset, thumb }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenientInt(.id)
        index = c.lenientInt(.index)
        tag = try? c.decodeIfPresent(String.self, forKey: .tag)
        startTimeOffset = c.lenientInt(.startTimeOffset) ?? 0
        endTimeOffset = c.lenientInt(.endTimeOffset) ?? 0
        thumb = try? c.decodeIfPresent(String.self, forKey: .thumb)
    }
}
