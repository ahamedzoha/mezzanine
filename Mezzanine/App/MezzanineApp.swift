import SwiftUI
import MezzanineKit
import MezzaninePlayback

@main
struct MezzanineApp: App {
    @State private var session: SessionStore
    @State private var player: MezzaninePlayer
    @State private var playback: PlaybackCoordinator
    @State private var commands = AppCommandCenter()

    init() {
        TitleFont.register()
        let session = SessionStore()
        let player = MezzaninePlayer.makeShared()
        _session = State(initialValue: session)
        _player = State(initialValue: player)
        _playback = State(initialValue: PlaybackCoordinator(player: player, session: session))
    }

    var body: some Scene {
        Window("Mezzanine", id: "main") {
            AppShell()
                .environment(session)
                .environment(player)
                .environment(playback)
                .environment(commands)
                .task { await session.restore() }
                #if DEBUG
                .modifier(LabLauncher())
                #endif
        }
        .defaultSize(width: 1440, height: 900)
        .windowResizability(.contentMinSize)
        .commands { MezzanineCommands(center: commands) }

        Settings {
            SettingsView()
                .environment(session)
        }

        #if DEBUG
        Window("Lab", id: "lab") {
            LabView()
                .environment(session)
                .environment(player)
                .environment(playback)
                .environment(commands)
        }
        .defaultSize(width: 1200, height: 800)
        #endif
    }
}

#if DEBUG
/// Opens the Lab window for the scripted matrix (`-LabAutoMatrix YES`).
private struct LabLauncher: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    func body(content: Content) -> some View {
        content.task { if LabAutoRunner.isEnabled { openWindow(id: "lab") } }
    }
}
#endif
