import SwiftUI
import MezzanineKit

/// What the menu bar can ask the window to do, and what the window tells the
/// menu bar (so items enable only when they can act). Every keyboard shortcut
/// in Mezzanine has a menu item here (HIG); single-key aliases handled by the
/// views (J/K/L, arrows) are listed in the same menus.
@MainActor
@Observable
final class AppCommandCenter {
    /// Video libraries, for the Go menu (⌘2…⌘9).
    var sections: [PlexLibrarySection] = []
    var selection: SidebarItem? = AppCommandCenter.restoredSelection {
        didSet {
            if selection != oldValue {
                query = ""
                path = []
                // The page that had a title in hand is going; the next one reports its own.
                focusedItem = nil
                detailFocusedItem = nil
                hasFocusedTitle = false
            }
            UserDefaults.standard.set(selection?.storageKey, forKey: "lastSidebarItem")
        }
    }

    /// The section open when the app last quit (title pages and the player aren't restored).
    /// Off under `-ApplePersistenceIgnoreState YES`, as every test run launches.
    private static var restoredSelection: SidebarItem? {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "ApplePersistenceIgnoreState"), let raw = defaults.string(forKey: "lastSidebarItem") else { return .home }
        return SidebarItem(storageKey: raw) ?? .home
    }

    /// The activity popover is open (View ▸ Activity).
    var isActivityShown = false
    private(set) var surpriseRequests = 0
    func surprise() { surpriseRequests += 1 }

    // MARK: Recent searches (per server and profile)

    private(set) var recentSearches: [String] = []
    /// The search field is focused and empty: the panel lists recent searches.
    var recentsShown = false
    @ObservationIgnored private var recentsKey: String?

    func useRecents(_ key: String) {
        recentsKey = "recentSearches.v1.\(key)"
        recentSearches = UserDefaults.standard.stringArray(forKey: recentsKey!) ?? []
    }

    func recordSearch(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return }
        setRecents(Array(([q] + recentSearches.filter { $0.localizedCaseInsensitiveCompare(q) != .orderedSame }).prefix(8)))
    }

    func clearRecentSearches() {
        setRecents([])
        recentsShown = false
        AccessibilityNotification.Announcement("Recent searches cleared").post()
    }

    private func setRecents(_ list: [String]) {
        guard let recentsKey else { return }
        recentSearches = list
        UserDefaults.standard.set(list, forKey: recentsKey)
    }

    /// The main window is key: bare-letter player shortcuts only act then, so typing in
    /// Settings or another window never pauses or mutes the film.
    var mainWindowIsKey = true
    /// A film plays in the corner tile while browsing.
    var hasMiniPlayer = false
    /// Cast devices on the network (id, name) and the one the film is on, for Playback ▸ Play On.
    var castTargets: [(id: String, name: String)] = []
    var castingTo: String?
    /// Home's summary panel is open (View ▸ Show/Hide Details).
    var detailsShown = false
    /// Detail pages pushed over the current section.
    var path: [DetailRoute] = [] {
        didSet {
            recordForward(from: oldValue)
            // Its button is rebuilt with the page's toolbar.
            if path != oldValue { isActivityShown = false }
        }
    }
    /// Pages left by Back (⌘[ or the toolbar), most recent last, for Forward (⌘]).
    private(set) var forwardStack: [DetailRoute] = []
    @ObservationIgnored private var steppingForward = false
    /// Toolbar search text. Choosing a sidebar item or a Go item clears it.
    var query = "" {
        didSet {
            if query.trimmingCharacters(in: .whitespaces).isEmpty { showsAllResults = false; searchPanelDismissedFor = nil }
        }
    }
    /// The full results grid replaces the page (See all in the search panel); otherwise typing
    /// only opens the panel and the page stays.
    var showsAllResults = false
    /// The query the panel was closed for (Esc or a click outside); typing more reopens it.
    var searchPanelDismissedFor: String?

    // State reported by the window.
    var isSignedIn = false
    var isPlayerOpen = false
    var isSearchFieldFocused = false
    /// The visible content has a focused title that Play would start.
    var hasFocusedTitle = false
    /// That title, and the title or episode in hand on an open title page (the Item menu).
    var focusedItem: PlexMetadata?
    var detailFocusedItem: PlexMetadata?
    /// What the Item menu acts on.
    var actionItem: PlexMetadata? { isTitlePage ? detailFocusedItem : focusedItem }
    /// A title's page (or a pushed collection) is on top, pushed or opened from Continue.
    var isTitlePage: Bool {
        if case .title = selection { return true }
        return !path.isEmpty
    }
    /// The profile in use has a watchlist.
    var hasWatchlist = false
    /// The index can answer Surprise Me.
    var canSurprise = false

    /// The main Home's All / Films / Shows switch.
    var homeKind = HomeKind(rawValue: UserDefaults.standard.string(forKey: "homeKind") ?? "") ?? .all {
        didSet { UserDefaults.standard.set(homeKind.rawValue, forKey: "homeKind") }
    }
    var isLibraryVisible: Bool {
        guard query.isEmpty else { return false }
        switch selection {
        case .library: return true
        case .slice(_, let slice): return slice != .collections
        default: return false
        }
    }
    var isHomeVisible: Bool { selection == .home && query.isEmpty }

    // Requests from the menu bar; views observe the counters.
    private(set) var searchRequests = 0
    private(set) var densitySteps: (count: Int, delta: Double) = (0, 0)
    private(set) var contentFocusRequests = 0
    private(set) var playFocusedRequests = 0
    private(set) var detailsRequests = 0
    private(set) var playerRequests: (count: Int, action: PlayerAction) = (0, .key(.playPause))
    private(set) var sidebarFocusRequests = 0
    private(set) var enclosingFolderRequests = 0
    /// View ▸ Layout / Sort By, applied by the visible library.
    private(set) var layoutRequest: (count: Int, layout: String) = (0, "")
    private(set) var sortRequest: (count: Int, sort: String) = (0, "")
    /// The visible library's current layout and sort (for menu checkmarks).
    var currentLayout: String?
    var currentSort: String?
    var isFolderBrowserVisible = false

    /// A Playback menu item or key: a rebindable player key, or one of the fixed ones.
    enum PlayerAction: Equatable { case key(PlayerKey), speed(Double), jump(Int), picture(String), cast(String?), sleep(SleepTimer.Choice), snapshot, close }
    // Player state the Playback menu enables and checks items from.
    var hasActiveMarker = false
    var hasNextEpisode = false
    var hasPreviousEpisode = false
    var canPictureInPicture = false
    var playbackRate: Double = 1
    /// The sleep timer's choice, and whether an episode is playing (its end, or a film's).
    var sleepChoice: SleepTimer.Choice = .off
    var playsEpisode = false
    /// The picture mode in force (Fit, Fill, Zoom), for the menu's checkmarks.
    var pictureMode = "fit"
    var isMuted = false
    var statsVisible = false
    /// On-device subtitles (M12), mirrored from the player for the menu's checkmarks.
    var generatingSubtitles = false
    var translatingSubtitles = false
    var matchingSubtitleTiming = false
    var canMatchSubtitleTiming = false
    /// "English": Translate's target, named in the menu.
    var subtitleTranslateTarget = "English"

    // Shelves (Home, or a library's Shelves layout).
    /// Shelf pages on screen (a counter: the next page can appear before the last disappears).
    var shelvesPages = 0
    var isShelvesPageVisible: Bool { shelvesPages > 0 && layoutsReady }
    /// The layout store knows the server and profile (nothing can be saved before).
    var layoutsReady = false
    var isEditingShelves = false
    /// A sheet, alert or confirmation is up over a shelf page: menu shortcuts stand down.
    var isModalShown = false
    /// ⌘K.
    var isQuickOpenShown = false
    /// Something shortcuts must not reach underneath.
    var isBlocked: Bool { isModalShown || isQuickOpenShown || isPlayerOpen }

    enum ShelfAction: Equatable {
        case toggleEditing, startEditing, newSmartShelf, addCollection, moveUp, moveDown, toggleHidden, rename, remove
    }
    private(set) var shelfRequests: (count: Int, action: ShelfAction) = (0, .toggleEditing)
    /// An action for Home that waits until Home is on screen (Quick Open from another page).
    var pendingHomeAction: ShelfAction?
    /// Which shelves page `pendingHomeAction` is for: Home, or a library's Shelves layout.
    var pendingShelfScope = HomeLayout.mainScope
    /// The library on screen (its key), for Edit Shelves from another layout.
    var currentLibraryKey: String?

    func shelf(_ action: ShelfAction) { shelfRequests = (shelfRequests.count + 1, action) }
    func toggleEditShelves() { shelf(.toggleEditing) }

    /// A library in Posters, Wide or List can't edit shelves yet: Edit Shelves switches it to
    /// Shelves and opens the editor there.
    var canSwitchToLibraryShelves: Bool {
        currentLibraryKey != nil && currentLayout != LibraryLayout.shelves.rawValue
            && availableLayouts.contains(LibraryLayout.shelves.rawValue)
    }

    func editShelves() {
        if isShelvesPageVisible { toggleEditShelves(); return }
        guard canSwitchToLibraryShelves, let key = currentLibraryKey else { return }
        pendingShelfScope = key
        pendingHomeAction = .startEditing
        setLayout(LibraryLayout.shelves.rawValue)
    }

    /// Choose Poster / Choose Background, presented by the window.
    var artworkRequest: ArtworkRequest?
    /// The movie, show or season whose page is showing (for View ▸ Choose Poster…).
    var currentDetailItem: PlexMetadata?
    /// A download removal waiting for confirmation (asked once, app-wide).
    var downloadRemoval: DownloadRemoval?
    /// The title chosen on the Downloads page (File ▸ Remove Download acts on it).
    var downloadsSelection: String?
    /// A protected Plex Home profile waiting for its PIN.
    var pinRequest: PlexHomeUser?

    /// The visible library's layouts (the Layout menu enables only these).
    var availableLayouts: [String] = []

    func requestSearch() { searchRequests += 1 }
    func focusContent() { contentFocusRequests += 1 }
    func stepDensity(_ delta: Double) { densitySteps = (densitySteps.count + 1, delta) }
    func playFocused() { playFocusedRequests += 1 }
    func toggleDetails() { detailsRequests += 1 }
    func player(_ action: PlayerAction) { playerRequests = (playerRequests.count + 1, action) }
    func focusSidebar() { sidebarFocusRequests += 1 }
    func enclosingFolder() { enclosingFolderRequests += 1 }
    func setLayout(_ raw: String) { layoutRequest = (layoutRequest.count + 1, raw) }
    func setSort(_ raw: String) { sortRequest = (sortRequest.count + 1, raw) }

    func go(to item: SidebarItem) {
        query = ""
        selection = item
        path = []
        forwardStack = []
        focusContent()
    }

    /// Opens a title's page. Episodes open their show; seasons open as themselves.
    func open(_ item: PlexMetadata) {
        // On the watchlist but not on this server: there's no page to open.
        guard !item.isDiscoverOnly else {
            AccessibilityNotification.Announcement("Not on this server").post()
            return
        }
        open(ratingKey: item.kind == .episode ? (item.grandparentRatingKey ?? item.ratingKey) : item.ratingKey,
             isCollection: item.kind == .collection)
    }

    func open(ratingKey key: String, isCollection: Bool = false) {
        guard path.last?.ratingKey != key else { return }
        path.append(DetailRoute(ratingKey: key, isCollection: isCollection))
        focusContent()
    }

    /// The page on screen holds titles it can shuffle (a collection, a pinned shelf, the watchlist).
    var canShufflePage = false
    private(set) var pageShuffle: (count: Int, unwatchedOnly: Bool) = (0, false)
    func shufflePage(unwatchedOnly: Bool) { pageShuffle = (pageShuffle.count + 1, unwatchedOnly) }

    /// A title chosen outside the app (Spotlight, Shortcuts), waiting for the library, or for a
    /// film that owns the window to close.
    var pendingTitle: String?

    func openWhenReady(_ ratingKey: String) {
        guard isSignedIn, !isPlayerOpen else { pendingTitle = ratingKey; return }
        pendingTitle = nil
        isQuickOpenShown = false
        open(ratingKey: ratingKey)
    }

    func openPendingTitle() {
        guard let key = pendingTitle else { return }
        openWhenReady(key)
    }

    func goBack() {
        guard !path.isEmpty else { return }
        path.removeLast()
        focusContent()
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        steppingForward = true
        path.append(next)
        steppingForward = false
        focusContent()
    }

    var canGoBack: Bool { !path.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    /// Back keeps what it left for Forward; opening anything new clears it (as in Safari).
    private func recordForward(from old: [DetailRoute]) {
        guard !steppingForward, path != old else { return }
        if path.count < old.count, Array(old.prefix(path.count)) == path {
            forwardStack.append(contentsOf: old[path.count...].reversed())
        } else {
            forwardStack.removeAll()
        }
    }
}

struct MezzanineCommands: Commands {
    let center: AppCommandCenter
    let sound: SoundSettings
    let session: SessionStore
    let downloads: DownloadStore
    let updater: AppUpdater
    let actions: TitleActions
    let library: LibraryStore
    let diagnostics: Diagnostics
    let music: MusicSession

    private var downloadTitle: String {
        switch center.currentDetailItem?.kind {
        case .show: "Download Next 3 Unwatched Episodes"
        case .season: "Download Season"
        default: DownloadWords.download
        }
    }

    private var canDownload: Bool {
        guard let item = center.currentDetailItem, !center.isBlocked else { return false }
        switch item.kind {
        case .movie, .episode: return downloads.record(item.ratingKey) == nil
        case .show, .season: return true
        default: return false
        }
    }

    /// What File ▸ Remove Download acts on: the Downloads page's chosen title, else the open film.
    private var removableDownload: DownloadRemoval? {
        if center.selection == .downloads, let key = center.downloadsSelection {
            let records = downloads.visible.filter { $0.groupKey == key }
            guard let first = records.first else { return nil }
            return DownloadRemoval(ids: records.map(\.id), title: first.showTitle ?? first.title, isShow: first.showKey != nil)
        }
        if let item = center.currentDetailItem, let r = downloads.record(item.ratingKey) {
            return DownloadRemoval(ids: [r.id], title: r.title, isShow: false)
        }
        return nil
    }

    private func removeCurrentDownload() { center.downloadRemoval = removableDownload }
    @Environment(\.openWindow) private var openWindow

    private var shortcuts: PlayerShortcuts { .shared }

    /// A player key as a menu item, showing its current (rebindable) key. The key router
    /// handles the key itself first, so these never fire while typing in a field.
    /// Player keys are bare letters: they're live only while a film plays in the key window.
    private var playerKeys: Bool { center.isPlayerOpen && center.mainWindowIsKey }

    private func item(_ key: PlayerKey, title: String? = nil, disabled: Bool = false) -> some View {
        Button(title ?? key.menuTitle) { center.player(.key(key)) }
            .keyboardShortcut(playerKeys ? shortcuts.menuShortcut(key) : nil)
            .disabled(disabled)
    }

    private func toggle(_ key: PlayerKey, isOn: Bool, title: String? = nil) -> some View {
        Toggle(title ?? key.menuTitle, isOn: Binding(get: { isOn }, set: { _ in center.player(.key(key)) }))
            .keyboardShortcut(playerKeys ? shortcuts.menuShortcut(key) : nil)
    }

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            // Release builds only (a Debug build never updates itself).
            if updater.isAvailable {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheck)
            }
        }
        CommandGroup(after: .appSettings) {
            Menu("Switch Profile") { ProfileMenuItems(session: session, commands: center) }
                .disabled(center.isPlayerOpen || center.hasMiniPlayer || center.isModalShown)
        }
        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") { openWindow(id: "shortcuts") }
                .keyboardShortcut("/", modifiers: .command)
            Divider()
            Button("Save Diagnostics Report…") { diagnostics.saveReport() }
        }
        CommandGroup(after: .textEditing) {
            Button("Find…") { center.requestSearch() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(!center.isSignedIn || center.isBlocked)
        }
        CommandGroup(after: .newItem) {
            Button("New Smart Shelf…") { center.shelf(.newSmartShelf) }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(!center.isShelvesPageVisible || center.isBlocked)
            Button("Add Collection…") { center.shelf(.addCollection) }
                .disabled(!center.isShelvesPageVisible || center.isBlocked)
            Divider()
            Button(downloadTitle) {
                guard let item = center.currentDetailItem else { return }
                switch item.kind {
                case .movie, .episode: downloads.download(item)
                case .show: downloads.downloadNext(3, of: item)
                case .season: downloads.downloadSeason(item)
                default: break
                }
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(!canDownload)
            Button(DownloadWords.removeEllipsis) { removeCurrentDownload() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(removableDownload == nil || center.isBlocked)
        }
        CommandGroup(after: .toolbar) {
            Button(center.isEditingShelves ? "Done Editing Shelves" : "Edit Shelves") { center.editShelves() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(!(center.isShelvesPageVisible || center.canSwitchToLibraryShelves) || center.isBlocked)
            if center.isEditingShelves {
                Button("Move Shelf Up") { center.shelf(.moveUp) }
                    .keyboardShortcut(.upArrow, modifiers: .option)
                    .disabled(center.isBlocked)
                Button("Move Shelf Down") { center.shelf(.moveDown) }
                    .keyboardShortcut(.downArrow, modifiers: .option)
                    .disabled(center.isBlocked)
                Button("Show or Hide Shelf") { center.shelf(.toggleHidden) }
                    .disabled(center.isBlocked)
                Button("Rename Shelf…") { center.shelf(.rename) }
                    .disabled(center.isBlocked)
                Button("Remove Shelf") { center.shelf(.remove) }
                    .disabled(center.isBlocked)
            }
            Divider()
            Button("Choose Poster…") {
                if let item = center.currentDetailItem { center.artworkRequest = ArtworkRequest(item: item, kind: .poster) }
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
            .disabled(center.currentDetailItem == nil || center.isBlocked)
            Button("Choose Background…") {
                if let item = center.currentDetailItem { center.artworkRequest = ArtworkRequest(item: item, kind: .background) }
            }
            .keyboardShortcut("b", modifiers: [.command, .option])
            .disabled(center.currentDetailItem == nil || center.isBlocked)
            Divider()
            Button(center.detailsShown ? "Hide Details" : "Show Details") { center.toggleDetails() }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(!center.isHomeVisible || center.isBlocked || center.isEditingShelves)
            Picker("Show on Home", selection: Binding(get: { center.homeKind }, set: { center.homeKind = $0 })) {
                ForEach(HomeKind.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .disabled(!center.isHomeVisible || center.isBlocked || center.isEditingShelves)
            Button("Clear Recent Searches") { center.clearRecentSearches() }
                .disabled(center.recentSearches.isEmpty)
            Button(center.isActivityShown ? "Hide Activity" : "Show Activity") { center.isActivityShown.toggle() }
                .keyboardShortcut("a", modifiers: [.command, .option])
                .disabled(!center.isSignedIn || center.isBlocked)
            Button("Larger Posters") { center.stepDensity(20) }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(!center.isLibraryVisible || center.isPlayerOpen)
            Button("Smaller Posters") { center.stepDensity(-20) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(!center.isLibraryVisible || center.isPlayerOpen)
            Menu("Layout") {
                ForEach(Array(LibraryLayout.allCases.enumerated()), id: \.element) { i, layout in
                    Button(layout.label) { center.setLayout(layout.rawValue) }
                        .keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: [.control, .command])
                        .disabled(!center.availableLayouts.contains(layout.rawValue))
                }
            }
            .disabled(!center.isLibraryVisible || center.isPlayerOpen)
            Menu("Sort By") {
                ForEach(LibraryQuery.Sort.allCases, id: \.self) { sort in
                    Button(sort.label) { center.setSort(sort.rawValue) }
                }
            }
            .disabled(!center.isLibraryVisible || center.isPlayerOpen || center.isFolderBrowserVisible)
            Divider()
        }
        CommandMenu("Go") {
            Button("Quick Open…") { center.isQuickOpenShown.toggle() }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(!center.isSignedIn || center.isPlayerOpen || center.isModalShown)
            Divider()
            Button("Back") { center.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!center.canGoBack || center.isPlayerOpen)
            Button("Forward") { center.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!center.canGoForward || center.isPlayerOpen)
            Button("Enclosing Folder") { center.enclosingFolder() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(!center.isFolderBrowserVisible || center.isPlayerOpen)
            Divider()
            Button("Home") { center.go(to: .home) }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(!center.isSignedIn || center.isPlayerOpen)
            Button("Watchlist") { center.go(to: .watchlist) }
                .keyboardShortcut("w", modifiers: [.command, .control])
                .disabled(!center.isSignedIn || !center.hasWatchlist || center.isPlayerOpen)
            Button("Surprise Me") { center.surprise() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!center.isSignedIn || !center.canSurprise || center.isBlocked)
            Button("Downloads") { center.go(to: .downloads) }
                .keyboardShortcut("l", modifiers: [.command, .option])
                .disabled(center.isPlayerOpen)
            ForEach(Array(center.sections.prefix(8).enumerated()), id: \.element.key) { index, section in
                Button(section.title) { center.go(to: .library(section.key)) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 2))), modifiers: .command)
                    .disabled(center.isPlayerOpen)
            }
        }
        CommandMenu("Item") {
            if let item = center.actionItem, center.isSignedIn {
                Section(Format.displayTitle(item)) {
                    TitleMenuItems(item: item, actions: actions, library: library, commands: center,
                                   offersOpen: !center.isTitlePage)
                }
                .disabled(center.isBlocked || center.isEditingShelves)
            } else {
                Text("No Title Selected")
            }
            if center.canShufflePage {
                Divider()
                Button("Shuffle This Page") { center.shufflePage(unwatchedOnly: false) }.disabled(center.isBlocked)
                Button("Shuffle Unwatched on This Page") { center.shufflePage(unwatchedOnly: true) }.disabled(center.isBlocked)
            }
        }
        CommandMenu("Playback") {
            if !center.isPlayerOpen {
                Button("Play") { center.playFocused() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!(center.hasFocusedTitle || center.actionItem != nil) || !center.isSignedIn || center.isBlocked || center.isEditingShelves)
                Divider()
            }
            // Shown always (dimmed with no film open) so the keys can be learned from here;
            // their bare-letter shortcuts only exist while a film plays in the key window.
            Group {
                item(.playPause)
                item(.back10)
                item(.forward10)
                item(.back60)
                item(.forward60)
                item(.previousChapter)
                item(.nextChapter)
                Menu("Jump To") {
                    ForEach(0..<10, id: \.self) { d in
                        Button(d == 0 ? "Start" : "\(d * 10) %") { center.player(.jump(d)) }
                            .keyboardShortcut(playerKeys ? KeyboardShortcut(KeyEquivalent(Character(String(d))), modifiers: []) : nil)
                    }
                }
                item(.goToTime, disabled: center.hasMiniPlayer)
                item(.previousFrame)
                item(.nextFrame)
                Menu("Speed") {
                    item(.slower)
                    item(.faster)
                    Divider()
                    ForEach(PlayerSpeeds.all, id: \.self) { rate in
                        Toggle(rate == 1 ? "Normal" : String(format: "%g×", rate),
                               isOn: Binding(get: { abs(center.playbackRate - rate) < 0.01 }, set: { _ in center.player(.speed(rate)) }))
                    }
                }
                Divider()
                item(.skipMarker, disabled: !center.hasActiveMarker)
                item(.nextEpisode, disabled: !center.hasNextEpisode)
                item(.previousEpisode, disabled: !center.hasPreviousEpisode)
                item(.queue)
                Divider()
                Menu("Audio and Subtitles") {
                    item(.cycleAudio)
                    item(.cycleSubtitles)
                    item(.subtitleOptions)
                    item(.findSubtitles)
                    item(.whatDidTheySay, disabled: center.hasMiniPlayer)
                    Divider()
                    // Actions that start and stop name what they'll do; Translate is a setting.
                    item(.generateSubtitles, title: center.generatingSubtitles ? "Stop Generating Subtitles" : nil)
                    toggle(.translateSubtitles, isOn: center.translatingSubtitles,
                           title: "Translate Subtitles to \(center.subtitleTranslateTarget)")
                    Divider()
                    item(.subtitlesEarlier)
                    item(.subtitlesLater)
                    item(.matchSubtitleTiming, title: center.matchingSubtitleTiming ? "Stop Matching Subtitle Timing" : nil,
                         disabled: !center.matchingSubtitleTiming && !center.canMatchSubtitleTiming)
                }
                Menu("Sound") {
                    item(.volumeUp)
                    item(.volumeDown)
                    toggle(.mute, isOn: center.isMuted)
                    toggle(.dialogueBoost, isOn: sound.current.profile.dialogueGainDB > 0)
                    toggle(.nightMode, isOn: sound.current.profile.nightMode)
                }
                Divider()
                Menu("Sleep Timer") {
                    ForEach([SleepTimer.Choice.off, .endOfTitle] + SleepTimer.minuteChoices.map { .minutes($0) }, id: \.self) { choice in
                        Toggle(SleepWords.label(choice, episode: center.playsEpisode),
                               isOn: Binding(get: { center.sleepChoice == choice }, set: { _ in center.player(.sleep(choice)) }))
                    }
                    Divider()
                    item(.sleepTimer)
                }
                .disabled(center.castingTo != nil)
                Menu("Play On") {
                    Toggle("This Mac", isOn: Binding(get: { center.castingTo == nil }, set: { on in if on { center.player(.cast(nil)) } }))
                    ForEach(center.castTargets, id: \.id) { target in
                        Toggle(target.name, isOn: Binding(get: { center.castingTo == target.id },
                                                          set: { on in if on { center.player(.cast(target.id)) } }))
                    }
                    if center.castTargets.isEmpty { Text("No TVs found") }
                }
                item(.fullScreen)
                Button(center.hasMiniPlayer ? "Expand Player" : PlayerKey.miniPlayer.menuTitle) { center.player(.key(.miniPlayer)) }
                    // The one player key that stays live in the corner (it grows the tile back).
                    .keyboardShortcut((center.isPlayerOpen || center.hasMiniPlayer) && center.mainWindowIsKey
                                      ? shortcuts.menuShortcut(.miniPlayer) : nil)
                Menu("Picture Size") {
                    item(.pictureMode)
                    Divider()
                    ForEach(PictureMode.allCases, id: \.self) { mode in
                        Toggle(mode.label, isOn: Binding(get: { center.pictureMode == mode.rawValue },
                                                         set: { _ in center.player(.picture(mode.rawValue)) }))
                    }
                }
                item(.pictureInPicture, disabled: !center.canPictureInPicture)
                item(.options)
                toggle(.stats, isOn: center.statsVisible)
                Button("Take Snapshot") { center.player(.snapshot) }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Button("Close Player") { center.player(.close) }
                    .keyboardShortcut(playerKeys ? KeyboardShortcut(.escape, modifiers: []) : nil)
            }
            .disabled(!center.isPlayerOpen && !center.hasMiniPlayer)
            Divider()
            Menu("Sound Profile for \(sound.deviceName)") {
                Picker("Profile", selection: Binding(get: { sound.current.kind }, set: { sound.setKind($0) })) {
                    ForEach([AudioOutputKind.builtInSpeakers, .headphones, .speakers21, .airPods, .hdmi, .other], id: \.self) {
                        Text($0.label).tag($0)
                    }
                }
                .pickerStyle(.inline)
            }
        }
        CommandMenu("Controls") {
            let musicActive = music.isActive
            let shortcutsActive = !center.isPlayerOpen
            let musicShortcuts = MusicShortcuts.shared
            Group {
                Button(music.isPlaying ? "Pause" : "Play") { music.togglePlayPause() }
                    .keyboardShortcut(shortcutsActive ? musicShortcuts.menuShortcut(.playPause) : nil)
                Button("Next Track") { music.next() }
                    .keyboardShortcut(shortcutsActive ? musicShortcuts.menuShortcut(.nextTrack) : nil)
                Button("Previous Track") { music.previous() }
                    .keyboardShortcut(shortcutsActive ? musicShortcuts.menuShortcut(.previousTrack) : nil)
                Divider()
                Button("Increase Volume") { music.adjustVolume(by: 0.1) }
                    .keyboardShortcut(shortcutsActive ? musicShortcuts.menuShortcut(.volumeUp) : nil)
                Button("Decrease Volume") { music.adjustVolume(by: -0.1) }
                    .keyboardShortcut(shortcutsActive ? musicShortcuts.menuShortcut(.volumeDown) : nil)
                Divider()
                Toggle("Shuffle", isOn: Binding(get: { music.queue.isShuffled }, set: { music.setShuffle($0) }))
                    .keyboardShortcut(shortcutsActive ? musicShortcuts.menuShortcut(.shuffle) : nil)
                Button("Repeat: \(music.queue.repeatMode.rawValue.capitalized)") { music.cycleRepeat() }
                    .keyboardShortcut(shortcutsActive ? musicShortcuts.menuShortcut(.repeatMode) : nil)
                Divider()
                Menu("Rate Playing Song") {
                    ForEach([MusicKey.rate5, .rate4, .rate3, .rate2, .rate1], id: \.self) { key in
                        let stars = Int(String(key.rawValue.last ?? "0")) ?? 0
                        Button(key.menuTitle) { music.rateCurrent(stars) }
                            .keyboardShortcut(shortcutsActive ? musicShortcuts.menuShortcut(key) : nil)
                    }
                    Divider()
                    Button(MusicKey.rate0.menuTitle) { music.rateCurrent(0) }
                        .keyboardShortcut(shortcutsActive ? musicShortcuts.menuShortcut(.rate0) : nil)
                }
            }
            .disabled(!musicActive)
        }
    }
}

/// The speeds the player offers, slowest first.
enum PlayerSpeeds {
    static let all: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    static func step(from rate: Double, by delta: Int) -> Double {
        let i = all.firstIndex { abs($0 - rate) < 0.01 } ?? all.firstIndex(of: 1.0)!
        return all[min(max(0, i + delta), all.count - 1)]
    }
}
