import SwiftUI
import MezzanineKit

/// Home: what you're in the middle of, on top, lit by the film in focus.
///
/// Arrow keys move focus across shelves; Return or Space plays the focused
/// title; I shows its details. Resting the pointer on a poster moves focus
/// to it, so the room follows the mouse too.
struct HomeView: View {
    @Environment(SessionStore.self) private var session
    @Environment(PlaybackCoordinator.self) private var playback
    @State private var model = HomeModel()
    @State private var showsDetails = false
    @State private var heroFrame: CGRect = .zero
    @FocusState private var keyboardFocus: Bool

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: Theme.Space.xl) {
                        if let item = model.focusedItem {
                            HeroView(item: item, showsDetails: $showsDetails,
                                     play: { play(item) })
                                .frame(height: heroHeight(geo.size.height), alignment: .bottom)
                                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { heroFrame = $0 }
                                .id("hero")
                        }
                        ForEach(Array(model.shelves.enumerated()), id: \.element.id) { row, shelf in
                            ShelfView(shelf: shelf, row: row,
                                      focusedColumn: model.focus.row == row ? model.focus.column : nil,
                                      onFocus: { column in withAnimation(Theme.Motion.quick) { model.focus(row: row, column: column) } },
                                      onPlay: { item in play(item) })
                                .id("shelf-\(row)")
                        }
                    }
                    .padding(.bottom, Theme.Space.xxl)
                }
                .scrollIndicators(.never)
                .onChange(of: model.focus.row) { _, row in
                    withAnimation(Theme.Motion.object) {
                        proxy.scrollTo(row == 0 ? "hero" : "shelf-\(row)", anchor: row == 0 ? .top : nil)
                    }
                }
            }
        }
        .overlay { emptyOrLoading }
        .focusable()
        .focusEffectDisabled()
        .focused($keyboardFocus)
        .onMoveCommand { model.move($0) }
        .onKeyPress(.return) { playFocused() }
        .onKeyPress(.space) { playFocused() }
        .onKeyPress(characters: CharacterSet(charactersIn: "iI")) { _ in
            withAnimation(Theme.Motion.object) { showsDetails.toggle() }
            return .handled
        }
        .onChange(of: model.focusedItem?.ratingKey) { _, _ in
            showsDetails = false
            updateRoom()
        }
        .onAppear {
            keyboardFocus = true
            updateRoom()
        }
        .task(id: session.currentServer?.clientIdentifier) {
            guard let client = session.client else { return }
            await model.load(client: client)
            updateRoom()
        }
        .navigationTitle("Home")
    }

    @ViewBuilder private var emptyOrLoading: some View {
        if model.shelves.isEmpty {
            if model.isLoading {
                ProgressView().controlSize(.large)
            } else if let error = model.error {
                ContentUnavailableView("Home didn’t load", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else {
                ContentUnavailableView("Nothing in progress", systemImage: "film.stack",
                                       description: Text("Start something from a library and it shows up here."))
            }
        }
    }

    private func heroHeight(_ windowHeight: CGFloat) -> CGFloat {
        min(560, max(360, windowHeight * 0.48))
    }

    private func updateRoom() {
        playback.roomPalette = RoomPalette(model.focusedItem?.ultraBlur) ?? .dark
    }

    private func playFocused() -> KeyPress.Result {
        guard let item = model.focusedItem else { return .ignored }
        play(item)
        return .handled
    }

    private func play(_ item: PlexMetadata) {
        Task { await playback.play(item, from: heroFrame) }
    }
}
