import SwiftUI
import MezzanineKit

enum SidebarItem: Hashable {
    case home
    case library(String)
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
    @Environment(\.colorSchemeContrast) private var contrast
    @FocusState private var searchFocused: Bool
    @FocusState private var contentFocused: Bool
    @State private var sectionsError: String?

    var body: some View {
        Group {
            if session.phase == .ready {
                split
                    .disabled(playback.isPresented)
                    .accessibilityHidden(playback.isPresented)
            } else {
                SignInView()
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
        // Theme reads Increase Contrast at render time; rebuild when it changes.
        .id(contrast)
        .frame(minWidth: 900, minHeight: 600)
        .containerBackground(Theme.graphite, for: .window)
        .preferredColorScheme(.dark)
        .onChange(of: session.phase, initial: true) { _, phase in commands.isSignedIn = phase == .ready }
        .onChange(of: playback.isPresented, initial: true) { _, presented in
            commands.isPlayerOpen = presented
            if !presented { contentFocused = true }
        }
    }

    private var split: some View {
        @Bindable var commands = commands
        return NavigationSplitView {
            List(selection: $commands.selection) {
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
            }
            .onKeyPress(.rightArrow) { contentFocused = true; return .handled }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } detail: {
            Group {
                if !commands.query.trimmingCharacters(in: .whitespaces).isEmpty {
                    SearchView(query: commands.query, contentFocus: $contentFocused)
                } else {
                    switch commands.selection {
                    case .library(let key):
                        if let section = commands.sections.first(where: { $0.key == key }) {
                            LibraryView(section: section, contentFocus: $contentFocused).id(key)
                        }
                    default:
                        HomeView(contentFocus: $contentFocused)
                    }
                }
            }
            .background {
                RoomLight(palette: playback.roomPalette, intensity: playback.isPresented ? 0 : 1)
            }
        }
        .searchable(text: $commands.query, placement: .toolbar, prompt: "Titles, people, collections")
        .searchFocused($searchFocused)
        .onChange(of: searchFocused) { _, focused in commands.isSearchFieldFocused = focused }
        .onChange(of: commands.searchRequests) { _, _ in searchFocused = true }
        .onChange(of: commands.contentFocusRequests) { _, _ in contentFocused = true }
        .task(id: session.currentServer?.clientIdentifier) {
            await loadSections()
            #if DEBUG
            // -MezzanineSection "TV Shows" opens a library at launch (screenshots, manual tests).
            if let title = UserDefaults.standard.string(forKey: "MezzanineSection"),
               let match = commands.sections.first(where: { $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame }) {
                commands.selection = .library(match.key)
            }
            #endif
            contentFocused = true
        }
    }

    private func loadSections() async {
        guard let client = session.client else { return }
        do {
            let sections = try await client.sections()
            // Music stays with Plexamp; photos aren't part of Mezzanine.
            commands.sections = sections.filter { $0.kind == .movie || $0.kind == .show }
            sectionsError = nil
        } catch {
            sectionsError = (error as? PlexError)?.userMessage ?? "\(error)"
        }
    }

    private func icon(for section: PlexLibrarySection) -> String {
        if section.isPersonalMedia { return "folder" }
        return section.kind == .show ? "tv" : "film"
    }
}

/// Signed out or connecting. The full onboarding flow is its own surface (M1).
struct SignInView: View {
    @Environment(SessionStore.self) private var session

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoomLight(palette: .dark)
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                Text("MEZZANINE")
                    .font(TitleFont.font(size: 72))
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                Group {
                    switch session.phase {
                    case .signedOut:
                        Text("Sign in with your Plex account to see your libraries.")
                        Button("Sign In with Plex") { session.signIn() }
                            .buttonStyle(PrimaryButtonStyle())
                            .keyboardShortcut(.defaultAction)
                    case .awaitingApproval(let code):
                        Text("Approve Mezzanine in your browser. Code \(code).")
                        Button("Cancel") { session.cancelSignIn() }
                            .buttonStyle(SecondaryButtonStyle())
                            .keyboardShortcut(.cancelAction)
                    case .connecting:
                        HStack(spacing: Theme.Space.s) {
                            ProgressView().controlSize(.small).accessibilityLabel("Connecting")
                            Text("Connecting to your server…")
                        }
                    case .failed(let message):
                        Text(message)
                        Button("Try Again") { Task { await session.restore() } }
                            .buttonStyle(PrimaryButtonStyle())
                            .keyboardShortcut(.defaultAction)
                    case .ready:
                        EmptyView()
                    }
                }
                .font(Theme.Typeface.body)
                .foregroundStyle(Theme.inkSecondary)
            }
            .padding(Theme.Space.gutter)
            .padding(.bottom, Theme.Space.xxl)
        }
    }
}
