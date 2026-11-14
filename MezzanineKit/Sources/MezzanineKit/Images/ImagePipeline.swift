import Foundation
import CoreGraphics

/// Memory → disk derivative → network, for every remote image in the app.
///
/// - Requests round up to a size bucket, so a 300-px and a 320-px card share
///   one decoded image.
/// - Concurrent requests for the same image share one fetch; when every
///   waiter is cancelled (cards scrolled away) the fetch is cancelled too.
/// - Downloads pass a newest-first gate, so visible cards load before the
///   ones the user scrolled past.
/// - Requests to the current server carry `X-Plex-Token` as a header; tokens
///   never appear in URLs or cache keys.
/// - Cache keys drop scheme and host for the current server, so switching
///   between the LAN and the remote address keeps every cached poster.
public actor ImagePipeline {
    private let session: URLSession
    private let disk: DerivativeDiskCache?
    private let gate: PriorityGate
    private var apiKey: String?
    /// The only host the token is sent to. Other hosts (plex.tv avatars) are
    /// fetched without it.
    private var keyHost: String?
    /// Stable id for the current server (its machine identifier), used in
    /// place of scheme + host in cache keys.
    private nonisolated(unsafe) var namespace: String = ""
    private nonisolated(unsafe) var namespaceHost: String = ""
    private var inFlight: [String: Entry] = [:]

    private struct Entry {
        let task: Task<CGImage, Error>
        var waiters: Int
    }

    /// Decoded images. NSCache is thread-safe; it's read synchronously from
    /// the main actor for instant display of already-loaded images.
    private nonisolated(unsafe) let memory: NSCache<NSString, ImageBox> = {
        let cache = NSCache<NSString, ImageBox>()
        cache.totalCostLimit = 320 * 1_048_576
        return cache
    }()

    public init(session: URLSession = Transport.makeImageSession(), disk: DerivativeDiskCache?, concurrentDownloads: Int = 8) {
        self.session = session
        self.disk = disk
        self.gate = PriorityGate(limit: concurrentDownloads)
    }

    /// The token goes only to `host` (the server's current address), never to another site.
    public func setToken(_ token: String?, host: String?, serverID: String) {
        apiKey = token
        keyHost = host?.lowercased()
        namespace = serverID
        namespaceHost = host?.lowercased() ?? ""
    }

    // MARK: Lookup

    /// Memory-only; never waits.
    public nonisolated func cachedImage(for url: URL, pixelSize: Int) -> CGImage? {
        memory.object(forKey: cacheKey(url, Downsampler.bucket(for: pixelSize)) as NSString)?.image
    }

    public func image(for url: URL, pixelSize: Int) async throws -> CGImage {
        let bucket = Downsampler.bucket(for: pixelSize)
        let key = cacheKey(url, bucket)
        if let hit = memory.object(forKey: key as NSString) { return hit.image }

        let task: Task<CGImage, Error>
        if var entry = inFlight[key] {
            entry.waiters += 1
            inFlight[key] = entry
            task = entry.task
        } else {
            let session = session, disk = disk, gate = gate, apiKey = (url.host()?.lowercased() == keyHost) ? apiKey : nil
            task = Task.detached(priority: Task.currentPriority) {
                try await Self.load(url: url, bucket: bucket, key: key, session: session, disk: disk,
                                    gate: gate, apiKey: apiKey)
            }
            inFlight[key] = Entry(task: task, waiters: 1)
        }

        do {
            let image = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                Task { await self.waiterCancelled(key) }
            }
            finish(key, image: image)
            return image
        } catch {
            finish(key, image: nil)
            throw error
        }
    }

    /// Drops everything in memory (Settings ▸ Clear Cache, memory pressure).
    public nonisolated func purgeMemory() {
        memory.removeAllObjects()
    }

    // MARK: Bookkeeping

    private func waiterCancelled(_ key: String) {
        guard var entry = inFlight[key] else { return }
        entry.waiters -= 1
        if entry.waiters <= 0 {
            entry.task.cancel()
            inFlight[key] = nil
        } else {
            inFlight[key] = entry
        }
    }

    private func finish(_ key: String, image: CGImage?) {
        if let image {
            memory.setObject(ImageBox(image), forKey: key as NSString, cost: image.bytesPerRow * image.height)
        }
        inFlight[key] = nil
    }

    nonisolated func cacheKey(_ url: URL, _ bucket: Int) -> String {
        Self.key(url, bucket, namespace: namespace, namespaceHost: namespaceHost)
    }

    static func key(_ url: URL, _ bucket: Int, namespace: String, namespaceHost: String) -> String {
        let base: String
        if let host = url.host()?.lowercased(), host == namespaceHost, !namespace.isEmpty {
            var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
            c?.scheme = nil; c?.host = nil; c?.port = nil
            base = namespace + (c?.string ?? url.path())
        } else {
            base = url.absoluteString
        }
        return "\(base)#\(bucket)"
    }

    // MARK: Raw bytes

    /// Undecoded files (animated GIFs), most recent first, ~64 MB.
    private nonisolated(unsafe) let rawMemory: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.totalCostLimit = 64 * 1_048_576
        return cache
    }()

    /// The file itself, for what has to be decoded frame by frame. Same
    /// header and download gate as images; kept in memory only.
    public func data(for url: URL) async throws -> Data {
        let key = url.absoluteString as NSString
        if let hit = rawMemory.object(forKey: key) { return hit as Data }
        var request = URLRequest(url: url)
        if let apiKey, !apiKey.isEmpty, url.host()?.lowercased() == keyHost { request.setValue(apiKey, forHTTPHeaderField: "X-Plex-Token") }
        try await gate.acquire()
        let data: Data
        do {
            data = try await Self.fetch(request, session: session)
            await gate.release()
        } catch {
            await gate.release()
            throw error
        }
        rawMemory.setObject(data as NSData, forKey: key, cost: data.count)
        return data
    }

    // MARK: Loading (off the actor)

    private static func load(url: URL, bucket: Int, key: String, session: URLSession,
                             disk: DerivativeDiskCache?, gate: PriorityGate, apiKey: String?) async throws -> CGImage {
        let useDisk = bucket <= Downsampler.maxDiskBucket
        if useDisk, let data = disk?.data(forKey: key), let image = Downsampler.decode(data, maxPixel: bucket) {
            return image
        }

        var request = URLRequest(url: url)
        if let apiKey, !apiKey.isEmpty { request.setValue(apiKey, forHTTPHeaderField: "X-Plex-Token") }

        try await gate.acquire()
        let data: Data
        do {
            data = try await fetch(request, session: session)
            await gate.release()
        } catch {
            await gate.release()
            throw error
        }
        try Task.checkCancellation()

        guard let image = Downsampler.decode(data, maxPixel: bucket) else {
            throw ImageError.undecodable
        }
        if useDisk, let encoded = Downsampler.encode(image) {
            disk?.store(encoded, forKey: key)
        }
        return image
    }

    /// One retry on a dropped connection; none on 4xx (missing art 404s, and that's an answer).
    private static func fetch(_ request: URLRequest, session: URLSession) async throws -> Data {
        var attempt = 0
        while true {
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw ImageError.badResponse(0) }
                guard (200..<300).contains(http.statusCode) else { throw ImageError.badResponse(http.statusCode) }
                return data
            } catch let error as URLError where error.code == .networkConnectionLost && attempt == 0 {
                attempt += 1
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            }
        }
    }
}

public enum ImageError: Error, Sendable, Equatable {
    case badResponse(Int)
    case undecodable
}

/// NSCache needs a class.
final class ImageBox: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}
