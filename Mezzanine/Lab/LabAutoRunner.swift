#if DEBUG
import Foundation
import MezzanineKit
import MezzaninePlayback

/// Spike S2, scripted: `-LabAutoMatrix YES` plays every Lab matrix row muted,
/// lets it run, seeks to the middle, and prints one result line per row to
/// stdout (launch the binary from Scripts/dev-run.sh to capture it).
/// Never reports timeline or scrobble, so nothing reaches watch history.
@MainActor
enum LabAutoRunner {
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "LabAutoMatrix") }

    static func run(session: SessionStore, player: MezzaninePlayer) async {
        // Wait for the connection.
        for _ in 0..<100 where session.client == nil { try? await Task.sleep(for: .milliseconds(200)) }
        guard let client = session.client else { emit("LAB abort: not connected (\(session.phase))"); return }
        emit("LAB start server=\(session.currentServer?.name ?? "?") route=\(session.connection?.connection.route.rawValue ?? "?")")
        player.volume = VolumeLevel(percent: 0)
        let only = UserDefaults.standard.string(forKey: "LabOnly")

        for entry in LabMatrix.entries where only == nil || entry.id == only {
            do {
                let item = try await client.metadata(entry.ratingKey)
                guard let key = item.media.first?.parts.first?.key, let url = client.urls.part(key: key) else {
                    emit("LAB \(entry.id) | no part"); continue
                }
                try await player.load(PlaybackRequest(url: url, headers: client.requestHeaders, startPosition: 60,
                                                      preferredAudioLanguages: ["eng"], preferredSubtitleLanguages: ["eng"]))
                // First frame (or give up after 25 s).
                for _ in 0..<250 where !player.firstFrameReady {
                    if case .failed = player.status { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                try? await Task.sleep(for: .seconds(6))
                let t0 = player.currentTime
                try? await Task.sleep(for: .seconds(2))
                let advanced = player.currentTime - t0
                await player.seek(to: player.duration / 2)
                try? await Task.sleep(for: .seconds(3))
                let subs = player.subtitleTracks.map(\.codec).joined(separator: ",")
                let d = player.diagnostics
                emit("LAB \(entry.id) | status=\(player.status) route=\(d.route) container=\(d.container ?? "-") vcodec=\(d.videoCodec ?? "-") vdec=\(d.videoDecoder ?? "-") adec=\(d.audioDecoder ?? "-") audio=\(d.audioDelivery) fmt=\(d.videoFormat) ttff=\(ms(d.timeToFirstFrame)) seek=\(ms(d.lastSeekLatency)) advanced2s=\(String(format: "%.2f", advanced)) audioTracks=\(player.audioTracks.count) subs=[\(subs)]")
            } catch {
                emit("LAB \(entry.id) | error \(error)")
            }
            player.stop()
            try? await Task.sleep(for: .seconds(1))
        }
        emit("LAB done")
    }

    private static func ms(_ d: Duration?) -> String {
        guard let d else { return "-" }
        let c = d.components
        return "\(c.seconds * 1000 + c.attoseconds / 1_000_000_000_000_000)ms"
    }

    private static func emit(_ line: String) {
        print(line)
        fflush(stdout)
    }
}
#endif
