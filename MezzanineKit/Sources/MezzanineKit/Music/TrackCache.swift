import Foundation

public enum TrackCacheError: Error, Sendable, Equatable {
    case http(status: Int)
    /// The connection ended before the server's own Content-Length arrived; the part file is
    /// kept and the next fetch resumes it.
    case incomplete(received: Int64, expected: Int64)
    case cancelled
}

/// Music files on disk, fetched whole and kept for the next play.
///
/// `MusicEngine` reads complete local files (gapless joins and exact seeks need the whole
/// file), so every track goes through here first: a ranged download with the Plex token as a
/// header, written to `<partID>.part` and renamed to `<partID>.<ext>` when it is whole.
/// A part file left by an interrupted download is resumed with a `Range` request. Completed
/// files are kept up to `limitBytes` (4 GB), the least recently used going first; tracks the
/// player still needs are pinned.
///
/// Integrity: the server's own `Content-Length` (or `Content-Range` total) is the only check.
/// Plex's `Part.size` is NOT used: for MP3 it is larger than the bytes served (the server
/// strips embedded art).
public actor TrackCache {
    public struct Source: Sendable, Hashable {
        public var partID: Int
        public var url: URL
        /// Plex headers including `X-Plex-Token` (never in the URL).
        public var headers: [String: String]
        public var fileExtension: String

        public init(partID: Int, url: URL, headers: [String: String], fileExtension: String) {
            self.partID = partID
            self.url = url
            self.headers = headers
            self.fileExtension = fileExtension.isEmpty ? "audio" : fileExtension.lowercased()
        }
    }

    public enum Readiness: Sendable, Equatable {
        case missing
        /// Bytes on disk of an unfinished download (and its size when the server said).
        case partial(bytes: Int64, total: Int64?)
        case complete
    }

    public struct Progress: Sendable, Equatable {
        public var bytes: Int64
        public var total: Int64?
        public var fraction: Double? { total.map { $0 > 0 ? Double(bytes) / Double($0) : 1 } }
    }

    public let directory: URL
    public let limitBytes: Int64
    private let makeConfiguration: @Sendable () -> URLSessionConfiguration
    private var inflight: [Int: Task<URL, Error>] = [:]
    private var totals: [Int: Int64] = [:]
    private var pinned: Set<Int> = []
    private var rateSamples: [Double] = []

    public static let defaultLimit: Int64 = 4_000_000_000

    /// `Caches/<bundle id>/Music/<server>`.
    public static func defaultDirectory(bundleID: String, serverID: String) throws -> URL {
        let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return caches.appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("Music", isDirectory: true)
            .appendingPathComponent(serverID.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
    }

    public init(directory: URL, limitBytes: Int64 = TrackCache.defaultLimit,
                configuration: @escaping @Sendable () -> URLSessionConfiguration = { .ephemeral }) {
        self.directory = directory
        self.limitBytes = limitBytes
        self.makeConfiguration = configuration
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: Reading state

    private func finalURL(_ source: Source) -> URL { directory.appendingPathComponent("\(source.partID).\(source.fileExtension)") }
    private func partURL(_ partID: Int) -> URL { directory.appendingPathComponent("\(partID).part") }

    private func completeFile(partID: Int) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        guard let name = names.first(where: { $0.hasPrefix("\(partID).") && !$0.hasSuffix(".part") }) else { return nil }
        return directory.appendingPathComponent(name)
    }

    /// The finished file for a part, marking it as just used. Nil while it is missing or partial.
    public func cachedFile(partID: Int) -> URL? {
        guard let url = completeFile(partID: partID) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return url
    }

    public func readiness(partID: Int) -> Readiness {
        if completeFile(partID: partID) != nil { return .complete }
        let size = (try? FileManager.default.attributesOfItem(atPath: partURL(partID).path)[.size] as? Int64) ?? nil
        guard let size else { return .missing }
        return .partial(bytes: size, total: totals[partID])
    }

    /// Bytes of finished files.
    public func totalBytes() -> Int64 { entries().filter { !$0.isPart }.reduce(0) { $0 + $1.size } }

    /// Measured download speed, bytes per second (average of the last fetches); nil before any.
    public var throughput: Double? {
        rateSamples.isEmpty ? nil : rateSamples.reduce(0, +) / Double(rateSamples.count)
    }

    /// Seconds until a file of `bytes` would be here, at the measured speed; nil before any
    /// download. The session compares it with how long it can wait and otherwise starts the
    /// track on the engine deck.
    public func estimatedSeconds(forBytes bytes: Int64, partID: Int? = nil) -> Double? {
        var remaining = bytes
        if let partID {
            switch readiness(partID: partID) {
            case .complete: return 0
            case .partial(let have, _): remaining = max(0, bytes - have)
            case .missing: break
            }
        }
        guard let rate = throughput, rate > 0 else { return nil }
        return Double(remaining) / rate
    }

    /// Keeps these parts from being evicted (the playing track and the next ones).
    public func pin(_ partIDs: Set<Int>) { pinned = partIDs }

    // MARK: Fetching

    /// The whole file, from disk when it is there, else downloaded (resuming a partial one).
    /// Concurrent calls for one part share a single download.
    public func fetch(_ source: Source, progress: (@Sendable (Progress) -> Void)? = nil) async throws -> URL {
        if let url = cachedFile(partID: source.partID) { return url }
        if let task = inflight[source.partID] { return try await task.value }
        let task = Task { try await self.download(source, progress: progress) }
        inflight[source.partID] = task
        defer { inflight[source.partID] = nil }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Starts downloads for tracks coming up, without waiting; failures are left for the
    /// moment the track is really needed.
    public func prefetch(_ sources: [Source]) {
        for source in sources where cachedFile(partID: source.partID) == nil && inflight[source.partID] == nil {
            let task = Task { try await self.download(source, progress: nil) }
            inflight[source.partID] = task
            Task { [weak self] in
                _ = try? await task.value
                await self?.finished(source.partID)
            }
        }
    }

    private func finished(_ partID: Int) { inflight[partID] = nil }

    /// The first bytes of a file by a ranged request, for a start before the download is whole
    /// (format sniffing, or a decoder that only needs the header).
    public func head(of source: Source, bytes: Int) async throws -> Data {
        var request = URLRequest(url: source.url)
        for (k, v) in source.headers { request.setValue(v, forHTTPHeaderField: k) }
        request.setValue("bytes=0-\(max(1, bytes) - 1)", forHTTPHeaderField: "Range")
        let session = URLSession(configuration: makeConfiguration())
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw TrackCacheError.http(status: status) }
        return data.prefix(bytes)
    }

    /// Deletes the oldest finished files until the cache fits `limitBytes`, never a pinned one.
    /// Old unfinished downloads (a week) go too.
    public func trim() {
        let all = entries()
        let weekAgo = Date().addingTimeInterval(-7 * 86_400)
        for e in all where e.isPart && e.modified < weekAgo && inflight[e.partID] == nil {
            try? FileManager.default.removeItem(at: e.url)
        }
        var finished = all.filter { !$0.isPart }.sorted { $0.modified < $1.modified }
        var total = finished.reduce(Int64(0)) { $0 + $1.size }
        while total > limitBytes, let oldest = finished.first(where: { !pinned.contains($0.partID) && inflight[$0.partID] == nil }) {
            try? FileManager.default.removeItem(at: oldest.url)
            total -= oldest.size
            finished.removeAll { $0.url == oldest.url }
        }
    }

    public func removeAll() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        totals = [:]
    }

    // MARK: Download

    private struct Entry {
        var url: URL
        var partID: Int
        var size: Int64
        var modified: Date
        var isPart: Bool
    }

    private func entries() -> [Entry] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        return urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard let id = Int(url.deletingPathExtension().lastPathComponent) else { return nil }
            return Entry(url: url, partID: id, size: Int64(values?.fileSize ?? 0),
                         modified: values?.contentModificationDate ?? .distantPast, isPart: url.pathExtension == "part")
        }
    }

    private func download(_ source: Source, progress: (@Sendable (Progress) -> Void)?) async throws -> URL {
        let part = partURL(source.partID)
        let fm = FileManager.default
        if !fm.fileExists(atPath: part.path) { fm.createFile(atPath: part.path, contents: nil) }
        let existing = (try? fm.attributesOfItem(atPath: part.path)[.size] as? Int64) ?? 0
        let started = ContinuousClock.now
        var result: PartDownload.Result
        do {
            result = try await PartDownload.run(source: source, partURL: part, resumeFrom: existing,
                                                configuration: makeConfiguration(), progress: progress)
            if result.rangeRefused {
                // 416: what is on disk is not a prefix of the file. Start over once.
                result = try await PartDownload.run(source: source, partURL: part, resumeFrom: 0,
                                                    configuration: makeConfiguration(), progress: progress)
            }
        } catch is CancellationError {
            throw CancellationError()
        }
        if let total = result.total { totals[source.partID] = total }
        if let total = result.total, result.bytesOnDisk != total {
            throw TrackCacheError.incomplete(received: result.bytesOnDisk, expected: total)
        }
        let seconds = Double((ContinuousClock.now - started) / .milliseconds(1)) / 1000
        if result.bytesWritten > 100_000, seconds > 0.05 {
            rateSamples.append(Double(result.bytesWritten) / seconds)
            if rateSamples.count > 6 { rateSamples.removeFirst() }
        }
        let final = finalURL(source)
        try? fm.removeItem(at: final)
        try fm.moveItem(at: part, to: final)
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: final.path)
        totals[source.partID] = nil
        trim()
        return final
    }
}

/// One ranged GET written to a part file. A delegate session, so the bytes go to disk as they
/// arrive instead of through `AsyncBytes`' one-byte steps.
private final class PartDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Result {
        var bytesOnDisk: Int64
        var bytesWritten: Int64
        var total: Int64?
        var rangeRefused: Bool
    }

    private let lock = NSLock()
    private let handle: FileHandle
    private let resumeFrom: Int64
    private let progress: (@Sendable (TrackCache.Progress) -> Void)?
    private var continuation: CheckedContinuation<Result, Error>?
    private var base: Int64
    private var written: Int64 = 0
    private var total: Int64?
    private var status = 0
    private var refused = false
    private var failure: Error?

    private init(handle: FileHandle, resumeFrom: Int64, progress: (@Sendable (TrackCache.Progress) -> Void)?) {
        self.handle = handle
        self.resumeFrom = resumeFrom
        self.base = resumeFrom
        self.progress = progress
    }

    static func run(source: TrackCache.Source, partURL: URL, resumeFrom: Int64, configuration: URLSessionConfiguration,
                    progress: (@Sendable (TrackCache.Progress) -> Void)?) async throws -> Result {
        let handle = try FileHandle(forUpdating: partURL)
        if resumeFrom == 0 { try handle.truncate(atOffset: 0) }
        try handle.seekToEnd()
        let delegate = PartDownload(handle: handle, resumeFrom: resumeFrom, progress: progress)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
        var request = URLRequest(url: source.url)
        for (k, v) in source.headers { request.setValue(v, forHTTPHeaderField: k) }
        if resumeFrom > 0 { request.setValue("bytes=\(resumeFrom)-", forHTTPHeaderField: "Range") }
        let task = session.dataTask(with: request)
        defer {
            session.invalidateAndCancel()
            try? handle.close()
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Result, Error>) in
                delegate.lock.lock()
                delegate.continuation = c
                delegate.lock.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        lock.lock()
        status = http?.statusCode ?? 0
        if status == 416 {
            refused = true
        } else if status == 206, let range = http?.value(forHTTPHeaderField: "Content-Range"),
                  let slash = range.lastIndex(of: "/"), let t = Int64(range[range.index(after: slash)...]) {
            total = t
        } else if status == 200 {
            // The server ignored the range: it sends the whole file again.
            if resumeFrom > 0 {
                try? handle.truncate(atOffset: 0)
                try? handle.seek(toOffset: 0)
                base = 0
            }
            if let length = http?.value(forHTTPHeaderField: "Content-Length"), let l = Int64(length) { total = l }
        }
        let ok = status == 200 || status == 206
        if !ok && !refused { failure = TrackCacheError.http(status: status) }
        lock.unlock()
        completionHandler(ok ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        do { try handle.write(contentsOf: data) } catch { failure = error }
        written += Int64(data.count)
        let snapshot = TrackCache.Progress(bytes: base + written, total: total)
        let report = progress
        lock.unlock()
        report?(snapshot)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let c = continuation
        continuation = nil
        let result = Result(bytesOnDisk: base + written, bytesWritten: written, total: total, rangeRefused: refused)
        let failed = failure ?? (refused ? nil : error)
        lock.unlock()
        if let failed {
            if (failed as? URLError)?.code == .cancelled, failure == nil { c?.resume(throwing: CancellationError()) }
            else { c?.resume(throwing: failed) }
        } else {
            c?.resume(returning: result)
        }
    }
}
