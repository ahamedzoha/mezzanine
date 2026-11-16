import Foundation
import Network
import Testing
@testable import MezzanineKit

@Suite struct CompanionTests {
    private func request(_ text: String) -> CompanionHTTPServer.Request? {
        CompanionHTTPServer.parse(Data(text.utf8), peer: .hostPort(host: "192.168.1.50", port: 5000))
    }

    @Test func parsesARequestWithQueryAndHeaders() throws {
        let r = try #require(request("GET /player/playback/seekTo?offset=125000&commandID=7 HTTP/1.1\r\nHost: mac:32500\r\nX-Plex-Client-Identifier: phone-1\r\n\r\n"))
        #expect(r.method == "GET")
        #expect(r.path == "/player/playback/seekTo")
        #expect(r.query["offset"] == "125000")
        #expect(r.header("x-plex-client-identifier") == "phone-1")
        #expect(r.peer == "192.168.1.50")
        #expect(CompanionService.command(for: r) == .seek(to: 125))
    }

    @Test func waitsForTheWholeBody() {
        #expect(request("POST /x HTTP/1.1\r\nContent-Length: 10\r\n\r\n12345") == nil)
        #expect(request("POST /x HTTP/1.1\r\nContent-Length: 5\r\n\r\n12345")?.body == Data("12345".utf8))
        #expect(request("GET /x HTTP/1.1\r\nHost: a") == nil)
    }

    @Test func playMediaCarriesTheServerAndOffset() throws {
        let r = try #require(request("GET /player/playback/playMedia?key=%2Flibrary%2Fmetadata%2F1508&offset=60000&machineIdentifier=srv&address=plex.example.com&port=443&protocol=https&containerKey=%2FplayQueues%2F9 HTTP/1.1\r\n\r\n"))
        guard case .playMedia(let media) = CompanionService.command(for: r) else { Issue.record("not playMedia"); return }
        #expect(media.ratingKey == "1508")
        #expect(media.offset == 60)
        #expect(media.machineIdentifier == "srv")
        #expect(media.scheme == "https")
        #expect(media.port == 443)
        #expect(media.containerKey == "/playQueues/9")
    }

    @Test func mapsTheTransportCommands() throws {
        func cmd(_ path: String) -> CompanionCommand? {
            request("GET \(path) HTTP/1.1\r\n\r\n").flatMap(CompanionService.command(for:))
        }
        #expect(cmd("/player/playback/play") == .play)
        #expect(cmd("/player/playback/pause") == .pause)
        #expect(cmd("/player/playback/stop") == .stop)
        #expect(cmd("/player/playback/skipNext") == .skipNext)
        #expect(cmd("/player/playback/stepBack") == .stepBack)
        #expect(cmd("/player/playback/setParameters?volume=140") == .setVolume(100))
        #expect(cmd("/player/playback/setStreams?subtitleStreamID=0") == .setStreams(audio: nil, subtitle: 0))
        #expect(cmd("/player/navigation/moveUp") == nil)
    }

    @Test func timelineXMLHasWhatControllersRead() {
        let t = CompanionTimeline(state: .paused, ratingKey: "1508", time: 61.5, duration: 6120, volume: 80,
                                  machineIdentifier: "srv", address: "plex.example.com", port: 443, scheme: "https",
                                  audioStreamID: 11, canSkipNext: true, canSkipPrevious: false)
        let xml = t.xml(commandID: 7)
        #expect(xml.contains(#"commandID="7""#))
        #expect(xml.contains(#"state="paused""#))
        #expect(xml.contains(#"time="61500""#))
        #expect(xml.contains(#"key="/library/metadata/1508""#))
        #expect(xml.contains(#"machineIdentifier="srv""#))
        #expect(xml.contains("skipNext"))
        #expect(!xml.contains("skipPrevious"))
        #expect(CompanionTimeline.stopped.xml(commandID: 0).contains(#"location="navigation""#))
    }

    @Test func gdmAdvertNamesThePlayer() {
        let body = CompanionGDM.Advert(name: "Living Room Mac", port: 32500, identifier: "abc", version: "0.3.0").body
        #expect(body.contains("Content-Type: plex/media-player"))
        #expect(body.contains("Resource-Identifier: abc"))
        #expect(body.contains("Port: 32500"))
        #expect(body.components(separatedBy: "\r\n").count == 10)
    }

    @Test func readsTheAccountDeviceList() {
        let xml = #"""
        <MediaContainer>
          <Device name="iPhone" id="11" clientIdentifier="phone" provides="client,player"><Connection uri="http://192.168.1.26:32500"/></Device>
          <Device name="Mac" id="22" clientIdentifier="mezzanine-abc" provides="client,player,pubsub-player"/>
        </MediaContainer>
        """#
        let devices = CompanionRegistration.parseDevices(Data(xml.utf8))
        #expect(devices.count == 2)
        #expect(devices[0].connections == ["http://192.168.1.26:32500"])
        #expect(devices[1].id == "22")
        #expect(devices[1].provides.contains("player"))
    }

    @Test func escapesAttributeValues() {
        #expect(CompanionTimeline.escape(#"Tom & "Jerry" <1>"#) == "Tom &amp; &quot;Jerry&quot; &lt;1&gt;")
    }
}
