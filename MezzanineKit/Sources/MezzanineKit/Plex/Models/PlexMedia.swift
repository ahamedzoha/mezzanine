import Foundation

/// One version of an item (a file, or several files for a multi-part movie).
public struct PlexMedia: Decodable, Sendable, Hashable, Identifiable {
    public let id: Int
    public let duration: Int?
    public let bitrate: Int?
    public let width: Int?
    public let height: Int?
    public let aspectRatio: Double?
    public let audioChannels: Int?
    public let audioCodec: String?
    public let videoCodec: String?
    public let videoResolution: String?
    public let videoProfile: String?
    public let videoFrameRate: String?
    public let container: String?
    public let audioProfile: String?
    public let parts: [PlexPart]

    enum CodingKeys: String, CodingKey {
        case id, duration, bitrate, width, height, aspectRatio, audioChannels, audioCodec, videoCodec
        case videoResolution, videoProfile, videoFrameRate, container, audioProfile
        case parts = "Part"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenientInt(.id) ?? 0
        duration = c.lenientInt(.duration)
        bitrate = c.lenientInt(.bitrate)
        width = c.lenientInt(.width)
        height = c.lenientInt(.height)
        aspectRatio = c.lenientDouble(.aspectRatio)
        audioChannels = c.lenientInt(.audioChannels)
        audioCodec = try? c.decodeIfPresent(String.self, forKey: .audioCodec)
        videoCodec = try? c.decodeIfPresent(String.self, forKey: .videoCodec)
        videoResolution = c.lenientString(.videoResolution)
        videoProfile = try? c.decodeIfPresent(String.self, forKey: .videoProfile)
        videoFrameRate = try? c.decodeIfPresent(String.self, forKey: .videoFrameRate)
        container = try? c.decodeIfPresent(String.self, forKey: .container)
        audioProfile = try? c.decodeIfPresent(String.self, forKey: .audioProfile)
        parts = c.list(PlexPart.self, .parts)
    }

    /// Short labels for badges: "4K", "HDR", "DV", "Atmos", "5.1".
    public var badges: [String] {
        var out: [String] = []
        if let height, height >= 1600 { out.append("4K") }
        let video = parts.flatMap(\.streams).first { $0.streamType == .video }
        if let video {
            if video.isDolbyVision { out.append("DV") } else if video.isHDR { out.append("HDR") }
        }
        let audio = parts.flatMap(\.streams).first { $0.streamType == .audio && $0.selected == true }
            ?? parts.flatMap(\.streams).first { $0.streamType == .audio }
        if let profile = audio?.audioProfile ?? audioProfile, profile.localizedCaseInsensitiveContains("atmos") {
            out.append("Atmos")
        } else if let channels = audioChannels, channels > 2 {
            out.append(channels == 8 ? "7.1" : channels == 6 ? "5.1" : "\(channels)ch")
        }
        return out
    }
}

/// One file of a version.
public struct PlexPart: Decodable, Sendable, Hashable, Identifiable {
    public let id: Int
    /// Download path, e.g. `/library/parts/123/1700000000/file.mkv`.
    public let key: String?
    public let duration: Int?
    public let file: String?
    public let size: Int64?
    public let container: String?
    /// `"sd"` when the server has generated BIF scrub thumbnails for this part.
    public let indexes: String?
    public let streams: [PlexStream]

    public var hasPreviewThumbnails: Bool { indexes?.isEmpty == false }

    enum CodingKeys: String, CodingKey {
        case id, key, duration, file, size, container, indexes
        case streams = "Stream"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenientInt(.id) ?? 0
        key = try? c.decodeIfPresent(String.self, forKey: .key)
        duration = c.lenientInt(.duration)
        file = try? c.decodeIfPresent(String.self, forKey: .file)
        size = (try? c.decodeIfPresent(Int64.self, forKey: .size)) ?? c.lenientInt(.size).map(Int64.init)
        container = try? c.decodeIfPresent(String.self, forKey: .container)
        indexes = try? c.decodeIfPresent(String.self, forKey: .indexes)
        streams = c.list(PlexStream.self, .streams)
    }
}

/// A video, audio or subtitle stream inside a part, or an external subtitle
/// (sidecar file, or a subtitle search result).
public struct PlexStream: Decodable, Sendable, Hashable, Identifiable {
    public enum StreamType: Int, Sendable, Hashable {
        case video = 1, audio = 2, subtitle = 3, lyrics = 4, unknown = 0
    }

    public let id: Int
    public let streamType: StreamType
    /// The stream's index inside the file (what a demuxer calls it); nil for sidecars.
    public let index: Int?
    public let codec: String?
    public let language: String?
    public let languageCode: String?
    public let languageTag: String?
    public let title: String?
    public let displayTitle: String?
    public let extendedDisplayTitle: String?
    public let channels: Int?
    public let audioChannelLayout: String?
    public let audioProfile: String?
    public let bitrate: Int?
    public let selected: Bool?
    public let isDefault: Bool
    public let forced: Bool
    public let hearingImpaired: Bool
    /// Present for external subtitles: `/library/streams/{id}`.
    public let key: String?
    public let format: String?
    public let colorTrc: String?
    public let colorPrimaries: String?
    public let doviProfile: Int?
    public let bitDepth: Int?
    public let frameRate: Double?
    // Subtitle search results only.
    public let providerTitle: String?
    public let score: Int?
    public let sourceKey: String?
    public let perfectMatch: Bool?

    public var isExternal: Bool { key != nil }
    public var isHDR: Bool { colorTrc == "smpte2084" || colorTrc == "arib-std-b67" }
    public var isDolbyVision: Bool { doviProfile != nil }
    /// Bitmap subtitles (PGS, VobSub, DVB) can't be restyled, only scaled.
    public var isBitmapSubtitle: Bool {
        guard streamType == .subtitle, let codec else { return false }
        return ["pgs", "vobsub", "dvd_subtitle", "dvb_subtitle", "hdmv_pgs_subtitle"].contains(codec)
    }

    public var label: String { extendedDisplayTitle ?? displayTitle ?? title ?? language ?? "Track \(id)" }

    enum CodingKeys: String, CodingKey {
        case id, streamType, index, codec, language, languageCode, languageTag, title, displayTitle
        case extendedDisplayTitle, channels, audioChannelLayout, profile, bitrate, selected
        case isDefault = "default", forced, hearingImpaired, key, format
        case colorTrc, colorPrimaries, DOVIProfile, bitDepth, frameRate
        case providerTitle, score, sourceKey, perfectMatch
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenientInt(.id) ?? 0
        streamType = StreamType(rawValue: c.lenientInt(.streamType) ?? 0) ?? .unknown
        index = c.lenientInt(.index)
        codec = try? c.decodeIfPresent(String.self, forKey: .codec)
        language = try? c.decodeIfPresent(String.self, forKey: .language)
        languageCode = try? c.decodeIfPresent(String.self, forKey: .languageCode)
        languageTag = try? c.decodeIfPresent(String.self, forKey: .languageTag)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        displayTitle = try? c.decodeIfPresent(String.self, forKey: .displayTitle)
        extendedDisplayTitle = try? c.decodeIfPresent(String.self, forKey: .extendedDisplayTitle)
        channels = c.lenientInt(.channels)
        audioChannelLayout = try? c.decodeIfPresent(String.self, forKey: .audioChannelLayout)
        audioProfile = try? c.decodeIfPresent(String.self, forKey: .profile)
        bitrate = c.lenientInt(.bitrate)
        selected = c.lenientBool(.selected)
        isDefault = c.lenientBool(.isDefault) ?? false
        forced = c.lenientBool(.forced) ?? false
        hearingImpaired = c.lenientBool(.hearingImpaired) ?? false
        key = try? c.decodeIfPresent(String.self, forKey: .key)
        format = try? c.decodeIfPresent(String.self, forKey: .format)
        colorTrc = try? c.decodeIfPresent(String.self, forKey: .colorTrc)
        colorPrimaries = try? c.decodeIfPresent(String.self, forKey: .colorPrimaries)
        doviProfile = c.lenientInt(.DOVIProfile)
        bitDepth = c.lenientInt(.bitDepth)
        frameRate = c.lenientDouble(.frameRate)
        providerTitle = try? c.decodeIfPresent(String.self, forKey: .providerTitle)
        score = c.lenientInt(.score)
        sourceKey = try? c.decodeIfPresent(String.self, forKey: .sourceKey)
        perfectMatch = c.lenientBool(.perfectMatch)
    }
}
