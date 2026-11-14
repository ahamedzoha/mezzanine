import Foundation
import Testing
@testable import MezzanineKit

/// Decoding against real responses captured from the owner's server
/// (PMS 1.43.5, tokens scrubbed). Plex JSON is loose about types, so these
/// guard the lenient decoders as much as the field mapping.
@Suite struct DecodingTests {
    static func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    static func container<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try JSONDecoder().decode(MediaContainerEnvelope<T>.self, from: fixture(name)).container
    }

    @Test func sections() throws {
        let c = try Self.container(DirectoryContainer<PlexLibrarySection>.self, "sections")
        let byTitle = Dictionary(uniqueKeysWithValues: c.directories.map { ($0.title, $0) })
        #expect(byTitle["Movies"]?.kind == .movie)
        #expect(byTitle["TV Shows"]?.kind == .show)
        #expect(byTitle["Music"]?.kind == .artist)
        #expect(byTitle["Courses"]?.isPersonalMedia == true)
        #expect(byTitle["Movies"]?.isPersonalMedia == false)
    }

    @Test func moviePageHasPagingAndMedia() throws {
        let c = try Self.container(MetadataContainer.self, "movies-page")
        #expect(c.metadata.count == 3)
        #expect((c.totalSize ?? 0) > 3)
        let movie = try #require(c.metadata.first)
        #expect(movie.kind == .movie)
        #expect(!movie.ratingKey.isEmpty)
        #expect(movie.posterPath != nil)
        let media = try #require(movie.media.first)
        #expect(media.videoCodec != nil)
        let part = try #require(media.parts.first)
        #expect(part.key?.hasPrefix("/library/parts/") == true)
    }

    @Test func showPageCountsLeaves() throws {
        let c = try Self.container(MetadataContainer.self, "shows-page")
        let show = try #require(c.metadata.first)
        #expect(show.kind == .show)
        #expect((show.leafCount ?? 0) > 0)
        #expect(show.unwatchedLeafCount != nil)
    }

    @Test func episodeDetailHasCreditsMarkerAndStreams() throws {
        let c = try Self.container(MetadataContainer.self, "episode-detail")
        let ep = try #require(c.metadata.first)
        #expect(ep.kind == .episode)
        #expect(ep.grandparentTitle == "After Life")
        let credits = try #require(ep.credits)
        #expect(credits.kind == .credits)
        #expect(credits.isFinal)
        #expect(credits.end > credits.start)
        let streams = try #require(ep.media.first?.parts.first?.streams)
        let audio = try #require(streams.first { $0.streamType == .audio })
        #expect(audio.codec == "eac3")
        #expect(audio.channels == 6)
        #expect(audio.selected == true)
        #expect(streams.contains { $0.streamType == .subtitle && $0.languageCode == "eng" && $0.selected == true })
        #expect(ep.ultraBlur != nil)
    }

    @Test func movieDetailImagesAndBadges() throws {
        let c = try Self.container(MetadataContainer.self, "movie-detail")
        let movie = try #require(c.metadata.first)
        #expect(movie.clearLogoPath != nil)
        #expect(movie.image(.coverPoster) != nil)
        #expect(movie.backdropPath != nil)
        #expect(movie.ultraBlur?.topLeft.count == 6)
    }

    @Test func homeHubs() throws {
        let c = try Self.container(HubContainer.self, "hubs-home")
        let ids = c.hubs.map(\.hubIdentifier)
        #expect(ids.contains("home.continue"))
        #expect(ids.contains("home.ondeck"))
        let cont = try #require(c.hubs.first { $0.hubIdentifier == "home.continue" })
        #expect(!cont.items.isEmpty)
    }

    @Test func subtitleSearchScoresAsInts() throws {
        let c = try Self.container(StreamContainer.self, "subtitle-search")
        #expect(!c.streams.isEmpty)
        let first = try #require(c.streams.first)
        #expect(first.providerTitle == "OpenSubtitles")
        #expect(first.score != nil)
        #expect(first.key?.hasPrefix("/library/streams/") == true)
        #expect(c.streams.contains { $0.hearingImpaired })
    }

    @Test func resourcesDecodeServersAndConnections() throws {
        let all = try JSONDecoder().decode([PlexServerResource].self, from: Self.fixture("resources"))
        let servers = all.filter(\.isServer)
        #expect(servers.count >= 1)
        let owned = try #require(servers.first { $0.owned })
        #expect(owned.connections.contains { $0.local && $0.uri.contains("plex.direct") })
        #expect(owned.connections.contains { !$0.local && !$0.relay })
        // A plain-http LAN fallback is synthesized after the plex.direct address.
        let candidates = owned.candidates
        #expect(candidates.first?.rank == 0)
        #expect(candidates.contains { $0.protocolName == "http" && $0.local })
    }
}

@Suite struct LenientDecodingTests {
    struct Probe: Decodable {
        let b: Bool?, i: Int?, d: Double?, s: String?
        enum CodingKeys: String, CodingKey { case b, i, d, s }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            b = c.lenientBool(.b); i = c.lenientInt(.i); d = c.lenientDouble(.d); s = c.lenientString(.s)
        }
    }

    func decode(_ json: String) throws -> Probe {
        try JSONDecoder().decode(Probe.self, from: Data(json.utf8))
    }

    @Test func boolsFromAnyShape() throws {
        #expect(try decode(#"{"b": true}"#).b == true)
        #expect(try decode(#"{"b": 0}"#).b == false)
        #expect(try decode(#"{"b": "1"}"#).b == true)
        #expect(try decode(#"{}"#).b == nil)
    }

    @Test func numbersFromStrings() throws {
        #expect(try decode(#"{"i": "22416"}"#).i == 22416)
        #expect(try decode(#"{"i": 12.0}"#).i == 12)
        #expect(try decode(#"{"d": "7.5"}"#).d == 7.5)
        #expect(try decode(#"{"s": 15461}"#).s == "15461")
    }
}
