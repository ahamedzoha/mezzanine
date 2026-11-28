import Foundation

/// What kind of release an album is, from Plex's Format and Subformat tags.
///
/// Format says Album, EP or Single (every album has one); Subformat refines it (Live,
/// Compilation, Soundtrack, Remix) on the few albums that carry one, and wins when present.
public enum AlbumType: String, Sendable, Codable, CaseIterable, Hashable {
    case album, ep, single, live, compilation, soundtrack, remix

    public var label: String {
        switch self {
        case .album: return "Album"
        case .ep: return "EP"
        case .single: return "Single"
        case .live: return "Live"
        case .compilation: return "Compilation"
        case .soundtrack: return "Soundtrack"
        case .remix: return "Remix"
        }
    }

    /// Plural heading for a discography section.
    public var sectionTitle: String {
        switch self {
        case .album: return "Albums"
        case .ep: return "EPs"
        case .single: return "Singles"
        case .live: return "Live"
        case .compilation: return "Compilations"
        case .soundtrack: return "Soundtracks"
        case .remix: return "Remixes"
        }
    }

    /// Discography order on an artist page.
    public static let discographyOrder: [AlbumType] = [.album, .ep, .single, .live, .compilation, .soundtrack, .remix]

    /// One name from either tag list (case-insensitive); nil when it is none of the known types.
    public init?(tag: String) {
        switch tag.trimmingCharacters(in: .whitespaces).lowercased() {
        case "album": self = .album
        case "ep": self = .ep
        case "single": self = .single
        case "live": self = .live
        case "compilation": self = .compilation
        case "soundtrack": self = .soundtrack
        case "remix": self = .remix
        default: return nil
        }
    }

    /// Subformat first (it is the more specific), then Format; an album with neither is an Album.
    /// A Subformat list can hold several (`Compilation, Live`): the first known one wins.
    public init(formats: [String], subformats: [String]) {
        if let sub = subformats.lazy.compactMap({ AlbumType(tag: $0) }).first {
            self = sub
        } else if let format = formats.lazy.compactMap({ AlbumType(tag: $0) }).first {
            self = format
        } else {
            self = .album
        }
    }

    public init(_ metadata: PlexMetadata) {
        self.init(formats: metadata.formats.map(\.tag), subformats: metadata.subformats.map(\.tag))
    }
}
