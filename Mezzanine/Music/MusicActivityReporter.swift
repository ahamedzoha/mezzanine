import Foundation
import MezzanineKit
import MezzaninePlayback

/// Reports music playback timelines (`type=track`) and ratings to Plex,
/// respecting `-MezzanineNoActivity YES` (prints `ACTION …` and sends nothing).
@MainActor
final class MusicActivityReporter {
    private let client: PlexServerClient
    private let track: QueuedTrack
    private let sessionID = UUID().uuidString.lowercased()
    private var heartbeat: Task<Void, Never>?
    private var lastState: PlexServerClient.TimelineState?

    init(client: PlexServerClient, track: QueuedTrack) {
        self.client = client
        self.track = track
    }

    func start(time: TimeInterval, isPlaying: Bool) {
        if ActivityReporter.isDisabled {
            print("ACTION music timeline \(track.ratingKey) start state=\(isPlaying ? "playing" : "paused") time=\(Int(time))/\(Int(track.duration))")
            return
        }
        Task { await report(state: isPlaying ? .playing : .paused, time: time, force: true) }
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                await self?.tick()
            }
        }
    }

    var currentPositionProvider: (@MainActor () -> (time: TimeInterval, status: MusicStatus))?

    private func tick() async {
        guard let (time, status) = currentPositionProvider?() else { return }
        let state: PlexServerClient.TimelineState
        switch status {
        case .playing: state = .playing
        case .paused: state = .paused
        case .loading: state = .buffering
        default: return
        }
        await report(state: state, time: time, force: true)
    }

    func statusChanged(to status: MusicStatus, time: TimeInterval) {
        let state: PlexServerClient.TimelineState
        switch status {
        case .playing: state = .playing
        case .paused: state = .paused
        case .loading: state = .buffering
        default: return
        }
        Task { await report(state: state, time: time, force: false) }
    }

    func stop(at time: TimeInterval) async {
        heartbeat?.cancel()
        heartbeat = nil
        if ActivityReporter.isDisabled {
            print("ACTION music timeline \(track.ratingKey) stopped time=\(Int(time))/\(Int(track.duration))")
            return
        }
        guard track.duration > 0 else { return }
        _ = try? await withTimeout(.seconds(2)) { [client, track, sessionID] in
            try await client.reportTimeline(
                ratingKey: track.ratingKey,
                state: .stopped,
                time: time,
                duration: track.duration,
                sessionID: sessionID,
                type: "track"
            )
        }
    }

    static func rate(ratingKey: String, stars: Int, client: PlexServerClient) async {
        let clampedStars = min(5, max(0, stars))
        let plexRating = clampedStars == 0 ? -1 : clampedStars * 2
        if ActivityReporter.isDisabled {
            print("ACTION rate \(ratingKey) stars=\(clampedStars) plex=\(plexRating)")
            return
        }
        try? await client.rate(ratingKey: ratingKey, rating: plexRating)
    }

    private func report(state: PlexServerClient.TimelineState, time: TimeInterval, force: Bool) async {
        guard !ActivityReporter.isDisabled, track.duration > 0 else { return }
        guard force || state != lastState else { return }
        lastState = state
        try? await client.reportTimeline(
            ratingKey: track.ratingKey,
            state: state,
            time: time,
            duration: track.duration,
            sessionID: sessionID,
            type: "track"
        )
    }

    private func withTimeout<T: Sendable>(_ limit: Duration, _ work: @escaping @Sendable () async throws -> T) async throws -> T? {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await work() }
            group.addTask { try await Task.sleep(for: limit); return nil }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
