import SwiftUI
import MezzanineKit

/// The Plex account's watchlist. A title that's on this server is shown as the server's own (it
/// plays); the rest are shown as "Not on this server". Managed Home profiles have no watchlist:
/// everything about it hides.
@MainActor
@Observable
final class WatchlistStore {
    private(set) var items: [PlexMetadata] = []
    private(set) var isAvailable = false
    /// Bumped on every change, so pages and shelves reload.
    private(set) var revision = 0
    private var ids: Set<String> = []
    @ObservationIgnored private var discover: PlexDiscover?
    @ObservationIgnored private var index: LibraryIndex?
    @ObservationIgnored private var generation = 0
    /// Told when Plex refuses a change.
    @ObservationIgnored var onError: ((String) -> Void)?

    func contains(_ item: PlexMetadata) -> Bool { item.discoverID.map(ids.contains) ?? false }

    /// The title can be put on the watchlist (a film or show Plex knows).
    func offers(_ item: PlexMetadata) -> Bool { isAvailable && item.discoverID != nil }

    /// Reads the list again: after connecting, and after each sync (a title may have arrived).
    func load(discover: PlexDiscover?, index: LibraryIndex?, changedAccount: Bool) async {
        generation += 1
        let generation = generation
        self.discover = discover
        self.index = index
        if changedAccount { set([], available: false) }
        guard let discover else { return }
        do {
            let list = try await discover.watchlist()
            let shown = await Self.onServer(list, index: index)
            // A newer request (another profile, a change) answers instead.
            guard generation == self.generation else { return }
            set(shown, available: true)
        } catch {
            guard generation == self.generation else { return }
            // A managed profile has none. Anything else keeps what was there.
            if let plex = error as? PlexError, case .unauthorized = plex { set([], available: false) }
        }
    }

    /// Adds or removes at once, and puts it back if Plex refuses. Logged, not sent, with
    /// `-MezzanineNoActivity`.
    func set(_ item: PlexMetadata, _ on: Bool) {
        guard let id = item.discoverID, let discover, on != ids.contains(id) else { return }
        let before = items
        generation += 1
        set(on ? [item] + items : items.filter { $0.discoverID != id }, available: true)
        AccessibilityNotification.Announcement(on ? "Added to Watchlist" : "Removed from Watchlist").post()
        if ActivityReporter.isDisabled {
            print("ACTION watchlist \(on ? "add" : "remove") \(item.ratingKey) not sent")
            return
        }
        let generation = generation
        Task {
            do { try await discover.setWatchlisted(id, on) } catch {
                if generation == self.generation { set(before, available: true) }
                onError?((error as? PlexError)?.userMessage ?? "Plex didn’t accept the change.")
            }
        }
    }

    func toggle(_ item: PlexMetadata) { set(item, !contains(item)) }

    private func set(_ list: [PlexMetadata], available: Bool) {
        let new = Set(list.compactMap(\.discoverID))
        guard list != items || available != isAvailable else { return }
        items = list
        ids = new
        isAvailable = available
        revision += 1
    }

    private nonisolated static func onServer(_ list: [PlexMetadata], index: LibraryIndex?) async -> [PlexMetadata] {
        guard let index else { return list }
        return await Task.detached(priority: .utility) {
            let local = ((try? index.items(guids: list.compactMap(\.guid))) ?? []).compactMap { $0.metadata() }
            let byGuid = Dictionary(local.compactMap { item in item.guid.map { ($0, item) } }, uniquingKeysWith: { a, _ in a })
            return list.map { $0.guid.flatMap { byGuid[$0] } ?? $0 }
        }.value
    }
}

/// The watchlist as a page.
struct WatchlistPage: View {
    var contentFocus: FocusState<Bool>.Binding
    @Environment(WatchlistStore.self) private var watchlist

    var body: some View {
        TitlesPage(title: "Watchlist", reloadKey: "watchlist|\(watchlist.revision)", filterable: true, contentFocus: contentFocus) {
            watchlist.items
        }
    }
}
