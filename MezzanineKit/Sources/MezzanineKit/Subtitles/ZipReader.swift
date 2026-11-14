import Foundation
import Compression

/// Just enough ZIP to open a subtitle archive: stored and deflated entries, no ZIP64, no
/// encryption. Reads the central directory, so sizes are always known.
enum ZipReader {
    enum Failure: Error { case notZip, unsupported }

    static func entries(_ data: Data) throws -> [(name: String, data: Data)] {
        let bytes = [UInt8](data)
        guard let end = endOfCentralDirectory(bytes) else { throw Failure.notZip }
        let count = Int(u16(bytes, end + 10))
        var offset = Int(u32(bytes, end + 16))
        var out: [(String, Data)] = []
        for _ in 0..<count {
            guard offset + 46 <= bytes.count, u32(bytes, offset) == 0x0201_4B50 else { throw Failure.notZip }
            let flags = u16(bytes, offset + 8)
            let method = u16(bytes, offset + 10)
            let compressed = Int(u32(bytes, offset + 20))
            let size = Int(u32(bytes, offset + 24))
            let nameLength = Int(u16(bytes, offset + 28))
            let extraLength = Int(u16(bytes, offset + 30))
            let commentLength = Int(u16(bytes, offset + 32))
            let local = Int(u32(bytes, offset + 42))
            guard offset + 46 + nameLength <= bytes.count else { throw Failure.notZip }
            let name = String(decoding: bytes[(offset + 46)..<(offset + 46 + nameLength)], as: UTF8.self)
            offset += 46 + nameLength + extraLength + commentLength

            guard !name.hasSuffix("/"), flags & 1 == 0, size > 0, size < 50_000_000 else { continue }
            guard local + 30 <= bytes.count, u32(bytes, local) == 0x0403_4B50 else { continue }
            let start = local + 30 + Int(u16(bytes, local + 26)) + Int(u16(bytes, local + 28))
            guard start + compressed <= bytes.count else { continue }
            let body = Data(bytes[start..<(start + compressed)])
            switch method {
            case 0: out.append((name, body))
            case 8: if let inflated = inflate(body, size: size) { out.append((name, inflated)) }
            default: continue
            }
        }
        return out
    }

    private static func endOfCentralDirectory(_ b: [UInt8]) -> Int? {
        guard b.count >= 22 else { return nil }
        var i = b.count - 22
        let floor = max(0, b.count - 22 - 65_535)
        while i >= floor {
            if u32(b, i) == 0x0605_4B50 { return i }
            i -= 1
        }
        return nil
    }

    /// Raw DEFLATE (Apple's `COMPRESSION_ZLIB` is RFC 1951, as ZIP stores it).
    private static func inflate(_ data: Data, size: Int) -> Data? {
        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return output.prefix(written)
    }

    private static func u16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
}
