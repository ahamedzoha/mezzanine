import Testing
import Foundation
@testable import MezzanineKit

@Suite("On-device subtitles")
struct OnDeviceSubtitleTests {
    private func words(_ text: String, from start: Double, perWord: Double = 0.35, gap: Double = 0.05) -> [SpokenWord] {
        var t = start
        return text.split(separator: " ").map { w in
            defer { t += perWord + gap }
            return SpokenWord(String(w), start: t, end: t + perWord)
        }
    }

    @Test func cueBuilderBreaksAtSentencesAndPauses() {
        let first = words("We should go now. The car is waiting outside.", from: 10)
        let second = words("Fine.", from: first.last!.end + 2)
        let lines = CueBuilder.lines(from: first + second)
        #expect(lines.map(\.text) == ["We should go now.", "The car is waiting outside.", "Fine."])
        #expect(lines[0].start == 10)
        #expect(lines[2].end - lines[2].start >= 1.0)
    }

    @Test func cueBuilderKeepsTwoRowsAndSixSeconds() {
        let long = words("this is a very long run of speech that keeps going without any punctuation at all for quite a while longer than a subtitle should hold", from: 0)
        let lines = CueBuilder.lines(from: long)
        #expect(lines.count >= 2)
        for line in lines {
            #expect(line.text.split(separator: "\n").count <= 2)
            #expect(line.text.split(separator: "\n").allSatisfy { $0.count <= 48 })
            #expect(line.end - line.start <= 6.6)
        }
    }

    @Test func cueBuilderJoinsUnspacedPieces() {
        let ws = [SpokenWord("It", start: 0, end: 0.2), SpokenWord("'s", start: 0.2, end: 0.3, spaced: false),
                  SpokenWord("fine.", start: 0.35, end: 0.7)]
        #expect(CueBuilder.lines(from: ws).first?.text == "It's fine.")
    }

    @Test func mergeSkipsOverlapsAndTrimsEnds() {
        let a = [TimedLine(start: 0, end: 3, text: "One")]
        let b = [TimedLine(start: 1, end: 2, text: "Dup"), TimedLine(start: 2.5, end: 5, text: "Two")]
        let merged = CueBuilder.merge(a, b)
        #expect(merged.map(\.text) == ["One", "Two"])
        #expect(merged[0].end <= 2.45 + 1e-9)
    }

    @Test func srtRoundTrip() {
        let lines = [TimedLine(start: 1.5, end: 3.25, text: "Hello there"),
                     TimedLine(start: 3725.04, end: 3727, text: "Two\nrows")]
        let text = SRT.write(lines)
        #expect(text.contains("01:02:05,040 --> 01:02:07,000"))
        let back = SRT.parse(text)
        #expect(back.count == 2)
        #expect(abs(back[1].start - 3725.04) < 0.001)
        #expect(back[1].text == "Two\nrows")
    }

    // MARK: Timing

    /// Subtitles for a minute of dialogue; speech is the same lines `shift` seconds later.
    private func scene(shift: Double) -> (cues: [TimedLine], words: [SpokenWord]) {
        let script = ["Where were you last night", "I told you already", "Nobody believes that story",
                      "Then ask my brother yourself", "Your brother left town on Friday", "That changes nothing at all",
                      "Sit down and listen carefully", "We found the car by the river", "Somebody wanted it found",
                      "You think this is a game"]
        var cues: [TimedLine] = []
        var spoken: [SpokenWord] = []
        var t = 100.0
        for (i, line) in script.enumerated() {
            let w = words(line, from: t + shift)
            spoken += w
            cues.append(TimedLine(start: t, end: t + Double(w.count) * 0.4 + 0.3, text: i % 3 == 0 ? "- " + line : line))
            t += Double(w.count) * 0.4 + 1.5 + Double(i % 4)
        }
        return (cues, spoken)
    }

    @Test func matchesByWords() throws {
        let (cues, spoken) = scene(shift: 2.3)
        let estimate = try #require(TimingMatcher.estimate(cues: cues, words: spoken))
        #expect(estimate.method == .words)
        #expect(abs(estimate.offset - 2.3) < 0.11)
    }

    @Test func matchesBySpeechInAnotherLanguage() throws {
        let (cues, spoken) = scene(shift: -1.7)
        // Same timing, different words: only the speech spans can line up.
        let foreign = spoken.map { SpokenWord("palabra", start: $0.start, end: $0.end) }
        #expect(TimingMatcher.byWords(cues: cues, words: foreign) == nil)
        let estimate = try #require(TimingMatcher.estimate(cues: cues, words: foreign))
        #expect(estimate.method == .speech)
        #expect(abs(estimate.offset + 1.7) < 0.21)
    }

    @Test func noMatchFromTooLittle() {
        let (cues, spoken) = scene(shift: 1)
        #expect(TimingMatcher.estimate(cues: Array(cues.prefix(2)), words: Array(spoken.prefix(8))) == nil)
    }

    @Test func languageCodes() {
        #expect(SubtitleLanguage.code("eng") == "en")
        #expect(SubtitleLanguage.code("fre") == "fr")
        #expect(SubtitleLanguage.code("ger") == "de")
        #expect(SubtitleLanguage.code("spa") == "es")
    }
}

@Suite("Translation pieces")
struct TranslationPiecesTests {
    @Test func speakerLinesStaySeparate() {
        #expect(TranslationPieces.pieces("- ¿Dónde?\n- Aquí.") == ["¿Dónde?", "Aquí."])
        #expect(TranslationPieces.compose("- ¿Dónde?\n- Aquí.", ["¿Dónde?": "Where?", "Aquí.": "Here."]) == "- Where?\n- Here.")
    }

    @Test func oneSentenceAcrossRows() {
        #expect(TranslationPieces.pieces("No sé si\nvendrá mañana.") == ["No sé si vendrá mañana."])
        #expect(TranslationPieces.compose("No sé si\nvendrá mañana.", [:]) == nil)
        #expect(TranslationPieces.compose("No sé si\nvendrá mañana.", ["No sé si vendrá mañana.": "I don't know if he'll come tomorrow."])
                == "I don't know if he'll come tomorrow.")
    }
}

@Suite("Cue builder tails")
struct CueBuilderTailTests {
    @Test func lastWordNeverAlone() {
        // 5.1 s of speech, then the phrase's last word just past the 6 s limit.
        var ws: [SpokenWord] = []
        var t = 1.0
        for w in "I acknowledge that henceforth my access to my memories will be spatially".split(separator: " ") {
            ws.append(SpokenWord(String(w), start: t, end: t + 0.4)); t += 0.45
        }
        ws.append(SpokenWord("dictated.", start: t, end: t + 0.6))
        let lines = CueBuilder.lines(from: ws)
        #expect(lines.count == 1)
        #expect(lines.first?.text.hasSuffix("dictated.") == true)
    }
}

@Suite("Word timing")
struct WordTimingTests {
    /// Real recognizer output for `say` audio whose voice onsets were measured at 1.42 s and
    /// 2.79 s: "I" had absorbed the pause before it.
    @Test func startsMoveToTheVoice() {
        let heard = [SpokenWord("already.", start: 1.98, end: 2.52), SpokenWord("I", start: 1.20, end: 1.62),
                     SpokenWord("Nobody", start: 2.58, end: 3.18)]
        let tight = SpokenWord.tightened(heard)
        #expect(abs(tight[1].start - 1.42) < 0.05)
        #expect(tight[0].start == 1.98)
        #expect(tight[2].start == 2.58)
    }
}
