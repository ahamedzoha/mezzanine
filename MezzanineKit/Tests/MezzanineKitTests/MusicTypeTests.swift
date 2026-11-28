import Foundation
import Testing
@testable import MezzanineKit

/// Music models and pure types. Fixtures are invented (public repo): no real artists, albums,
/// tracks or ids.
@Suite struct MusicModelTests {
    static func detail() throws -> [PlexMetadata] {
        try DecodingTests.container(MetadataContainer.self, "music-detail").metadata
    }

    @Test func artistAlbumTrackFieldsDecode() throws {
        let items = try Self.detail()
        let artist = try #require(items.first { $0.kind == .artist })
        #expect(artist.moods.map(\.tag) == ["Mellow", "Wistful"])
        #expect(artist.styles.map(\.tag) == ["Dream Pop"])
        #expect(artist.similar.map(\.tag) == ["Another Invented Band"])
        #expect(artist.location == ["/music/invented"])
        #expect(artist.countries.map(\.tag) == ["Exampleland"])
        #expect(artist.popularLeaves.map(\.ratingKey) == ["9003"])
        #expect(artist.mbid == "11111111-1111-1111-1111-111111111111")
        #expect(artist.userRating == 8.0)
        #expect(artist.isWatched == false)

        let album = try #require(items.first { $0.kind == .album })
        #expect(album.formats.map(\.tag) == ["Album"])
        #expect(album.subformats.map(\.tag) == ["Live"])
        #expect(album.studio == "Sample Records")
        #expect(AlbumType(album) == .live)
        // A partly played album is not "watched", whatever its counts say.
        #expect(album.isWatched == false)

        let track = try #require(items.first { $0.kind == .track })
        #expect(track.parentYear == 2019)
        #expect(track.parentStudio == "Sample Records")
        #expect(track.skipCount == 1)
        #expect(track.ratingCount == 1200)
        #expect(track.originalTitle == "Guest Singer")
    }

    @Test func streamLoudnessComesThroughAsNumbers() throws {
        let track = try #require(try Self.detail().first { $0.kind == .track })
        let streams = try #require(track.media.first?.parts.first?.streams)
        let audio = try #require(streams.first { $0.streamType == .audio })
        #expect(audio.samplingRate == 96_000)
        #expect(audio.bitDepth == 24)
        #expect(audio.gain == -3.10)
        #expect(audio.albumGain == -4.56)
        #expect(audio.peak == 0.635925)
        #expect(audio.albumPeak == 0.977112)
        #expect(audio.loudness == -19.04)
        #expect(audio.lra == 6.36)
        #expect(audio.startRamp?.hasPrefix("-51.00 0.00") == true)
        #expect(audio.endRamp?.hasSuffix("0.23 52.23;") == true)
        let lrc = try #require(streams.first { $0.codec == "lrc" })
        #expect(lrc.streamType == .lyrics)
        #expect(lrc.timed == true)
        #expect(lrc.provider == "com.plexapp.agents.lyricfind")
        let txt = try #require(streams.first { $0.codec == "txt" })
        #expect(txt.timed == nil)
        #expect(txt.key == "/library/streams/703")
    }

    @Test func listingNumbersThatArriveAsStrings() throws {
        let track = try #require(try DecodingTests.container(MetadataContainer.self, "music-listing").metadata.last)
        #expect(track.ratingCount == 1200)
    }

    @Test func queuedTrackReadsTheStreamAndTheTrackArtist() throws {
        let track = try #require(try Self.detail().first { $0.kind == .track })
        let queued = try #require(QueuedTrack(track))
        #expect(queued.artist == "Guest Singer")
        #expect(queued.album == "Invented Hours")
        #expect(queued.duration == 215)
        #expect(queued.partID == 601)
        #expect(queued.partKey == "/library/parts/601/1700000000/file.flac")
        #expect(queued.loudness.gain == -3.10)
        #expect(queued.quality?.caption == "FLAC · 24-bit · 96 kHz")
        #expect(queued.endLoudnessRamp.distance(reaching: -20.68) == 9.53)
        #expect(QueuedTrack(try #require(try Self.detail().first { $0.kind == .album })) == nil)
    }
}

@Suite struct MusicPureTypeTests {
    @Test func rampParsesPairsAndInterpolates() {
        let ramp = LoudnessRamp(parsing: "-51.00 0.00;-8.03 0.10;-2.90 34.90;0.49 84.10;")
        #expect(ramp.points.count == 4)
        #expect(ramp.points[1] == .init(db: -8.03, seconds: 0.10))
        #expect(ramp.distance(reaching: -8.03) == 0.10)
        // Halfway between -8.03 dB at 0.1 s and -2.90 dB at 34.9 s.
        let mid = try! #require(ramp.distance(reaching: -5.465))
        #expect(abs(mid - 17.5) < 0.01)
        #expect(ramp.distance(reaching: 3) == nil)
        #expect(ramp.level(at: 0) == -51)
        #expect(ramp.level(at: 1000) == 0.49)
        #expect(LoudnessRamp(parsing: nil).isEmpty)
        #expect(LoudnessRamp(parsing: "garbage;1;-3 x;-4.0 2.0").points == [.init(db: -4.0, seconds: 2.0)])
    }

    @Test func loudnessPlanModes() {
        let l = TrackLoudness(gain: -3, albumGain: -5, peak: 0.5, albumPeak: 0.9)
        #expect(LoudnessPlan(mode: .off).gain(for: l).gainDB == 0)
        #expect(LoudnessPlan(mode: .track).gain(for: l, inAlbumOrder: true).gainDB == -3)
        #expect(LoudnessPlan(mode: .album).gain(for: l).gainDB == -5)
        #expect(LoudnessPlan(mode: .auto).gain(for: l, inAlbumOrder: true).gainDB == -5)
        #expect(LoudnessPlan(mode: .auto).gain(for: l, inAlbumOrder: false).gainDB == -3)
        #expect(LoudnessPlan(mode: .track, preAmpDB: 2).gain(for: l).gainDB == -1)
    }

    @Test func peakGuardKeepsBoostsFromClipping() {
        // +6 dB on a 0.9 peak would clip: the guard stops at 0.98 / 0.9 (about +0.74 dB).
        let l = TrackLoudness(gain: 6, peak: 0.9)
        let guarded = LoudnessPlan(mode: .track).gain(for: l)
        #expect(guarded.limitedByPeak)
        #expect(abs(guarded.gainDB - 20 * log10(0.98 / 0.9)) < 1e-9)
        #expect(guarded.linear * 0.9 <= 0.98 + 1e-9)
        let unguarded = LoudnessPlan(mode: .track, peakGuard: false).gain(for: l)
        #expect(unguarded.gainDB == 6)
        // A cut is never limited.
        #expect(LoudnessPlan(mode: .track).gain(for: TrackLoudness(gain: -8, peak: 1.2)).limitedByPeak == false)
    }

    @Test func unmeasuredTracksGetOnlyThePreAmpAndFallbacksCross() {
        #expect(LoudnessPlan(mode: .track).gain(for: TrackLoudness()).gainDB == 0)
        #expect(LoudnessPlan(mode: .track, preAmpDB: 1.5).gain(for: TrackLoudness()).gainDB == 1.5)
        #expect(LoudnessPlan(mode: .track).gain(for: TrackLoudness(albumGain: -4)).gainDB == -4)
        #expect(LoudnessPlan(mode: .album).gain(for: TrackLoudness(gain: -2)).gainDB == -2)
        #expect(LoudnessPlan(mode: .track, minimumDB: -10).gain(for: TrackLoudness(gain: -30)).gainDB == -10)
    }

    @Test func albumTypeFromFormatAndSubformat() {
        #expect(AlbumType(formats: ["Album"], subformats: []) == .album)
        #expect(AlbumType(formats: ["EP"], subformats: []) == .ep)
        #expect(AlbumType(formats: ["Single"], subformats: []) == .single)
        #expect(AlbumType(formats: ["Album"], subformats: ["Live"]) == .live)
        #expect(AlbumType(formats: ["Album"], subformats: ["Soundtrack"]) == .soundtrack)
        #expect(AlbumType(formats: ["Album"], subformats: ["Compilation", "Live"]) == .compilation)
        #expect(AlbumType(formats: ["Single"], subformats: ["Remix"]) == .remix)
        #expect(AlbumType(formats: [], subformats: ["Unknown Thing"]) == .album)
        #expect(AlbumType(formats: ["Album"], subformats: []).sectionTitle == "Albums")
    }

    @Test func audioQualityCaptionsAndTiers() {
        let hi = AudioQuality(codec: "flac", bitDepth: 24, samplingRate: 96_000)
        #expect(hi.caption == "FLAC · 24-bit · 96 kHz")
        #expect(hi.tier == .hiRes)
        let cd = AudioQuality(codec: "FLAC", bitDepth: 16, samplingRate: 44_100)
        #expect(cd.caption == "FLAC · 16-bit · 44.1 kHz")
        #expect(cd.tier == .lossless)
        #expect(AudioQuality(codec: "flac", bitDepth: 24, samplingRate: 44_100).tier == .hiRes)
        #expect(AudioQuality(codec: "flac", bitDepth: 24, samplingRate: 88_200).caption == "FLAC · 24-bit · 88.2 kHz")
        #expect(AudioQuality(codec: "flac", bitDepth: 24, samplingRate: 176_400).caption.hasSuffix("176.4 kHz"))
        let mp3 = AudioQuality(codec: "mp3", samplingRate: 44_100, bitrate: 320)
        #expect(mp3.caption == "MP3 · 320 kbps")
        #expect(mp3.tier == .lossy)
        #expect(AudioQuality(codec: "eac3", channels: 6, bitrate: 640).caption == "E-AC-3 · 640 kbps · 5.1")
        #expect(AudioQuality(codec: "vorbis").tier == .lossy)
        #expect(AudioQuality(codec: "alac", bitDepth: 16, samplingRate: 44_100).tier == .lossless)
    }

    @Test func scrobbleRules() {
        #expect(ScrobbleRules.threshold(duration: 20) == nil)
        #expect(ScrobbleRules.threshold(duration: 30) == nil)
        #expect(ScrobbleRules.threshold(duration: 120) == 60)
        #expect(ScrobbleRules.threshold(duration: 900) == 240)
        #expect(ScrobbleRules.counts(played: 59, duration: 120) == false)
        #expect(ScrobbleRules.counts(played: 60, duration: 120))
        #expect(ScrobbleRules.counts(played: 240, duration: 1200))
        #expect(ScrobbleRules.counts(played: 100, duration: 25) == false)
        #expect(ScrobbleRules.isNowPlayingEligible(duration: 31))
    }

    @Test func lrcParsesStampsTagsAndOffsets() throws {
        let text = """
        [ar:Invented Artist]
        [offset:500]
        [00:12.00] First invented line
        [00:05.50]Opening words
        [00:30.00][01:00.25] Repeated hook
        [00:40.00]
        no stamp here
        """
        let lyrics = try #require(LRC.parse(text))
        #expect(lyrics.isTimed)
        #expect(lyrics.lines.map(\.text) == ["Opening words", "First invented line", "Repeated hook", "", "Repeated hook"])
        #expect(lyrics.lines.map { $0.start! } == [5.0, 11.5, 29.5, 39.5, 59.75])
        #expect(lyrics.lineIndex(at: 4) == nil)
        #expect(lyrics.lineIndex(at: 12) == 1)
        #expect(lyrics.lineIndex(at: 100) == 4)
        #expect(LRC.parse("just words\nmore words") == nil)
        let plain = try #require(LRC.plain("one\n\ntwo"))
        #expect(plain.isTimed == false)
        #expect(plain.lines.count == 3)
        #expect(plain.lineIndex(at: 3) == nil)
        #expect(LRC.plain("  \n ") == nil)
    }

    @Test func lyricsAnswersDecodeEmptyAsNil() throws {
        // What the owner's server sends today: an empty Lyrics element.
        #expect(PlexServerClient.decodeLyrics(Data(#"{"MediaContainer":{"size":1,"Lyrics":[{}]}}"#.utf8)) == nil)
        #expect(PlexServerClient.decodeLyrics(Data(#"{"MediaContainer":{"size":1,"Lyrics":[{"provider":"x","Line":[{}]}]}}"#.utf8)) == nil)
        #expect(PlexServerClient.decodeLyrics(Data()) == nil)
        let json = """
        {"MediaContainer":{"size":1,"Lyrics":[{"provider":"example","timed":"1","Line":[
          {"startOffset":1500,"Span":[{"startOffset":1500,"text":"Invented "},{"text":"words"}]},
          {"startOffset":4000,"text":"Second line"}]}]}}
        """
        let l = try #require(PlexServerClient.decodeLyrics(Data(json.utf8)))
        #expect(l.isTimed)
        #expect(l.provider == "example")
        #expect(l.lines == [LyricLine(start: 1.5, text: "Invented words"), LyricLine(start: 4, text: "Second line")])
        let lrcText = try #require(PlexServerClient.decodeLyrics(Data("[00:01.00] hello".utf8)))
        #expect(lrcText.lines.first == LyricLine(start: 1, text: "hello"))
    }

    @Test func batchingAndDetailQuery() {
        let keys = (1...250).map(String.init)
        let chunks = keys.chunked(into: PlexServerClient.musicBatchSize)
        #expect(chunks.map(\.count) == [100, 100, 50])
        let names = PlexServerClient.musicDetailQuery(popularLeaves: true).map(\.name)
        #expect(names == ["includeLoudnessRamps", "includeGuids", "includePopularLeaves"])
        #expect(PlexServerClient.musicDetailQuery(popularLeaves: false).map(\.name) == ["includeLoudnessRamps", "includeGuids"])
    }

    @Test func historyRowsDecode() throws {
        let json = """
        {"MediaContainer":{"Metadata":[{"historyKey":"/status/sessions/history/7","ratingKey":"9003","key":"/library/metadata/9003",
        "title":"Quiet Arithmetic","type":"track","viewedAt":1700000500,"accountID":1,"deviceID":2,
        "grandparentTitle":"The Example Band","parentTitle":"Invented Hours","grandparentKey":"/library/metadata/9001","parentKey":"/library/metadata/9002","librarySectionID":6}]}}
        """
        let c = try JSONDecoder().decode(MediaContainerEnvelope<HistoryProbe>.self, from: Data(json.utf8)).container
        let row = try #require(c.rows.first)
        #expect(row.kind == .track)
        #expect(row.grandparentRatingKey == "9001")
        #expect(row.parentRatingKey == "9002")
        #expect(row.viewedAt == Date(timeIntervalSince1970: 1_700_000_500))
    }

    struct HistoryProbe: Decodable {
        let rows: [PlexHistoryEntry]
        enum CodingKeys: String, CodingKey { case rows = "Metadata" }
    }
}

@Suite struct MusicRouteTests {
    @Test func routesByCodecAndChannels() {
        #expect(MusicRoute.choose(codec: "flac", channels: 2) == .native)
        #expect(MusicRoute.choose(codec: "FLAC", channels: 1) == .native)
        #expect(MusicRoute.choose(codec: "mp3", channels: 2) == .native)
        #expect(MusicRoute.choose(codec: "aac", channels: 2) == .native)
        #expect(MusicRoute.choose(codec: "alac", channels: 2) == .native)
        #expect(MusicRoute.choose(codec: "vorbis", channels: 2) == .engine)
        #expect(MusicRoute.choose(codec: "wmav2", channels: 2) == .engine)
        #expect(MusicRoute.choose(codec: "eac3", channels: 6) == .engine)
        #expect(MusicRoute.choose(codec: "flac", channels: 6) == .engine)
        #expect(MusicRoute.choose(codec: nil, channels: 2) == .engine)
        #expect(MusicRoute.choose(codec: "flac", channels: 2, nativeFailed: true) == .engine)
    }
}
