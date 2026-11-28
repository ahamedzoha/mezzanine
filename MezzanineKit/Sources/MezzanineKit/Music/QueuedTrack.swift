import Foundation

/// One track as the queue holds it: everything needed to draw it and start it without asking
/// the server or the index again.
public struct QueuedTrack: Sendable, Hashable, Codable, Identifiable {
    /// Identity inside the queue (the same song can be queued twice).
    public var id: UUID
    public var ratingKey: String
    public var title: String
    public var artist: String
    public var album: String
    public var albumKey: String?
    public var artistKey: String?
    /// Plex image path of the album art (square).
    public var thumb: String?
    /// Seconds.
    public var duration: TimeInterval
    /// The file to fetch: `/library/parts/<id>/<ts>/file.flac`.
    public var partKey: String?
    public var partID: Int?
    public var codec: String?
    public var container: String?
    public var channels: Int?
    public var bitDepth: Int?
    public var samplingRate: Int?
    public var bitrate: Int?
    public var loudness: TrackLoudness
    public var startRamp: String?
    public var endRamp: String?
    /// Track and disc position in its album.
    public var index: Int?
    public var discIndex: Int?
    public var year: Int?

    public init(id: UUID = UUID(), ratingKey: String, title: String, artist: String, album: String,
                albumKey: String? = nil, artistKey: String? = nil, thumb: String? = nil, duration: TimeInterval,
                partKey: String? = nil, partID: Int? = nil, codec: String? = nil, container: String? = nil,
                channels: Int? = nil, bitDepth: Int? = nil, samplingRate: Int? = nil, bitrate: Int? = nil,
                loudness: TrackLoudness = TrackLoudness(), startRamp: String? = nil, endRamp: String? = nil,
                index: Int? = nil, discIndex: Int? = nil, year: Int? = nil) {
        self.id = id
        self.ratingKey = ratingKey
        self.title = title
        self.artist = artist
        self.album = album
        self.albumKey = albumKey
        self.artistKey = artistKey
        self.thumb = thumb
        self.duration = duration
        self.partKey = partKey
        self.partID = partID
        self.codec = codec
        self.container = container
        self.channels = channels
        self.bitDepth = bitDepth
        self.samplingRate = samplingRate
        self.bitrate = bitrate
        self.loudness = loudness
        self.startRamp = startRamp
        self.endRamp = endRamp
        self.index = index
        self.discIndex = discIndex
        self.year = year
    }

    /// A queue entry from a track's full metadata (its media and audio stream included).
    /// Nil for anything that is not a track.
    public init?(_ m: PlexMetadata) {
        guard m.kind == .track else { return nil }
        let media = m.media.first
        let part = media?.parts.first
        let stream = part?.streams.first { $0.streamType == .audio }
        self.init(ratingKey: m.ratingKey, title: m.title,
                  artist: m.originalTitle ?? m.grandparentTitle ?? "", album: m.parentTitle ?? "",
                  albumKey: m.parentRatingKey, artistKey: m.grandparentRatingKey,
                  thumb: m.parentThumb ?? m.thumb, duration: Double(m.duration ?? media?.duration ?? 0) / 1000,
                  partKey: part?.key, partID: part?.id, codec: stream?.codec ?? media?.audioCodec,
                  container: part?.container ?? media?.container,
                  channels: stream?.channels ?? media?.audioChannels, bitDepth: stream?.bitDepth,
                  samplingRate: stream?.samplingRate, bitrate: stream?.bitrate ?? media?.bitrate,
                  loudness: TrackLoudness(stream), startRamp: stream?.startRamp, endRamp: stream?.endRamp,
                  index: m.index, discIndex: m.parentIndex, year: m.parentYear ?? m.year)
    }

    public var quality: AudioQuality? {
        codec.map { AudioQuality(codec: $0, bitDepth: bitDepth, samplingRate: samplingRate, channels: channels, bitrate: bitrate) }
    }

    public var startLoudnessRamp: LoudnessRamp { LoudnessRamp(parsing: startRamp) }
    public var endLoudnessRamp: LoudnessRamp { LoudnessRamp(parsing: endRamp) }
}
