import Foundation
import Testing
@testable import MezzanineKit

@Suite struct IndexTests {
    /// Items from a captured page, with their own JSON (as the sync stores them).
    func entries(_ fixture: String) throws -> [(PlexMetadata, Data)] {
        let data = try DecodingTests.fixture(fixture)
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rows = try #require((root["MediaContainer"] as? [String: Any])?["Metadata"] as? [[String: Any]])
        return try rows.map { row in
            let json = try JSONSerialization.data(withJSONObject: row)
            return (try JSONDecoder().decode(PlexMetadata.self, from: json), json)
        }
    }

    @Test func upsertQueryAndDecode() throws {
        let index = try LibraryIndex()
        let movies = try entries("movies-page")
        try index.upsert(movies, section: "1")
        let all = try index.items(LibraryQuery(section: "1", kinds: ["movie"]))
        #expect(all.count == movies.count)
        // Title sort ignores leading articles.
        let titles = all.map(\.titleSort)
        #expect(titles == titles.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
        let decoded = try #require(all.first?.metadata())
        #expect(!decoded.media.isEmpty)
        #expect(decoded.ultraBlur != nil)
    }

    @Test func filtersAndSearch() throws {
        let index = try LibraryIndex()
        let movies = try entries("movies-page")
        try index.upsert(movies, section: "1")
        let first = try #require(movies.first?.0)
        if let genre = first.genres.first?.tag {
            var q = LibraryQuery(section: "1", kinds: ["movie"])
            q.genre = genre
            #expect(try index.items(q).contains { $0.ratingKey == first.ratingKey })
        }
        let word = String(first.title.split(separator: " ").first ?? "")
        let hits = try index.search(word)
        #expect(hits.contains { $0.ratingKey == first.ratingKey })
        var unwatched = LibraryQuery(section: "1", kinds: ["movie"])
        unwatched.unwatchedOnly = true
        #expect(try index.items(unwatched).allSatisfy { $0.viewCount == 0 })
    }

    @Test func pruneRemovesMissing() throws {
        let index = try LibraryIndex()
        let movies = try entries("movies-page")
        try index.upsert(movies, section: "1")
        let keep = Set(movies.prefix(1).map(\.0.ratingKey))
        try index.prune(section: "1", keeping: keep, kinds: ["movie"])
        #expect(try index.count(section: "1") == 1)
    }

    @Test func upsertKeepsCleanPoster() throws {
        let index = try LibraryIndex()
        let movies = try entries("movies-page")
        try index.upsert(movies, section: "1")
        let key = movies[0].0.ratingKey
        try index.setCleanPoster("/clean.jpg", for: key)
        try index.upsert(movies, section: "1")
        #expect(try index.item(key)?.cleanPosterPath == "/clean.jpg")
    }
}
