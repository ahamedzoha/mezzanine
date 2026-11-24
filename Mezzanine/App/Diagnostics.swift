import AppKit
import MetricKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers
import MezzanineKit
import MezzaninePlayback

/// Keeps what macOS reports about the app (crashes, hangs, heavy disk or CPU use) and writes it,
/// with this run's log, into one file when asked: Help ▸ Save Diagnostics Report…. Everything in
/// the file passes `Redactor`. Nothing is sent anywhere.
@MainActor
final class Diagnostics: NSObject, MXMetricManagerSubscriber {
    private weak var session: SessionStore?
    private weak var library: LibraryStore?
    private weak var playback: PlaybackCoordinator?
    private weak var sound: SoundSettings?
    private let startedAt = Date()

    /// Payloads kept, newest last.
    nonisolated static let keeps = 14
    /// The log's newest lines go in the report, up to this many.
    nonisolated static let logLines = 6000

    func start(session: SessionStore, library: LibraryStore, playback: PlaybackCoordinator, sound: SoundSettings) {
        self.session = session
        self.library = library
        self.playback = playback
        self.sound = sound
        MXMetricManager.shared.add(self)
    }

    // MARK: MetricKit

    nonisolated static var folder: URL {
        URL.applicationSupportDirectory.appending(path: "Mezzanine/Diagnostics", directoryHint: .isDirectory)
    }

    /// Delivered on MetricKit's own queue.
    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let folder = Self.folder
        let files = FileManager.default
        try? files.createDirectory(at: folder, withIntermediateDirectories: true)
        for payload in payloads {
            let name = "\(Int(payload.timeStampEnd.timeIntervalSince1970))-\(UUID().uuidString.prefix(4)).json"
            try? payload.jsonRepresentation().write(to: folder.appending(path: name))
        }
        for old in Self.stored().dropLast(Self.keeps) { try? files.removeItem(at: old) }
    }

    /// Oldest first.
    nonisolated static func stored() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: The report

    func saveReport() {
        let panel = NSSavePanel()
        panel.title = "Save Diagnostics Report"
        panel.message = "Names, titles, addresses and tokens are left out. Nothing is sent."
        panel.nameFieldStringValue = "Mezzanine Diagnostics \(Date().formatted(.iso8601.year().month().day())).txt"
        panel.allowedContentTypes = [.plainText]
        // Not modal: a film (and its sleep timer) goes on behind it.
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.write(to: url) }
        }
    }

    private func write(to url: URL) {
        Task {
            let text = await report()
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                // Finder doesn't come forward over a film.
                if playback?.isPresented != true { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            } catch {
                let alert = NSAlert()
                alert.messageText = "The report couldn’t be saved"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    func report() async -> String {
        let facts = facts()
        let redact = Redactor(names: names())
        let since = max(startedAt, Date().addingTimeInterval(-6 * 3600))
        // Reading the log takes a moment: off the main actor.
        return await Task.detached(priority: .userInitiated) {
            redact([facts, Self.macOSReports(), Self.log(since: since)].joined(separator: "\n\n"))
        }.value
    }

    /// What the redactor must know by name.
    private func names() -> [String] {
        var out: [String] = [NSFullUserName(), NSUserName(), Host.current().localizedName ?? ""]
        if let session {
            out += session.servers.map(\.name)
            out += session.homeUsers.map(\.title)
            if let account = session.account { out.append(account.displayName) }
        }
        var items = library?.continueItems ?? []
        if let item = playback?.item { items.append(item) }
        items += library?.recentStops.map(\.item) ?? []
        for item in items { out += [item.title, item.grandparentTitle, item.parentTitle].compactMap { $0 } }
        return out
    }

    private func facts() -> String {
        let process = ProcessInfo.processInfo
        var lines = ["Mezzanine \(AppUpdater.versionLine)", "macOS \(process.operatingSystemVersionString)",
                     "\(Self.model()), \(process.physicalMemory / 1_073_741_824) GB, \(process.processorCount) cores",
                     "Running \(Int(Date().timeIntervalSince(startedAt) / 60)) min, report \(Date().formatted(.iso8601))",
                     "Low power \(process.isLowPowerModeEnabled), thermal \(process.thermalState.rawValue)"]
        if let session {
            let latency = session.connection.map { "\($0.latency)" } ?? "-"
            lines.append("Server: \(session.routeWords), \(session.connection?.connection.protocolName ?? "-"), \(latency), servers \(session.servers.count), profiles \(session.homeUsers.count)")
        }
        if let library {
            let counts = library.sliceCounts.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value.total)" }.joined(separator: ", ")
            lines.append("Library: \(library.syncState), last \(library.lastSyncedAt?.formatted(.iso8601) ?? "never"), titles \(counts)")
        }
        if let sound {
            let s = sound.current
            lines.append("Sound: \(s.kind.rawValue), \(Int(s.volumePercent)) %, channels \(s.profile.maxChannels.map(String.init) ?? "source"), dialogue \(s.profile.dialogueGainDB) dB, loudness \(s.profile.loudnessTargetLUFS.map { "\($0)" } ?? "off"), night \(s.profile.nightMode)")
        }
        if let playback, playback.isPresented {
            let d = playback.player.diagnostics
            lines.append("Playing: \(playback.player.status), \(playback.mode.label), route \(d.route), video \(d.videoCodec ?? "-") \(d.videoDecoder ?? "-"), audio \(d.audioDelivery) \(d.audioDecoder ?? "-"), shaping \(d.audioShaping)")
        }
        return lines.joined(separator: "\n")
    }

    private static func model() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "Mac" }
        var buffer = [UInt8](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }

    /// Crashes, hangs, disk writes and CPU exceptions macOS recorded, newest last, as JSON.
    private nonisolated static func macOSReports() -> String {
        let files = stored()
        guard !files.isEmpty else { return "macOS reports: none kept" }
        return (["macOS reports: \(files.count)"] + files.map { url in
            "--- \(url.lastPathComponent)\n" + ((try? String(contentsOf: url, encoding: .utf8)) ?? "unreadable")
        }).joined(separator: "\n")
    }

    /// This run's log: Mezzanine's own and the playback engine's.
    private nonisolated static func log(since: Date) -> String {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let predicate = NSPredicate(format: "subsystem == %@ OR subsystem BEGINSWITH %@", AppLog.subsystem, "de.superuser404.AetherEngine")
            var lines: [String] = []
            for case let entry as OSLogEntryLog in try store.getEntries(at: store.position(date: since), matching: predicate) {
                lines.append("\(entry.date.formatted(.iso8601.time(includingFractionalSeconds: true))) [\(entry.category)] \(entry.composedMessage)")
                if lines.count > logLines * 2 { lines.removeFirst(logLines) }
            }
            return "Log: \(lines.count) lines\n" + lines.suffix(logLines).joined(separator: "\n")
        } catch {
            return "Log: couldn’t be read (\(error.localizedDescription))"
        }
    }
}
