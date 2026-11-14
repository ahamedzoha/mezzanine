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
