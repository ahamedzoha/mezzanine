import SwiftUI
import MezzanineKit
import MezzaninePlayback

/// The ⋯ panel: four rows (Audio, Subtitles, Sound, Speed), each opening its
/// choices in place. Dark glass, like every player control.
struct PlayerOptions: View {
    let item: PlexMetadata
    /// The open page; the stage owns it so Esc and the subtitle-options key can drive it.
    @Binding var page: Page
    let close: () -> Void

    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(SoundSettings.self) private var sound
    @Environment(SessionStore.self) private var session
    @AppStorage("subtitleScale") private var subtitleScale: Double = 1
    @AppStorage("subtitleBackground") private var subtitleBackground = false
    @AppStorage("subtitleOffset") private var subtitleOffset: Double = 0
    @AppStorage("settingsTab") private var settingsTab = "account"
    @Environment(SubtitleFinder.self) private var finder
    @Environment(SubtitleSourceSettings.self) private var sources
    @Environment(DownloadStore.self) private var downloads
    @Environment(\.openSettings) private var openSettings

    enum Page { case root, audio, subtitles, search, sound, speed, quality, picture, sleep, queue }

    private var player: MezzaninePlayer { playback.player }
    private var onDevice: OnDeviceSubtitles { playback.onDevice }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch page {
            case .root: root
            case .audio: audio
            case .subtitles: subtitles
            case .search: search
            case .sound: soundPage
            case .speed: speed
            case .quality: quality
            case .picture: picturePage
            case .sleep: sleepPage
            case .queue: queuePage
            }
        }
        .padding(Theme.Space.s)
        .frame(width: 360)
        // A solid graphite body over the glass rim: a bright frame never shows through the rows.
        .background(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous).fill(Theme.graphite.opacity(0.95)))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous).strokeBorder(Theme.rule, lineWidth: 1))
        .animation(Theme.Motion.quick, value: page)
        .task(id: page) { if page == .search { startSearch() } }
        #if DEBUG
        // -FindSubtitlesChoose YES: picks the first non-Plex result once the search ends (local only).
        .task(id: finder.isSearching) {
            guard page == .search, !finder.isSearching, UserDefaults.standard.bool(forKey: "FindSubtitlesChoose"),
                  let first = finder.results.first(where: { $0.source != PlexSubtitleSource.sourceName }) else { return }
            choose(first)
        }
        #endif
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
            row("Picture", value: playback.pictureMode.label) { page = .picture }
            row("Quality", value: playback.mode.label) { page = .quality }
            row("Queue", value: playback.queue.summary ?? "Empty") { page = .queue }
            if !playback.cast.isCasting { row("Sleep timer", value: playback.sleep.label(for: item)) { page = .sleep } }
        }
    }

    private var audio: some View {
        Group {
            header("Audio")
            boundedList(selected: player.selectedAudioID) {
                ForEach(player.audioTracks) { track in
                    choice(trackLabel(track), detail: trackDetail(track), selected: track.id == player.selectedAudioID) {
                        playback.selectAudio(trackID: track.id)
                    }
                    .id(track.id)
                }
            }
        }
    }

    private var subtitles: some View {
        Group {
            header("Subtitles")
            boundedList(selected: onDevice.showsGenerated ? Self.generatedRowID : player.selectedSubtitleID) {
                choice("Off", detail: nil, selected: player.selectedSubtitleID == nil && !onDevice.showsGenerated) {
                    playback.selectSubtitle(trackID: nil)
                }
                ForEach(player.subtitleTracks) { track in
                    choice(trackLabel(track), detail: subtitleDetail(track),
                           selected: track.id == player.selectedSubtitleID && !onDevice.showsGenerated) {
                        playback.selectSubtitle(trackID: track.id)
                    }
                    .id(track.id)
                }
                if onDevice.hasGenerated {
                    choice(generatedLabel, detail: generatedDetail, selected: onDevice.showsGenerated,
                           busy: onDevice.showsGenerated && onDevice.generation != .listening) {
                        if !onDevice.showsGenerated { onDevice.showGenerated() }
                    }
                    .id(Self.generatedRowID)
                }
            }
            Divider().overlay(Theme.rule).padding(.vertical, 4)
            row("Find Subtitles…", value: nil) { page = .search }
            row(onDevice.showsGenerated ? "Stop Generating" : "Generate from Speech", value: generateValue,
                symbol: onDevice.showsGenerated ? "stop.circle" : "waveform") { onDevice.toggleGenerate() }
                .accessibilityHint(onDevice.showsGenerated ? "Puts back the subtitle shown before; what was written is kept"
                                   : "Writes subtitles from the dialogue. The audio stays on this Mac")
            if case .failed(let message) = onDevice.generation { problemNote(message) }
            toggleRow("Translate to \(OnDeviceSubtitles.languageName(onDevice.targetLanguage))",
                      isOn: Binding(get: { onDevice.translates }, set: { _ in onDevice.toggleTranslate() }))
            if let note = translateNote { note.problem ? AnyView(problemNote(note.text)) : AnyView(self.note(note.text)) }
            if case .unavailable = onDevice.translating, onDevice.translates {
                row("Translation Languages…", value: nil, symbol: "arrow.up.forward.app") { openTranslationLanguages() }
                    .accessibilityHint("Opens Language & Region in System Settings")
            }
            stepper("Size", value: "\(Int(subtitleScale * 100)) %",
                    minus: { subtitleScale = max(0.6, subtitleScale - 0.1) }, plus: { subtitleScale = min(2, subtitleScale + 0.1) })
            toggleRow("Background box", isOn: $subtitleBackground)
            stepper("Timing", value: offsetLabel,
                    minus: { subtitleOffset = (subtitleOffset - 0.1).rounded(to: 0.1) }, plus: { subtitleOffset = (subtitleOffset + 0.1).rounded(to: 0.1) })
            row(onDevice.isMatching ? "Stop Matching" : "Match Timing to Speech", value: matchValue ?? onDevice.matchBlocker,
                symbol: onDevice.isMatching ? "stop.circle" : "waveform.badge.magnifyingglass") { onDevice.toggleMatching() }
                .disabled(!onDevice.isMatching && !onDevice.canMatch)
                .accessibilityValue(matchValue ?? onDevice.matchBlocker ?? "")
                .accessibilityHint(onDevice.isMatching ? "Stops listening and keeps the current Timing"
                                   : "Listens to the dialogue while the video plays and sets Timing so the lines land on the words")
            if case .failed(let message) = onDevice.matching { problemNote(message) }
        }
    }

    // MARK: On-device subtitles (M12)

    private static let generatedRowID = -2

    private var generatedLabel: String {
        "\(onDevice.generatedLanguage.map(OnDeviceSubtitles.languageName) ?? onDevice.spokenLanguageName ?? "Speech") · Generated"
    }

    private var generatedDetail: String {
        let written = onDevice.lines.last.map { "written to \(Format.clock($0.end))" }
        if onDevice.showsGenerated {
            if let p = onDevice.modelProgress { return "Downloading the speech model · \(Int(p * 100)) %" }
            switch onDevice.generation {
            case .preparing: return "Starting…"
            case .listening: return ["From the dialogue", written, "writing ahead"].compactMap { $0 }.joined(separator: " · ")
            default: break
            }
        }
        return ["From the dialogue", written ?? "on this Mac"].joined(separator: " · ")
    }

    private var generateValue: String? {
        guard !onDevice.showsGenerated, let name = onDevice.spokenLanguageName else { return nil }
        return "\(name) speech"
    }

    private var translateNote: (text: String, problem: Bool)? {
        guard onDevice.translates else { return nil }
        if let blocker = onDevice.translateBlocker { return (blocker + ".", false) }
        if let source = onDevice.sourceLanguage, source == onDevice.targetLanguage {
            return ("Already in \(OnDeviceSubtitles.languageName(source)).", false)
        }
        switch onDevice.translating {
        case .unavailable(_, let message): return (message, true)
        case .working: return ("Translated on this Mac · a minute ahead", false)
        case .idle, .preparing: return ("Preparing translation…", false)
        }
    }

    private var matchValue: String? {
        guard case .listening(let n) = onDevice.matching else { return nil }
        if player.status == .paused { return "Paused · play to match" }
        if onDevice.modelProgress != nil { return "Downloading model" }
        return n == 0 ? "Listening…" : (n == 1 ? "1 line matched" : "\(n) lines matched")
    }

    /// System Settings ▸ General ▸ Language & Region, where Translation Languages live.
    private func openTranslationLanguages() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Every source at once; results arrive as each answers, files made for exactly this
    /// one first.
    private var search: some View {
        Group {
            header("Find Subtitles")
            if finder.isSearching {
                HStack(spacing: Theme.Space.s) {
                    ProgressView().controlSize(.small)
                    Text("Searching \(finder.pending.formatted(.list(type: .and)))…").lineLimit(2)
                }
                .font(Theme.Typeface.caption).foregroundStyle(Theme.inkSecondary)
                .padding(.horizontal, Theme.Space.m).padding(.vertical, 8)
                .accessibilityElement(children: .combine)
            }
            if !finder.results.isEmpty {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(finder.results.prefix(Self.shownResults)) { result in
                            choice(result.release, detail: resultDetail(result), selected: false,
                                   busy: finder.downloading == result.id, titleLines: 2, detailLines: 2) { choose(result) }
                                .disabled(finder.downloading != nil && finder.downloading != result.id)
                                .help(result.release)
                                .accessibilityHint("Loads this subtitle")
                        }
                        if finder.results.count > Self.shownResults {
                            note("Showing the best \(Self.shownResults) of \(finder.results.count).")
                        }
                    }
                }
                .frame(maxHeight: 300)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let failure = finder.failure { problemNote(failure) }
            if finder.problems.count > 2 {
                problemNote("\(finder.problems.map(\.source).formatted(.list(type: .and))) didn’t answer.")
            } else {
                ForEach(finder.problems, id: \.source) { problem in problemNote("\(problem.source): \(problem.message).") }
            }
            if finder.results.isEmpty && !finder.isSearching {
                note(finder.sourceCount == 0 ? "Every subtitle source is turned off. Turn one on in Subtitle Settings."
                     : "No subtitles found in \(languageList).")
            }
            Divider().overlay(Theme.rule).padding(.vertical, 4)
            if !finder.isSearching {
                row("Search Again", value: nil, symbol: "arrow.clockwise") { startSearch(again: true) }
            }
            if let missing = missingKeysNote {
                note(missing)
            } else if !finder.results.isEmpty {
                note("Plex results are saved on your server for every Plex app. The rest are kept on this Mac.")
            }
            row("Subtitle Settings…", value: languageList, symbol: "arrow.up.forward.app") {
                settingsTab = "subtitles"
                openSettings()
                close()
            }
            .accessibilityHint("Opens Settings")
        }
        .onChange(of: finder.isSearching) { _, searching in
            guard !searching, page == .search else { return }
            let n = finder.results.count
            AccessibilityNotification.Announcement(n == 0 ? "No subtitles found" : (n == 1 ? "1 subtitle found" : "\(n) subtitles found")).post()
        }
    }

    private static let shownResults = 60

    private var missingKeysNote: String? {
        switch (sources.openSubtitlesKey.isEmpty, sources.subdlKey.isEmpty) {
        case (true, true): "Free OpenSubtitles and Subdl keys find more, including subtitles made for this exact file."
        case (true, false): "A free OpenSubtitles key finds more, including subtitles made for this exact file."
        case (false, true): "A free Subdl key finds more."
        case (false, false): nil
        }
    }

    private func resultDetail(_ r: SubtitleResult) -> String {
        if finder.downloading == r.id { return "Loading…" }
        return [r.hashMatch ? "Matches this file" : nil,
                finder.languages.count > 1 ? Locale.current.localizedString(forLanguageCode: r.language) : nil,
                r.sourceLabel, r.hearingImpaired ? "SDH" : nil, r.forced ? "Forced" : nil,
                r.downloads.map { $0 == 1 ? "1 download" : "\($0.formatted(.number.notation(.compactName))) downloads" }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func note(_ text: String, color: Color = Theme.inkSecondary) -> some View {
        Text(text).font(Theme.Typeface.cardMeta).foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Theme.Space.m).padding(.vertical, 4)
    }

    /// A source that failed, or a choice that didn't load: marked with a symbol, not colour alone.
    private func problemNote(_ text: String) -> some View {
        Label { Text(text) } icon: { Image(systemName: "exclamationmark.triangle") }
            .font(Theme.Typeface.cardMeta).foregroundStyle(Theme.ink)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Theme.Space.m).padding(.vertical, 4)
            .accessibilityLabel("Problem: \(text)")
    }

    private var languageList: String {
        finder.languages.isEmpty ? languageName(sources.languages.first ?? "en")
            : finder.languages.map(languageName).formatted(.list(type: .and))
    }

    private func languageName(_ code: String) -> String { Locale.current.localizedString(forLanguageCode: code) ?? code }

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

    private var queuePage: some View {
        let entries = playback.queue.queue.entries
        return Group {
            header("Queue")
            if entries.isEmpty {
                note("Nothing queued. Choose Play Next or Add to Queue on a title, or Shuffle on a show or collection.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { i, entry in
                            queueRow(entry, isFirst: i == 0, isLast: i == entries.count - 1)
                        }
                    }
                }
                .frame(maxHeight: 300)
                Button("Clear Queue") { playback.queue.change { $0.clear() }; say("Queue cleared") }
                    .buttonStyle(SecondaryButtonStyle())
                    .focusEffectDisabled(false)
                    .padding(Theme.Space.s)
            }
        }
    }

    private func queueRow(_ entry: PlayQueue.Entry, isFirst: Bool, isLast: Bool) -> some View {
        HStack(spacing: Theme.Space.s) {
            Button { Task { await playback.playQueued(entry) } } label: { VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).font(Theme.Typeface.cardTitle).foregroundStyle(Theme.ink).lineLimit(1)
                if !entry.detail.isEmpty {
                    Text(entry.detail).font(Theme.Typeface.cardMeta).foregroundStyle(Theme.inkSecondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .focusEffectDisabled(false)
            .help("Play now")
            .accessibilityLabel("Play \(entry.title) now")
            queueButton("chevron.up", "Move Up", entry) { playback.queue.change { $0.move(entry.id, by: -1) }; say("\(entry.title) moved up") }.disabled(isFirst)
            queueButton("chevron.down", "Move Down", entry) { playback.queue.change { $0.move(entry.id, by: 1) }; say("\(entry.title) moved down") }.disabled(isLast)
            queueButton("xmark", "Remove from Queue", entry) { playback.queue.change { $0.remove(entry.id) }; say("\(entry.title) removed") }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel([entry.title, entry.detail].filter { !$0.isEmpty }.joined(separator: ", "))
    }

    private func say(_ text: String) { AccessibilityNotification.Announcement(text).post() }

    private func queueButton(_ symbol: String, _ label: String, _ entry: PlayQueue.Entry, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.ink)
                .frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled(false)
        .help(label)
        .accessibilityLabel("\(label): \(entry.title)")
    }

    private var sleepPage: some View {
        Group {
            header("Sleep timer")
            ForEach([SleepTimer.Choice.off, .endOfTitle] + SleepTimer.minuteChoices.map { .minutes($0) }, id: \.self) { choice in
                choiceRow(choice)
            }
            note("The sound fades out, then playback pauses and the Mac can sleep.")
        }
    }

    private func choiceRow(_ choice: SleepTimer.Choice) -> some View {
        let selected = playback.sleep.timer.choice == choice
        let left: String? = if selected, case .minutes = choice { playback.sleep.label(for: item) + " left" } else { nil }
        return self.choice(SleepWords.label(choice, episode: item.kind == .episode), detail: left, selected: selected) {
            playback.sleep.set(choice)
        }
    }

    /// Fit, Fill or Zoom (Z cycles), remembered for the film or show.
    private var picturePage: some View {
        Group {
            header("Picture")
            ForEach(PictureMode.allCases, id: \.self) { mode in
                choice(mode.label, detail: mode.detail, selected: playback.pictureMode == mode) {
                    withAnimation(Theme.Motion.object) { playback.pictureMode = mode }
                }
            }
            note("Kept for this film, or for every episode of this show.")
        }
    }

    /// Original first (direct play: the server does nothing); conversions only for slow
    /// links or files that won't open.
    private var quality: some View {
        Group {
            header("Quality")
            choice("Original", detail: "Direct play · the server does no work", selected: playback.mode == .direct) {
                Task { await playback.setMode(.direct) }
            }
            choice("Original, converted", detail: "Plex re-encodes at full quality", selected: playback.mode == .convert(nil) || playback.mode == .remux) {
                Task { await playback.setMode(.convert(nil)) }
            }
            ForEach(PlaybackMode.caps, id: \.self) { kbps in
                let mode = PlaybackMode.convert(kbps)
                choice(mode.label, detail: "For slow connections · Plex converts", selected: playback.mode == mode) {
                    Task { await playback.setMode(mode) }
                }
            }
        }
    }

    // MARK: Rows

    /// Long track lists scroll inside the panel instead of running off the window, opened
    /// on the track in use.
    private func boundedList<C: View>(selected: Int?, @ViewBuilder _ content: () -> C) -> some View {
        let rows = content()
        return ScrollViewReader { proxy in
            ScrollView { VStack(spacing: 2) { rows } }
                .frame(maxHeight: 260)
                .fixedSize(horizontal: false, vertical: true)
                .onAppear { if let selected { proxy.scrollTo(selected, anchor: .center) } }
                .onChange(of: selected) { _, id in if let id { withAnimation(Theme.Motion.quick) { proxy.scrollTo(id, anchor: .center) } } }
        }
    }

    private func row(_ title: String, value: String?, symbol: String = "chevron.right", action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.m) {
                Text(title).font(Theme.Typeface.cardTitle).foregroundStyle(Theme.ink)
                Spacer(minLength: Theme.Space.s)
                if let value { Text(value).font(Theme.Typeface.caption).foregroundStyle(Theme.inkSecondary).lineLimit(1) }
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                    .accessibilityHidden(true)
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
        .accessibilityLabel("\(title). Back to \(page == .search ? "Subtitles" : "playback options")")
        .accessibilityAddTraits(.isHeader)
    }

    private func choice(_ title: String, detail: String?, selected: Bool, busy: Bool = false, titleLines: Int = 1, detailLines: Int = 1,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.m) {
                ZStack {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.lilac).opacity(selected && !busy ? 1 : 0)
                    if busy { ProgressView().controlSize(.mini) }
                }
                .frame(width: 12)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(Theme.Typeface.cardTitle).foregroundStyle(Theme.ink).lineLimit(titleLines)
                    if let detail, !detail.isEmpty {
                        Text(detail).font(Theme.Typeface.cardMeta).foregroundStyle(Theme.inkSecondary).lineLimit(detailLines)
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
        .accessibilityElement(children: .combine)
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

    /// A switch row: the whole row flips it, and the switch sits on the trailing edge. Hueless
    /// (lilac is for the selection and the primary action only).
    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            HStack(spacing: Theme.Space.m) {
                Text(title).font(Theme.Typeface.cardTitle).foregroundStyle(Theme.ink)
                Spacer(minLength: Theme.Space.s)
                Toggle(title, isOn: isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(Theme.inkSecondary)
                    .allowsHitTesting(false)
            }
            .padding(.horizontal, Theme.Space.m)
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(OptionRowStyle())
        .focusEffectDisabled(false)
        .accessibilityRepresentation { Toggle(title, isOn: isOn) }
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
        if onDevice.showsGenerated { return generatedLabel }
        return player.subtitleTracks.first { $0.id == player.selectedSubtitleID }.map(trackLabel) ?? "Off"
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
        [t.codec.lowercased() == "subrip" ? "SRT" : t.codec.uppercased(), t.isForced ? "Forced" : nil, t.isHearingImpaired ? "SDH" : nil,
         t.isExternal ? "File" : nil, t.name.isEmpty ? nil : t.name].compactMap { $0 }.joined(separator: " · ")
    }

    private func speedLabel(_ r: Double) -> String {
        r == 1 ? "Normal" : (r == r.rounded() ? "\(Int(r))×" : String(format: "%g×", r))
    }

    // MARK: Subtitle search

    private func startSearch(again: Bool = false) {
        let current = playback.item ?? item
        finder.search(current, client: session.client,
                      localFile: playback.playingDownload ? downloads.localFile(for: current.ratingKey) : nil,
                      settings: sources, again: again)
    }

    private func choose(_ result: SubtitleResult) {
        let current = playback.item ?? item
        let serverID = session.currentServer?.clientIdentifier ?? downloads.record(current.ratingKey)?.serverID
        Task {
            if let found = await finder.choose(result, current: current, client: session.client, serverID: serverID, player: player,
                                               isCurrent: { playback.item?.ratingKey == current.ratingKey }) {
                playback.adoptFoundSubtitle(trackID: found.trackID, savedEntry: found.savedEntry, plexStream: found.plexStream)
                page = .subtitles
            }
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
