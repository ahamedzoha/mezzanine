import Foundation

/// Which deck plays a file.
public enum MusicRoute: String, Sendable, Codable, Hashable {
    /// `AVAudioEngine` reading a whole local file: sample-exact gapless joins and seeks.
    case native
    /// A second AetherEngine instance streaming the file: for what the native deck decodes
    /// badly or not at all. Joins to and from it are not gapless.
    case engine

    /// Codecs `AVAudioFile` opens and seeks exactly (measured on macOS 27: raw FLAC and MP3
    /// bit-exact, AAC within float rounding).
    static let nativeCodecs: Set<String> = ["flac", "alac", "mp3", "aac", "pcm_s16le", "pcm_s24le", "pcm_s32le", "pcm_f32le", "wav", "aiff"]

    /// Vorbis opens but seeks 896 frames off; WMA does not open; E-AC-3 / AC-3 / DTS / Opus are
    /// surround or unsupported containers; more than two channels needs a fold-down the native
    /// graph does not do. Unknown codecs go to the engine too (it decodes almost anything).
    /// `nativeFailed` is set after `AVAudioFile` refused the file: it then goes to the engine
    /// whatever the codec says.
    public static func choose(codec: String?, channels: Int?, nativeFailed: Bool = false) -> MusicRoute {
        if nativeFailed { return .engine }
        guard let codec = codec?.lowercased(), nativeCodecs.contains(codec) else { return .engine }
        if let channels, channels > 2 { return .engine }
        return .native
    }
}
