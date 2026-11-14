import SwiftUI
import MezzanineKit

/// Settings (⌘,): Account, Playback (binge rules), Sound (per-device setups),
/// Shortcuts (every player key, rebindable), Library.
struct SettingsView: View {
    @Environment(SessionStore.self) private var session
    @Environment(LibraryStore.self) private var library
    @Environment(SoundSettings.self) private var sound
    @Environment(PlaybackCoordinator.self) private var playback
    @State private var confirmSignOut = false
    @AppStorage("settingsTab") private var tab = "account"

    var body: some View {
        TabView(selection: $tab) {
            Tab("Account", systemImage: "person.crop.circle", value: "account") {
                Form {
                    LabeledContent("Plex account", value: session.account?.displayName ?? "Not signed in")
                    LabeledContent("Server", value: session.currentServer?.name ?? "—")
                    if let c = session.connection {
                        LabeledContent("Connection", value: "\(c.connection.route.rawValue) · \(c.connection.protocolName)")
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
                        Picker("Ask “Still watching?” after", selection: Binding(
                            get: { playback.binge.stillWatchingAfterEpisodes ?? 0 },
                            set: { playback.binge.stillWatchingAfterEpisodes = $0 == 0 ? nil : $0 })) {
                            Text("Never").tag(0)
                            ForEach([2, 3, 4, 6, 8], id: \.self) { Text("\($0) episodes").tag($0) }
                        }
                    } footer: {
                        Text("Skip Intro and Next Episode buttons always appear; these settings decide what happens without them. S or Return skips by hand.")
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
                        Toggle("Night mode (softer explosions, clearer whispers)", isOn: Binding(get: { sound.current.profile.nightMode }, set: { _ in sound.toggleNight() }))
                    } header: {
                        Text("Adjust")
                    } footer: {
                        if sound.current.volumePercent > 100 {
                            Text("Above 100 % is boost: a limiter keeps peaks from clipping, but very quiet films raised a lot can sound compressed.")
                        }
                    }
                    .disabled(sound.current.kind == .hdmi || sound.current.kind == .airPods)
                }
                .formStyle(.grouped)
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
                            case .syncing(let s, let d, let t): Text("Reading \(s) (\(d.formatted()) of \(t.formatted()))")
                            case .failed(let m): Label(m, systemImage: "exclamationmark.triangle.fill")
                            }
                        }
                        Button("Read Library Again") { Task { await library.syncAll(force: true) } }
                            .disabled({ if case .syncing = library.syncState { return true }; return false }())
                    }
                }
                .formStyle(.grouped)
            }
        }
        .frame(minWidth: 520, idealWidth: 540, minHeight: 320)
    }
}
