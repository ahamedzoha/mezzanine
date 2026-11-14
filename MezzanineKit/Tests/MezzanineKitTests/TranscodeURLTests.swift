import Foundation
import Testing
@testable import MezzanineKit

struct TranscodeURLTests {
    let urls = PlexURLs(baseURL: URL(string: "https://pms.example:32400")!, token: "secret")

    @Test func remuxAsksForCopyWithGenericProfile() throws {
        let options = TranscodeOptions(directStream: true, session: "S1")
        let url = try #require(urls.transcode(ratingKey: "42", options))
        let s = url.absoluteString
        #expect(s.hasPrefix("https://pms.example:32400/video/:/transcode/universal/start.m3u8?"))
        #expect(s.contains("path=%2Flibrary%2Fmetadata%2F42") || s.contains("path=/library/metadata/42"))
        #expect(s.contains("directStream=1"))
        #expect(s.contains("X-Plex-Client-Profile-Name=Generic"))
        #expect(s.contains("session=S1"))
        #expect(!s.contains("maxVideoBitrate"))
        #expect(!s.contains("secret"))
    }

    @Test func capsSetBitrateAndResolution() throws {
        let options = TranscodeOptions(directStream: false, maxVideoBitrate: 4000, videoResolution: "1280x720", session: "S2")
        let decision = try #require(urls.transcodeDecision(ratingKey: "42", options)).absoluteString
        #expect(decision.contains("/video/:/transcode/universal/decision?"))
        #expect(decision.contains("directStream=0"))
        #expect(decision.contains("maxVideoBitrate=4000"))
        #expect(decision.contains("videoResolution=1280x720"))
    }
}
