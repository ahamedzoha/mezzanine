import Foundation
import Testing
@testable import MezzanineKit

@Suite struct ConnectionRacerTests {
    let lanHTTPS = PlexConnection(protocolName: "https", address: "192.168.1.20", port: 32400,
                                  uri: "https://192-168-1-20.abc.plex.direct:32400", local: true, relay: false)
    let lanHTTP = PlexConnection(protocolName: "http", address: "192.168.1.20", port: 32400,
                                 uri: "http://192.168.1.20:32400", local: true, relay: false)
    let remote = PlexConnection(protocolName: "https", address: "plex.example.com", port: 443,
                                uri: "https://plex.example.com:443", local: false, relay: false)
    let relay = PlexConnection(protocolName: "https", address: "1.2.3.4", port: 8443,
                               uri: "https://1-2-3-4.relay.plex.direct:8443", local: false, relay: true)

    /// A probe where each address answers after `delays[uri]` (nil = never).
    func probe(_ delays: [String: Duration?]) -> ConnectionProbe {
        { conn in
            guard let delay = delays[conn.uri] ?? nil else {
                try? await Task.sleep(for: .seconds(30))
                return false
            }
            try? await Task.sleep(for: delay)
            return !Task.isCancelled
        }
    }

    @Test func lanWinsEvenWhenRemoteIsFaster() async {
        let racer = ConnectionRacer(localGrace: .milliseconds(300), timeout: .seconds(2))
        let won = await racer.race([lanHTTPS, remote], probe: probe([
            lanHTTPS.uri: .milliseconds(150),
            remote.uri: .milliseconds(20),
        ]))
        #expect(won?.connection == lanHTTPS)
    }

    @Test func remoteWinsWhenLanNeverAnswers() async {
        let racer = ConnectionRacer(localGrace: .milliseconds(100), timeout: .milliseconds(500))
        let won = await racer.race([lanHTTPS, remote, relay], probe: probe([
            lanHTTPS.uri: nil,
            remote.uri: .milliseconds(30),
            relay.uri: .milliseconds(10),
        ]))
        #expect(won?.connection == remote)
    }

    @Test func plainHTTPFallbackWhenPlexDirectFails() async {
        let racer = ConnectionRacer(localGrace: .milliseconds(100), timeout: .milliseconds(400))
        let won = await racer.race([lanHTTPS, lanHTTP, remote], probe: probe([
            lanHTTPS.uri: nil,
            lanHTTP.uri: .milliseconds(20),
            remote.uri: .milliseconds(10),
        ]))
        #expect(won?.connection == lanHTTP)
    }

    @Test func relayOnlyAsLastResort() async {
        let racer = ConnectionRacer(localGrace: .milliseconds(100), timeout: .milliseconds(300))
        let won = await racer.race([lanHTTPS, remote, relay], probe: probe([
            lanHTTPS.uri: nil, remote.uri: nil, relay.uri: .milliseconds(10),
        ]))
        #expect(won?.connection == relay)
    }

    @Test func nothingAnswers() async {
        let racer = ConnectionRacer(localGrace: .milliseconds(50), timeout: .milliseconds(200))
        let won = await racer.race([lanHTTPS, remote], probe: probe([:]))
        #expect(won == nil)
    }
}

@Suite struct PlexURLsTests {
    let urls = PlexURLs(baseURL: URL(string: "https://plex.example.com:443")!, token: "SECRET")

    @Test func partURLHasNoToken() throws {
        let url = try #require(urls.part(key: "/library/parts/42/1700000000/file.mkv"))
        #expect(url.absoluteString == "https://plex.example.com:443/library/parts/42/1700000000/file.mkv")
        #expect(!url.absoluteString.contains("SECRET"))
    }

    @Test func photoTranscodeKeepsColonAndEncodesPath() throws {
        let url = try #require(urls.photo("/library/metadata/1/thumb/99", width: 300, height: 450))
        let s = url.absoluteString
        #expect(s.contains("/photo/:/transcode?"))
        #expect(s.contains("width=300"))
        #expect(s.contains("url=/library/metadata/1/thumb/99") || s.contains("url=%2Flibrary%2Fmetadata%2F1%2Fthumb%2F99"))
    }

    @Test func redactionHidesToken() {
        let tokenized = urls.tokenized(URL(string: "https://plex.example.com/library/parts/1/2/file.mkv?a=b")!)
        #expect(tokenized.absoluteString.contains("SECRET"))
        let safe = PlexURLs.redacted(tokenized)
        #expect(!safe.contains("SECRET"))
        #expect(safe.contains("a=b"))
    }
}

@Suite struct ServerClientRequestTests {
    private func timelineQuery(type: String?) async -> (query: [String: String], session: String?) {
        let client = PlexServerClient(baseURL: URL(string: "http://127.0.0.1:32400")!, token: "T",
                                      machineIdentifier: "m", identity: PlexIdentity(clientIdentifier: "c"))
        let request = await client.timelineRequest(ratingKey: "900", state: .playing, time: 70.5,
                                                   duration: 188.373, sessionID: "sess", type: type)
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
        return (Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") }),
                request.value(forHTTPHeaderField: "X-Plex-Session-Identifier"))
    }

    @Test func videoTimelineShapeIsUnchanged() async {
        let (q, session) = await timelineQuery(type: nil)
        #expect(q == ["ratingKey": "900", "key": "/library/metadata/900", "state": "playing",
                      "time": "70500", "duration": "188373", "hasMDE": "1"])
        #expect(session == "sess")
    }

    @Test func musicTimelineAddsTypeAndPlaybackTime() async {
        let (q, session) = await timelineQuery(type: "track")
        #expect(q["type"] == "track")
        #expect(q["playbackTime"] == "70500")
        #expect(q["time"] == "70500")
        #expect(q["key"] == "/library/metadata/900")
        #expect(q["playQueueItemID"] == nil && q["containerKey"] == nil)
        #expect(session == "sess")
    }

    @Test func timelinePathKeepsColon() async {
        let client = PlexServerClient(baseURL: URL(string: "http://127.0.0.1:32400")!, token: "T",
                                      machineIdentifier: "m", identity: PlexIdentity(clientIdentifier: "c"))
        let request = await client.makeRequest("POST", "/:/timeline", query: [
            URLQueryItem(name: "ratingKey", value: "1"),
            URLQueryItem(name: "updatedAt>", value: "5"),
        ])
        let s = request.url!.absoluteString
        #expect(s.hasPrefix("http://127.0.0.1:32400/:/timeline?"))
        #expect(s.contains("updatedAt%3E=5") || s.contains("updatedAt>=5"))
        #expect(request.value(forHTTPHeaderField: "X-Plex-Token") == "T")
        #expect(request.value(forHTTPHeaderField: "X-Plex-Client-Identifier") == "c")
    }
}
