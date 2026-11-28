import Foundation
import GRDB
import Testing
@testable import MezzanineKit

@Suite struct MusicIndexTests {
    func rows(_ fixture: String) throws -> [(PlexMetadata, Data)] {
        let root = try #require(JSONSerialization.jsonObject(with: DecodingTests.fixture(fixture)) as? [String: Any])
        let list = try #require((root["MediaContainer"] as? [String: Any])?["Metadata"] as? [[String: Any]])
        return try list.map { row in
            let json = try JSONSerialization.data(withJSONObject: row)
            return (try JSONDecoder().decode(PlexMetadata.self, from: json), json)
        }
    }

    func query(_ sort: LibraryQuery.Sort = .title, kinds: [String] = ["track"]) -> LibraryQuery {
        LibraryQuery(section: "6", kinds: kinds, sort: sort)
    }

    @Test func musicSectionsSyncThreeLevels() throws {
        let sections = try DecodingTests.container(DirectoryContainer<PlexLibrarySection>.self, "sections").directories
        let music = try #require(sections.first { $0.kind == .artist })
        let types = LibrarySync.types(for: music)
        #expect(types.map(\.type) == [8, 9, 10])
        #expect(types.map(\.kind) == ["artist", "album", "track"])
        #expect(LibrarySync.types(for: sections.first { $0.kind == .movie }!).map(\.kind) == ["movie"])
    }

    @Test func listingFillsTheMusicColumns() throws {
        let index = try LibraryIndex()
        try index.upsert(try rows("music-listing"), section: "6")
        let track = try #require(try index.item("9003"))
        #expect(track.parentTitle == "Invented Hours")
        #expect(track.grandparentTitle == "The Example Band")
        #expect(track.originalTitle == "Guest Singer")
        #expect(track.studio == "Sample Records")
        #expect(track.ratingCount == 1200)
        #expect(track.skipCount == 1)
        #expect(track.year == 2019)
        #expect(track.mbid == "33333333-3333-3333-3333-333333333333")
        #expect(track.credits == "The Example Band Invented Hours Guest Singer Sample Records")
        #expect(track.audioCodec == "flac")
        #expect(track.gainDB == nil)
        let album = try #require(try index.item("9002"))
        #expect(album.studio == "Sample Records")
        #expect(album.albumType == nil)   // needs the detail pass
    }

    @Test func externalIDsAreSearchable() throws {
        let index = try LibraryIndex()
        try index.upsert(try rows("music-listing"), section: "6")
        let hit = try index.items(scheme: "mbid", value: "22222222-2222-2222-2222-222222222222")
        #expect(hit.map(\.ratingKey) == ["9002"])
        #expect(try index.items(scheme: "mbid", value: "11111111-1111-1111-1111-111111111111", kinds: ["album"]).isEmpty)
        // Plex re-matched the album: the old id goes.
        var (meta, json) = try rows("music-listing")[1]
        var object = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
        object["Guid"] = [["id": "mbid://44444444-4444-4444-4444-444444444444"]]
        json = try JSONSerialization.data(withJSONObject: object)
        meta = try JSONDecoder().decode(PlexMetadata.self, from: json)
        try index.upsert([(meta, json)], section: "6")
        #expect(try index.items(scheme: "mbid", value: "22222222-2222-2222-2222-222222222222").isEmpty)
        #expect(try index.items(scheme: "mbid", value: "44444444-4444-4444-4444-444444444444").count == 1)
    }

    @Test func detailPassFillsOnlyWhatIsNewOrChanged() throws {
        let index = try LibraryIndex()
        try index.upsert(try rows("music-listing"), section: "6")
        #expect(Set(try index.musicKeysNeedingDetail(section: "6")) == ["9001", "9002", "9003"])
        try index.storeMusicDetail(try rows("music-detail"))
        #expect(try index.musicKeysNeedingDetail(section: "6").isEmpty)

        let track = try #require(try index.item("9003"))
        #expect(track.audioCodec == "flac")
        #expect(track.bitDepth == 24)
        #expect(track.samplingRate == 96_000)
        #expect(track.gainDB == -3.10)
        #expect(track.albumGainDB == -4.56)
        #expect(track.peak == 0.635925)
        #expect(track.loudness == -19.04)
        #expect(track.hasLyrics)
        #expect(track.userRating == 6.0)
        let album = try #require(try index.item("9002"))
        #expect(album.albumType == "live")
        #expect(album.moods == "|Mellow|")
        #expect(album.styles == "|Dream Pop|")
        let artist = try #require(try index.item("9001"))
        #expect(artist.moods == "|Mellow|Wistful|")
        #expect(artist.countries == "|Exampleland|")

        // The detail JSON is kept apart; the item keeps its own listing JSON.
        let full = try #require(try index.musicDetail("9003"))
        #expect(full.media.first?.parts.first?.streams.contains { $0.streamType == .audio } == true)
        #expect(track.metadata()?.media.first?.parts.first?.streams.isEmpty == true)

        // The server changes the album: only it needs detail again.
        var (meta, json) = try rows("music-listing")[1]
        var object = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
        object["updatedAt"] = 1_700_009_999
        json = try JSONSerialization.data(withJSONObject: object)
        meta = try JSONDecoder().decode(PlexMetadata.self, from: json)
        try index.upsert([(meta, json)], section: "6")
        #expect(try index.musicKeysNeedingDetail(section: "6") == ["9002"])
    }

    @Test func aListingRefreshKeepsStoredDetailAndCleanPoster() throws {
        let index = try LibraryIndex()
        let listing = try rows("music-listing")
        try index.upsert(listing, section: "6")
        try index.storeMusicDetail(try rows("music-detail"))
        try index.setCleanPoster("/clean/path", for: "9002")
        try index.updateProgress(ratingKey: "9003", viewOffset: 0, viewCount: 4)
        // Watch-state refresh: the listing again, which has no streams and no moods.
        try index.upsert(listing, section: "6")
        let track = try #require(try index.item("9003"))
        #expect(track.gainDB == -3.10)
        #expect(track.hasLyrics)
        #expect(track.viewCount == 3)   // the listing's value wins, as before
        let album = try #require(try index.item("9002"))
        #expect(album.moods == "|Mellow|")
        #expect(album.albumType == "live")
        #expect(album.cleanPosterPath == "/clean/path")
        #expect(try index.musicKeysNeedingDetail(section: "6").isEmpty)
    }

    @Test func searchFindsTracksByArtistAlbumAndLabel() throws {
        let index = try LibraryIndex()
        try index.upsert(try rows("music-listing"), section: "6")
        let kinds = ["artist", "album", "track"]
        #expect(try index.search("quiet arith", kinds: kinds).map(\.ratingKey) == ["9003"])
        #expect(Set(try index.search("Sample Records", kinds: kinds).map(\.ratingKey)) == ["9002", "9003"])
        #expect(Set(try index.search("example band", kinds: kinds).map(\.ratingKey)) == ["9001", "9002", "9003"])
        #expect(try index.search("guest singer", kinds: kinds).map(\.ratingKey) == ["9003"])
    }

    @Test func newSorts() throws {
        let index = try LibraryIndex()
        func track(_ key: String, _ title: String, artist: String, album: String, plays: Int, year: Int, viewed: Int, disc: Int = 1, n: Int = 1) throws -> (PlexMetadata, Data) {
            let object: [String: Any] = ["ratingKey": key, "key": "/library/metadata/\(key)", "type": "track", "title": title,
                                         "grandparentTitle": artist, "parentTitle": album, "viewCount": plays, "parentYear": year,
                                         "lastViewedAt": viewed, "parentIndex": disc, "index": n, "updatedAt": 1]
            let json = try JSONSerialization.data(withJSONObject: object)
            return (try JSONDecoder().decode(PlexMetadata.self, from: json), json)
        }
        try index.upsert([
            try track("1", "Alpha", artist: "Zed", album: "First", plays: 1, year: 2001, viewed: 300),
            try track("2", "Beta", artist: "Abe", album: "Second", plays: 9, year: 1999, viewed: 100),
            try track("3", "Gamma", artist: "Abe", album: "Second", plays: 5, year: 1999, viewed: 200, n: 2),
            try track("4", "Delta", artist: "Abe", album: "Another", plays: 0, year: 2010, viewed: 0),
        ], section: "6")
        func order(_ sort: LibraryQuery.Sort) throws -> [String] { try index.items(query(sort)).map(\.ratingKey) }
        #expect(try order(.mostPlayed) == ["2", "3", "1", "4"])
        #expect(try order(.artist) == ["4", "2", "3", "1"])
        #expect(try order(.album) == ["4", "1", "2", "3"])
        #expect(try order(.year) == ["4", "1", "2", "3"])
        #expect(try order(.recentlyPlayed) == ["1", "3", "2", "4"])
        #expect(LibraryQuery.Sort.mostPlayed.label == "Most Played")
    }

    @Test func albumsAndArtistsNeverReadAsWatched() throws {
        let index = try LibraryIndex()
        let listing = try rows("music-listing")
        try index.upsert(listing, section: "6")
        // The album has 1 of 2 tracks played, the artist has plays: still no watched state.
        for sort in [LibraryQuery.Sort.title] {
            var watched = LibraryQuery(section: "6", kinds: ["artist", "album", "track"], sort: sort)
            watched.watchedOnly = true
            #expect(try index.items(watched).map(\.ratingKey) == ["9003"])   // the played track only
            var unwatched = watched
            unwatched.watchedOnly = false
            unwatched.unwatchedOnly = true
            #expect(try index.items(unwatched).isEmpty)
            var progress = watched
            progress.watchedOnly = false
            progress.inProgressOnly = true
            #expect(try index.items(progress).isEmpty)
        }
        let album = try #require(try index.item("9002"))
        #expect(album.isWatched == false)
        #expect(try #require(album.metadata()).isWatched == false)
    }

    @Test func musicFilters() throws {
        let index = try LibraryIndex()
        try index.upsert(try rows("music-listing"), section: "6")
        try index.storeMusicDetail(try rows("music-detail"))
        var byParent = query(kinds: ["track"])
        byParent.parentRatingKey = "9002"
        #expect(try index.items(byParent).map(\.ratingKey) == ["9003"])
        var byArtist = query(kinds: ["album"])
        byArtist.parentRatingKey = "9001"
        #expect(try index.items(byArtist).map(\.ratingKey) == ["9002"])
        var live = query(kinds: ["album"])
        live.albumType = "live"
        #expect(try index.count(live) == 1)
        live.albumType = "single"
        #expect(try index.count(live) == 0)
        var mellow = query(kinds: ["album", "artist"])
        mellow.mood = "Mellow"
        #expect(try index.count(mellow) == 2)
        #expect(mellow.hasFilters)
        #expect(try index.moods(section: "6", kinds: ["album", "artist"]).first?.0 == "Mellow")
    }

    // MARK: v3 → v4

    /// A database as v3 left it, with a film, an episode and a music track already stored.
    func v3Database() throws -> (String, DatabasePool) {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("v3-\(UUID().uuidString).sqlite").path
        let pool = try DatabasePool(path: path)
        try LibraryIndex.migrator.migrate(pool, upTo: "v3")
        func insert(_ db: Database, _ key: String, _ kind: String, _ title: String, _ object: [String: Any]) throws {
            let json = try JSONSerialization.data(withJSONObject: object)
            try db.execute(sql: "INSERT INTO item (ratingKey, section, kind, title, titleSort, json) VALUES (?, ?, ?, ?, ?, ?)",
                           arguments: [key, kind == "track" ? "6" : "1", kind, title, title, json])
        }
        try pool.write { db in
            try insert(db, "1", "movie", "Invented Film", ["ratingKey": "1", "studio": "Made Up Pictures", "userRating": 8,
                                                          "Guid": [["id": "imdb://tt0000001"], ["id": "tmdb://11"]]])
            try insert(db, "2", "episode", "Pilot", ["ratingKey": "2", "parentTitle": "Season 1", "grandparentTitle": "Invented Show"])
            try insert(db, "3", "track", "Quiet Arithmetic", ["ratingKey": "3", "parentTitle": "Invented Hours",
                                                              "grandparentTitle": "The Example Band", "originalTitle": "Guest Singer",
                                                              "parentStudio": "Sample Records", "skipCount": 2, "ratingCount": 40,
                                                              "Guid": [["id": "mbid://33333333-3333-3333-3333-333333333333"]]])
        }
        return (path, pool)
    }

    @Test func migrationBackfillsFromStoredJSON() throws {
        let (path, old) = try v3Database()
        try old.close()
        let index = try LibraryIndex(path: path)
        let film = try #require(try index.item("1"))
        #expect(film.studio == "Made Up Pictures")
        #expect(film.userRating == 8)
        #expect(film.credits == "")   // video search is unchanged
        let episode = try #require(try index.item("2"))
        #expect(episode.grandparentTitle == "Invented Show")
        #expect(episode.credits == "")
        let track = try #require(try index.item("3"))
        #expect(track.mbid == "33333333-3333-3333-3333-333333333333")
        #expect(track.skipCount == 2)
        #expect(track.ratingCount == 40)
        #expect(track.credits == "The Example Band Invented Hours Guest Singer Sample Records")
        #expect(try index.items(scheme: "imdb", value: "tt0000001").map(\.ratingKey) == ["1"])
        #expect(try index.items(scheme: "tmdb", value: "11").map(\.ratingKey) == ["1"])
        #expect(try index.items(scheme: "mbid", value: "33333333-3333-3333-3333-333333333333").map(\.ratingKey) == ["3"])
        // The rebuilt search index finds old rows by title and new ones by credits.
        #expect(try index.search("invented film", kinds: ["movie"]).map(\.ratingKey) == ["1"])
        #expect(try index.search("Sample Records", kinds: ["track"]).map(\.ratingKey) == ["3"])
        // New rows keep the triggers working.
        try index.upsert(try rows("music-listing"), section: "6")
        #expect(try index.search("quiet arith", kinds: ["track"]).count == 2)
    }

    @Test func deletingAnItemTakesItsDetailAndIdsWithIt() throws {
        let index = try LibraryIndex()
        let listing = try rows("music-listing")
        try index.upsert(listing, section: "6")
        try index.storeMusicDetail(try rows("music-detail"))
        try index.prune(section: "6", keeping: ["9001"], kinds: ["album", "track"])
        #expect(try index.musicDetail("9003") == nil)
        #expect(try index.items(scheme: "mbid", value: "33333333-3333-3333-3333-333333333333").isEmpty)
        #expect(try index.musicDetail("9001") != nil)
    }
}

/// Opt-in: migrates a copy of a real index (`MEZZANINE_INDEX_COPY=/path/to/copy.sqlite`) and
/// reports the timings. Never point it at the original: opening it migrates it.
@Suite struct IndexCopyMigrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MEZZANINE_INDEX_COPY"] != nil))
    func migratesACopy() throws {
        let path = try #require(ProcessInfo.processInfo.environment["MEZZANINE_INDEX_COPY"])
        let clock = ContinuousClock()
        var index: LibraryIndex?
        let took = try clock.measure { index = try LibraryIndex(path: path) }
        let index2 = try #require(index)
        let count = try index2.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM item") ?? 0 }
        let ids = try index2.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM external_id") ?? 0 }
        let withStudio = try index2.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM item WHERE studio IS NOT NULL") ?? 0 }
        let fts = try index2.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM item_ft") ?? 0 }
        let hit = try clock.measure { _ = try? index2.search("the", kinds: ["movie", "show", "episode"]) }
        print("INDEXCOPY migrate=\(took) items=\(count) fts=\(fts) external_id=\(ids) studio=\(withStudio) search=\(hit)")
        #expect(fts == count)
        let tables = try index2.pool.read { try String.fetchAll($0, sql: "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('external_id','musicDetail')") }
        #expect(tables.count == 2)
        let integrity = try index2.pool.read { try String.fetchOne($0, sql: "PRAGMA integrity_check") }
        #expect(integrity == "ok")
    }
}
