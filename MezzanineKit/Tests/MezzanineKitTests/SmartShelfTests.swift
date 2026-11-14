import Foundation
import Testing
@testable import MezzanineKit

@Suite struct SmartShelfTests {
    let base = IndexTests()

    func filled() throws -> (LibraryIndex, [PlexMetadata]) {
        let index = try LibraryIndex()
        let movies = try base.entries("movies-page")
        try index.upsert(movies, section: "1")
        return (index, movies.map(\.0))
    }

    @Test func genreDecadeAndExclusion() throws {
        let (index, movies) = try filled()
        let first = try #require(movies.first { !$0.genres.isEmpty && $0.year != nil })
        let genre = try #require(first.genres.first?.tag)
        let decade = (first.year! / 10) * 10
        let rule = SmartRule(conditions: [.genre(genre, excluded: false), .decade(decade)], limit: 0)
        let hits = try index.items(rule)
        #expect(hits.contains { $0.ratingKey == first.ratingKey })
        #expect(hits.allSatisfy { $0.genres.contains("|\(genre)|") && ($0.year ?? 0) / 10 * 10 == decade })
        #expect(try index.count(rule) == hits.count)
        let without = try index.items(SmartRule(conditions: [.genre(genre, excluded: true)], limit: 0))
        #expect(!without.contains { $0.ratingKey == first.ratingKey })
    }

    @Test func peopleAndCollectionsMatchWholeNames() throws {
        let (index, movies) = try filled()
        if let movie = movies.first(where: { !$0.roles.isEmpty }), let actor = movie.roles.first?.tag {
            #expect(try index.items(SmartRule(conditions: [.person(actor)], limit: 0)).contains { $0.ratingKey == movie.ratingKey })
            // A fragment of the name is not the person.
            let fragment = String(actor.prefix(max(1, actor.count - 2)))
            #expect(try !index.items(SmartRule(conditions: [.person(fragment)], limit: 0)).contains { $0.ratingKey == movie.ratingKey })
        }
        if let movie = movies.first(where: { !$0.collections.isEmpty }), let name = movie.collections.first?.tag {
            #expect(try index.items(SmartRule(conditions: [.collection(name)], limit: 0)).contains { $0.ratingKey == movie.ratingKey })
            #expect(try index.collectionNames(sections: ["1"]).contains(name))
        }
    }

    @Test func limitSortAndIncompleteConditions() throws {
        let (index, movies) = try filled()
        let limited = try index.items(SmartRule(sort: .title, limit: 3))
        #expect(limited.count == min(3, movies.count))
        // An empty person matches everything rather than nothing.
        #expect(try index.count(SmartRule(conditions: [.person("")])) == movies.count)
        #expect(try index.count(SmartRule(sections: ["nope"])) == 0)
    }

    @Test func summariesAndCodableLayout() throws {
        let rule = SmartRule(conditions: [.watch(.unwatched), .genre("Comedy", excluded: false), .decade(1990)])
        #expect(rule.summary == "Unwatched · Comedy · 1990s")
        var layout = HomeLayout(scopes: [HomeLayout.mainScope: HomeLayout.defaultHome])
        layout.scopes["1"] = [ShelfSpec(title: "90s comedies", source: .smart(rule))]
        let data = try JSONEncoder().encode(layout)
        #expect(try JSONDecoder().decode(HomeLayout.self, from: data) == layout)
    }
}
