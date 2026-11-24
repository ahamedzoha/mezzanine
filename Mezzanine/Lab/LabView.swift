#if DEBUG
import SwiftUI
import MezzanineKit
import MezzaninePlayback

/// Debug-only harness for the M0 spikes: connection race (S1), the engine
/// matrix on real files (S2) and audio shaping per output (S3). Never sends
/// timeline or scrobble calls, so nothing here touches watch history.
struct LabView: View {
    @Environment(SessionStore.self) private var session
    @Environment(MezzaninePlayer.self) private var player

    @State private var selection: LabMatrixEntry?
    @State private var item: PlexMetadata?
    @State private var error: String?
    @State private var log: [String] = []
    @State private var profileKind: AudioOutputKind = .builtInSpeakers
    @State private var volumePercent: Double = 100

    var body: some View {
        NavigationSplitView {
            List(LabMatrix.entries, selection: $selection) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.id).font(.callout.monospaced())
                    Text(entry.note).font(.caption).foregroundStyle(.secondary)
                }
                .tag(entry)
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 300)
            .safeAreaInset(edge: .top) { connectionHeader }
        } detail: {
            detail
        }
        .onChange(of: selection) { _, entry in
            guard let entry else { return }
            Task { await open(entry) }
        }
        .task {
            if LabAutoRunner.isEnabled { await LabAutoRunner.run(session: session, player: player) }
        }
    }

    private var connectionHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.currentServer?.name ?? "Not connected").font(.headline)
            if let c = session.connection {
                Text("\(c.connection.route.rawValue) · \(c.connection.protocolName) · \(c.latency.formatted(.units(allowed: [.milliseconds])))")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    @ViewBuilder private var detail: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                PlayerSurface(player: player)
                subtitleOverlay
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxWidth: .infinity)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let item { itemSummary(item) }
                    transport
                    audioControls
                    tracks
                    stats
                    logView
                    if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                }
                .padding(16)
            }
        }
    }

    // MARK: Sections

    private func itemSummary(_ item: PlexMetadata) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.grandparentTitle.map { "\($0) — \(item.title)" } ?? item.title).font(.title3.bold())
            if let media = item.media.first {
                Text([media.container, media.videoCodec, media.videoResolution, media.audioCodec,
                      media.audioChannels.map { "\($0)ch" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.callout.monospaced()).foregroundStyle(.secondary)
            }
            if let intro = item.intro { Text("Intro \(Int(intro.start))–\(Int(intro.end)) s").font(.caption) }
            if let credits = item.credits { Text("Credits from \(Int(credits.start)) s").font(.caption) }
        }
    }

    private var transport: some View {
        HStack(spacing: 10) {
            Button("Play from start") { Task { await play(from: 0) } }.disabled(item == nil)
            Button(player.status == .playing ? "Pause" : "Play") { player.togglePlayPause() }
            Button("−10 s") { Task { await player.seek(by: -10) } }
            Button("+10 s") { Task { await player.seek(by: 10) } }
            Button("Seek 50 %") { Task { await player.seek(to: player.duration / 2) } }
            if let intro = item?.intro {
                Button("Skip intro") { Task { await player.seek(to: intro.end, exact: true) } }
            }
            Button("Stop") { player.stop() }
            Spacer()
            Text("\(format(player.currentTime)) / \(format(player.duration))").font(.callout.monospaced())
        }
    }

    private var audioControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Output profile", selection: $profileKind) {
                ForEach(AudioOutputKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .onChange(of: profileKind) { _, kind in player.audioProfile = kind.defaultProfile }
            HStack {
                Text("Volume \(Int(volumePercent)) %").font(.callout.monospaced()).frame(width: 130, alignment: .leading)
                Slider(value: $volumePercent, in: 0...400, step: 5)
                    .onChange(of: volumePercent) { _, v in player.volume = VolumeLevel(percent: v) }
            }
        }
    }

    private var tracks: some View {
        HStack(alignment: .top, spacing: 24) {
            Picker("Audio", selection: Binding(get: { player.selectedAudioID ?? -1 }, set: { player.selectAudio(id: $0) })) {
                ForEach(player.audioTracks) { Text("\($0.name) (\($0.codec) \($0.channels)ch)").tag($0.id) }
            }
            Picker("Subtitles", selection: Binding(get: { player.selectedSubtitleID ?? -1 }, set: { player.selectSubtitle(id: $0 < 0 ? nil : $0) })) {
                Text("Off").tag(-1)
                ForEach(player.subtitleTracks) { Text("\($0.name) (\($0.codec))").tag($0.id) }
            }
        }
    }

    private var stats: some View {
        let d = player.diagnostics
        return Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            row("status", "\(player.status)\(player.isBuffering ? " (buffering)" : "")")
            row("route", d.route)
            row("container / codec", "\(d.container ?? "?") / \(d.videoCodec ?? "?")")
            row("video decoder", d.videoDecoder ?? "–")
            row("audio decoder", d.audioDecoder ?? "–")
            row("audio delivery", d.audioDelivery)
            row("audio shaping", d.audioShaping)
            row("video format", d.videoFormat)
            row("video bitrate", d.videoBitrate > 0 ? "\(d.videoBitrate / 1000) kb/s" : "–")
            row("first frame", d.timeToFirstFrame.map { $0.formatted(.units(allowed: [.milliseconds])) } ?? "–")
            row("last seek", d.lastSeekLatency.map { $0.formatted(.units(allowed: [.milliseconds])) } ?? "–")
        }
        .font(.callout.monospaced())
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v).textSelection(.enabled)
        }
    }

    private var logView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Results").font(.headline)
                Spacer()
                Button("Record row") { record() }.disabled(selection == nil)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(log.joined(separator: "\n"), forType: .string)
                }
            }
            ForEach(Array(log.enumerated()), id: \.offset) { Text($0.element).font(.caption.monospaced()).textSelection(.enabled) }
        }
    }

    @ViewBuilder private var subtitleOverlay: some View {
        let now = player.currentTime
        let active = player.cues.filter { $0.start <= now && now < $0.end }
        VStack(spacing: 4) {
            ForEach(active) { cue in
                if case .text(let text) = cue.content {
                    Text(text)
                        .font(.system(size: 22, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .shadow(color: .black, radius: 2)
                        .padding(.horizontal, 8)
                } else if case .image(let image, _, _) = cue.content {
                    Image(decorative: image, scale: 1).resizable().scaledToFit().frame(maxHeight: 120)
                }
            }
        }
        .padding(.bottom, 24)
        .allowsHitTesting(false)
    }

    // MARK: Actions

    private func open(_ entry: LabMatrixEntry) async {
        error = nil
        item = nil
        guard let client = session.client else { error = "Not connected"; return }
        do {
            item = try await client.metadata(entry.ratingKey)
        } catch {
            self.error = "\(error)"
        }
    }

    private func play(from start: Double) async {
        guard let client = session.client, let item,
              let key = item.media.first?.parts.first?.key,
              let url = client.urls.part(key: key) else { return }
        error = nil
        do {
            try await player.load(PlaybackRequest(url: url, headers: client.requestHeaders, startPosition: start,
                                                  preferredAudioLanguages: ["eng"], preferredSubtitleLanguages: ["eng"]))
        } catch is CancellationError {
        } catch {
            self.error = "\(error)"
        }
    }

    private func record() {
        guard let entry = selection else { return }
        let d = player.diagnostics
        let ttff = d.timeToFirstFrame.map { "\(Int($0.components.seconds * 1000 + $0.components.attoseconds / 1_000_000_000_000_000))ms" } ?? "-"
        let seek = d.lastSeekLatency.map { "\(Int($0.components.seconds * 1000 + $0.components.attoseconds / 1_000_000_000_000_000))ms" } ?? "-"
        log.append("\(entry.id) | route=\(d.route) vdec=\(d.videoDecoder ?? "-") adec=\(d.audioDecoder ?? "-") audio=\(d.audioDelivery) shaping=\(d.audioShaping) fmt=\(d.videoFormat) ttff=\(ttff) seek=\(seek) status=\(player.status)")
    }

    private func format(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "--:--" }
        let t = Int(s)
        return String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60)
    }
}
#endif
