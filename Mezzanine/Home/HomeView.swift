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
    @Environment(AppCommandCenter.self) private var commands
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
        .onChange(of: model.focusedItem?.ratingKey, initial: true) { _, key in
            showsDetails = false
            commands.hasFocusedTitle = key != nil
            updateRoom()
        }
        .onChange(of: commands.playFocusedRequests) { _, _ in _ = playFocused() }
        .onChange(of: commands.detailsRequests) { _, _ in
            withAnimation(Theme.Motion.object(reduceMotion)) { showsDetails.toggle() }
        }
        .task(id: session.currentServer?.clientIdentifier) { await load() }
        .navigationTitle("Home")
    }

    @ViewBuilder private var emptyOrLoading: some View {
        if model.shelves.isEmpty {
            if model.isLoading {
                RoomMessage { ProgressView().controlSize(.small).accessibilityLabel("Loading") }
            } else if let error = model.error {
                RoomMessage(title: "Home didn’t load", detail: error, retry: { Task { await load() } })
            } else {
                RoomMessage(title: "Nothing in progress", detail: "Start something from a library and it shows up here.")
            }
        }
    }

    private func load() async {
        guard let client = session.client else { return }
        await model.load(client: client)
        updateRoom()
        await prefetchHeroArt()
    }

    /// Warms the backdrop and logo of every shelf title, so moving focus
    /// swaps the hero from memory instead of waiting on the server.
    private func prefetchHeroArt() async {
        let width = Int((NSScreen.main?.frame.width ?? 1440) * 0.74 * 2)
        let items = model.shelves.flatMap { $0.items.prefix(16) }
        await withTaskGroup(of: Void.self) { group in
            for item in items {
                if let url = session.backdropURL(item.backdropPath, pixelWidth: width) {
                    group.addTask(priority: .utility) { [images = session.images] in _ = try? await images.image(for: url, pixelSize: width) }
                }
                if let url = session.logoURL(item.clearLogoPath) {
                    group.addTask(priority: .utility) { [images = session.images] in _ = try? await images.image(for: url, pixelSize: 1200) }
                }
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
    var retry: (() -> Void)?
    @ViewBuilder var accessory: () -> Accessory

    init(title: String? = nil, detail: String? = nil, retry: (() -> Void)? = nil,
         @ViewBuilder accessory: @escaping () -> Accessory) {
        self.title = title
        self.detail = detail
        self.retry = retry
        self.accessory = accessory
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            accessory()
            if let title {
                Text(title).font(Theme.Typeface.messageTitle).foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
            }
            if let detail {
                Text(detail).font(Theme.Typeface.body).foregroundStyle(Theme.inkSecondary)
                    .frame(maxWidth: 480, alignment: .leading)
            }
            if let retry {
                Button("Try Again", action: retry)
                    .buttonStyle(SecondaryButtonStyle())
                    .focusEffectDisabled(false)
                    .padding(.top, Theme.Space.s)
            }
        }
        .padding(.leading, Theme.Space.gutter)
        .padding(.top, Theme.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

extension RoomMessage where Accessory == EmptyView {
    init(title: String?, detail: String?, retry: (() -> Void)? = nil) {
        self.init(title: title, detail: detail, retry: retry) { EmptyView() }
    }
}
