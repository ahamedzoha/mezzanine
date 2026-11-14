import SwiftUI
import MezzanineKit
import MezzaninePlayback

@main
struct MezzanineApp: App {
    @State private var session = SessionStore()
    @State private var player = MezzaninePlayer.makeShared()

    var body: some Scene {
        Window("Mezzanine", id: "main") {
            RootView()
                .environment(session)
                .environment(player)
                .task { await session.restore() }
        }
        .defaultSize(width: 1360, height: 860)

        #if DEBUG
        Window("Lab", id: "lab") {
            LabView()
                .environment(session)
                .environment(player)
        }
        .defaultSize(width: 1200, height: 800)
        #endif
    }
}

/// Placeholder shell until the M1 design round lands.
struct RootView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 16) {
            Text("Mezzanine").font(.largeTitle.bold())
            switch session.phase {
            case .signedOut:
                Button("Sign in with Plex") { session.signIn() }
            case .awaitingApproval(let code):
                Text("Approve Mezzanine in your browser (code \(code)).")
                Button("Cancel") { session.cancelSignIn() }
            case .connecting:
                ProgressView("Connecting…")
            case .ready:
                Text("Connected to \(session.currentServer?.name ?? "server") via \(session.connection?.connection.route.rawValue ?? "?").")
            case .failed(let message):
                Text(message).foregroundStyle(.red)
                Button("Try Again") { Task { await session.restore() } }
            }
            #if DEBUG
            Button("Open Lab") { openWindow(id: "lab") }
            #endif
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if DEBUG
        .task { if LabAutoRunner.isEnabled { openWindow(id: "lab") } }
        #endif
    }
}
