import Foundation
import Network

/// A Google Cast device on the network (found by Bonjour, `_googlecast._tcp`).
public struct CastDevice: Identifiable, Hashable, Sendable {
    public let id: String
    /// "Family Room" (the name set on the TV).
    public let name: String
    public let model: String?
    public let endpoint: NWEndpoint

    public static func == (a: CastDevice, b: CastDevice) -> Bool { a.id == b.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Watches the network for Cast devices while started.
public final class CastDiscovery: @unchecked Sendable {
    private let browser: NWBrowser
    private let queue = DispatchQueue(label: "mezzanine.cast.discovery")
    public let devices: AsyncStream<[CastDevice]>
    private let continuation: AsyncStream<[CastDevice]>.Continuation

    public init() {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_googlecast._tcp", domain: "local."), using: parameters)
        (devices, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    /// The browser's state, for diagnosing a network that hides devices (Local Network access).
    public var onState: (@Sendable (String) -> Void)?

    public func start() {
        browser.stateUpdateHandler = { [weak self] state in self?.onState?("\(state)") }
        browser.browseResultsChangedHandler = { [continuation] results, _ in
            let found = results.compactMap { result -> CastDevice? in
                guard case .service(let instance, _, _, _) = result.endpoint else { return nil }
                var name = instance, model: String?
                if case .bonjour(let txt) = result.metadata {
                    name = txt["fn"] ?? instance
                    model = txt["md"]
                }
                return CastDevice(id: instance, name: name, model: model, endpoint: result.endpoint)
            }
            continuation.yield(found.sorted { $0.name < $1.name })
        }
        browser.start(queue: queue)
    }

    public func stop() {
        browser.cancel()
        continuation.finish()
    }
}

/// One cast: Mezzanine (the sender) talking to a TV's Default Media Receiver. Connects over
/// TLS to port 8009, keeps the heartbeat, launches the receiver app, loads a stream and
/// drives it. Statuses arrive on `statuses` as the TV reports them.
public actor CastSession {
    public struct Status: Sendable, Equatable {
        /// PLAYING, PAUSED, BUFFERING or IDLE (Cast's own words).
        public var playerState: String
        /// IDLE's reason: FINISHED, CANCELLED, INTERRUPTED, ERROR.
        public var idleReason: String?
        public var currentTime: Double
        public var duration: Double?
        public var volume: Double
        public var muted: Bool
    }

    public enum Failure: Error, Sendable, Equatable {
        case unreachable, launchFailed, loadFailed(String), closed
    }

    /// Google's Default Media Receiver (plays HLS, MP4 and WebM).
    public static let defaultReceiver = "CC1AD845"

    public nonisolated let statuses: AsyncStream<Status>
    private let statusOut: AsyncStream<Status>.Continuation
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "mezzanine.cast.session")
    private var buffer = Data()
    private var nextRequest = 1
    private var waiters: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var transportID: String?
    private var appSessionID: String?
    private var mediaSessionID: Int?
    /// After a new LOAD, reports for older media sessions are stale.
    private var pendingMediaSession: Int?
    private var status = Status(playerState: "IDLE", currentTime: 0, volume: 1, muted: false)
    private var heartbeat: Task<Void, Never>?
    private var closed = false

    public init(device: CastDevice) {
        let tls = NWProtocolTLS.Options()
        // Cast devices present self-signed certificates: the media path doesn't need them verified.
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) }, .global())
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        connection = NWConnection(to: device.endpoint, using: parameters)
        (statuses, statusOut) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(8))
    }

    // MARK: Connecting

    /// Connects, launches the receiver and joins it.
    public func start() async throws {
        try await connect()
        receive()
        send(CastNamespace.connection, to: "receiver-0", ["type": "CONNECT"])
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                await self?.send(CastNamespace.heartbeat, to: "receiver-0", ["type": "PING"])
                // The TV only reports on changes: ask for its position now and then.
                await self?.requestMediaStatus()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        let status = try await request(CastNamespace.receiver, to: "receiver-0", ["type": "LAUNCH", "appId": Self.defaultReceiver])
        guard let apps = (status["status"] as? [String: Any])?["applications"] as? [[String: Any]],
              let app = apps.first(where: { $0["appId"] as? String == Self.defaultReceiver }),
              let transport = app["transportId"] as? String else { throw Failure.launchFailed }
        transportID = transport
        appSessionID = app["sessionId"] as? String
        send(CastNamespace.connection, to: transport, ["type": "CONNECT"])
    }

    private func connect() async throws {
        let box = ResumeOnce()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: box.resume { continuation.resume() }
                case .failed, .cancelled: box.resume { continuation.resume(throwing: Failure.unreachable) }
                case .waiting:
                    // No route (TV off, wrong network): give up rather than wait forever.
                    box.resume { continuation.resume(throwing: Failure.unreachable) }
                default: break
                }
            }
            connection.start(queue: queue)
            // A TV that's off or gone never answers: give up after ten seconds.
            let connection = self.connection
            Task {
                try? await Task.sleep(for: .seconds(10))
                box.resume {
                    connection.cancel()
                    continuation.resume(throwing: Failure.unreachable)
                }
            }
        }
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { Task { await self?.connectionLost() } }
            if case .cancelled = state { Task { await self?.connectionLost() } }
        }
    }

    // MARK: Media

    /// Loads a stream on the TV, starting at `startTime` seconds.
    public func load(url: URL, contentType: String, title: String, subtitle: String?, image: URL?, startTime: Double) async throws {
        guard let transport = transportID else { throw Failure.closed }
        var metadata: [String: Any] = ["metadataType": 0, "title": title]
        if let subtitle { metadata["subtitle"] = subtitle }
        if let image { metadata["images"] = [["url": image.absoluteString]] }
        let media: [String: Any] = ["contentId": url.absoluteString, "streamType": "BUFFERED",
                                    "contentType": contentType, "metadata": metadata]
        let answer = try await request(CastNamespace.media, to: transport,
                                       ["type": "LOAD", "media": media, "autoplay": true, "currentTime": startTime])
        if let entry = (answer["status"] as? [[String: Any]])?.first, let id = entry["mediaSessionId"] as? Int {
            pendingMediaSession = id
            mediaSessionID = id
        }
        if let type = answer["type"] as? String, type != "MEDIA_STATUS" {
            throw Failure.loadFailed((answer["reason"] as? String) ?? type)
        }
    }

    public func play() { mediaCommand("PLAY") }

    func requestMediaStatus() {
        guard let transport = transportID, mediaSessionID != nil else { return }
        var payload: [String: Any] = ["type": "GET_STATUS", "requestId": takeRequestID()]
        payload["mediaSessionId"] = mediaSessionID
        send(CastNamespace.media, to: transport, payload)
    }
    public func pause() { mediaCommand("PAUSE") }
    public func seek(to seconds: Double) { mediaCommand("SEEK", ["currentTime": max(0, seconds)]) }

    public func setVolume(_ level: Double) {
        send(CastNamespace.receiver, to: "receiver-0", ["type": "SET_VOLUME", "volume": ["level": min(1, max(0, level))], "requestId": takeRequestID()])
    }

    /// Stops the film and closes the receiver app on the TV.
    public func stop() {
        mediaCommand("STOP")
        if let appSessionID {
            send(CastNamespace.receiver, to: "receiver-0", ["type": "STOP", "sessionId": appSessionID, "requestId": takeRequestID()])
        }
        close()
    }

    /// Joins a TV that's already showing the Default Media Receiver (a cast from a session that
    /// ended, say) and closes it. Returns whether there was one.
    public func stopRunningReceiver() async throws -> Bool {
        try await connect()
        receive()
        send(CastNamespace.connection, to: "receiver-0", ["type": "CONNECT"])
        let status = try await request(CastNamespace.receiver, to: "receiver-0", ["type": "GET_STATUS"])
        guard let apps = (status["status"] as? [String: Any])?["applications"] as? [[String: Any]],
              let app = apps.first(where: { $0["appId"] as? String == Self.defaultReceiver }),
              let session = app["sessionId"] as? String else { close(); return false }
        send(CastNamespace.receiver, to: "receiver-0", ["type": "STOP", "sessionId": session, "requestId": takeRequestID()])
        try? await Task.sleep(for: .milliseconds(500))
        close()
        return true
    }

    /// Leaves the TV playing as it is; just disconnects.
    public func close() {
        guard !closed else { return }
        closed = true
        heartbeat?.cancel()
        if let transportID { send(CastNamespace.connection, to: transportID, ["type": "CLOSE"]) }
        connection.cancel()
        statusOut.finish()
        for (_, waiter) in waiters { waiter.resume(throwing: Failure.closed) }
        waiters = [:]
    }

    public var latest: Status { status }

    private func mediaCommand(_ type: String, _ extra: [String: Any] = [:]) {
        guard let transport = transportID, let media = mediaSessionID else { return }
        var payload = extra
        payload["type"] = type
        payload["mediaSessionId"] = media
        payload["requestId"] = takeRequestID()
        send(CastNamespace.media, to: transport, payload)
    }

    // MARK: Messages

    private func takeRequestID() -> Int {
        defer { nextRequest += 1 }
        return nextRequest
    }

    private func request(_ namespace: String, to destination: String, _ body: [String: Any]) async throws -> [String: Any] {
        let id = takeRequestID()
        var payload = body
        payload["requestId"] = id
        return try await withCheckedThrowingContinuation { continuation in
            waiters[id] = continuation
            send(namespace, to: destination, payload)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                await self?.timeOut(id)
            }
        }
    }

    private func timeOut(_ id: Int) {
        waiters.removeValue(forKey: id)?.resume(throwing: Failure.loadFailed("The TV didn't answer"))
    }

    private func send(_ namespace: String, to destination: String, _ body: [String: Any]) {
        guard !closed || body["type"] as? String == "CLOSE",
              let data = try? JSONSerialization.data(withJSONObject: body),
              let text = String(data: data, encoding: .utf8) else { return }
        let message = CastMessage(source: "sender-0", destination: destination, namespace: namespace, payload: text)
        connection.send(content: message.encoded(), completion: .contentProcessed { _ in })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            Task {
                if let data { await self?.received(data) }
                if complete || error != nil { await self?.connectionLost() } else { await self?.receive() }
            }
        }
    }

    private func received(_ data: Data) {
        buffer.append(data)
        for message in CastMessage.frames(from: &buffer) { handle(message) }
    }

    private func handle(_ message: CastMessage) {
        guard let json = message.json else { return }
        let type = json["type"] as? String
        if message.namespace == CastNamespace.heartbeat, type == "PING" {
            send(CastNamespace.heartbeat, to: message.source, ["type": "PONG"])
            return
        }
        if type == "CLOSE", message.source == transportID {
            connectionLost()
            return
        }
        if type == "RECEIVER_STATUS", let volume = (json["status"] as? [String: Any])?["volume"] as? [String: Any] {
            status.volume = volume["level"] as? Double ?? status.volume
            status.muted = volume["muted"] as? Bool ?? status.muted
            statusOut.yield(status)
        }
        if type == "MEDIA_STATUS", let entry = (json["status"] as? [[String: Any]])?.first {
            // A late report about the media session that was just replaced is ignored.
            if let id = entry["mediaSessionId"] as? Int, let current = pendingMediaSession, id < current { return }
            mediaSessionID = entry["mediaSessionId"] as? Int ?? mediaSessionID
            status.playerState = entry["playerState"] as? String ?? status.playerState
            status.idleReason = entry["idleReason"] as? String
            status.currentTime = entry["currentTime"] as? Double ?? status.currentTime
            if let duration = (entry["media"] as? [String: Any])?["duration"] as? Double { status.duration = duration }
            statusOut.yield(status)
        }
        if let id = json["requestId"] as? Int, id != 0, let waiter = waiters.removeValue(forKey: id) {
            if type == "LOAD_FAILED" || type == "LAUNCH_ERROR" || type == "INVALID_REQUEST" {
                waiter.resume(throwing: Failure.loadFailed((json["reason"] as? String) ?? type ?? "failed"))
            } else {
                waiter.resume(returning: json)
            }
        }
    }

    private func connectionLost() {
        guard !closed else { return }
        status.playerState = "IDLE"
        status.idleReason = "INTERRUPTED"
        statusOut.yield(status)
        close()
    }
}

/// Resumes a continuation at most once (NWConnection reports several states).
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func resume(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}
