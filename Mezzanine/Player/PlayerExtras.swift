import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MezzanineKit
import MezzaninePlayback

/// Reports the window a view lives in (for the key router).
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) { view.onWindow = onWindow }

    final class ReaderView: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }
    }
}

/// Playback info (I): how the file is reaching the screen and the speakers.
/// Top-left under the title mark, solid so a bright frame never shows through.
struct PlayerStats: View {
    let item: PlexMetadata
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(SoundSettings.self) private var sound

    private var player: MezzaninePlayer { playback.player }
    private var d: PlayerDiagnostics { player.diagnostics }
    private var media: PlexMedia? { item.media.first }
    private var audioStream: PlexStream? {
        let streams = media?.parts.first?.streams ?? []
        return streams.first { $0.streamType == .audio && $0.index == player.selectedAudioID }
            ?? streams.first { $0.streamType == .audio && $0.selected == true }
    }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: Theme.Space.m, verticalSpacing: 4) {
            row("Playback", route)
            row("Video", video)
            row("Decoder", [d.videoDecoder, d.videoFormat == "sdr" ? nil : d.videoFormat.uppercased()].compactMap { $0 }.joined(separator: " · "))
            row("Audio", audio)
            row("Sound", "\(sound.deviceName) · \(sound.current.kind.label) · shaping \(d.audioShaping)")
            row("Volume", "\(Int(sound.current.volumePercent)) %\(player.isMuted ? " (muted)" : "")")
            row("Timing", timing)
        }
        .font(.system(size: 11, weight: .medium).monospacedDigit())
        .foregroundStyle(Theme.ink)
        .padding(Theme.Space.m)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.still, style: .continuous).fill(Theme.graphite.opacity(0.92)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.still, style: .continuous).strokeBorder(Theme.rule, lineWidth: 1))
        .frame(maxWidth: 460, alignment: .leading)
        .padding(.top, 150)
        .padding(.leading, Theme.Space.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Playback info")
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(Theme.inkSecondary)
            Text(value.isEmpty ? "–" : value).lineLimit(1)
        }
    }

    private var route: String {
        let path: String
        switch d.route {
        case "native": path = "AVPlayer"
        case "loopback", "hls": path = "AVPlayer via the in-app HLS bridge"
        case "software": path = "software renderer"
        default: path = d.route
        }
        let delivery = playback.playingDownload ? "Downloaded copy" : (playback.mode == .direct ? "Direct play" : playback.mode.label)
        return "\(delivery) · \(path)\(player.isBuffering ? " · buffering" : "")"
    }

    private var video: String {
        var parts: [String] = []
        if let c = d.container { parts.append(c.components(separatedBy: ",").first ?? c) }
        if let codec = d.videoCodec ?? media?.videoCodec { parts.append(Format.codecLabel(codec)) }
        if let w = media?.width, let h = media?.height { parts.append("\(w)×\(h)") }
        if let fps = d.frameRate { parts.append(String(format: "%g fps", (fps * 1000).rounded() / 1000)) }
        let kbps = d.videoBitrate > 0 ? Int(d.videoBitrate / 1000) : (media?.bitrate ?? 0)
        if kbps > 0 { parts.append(kbps >= 1000 ? String(format: "%.1f Mb/s", Double(kbps) / 1000) : "\(kbps) kb/s") }
        return parts.joined(separator: " · ")
    }

    private var audio: String {
        var parts: [String] = []
        if let s = audioStream {
            parts.append(Format.codecLabel(s.codec ?? ""))
            if let ch = s.channels, ch > 0 { parts.append(Format.channelLabel(ch)) }
        }
        parts.append(d.audioDelivery)
        if let dec = d.audioDecoder { parts.append(dec) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var timing: String {
        var parts: [String] = []
        if let t = d.timeToFirstFrame { parts.append("start \(ms(t))") }
        if let t = d.lastSeekLatency { parts.append("last seek \(ms(t))") }
        return parts.joined(separator: " · ")
    }

    private func ms(_ d: Duration) -> String {
        let c = d.components
        return "\(c.seconds * 1000 + c.attoseconds / 1_000_000_000_000_000) ms"
    }
}

/// Snapshot files: Pictures ▸ Mezzanine ▸ "From S3E10 0h12m03s.png", and the clipboard.
enum Snapshot {
    enum Failure: Error { case noFolder, write }

    static func fileName(for item: PlexMetadata, at seconds: Double) -> String {
        let t = Int(seconds)
        let stamp = String(format: "%dh%02dm%02ds", t / 3600, (t / 60) % 60, t % 60)
        let code = item.kind == .episode ? Format.episodeCode(item)?.replacingOccurrences(of: " ", with: "") : nil
        let title = [Format.displayTitle(item), code].compactMap { $0 }.joined(separator: " ")
        let safe = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: " -")
        return "\(safe) \(stamp).png"
    }

    @discardableResult
    static func save(_ image: CGImage, named name: String) -> Result<URL, Failure> {
        let ns = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        #if DEBUG
        let copies = !UserDefaults.standard.bool(forKey: "SnapshotNoClipboard")
        #else
        let copies = true
        #endif
        if copies {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([ns])
        }
        guard let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first else {
            return .failure(.noFolder)
        }
        let folder = pictures.appendingPathComponent("Mezzanine", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(name)
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                return .failure(.write)
            }
            CGImageDestinationAddImage(dest, image, nil)
            return CGImageDestinationFinalize(dest) ? .success(url) : .failure(.write)
        } catch {
            return .failure(.write)
        }
    }
}
