import CoreSpotlight
import SwiftUI
import MezzanineKit

/// The window: sidebar (system glass), the room, and the player stage above both.
///
/// Keyboard: ⌘1…⌘9 (Go menu) switch sections and put focus in the content;
/// → in the sidebar also moves focus into the content; ⌘F searches. Content
/// takes focus once at launch and again when the player closes, never while
/// the user is walking the sidebar. While the player is open everything
/// behind it is disabled and hidden from VoiceOver.
struct AppShell: View {
    @Environment(SessionStore.self) private var session
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(AppCommandCenter.self) private var commands
    @Environment(LibraryStore.self) private var library
    @Environment(NewEpisodeNotifier.self) private var notifier
    @Environment(AppUpdater.self) private var updater
    @Environment(RemoteControl.self) private var remote
    @State private var keepAwake = KeepAwake()
    @Environment(HomeLayoutStore.self) private var layouts
    @Environment(DownloadStore.self) private var downloads
    @Environment(TitleActions.self) private var titleActions
    @Environment(PinnedStore.self) private var pins
    @Environment(WatchlistStore.self) private var watchlist
    @Environment(SpotlightIndex.self) private var spotlight
    @State private var spotlightActivity: NSUserActivity?
    @State private var watchlistAccount: String?
    @FocusState private var searchFocused: Bool
    @FocusState private var contentFocused: Bool
    @FocusState private var sidebarFocused: Bool
    @State private var sectionsError: String?
    @AppStorage("onboardingComplete") private var onboardingComplete = false

    var body: some View {
        Group {
            // Once connected, the library stays on screen through reconnects.
            if showsLibrary {
                split
                    .disabled(playback.ownsWindow)
                    .accessibilityHidden(playback.ownsWindow)
            } else {
                OnboardingView().navigationTitle("")
            }
        }
        .overlay {
            if let item = playback.item {
                if playback.isMini {
                    MiniPlayerTile(item: item)
                } else {
                    GeometryReader { geo in
                        PlayerStage(item: item, origin: playback.origin, window: geo.size)
                    }
                    .ignoresSafeArea()
                    .transition(.opacity)
                }
            }
        }
        // While a film plays the window is only the film: no toolbar, no toolbar
        // material, no title (AppKit draws those above SwiftUI content).
        .toolbarVisibility(playback.ownsWindow ? .hidden : .visible, for: .windowToolbar)
        .toolbarBackgroundVisibility(chromeHidden ? .hidden : .automatic, for: .windowToolbar)
        .background(WindowChrome(hidden: chromeHidden, hidesToolbar: playback.ownsWindow))
        .background(MainWindowWatcher(keyChanged: { commands.mainWindowIsKey = $0 },
                                      willClose: { if playback.isPresented { playback.close() } }))
        .frame(minWidth: 900, minHeight: 600)
        .alert("Couldn’t play this", isPresented: Binding(get: { playback.error != nil && !playback.isPresented },
                                                          set: { if !$0 { playback.clearError() } })) {
            Button("Try Again") { Task { await playback.retry() } }
            Button("OK", role: .cancel) { playback.clearError() }
        } message: {
            Text(playback.error ?? "")
        }
        .containerBackground(Theme.graphite, for: .window)
        .preferredColorScheme(.dark)
        .onChange(of: session.phase, initial: true) { old, phase in
            commands.isSignedIn = phase == .ready
            if phase == .ready { commands.openPendingTitle() }
            if phase == .signedOut && old != .signedOut { spotlight.clear() }
            // Only a real sign-out starts onboarding over (every launch begins signed out
            // for a moment while the session restores).
            if phase == .signedOut && old != .signedOut { onboardingComplete = false }
        }
        // Sections and the local library follow the connection, onboarding included.
        // The address is part of it: after a Wi-Fi or VPN change the library and downloads move to
        // the new client too.
        .task(id: "\(session.currentServer?.clientIdentifier ?? "")|\(session.account?.uuid ?? "")|\(session.connection?.baseURL.absoluteString ?? "")") {
            await loadSections()
        }
        // Continue Watching for the sidebar, after every change to the library or a stop.
        .task(id: "\(session.connection?.baseURL.absoluteString ?? "")|\(library.revision)") {
            // Several changes arrive together (a sync, a stop): one request once they settle.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await library.loadContinue()
        }
        .task(id: "\(library.indexKey ?? "")|\(library.revision)|\(pins.pins.map(\.id))") {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await library.loadCounts(pins: pins.pins)
        }
        .onChange(of: library.indexKey, initial: true) { _, key in if let key { commands.useRecents(key) } }
        // The watchlist follows the account, and each sync (a title on it may have arrived).
        .task(id: "\(library.indexKey ?? "")|\(library.lastSyncedAt?.timeIntervalSince1970 ?? 0)") {
            guard let key = library.indexKey, !isOffline else { return }
            let changed = key != watchlistAccount
            watchlistAccount = key
            await watchlist.load(discover: session.discover, index: library.index, changedAccount: changed)
        }
        .task(id: "\(library.indexKey ?? "")|\(library.lastSyncedAt?.timeIntervalSince1970 ?? 0)|\(spotlight.enabled)") {
            guard library.lastSyncedAt != nil else { return }
            spotlight.update(index: library.index, key: library.indexKey,
                                   sections: commands.sections.filter { !$0.isPersonalMedia }.map(\.key))
        }
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            spotlightActivity = activity
            openSpotlightTitle()
        }
        .onChange(of: library.indexKey) { _, _ in openSpotlightTitle() }
        .onChange(of: watchlist.isAvailable, initial: true) { _, available in
            commands.hasWatchlist = available
            if !available, commands.selection == .watchlist, library.lastSyncedAt != nil { commands.selection = .home }
        }
        .onChange(of: isOffline, initial: true) { _, offline in
            guard offline else { return }
            // The queue of whoever the downloads were made for.
            if let record = downloads.records.first { playback.queue.use(serverID: record.serverID, userID: record.userID) }
            commands.selection = .downloads
            AccessibilityNotification.Announcement("Offline. Showing downloads.").post()
        }
        .onChange(of: playback.ownsWindow, initial: true) { _, owns in
            commands.isPlayerOpen = owns
            if !owns { contentFocused = true }
            commands.openPendingTitle()
            notifier.openPending()
        }
        .onChange(of: playback.item == nil) { _, closed in if closed { updater.playerClosed() } }
        // The screen stays awake while a video plays (full player or the corner tile), never
        // while paused, closed or casting. Loading and seeking count as playing: letting go for a
        // rebuffer after a long idle stretch would blank the screen at once.
        .onChange(of: playback.item != nil && [.playing, .loading, .seeking].contains(playback.player.status) && !playback.cast.isCasting,
                  initial: true) { _, playing in
            keepAwake.update(playing: playing)
            #if DEBUG
            print("KEEPAWAKE \(playing ? "on" : "off")")
            #endif
        }
        // Plex apps can control Mezzanine only while signed in to a server.
        .onChange(of: session.client == nil) { _, _ in Task { await remote.apply() } }
        .onChange(of: library.index == nil) { _, missing in if !missing { notifier.openPending() } }
        .onChange(of: playback.sleep.timer.choice, initial: true) { _, choice in commands.sleepChoice = choice }
        .onChange(of: playback.item?.kind, initial: true) { _, kind in commands.playsEpisode = kind == .episode }
        .onChange(of: playback.isMini, initial: true) { _, mini in commands.hasMiniPlayer = mini }
    }

    /// The film, or onboarding, owns the whole window.
    private var chromeHidden: Bool { playback.ownsWindow || !showsLibrary }

    /// Onboarding until it's done; then the library, kept through reconnects (and the
    /// Downloads page alone when Plex can't be reached).
    private var showsLibrary: Bool {
        onboardingComplete && (session.phase == .ready || (session.client != nil && session.phase == .connecting) || isOffline)
    }

    /// Signed in before, Plex unreachable now, and something downloaded to watch.
    private var isOffline: Bool {
        guard onboardingComplete, session.client == nil, !downloads.records.isEmpty else { return false }
        if case .failed = session.phase { return true }
        return false
    }

    private var split: some View {
        @Bindable var commands = commands
        return NavigationSplitView {
            Sidebar(isOffline: isOffline, sectionsError: sectionsError,
                    retrySections: { Task { await loadSections() } },
                    enterContent: { contentFocused = true })
                .focused($sidebarFocused)
        } detail: {
            detailColumn
        }
        .onChange(of: commands.surpriseRequests) { _, _ in surprise() }
        .onChange(of: canSurprise, initial: true) { _, can in commands.canSurprise = can }
        .sheet(item: $commands.artworkRequest) { request in
            ArtworkPicker(request: request)
        }
        .sheet(item: $commands.pinRequest) { user in
            ProfilePINSheet(user: user)
        }
        .confirmationDialog(commands.downloadRemoval?.question ?? "",
                            isPresented: Binding(get: { commands.downloadRemoval != nil }, set: { if !$0 { commands.downloadRemoval = nil } }),
                            presenting: commands.downloadRemoval) { removal in
            Button(removal.confirm, role: .destructive) {
                for id in removal.ids { downloads.remove(id) }
                AccessibilityNotification.Announcement("Removed. The files are in the Trash.").post()
                commands.downloadRemoval = nil
            }
            Button("Cancel", role: .cancel) { commands.downloadRemoval = nil }
        } message: { _ in
            Text("The files go to the Trash. Nothing changes on the Plex server.")
        }
        .modifier(TitleActionPrompts(actions: titleActions))
        .onChange(of: titleActions.confirmation == nil) { _, closed in commands.isModalShown = !closed }
        .onChange(of: commands.downloadRemoval == nil) { _, closed in commands.isModalShown = !closed }
        .onChange(of: commands.artworkRequest == nil) { _, closed in commands.isModalShown = !closed }
        // Offline there's nothing to search: the field goes rather than sitting dead.
        .modifier(LibrarySearch(enabled: !isOffline, query: $commands.query))
        .searchFocused($searchFocused)
        .onChange(of: searchFocused) { _, focused in searchFocusChanged(focused) }
        .onChange(of: commands.query.isEmpty) { _, empty in
            commands.recentsShown = empty && searchFocused && !commands.recentSearches.isEmpty
        }
        .onChange(of: commands.searchRequests) { _, _ in searchFocused = true }
        .onChange(of: commands.contentFocusRequests) { _, _ in contentFocused = true }
        .onChange(of: commands.sidebarFocusRequests) { _, _ in sidebarFocused = true }
        .task(id: session.currentServer?.clientIdentifier) {
            contentFocused = true
            #if DEBUG
            await launchHooks()
            #endif
        }
    }

    #if DEBUG
    /// Launch arguments for tests and captures.
    private func launchHooks() async {
        // -SidebarSelect "slice:unwatched:1" (a SidebarItem storage key) and -ActivityOpen YES: captures.
        if let raw = UserDefaults.standard.string(forKey: "SidebarSelect"), let item = SidebarItem(storageKey: raw) {
            try? await Task.sleep(for: .seconds(4))
            commands.selection = item
        }
        // -WindowSize 900x600: the window at that size (captures).
        if let size = UserDefaults.standard.string(forKey: "WindowSize")?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
            NSApp.windows.first { $0.isVisible && $0.canBecomeMain }?.setFrame(CGRect(x: 200, y: 300, width: size[0], height: size[1]), display: true)
        }
        // -SidebarKeyScript "down,right,down": keys into the sidebar, printing the selection after each.
        if let script = UserDefaults.standard.string(forKey: "SidebarKeyScript") {
            try? await Task.sleep(for: .seconds(4))
            commands.focusSidebar()
            try? await Task.sleep(for: .milliseconds(600))
            for token in script.split(separator: ",") {
                DebugKeys.post(String(token))
                try? await Task.sleep(for: .milliseconds(500))
                print("SIDEBAR \(token) -> \(commands.selection.map { "\($0)" } ?? "none") sidebarFocus=\(sidebarFocused) item=\(commands.actionItem?.title ?? "-")")
            }
            fflush(stdout)
        }
        if UserDefaults.standard.bool(forKey: "ActivityOpen") {
            try? await Task.sleep(for: .seconds(3))
            commands.isActivityShown = true
        }
        // -SelectBehindAfter 14: switches the sidebar page under the player (Downloads, then
        // back), the way a background update rebuilds the toolbar while a film plays.
        let selectAfter = UserDefaults.standard.integer(forKey: "SelectBehindAfter")
        if selectAfter > 0 {
            Task {
                try? await Task.sleep(for: .seconds(selectAfter))
                let was = commands.selection
                print("CHROME poke: select downloads"); commands.selection = .downloads
                try? await Task.sleep(for: .seconds(2))
                print("CHROME poke: select back"); commands.selection = was
            }
        }
        // -SearchQuery "south" types into the toolbar search at launch (search panel tests).
        if let q = UserDefaults.standard.string(forKey: "SearchQuery") {
            try? await Task.sleep(for: .seconds(4))
            for i in 1...q.count { commands.query = String(q.prefix(i)); try? await Task.sleep(for: .milliseconds(40)) }
        }
        // -MezzanineAutoplay <ratingKey> starts a title at launch (player tests).
        if let key = UserDefaults.standard.string(forKey: "MezzanineAutoplay"), let client = session.client,
           let item = try? await client.metadata(key) {
            // -MezzanineAutoplayDelay 5: wait first (prewarm measurements: open the page, then play).
            let delay = UserDefaults.standard.integer(forKey: "MezzanineAutoplayDelay")
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            if UserDefaults.standard.bool(forKey: "playerMuted") { playback.player.volume = VolumeLevel(percent: 0) }
            await playback.play(item, from: nil)
            Task {
                try? await Task.sleep(for: .seconds(8))
                let d = playback.player.diagnostics
                let decoder = d.audioDecoder ?? "-"
                print("AUTOPLAY route=\(d.route) audio=\(d.audioDelivery) adec=\(decoder) shaping=\(d.audioShaping) profile=\(playback.player.audioProfile)")
                fflush(stdout)
            }
            let seekTo = UserDefaults.standard.integer(forKey: "MezzanineAutoSeek")
            if seekTo > 0 { try? await Task.sleep(for: .seconds(3)); await playback.player.seek(to: Double(seekTo)) }
            // -MezzanineAutoClose <seconds> closes the player like Esc (activity tests).
            let close = UserDefaults.standard.integer(forKey: "MezzanineAutoClose")
            if close > 0 {
                try? await Task.sleep(for: .seconds(close))
                playback.close()
            }
        }
    }
    #endif

    private var detailColumn: some View {
        @Bindable var commands = commands
        return NavigationStack(path: $commands.path) { rootPage }
            .background { roomLight }
            .toolbar { ShellToolbar(shown: !isOffline, canSurprise: canSurprise) }
    }

    private var rootPage: some View {
        sectionRoot
            // Quick Open is modal: VoiceOver and Tab stay inside it.
            .accessibilityHidden(commands.isQuickOpenShown)
            .disabled(commands.isQuickOpenShown)
            .modifier(PagePanels(onTop: commands.path.isEmpty, showsSearchPanel: showsSearchPanel))
            .navigationDestination(for: DetailRoute.self) { (route: DetailRoute) in pushed(route) }
    }

    private var roomLight: some View {
        RoomLight(palette: playback.roomPalette, intensity: playback.ownsWindow ? 0 : 1)
    }

    private var canSurprise: Bool { library.index != nil && !commands.isEditingShelves }

    private func pushed(_ route: DetailRoute) -> some View {
        Group {
            if route.isCollection {
                CollectionPage(route: route, contentFocus: $contentFocused)
            } else {
                DetailView(route: route, contentFocus: $contentFocused)
            }
        }
        .background { roomLight }
        .modifier(PagePanels(onTop: commands.path.last == route, showsSearchPanel: showsSearchPanel))
    }

    private func searchFocusChanged(_ focused: Bool) {
        commands.isSearchFieldFocused = focused
        if focused {
            commands.recentsShown = commands.query.isEmpty && !commands.recentSearches.isEmpty
        } else {
            // After a click on a recent search has landed.
            Task {
                try? await Task.sleep(for: .milliseconds(250))
                if !searchFocused { commands.recentsShown = false }
            }
        }
    }

    /// Typing in the toolbar field opens the results panel over the page (not on the full
    /// results grid, over Quick Open, the player, or after Esc for this query).
    private var showsSearchPanel: Bool {
        let q = commands.query.trimmingCharacters(in: .whitespaces)
        let wanted = q.isEmpty ? commands.recentsShown : commands.searchPanelDismissedFor != commands.query
        return wanted && !commands.showsAllResults
            && !commands.isQuickOpenShown && !playback.ownsWindow
    }

    /// The current section's own page (the full search results after See all).
    @ViewBuilder private var sectionRoot: some View {
        if commands.showsAllResults && !commands.query.trimmingCharacters(in: .whitespaces).isEmpty {
            SearchView(query: commands.query, contentFocus: $contentFocused)
        } else {
            switch commands.selection {
            case .downloads:
                DownloadsView(contentFocus: $contentFocused)
            case .library(let key):
                if let section = commands.sections.first(where: { $0.key == key }) {
                    LibraryView(section: section, contentFocus: $contentFocused).id(key)
                }
            case .slice(let key, let slice):
                if let section = commands.sections.first(where: { $0.key == key }) {
                    if slice == .collections { CollectionsView(section: section, contentFocus: $contentFocused).id(key) }
                    else { LibraryView(section: section, slice: slice, contentFocus: $contentFocused).id("\(key)|\(slice.rawValue)") }
                }
            case .pinned(let id):
                if let pin = pins.pin(id) { PinnedPage(pin: pin, contentFocus: $contentFocused).id(id) }
            case .watchlist:
                WatchlistPage(contentFocus: $contentFocused)
            case .title(let key):
                DetailView(route: DetailRoute(ratingKey: key), contentFocus: $contentFocused, rootPage: true).id(key)
            default:
                HomeView(contentFocus: $contentFocused)
            }
        }
    }

    /// A Spotlight result, once the library it belongs to is open.
    private func openSpotlightTitle() {
        guard let activity = spotlightActivity, let key = library.indexKey else { return }
        spotlightActivity = nil
        if let ratingKey = SpotlightIndex.ratingKey(from: activity, key: key) { commands.openWhenReady(ratingKey) }
    }

    /// A page restored from the last launch that's gone (or another server's): Home.
    private func leaveMissingPage() {
        switch commands.selection {
        case .library(let key), .slice(let key, _):
            if !commands.sections.contains(where: { $0.key == key }) { commands.selection = .home }
        case .pinned(let id):
            if !pins.contains(id) { commands.selection = .home }
        default: break
        }
    }

    /// Opens a random unwatched title: from the library on screen, else by Home's switch.
    private func surprise() {
        var section: String?
        var kinds = commands.homeKind.kinds
        switch commands.selection {
        case .library(let key), .slice(let key, _): section = key; kinds = ["movie", "show"]
        case .home: break
        default: kinds = ["movie", "show"]
        }
        Task {
            guard let item = await library.surprise(section: section, kinds: kinds) else {
                AccessibilityNotification.Announcement("Nothing unwatched here").post()
                return
            }
            commands.open(item)
        }
    }

    private func loadSections() async {
        guard let client = session.client else { return }
        do {
            let sections = try await client.sections()
            // Music stays with Plexamp; photos aren't part of Mezzanine.
            commands.sections = sections.filter { $0.kind == .movie || $0.kind == .show }
            sectionsError = nil
            // A library restored from the last launch that's gone (or another server's): Home.
            if let server = session.currentServer {
                library.connect(client: client, serverID: server.clientIdentifier,
                                userID: session.account?.uuid ?? "owner", sections: commands.sections)
                layouts.use(serverID: server.clientIdentifier, userID: session.account?.uuid ?? "owner")
                pins.use(serverID: server.clientIdentifier, userID: session.account?.uuid ?? "owner")
                playback.queue.use(serverID: server.clientIdentifier, userID: session.account?.uuid ?? "owner")
                commands.layoutsReady = true
                leaveMissingPage()
                downloads.use(client: client, images: session.images, serverID: server.clientIdentifier,
                              userID: session.account?.uuid ?? "owner")
                downloads.applyKeepRules()
                // Back online: positions watched offline go to Plex now.
                Task { await OfflineProgress.replay(client: client, serverID: server.clientIdentifier) }
                #if DEBUG
                // -DownloadKey <ratingKey> queues a download; -OpenDownloads YES opens the page (tests).
                if let key = UserDefaults.standard.string(forKey: "DownloadKey"), let meta = try? await client.metadata(key) {
                    downloads.download(meta)
                }
                if UserDefaults.standard.bool(forKey: "OpenDownloads") { commands.selection = .downloads }
                #endif
                if session.homeUsers.isEmpty { await session.loadHomeUsers() }
            }
            #if DEBUG
            // -MezzanineSection "TV Shows" opens a library at launch (screenshots, manual tests).
            if let title = UserDefaults.standard.string(forKey: "MezzanineSection"),
               let match = commands.sections.first(where: { $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame }) {
                commands.selection = .library(match.key)
            }
            // -QuickOpenQuery "after" (or "_" for empty) opens ⌘K at launch.
            if UserDefaults.standard.string(forKey: "QuickOpenQuery") != nil {
                Task { try? await Task.sleep(for: .seconds(3)); commands.isQuickOpenShown = true }
            }
            // -MezzanineOpen <ratingKey> opens a title's page at launch.
            if let key = UserDefaults.standard.string(forKey: "MezzanineOpen") {
                commands.path = [DetailRoute(ratingKey: key)]
            }
            #endif
        } catch {
            sectionsError = (error as? PlexError)?.userMessage ?? "\(error)"
        }
    }
}

/// Quick Open (⌘K) and the search panel, hung on the page that's on top. A NavigationStack
/// draws a pushed page above anything overlaid on the stack itself, so they can't live
/// there: each page carries them, and only the top page shows them (one panel, one key
/// monitor).
private struct PagePanels: ViewModifier {
    let onTop: Bool
    let showsSearchPanel: Bool
    @Environment(AppCommandCenter.self) private var commands
    @Environment(PlaybackCoordinator.self) private var playback

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topLeading) {
                if onTop && commands.isQuickOpenShown && !playback.ownsWindow {
                    QuickOpen().transition(.opacity)
                }
            }
            .overlay(alignment: .topTrailing) {
                if onTop && showsSearchPanel { SearchPanel().transition(.opacity) }
            }
            .animation(Theme.Motion.quick, value: commands.isQuickOpenShown)
            .animation(Theme.Motion.quick, value: showsSearchPanel)
    }
}

/// Asked once, app-wide: marking a whole show or season, and a change the server refused.
private struct TitleActionPrompts: ViewModifier {
    @Bindable var actions: TitleActions

    func body(content: Content) -> some View {
        content
            .confirmationDialog(actions.confirmationTitle,
                                isPresented: Binding(get: { actions.confirmation != nil }, set: { if !$0 { actions.confirmation = nil } }),
                                titleVisibility: .visible) {
                Button(actions.confirmationButton) {
                    if let (item, watched) = actions.confirmation { Task { await actions.setWatched(item, watched) } }
                    actions.confirmation = nil
                }
                Button("Cancel", role: .cancel) { actions.confirmation = nil }
            } message: {
                Text("This changes your watch history on the server, which Plex apps, Tautulli and Trakt all read.")
            }
            .alert("Couldn’t make that change", isPresented: Binding(get: { actions.error != nil }, set: { if !$0 { actions.error = nil } })) {
                Button("OK", role: .cancel) { actions.error = nil }
            } message: { Text(actions.error ?? "") }
    }
}

/// The toolbar search field, present only when there's a library to search.
private struct LibrarySearch: ViewModifier {
    let enabled: Bool
    @Binding var query: String
    func body(content: Content) -> some View {
        if enabled {
            content.searchable(text: $query, placement: .toolbar, prompt: "Titles, people, collections")
        } else {
            content
        }
    }
}
