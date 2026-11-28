import SwiftUI
import MezzanineKit

/// An audio playlist: its cover, name and facts on the left, its songs in order on the right.
/// Read-only in Music M1 (editing arrives in M5; nothing here changes or deletes a playlist).
///
/// Keys: ↑/↓ move, Return or Space plays the song in hand (else the playlist), ⌘[ or Esc goes back.
struct PlaylistPage: View {
    let route: DetailRoute
    var contentFocus: FocusState<Bool>.Binding

    @Environment(SessionStore.self) private var session
    @Environment(AppCommandCenter.self) private var commands
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(MusicActions.self) private var actions
    @Environment(MusicSession.self) private var music
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var playlist: PlexMetadata?
    @State private var songs: [PlexMetadata] = []
    @State private var loaded = false
    @State private var failure: String?
    @State private var focused: String?
    @State private var keyboardMoved = false
    @State private var attempt = 0

    private var isTop: Bool { commands.path.last == route }
    /// A playlist can hold one song twice: rows are identified by their place and the song's key.
    private var focusedSong: PlexMetadata? { focused.flatMap { key in songs.first { $0.ratingKey == key } } }

    var body: some View {
        SleevePage { art in
            if let playlist { sleeve(playlist, art: art) }
        } right: { width in
            ScrollViewReader { proxy in
                list(width: width)
                    .onChange(of: focused) { _, key in
                        guard keyboardMoved, let key else { return }
                        withAnimation(Theme.Motion.object(reduceMotion)) { proxy.scrollTo(key) }
                    }
            }
        }
        .overlay { state }
        .focusable()
        .focusEffectDisabled()
        .focused(contentFocus)
        .onMoveCommand(perform: move)
        .onKeyPress(.return) { playFocused() }
        .onKeyPress(.space) { spacePressed() }
        .onKeyPress(.escape) {
            guard commands.canGoBack else { return .ignored }
            commands.goBack()
            return .handled
        }
        .navigationTitle(playlist?.title ?? "")
        .navigationSubtitle("Playlist")
        .task(id: "\(route.ratingKey)|\(attempt)") { await load() }
        .onChange(of: reportedItem, initial: true) { _, _ in report() }
        .onChange(of: isTop) { _, top in if top { report() } }
        .onChange(of: commands.playFocusedRequests) { _, _ in
            if isTop { _ = playFocused() }
        }
        .onDisappear { if commands.detailFocusedItem?.ratingKey == reportedItem?.ratingKey { commands.detailFocusedItem = nil } }
    }

    private func sleeve(_ playlist: PlexMetadata, art: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SleeveArt(path: playlist.posterPath, size: art)
            Text(playlist.title)
                .font(.system(.title, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Theme.Space.l)
                .accessibilityAddTraits(.isHeader)
            MusicCaption(lines: [[playlist.leafCount.map(MusicFormat.songs), playlist.duration.map(Format.duration),
                                  playlist.isSmart ? "Smart playlist" : nil].compactMap { $0 }])
                .padding(.top, Theme.Space.m)
                .frame(width: art, alignment: .leading)
            MusicPageButtons(item: playlist, width: art)
                .padding(.top, Theme.Space.m)
        }
    }

    private func list(width: CGFloat) -> some View {
        let columns = SongColumns.table(width: width)
        return LazyVStack(alignment: .leading, spacing: 0) {
            SongHeader(columns: columns).padding(.bottom, 4)
            ForEach(Array(songs.enumerated()), id: \.element.ratingKey) { i, song in
                SongRowView(song: song, number: i + 1, columns: columns, height: 40, isFocused: focused == song.ratingKey,
                            onSelect: { focused = song.ratingKey }) { play(song) }
                    .id(song.ratingKey)
            }
        }
    }

    @ViewBuilder private var state: some View {
        if playlist == nil, !loaded {
            if let failure { RoomMessage(title: "Couldn’t open this playlist", detail: failure, retry: { attempt += 1 }) }
        } else if loaded, songs.isEmpty {
            RoomMessage(title: failure == nil ? "Nothing in This Playlist" : "Couldn’t read the songs", detail: failure,
                        retry: failure == nil ? nil : { attempt += 1 })
                .padding(.leading, 380)
        }
    }

    private func play(_ song: PlexMetadata) {
        guard let playlist else { return }
        focused = song.ratingKey
        actions.play(song: song, in: songs, title: playlist.title, kind: .playlist, ratingKey: playlist.ratingKey)
    }

    private func playFocused() -> KeyPress.Result {
        if let song = focusedSong { play(song) } else if let playlist { actions.play(playlist) } else { return .ignored }
        return .handled
    }

    private func spacePressed() -> KeyPress.Result {
        if let song = focusedSong {
            if actions.isNowPlaying(song) { music.togglePlayPause() } else { play(song) }
        } else if let playlist {
            actions.playOrToggle(playlist)
        } else { return .ignored }
        return .handled
    }

    private func move(_ direction: MoveCommandDirection) {
        guard !songs.isEmpty else { return }
        let current = focused.flatMap { key in songs.firstIndex { $0.ratingKey == key } }
        keyboardMoved = true
        switch direction {
        case .down: focused = songs[min(songs.count - 1, (current ?? -1) + 1)].ratingKey
        case .up: focused = songs[max(0, (current ?? songs.count) - 1)].ratingKey
        case .left: commands.focusSidebar()
        default: break
        }
    }

    private var reportedItem: PlexMetadata? { focusedSong ?? playlist }

    private func report() {
        guard isTop else { return }
        commands.detailFocusedItem = reportedItem
    }

    private func load() async {
        guard let client = session.client else { return }
        let key = route.ratingKey
        do {
            if playlist == nil { playlist = try await client.audioPlaylists().first { $0.ratingKey == key } }
            guard !Task.isCancelled else { return }
            if let palette = playlist.flatMap({ RoomPalette($0.ultraBlur) }) { playback.roomPalette = palette }
            songs = try await client.playlistItems(key).filter { $0.kind == .track }
            guard !Task.isCancelled else { return }
            loaded = true
            failure = nil
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            failure = (error as? PlexError)?.userMessage ?? "Plex didn’t answer."
            loaded = true
        }
    }
}
