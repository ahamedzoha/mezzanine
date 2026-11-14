import SwiftUI
import MezzanineKit

/// Settings (⌘,). M13 fills the Playback, Audio, Subtitles and Shortcuts
/// tabs; the account tab works now.
struct SettingsView: View {
    @Environment(SessionStore.self) private var session
    @Environment(LibraryStore.self) private var library

    var body: some View {
        TabView {
            Tab("Account", systemImage: "person.crop.circle") {
                Form {
                    LabeledContent("Plex account", value: session.account?.displayName ?? "Not signed in")
                    LabeledContent("Server", value: session.currentServer?.name ?? "—")
                    if let c = session.connection {
                        LabeledContent("Connection", value: "\(c.connection.route.rawValue) · \(c.connection.protocolName)")
                    }
                    if session.account != nil {
                        Button("Sign Out") { session.signOut() }
                    }
                }
                .formStyle(.grouped)
            }
            Tab("Library", systemImage: "books.vertical") {
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
