import Foundation
import SwiftUI
import MezzanineKit

/// One downloaded (or downloading) film or episode, with everything needed to show and play
/// it offline: its Plex JSON, artwork files and subtitle files beside the video.
nonisolated struct DownloadRecord: Codable, Identifiable, Hashable, Sendable {
    enum State: Codable, Hashable, Sendable {
        case queued, downloading, paused, done
        case failed(String)
    }

    struct Subtitle: Codable, Hashable, Sendable {
        var file: String
        var language: String?
        var codec: String?
        var forced: Bool
        var hearingImpaired: Bool
        var name: String?
    }

    /// The title's ratingKey.
    var id: String
    var serverID: String
    var userID: String
    var kind: String
    var title: String
    /// Episodes: their show (the Downloads page groups by it).
    var showKey: String?
    var showTitle: String?
    var seasonIndex: Int?
    var episodeIndex: Int?
    var year: Int?
    /// The title's Plex JSON (markers, chapters, streams) for offline pages and playback.
    var metadata: Data
    /// Paths relative to the downloads folder.
    var videoFile: String
    var posterFile: String?
    var backdropFile: String?
    /// The title's clear logo (the player's title mark, offline too).
    var logoFile: String?
    var subtitles: [Subtitle] = []
    var totalBytes: Int64 = 0
    var receivedBytes: Int64 = 0
    var state: State = .queued
    var addedAt = Date()
    var completedAt: Date?
    /// Set when the download was started by a show's keep rule (so the rule may clear it).
    var keptByRule = false

    var isDone: Bool { state == .done }
    var progress: Double { totalBytes > 0 ? Double(receivedBytes) / Double(totalBytes) : 0 }
    var groupKey: String { showKey ?? id }

    func decoded() -> PlexMetadata? { try? JSONDecoder().decode(PlexMetadata.self, from: metadata) }
}

/// Downloads for offline viewing: a queue (two at a time, resumable), files in Movies ▸
/// Mezzanine with readable names, a manifest in Application Support, and a keep rule per show
/// ("keep the next N unwatched episodes downloaded").
///
/// A downloaded copy always plays instead of the server's (`localFile(for:)`), online or not.
@MainActor
@Observable
final class DownloadStore {
    private(set) var records: [DownloadRecord] = []
    /// Show ratingKey → how many unwatched episodes to keep downloaded.
    private(set) var keepRules: [String: Int] = [:]
    /// Bytes per second of the transfer in flight, for "3 min left".
    private(set) var rates: [String: Double] = [:]

    @ObservationIgnored private var session: URLSession!
    @ObservationIgnored private let bridge = DownloadBridge()
    @ObservationIgnored private var tasks: [String: URLSessionDownloadTask] = [:]
    @ObservationIgnored private var lastSample: [String: (Date, Int64)] = [:]
    @ObservationIgnored private var client: PlexServerClient?
    @ObservationIgnored private var images: ImagePipeline?
    @ObservationIgnored private var serverID = ""
    @ObservationIgnored private var userID = ""
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    static let maxConcurrent = 2

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.httpMaximumConnectionsPerHost = Self.maxConcurrent
        session = URLSession(configuration: config, delegate: bridge, delegateQueue: nil)
        bridge.store = self
        load()
        // Anything mid-transfer when the app last quit (or was stopped) carries on: queued again,
        // resuming from its saved data when there is any. Only an explicit Pause stays paused.
        for i in records.indices where records[i].state == .downloading { records[i].state = .queued }
    }

    // MARK: Folders

    /// Movies ▸ Mezzanine (the sandbox's Movies points at the real one with the entitlement).
    nonisolated static var folder: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
        return movies.appendingPathComponent("Mezzanine", isDirectory: true)
    }

    nonisolated private static var support: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Mezzanine/Downloads", isDirectory: true)
    }

    nonisolated private static var manifest: URL { support.appendingPathComponent("manifest.json") }
    nonisolated private static func resumeData(_ id: String) -> URL { support.appendingPathComponent("resume-\(id).data") }

    func url(_ relative: String?) -> URL? {
        relative.map { Self.folder.appendingPathComponent($0) }
    }

    // MARK: Connection

    /// The server and profile downloads are made for (called when the index opens).
    func use(client: PlexServerClient, images: ImagePipeline, serverID: String, userID: String) {
        self.client = client
        self.images = images
        self.serverID = serverID
        self.userID = userID
        pump()
    }

    /// Downloads of the current profile (all of them when offline and unknown).
    var visible: [DownloadRecord] {
        userID.isEmpty ? records : records.filter { $0.serverID == serverID && $0.userID == userID }
    }

    // MARK: Queries

    func record(_ ratingKey: String) -> DownloadRecord? {
        visible.first { $0.id == ratingKey }
    }

    /// The finished file for a title, if it's downloaded (playback prefers it).
    func localFile(for ratingKey: String) -> URL? {
        guard let r = record(ratingKey), r.isDone, let url = url(r.videoFile),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    var bytesOnDisk: Int64 { visible.filter(\.isDone).reduce(0) { $0 + $1.totalBytes } }

    var freeBytes: Int64? {
        let values = try? Self.folder.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    // MARK: Adding

    /// Queues a film or an episode (original quality). Already queued or done: nothing.
    func download(_ item: PlexMetadata, keptByRule: Bool = false) {
        guard item.kind == .movie || item.kind == .episode, record(item.ratingKey) == nil,
              let client, !serverID.isEmpty else { return }
        // The profile this download belongs to, fixed before anything is awaited.
        let serverID = self.serverID, userID = self.userID
        Task {
            guard let (meta, json) = try? await client.metadataWithJSON(item.ratingKey),
                  let part = meta.media.first?.parts.first, let partKey = part.key else { return }
            guard self.serverID == serverID, self.userID == userID else { return }
            let ext = (partKey as NSString).pathExtension.isEmpty ? "mkv" : (partKey as NSString).pathExtension
            let base = Self.fileBase(meta)
            var record = DownloadRecord(
                id: meta.ratingKey, serverID: serverID, userID: userID, kind: meta.kind.rawValue,
                title: meta.title, showKey: meta.grandparentRatingKey, showTitle: meta.grandparentTitle,
                seasonIndex: meta.parentIndex, episodeIndex: meta.index, year: meta.year, metadata: json,
                videoFile: "\(base).\(ext)", totalBytes: Int64(part.size ?? 0), keptByRule: keptByRule)
            // Sidecar subtitle files travel with the video.
            record.subtitles = part.streams.compactMap { stream in
                guard stream.streamType == .subtitle, stream.key != nil else { return nil }
                let ext = stream.codec ?? "srt"
                return .init(file: "\(base).\(stream.id).\(ext)", language: stream.languageCode, codec: stream.codec,
                             forced: stream.forced, hearingImpaired: stream.hearingImpaired, name: stream.label)
            }
            guard self.record(meta.ratingKey) == nil else { return }
            records.append(record)
            save()
            await fetchExtras(record, meta: meta, part: part)
            pump()
        }
    }

    /// The next `count` unwatched episodes of a show, in order.
    func downloadNext(_ count: Int, of show: PlexMetadata, keptByRule: Bool = false) {
        guard let client else { return }
        Task {
            let all = (try? await client.allLeaves(show.ratingKey)) ?? []
            let next = Self.nextUnwatched(all, count: count)
            for episode in next { download(episode, keptByRule: keptByRule) }
        }
    }

    func downloadSeason(_ season: PlexMetadata) {
        guard let client else { return }
        Task {
            for episode in (try? await client.children(season.ratingKey)) ?? [] { download(episode) }
        }
    }

    static func nextUnwatched(_ episodes: [PlexMetadata], count: Int) -> [PlexMetadata] {
        let ordered = episodes.filter { ($0.parentIndex ?? 0) > 0 }
            .sorted { ($0.parentIndex ?? 0, $0.index ?? 0) < ($1.parentIndex ?? 0, $1.index ?? 0) }
        guard let first = ordered.firstIndex(where: { !$0.isWatched }) else { return [] }
        return Array(ordered[first...].filter { !$0.isWatched }.prefix(count))
    }

    // MARK: Keep rules

    func keepRule(for showKey: String) -> Int? { keepRules[showKey] }

    /// Keep the next `count` unwatched episodes downloaded (nil turns the rule off).
    func setKeepRule(_ count: Int?, showKey: String) {
        keepRules[showKey] = count
        save()
        applyKeepRules()
    }

    /// Tops each rule's show up to its count and clears watched episodes the rule added.
    func applyKeepRules() {
        guard let client else { return }
        for (showKey, count) in keepRules {
            Task {
                let all = (try? await client.allLeaves(showKey)) ?? []
                let wanted = Self.nextUnwatched(all, count: count)
                let wantedKeys = Set(wanted.map(\.ratingKey))
                for episode in wanted where record(episode.ratingKey) == nil { download(episode, keptByRule: true) }
                let watched = Set(all.filter(\.isWatched).map(\.ratingKey))
                for r in visible where r.showKey == showKey && r.keptByRule && watched.contains(r.id) && !wantedKeys.contains(r.id) {
                    remove(r.id)
                }
            }
        }
    }

    // MARK: Control

    func pause(_ id: String) {
        guard let task = tasks[id] else { return }
        task.cancel { [weak self] data in
            Task { @MainActor in
                if let data { try? data.write(to: Self.resumeData(id)) }
                // Resumed again meanwhile: the new transfer is the one in charge.
                guard let self, self.tasks[id] === task else { return }
                self.tasks[id] = nil
                self.setState(id, .paused)
                self.pump()
            }
        }
    }

    func resume(_ id: String) {
        guard let i = records.firstIndex(where: { $0.id == id }), records[i].state != .done else { return }
        records[i].state = .queued
        save()
        pump()
    }

    /// Removes a download (cancelling it first if it's in flight). A finished file goes to the
    /// Trash, so a mistake is recoverable in Finder; partial files are simply deleted.
    func remove(_ id: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        let r = records.remove(at: i)
        for file in [r.videoFile, r.posterFile, r.backdropFile, r.logoFile].compactMap({ $0 }) + r.subtitles.map(\.file) {
            guard let url = url(file), FileManager.default.fileExists(atPath: url.path) else { continue }
            if r.isDone && file == r.videoFile {
                if (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) == nil { try? FileManager.default.removeItem(at: url) }
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
        // An emptied show folder goes too.
        if r.showKey != nil, let folder = url(r.videoFile)?.deletingLastPathComponent(),
           (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: folder)
        }
        try? FileManager.default.removeItem(at: Self.resumeData(id))
        save()
        pump()
    }

    func removeAll(inGroup key: String) {
        for r in visible where r.groupKey == key { remove(r.id) }
    }

    /// Before quitting: keep what the transfers have so far, to resume next launch.
    func suspendForQuit() async {
        for (id, task) in tasks {
            let data: Data? = await withCheckedContinuation { c in task.cancel { c.resume(returning: $0) } }
            if let data { try? data.write(to: Self.resumeData(id)) }
            setState(id, .paused)
        }
        tasks = [:]
        save()
    }

    // MARK: Queue

    /// Starts queued downloads up to the concurrency limit.
    private func pump() {
        guard let client else { return }
        while tasks.count < Self.maxConcurrent,
              let next = records.first(where: { $0.state == .queued && $0.serverID == serverID && $0.userID == userID }) {
            guard let meta = next.decoded(), let partKey = meta.media.first?.parts.first?.key,
                  let url = client.urls.part(key: partKey) else {
                setState(next.id, .failed("This file isn’t on the server any more."))
                continue
            }
            let task: URLSessionDownloadTask
            if let data = try? Data(contentsOf: Self.resumeData(next.id)) {
                task = session.downloadTask(withResumeData: data)
                try? FileManager.default.removeItem(at: Self.resumeData(next.id))
            } else {
                var request = URLRequest(url: url)
                for (k, v) in client.requestHeaders { request.setValue(v, forHTTPHeaderField: k) }
                task = session.downloadTask(with: request)
            }
            task.taskDescription = next.id
            tasks[next.id] = task
            setState(next.id, .downloading)
            task.resume()
        }
    }

    // MARK: Bridge callbacks

    fileprivate func progressed(_ id: String, received: Int64, total: Int64) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        records[i].receivedBytes = received
        if total > 0 { records[i].totalBytes = total }
        let now = Date()
        if let (t, bytes) = lastSample[id], now.timeIntervalSince(t) >= 1 {
            let rate = Double(received - bytes) / now.timeIntervalSince(t)
            rates[id] = rates[id].map { $0 * 0.7 + rate * 0.3 } ?? rate
            lastSample[id] = (now, received)
        } else if lastSample[id] == nil {
            lastSample[id] = (now, received)
        }
    }

    fileprivate func finished(_ id: String, at temporary: URL) {
        guard let i = records.firstIndex(where: { $0.id == id }), let dest = url(records[i].videoFile) else { return }
        do {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: temporary, to: dest)
            let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? records[i].totalBytes
            records[i].totalBytes = size
            records[i].receivedBytes = size
            records[i].state = .done
            records[i].completedAt = Date()
            AccessibilityNotification.Announcement("\(records[i].title) downloaded").post()
        } catch {
            records[i].state = .failed("Couldn’t save the file: \(error.localizedDescription)")
        }
        tasks[id] = nil
        rates[id] = nil
        lastSample[id] = nil
        save()
        pump()
    }

    fileprivate func failed(_ id: String, _ error: Error) {
        tasks[id] = nil
        rates[id] = nil
        guard let i = records.firstIndex(where: { $0.id == id }), records[i].state == .downloading else { return }
        let ns = error as NSError
        if let data = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            try? data.write(to: Self.resumeData(id))
            records[i].state = .paused
        } else {
            records[i].state = .failed((error as? PlexError)?.userMessage ?? error.localizedDescription)
            AccessibilityNotification.Announcement("\(records[i].title) didn’t download").post()
        }
        save()
        pump()
    }

    // MARK: Extras (artwork and subtitles beside the video)

    private func fetchExtras(_ record: DownloadRecord, meta: PlexMetadata, part: PlexPart) async {
        guard let client else { return }
        let base = (record.videoFile as NSString).deletingPathExtension
        let folder = Self.folder
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent(base).deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        var updated = record
        // Artwork: the show's for episodes, the film's own otherwise, sized for the Downloads page.
        if let images {
            let posterPath = meta.kind == .episode ? (meta.grandparentThumb ?? meta.thumb) : meta.thumb
            if let path = posterPath, let url = client.urls.photo(path, width: 300, height: 450),
               let image = try? await images.image(for: url, pixelSize: 300), Self.writeJPEG(image, to: folder.appendingPathComponent("\(base).poster.jpg")) {
                updated.posterFile = "\(base).poster.jpg"
            }
            if let logo = meta.clearLogoPath, let url = client.urls.asset(logo) {
                var request = URLRequest(url: url)
                for (k, v) in client.requestHeaders { request.setValue(v, forHTTPHeaderField: k) }
                if let (data, response) = try? await URLSession.shared.data(for: request),
                   (response as? HTTPURLResponse)?.statusCode == 200,
                   (try? data.write(to: folder.appendingPathComponent("\(base).logo.png"))) != nil {
                    updated.logoFile = "\(base).logo.png"
                }
            }
            let artPath = meta.kind == .episode ? (meta.grandparentArt ?? meta.art) : meta.art
            if let path = artPath, let url = client.urls.photo(path, width: 1600, height: 900),
               let image = try? await images.image(for: url, pixelSize: 1600), Self.writeJPEG(image, to: folder.appendingPathComponent("\(base).backdrop.jpg")) {
                updated.backdropFile = "\(base).backdrop.jpg"
            }
        }
        // Sidecar subtitles.
        for (sub, stream) in zip(record.subtitles, part.streams.filter { $0.streamType == .subtitle && $0.key != nil }) {
            guard let key = stream.key, let url = client.urls.subtitle(streamKey: key) else { continue }
            var request = URLRequest(url: url)
            for (k, v) in client.requestHeaders { request.setValue(v, forHTTPHeaderField: k) }
            if let (data, _) = try? await URLSession.shared.data(for: request) {
                try? data.write(to: folder.appendingPathComponent(sub.file))
            }
        }
        guard let i = records.firstIndex(where: { $0.id == record.id }) else {
            // Removed while its extras arrived: don't leave them behind.
            for file in [updated.posterFile, updated.backdropFile, updated.logoFile].compactMap({ $0 }) + record.subtitles.map(\.file) {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(file))
            }
            return
        }
        records[i].posterFile = updated.posterFile
        records[i].backdropFile = updated.backdropFile
        records[i].logoFile = updated.logoFile
        save()
    }

    private static func writeJPEG(_ image: CGImage, to url: URL) -> Bool {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return false }
        return (try? data.write(to: url)) != nil
    }

    /// "Severance/Severance S02E04 Woe's Hollow" or "12 Angry Men (1957)".
    static func fileBase(_ m: PlexMetadata) -> String {
        func clean(_ s: String) -> String {
            s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: " -")
        }
        if m.kind == .episode {
            let show = clean(m.grandparentTitle ?? "Show")
            let code = String(format: "S%02dE%02d", m.parentIndex ?? 0, m.index ?? 0)
            return "\(show)/\(show) \(code) \(clean(m.title))"
        }
        return clean(m.year.map { "\(m.title) (\($0))" } ?? m.title)
    }

    // MARK: Persistence

    nonisolated private struct Manifest: Codable, Sendable {
        var records: [DownloadRecord]
        var keepRules: [String: Int]
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.manifest),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return }
        records = manifest.records
        keepRules = manifest.keepRules
    }

    /// Writes run one after another in the order asked, so the last snapshot is the one on disk
    /// (several saves fire within milliseconds when a season is queued).
    private func save() {
        let manifest = Manifest(records: records, keepRules: keepRules)
        let previous = saveTask
        saveTask = Task.detached(priority: .utility) {
            await previous?.value
            try? FileManager.default.createDirectory(at: Self.support, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(manifest) { try? data.write(to: Self.manifest, options: .atomic) }
        }
    }

    private func setState(_ id: String, _ state: DownloadRecord.State) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        records[i].state = state
        save()
    }
}

/// URLSession's delegate, forwarding to the store on the main actor.
private final class DownloadBridge: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    weak var store: DownloadStore?

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription else { return }
        Task { @MainActor [weak store] in store?.progressed(id, received: totalBytesWritten, total: totalBytesExpectedToWrite) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let error = PlexError.http(status: http.statusCode)
            Task { @MainActor [weak store] in store?.failed(id, error) }
            return
        }
        // The temporary file disappears when this returns: move it out first.
        let holding = FileManager.default.temporaryDirectory.appendingPathComponent("mezzanine-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: holding)
            Task { @MainActor [weak store] in store?.finished(id, at: holding) }
        } catch {
            Task { @MainActor [weak store] in store?.failed(id, error) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = task.taskDescription else { return }
        if (error as NSError).code == NSURLErrorCancelled, (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] == nil { return }
        Task { @MainActor [weak store] in store?.failed(id, error) }
    }
}
