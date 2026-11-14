import SwiftUI
import MezzanineKit
import MezzaninePlayback

/// The ⋯ panel: four rows (Audio, Subtitles, Sound, Speed), each opening its
/// choices in place. Dark glass, like every player control.
struct PlayerOptions: View {
    let item: PlexMetadata
    let close: () -> Void

    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(SoundSettings.self) private var sound
    @Environment(SessionStore.self) private var session
    @AppStorage("subtitleScale") private var subtitleScale: Double = 1
    @AppStorage("subtitleBackground") private var subtitleBackground = false
    @AppStorage("subtitleOffset") private var subtitleOffset: Double = 0
    @State private var page: Page = .root
    @State private var results: [PlexStream] = []
    @State private var searching = false
    @State private var searchError: String?
    @State private var downloading: String?

    enum Page { case root, audio, subtitles, search, sound, speed }

    private var player: MezzaninePlayer { playback.player }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch page {
            case .root: root
            case .audio: audio
            case .subtitles: subtitles
            case .search: search
            case .sound: soundPage
            case .speed: speed
            }
        }
        .padding(Theme.Space.s)
        .frame(width: 360)
        // A solid graphite body over the glass rim: a bright frame never shows through the rows.
        .background(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous).fill(Theme.graphite.opacity(0.95)))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous).strokeBorder(Theme.rule, lineWidth: 1))
        .animation(Theme.Motion.quick, value: page)
        .onKeyPress(.escape) {
            guard page != .root else { return .ignored }
            page = page == .search ? .subtitles : .root
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Playback options")
    }

    // MARK: Pages

    private var root: some View {
        Group {
            row("Audio", value: currentAudio) { page = .audio }
            row("Subtitles", value: currentSubtitle) { page = .subtitles }
            row("Sound", value: soundSummary) { page = .sound }
            row("Speed", value: speedLabel(player.rate)) { page = .speed }
        }
    }

    private var audio: some View {
        Group {
            header("Audio")
            boundedList {
                ForEach(player.audioTracks) { track in
                    choice(trackLabel(track), detail: trackDetail(track), selected: track.id == player.selectedAudioID) {
                        playback.selectAudio(trackID: track.id)
                    }
                }
            }
        }
    }

    private var subtitles: some View {
        Group {
            header("Subtitles")
            boundedList {
                choice("Off", detail: nil, selected: player.selectedSubtitleID == nil) { playback.selectSubtitle(trackID: nil) }
                ForEach(player.subtitleTracks) { track in
                    choice(trackLabel(track), detail: subtitleDetail(track), selected: track.id == player.selectedSubtitleID) {
                        playback.selectSubtitle(trackID: track.id)
                    }
                }
            }
            Divider().overlay(Theme.rule).padding(.vertical, 4)
            row("Find Subtitles…", value: nil) { page = .search; Task { await runSearch() } }
            stepper("Size", value: "\(Int(subtitleScale * 100)) %",
                    minus: { subtitleScale = max(0.6, subtitleScale - 0.1) }, plus: { subtitleScale = min(2, subtitleScale + 0.1) })
            toggleRow("Background box", isOn: $subtitleBackground)
            stepper("Timing", value: offsetLabel,
                    minus: { subtitleOffset = (subtitleOffset - 0.1).rounded(to: 0.1) }, plus: { subtitleOffset = (subtitleOffset + 0.1).rounded(to: 0.1) })
        }
    }

    private var search: some View {
        Group {
            header("Find Subtitles")
            if searching {
                HStack(spacing: Theme.Space.s) { ProgressView().controlSize(.small); Text("Searching OpenSubtitles through Plex…") }
                    .font(Theme.Typeface.caption).foregroundStyle(Theme.inkSecondary).padding(Theme.Space.m)
            } else if let searchError {
                Text(searchError).font(Theme.Typeface.caption).foregroundStyle(Theme.inkSecondary).padding(Theme.Space.m)
            } else if results.isEmpty {
                Text("No subtitles found in \(languageName).").font(Theme.Typeface.caption).foregroundStyle(Theme.inkSecondary).padding(Theme.Space.m)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(results.prefix(20)) { result in
                            choice(result.title ?? result.label,
                                   detail: [result.providerTitle, result.hearingImpaired ? "SDH" : nil,
                                            downloading == result.key ? "Downloading…" : nil].compactMap { $0 }.joined(separator: " · "),
                                   selected: false) { Task { await download(result) } }
                        }
                    }
                }
                .frame(maxHeight: 300)
                Text("A chosen subtitle is saved on your server, so every Plex app sees it.")
                    .font(Theme.Typeface.cardMeta).foregroundStyle(Theme.inkTertiary).padding(.horizontal, Theme.Space.m).padding(.vertical, 6)
            }
        }
    }

    private var soundPage: some View {
        Group {
            header("Sound · \(sound.deviceName)")
            Picker("This output is", selection: Binding(get: { sound.current.kind }, set: { sound.setKind($0) })) {
                ForEach([AudioOutputKind.builtInSpeakers, .headphones, .speakers21, .airPods, .hdmi, .other], id: \.self) {
                    Text($0.label).tag($0)
                }
            }
            .pickerStyle(.menu)
            .padding(.horizontal, Theme.Space.m).padding(.vertical, 6)
            sliderRow("Volume", value: Binding(get: { sound.current.volumePercent }, set: { sound.setVolume($0) }),
                      range: 0...400, step: 10, label: "\(Int(sound.current.volumePercent)) %")
            sliderRow("Dialogue", value: Binding(get: { sound.current.profile.dialogueGainDB }, set: { sound.setDialogue($0) }),
                      range: 0...12, step: 1, label: "+\(Int(sound.current.profile.dialogueGainDB)) dB")
                .disabled(sound.current.kind == .hdmi)
            toggleRow("Night mode", isOn: Binding(get: { sound.current.profile.nightMode }, set: { _ in sound.toggleNight() }))
                .disabled(sound.current.kind == .hdmi)
            Text(sound.current.kind.summary)
                .font(Theme.Typeface.cardMeta).foregroundStyle(Theme.inkTertiary)
                .padding(.horizontal, Theme.Space.m).padding(.vertical, 6)
        }
    }

    private var speed: some View {
        Group {
            header("Speed")
            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                choice(speedLabel(rate), detail: nil, selected: abs(player.rate - rate) < 0.01) { player.setRate(rate) }
            }
        }
    }

    // MARK: Rows

    /// Long track lists scroll inside the panel instead of running off the window.
    private func boundedList<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        ScrollView { VStack(spacing: 2) { content() } }
            .frame(maxHeight: 260)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ title: String, value: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.m) {
                Text(title).font(Theme.Typeface.cardTitle).foregroundStyle(Theme.ink)
                Spacer(minLength: Theme.Space.s)
                if let value { Text(value).font(Theme.Typeface.caption).foregroundStyle(Theme.inkSecondary).lineLimit(1) }
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
            }
            .padding(.horizontal, Theme.Space.m)
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(OptionRowStyle())
        .focusEffectDisabled(false)
    }

    private func header(_ title: String) -> some View {
        Button { page = page == .search ? .subtitles : .root } label: {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                Text(title).font(Theme.Typeface.cardTitle)
                Spacer()
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, Theme.Space.m)
            .frame(height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled(false)
        .accessibilityLabel("Back to playback options")
    }

    private func choice(_ title: String, detail: String?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.lilac).opacity(selected ? 1 : 0)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(Theme.Typeface.cardTitle).foregroundStyle(Theme.ink).lineLimit(1)
                    if let detail, !detail.isEmpty {
                        Text(detail).font(Theme.Typeface.cardMeta).foregroundStyle(Theme.inkSecondary).lineLimit(1)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, Theme.Space.m)
            .frame(minHeight: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(OptionRowStyle())
        .focusEffectDisabled(false)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func stepper(_ title: String, value: String, minus: @escaping () -> Void, plus: @escaping () -> Void) -> some View {
        HStack(spacing: Theme.Space.s) {
            Text(title).font(Theme.Typeface.cardTitle).foregroundStyle(Theme.ink)
            Spacer()
            Button(action: minus) { Image(systemName: "minus").frame(width: 28, height: 28).contentShape(Rectangle()) }
                .buttonStyle(.plain).accessibilityLabel("Decrease \(title)")
            Text(value).font(Theme.Typeface.caption).foregroundStyle(Theme.inkSecondary).frame(minWidth: 64)
            Button(action: plus) { Image(systemName: "plus").frame(width: 28, height: 28).contentShape(Rectangle()) }
                .buttonStyle(.plain).accessibilityLabel("Increase \(title)")
        }
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, Theme.Space.m)
        .frame(height: 40)
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) { Text(title).font(Theme.Typeface.cardTitle).foregroundStyle(Theme.ink) }
            .toggleStyle(.switch)
            .tint(Theme.lilac)
            .padding(.horizontal, Theme.Space.m)
            .frame(height: 40)
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, label: String) -> some View {
        HStack(spacing: Theme.Space.m) {
            Text(title).font(Theme.Typeface.cardTitle).foregroundStyle(Theme.ink).frame(width: 72, alignment: .leading)
            Slider(value: value, in: range, step: step) { Text(title) }.labelsHidden().tint(Theme.ink)
            Text(label).font(Theme.Typeface.cardMeta).foregroundStyle(Theme.inkSecondary).frame(width: 52, alignment: .trailing)
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(height: 40)
    }

    // MARK: Labels

    private var currentAudio: String {
        player.audioTracks.first { $0.id == player.selectedAudioID }.map(trackLabel) ?? "—"
    }

    private var currentSubtitle: String {
        player.subtitleTracks.first { $0.id == player.selectedSubtitleID }.map(trackLabel) ?? "Off"
    }

    private var soundSummary: String {
        let s = sound.current
        var parts = ["\(Int(s.volumePercent)) %"]
        if s.profile.dialogueGainDB > 0 { parts.append("Dialogue +\(Int(s.profile.dialogueGainDB)) dB") }
        if s.profile.nightMode { parts.append("Night") }
        return parts.joined(separator: " · ")
    }

    private var offsetLabel: String {
        subtitleOffset == 0 ? "On time" : String(format: "%+.1f s", subtitleOffset)
    }

    private func trackLabel(_ t: PlayerTrack) -> String {
        let language = t.language.flatMap { Locale.current.localizedString(forLanguageCode: $0) }
        return language ?? (t.name.isEmpty ? "Track \(t.id)" : t.name)
    }

    private func trackDetail(_ t: PlayerTrack) -> String {
        [Format.codecLabel(t.codec), t.channels > 0 ? Format.channelLabel(t.channels) : nil,
         t.isAtmos ? "Atmos" : nil, t.isCommentary ? "Commentary" : nil, t.name.isEmpty ? nil : t.name]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func subtitleDetail(_ t: PlayerTrack) -> String {
        [t.codec.uppercased(), t.isForced ? "Forced" : nil, t.isHearingImpaired ? "SDH" : nil,
         t.isExternal ? "File" : nil, t.name.isEmpty ? nil : t.name].compactMap { $0 }.joined(separator: " · ")
    }

    private func speedLabel(_ r: Double) -> String {
        r == 1 ? "Normal" : (r == r.rounded() ? "\(Int(r))×" : String(format: "%g×", r))
    }

    private var languageCode: String { Locale.current.language.languageCode?.identifier ?? "en" }
    private var languageName: String { Locale.current.localizedString(forLanguageCode: languageCode) ?? "your language" }

    // MARK: Subtitle search

    private func runSearch() async {
        guard let client = session.client else { return }
        searching = true
        searchError = nil
        defer { searching = false }
        do {
            results = try await client.searchSubtitles(ratingKey: playback.item?.ratingKey ?? item.ratingKey, language: languageCode)
        } catch {
            searchError = (error as? PlexError)?.userMessage ?? "Search didn’t work."
        }
    }

    /// Downloads to the server as a sidecar, then adds it to this session and selects it.
    private func download(_ result: PlexStream) async {
        guard let client = session.client, let current = playback.item else { return }
        downloading = result.key
        defer { downloading = nil }
        do {
            let before = Set(current.media.first?.parts.first?.streams.map(\.id) ?? [])
            try await client.downloadSubtitle(ratingKey: current.ratingKey, result: result)
            let fresh = try await client.metadata(current.ratingKey)
            guard let added = fresh.media.first?.parts.first?.streams.first(where: {
                $0.streamType == .subtitle && $0.key != nil && !before.contains($0.id)
            }), let key = added.key, let url = client.urls.subtitle(streamKey: key) else {
                searchError = "The server saved it, but it isn’t listed yet. Try again in a moment."
                return
            }
            let track = player.addExternalSubtitle(ExternalSubtitle(url: url, name: added.label, language: added.languageCode,
                                                                    format: added.codec, isForced: added.forced,
                                                                    isHearingImpaired: added.hearingImpaired),
                                                   headers: client.requestHeaders)
            player.selectSubtitle(id: track.id)
            page = .subtitles
        } catch {
            searchError = (error as? PlexError)?.userMessage ?? "Couldn’t download that subtitle."
        }
    }
}

private struct OptionRowStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(configuration.isPressed ? Theme.ink.opacity(0.16) : (hovering ? Theme.ink.opacity(0.1) : .clear)))
            .onHover { hovering = $0 }
    }
}

private extension Double {
    func rounded(to step: Double) -> Double { (self / step).rounded() * step }
}
