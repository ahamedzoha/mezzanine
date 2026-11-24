import Foundation

/// Takes what could identify a person, a server or what was watched out of a diagnostics report.
/// Patterns cover what nobody can list (tokens, addresses, paths); `names` covers what the app
/// knows (server, account, profile and title names).
public struct Redactor: Sendable {
    private let names: [String]
    private let home: String

    public init(names: [String], home: String = NSHomeDirectory()) {
        // Longest first, so "Example Media Harbour" goes before "Harbour". Very short names would eat words.
        self.names = Set(names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { $0.count >= 3 })
            .sorted { $0.count > $1.count }
        self.home = home
    }

    public func callAsFunction(_ text: String) -> String {
        var out = text
        if !home.isEmpty { out = out.replacingOccurrences(of: home, with: "~") }
        // Before names: a profile called "Plex" would break a host name up for the patterns.
        for (pattern, replacement) in Self.patterns {
            out = out.replacingOccurrences(of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
        }
        for name in names {
            // Whole words: a film called "Cars" must not eat into other words.
            out = out.replacingOccurrences(of: "(?<!\\w)\(NSRegularExpression.escapedPattern(for: name))(?!\\w)", with: "<name>",
                                           options: [.regularExpression, .caseInsensitive])
        }
        return out
    }

    private static let patterns: [(String, String)] = [
        // Tokens, wherever they're written.
        (#"(X-Plex-Token|X-Plex-Client-Identifier|access_?token|auth_?token|api_?key|authorization|password)(["']?\s*[=:]\s*["']?)(Bearer\s+)?[^\s&"',;)}]+"#, "$1$2<redacted>"),
        // Every URL keeps its scheme, port and path kind only; the app's own loopback server stays.
        (#"(https?|wss?)://(?!127\.0\.0\.1|localhost)[^\s/"'<>:]+(:\d+)?"#, "$1://<host>$2"),
        (#"[A-Za-z0-9.-]+\.plex\.direct"#, "<host>"),
        (#"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, "<email>"),
        (#"/Users/[^/\s"']+"#, "/Users/<user>"),
        (#"/library/parts/[^\s"'?]+"#, "/library/parts/<file>"),
        (#"(file|path|name)=("[^"]*"|\S+\.(mkv|mp4|avi|m4v|mov|ts|srt|ass))"#, "$1=<file>"),
        // Addresses on their own: IPv4 other than loopback, MAC, IPv6.
        (#"(?<![\d.])(?!127\.0\.0\.1)(\d{1,3}\.){3}\d{1,3}(?![\d.])"#, "<address>"),
        (#"(?<![0-9a-f:])([0-9a-f]{2}:){5}[0-9a-f]{2}(?![0-9a-f:])"#, "<address>"),
        (#"(?<![0-9a-f:])([0-9a-f]{1,4}:){4,7}[0-9a-f]{1,4}(?![0-9a-f:])"#, "<address>"),
        // Machine and install identifiers.
        (#"\b[0-9a-f]{32,}\b"#, "<id>"),
        (#"mezzanine-[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}"#, "<install>"),
    ]
}
