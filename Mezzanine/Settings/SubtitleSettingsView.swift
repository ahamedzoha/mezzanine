import SwiftUI
import MezzanineKit

/// Settings ▸ Subtitles: the languages Find Subtitles looks for, and its sources. OpenSubtitles
/// and Subdl need the owner's own free keys (entered in a sheet, kept in the Keychain); Plex
/// and Addic7ed work as they are.
struct SubtitleSettingsView: View {
    @Environment(SubtitleSourceSettings.self) private var settings
    @State private var editing: Account?

    enum Account: String, Identifiable { case openSubtitles, subdl; var id: String { rawValue } }

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker("Language", selection: Binding(get: { settings.languages.first ?? "en" }, set: { setLanguage($0, at: 0) })) {
                    ForEach(Self.languageChoices, id: \.code) { Text($0.name).tag($0.code) }
                }
                Picker("Second language", selection: Binding(get: { settings.languages.dropFirst().first ?? "" }, set: { setLanguage($0, at: 1) })) {
                    Text("None").tag("")
                    Divider()
                    ForEach(Self.languageChoices.filter { $0.code != settings.languages.first }, id: \.code) { Text($0.name).tag($0.code) }
                }
            } header: {
                Text("Languages")
            } footer: {
                Text("Find Subtitles in the player asks every source below at once. Subtitles made for your exact file come first.")
            }

            Section {
                Toggle(isOn: $settings.usePlex) {
                    Text("Plex")
                    Text("Your server’s own OpenSubtitles search. Choices are saved on the server for every Plex app.")
                }
                Toggle(isOn: $settings.useAddic7ed) {
                    Text("Addic7ed")
                    Text("TV episodes, through Gestdown. No account or key.")
                }
                LabeledContent {
                    Button(settings.openSubtitlesKey.isEmpty ? "Set Up…" : "Edit…") { editing = .openSubtitles }
                        .accessibilityLabel(settings.openSubtitlesKey.isEmpty ? "Set Up OpenSubtitles.com" : "Edit OpenSubtitles.com")
                } label: {
                    Text("OpenSubtitles.com")
                    Text(openSubtitlesSummary)
                }
                LabeledContent {
                    Button(settings.subdlKey.isEmpty ? "Set Up…" : "Edit…") { editing = .subdl }
                        .accessibilityLabel(settings.subdlKey.isEmpty ? "Set Up Subdl" : "Edit Subdl")
                } label: {
                    Text("Subdl")
                    Text(settings.subdlKey.isEmpty ? "Not set up. Needs a free API key." : "Key saved")
                }
            } header: {
                Text("Sources")
            } footer: {
                Text("Subtitles chosen from OpenSubtitles, Subdl and Addic7ed are kept on this Mac and load every time that title plays.")
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { account in
            switch account {
            case .openSubtitles: OpenSubtitlesSheet()
            case .subdl: SubdlSheet()
            }
        }
    }

    private var openSubtitlesSummary: String {
        if settings.openSubtitlesKey.isEmpty { return "Not set up. Needs a free API key; the best source for films." }
        if let status = settings.openSubtitlesStatus { return status }
        return settings.openSubtitlesUser.isEmpty ? "Key saved" : "Key saved, account \(settings.openSubtitlesUser)"
    }

    private func setLanguage(_ code: String, at index: Int) {
        var list = settings.languages
        if index == 0 {
            list.removeAll { $0 == code }
            list.insert(code, at: 0)
        } else {
            list = [list.first ?? "en"]
            if !code.isEmpty, code != list[0] { list.append(code) }
        }
        settings.languages = Array(list.prefix(2))
    }

    /// Every two-letter language, by its name in the Mac's language.
    static let languageChoices: [(code: String, name: String)] = {
        Locale.LanguageCode.isoLanguageCodes.map(\.identifier).filter { $0.count == 2 }
            .compactMap { code in Locale.current.localizedString(forLanguageCode: code).map { (code, $0) } }
            .sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }
    }()
}

/// OpenSubtitles.com: the API key (required) and the account (optional, more downloads a day).
/// Edits are a draft until Save; Check Key tries the draft.
struct OpenSubtitlesSheet: View {
    @Environment(SubtitleSourceSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var user = ""
    @State private var password = ""
    @State private var checking = false
    @State private var result: (ok: Bool, message: String)?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    SecureField("API key", text: $key, prompt: Text("Required"))
                    TextField("Username", text: $user, prompt: Text("Optional"))
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password, prompt: Text("Optional"))
                        .textContentType(.password)
                } header: {
                    Text("OpenSubtitles.com")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Free. Make an account, open API Consumers in your profile, add a consumer and paste its key here. Sign in with your username and password to download more subtitles each day. Kept in your Keychain.")
                        Link("Get a Free API Key", destination: URL(string: "https://www.opensubtitles.com/en/consumers")!)
                    }
                }
            }
            .formStyle(.grouped)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button("Check Key") { Task { await check() } }
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || checking)
                if checking { ProgressView().controlSize(.small) }
                if let result {
                    Label(result.message, systemImage: result.ok ? "checkmark.circle" : "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(result.ok ? .secondary : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20).padding(.bottom, 16)
        }
        .frame(width: 520)
        .frame(minHeight: 360)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            key = settings.openSubtitlesKey
            user = settings.openSubtitlesUser
            password = settings.openSubtitlesPassword
        }
        .onChange(of: [key, user, password]) { result = nil }
    }

    private var halfAccount: Bool { user.isEmpty != password.isEmpty }

    private func check() async {
        if halfAccount {
            result = (false, "Enter both the username and the password, or neither.")
            return
        }
        checking = true
        result = await SubtitleSourceSettings.checkOpenSubtitles(key: key, user: user, password: password)
        checking = false
        if let result { AccessibilityNotification.Announcement(result.message).post() }
    }

    private func save() {
        settings.openSubtitlesKey = key
        settings.openSubtitlesUser = user
        settings.openSubtitlesPassword = password
        settings.openSubtitlesStatus = result.map { $0.ok ? $0.message : nil } ?? nil
        dismiss()
    }
}

/// Subdl: one free API key, saved on Save.
private struct SubdlSheet: View {
    @Environment(SubtitleSourceSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    SecureField("API key", text: $key, prompt: Text("Required"))
                } header: {
                    Text("Subdl")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Free. Make an account at subdl.com and copy the key from its API page. Kept in your Keychain.")
                        Link("Get a Free API Key", destination: URL(string: "https://subdl.com/panel/api")!)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { settings.subdlKey = key; dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20).padding(.bottom, 16)
        }
        .frame(width: 520)
        .frame(minHeight: 240)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            key = settings.subdlKey
        }
    }
}
