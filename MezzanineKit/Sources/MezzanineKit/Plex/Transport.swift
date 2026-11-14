import Foundation
import Network

/// Refuses every HTTP redirect, so `X-Plex-Token` is never replayed to
/// whatever host a redirect points at. The 3xx itself reaches the caller.
///
/// Explicitly non-isolated: URLSession calls delegates on its own queue.
public final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}

public enum Transport {
    public static let userAgent = "Mezzanine/0.1 (macOS)"

    /// Session for API calls: JSON, no cache, no redirects, short timeout.
    public static func makeAPISession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 20
        config.httpAdditionalHeaders = ["User-Agent": userAgent, "Accept": "application/json"]
        config.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    /// Session for connection probes: fails a dead address within seconds.
    public static func makeProbeSession(timeout: TimeInterval = 4) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = ["User-Agent": userAgent, "Accept": "application/json"]
        return URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    /// Session for artwork: Mezzanine keeps its own disk cache.
    public static func makeImageSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15
        config.httpAdditionalHeaders = ["User-Agent": userAgent]
        config.httpMaximumConnectionsPerHost = 10
        return URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }
}

/// Whether the Mac has a usable network right now, kept current by one
/// `NWPathMonitor`. Tells "offline" from "macOS blocked the local network"
/// (both reach URLSession as -1009) and lets discovery re-race on a change.
public final class NetworkPath: @unchecked Sendable {
    public static let shared = NetworkPath()

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var satisfied = true
    private var generation = 0
    private var handlers: [UUID: @Sendable (Bool) -> Void] = [:]

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let ok = path.status == .satisfied
            let toCall = self.lock.withLock { () -> [@Sendable (Bool) -> Void] in
                self.satisfied = ok
                self.generation += 1
                return Array(self.handlers.values)
            }
            toCall.forEach { $0(ok) }
        }
        monitor.start(queue: DispatchQueue(label: "mezzanine.network-path"))
    }

    public var isSatisfied: Bool { lock.withLock { satisfied } }

    /// Increments on every path change (Wi-Fi switch, VPN up/down).
    public var changeGeneration: Int { lock.withLock { generation } }

    @discardableResult
    public func onChange(_ handler: @escaping @Sendable (Bool) -> Void) -> UUID {
        let id = UUID()
        lock.withLock { handlers[id] = handler }
        return id
    }

    public func removeHandler(_ id: UUID) {
        _ = lock.withLock { handlers.removeValue(forKey: id) }
    }
}
