import SwiftUI
import MezzanineKit

/// Results for the toolbar search, as a poster grid in the same room.
/// The local index (M1) will answer this instantly; for now the server does.
struct SearchView: View {
    let query: String

    @Environment(SessionStore.self) private var session
    @Environment(PlaybackCoordinator.self) private var playback
    @State private var results: [PlexMetadata] = []
    @State private var searching = false
    @State private var focused: Int?

    var body: some View {
        ScrollView {
            PosterGrid(items: results, density: 150, focused: focused,
                       onFocus: { index in
                           focused = index
                           playback.roomPalette = RoomPalette(results[index].ultraBlur) ?? .dark
                       },
                       onPlay: { item, frame in Task { await playback.play(item, from: frame) } })
        }
        .overlay {
            if results.isEmpty {
                if searching { RoomMessage { ProgressView().controlSize(.small) } }
                else { RoomMessage(title: "No results for “\(query)”", detail: "Search looks at titles, people and collections in every library.") }
            }
        }
        .navigationTitle("Search")
        .navigationSubtitle(results.isEmpty ? "" : "\(results.count) results")
        .task(id: query) { await search() }
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2, let client = session.client else { results = []; return }
        searching = true
        defer { searching = false }
        // Wait for the typing to settle.
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        do {
            let hubs = try await client.search(q, limit: 40)
            var seen = Set<String>()
            results = hubs.flatMap(\.items).filter {
                [.movie, .show, .season, .episode, .collection].contains($0.kind) && seen.insert($0.ratingKey).inserted
            }
            focused = nil
        } catch is CancellationError {
        } catch {
            results = []
        }
    }
}
