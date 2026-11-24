import SwiftUI
import MezzanineKit

/// Collections, playlists and smart shelves pinned to the sidebar, in the owner's order, saved
/// per server and Plex Home profile (as `HomeLayoutStore` does).
@MainActor
@Observable
final class PinnedStore {
    private(set) var pins: [ShelfSpec] = []
    @ObservationIgnored private var storageKey: String?

    func use(serverID: String, userID: String) {
        let key = "pins.v1.\(serverID).\(userID)"
        guard key != storageKey else { return }
        storageKey = key
        pins = UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([ShelfSpec].self, from: $0) } ?? []
    }

    var isReady: Bool { storageKey != nil }

    func pin(_ id: String) -> ShelfSpec? { pins.first { $0.id == id } }
    func contains(_ id: String) -> Bool { pins.contains { $0.id == id } }

    /// Pins have their own ids, so a shelf removed from Home keeps its pin.
    static func id(collection ratingKey: String) -> String { "collection:\(ratingKey)" }

    static func spec(for collection: PlexMetadata, section: String) -> ShelfSpec {
        ShelfSpec(id: id(collection: collection.ratingKey), title: collection.title,
                  source: .collection(ratingKey: collection.ratingKey, section: section))
    }

    /// The pin a Home shelf would make; nil for Plex's own rows, which belong to Home.
    static func spec(for shelf: ShelfSpec) -> ShelfSpec? {
        var pin = shelf
        pin.hidden = false
        switch shelf.source {
        case .hub: return nil
        case .collection(let key, _): pin.id = id(collection: key)
        case .playlist(let key): pin.id = "playlist:\(key)"
        case .smart(let rule):
            pin.id = "smart:\(shelf.id)"
            if pin.title.isEmpty { pin.title = rule.summary }
        }
        return pin
    }

    func toggle(_ spec: ShelfSpec) {
        set(contains(spec.id) ? pins.filter { $0.id != spec.id } : pins + [spec])
    }

    func remove(_ id: String) { set(pins.filter { $0.id != id }) }

    func move(from: IndexSet, to: Int) {
        var list = pins
        list.move(fromOffsets: from, toOffset: to)
        set(list)
    }

    /// Assigned once per change.
    private func set(_ list: [ShelfSpec]) {
        guard let storageKey else { return }
        pins = list
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: storageKey) }
    }
}
