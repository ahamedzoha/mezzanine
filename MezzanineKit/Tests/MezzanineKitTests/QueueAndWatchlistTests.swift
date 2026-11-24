import Foundation
import GRDB
import Testing
@testable import MezzanineKit

@Suite("Play queue")
struct PlayQueueTests {
    func e(_ key: String) -> PlayQueue.Entry { .init(ratingKey: key, title: "T\(key)", detail: "") }
    func keys(_ q: PlayQueue) -> [String] { q.entries.map(\.ratingKey) }

    @Test func orderAndNoRepeats() {
        var q = PlayQueue()
        q.add([e("1"), e("2")])
        q.playNext([e("3"), e("4")])
        #expect(keys(q) == ["3", "4", "1", "2"])
        // A title already waiting moves instead of playing twice.
        q.playNext([e("2")])
        #expect(keys(q) == ["2", "3", "4", "1"])
        q.add([e("3"), e("3")])
        #expect(keys(q) == ["2", "4", "1", "3"])
        q.started("4")
        #expect(keys(q) == ["2", "1", "3"])
        q.move(q.entries[2].id, by: -1)
        q.move(q.entries[0].id, by: -1)
        #expect(keys(q) == ["2", "3", "1"])
        q.remove(q.entries[0].id)
        #expect(q.first?.ratingKey == "3")
        q.replace(with: (0..<900).map { e("n\($0)") })
        #expect(q.entries.count == PlayQueue.limit)
        q.clear()
        #expect(q.isEmpty)
    }

    @Test func survivesSaving() throws {
        var q = PlayQueue()
        q.add([e("1"), e("2")])
        #expect(try JSONDecoder().decode(PlayQueue.self, from: JSONEncoder().encode(q)) == q)
    }

    @Test func shuffle() throws {
        func item(_ key: String, _ kind: String, season: Int = 1, views: Int = 0) throws -> PlexMetadata {
            try JSONDecoder().decode(PlexMetadata.self, from: Data(#"{"ratingKey":"\#(key)","type":"\#(kind)","title":"x","parentIndex":\#(season),"viewCount":\#(views)}"#.utf8))
        }
        var rng = SystemRandomNumberGenerator()
        let episodes = try (1...20).map { try item("\($0)", "episode", views: $0 > 10 ? 1 : 0) } + [item("s", "episode", season: 0)]
        let all = PlayQueue.shuffled(episodes + episodes, unwatchedOnly: false, using: &rng)
        #expect(Set(all.map(\.ratingKey)) == Set((1...20).map(String.init)) && all.count == 20)
        #expect(Set(PlayQueue.shuffled(episodes, unwatchedOnly: true, using: &rng).map(\.ratingKey)) == Set((1...10).map(String.init)))
        #expect(try PlayQueue.shuffled([item("s", "episode", season: 0)], unwatchedOnly: false, using: &rng).count == 1)
        #expect(try PlayQueue.shuffled([item("w", "movie", views: 1)], unwatchedOnly: true, using: &rng).map(\.ratingKey) == ["w"])
        #expect(try PlayQueue.shuffled([item("c", "collection"), item("a", "season")], unwatchedOnly: false, using: &rng).isEmpty)
    }
}

@Suite("Watchlist")
struct WatchlistTests {
    @Test func decodesAPage() throws {
        let json = Data(#"""
        {"MediaContainer":{"librarySectionID":"watchlist","offset":0,"size":3,"totalSize":"7","Metadata":[
          {"ratingKey":"5d7768303c3c2a001fbcd0d8","guid":"plex://movie/5d7768303c3c2a001fbcd0d8","type":"movie","title":"27 Dresses","year":2008,"thumb":"https://metadata-static.plex.tv/x.jpg"},
          {"ratingKey":"5d9c0000000000000000aaaa","guid":"plex://show/5d9c0000000000000000aaaa","type":"show","title":"A Show","userState":false},
          {"ratingKey":"bad"}]}}
        """#.utf8)
        let page = try PlexDiscover.decode(json)
        #expect(page.total == 7)
        #expect(page.items.prefix(2).map(\.title) == ["27 Dresses", "A Show"])
        #expect(page.items[0].discoverID == "5d7768303c3c2a001fbcd0d8" && page.items[0].isDiscoverOnly)
        #expect(throws: PlexError.self) { try PlexDiscover.decode(Data("<html>".utf8)) }
    }

    @Test func idsComeOnlyFromPlexGuids() throws {
        func id(_ guid: String, _ kind: String = "movie") throws -> String? {
            try JSONDecoder().decode(PlexMetadata.self, from: Data(#"{"ratingKey":"12","type":"\#(kind)","title":"x","guid":"\#(guid)"}"#.utf8)).discoverID
        }
        #expect(try id("plex://movie/abc") == "abc")
        #expect(try id("plex://show/abc", "show") == "abc")
        #expect(try id("plex://show/abc") == nil)
        #expect(try id("plex://episode/abc", "episode") == nil)
        #expect(try id("com.plexapp.agents.imdb://tt1?lang=en") == nil)
        #expect(try id("local://12") == nil)
        #expect(try id("plex://movie/") == nil)
    }

    @Test func indexFindsTitlesByGuid() throws {
        let index = try LibraryIndex()
        let movies = try IndexTests().entries("movies-page")
        try index.upsert(movies, section: "1")
        let wanted = try #require(movies.first { $0.0.guid != nil }?.0)
        #expect(try index.items(guids: [wanted.guid!, "plex://movie/none"]).map(\.ratingKey) == [wanted.ratingKey])
        #expect(try index.items(guids: []).isEmpty)
        #expect(try index.spotlightTitles(sections: ["1"]).count == movies.count)
        #expect(try index.spotlightTitles(sections: ["9"]).isEmpty)
    }

    /// An index made before guids were kept gets them from its own JSON, without a full sync.
    @Test func migrationFillsGuids() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("v2-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let pool = try DatabasePool(path: path)
        try LibraryIndex.migrator.migrate(pool, upTo: "v2")
        let json = Data(#"{"ratingKey":"7","type":"movie","title":"Old","guid":"plex://movie/abc"}"#.utf8)
        try pool.write { db in
            try db.execute(sql: "INSERT INTO item (ratingKey, section, kind, title, titleSort, viewCount, viewOffset, isHDR, genres, people, collections, summary, json) VALUES ('7','1','movie','Old','Old',0,0,0,'','','','',?)", arguments: [json])
        }
        try pool.close()
        let index = try LibraryIndex(path: path)
        #expect(try index.items(guids: ["plex://movie/abc"]).map(\.ratingKey) == ["7"])
        #expect(try index.item("7")?.metadata()?.title == "Old")
    }
}
