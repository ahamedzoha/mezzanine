import Foundation

/// The winner of a connection race.
public struct ResolvedConnection: Sendable, Equatable {
    public let connection: PlexConnection
    public let latency: Duration
    public var baseURL: URL { connection.url! }

    public init(connection: PlexConnection, latency: Duration) {
        self.connection = connection
        self.latency = latency
    }
}

/// Probes one address. The default probe asks the server for `/identity`
/// (no token needed) and checks it is the server we expect.
public typealias ConnectionProbe = @Sendable (PlexConnection) async -> Bool

/// Tries every address of a server at once and picks the best one that
/// answers: a LAN address if any answers, otherwise the fastest remote, and
/// a relay only as a last resort. A LAN answer wins immediately; a remote
/// answer waits `localGrace` for a LAN answer to beat it, so a slow LAN probe
/// doesn't lose to a fast WAN round-trip through the reverse proxy.
public struct ConnectionRacer: Sendable {
    public var localGrace: Duration
    public var timeout: Duration

    public init(localGrace: Duration = .milliseconds(600), timeout: Duration = .seconds(5)) {
        self.localGrace = localGrace
        self.timeout = timeout
    }

    public func race(_ candidates: [PlexConnection], probe: @escaping ConnectionProbe) async -> ResolvedConnection? {
        let clock = ContinuousClock()
        let start = clock.now
        let timeout = self.timeout
        let grace = self.localGrace

        return await withTaskGroup(of: (PlexConnection, Duration)?.self) { group in
            for candidate in candidates where candidate.url != nil {
                group.addTask {
                    let ok = await withTaskGroup(of: Bool.self) { inner in
                        inner.addTask { await probe(candidate) }
                        inner.addTask { try? await Task.sleep(for: timeout); return false }
                        let first = await inner.next() ?? false
                        inner.cancelAll()
                        return first
                    }
                    return ok ? (candidate, clock.now - start) : nil
                }
            }

            var best: (PlexConnection, Duration)?
            var graceDeadline: ContinuousClock.Instant?
            // A timer child that wakes the loop when the grace period ends.
            var graceTimerAdded = false

            while let result = await group.next() {
                if let (conn, latency) = result {
                    if conn.route == .local {
                        if best == nil || best!.0.route != .local || conn.rank < best!.0.rank {
                            best = (conn, latency)
                        }
                        // LAN https is the best possible answer.
                        if conn.rank == 0 { break }
                    } else if best == nil || conn.rank < best!.0.rank {
                        best = (conn, latency)
                    }
                    if graceDeadline == nil {
                        graceDeadline = clock.now + grace
                        if !graceTimerAdded {
                            graceTimerAdded = true
                            group.addTask { try? await Task.sleep(for: grace); return nil }
                        }
                    }
                }
                if let deadline = graceDeadline, clock.now >= deadline, best != nil { break }
            }
            group.cancelAll()
            return best.map { ResolvedConnection(connection: $0.0, latency: $0.1) }
        }
    }

    /// Probe that GETs `/identity` and checks the machine identifier.
    public static func identityProbe(expectedMachineIdentifier: String,
                                     session: URLSession = Transport.makeProbeSession()) -> ConnectionProbe {
        { connection in
            guard let url = connection.url?.appending(path: "identity") else { return false }
            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            guard let (data, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
            struct Identity: Decodable {
                struct Container: Decodable { let machineIdentifier: String? }
                let MediaContainer: Container
            }
            guard let identity = try? JSONDecoder().decode(Identity.self, from: data) else { return false }
            return expectedMachineIdentifier.isEmpty
                || identity.MediaContainer.machineIdentifier == expectedMachineIdentifier
        }
    }
}
