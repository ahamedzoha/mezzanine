import SwiftUI
import MezzanineKit

/// The titles waiting to play (Play Next, Add to Queue, Shuffle), kept per server and profile on
/// this Mac. `PlaybackCoordinator` plays its head before the next episode.
@MainActor
@Observable
final class QueueStore {
    private(set) var queue = PlayQueue()
    @ObservationIgnored private var storageKey: String?
    /// The coordinator looks the new head up.
    @ObservationIgnored var onChange: (() -> Void)?

    func use(serverID: String, userID: String) {
        let key = "playQueue.v1.\(serverID).\(userID)"
        guard key != storageKey else { return }
        storageKey = key
        queue = UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(PlayQueue.self, from: $0) } ?? PlayQueue()
        onChange?()
    }

    func change(_ body: (inout PlayQueue) -> Void) {
        var next = queue
        body(&next)
        guard next != queue else { return }
        queue = next
        if let storageKey, let data = try? JSONEncoder().encode(next) { UserDefaults.standard.set(data, forKey: storageKey) }
        onChange?()
    }

    /// "3 queued"; nil when empty.
    var summary: String? { queue.isEmpty ? nil : "\(queue.entries.count) queued" }

    static func entry(_ item: PlexMetadata) -> PlayQueue.Entry {
        switch item.kind {
        case .episode:
            PlayQueue.Entry(ratingKey: item.ratingKey, title: item.grandparentTitle ?? item.title,
                            detail: [Format.episodeCode(item), item.grandparentTitle == nil ? nil : item.title].compactMap { $0 }.joined(separator: " · "))
        case .show:
            PlayQueue.Entry(ratingKey: item.ratingKey, title: item.title, detail: "Next unwatched episode")
        default:
            PlayQueue.Entry(ratingKey: item.ratingKey, title: Format.displayTitle(item), detail: item.year.map(String.init) ?? "")
        }
    }
}
