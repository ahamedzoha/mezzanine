import Foundation

/// Finds how far a subtitle track is off from the dialogue: the offset to add to every cue
/// so it appears when the words are spoken.
///
/// Two ways, best first:
/// - **Words**: the subtitle and the speech share a language, so a cue's first words are
///   found in the transcript and their times compared. Precise to a frame or two.
/// - **Speech**: any language. The cues' on-screen spans are slid along the spans where
///   someone is talking until they overlap most.
public enum TimingMatcher {
    public struct Estimate: Sendable, Equatable {
        public enum Method: Sendable, Equatable { case words, speech }
        /// Seconds to add to the cue times (positive: subtitles were early).
        public var offset: Double
        /// Lines that agreed (words) or lines inside the listened span (speech).
        public var lines: Int
        public var method: Method
    }

    /// How far either way the search reaches.
    public static let reach = 30.0

    public static func estimate(cues: [TimedLine], words: [SpokenWord]) -> Estimate? {
        byWords(cues: cues, words: words) ?? bySpeech(cues: cues, words: words)
    }

    // MARK: Words

    static let wordsNeeded = 4

    public static func byWords(cues: [TimedLine], words: [SpokenWord]) -> Estimate? {
        let spoken = words.map { normalize($0.text) }
        var offsets: [Double] = []
        for cue in cues {
            let tokens = tokens(cue.text)
            let k = min(3, tokens.count)
            guard k >= 2, tokens.prefix(k).joined().count >= 8 else { continue }
            var hits: [Int] = []
            var i = 0
            while i + k <= spoken.count {
                if abs(words[i].start - cue.start) <= reach, Array(spoken[i..<(i + k)]) == Array(tokens.prefix(k)) {
                    hits.append(i)
                }
                i += 1
            }
            // The same three words twice in a minute: can't tell which, skip the line.
            guard hits.count == 1, let hit = hits.first else { continue }
            offsets.append(words[hit].start - cue.start)
        }
        guard offsets.count >= wordsNeeded else { return nil }
        let median = offsets.sorted()[offsets.count / 2]
        let agreeing = offsets.filter { abs($0 - median) <= 0.6 }
        guard agreeing.count >= wordsNeeded, Double(agreeing.count) >= Double(offsets.count) * 0.6 else { return nil }
        let mean = agreeing.reduce(0, +) / Double(agreeing.count)
        return Estimate(offset: (mean * 10).rounded() / 10, lines: agreeing.count, method: .words)
    }

    static func normalize(_ word: String) -> String {
        String(word.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// A cue's words, without speaker dashes, tags in brackets or sound descriptions.
    static func tokens(_ text: String) -> [String] {
        var cleaned = text
        for (open, close) in [("[", "]"), ("(", ")"), ("<", ">"), ("{", "}")] {
            while let a = cleaned.range(of: open), let b = cleaned.range(of: close, range: a.upperBound..<cleaned.endIndex) {
                cleaned.removeSubrange(a.lowerBound..<b.upperBound)
            }
        }
        return cleaned.split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "—" })
            .map { normalize(String($0)) }.filter { !$0.isEmpty }
    }

    // MARK: Speech

    static let speechStep = 0.05

    public static func bySpeech(cues: [TimedLine], words: [SpokenWord]) -> Estimate? {
        guard let first = words.first?.start, let last = words.last?.end, last - first >= 40 else { return nil }
        let speech = spans(words)
        let shown = cues.filter { !tokens($0.text).isEmpty }
        var best: (offset: Double, score: Double, count: Int)?
        var scores: [Double] = []
        var d = -reach
        while d <= reach + 1e-9 {
            var covered = 0.0, total = 0.0, count = 0
            for cue in shown {
                let a = cue.start + d, b = cue.end + d
                guard a >= first, b <= last else { continue }
                total += b - a
                count += 1
                for s in speech where s.upperBound > a && s.lowerBound < b {
                    covered += min(b, s.upperBound) - max(a, s.lowerBound)
                }
            }
            if count >= 6, total > 0 {
                let score = covered / total
                scores.append(score)
                if best == nil || score > best!.score { best = (d, score, count) }
            }
            d += speechStep
        }
        guard let best, scores.count > 20 else { return nil }
        // A real fit stands well clear of the typical overlap.
        let typical = scores.sorted()[scores.count / 2]
        guard best.score >= 0.6, best.score - typical >= 0.15 else { return nil }
        return Estimate(offset: (best.offset * 10).rounded() / 10, lines: best.count, method: .speech)
    }

    /// Spans where someone is speaking: words closer than 0.4 s joined.
    static func spans(_ words: [SpokenWord]) -> [ClosedRange<Double>] {
        var out: [ClosedRange<Double>] = []
        for w in words.sorted(by: { $0.start < $1.start }) {
            let end = max(w.end, w.start + 0.05)
            if let lastSpan = out.last, w.start - lastSpan.upperBound < 0.4 {
                out[out.count - 1] = lastSpan.lowerBound...max(lastSpan.upperBound, end)
            } else {
                out.append(w.start...end)
            }
        }
        return out
    }
}
