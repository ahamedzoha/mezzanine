import AppKit
import CoreSpotlight
import CryptoKit
import MezzanineKit

/// The libraries' films and shows in macOS Spotlight. One server and profile at a time: switching
/// or signing out takes the others away. Written only when a title was added, removed or renamed.
@MainActor
@Observable
final class SpotlightIndex {
    var enabled = UserDefaults.standard.object(forKey: "spotlight") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "spotlight")
            if !enabled { clear() }
        }
    }

    @ObservationIgnored private var generation = 0
    /// Writes and deletes run one after another, so an older write can't land after a delete.
    @ObservationIgnored private var chain: Task<Void, Never>?
    private static let digestKey = "spotlight.digest"
    private static let ownerKey = "spotlight.owner"

    /// Debug builds would put every title in Spotlight twice: only with -SpotlightIndex YES.
    private var isAllowed: Bool {
        #if DEBUG
        enabled && UserDefaults.standard.bool(forKey: "SpotlightIndex")
        #else
        enabled
        #endif
    }

    /// `key` is the server and profile; `sections` the libraries to list.
    func update(index: LibraryIndex?, key: String?, sections: [String]) {
        guard isAllowed, CSSearchableIndex.isIndexingAvailable(), let index, let key else { return }
        // Another server or profile: its titles go before anything else, even if this one has none.
        if UserDefaults.standard.string(forKey: Self.ownerKey) != key { forget(owner: key) }
        guard !sections.isEmpty else { return }
        generation += 1
        let generation = generation
        enqueue { [weak self] in
            guard let self, generation == self.generation else { return }
            do {
                let known = UserDefaults.standard.string(forKey: Self.digestKey)
                guard let written = try await Self.write(index: index, key: key, sections: sections, known: known) else { return }
                guard generation == self.generation else { return }
                UserDefaults.standard.set(written.digest, forKey: Self.digestKey)
                AppLog.library.info("spotlight: \(written.count) titles")
                #if DEBUG
                print("SPOTLIGHT indexed \(written.count)")
                #endif
            } catch {
                AppLog.library.error("spotlight failed: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    /// Signed out, or turned off in Settings.
    func clear() { forget(owner: nil) }

    private func forget(owner: String?) {
        generation += 1
        UserDefaults.standard.removeObject(forKey: Self.digestKey)
        UserDefaults.standard.set(owner, forKey: Self.ownerKey)
        #if DEBUG
        guard UserDefaults.standard.bool(forKey: "SpotlightIndex") else { return }
        #endif
        enqueue { try? await CSSearchableIndex.default().deleteAllSearchableItems() }
    }

    private func enqueue(_ body: @escaping @MainActor () async -> Void) {
        let previous = chain
        chain = Task {
            await previous?.value
            await body()
        }
    }

    /// The title a chosen result stands for; nil when it belongs to another server or profile.
    static func ratingKey(from activity: NSUserActivity, key: String?) -> String? {
        guard activity.activityType == CSSearchableItemActionType,
              let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String, let key,
              id.hasPrefix(key + "|") else { return nil }
        return String(id.dropFirst(key.count + 1))
    }

    /// Writes every title when something changed; nil when nothing did (or the read failed: an
    /// empty answer isn't an empty library).
    private nonisolated static func write(index: LibraryIndex, key: String, sections: [String],
                                          known: String?) async throws -> (digest: String, count: Int)? {
        try await Task.detached(priority: .utility) {
            let made = items(index: index, key: key, sections: sections)
            guard !made.items.isEmpty, made.digest != known else { return nil }
            let store = CSSearchableIndex.default()
            try await store.deleteAllSearchableItems()
            try await store.indexSearchableItems(made.items)
            return (made.digest, made.items.count)
        }.value
    }

    private nonisolated static func items(index: LibraryIndex, key: String, sections: [String]) -> (items: [CSSearchableItem], digest: String) {
        let titles = (try? index.spotlightTitles(sections: sections)) ?? []
        var hash = SHA256()
        hash.update(data: Data(key.utf8))
        let items = titles.map { title -> CSSearchableItem in
            hash.update(data: Data("\(title.ratingKey)\u{1}\(title.title)\u{1}\(title.year ?? 0)\u{1}\(title.summary)\u{2}".utf8))
            let set = CSSearchableItemAttributeSet(contentType: title.kind == "movie" ? .movie : .audiovisualContent)
            set.title = title.title
            set.displayName = title.title
            let facts = [title.kind == "movie" ? "Film" : "Show", title.year.map(String.init)].compactMap { $0 }.joined(separator: " · ")
            set.contentDescription = title.summary.isEmpty ? facts : "\(facts)\n\(title.summary)"
            set.genre = title.genres.first
            set.keywords = title.genres
            let item = CSSearchableItem(uniqueIdentifier: "\(key)|\(title.ratingKey)", domainIdentifier: key, attributeSet: set)
            // They're only rewritten when something changed, so they must not run out on their own.
            item.expirationDate = .distantFuture
            return item
        }
        return (items, hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
}
