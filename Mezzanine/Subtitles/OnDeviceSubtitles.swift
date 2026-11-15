import SwiftUI
import Translation
import MezzanineKit
import MezzaninePlayback

/// Subtitles made on this Mac (M12), one set per title on screen:
/// - **Generate from Speech**: the dialogue, read ~10 s ahead of the picture, is turned into
///   subtitle lines (SpeechAnalyzer) and kept for the title, so rewatching starts with them.
/// - **Translate**: any text subtitle in another language is shown in the owner's language
///   (Translation), a minute ahead of the picture.
/// - **Match Timing to Speech**: listens for up to a couple of minutes and sets the
///   subtitle Timing so the lines land on the words.
/// The audio and the text are processed on this Mac and never sent anywhere.
@MainActor @Observable
final class OnDeviceSubtitles {
    enum Generation: Equatable {
        case off
        /// Getting the recognizer ready (and downloading its model: `modelProgress`).
        case preparing
        case listening
        case failed(String)
    }

    enum Matching: Equatable {
        case idle
        /// Lines matched so far.
        case listening(Int)
        case failed(String)
    }

    enum Translating: Equatable {
        case idle
        /// The pair is being checked or its languages downloaded.
        case preparing
        case working
        /// This pair ("es>en") can't be translated here; another pair is tried afresh.
        case unavailable(pair: String, message: String)
    }

    // MARK: State the panel and the overlay read

    /// Generated lines for this title, sorted.
    private(set) var lines: [TimedLine] = []
    /// Two-letter code of the language they're in.
    private(set) var generatedLanguage: String?
    /// The generated track is the one on screen (and still being written).
    private(set) var showsGenerated = false
    private(set) var generation: Generation = .off
    private(set) var matching: Matching = .idle
    /// Translate subtitles that aren't in the owner's language (kept across titles).
    var translates = UserDefaults.standard.bool(forKey: "translateSubtitles") {
        didSet { UserDefaults.standard.set(translates, forKey: "translateSubtitles") }
    }
    private(set) var translating: Translating = .idle
    private(set) var translations: [String: String] = [:]
    /// The speech model is downloading (0…1).
    private(set) var modelProgress: Double?
    /// The latest thing worth a readout (the stage shows it and VoiceOver hears it); `long`
    /// keeps a problem on screen long enough to read.
    private(set) var announcement: (id: Int, text: String, long: Bool)?
    /// Chooses a subtitle track the way the panel does (set by the coordinator), so Stop
    /// Generating and a failed start put back the subtitle that was on screen.
    @ObservationIgnored var selectTrack: ((Int?) -> Void)?

    var hasGenerated: Bool { showsGenerated || !lines.isEmpty }

    /// A readout held on screen while something runs: the model download or a timing match.
    var status: String? {
        if let modelProgress { return "Speech model · \(Int(modelProgress * 100)) %" }
        if case .listening(let n) = matching {
            return n == 0 ? "Timing · Matching to speech" : "Timing · Matching · \(n) \(n == 1 ? "line" : "lines")"
        }
        return nil
    }

    /// The spoken language, for labels: the generated track's, else the audio track's.
    var spokenLanguageName: String? { spokenLanguage.map(Self.languageName) }

    // MARK: Context

    @ObservationIgnored private let player: MezzaninePlayer
    @ObservationIgnored private var ratingKey: String?
    @ObservationIgnored private var serverID: String?
    @ObservationIgnored private var listenTask: Task<Void, Never>?
    @ObservationIgnored private var feedTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var matchWords: [SpokenWord] = []
    @ObservationIgnored private var matchCues: [Int: TimedLine] = [:]
    @ObservationIgnored private var untranslatable: Set<String> = []
    /// The subtitle on screen before generating started.
    @ObservationIgnored private var previousTrack: Int?
    /// Generate was asked for while the title was still loading.
    @ObservationIgnored private var generateWhenReady = false

    init(player: MezzaninePlayer) {
        self.player = player
    }

    /// A title is on screen: its generated subtitles come back, on screen again if they were
    /// last time (or `carry`: the previous episode of the same show was generating).
    func begin(ratingKey: String, serverID: String?, carry: Bool) {
        let asked = generateWhenReady
        end()
        self.ratingKey = ratingKey
        self.serverID = serverID
        if let saved = SavedSubtitles.generated(serverID: serverID, ratingKey: ratingKey) {
            lines = saved.lines
            generatedLanguage = saved.meta.language
            if saved.meta.active || carry || asked { showGenerated() }
        } else if carry || asked {
            showGenerated()
        }
    }

    /// The title left the screen: what was written is saved, listening stops.
    func end() {
        if ratingKey != nil { save() }
        stopListening()
        saveTask?.cancel()
        ratingKey = nil
        lines = []
        generatedLanguage = nil
        showsGenerated = false
        generation = .off
        matching = .idle
        modelProgress = nil
        previousTrack = nil
        generateWhenReady = false
        translations = [:]
        untranslatable = []
        translating = .idle
    }

    /// Another subtitle was chosen: old problems and a refused translation pair no longer apply.
    func trackChanged() {
        if case .failed = generation { generation = .off }
        if case .failed = matching { matching = .idle }
        if case .unavailable = translating { translating = .idle }
    }

    // MARK: Generate from Speech

    /// Starts writing subtitles from the dialogue and shows them, or stops: the subtitle
    /// shown before comes back, and what was written is kept.
    func toggleGenerate() {
        if showsGenerated {
            hideGenerated()
            restorePreviousTrack()
        } else if ratingKey == nil {
            // Still loading: start as soon as the title is on screen.
            generateWhenReady.toggle()
            announce(generateWhenReady ? "Subtitles · Generating from speech once it starts" : "Subtitles · Generate cancelled")
        } else {
            showGenerated()
            announce("Subtitles · Generating from \(spokenLanguageName.map { $0 + " " } ?? "")speech")
        }
    }

    func showGenerated() {
        guard ratingKey != nil else { return }
        if player.selectedSubtitleID != nil { previousTrack = player.selectedSubtitleID }
        player.selectSubtitle(id: nil)
        if let ratingKey { SavedSubtitles.setActive(nil, serverID: serverID, ratingKey: ratingKey) }
        showsGenerated = true
        if case .listening = matching { cancelMatching() }
        generation = .preparing
        save()
        startListening()
    }

    /// Another track (or Off) was chosen, or generating stopped.
    func hideGenerated() {
        guard showsGenerated else { return }
        showsGenerated = false
        generation = .off
        modelProgress = nil
        save()
        stopListeningIfIdle()
    }

    private func restorePreviousTrack() {
        let track = previousTrack
        previousTrack = nil
        selectTrack?(track)
        let name = track.flatMap { id in player.subtitleTracks.first { $0.id == id } }.map(Format.trackName)
        announce("Subtitles: " + (name ?? "Off"))
    }

    // MARK: Match Timing to Speech

    /// Why Match Timing can't run on the subtitle on screen (short: it's the row's value).
    var matchBlocker: String? {
        if showsGenerated { return "Already in time" }
        guard let id = player.selectedSubtitleID, let track = player.subtitleTracks.first(where: { $0.id == id }) else {
            return "Needs a subtitle"
        }
        return Self.isPicture(track) ? "Picture subtitles" : nil
    }

    var canMatch: Bool { matchBlocker == nil }

    var isMatching: Bool {
        if case .listening = matching { return true }
        return false
    }

    func toggleMatching() {
        if isMatching {
            cancelMatching()
            announce("Timing · Match stopped")
            return
        }
        if let blocker = matchBlocker {
            announce("Timing · " + blocker)
            return
        }
        matchWords = []
        matchCues = [:]
        matching = .listening(0)
        startListening()
    }

    private func cancelMatching() {
        matching = .idle
        matchWords = []
        matchCues = [:]
        stopListeningIfIdle()
    }

    private func evaluateMatch() {
        for cue in player.cues {
            if case .text(let text) = cue.content, !text.isEmpty {
                matchCues[cue.id] = TimedLine(start: cue.start, end: cue.end, text: text)
            }
        }
        guard let first = matchWords.first?.start, let last = matchWords.last?.end else { return }
        let span = last - first
        let cues = Array(matchCues.values)
        #if DEBUG
        print(String(format: "MATCHING span=%.0f words=%d cues=%d byWords=%@", span, matchWords.count, cues.count,
                     TimingMatcher.byWords(cues: cues, words: matchWords).map { "\($0.offset)/\($0.lines)" } ?? "none"))
        #endif
        if let estimate = TimingMatcher.byWords(cues: cues, words: matchWords) {
            matching = .listening(estimate.lines)
            if estimate.lines >= 6 || span >= 45 { apply(estimate) }
        } else if span >= 60, let estimate = TimingMatcher.bySpeech(cues: cues, words: matchWords) {
            apply(estimate)
        } else if span >= 150 {
            matching = .failed("Not enough dialogue to match. Try a scene with more talking.")
            announce("Timing · Not enough dialogue", long: true)
            matchWords = []
            stopListeningIfIdle()
        }
    }

    private func apply(_ estimate: TimingMatcher.Estimate) {
        #if DEBUG
        print("MATCH offset=\(estimate.offset) lines=\(estimate.lines) method=\(estimate.method) words=\(matchWords.count) cues=\(matchCues.count)")
        #endif
        UserDefaults.standard.set(estimate.offset, forKey: "subtitleOffset")
        matching = .idle
        matchWords = []
        stopListeningIfIdle()
        announce(estimate.offset == 0 ? "Timing · Matched · on time" : String(format: "Timing · Matched · %+.1f s", estimate.offset))
    }

    // MARK: Listening

    private var wantsAudio: Bool {
        if showsGenerated { return true }
        if case .listening = matching { return true }
        return false
    }

    private func startListening() {
        guard listenTask == nil else { return }
        listenTask = Task { [weak self] in
            await self?.listen()
            self?.listenTask = nil
        }
    }

    private func stopListening() {
        listenTask?.cancel()
        listenTask = nil
        feedTask?.cancel()
        feedTask = nil
        player.stopSpeechAudio()
    }

    private func stopListeningIfIdle() {
        if !wantsAudio { stopListening() }
    }

    /// The spoken language: the generated track's, else the audio track's.
    private var spokenLanguage: String? {
        if let generatedLanguage { return generatedLanguage }
        let track = player.audioTracks.first { $0.id == player.selectedAudioID }
        return track?.language.map(SubtitleLanguage.code).flatMap { $0 == "und" ? nil : $0 }
    }

    private func listen() async {
        let language = spokenLanguage
        let name = language.map(Self.languageName) ?? "This language"
        guard let locale = await SpeechListener.locale(for: language) else {
            fail("\(name) speech can’t be recognized on this Mac.", short: "\(name) speech isn’t supported")
            return
        }
        if !(await SpeechListener.isInstalled(locale)) {
            modelProgress = 0
            announce("Speech model · Downloading \(name)")
            do {
                try await SpeechListener.install(locale) { [weak self] fraction in
                    Task { @MainActor in
                        guard let self, self.modelProgress != nil else { return }
                        self.modelProgress = min(fraction, 0.99)
                    }
                }
                modelProgress = nil
            } catch {
                modelProgress = nil
                fail("The \(name) speech model couldn’t be downloaded. Check the connection and try again.",
                     short: "Speech model download failed")
                return
            }
        }
        if showsGenerated, generatedLanguage == nil {
            generatedLanguage = locale.language.languageCode?.identifier ?? language
        }
        while !Task.isCancelled, wantsAudio {
            guard let audio = player.speechAudio() else {
                fail("This video’s sound can’t be read for speech. Try again after the next scene loads.",
                     short: "Sound can’t be read")
                return
            }
            if showsGenerated { generation = .listening }
            let listener = SpeechListener(locale: locale)
            feedTask = Task.detached {
                for await slice in audio { await listener.feed(slice) }
                #if DEBUG
                print("TAP ENDED")
                #endif
                await listener.finish()
            }
            for await phrase in listener.phrases {
                received(phrase)
            }
            feedTask?.cancel()
            // The tap ends on any reload (a track switch, a seek into a new session): follow it.
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    private func received(_ words: [SpokenWord]) {
        #if DEBUG
        print(String(format: "HEARD %.1f–%.1f %@", words.first?.start ?? 0, words.last?.end ?? 0, words.map(\.text).joined(separator: " ")))
        #endif
        if showsGenerated {
            lines = CueBuilder.merge(lines, CueBuilder.lines(from: words))
            scheduleSave()
        }
        if case .listening = matching {
            // A seek starts the listening over: only one stretch of film is compared.
            if let last = matchWords.last, let first = words.first, first.start < last.start || first.start - last.end > 30 {
                matchWords = []
            }
            matchWords += words
            evaluateMatch()
        }
    }

    /// Something stopped the listening: the panel keeps `message`, the readout shows `short`,
    /// and the subtitle on screen before generating comes back.
    private func fail(_ message: String, short: String) {
        stopListening()
        if showsGenerated {
            showsGenerated = false
            generation = .failed(message)
            save()
            let track = previousTrack
            previousTrack = nil
            selectTrack?(track)
            generation = .failed(message)
        }
        if case .listening = matching { matching = .failed(message) }
        announce(short, long: true)
    }

    // MARK: Saving

    private func scheduleSave() {
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.save()
            self?.saveTask = nil
        }
    }

    private func save() {
        guard let ratingKey, let language = generatedLanguage, !lines.isEmpty || showsGenerated else { return }
        SavedSubtitles.saveGenerated(lines, meta: .init(language: language, active: showsGenerated),
                                     serverID: serverID, ratingKey: ratingKey)
    }

    // MARK: Translate

    /// The owner's language: the first one Find Subtitles searches in.
    var targetLanguage: String {
        UserDefaults.standard.stringArray(forKey: "subtitleLanguages")?.first
            ?? SubtitleSourceSettings.systemLanguages.first ?? "en"
    }

    /// The language of the text on screen, when known.
    var sourceLanguage: String? {
        if showsGenerated { return generatedLanguage }
        guard let id = player.selectedSubtitleID, let track = player.subtitleTracks.first(where: { $0.id == id }) else { return nil }
        return track.language.map(SubtitleLanguage.code).flatMap { $0 == "und" || $0.isEmpty ? nil : $0 }
    }

    /// Why Translate has nothing to do for the subtitle on screen.
    var translateBlocker: String? {
        if showsGenerated { return nil }
        guard let id = player.selectedSubtitleID, let track = player.subtitleTracks.first(where: { $0.id == id }) else {
            return "Choose a subtitle to translate"
        }
        if Self.isPicture(track) { return "Picture subtitles can’t be translated" }
        return nil
    }

    private var pairKey: String { "\(sourceLanguage ?? "auto")>\(targetLanguage)" }

    /// The pair Translation should prepare for, or nil when nothing needs translating.
    var translationConfiguration: TranslationSession.Configuration? {
        guard translates, translateBlocker == nil, showsGenerated || player.selectedSubtitleID != nil else { return nil }
        let target = targetLanguage
        if let source = sourceLanguage, source == target { return nil }
        if case .unavailable(let pair, _) = translating, pair == pairKey { return nil }
        return TranslationSession.Configuration(source: sourceLanguage.map { Locale.Language(identifier: $0) },
                                                target: Locale.Language(identifier: target))
    }

    /// Lines are being translated now (the overlay swaps them in).
    var isTranslatingNow: Bool { translationConfiguration != nil }

    func toggleTranslate() {
        translates.toggle()
        translating = .idle
        let target = Self.languageName(targetLanguage)
        if translates {
            if let blocker = translateBlocker { announce("Subtitles · " + blocker); return }
            if let source = sourceLanguage, source == targetLanguage {
                announce("Subtitles · Already in \(target)")
            } else {
                announce("Subtitles · Translating to \(target)")
            }
        } else {
            announce("Subtitles · Translation off")
        }
    }

    /// Runs inside `.translationTask` while a pair is configured: translates the lines on
    /// screen and the next minute and a half, nearest first.
    func serve(_ session: TranslationSession) async {
        let pair = pairKey
        translating = .preparing
        if let source = sourceLanguage {
            let status = await LanguageAvailability().status(from: Locale.Language(identifier: source),
                                                             to: Locale.Language(identifier: targetLanguage))
            if status == .unsupported {
                let message = "\(Self.languageName(source)) to \(Self.languageName(targetLanguage)) isn’t available on this Mac."
                translating = .unavailable(pair: pair, message: message)
                announce("Subtitles · Can’t translate \(Self.languageName(source))", long: true)
                return
            }
        }
        let box = SessionBox(session: session)
        do {
            try await Self.prepare(box)
        } catch {
            guard !Task.isCancelled else { return }
            translating = .unavailable(pair: pair, message: "The languages aren’t downloaded yet.")
            announce("Subtitles · Translation needs its languages", long: true)
            return
        }
        translating = .working
        while !Task.isCancelled {
            let batch = pendingPieces(limit: 16)
            guard !batch.isEmpty else {
                try? await Task.sleep(for: .milliseconds(400))
                continue
            }
            do {
                for (key, text) in try await Self.translate(box, batch) { translations[key] = text }
                for piece in batch where translations[piece] == nil { untranslatable.insert(piece) }
            } catch {
                if Task.isCancelled { return }
                untranslatable.formUnion(batch)
            }
        }
    }

    /// The session `.translationTask` hands over, used one call at a time from here (its
    /// methods predate Sendable annotations).
    nonisolated private struct SessionBox: @unchecked Sendable { let session: TranslationSession }

    nonisolated private static func prepare(_ box: SessionBox) async throws {
        try await box.session.prepareTranslation()
    }

    nonisolated private static func translate(_ box: SessionBox, _ texts: [String]) async throws -> [(String, String)] {
        let requests = texts.map { TranslationSession.Request(sourceText: $0, clientIdentifier: $0) }
        return try await box.session.translations(from: requests).compactMap { r in r.clientIdentifier.map { ($0, r.targetText) } }
    }

    private func pendingPieces(limit: Int) -> [String] {
        let now = player.currentTime - UserDefaults.standard.double(forKey: "subtitleOffset")
        var out: [String] = []
        for line in textLines(from: now - 2, to: now + 90) {
            for piece in TranslationPieces.pieces(line.text) where translations[piece] == nil && !untranslatable.contains(piece) && !out.contains(piece) {
                out.append(piece)
                if out.count == limit { return out }
            }
        }
        return out
    }

    /// The text lines of the subtitle on screen between two times, in order.
    func textLines(from start: Double, to end: Double) -> [TimedLine] {
        if showsGenerated {
            return lines.filter { $0.end > start && $0.start < end }
        }
        return player.cues.compactMap { cue -> TimedLine? in
            guard cue.end > start, cue.start < end, case .text(let text) = cue.content else { return nil }
            return TimedLine(start: cue.start, end: cue.end, text: text)
        }
        .sorted { $0.start < $1.start }
    }

    /// The line as it should read on screen: translated when Translate is on and the
    /// translation has arrived.
    func display(_ text: String) -> String {
        guard isTranslatingNow else { return text }
        return TranslationPieces.compose(text, translations) ?? text
    }

    // MARK: Helpers

    private func announce(_ text: String, long: Bool = false) {
        announcement = ((announcement?.id ?? 0) + 1, text, long)
    }

    static func languageName(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    static func isPicture(_ track: PlayerTrack) -> Bool {
        let codec = track.codec.lowercased()
        return ["pgs", "hdmv_pgs_subtitle", "dvd_subtitle", "dvdsub", "vobsub", "dvb_subtitle", "dvbsub", "xsub"].contains(codec)
    }
}
