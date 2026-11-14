import Foundation
import MezzanineKit

/// Where downloads were left while Plex couldn't be reached, sent to the server once it's
/// back so resume points and watched marks (and Tautulli, Trakt, Playbill) catch up.
/// Nothing is ever sent while testing (`-MezzanineNoActivity`).
enum OfflineProgress {
    struct Entry: Codable, Equatable {
        var ratingKey: String
        var serverID: String
        var time: TimeInterval
        var duration: TimeInterval
        var at: Date
    }

    private static let key = "offlineProgress.v1"

    static var pending: [Entry] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    /// Keeps the latest position per title.
    static func record(ratingKey: String, serverID: String, time: TimeInterval, duration: TimeInterval) {
        guard duration > 0, time > 0 else { return }
        var list = pending.filter { $0.ratingKey != ratingKey }
        list.append(Entry(ratingKey: ratingKey, serverID: serverID, time: time, duration: duration, at: Date()))
        save(list)
    }

    /// Sends what this server is owed: watched past 90 % becomes a scrobble, else a stopped timeline.
    static func replay(client: PlexServerClient, serverID: String) async {
        guard !ActivityReporter.isDisabled else { return }
        var remaining: [Entry] = []
        for entry in pending {
            guard entry.serverID == serverID else { remaining.append(entry); continue }
            do {
                if entry.time / entry.duration >= 0.9 {
                    try await client.scrobble(ratingKey: entry.ratingKey)
                } else {
                    try await client.reportTimeline(ratingKey: entry.ratingKey, state: .stopped, time: entry.time,
                                                    duration: entry.duration, sessionID: UUID().uuidString)
                }
            } catch {
                remaining.append(entry)
            }
        }
        save(remaining)
    }

    private static func save(_ list: [Entry]) {
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: key) }
    }
}
