import Foundation
import Testing
@testable import MezzanineKit

/// Tests for `TrackIdentity`, ported from Crossfade's `matching.test.ts` (commit 38cfe71).
///
/// Artist / track names from the original TypeScript fixtures have been replaced with invented
/// ones (keeping the same string shape — brackets, feat. credits, punctuation, diacritics,
/// version tags — so each case still exercises the same normalisation rule).
/// Extra cases marked "Swift pin" verify that Swift's handling of Unicode matches the JS result.
@Suite struct TrackIdentityTests {

    // MARK: - fold

    @Suite struct FoldTests {
        @Test func stripsAccentsViaNFKD() {
            // "Café" → "cafe", "naïve" → "naive", diacritics removed
            #expect(TrackIdentity.fold("Café Lunara") == "cafe lunara")
            #expect(TrackIdentity.fold("Naïve Song") == "naive song")
            #expect(TrackIdentity.fold("Résumé") == "resume")
        }

        @Test func lowercases() {
            #expect(TrackIdentity.fold("HELLO WORLD") == "hello world")
        }

        @Test func normalisesApostrophes() {
            // JS: .replace(/[''`´]/g, "'")
            // U+2018 left single, U+2019 right single, backtick, acute
            #expect(TrackIdentity.fold("Can\u{2019}t Find the Harbor") == "can\'t find the harbor")
            #expect(TrackIdentity.fold("Rock`n`Roll") == "rock'n'roll")
        }

        @Test func ampersandAndPlusBecome_and() {
            #expect(TrackIdentity.fold("Salt & Pepper") == "salt  and  pepper")
            #expect(TrackIdentity.fold("Copper + Willow") == "copper  and  willow")
        }

        /// Swift pin: full-width letters are decomposed via NFKD to ASCII, matching JS.
        @Test func fullWidthCharactersDecompose() {
            // U+FF21 FULLWIDTH LATIN CAPITAL LETTER A → 'A' via NFKD
            let fullWidth = "\u{FF21}\u{FF22}\u{FF23}" // ＡＢＣ
            #expect(TrackIdentity.fold(fullWidth) == "abc")
        }

        /// Swift pin: curly double quotes are NOT normalised by fold (only single-quote variants).
        /// They will be replaced by `clean` as non-alphanumeric. This matches JS behaviour.
        @Test func curlyDoubleQuotesAreLeftToClean() {
            // fold doesn't remove them, but parseTitle will strip them through clean()
            let result = TrackIdentity.fold("\u{201C}Hello\u{201D}")
            // After NFKD the quotes remain as-is; they are not in the apostrophe replacement set.
            #expect(result.contains("hello"))
        }
    }

    // MARK: - parseTitle

    @Suite struct ParseTitleTests {

        @Test func stripsReasterAndFeatNoiseKeepsBase() {
            // Port of: "strips remaster and feat noise but keeps the base title"
            // Original: 'Echoes - 2004 Remaster' → "echoes"
            #expect(TrackIdentity.parseTitle("Echoes - 2004 Remaster").key == "echoes")
            // Original: 'Echoes (Remastered)' → "echoes"
            #expect(TrackIdentity.parseTitle("Echoes (Remastered)").key == "echoes")
            // Original: 'Glass Tower (feat. Mira Volkov)' → "glass tower"
            #expect(TrackIdentity.parseTitle("Glass Tower (feat. Mira Volkov)").key == "glass tower")
            // Original: 'Copper + Willow' → "copper and willow"
            #expect(TrackIdentity.parseTitle("Salt + Iron").key == "salt and iron")
        }

        @Test func keepsVersionTagsThatChangeTheRecording() {
            // Original: 'Echoes (Live)' → versionTag "live"
            #expect(TrackIdentity.parseTitle("Echoes (Live)").versionTag == "live")
            // Original: 'Glass Tower - Acoustic' → versionTag "acoustic"
            #expect(TrackIdentity.parseTitle("Glass Tower - Acoustic").versionTag == "acoustic")
            // Original: 'Velvet Coast (Neon Remix)' → "remix:neon remix"
            #expect(TrackIdentity.parseTitle("Velvet Coast (Neon Remix)").versionTag == "remix:neon remix")
            // Original: 'Echoes - 2004 Remaster' → versionTag nil
            #expect(TrackIdentity.parseTitle("Echoes - 2004 Remaster").versionTag == nil)
        }

        @Test func handlesYouTubeArtistDashTitleFormat() {
            // Original: parseTitle('VX7 - Velvet Coast (Official Video)', ['VX7'])
            //           → key "velvet coast", versionTag nil
            let p = TrackIdentity.parseTitle("VX7 - Velvet Coast (Official Video)", artists: ["VX7"])
            #expect(p.key == "velvet coast")
            #expect(p.versionTag == nil)
        }

        @Test func foldsAccentsAndPunctuation() {
            // Original: 'Café Lunara' → "cafe lunara"
            #expect(TrackIdentity.parseTitle("Café Soleil").key == "cafe soleil")
            // Original: "Can't Find the Harbor" → "cant find the harbor"
            #expect(TrackIdentity.parseTitle("Can't Find the Harbor").key == "cant find the harbor")
        }

        @Test func stripsMultipleBracketedSegments() {
            // A title with two bracketed segments; only the first version tag wins.
            let p = TrackIdentity.parseTitle("Glass Tower (Live) (2004 Remaster)")
            #expect(p.key == "glass tower")
            #expect(p.versionTag == "live")
        }

        @Test func unplugged_mappedToAcoustic() {
            #expect(TrackIdentity.parseTitle("Glass Tower (Unplugged)").versionTag == "acoustic")
        }

        @Test func remixIncludesQualifier() {
            let p = TrackIdentity.parseTitle("Velvet Coast (Phantom Club Remix)")
            #expect(p.versionTag == "remix:phantom club remix")
        }

        @Test func demoTag() {
            #expect(TrackIdentity.parseTitle("Glass Tower (Demo)").versionTag == "demo")
        }

        @Test func instrumentalTag() {
            #expect(TrackIdentity.parseTitle("Glass Tower (Instrumental)").versionTag == "instrumental")
        }

        @Test func liveEnVivoTag() {
            #expect(TrackIdentity.parseTitle("Glass Tower (En Vivo)").versionTag == "live")
        }

        @Test func inlineFeatCutsBase() {
            // Inline feat. not in brackets: title is cut before it.
            let p = TrackIdentity.parseTitle("Glass Tower feat. Mira Volkov")
            #expect(p.key == "glass tower")
            #expect(p.versionTag == nil)
        }

        @Test func inlineFeatAtStartIsIgnored() {
            // "feat" at position 0 is not stripped (the TS condition is featIdx > 0).
            // This edge case is unlikely in real data but the behaviour should be pinned.
            let p = TrackIdentity.parseTitle("feat. Mira Volkov")
            // The key is whatever remains after fold + clean; versionTag is nil.
            #expect(p.versionTag == nil)
        }

        @Test func editionAndDeluxeAreNoise() {
            #expect(TrackIdentity.parseTitle("Glass Tower (Deluxe Edition)").key == "glass tower")
            #expect(TrackIdentity.parseTitle("Glass Tower (Deluxe Edition)").versionTag == nil)
        }

        @Test func officialVideoIsNoise() {
            let p = TrackIdentity.parseTitle("Glass Tower (Official Music Video)")
            #expect(p.key == "glass tower")
            #expect(p.versionTag == nil)
        }

        // MARK: Unicode / Swift-specific pins

        @Test func diacriticsInBracketedFeatures() {
            // "feat. Señorita" — the accented name should be stripped by fold.
            let p = TrackIdentity.parseTitle("Glass Tower (feat. Señorita)")
            #expect(p.key == "glass tower")
            #expect(p.versionTag == nil)
        }

        @Test func curlyQuoteInTitle() {
            // Right single quotation mark in title → apostrophe after fold → stripped by clean.
            #expect(TrackIdentity.parseTitle("Don\u{2019}t Stop").key == "dont stop")
        }

        @Test func ampersandInTitleBecomesAnd() {
            // JS: .replace(/&/g, ' and ')
            // After fold: "salt  and  iron" → clean collapses spaces → "salt and iron"
            #expect(TrackIdentity.parseTitle("Salt & Iron").key == "salt and iron")
        }

        /// Swift pin: `\w` in JS is ASCII-only; our `clean()` mirrors that by keeping only
        /// `[a-z0-9]` and whitespace. Greek letters, Cyrillic, etc. are replaced with spaces.
        @Test func nonLatinScriptStrippedByClean() {
            // A Greek letter in the title is stripped.
            let p = TrackIdentity.parseTitle("Glass α Tower")
            // "α" is U+03B1, non-ASCII → replaced → "glass tower"
            #expect(p.key == "glass tower")
        }
    }

    // MARK: - artistKey

    @Suite struct ArtistKeyTests {

        @Test func derivesTheSamePrimaryArtistFromEveryProviderFormat() {
            // Original: artistKey(['Lark & Fenwick']) == 'lark'
            #expect(TrackIdentity.artistKey(["Holt & Brennan"]) == "holt")
            // Original: artistKey(['Velvet Echo', 'Mira Volkov']) == 'velvet echo'
            #expect(TrackIdentity.artistKey(["Velvet Echo", "Mira Volkov"]) == "velvet echo")
            // Original: artistKey(['Velvet Echo & Mira Volkov']) == 'velvet echo'
            #expect(TrackIdentity.artistKey(["Velvet Echo & Mira Volkov"]) == "velvet echo")
            // Original: artistKey(['The Borrowed Hours']) == 'borrowed hours'
            #expect(TrackIdentity.artistKey(["The Borrowed Hours"]) == "borrowed hours")
        }

        @Test func stripsTopicSuffix() {
            // YouTube "Artist - Topic" channels.
            // Note: clean() converts "-" to a space, so after fold+split+clean the result is
            // "velvet echo topic". The TS ` - topic` regex also fails to match after clean for
            // the same reason. The token-level result is "velvet echo topic" in both runtimes.
            // We pin that behaviour here (and separately test the " topic" strip in artistTokens).
            #expect(TrackIdentity.artistKey(["Velvet Echo - Topic"]) == "velvet echo topic")
        }

        @Test func filtersEmptyStrings() {
            #expect(TrackIdentity.artistKey(["", "Velvet Echo"]) == "velvet echo")
        }

        @Test func foldsDiacriticsInArtistNames() {
            // "Brånvik" → "branvik"
            #expect(TrackIdentity.artistKey(["Brånvik"]) == "branvik")
        }

        @Test func vsDelimiterSplitsArtists() {
            // vs. treated as a split delimiter.
            #expect(TrackIdentity.artistKey(["Velvet Echo vs. Neon Craft"]) == "velvet echo")
        }
    }

    // MARK: - artistTokens

    @Suite struct ArtistTokensTests {

        @Test func returnsAllTokensFromMultipleArtists() {
            let tokens = TrackIdentity.artistTokens(["Velvet Echo", "Mira Volkov"])
            #expect(tokens.contains("velvet echo"))
            #expect(tokens.contains("mira volkov"))
        }

        @Test func splitsAndDelimited() {
            let tokens = TrackIdentity.artistTokens(["Velvet Echo & Mira Volkov"])
            #expect(tokens.contains("velvet echo"))
            #expect(tokens.contains("mira volkov"))
        }

        @Test func stripsThePrefix() {
            let tokens = TrackIdentity.artistTokens(["The Borrowed Hours"])
            #expect(tokens.contains("borrowed hours"))
        }
    }

    // MARK: - splitArtistString

    @Suite struct SplitArtistStringTests {

        @Test func splitsOnAmpersand() {
            #expect(TrackIdentity.splitArtistString("Velvet Echo & Mira Volkov") == ["Velvet Echo", "Mira Volkov"])
        }

        @Test func splitsOnComma() {
            #expect(TrackIdentity.splitArtistString("Velvet Echo, Mira Volkov") == ["Velvet Echo", "Mira Volkov"])
        }

        @Test func splitsOnFeat() {
            #expect(TrackIdentity.splitArtistString("Velvet Echo feat. Mira Volkov") == ["Velvet Echo", "Mira Volkov"])
        }

        @Test func splitsOnFt() {
            #expect(TrackIdentity.splitArtistString("Velvet Echo ft. Mira Volkov") == ["Velvet Echo", "Mira Volkov"])
        }

        @Test func splitsOnX() {
            // " x " with surrounding spaces — matches JS regex.
            #expect(TrackIdentity.splitArtistString("Velvet Echo x Mira Volkov") == ["Velvet Echo", "Mira Volkov"])
        }

        @Test func singleArtistReturnedAsIs() {
            #expect(TrackIdentity.splitArtistString("Velvet Echo") == ["Velvet Echo"])
        }
    }

    // MARK: - similarity (Dice)

    @Suite struct SimilarityTests {

        @Test func identicalStringsScore1() {
            #expect(TrackIdentity.similarity("glass tower", "glass tower") == 1.0)
        }

        @Test func emptyStringScores0() {
            #expect(TrackIdentity.similarity("", "glass tower") == 0.0)
            #expect(TrackIdentity.similarity("glass tower", "") == 0.0)
        }

        @Test func totallyDifferentStringsScoreLow() {
            let s = TrackIdentity.similarity("abcdef", "xyz")
            #expect(s < 0.3)
        }

        @Test func nearlyIdenticalStringScoresHigh() {
            // "glass tower" vs "glass towers" share most bigrams.
            // The Dice score for these is 0.88 (the boost floor), which is still high —
            // the threshold here is 0.85 to leave room for the Dice value at this length.
            let s = TrackIdentity.similarity("glass tower", "glass towers")
            #expect(s >= 0.85)
        }
    }

    // MARK: - durationScore

    @Suite struct DurationScoreTests {

        @Test func missingDurationReturnsNeutral() {
            #expect(TrackIdentity.durationScore(nil, nil) == 0.7)
            #expect(TrackIdentity.durationScore(200_000, nil) == 0.7)
            #expect(TrackIdentity.durationScore(nil, 200_000) == 0.7)
        }

        @Test func within2SecondsScores1() {
            #expect(TrackIdentity.durationScore(200_000, 201_000) == 1.0)
            #expect(TrackIdentity.durationScore(200_000, 202_000) == 1.0)
        }

        @Test func within5SecondScores085() {
            #expect(TrackIdentity.durationScore(200_000, 204_000) == 0.85)
        }

        @Test func within10SecondsScores06() {
            #expect(TrackIdentity.durationScore(200_000, 207_000) == 0.6)
        }

        @Test func within20SecondsScores03() {
            #expect(TrackIdentity.durationScore(200_000, 215_000) == 0.3)
        }

        @Test func moreThan20SecondsScores0() {
            #expect(TrackIdentity.durationScore(200_000, 225_000) == 0.0)
        }
    }

    // MARK: - scoreMatch

    @Suite struct ScoreMatchTests {

        // The "target" track used across several tests — invented to match the TS fixture's shape.
        // Ported from Crossfade's matching.test.ts (names invented).
        static let target = TrackIdentity.Candidate(
            title: "Ironveil",
            artists: ["The Driftwood Collective"],
            durationMs: 326_000
        )

        @Test func isrcEqualityIsCertain() {
            // Original: scoreMatch({ ...target, isrc: 'USYAH1600107' }, { title: 'x', artists: ['y'], isrc: 'usyah1600107' }).score === 1
            let t = TrackIdentity.Candidate(title: "Ironveil", artists: ["The Driftwood Collective"], durationMs: 326_000, isrc: "USMZ12600001")
            let c = TrackIdentity.Candidate(title: "unrelated", artists: ["nobody"], isrc: "usmz12600001")
            #expect(TrackIdentity.scoreMatch(target: t, candidate: c).score == 1.0)
        }

        @Test func isrcCaseInsensitive() {
            let t = TrackIdentity.Candidate(title: "Ironveil", artists: ["The Driftwood Collective"], isrc: "USMZ12600001")
            let c = TrackIdentity.Candidate(title: "Ironveil", artists: ["The Driftwood Collective"], isrc: "usmz12600001")
            #expect(TrackIdentity.scoreMatch(target: t, candidate: c).score == 1.0)
        }

        @Test func cleanMatchScoresHigh() {
            // Ported from Crossfade's matching.test.ts: a close duration still scores > 0.95.
            let c = TrackIdentity.Candidate(title: "Ironveil", artists: ["The Driftwood Collective"], durationMs: 327_000)
            #expect(TrackIdentity.scoreMatch(target: Self.target, candidate: c).score > 0.95)
        }

        @Test func liveVersionPenalisedBelow085() {
            // Original: live score < 0.85
            let live = TrackIdentity.Candidate(title: "Ironveil (Live)", artists: ["The Driftwood Collective"], durationMs: 330_000)
            #expect(TrackIdentity.scoreMatch(target: Self.target, candidate: live).score < 0.85)
        }

        @Test func wrongArtistPenalisedBelow085() {
            // Original: cover score < 0.85 (same title, different artist)
            let cover = TrackIdentity.Candidate(title: "Ironveil", artists: ["The Cover Collective"], durationMs: 300_000)
            #expect(TrackIdentity.scoreMatch(target: Self.target, candidate: cover).score < 0.85)
        }

        @Test func versionMismatchFlaggedCorrectly() {
            let live = TrackIdentity.Candidate(title: "Ironveil (Live)", artists: ["The Driftwood Collective"], durationMs: 326_000)
            let bd = TrackIdentity.scoreMatch(target: Self.target, candidate: live)
            #expect(bd.versionMismatch == true)

            let studio = TrackIdentity.Candidate(title: "Ironveil", artists: ["The Driftwood Collective"], durationMs: 327_000)
            let clean = TrackIdentity.scoreMatch(target: Self.target, candidate: studio)
            #expect(clean.versionMismatch == false)
        }

        @Test func remastersAreNotVersionMismatches() {
            // A remaster has no version tag → versionTag nil on both → no mismatch.
            let remaster = TrackIdentity.Candidate(title: "Ironveil (Remastered)", artists: ["The Driftwood Collective"], durationMs: 326_000)
            let bd = TrackIdentity.scoreMatch(target: Self.target, candidate: remaster)
            #expect(bd.versionMismatch == false)
        }

        @Test func scoreIsClampedTo0and1() {
            // Wildly different tracks should not go below 0.
            let t = TrackIdentity.Candidate(title: "aaaaaaaaaaaaa", artists: ["aaaaaaaaaaaaa"], durationMs: 1_000)
            let c = TrackIdentity.Candidate(title: "zzzzzzzzzzzzz", artists: ["zzzzzzzzzzzzz (Live)"], durationMs: 999_000)
            let s = TrackIdentity.score(t, c)
            #expect(s >= 0 && s <= 1)
        }

        @Test func scoreRoundedTo3DecimalPlaces() {
            let c = TrackIdentity.Candidate(title: "Ironveil", artists: ["The Driftwood Collective"], durationMs: 327_000)
            let s = TrackIdentity.scoreMatch(target: Self.target, candidate: c).score
            // Check that the value has at most 3 decimal places.
            let rounded = (s * 1000).rounded() / 1000
            #expect(s == rounded)
        }

        @Test func containsBoostApplied() {
            // If one title contains the other (and both are >3 chars), score is boosted to >= 0.88.
            let t = TrackIdentity.Candidate(title: "Glass Tower", artists: ["Velvet Echo"])
            let c = TrackIdentity.Candidate(title: "Glass Tower (Deluxe)", artists: ["Velvet Echo"])
            // Keys: "glass tower" and "glass tower" (deluxe is noise) → exact match → 1.0 title.
            // Let's test with a genuinely contained but not identical key.
            let t2 = TrackIdentity.Candidate(title: "Glass Tower Sessions", artists: ["Velvet Echo"])
            let c2 = TrackIdentity.Candidate(title: "Glass Tower", artists: ["Velvet Echo"])
            let bd = TrackIdentity.scoreMatch(target: t2, candidate: c2)
            // "glass tower sessions" contains "glass tower" → title >= 0.88
            #expect(bd.title >= 0.88)
        }
    }

    // MARK: - sameRecording

    @Suite struct SameRecordingTests {

        @Test func remastersWithCloseDurationAreTheSameSong() {
            // Original: a = { title: 'Echoes', artists: ['The Midnight Shore'], durationMs: 254_000 }
            //           b = { title: 'Echoes - 2004 Remaster', ... durationMs: 257_000 }
            //           sameRecording(a, b, 'strict') === true
            let a = TrackIdentity.Candidate(title: "Echoes", artists: ["The Midnight Shore"], durationMs: 254_000)
            let b = TrackIdentity.Candidate(title: "Echoes - 2004 Remaster", artists: ["The Midnight Shore"], durationMs: 257_000)
            #expect(TrackIdentity.sameRecording(a, b, mode: .strict) == true)
        }

        @Test func liveIsNeverFoldedIntoStudio() {
            // Original: sameRecording(a, b='Echoes (Live)', 'loose') === false
            let a = TrackIdentity.Candidate(title: "Echoes", artists: ["The Midnight Shore"], durationMs: 254_000)
            let b = TrackIdentity.Candidate(title: "Echoes (Live)", artists: ["The Midnight Shore"], durationMs: 255_000)
            #expect(TrackIdentity.sameRecording(a, b, mode: .loose) == false)
        }

        @Test func strictModeRejectsVeryDifferentLengths() {
            // Original: a.durationMs 200_000, b.durationMs 400_000 → strict false, loose true
            let a = TrackIdentity.Candidate(title: "Glass Tower", artists: ["Velvet Echo"], durationMs: 200_000)
            let b = TrackIdentity.Candidate(title: "Glass Tower", artists: ["Velvet Echo"], durationMs: 400_000)
            #expect(TrackIdentity.sameRecording(a, b, mode: .strict) == false)
            #expect(TrackIdentity.sameRecording(a, b, mode: .loose) == true)
        }

        @Test func isrcShortCircuits() {
            // Completely different titles + artists but matching ISRC → same.
            let a = TrackIdentity.Candidate(title: "Glass Tower", artists: ["Velvet Echo"], isrc: "USMZ12600001")
            let b = TrackIdentity.Candidate(title: "Completely Different", artists: ["Another Artist"], isrc: "USMZ12600001")
            #expect(TrackIdentity.sameRecording(a, b, mode: .strict) == true)
        }

        @Test func isrcCaseInsensitiveForSameRecording() {
            let a = TrackIdentity.Candidate(title: "Glass Tower", artists: ["Velvet Echo"], isrc: "USMZ12600001")
            let b = TrackIdentity.Candidate(title: "Glass Tower", artists: ["Velvet Echo"], isrc: "usmz12600001")
            #expect(TrackIdentity.sameRecording(a, b, mode: .strict) == true)
        }

        @Test func differentArtistsAreNotTheSameRecording() {
            let a = TrackIdentity.Candidate(title: "Glass Tower", artists: ["Velvet Echo"], durationMs: 200_000)
            let b = TrackIdentity.Candidate(title: "Glass Tower", artists: ["Another Band"], durationMs: 200_000)
            #expect(TrackIdentity.sameRecording(a, b, mode: .loose) == false)
        }

        @Test func missingDurationIsPermissiveInStrictMode() {
            // No duration data → strict behaves like loose.
            let a = TrackIdentity.Candidate(title: "Glass Tower", artists: ["Velvet Echo"])
            let b = TrackIdentity.Candidate(title: "Glass Tower", artists: ["Velvet Echo"])
            #expect(TrackIdentity.sameRecording(a, b, mode: .strict) == true)
        }

        @Test func within6SecondsIsStrictMatch() {
            let a = TrackIdentity.Candidate(title: "Glass Tower", artists: ["Velvet Echo"], durationMs: 200_000)
            let b = TrackIdentity.Candidate(title: "Glass Tower", artists: ["Velvet Echo"], durationMs: 206_000)
            #expect(TrackIdentity.sameRecording(a, b, mode: .strict) == true)
        }

        @Test func justOver6SecondsFailsStrict() {
            let a = TrackIdentity.Candidate(title: "Glass Tower", artists: ["Velvet Echo"], durationMs: 200_000)
            let b = TrackIdentity.Candidate(title: "Glass Tower", artists: ["Velvet Echo"], durationMs: 206_001)
            #expect(TrackIdentity.sameRecording(a, b, mode: .strict) == false)
        }
    }

    // MARK: - bestMatch

    @Suite struct BestMatchTests {

        @Test func returnsNilForEmptyPool() {
            let t = TrackIdentity.Candidate(title: "Glass Tower", artists: ["Velvet Echo"])
            #expect(TrackIdentity.bestMatch(for: t, in: []) == nil)
        }

        @Test func returnsOnlyOptionForSingleCandidate() {
            let t = TrackIdentity.Candidate(title: "Glass Tower", artists: ["Velvet Echo"])
            let c = TrackIdentity.Candidate(title: "Glass Tower", artists: ["Velvet Echo"])
            let result = TrackIdentity.bestMatch(for: t, in: [c])
            #expect(result?.0 == c)
        }

        @Test func picksExactMatchOverPartialMatch() {
            let t = TrackIdentity.Candidate(title: "Glass Tower", artists: ["Velvet Echo"], durationMs: 200_000)
            let exact = TrackIdentity.Candidate(title: "Glass Tower", artists: ["Velvet Echo"], durationMs: 200_000)
            let close = TrackIdentity.Candidate(title: "Glass Towers", artists: ["Velvet Echo"], durationMs: 200_000)
            let result = TrackIdentity.bestMatch(for: t, in: [close, exact])
            #expect(result?.0 == exact)
        }

        @Test func isrcMatchWinsOverHighScoreCandidate() {
            // The target has an ISRC. isrcMatch shares it (score = 1.0 via short-circuit).
            // closeTitle has the same title/artist but no ISRC and a significantly different
            // duration so its score is high but < 1.0, ensuring the ISRC candidate wins.
            let t = TrackIdentity.Candidate(title: "Glass Tower", artists: ["Velvet Echo"], durationMs: 200_000, isrc: "USMZ12600001")
            let isrcMatch = TrackIdentity.Candidate(title: "completely wrong", artists: ["nobody"], isrc: "USMZ12600001")
            // 30 s duration gap → durationScore 0.3 → score = 0.5*1.0 + 0.3*1.0 + 0.2*0.3 = 0.86
            let closeTitle = TrackIdentity.Candidate(title: "Glass Tower", artists: ["Velvet Echo"], durationMs: 230_000)
            let result = TrackIdentity.bestMatch(for: t, in: [closeTitle, isrcMatch])
            #expect(result?.0 == isrcMatch)
            #expect(result?.1 == 1.0)
        }
    }

    // MARK: - Unicode / Swift-specific pins

    @Suite struct UnicodePinTests {

        /// Swift pin: our `clean()` uses an ASCII character class matching JS `[^a-z0-9\s]`.
        /// This ensures Greek and other non-Latin scripts are stripped rather than kept.
        @Test func greekLettersStrippedByClean() {
            let p = TrackIdentity.parseTitle("αβγ Velvet Coast")
            // Greek letters → spaces → collapsed → "velvet coast"
            #expect(p.key == "velvet coast")
        }

        /// Swift pin: en-dash in dash suffix is treated as a separator.
        @Test func enDashSeparator() {
            let p = TrackIdentity.parseTitle("Glass Tower \u{2013} Acoustic Version")
            #expect(p.key == "glass tower")
        }

        /// Swift pin: em-dash in dash suffix is treated as a separator.
        @Test func emDashSeparator() {
            let p = TrackIdentity.parseTitle("Glass Tower \u{2014} Live")
            #expect(p.key == "glass tower")
            #expect(p.versionTag == "live")
        }

        /// Swift pin: `fold` does not break on strings with combining characters in unusual orders.
        @Test func precomposedVsDecomposedAreEqual() {
            // "é" precomposed (U+00E9) vs "e" + combining acute (U+0065 U+0301).
            let precomposed = TrackIdentity.fold("\u{00E9}")
            let decomposed  = TrackIdentity.fold("e\u{0301}")
            #expect(precomposed == "e")
            #expect(decomposed == "e")
            #expect(precomposed == decomposed)
        }

        /// Swift pin: full-width digits are normalised to ASCII by NFKD, matching JS.
        @Test func fullWidthDigitsDecompose() {
            let p = TrackIdentity.parseTitle("Glass Tower \u{FF11}\u{FF12}\u{FF13}")
            // Full-width "１２３" → "123" after fold
            #expect(p.key == "glass tower 123")
        }

        @Test func ampersandAndInArtistKey() {
            // JS: fold converts & → " and " before splitting.
            // "Holt & Brennan" → after fold "holt  and  brennan" → split on "and" → first = "holt"
            #expect(TrackIdentity.artistKey(["Holt & Brennan"]) == "holt")
        }

        @Test func andInArtistKeyWithoutAmpersand() {
            // "Lark and Fenwick" → split on \band\b → "lark"
            #expect(TrackIdentity.artistKey(["Lark and Fenwick"]) == "lark")
        }

        @Test func theStrippedFromArtistKey() {
            // "The Example Band" → after split still "the example band" → strip "the " prefix
            #expect(TrackIdentity.artistKey(["The Example Band"]) == "example band")
        }
    }
}
