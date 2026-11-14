import SwiftUI
import MezzanineKit

/// Settings (⌘,). M13 fills the Playback, Audio, Subtitles and Shortcuts
/// tabs; the account tab works now.
struct SettingsView: View {
    @Environment(SessionStore.self) private var session

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
        }
        .frame(width: 480, height: 260)
    }
}
