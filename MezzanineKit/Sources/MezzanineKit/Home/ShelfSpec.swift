import Foundation

/// One shelf the owner put on a Home (the main Home or a library's Shelves layout).
public struct ShelfSpec: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    /// Empty means "use the source's own name" (a Plex hub's title, a collection's name).
    public var title: String
    public var source: Source
    public var hidden: Bool

    public enum Source: Codable, Hashable, Sendable {
        /// A Plex hub: global (`home.continue`) when `section` is nil, else a library's own
        /// (`movie.recentlyadded.1`).
        case hub(identifier: String, section: String?)
        case collection(ratingKey: String, section: String)
        case playlist(ratingKey: String)
        case smart(SmartRule)
        /// The account's watchlist: its titles that are on this server.
        case watchlist
    }

    public init(id: String = UUID().uuidString, title: String = "", source: Source, hidden: Bool = false) {
        self.id = id
        self.title = title
        self.source = source
        self.hidden = hidden
    }

    public var smartRule: SmartRule? {
        if case .smart(let rule) = source { return rule }
        return nil
    }
}

/// A shelf defined by rules over the local index: every condition must hold.
public struct SmartRule: Codable, Hashable, Sendable {
    /// Library section keys; empty means every indexed video library.
    public var sections: [String]
    /// Plex kinds shown (`movie`, `show`, `episode`); empty means movies and shows.
    public var kinds: [String]
    public var conditions: [SmartCondition]
    public var sort: LibraryQuery.Sort
    /// How many titles the shelf shows (the index may hold more).
    public var limit: Int

    public init(sections: [String] = [], kinds: [String] = [], conditions: [SmartCondition] = [],
                sort: LibraryQuery.Sort = .addedNewest, limit: Int = 24) {
        self.sections = sections
        self.kinds = kinds
        self.conditions = conditions
        self.sort = sort
        self.limit = limit
    }

    public var effectiveKinds: [String] { kinds.isEmpty ? ["movie", "show"] : kinds }

    /// "Unwatched · Comedy · 1990s": the default name and the strip's source line.
    public var summary: String {
        let parts = conditions.map(\.label)
        return parts.isEmpty ? "Everything" : parts.joined(separator: " · ")
    }
}

/// One condition of a smart shelf.
public enum SmartCondition: Codable, Hashable, Sendable {
    case genre(String, excluded: Bool)
    case decade(Int)
    case years(from: Int, to: Int)
    case watch(WatchState)
    case addedWithin(days: Int)
    case minRating(Double)
    case resolution(String)
    case hdr
    case minChannels(Int)
    case collection(String)
    case person(String)

    public enum WatchState: String, Codable, Hashable, Sendable, CaseIterable {
        case unwatched, inProgress, watched
        public var label: String {
            switch self {
            case .unwatched: "Unwatched"
            case .inProgress: "In progress"
            case .watched: "Watched"
            }
        }
    }

    /// The field this condition belongs to (rule rows pick a field, then a value).
    public enum Field: String, CaseIterable, Sendable, Identifiable {
        case genre, decade, years, watch, added, rating, resolution, hdr, channels, collection, person
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .genre: "Genre"
            case .decade: "Decade"
            case .years: "Released"
            case .watch: "Watch state"
            case .added: "Added"
            case .rating: "Rating"
            case .resolution: "Resolution"
            case .hdr: "HDR"
            case .channels: "Audio"
            case .collection: "Collection"
            case .person: "Cast or crew"
            }
        }
        /// A sensible first value when a row switches to this field.
        public var defaultCondition: SmartCondition {
            switch self {
            case .genre: .genre("Comedy", excluded: false)
            case .decade: .decade(1990)
            case .years: .years(from: 2000, to: 2009)
            case .watch: .watch(.unwatched)
            case .added: .addedWithin(days: 30)
            case .rating: .minRating(7)
            case .resolution: .resolution("1080")
            case .hdr: .hdr
            case .channels: .minChannels(6)
            case .collection: .collection("")
            case .person: .person("")
            }
        }
    }

    public var field: Field {
        switch self {
        case .genre: .genre
        case .decade: .decade
        case .years: .years
        case .watch: .watch
        case .addedWithin: .added
        case .minRating: .rating
        case .resolution: .resolution
        case .hdr: .hdr
        case .minChannels: .channels
        case .collection: .collection
        case .person: .person
        }
    }

    public var label: String {
        switch self {
        case .genre(let g, let excluded): excluded ? "Not \(g)" : g
        case .decade(let d): "\(d)s"
        case .years(let a, let b): a == b ? "\(a)" : "\(a)–\(b)"
        case .watch(let w): w.label
        case .addedWithin(let days): days % 365 == 0 ? "Added in the last \(days / 365 == 1 ? "year" : "\(days / 365) years")"
                                                    : "Added in the last \(days) days"
        case .minRating(let r): String(format: "Rated %g+", r)
        case .resolution(let r): ResolutionLabel.label(r)
        case .hdr: "HDR"
        case .minChannels(let c): c >= 8 ? "7.1" : (c >= 6 ? "5.1 or more" : "\(c) channels or more")
        case .collection(let c): c.isEmpty ? "Collection" : c
        case .person(let p): p.isEmpty ? "Person" : p
        }
    }

    /// A condition with no value yet (an empty person or collection) matches everything.
    public var isComplete: Bool {
        switch self {
        case .collection(let c): !c.trimmingCharacters(in: .whitespaces).isEmpty
        case .person(let p): !p.trimmingCharacters(in: .whitespaces).isEmpty
        default: true
        }
    }
}

/// Plex's `videoResolution` values as people say them.
public enum ResolutionLabel {
    public static let all = ["4k", "1080", "720", "sd"]
    public static func label(_ r: String) -> String {
        switch r.lowercased() {
        case "4k": "4K"
        case "1080": "1080p"
        case "720": "720p"
        case "480", "576", "sd": "SD"
        default: r
        }
    }
}

/// The shelves of every Home, keyed by scope: `home` for the main Home, a section key for a
/// library's Shelves layout.
public struct HomeLayout: Codable, Hashable, Sendable {
    public var scopes: [String: [ShelfSpec]]

    public init(scopes: [String: [ShelfSpec]] = [:]) { self.scopes = scopes }

    public static let mainScope = "home"

    /// What Home shows before the owner changes anything: Plex's own rows.
    public static let defaultHome: [ShelfSpec] = [
        ShelfSpec(id: "hub:home.continue", source: .hub(identifier: "home.continue", section: nil)),
        ShelfSpec(id: "hub:home.movies.recent", source: .hub(identifier: "home.movies.recent", section: nil)),
        ShelfSpec(id: "hub:home.television.recent", source: .hub(identifier: "home.television.recent", section: nil)),
    ]
}
