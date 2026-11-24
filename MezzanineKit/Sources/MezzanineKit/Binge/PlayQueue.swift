import Foundation

/// Titles to play after the one on screen, ahead of the next episode. Kept on this Mac (Plex's own
/// queues aren't touched), so it works with downloads too.
public struct PlayQueue: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable, Identifiable {
        public var id = UUID()
        public let ratingKey: String
        public let title: String
        /// "S5 E1 · White Elephant", "2006".
        public let detail: String

        public init(ratingKey: String, title: String, detail: String) {
            self.ratingKey = ratingKey
            self.title = title
            self.detail = detail
        }
    }

    public private(set) var entries: [Entry] = []
    public static let limit = 500

    public init() {}

    public var first: Entry? { entries.first }
    public var isEmpty: Bool { entries.isEmpty }

    /// Right after what's on screen, in the order given. A title already waiting moves up.
    public mutating func playNext(_ new: [Entry]) { put(new, at: 0) }

    /// After everything waiting. A title already waiting moves to the end.
    public mutating func add(_ new: [Entry]) { put(new, at: nil) }

    public mutating func replace(with new: [Entry]) {
        entries = []
        put(new, at: 0)
    }

    private mutating func put(_ new: [Entry], at index: Int?) {
        var seen = Set<String>()
        let unique = new.filter { seen.insert($0.ratingKey).inserted }
        var rest = entries.filter { !seen.contains($0.ratingKey) }
        rest.insert(contentsOf: unique, at: index ?? rest.count)
        entries = Array(rest.prefix(Self.limit))
    }

    public mutating func remove(_ id: Entry.ID) { entries.removeAll { $0.id == id } }

    /// Takes a title out once it has started, wherever it was started from.
    public mutating func started(_ ratingKey: String) { entries.removeAll { $0.ratingKey == ratingKey } }

    public mutating func move(_ id: Entry.ID, by delta: Int) {
        guard let i = entries.firstIndex(where: { $0.id == id }), entries.indices.contains(i + delta) else { return }
        entries.swapAt(i, i + delta)
    }

    public mutating func clear() { entries = [] }

    /// What Shuffle plays: every title once, in random order; specials stay out unless they're all
    /// there is; `unwatchedOnly` falls back to everything when nothing is unwatched.
    public static func shuffled<G: RandomNumberGenerator>(_ items: [PlexMetadata], unwatchedOnly: Bool, using generator: inout G) -> [PlexMetadata] {
        var seen = Set<String>()
        let playable = items.filter { [.movie, .episode, .show].contains($0.kind) && seen.insert($0.ratingKey).inserted }
        let regular = playable.filter { $0.kind != .episode || ($0.parentIndex ?? 1) > 0 }
        let pool = regular.isEmpty ? playable : regular
        let unwatched = pool.filter { !$0.isWatched }
        return (unwatchedOnly && !unwatched.isEmpty ? unwatched : pool).shuffled(using: &generator)
    }
}
