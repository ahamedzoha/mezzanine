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
            if selection != oldValue { query = ""; path = [] }
            UserDefaults.standard.set(selection.map(Self.storageKey), forKey: "lastSidebarItem")
        }
    }

    /// The section open when the app last quit (title pages and the player aren't restored).
    /// Off under `-ApplePersistenceIgnoreState YES`, as every test run launches.
    private static var restoredSelection: SidebarItem? {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "ApplePersistenceIgnoreState"), let raw = defaults.string(forKey: "lastSidebarItem") else { return .home }
        if raw == "downloads" { return .downloads }
        if raw.hasPrefix("library:") { return .library(String(raw.dropFirst("library:".count))) }
        return .home
    }

    private static func storageKey(_ item: SidebarItem) -> String {
        switch item {
        case .home: "home"
        case .downloads: "downloads"
        case .library(let key): "library:\(key)"
        }
    }

    /// The main window is key: bare-letter player shortcuts only act then, so typing in
    /// Settings or another window never pauses or mutes the film.
    var mainWindowIsKey = true
    /// Home's summary panel is open (View ▸ Show/Hide Details).
    var detailsShown = false
    /// Detail pages pushed over the current section.
    var path: [DetailRoute] = [] {
        didSet { recordForward(from: oldValue) }
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
    var isLibraryVisible: Bool {
        if case .library = selection, query.isEmpty { return true }
        return false
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
    enum PlayerAction: Equatable { case key(PlayerKey), speed(Double), jump(Int), snapshot, close }
    // Player state the Playback menu enables and checks items from.
    var hasActiveMarker = false
    var hasNextEpisode = false
    var hasPreviousEpisode = false
    var canPictureInPicture = false
    var playbackRate: Double = 1
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
        let key = item.kind == .episode ? (item.grandparentRatingKey ?? item.ratingKey) : item.ratingKey
        guard path.last?.ratingKey != key else { return }
        path.append(DetailRoute(ratingKey: key))
        focusContent()
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
        CommandGroup(after: .appSettings) {
            Menu("Switch Profile") { ProfileMenuItems(session: session, commands: center) }
                .disabled(center.isPlayerOpen || center.isModalShown)
        }
        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") { openWindow(id: "shortcuts") }
                .keyboardShortcut("/", modifiers: .command)
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
            Button("Downloads") { center.go(to: .downloads) }
                .keyboardShortcut("l", modifiers: [.command, .option])
                .disabled(center.isPlayerOpen)
            ForEach(Array(center.sections.prefix(8).enumerated()), id: \.element.key) { index, section in
                Button(section.title) { center.go(to: .library(section.key)) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 2))), modifiers: .command)
                    .disabled(center.isPlayerOpen)
            }
        }
        CommandMenu("Playback") {
            if !center.isPlayerOpen {
                Button("Play") { center.playFocused() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!center.hasFocusedTitle || !center.isSignedIn || center.isBlocked || center.isEditingShelves)
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
                Divider()
                Menu("Audio and Subtitles") {
                    item(.cycleAudio)
                    item(.cycleSubtitles)
                    item(.subtitleOptions)
                    item(.findSubtitles)
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
                item(.fullScreen)
                item(.pictureInPicture, disabled: !center.canPictureInPicture)
                item(.options)
                toggle(.stats, isOn: center.statsVisible)
                Button("Take Snapshot") { center.player(.snapshot) }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Button("Close Player") { center.player(.close) }
                    .keyboardShortcut(playerKeys ? KeyboardShortcut(.escape, modifiers: []) : nil)
            }
            .disabled(!center.isPlayerOpen)
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
