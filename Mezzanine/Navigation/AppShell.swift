import SwiftUI
import MezzanineKit

enum SidebarItem: Hashable {
    case home
    case library(String)
    case downloads
}

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
    @Environment(HomeLayoutStore.self) private var layouts
    @Environment(DownloadStore.self) private var downloads
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
        .onChange(of: isOffline, initial: true) { _, offline in
            guard offline else { return }
            commands.selection = .downloads
            AccessibilityNotification.Announcement("Offline. Showing downloads.").post()
        }
        .onChange(of: playback.ownsWindow, initial: true) { _, owns in
            commands.isPlayerOpen = owns
            if !owns { contentFocused = true }
            notifier.openPending()
        }
        .onChange(of: library.index == nil) { _, missing in if !missing { notifier.openPending() } }
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
            List(selection: $commands.selection) {
                if isOffline {
                    // Offline: only what's on this Mac.
                    Label("Downloads", systemImage: "arrow.down.circle").tag(SidebarItem.downloads)
                    Section {
                        Text("Plex can’t be reached. Downloads still play.")
                            .font(Theme.Typeface.cardMeta).foregroundStyle(Theme.inkSecondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Try Again") { Task { await session.restore() } }
                    } header: {
                        Text("Offline")
                    }
                } else {
                    Label("Home", systemImage: "house").tag(SidebarItem.home)
                    Section("Libraries") {
                        ForEach(commands.sections) { section in
                            Label(section.title, systemImage: icon(for: section)).tag(SidebarItem.library(section.key))
                        }
                        if let sectionsError {
                            Button("Libraries didn’t load. Try Again") { Task { await loadSections() } }
                                .help(sectionsError)
                        }
                    }
                    Section("On This Mac") {
                        Label("Downloads", systemImage: "arrow.down.circle").tag(SidebarItem.downloads)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if session.homeUsers.count > 1 { SidebarProfileButton() }
            }
            .focused($sidebarFocused)
            .onKeyPress(.rightArrow) { contentFocused = true; return .handled }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } detail: {
            NavigationStack(path: $commands.path) {
                sectionRoot
                    // Quick Open is modal: VoiceOver and Tab stay inside it.
                    .accessibilityHidden(commands.isQuickOpenShown)
                    .disabled(commands.isQuickOpenShown)
                    .modifier(PagePanels(onTop: commands.path.isEmpty, showsSearchPanel: showsSearchPanel))
                    .navigationDestination(for: DetailRoute.self) { route in
                        DetailView(route: route, contentFocus: $contentFocused)
                            .background { RoomLight(palette: playback.roomPalette, intensity: playback.ownsWindow ? 0 : 1) }
                            .modifier(PagePanels(onTop: commands.path.last == route, showsSearchPanel: showsSearchPanel))
                    }
            }
            .background {
                RoomLight(palette: playback.roomPalette, intensity: playback.ownsWindow ? 0 : 1)
            }
        }
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
        .onChange(of: commands.downloadRemoval == nil) { _, closed in commands.isModalShown = !closed }
        .onChange(of: commands.artworkRequest == nil) { _, closed in commands.isModalShown = !closed }
        // Offline there's nothing to search: the field goes rather than sitting dead.
        .modifier(LibrarySearch(enabled: !isOffline, query: $commands.query))
        .searchFocused($searchFocused)
        .onChange(of: searchFocused) { _, focused in commands.isSearchFieldFocused = focused }
        .onChange(of: commands.searchRequests) { _, _ in searchFocused = true }
        .onChange(of: commands.contentFocusRequests) { _, _ in contentFocused = true }
        .onChange(of: commands.sidebarFocusRequests) { _, _ in sidebarFocused = true }
        .task(id: session.currentServer?.clientIdentifier) {
            contentFocused = true
            #if DEBUG
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
                    print("AUTOPLAY route=\(d.route) audio=\(d.audioDelivery) adec=\(d.audioDecoder ?? "-") shaping=\(d.audioShaping) profile=\(playback.player.audioProfile)")
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
            #endif
        }
    }

    /// Typing in the toolbar field opens the results panel over the page (not on the full
    /// results grid, over Quick Open, the player, or after Esc for this query).
    private var showsSearchPanel: Bool {
        let q = commands.query.trimmingCharacters(in: .whitespaces)
        return !q.isEmpty && !commands.showsAllResults && commands.searchPanelDismissedFor != commands.query
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
            default:
                HomeView(contentFocus: $contentFocused)
            }
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
            if case .library(let key) = commands.selection, !commands.sections.contains(where: { $0.key == key }) {
                commands.selection = .home
            }
            if let server = session.currentServer {
                library.connect(client: client, serverID: server.clientIdentifier,
                                userID: session.account?.uuid ?? "owner", sections: commands.sections)
                layouts.use(serverID: server.clientIdentifier, userID: session.account?.uuid ?? "owner")
                commands.layoutsReady = true
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

    private func icon(for section: PlexLibrarySection) -> String {
        if section.isPersonalMedia { return "folder" }
        return section.kind == .show ? "tv" : "film"
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
