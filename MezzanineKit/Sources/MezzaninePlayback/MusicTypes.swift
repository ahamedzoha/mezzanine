import Foundation
import MezzanineKit

/// What the music engine is doing, in Mezzanine's own terms.
public enum MusicStatus: Equatable, Sendable {
    case idle, loading, playing, paused
    /// The last track finished and nothing followed.
    case ended
    case failed(String)

    public var isActive: Bool {
        switch self {
        case .loading, .playing, .paused: return true
        default: return false
        }
    }
}

/// One track to play: the queue entry, the deck that should play it and where its bytes are.
public struct MusicTrackRequest: Sendable {
    public var track: QueuedTrack
    public var route: MusicRoute
    /// A complete local file (from `TrackCache`) for the native deck.
    public var fileURL: URL?
    /// The server URL for the engine deck (and the fallback when the native deck refuses the file).
    public var streamURL: URL?
    /// Plex headers with the token; the token never sits in a URL.
    public var headers: [String: String]
    /// Leveling gain in dB, from `LoudnessPlan`.
    public var gainDB: Double

    public init(track: QueuedTrack, route: MusicRoute, fileURL: URL? = nil, streamURL: URL? = nil,
                headers: [String: String] = [:], gainDB: Double = 0) {
        self.track = track
        self.route = route
        self.fileURL = fileURL
        self.streamURL = streamURL
        self.headers = headers
        self.gainDB = gainDB
    }

    var gainLinear: Float { Float(pow(10, gainDB / 20)) }
}

/// What the engine tells its owner (the music session).
public enum MusicEvent: Sendable {
    /// A track began (the first, or the follower after a join).
    case trackStarted(QueuedTrack, route: MusicRoute)
    /// A track played to its end.
    case trackEnded(QueuedTrack)
    /// Nothing is scheduled after the current track: call `enqueueNext` (or let the queue end).
    case needsNext
    /// The queue is exhausted: the last track ended and no follower was set.
    case finished
    case failed(QueuedTrack, String)
}

public enum MusicEngineError: Error, Sendable, Equatable {
    case noSource
    case cannotOpen(String)
}
