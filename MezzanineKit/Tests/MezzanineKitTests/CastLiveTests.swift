import Testing
import Foundation
@testable import MezzanineKit

/// Finds Cast devices on the real network. Opt in: MEZZANINE_CAST=1.
@Suite("Cast discovery (network)", .enabled(if: ProcessInfo.processInfo.environment["MEZZANINE_CAST"] != nil))
struct CastLiveTests {
    @Test func findsDevices() async throws {
        let discovery = CastDiscovery()
        discovery.onState = { print("CAST browser state", $0) }
        discovery.start()
        Task { try? await Task.sleep(for: .seconds(8)); discovery.stop() }
        var found: [CastDevice] = []
        for await devices in discovery.devices {
            found = devices
            if !devices.isEmpty { break }
        }
        discovery.stop()
        print("CAST found", found.map { "\($0.name) [\($0.model ?? "-")]" })
        #expect(!found.isEmpty)
    }

    /// MEZZANINE_CAST=stop: closes the Default Media Receiver if a TV is showing it.
    @Test func stopsRunningReceiver() async throws {
        guard ProcessInfo.processInfo.environment["MEZZANINE_CAST"] == "stop" else { return }
        let discovery = CastDiscovery()
        discovery.start()
        Task { try? await Task.sleep(for: .seconds(8)); discovery.stop() }
        var found: [CastDevice] = []
        for await devices in discovery.devices { found = devices; if !devices.isEmpty { break } }
        discovery.stop()
        for device in found {
            let stopped = try await CastSession(device: device).stopRunningReceiver()
            print("CAST stop \(device.name): \(stopped ? "closed the player" : "nothing running")")
        }
    }
}
