import Foundation
import MezzanineKit
import MezzaninePlayback

/// Subtitles chosen from the internet sources, kept on this Mac per title
/// (Application Support ▸ Mezzanine ▸ Subtitles ▸ server ▸ title) and loaded every time the
/// title plays, online, offline or from a download.
nonisolated enum SavedSubtitles {
    struct Entry: Codable, Hashable, Sendable {
        var id: String
        var file: String
        var source: String
        var language: String
        var format: String
        var hearingImpaired: Bool
        var forced: Bool
        var savedAt: Date
        /// The subtitle on screen when this title was last watched (Plex can't store a choice
        /// of a file it doesn't have).
        var active: Bool?
    }

    static var root: URL {
        URL.applicationSupportDirectory.appending(path: "Mezzanine/Subtitles", directoryHint: .isDirectory)
    }

    private static func folder(serverID: String, ratingKey: String) -> URL {
        root.appending(path: safe(serverID), directoryHint: .isDirectory).appending(path: safe(ratingKey), directoryHint: .isDirectory)
    }

    private static func safe(_ s: String) -> String {
        String(s.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" })
    }

    static func entries(serverID: String, ratingKey: String) -> [Entry] {
        let url = folder(serverID: serverID, ratingKey: ratingKey).appending(path: "subtitles.json")
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    /// Writes the file and records it; choosing the same subtitle again replaces it.
    @discardableResult
    static func save(_ file: SubtitleFile, result: SubtitleResult, serverID: String, ratingKey: String) throws -> (Entry, URL) {
        let dir = folder(serverID: serverID, ratingKey: ratingKey)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "\(safe(result.source))-\(safe(String(result.id.suffix(24)))).\(file.format)"
        let url = dir.appending(path: name)
        try file.data.write(to: url, options: .atomic)
        let entry = Entry(id: result.id, file: name, source: result.sourceLabel, language: result.language, format: file.format,
                          hearingImpaired: result.hearingImpaired, forced: result.forced, savedAt: Date())
        var list = entries(serverID: serverID, ratingKey: ratingKey).filter { $0.id != entry.id }
        list.append(entry)
        try write(list, serverID: serverID, ratingKey: ratingKey)
        return (entry, url)
    }

    private static func write(_ list: [Entry], serverID: String, ratingKey: String) throws {
        let dir = folder(serverID: serverID, ratingKey: ratingKey)
        try JSONEncoder().encode(list).write(to: dir.appending(path: "subtitles.json"), options: .atomic)
    }

    /// Marks which saved subtitle is on screen (nil: another track or none).
    static func setActive(_ id: String?, serverID: String?, ratingKey: String) {
        guard let serverID else { return }
        let list = entries(serverID: serverID, ratingKey: ratingKey)
        guard !list.isEmpty else { return }
        let updated = list.map { entry -> Entry in
            var e = entry
            e.active = entry.id == id ? true : nil
            return e
        }
        if updated != list { try? write(updated, serverID: serverID, ratingKey: ratingKey) }
    }

    static func url(_ entry: Entry, serverID: String, ratingKey: String) -> URL {
        folder(serverID: serverID, ratingKey: ratingKey).appending(path: entry.file)
    }

    /// For the engine: every saved subtitle that's still on disk, with its entry.
    static func available(serverID: String?, ratingKey: String) -> [(entry: Entry, subtitle: ExternalSubtitle)] {
        guard let serverID, !serverID.isEmpty else { return [] }
        return entries(serverID: serverID, ratingKey: ratingKey).compactMap { entry in
            let url = url(entry, serverID: serverID, ratingKey: ratingKey)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return (entry, ExternalSubtitle(entry, url: url))
        }
    }
}

extension ExternalSubtitle {
    nonisolated init(_ entry: SavedSubtitles.Entry, url: URL) {
        self.init(url: url, name: entry.source, language: entry.language, format: entry.format,
                  isForced: entry.forced, isHearingImpaired: entry.hearingImpaired)
    }
}
