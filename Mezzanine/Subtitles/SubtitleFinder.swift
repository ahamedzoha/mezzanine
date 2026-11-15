import Foundation
import Observation
import MezzanineKit
import MezzaninePlayback

/// Find Subtitles: asks every source at once (Plex, OpenSubtitles, Subdl, Addic7ed), lists
/// what each finds as it answers, and loads the one chosen. Kept per title, so going back
/// to the list doesn't search again.
@MainActor @Observable
final class SubtitleFinder {
    private(set) var ratingKey: String?
    private(set) var results: [SubtitleResult] = []
    /// Sources still searching, in the order asked.
    private(set) var pending: [String] = []
    /// "Subdl" → "the Subdl API key was refused".
    private(set) var problems: [(source: String, message: String)] = []
    private(set) var downloading: String?
    /// Why the last choice didn't load.
    var failure: String?
    private(set) var languages: [String] = []
    /// How many sources the last search asked (0: every source is turned off).
    private(set) var sourceCount = 0
    /// When the list last re-sorted: a click just after lands on a row that moved under the
    /// pointer, so it's ignored.
    @ObservationIgnored private var reorderedAt = Date.distantPast

    @ObservationIgnored private var query: SubtitleQuery?
    @ObservationIgnored private var sources: [any SubtitleSource] = []
    @ObservationIgnored private var task: Task<Void, Never>?

    var isSearching: Bool { !pending.isEmpty }

    /// Starts a search for `item` unless one for it already ran (`again` forces it).
    func search(_ item: PlexMetadata, client: PlexServerClient?, localFile: URL?, settings: SubtitleSourceSettings, again: Bool = false) {
        let sources = settings.sources(client: client, ratingKey: item.ratingKey)
        if !again, ratingKey == item.ratingKey, languages == settings.languages,
           self.sources.map(\.name) == sources.map(\.name), task != nil { return }
        task?.cancel()
        ratingKey = item.ratingKey
        languages = settings.languages
        results = []
        problems = []
        failure = nil
        self.sources = sources
        sourceCount = sources.count
        pending = sources.map(\.name)
        let languages = settings.languages
        task = Task { [weak self] in
            let query = await Self.query(for: item, client: client, localFile: localFile, languages: languages)
            guard !Task.isCancelled else { return }
            self?.query = query
            for await answer in SubtitleSearch.answers(query, sources: sources) {
                guard let self, !Task.isCancelled else { return }
                let ranked = SubtitleSearch.rank(self.results + answer.results, languages: languages)
                if !self.results.isEmpty, ranked.prefix(self.results.count).map(\.id) != self.results.map(\.id) {
                    self.reorderedAt = Date()
                }
                self.results = ranked
                self.pending.removeAll { $0 == answer.source }
                if let problem = answer.problem { self.problems.append((answer.source, problem)) }
            }
        }
    }

    /// A chosen subtitle, added to the player (the caller selects it).
    struct Found {
        let trackID: Int
        /// Kept on this Mac.
        var savedEntry: String?
        /// Fetched by the server.
        var plexStream: Int?
    }

    /// Adds `result` to the player. Plex's own results are fetched by the server (every Plex
    /// app sees them); the rest are kept on this Mac for this title.
    func choose(_ result: SubtitleResult, current: PlexMetadata, client: PlexServerClient?, serverID: String?,
                player: MezzaninePlayer, isCurrent: @escaping () -> Bool = { true }) async -> Found? {
        guard downloading == nil, Date().timeIntervalSince(reorderedAt) > 0.35 else { return nil }
        downloading = result.id
        failure = nil
        defer { downloading = nil }
        do {
            if result.source == PlexSubtitleSource.sourceName {
                guard let client else { throw SubtitleSourceError.rejected("the server isn’t connected") }
                return try await chooseThroughPlex(result, current: current, client: client, player: player, isCurrent: isCurrent)
            } else {
                guard let query, let source = sources.first(where: { $0.name == result.source }) else { throw SubtitleSourceError.notFound }
                let file = try await source.download(result, for: query)
                guard let serverID else { throw SubtitleSourceError.unreadable }
                let (entry, url) = try SavedSubtitles.save(file, result: result, serverID: serverID, ratingKey: current.ratingKey)
                // Kept for its title either way; only shown if that title is still playing.
                guard isCurrent() else { return nil }
                let track = player.addExternalSubtitle(ExternalSubtitle(entry, url: url), headers: [:])
                return Found(trackID: track.id, savedEntry: entry.id)
            }
        } catch let error as SubtitleSourceError {
            failure = "\(result.source): \(error.userMessage)."
        } catch let error as PlexError {
            failure = error.userMessage
        } catch {
            failure = "Couldn’t load that subtitle."
        }
        return nil
    }

    private func chooseThroughPlex(_ result: SubtitleResult, current: PlexMetadata, client: PlexServerClient,
                                   player: MezzaninePlayer, isCurrent: () -> Bool) async throws -> Found? {
        let before = Set(current.media.flatMap { $0.parts.flatMap { $0.streams.map(\.id) } })
        try await client.downloadSubtitle(ratingKey: current.ratingKey, key: result.payload, codec: result.format,
                                          language: result.language, hearingImpaired: result.hearingImpaired,
                                          forced: result.forced, providerTitle: result.via)
        let fresh = try await client.metadata(current.ratingKey)
        guard let added = fresh.media.flatMap({ $0.parts.flatMap(\.streams) }).first(where: {
            $0.streamType == .subtitle && $0.key != nil && !before.contains($0.id)
        }), let key = added.key, let url = client.urls.subtitle(streamKey: key) else {
            throw SubtitleSourceError.rejected("the server saved it, but hasn’t listed it yet. Try again in a moment")
        }
        guard isCurrent() else { return nil }
        let track = player.addExternalSubtitle(ExternalSubtitle(url: url, name: added.label, language: added.languageCode,
                                                                format: added.codec, isForced: added.forced,
                                                                isHearingImpaired: added.hearingImpaired),
                                               headers: client.requestHeaders)
        return Found(trackID: track.id, plexStream: added.id)
    }

    // MARK: The query

    /// The title's identity (IDs from Plex's guids, the show's for episodes) and, when the
    /// file is reachable, its OpenSubtitles hash.
    static func query(for item: PlexMetadata, client: PlexServerClient?, localFile: URL?, languages: [String]) async -> SubtitleQuery {
        let isEpisode = item.kind == .episode
        let part = item.media.first?.parts.first
        var query = SubtitleQuery(kind: isEpisode ? .episode : .movie, title: item.title, year: item.year,
                                  imdbID: SubtitleQuery.id("imdb", in: item.externalGuids),
                                  tmdbID: SubtitleQuery.id("tmdb", in: item.externalGuids),
                                  showTitle: item.grandparentTitle, season: item.parentIndex, episode: item.index,
                                  fileName: part?.file.map { ($0 as NSString).lastPathComponent }, languages: languages)
        async let show: PlexMetadata? = {
            guard isEpisode, let client, let key = item.grandparentRatingKey else { return nil }
            return try? await client.metadata(key)
        }()
        async let hash: (String, Int64)? = fileHash(part: part, client: client, localFile: localFile)
        if let show = await show {
            query.showIMDbID = SubtitleQuery.id("imdb", in: show.externalGuids)
            query.showTVDbID = SubtitleQuery.id("tvdb", in: show.externalGuids)
        }
        if let (value, size) = await hash {
            query.fileHash = value
            query.fileSize = size
        }
        return query
    }

    private static func fileHash(part: PlexPart?, client: PlexServerClient?, localFile: URL?) async -> (String, Int64)? {
        let chunk = OpenSubtitlesHash.chunk
        if let localFile {
            return await Task.detached(priority: .utility) { () -> (String, Int64)? in
                guard let handle = try? FileHandle(forReadingFrom: localFile) else { return nil }
                defer { try? handle.close() }
                guard let size = try? handle.seekToEnd(), size >= UInt64(chunk * 2) else { return nil }
                try? handle.seek(toOffset: 0)
                guard let head = try? handle.read(upToCount: chunk) else { return nil }
                try? handle.seek(toOffset: size - UInt64(chunk))
                guard let tail = try? handle.read(upToCount: chunk),
                      let hash = OpenSubtitlesHash.hash(size: Int64(size), head: head, tail: tail) else { return nil }
                return (hash, Int64(size))
            }.value
        }
        guard let client, let key = part?.key, let size = part?.size, size >= Int64(chunk * 2) else { return nil }
        async let head = try? client.partBytes(key: key, offset: 0, length: chunk)
        async let tail = try? client.partBytes(key: key, offset: size - Int64(chunk), length: chunk)
        guard let head = await head, let tail = await tail,
              let hash = OpenSubtitlesHash.hash(size: size, head: head, tail: tail) else { return nil }
        return (hash, size)
    }
}
