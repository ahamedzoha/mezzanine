import Foundation
import Darwin

/// GDM, the discovery half of Plex Companion: how Plex servers and controllers (the Plex iPhone
/// app, Plex Web) find players on the LAN. The player listens on UDP 32412 (also joined to the
/// multicast group 239.0.0.250), answers any `M-SEARCH * HTTP/1.x` with its details, and
/// announces itself (HELLO) and leaves (BYE) on 239.0.0.250:32413.
///
/// BSD sockets rather than Network.framework: an NWConnectionGroup needs the multicast
/// entitlement, a plain socket in the sandbox only needs `network.server`.
public final class CompanionGDM: @unchecked Sendable {
    public struct Advert: Sendable {
        public var name: String
        public var port: UInt16
        public var identifier: String
        public var product: String
        public var version: String
        public var capabilities: String

        public init(name: String, port: UInt16, identifier: String, product: String = "Mezzanine",
                    version: String, capabilities: String = CompanionGDM.capabilities) {
            self.name = name
            self.port = port
            self.identifier = identifier
            self.product = product
            self.version = version
            self.capabilities = capabilities
        }

        /// The header block every GDM message carries (CRLF, as the Plex wiki's examples).
        public var body: String {
            [
                "Name: \(name)",
                "Port: \(port)",
                "Content-Type: plex/media-player",
                "Product: \(product)",
                "Protocol: plex",
                "Protocol-Version: 1",
                "Protocol-Capabilities: \(capabilities)",
                "Version: \(version)",
                "Resource-Identifier: \(identifier)",
                "Device-Class: pc",
            ].joined(separator: "\r\n")
        }
    }

    // Navigation and play queues are accepted (navigation is a no-op), so controllers that
    // only list full players still offer this one.
    public static let capabilities = "timeline,playback,navigation,playqueues"
    static let group = "239.0.0.250"
    static let searchPort: UInt16 = 32412
    static let helloPort: UInt16 = 32413

    private let queue = DispatchQueue(label: "mezzanine.companion.gdm")
    private var fd: Int32 = -1
    private var reader: DispatchSourceRead?
    private var helloTimer: DispatchSourceTimer?
    private let advert: Advert
    /// Who searched (for logs): the sender's address.
    public var onSearch: (@Sendable (String) -> Void)?

    public init(advert: Advert) {
        self.advert = advert
    }

    deinit { stopNow() }

    /// Opens the socket, joins the group, announces HELLO now and once a minute.
    public func start() throws {
        try queue.sync {
            guard fd < 0 else { return }
            let s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard s >= 0 else { throw CompanionError.socket("socket", errno) }
            var yes: Int32 = 1
            let size = socklen_t(MemoryLayout<Int32>.size)
            // Plexamp and other players on this Mac may hold 32412 too: share it.
            setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, size)
            setsockopt(s, SOL_SOCKET, SO_REUSEPORT, &yes, size)
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = Self.searchPort.bigEndian
            addr.sin_addr.s_addr = INADDR_ANY
            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard bound == 0 else { let e = errno; close(s); throw CompanionError.socket("bind", e) }
            var membership = ip_mreq(imr_multiaddr: in_addr(s_addr: inet_addr(Self.group)), imr_interface: in_addr(s_addr: INADDR_ANY))
            setsockopt(s, IPPROTO_IP, IP_ADD_MEMBERSHIP, &membership, socklen_t(MemoryLayout<ip_mreq>.size))
            var ttl: UInt8 = 1
            setsockopt(s, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
            fd = s

            let reader = DispatchSource.makeReadSource(fileDescriptor: s, queue: queue)
            reader.setEventHandler { [weak self] in self?.receive() }
            reader.resume()
            self.reader = reader

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .seconds(60))
            timer.setEventHandler { [weak self] in self?.announce("HELLO * HTTP/1.0") }
            timer.resume()
            helloTimer = timer
        }
    }

    /// BYE, then closes the socket.
    public func stop() {
        queue.sync { stopNow() }
    }

    private func stopNow() {
        guard fd >= 0 else { return }
        announce("BYE * HTTP/1.0")
        helloTimer?.cancel()
        helloTimer = nil
        reader?.cancel()
        reader = nil
        close(fd)
        fd = -1
    }

    private func receive() {
        var buffer = [UInt8](repeating: 0, count: 2048)
        var from = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = withUnsafeMutablePointer(to: &from) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &length) }
        }
        guard n > 0 else { return }
        let text = String(decoding: buffer[0..<n], as: UTF8.self)
        guard text.hasPrefix("M-SEARCH * HTTP/1.") else { return }
        let reply = Array("HTTP/1.0 200 OK\r\n\(advert.body)\r\n".utf8)
        _ = withUnsafePointer(to: &from) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, reply, reply.count, 0, $0, length) }
        }
        onSearch?(String(cString: inet_ntoa(from.sin_addr)))
    }

    private func announce(_ line: String) {
        guard fd >= 0 else { return }
        var to = sockaddr_in()
        to.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        to.sin_family = sa_family_t(AF_INET)
        to.sin_port = Self.helloPort.bigEndian
        to.sin_addr.s_addr = inet_addr(Self.group)
        let message = Array("\(line)\r\n\(advert.body)\r\n".utf8)
        _ = withUnsafePointer(to: &to) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, message, message.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
    }
}

public enum CompanionError: Error, CustomStringConvertible {
    case socket(String, Int32)
    case listener(String)

    public var description: String {
        switch self {
        case .socket(let call, let code): "\(call) failed: \(String(cString: strerror(code)))"
        case .listener(let message): message
        }
    }
}
