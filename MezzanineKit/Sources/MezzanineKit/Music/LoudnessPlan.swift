import Foundation

/// How a track is levelled so a quiet record and a loud one play at a similar volume.
public enum LoudnessMode: String, Sendable, Codable, CaseIterable {
    case off
    /// Each track to the same loudness.
    case track
    /// One gain for a whole album, so its own dynamics between songs stay.
    case album
    /// Album gain while an album plays in its own order, track gain otherwise.
    case auto

    public var label: String {
        switch self {
        case .off: return "Off"
        case .track: return "Track"
        case .album: return "Album"
        case .auto: return "Automatic"
        }
    }
}

/// The loudness numbers Plex measured for one track (its audio stream).
public struct TrackLoudness: Sendable, Hashable, Codable {
    /// dB to add to reach the reference level.
    public var gain: Double?
    public var albumGain: Double?
    /// Linear sample peaks (1.0 is full scale).
    public var peak: Double?
    public var albumPeak: Double?
    /// Integrated loudness, LUFS.
    public var loudness: Double?

    public init(gain: Double? = nil, albumGain: Double? = nil, peak: Double? = nil, albumPeak: Double? = nil,
                loudness: Double? = nil) {
        self.gain = gain
        self.albumGain = albumGain
        self.peak = peak
        self.albumPeak = albumPeak
        self.loudness = loudness
    }

    public init(_ stream: PlexStream?) {
        self.init(gain: stream?.gain, albumGain: stream?.albumGain, peak: stream?.peak,
                  albumPeak: stream?.albumPeak, loudness: stream?.loudness)
    }

    public var isMeasured: Bool { gain != nil || albumGain != nil }
}

/// What gain to put in front of a track, as a pure function of the setting and the measurements.
public struct LoudnessPlan: Sendable, Hashable, Codable {
    public var mode: LoudnessMode
    /// Added after the leveling gain, dB. Plex's reference is quiet (about −23 LUFS), so a
    /// positive pre-amp is normal; the peak guard keeps it from clipping.
    public var preAmpDB: Double
    /// Never raise a track so its measured peak passes this linear level.
    public var peakGuard: Bool
    public var ceiling: Double
    /// Hard limits on the total gain, dB.
    public var minimumDB: Double
    public var maximumDB: Double

    public init(mode: LoudnessMode = .auto, preAmpDB: Double = 0, peakGuard: Bool = true,
                ceiling: Double = 0.98, minimumDB: Double = -24, maximumDB: Double = 12) {
        self.mode = mode
        self.preAmpDB = preAmpDB
        self.peakGuard = peakGuard
        self.ceiling = ceiling
        self.minimumDB = minimumDB
        self.maximumDB = maximumDB
    }

    public struct Result: Sendable, Hashable {
        public var gainDB: Double
        /// The peak guard reduced the gain.
        public var limitedByPeak: Bool
        public var linear: Double { pow(10, gainDB / 20) }
    }

    /// `inAlbumOrder`: the track plays as part of its album, in the album's own order (what
    /// `.auto` keys on). A track without the preferred measurement falls back to the other one;
    /// an unmeasured track gets only the pre-amp (never a guess).
    public func gain(for loudness: TrackLoudness, inAlbumOrder: Bool = false) -> Result {
        let useAlbum: Bool
        switch mode {
        case .off: return Result(gainDB: 0, limitedByPeak: false)
        case .track: useAlbum = false
        case .album: useAlbum = true
        case .auto: useAlbum = inAlbumOrder
        }
        let chosenGain: Double?
        let chosenPeak: Double?
        if useAlbum {
            chosenGain = loudness.albumGain ?? loudness.gain
            chosenPeak = loudness.albumGain != nil ? (loudness.albumPeak ?? loudness.peak) : loudness.peak
        } else {
            chosenGain = loudness.gain ?? loudness.albumGain
            chosenPeak = loudness.gain != nil ? loudness.peak : (loudness.albumPeak ?? loudness.peak)
        }
        guard let chosenGain else {
            return Result(gainDB: min(max(preAmpDB, minimumDB), maximumDB), limitedByPeak: false)
        }
        var db = chosenGain + preAmpDB
        var limited = false
        if peakGuard, let peak = chosenPeak, peak > 0, ceiling > 0 {
            let headroom = 20 * log10(ceiling / peak)
            if db > headroom {
                db = headroom
                limited = true
            }
        }
        return Result(gainDB: min(max(db, minimumDB), maximumDB), limitedByPeak: limited)
    }
}
