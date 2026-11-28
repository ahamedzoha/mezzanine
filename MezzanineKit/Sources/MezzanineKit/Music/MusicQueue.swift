import Foundation

public enum RepeatMode: String, Sendable, Codable, CaseIterable, Hashable {
    case off, all, one

    /// Off → all → one → off, the order the Repeat control cycles through.
    public var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }
}

/// Where the tracks after the manual queue come from.
public struct QueueContext: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Codable, Hashable {
        case album, playlist, artist, songs, radio, mix
    }

    public var kind: Kind
    /// The album, playlist or artist behind it, when there is one.
    public var ratingKey: String?
    public var title: String

    public init(kind: Kind, ratingKey: String? = nil, title: String) {
        self.kind = kind
        self.ratingKey = ratingKey
        self.title = title
    }
}

/// The local play queue, and the source of truth for what plays next (Plex play queues are
/// never used: nothing here talks to the server).
///
/// It has four parts, in the order they are used:
/// - `current`, the track playing now;
/// - `playingNext`, what the user queued by hand (Play Next goes to the front, Play Later to
///   the back);
/// - the context (album, playlist, station) with what is left of it, `remaining`;
/// - `history`, the last 200 tracks played, newest last.
///
/// Shuffle reorders only the rest of the context and keeps the original order, so turning it
/// off puts the remaining tracks back in album order. Everything is `Codable` for persistence.
/// Operations that need randomness take a generator so tests can seed it.
public struct MusicQueue: Sendable, Hashable, Codable {
    public static let historyLimit = 200
    static let currentVersion = 1

    public private(set) var version = MusicQueue.currentVersion
    public private(set) var current: QueuedTrack?
    public private(set) var playingNext: [QueuedTrack] = []
    public private(set) var context: QueueContext?
    /// The context in its own order, whole (for repeat all and for turning shuffle off).
    public private(set) var contextOrder: [QueuedTrack] = []
    /// What is left of the context, in the order it will play.
    public private(set) var remaining: [QueuedTrack] = []
    public private(set) var history: [QueuedTrack] = []
    public private(set) var isShuffled = false
    public var repeatMode: RepeatMode = .off
    /// When the queue runs dry with repeat off, ask for more similar music.
    public var continuesWithSimilar = true

    public init() {}

    // MARK: Reading

    public var isEmpty: Bool { current == nil && playingNext.isEmpty && remaining.isEmpty }

    /// Everything after the current track, in play order: the manual queue, then the context.
    public var upNext: [QueuedTrack] { playingNext + remaining }

    /// The track that `advance` would start, without moving anything. Repeat one answers the
    /// current track; repeat all with nothing left answers the context's first.
    public var peekNext: QueuedTrack? {
        if repeatMode == .one, let current { return current }
        if let first = playingNext.first { return first }
        if let first = remaining.first { return first }
        if repeatMode == .all { return contextOrder.first }
        return nil
    }

    /// The context's tracks that have not played yet are an album in its own order (what
    /// loudness `auto` keys on): no shuffle, no manual entries in front of the next track.
    public var isPlayingContextInOrder: Bool {
        guard let context, context.kind == .album || context.kind == .playlist, !isShuffled else { return false }
        return playingNext.isEmpty
    }

    /// The queue has played out and should be refilled (radio) when `continuesWithSimilar`.
    public var needsMoreSimilar: Bool {
        continuesWithSimilar && repeatMode == .off && current != nil && playingNext.isEmpty && remaining.isEmpty
    }

    // MARK: Starting

    /// Replaces the queue with a context and starts at `index` of `tracks`. With shuffle the
    /// chosen track plays first and the rest are mixed.
    public mutating func start(context: QueueContext, tracks: [QueuedTrack], at index: Int = 0, shuffled: Bool = false) {
        var generator = SystemRandomNumberGenerator()
        start(context: context, tracks: tracks, at: index, shuffled: shuffled, using: &generator)
    }

    public mutating func start<G: RandomNumberGenerator>(context: QueueContext, tracks: [QueuedTrack], at index: Int = 0,
                                                         shuffled: Bool, using generator: inout G) {
        guard tracks.indices.contains(index) else {
            clear()
            return
        }
        self.context = context
        contextOrder = tracks
        playingNext = []
        history = []
        isShuffled = shuffled
        current = tracks[index]
        let rest = Array(tracks[(index + 1)...])
        if shuffled {
            // Tracks before the chosen one still play (after the shuffled rest has been through
            // them): shuffle everything except the chosen track.
            var others = Array(tracks[..<index]) + rest
            others.shuffle(using: &generator)
            remaining = others
        } else {
            remaining = rest
        }
    }

    /// A shuffled start from the whole list (Shuffle button): any track may play first.
    public mutating func startShuffled(context: QueueContext, tracks: [QueuedTrack]) {
        var generator = SystemRandomNumberGenerator()
        startShuffled(context: context, tracks: tracks, using: &generator)
    }

    public mutating func startShuffled<G: RandomNumberGenerator>(context: QueueContext, tracks: [QueuedTrack], using generator: inout G) {
        guard !tracks.isEmpty else {
            clear()
            return
        }
        start(context: context, tracks: tracks, at: Int.random(in: 0..<tracks.count, using: &generator), shuffled: true, using: &generator)
    }

    public mutating func clear() {
        current = nil
        playingNext = []
        context = nil
        contextOrder = []
        remaining = []
        history = []
        isShuffled = false
    }

    // MARK: Manual queue

    /// Play Next: right after the current track, ahead of anything queued earlier.
    public mutating func playNext(_ tracks: [QueuedTrack]) {
        playingNext.insert(contentsOf: tracks.map(Self.fresh), at: 0)
        adoptIfEmpty()
    }

    /// Play Later: after everything queued by hand (the context follows it).
    public mutating func playLater(_ tracks: [QueuedTrack]) {
        playingNext.append(contentsOf: tracks.map(Self.fresh))
        adoptIfEmpty()
    }

    /// Adds tracks to the end of the context (radio refills, "keep playing similar").
    public mutating func append(contextTracks tracks: [QueuedTrack]) {
        let fresh = tracks.map(Self.fresh)
        contextOrder += fresh
        remaining += fresh
        adoptIfEmpty()
    }

    /// Removes an entry from the up-next lists (not the playing one).
    @discardableResult
    public mutating func remove(id: UUID) -> Bool {
        if let i = playingNext.firstIndex(where: { $0.id == id }) {
            playingNext.remove(at: i)
            return true
        }
        if let i = remaining.firstIndex(where: { $0.id == id }) {
            remaining.remove(at: i)
            contextOrder.removeAll { $0.id == id }
            return true
        }
        return false
    }

    /// Moves a manual entry to a place in the manual list (drag in Up Next).
    public mutating func movePlayingNext(from source: Int, to destination: Int) {
        guard playingNext.indices.contains(source) else { return }
        let item = playingNext.remove(at: source)
        playingNext.insert(item, at: min(max(0, destination), playingNext.count))
    }

    /// Moves an entry of the context's remainder.
    public mutating func moveRemaining(from source: Int, to destination: Int) {
        guard remaining.indices.contains(source) else { return }
        let item = remaining.remove(at: source)
        remaining.insert(item, at: min(max(0, destination), remaining.count))
    }

    /// Jumps to an entry of the up-next lists; what was skipped over stays in `history`.
    public mutating func skip(to id: UUID) -> QueuedTrack? {
        if let i = playingNext.firstIndex(where: { $0.id == id }) {
            let skipped = Array(playingNext[..<i])
            let target = playingNext[i]
            playingNext.removeSubrange(...i)
            retire(current)
            for track in skipped { retire(track) }
            current = target
            return target
        }
        if let i = remaining.firstIndex(where: { $0.id == id }) {
            let skipped = Array(remaining[..<i])
            let target = remaining[i]
            remaining.removeSubrange(...i)
            retire(current)
            for track in skipped { retire(track) }
            current = target
            return target
        }
        return nil
    }

    // MARK: Moving

    /// The track ended (or Next was pressed): moves on and returns what plays now. `userInitiated`
    /// makes Next leave a repeated single track (repeat one only repeats on its own).
    /// Returns nil when the queue has played out (`current` becomes nil with repeat off).
    @discardableResult
    public mutating func advance(userInitiated: Bool = false) -> QueuedTrack? {
        if repeatMode == .one, !userInitiated, let current {
            return current
        }
        retire(current)
        if !playingNext.isEmpty {
            current = playingNext.removeFirst()
        } else if !remaining.isEmpty {
            current = remaining.removeFirst()
        } else if repeatMode != .off, !contextOrder.isEmpty {
            // Repeat all (or Next while repeating one) starts the context again.
            var generator = SystemRandomNumberGenerator()
            restartContext(using: &generator)
        } else {
            current = nil
        }
        return current
    }

    /// Previous: the track played before, which goes back in front of the current one. Nil when
    /// there is no history (the caller restarts the current track instead).
    @discardableResult
    public mutating func goBack() -> QueuedTrack? {
        guard let previous = history.popLast() else { return nil }
        if let current {
            // The track we left plays again after the one we return to.
            if contextOrder.contains(where: { $0.id == current.id }) { remaining.insert(current, at: 0) }
            else { playingNext.insert(current, at: 0) }
        }
        current = previous
        return previous
    }

    // MARK: Shuffle

    public mutating func setShuffled(_ on: Bool) {
        var generator = SystemRandomNumberGenerator()
        setShuffled(on, using: &generator)
    }

    public mutating func setShuffled<G: RandomNumberGenerator>(_ on: Bool, using generator: inout G) {
        guard on != isShuffled else { return }
        isShuffled = on
        if on {
            remaining.shuffle(using: &generator)
        } else {
            // Original order, limited to what has not played.
            let left = Set(remaining.map(\.id))
            remaining = contextOrder.filter { left.contains($0.id) }
        }
    }

    // MARK: Private

    private mutating func restartContext<G: RandomNumberGenerator>(using generator: inout G) {
        // New identities: the same tracks come round again.
        contextOrder = contextOrder.map(Self.fresh)
        var order = contextOrder
        if isShuffled { order.shuffle(using: &generator) }
        guard !order.isEmpty else {
            current = nil
            return
        }
        current = order.removeFirst()
        remaining = order
    }

    private mutating func retire(_ track: QueuedTrack?) {
        guard let track else { return }
        history.append(track)
        if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
    }

    /// Queueing onto an empty queue makes the first entry current (nothing plays by itself:
    /// the caller starts it).
    private mutating func adoptIfEmpty() {
        guard current == nil else { return }
        if !playingNext.isEmpty { current = playingNext.removeFirst() }
        else if !remaining.isEmpty { current = remaining.removeFirst() }
    }

    private static func fresh(_ track: QueuedTrack) -> QueuedTrack {
        var copy = track
        copy.id = UUID()
        return copy
    }
}
