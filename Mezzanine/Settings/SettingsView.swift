import SwiftUI
import MezzanineKit

/// Settings (⌘,): Account, Playback (binge rules), Sound (per-device setups), Subtitles
/// (Find Subtitles' languages and sources), Shortcuts (every player key, rebindable), Library.
struct SettingsView: View {
    @Environment(SessionStore.self) private var session
    @Environment(LibraryStore.self) private var library
    @Environment(SoundSettings.self) private var sound
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(NewEpisodeNotifier.self) private var notifier
    @Environment(AppUpdater.self) private var updater
    @Environment(RemoteControl.self) private var remote
    @State private var confirmSignOut = false
    @AppStorage("settingsTab") private var tab = "account"

    var body: some View {
        TabView(selection: $tab) {
            Tab("Account", systemImage: "person.crop.circle", value: "account") {
                Form {
                    LabeledContent("Plex account", value: session.account?.displayName ?? "Not signed in")
                    LabeledContent("Server", value: session.currentServer?.name ?? "None")
                    if let c = session.connection {
                        LabeledContent("Connection", value: "\(routeName(c.connection.route)) · \(c.connection.protocolName)")
                    }
                    if session.account != nil {
                        Button("Sign Out…", role: .destructive) { confirmSignOut = true }
                            .confirmationDialog("Sign out of Plex?", isPresented: $confirmSignOut) {
                                Button("Sign Out", role: .destructive) { session.signOut() }
                            } message: {
                                Text("Mezzanine forgets this account on this Mac. Your library on the server isn’t touched.")
                            }
                    }
                }
                .formStyle(.grouped)
                .safeAreaInset(edge: .bottom) {
                    Text("Switch Plex Home profiles from Mezzanine ▸ Switch Profile.")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20).padding(.bottom, 16)
                }
            }
            Tab("Playback", systemImage: "play.rectangle", value: "playback") {
                @Bindable var playback = playback
                Form {
                    Section("Episodes") {
                        Picker("Up Next", selection: $playback.binge.upNextCountdown) {
                            Text("Don’t play automatically").tag(0)
                            ForEach([5, 10, 15, 30], id: \.self) { Text("Play after \($0) seconds").tag($0) }
                        }
                        Picker("Skip intros", selection: $playback.binge.autoSkipIntro) {
                            ForEach(BingeSettings.AutoSkip.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        Toggle("Skip credits and go to the next episode", isOn: $playback.binge.autoSkipCredits)
                    }
                    Section {
                        @Bindable var notifier = notifier
                        Toggle(isOn: $notifier.enabled) {
                            Text("New episodes")
                            Text("A notification when a show you’re watching gets new episodes, while Mezzanine is open.")
                        }
                        if notifier.enabled && notifier.authorization == .notDetermined {
                            LabeledContent {
                                Button("Allow Notifications…") { Task { await notifier.requestIfNeeded() } }
                            } label: {
                                Text("Mezzanine hasn’t been allowed to post notifications yet.")
                            }
                        }
                        if notifier.enabled && notifier.authorization == .denied {
                            LabeledContent {
                                Button("Open Notification Settings…") {
                                    let id = Bundle.main.bundleIdentifier ?? ""
                                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                            } label: {
                                Label("Notifications are off for Mezzanine in System Settings.", systemImage: "exclamationmark.triangle")
                            }
                        }
                    }
                    .task { await notifier.refreshStatus() }
                    Section {
                        @Bindable var remote = remote
                        Toggle(isOn: $remote.enabled) {
                            Text("Plex apps can control Mezzanine")
                            Text("The Plex app on your phone and Plex Web list “\(remote.name)” as a player on this network: pick it to play here, then pause, seek and skip from the phone.")
                        }
                        if let problem = remote.problem {
                            Label(problem, systemImage: "exclamationmark.triangle")
                        } else if remote.enabled, let controller = remote.lastController {
                            LabeledContent("Last controlled by", value: controller)
                        }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                        Task { await notifier.refreshStatus() }
                    }
                    Section("Films") {
                        Toggle("Suggest what to watch next at the credits", isOn: Binding(
                            get: { playback.showsPostPlay }, set: { playback.showsPostPlay = $0 }))
                    }
                    Section {
                        Picker("Ask “Still watching?” after", selection: Binding(
                            get: { playback.binge.stillWatchingAfterEpisodes ?? 0 },
                            set: { playback.binge.stillWatchingAfterEpisodes = $0 == 0 ? nil : $0 })) {
                            Text("Never").tag(0)
                            ForEach([2, 3, 4, 6, 8], id: \.self) { Text("\($0) episodes").tag($0) }
                        }
                    } footer: {
                        Text("Skip Intro and Next Episode buttons always appear; these settings decide what happens without them. \(PlayerShortcuts.shared.display(.skipMarker)) or Return skips by hand.")
                    }
                }
                .formStyle(.grouped)
            }
            Tab("Sound", systemImage: "speaker.wave.2", value: "sound") {
                Form {
                    Section {
                        LabeledContent("Output", value: sound.deviceName)
                        Picker("This output is", selection: Binding(get: { sound.current.kind }, set: { sound.setKind($0) })) {
                            ForEach([AudioOutputKind.builtInSpeakers, .headphones, .speakers21, .airPods, .hdmi, .other], id: \.self) {
                                Text($0.label).tag($0)
                            }
                        }
                    } footer: {
                        Text(sound.current.kind.summary + ". Mezzanine remembers this for each output and switches when you change outputs.")
                    }
                    Section {
                        LabeledContent("Volume") {
                            HStack {
                                Slider(value: Binding(get: { sound.current.volumePercent }, set: { sound.setVolume($0) }), in: 0...400, step: 10)
                                    .frame(width: 200)
                                    .accessibilityLabel("Volume")
                                    .accessibilityValue("\(Int(sound.current.volumePercent)) percent")
                                Text("\(Int(sound.current.volumePercent)) %").monospacedDigit().frame(width: 52, alignment: .trailing)
                            }
                        }
                        LabeledContent("Dialogue boost") {
                            HStack {
                                Slider(value: Binding(get: { sound.current.profile.dialogueGainDB }, set: { sound.setDialogue($0) }), in: 0...12, step: 1)
                                    .frame(width: 200)
                                    .accessibilityLabel("Dialogue boost")
                                    .accessibilityValue("plus \(Int(sound.current.profile.dialogueGainDB)) decibels")
                                Text("+\(Int(sound.current.profile.dialogueGainDB)) dB").monospacedDigit().frame(width: 52, alignment: .trailing)
                            }
                        }
                        Picker("Raise quiet films", selection: Binding(get: { sound.current.profile.loudnessTargetLUFS }, set: { sound.setLoudness($0) })) {
                            Text("Off").tag(Double?.none)
                            Text("A little").tag(Double?.some(-24))
                            Text("Moderately").tag(Double?.some(-20))
                            Text("A lot").tag(Double?.some(-16))
                        }
                        Toggle(isOn: Binding(get: { sound.current.profile.nightMode }, set: { _ in sound.toggleNight() })) {
                            Text("Night mode")
                            Text("Softer explosions, clearer whispers")
                        }
                    } header: {
                        Text("Adjust")
                    } footer: {
                        if adjustmentsOff {
                            Text(sound.current.kind == .hdmi
                                 ? "A receiver or soundbar gets the original sound untouched, so it can decode surround itself. Adjust volume on it."
                                 : "AirPods get the original sound so spatial audio keeps working. Adjust volume on the Mac.")
                        } else if sound.current.volumePercent > 100 {
                            Text("Above 100 % is boost: a limiter keeps peaks from clipping, but very quiet films raised a lot can sound compressed.")
                        }
                    }
                    .disabled(adjustmentsOff)
                }
                .formStyle(.grouped)
            }
            Tab("Subtitles", systemImage: "captions.bubble", value: "subtitles") {
                SubtitleSettingsView()
            }
            Tab("Shortcuts", systemImage: "keyboard", value: "shortcuts") {
                ShortcutSettings()
            }
            Tab("Library", systemImage: "books.vertical", value: "library") {
                @Bindable var library = library
                Form {
                    Section {
                        Toggle("Show original posters", isOn: $library.prefersCleanPosters)
                    } footer: {
                        Text("Uses each title’s original poster instead of the one your server shows, so badges added to posters on the server (like resolution or rating stickers) don’t appear here. Nothing on the server changes.")
                    }
                    Section {
                        LabeledContent("Local library") {
                            switch library.syncState {
                            case .idle: Text("Up to date")
                            case .syncing(let s, let d, let t):
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("Reading \(s) (\(d.formatted()) of \(t.formatted()))")
                                }
                            case .failed(let m): Label(m, systemImage: "exclamationmark.triangle.fill").lineLimit(3)
                            }
                        }
                        Button("Read Library Again") { Task { await library.syncAll(force: true) } }
                            .disabled({ if case .syncing = library.syncState { return true }; return false }())
                    }
                }
                .formStyle(.grouped)
            }
            Tab("Updates", systemImage: "arrow.down.app", value: "updates") {
                updatesForm
            }
        }
        .frame(minWidth: 520, idealWidth: 540, minHeight: 420)
    }

    /// Settings ▸ Updates: the version, Sparkle's two switches, and Check Now.
    private var updatesForm: some View {
        @Bindable var updater = updater
        return Form {
            Section {
                LabeledContent("Version", value: AppUpdater.versionLine)
                if updater.isAvailable {
                    Toggle("Check for updates automatically", isOn: $updater.checksAutomatically)
                    Toggle(isOn: $updater.installsAutomatically) {
                        Text("Download and install updates automatically")
                        Text(updater.checksAutomatically
                             ? "New versions install the next time you quit Mezzanine."
                             : "Needs automatic checks.")
                    }
                    .disabled(!updater.checksAutomatically)
                    if let version = updater.waitingVersion {
                        LabeledContent("Update waiting") { Text("Version \(version) will be offered when you close the film.") }
                    }
                    LabeledContent("Last checked") {
                        HStack(spacing: 10) {
                            if !updater.canCheck {
                                ProgressView().controlSize(.small)
                                Text("Checking…")
                            } else if let date = updater.lastChecked {
                                Text(date, format: .relative(presentation: .numeric))
                            } else {
                                Text("Never")
                            }
                            Button("Check Now") { updater.checkForUpdates() }
                                .disabled(!updater.canCheck)
                                .accessibilityHint("Looks for a new version of Mezzanine.")
                        }
                    }
                }
            } footer: {
                Text(updater.isAvailable
                     ? "Updates come from Mezzanine’s GitHub releases and are signed."
                     : "This is a development build. It doesn’t update itself; install a release to get updates.")
            }
        }
        .formStyle(.grouped)
    }

    /// The device plays the original sound (receiver decodes it, AirPods keep spatial audio).
    private var adjustmentsOff: Bool { sound.current.kind == .hdmi || sound.current.kind == .airPods }

    private func routeName(_ route: PlexConnection.Route) -> String {
        switch route {
        case .local: "Local network"
        case .remote: "Internet"
        case .relay: "Plex relay"
        }
    }
}
