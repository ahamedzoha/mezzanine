import Foundation
import Testing
@testable import MezzanineKit

@Suite struct ContinueWatchingTests {
    private func item(_ json: String) throws -> PlexMetadata {
        try JSONDecoder().decode(PlexMetadata.self, from: Data(json.utf8))
    }
    private func episode(_ key: String, show: String, index: Int, offset: Int? = nil) throws -> PlexMetadata {
        let resume = offset.map { ",\"viewOffset\":\($0)" } ?? ""
        return try item(#"{"ratingKey":"\#(key)","type":"episode","title":"E\#(index)","index":\#(index),"parentIndex":1,"grandparentRatingKey":"\#(show)","grandparentTitle":"Show \#(show)","duration":3000000\#(resume)}"#)
    }
    private func film(_ key: String, offset: Int? = nil) throws -> PlexMetadata {
        let resume = offset.map { ",\"viewOffset\":\($0)" } ?? ""
        return try item(#"{"ratingKey":"\#(key)","type":"movie","title":"Film \#(key)","duration":6000000\#(resume)}"#)
    }

    /// The owner's case: E1 ended, E2 autoplayed and stopped at 7 min; Plex still lists E1.
    @Test func finishedEpisodeGivesWayToTheOneAfterIt() throws {
        let now = Date()
        let e1 = try episode("61905", show: "td", index: 1, offset: 2_800_000)
        let e2 = try episode("61906", show: "td", index: 2)
        let plex = [e1, try film("9")]
        let stops = [PlaybackStop(item: e1, time: 2990, duration: 3000, at: now.addingTimeInterval(-160 + 60)),
                     PlaybackStop(item: e2, time: 426, duration: 3000, at: now.addingTimeInterval(-2))]
        let out = ContinueWatching.applying(stops, to: plex, now: now)
        #expect(out.map(\.ratingKey) == ["61906", "9"])
        #expect(out[0].viewOffset == 426_000)
    }

    @Test func plexAlreadyRightStaysRight() throws {
        let e2 = try episode("61906", show: "td", index: 2, offset: 425_989)
        let out = ContinueWatching.applying([PlaybackStop(item: e2, time: 426, duration: 3000)], to: [try film("9"), e2])
        #expect(out.map(\.ratingKey) == ["61906", "9"])
    }

    @Test func finishedFilmLeavesTheRow() throws {
        let f = try film("9", offset: 5_000_000)
        let out = ContinueWatching.applying([PlaybackStop(item: f, time: 5900, duration: 6000)], to: [f, try film("10")])
        #expect(out.map(\.ratingKey) == ["10"])
    }

    @Test func oldStopsAndShortPlaysChangeNothing() throws {
        let now = Date()
        let f = try film("9", offset: 1_000_000)
        let plex = [try film("10"), f]
        let old = PlaybackStop(item: f, time: 2000, duration: 6000, at: now.addingTimeInterval(-600))
        let short = PlaybackStop(item: try film("11"), time: 12, duration: 6000, at: now)
        #expect(ContinueWatching.applying([old, short], to: plex, now: now).map(\.ratingKey) == ["10", "9"])
    }

    /// Taken out by hand: gone at once, back if played again, and Plex decides after the window.
    @Test func removedTitlesLeaveUntilPlayedAgain() throws {
        let now = Date()
        let f = try film("9", offset: 1_000_000)
        let plex = [f, try film("10")]
        let removed = ["9": now.addingTimeInterval(-5)]
        #expect(ContinueWatching.applying([], removed: removed, to: plex, now: now).map(\.ratingKey) == ["10"])
        let before = PlaybackStop(item: f, time: 2000, duration: 6000, at: now.addingTimeInterval(-30))
        #expect(ContinueWatching.applying([before], removed: removed, to: plex, now: now).map(\.ratingKey) == ["10"])
        let after = PlaybackStop(item: f, time: 2000, duration: 6000, at: now.addingTimeInterval(-1))
        #expect(ContinueWatching.applying([after], removed: removed, to: plex, now: now).map(\.ratingKey) == ["9", "10"])
        let old = ["9": now.addingTimeInterval(-ContinueWatching.window - 1)]
        #expect(ContinueWatching.applying([], removed: old, to: plex, now: now).map(\.ratingKey) == ["9", "10"])
    }

    @Test func hubNames() {
        #expect(ContinueWatching.isContinueHub("home.continue"))
        #expect(ContinueWatching.isContinueHub("tv.ondeck"))
        #expect(ContinueWatching.isContinueHub("movie.inprogress"))
        #expect(!ContinueWatching.isContinueHub("home.movies.recent"))
    }
}
