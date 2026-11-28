import Foundation
import Testing
@testable import MezzanineKit

/// A generator that always gives the same shuffles.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

@Suite struct MusicQueueTests {
    func track(_ n: Int) -> QueuedTrack {
        QueuedTrack(ratingKey: "\(n)", title: "Song \(n)", artist: "Invented", album: "Album", duration: 180, index: n)
    }
    func tracks(_ range: ClosedRange<Int>) -> [QueuedTrack] { range.map(track) }
    func keys(_ list: [QueuedTrack]) -> [String] { list.map(\.ratingKey) }
    func adv(_ q: inout MusicQueue, user: Bool = false) -> String? { q.advance(userInitiated: user)?.ratingKey }
    func back(_ q: inout MusicQueue) -> String? { q.goBack()?.ratingKey }
    func jump(_ q: inout MusicQueue, _ id: UUID) -> String? { q.skip(to: id)?.ratingKey }
    func drop(_ q: inout MusicQueue, _ id: UUID) -> Bool { q.remove(id: id) }
    let album = QueueContext(kind: .album, ratingKey: "A", title: "Album")

    @Test func playsAnAlbumInOrderAndEnds() {
        var q = MusicQueue()
        q.start(context: album, tracks: tracks(1...4), at: 1)
        #expect(q.current?.ratingKey == "2")
        #expect(keys(q.upNext) == ["3", "4"])
        #expect(q.isPlayingContextInOrder)
        #expect(adv(&q) == "3")
        #expect(adv(&q) == "4")
        #expect(q.needsMoreSimilar)
        #expect(adv(&q) == nil)
        #expect(q.current == nil)
        #expect(keys(q.history) == ["2", "3", "4"])
    }

    @Test func playNextAndLaterOrder() {
        var q = MusicQueue()
        q.start(context: album, tracks: tracks(1...3))
        q.playLater([track(10)])
        q.playNext([track(20), track(21)])
        #expect(keys(q.upNext) == ["20", "21", "10", "2", "3"])
        #expect(q.isPlayingContextInOrder == false)
        #expect(adv(&q) == "20")
        #expect(adv(&q) == "21")
        #expect(adv(&q) == "10")
        #expect(adv(&q) == "2")
    }

    @Test func queuedCopiesGetTheirOwnIdentity() {
        var q = MusicQueue()
        let t = track(5)
        q.start(context: album, tracks: [track(1)])
        q.playNext([t])
        q.playNext([t])
        #expect(Set(q.playingNext.map(\.id)).count == 2)
        let target = q.playingNext[1].id
        #expect(drop(&q, target))
        #expect(q.playingNext.count == 1)
    }

    @Test func shuffleKeepsTheOriginalOrderToRestore() {
        var gen = SeededGenerator(state: 7)
        var q = MusicQueue()
        q.start(context: album, tracks: tracks(1...10), at: 0, shuffled: true, using: &gen)
        #expect(q.current?.ratingKey == "1")
        #expect(Set(keys(q.remaining)) == Set((2...10).map(String.init)))
        #expect(keys(q.remaining) != (2...10).map(String.init))
        q.advance()
        q.advance()
        q.setShuffled(false, using: &gen)
        // Back in album order, minus what already played.
        let left = keys(q.remaining)
        #expect(left == left.sorted { Int($0)! < Int($1)! })
        #expect(left.count == 7)
        q.setShuffled(true, using: &gen)
        #expect(Set(keys(q.remaining)) == Set(left))
    }

    @Test func shuffleStartPlaysTheChosenTrackFirstAndTheRestAll() {
        var gen = SeededGenerator(state: 3)
        var q = MusicQueue()
        q.start(context: album, tracks: tracks(1...6), at: 3, shuffled: true, using: &gen)
        #expect(q.current?.ratingKey == "4")
        #expect(Set(keys(q.remaining)) == ["1", "2", "3", "5", "6"])
        var q2 = MusicQueue()
        q2.startShuffled(context: album, tracks: tracks(1...6), using: &gen)
        #expect(q2.upNext.count == 5)
        #expect(q2.isShuffled)
    }

    @Test func repeatModes() {
        var q = MusicQueue()
        q.start(context: album, tracks: tracks(1...2))
        q.repeatMode = .one
        #expect(adv(&q) == "1")   // the track ends: it plays again
        #expect(adv(&q) == "1")
        #expect(adv(&q, user: true) == "2")   // Next still moves on
        q.repeatMode = .all
        #expect(q.peekNext?.ratingKey == "1")
        #expect(adv(&q) == "1")
        #expect(adv(&q) == "2")
        #expect(adv(&q) == "1")
        #expect(q.needsMoreSimilar == false)
        q.repeatMode = .off
        #expect(q.repeatMode.next == .all)
        #expect(RepeatMode.one.next == .off)
    }

    @Test func goBackReturnsToThePreviousTrackAndKeepsTheOneLeft() {
        var q = MusicQueue()
        q.start(context: album, tracks: tracks(1...3))
        #expect(back(&q) == nil)
        q.advance()
        q.advance()
        #expect(q.current?.ratingKey == "3")
        #expect(back(&q) == "2")
        #expect(q.current?.ratingKey == "2")
        #expect(keys(q.upNext) == ["3"])
        #expect(keys(q.history) == ["1"])
    }

    @Test func historyKeeps200() {
        var q = MusicQueue()
        q.start(context: album, tracks: tracks(1...260))
        for _ in 0..<255 { q.advance() }
        #expect(q.history.count == MusicQueue.historyLimit)
        #expect(q.history.last?.ratingKey == "255")
        #expect(q.history.first?.ratingKey == "56")
    }

    @Test func skipToAnUpNextEntry() {
        var q = MusicQueue()
        q.start(context: album, tracks: tracks(1...5))
        let target = q.remaining[2].id
        #expect(jump(&q, target) == "4")
        #expect(keys(q.history) == ["1", "2", "3"])
        #expect(keys(q.upNext) == ["5"])
        #expect(jump(&q, UUID()) == nil)
    }

    @Test func appendingKeepsThePlayOrderAndAdoptsIntoAnEmptyQueue() {
        var q = MusicQueue()
        q.playLater([track(1), track(2)])
        #expect(q.current?.ratingKey == "1")
        q.start(context: QueueContext(kind: .radio, title: "Radio"), tracks: [track(7)])
        q.append(contextTracks: [track(8), track(9)])
        #expect(keys(q.upNext) == ["8", "9"])
        #expect(q.contextOrder.count == 3)
        q.movePlayingNext(from: 0, to: 0)
        q.moveRemaining(from: 1, to: 0)
        #expect(keys(q.remaining) == ["9", "8"])
    }

    @Test func codableRoundTripKeepsEverything() throws {
        var gen = SeededGenerator(state: 11)
        var q = MusicQueue()
        q.start(context: album, tracks: tracks(1...8), at: 2, shuffled: true, using: &gen)
        q.playNext([track(30)])
        q.advance()
        q.repeatMode = .all
        q.continuesWithSimilar = false
        let data = try JSONEncoder().encode(q)
        let back = try JSONDecoder().decode(MusicQueue.self, from: data)
        #expect(back == q)
        #expect(back.isShuffled)
        #expect(back.repeatMode == .all)
        #expect(back.continuesWithSimilar == false)
    }
}
