import SwiftUI
import MezzanineKit

/// Home: what you're in the middle of, on top, lit by the film in focus.
///
/// Arrow keys move focus across shelves and scroll to it; Return or Space
/// plays the focused title; I shows its details. Resting the pointer on a
/// poster moves focus (and the room's light) to it without scrolling.
struct HomeView: View {
    var contentFocus: FocusState<Bool>.Binding
    /// `home` for the main Home; a section key for a library's Shelves layout.
    var scope: String = HomeLayout.mainScope
    /// The main Home sets its own title and toolbar; a library page keeps its own.
    var isMain: Bool { scope == HomeLayout.mainScope }

    @Environment(SessionStore.self) private var session
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(AppCommandCenter.self) private var commands
    @Environment(HomeLayoutStore.self) private var layouts
    @Environment(LibraryStore.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model = HomeModel()
    @State private var showsDetails = false
    @State private var heroFrame: CGRect = .zero
    /// True when the last focus change came from the keyboard (only then do we scroll).
    @State private var keyboardMoved = false
    // Edit Home
    @State private var editing = false
    @State private var editSpecs: [ShelfSpec] = []
    @State private var ruleSheet: RuleSheetTarget?
    @State private var pickingCollection = false
    @State private var playlists: [PlexMetadata] = []
    @Namespace private var fold

    /// The rule sheet's subject: an existing smart shelf, or a new one.
    struct RuleSheetTarget: Identifiable {
        let id = UUID()
        let spec: ShelfSpec?
    }

    var body: some View {
        Group {
            if editing {
                ShelfEditor(scope: scope, model: model, specs: $editSpecs, sections: commands.sections, peek: fold,
                            editRules: { ruleSheet = RuleSheetTarget(spec: $0) },
                            addCollection: { pickingCollection = true },
                            addPlaylist: { playlist in
                                editSpecs.append(ShelfSpec(title: playlist.title, source: .playlist(ratingKey: playlist.ratingKey)))
                            },
                            playlists: playlists,
                            resetLayout: resetLayout,
                            done: { setEditing(false) })
                    .transition(.opacity)
            } else {
                browsing
            }
        }
        .task(id: "\(session.currentServer?.clientIdentifier ?? "")|\(scope)|\(layouts.revision)|\(library.revision)") { await load() }
        .onChange(of: editSpecs) { _, specs in
            // A shelf just added has nothing resolved yet: fetch its posters for the strip's peek.
            guard let client = session.client else { return }
            for spec in specs where model.resolved[spec.id] == nil {
                Task { await model.refresh(spec, client: client, index: library.index) }
            }
        }
        .onChange(of: commands.editShelvesRequests) { _, _ in setEditing(!editing) }
        .onChange(of: commands.newSmartShelfRequests) { _, _ in
            if !editing { setEditing(true) }
            ruleSheet = RuleSheetTarget(spec: nil)
        }
        .onAppear { commands.isShelvesPageVisible = true }
        .onDisappear {
            if editing { save() }
            commands.isShelvesPageVisible = false
            commands.isEditingShelves = false
        }
        .sheet(item: $ruleSheet) { target in
            SmartShelfSheet(existing: target.spec, scope: scope, sections: commands.sections) { spec in
                if let i = editSpecs.firstIndex(where: { $0.id == spec.id }) {
                    editSpecs[i] = spec
                    if let client = session.client { Task { await model.refresh(spec, client: client, index: library.index) } }
                } else {
                    editSpecs.append(spec)
                }
            }
        }
        .sheet(isPresented: $pickingCollection) {
            CollectionPicker(sections: isMain ? commands.sections : commands.sections.filter { $0.key == scope }) { collection, section in
                editSpecs.append(ShelfSpec(title: collection.title, source: .collection(ratingKey: collection.ratingKey, section: section)))
            }
        }
        .toolbar {
            if isMain {
                ToolbarItem(placement: .primaryAction) { editButton }
            }
        }
        .modifier(MainTitle(isMain: isMain))
    }

    /// Edit / Done. Done is the screen's primary action while editing.
    @ViewBuilder private var editButton: some View {
        if editing {
            Button("Done") { setEditing(false) }
                .buttonStyle(.borderedProminent)
                .tint(Theme.lilac)
                .help("Finish editing shelves (⌘E)")
        } else {
            Button("Edit") { setEditing(true) }
                .help("Reorder, hide and add shelves (⌘E)")
        }
    }

    private var browsing: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: Theme.Space.xl) {
                        if let item = model.focusedItem {
                            HeroView(item: item, showsDetails: $showsDetails, play: { play(item, from: heroFrame) },
                                     open: { commands.open(item) })
                                .frame(minHeight: heroHeight(geo.size.height), alignment: .bottom)
                                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { heroFrame = $0 }
                                .id("hero")
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                        ForEach(Array(model.shelves.enumerated()), id: \.element.id) { row, shelf in
                            ShelfView(shelf: shelf, row: row,
                                      focusedColumn: model.focus.row == row ? model.focus.column : nil,
                                      scrollsToFocus: keyboardMoved,
                                      onFocus: { column in
                                          keyboardMoved = false
                                          model.focus(row: row, column: column)
                                      },
                                      onPlay: { item, frame in play(item, from: frame) },
                                      fold: fold)
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
            // At the first poster of a shelf, ← hands focus back to the sidebar.
            if direction == .left && model.focus.column == 0 { commands.focusSidebar(); return }
            model.move(direction)
        }
        .onKeyPress(.return) {
            guard let item = model.focusedItem else { return .ignored }
            commands.open(item)
            return .handled
        }
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
    }

    @ViewBuilder private var emptyOrLoading: some View {
        if model.shelves.isEmpty {
            if model.isLoading {
                RoomMessage { ProgressView().controlSize(.small).accessibilityLabel("Loading") }
            } else if let error = model.error {
                RoomMessage(title: isMain ? "Home didn’t load" : "Shelves didn’t load", detail: error, retry: { Task { await load() } })
            } else if !model.specs.isEmpty && model.specs.allSatisfy(\.hidden) {
                RoomMessage(title: "Every shelf is hidden", detail: "Edit Shelves (⌘E) to show some again.")
            } else {
                RoomMessage(title: "Nothing in progress", detail: "Start something from a library and it shows up here.")
            }
        }
    }

    // MARK: Edit Home

    private func setEditing(_ on: Bool) {
        // Editing before the server and profile are known would have nowhere to save.
        guard on != editing, layouts.isReady else { return }
        if on {
            editSpecs = model.specs
            if let client = session.client {
                Task {
                    await model.loadCatalog(sections: isMain ? commands.sections : [], client: client)
                    playlists = (try? await client.playlists()) ?? []
                }
            }
        } else {
            save()
        }
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : Theme.Motion.object) { editing = on }
        commands.isEditingShelves = on
    }

    /// Saves the edited layout when it differs from what Home shows (untouched defaults stay defaults).
    private func save() {
        guard editSpecs != model.specs || layouts.saved(scope) != nil else { return }
        layouts.set(scope, editSpecs)
    }

    private func resetLayout() {
        let defaults = isMain ? HomeLayout.defaultHome : HomeModel.defaultSpecs(section: scope, hubs: model.hubCatalog[scope] ?? [])
        withAnimation(Theme.Motion.object(reduceMotion)) { editSpecs = defaults }
        layouts.reset(scope)
    }

    // MARK: Loading

    private func load() async {
        guard let client = session.client else { return }
        await model.load(scope: scope, saved: layouts.saved(scope), client: client, index: library.index)
        // A newer load (the layout changed) supersedes this one.
        guard !Task.isCancelled else { return }
        if !editing { updateRoom() }
        #if DEBUG
        // -HomeSeedShelves YES: a layout with a smart shelf, a collection and a hidden row (captures).
        if isMain, layouts.isReady, layouts.saved(scope) == nil, UserDefaults.standard.bool(forKey: "HomeSeedShelves") {
            var seeded = HomeLayout.defaultHome
            seeded[2].hidden = true
            seeded.insert(ShelfSpec(title: "Unwatched Comedy", source: .smart(SmartRule(kinds: ["movie"],
                conditions: [.watch(.unwatched), .genre("Comedy", excluded: false)], sort: .rating))), at: 1)
            seeded.append(ShelfSpec(title: "IMDb Top 250", source: .collection(ratingKey: "7599", section: "1")))
            layouts.set(scope, seeded)
            return
        }
        // -HomeEditing YES opens Edit Home; -SmartShelfSheet YES also opens a new smart shelf (captures).
        if isMain, !editing, layouts.isReady, !model.specs.isEmpty, UserDefaults.standard.bool(forKey: "HomeEditing") {
            setEditing(true)
            if UserDefaults.standard.bool(forKey: "SmartShelfSheet") {
                try? await Task.sleep(for: .milliseconds(600))
                ruleSheet = RuleSheetTarget(spec: nil)
            }
        }
        #endif
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

/// The main Home names itself; a library's Shelves layout keeps the library's title.
private struct MainTitle: ViewModifier {
    let isMain: Bool
    func body(content: Content) -> some View {
        if isMain { content.navigationTitle("Home") } else { content }
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
