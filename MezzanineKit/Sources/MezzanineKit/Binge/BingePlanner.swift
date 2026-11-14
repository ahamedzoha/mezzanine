import Foundation

/// How a binge behaves. Global, with per-show overrides for intro skipping.
public struct BingeSettings: Codable, Sendable, Equatable {
    public enum AutoSkip: String, Codable, Sendable, CaseIterable {
        case never, afterFirstEpisode, always
        public var label: String {
            switch self {
            case .never: return "Never"
            case .afterFirstEpisode: return "After the first episode"
            case .always: return "Always"
            }
        }
    }

    /// Seconds the Up Next card counts down before the next episode starts (0 = don't autoplay).
    public var upNextCountdown: Int = 10
    public var autoSkipIntro: AutoSkip = .afterFirstEpisode
    /// Skipping the credits goes straight to the next episode.
    public var autoSkipCredits = false
    /// Ask "Still watching?" after this many episodes in a row (nil = never).
    public var stillWatchingAfterEpisodes: Int? = 4
    /// …or after this many hours of continuous autoplay (nil = never).
    public var stillWatchingAfterHours: Double? = 3
    /// Per-show intro rule, by show rating key.
    public var showIntroRules: [String: AutoSkip] = [:]

    public init() {}

    public static let countdownChoices = [0, 5, 10, 15, 30]
}

/// The arithmetic of a binge, kept pure so it's testable.
public enum BingePlanner {
    /// Seconds before the end to show Up Next when an episode has no credits marker.
    public static let fallbackLead: TimeInterval = 30

    /// When Up Next appears: at the final credits marker, else `fallbackLead` before the end.
    public static func upNextTrigger(duration: TimeInterval, markers: [PlexMarker]) -> TimeInterval? {
        guard duration > 60 else { return nil }
        if let credits = markers.last(where: { $0.kind == .credits && $0.isFinal })
            ?? markers.last(where: { $0.kind == .credits }),
           credits.start > duration * 0.5 {
            return credits.start
        }
        return max(0, duration - fallbackLead)
    }

    /// Whether to skip this episode's intro without asking.
    public static func shouldAutoSkipIntro(settings: BingeSettings, showKey: String?, episodesThisSession: Int) -> Bool {
        let rule = showKey.flatMap { settings.showIntroRules[$0] } ?? settings.autoSkipIntro
        switch rule {
        case .never: return false
        case .always: return true
        case .afterFirstEpisode: return episodesThisSession >= 1
        }
    }

    /// Whether to pause and ask before the next autoplay.
    public static func shouldAskStillWatching(settings: BingeSettings, autoplayedInARow: Int,
                                              sessionStart: Date, now: Date) -> Bool {
        if let n = settings.stillWatchingAfterEpisodes, autoplayedInARow >= n { return true }
        if let h = settings.stillWatchingAfterHours, now.timeIntervalSince(sessionStart) >= h * 3600 { return true }
        return false
    }

    /// The episode after `current` in a show's ordered episode list (crossing seasons;
    /// specials, season 0, are skipped unless the current episode is one).
    public static func nextEpisode(after current: PlexMetadata, in allEpisodes: [PlexMetadata]) -> PlexMetadata? {
        let ordered = allEpisodes
            .filter { ($0.parentIndex ?? 0) > 0 || (current.parentIndex ?? 0) == 0 }
            .sorted { ($0.parentIndex ?? 0, $0.index ?? 0) < ($1.parentIndex ?? 0, $1.index ?? 0) }
        guard let i = ordered.firstIndex(where: { $0.ratingKey == current.ratingKey }) else { return nil }
        return ordered.indices.contains(i + 1) ? ordered[i + 1] : nil
    }
}
