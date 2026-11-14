import SwiftUI
import MezzanineKit

/// The shelves of every Home the owner arranges (the main Home and each library's Shelves
/// layout), saved per server and Plex Home profile.
@MainActor
@Observable
final class HomeLayoutStore {
    private(set) var layout = HomeLayout()
    /// Bumped on every change, so Home reloads its shelves.
    private(set) var revision = 0
    @ObservationIgnored private var storageKey: String?

    /// Loads the layout for a server + profile (called when the library index opens).
    func use(serverID: String, userID: String) {
        let key = "homeLayout.v1.\(serverID).\(userID)"
        guard key != storageKey else { return }
        storageKey = key
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode(HomeLayout.self, from: data) {
            layout = saved
        } else {
            layout = HomeLayout()
        }
        revision += 1
    }

    /// True once the server and profile are known; until then nothing can be saved.
    var isReady: Bool { storageKey != nil }

    /// A scope's shelves; nil when the owner hasn't arranged it yet (callers fall back to defaults).
    func saved(_ scope: String) -> [ShelfSpec]? { layout.scopes[scope] }

    func shelves(_ scope: String, defaults: [ShelfSpec]) -> [ShelfSpec] {
        layout.scopes[scope] ?? defaults
    }

    func set(_ scope: String, _ shelves: [ShelfSpec]) {
        layout.scopes[scope] = shelves
        save()
    }

    func reset(_ scope: String) {
        layout.scopes[scope] = nil
        save()
    }

    private func save() {
        revision += 1
        guard let storageKey, let data = try? JSONEncoder().encode(layout) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
