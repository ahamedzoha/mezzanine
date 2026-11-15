import Foundation
import Speech
import AVFAudio
import CoreMedia

/// On-device speech recognition of the playing audio (SpeechAnalyzer with SpeechTranscriber).
/// Feed it the audio as it's read; it answers with the words of each finished phrase and
/// when they were spoken, on the file's own timeline. Nothing leaves the Mac.
public actor SpeechListener {
    /// The recognizer's locale for a track language ("eng", "en", "fr-CA"); without one, the
    /// Mac's own language. Nil when this Mac can't transcribe that language.
    public static func locale(for language: String?) async -> Locale? {
        guard SpeechTranscriber.isAvailable else { return nil }
        let code = language.map(SubtitleLanguage.code).flatMap { $0 == "und" || $0.isEmpty ? nil : $0 }
            ?? Locale.current.language.languageCode?.identifier ?? "en"
        // The Mac's own region first ("en" on a UK Mac is en-GB).
        let regional = Locale.current.region.map { Locale(identifier: "\(code)-\($0.identifier)") }
        if let regional, let match = await SpeechTranscriber.supportedLocale(equivalentTo: regional),
           match.language.languageCode?.identifier == code { return match }
        return await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: code))
    }

    /// The speech model for `locale` is already on this Mac.
    public static func isInstalled(_ locale: Locale) async -> Bool {
        let id = locale.identifier(.bcp47)
        return await SpeechTranscriber.installedLocales.contains { $0.identifier(.bcp47) == id }
    }

    /// Downloads the speech model for `locale` when it isn't on this Mac yet, reporting 0…1.
    public static func install(_ locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber(locale)]) else { return }
        let observation = request.progress.observe(\.fractionCompleted, options: [.initial, .new]) { p, _ in
            progress(p.fractionCompleted)
        }
        defer { observation.invalidate() }
        try await request.downloadAndInstall()
    }

    static func transcriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
    }

    // MARK: Listening

    /// Each finished phrase's words, in order.
    public nonisolated let phrases: AsyncStream<[SpokenWord]>
    private let output: AsyncStream<[SpokenWord]>.Continuation
    private let locale: Locale

    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private var format: AVAudioFormat?
    /// Where the audio fed so far ends (source seconds).
    private var fedEnd: Double?

    public init(locale: Locale) {
        self.locale = locale
        (phrases, output) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    /// Adds the next slice. Audio that jumps back (a seek backwards) starts a fresh analysis,
    /// since the recognizer only moves forward; a jump forward just leaves a gap.
    public func feed(_ audio: SpeechAudio) async {
        let duration = Double(audio.buffer.frameLength) / audio.buffer.format.sampleRate
        if analyzer == nil || (fedEnd.map { audio.time < $0 - 0.05 } ?? false) {
            await restart()
        }
        guard input != nil, let format else { return }
        // Contiguous audio carries no time (the analyzer counts samples); after a gap, the
        // slice says where it starts.
        var start: CMTime?
        if fedEnd == nil || audio.discontinuity || abs(audio.time - (fedEnd ?? 0)) > 0.02 {
            converter?.reset()
            start = CMTime(seconds: audio.time, preferredTimescale: 48_000)
        }
        fedEnd = audio.time + duration
        guard let buffer = convert(audio.buffer, to: format) else { return }
        input?.yield(AnalyzerInput(buffer: buffer, bufferStartTime: start))
    }

    /// Finishes the phrases in progress, then ends `phrases`.
    public func finish() async {
        input?.finish()
        if let analyzer { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
        await results?.value
        analyzer = nil
        output.finish()
    }

    /// Stops at once, dropping anything unfinished.
    public func cancel() async {
        input?.finish()
        await analyzer?.cancelAndFinishNow()
        results?.cancel()
        analyzer = nil
        output.finish()
    }

    private func restart() async {
        if let analyzer {
            input?.finish()
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
            await results?.value
        }
        analyzer = nil
        input = nil
        fedEnd = nil
        let module = Self.transcriber(locale)
        guard let best = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else { return }
        let analyzer = SpeechAnalyzer(modules: [module])
        let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
        do {
            try await analyzer.prepareToAnalyze(in: best)
            try await analyzer.start(inputSequence: stream)
        } catch {
            return
        }
        let output = self.output
        results = Task {
            do {
                for try await result in module.results {
                    let words = SpokenWord.tightened(Self.words(result.text))
                    if !words.isEmpty { output.yield(words) }
                }
            } catch {}
        }
        self.analyzer = analyzer
        self.input = input
        if format != best {
            format = best
            converter = nil
        }
    }

    // MARK: Helpers

    /// Words with their times from a result's runs. Punctuation without a time joins the word
    /// before it.
    static func words(_ text: AttributedString) -> [SpokenWord] {
        var out: [SpokenWord] = []
        var pendingSpace = true
        for run in text.runs {
            let raw = String(text[run.range].characters)
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { pendingSpace = true; continue }
            let spaced = pendingSpace || (raw.first?.isWhitespace ?? false)
            pendingSpace = raw.last?.isWhitespace ?? false
            let spoken = trimmed.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
            if spoken, let range = run.audioTimeRange, range.duration.seconds.isFinite, range.start.seconds.isFinite {
                out.append(SpokenWord(trimmed, start: range.start.seconds, end: range.end.seconds, spaced: spaced))
            } else if !out.isEmpty {
                out[out.count - 1].text += (spaced ? " " : "") + trimmed
            }
        }
        return out
    }

    private final class Once: @unchecked Sendable { var done = false }

    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        let once = Once()
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, status in
            if once.done { status.pointee = .noDataNow; return nil }
            once.done = true
            status.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0 else { return nil }
        return out
    }
}
