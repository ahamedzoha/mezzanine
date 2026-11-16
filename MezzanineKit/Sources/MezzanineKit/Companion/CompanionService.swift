import Foundation

/// What a Plex controller asks the player to do.
public enum CompanionCommand: Sendable, Equatable {
    /// Play `key` (`/library/metadata/123`) from `offset` seconds, from the server named by
    /// `machineIdentifier` (its address as the controller sees it in `address`/`port`/`scheme`).
    case playMedia(PlayMedia)
    case play
    case pause
    case stop
    case seek(to: Double)
    case stepForward
    case stepBack
    case skipNext
    case skipPrevious
    /// 0…100.
    case setVolume(Int)
    /// Plex stream ids. A subtitle id of 0 turns subtitles off; nil leaves that kind alone.
    case setStreams(audio: Int?, subtitle: Int?)

    public struct PlayMedia: Sendable, Equatable {
        public let key: String
        public let offset: Double?
        public let machineIdentifier: String?
        public let address: String?
        public let port: Int?
        public let scheme: String?
        public let containerKey: String?
        public let mediaIndex: Int?

        /// `123` from `/library/metadata/123`.
        public var ratingKey: String? {
            let last = key.split(separator: "/").last.map(String.init)
            return last.flatMap { Int($0) != nil ? $0 : nil }
        }
    }
}

/// What's playing, as the controller's timeline shows it.
public struct CompanionTimeline: Sendable, Equatable {
    public enum State: String, Sendable { case playing, paused, buffering, stopped }

    public var state: State
    public var ratingKey: String?
    public var time: Double
    public var duration: Double
    public var volume: Int
    /// The server the item comes from.
    public var machineIdentifier: String?
    public var address: String?
    public var port: Int?
    public var scheme: String?
    public var audioStreamID: Int?
    public var subtitleStreamID: Int?
    public var canSkipNext: Bool
    public var canSkipPrevious: Bool

    public static let stopped = CompanionTimeline(state: .stopped, time: 0, duration: 0, volume: 100,
                                                  canSkipNext: false, canSkipPrevious: false)

    public init(state: State, ratingKey: String? = nil, time: Double, duration: Double, volume: Int,
                machineIdentifier: String? = nil, address: String? = nil, port: Int? = nil, scheme: String? = nil,
                audioStreamID: Int? = nil, subtitleStreamID: Int? = nil, canSkipNext: Bool, canSkipPrevious: Bool) {
        self.state = state
        self.ratingKey = ratingKey
        self.time = time
        self.duration = duration
        self.volume = volume
        self.machineIdentifier = machineIdentifier
        self.address = address
        self.port = port
        self.scheme = scheme
        self.audioStreamID = audioStreamID
        self.subtitleStreamID = subtitleStreamID
        self.canSkipNext = canSkipNext
        self.canSkipPrevious = canSkipPrevious
    }

    /// The `<MediaContainer>` a controller polls for or is sent.
    public func xml(commandID: Int) -> String {
        var video: [(String, String)] = [("type", "video"), ("state", state.rawValue)]
        if state != .stopped, let ratingKey {
            var controllable = ["playPause", "stop", "seekTo", "stepBack", "stepForward", "volume", "audioStream", "subtitleStream"]
            if canSkipNext { controllable.append("skipNext") }
            if canSkipPrevious { controllable.append("skipPrevious") }
            let key = "/library/metadata/\(ratingKey)"
            video += [
                ("time", "\(Int(time * 1000))"), ("duration", "\(Int(duration * 1000))"),
                ("seekRange", "0-\(Int(duration * 1000))"), ("ratingKey", ratingKey), ("key", key),
                ("containerKey", key), ("volume", "\(volume)"), ("controllable", controllable.joined(separator: ",")),
            ]
            if let machineIdentifier { video.append(("machineIdentifier", machineIdentifier)) }
            if let address { video.append(("address", address)) }
            if let port { video.append(("port", "\(port)")) }
            if let scheme { video.append(("protocol", scheme)) }
            if let audioStreamID { video.append(("audioStreamID", "\(audioStreamID)")) }
            video.append(("subtitleStreamID", "\(subtitleStreamID ?? 0)"))
        }
        let location = state == .stopped ? "navigation" : "fullScreenVideo"
        return #"<?xml version="1.0" encoding="UTF-8"?>"# + "\n"
            + #"<MediaContainer commandID="\#(commandID)" location="\#(location)">"# + "\n"
            + "  <Timeline \(Self.attributes(video))/>\n"
            + #"  <Timeline type="music" state="stopped"/>"# + "\n"
            + #"  <Timeline type="photo" state="stopped"/>"# + "\n"
            + "</MediaContainer>\n"
    }

    static func attributes(_ pairs: [(String, String)]) -> String {
        pairs.map { "\($0.0)=\"\(escape($0.1))\"" }.joined(separator: " ")
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// The app side: carries out commands and says what's playing.
public protocol CompanionPlayer: AnyObject, Sendable {
    func perform(_ command: CompanionCommand, from controller: String) async
    func timeline() async -> CompanionTimeline
}

/// Plex Companion's player side: routes controller requests to commands, keeps the
/// controllers that subscribed, and sends each its timeline (about once a second while
/// something plays, at once after a command or a change, and when it subscribes).
public actor CompanionService {
    public struct Identity: Sendable {
        public let identifier: String
        public let name: String
        public let product: String
        public let version: String
        public let platformVersion: String

        public init(identifier: String, name: String, product: String = "Mezzanine", version: String, platformVersion: String) {
            self.identifier = identifier
            self.name = name
            self.product = product
            self.version = version
            self.platformVersion = platformVersion
        }
    }

    struct Subscriber {
        let url: URL
        var commandID: Int
        var lastSeen: Date
    }

    private let identity: Identity
    private weak var player: (any CompanionPlayer)?
    private var subscribers: [String: Subscriber] = [:]
    private var commandIDs: [String: Int] = [:]
    private var lastSent: CompanionTimeline?
    private var pusher: Task<Void, Never>?
    private var changeWaiters: [CheckedContinuation<Void, Never>] = []
    private let session: URLSession
    /// Every command, for logs: (controller name, path).
    public var log: (@Sendable (String) -> Void)?

    public init(identity: Identity, player: any CompanionPlayer) {
        self.identity = identity
        self.player = player
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        session = URLSession(configuration: config)
    }

    public func setLog(_ log: (@Sendable (String) -> Void)?) { self.log = log }

    public func startPushing() {
        guard pusher == nil else { return }
        pusher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await self?.pushIfNeeded(force: false)
            }
        }
    }

    public func stop() {
        pusher?.cancel()
        pusher = nil
        subscribers = [:]
        changeWaiters.forEach { $0.resume() }
        changeWaiters = []
    }

    /// Something changed in the player (play, pause, seek, a new title): tell the controllers now.
    public func changed() async {
        await pushIfNeeded(force: true)
        changeWaiters.forEach { $0.resume() }
        changeWaiters = []
    }

    // MARK: Requests

    public func handle(_ request: CompanionHTTPServer.Request) async -> CompanionHTTPServer.Response {
        if request.method == "OPTIONS" { return CompanionHTTPServer.Response() }
        let client = request.header("X-Plex-Client-Identifier") ?? request.query["X-Plex-Client-Identifier"] ?? request.peer
        if let id = request.query["commandID"].flatMap(Int.init) {
            commandIDs[client] = id
            subscribers[client]?.commandID = id
        }
        let name = request.header("X-Plex-Device-Name") ?? request.header("X-Plex-Product") ?? client
        log?("\(name) \(request.method) \(request.path)")

        switch request.path {
        case "/resources":
            return .xml(resourcesXML())
        case "/player/timeline/subscribe":
            guard let port = request.query["port"].flatMap(Int.init), !request.peer.isEmpty else { return failure(400) }
            let scheme = request.query["protocol"] == "https" ? "https" : "http"
            // Callbacks only ever go back to the controller that asked (never an address it names).
            guard let url = URL(string: "\(scheme)://\(Self.hostLiteral(request.peer)):\(port)") else { return failure(400) }
            subscribers[client] = Subscriber(url: url, commandID: commandIDs[client] ?? 0, lastSeen: Date())
            if let subscriber = subscribers[client] { await send(to: subscriber, timeline: await currentTimeline()) }
            return ok()
        case "/player/timeline/unsubscribe":
            subscribers[client] = nil
            return ok()
        case "/player/timeline/poll":
            if ["1", "true"].contains(request.query["wait"]) { await waitForChange(seconds: 30) }
            return .xml(await currentTimeline().xml(commandID: commandIDs[client] ?? 0))
        default:
            break
        }

        guard let command = Self.command(for: request) else {
            // Navigation, mirroring and the rest: accepted, nothing to do.
            return request.path.hasPrefix("/player/") ? ok() : failure(404)
        }
        await player?.perform(command, from: name)
        await changed()
        return ok()
    }

    static func command(for request: CompanionHTTPServer.Request) -> CompanionCommand? {
        let q = request.query
        switch request.path {
        case "/player/playback/playMedia", "/player/application/playMedia":
            guard let key = q["key"], !key.isEmpty else { return nil }
            return .playMedia(.init(key: key, offset: q["offset"].flatMap(Double.init).map { $0 / 1000 },
                                    machineIdentifier: q["machineIdentifier"], address: q["address"],
                                    port: q["port"].flatMap(Int.init), scheme: q["protocol"],
                                    containerKey: q["containerKey"], mediaIndex: q["mediaIndex"].flatMap(Int.init)))
        case "/player/playback/play": return .play
        case "/player/playback/pause": return .pause
        case "/player/playback/stop": return .stop
        case "/player/playback/seekTo":
            guard let offset = q["offset"].flatMap(Double.init) else { return nil }
            return .seek(to: offset / 1000)
        case "/player/playback/stepForward", "/player/playback/bigStepForward": return .stepForward
        case "/player/playback/stepBack", "/player/playback/bigStepBack": return .stepBack
        case "/player/playback/skipNext": return .skipNext
        case "/player/playback/skipPrevious": return .skipPrevious
        case "/player/playback/setParameters":
            return q["volume"].flatMap(Int.init).map { .setVolume(max(0, min(100, $0))) }
        case "/player/playback/setStreams":
            let audio = q["audioStreamID"].flatMap(Int.init), subtitle = q["subtitleStreamID"].flatMap(Int.init)
            return audio == nil && subtitle == nil ? nil : .setStreams(audio: audio, subtitle: subtitle)
        default:
            return nil
        }
    }

    func resourcesXML() -> String {
        let player = CompanionTimeline.attributes([
            ("title", identity.name), ("machineIdentifier", identity.identifier), ("product", identity.product),
            ("version", identity.version), ("platform", "macOS"), ("platformVersion", identity.platformVersion),
            ("protocol", "plex"), ("protocolVersion", "1"), ("protocolCapabilities", CompanionGDM.capabilities),
            ("deviceClass", "pc"), ("provides", "client,player"),
        ])
        return #"<?xml version="1.0" encoding="UTF-8"?>"# + "\n<MediaContainer>\n  <Player \(player)/>\n</MediaContainer>\n"
    }

    // MARK: Timelines

    private func currentTimeline() async -> CompanionTimeline {
        await player?.timeline() ?? .stopped
    }

    private func pushIfNeeded(force: Bool) async {
        let now = Date()
        subscribers = subscribers.filter { now.timeIntervalSince($0.value.lastSeen) < 90 }
        guard !subscribers.isEmpty else { return }
        let timeline = await currentTimeline()
        // While playing, every second (the time moves); otherwise only when something changed.
        guard force || timeline.state == .playing || timeline != lastSent else { return }
        lastSent = timeline
        for subscriber in subscribers.values { await send(to: subscriber, timeline: timeline) }
    }

    private func send(to subscriber: Subscriber, timeline: CompanionTimeline) async {
        var request = URLRequest(url: subscriber.url.appending(path: ":/timeline"))
        request.httpMethod = "POST"
        request.httpBody = Data(timeline.xml(commandID: subscriber.commandID).utf8)
        request.setValue("text/xml", forHTTPHeaderField: "Content-Type")
        request.setValue(identity.identifier, forHTTPHeaderField: "X-Plex-Client-Identifier")
        request.setValue(identity.name, forHTTPHeaderField: "X-Plex-Device-Name")
        request.setValue(identity.product, forHTTPHeaderField: "X-Plex-Product")
        request.setValue(identity.version, forHTTPHeaderField: "X-Plex-Version")
        request.setValue("macOS", forHTTPHeaderField: "X-Plex-Platform")
        _ = try? await session.data(for: request)
    }

    private func waitForChange(seconds: Double) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.parkUntilChange() }
            group.addTask { try? await Task.sleep(for: .seconds(seconds)) }
            await group.next()
            group.cancelAll()
            await self.releaseWaiters()
        }
    }

    private func parkUntilChange() async {
        await withCheckedContinuation { changeWaiters.append($0) }
    }

    private func releaseWaiters() {
        changeWaiters.forEach { $0.resume() }
        changeWaiters = []
    }

    private func ok() -> CompanionHTTPServer.Response { .xml(#"<Response code="200" status="OK"/>"#) }
    private func failure(_ code: Int) -> CompanionHTTPServer.Response { .xml(#"<Response code="\#(code)" status="Error"/>"#, status: code) }

    static func hostLiteral(_ host: String) -> String { host.contains(":") ? "[\(host)]" : host }
}
