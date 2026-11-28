import Foundation

/// A track's file quality, for captions ("FLAC · 24-bit · 96 kHz") and the lossless / hi-res /
/// lossy facet.
public struct AudioQuality: Sendable, Hashable, Codable {
    public enum Tier: String, Sendable, Codable, CaseIterable, Hashable {
        case lossy, lossless, hiRes

        public var label: String {
            switch self {
            case .lossy: return "Lossy"
            case .lossless: return "Lossless"
            case .hiRes: return "Hi-Res Lossless"
            }
        }
    }

    public var codec: String
    public var bitDepth: Int?
    public var samplingRate: Int?
    public var channels: Int?
    /// kbit/s, used for lossy captions.
    public var bitrate: Int?

    public init(codec: String, bitDepth: Int? = nil, samplingRate: Int? = nil, channels: Int? = nil, bitrate: Int? = nil) {
        self.codec = codec.lowercased()
        self.bitDepth = bitDepth
        self.samplingRate = samplingRate
        self.channels = channels
        self.bitrate = bitrate
    }

    /// From a track's first media and its audio stream; nil without a codec.
    public init?(_ metadata: PlexMetadata) {
        guard let media = metadata.media.first else { return nil }
        let stream = media.parts.first?.streams.first { $0.streamType == .audio }
        guard let codec = stream?.codec ?? media.audioCodec else { return nil }
        self.init(codec: codec, bitDepth: stream?.bitDepth, samplingRate: stream?.samplingRate,
                  channels: stream?.channels ?? media.audioChannels, bitrate: stream?.bitrate ?? media.bitrate)
    }

    static let losslessCodecs: Set<String> = ["flac", "alac", "wav", "pcm", "aiff", "ape", "wavpack", "wv", "tta", "dsd", "dsf",
                                              "truehd", "mlp"]
    static func isLosslessCodec(_ codec: String) -> Bool {
        losslessCodecs.contains(codec) || codec.hasPrefix("pcm_")
    }

    public var isLossless: Bool { Self.isLosslessCodec(codec) }

    /// Hi-res means better than CD: more than 16 bits or more than 48 kHz (a 24-bit/44.1 or
    /// 16-bit/96 file counts).
    public var tier: Tier {
        guard isLossless else { return .lossy }
        if (bitDepth ?? 16) > 16 || (samplingRate ?? 44_100) > 48_000 { return .hiRes }
        return .lossless
    }

    public var codecLabel: String {
        switch codec {
        case "flac": return "FLAC"
        case "alac": return "ALAC"
        case "mp3": return "MP3"
        case "aac": return "AAC"
        case "vorbis": return "Vorbis"
        case "opus": return "Opus"
        case "eac3": return "E-AC-3"
        case "ac3": return "AC-3"
        case "wmav2", "wmav1", "wmapro", "wma": return "WMA"
        case "wav", "pcm_s16le", "pcm_s24le": return "WAV"
        case "aiff": return "AIFF"
        case "dts": return "DTS"
        default: return codec.uppercased()
        }
    }

    /// 44100 → "44.1 kHz", 48000 → "48 kHz", 176400 → "176.4 kHz".
    public static func rateLabel(_ hz: Int) -> String {
        let khz = Double(hz) / 1000
        let rounded = (khz * 10).rounded() / 10
        return rounded == rounded.rounded() ? "\(Int(rounded)) kHz" : "\(rounded) kHz"
    }

    /// "FLAC · 24-bit · 96 kHz" for lossless files, "MP3 · 320 kbps" for lossy ones; a surround
    /// mix adds "5.1".
    public var caption: String {
        var parts = [codecLabel]
        if isLossless {
            if let bitDepth { parts.append("\(bitDepth)-bit") }
            if let samplingRate { parts.append(Self.rateLabel(samplingRate)) }
        } else if let bitrate, bitrate > 0 {
            parts.append("\(bitrate) kbps")
        }
        if let channels, channels > 2 {
            parts.append(channels == 6 ? "5.1" : channels == 8 ? "7.1" : "\(channels) ch")
        }
        return parts.joined(separator: " · ")
    }
}
