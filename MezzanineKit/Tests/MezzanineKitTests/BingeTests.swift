import Foundation
import Testing
@testable import MezzanineKit

@Suite struct BingeTests {
    @Test func upNextAtCreditsMarker() {
        let markers = [PlexMarker(kind: .intro, startTimeOffset: 30_000, endTimeOffset: 90_000),
                       PlexMarker(kind: .credits, startTimeOffset: 1_621_000, endTimeOffset: 1_714_000, isFinal: true)]
        #expect(BingePlanner.upNextTrigger(duration: 1714, markers: markers) == 1621)
    }

    @Test func upNextFallsBackBeforeEnd() {
        #expect(BingePlanner.upNextTrigger(duration: 1500, markers: []) == 1470)
        // A "credits" marker in the first half is a cold-open card, not the end.
        let early = [PlexMarker(kind: .credits, startTimeOffset: 100_000, endTimeOffset: 120_000)]
        #expect(BingePlanner.upNextTrigger(duration: 1500, markers: early) == 1470)
        #expect(BingePlanner.upNextTrigger(duration: 40, markers: []) == nil)
    }

    @Test func introRules() {
        var s = BingeSettings()
        s.autoSkipIntro = .afterFirstEpisode
        #expect(!BingePlanner.shouldAutoSkipIntro(settings: s, showKey: "1", episodesThisSession: 0))
        #expect(BingePlanner.shouldAutoSkipIntro(settings: s, showKey: "1", episodesThisSession: 1))
        s.showIntroRules["1"] = .never
        #expect(!BingePlanner.shouldAutoSkipIntro(settings: s, showKey: "1", episodesThisSession: 3))
        s.showIntroRules["2"] = .always
        #expect(BingePlanner.shouldAutoSkipIntro(settings: s, showKey: "2", episodesThisSession: 0))
    }

    @Test func stillWatching() {
        var s = BingeSettings()
        s.stillWatchingAfterEpisodes = 3
        s.stillWatchingAfterHours = nil
        let start = Date()
        #expect(!BingePlanner.shouldAskStillWatching(settings: s, autoplayedInARow: 2, sessionStart: start, now: start))
        #expect(BingePlanner.shouldAskStillWatching(settings: s, autoplayedInARow: 3, sessionStart: start, now: start))
        s.stillWatchingAfterEpisodes = nil
        s.stillWatchingAfterHours = 2
        #expect(BingePlanner.shouldAskStillWatching(settings: s, autoplayedInARow: 9, sessionStart: start, now: start + 7300))
    }

    @Test func nextEpisodeCrossesSeasons() throws {
        let data = try DecodingTests.fixture("season-episodes")
        let episodes = try JSONDecoder().decode(MediaContainerEnvelope<MetadataContainer>.self, from: data).container.metadata
        let first = try #require(episodes.first)
        let next = BingePlanner.nextEpisode(after: first, in: episodes)
        #expect(next?.index == (first.index ?? 0) + 1)
        #expect(BingePlanner.nextEpisode(after: try #require(episodes.last), in: episodes) == nil)
    }

    @Test func previousEpisodeMirrorsNext() throws {
        let data = try DecodingTests.fixture("season-episodes")
        let episodes = try JSONDecoder().decode(MediaContainerEnvelope<MetadataContainer>.self, from: data).container.metadata
        let first = try #require(episodes.first)
        #expect(BingePlanner.previousEpisode(before: first, in: episodes) == nil)
        let second = try #require(BingePlanner.nextEpisode(after: first, in: episodes))
        #expect(BingePlanner.previousEpisode(before: second, in: episodes)?.ratingKey == first.ratingKey)
    }
}
