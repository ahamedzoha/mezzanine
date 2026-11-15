import Foundation
import AVFAudio

/// A slice of the playing audio for speech recognition: mono 48 kHz Float32 PCM and the
/// source time (seconds on the file's own timeline) of its first sample.
public struct SpeechAudio: @unchecked Sendable {
    public let buffer: AVAudioPCMBuffer
    public let time: Double
    /// A gap before this slice (seek, track switch, dropped audio).
    public let discontinuity: Bool

    public init(buffer: AVAudioPCMBuffer, time: Double, discontinuity: Bool) {
        self.buffer = buffer
        self.time = time
        self.discontinuity = discontinuity
    }
}

/// One recognized word and when it was spoken (source seconds).
public struct SpokenWord: Sendable, Equatable {
    public var text: String
    public var start: Double
    public var end: Double
    /// False when the word continues the previous one without a space ("'s", "n't").
    public var spaced: Bool

    public init(_ text: String, start: Double, end: Double, spaced: Bool = true) {
        self.text = text
        self.start = start
        self.end = end
        self.spaced = spaced
    }
}

extension SpokenWord {
    /// The recognizer's word ranges run edge to edge, so a word after a pause "starts" where
    /// the pause began (measured: up to a second early in films). Caps each word at a natural
    /// length for its letters, so its start lands near the voice.
    public static func tightened(_ words: [SpokenWord]) -> [SpokenWord] {
        words.map { word in
            let letters = word.text.filter(\.isLetter).count
            let natural = 0.12 + 0.075 * Double(max(1, letters))
            guard word.end - word.start > natural * 1.5 else { return word }
            var tight = word
            tight.start = word.end - natural
            return tight
        }
    }
}

/// A subtitle line: text shown from `start` to `end` (source seconds).
public struct TimedLine: Sendable, Equatable, Codable, Hashable {
    public var start: Double
    public var end: Double
    public var text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// Turns recognized phrases into subtitle lines the way a subtitler would: at most two rows
/// of about 42 characters, at most ~6 s on screen, broken at sentence ends and pauses first.
public enum CueBuilder {
    public static let rowWidth = 42
    static let maxCharacters = 84
    static let maxSeconds = 6.0
    static let pauseBreak = 1.2
    static let minimumDuration = 1.0
    static let tail = 0.4

    public static func lines(from words: [SpokenWord]) -> [TimedLine] {
        var groups: [[SpokenWord]] = []
        var current: [SpokenWord] = []
        func length(_ group: [SpokenWord]) -> Int { joined(group).count }
        let words = words.filter { !$0.text.isEmpty }
        for (i, word) in words.enumerated() {
            if let first = current.first, let last = current.last {
                let gap = word.start - last.end
                let sentenceEnded = last.text.last.map { ".?!…".contains($0) } ?? false
                // A phrase's last word or two never sits alone on the next line.
                let rest = words[i...].prefix { $0.start - last.end <= pauseBreak }
                let tail = !rest.isEmpty && rest.count <= 2 && length(current + rest) <= maxCharacters
                    && (rest.last?.end ?? 0) - first.start <= maxSeconds + 1.5
                let tooLong = length(current + [word]) > maxCharacters
                let tooSlow = word.end - first.start > maxSeconds && !tail
                if gap > pauseBreak || tooLong || tooSlow || (sentenceEnded && length(current) >= 16) {
                    groups.append(current)
                    current = []
                }
            }
            current.append(word)
        }
        if !current.isEmpty { groups.append(current) }
        let built = groups.compactMap { group -> TimedLine? in
            guard let first = group.first, let last = group.last else { return nil }
            let text = joined(group)
            guard !text.isEmpty else { return nil }
            let end = max(last.end + tail, first.start + minimumDuration)
            return TimedLine(start: first.start, end: end, text: wrap(text))
        }
        return merge([], built)
    }

    /// Appends `new` lines to `existing` (sorted), dropping any that overlap lines already
    /// written, and trims each line's end so it never runs into the next one.
    public static func merge(_ existing: [TimedLine], _ new: [TimedLine]) -> [TimedLine] {
        var all = existing
        for line in new {
            let length = max(0.1, line.end - line.start)
            let clash = existing.contains { old in
                let overlap = min(old.end, line.end) - max(old.start, line.start)
                return overlap > min(1.0, length * 0.5)
            }
            if !clash { all.append(line) }
        }
        all.sort { $0.start < $1.start }
        for i in all.indices.dropLast() where all[i].end > all[i + 1].start - 0.05 {
            all[i].end = max(all[i].start + 0.3, all[i + 1].start - 0.05)
        }
        return all
    }

    static func joined(_ group: [SpokenWord]) -> String {
        var text = ""
        for word in group {
            if !text.isEmpty, word.spaced { text += " " }
            text += word.text
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// One row if it fits, else two rows broken at the space nearest the middle (a break after
    /// a comma or full stop wins when it's close).
    public static func wrap(_ text: String, width: Int = rowWidth) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        guard flat.count > width else { return flat }
        let chars = Array(flat)
        let middle = chars.count / 2
        var best: Int?
        var bestScore = Int.max
        for (i, c) in chars.enumerated() where c == " " {
            var score = abs(i - middle) * 2
            if i > 0, ",.;:?!".contains(chars[i - 1]) { score -= 8 }
            if score < bestScore { bestScore = score; best = i }
        }
        guard let split = best else { return flat }
        return String(chars[..<split]) + "\n" + String(chars[(split + 1)...])
    }
}

/// Reads and writes SubRip, the format generated subtitles are kept in.
public enum SRT {
    public static func write(_ lines: [TimedLine]) -> String {
        lines.enumerated().map { i, line in
            "\(i + 1)\n\(stamp(line.start)) --> \(stamp(line.end))\n\(line.text)\n"
        }.joined(separator: "\n")
    }

    public static func parse(_ text: String) -> [TimedLine] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var lines: [TimedLine] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let rows = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let arrow = rows.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = rows[arrow].components(separatedBy: "-->")
            guard parts.count == 2, let start = seconds(parts[0]), let end = seconds(parts[1]) else { continue }
            let body = rows[(arrow + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            lines.append(TimedLine(start: start, end: end, text: body))
        }
        return lines.sorted { $0.start < $1.start }
    }

    static func stamp(_ t: Double) -> String {
        let ms = Int((max(0, t) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }

    static func seconds(_ s: String) -> Double? {
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: " ").first?
            .replacingOccurrences(of: ",", with: ".").split(separator: ":") ?? []
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let sec = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + sec
    }
}

/// How a subtitle line is cut up for translation, and put back together.
/// Speaker lines ("- Where?\n- Here.") are translated one by one so each keeps its dash; any
/// other line is translated as one sentence and wrapped again afterwards.
public enum TranslationPieces {
    public static func pieces(_ text: String) -> [String] {
        let rows = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if rows.count > 1, rows.allSatisfy({ $0.hasPrefix("-") || $0.hasPrefix("–") || $0.hasPrefix("—") }) {
            return rows.map { String($0.drop { "-–— ".contains($0) }) }.filter { !$0.isEmpty }
        }
        let flat = rows.joined(separator: " ")
        return flat.isEmpty ? [] : [flat]
    }

    /// The translated line, or nil while any piece is still missing.
    public static func compose(_ text: String, _ table: [String: String]) -> String? {
        let parts = pieces(text)
        guard !parts.isEmpty else { return nil }
        var out: [String] = []
        for part in parts {
            guard let translated = table[part] else { return nil }
            out.append(translated)
        }
        if out.count > 1 { return out.map { "- " + $0 }.joined(separator: "\n") }
        return CueBuilder.wrap(out[0])
    }
}
