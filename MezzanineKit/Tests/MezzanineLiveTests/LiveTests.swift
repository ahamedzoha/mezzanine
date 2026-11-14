import Foundation
import Testing
import MezzanineKit

/// Read-only checks against the owner's real server. Skipped unless
/// MEZZANINE_LIVE=1 (Scripts/live-test.sh loads the token from
/// .mezzanine-live.env). Never writes: no timeline, scrobble or rating calls.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MEZZANINE_LIVE"] == "1"))
struct LiveTests {
    var env: [String: String] { ProcessInfo.processInfo.environment }

    func identity() -> PlexIdentity {
        PlexIdentity(clientIdentifier: env["PLEX_CLIENT_ID"] ?? "mezzanine-live-tests", product: "Mezzanine (dev)")
    }

    @Test func discoverAndRaceOwnedServer() async throws {
        let token = try #require(env["PLEX_TOKEN"])
        let tv = PlexTV(identity: identity())
        let servers = try await tv.resources(token: token)
        let owned = try #require(servers.first { $0.owned })
        let raceStart = ContinuousClock.now
        let won = await ConnectionRacer().race(owned.candidates,
            probe: ConnectionRacer.identityProbe(expectedMachineIdentifier: owned.clientIdentifier))
        let resolved = try #require(won)
        print("raced \(owned.name): \(resolved.connection.route) \(resolved.connection.protocolName) in \(resolved.latency); race returned after \(ContinuousClock.now - raceStart)")

        let client = PlexServerClient(baseURL: resolved.baseURL, token: owned.accessToken ?? token,
                                      machineIdentifier: owned.clientIdentifier, identity: identity())
        let sections = try await client.sections()
        #expect(sections.contains { $0.kind == .movie })
        let movies = try #require(sections.first { $0.kind == .movie && !$0.isPersonalMedia })
        let page = try await client.items(section: movies.key, sort: .addedNewest, limit: 5)
        #expect(page.items.count == 5)
        #expect((page.totalSize ?? 0) >= 5)
        let detail = try await client.metadata(page.items[0].ratingKey)
        #expect(!detail.media.isEmpty)
        let hubs = try await client.homeHubs()
        #expect(!hubs.isEmpty)
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["MEZZANINE_LIVE"] == "1"))
struct LiveSyncTests {
    @Test func fullSyncEverySection() async throws {
        let env = ProcessInfo.processInfo.environment
        let token = try #require(env["PLEX_TOKEN"])
        let identity = PlexIdentity(clientIdentifier: env["PLEX_CLIENT_ID"] ?? "mezzanine-live-tests", product: "Mezzanine (dev)")
        let servers = try await PlexTV(identity: identity).resources(token: token)
        let owned = try #require(servers.first { $0.owned })
        let won = try #require(await ConnectionRacer().race(owned.candidates,
            probe: ConnectionRacer.identityProbe(expectedMachineIdentifier: owned.clientIdentifier)))
        let client = PlexServerClient(baseURL: won.baseURL, token: owned.accessToken ?? token,
                                      machineIdentifier: owned.clientIdentifier, identity: identity)
        let index = try LibraryIndex()
        let sync = LibrarySync(client: client, index: index)
        let clock = ContinuousClock()
        for section in try await client.sections() where !LibrarySync.types(for: section).isEmpty {
            let start = clock.now
            try await sync.sync(section)
            let full = clock.now - start
            let start2 = clock.now
            try await sync.sync(section)
            print("sync \(section.title): \(try index.count(section: section.key)) items, full \(full), incremental \(clock.now - start2)")
        }
        let q0 = clock.now
        let hits = try index.search("breaking")
        print("search 'breaking': \(hits.count) hits in \(clock.now - q0)")
        #expect(!hits.isEmpty)
    }
}

/// Gestdown (Addic7ed) needs no key: a real search and download for a well-known episode.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MEZZANINE_LIVE"] == "1"))
struct GestdownLiveTests {
    @Test func findsAndDownloadsAnEpisode() async throws {
        let query = SubtitleQuery(kind: .episode, title: "Good News About Hell", showTitle: "Severance",
                                  season: 1, episode: 1, languages: ["en"])
        let source = GestdownSource()
        let results = try await source.search(query)
        #expect(!results.isEmpty)
        let first = try #require(results.first)
        let file = try await source.download(first, for: query)
        #expect(String(decoding: file.data, as: UTF8.self).contains("-->"))
    }
}
