import Foundation

/// Stops playback on its own: after some minutes, or when the title on screen ends. The last
/// seconds fade the sound out. Pure, so it's testable; `SleepControl` in the app runs it.
public struct SleepTimer: Sendable, Equatable {
    public enum Choice: Sendable, Hashable {
        case off
        /// The end of this episode or film; nothing plays after it.
        case endOfTitle
        case minutes(Int)
    }

    public enum Phase: Sendable, Equatable {
        case idle
        case waiting
        /// Fading out: whole seconds left, and the sound's level (1 to 0).
        case fading(seconds: Int, level: Double)
        case due
    }

    public static let minuteChoices = [15, 30, 45, 60, 90]
    /// How long the sound takes to fade out.
    public static let fade: TimeInterval = 20
    /// What Keep Watching adds.
    public static let keepWatchingMinutes = 15

    public private(set) var choice: Choice = .off
    public private(set) var deadline: Date?

    public init() {}

    public mutating func set(_ choice: Choice, now: Date = Date()) {
        self.choice = choice
        if case .minutes(let n) = choice { deadline = now.addingTimeInterval(Double(n) * 60) } else { deadline = nil }
    }

    /// Keep Watching: a timed stop moves on a quarter of an hour; the end of a title no longer stops.
    public mutating func keepWatching(now: Date = Date()) {
        switch choice {
        case .minutes:
            choice = .minutes(Self.keepWatchingMinutes)
            deadline = now.addingTimeInterval(Double(Self.keepWatchingMinutes) * 60)
        default:
            choice = .off
            deadline = nil
        }
    }

    /// Seconds until it stops; nil when off, or at the end of a title of unknown length.
    /// `remaining` is what's left of the title in real time (its length over the speed).
    public func left(now: Date = Date(), remaining: TimeInterval?) -> TimeInterval? {
        switch choice {
        case .off: nil
        case .endOfTitle: remaining.map { max(0, $0) }
        case .minutes: deadline.map { max(0, $0.timeIntervalSince(now)) }
        }
    }

    public func phase(now: Date = Date(), remaining: TimeInterval?) -> Phase {
        guard choice != .off else { return .idle }
        guard let left = left(now: now, remaining: remaining) else { return .waiting }
        // The end of a title is the player's to report; here it only fades towards it.
        if left <= 0 { return choice == .endOfTitle ? .fading(seconds: 0, level: 0) : .due }
        guard left <= Self.fade else { return .waiting }
        return .fading(seconds: Int(left.rounded(.up)), level: left / Self.fade)
    }

    /// Nothing follows the title on screen.
    public var stopsAtEnd: Bool { choice == .endOfTitle }
}
