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
    @State private var layouts = HomeLayoutStore()
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
                .environment(layouts)
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
        .commands { MezzanineCommands(center: commands, sound: sound, session: session) }

        Settings {
            SettingsView()
                .environment(playback)
                .environment(session)
                .environment(library)
                .environment(layouts)
                .environment(sound)
        }

        Window("Keyboard Shortcuts", id: "shortcuts") {
            ShortcutsWindow()
        }
        .defaultSize(width: 520, height: 720)
        .windowResizability(.contentMinSize)

        #if DEBUG
        // Review captures: the rule sheet and collection picker as plain windows (window
        // snapshots of an attached sheet fail).
        Window("Sheet Preview", id: "sheetPreview") {
            SheetPreview()
                .environment(session)
                .environment(library)
                .environment(commands)
        }
        Window("Lab", id: "lab") {
            LabView()
                .environment(session)
                .environment(player)
                .environment(playback)
                .environment(commands)
                .environment(library)
                .environment(layouts)
        }
        .defaultSize(width: 1200, height: 800)
        #endif
    }
}

#if DEBUG
/// Opens the Lab window for the scripted matrix (`-LabAutoMatrix YES`).
private struct LabLauncher: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    func body(content: Content) -> some View {
        content.task {
            if LabAutoRunner.isEnabled { openWindow(id: "lab") }
            // -MezzanineOpenWindow shortcuts: open a window at launch, for review captures.
            if let id = UserDefaults.standard.string(forKey: "MezzanineOpenWindow") {
                if id == "settings" { openSettings() } else { openWindow(id: id) }
            }
        }
    }
}
#endif

#if DEBUG
/// `-MezzanineOpenWindow sheetPreview -SheetPreviewKind picker|rules`.
private struct SheetPreview: View {
    @Environment(AppCommandCenter.self) private var commands
    @Environment(SessionStore.self) private var session
    @Environment(LibraryStore.self) private var library
    @State private var artworkItem: PlexMetadata?
    var body: some View {
        let kind = UserDefaults.standard.string(forKey: "SheetPreviewKind")
        if kind == "artwork" {
            ZStack {
                Color.clear
                if let artworkItem, session.client != nil {
                    ArtworkPicker(request: ArtworkRequest(item: artworkItem, kind: .poster))
                }
            }
            .task(id: library.revision) {
                let key = UserDefaults.standard.string(forKey: "ArtworkKey") ?? "52003"
                artworkItem = try? library.index?.item(key)?.metadata()
            }
        } else if kind == "picker" {
            if session.client != nil && !commands.sections.isEmpty {
                CollectionPicker(sections: commands.sections, existing: []) { _, _ in }
            }
        } else {
            SmartShelfSheet(existing: ShelfSpec(title: "", source: .smart(SmartRule(
                conditions: [.watch(.unwatched), .genre("Comedy", excluded: false), .decade(1990), .minRating(7)],
                sort: .rating))), scope: HomeLayout.mainScope, sections: commands.sections) { _ in }
        }
    }
}
#endif
