import Foundation

/// A playback that just stopped, as this Mac saw it.
public struct PlaybackStop: Sendable {
    public let item: PlexMetadata
    public let time: TimeInterval
    public let duration: TimeInterval
    public let at: Date

    public init(item: PlexMetadata, time: TimeInterval, duration: TimeInterval, at: Date = Date()) {
        self.item = item
        self.time = time
        self.duration = duration
        self.at = at
    }

    /// Past 90 %: Plex counts it watched.
    public var finished: Bool { duration > 0 && time / duration >= 0.9 }
}

/// Keeps Continue Watching right while Plex catches up. Home re-reads Plex's rows a moment after
/// the player closes, and Plex can still answer with what was true before (the episode that just
/// finished, not the one after it) until it has processed the last reports. Recent stops are laid
/// over Plex's rows: a finished title leaves the row; one stopped part-way comes to the front at
/// its new resume point, replacing any other episode of the same show.
public enum ContinueWatching {
    /// How long a local stop outranks what Plex says.
    public static let window: TimeInterval = 120
    /// Shorter than this and Plex doesn't list it as in progress either.
    public static let minimumResume: TimeInterval = 30

    /// Plex rows that list what you're in the middle of.
    public static func isContinueHub(_ identifier: String) -> Bool {
        ["continue", "ondeck", "inprogress"].contains { identifier.lowercased().contains($0) }
    }

    /// Plex's items with the recent stops (oldest first) applied; `now` for tests.
    public static func applying(_ stops: [PlaybackStop], to items: [PlexMetadata], now: Date = Date()) -> [PlexMetadata] {
        var out = items
        for stop in stops.sorted(by: { $0.at < $1.at }) where now.timeIntervalSince(stop.at) <= window {
            let item = stop.item
            if stop.finished {
                out.removeAll { $0.ratingKey == item.ratingKey }
                continue
            }
            guard stop.time >= minimumResume else { continue }
            let show = item.kind == .episode ? item.grandparentRatingKey : nil
            out.removeAll { $0.ratingKey == item.ratingKey || (show != nil && $0.kind == .episode && $0.grandparentRatingKey == show) }
            out.insert(item.resumed(atMilliseconds: Int(stop.time * 1000)), at: 0)
        }
        return out
    }
}
