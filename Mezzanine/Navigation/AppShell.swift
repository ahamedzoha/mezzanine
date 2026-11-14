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
/// the user is walking the sidebar.
struct AppShell: View {
    @Environment(SessionStore.self) private var session
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(AppCommandCenter.self) private var commands
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @FocusState private var contentFocused: Bool

    var body: some View {
        Group {
            if session.phase == .ready {
                split
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
        .containerBackground(Theme.graphite, for: .window)
        .preferredColorScheme(.dark)
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
                }
            }
            .onKeyPress(.rightArrow) { contentFocused = true; return .handled }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } detail: {
            Group {
                if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    SearchView(query: query)
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
        .searchable(text: $query, placement: .toolbar, prompt: "Titles, people, collections")
        .searchFocused($searchFocused)
        .onChange(of: commands.searchRequests) { _, _ in searchFocused = true }
        .onChange(of: commands.contentFocusRequests) { _, _ in contentFocused = true }
        .onChange(of: playback.isPresented) { _, presented in
            if !presented { contentFocused = true }
        }
        .task(id: session.currentServer?.clientIdentifier) {
            guard let client = session.client else { return }
            let sections = (try? await client.sections()) ?? []
            // Music stays with Plexamp; photos aren't part of Mezzanine.
            commands.sections = sections.filter { $0.kind == .movie || $0.kind == .show }
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
                Group {
                    switch session.phase {
                    case .signedOut:
                        Text("Sign in with your Plex account to see your libraries.")
                        Button("Sign In with Plex") { session.signIn() }.buttonStyle(PrimaryButtonStyle())
                    case .awaitingApproval(let code):
                        Text("Approve Mezzanine in your browser. Code \(code).")
                        Button("Cancel") { session.cancelSignIn() }.buttonStyle(SecondaryButtonStyle())
                    case .connecting:
                        HStack(spacing: Theme.Space.s) { ProgressView().controlSize(.small); Text("Connecting to your server…") }
                    case .failed(let message):
                        Text(message)
                        Button("Try Again") { Task { await session.restore() } }.buttonStyle(PrimaryButtonStyle())
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
