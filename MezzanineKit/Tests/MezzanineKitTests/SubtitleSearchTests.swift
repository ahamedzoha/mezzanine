import Foundation
import Testing
@testable import MezzanineKit

@Suite struct SubtitleSearchTests {
    /// OpenSubtitles' published test vector: breakdance.avi (12 909 756 bytes) hashes to
    /// 8e245d9679d31e12. Rebuilt here from a synthetic file with the same arithmetic.
    @Test func hashSumsSizeAndBothChunks() {
        let chunk = OpenSubtitlesHash.chunk
        let head = Data(repeating: 0, count: chunk)
        let tail = Data(repeating: 0, count: chunk)
        #expect(OpenSubtitlesHash.hash(size: 131_072, head: head, tail: tail) == "0000000000020000")

        var one = Data(repeating: 0, count: chunk)
        one[0] = 1
        #expect(OpenSubtitlesHash.hash(size: 0, head: one, tail: one) == "0000000000000002")

        var high = Data(repeating: 0, count: chunk)
        for i in 0..<8 { high[i] = 0xFF }
        // Wraps: 0xFFFF_FFFF_FFFF_FFFF + 0xFFFF_FFFF_FFFF_FFFF + 2 = 0
        #expect(OpenSubtitlesHash.hash(size: 2, head: high, tail: high) == "0000000000000000")
        #expect(OpenSubtitlesHash.hash(size: 1, head: Data(count: 10), tail: tail) == nil)
    }

    @Test func ranksHashMatchThenLanguageThenPopularity() {
        func r(_ id: String, _ lang: String, hash: Bool = false, downloads: Int? = nil) -> SubtitleResult {
            SubtitleResult(id: id, source: "T", language: lang, release: id, hearingImpaired: false,
                           hashMatch: hash, downloads: downloads, payload: id)
        }
        let ranked = SubtitleSearch.rank([r("fr-pop", "fr", downloads: 900), r("en-low", "en", downloads: 3),
                                          r("fr-hash", "fr", hash: true), r("en-pop", "en", downloads: 500)],
                                         languages: ["en", "fr"])
        #expect(ranked.map(\.id) == ["fr-hash", "en-pop", "en-low", "fr-pop"])
    }

    @Test func readsStoredZipAndPicksTheEpisode() throws {
        let zip = Self.storedZip([("Show.S01E01.srt", "one"), ("Show.S01E02.srt", "two"), ("readme.txt", "x")])
        let entries = try ZipReader.entries(zip)
        #expect(entries.map(\.name) == ["Show.S01E01.srt", "Show.S01E02.srt", "readme.txt"])
        let file = SubtitleArchive.pick(entries, season: 1, episode: 2)
        #expect(file.map { String(decoding: $0.data, as: UTF8.self) } == "two")
        #expect(file?.format == "srt")
        #expect(SubtitleArchive.pick(entries, season: nil, episode: nil).map { String(decoding: $0.data, as: UTF8.self) } == "one")
    }

    @Test func convertsLatin1ToUTF8() {
        let latin1 = "Ça va? Très bien.".data(using: .windowsCP1252)!
        #expect(String(data: latin1, encoding: .utf8) == nil)
        #expect(String(data: SubtitleText.utf8(latin1), encoding: .utf8) == "Ça va? Très bien.")
    }

    @Test func languageCodes() {
        #expect(SubtitleLanguage.code("pt-BR") == "pt")
        #expect(SubtitleLanguage.code("eng") == "en")
        #expect(SubtitleLanguage.code("English") == "en")
        #expect(SubtitleLanguage.code("EN") == "en")
        #expect(SubtitleLanguage.code("BR_PT") == "pt")
        #expect(OpenSubtitlesSource.imdbNumber("tt0111161") == "111161")
        #expect(OpenSubtitlesSource.languages(["pt", "en"]) == ["en", "pt-br", "pt-pt"])
        #expect(SubtitleQuery.id("imdb", in: ["tmdb://1", "imdb://tt42"]) == "tt42")
    }

    /// A ZIP with stored (uncompressed) entries, as `zip -0` writes it.
    static func storedZip(_ files: [(String, String)]) -> Data {
        var out = Data(), central = Data()
        func le16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
        func le32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
        for (name, text) in files {
            let body = Data(text.utf8), nameData = Data(name.utf8), offset = out.count
            out += le32(0x0403_4B50) + le16(10) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0)
            out += le32(body.count) + le32(body.count) + le16(nameData.count) + le16(0) + nameData + body
            central += le32(0x0201_4B50) + le16(20) + le16(10) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0)
            central += le32(body.count) + le32(body.count) + le16(nameData.count) + le16(0) + le16(0) + le16(0) + le16(0)
            central += le32(0) + le32(offset) + nameData
        }
        let start = out.count
        out += central
        out += le32(0x0605_4B50) + le16(0) + le16(0) + le16(files.count) + le16(files.count) + le32(central.count) + le32(start) + le16(0)
        return out
    }
}

@Suite struct SubtitleArchiveFixtureTests {
    /// A season pack written by `zip -9` (deflated entries).
    @Test func inflatesDeflatedEntries() throws {
        let url = try #require(Bundle.module.url(forResource: "subtitle-season", withExtension: "zip", subdirectory: "Fixtures"))
        let entries = try ZipReader.entries(try Data(contentsOf: url))
        #expect(entries.count == 2)
        let file = try #require(SubtitleArchive.pick(entries, season: 2, episode: 3))
        let text = String(decoding: file.data, as: UTF8.self)
        #expect(text.hasPrefix("1\n00:00:01,000"))
        #expect(text.contains("Line number 199 of the episode."))
    }
}
