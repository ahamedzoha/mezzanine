import Foundation
import CryptoKit

/// Downsampled copies of remote images on disk, so relaunches and re-scrolls
/// don't refetch multi-megabyte artwork or decode them again.
///
/// Files are named by SHA-256 of the key (which never contains credentials).
/// Trimmed least-recently-used first to a size limit.
public final class DerivativeDiskCache: Sendable {
    public let directory: URL
    public let limitBytes: Int64

    public init(directory: URL, limitBytes: Int64) {
        self.directory = directory
        self.limitBytes = limitBytes
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// `~/Library/Caches/<bundle>/Images` inside the sandbox container.
    public static func standard(limitMB: Int) -> DerivativeDiskCache? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return DerivativeDiskCache(directory: caches.appendingPathComponent("Images", isDirectory: true),
                                   limitBytes: Int64(limitMB) * 1_048_576)
    }

    public func data(forKey key: String) -> Data? {
        var file = fileURL(for: key)
        guard let data = try? Data(contentsOf: file) else { return nil }
        var values = URLResourceValues()
        values.contentAccessDate = Date()
        try? file.setResourceValues(values)
        return data
    }

    public func store(_ data: Data, forKey key: String) {
        try? data.write(to: fileURL(for: key), options: .atomic)
    }

    public func removeAll() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func size() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])) ?? []
        return files.reduce(0) { total, file in
            total + Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
    }

    /// Deletes the least recently used files until the cache fits its limit.
    public func trim() {
        let keys: [URLResourceKey] = [.contentAccessDateKey, .totalFileAllocatedSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)
        else { return }
        Self.trim(files, to: limitBytes)
    }

    /// Pure over the files given, so the policy is testable.
    static func trim(_ files: [URL], to limitBytes: Int64) {
        let keys: Set<URLResourceKey> = [.contentAccessDateKey, .totalFileAllocatedSizeKey]
        var entries = files.map { file -> (URL, Date, Int64) in
            let values = try? file.resourceValues(forKeys: keys)
            return (file, values?.contentAccessDate ?? .distantPast, Int64(values?.totalFileAllocatedSize ?? 0))
        }
        var total = entries.reduce(0) { $0 + $1.2 }
        guard total > limitBytes else { return }
        entries.sort { $0.1 < $1.1 }
        for (file, _, size) in entries where total > limitBytes {
            try? FileManager.default.removeItem(at: file)
            total -= size
        }
    }

    func fileURL(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name, isDirectory: false)
    }
}
