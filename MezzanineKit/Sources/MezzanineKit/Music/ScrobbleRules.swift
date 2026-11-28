import Foundation

/// When a listen counts, by the rules Last.fm and ListenBrainz share: the track is longer than
/// 30 seconds and was played for half its length or 4 minutes, whichever comes first.
public enum ScrobbleRules {
    public static let minimumTrackLength: TimeInterval = 30
    public static let maximumThreshold: TimeInterval = 240

    /// Seconds of play after which the listen counts; nil for a track too short ever to count.
    public static func threshold(duration: TimeInterval) -> TimeInterval? {
        guard duration > minimumTrackLength else { return nil }
        return min(duration / 2, maximumThreshold)
    }

    public static func counts(played: TimeInterval, duration: TimeInterval) -> Bool {
        guard let threshold = threshold(duration: duration) else { return false }
        return played >= threshold
    }

    /// "Now playing" notices are worth sending for any track longer than 30 seconds.
    public static func isNowPlayingEligible(duration: TimeInterval) -> Bool {
        duration > minimumTrackLength
    }
}
