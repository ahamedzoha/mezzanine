import Foundation

/// One Cast v2 message (the `CastMessage` protobuf every Google Cast device speaks on port
/// 8009, inside TLS, each prefixed with its length as a 4-byte big-endian integer). Only the
/// UTF-8 payload form is used: every namespace Mezzanine needs carries JSON.
public struct CastMessage: Equatable, Sendable {
    public var source: String
    public var destination: String
    public var namespace: String
    public var payload: String

    public init(source: String, destination: String, namespace: String, payload: String) {
        self.source = source
        self.destination = destination
        self.namespace = namespace
        self.payload = payload
    }

    /// The JSON payload as a dictionary (nil when it isn't an object).
    public var json: [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any]
    }

    // MARK: Protobuf (fields 1 protocol_version, 2 source_id, 3 destination_id, 4 namespace,
    // 5 payload_type, 6 payload_utf8)

    public func encoded() -> Data {
        var body = Data()
        Self.varintField(1, 0, into: &body)               // CASTV2_1_0
        Self.stringField(2, source, into: &body)
        Self.stringField(3, destination, into: &body)
        Self.stringField(4, namespace, into: &body)
        Self.varintField(5, 0, into: &body)               // STRING
        Self.stringField(6, payload, into: &body)
        var frame = Data()
        let length = UInt32(body.count).bigEndian
        withUnsafeBytes(of: length) { frame.append(contentsOf: $0) }
        frame.append(body)
        return frame
    }

    /// Decodes one message body (without the length prefix).
    public static func decode(_ body: Data) -> CastMessage? {
        var source = "", destination = "", namespace = "", payload = ""
        var i = body.startIndex
        while i < body.endIndex {
            guard let key = varint(body, &i) else { return nil }
            let field = Int(key >> 3), wire = Int(key & 7)
            switch wire {
            case 0:
                guard varint(body, &i) != nil else { return nil }
            case 2:
                guard let length = varint(body, &i), let end = body.index(i, offsetBy: Int(length), limitedBy: body.endIndex) else { return nil }
                let bytes = body[i..<end]
                i = end
                let text = String(decoding: bytes, as: UTF8.self)
                switch field {
                case 2: source = text
                case 3: destination = text
                case 4: namespace = text
                case 6: payload = text
                default: break
                }
            case 5: i = body.index(i, offsetBy: 4, limitedBy: body.endIndex) ?? body.endIndex
            case 1: i = body.index(i, offsetBy: 8, limitedBy: body.endIndex) ?? body.endIndex
            default: return nil
            }
        }
        return CastMessage(source: source, destination: destination, namespace: namespace, payload: payload)
    }

    /// Splits complete frames off the front of `buffer` (TLS delivers them in arbitrary chunks).
    public static func frames(from buffer: inout Data) -> [CastMessage] {
        var out: [CastMessage] = []
        while buffer.count >= 4 {
            let start = buffer.startIndex
            let length = buffer[start..<start + 4].reduce(0) { ($0 << 8) | Int($1) }
            guard buffer.count >= 4 + length else { break }
            let body = Data(buffer[(start + 4)..<(start + 4 + length)])
            buffer.removeFirst(4 + length)
            if let message = decode(body) { out.append(message) }
        }
        return out
    }

    private static func varintField(_ field: Int, _ value: UInt64, into data: inout Data) {
        writeVarint(UInt64(field << 3), into: &data)
        writeVarint(value, into: &data)
    }

    private static func stringField(_ field: Int, _ value: String, into data: inout Data) {
        writeVarint(UInt64(field << 3 | 2), into: &data)
        let bytes = Data(value.utf8)
        writeVarint(UInt64(bytes.count), into: &data)
        data.append(bytes)
    }

    private static func writeVarint(_ value: UInt64, into data: inout Data) {
        var v = value
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            data.append(byte)
        } while v != 0
    }

    private static func varint(_ data: Data, _ i: inout Data.Index) -> UInt64? {
        var result: UInt64 = 0, shift: UInt64 = 0
        while i < data.endIndex {
            let byte = data[i]
            i = data.index(after: i)
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }
}

/// The Cast namespaces Mezzanine uses.
public enum CastNamespace {
    public static let connection = "urn:x-cast:com.google.cast.tp.connection"
    public static let heartbeat = "urn:x-cast:com.google.cast.tp.heartbeat"
    public static let receiver = "urn:x-cast:com.google.cast.receiver"
    public static let media = "urn:x-cast:com.google.cast.media"
}
