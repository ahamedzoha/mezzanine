import SwiftUI
import UserNotifications
import MezzanineKit

/// "New episode of Severance": after each library sync, shows the profile is watching (an
/// episode seen in the past year) that gained unwatched episodes since the last check get one
/// notification each, with the poster (more than six at once: five and a summary). Clicking
/// one opens the show's page, once the library is ready and the film (if one is playing) is
/// closed. Settings ▸ Playback turns it off. Runs while Mezzanine is open (the sync runs every
/// ten minutes). While a film owns the window they go quietly to Notification Centre.
@MainActor @Observable
final class NewEpisodeNotifier: NSObject, UNUserNotificationCenterDelegate {
    var enabled = UserDefaults.standard.object(forKey: "notifyNewEpisodes") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "notifyNewEpisodes")
            if enabled { Task { await requestIfNeeded() } }
        }
    }
    private(set) var authorization: UNAuthorizationStatus = .notDetermined

    @ObservationIgnored private weak var library: LibraryStore?
    @ObservationIgnored private weak var session: SessionStore?
    @ObservationIgnored private weak var commands: AppCommandCenter?
    @ObservationIgnored private var started = false
    /// A clicked notification waiting for the index, or for the film to close.
    @ObservationIgnored private var pendingShow: String?

    static let maxSingles = 6

    override init() {
        super.init()
        // Before the app finishes launching, so a click that launched it still arrives here.
        UNUserNotificationCenter.current().delegate = self
    }

    func start(library: LibraryStore, session: SessionStore, commands: AppCommandCenter) {
        guard !started else { return }
        started = true
        self.library = library
        self.session = session
        self.commands = commands
        library.onSynced = { [weak self] in Task { await self?.check() } }
        Task {
            await refreshStatus()
            await requestIfNeeded()
        }
    }

    func refreshStatus() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Asks once (the owner agreed to the prompt); never again after an answer. Banners only:
    /// a new episode isn't worth a sound.
    func requestIfNeeded() async {
        guard enabled, authorization == .notDetermined else { return }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
        await refreshStatus()
    }

    // MARK: Checking

    func check() async {
        guard enabled, let library, let index = library.index, let key = library.indexKey else { return }
        await refreshStatus()
        let defaultsKey = "newEpisodesCheckedAt.\(key)"
        let last = UserDefaults.standard.double(forKey: defaultsKey)
        let now = Date().timeIntervalSince1970
        // The first check for a profile only sets the mark: no flood of old arrivals. While the
        // permission prompt is unanswered the mark stays put, so nothing found meanwhile is lost;
        // once refused, it moves on (turning them on later doesn't replay months of episodes).
        if last > 0, authorization == .notDetermined { return }
        UserDefaults.standard.set(now, forKey: defaultsKey)
        guard last > 0, authorization == .authorized || authorization == .provisional else { return }
        let found = await Task.detached(priority: .utility) { (try? index.newEpisodes(since: last)) ?? [] }.value
        guard enabled, library.indexKey == key else { return }
        let singles = found.count > Self.maxSingles ? Self.maxSingles - 1 : found.count
        for (show, episodes) in found.prefix(singles) { await post(show: show, episodes: episodes) }
        let rest = found.dropFirst(singles).map(\.0)
        if !rest.isEmpty { await postSummary(rest) }
    }

    /// The overflow: "New episodes of 4 more shows", naming them.
    private func postSummary(_ shows: [IndexedItem]) async {
        let content = UNMutableNotificationContent()
        content.title = "New episodes of \(shows.count) more shows"
        content.body = ListFormatter.localizedString(byJoining: shows.map(\.title))
        content.threadIdentifier = "new-episodes"
        let stamp = Int(Date().timeIntervalSince1970)
        let request = UNNotificationRequest(identifier: "new-more-\(stamp)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    private func post(show: IndexedItem, episodes: [IndexedItem]) async {
        guard let first = episodes.first, let last = episodes.last else { return }
        let content = UNMutableNotificationContent()
        content.title = episodes.count == 1 ? "New episode of \(show.title)" : "\(episodes.count) new episodes of \(show.title)"
        content.body = episodes.count == 1 ? Self.line(first) : Self.range(first, last)
        content.threadIdentifier = show.ratingKey
        content.userInfo = ["show": show.ratingKey]
        if let attachment = await posterAttachment(show) { content.attachments = [attachment] }
        let request = UNNotificationRequest(identifier: "new-\(show.ratingKey)-\(last.ratingKey)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    static func line(_ e: IndexedItem) -> String {
        let code = [e.parentIndex.map { "S\($0)" }, e.index.map { "E\($0)" }].compactMap { $0 }.joined(separator: " ")
        return [code.isEmpty ? nil : code, e.title].compactMap { $0 }.joined(separator: " · ")
    }

    static func range(_ a: IndexedItem, _ b: IndexedItem) -> String {
        if a.parentIndex == b.parentIndex, let s = a.parentIndex, let x = a.index, let y = b.index { return "S\(s) E\(x)–E\(y)" }
        return "\(line(a)) to \(line(b))"
    }

    /// The show's poster as a file (notifications take attachments by URL).
    private func posterAttachment(_ show: IndexedItem) async -> UNNotificationAttachment? {
        guard let session, let library, let meta = show.metadata(),
              let url = session.posterURL(library.posterPath(for: meta), pixelWidth: 300),
              let image = try? await session.images.image(for: url, pixelSize: 300) else { return nil }
        let file = FileManager.default.temporaryDirectory.appending(path: "poster-\(show.ratingKey).png")
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
              (try? data.write(to: file)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: "poster", url: file)
    }

    // MARK: Delegate

    /// In front: a banner, unless a film owns the window (then straight to Notification Centre).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        let watching = await MainActor.run { commands?.isPlayerOpen ?? false }
        return watching ? [.list] : [.banner, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let key = response.notification.request.content.userInfo["show"] as? String
        await MainActor.run {
            NSApp.activate()
            guard let key else { return }
            pendingShow = key
            openPending()
        }
    }

    /// Opens a clicked show once it can: the index is open and no film owns the window.
    /// AppShell calls this again when either changes.
    func openPending() {
        guard let key = pendingShow, let library, let commands, let index = library.index,
              !commands.isPlayerOpen else { return }
        pendingShow = nil
        guard let meta = try? index.item(key)?.metadata() else { return }
        commands.open(meta)
    }

    #if DEBUG
    /// -NotifyTest YES: posts one for the first show being watched, with its newest episode.
    func postTest() async {
        // Wait (up to a minute) for an answer to the permission prompt.
        for _ in 0..<60 where authorization == .notDetermined {
            try? await Task.sleep(for: .seconds(1))
            await refreshStatus()
        }
        guard let index = library?.index else { return }
        let found = (try? index.newEpisodes(since: 0)) ?? []
        if let (show, episodes) = found.first, let newest = episodes.last {
            await post(show: show, episodes: [newest])
            print("NOTIFY posted \(show.title) · \(Self.line(newest)) auth=\(authorization.rawValue)")
        } else {
            print("NOTIFY nothing to post")
        }
    }
    #endif
}
