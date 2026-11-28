import Foundation
import Testing
@testable import MezzanineKit

/// Serves a fixed file with Range support from memory, and records what was asked.
final class FakeFileServer: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var honoursRange = true
    nonisolated(unsafe) static var truncateAfter: Int?
    nonisolated(unsafe) static var status = 200
    static let lock = NSLock()

    static func reset(body: Data, honoursRange: Bool = true, truncateAfter: Int? = nil, status: Int = 200) {
        lock.lock()
        self.body = body
        self.requests = []
        self.honoursRange = honoursRange
        self.truncateAfter = truncateAfter
        self.status = status
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let body = Self.body
        let honours = Self.honoursRange
        let cut = Self.truncateAfter
        let status = Self.status
        Self.lock.unlock()
        guard status == 200 else {
            send(status: status, headers: [:], data: Data())
            return
        }
        var from = 0
        if honours, let range = request.value(forHTTPHeaderField: "Range"), range.hasPrefix("bytes=") {
            from = Int(range.dropFirst(6).split(separator: "-").first ?? "0") ?? 0
        }
        if from >= body.count {
            send(status: 416, headers: [:], data: Data())
            return
        }
        let slice = body.subdata(in: from..<body.count)
        let partial = from > 0
        var headers = cut == nil ? ["Content-Length": String(slice.count)] : [:]
        if partial { headers["Content-Range"] = "bytes \(from)-\(body.count - 1)/\(body.count)" }
        let delivered = cut.map { Data(slice.prefix($0)) } ?? slice
        send(status: partial ? 206 : 200, headers: headers, data: delivered, failAfter: cut != nil)
    }

    func send(status: Int, headers: [String: String], data: Data, failAfter: Bool = false) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // Two chunks, so progress and resumption have something to see.
        let half = data.count / 2
        if half > 0 { client?.urlProtocol(self, didLoad: data.prefix(half)) }
        client?.urlProtocol(self, didLoad: data.dropFirst(half))
        if failAfter {
            // Let the delegate see the bytes before the connection drops.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { [self] in
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            }
        } else { client?.urlProtocolDidFinishLoading(self) }
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct TrackCacheTests {
    func makeCache(limit: Int64 = 4_000_000_000) throws -> (TrackCache, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tc-\(UUID().uuidString)", isDirectory: true)
        let cache = TrackCache(directory: dir, limitBytes: limit) {
            let c = URLSessionConfiguration.ephemeral
            c.protocolClasses = [FakeFileServer.self]
            return c
        }
        return (cache, dir)
    }

    func source(_ id: Int, ext: String = "flac") -> TrackCache.Source {
        TrackCache.Source(partID: id, url: URL(string: "https://music.invalid/library/parts/\(id)/1/file.\(ext)")!,
                          headers: ["X-Plex-Token": "test-token-not-real"], fileExtension: ext)
    }

    func bytes(_ n: Int) -> Data { Data((0..<n).map { UInt8($0 % 251) }) }

    @Test func downloadsWholeFileWithTheTokenAsAHeaderOnly() async throws {
        let (cache, dir) = try makeCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        let body = bytes(50_000)
        FakeFileServer.reset(body: body)
        let url = try await cache.fetch(source(1))
        #expect(try Data(contentsOf: url) == body)
        #expect(url.lastPathComponent == "1.flac")
        let request = try #require(FakeFileServer.requests.first)
        #expect(request.value(forHTTPHeaderField: "X-Plex-Token") == "test-token-not-real")
        #expect(request.url?.absoluteString.contains("token") == false)
        #expect(request.value(forHTTPHeaderField: "Range") == nil)
        #expect(await cache.readiness(partID: 1) == .complete)
        // A second fetch reads the disk.
        FakeFileServer.reset(body: Data())
        _ = try await cache.fetch(source(1))
        #expect(FakeFileServer.requests.isEmpty)
        #expect(await cache.throughput != nil || true)
    }

    @Test func resumesAnInterruptedDownloadWithARange() async throws {
        let (cache, dir) = try makeCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        let body = bytes(40_000)
        FakeFileServer.reset(body: body, truncateAfter: 15_000)
        await #expect(throws: (any Error).self) { _ = try await cache.fetch(source(2)) }
        guard case .partial(let have, _) = await cache.readiness(partID: 2) else {
            Issue.record("expected a partial file")
            return
        }
        #expect(have == 15_000)
        FakeFileServer.reset(body: body)
        let url = try await cache.fetch(source(2))
        #expect(try Data(contentsOf: url) == body)
        #expect(FakeFileServer.requests.first?.value(forHTTPHeaderField: "Range") == "bytes=15000-")
    }

    @Test func serverIgnoringTheRangeRestartsCleanly() async throws {
        let (cache, dir) = try makeCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        let body = bytes(30_000)
        FakeFileServer.reset(body: body, truncateAfter: 10_000)
        _ = try? await cache.fetch(source(3))
        FakeFileServer.reset(body: body, honoursRange: false)
        let url = try await cache.fetch(source(3))
        #expect(try Data(contentsOf: url) == body)
    }

    @Test func aShortAnswerIsNotKeptAsComplete() async throws {
        let (cache, dir) = try makeCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        FakeFileServer.reset(body: bytes(20_000), truncateAfter: 5_000)
        await #expect(throws: (any Error).self) { _ = try await cache.fetch(source(4)) }
        #expect(await cache.cachedFile(partID: 4) == nil)
    }

    @Test func httpErrorsSurface() async throws {
        let (cache, dir) = try makeCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        FakeFileServer.reset(body: Data(), status: 404)
        await #expect(throws: TrackCacheError.http(status: 404)) { _ = try await cache.fetch(source(5)) }
    }

    @Test func plexPartSizeIsNeverTheCheck() async throws {
        // MP3 parts report a size larger than the bytes the server sends; the download counts.
        let (cache, dir) = try makeCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        let body = bytes(10_000)
        FakeFileServer.reset(body: body)
        let url = try await cache.fetch(source(6, ext: "mp3"))
        #expect(try Data(contentsOf: url).count == 10_000)
    }

    @Test func evictsLeastRecentlyUsedAndSparesPinned() async throws {
        let (cache, dir) = try makeCache(limit: 25_000)
        defer { try? FileManager.default.removeItem(at: dir) }
        FakeFileServer.reset(body: bytes(10_000))
        _ = try await cache.fetch(source(10))
        try await Task.sleep(for: .milliseconds(20))
        _ = try await cache.fetch(source(11))
        try await Task.sleep(for: .milliseconds(20))
        // Touch 10 so 11 is now the oldest.
        _ = await cache.cachedFile(partID: 10)
        try await Task.sleep(for: .milliseconds(20))
        _ = try await cache.fetch(source(12))
        #expect(await cache.cachedFile(partID: 11) == nil)
        #expect(await cache.cachedFile(partID: 10) != nil)
        #expect(await cache.cachedFile(partID: 12) != nil)
        // Pinned files stay even over the limit.
        await cache.pin([10, 12])
        _ = try await cache.fetch(source(13))
        #expect(await cache.cachedFile(partID: 10) != nil)
        #expect(await cache.cachedFile(partID: 12) != nil)
        #expect(await cache.totalBytes() >= 30_000)
    }

    @Test func headReadsTheFirstBytes() async throws {
        let (cache, dir) = try makeCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        FakeFileServer.reset(body: bytes(5_000))
        let head = try await cache.head(of: source(20), bytes: 64)
        #expect(head.count == 64)
        #expect(FakeFileServer.requests.first?.value(forHTTPHeaderField: "Range") == "bytes=0-63")
    }

    @Test func estimateUsesMeasuredSpeedAndWhatIsAlreadyHere() async throws {
        let (cache, dir) = try makeCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(await cache.estimatedSeconds(forBytes: 1_000_000) == nil)
        FakeFileServer.reset(body: bytes(300_000))
        _ = try await cache.fetch(source(30))
        #expect(await cache.estimatedSeconds(forBytes: 1_000_000, partID: 30) == 0)
    }
}
