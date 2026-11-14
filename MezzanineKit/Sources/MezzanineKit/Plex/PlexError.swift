import Foundation

/// Everything that can go wrong talking to plex.tv or a Plex Media Server, in
/// terms the UI can act on. Cancellation is never wrapped: it surfaces as
/// `CancellationError`.
public enum PlexError: Error, Sendable, Equatable {
    /// The request never got an HTTP answer (offline, DNS, refused, timeout).
    case unreachable(String)
    /// macOS keeps Mezzanine off the local network (Privacy & Security ▸ Local
    /// Network) while the Mac itself is online. URLSession reports it as -1009.
    case localNetworkDenied
    /// 401: the token is missing, expired or was revoked on plex.tv.
    case unauthorized
    /// 403: this user may not see that server or item.
    case forbidden
    /// 404: the item or endpoint isn't there (deleted, or an older server).
    case notFound
    /// Something in front of Plex answered instead of Plex (a redirect, an HTML page).
    case proxyIntercepted(location: String?)
    /// A proxy says the server itself is down (502/503/504).
    case serverDown(status: Int)
    /// Any other unexpected HTTP status.
    case http(status: Int)
    /// Plex answered, but not in the shape this app expects.
    case decoding(String)
    /// No connection to the server answered in time.
    case noReachableConnection

    public var userMessage: String {
        switch self {
        case .unreachable:
            return "Couldn’t reach the server. Check that Plex Media Server is running."
        case .localNetworkDenied:
            return "macOS is keeping Mezzanine off your local network. Turn on Mezzanine in System Settings ▸ Privacy & Security ▸ Local Network."
        case .unauthorized:
            return "Plex didn’t accept the sign-in. Sign in again."
        case .forbidden:
            return "Your Plex account isn’t allowed to see this."
        case .notFound:
            return "That item isn’t on the server any more."
        case .proxyIntercepted:
            return "Something in front of Plex answered instead of Plex."
        case .serverDown(let status):
            return "Plex isn’t responding (error \(status) from the proxy)."
        case .http(let status):
            return "The server returned error \(status)."
        case .decoding:
            return "The server’s answer wasn’t what Mezzanine expected."
        case .noReachableConnection:
            return "None of the server’s addresses answered."
        }
    }

    /// Worth retrying a read after a short pause.
    public var isTransient: Bool {
        switch self {
        case .unreachable, .serverDown: return true
        case .http(let status): return status == 429 || (500...599).contains(status)
        default: return false
        }
    }

    /// Maps a transport-level error. `localNetworkSuspected` is true when the
    /// Mac is online but the request still failed as "not connected", which is
    /// how macOS reports a Local Network denial.
    static func from(_ error: Error, localNetworkSuspected: Bool) -> Error {
        if error is CancellationError { return error }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            if ns.code == NSURLErrorCancelled { return CancellationError() }
            if ns.code == NSURLErrorNotConnectedToInternet, localNetworkSuspected {
                return PlexError.localNetworkDenied
            }
            return PlexError.unreachable(ns.localizedDescription)
        }
        return error
    }

    static func from(status: Int, location: String?) -> PlexError? {
        switch status {
        case 200..<300: return nil
        case 300..<400: return .proxyIntercepted(location: location)
        case 401: return .unauthorized
        case 403: return .forbidden
        case 404: return .notFound
        case 502, 503, 504: return .serverDown(status: status)
        default: return .http(status: status)
        }
    }
}
