import Foundation
import MezzanineKit

/// Persists `MusicQueue` per server and Plex profile (`musicQueue.v1.<server>.<user>.json`)
/// in Application Support.
enum MusicQueueStore {
    private static func fileURL(serverID: String, userID: String) throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let bundle = Bundle.main.bundleIdentifier ?? "com.mezzanine.mac"
        let dir = support.appendingPathComponent(bundle, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let s = serverID.replacingOccurrences(of: "/", with: "_")
        let u = userID.replacingOccurrences(of: "/", with: "_")
        return dir.appendingPathComponent("musicQueue.v1.\(s).\(u).json")
    }

    static func load(serverID: String, userID: String) -> MusicQueue? {
        guard let url = try? fileURL(serverID: serverID, userID: userID),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(MusicQueue.self, from: data)
    }

    static func save(_ queue: MusicQueue, serverID: String, userID: String) {
        guard let url = try? fileURL(serverID: serverID, userID: userID),
              let data = try? JSONEncoder().encode(queue) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
