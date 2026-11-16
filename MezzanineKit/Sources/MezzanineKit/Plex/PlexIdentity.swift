import Foundation

/// Who this client is, in the headers every Plex request carries.
///
/// The client identifier must stay stable for the life of the install: plex.tv
/// ties the auth token and the "Authorized Devices" entry to it, and the
/// server ties playback sessions (and so Tautulli's history) to it.
public struct PlexIdentity: Sendable, Equatable {
    public var clientIdentifier: String
    public var product: String
    public var version: String
    public var deviceName: String
    public var platform: String
    public var platformVersion: String
    public var device: String
    /// What plex.tv records this client as (`player`; the remote-control registration adds
    /// `client,player,pubsub-player`).
    public var provides: String = "player"

    public init(clientIdentifier: String,
                product: String = "Mezzanine",
                version: String = "0.1.0",
                deviceName: String = Host.current().localizedName ?? "Mac",
                platform: String = "macOS",
                platformVersion: String = ProcessInfo.processInfo.operatingSystemVersionString,
                device: String = "Mac") {
        self.clientIdentifier = clientIdentifier
        self.product = product
        self.version = version
        self.deviceName = deviceName
        self.platform = platform
        self.platformVersion = platformVersion
        self.device = device
    }

    /// The `X-Plex-*` headers Plex expects from a client. The token is added
    /// separately, per server, so it never reaches the wrong host.
    public var headers: [String: String] {
        [
            "X-Plex-Client-Identifier": clientIdentifier,
            "X-Plex-Product": product,
            "X-Plex-Version": version,
            "X-Plex-Device-Name": deviceName,
            "X-Plex-Platform": platform,
            "X-Plex-Platform-Version": platformVersion,
            "X-Plex-Device": device,
            "X-Plex-Provides": provides,
        ]
    }
}
