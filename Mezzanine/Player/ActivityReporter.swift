import Foundation
import MezzanineKit
import MezzaninePlayback

/// Tells the server what's playing: every 10 s while playing, and at once on
/// play, pause, seek-settle and stop. That keeps resume points, Continue
/// Watching, watched marks and Tautulli accurate.
///
/// `-MezzanineNoActivity YES` (tests, dev runs) turns every report off, so
/// nothing reaches watch history, Tautulli, Trakt or the owner's newsletters.
@MainActor
final class ActivityReporter {
    static var isDisabled: Bool { UserDefaults.standard.bool(forKey: "MezzanineNoActivity") }

    private let client: PlexServerClient
    private let item: PlexMetadata
    private let player: MezzaninePlayer
    private let sessionID = UUID().uuidString.lowercased()
    private var heartbeat: Task<Void, Never>?
    private var lastState: PlexServerClient.TimelineState?
    private(set) var lastReportedTime: TimeInterval = 0

    init(client: PlexServerClient, item: PlexMetadata, player: MezzaninePlayer) {
        self.client = client
        self.item = item
        self.player = player
    }

    func start() {
        guard !Self.isDisabled else { return }
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                await self?.report(force: true)
            }
        }
    }

    /// Called whenever the player's status changes.
    func statusChanged() {
        Task { await report(force: false) }
    }

    /// Final report; waits briefly so a quit still records the resume point.
    /// Pass the time explicitly when the player is about to be (or was) stopped.
    func stop(at time: TimeInterval? = nil, duration: TimeInterval? = nil) async {
        heartbeat?.cancel()
        let time = time ?? player.currentTime
        let duration = duration ?? player.duration
        guard !Self.isDisabled, duration > 0 else { return }
        _ = try? await withTimeout(.seconds(2)) { [client, item, sessionID] in
            try await client.reportTimeline(ratingKey: item.ratingKey, state: .stopped, time: time,
                                            duration: duration, sessionID: sessionID)
        }
        lastReportedTime = time
    }

    private func report(force: Bool) async {
        guard !Self.isDisabled, player.duration > 0 else { return }
        let state: PlexServerClient.TimelineState
        switch player.status {
        case .playing: state = player.isBuffering ? .buffering : .playing
        case .paused: state = .paused
        case .seeking, .loading: state = .buffering
        default: return
        }
        guard force || state != lastState else { return }
        lastState = state
        lastReportedTime = player.currentTime
        try? await client.reportTimeline(ratingKey: item.ratingKey, state: state, time: player.currentTime,
                                         duration: player.duration, sessionID: sessionID)
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
