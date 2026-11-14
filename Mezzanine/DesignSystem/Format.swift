import Foundation
import MezzanineKit

/// The words Mezzanine puts under titles. Quiet and precise: numbers, not adjectives.
enum Format {
    /// "26 min left", "1 h 38 min left".
    static func timeLeft(_ item: PlexMetadata) -> String? {
        guard let total = item.duration, let offset = item.viewOffset, offset > 0 else { return nil }
        return duration(max(0, total - offset)) + " left"
    }

    /// "41 min", "1 h 38 min".
    static func duration(_ ms: Int) -> String {
        let minutes = Int((Double(ms) / 60_000).rounded())
        if minutes < 60 { return "\(max(1, minutes)) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    /// "S2 E3".
    static func episodeCode(_ item: PlexMetadata) -> String? {
        guard item.kind == .episode, let s = item.parentIndex, let e = item.index else { return nil }
        return "S\(s) E\(e)"
    }

    /// The title a card or the hero shows: the show for episodes and seasons.
    static func displayTitle(_ item: PlexMetadata) -> String {
        switch item.kind {
        case .episode: return item.grandparentTitle ?? item.title
        case .season: return item.parentTitle ?? item.title
        default: return item.title
        }
    }

    /// The line under a poster.
    static func cardSubtitle(_ item: PlexMetadata) -> String {
        switch item.kind {
        case .episode:
            return [episodeCode(item), timeLeft(item)].compactMap { $0 }.joined(separator: " · ")
        case .season:
            return item.title
        case .show:
            if let n = item.childCount { return n == 1 ? "1 season" : "\(n) seasons" }
            return item.year.map(String.init) ?? ""
        default:
            return timeLeft(item) ?? item.year.map(String.init) ?? ""
        }
    }

    /// The ruled caption under the hero title: what it is, then every part of the file.
    static func heroCaption(_ item: PlexMetadata) -> String {
        var parts: [String] = []
        switch item.kind {
        case .episode:
            if let code = episodeCode(item) { parts.append(code) }
            parts.append(item.title)
        case .season:
            parts.append(item.title)
            if let n = item.leafCount { parts.append("\(n) episodes") }
        case .show:
            if let n = item.childCount { parts.append(n == 1 ? "1 season" : "\(n) seasons") }
            if let y = item.year { parts.append(String(y)) }
        default:
            if let y = item.year { parts.append(String(y)) }
            if let d = item.duration { parts.append(duration(d)) }
        }
        if let media = item.media.first {
            if let r = media.videoResolution { parts.append(resolutionLabel(r)) }
            if let v = media.videoCodec { parts.append(codecLabel(v)) }
            if let a = media.audioCodec {
                let ch = media.audioChannels.map { channelLabel($0) } ?? ""
                parts.append([codecLabel(a), ch].filter { !$0.isEmpty }.joined(separator: " "))
            }
        }
        if let left = timeLeft(item) { parts.append(left) }
        return parts.joined(separator: " · ")
    }

    static func resolutionLabel(_ r: String) -> String {
        switch r.lowercased() {
        case "4k": return "4K"
        case "sd": return "SD"
        default: return r.hasSuffix("p") ? r : r + "p"
        }
    }

    static func codecLabel(_ c: String) -> String {
        switch c.lowercased() {
        case "h264": return "H.264"
        case "hevc", "h265": return "HEVC"
        case "av1": return "AV1"
        case "mpeg4": return "MPEG-4"
        case "eac3": return "E-AC-3"
        case "ac3": return "AC-3"
        case "dca", "dts": return "DTS"
        case "truehd": return "TrueHD"
        case "aac": return "AAC"
        case "opus": return "Opus"
        case "mp3": return "MP3"
        case "flac": return "FLAC"
        default: return c.uppercased()
        }
    }

    static func channelLabel(_ n: Int) -> String {
        switch n {
        case 1: return "mono"
        case 2: return "2.0"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "\(n)ch"
        }
    }
}
