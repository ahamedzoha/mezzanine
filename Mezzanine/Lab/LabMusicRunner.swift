#if DEBUG
import Foundation
import MezzanineKit
import MezzaninePlayback

/// Silent Lab runner for Music M1: `-LabMusic YES` exercises `TrackCache`, `MusicRoute`,
/// `MusicEngine` (native + EngineDeck), seek accuracy, and gapless joins across codec families
/// on the connected server's Music section with `volume = 0` and `isMuted = true`.
/// Never reports timeline, scrobble, or ratings.
@MainActor
enum LabMusicRunner {
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "LabMusic") }

    struct MusicCase: Identifiable, Hashable {
        let id: String
        let note: String
        let match: @Sendable (QueuedTrack) -> Bool

        static func == (lhs: MusicCase, rhs: MusicCase) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    static let cases: [MusicCase] = [
        MusicCase(id: "flac-16-44", note: "FLAC 16-bit 44.1 kHz — native gapless") {
            $0.codec?.lowercased() == "flac" && ($0.bitDepth ?? 16) <= 16 && ($0.samplingRate ?? 44_100) <= 48_000
        },
        MusicCase(id: "flac-24-hires", note: "FLAC 24-bit hi-res — native") {
            $0.codec?.lowercased() == "flac" && ($0.bitDepth ?? 0) >= 24 && ($0.samplingRate ?? 0) >= 88_200
        },
        MusicCase(id: "mp3", note: "MP3 — native gapless") {
            $0.codec?.lowercased() == "mp3"
        },
        MusicCase(id: "aac", note: "AAC — native gapless") {
            $0.codec?.lowercased() == "aac"
        },
        MusicCase(id: "vorbis", note: "Vorbis — EngineDeck fallback") {
            $0.codec?.lowercased() == "vorbis"
        },
        MusicCase(id: "eac3-surround", note: "E-AC-3 / surround — EngineDeck fallback") {
            let codec = $0.codec?.lowercased() ?? ""
            return codec == "eac3" || ($0.channels ?? 2) > 2
        },
        MusicCase(id: "wma", note: "WMA — EngineDeck fallback") {
            let codec = $0.codec?.lowercased() ?? ""
            return codec.hasPrefix("wma")
        },
    ]

    static func run(session: SessionStore) async {
        for _ in 0..<100 where session.client == nil { try? await Task.sleep(for: .milliseconds(200)) }
        guard let client = session.client else { emit("LABMUSIC abort: not connected (\(session.phase))"); return }

        emit("LABMUSIC start server=\(session.currentServer?.name ?? "?")")
        let tracks: [QueuedTrack]
        do {
            tracks = try await sampleTracks(client: client)
        } catch {
            emit("LABMUSIC abort: failed to load tracks: \(error)")
            return
        }

        let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("mezzanine-lab-music", isDirectory: true)
        let cache = TrackCache(directory: cacheDir, limitBytes: 512_000_000)

        let engine: MusicEngine
        do {
            engine = try MusicEngine(mode: .live)
        } catch {
            emit("LABMUSIC abort: MusicEngine init failed: \(error)")
            return
        }
        engine.volume = 0
        engine.isMuted = true

        let only = UserDefaults.standard.string(forKey: "LabOnly")
        for c in cases where only == nil || c.id == only {
            guard let track = tracks.first(where: c.match) else {
                emit("LABMUSIC \(c.id) | skipped (no matching track)")
                continue
            }
            await runSingle(id: c.id, track: track, client: client, cache: cache, engine: engine)
            engine.stop()
            try? await Task.sleep(for: .milliseconds(300))
        }

        if only == nil || only == "gapless-join" {
            await runGaplessJoin(tracks: tracks, client: client, cache: cache, engine: engine)
            engine.stop()
        }

        try? FileManager.default.removeItem(at: cacheDir)
        emit("LABMUSIC done")
    }

    /// Fetches a bounded slice of tracks with full stream detail from the first music section.
    static func sampleTracks(client: PlexServerClient) async throws -> [QueuedTrack] {
        let sections = try await client.sections()
        guard let musicSection = sections.first(where: { $0.kind == .artist }) else { return [] }
        let page = try await client.items(section: musicSection.key, type: 10, offset: 0, limit: 250)
        let keys = page.items.map(\.ratingKey)
        guard !keys.isEmpty else { return [] }
        let detailed = try await client.musicMetadata(keys: keys)
        return detailed.compactMap { QueuedTrack($0) }
    }

    static func makeRequest(for track: QueuedTrack, client: PlexServerClient, cache: TrackCache) async throws -> MusicTrackRequest {
        let route = MusicRoute.choose(codec: track.codec, channels: track.channels)
        guard let partKey = track.partKey, let streamURL = client.urls.part(key: partKey) else {
            throw MusicEngineError.noSource
        }
        var fileURL: URL?
        if route == .native, let partID = track.partID {
            let ext = (partKey as NSString).pathExtension
            let source = TrackCache.Source(partID: partID, url: streamURL, headers: client.requestHeaders, fileExtension: ext)
            fileURL = try await cache.fetch(source)
        }
        return MusicTrackRequest(track: track, route: route, fileURL: fileURL, streamURL: streamURL,
                                 headers: client.requestHeaders, gainDB: 0)
    }

    private static func runSingle(id: String, track: QueuedTrack, client: PlexServerClient,
                                  cache: TrackCache, engine: MusicEngine) async {
        do {
            let req = try await makeRequest(for: track, client: client, cache: cache)
            try await engine.play(req, startAt: 0, autoplay: true)
            try? await Task.sleep(for: .seconds(1))

            let target = max(1, engine.duration / 2)
            await engine.seek(to: target)
            try? await Task.sleep(for: .milliseconds(300))
            let seekErrMs = Int(abs(engine.position - target) * 1000)

            let firstAudio = engine.firstAudioLatency.map {
                "\(Int($0.components.seconds * 1000 + $0.components.attoseconds / 1_000_000_000_000_000))ms"
            } ?? "-"
            emit("LABMUSIC \(id) | route=\(engine.activeRoute.rawValue) codec=\(track.codec ?? "-") sr=\(track.samplingRate ?? 0) firstAudio=\(firstAudio) seekErr=\(seekErrMs)ms status=\(engine.status)")
        } catch {
            emit("LABMUSIC \(id) | error \(error)")
        }
    }

    private static func runGaplessJoin(tracks: [QueuedTrack], client: PlexServerClient,
                                       cache: TrackCache, engine: MusicEngine) async {
        let nativeTracks = tracks.filter {
            MusicRoute.choose(codec: $0.codec, channels: $0.channels) == .native && $0.duration >= 6
        }
        guard nativeTracks.count >= 2 else {
            emit("LABMUSIC gapless-join | skipped (need 2 native tracks)")
            return
        }
        let first = nativeTracks[0]
        let second = nativeTracks[1]
        do {
            let req1 = try await makeRequest(for: first, client: client, cache: cache)
            let req2 = try await makeRequest(for: second, client: client, cache: cache)
            var joined = false
            engine.onEvent = { event in
                if case .trackStarted(let started, _) = event, started.id == second.id {
                    joined = true
                }
            }
            let startAt = max(0, first.duration - 2.5)
            try await engine.play(req1, startAt: startAt, autoplay: true)
            engine.enqueueNext(req2)
            for _ in 0..<50 where !joined {
                try? await Task.sleep(for: .milliseconds(100))
            }
            engine.onEvent = nil
            emit("LABMUSIC gapless-join | joined=\(joined) route=\(engine.activeRoute.rawValue) status=\(engine.status)")
        } catch {
            engine.onEvent = nil
            emit("LABMUSIC gapless-join | error \(error)")
        }
    }

    private static func emit(_ line: String) {
        print(line)
        fflush(stdout)
    }
}
#endif
