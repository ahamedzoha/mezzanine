#if DEBUG
import Foundation
import MezzanineKit
import AVFAudio
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
            guard let track = tracks.first(where: { $0.duration >= 20 && c.match($0) }) else {
                emit("LABMUSIC \(c.id) | skipped (no matching track)")
                continue
            }
            await runSingle(id: c.id, track: track, client: client, cache: cache, engine: engine)
            engine.stop()
            try? await Task.sleep(for: .milliseconds(300))
        }

        if only == nil || only == "offline-joins" {
            await runOfflineJoins(tracks: tracks, client: client, cache: cache)
        }

        if only == nil || only == "gapless-join" {
            await runGaplessJoin(tracks: tracks, client: client, cache: cache, engine: engine)
            engine.stop()
        }

        try? FileManager.default.removeItem(at: cacheDir)
        emit("LABMUSIC done")
    }

    /// Candidate tracks with full stream detail: from the whole listing, per codec the smallest
    /// files (they download fastest), plus FLACs spread over the size range so hi-res files appear.
    static func sampleTracks(client: PlexServerClient) async throws -> [QueuedTrack] {
        let sections = try await client.sections()
        guard let musicSection = sections.first(where: { $0.kind == .artist }) else { return [] }
        let page = try await client.items(section: musicSection.key, type: 10, offset: 0, limit: 5000)
        func size(_ m: PlexMetadata) -> Int64 { m.media.first?.parts.first?.size ?? .max }
        func codec(_ m: PlexMetadata) -> String { (m.media.first?.audioCodec ?? "").lowercased() }
        var keys: [String] = []
        for name in ["mp3", "aac", "vorbis", "eac3", "wmav2"] {
            let sorted = page.items.filter { codec($0) == name }.sorted { size($0) < size($1) }
            // The very smallest are often clips: sample the lower half of the size range.
            let step = max(1, sorted.count / 16)
            keys += stride(from: 0, to: sorted.count / 2 + 1, by: step).compactMap { sorted.indices.contains($0) ? sorted[$0].ratingKey : nil }
        }
        let flacs = page.items.filter { codec($0) == "flac" }.sorted { size($0) < size($1) }
        if !flacs.isEmpty {
            let step = max(1, flacs.count / 40)
            keys += stride(from: 0, to: flacs.count, by: step).map { flacs[$0].ratingKey }
        }
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
            let began = ContinuousClock.now
            try await engine.play(req, startAt: 0, autoplay: true)
            let loadMs = ms(ContinuousClock.now - began)
            try? await Task.sleep(for: .seconds(1))
            let advanced = engine.position

            // Seek, pause at once, and read where it landed (running time would blur the error).
            let target = max(1, engine.duration / 2)
            await engine.seek(to: target)
            engine.pause()
            try? await Task.sleep(for: .milliseconds(400))
            let seekErrMs = Int(abs(engine.position - target) * 1000)

            let firstAudio = engine.firstAudioLatency.map { "\(ms($0))ms" } ?? "-"
            emit("LABMUSIC \(id) | route=\(engine.activeRoute.rawValue) codec=\(track.codec ?? "-") bits=\(track.bitDepth ?? 0) sr=\(track.samplingRate ?? 0) ch=\(track.channels ?? 0) play=\(loadMs)ms firstAudio=\(firstAudio) after1s=\(String(format: "%.2f", advanced))s seekErr=\(seekErrMs)ms status=\(engine.status)")
        } catch {
            emit("LABMUSIC \(id) | error \(error)")
        }
    }

    private static func ms(_ d: Duration) -> Int {
        Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
    }

    /// Renders a join offline (no output device: silent by construction) and finds where the
    /// second file's first samples land against where they should: 0 frames is gapless.
    /// `gainDB` on the follower forces the cross-deck path (different leveling gain).
    static func offlineJoin(id: String, first: URL, second: URL, followerGainDB: Double = 0) async {
        do {
            let fa = try AVAudioFile(forReading: first)
            let fb = try AVAudioFile(forReading: second)
            let rate = fa.processingFormat.sampleRate
            guard fb.processingFormat.sampleRate == rate, fb.processingFormat.channelCount == fa.processingFormat.channelCount else {
                emit("LABMUSIC \(id) | skipped (formats differ)")
                return
            }
            let tail = AVAudioFrameCount(rate)   // the last second of the first file
            let startFrame = max(0, fa.length - AVAudioFramePosition(tail))
            let tailFrames = Int(fa.length - startFrame)
            let engine = try MusicEngine(mode: .offline(sampleRate: rate), bypassLimiter: true)
            func req(_ url: URL, _ gain: Double) -> MusicTrackRequest {
                MusicTrackRequest(track: QueuedTrack(ratingKey: "lab", title: "lab", artist: "", album: "", duration: 1),
                                  route: .native, fileURL: url, gainDB: gain)
            }
            try await engine.play(req(first, 0), startAt: Double(startFrame) / rate)
            engine.enqueueNext(req(second, followerGainDB))
            var rendered: [Float] = []
            let total = tailFrames + Int(rate / 2)
            while rendered.count < total {
                let buffer = try engine.renderOffline(frames: 4096)
                rendered += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
                try? await Task.sleep(for: .milliseconds(1))   // let completion handlers hop to the main actor
            }
            // The second file's opening samples (first loud stretch), scaled by the follower's gain.
            let head = AVAudioPCMBuffer(pcmFormat: fb.processingFormat, frameCapacity: 44_100)!
            try fb.read(into: head, frameCount: min(44_100, AVAudioFrameCount(fb.length)))
            let left = Array(UnsafeBufferPointer(start: head.floatChannelData![0], count: Int(head.frameLength)))
            let scale = Float(pow(10, followerGainDB / 20))
            guard let k = left.firstIndex(where: { abs($0) > 1e-3 }), k + 256 <= left.count else {
                emit("LABMUSIC \(id) | skipped (no clear opening)")
                return
            }
            var gap: Int?
            for d in -60000...60000 {
                let base = tailFrames + k + d
                guard base >= 0, base + 256 <= rendered.count else { continue }
                if (0..<256).allSatisfy({ abs(rendered[base + $0] - left[k + $0] * scale) < 2e-4 }) { gap = d; break }
            }
            let path = followerGainDB == 0 ? "same-deck" : "cross-deck"
            emit("LABMUSIC \(id) | \(path) sr=\(Int(rate)) join gap=\(gap.map { "\($0) frames" } ?? "no match")")
        } catch {
            emit("LABMUSIC \(id) | error \(error)")
        }
    }

    /// Pairs of the same codec and sample rate, one pair per family, joined offline.
    private static func runOfflineJoins(tracks: [QueuedTrack], client: PlexServerClient, cache: TrackCache) async {
        let families: [(String, @Sendable (QueuedTrack) -> Bool)] = [
            ("flac-16-44", { $0.codec == "flac" && ($0.bitDepth ?? 16) <= 16 && $0.samplingRate == 44_100 }),
            ("flac-24", { $0.codec == "flac" && ($0.bitDepth ?? 0) >= 24 }),
            ("mp3", { $0.codec == "mp3" && $0.samplingRate == 44_100 }),
            ("aac", { $0.codec == "aac" && $0.samplingRate == 44_100 }),
        ]
        for (name, match) in families {
            var pool = tracks.filter { $0.duration >= 20 && match($0) }
            if name == "flac-24", let rate = pool.first?.samplingRate { pool = pool.filter { $0.samplingRate == rate } }
            guard pool.count >= 2 else { emit("LABMUSIC join-\(name) | skipped (need 2 tracks)"); continue }
            do {
                let a = try await makeRequest(for: pool[0], client: client, cache: cache)
                let b = try await makeRequest(for: pool[1], client: client, cache: cache)
                guard let ua = a.fileURL, let ub = b.fileURL else { continue }
                await offlineJoin(id: "join-\(name)", first: ua, second: ub)
                if name == "flac-16-44" { await offlineJoin(id: "join-\(name)-gain", first: ua, second: ub, followerGainDB: -3) }
            } catch {
                emit("LABMUSIC join-\(name) | error \(error)")
            }
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
