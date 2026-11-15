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

@Suite("Search ranking")
struct SearchRankingTests {
    private func row(_ key: String, _ type: String, _ title: String, summary: String = "") throws -> (PlexMetadata, Data) {
        let json = try JSONSerialization.data(withJSONObject: ["ratingKey": key, "type": type, "title": title, "summary": summary])
        return (try JSONDecoder().decode(PlexMetadata.self, from: json), json)
    }

    @Test func titleStartsBeatLessonsAndSummaries() throws {
        let index = try LibraryIndex()
        try index.upsert([try row("10", "movie", "1.Recap-Architecture"), try row("11", "movie", "003 Testing Architecture")], section: "3")
        try index.upsert([try row("20", "show", "Archer (2009)"), try row("21", "show", "Bob's Burgers", summary: "An arch rival")], section: "2")
        try index.upsert([try row("30", "movie", "The Departed", summary: "South Boston")], section: "1")
        let arch = try index.search("arch", demotedSections: ["3"]).map(\.title)
        #expect(arch.first == "Archer (2009)")
        #expect(arch.firstIndex(of: "Bob's Burgers")! > arch.firstIndex(of: "1.Recap-Architecture")!)
        let south = try index.search("south", demotedSections: ["3"]).map(\.title)
        #expect(south == ["The Departed"])
    }
}

@Suite("New episodes")
struct NewEpisodeTests {
    private func row(_ fields: [String: Any]) throws -> (PlexMetadata, Data) {
        let json = try JSONSerialization.data(withJSONObject: fields)
        return (try JSONDecoder().decode(PlexMetadata.self, from: json), json)
    }

    @Test func onlyShowsBeingWatched() throws {
        let index = try LibraryIndex()
        let now = 2_000_000_000.0
        try index.upsert([
            try row(["ratingKey": "1", "type": "show", "title": "Severance", "leafCount": 19, "viewedLeafCount": 18, "lastViewedAt": now - 86_400]),
            try row(["ratingKey": "2", "type": "show", "title": "Never Started", "leafCount": 10, "viewedLeafCount": 0]),
            try row(["ratingKey": "3", "type": "show", "title": "Abandoned", "leafCount": 10, "viewedLeafCount": 3, "lastViewedAt": now - 3 * 365 * 86_400]),
        ], section: "2")
        try index.upsert([
            try row(["ratingKey": "11", "type": "episode", "title": "Cold Harbor", "grandparentRatingKey": "1", "parentIndex": 2, "index": 10, "addedAt": now - 60]),
            try row(["ratingKey": "12", "type": "episode", "title": "Old one", "grandparentRatingKey": "1", "parentIndex": 2, "index": 9, "addedAt": now - 900_000, "viewCount": 1]),
            try row(["ratingKey": "21", "type": "episode", "title": "Pilot", "grandparentRatingKey": "2", "parentIndex": 1, "index": 1, "addedAt": now - 60]),
            try row(["ratingKey": "31", "type": "episode", "title": "Return", "grandparentRatingKey": "3", "parentIndex": 2, "index": 1, "addedAt": now - 60]),
        ], section: "2")
        let found = try index.newEpisodes(since: now - 3600, now: now)
        #expect(found.map(\.show.title) == ["Severance"])
        #expect(found.first?.episodes.map(\.title) == ["Cold Harbor"])
    }
}
