import SwiftUI
import MezzanineKit

/// One row of posters on Home.
struct Shelf: Identifiable, Equatable {
    let id: String
    let title: String
    var items: [PlexMetadata]
}

/// Where keyboard focus sits on Home: a shelf and a position in it.
struct ShelfFocus: Equatable, Hashable {
    var row: Int
    var column: Int
}

/// Home's content and its focus. Shelves come from the server's hubs for
/// now; user-built shelves arrive in M7 and slot into the same model.
@MainActor
@Observable
final class HomeModel {
    private(set) var shelves: [Shelf] = []
    private(set) var isLoading = false
    private(set) var error: String?
    var focus = ShelfFocus(row: 0, column: 0)

    /// Hubs Home shows, in order. Everything else stays on its library page.
    private static let hubOrder = ["home.continue", "home.ondeck", "home.movies.recent", "home.television.recent"]

    var focusedItem: PlexMetadata? {
        guard shelves.indices.contains(focus.row) else { return nil }
        let items = shelves[focus.row].items
        return items.indices.contains(focus.column) ? items[focus.column] : nil
    }

    func load(client: PlexServerClient) async {
        isLoading = shelves.isEmpty
        defer { isLoading = false }
        do {
            let hubs = try await client.homeHubs(count: 24)
            var seen = Set<String>()
            var rows: [Shelf] = []
            for id in Self.hubOrder {
                guard let hub = hubs.first(where: { $0.hubIdentifier == id }) else { continue }
                // On Deck repeats what Continue Watching already holds on recent servers.
                let items = hub.items.filter { seen.insert($0.ratingKey).inserted }
                guard !items.isEmpty else { continue }
                rows.append(Shelf(id: hub.hubIdentifier, title: hub.title, items: items))
            }
            shelves = rows
            clampFocus()
            error = nil
        } catch {
            self.error = (error as? PlexError)?.userMessage ?? "Couldn’t load Home."
        }
    }

    // MARK: Focus movement

    func move(_ direction: MoveCommandDirection) {
        guard !shelves.isEmpty else { return }
        switch direction {
        case .left: focus.column = max(0, focus.column - 1)
        case .right: focus.column = min(shelves[focus.row].items.count - 1, focus.column + 1)
        case .up: focus.row = max(0, focus.row - 1)
        case .down: focus.row = min(shelves.count - 1, focus.row + 1)
        @unknown default: break
        }
        clampFocus()
    }

    func focus(row: Int, column: Int) {
        focus = ShelfFocus(row: row, column: column)
        clampFocus()
    }

    private func clampFocus() {
        guard !shelves.isEmpty else { focus = ShelfFocus(row: 0, column: 0); return }
        focus.row = min(max(0, focus.row), shelves.count - 1)
        focus.column = min(max(0, focus.column), max(0, shelves[focus.row].items.count - 1))
    }
}
