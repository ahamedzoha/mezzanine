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
    /// What Plex last listed, and this Mac's changes still on their way, by Discover id.
    @ObservationIgnored private var listed: [PlexMetadata] = []
    @ObservationIgnored private var pending: [String: (item: PlexMetadata, on: Bool, token: Int)] = [:]
    @ObservationIgnored private var sending: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var token = 0
    private var account: Int { discover?.account ?? 0 }
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
        if changedAccount {
            listed = []
            pending = [:]
            set([], available: false)
        }
        guard let discover else { return }
        do {
            let list = try await discover.watchlist()
            let shown = await Self.onServer(list, index: index)
            // A newer request (another profile, a change) answers instead.
            guard generation == self.generation else { return }
            listed = shown
            show()
        } catch {
            guard generation == self.generation else { return }
            // A managed profile has none. Anything else keeps what was there.
            switch error as? PlexError {
            case .unauthorized, .forbidden: set([], available: false)
            default: break
            }
        }
    }

    /// Adds or removes at once, and puts it back if Plex refuses. Until Plex has answered, the
    /// change is laid over whatever it lists. Logged, not sent, with `-MezzanineNoActivity`.
    func set(_ item: PlexMetadata, _ on: Bool) {
        guard let id = item.discoverID, let discover, on != ids.contains(id) else { return }
        token += 1
        let token = token
        pending[id] = (item, on, token)
        show()
        AccessibilityNotification.Announcement(on ? "Added to Watchlist" : "Removed from Watchlist").post()
        if ActivityReporter.isDisabled {
            print("ACTION watchlist \(on ? "add" : "remove") \(item.ratingKey) not sent")
            return
        }
        // A title's changes go out in the order they were made.
        let previous = sending[id]
        sending[id] = Task { [weak self] in
            await previous?.value
            var refused: String?
            do { try await discover.setWatchlisted(id, on) } catch {
                refused = (error as? PlexError)?.userMessage ?? "Plex didn’t accept the change."
            }
            guard let self else { return }
            if refused == nil, self.account == discover.account { self.accept(item, id, on) }
            // A newer change to this title stands; this one is settled.
            if self.pending[id]?.token == token { self.pending[id] = nil }
            self.show()
            if let refused { self.onError?(refused) }
        }
    }

    /// Plex took the change: it's part of the list now.
    private func accept(_ item: PlexMetadata, _ id: String, _ on: Bool) {
        listed.removeAll { $0.discoverID == id }
        if on { listed.insert(item, at: 0) }
    }

    func toggle(_ item: PlexMetadata) { set(item, !contains(item)) }

    /// Plex's list with the changes it hasn't answered yet.
    private func show() {
        var list = listed.filter { item in item.discoverID.flatMap { pending[$0] }?.on != false }
        for change in pending.values.sorted(by: { $0.token > $1.token })
        where change.on && !list.contains(where: { $0.discoverID == change.item.discoverID }) { list.insert(change.item, at: 0) }
        set(list, available: true)
    }

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
