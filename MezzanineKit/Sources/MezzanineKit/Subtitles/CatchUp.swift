import Foundation

/// "What did they say?": back a few seconds with subtitles on, until the moment it was asked.
public struct CatchUp: Sendable, Equatable {
    /// How far it goes back.
    public static let step: TimeInterval = 10
    /// Subtitles stay a moment past the old position, so the last line can be read.
    public static let tail: TimeInterval = 1.5

    /// The position it was first asked at: subtitles go off past it.
    public let until: TimeInterval
    public let trackID: Int

    public init(at time: TimeInterval, trackID: Int) {
        until = time + Self.tail
        self.trackID = trackID
    }

    public func isOver(at time: TimeInterval) -> Bool { time >= until }

    public struct Track: Sendable, Equatable {
        public let id: Int
        public let language: String?
        public let isForced: Bool
        public let isHearingImpaired: Bool
        public let isCommentary: Bool

        public init(id: Int, language: String?, isForced: Bool = false, isHearingImpaired: Bool = false, isCommentary: Bool = false) {
            self.id = id
            self.language = language
            self.isForced = isForced
            self.isHearingImpaired = isHearingImpaired
            self.isCommentary = isCommentary
        }
    }

    /// The track that says what was said: the spoken language first, then the viewer's own, then
    /// any. Forced tracks hold only foreign lines, so they never answer; plain ones come before
    /// hearing-impaired ones.
    public static func track(from tracks: [Track], spoken: String?, preferred: [String]) -> Track? {
        let full = tracks.filter { !$0.isForced && !$0.isCommentary }
        for language in [spoken].compactMap({ $0 }) + preferred {
            let matches = full.filter { $0.language.map { same($0, language) } ?? false }
            if let best = matches.first(where: { !$0.isHearingImpaired }) ?? matches.first { return best }
        }
        return full.first { !$0.isHearingImpaired } ?? full.first
    }

    /// "en", "eng" and "en-US" are the same language.
    static func same(_ a: String, _ b: String) -> Bool { code(a) == code(b) }

    private static func code(_ raw: String) -> String {
        let base = raw.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? raw
        return Locale.Language(identifier: base).languageCode?.identifier(.alpha3) ?? base
    }
}
