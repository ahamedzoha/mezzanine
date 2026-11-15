import SwiftUI
import MezzanineKit

/// One row of posters on Home.
struct Shelf: Identifiable, Equatable {
    let id: String
    let title: String
    var items: [PlexMetadata]
    /// A Plex row this server doesn't have (the layout came from another server, or Plex
    /// stopped offering it). Shown in Edit Home, never on Home.
    var isMissing = false
}

/// Where keyboard focus sits on Home: a shelf and a position in it.
struct ShelfFocus: Equatable, Hashable {
    var row: Int
    var column: Int
}

/// A Home's content (the main Home, or one library's Shelves layout) and its focus.
/// Shelves come from the owner's layout: Plex rows, collections, playlists and smart
/// shelves answered by the local index.
@MainActor
@Observable
final class HomeModel {
    /// Shown shelves: visible, resolved and non-empty, in the owner's order.
    private(set) var shelves: [Shelf] = []
    /// Every shelf of the layout, hidden ones included (Edit Home's peeks and counts).
    private(set) var resolved: [String: Shelf] = [:]
    /// The layout in force (the saved one, or the defaults).
    private(set) var specs: [ShelfSpec] = []
    /// Plex rows the server offers, for Add Shelf: global (`nil`) and per library.
    private(set) var hubCatalog: [String?: [PlexHub]] = [:]
    private(set) var isLoading = false
    private(set) var error: String?
    var focus = ShelfFocus(row: 0, column: 0)

    var focusedItem: PlexMetadata? {
        guard shelves.indices.contains(focus.row) else { return nil }
        let items = shelves[focus.row].items
        return items.indices.contains(focus.column) ? items[focus.column] : nil
    }

    /// Global hubs Home can offer (music and photos stay out of Mezzanine).
    static func offersGlobal(_ hub: PlexHub) -> Bool {
        !["home.music.recent", "home.photos.recent", "home.playlists"].contains(hub.hubIdentifier)
    }

    /// A library's default Shelves: Plex's own rows, minus the ones that rotate their subject
    /// every visit (a random genre or actor), which read as noise in a fixed layout.
    static func defaultSpecs(section: String, hubs: [PlexHub]) -> [ShelfSpec] {
        hubs.filter { hub in
            !["genre", "by.actor", "moreingenre", "random", "rediscover"].contains { hub.hubIdentifier.contains($0) }
        }
        .map { ShelfSpec(id: "hub:\($0.hubIdentifier)", source: .hub(identifier: $0.hubIdentifier, section: section)) }
    }

    /// Bumped by every load: an older one (a retry, a sync tick, a profile switch) that finishes
    /// late stops instead of writing over the newer shelves. `Task.isCancelled` alone can't tell,
    /// because some loads start outside a cancellable task.
    @ObservationIgnored private var loadGeneration = 0
    /// The last refresh asked for each shelf, so an older one can't land after a newer edit.
    @ObservationIgnored private var refreshTokens: [String: UUID] = [:]

    func load(scope: String, saved: [ShelfSpec]?, client: PlexServerClient, index: LibraryIndex?) async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = shelves.isEmpty
        defer { if generation == loadGeneration { isLoading = false } }
        var hubCache: [String?: [PlexHub]] = [:]
        func hubs(_ section: String?) async throws -> [PlexHub] {
            if let cached = hubCache[section] { return cached }
            let list: [PlexHub]
            if let section { list = try await client.sectionHubs(section, count: 24) } else { list = try await client.homeHubs(count: 24) }
            hubCache[section] = list
            return list
        }
        do {
            let isMain = scope == HomeLayout.mainScope
            // One entry per id (a layout saved by an older build could repeat one).
            var seen = Set<String>()
            var layout = (saved ?? []).filter { seen.insert($0.id).inserted }
            if saved == nil {
                layout = isMain ? HomeLayout.defaultHome : Self.defaultSpecs(section: scope, hubs: try await hubs(scope))
            }
            var out: [String: Shelf] = [:]
            for spec in layout {
                out[spec.id] = await resolve(spec, hubs: hubs, client: client, index: index)
            }
            // Superseded by a newer load (the layout changed): leave the state to it.
            guard !Task.isCancelled, generation == loadGeneration else { return }
            specs = layout
            resolved = out
            shelves = layout.filter { !$0.hidden }.compactMap { out[$0.id] }.filter { !$0.items.isEmpty && !$0.isMissing }
            // The rows Add Shelf can offer here: global ones on the main Home, the library's own elsewhere.
            let catalog = try await hubs(isMain ? nil : scope)
            guard generation == loadGeneration else { return }
            hubCatalog[isMain ? nil : scope] = catalog
            clampFocus()
            error = nil
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled, generation == loadGeneration else { return }
            self.error = (error as? PlexError)?.userMessage ?? "Couldn’t load the shelves."
        }
    }

    /// Shows an edited layout at once from what's already resolved (Done in Edit Shelves),
    /// so the strips unfold into poster rows in the new order without a reload.
    func apply(_ layout: [ShelfSpec]) {
        specs = layout
        shelves = layout.filter { !$0.hidden }.compactMap { resolved[$0.id] }.filter { !$0.items.isEmpty && !$0.isMissing }
        clampFocus()
    }

    /// The default layout for a scope (what "Restore Default Shelves" returns to).
    func defaults(for scope: String) -> [ShelfSpec] {
        scope == HomeLayout.mainScope ? HomeLayout.defaultHome : Self.defaultSpecs(section: scope, hubs: hubCatalog[scope] ?? [])
    }

    /// The Plex rows of each library, for the main Home's Add Shelf ▸ library submenus.
    func loadCatalog(sections: [PlexLibrarySection], client: PlexServerClient) async {
        for section in sections where hubCatalog[section.key] == nil {
            hubCatalog[section.key] = (try? await client.sectionHubs(section.key, count: 1)) ?? []
        }
    }

    /// Resolves one shelf in place (after Edit Home adds or changes it), without reloading Home.
    func refresh(_ spec: ShelfSpec, client: PlexServerClient, index: LibraryIndex?) async {
        let token = UUID()
        refreshTokens[spec.id] = token
        let generation = loadGeneration
        let cache = hubCatalog
        let shelf = await resolve(spec, hubs: { section in
            if let list = cache[section], list.contains(where: { $0.items.count > 1 }) { return list }
            if let section { return try await client.sectionHubs(section, count: 24) }
            return try await client.homeHubs(count: 24)
        }, client: client, index: index)
        // A newer edit of this shelf, or a full reload, answered meanwhile.
        guard refreshTokens[spec.id] == token, generation == loadGeneration else { return }
        resolved[spec.id] = shelf
    }

    private func resolve(_ spec: ShelfSpec, hubs: (String?) async throws -> [PlexHub],
                         client: PlexServerClient, index: LibraryIndex?) async -> Shelf {
        switch spec.source {
        case .hub(let identifier, let section):
            if let hub = try? await hubs(section).first(where: { $0.hubIdentifier == identifier }) {
                return Shelf(id: spec.id, title: spec.title.isEmpty ? hub.title : spec.title, items: hub.items)
            }
            return Shelf(id: spec.id, title: spec.title.isEmpty ? Self.fallbackTitle(identifier) : spec.title,
                         items: [], isMissing: true)
        case .collection(let key, _):
            let items = (try? await client.collectionItems(key)) ?? []
            return Shelf(id: spec.id, title: spec.title, items: Array(items.prefix(60)))
        case .playlist(let key):
            let items = (try? await client.playlistItems(key)) ?? []
            return Shelf(id: spec.id, title: spec.title, items: Array(items.prefix(60)))
        case .smart(let rule):
            let items = ((try? index?.items(rule)) ?? []).compactMap { $0.metadata() }
            return Shelf(id: spec.id, title: spec.title.isEmpty ? rule.summary : spec.title, items: items)
        }
    }

    /// A readable name for a Plex row that isn't on this server.
    static func fallbackTitle(_ identifier: String) -> String {
        switch identifier {
        case "home.continue": "Continue Watching"
        case "home.ondeck": "On Deck"
        case "home.movies.recent": "Recently Added Movies"
        case "home.television.recent": "Recently Added TV"
        default: identifier
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
