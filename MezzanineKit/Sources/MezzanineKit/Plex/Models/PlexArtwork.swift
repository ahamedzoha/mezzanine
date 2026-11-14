import Foundation

/// Which picture of a title: its poster or its background.
public enum ArtworkKind: String, Sendable, Codable, CaseIterable {
    case poster, background

    /// Plex's path component: `/library/metadata/{id}/posters` and `/arts`.
    var listPath: String { self == .poster ? "posters" : "arts" }
    var setPath: String { self == .poster ? "poster" : "art" }
}

/// One picture Plex offers for a title (from an agent, an upload such as Kometa's, or the
/// title's own folder).
public struct ArtworkCandidate: Decodable, Sendable, Hashable, Identifiable {
    /// Where to draw it from: a server path or a provider's URL.
    public let key: String
    /// Plex's identifier for the choice (what `PUT …/poster?url=` takes).
    public let ratingKey: String
    public let provider: String?
    public let selected: Bool
    public let thumb: String?

    public var id: String { ratingKey }

    /// "TMDB", "Uploaded", "Original"… for the caption under each picture.
    public var source: String {
        if ratingKey.hasPrefix("upload://") { return "Uploaded" }
        if ratingKey.hasPrefix("metadata://") { return "Original" }
        if ratingKey.hasPrefix("media://") || ratingKey.hasPrefix("file://") { return "Local file" }
        switch provider?.lowercased() {
        case "tmdb", "com.plexapp.agents.themoviedb": return "TMDB"
        case "tvdb", "com.plexapp.agents.thetvdb": return "TVDB"
        case "fanarttv", "fanart": return "Fanart.tv"
        case "imdb": return "IMDb"
        case "gracenote": return "Gracenote"
        case .some(let p) where !p.isEmpty: return p.capitalized
        default: return "Plex"
        }
    }

    enum CodingKeys: String, CodingKey { case key, ratingKey, provider, selected, thumb }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        ratingKey = (try? c.decode(String.self, forKey: .ratingKey)) ?? key
        provider = try? c.decode(String.self, forKey: .provider)
        selected = c.lenientBool(.selected) ?? false
        thumb = try? c.decode(String.self, forKey: .thumb)
    }
}
