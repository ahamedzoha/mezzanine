import Foundation
import Network

/// The smallest HTTP/1.1 server Plex Companion needs: one request per connection, GET/POST/
/// OPTIONS, query strings, headers, a body when Content-Length says so. Plex controllers send
/// short requests and accept `Connection: close`.
public final class CompanionHTTPServer: @unchecked Sendable {
    public struct Request: Sendable {
        public let method: String
        public let path: String
        public let query: [String: String]
        /// Lowercased names.
        public let headers: [String: String]
        public let body: Data
        /// The peer's IPv4 address (an IPv4-mapped IPv6 peer is unwrapped).
        public let peer: String

        public func header(_ name: String) -> String? { headers[name.lowercased()] }
    }

    public struct Response: Sendable {
        public var status: Int
        public var body: Data
        public var contentType: String

        public init(status: Int = 200, body: Data = Data(), contentType: String = "text/xml; charset=utf-8") {
            self.status = status
            self.body = body
            self.contentType = contentType
        }

        public static func xml(_ text: String, status: Int = 200) -> Response {
            Response(status: status, body: Data(text.utf8))
        }
    }

    public typealias Handler = @Sendable (Request) async -> Response

    private let queue = DispatchQueue(label: "mezzanine.companion.http")
    private var listener: NWListener?
    private let identifier: String

    /// `identifier` goes out as X-Plex-Client-Identifier on every response.
    public init(identifier: String) {
        self.identifier = identifier
    }

    /// Listens on `preferredPort`, or any free port if it's taken; returns the port in use.
    public func start(preferredPort: UInt16, handler: @escaping Handler) async throws -> UInt16 {
        do {
            return try await listen(on: NWEndpoint.Port(rawValue: preferredPort) ?? .any, handler: handler)
        } catch {
            return try await listen(on: .any, handler: handler)
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func listen(on port: NWEndpoint.Port, handler: @escaping Handler) async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: port)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection, handler: handler)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let resumed = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.claim() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    listener.cancel()
                    if resumed.claim() { continuation.resume(throwing: CompanionError.listener("\(error)")) }
                case .cancelled:
                    if resumed.claim() { continuation.resume(throwing: CompanionError.listener("cancelled")) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    private func serve(_ connection: NWConnection, handler: @escaping Handler) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data(), handler: handler)
    }

    private func receive(on connection: NWConnection, buffer: Data, handler: @escaping Handler) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer, peer: connection.endpoint) {
                Task {
                    let response = await handler(request)
                    self.send(response, for: request, on: connection)
                }
            } else if complete || error != nil || buffer.count > 256 * 1024 {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer, handler: handler)
            }
        }
    }

    private func send(_ response: Response, for request: Request, on connection: NWConnection) {
        var head = "HTTP/1.1 \(response.status) \(response.status == 200 ? "OK" : "Error")\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Connection: close\r\n"
        head += "X-Plex-Client-Identifier: \(identifier)\r\n"
        // Plex Web calls players from the browser.
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "Access-Control-Expose-Headers: X-Plex-Client-Identifier\r\n"
        if request.method == "OPTIONS" {
            head += "Access-Control-Allow-Methods: GET, POST, PUT, OPTIONS\r\n"
            head += "Access-Control-Allow-Headers: *\r\n"
            head += "Access-Control-Max-Age: 1209600\r\n"
        }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(response.body)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// A complete request from the bytes so far, or nil while more are needed.
    static func parse(_ data: Data, peer: NWEndpoint) -> Request? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let start = lines.removeFirst().split(separator: " ")
        guard start.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "") ?? 0
        let bodyStart = end.upperBound
        guard data.count - bodyStart >= length else { return nil }
        let target = String(start[1])
        let components = URLComponents(string: target)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return Request(method: String(start[0]).uppercased(), path: components?.path ?? target, query: query,
                       headers: headers, body: data.subdata(in: bodyStart..<(bodyStart + length)), peer: host(of: peer))
    }

    static func host(of endpoint: NWEndpoint) -> String {
        guard case .hostPort(let host, _) = endpoint else { return "" }
        var text: String
        switch host {
        case .ipv4(let address): text = "\(address)"
        case .ipv6(let address): text = "\(address)"
        case .name(let name, _): text = name
        @unknown default: text = "\(host)"
        }
        if let percent = text.firstIndex(of: "%") { text = String(text[..<percent]) }
        if text.hasPrefix("::ffff:") { text.removeFirst(7) }
        return text
    }
}

/// Resumes a continuation once, whichever state comes first.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
