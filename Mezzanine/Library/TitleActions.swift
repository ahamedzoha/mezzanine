import SwiftUI
import MezzanineKit

/// What you can do to a title from anywhere it appears: mark it watched, take it out of Continue
/// Watching, start it over, go to its show. Cards, episode rows, title pages and the Item menu
/// all act through here, so a change is asked for, shown and undone the same way everywhere.
///
/// These write to the Plex server. With `-MezzanineNoActivity` they're logged and not sent.
@MainActor
@Observable
final class TitleActions {
    /// A watched mark on its way: pages show it at once, then read the server's copy.
    struct Mark: Equatable {
        enum Phase { case applied, confirmed, failed }
        let item: PlexMetadata
        let watched: Bool
        let phase: Phase
    }

    private(set) var mark: Mark?
    /// A show or season waiting for "Mark all as watched?" (they change many episodes).
    var confirmation: (item: PlexMetadata, watched: Bool)?
    var error: String?

    @ObservationIgnored private(set) weak var pins: PinnedStore?
    @ObservationIgnored private(set) weak var watchlist: WatchlistStore?
    @ObservationIgnored private weak var session: SessionStore?
    @ObservationIgnored private weak var library: LibraryStore?
    @ObservationIgnored private weak var playback: PlaybackCoordinator?
    @ObservationIgnored private weak var commands: AppCommandCenter?

    func start(session: SessionStore, library: LibraryStore, playback: PlaybackCoordinator, commands: AppCommandCenter,
               pins: PinnedStore, watchlist: WatchlistStore) {
        self.pins = pins
        self.watchlist = watchlist
        watchlist.onError = { [weak self] in self?.error = $0 }
        self.session = session
        self.library = library
        self.playback = playback
        self.commands = commands
    }

    // MARK: What applies

    static func canMark(_ item: PlexMetadata) -> Bool {
        [.movie, .show, .season, .episode].contains(item.kind) && !item.isDiscoverOnly
    }

    /// Started and not finished: a film or episode with a resume point, a show or season with
    /// some of its episodes watched. Both marks apply.
    static func isPartlyWatched(_ item: PlexMetadata) -> Bool {
        switch item.kind {
        case .show, .season: (item.viewedLeafCount ?? 0) > 0 && !item.isWatched
        default: item.progress != nil
        }
    }

    /// The show an episode or season belongs to.
    static func showKey(_ item: PlexMetadata) -> String? {
        switch item.kind {
        case .episode: item.grandparentRatingKey
        case .season: item.parentRatingKey
        default: nil
        }
    }

    // MARK: Watched

    /// Marks a film or episode at once; asks first for a show or season.
    func requestWatched(_ item: PlexMetadata, _ watched: Bool) {
        guard Self.canMark(item), session?.client != nil else { return }
        if item.kind == .show || item.kind == .season { confirmation = (item, watched) }
        else { Task { await setWatched(item, watched) } }
    }

    func toggleWatched(_ item: PlexMetadata) { requestWatched(item, !item.isWatched) }

    func setWatched(_ item: PlexMetadata, _ watched: Bool) async {
        guard let client = session?.client else { return }
        mark = Mark(item: item, watched: watched, phase: .applied)
        AccessibilityNotification.Announcement(watched ? "Marked as watched" : "Marked as unwatched").post()
        if ActivityReporter.isDisabled {
            print("ACTION \(watched ? "watched" : "unwatched") \(item.ratingKey) not sent")
            return
        }
        do {
            if watched { try await client.scrobble(ratingKey: item.ratingKey) }
            else { try await client.unscrobble(ratingKey: item.ratingKey) }
            mark = Mark(item: item, watched: watched, phase: .confirmed)
            // Home, the grids and smart shelves follow the index.
            await library?.refresh(item)
        } catch {
            mark = Mark(item: item, watched: watched, phase: .failed)
            self.error = (error as? PlexError)?.userMessage ?? "The server didn’t accept the change."
        }
    }

    // MARK: Continue Watching

    /// The title leaves the row at once, and comes back if the server refuses.
    func removeFromContinue(_ item: PlexMetadata) {
        guard let client = session?.client, let library else { return }
        library.setRemovedFromContinue(item.ratingKey, true)
        AccessibilityNotification.Announcement("Removed from Continue Watching").post()
        if ActivityReporter.isDisabled {
            print("ACTION removeFromContinue \(item.ratingKey) not sent")
            return
        }
        Task {
            do { try await client.removeFromContinueWatching(ratingKey: item.ratingKey) } catch {
                library.setRemovedFromContinue(item.ratingKey, false)
                self.error = (error as? PlexError)?.userMessage ?? "The server didn’t accept the change."
            }
        }
    }

    // MARK: Going and playing

    func goToShow(_ item: PlexMetadata) {
        guard let key = Self.showKey(item) else { return }
        commands?.open(ratingKey: key)
    }

    func play(_ item: PlexMetadata, from frame: CGRect? = nil) {
        Task { await playback?.play(item, from: frame) }
    }

    func playFromStart(_ item: PlexMetadata, from frame: CGRect? = nil) {
        Task { await playback?.play(item, from: frame, startAt: 0) }
    }

    // MARK: Queue

    static func canQueue(_ item: PlexMetadata) -> Bool {
        [.movie, .episode, .show].contains(item.kind) && !item.isDiscoverOnly
    }

    static func canShuffle(_ item: PlexMetadata) -> Bool {
        [.show, .season, .collection].contains(item.kind) && !item.isDiscoverOnly
    }

    func playNext(_ item: PlexMetadata) {
        playback?.queue.change { $0.playNext([QueueStore.entry(item)]) }
        AccessibilityNotification.Announcement("\(Format.displayTitle(item)) plays next").post()
    }

    func addToQueue(_ item: PlexMetadata) {
        playback?.queue.change { $0.add([QueueStore.entry(item)]) }
        AccessibilityNotification.Announcement("Added to queue").post()
    }

    /// Plays a show, season or collection in random order.
    func shuffle(_ item: PlexMetadata, unwatchedOnly: Bool) {
        guard let client = session?.client else { return }
        shuffle(unwatchedOnly: unwatchedOnly) {
            switch item.kind {
            case .show: try await client.allLeaves(item.ratingKey)
            case .season: try await client.children(item.ratingKey)
            case .collection: try await client.collectionItems(item.ratingKey)
            default: []
            }
        }
    }

    /// The same for any page's titles. What was queued makes way.
    func shuffle(unwatchedOnly: Bool, titles: @escaping () async throws -> [PlexMetadata]) {
        Task {
            do {
                var generator = SystemRandomNumberGenerator()
                let order = PlayQueue.shuffled(try await titles(), unwatchedOnly: unwatchedOnly, using: &generator)
                guard let first = order.first, let playback else {
                    AccessibilityNotification.Announcement("Nothing to shuffle").post()
                    return
                }
                playback.queue.change { $0.replace(with: order.dropFirst().map(QueueStore.entry)) }
                await playback.play(first, from: nil, startAt: 0)
            } catch {
                self.error = (error as? PlexError)?.userMessage ?? "The server didn’t answer."
            }
        }
    }

    /// W and ⇧W on a focused title: watched, and the watchlist.
    func key(_ press: KeyPress, on item: PlexMetadata?) -> KeyPress.Result {
        guard let item else { return .ignored }
        if press.modifiers.contains(.shift) {
            guard let watchlist, watchlist.offers(item) else { return .ignored }
            watchlist.toggle(item)
            return .handled
        }
        guard Self.canMark(item) else { return .ignored }
        toggleWatched(item)
        return .handled
    }

    // MARK: Words

    var confirmationTitle: String {
        guard let (item, watched) = confirmation else { return "" }
        let what = item.leafCount.map { $0 == 1 ? "the only episode of \(item.title)" : "all \($0) episodes of \(item.title)" }
            ?? "every episode of \(item.title)"
        return watched ? "Mark \(what) as watched?" : "Mark \(what) as unwatched?"
    }

    var confirmationButton: String { confirmation?.watched == true ? "Mark as Watched" : "Mark as Unwatched" }
}

/// A title's actions as menu items, for context menus and the Item menu. Takes its stores
/// directly: the menu bar's commands have no environment objects.
struct TitleMenuItems: View {
    let item: PlexMetadata
    let actions: TitleActions
    let library: LibraryStore
    let commands: AppCommandCenter
    /// Where the title is on screen, for the player to grow from.
    var frame: CGRect? = nil
    /// Off on the title's own page.
    var offersOpen = true
    /// Runs instead of playing directly (a page with its own idea of Play).
    var play: (() -> Void)? = nil

    var body: some View {
        if item.kind != .collection && !item.isDiscoverOnly {
            Button(item.progress != nil ? "Resume" : "Play") {
                if let play { play() } else { actions.play(item, from: frame) }
            }
        }
        if item.progress != nil {
            Button("Play from Start") { actions.playFromStart(item, from: frame) }
        }
        if TitleActions.showKey(item) != nil {
            Button("Go to Show") { actions.goToShow(item) }
        } else if offersOpen && !item.isDiscoverOnly {
            Button("Open") { commands.open(item) }
        }
        if TitleActions.canQueue(item) {
            Divider()
            Button("Play Next") { actions.playNext(item) }
            Button("Add to Queue") { actions.addToQueue(item) }
        }
        if TitleActions.canShuffle(item) {
            Divider()
            Button("Shuffle") { actions.shuffle(item, unwatchedOnly: false) }
            Button("Shuffle Unwatched") { actions.shuffle(item, unwatchedOnly: true) }
        }
        if let watchlist = actions.watchlist, watchlist.offers(item) {
            Divider()
            Button(watchlist.contains(item) ? "Remove from Watchlist" : "Add to Watchlist") { watchlist.toggle(item) }
        }
        if item.kind == .collection, let pins = actions.pins, let section = item.librarySectionID {
            let pin = PinnedStore.spec(for: item, section: String(section))
            Button(pins.contains(pin.id) ? "Unpin from Sidebar" : "Pin to Sidebar") { pins.toggle(pin) }
        }
        if TitleActions.canMark(item) {
            Divider()
            if !item.isWatched { Button("Mark as Watched\(Self.ellipsis(item))") { actions.requestWatched(item, true) } }
            if item.isWatched || TitleActions.isPartlyWatched(item) {
                Button("Mark as Unwatched\(Self.ellipsis(item))") { actions.requestWatched(item, false) }
            }
            if library.isInContinue(item.ratingKey) {
                Button("Remove from Continue Watching") { actions.removeFromContinue(item) }
            }
        }
        if [.movie, .show, .season].contains(item.kind), !item.isDiscoverOnly {
            Divider()
            Button("Choose Poster…") { commands.artworkRequest = ArtworkRequest(item: item, kind: .poster) }
            Button("Choose Background…") { commands.artworkRequest = ArtworkRequest(item: item, kind: .background) }
        }
    }

    /// A show or season asks first.
    private static func ellipsis(_ item: PlexMetadata) -> String {
        item.kind == .show || item.kind == .season ? "…" : ""
    }
}
