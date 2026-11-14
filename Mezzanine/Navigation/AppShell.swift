import SwiftUI
import MezzanineKit

enum SidebarItem: Hashable {
    case home
    case library(String)
}

/// The window: sidebar (system glass), the room, and the player stage above both.
struct AppShell: View {
    @Environment(SessionStore.self) private var session
    @Environment(PlaybackCoordinator.self) private var playback
    @State private var selection: SidebarItem? = .home
    @State private var sections: [PlexLibrarySection] = []

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
        .tint(Theme.lilac)
    }

    private var split: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Home", systemImage: "house").tag(SidebarItem.home)
                Section("Libraries") {
                    ForEach(videoSections) { section in
                        Label(section.title, systemImage: icon(for: section)).tag(SidebarItem.library(section.key))
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } detail: {
            Group {
                switch selection {
                case .library(let key):
                    if let section = sections.first(where: { $0.key == key }) {
                        LibraryView(section: section).id(key)
                    }
                default:
                    HomeView()
                }
            }
            .background {
                RoomLight(palette: playback.roomPalette, intensity: playback.isPresented ? 0 : 1)
            }
        }
        .task(id: session.currentServer?.clientIdentifier) {
            guard let client = session.client else { return }
            sections = (try? await client.sections()) ?? []
            #if DEBUG
            // -MezzanineSection "TV Shows" opens a library at launch (screenshots, manual tests).
            if let title = UserDefaults.standard.string(forKey: "MezzanineSection"),
               let match = sections.first(where: { $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame }) {
                selection = .library(match.key)
            }
            #endif
        }
    }

    /// Music stays with Plexamp; photos aren't part of Mezzanine.
    private var videoSections: [PlexLibrarySection] {
        sections.filter { $0.kind == .movie || $0.kind == .show }
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
