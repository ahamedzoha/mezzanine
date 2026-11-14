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
                    Toggle("Show original posters", isOn: $library.prefersCleanPosters)
                    Text("Shows each title's agent poster instead of the server's selected one, so overlays added by tools like Kometa don't appear in Mezzanine. Nothing changes on the server.")
                        .font(.callout).foregroundStyle(.secondary)
                    LabeledContent("Local library") {
                        switch library.syncState {
                        case .idle: Text("Up to date")
                        case .syncing(let s, let d, let t): Text("Reading \(s) (\(d) of \(t))")
                        case .failed(let m): Text(m).foregroundStyle(.red)
                        }
                    }
                    Button("Read Library Again") { Task { await library.syncAll(force: true) } }
                }
                .formStyle(.grouped)
            }
        }
        .frame(width: 520, height: 320)
    }
}
