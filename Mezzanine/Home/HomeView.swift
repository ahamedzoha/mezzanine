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
    /// What this page last loaded or saved (to tell our own writes from a change elsewhere).
    @State private var loadedSaved: [ShelfSpec]??
    @State private var saveTask: Task<Void, Never>?
    /// Bumped when a sheet closes, so the editor takes keyboard focus back.
    @State private var refocus = 0
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
                            defaults: model.defaults(for: scope),
                            refocus: refocus,
                            done: { setEditing(false) })
                    .transition(.opacity)
            } else {
                browsing
            }
        }
        .task(id: "\(session.currentServer?.clientIdentifier ?? "")|\(scope)|\(library.revision)") { await load() }
        .onChange(of: showsDetails, initial: true) { _, shown in commands.detailsShown = shown }
        .onDisappear { commands.detailsShown = false }
        .onChange(of: layouts.revision) { _, _ in
            // Reload only for changes made elsewhere (a profile switch), not for this page's own saves.
            guard !editing, loadedSaved != .some(layouts.saved(scope)) else { return }
            Task { await load() }
        }
        .onChange(of: editSpecs) { _, specs in
            guard editing else { return }
            // A shelf just added has nothing resolved yet: fetch its posters for the strip's peek.
            if let client = session.client {
                for spec in specs where model.resolved[spec.id] == nil {
                    Task { await model.refresh(spec, client: client, index: library.index, stops: library.recentStops) }
                }
            }
            // Save as the edit happens (debounced), so a quit mid-edit keeps it.
            saveTask?.cancel()
            saveTask = Task {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                save()
            }
        }
        .onChange(of: commands.shelfRequests.count) { _, _ in handle(commands.shelfRequests.action) }
        .onChange(of: commands.pendingHomeAction) { _, _ in consumePendingAction() }
        .onChange(of: ruleSheet == nil && !pickingCollection) { _, closed in
            commands.isModalShown = !closed
            if closed { refocus += 1 }
        }
        .onAppear {
            commands.shelvesPages += 1
            consumePendingAction()
        }
        .onDisappear {
            if editing { save() }
            commands.shelvesPages -= 1
            commands.isEditingShelves = false
            commands.isModalShown = false
        }
        .sheet(item: $ruleSheet) { target in
            SmartShelfSheet(existing: target.spec, scope: scope, sections: commands.sections) { spec in
                if let i = editSpecs.firstIndex(where: { $0.id == spec.id }) {
                    editSpecs[i] = spec
                    if let client = session.client { Task { await model.refresh(spec, client: client, index: library.index, stops: library.recentStops) } }
                } else {
                    editSpecs.append(spec)
                }
            }
        }
        .sheet(isPresented: $pickingCollection) {
            CollectionPicker(sections: isMain ? commands.sections : commands.sections.filter { $0.key == scope },
                             existing: Set(editSpecs.compactMap { spec in
                                 if case .collection(let key, _) = spec.source { return key }
                                 return nil
                             })) { collection, section in
                editSpecs.append(ShelfSpec(title: collection.title, source: .collection(ratingKey: collection.ratingKey, section: section)))
            }
        }
        .toolbar {
            if isMain {
                ToolbarItem(placement: .primaryAction) { editButton }
            }
        }
        .modifier(MainTitle(isMain: isMain, editing: editing))
    }

    /// Edit Shelves / Done. Done is the screen's primary action while editing.
    @ViewBuilder private var editButton: some View {
        EditShelvesButton(editing: editing) { setEditing(!editing) }
            .disabled(!layouts.isReady)
    }

    // MARK: Requests

    private func handle(_ action: AppCommandCenter.ShelfAction) {
        switch action {
        case .toggleEditing: setEditing(!editing)
        case .startEditing: setEditing(true)
        case .newSmartShelf:
            guard ruleSheet == nil, !pickingCollection else { return }
            setEditing(true)
            ruleSheet = RuleSheetTarget(spec: nil)
        case .addCollection:
            guard ruleSheet == nil, !pickingCollection else { return }
            setEditing(true)
            pickingCollection = true
        default: break   // strip actions: the editor handles them
        }
    }

    /// Quick Open (or Edit Shelves from a library's other layout) asked for something on this
    /// page before it was on screen.
    private func consumePendingAction() {
        guard commands.pendingShelfScope == scope, layouts.isReady, !model.specs.isEmpty,
              let action = commands.pendingHomeAction else { return }
        commands.pendingHomeAction = nil
        handle(action)
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
        // A poster that keeps focus a moment is likely to be played: warm its file.
        .task(id: model.focusedItem?.ratingKey) {
            guard let item = model.focusedItem else { return }
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            playback.prewarm(item)
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
            AccessibilityNotification.Announcement("Editing shelves. Arrow keys select, Option-arrow moves, Space hides.").post()
        } else {
            saveTask?.cancel()
            save()
        }
        // One transaction: the strips unfold into the new order (matched geometry), no reload.
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : Theme.Motion.object) {
            if !on { model.apply(editSpecs) }
            editing = on
        }
        if !on { updateRoom() }
        commands.isEditingShelves = on
    }

    /// Saves the layout; a layout equal to the defaults stays "not customised", so Plex's own
    /// rows keep following the server.
    private func save() {
        let defaults = model.defaults(for: scope)
        if editSpecs == defaults {
            guard layouts.saved(scope) != nil else { return }
            loadedSaved = .some(nil)
            layouts.reset(scope)
        } else if layouts.saved(scope) != editSpecs {
            loadedSaved = .some(editSpecs)
            layouts.set(scope, editSpecs)
        }
    }

    // MARK: Loading

    private func load() async {
        guard let client = session.client else { return }
        // At launch the server, then the index, then its first sync each change the task id
        // within a fraction of a second; once shelves are on screen, let those settle into
        // one reload instead of three rounds of hub requests.
        if !model.shelves.isEmpty {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
        }
        let saved = layouts.saved(scope)
        await model.load(scope: scope, saved: saved, client: client, index: library.index, stops: library.recentStops)
        // A newer load (the layout changed) supersedes this one.
        guard !Task.isCancelled else { return }
        loadedSaved = .some(saved)
        #if DEBUG
        PerfLog.mark("home loaded (\(model.shelves.count) shelves)")
        print("HOME row0 \(model.shelves.first?.items.prefix(5).map(\.ratingKey) ?? []) stops \(library.recentStops.map { "\($0.item.ratingKey)@\(Int($0.time))\($0.finished ? "✓" : "")" })")
        #endif
        if editing { return }
        if !editing { updateRoom() }
        consumePendingAction()
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
            // -HomeKeyScript "down,opt+down,space": key events into the editor after 2 s.
            if let script = UserDefaults.standard.string(forKey: "HomeKeyScript") {
                try? await Task.sleep(for: .seconds(2))
                for token in script.split(separator: ",") {
                    DebugKeys.post(String(token))
                    try? await Task.sleep(for: .milliseconds(400))
                }
            }
            if UserDefaults.standard.bool(forKey: "CollectionPicker") {
                try? await Task.sleep(for: .milliseconds(600))
                pickingCollection = true
            }
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
                if let url = session.backdropURL(library.backdropPath(for: item), pixelWidth: width) {
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
    let editing: Bool
    func body(content: Content) -> some View {
        if isMain { content.navigationTitle("Home").navigationSubtitle(editing ? "Editing shelves" : "") } else { content }
    }
}

/// Edit Shelves, or the prominent Done while editing (Home and library toolbars alike).
struct EditShelvesButton: View {
    let editing: Bool
    let action: () -> Void
    var body: some View {
        if editing {
            Button("Done", action: action)
                .buttonStyle(.borderedProminent)
                .tint(Theme.lilac)
                .help("Finish editing shelves (⌘E)")
        } else {
            Button("Edit Shelves", action: action)
                .help("Reorder, hide and add shelves (⌘E)")
        }
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
