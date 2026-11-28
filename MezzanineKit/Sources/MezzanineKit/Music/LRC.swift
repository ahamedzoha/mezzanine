import Foundation

/// One line of lyrics. `start` is nil for lyrics without timing.
public struct LyricLine: Sendable, Hashable, Codable {
    public var start: TimeInterval?
    public var text: String
    public init(start: TimeInterval? = nil, text: String) {
        self.start = start
        self.text = text
    }
}

/// A song's lyrics, timed (an LRC file) or plain.
public struct Lyrics: Sendable, Hashable, Codable {
    public var lines: [LyricLine]
    public var isTimed: Bool
    public var provider: String?

    public init(lines: [LyricLine], isTimed: Bool, provider: String? = nil) {
        self.lines = lines
        self.isTimed = isTimed
        self.provider = provider
    }

    /// The line that is current at `time`: the last one that started. Nil before the first line
    /// or when the lyrics are not timed.
    public func lineIndex(at time: TimeInterval) -> Int? {
        guard isTimed else { return nil }
        var found: Int?
        for (i, line) in lines.enumerated() {
            guard let start = line.start else { continue }
            if start <= time { found = i } else { break }
        }
        return found
    }
}

/// Reads LRC text (`[mm:ss.xx] words`), the format LRCLIB and Plex serve for synced lyrics.
public enum LRC {
    /// Timed lines in time order. A line with several stamps (`[00:12.00][00:45.00] hook`)
    /// repeats per stamp; tags such as `[ar:…]` and `[offset:…]` are metadata (offset is applied).
    /// Returns nil when no line carries a timestamp.
    public static func parse(_ text: String) -> Lyrics? {
        var lines: [LyricLine] = []
        var offset = 0.0
        for raw in text.split(whereSeparator: \.isNewline) {
            var rest = Substring(raw).trimmingCharacters(in: .whitespaces)[...]
            var stamps: [TimeInterval] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                if let seconds = stamp(tag) {
                    stamps.append(seconds)
                } else if tag.lowercased().hasPrefix("offset:"), let ms = Double(tag.dropFirst(7).trimmingCharacters(in: .whitespaces)) {
                    offset = ms / 1000
                }
                rest = rest[rest.index(after: close)...]
            }
            guard !stamps.isEmpty else { continue }
            let words = rest.trimmingCharacters(in: .whitespaces)
            for s in stamps { lines.append(LyricLine(start: s, text: words)) }
        }
        guard !lines.isEmpty else { return nil }
        lines = lines.map { LyricLine(start: max(0, ($0.start ?? 0) - offset), text: $0.text) }
        lines.sort { ($0.start ?? 0) < ($1.start ?? 0) }
        return Lyrics(lines: lines, isTimed: true)
    }

    /// Plain text: one line per row, blank rows kept as gaps. Nil when empty.
    public static func plain(_ text: String) -> Lyrics? {
        let rows = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }
        guard rows.contains(where: { !$0.isEmpty }) else { return nil }
        return Lyrics(lines: rows.map { LyricLine(text: $0) }, isTimed: false)
    }

    /// `mm:ss`, `mm:ss.xx` or `mm:ss.xxx` as seconds; nil for tags like `ar:name`.
    static func stamp(_ tag: Substring) -> TimeInterval? {
        let parts = tag.split(separator: ":")
        guard parts.count == 2, let minutes = Int(parts[0]), let seconds = Double(parts[1]), seconds < 60,
              parts[1].allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
        return Double(minutes) * 60 + seconds
    }
}
