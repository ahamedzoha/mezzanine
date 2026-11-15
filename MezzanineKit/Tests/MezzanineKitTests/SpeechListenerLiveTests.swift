import Testing
import Foundation
import AVFAudio
@testable import MezzanineKit

/// Runs the real on-device recognizer over an audio file, fed as the player would feed it
/// (48 kHz mono slices, starting 1000 s into the "film"). Opt in:
/// `MEZZANINE_SPEECH=/path/to/speech.aiff swift test --filter SpeechListenerLiveTests`
/// (make one with `say -o speech.aiff "…"`). May download the speech model once.
@Suite("Speech listener (on device)", .enabled(if: ProcessInfo.processInfo.environment["MEZZANINE_SPEECH"] != nil))
struct SpeechListenerLiveTests {
    @Test func transcribesOnTheSourceTimeline() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["MEZZANINE_SPEECH"])
        let locale = try #require(await SpeechListener.locale(for: "eng"))
        print("locale", locale.identifier, "installed", await SpeechListener.isInstalled(locale))
        try await SpeechListener.install(locale) { print("model", $0) }

        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let tap = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let converter = try #require(AVAudioConverter(from: file.processingFormat, to: tap))
        let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: source)
        let whole = AVAudioPCMBuffer(pcmFormat: tap, frameCapacity: AVAudioFrameCount(Double(file.length) * 48_000 / file.processingFormat.sampleRate) + 4800)!
        var fed = false
        _ = converter.convert(to: whole, error: nil) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true; status.pointee = .haveData; return source
        }

        let listener = SpeechListener(locale: locale)
        let collector = Task { var all: [SpokenWord] = []; for await p in listener.phrases { all += p }; return all }
        var t = 1000.0
        var offset: AVAudioFrameCount = 0
        while offset < whole.frameLength {
            let n = min(4800, whole.frameLength - offset)
            let slice = AVAudioPCMBuffer(pcmFormat: tap, frameCapacity: n)!
            slice.frameLength = n
            memcpy(slice.floatChannelData![0], whole.floatChannelData![0].advanced(by: Int(offset)), Int(n) * 4)
            await listener.feed(SpeechAudio(buffer: slice, time: t, discontinuity: false))
            t += Double(n) / 48_000
            offset += n
        }
        await listener.finish()
        let words = await collector.value
        print(words.map { String(format: "%@ %.2f-%.2f", $0.text, $0.start, $0.end) }.joined(separator: " | "))
        for line in CueBuilder.lines(from: words) {
            print(String(format: "%.2f → %.2f", line.start, line.end), line.text.replacingOccurrences(of: "\n", with: " / "))
        }
        #expect(words.count >= 10)
        #expect((words.first?.start ?? 0) >= 1000)
        #expect((words.last?.end ?? 0) <= t + 0.5)
    }
}
