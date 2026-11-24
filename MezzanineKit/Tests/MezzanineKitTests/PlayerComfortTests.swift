import Foundation
import Testing
@testable import MezzanineKit

@Suite("Sleep timer")
struct SleepTimerTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func minutesWaitFadeAndStop() {
        var timer = SleepTimer()
        #expect(timer.phase(now: start, remaining: 100) == .idle)
        timer.set(.minutes(30), now: start)
        #expect(timer.phase(now: start, remaining: nil) == .waiting)
        #expect(timer.left(now: start.addingTimeInterval(60), remaining: nil) == 1740.0)
        #expect(timer.phase(now: start.addingTimeInterval(30 * 60 - 20), remaining: nil) == .fading(seconds: 20, level: 1))
        #expect(timer.phase(now: start.addingTimeInterval(30 * 60 - 5), remaining: nil) == .fading(seconds: 5, level: 0.25))
        #expect(timer.phase(now: start.addingTimeInterval(30 * 60), remaining: nil) == .due)
        #expect(timer.phase(now: start.addingTimeInterval(99_999), remaining: nil) == .due)
    }

    @Test func endOfTitleFollowsTheTitle() {
        var timer = SleepTimer()
        timer.set(.endOfTitle, now: start)
        #expect(timer.stopsAtEnd)
        #expect(timer.phase(now: start, remaining: 600) == .waiting)
        #expect(timer.phase(now: start, remaining: 10) == .fading(seconds: 10, level: 0.5))
        // Seeking back un-fades; an unknown length just waits; the player reports the end itself.
        #expect(timer.phase(now: start, remaining: 300) == .waiting)
        #expect(timer.phase(now: start, remaining: nil) == .waiting)
        #expect(timer.phase(now: start, remaining: 0) == .fading(seconds: 0, level: 0))
    }

    @Test func keepWatching() {
        var timer = SleepTimer()
        timer.set(.minutes(15), now: start)
        let later = start.addingTimeInterval(15 * 60 - 3)
        timer.keepWatching(now: later)
        #expect(timer.left(now: later, remaining: nil) == 900.0)
        timer.set(.endOfTitle, now: later)
        timer.keepWatching(now: later)
        #expect(timer.choice == .off && !timer.stopsAtEnd)
        timer.set(.off, now: later)
        #expect(timer.left(now: later, remaining: 5) == nil)
    }
}

@Suite("Time entry")
struct TimeEntryTests {
    @Test(arguments: [("1:02:30", 3750.0), ("62:30", 3750), ("62", 3720), ("0:05", 5), (" 90 ", 5400), ("0", 0), ("1:00:00", 3600)])
    func reads(_ text: String, _ seconds: Double) { #expect(TimeEntry.seconds(text) == seconds) }

    @Test(arguments: ["", ":", "1:", ":30", "1:60", "1:2:60", "1:99:00", "1:2:3:4", "abc", "-5", "1.5", "１２", "99999"])
    func refuses(_ text: String) { #expect(TimeEntry.seconds(text) == nil) }

    @Test func endsByTheClock() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(TimeEntry.end(current: 600, duration: 4200, rate: 1, now: now) == now.addingTimeInterval(3600))
        #expect(TimeEntry.end(current: 600, duration: 4200, rate: 2, now: now) == now.addingTimeInterval(1800))
        #expect(TimeEntry.end(current: 5000, duration: 4200, rate: 1, now: now) == now)
        #expect(TimeEntry.end(current: 0, duration: 0, rate: 1, now: now) == nil)
    }
}

@Suite("What did they say")
struct CatchUpTests {
    func t(_ id: Int, _ language: String?, forced: Bool = false, sdh: Bool = false, commentary: Bool = false) -> CatchUp.Track {
        .init(id: id, language: language, isForced: forced, isHearingImpaired: sdh, isCommentary: commentary)
    }

    @Test func picksTheSpokenLanguageInFull() {
        let tracks = [t(1, "eng", forced: true), t(2, "fra"), t(3, "en", sdh: true), t(4, "en-US"), t(5, "eng", commentary: true)]
        #expect(CatchUp.track(from: tracks, spoken: "eng", preferred: ["fra"])?.id == 4)
        #expect(CatchUp.track(from: tracks, spoken: "jpn", preferred: ["fr"])?.id == 2)
        #expect(CatchUp.track(from: [tracks[0], tracks[2]], spoken: "en", preferred: [])?.id == 3)
        #expect(CatchUp.track(from: [t(7, nil)], spoken: "en", preferred: [])?.id == 7)
        #expect(CatchUp.track(from: [tracks[0], tracks[4]], spoken: "en", preferred: []) == nil)
        #expect(CatchUp.track(from: [], spoken: nil, preferred: []) == nil)
    }

    @Test func endsPastWhereItWasAsked() {
        let c = CatchUp(at: 100, trackID: 2)
        #expect(!c.isOver(at: 90))
        #expect(!c.isOver(at: 101))
        #expect(c.isOver(at: 101.5))
    }
}

@Suite("Diagnostics redaction")
struct RedactorTests {
    let redact = Redactor(names: ["Example Media Harbour", "Harbour", "Jo Doe", "The Wild Robot", "Al"], home: "/Users/jo")

    @Test func removesWhatIdentifies() {
        let text = """
        GET https://10-0-0-7.0123456789abcdef0123456789abcdef.plex.direct:32400/library/parts/12345/1700000000/file.mkv?X-Plex-Token=SECRET123abc&x=1
        wss://plex.example.com/:/websockets X-Plex-Token: "SECRET123abc" Authorization: Bearer SECRET123abc
        server Example Media Harbour for jo doe <jo@example.com> playing the wild robot at 10.0.0.7 (aa:bb:cc:dd:ee:ff, fe80:1:2:3:4:5:6:7)
        opened /Users/jo/Movies/x and /Users/other/y id 00112233445566778899aabbccddeeff00112233
        client mezzanine-01234567-89ab-cdef-0123-456789abcdef loaded http://127.0.0.1:53523/master.m3u8
        """
        let out = redact(text)
        for secret in ["SECRET123abc", "10-0-0-7", "plex.direct", "plex.example.com", "Harbour", "jo doe", "jo@example", "wild robot",
                       "10.0.0.7", "aa:bb:cc", "fe80", "/Users/jo", "/Users/other", "00112233", "01234567-89ab", "12345"] {
            #expect(!out.localizedCaseInsensitiveContains(secret), "\(secret) is still there")
        }
        #expect(out.contains("http://127.0.0.1:53523/master.m3u8"))
        #expect(out.contains(":32400"))
    }

    /// What a reader needs stays: times, versions, engine facts.
    @Test func keepsTheEvidence() {
        let text = "2026-11-24 10:19:44.438 [engine] startup 8/8 presenting (gen 4) makeup +11.6 dB seg-255 1011.58s version 26.6.2"
        #expect(redact(text) == text)
    }
}
