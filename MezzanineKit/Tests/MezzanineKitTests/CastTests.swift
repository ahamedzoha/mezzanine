import Testing
import Foundation
@testable import MezzanineKit

@Suite("Cast protocol")
struct CastTests {
    @Test func roundTripsThroughFraming() throws {
        let m = CastMessage(source: "sender-0", destination: "receiver-0", namespace: CastNamespace.receiver,
                            payload: #"{"type":"LAUNCH","appId":"CC1AD845","requestId":1}"#)
        var buffer = m.encoded() + m.encoded()
        // Arrives in two chunks, split mid-frame.
        var first = Data(buffer.prefix(10))
        #expect(CastMessage.frames(from: &first).isEmpty)
        let frames = CastMessage.frames(from: &buffer)
        #expect(frames == [m, m])
        #expect(buffer.isEmpty)
        #expect(frames.first?.json?["appId"] as? String == "CC1AD845")
    }

    @Test func knownBytes() {
        // protocol_version 0, source "a", destination "b", namespace "c", payload_type 0, payload "{}"
        let body = Data([0x08, 0x00, 0x12, 0x01, 0x61, 0x1A, 0x01, 0x62, 0x22, 0x01, 0x63, 0x28, 0x00, 0x32, 0x02, 0x7B, 0x7D])
        #expect(CastMessage(source: "a", destination: "b", namespace: "c", payload: "{}").encoded() == Data([0, 0, 0, 17]) + body)
        #expect(CastMessage.decode(body) == CastMessage(source: "a", destination: "b", namespace: "c", payload: "{}"))
    }

    @Test func longPayloadUsesMultiByteLength() {
        let payload = String(repeating: "x", count: 300)
        var buffer = CastMessage(source: "s", destination: "d", namespace: "n", payload: payload).encoded()
        #expect(CastMessage.frames(from: &buffer).first?.payload.count == 300)
    }
}
