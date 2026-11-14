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

    let identity: PlexIdentity
    /// Every remote image in the app goes through this one pipeline.
    let images = ImagePipeline(disk: .standard(limitMB: 512))
    private let keychain = Keychain(service: "com.mezzanine.mac.plex")
    private let tv: PlexTV
    private var signInTask: Task<Void, Never>?
    private var pathObserver: UUID?
    private var lastPathGeneration = NetworkPath.shared.changeGeneration

    private static let accountKey = "account"
    private static let serverDefaultsKey = "selectedServer"

    init() {
        identity = PlexIdentity(clientIdentifier: Self.stableClientIdentifier())
        tv = PlexTV(identity: identity)
        pathObserver = NetworkPath.shared.onChange { [weak self] _ in
            Task { @MainActor in self?.networkChanged() }
        }
    }

    var token: String? { keychain.read(Self.accountKey) }

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
        guard let token else { phase = .signedOut; return }
        await connect(token: token)
    }

    func signIn() {
        signInTask?.cancel()
        signInTask = Task {
            do {
                let pin = try await tv.createPin(strong: true)
                phase = .awaitingApproval(code: pin.code)
                NSWorkspace.shared.open(tv.authURL(for: pin))
                let token = try await tv.waitForToken(pin: pin)
                try keychain.write(token, for: Self.accountKey)
                await connect(token: token)
            } catch is CancellationError {
                phase = .signedOut
            } catch {
                phase = .failed((error as? PlexError)?.userMessage ?? error.localizedDescription)
            }
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        phase = .signedOut
    }

    func signOut() {
        keychain.delete(Self.accountKey)
        account = nil
        servers = []
        currentServer = nil
        connection = nil
        client = nil
        phase = .signedOut
    }

    // MARK: Servers

    private func connect(token: String) async {
        phase = .connecting
        do {
            async let account = tv.account(token: token)
            async let servers = tv.resources(token: token)
            self.account = try await account
            self.servers = try await servers.sorted { ($0.owned ? 0 : 1, $0.name) < ($1.owned ? 0 : 1, $1.name) }
            let saved = UserDefaults.standard.string(forKey: Self.serverDefaultsKey)
            guard let server = self.servers.first(where: { $0.clientIdentifier == saved })
                    ?? self.servers.first(where: \.owned) ?? self.servers.first else {
                phase = .failed("This Plex account has no servers.")
                return
            }
            try await select(server, token: token)
        } catch PlexError.unauthorized {
            signOut()
        } catch {
            phase = .failed((error as? PlexError)?.userMessage ?? error.localizedDescription)
        }
    }

    func select(_ server: PlexServerResource) async {
        guard let token else { return }
        do { try await select(server, token: token) } catch {
            phase = .failed((error as? PlexError)?.userMessage ?? error.localizedDescription)
        }
    }

    private func select(_ server: PlexServerResource, token: String) async throws {
        phase = .connecting
        let racer = ConnectionRacer()
        guard let won = await racer.race(server.candidates,
                                         probe: ConnectionRacer.identityProbe(expectedMachineIdentifier: server.clientIdentifier)) else {
            throw PlexError.noReachableConnection
        }
        currentServer = server
        connection = won
        client = PlexServerClient(baseURL: won.baseURL, token: server.accessToken ?? token,
                                  machineIdentifier: server.clientIdentifier, identity: identity)
        UserDefaults.standard.set(server.clientIdentifier, forKey: Self.serverDefaultsKey)
        await images.setToken(server.accessToken ?? token, host: won.baseURL.host(), serverID: server.clientIdentifier)
        phase = .ready
    }

    /// Wi-Fi switch, VPN up or down: the best address may have changed.
    private func networkChanged() {
        let generation = NetworkPath.shared.changeGeneration
        guard generation != lastPathGeneration, phase == .ready, let server = currentServer else { return }
        lastPathGeneration = generation
        Task { await select(server) }
    }

    // MARK: Artwork URLs

    /// A poster at the pixel width it's drawn at (2:3), resized by the server.
    func posterURL(_ path: String?, pixelWidth: Int) -> URL? {
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
}
