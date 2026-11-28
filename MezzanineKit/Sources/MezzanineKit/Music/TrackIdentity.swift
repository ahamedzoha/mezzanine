import Foundation

/// Track and album identity matching for Mezzanine.
///
/// Ports Crossfade's `apps/api/src/matching` (commit 38cfe71) so that Mezzanine can group
/// duplicate albums, match scrobble results to library tracks, and reconcile Aurral data.
///
/// ## Deliberate differences from TypeScript
/// - Swift's `String` is already in Unicode scalar form; we use `String.applyingTransform(.NFKD)`
///   then filter combining marks (Unicode general category Mn) to match JS `normalize("NFKD")` +
///   the combining-character strip regex `/[\u0300-\u036f]/g`.
/// - JS `\w` in character classes matches `[a-zA-Z0-9_]` only; we match that exactly rather than
///   using Swift's Unicode-aware `\w`.
/// - `String.lowercased()` in Swift applies full Unicode case folding, matching JS `.toLowerCase()`.
/// - Full-width to half-width conversion is handled by the NFKD transform (matches JS NFKD).
/// - Curly quotes (Unicode) are normalised to ASCII apostrophe before the `fold` clean step.

// MARK: - Namespace

/// Namespace for track-identity matching. Use `TrackIdentity.score(_:_:)` to compare two
/// tracks and `TrackIdentity.bestMatch(for:in:)` to find the best candidate from a list.
public enum TrackIdentity {

    // MARK: - Candidate

    /// A track description used as an input to scoring.
    public struct Candidate: Sendable, Hashable {
        public var title: String
        public var artists: [String]
        public var album: String?
        public var durationMs: Int?
        public var isrc: String?

        public init(
            title: String,
            artists: [String],
            album: String? = nil,
            durationMs: Int? = nil,
            isrc: String? = nil
        ) {
            self.title = title
            self.artists = artists
            self.album = album
            self.durationMs = durationMs
            self.isrc = isrc
        }
    }

    // MARK: - DedupeMode

    /// Controls how strict the `sameRecording` check is about duration differences.
    public enum DedupeMode: Sendable {
        /// Two tracks must have durations within 6 seconds of each other (or lack duration data).
        case strict
        /// Duration is ignored; only title key, version tag, and primary artist must match.
        case loose
    }

    // MARK: - ScoreBreakdown

    /// Detailed output of `scoreMatch`.
    public struct ScoreBreakdown: Sendable {
        /// Combined match score, 0–1, rounded to 3 decimal places.
        public var score: Double
        /// Title similarity component, 0–1.
        public var title: Double
        /// Artist similarity component, 0–1.
        public var artist: Double
        /// Duration score component, 0–1.
        public var duration: Double
        /// True when the two tracks carry different version tags (e.g. live vs. studio).
        public var versionMismatch: Bool
    }

    // MARK: - TitleParts

    /// The parsed result of a track title: a normalised key and an optional version tag.
    public struct TitleParts: Sendable, Equatable {
        /// Normalised, punctuation-stripped base title for exact/fuzzy matching.
        public var key: String
        /// Non-nil when the title includes a version tag that distinguishes recordings
        /// (e.g. `"live"`, `"acoustic"`, `"remix:neon remix"`).
        public var versionTag: String?
    }

    // MARK: - Public API

    /// Score how likely `candidate` is the same recording as `target`. Returns 1.0 on ISRC match.
    public static func score(_ target: Candidate, _ candidate: Candidate) -> Double {
        scoreMatch(target: target, candidate: candidate).score
    }

    /// Find the best match for `target` in `candidates`, or `nil` when the list is empty.
    ///
    /// Returns the highest-scoring candidate and its score. ISRC matches always win.
    public static func bestMatch(
        for target: Candidate,
        in candidates: [Candidate]
    ) -> (Candidate, Double)? {
        guard !candidates.isEmpty else { return nil }
        var best: (Candidate, Double)? = nil
        for c in candidates {
            let s = score(target, c)
            if best == nil || s > best!.1 {
                best = (c, s)
            }
        }
        return best
    }

    /// Whether two tracks are the same recording for dedupe purposes.
    ///
    /// ISRC equality short-circuits all other checks, mirroring the TypeScript.
    public static func sameRecording(_ a: Candidate, _ b: Candidate, mode: DedupeMode) -> Bool {
        // ISRC short-circuit.
        if let ai = a.isrc, let bi = b.isrc, ai.uppercased() == bi.uppercased() { return true }
        let ta = parseTitle(a.title, artists: a.artists)
        let tb = parseTitle(b.title, artists: b.artists)
        guard ta.key == tb.key,
              (ta.versionTag ?? "") == (tb.versionTag ?? "") else { return false }
        guard artistKey(a.artists) == artistKey(b.artists) else { return false }
        if mode == .loose { return true }
        guard let da = a.durationMs, let db = b.durationMs else { return true }
        return abs(da - db) <= 6_000
    }

    /// Full scoring breakdown between two tracks.
    public static func scoreMatch(target: Candidate, candidate: Candidate) -> ScoreBreakdown {
        // ISRC short-circuit.
        if let ti = target.isrc, let ci = candidate.isrc,
           ti.uppercased() == ci.uppercased() {
            return ScoreBreakdown(score: 1, title: 1, artist: 1, duration: 1, versionMismatch: false)
        }

        let t = parseTitle(target.title, artists: target.artists)
        let c = parseTitle(candidate.title, artists: candidate.artists)

        // Title similarity: Dice over bigrams, boosted when one key contains the other.
        var titleScore = similarity(t.key, c.key)
        if titleScore < 1,
           t.key.count > 3, c.key.count > 3,
           t.key.contains(c.key) || c.key.contains(t.key) {
            titleScore = max(titleScore, 0.88)
        }

        // Artist similarity: best pairwise Dice across all tokens.
        let ta = artistTokens(target.artists)
        let ca = artistTokens(candidate.artists)
        var artistScore = similarity(artistKey(target.artists), artistKey(candidate.artists))
        for x in ta {
            for y in ca { artistScore = max(artistScore, similarity(x, y)) }
        }

        let dur = durationScore(target.durationMs, candidate.durationMs)
        let versionMismatch = (t.versionTag ?? "") != (c.versionTag ?? "")
        let penalty = versionMismatch ? 0.25 : 0.0

        let raw = 0.5 * titleScore + 0.3 * artistScore + 0.2 * dur - penalty
        let clamped = max(0, min(1, raw))
        let rounded = (clamped * 1_000).rounded() / 1_000

        return ScoreBreakdown(
            score: rounded,
            title: titleScore,
            artist: artistScore,
            duration: dur,
            versionMismatch: versionMismatch
        )
    }

    // MARK: - Normalisation (public so tests can pin each step)

    /// Unicode-normalise, strip combining diacritics, lowercase, and fold punctuation.
    ///
    /// Matches JS `fold()`: NFKD → strip combining chars → lowercase → apostrophe normalise
    /// → `&`/`+` → "and".
    public static func fold(_ value: String) -> String {
        // NFKD decomposition + strip combining marks (Unicode category Mn, U+0300–U+036F
        // and beyond; we use the same scalar range JS strips: U+0300–U+036F).
        let nfkd = value.applyingTransform(.init("NFKD"), reverse: false) ?? value
        let stripped = nfkd.unicodeScalars.filter { scalar in
            // Keep anything that is not a combining character (Mn).
            // JS strips U+0300–U+036F; Swift's NFKD may produce a wider range, but limiting
            // to Mn ensures we match JS output for the characters actually encountered.
            scalar.properties.generalCategory != .nonspacingMark
        }
        var s = String(String.UnicodeScalarView(stripped))
        s = s.lowercased()
        // Normalise various apostrophes/right-single-quote/backtick/acute to ASCII apostrophe.
        // JS: .replace(/[''`´]/g, "'")  — U+2018 ' U+2019 ' U+0060 ` U+00B4 ´
        s = s.replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "`", with: "'")
            .replacingOccurrences(of: "\u{00B4}", with: "'")
        // & → " and ", + → " and "
        s = s.replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "+", with: " and ")
        return s
    }

    /// Parse a track title into a normalised base key and an optional version tag.
    public static func parseTitle(_ title: String, artists: [String] = []) -> TitleParts {
        var base = fold(title)
        var extras: [String] = []

        // Extract bracketed segments: (…), […], {…}
        base = extractBrackets(from: base, into: &extras)

        // Dash suffixes: "Title – Live at Venue", "Artist – Title"
        let dashParts = base.components(separatedBy: dashRegex)
        if dashParts.count > 1 {
            let head = clean(dashParts[0])
            let artistKeys = artists.map { clean(fold($0)) }
            if artistKeys.contains(where: { !$0.isEmpty && (head == $0 || head.hasPrefix($0)) }) {
                // YouTube style: "Artist – Title (Noise)"
                base = dashParts.dropFirst().joined(separator: " - ")
                let rest = base.components(separatedBy: dashRegex)
                base = rest[0]
                extras.append(contentsOf: rest.dropFirst())
            } else {
                base = dashParts[0]
                extras.append(contentsOf: dashParts.dropFirst())
            }
        }

        // Inline feat. without brackets.
        if let range = base.range(of: featPattern, options: .regularExpression),
           range.lowerBound > base.startIndex {
            base = String(base[..<range.lowerBound])
        }

        // Classify extras into version tags or noise.
        var versionTag: String? = nil
        for extra in extras {
            let e = clean(extra)
            guard !e.isEmpty else { continue }
            guard !matchesFeat(e) else { continue }
            if let tag = versionWordTag(for: e) {
                versionTag = tag
                break
            }
            if matchesNoise(e) { continue }
        }

        let key = clean(base)
        return TitleParts(
            key: key.isEmpty ? clean(fold(title)) : key,
            versionTag: versionTag
        )
    }

    /// Primary artist key — strips "The " prefix and " - Topic" suffix, folds and splits.
    public static func artistKey(_ artists: [String]) -> String {
        let joined = fold(artists.filter { !$0.isEmpty }.joined(separator: ", "))
        let first = artistSplit(joined).first ?? joined
        return clean(first)
            .replacingOccurrences(of: "^the ", with: "", options: .regularExpression)
            .replacingOccurrences(of: " - topic$", with: "", options: .regularExpression)
    }

    /// All artist tokens (for pairwise overlap scoring).
    public static func artistTokens(_ artists: [String]) -> Set<String> {
        var out = Set<String>()
        for part in artistSplit(fold(artists.joined(separator: ", "))) {
            let c = clean(part)
                .replacingOccurrences(of: "^the ", with: "", options: .regularExpression)
                .replacingOccurrences(of: " topic$", with: "", options: .regularExpression)
            if !c.isEmpty { out.insert(c) }
        }
        return out
    }

    /// Split a display string like "Band A & Band B" into individual names.
    public static func splitArtistString(_ value: String) -> [String] {
        // JS: /\s*(?:,|&| x | feat\.? | ft\.? )\s*/i
        // Note: in the JS, the " x " and " feat.? " alternatives include surrounding spaces
        // as part of the delimiter so we match that precisely.
        let pattern = #"\s*(?:,|&| x | feat\.? | ft\.? )\s*"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return [value]
        }
        let ns = value as NSString
        let range = NSRange(location: 0, length: ns.length)
        let parts = regex.splitString(value, range: range)
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Sørensen–Dice similarity over character bigrams, 0–1.
    public static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        if a.isEmpty || b.isEmpty { return 0 }
        let A = bigrams(a)
        let B = bigrams(b)
        var overlap = 0
        var total = 0
        for (g, n) in A {
            overlap += min(n, B[g] ?? 0)
            total += n
        }
        for n in B.values { total += n }
        return Double(2 * overlap) / Double(total)
    }

    /// Duration match score. Missing duration → 0.7 (neutral).
    public static func durationScore(_ a: Int?, _ b: Int?) -> Double {
        guard let a, let b, a > 0, b > 0 else { return 0.7 }
        let diff = Double(abs(a - b)) / 1_000
        if diff <= 2  { return 1 }
        if diff <= 5  { return 0.85 }
        if diff <= 10 { return 0.6 }
        if diff <= 20 { return 0.3 }
        return 0
    }

    // MARK: - Private helpers

    /// Strip apostrophes, replace non-alphanumeric (ASCII only, matching JS `[^a-z0-9\s]`) with
    /// space, collapse whitespace.
    private static func clean(_ value: String) -> String {
        var s = value.replacingOccurrences(of: "'", with: "")
        // JS: [^a-z0-9\s] — replace anything that's not a-z, 0-9 or whitespace with a space.
        // We use an ASCII-only character class to exactly match JS \w behaviour.
        s = replaceNonAlphanumeric(s)
        // Collapse and trim.
        let components = s.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        return components.joined(separator: " ")
    }

    /// Replace characters that are not `[a-z0-9]` or whitespace with a space.
    /// Mirrors JS `/[^a-z0-9\s]/g` → `' '`, which uses ASCII-only character classes.
    private static func replaceNonAlphanumeric(_ s: String) -> String {
        var result = ""
        result.reserveCapacity(s.utf8.count)
        for ch in s.unicodeScalars {
            let v = ch.value
            if (v >= 0x61 && v <= 0x7A)   // a-z
                || (v >= 0x30 && v <= 0x39) // 0-9
                || v == 0x20 || v == 0x09 || v == 0x0A || v == 0x0D // whitespace
            {
                result.append(Character(ch))
            } else {
                result.append(" ")
            }
        }
        return result
    }

    // MARK: Bracket extraction

    private static func extractBrackets(from base: String, into extras: inout [String]) -> String {
        // Matches (…), […], {…} non-greedily. We iterate because there can be multiple.
        let pattern = #"[(\[{]([^)\]}]*)[)\]}]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return base }
        var result = base
        var keepGoing = true
        while keepGoing {
            let ns = result as NSString
            let range = NSRange(location: 0, length: ns.length)
            if let match = regex.firstMatch(in: result, range: range),
               let innerRange = Range(match.range(at: 1), in: result),
               let fullRange = Range(match.range, in: result) {
                extras.append(String(result[innerRange]))
                result = result.replacingCharacters(in: fullRange, with: " ")
            } else {
                keepGoing = false
            }
        }
        return result
    }

    // MARK: Dash splitting

    // Matches " - ", " – ", " — " (space + dash variant + space).
    private static let dashRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"\s[-–—]\s"#)
    }()

    // MARK: Feat pattern

    private static let featPattern =
        #"\b(feat\.?|ft\.?|featuring|with)\b"#

    private static func matchesFeat(_ s: String) -> Bool {
        (try? NSRegularExpression(pattern: featPattern))?.firstMatch(
            in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    // MARK: Noise

    private static let noisePattern =
        #"\b(remaster(ed)?|\d{4} remaster(ed)?|mono|stereo|version|edit|radio|single|album|original|explicit|clean|deluxe|bonus( track)?|anniversary|edition|expanded|from .+|official( music)?( video| audio)?|music video|lyric(s)?( video)?|visuali[sz]er|audio|video|hd|hq|4k|mv|prod\.? .+)\b"#

    private static func matchesNoise(_ s: String) -> Bool {
        (try? NSRegularExpression(pattern: noisePattern))?.firstMatch(
            in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    // MARK: Version words

    private static let versionWords: [(NSRegularExpression, String)] = {
        let pairs: [(String, String)] = [
            (#"\b(live|en vivo|ao vivo)\b"#, "live"),
            (#"\bacoustic\b"#, "acoustic"),
            (#"\bunplugged\b"#, "acoustic"),
            (#"\binstrumental\b"#, "instrumental"),
            (#"\bkaraoke\b"#, "karaoke"),
            (#"\bdemo\b"#, "demo"),
            (#"\b(sped up|speed up|slowed|reverb|nightcore)\b"#, "altered"),
            (#"\b(remix|rmx|bootleg|rework|vip mix|club mix|dub mix|extended mix)\b"#, "remix"),
            (#"\bcover\b"#, "cover"),
            (#"\b(a cappella|acapella)\b"#, "acapella"),
        ]
        return pairs.compactMap { pattern, tag in
            guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (re, tag)
        }
    }()

    private static func versionWordTag(for extra: String) -> String? {
        let range = NSRange(extra.startIndex..., in: extra)
        for (re, tag) in versionWords {
            if re.firstMatch(in: extra, range: range) != nil {
                if tag == "remix" {
                    // Include the full cleaned extra so "neon remix" becomes the qualifier.
                    return "remix:\(extra)"
                }
                return tag
            }
        }
        return nil
    }

    // MARK: Artist splitting

    // Matches the same delimiters as the TS ARTIST_SPLIT regex.
    private static let artistSplitPattern =
        #"\s*(?:,|;|\/|\band\b|\bx\b|\bvs\.?\b|\bfeat\.?|\bft\.?|\bfeaturing\b|\bwith\b)\s*"#

    private static func artistSplit(_ value: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: artistSplitPattern) else {
            return [value]
        }
        let ns = value as NSString
        return regex.splitString(value, range: NSRange(location: 0, length: ns.length))
            .filter { !$0.isEmpty }
    }

    // MARK: Bigrams (Dice)

    private static func bigrams(_ s: String) -> [String: Int] {
        var out = [String: Int]()
        let padded = " \(s) "
        let chars = Array(padded)
        for i in 0 ..< chars.count - 1 {
            let g = String([chars[i], chars[i + 1]])
            out[g, default: 0] += 1
        }
        return out
    }
}

// MARK: - NSRegularExpression + split helper

private extension NSRegularExpression {
    /// Splits `string` by all non-overlapping matches of this regex, returning the pieces between.
    func splitString(_ string: String, range: NSRange) -> [String] {
        let ns = string as NSString
        var parts: [String] = []
        var lastEnd = 0
        for match in matches(in: string, range: range) {
            let matchRange = match.range
            if matchRange.location >= lastEnd {
                let piece = ns.substring(with: NSRange(location: lastEnd, length: matchRange.location - lastEnd))
                parts.append(piece)
                lastEnd = matchRange.location + matchRange.length
            }
        }
        parts.append(ns.substring(from: lastEnd))
        return parts
    }
}

// MARK: - String + components(separatedBy: NSRegularExpression)

private extension String {
    func components(separatedBy regex: NSRegularExpression) -> [String] {
        regex.splitString(self, range: NSRange(startIndex..., in: self))
    }
}
