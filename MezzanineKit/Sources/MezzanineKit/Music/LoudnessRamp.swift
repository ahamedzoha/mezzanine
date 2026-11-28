import Foundation

/// Plex's loudness ramps: `startRamp` and `endRamp` on a track's audio stream.
///
/// The text is `"dB seconds;dB seconds;…"`, for example `"-51.00 0.00;-8.03 0.10;0.49 84.10;"`.
/// Each pair says how loud the audio is (dB, relative to the track's loudest part, so the last
/// pair is about 0) and how far from the track's edge that is: seconds after the start for a
/// start ramp, seconds before the end for an end ramp. The first pair sits at the edge itself,
/// so a quiet intro or a long fade-out shows as low levels at large distances. Crossfade
/// planning reads them to find how much of an edge is already quiet.
public struct LoudnessRamp: Sendable, Hashable, Codable {
    public struct Point: Sendable, Hashable, Codable {
        public var db: Double
        public var seconds: Double
        public init(db: Double, seconds: Double) {
            self.db = db
            self.seconds = seconds
        }
    }

    public var points: [Point]

    public init(points: [Point]) { self.points = points }

    /// Parses Plex's text. Malformed pairs are skipped; nil text or no pairs gives an empty ramp.
    public init(parsing text: String?) {
        guard let text else {
            points = []
            return
        }
        points = text.split(separator: ";").compactMap { pair in
            let parts = pair.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 2, let db = Double(parts[0]), let seconds = Double(parts[1]),
                  db.isFinite, seconds.isFinite, seconds >= 0 else { return nil }
            return Point(db: db, seconds: seconds)
        }
    }

    public var isEmpty: Bool { points.isEmpty }

    /// How far from the edge the audio first reaches `db` or louder, interpolated between the
    /// two pairs around it. Nil when the ramp never gets that loud (or is empty).
    public func distance(reaching db: Double) -> Double? {
        guard let first = points.first else { return nil }
        if first.db >= db { return first.seconds }
        for (a, b) in zip(points, points.dropFirst()) where b.db >= db {
            guard b.db > a.db else { return b.seconds }
            let t = (db - a.db) / (b.db - a.db)
            return a.seconds + t * (b.seconds - a.seconds)
        }
        return nil
    }

    /// The level at `seconds` from the edge, interpolated; the nearest pair outside the range.
    public func level(at seconds: Double) -> Double? {
        guard let first = points.first, let last = points.last else { return nil }
        if seconds <= first.seconds { return first.db }
        if seconds >= last.seconds { return last.db }
        for (a, b) in zip(points, points.dropFirst()) where seconds <= b.seconds {
            guard b.seconds > a.seconds else { return b.db }
            let t = (seconds - a.seconds) / (b.seconds - a.seconds)
            return a.db + t * (b.db - a.db)
        }
        return last.db
    }
}
