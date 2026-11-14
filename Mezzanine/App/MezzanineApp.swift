import SwiftUI
import MezzanineKit
import MezzaninePlayback

/// Holds quit until the final timeline report is sent (≤ 2 s), so quitting
/// mid-film still saves the resume point.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var beforeQuit: (() async -> Void)?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let beforeQuit else { return .terminateNow }
        Task { @MainActor in
            await beforeQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct MezzanineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var session: SessionStore
    @State private var player: MezzaninePlayer
    @State private var playback: PlaybackCoordinator
    @State private var commands = AppCommandCenter()
    @State private var library = LibraryStore()
    @State private var sound: SoundSettings

    init() {
        TitleFont.register()
        let session = SessionStore()
        let player = MezzaninePlayer.makeShared()
        _session = State(initialValue: session)
        _player = State(initialValue: player)
        _playback = State(initialValue: PlaybackCoordinator(player: player, session: session))
        _sound = State(initialValue: SoundSettings(route: AudioRouteMonitor(), player: player))
    }

    var body: some Scene {
        Window("Mezzanine", id: "main") {
            AppShell()
                .environment(session)
                .environment(player)
                .environment(playback)
                .environment(commands)
                .environment(library)
                .environment(sound)
                .task {
                    appDelegate.beforeQuit = { [playback] in await playback.finishForQuit() }
                    playback.onStopped = { [library] item, time, duration in
                        library.recordStop(item, at: time, duration: duration)
                    }
                    await session.restore()
                }
                #if DEBUG
                .modifier(LabLauncher())
                #endif
        }
        .defaultSize(width: 1440, height: 900)
        .windowResizability(.contentMinSize)
        .commands { MezzanineCommands(center: commands, sound: sound) }

        Settings {
            SettingsView()
                .environment(session)
                .environment(library)
                .environment(sound)
        }

        #if DEBUG
        Window("Lab", id: "lab") {
            LabView()
                .environment(session)
                .environment(player)
                .environment(playback)
                .environment(commands)
                .environment(library)
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
