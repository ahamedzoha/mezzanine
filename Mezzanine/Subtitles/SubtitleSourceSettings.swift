import Foundation
import Observation
import MezzanineKit

/// Where Find Subtitles looks, and in which languages. API keys and the OpenSubtitles
/// password live in the Keychain; everything else in defaults.
@MainActor @Observable
final class SubtitleSourceSettings {
    private static let defaults = UserDefaults.standard
    @ObservationIgnored private let keychain = Keychain(service: (Bundle.main.bundleIdentifier ?? "com.mezzanine.mac") + ".subtitles",
                                                       label: "Mezzanine — subtitle source key")

    /// ISO 639-1 codes, best first (one or two).
    var languages: [String] { didSet { Self.defaults.set(languages, forKey: "subtitleLanguages") } }
    var usePlex: Bool { didSet { Self.defaults.set(usePlex, forKey: "subtitleSourcePlex") } }
    var useAddic7ed: Bool { didSet { Self.defaults.set(useAddic7ed, forKey: "subtitleSourceAddic7ed") } }
    var openSubtitlesKey: String { didSet { store(openSubtitlesKey, "opensubtitles.apiKey"); openSubtitles = nil; openSubtitlesStatus = nil } }
    var openSubtitlesUser: String { didSet { Self.defaults.set(openSubtitlesUser, forKey: "openSubtitlesUser"); openSubtitles = nil; openSubtitlesStatus = nil } }
    var openSubtitlesPassword: String { didSet { store(openSubtitlesPassword, "opensubtitles.password"); openSubtitles = nil; openSubtitlesStatus = nil } }
    var subdlKey: String { didSet { store(subdlKey, "subdl.apiKey") } }

    /// The last Check result ("Signed in. 18 of 20 downloads left today.").
    var openSubtitlesStatus: String?

    /// Kept between searches so the sign-in token is reused (the API asks clients not to
    /// sign in for every request).
    @ObservationIgnored private var openSubtitles: OpenSubtitlesSource?

    init() {
        let d = Self.defaults
        let stored = d.stringArray(forKey: "subtitleLanguages") ?? []
        languages = stored.isEmpty ? Self.systemLanguages : stored
        usePlex = d.object(forKey: "subtitleSourcePlex") as? Bool ?? true
        useAddic7ed = d.object(forKey: "subtitleSourceAddic7ed") as? Bool ?? true
        openSubtitlesUser = d.string(forKey: "openSubtitlesUser") ?? ""
        openSubtitlesKey = keychain.read("opensubtitles.apiKey") ?? ""
        openSubtitlesPassword = keychain.read("opensubtitles.password") ?? ""
        subdlKey = keychain.read("subdl.apiKey") ?? ""
    }

    /// The Mac's preferred languages, as two-letter codes (at most two).
    static var systemLanguages: [String] {
        var out: [String] = []
        for id in Locale.preferredLanguages {
            if let code = Locale(identifier: id).language.languageCode?.identifier(.alpha2), !out.contains(code) { out.append(code) }
        }
        return Array((out.isEmpty ? ["en"] : out).prefix(2))
    }

    /// The sources to ask for one title. Plex needs the server; the rest are on the internet.
    func sources(client: PlexServerClient?, ratingKey: String) -> [any SubtitleSource] {
        var out: [any SubtitleSource] = []
        if usePlex, let client { out.append(PlexSubtitleSource(client: client, ratingKey: ratingKey)) }
        if !openSubtitlesKey.isEmpty { out.append(openSubtitlesSource()) }
        if !subdlKey.isEmpty { out.append(SubdlSource(apiKey: subdlKey)) }
        if useAddic7ed { out.append(GestdownSource()) }
        return out
    }

    private func openSubtitlesSource() -> OpenSubtitlesSource {
        if let openSubtitles { return openSubtitles }
        let made = OpenSubtitlesSource(apiKey: openSubtitlesKey, username: openSubtitlesUser, password: openSubtitlesPassword)
        openSubtitles = made
        return made
    }

    /// Tries a key and account without saving them (the setup sheet's Check Key).
    static func checkOpenSubtitles(key: String, user: String, password: String) async -> (ok: Bool, message: String) {
        do {
            return (true, try await OpenSubtitlesSource(apiKey: key, username: user, password: password).check())
        } catch {
            let why = (error as? SubtitleSourceError)?.userMessage ?? "OpenSubtitles didn’t answer"
            return (false, why.prefix(1).uppercased() + why.dropFirst() + ".")
        }
    }

    private func store(_ value: String, _ account: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { keychain.delete(account) } else { try? keychain.write(trimmed, for: account) }
    }
}
