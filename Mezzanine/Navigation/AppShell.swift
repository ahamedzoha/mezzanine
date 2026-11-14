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
                    .disabled(playback.isPresented)
                    .accessibilityHidden(playback.isPresented)
            } else {
                OnboardingView().navigationTitle("")
            }
        }
        .overlay {
            if let item = playback.item {
                GeometryReader { geo in
                    PlayerStage(item: item, origin: playback.origin, window: geo.size)
                }
                .ignoresSafeArea()
                .transition(.opacity)
            }
        }
        // While a film plays the window is only the film: no toolbar, no toolbar
        // material, no title (AppKit draws those above SwiftUI content).
        .toolbarVisibility(playback.isPresented ? .hidden : .visible, for: .windowToolbar)
        .toolbarBackgroundVisibility(chromeHidden ? .hidden : .automatic, for: .windowToolbar)
        .background(WindowChrome(hidden: chromeHidden, hidesToolbar: playback.isPresented))
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
        .task(id: "\(session.currentServer?.clientIdentifier ?? "")|\(session.account?.uuid ?? "")") { await loadSections() }
        .onChange(of: isOffline, initial: true) { _, offline in if offline { commands.selection = .downloads } }
        .onChange(of: playback.isPresented, initial: true) { _, presented in
            commands.isPlayerOpen = presented
            if !presented { contentFocused = true }
        }
    }

    /// The film, or onboarding, owns the whole window.
    private var chromeHidden: Bool { playback.isPresented || !showsLibrary }

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
                    .navigationDestination(for: DetailRoute.self) { route in
                        DetailView(route: route, contentFocus: $contentFocused)
                            .background { RoomLight(palette: playback.roomPalette, intensity: playback.isPresented ? 0 : 1) }
                    }
            }
            .background {
                RoomLight(palette: playback.roomPalette, intensity: playback.isPresented ? 0 : 1)
            }
            .overlay(alignment: .topLeading) {
                if commands.isQuickOpenShown && !playback.isPresented {
                    QuickOpen().transition(.opacity)
                }
            }
            .animation(Theme.Motion.quick, value: commands.isQuickOpenShown)
        }
        .sheet(item: $commands.artworkRequest) { request in
            ArtworkPicker(request: request)
        }
        .sheet(item: $commands.pinRequest) { user in
            ProfilePINSheet(user: user)
        }
        .onChange(of: commands.artworkRequest == nil) { _, closed in commands.isModalShown = !closed }
        .searchable(text: $commands.query, placement: .toolbar, prompt: "Titles, people, collections")
        .searchFocused($searchFocused)
        .onChange(of: searchFocused) { _, focused in commands.isSearchFieldFocused = focused }
        .onChange(of: commands.searchRequests) { _, _ in searchFocused = true }
        .onChange(of: commands.contentFocusRequests) { _, _ in contentFocused = true }
        .onChange(of: commands.sidebarFocusRequests) { _, _ in sidebarFocused = true }
        .task(id: session.currentServer?.clientIdentifier) {
            contentFocused = true
            #if DEBUG
            // -MezzanineAutoplay <ratingKey> starts a title at launch (player tests).
            if let key = UserDefaults.standard.string(forKey: "MezzanineAutoplay"), let client = session.client,
               let item = try? await client.metadata(key) {
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

    /// The current section's own page (search results while a query is typed).
    @ViewBuilder private var sectionRoot: some View {
        if !commands.query.trimmingCharacters(in: .whitespaces).isEmpty {
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
            if let server = session.currentServer {
                library.connect(client: client, serverID: server.clientIdentifier,
                                userID: session.account?.uuid ?? "owner", sections: commands.sections)
                layouts.use(serverID: server.clientIdentifier, userID: session.account?.uuid ?? "owner")
                commands.layoutsReady = true
                downloads.use(client: client, images: session.images, serverID: server.clientIdentifier,
                              userID: session.account?.uuid ?? "owner")
                downloads.applyKeepRules()
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
