import Foundation

/// What to look for: the title's identity (IDs, names, episode numbers), the file's
/// OpenSubtitles hash when known, and the languages wanted (ISO 639-1, best first).
public struct SubtitleQuery: Sendable, Equatable {
    public enum Kind: String, Sendable { case movie, episode }
    public var kind: Kind
    public var title: String
    public var year: Int?
    public var imdbID: String?
    public var tmdbID: String?
    /// Episodes: the show's identity and the episode's place in it.
    public var showTitle: String?
    public var showIMDbID: String?
    public var showTVDbID: String?
    public var season: Int?
    public var episode: Int?
    /// OpenSubtitles' 64-bit file hash (hex) and the file's size.
    public var fileHash: String?
    public var fileSize: Int64?
    /// The file's name, for release matching ("Show.S01E02.1080p.WEB-DL…").
    public var fileName: String?
    public var languages: [String]

    public init(kind: Kind, title: String, year: Int? = nil, imdbID: String? = nil, tmdbID: String? = nil,
                showTitle: String? = nil, showIMDbID: String? = nil, showTVDbID: String? = nil,
                season: Int? = nil, episode: Int? = nil, fileHash: String? = nil, fileSize: Int64? = nil,
                fileName: String? = nil, languages: [String]) {
        self.kind = kind; self.title = title; self.year = year; self.imdbID = imdbID; self.tmdbID = tmdbID
        self.showTitle = showTitle; self.showIMDbID = showIMDbID; self.showTVDbID = showTVDbID
        self.season = season; self.episode = episode; self.fileHash = fileHash; self.fileSize = fileSize
        self.fileName = fileName; self.languages = languages
    }

    /// Reads IMDb/TMDB/TVDB IDs out of Plex's `Guid` list ("imdb://tt0111161").
    public static func id(_ scheme: String, in guids: [String]) -> String? {
        guids.first { $0.hasPrefix("\(scheme)://") }.map { String($0.dropFirst(scheme.count + 3)) }
    }
}

/// One subtitle a source offers.
public struct SubtitleResult: Identifiable, Sendable, Hashable {
    public let id: String
    public let source: String
    /// ISO 639-1 ("en").
    public let language: String
    /// The release it was made for, or the source's own title for it.
    public let release: String
    public let hearingImpaired: Bool
    public let forced: Bool
    /// Made for exactly this file (OpenSubtitles' hash match).
    public let hashMatch: Bool
    public let downloads: Int?
    public let format: String
    /// The source's own reference for the download.
    public let payload: String
    /// Where a relaying source got it ("OpenSubtitles" for Plex's own search).
    public let via: String?

    public init(id: String, source: String, language: String, release: String, hearingImpaired: Bool, forced: Bool = false,
                hashMatch: Bool = false, downloads: Int? = nil, format: String = "srt", payload: String, via: String? = nil) {
        self.id = id; self.source = source; self.language = language; self.release = release
        self.hearingImpaired = hearingImpaired; self.forced = forced; self.hashMatch = hashMatch
        self.downloads = downloads; self.format = format; self.payload = payload; self.via = via
    }

    /// "Subdl", "Plex (OpenSubtitles)".
    public var sourceLabel: String { via.map { "\(source) (\($0))" } ?? source }
}

/// A downloaded subtitle file.
public struct SubtitleFile: Sendable {
    /// UTF-8 text.
    public let data: Data
    /// "srt", "ass", "vtt"…
    public let format: String

    public init(data: Data, format: String) {
        self.data = SubtitleText.utf8(data)
        self.format = format.lowercased()
    }
}

/// A place subtitles come from.
public protocol SubtitleSource: Sendable {
    var name: String { get }
    func search(_ query: SubtitleQuery) async throws -> [SubtitleResult]
    /// `query` is the search that found it (a season pack needs the episode number).
    func download(_ result: SubtitleResult, for query: SubtitleQuery) async throws -> SubtitleFile
}

public enum SubtitleSourceError: Error, Sendable, Equatable {
    case needsKey
    case rejected(String)
    case notFound
    case quotaReached
    case unreadable

    public var userMessage: String {
        switch self {
        case .needsKey: "needs an API key (Settings ▸ Subtitles)"
        case .rejected(let why): why
        case .notFound: "the file isn’t there any more"
        case .quotaReached: "today’s download limit is reached"
        case .unreadable: "the file couldn’t be read"
        }
    }
}

/// Searches every source at once and ranks the results: files made for exactly this one
/// first, then by the order of the wanted languages, then by popularity.
public enum SubtitleSearch {
    public struct Outcome: Sendable {
        public var results: [SubtitleResult]
        /// Sources that failed, with why ("Subdl: needs an API key").
        public var problems: [(source: String, message: String)]
    }

    public static func search(_ query: SubtitleQuery, sources: [any SubtitleSource]) async -> Outcome {
        var results: [SubtitleResult] = []
        var problems: [(String, String)] = []
        await withTaskGroup(of: (String, Result<[SubtitleResult], Error>).self) { group in
            for source in sources {
                group.addTask {
                    do { return (source.name, .success(try await source.search(query))) }
                    catch { return (source.name, .failure(error)) }
                }
            }
            for await (name, outcome) in group {
                switch outcome {
                case .success(let found): results += found
                case .failure(let error):
                    let message = (error as? SubtitleSourceError)?.userMessage ?? "didn’t answer"
                    problems.append((name, message))
                }
            }
        }
        return Outcome(results: rank(results, languages: query.languages), problems: problems.sorted { $0.0 < $1.0 })
    }

    /// One source's answer, as it arrives (the fast sources fill the list first).
    public struct SourceAnswer: Sendable {
        public let source: String
        public let results: [SubtitleResult]
        public let problem: String?
    }

    public static func answers(_ query: SubtitleQuery, sources: [any SubtitleSource]) -> AsyncStream<SourceAnswer> {
        AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: SourceAnswer.self) { group in
                    for source in sources {
                        group.addTask {
                            do { return SourceAnswer(source: source.name, results: try await source.search(query), problem: nil) }
                            catch is CancellationError { return SourceAnswer(source: source.name, results: [], problem: nil) }
                            catch {
                                let message = (error as? SubtitleSourceError)?.userMessage ?? "didn’t answer"
                                return SourceAnswer(source: source.name, results: [], problem: message)
                            }
                        }
                    }
                    for await answer in group { continuation.yield(answer) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public static func rank(_ results: [SubtitleResult], languages: [String]) -> [SubtitleResult] {
        func languageOrder(_ r: SubtitleResult) -> Int { languages.firstIndex(of: r.language) ?? languages.count }
        return results.sorted {
            if $0.hashMatch != $1.hashMatch { return $0.hashMatch }
            if languageOrder($0) != languageOrder($1) { return languageOrder($0) < languageOrder($1) }
            return ($0.downloads ?? 0) > ($1.downloads ?? 0)
        }
    }
}

/// OpenSubtitles' file hash: the size plus the 64-bit little-endian word sums of the first and
/// last 64 KiB, as 16 hex digits. Callers fetch the two chunks (range requests for remote files).
public enum OpenSubtitlesHash {
    public static let chunk = 65_536

    public static func hash(size: Int64, head: Data, tail: Data) -> String? {
        guard head.count >= chunk, tail.count >= chunk else { return nil }
        var sum = UInt64(bitPattern: size)
        for data in [head.prefix(chunk), tail.suffix(chunk)] {
            data.withUnsafeBytes { raw in
                for i in stride(from: 0, to: chunk, by: 8) {
                    sum &+= raw.loadUnaligned(fromByteOffset: i, as: UInt64.self).littleEndian
                }
            }
        }
        return String(format: "%016llx", sum)
    }
}

/// Subtitle files arrive in whatever encoding their author used (Windows-1252, ISO-8859-x,
/// UTF-16…); the engine reads UTF-8.
public enum SubtitleText {
    public static func utf8(_ data: Data) -> Data {
        if String(data: data, encoding: .utf8) != nil { return data }
        var converted: NSString?
        var lossy = ObjCBool(false)
        let suggestions: [StringEncoding] = [.windowsCP1252, .isoLatin1, .windowsCP1250, .windowsCP1251, .utf16]
        let encoding = NSString.stringEncoding(for: data, encodingOptions: [
            .suggestedEncodingsKey: suggestions.map(\.rawValue), .useOnlySuggestedEncodingsKey: false,
        ], convertedString: &converted, usedLossyConversion: &lossy)
        guard encoding != 0, let text = converted as String? else { return data }
        return Data(text.utf8)
    }

    private typealias StringEncoding = String.Encoding
}

/// Picks the right file out of an archive: the episode's own file in a season pack, then
/// the first subtitle file.
public enum SubtitleArchive {
    static let formats = ["srt", "ass", "ssa", "vtt", "sub"]

    public static func pick(_ entries: [(name: String, data: Data)], season: Int?, episode: Int?) -> SubtitleFile? {
        let subtitles = entries.filter { formats.contains(($0.name as NSString).pathExtension.lowercased()) && !$0.name.hasPrefix("__MACOSX") }
        var chosen = subtitles.first
        if let season, let episode {
            let tags = [String(format: "s%02de%02d", season, episode), "\(season)x\(String(format: "%02d", episode))",
                        String(format: "e%02d", episode)]
            for tag in tags {
                if let match = subtitles.first(where: { $0.name.lowercased().contains(tag) }) { chosen = match; break }
            }
        }
        guard let chosen else { return nil }
        let ext = (chosen.name as NSString).pathExtension.lowercased()
        return SubtitleFile(data: chosen.data, format: ext == "ssa" ? "ass" : ext)
    }
}
