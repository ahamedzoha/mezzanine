import SwiftUI
import MezzanineKit

/// Home: what you're in the middle of, on top, lit by the film in focus.
///
/// Arrow keys move focus across shelves and scroll to it; Return or Space
/// plays the focused title; I shows its details. Resting the pointer on a
/// poster moves focus (and the room's light) to it without scrolling.
struct HomeView: View {
    var contentFocus: FocusState<Bool>.Binding

    @Environment(SessionStore.self) private var session
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model = HomeModel()
    @State private var showsDetails = false
    @State private var heroFrame: CGRect = .zero
    /// True when the last focus change came from the keyboard (only then do we scroll).
    @State private var keyboardMoved = false

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: Theme.Space.xl) {
                        if let item = model.focusedItem {
                            HeroView(item: item, showsDetails: $showsDetails, play: { play(item, from: heroFrame) })
                                .frame(minHeight: heroHeight(geo.size.height), alignment: .bottom)
                                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { heroFrame = $0 }
                                .id("hero")
                        }
                        ForEach(Array(model.shelves.enumerated()), id: \.element.id) { row, shelf in
                            ShelfView(shelf: shelf, row: row,
                                      focusedColumn: model.focus.row == row ? model.focus.column : nil,
                                      scrollsToFocus: keyboardMoved,
                                      onFocus: { column in
                                          keyboardMoved = false
                                          model.focus(row: row, column: column)
                                      },
                                      onPlay: { item, frame in play(item, from: frame) })
                                .id("shelf-\(row)")
                        }
                    }
                    .padding(.bottom, Theme.Space.xxl)
                }
                .scrollIndicators(.never)
                .onChange(of: model.focus.row) { _, row in
                    guard keyboardMoved else { return }
                    withAnimation(Theme.Motion.object(reduceMotion)) {
                        proxy.scrollTo(row == 0 ? "hero" : "shelf-\(row)", anchor: row == 0 ? .top : nil)
                    }
                }
            }
        }
        .overlay { emptyOrLoading }
        .focusable()
        .focusEffectDisabled()
        .focused(contentFocus)
        .onMoveCommand { direction in
            keyboardMoved = true
            model.move(direction)
        }
        .onKeyPress(.return) { playFocused() }
        .onKeyPress(.space) { playFocused() }
        .onKeyPress(characters: CharacterSet(charactersIn: "iI")) { _ in
            withAnimation(Theme.Motion.object(reduceMotion)) { showsDetails.toggle() }
            return .handled
        }
        .onChange(of: model.focusedItem?.ratingKey) { _, _ in
            showsDetails = false
            updateRoom()
        }
        .onAppear { updateRoom() }
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
                RoomMessage { ProgressView().controlSize(.small) }
            } else if let error = model.error {
                RoomMessage(title: "Home didn’t load", detail: error)
            } else {
                RoomMessage(title: "Nothing in progress", detail: "Start something from a library and it shows up here.")
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
        // The stage grows from the hero when it's on screen, else from the window centre.
        play(item, from: heroFrame.maxY > 80 ? heroFrame : nil)
        return .handled
    }

    private func play(_ item: PlexMetadata, from frame: CGRect?) {
        Task { await playback.play(item, from: frame) }
    }
}

/// A short message set on the content gutter, below the toolbar: loading,
/// empty and error states never float in the middle of the room.
struct RoomMessage<Accessory: View>: View {
    var title: String?
    var detail: String?
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            accessory()
            if let title {
                Text(title).font(Theme.Typeface.messageTitle).foregroundStyle(Theme.ink)
            }
            if let detail {
                Text(detail).font(Theme.Typeface.body).foregroundStyle(Theme.inkSecondary)
                    .frame(maxWidth: 480, alignment: .leading)
            }
        }
        .padding(.leading, Theme.Space.gutter)
        .padding(.top, Theme.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

extension RoomMessage where Accessory == EmptyView {
    init(title: String?, detail: String?) {
        self.init(title: title, detail: detail) { EmptyView() }
    }
}
