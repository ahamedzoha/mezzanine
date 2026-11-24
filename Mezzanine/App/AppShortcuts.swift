import AppIntents
import MezzanineKit

/// What Shortcuts, Siri and Spotlight's actions reach the app through. They act on the profile in
/// use and never switch it, so a protected one can't be opened this way.
@MainActor
final class IntentBridge {
    static let shared = IntentBridge()
    private init() {}

    private(set) weak var session: SessionStore?
    private(set) weak var library: LibraryStore?
    private(set) weak var playback: PlaybackCoordinator?
    private(set) weak var commands: AppCommandCenter?

    func start(session: SessionStore, library: LibraryStore, playback: PlaybackCoordinator, commands: AppCommandCenter) {
        self.session = session
        self.library = library
        self.playback = playback
        self.commands = commands
    }

    /// Waits (the app may just have been launched) until it's connected and has its library.
    func ready() async throws {
        for _ in 0..<150 {
            if session?.phase == .ready, library?.index != nil { return }
            if session?.phase == .signedOut, session?.token == nil { throw IntentProblem.signedOut }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw IntentProblem.notConnected
    }
}

nonisolated enum IntentProblem: Error, CustomLocalizedStringResourceConvertible {
    case signedOut, notConnected, nothingToResume, nothingUnwatched, gone

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .signedOut: "Open Mezzanine and sign in to Plex first."
        case .notConnected: "Mezzanine couldn’t reach your Plex server."
        case .nothingToResume: "Nothing is in progress."
        case .nothingUnwatched: "Nothing unwatched here."
        case .gone: "That title isn’t on the server any more."
        }
    }
}

/// A film or show of the profile in use.
nonisolated struct TitleEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Title")
    static let defaultQuery = TitleQuery()

    let id: String
    let name: String
    let detail: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)", subtitle: "\(detail)") }

    init(_ item: PlexMetadata) {
        id = item.ratingKey
        name = item.title
        detail = [item.kind == .show ? "Show" : "Film", item.year.map(String.init)].compactMap { $0 }.joined(separator: " · ")
    }
}

nonisolated struct TitleQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [TitleEntity] {
        guard let index = await IntentBridge.shared.library?.index else { return [] }
        return identifiers.compactMap { (try? index.item($0))??.metadata().map(TitleEntity.init) }
    }

    func entities(matching string: String) async throws -> [TitleEntity] {
        guard let library = await IntentBridge.shared.library else { return [] }
        return await library.search(string).filter { $0.kind == .movie || $0.kind == .show }.prefix(20).map(TitleEntity.init)
    }

    func suggestedEntities() async throws -> [TitleEntity] {
        guard let library = await IntentBridge.shared.library else { return [] }
        return await library.wallItems(limit: 20).map(TitleEntity.init)
    }
}

nonisolated struct ResumeWatchingIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume Watching"
    static let description = IntentDescription("Plays what you were watching last, from where you stopped.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        let bridge = IntentBridge.shared
        try await bridge.ready()
        if bridge.library?.continueItems.isEmpty == true { await bridge.library?.loadContinue() }
        guard let item = bridge.library?.continueItems.first else { throw IntentProblem.nothingToResume }
        await bridge.playback?.play(item, from: nil)
        return .result()
    }
}

struct PlayNextEpisodeIntent: AppIntent {
    nonisolated static let title: LocalizedStringResource = "Play Next Episode"
    nonisolated static let description = IntentDescription("Plays a show’s next unwatched episode, or a film.")
    nonisolated static let openAppWhenRun = true

    @Parameter(title: "Title") var target: TitleEntity
    nonisolated static var parameterSummary: some ParameterSummary { Summary("Play the next episode of \(\.$target)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        let bridge = IntentBridge.shared
        try await bridge.ready()
        guard let item = (try? bridge.library?.index?.item(target.id))??.metadata() else { throw IntentProblem.gone }
        await bridge.playback?.play(item, from: nil)
        return .result()
    }
}

struct OpenTitleIntent: AppIntent {
    nonisolated static let title: LocalizedStringResource = "Open Title"
    nonisolated static let description = IntentDescription("Shows a film’s or show’s page.")
    nonisolated static let openAppWhenRun = true

    @Parameter(title: "Title") var target: TitleEntity
    nonisolated static var parameterSummary: some ParameterSummary { Summary("Open \(\.$target)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        let bridge = IntentBridge.shared
        try await bridge.ready()
        guard (try? bridge.library?.index?.item(target.id)) ?? nil != nil else { throw IntentProblem.gone }
        bridge.commands?.openWhenReady(target.id)
        return .result()
    }
}

nonisolated struct SurpriseMeIntent: AppIntent {
    static let title: LocalizedStringResource = "Surprise Me"
    static let description = IntentDescription("Shows a random unwatched film or show.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        let bridge = IntentBridge.shared
        try await bridge.ready()
        guard let item = await bridge.library?.surprise(section: nil, kinds: ["movie", "show"]) else { throw IntentProblem.nothingUnwatched }
        bridge.commands?.openWhenReady(item.ratingKey)
        return .result()
    }
}

nonisolated struct MezzanineShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ResumeWatchingIntent(), phrases: ["Resume watching in \(.applicationName)", "Resume \(.applicationName)"],
                    shortTitle: "Resume Watching", systemImageName: "play.fill")
        AppShortcut(intent: SurpriseMeIntent(), phrases: ["Surprise me in \(.applicationName)", "Surprise me with \(.applicationName)"],
                    shortTitle: "Surprise Me", systemImageName: "dice")
    }
}
