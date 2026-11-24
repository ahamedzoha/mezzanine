import Foundation
import AppKit
import MezzanineKit

/// The signed-in account, its servers, and the live connection to the chosen
/// server. One instance for the app's lifetime.
@Observable
final class SessionStore {
    enum Phase: Equatable {
        case signedOut
        case awaitingApproval(code: String)
        case connecting
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .signedOut
    private(set) var account: PlexAccount?
    private(set) var servers: [PlexServerResource] = []
    private(set) var currentServer: PlexServerResource?
    private(set) var connection: ResolvedConnection?
    private(set) var client: PlexServerClient?
    /// Plex Home members (empty when the account has no Home).
    private(set) var homeUsers: [PlexHomeUser] = []
    /// Each profile's avatar as a round menu-sized image (menus can't clip SwiftUI images).
    private(set) var avatars: [String: NSImage] = [:]

    let identity: PlexIdentity
    /// Every remote image in the app goes through this one pipeline.
    let images = ImagePipeline(disk: .standard(limitMB: 512))
    /// "com.mezzanine.mac.plex" for the app; Debug builds (com.mezzanine.mac.debug) keep
    /// their own token, so test runs never touch the installed app's sign-in.
    private let keychain = Keychain(service: (Bundle.main.bundleIdentifier ?? "com.mezzanine.mac") + ".plex")
    private let tv: PlexTV
    private var signInTask: Task<Void, Never>?
    /// The browser page for the sign-in in progress (to reopen it).
    private(set) var pendingAuthURL: URL?
    private var pathObserver: UUID?
    private var lastPathGeneration = NetworkPath.shared.changeGeneration

    private static let accountKey = "account"
    /// The active Plex Home profile's token, when it isn't the account owner.
    private static let profileKey = "profile"
    private static let serverDefaultsKey = "selectedServer"

    init() {
        identity = PlexIdentity(clientIdentifier: Self.stableClientIdentifier())
        tv = PlexTV(identity: identity)
        pathObserver = NetworkPath.shared.onChange { [weak self] _ in
            Task { @MainActor in self?.networkChanged() }
        }
    }

    /// The signed-in plex.tv account's token.
    var token: String? { keychain.read(Self.accountKey) }
    /// The token everything else uses: the active Home profile's, else the account's.
    var activeToken: String? { keychain.read(Self.profileKey) ?? token }

    /// Plex's own service for the profile in use (its watchlist).
    var discover: PlexDiscover? { activeToken.map { PlexDiscover(identity: identity, token: $0) } }

    /// One identifier per install. plex.tv ties the token and the Authorized
    /// Devices entry to it; Plex ties playback sessions to it.
    private static func stableClientIdentifier() -> String {
        let key = "plexClientIdentifier"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = "mezzanine-" + UUID().uuidString.lowercased()
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }

    // MARK: Lifecycle

    func restore() async {
        #if DEBUG
        // Dev seeding (Scripts/dev-run.sh): a fresh Debug build signs in with the dev token
        // from .mezzanine-live.env instead of the browser flow. The env var only exists when
        // the binary is launched from that script.
        if token == nil, let seeded = ProcessInfo.processInfo.environment["MEZZANINE_DEV_TOKEN"], !seeded.isEmpty {
            try? keychain.write(seeded, for: Self.accountKey)
        }
        #endif
        guard let active = activeToken else { phase = .signedOut; return }
        #if DEBUG
        // -ForceOffline YES: behave as if Plex can't be reached (offline downloads tests).
        if UserDefaults.standard.bool(forKey: "ForceOffline") { phase = .failed(PlexError.noReachableConnection.userMessage); return }
        #endif
        await connect(token: active)
    }

    func signIn() {
        signInTask?.cancel()
        signInTask = Task {
            do {
                let pin = try await tv.createPin(strong: true)
                phase = .awaitingApproval(code: pin.code)
                let url = tv.authURL(for: pin)
                pendingAuthURL = url
                NSWorkspace.shared.open(url)
                let token = try await tv.waitForToken(pin: pin)
                try keychain.write(token, for: Self.accountKey)
                keychain.delete(Self.profileKey)
                await connect(token: token)
            } catch is CancellationError {
                phase = .signedOut
            } catch {
                phase = .failed((error as? PlexError)?.userMessage ?? error.localizedDescription)
            }
        }
    }

    func reopenApproval() {
        if let pendingAuthURL { NSWorkspace.shared.open(pendingAuthURL) }
    }

    /// System Settings ▸ Privacy & Security ▸ Local Network (new pane id first, legacy after).
    static func openLocalNetworkSettings() {
        let modern = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_LocalNetwork")!
        let legacy = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!
        if !NSWorkspace.shared.open(modern) { NSWorkspace.shared.open(legacy) }
    }

    func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        phase = .signedOut
    }

    func signOut() {
        keychain.delete(Self.accountKey)
        keychain.delete(Self.profileKey)
        homeUsers = []
        account = nil
        servers = []
        currentServer = nil
        connection = nil
        client = nil
        phase = .signedOut
    }

    // MARK: Servers

    /// Bumped by every sign-in, profile switch and server pick: a slower, older one that's still
    /// racing addresses stops instead of landing over the newer choice.
    @ObservationIgnored private var connectGeneration = 0

    private func connect(token: String) async {
        connectGeneration += 1
        let generation = connectGeneration
        phase = .connecting
        do {
            async let account = tv.account(token: token)
            async let servers = tv.resources(token: token)
            let newAccount = try await account
            let newServers = try await servers.sorted { ($0.owned ? 0 : 1, $0.name) < ($1.owned ? 0 : 1, $1.name) }
            guard generation == connectGeneration else { return }
            self.servers = newServers
            let saved = UserDefaults.standard.string(forKey: Self.serverDefaultsKey)
            guard let server = newServers.first(where: { $0.clientIdentifier == saved })
                    ?? newServers.first(where: \.owned) ?? newServers.first else {
                self.account = newAccount
                phase = .failed("This Plex account has no servers.")
                return
            }
            // The account changes together with its client, so nothing reads the new profile
            // through the previous profile's connection.
            try await select(server, token: token, account: newAccount, generation: generation)
        } catch is CancellationError {
        } catch PlexError.unauthorized {
            guard generation == connectGeneration else { return }
            signOut()
        } catch {
            guard generation == connectGeneration else { return }
            phase = .failed((error as? PlexError)?.userMessage ?? error.localizedDescription)
        }
    }

    func select(_ server: PlexServerResource) async {
        guard let token = activeToken else { return }
        connectGeneration += 1
        let generation = connectGeneration
        do { try await select(server, token: token, account: nil, generation: generation) } catch {
            guard generation == connectGeneration else { return }
            phase = .failed((error as? PlexError)?.userMessage ?? error.localizedDescription)
        }
    }

    private func select(_ server: PlexServerResource, token: String, account newAccount: PlexAccount?, generation: Int) async throws {
        // A refresh of the same server keeps the window as it is; only a first
        // connection or a server switch shows "Connecting".
        if currentServer?.clientIdentifier != server.clientIdentifier || client == nil {
            phase = .connecting
        }
        let racer = ConnectionRacer()
        guard let won = await racer.race(server.candidates,
                                         probe: ConnectionRacer.identityProbe(expectedMachineIdentifier: server.clientIdentifier)) else {
            guard generation == connectGeneration else { return }
            throw await diagnoseUnreachable(server)
        }
        guard generation == connectGeneration else { return }
        if let newAccount { account = newAccount }
        currentServer = server
        connection = won
        client = PlexServerClient(baseURL: won.baseURL, token: server.accessToken ?? token,
                                  machineIdentifier: server.clientIdentifier, identity: identity)
        UserDefaults.standard.set(server.clientIdentifier, forKey: Self.serverDefaultsKey)
        await images.setToken(server.accessToken ?? token, host: won.baseURL.host(), serverID: server.clientIdentifier)
        phase = .ready
        AppLog.session.notice("connected, \(self.routeWords, privacy: .public)")
    }

    // MARK: Plex Home

    /// Loads the Home's members (account token; only the owner can list them).
    func loadHomeUsers() async {
        guard let token else { return }
        homeUsers = (try? await tv.homeUsers(token: token)) ?? []
        Task { await loadAvatars() }
    }

    /// The profile in use: the account itself, or a Home member.
    var activeProfileUUID: String? { account?.uuid }

    /// Switches to a Home member (PIN when the profile has one) and reconnects
    /// as them. Switching back to the owner clears the profile token.
    func switchProfile(to user: PlexHomeUser, pin: String?) async throws {
        guard let token else { throw PlexError.unauthorized }
        if user.admin {
            keychain.delete(Self.profileKey)
            await connect(token: token)
            return
        }
        let userToken = try await tv.switchHomeUser(uuid: user.uuid, pin: pin, token: token)
        try keychain.write(userToken, for: Self.profileKey)
        await connect(token: userToken)
    }

    /// Every address failed. macOS reports a Local Network denial as "offline"
    /// (-1009) while the Mac is online; ask one LAN address directly to tell the
    /// two apart, because the fix (System Settings) is entirely different.
    private func diagnoseUnreachable(_ server: PlexServerResource) async -> PlexError {
        guard NetworkPath.shared.isSatisfied,
              let lan = server.candidates.first(where: { $0.local })?.url?.appending(path: "identity") else {
            return .noReachableConnection
        }
        do {
            _ = try await Transport.makeProbeSession().data(from: lan)
            return .noReachableConnection
        } catch {
            let ns = error as NSError
            return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorNotConnectedToInternet
                ? .localNetworkDenied : .noReachableConnection
        }
    }

    var isLocalNetworkDenied: Bool {
        if case .failed(let message) = phase { return message == PlexError.localNetworkDenied.userMessage }
        return false
    }

    /// Wi-Fi switch, VPN up or down: the best address may have changed.
    private func networkChanged() {
        let generation = NetworkPath.shared.changeGeneration
        guard generation != lastPathGeneration, phase == .ready, let server = currentServer else { return }
        lastPathGeneration = generation
        Task { await refreshConnection(server) }
    }

    /// Re-races in the background after a real network change and swaps the
    /// client only when a different address wins. Nothing on screen reloads
    /// unless the address actually changed.
    private func refreshConnection(_ server: PlexServerResource) async {
        guard let token = activeToken else { return }
        let generation = connectGeneration
        guard let won = await ConnectionRacer().race(server.candidates,
                                                     probe: ConnectionRacer.identityProbe(expectedMachineIdentifier: server.clientIdentifier)),
              won.connection != connection?.connection else { return }
        // A profile or server switch finished meanwhile: its connection stands.
        guard generation == connectGeneration, activeToken == token,
              currentServer?.clientIdentifier == server.clientIdentifier else { return }
        connection = won
        client = PlexServerClient(baseURL: won.baseURL, token: server.accessToken ?? token,
                                  machineIdentifier: server.clientIdentifier, identity: identity)
        await images.setToken(server.accessToken ?? token, host: won.baseURL.host(), serverID: server.clientIdentifier)
    }

    // MARK: Artwork URLs

    /// A poster at the pixel width it's drawn at (2:3), resized by the server.
    func posterURL(_ path: String?, pixelWidth: Int) -> URL? {
        // Plex's own service (the watchlist) gives whole addresses; no token goes there.
        if let path, path.hasPrefix("https://") { return URL(string: path) }
        guard let path, let client else { return nil }
        let w = Downsampler.bucket(for: pixelWidth)
        return client.urls.photo(path, width: w, height: w * 3 / 2)
    }

    /// A 16:9 still or backdrop at the pixel width it's drawn at.
    func backdropURL(_ path: String?, pixelWidth: Int) -> URL? {
        guard let path, let client else { return nil }
        let w = Downsampler.bucket(for: pixelWidth)
        return client.urls.photo(path, width: w, height: w * 9 / 16)
    }

    /// Clear logos stay originals: they're transparent PNGs, and a resize could flatten them.
    func logoURL(_ path: String?) -> URL? {
        guard let path, let client else { return nil }
        return client.urls.asset(path)
    }

    // MARK: Avatars

    /// Fetches every profile's avatar once (plex.tv, no token) and keeps a round copy for menus.
    func loadAvatars() async {
        for user in homeUsers where avatars[user.uuid] == nil {
            guard let thumb = user.thumb, let url = URL(string: thumb),
                  let image = try? await images.image(for: url, pixelSize: 64) else { continue }
            avatars[user.uuid] = Self.roundMenuImage(image, points: 18)
        }
        #if DEBUG
        print("AVATARS \(avatars.count) of \(homeUsers.count)")
        #endif
    }

    static func roundMenuImage(_ image: CGImage, points: CGFloat) -> NSImage {
        let size = NSSize(width: points, height: points)
        return NSImage(size: size, flipped: false) { rect in
            NSBezierPath(ovalIn: rect).addClip()
            NSGraphicsContext.current?.imageInterpolation = .high
            NSImage(cgImage: image, size: .zero).draw(in: rect)
            return true
        }
    }
}
