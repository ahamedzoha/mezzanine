import SwiftUI
import MezzanineKit

/// Results for the toolbar search, as a poster grid in the same room.
/// Arrow keys move through results, Return or Space plays. The local index
/// (M1) will answer this instantly; for now the server does.
struct SearchView: View {
    let query: String
    var contentFocus: FocusState<Bool>.Binding

    @Environment(SessionStore.self) private var session
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(AppCommandCenter.self) private var commands
    @Environment(LibraryStore.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var results: [PlexMetadata] = []
    @State private var phase: Phase = .idle
    @State private var focused: Int?
    @State private var keyboardMoved = false
    @State private var columns = 1

    private enum Phase: Equatable { case idle, tooShort, searching, done, failed(String) }
    private static let density: Double = 150

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    PosterGrid(items: results, density: Self.density, focused: focused,
                               actions: CardActions(focus: { setFocus($0, byKeyboard: false) },
                                                    open: { commands.open($0) },
                                                    play: { item, frame in Task { await playback.play(item, from: frame) } }))
                }
                .onChange(of: focused) { _, index in
                    guard let index, keyboardMoved else { return }
                    withAnimation(Theme.Motion.object(reduceMotion)) { proxy.scrollTo(index) }
                }
            }
            .onChange(of: geo.size.width, initial: true) { _, w in columns = PosterGrid.columnCount(width: w, density: Self.density) }
        }
        .overlay { state }
        .focusable()
        .focusEffectDisabled()
        .focused(contentFocus)
        .onMoveCommand(perform: move)
        .onKeyPress(.return) {
            guard let focused, results.indices.contains(focused) else { return .ignored }
            commands.open(results[focused])
            return .handled
        }
        .onKeyPress(.space) { playFocused() }
        .onChange(of: focused, initial: true) { _, index in commands.hasFocusedTitle = index != nil }
        .onChange(of: commands.playFocusedRequests) { _, _ in _ = playFocused() }
        .navigationTitle("Search")
        .navigationSubtitle(results.isEmpty ? "" : (results.count == 1 ? "1 result" : "\(results.count) results"))
        .task(id: query) { await search() }
    }

    @ViewBuilder private var state: some View {
        if results.isEmpty {
            switch phase {
            case .searching: RoomMessage { ProgressView().controlSize(.small).accessibilityLabel("Searching") }
            case .tooShort: RoomMessage(title: "Keep typing", detail: "Search starts at two characters.")
            case .failed(let message): RoomMessage(title: "Search didn’t work", detail: message, retry: { Task { await search() } })
            case .done: RoomMessage(title: "No results for “\(query)”", detail: "Search looks at titles, people and collections in every library.")
            case .idle: EmptyView()
            }
        }
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { results = []; phase = .tooShort; return }
        guard let client = session.client else { return }
        // The local index answers as you type; the server only when it's empty.
        let local = await library.search(q)
        if !local.isEmpty || library.index != nil && library.syncState == .idle {
            let titles = local.filter { $0.kind != .episode }
            results = titles + local.filter { $0.kind == .episode }.prefix(12)
            focused = nil
            phase = .done
            return
        }
        phase = .searching
        // Wait for the typing to settle.
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        do {
            let hubs = try await client.search(q, limit: 40)
            var seen = Set<String>()
            let found = hubs.flatMap(\.items).filter {
                [.movie, .show, .season, .episode, .collection].contains($0.kind) && seen.insert($0.ratingKey).inserted
            }
            // Titles first; a show's episodes come last and capped, so one series can't bury everything else.
            let rank: [PlexMetadata.Kind: Int] = [.movie: 0, .show: 0, .collection: 1, .season: 2, .episode: 3]
            let titles = found.filter { $0.kind != .episode }.sorted { (rank[$0.kind] ?? 9) < (rank[$1.kind] ?? 9) }
            results = titles + found.filter { $0.kind == .episode }.prefix(12)
            focused = nil
            phase = .done
        } catch is CancellationError {
        } catch {
            results = []
            phase = .failed((error as? PlexError)?.userMessage ?? "The server didn’t answer.")
        }
    }

    private func setFocus(_ index: Int, byKeyboard: Bool) {
        keyboardMoved = byKeyboard
        focused = index
        playback.roomPalette = RoomPalette(results[index].ultraBlur) ?? .dark
    }

    private func move(_ direction: MoveCommandDirection) {
        guard !results.isEmpty else { return }
        let current = focused ?? 0
        var next = current
        switch direction {
        case .left: next = current - 1
        case .right: next = current + 1
        case .up: next = current - columns
        case .down: next = current + columns
        @unknown default: break
        }
        if focused == nil { next = 0 }
        setFocus(min(max(0, next), results.count - 1), byKeyboard: true)
    }

    private func playFocused() -> KeyPress.Result {
        guard let focused, results.indices.contains(focused) else { return .ignored }
        Task { await playback.play(results[focused], from: nil) }
        return .handled
    }
}
