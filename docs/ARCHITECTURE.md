# Mezzanine architecture

Mezzanine is a private, native macOS 26 SwiftUI client for one owner's Plex Media Server. It
replaces Infuse and plays every file direct, through the AetherEngine package, so the server
does no transcoding in the normal case. This document maps what exists in the code today. For
history and open items read `docs/PROGRESS.md`; for working rules and debug launch flags read
`CLAUDE.md`; for the visual language read `DESIGN.md` and `PRODUCT.md`. Where the original plan
(`~/.claude/plans/eventual-plotting-storm.md`) and the code differ, the code wins (see the last
section).

## 1. Overview

Three pieces:

| Piece | Path | Owns |
| --- | --- | --- |
| `MezzanineKit` (SPM library) | `MezzanineKit/Sources/MezzanineKit/` | Everything without UI: Plex client, models, local index, image pipeline, subtitle sources, on-device speech logic, binge and audio arithmetic |
| `MezzaninePlayback` (SPM library) | `MezzanineKit/Sources/MezzaninePlayback/` | `MezzaninePlayer`, `PlayerSurface`: the only code that imports AetherEngine |
| App target `Mezzanine` | `Mezzanine/` (raw `Mezzanine.xcodeproj`, synchronized folders) | SwiftUI views, stores, the player stage, menus and keyboard routing, downloads, settings |

Dependencies (`MezzanineKit/Package.swift`): AetherEngine pinned to an exact version (it
releases almost daily; bump deliberately and re-run the Lab matrix), GRDB `upToNextMinor`.
`MezzaninePlayback` depends on `MezzanineKit` and AetherEngine; `MezzanineKit` never imports the
engine. Platform is `.macOS(.v26)`, Swift tools 6.2.

**Isolation model.**
- The package targets use the default (non-isolated) setting. Kit types are `Sendable` structs,
  actors (`PlexServerClient`, `LibrarySync`, `ImagePipeline`, `PriorityGate`, `SpeechListener`)
  or `Sendable` final classes (`LibraryIndex`, `DerivativeDiskCache`). Decoding, indexing and
  image work run off the main actor.
- Exception: `MezzaninePlayer` in `MezzaninePlayback` is `@MainActor @Observable`, because the
  engine and SwiftUI observation want the main actor. Its static `prewarm` is `nonisolated`.
- The app target has `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. Every store (`SessionStore`,
  `LibraryStore`, `PlaybackCoordinator`, ...) is `@Observable` and main-actor. Code that must
  run elsewhere is marked `nonisolated` (for example `DownloadStore.folder`) or called through
  `Task.detached` (index reads in `LibraryStore.items`).
- Stores are created once in `Mezzanine/App/MezzanineApp.swift` as `@State` and injected with
  `.environment(...)`. Menu-bar `Commands` have no environment, so `MezzanineCommands` receives
  its stores as init arguments.
- The app is sandboxed (`Mezzanine.entitlements`: sandbox, network client and server, Pictures
  and Movies read-write).

## 2. Module map

### MezzanineKit (`MezzanineKit/Sources/MezzanineKit/`)

| Path | What it is | Used by |
| --- | --- | --- |
| `Plex/PlexIdentity.swift` | `X-Plex-*` headers; stable client identifier | `PlexTV`, `PlexServerClient` |
| `Plex/PlexTV.swift` | plex.tv: PIN sign-in, account, resources, Home users, profile switch | `SessionStore` |
| `Plex/PlexServerResource.swift` | A server and its `PlexConnection`s; `candidates` = plex.tv list plus a plain-http LAN fallback per local address | `SessionStore`, `ConnectionRacer` |
| `Plex/ConnectionRacer.swift` | Probes all addresses at once: LAN wins at once, remote waits a 600 ms grace, relay last | `SessionStore` |
| `Plex/PlexServerClient.swift` | Actor over one server address: sections, paged items, incremental `updatedAt>`, detail, hubs, search, timeline/scrobble, subtitles, artwork, folders, transcode decision | everything server-facing |
| `Plex/PlexURLs.swift` | URL builders: part, `photo/:/transcode`, HLS transcode (+ decision, stop), subtitle stream, `redacted`; `TranscodeOptions` | `PlexServerClient`, `PlaybackCoordinator`, images |
| `Plex/Transport.swift` | URLSession factories (API, probe, image), `NoRedirectDelegate`, `NetworkPath` (one `NWPathMonitor`, change generation) | everything |
| `Plex/PlexError.swift` | Error taxonomy with `userMessage`, `isTransient` | all UI |
| `Plex/Models/*` | `PlexMetadata`, `PlexMedia`/parts/streams, markers, chapters, libraries, hubs, artwork; `Lenient.swift` helpers | everything |
| `Index/LibraryIndex.swift` | GRDB `DatabasePool` mirror of a server's libraries for one user; FTS5 search; `LibraryQuery` | `LibraryStore` |
| `Index/LibraryIndex+Smart.swift` | Smart-shelf rule to SQL (`items(_ rule:)`, `count`, genres, collection names) | `HomeModel`, `SmartShelfSheet` |
| `Index/LibrarySync.swift` | Actor that keeps the index current (paged first sync, incremental, daily full pass) | `LibraryStore` |
| `Home/ShelfSpec.swift` | `ShelfSpec`, `SmartRule`, `SmartCondition`, `HomeLayout` (codable shelf model) | Home, `HomeLayoutStore` |
| `Images/ImagePipeline.swift` | Actor: memory, then disk derivative, then network; size buckets, coalescing, token only to current host | `RemoteImage`, `DownloadStore` |
| `Images/DerivativeDiskCache.swift`, `Downsampler.swift`, `PriorityGate.swift` | Disk LRU cache (SHA-256 file names), ImageIO downsampling, newest-first download gate | `ImagePipeline` |
| `Audio/AudioProfile.swift` | `AudioProfile`, `AudioOutputKind` (starting profiles), `VolumeLevel` (0-400 %) | `SoundSettings`, `MezzaninePlayer` |
| `Binge/BingePlanner.swift` | `BingeSettings`; pure rules: Up Next trigger, intro auto-skip, "Still watching?", next/previous episode | `PlaybackCoordinator`, `PlayerStage` |
| `Subtitles/SubtitleSearch.swift` | `SubtitleQuery`, `SubtitleResult`, `SubtitleSource` protocol, search fan-out, ranking, OpenSubtitles hash, encoding conversion | `SubtitleFinder` |
| `Subtitles/SubtitleSources.swift` | `OpenSubtitlesSource`, `SubdlSource`, `GestdownSource` (Addic7ed), `PlexSubtitleSource`; language code mapping | `SubtitleSourceSettings` |
| `Subtitles/ZipReader.swift` | Minimal ZIP reader for Subdl archives | `SubdlSource` |
| `OnDevice/SpeechListener.swift` | Actor over SpeechAnalyzer/SpeechTranscriber; words with source-timeline times | `OnDeviceSubtitles` |
| `OnDevice/SpeechCues.swift` | `SpeechAudio`, `SpokenWord` (+ `tightened`), `TimedLine`, `CueBuilder`, `SRT`, `TranslationPieces` | `OnDeviceSubtitles` |
| `OnDevice/TimingMatcher.swift` | Estimates the subtitle offset from words or from speech spans | `OnDeviceSubtitles` |

### MezzaninePlayback (`MezzanineKit/Sources/MezzaninePlayback/`)

| Path | What it is |
| --- | --- |
| `MezzaninePlayer.swift` | The player. Also defines Mezzanine's own `PlaybackRequest`, `ExternalSubtitle`, `PlayerStatus`, `PlayerTrack`, `PlayerCue`, `PlayerChapter`, `PlayerDiagnostics`, and `AirPlayButton`. One instance for the app's life (`makeShared()`) |
| `PlayerSurface.swift` | `PlayerSurface` (hosts the engine's layer) and `PictureCorners` |

### App target (`Mezzanine/`)

| Folder | Contents |
| --- | --- |
| `App/` | `MezzanineApp` (scenes, store wiring, quit hook via `AppDelegate`); DEBUG-only `LabLauncher` and `SheetPreview` |
| `Session/` | `SessionStore` (sign-in, servers, connection, profiles, network re-race), `Keychain`, `ProfileSwitcher` (profile menu, PIN sheet) |
| `Navigation/` | `AppShell` (sidebar + content + player stage), `AppCommands` (`AppCommandCenter`, `MezzanineCommands`), `QuickOpen`, `WindowChrome` |
| `Home/` | `HomeView`, `HomeModel`, `HomeLayoutStore`, `ShelfView`, `HeroView`, `ShelfEditor` (Edit in Place), `SmartShelfSheet`, `CollectionPicker` |
| `Library/` | `LibraryStore` (index + sync owner), `LibraryView` (Posters/Wide/List/Folders/Shelves), `FolderBrowser`, `SearchView` |
| `Detail/` | `DetailView`, `DetailParts`, `ArtworkPicker` |
| `Player/` | `PlaybackCoordinator`, `PlayerStage`, `PlayerOptions` (the ⋯ panel), `PlayerShortcuts` (`PlayerKey`, `KeyBinding`, `PlayerShortcuts`, `PlayerKeyRouter`), `UpNext`, `ActivityReporter`, `PlayerExtras` (stats, snapshot) |
| `Audio/` | `AudioRouteMonitor`, `SoundSettings` |
| `Subtitles/` | `SubtitleFinder`, `SubtitleSourceSettings`, `SavedSubtitles`, `OnDeviceSubtitles` |
| `Downloads/` | `DownloadStore`, `DownloadsView`, `DownloadControls`, `OfflineProgress` |
| `Settings/` | `SettingsView` (Account, Playback, Sound, Subtitles, Shortcuts, Library), `ShortcutSettings`, `SubtitleSettingsView` |
| `DesignSystem/` | `Theme` (tokens, motion, `TitleFont`), `Format`, `RoomLight` (UltraBlur corner wash) |
| `Images/` | `RemoteImage`, `LogoImage` (SwiftUI front of `ImagePipeline`) |
| `Onboarding/` | Poster Wall onboarding: sign in, server, profile, library warm-up |
| `Lab/` | DEBUG-only M0 spike harness: engine matrix on real files, scripted run (`-LabAutoMatrix YES`) |

## 3. Data flow

```
 plex.tv                       Plex Media Server(s)                      disk
 -------                       --------------------                      ----
 PlexTV.createPin/waitForToken
   |  token -> Keychain (<bundleID>.plex)
   v
 PlexTV.account + resources  -> [PlexServerResource] (owned first)
   |
   v
 ConnectionRacer.race(candidates, identityProbe)   LAN https > LAN http > remote > relay
   |  ResolvedConnection
   v
 SessionStore.client = PlexServerClient(baseURL, token)          (actor)
   |        |  images.setToken(token, host, serverID)  -> ImagePipeline
   |        v
   |   LibraryStore.connect(client, serverID, userID, sections)
   |        |   LibraryIndex.open  -> Application Support/Mezzanine/Index/<server>-<user>.sqlite
   |        |   LibrarySync (actor) -- every 10 min -->  client.rawItems / itemsUpdated
   |        v
   |   LibraryIndex (GRDB pool, FTS5 item_ft)  <----- browsing, search, smart shelves read ONLY here
   |        |
   |        v
   |   views: LibraryView, SearchView, QuickOpen, HomeModel (smart shelves)
   |
   +--> live calls: detail (markers, chapters, streams), hubs, collections,
        playlists, children, allLeaves, related, artwork, folders, timeline
```

**Sign-in.** `SessionStore.signIn()` asks plex.tv for a strong PIN, opens the browser, polls
for the token and writes it to the Keychain. `restore()` reconnects on launch. A 401 signs out.
The Plex Home profile token (if the user switched profile) is stored separately and is the
`activeToken`; everything else uses `activeToken`.

**Discovery.** `connect(token:)` loads the account and server list in parallel, picks the saved
server (UserDefaults `serverID` key in `SessionStore`), else the first owned one, and calls
`select`. The account sees more than one server (the owner's and a friend's shared one), so
multi-server must keep working. `ConnectionRacer` verifies the answering server by machine
identifier via `/identity`. `SessionStore` observes `NetworkPath` and re-races in the background
after a real network change; the client is swapped only when a different address wins. If every
address fails, `diagnoseUnreachable` distinguishes "offline" from a macOS Local Network denial
(both arrive as -1009).

**Client.** `PlexServerClient` sends the token as an `X-Plex-Token` header. Reads retry
transient failures twice; writes (timeline, scrobble, artwork, subtitle upload) never retry.
`Transport` refuses all redirects so the token cannot be replayed to another host.

**Index.** `LibraryStore.connect` opens one SQLite file per server and Plex user, so each Home
profile has its own watched marks and Continue Watching. `LibrarySync`: the first sync of a
section pages through everything (page size 300); later runs ask for items changed
(`updatedAt>`) and watched (`lastViewedAt>`) since the last sync, with a small clock-skew
overlap; a full reconcile runs when counts differ or once a day (catches deletions and
unwatched marks). `LibraryStore` re-runs `syncAll` every 600 s. There is no websocket. The
`item` table keeps queryable columns plus the item's original JSON, so `IndexedItem.metadata()`
decodes a full `PlexMetadata` without the network. `item_ft` is an FTS5 table (title, people, collections, summary; unicode61, diacritics removed) queried with prefix matching, ranked by `bm25`. `LibraryStore.revision` bumps on
change; views reload on it. A finished playback calls `recordStop`, which updates resume point
or watched state in the index at once (watched at 90 %).

**Images.** `RemoteImage` asks `SessionStore` for a URL sized to the slot (`photo/:/transcode`
at exact pixel size; clear logos stay originals). `ImagePipeline` rounds to a size bucket,
coalesces duplicate fetches, gates downloads newest-first, and stores downsampled copies in
`DerivativeDiskCache` (512 MB, `Caches/<bundle>/Images`). Cache keys drop scheme and host for
the current server, so LAN and remote addresses share cached posters. Poster choice order in
`LibraryStore.posterPath`: Mezzanine-only artwork override, then the clean (pre-Kometa) poster
if Settings ▸ Library asks for it, then Plex's.

## 4. Playback

```
 UI (Home/Detail/QuickOpen/Downloads)            PlayerStage (keys, HUD, Up Next)
        |  play(item)                                  ^   |  PlayerKeyRouter -> perform(PlayerKey)
        v                                              |   v
 PlaybackCoordinator  --- load(PlaybackRequest) --> MezzaninePlayer --> AetherEngine
   |  mode ladder: direct -> remux -> convert          (MainActor)       (native AVPlayer route
   |  ActivityReporter (timeline)                          ^              or software route)
   |  Up Next / post-play / prewarm                        | status, tracks, cues
   |  SavedSubtitles, OnDeviceSubtitles                    | SoundSettings -> audioProfile, volume
   v                                                       | AudioRouteMonitor (CoreAudio)
 PlexServerClient (timeline, decision, stop transcode)
```

### Coordinator and player

`PlaybackCoordinator` (`Mezzanine/Player/PlaybackCoordinator.swift`) is the app's playback
state: the item playing (full detail with markers, chapters, streams), the window origin for
the grow/shrink animation, binge state, delivery mode, and the subtitle bookkeeping. It owns an
`OnDeviceSubtitles` and, per title, an `ActivityReporter`. `play(_:)` resolves a show or season
to its next unwatched episode, fetches full detail, then walks the ladder below. If there is no
server client (offline) it calls `playOffline` instead.

`MezzaninePlayer` wraps one long-lived `AetherEngine`. Reusing it keeps the audio session and
display pipeline warm, which is what makes the next episode start without a black frame. The
app reads only Mezzanine types (`PlayerStatus`, `PlayerTrack`, `PlayerCue`, ...). The engine owns
system Now Playing and media keys (`ownsVideoNowPlayingSession`). The adapter also provides
PiP, an AirPlay picker bound to the native route's `AVPlayer`, frame step, rate, audio delay,
mute, `snapshot()`, and a second reader (`FrameExtractor`) for scrub-hover previews far from the
playhead. `PlayerStage.swift` is the player UI ("Bare Picture": nothing but the film until the
pointer moves).

### The delivery ladder

`PlaybackMode` has three cases, tried in order by `PlaybackCoordinator.play`:

1. `.direct`: the original part (`PlexURLs.part`), token in headers (`PlaybackRequest.headers`),
   server does nothing. If the title is downloaded, the local file plays instead with no
   headers.
2. `.remux`: Plex copies streams into HLS (`PlexURLs.transcode` with `directStream: true`).
3. `.convert(cap)`: Plex re-encodes, optionally capped (kbps; 20000/12000/8000/4000/2000 offered
   in the ⋯ Quality page; 8000 and up is 1080p, below is 720p).

Remux and convert first call `client.decideTranscode` (Plex answers 400 to `start.m3u8` without
a decision) and carry a session id; the previous session is stopped with `stopTranscode` when
switching. A fallback shows a one-time notice ("Direct play failed"). The same ladder is
reachable by hand: ⋯ ▸ Quality, the failure panel's Convert on the Server, or `-PlayerQuality`
and `-ForceDirectFail YES` in Debug. Transcode URLs use Plex's Generic profile plus Mezzanine's
own target declaration (`TranscodeOptions.profileExtra`: HLS/MPEG-TS, H.264/HEVC, AAC/AC-3/E-AC-3);
there is no profile for platform "macOS". Subtitles are left out of transcodes (Mezzanine draws
its own). Multi-file titles have a version picker (`mediaIndex`).

### ActivityReporter

`Mezzanine/Player/ActivityReporter.swift` sends `/:/timeline` every 10 s while playing and at
once on play, pause, seek and stop; the stop report is waited for (at most 2 s) so quitting
mid-film saves the resume point (`AppDelegate.beforeQuit` -> `finishForQuit`). Plex derives
resume points, Continue Watching, watched marks (stop past ~90 %), Now Playing, Tautulli, Trakt
and the owner's Playbill newsletters from these. `UserDefaults "MezzanineNoActivity"` (launch
`-MezzanineNoActivity YES`) makes every report a no-op, as it does for `OfflineProgress`. The
Lab window never reports. Marking watched/unwatched from the UI uses `scrobble`/`unscrobble`
directly and is not gated.

### Binge flow

- Markers come from `PlexMetadata` (intro, credits). `PlayerStage.tick` runs on every clock
  tick: an intro marker is auto-skipped when `BingePlanner.shouldAutoSkipIntro` says so
  (never / after the first episode of the sitting / always; per-show override); a credits marker
  with `autoSkipCredits` goes straight to the next episode. Otherwise a Skip button sits over the
  marker.
- `BingePlanner.upNextTrigger` = start of the last credits marker, else 30 s before the end.
  At the trigger `PlayerStage` calls `playback.prewarmNext()` (which runs
  `MezzaninePlayer.prewarm` off the main actor to fetch the next file's opening bytes) and
  starts the countdown (default 10 s; 0 disables autoplay). The picture shrinks beside the card.
- `PlaybackCoordinator.resolveNext` caches a show's episode list (`allLeaves`) and sets
  `nextEpisode`/`previousEpisode` (crossing seasons, skipping specials).
- "Still watching?" pauses instead of autoplaying after N episodes in a row (default 4) or
  hours (default 3): `BingePlanner.shouldAskStillWatching`.
- Films get post-play (suggestions from Plex's related hubs, no countdown, no autoplay),
  toggled by `postPlayMovies`. `BingeSettings` persists as JSON under `bingeSettings.v1`.

### Audio route and profiles

`Audio/AudioRouteMonitor.swift` listens to CoreAudio for default-output changes (and the
built-in device's data source, speakers vs jack) and describes the device by UID, transport and
data source. `SoundSettings` keeps one `DeviceSetup` (kind + `AudioProfile`) per device key in
UserDefaults `soundSetups.v1`, starting from `AudioOutputKind.defaultProfile`, and pushes the
profile and volume into `MezzaninePlayer` on every route change. The owner can reclassify a
device (his 2.1 speakers look like headphones to macOS). In `MezzaninePlayer.applyVolumeAndShaping`
the profile and the volume boost (above 100 % becomes gain before the engine's limiter, up to
+12 dB at 400 %) map onto the engine. The design intent: a 5.1 fold is unnormalised into a
limiter with a dialogue lift, so films are about as loud as stereo; an HDMI receiver or AirPods
get no shaping so Atmos/5.1 pass through. `PlayerDiagnostics` feeds the stats overlay (I).

### Subtitles

Three layers, all shown by `SubtitleOverlay` in `PlayerStage.swift` (font, size, background and
offset from the ⋯ panel / Settings).

1. **Engine tracks.** Embedded tracks and server sidecars. Sidecar streams are handed to the
   engine as `ExternalSubtitle` at load (`PlexURLs.subtitle`); their order is remembered in
   `sidecarStreamIDs`. Preferred languages come from the streams Plex has marked selected, and
   `setStreams` writes the owner's choice back to the file's part.
2. **Find Subtitles** (⌥F; `Subtitles/SubtitleFinder.swift`). `SubtitleSearch.answers` asks every
   source at once and results stream in as each answers; ranking is: made for this file (hash
   match), then language order, then downloads. Sources (`MezzanineKit/Subtitles/`): Plex
   (the server's own OpenSubtitles search), OpenSubtitles.com (owner's API key, hash from two
   64 KiB range reads), Subdl (key; ZIP archives, season packs matched to the episode),
   Addic7ed through Gestdown (keyless, TV only). Keys live in the Keychain
   (`<bundleID>.subtitles`); languages and toggles in UserDefaults
   (`SubtitleSourceSettings`). Choosing a Plex result makes the server fetch it and store a
   sidecar (every Plex app sees it; the coordinator tracks it in `plexSubtitleStreams`).
   Choosing an internet result writes the file to `SavedSubtitles` and does not touch the
   server.
3. **On-device** (M12; `Subtitles/OnDeviceSubtitles.swift` over `MezzanineKit/OnDevice/`):
   - *Generate from Speech*: `MezzaninePlayer.speechAudio()` (AetherEngine's audio tap, centre
     channel, about 10 s ahead of the picture on the native route) feeds `SpeechListener`
     (SpeechAnalyzer). `SpokenWord.tightened` caps word starts, `CueBuilder` makes two-row lines
     of about 6 s, and `SavedSubtitles` keeps `generated.srt` plus `.json` per title; they return
     on screen next time and carry to the next episode of the same show if generating.
   - *Match Timing*: `TimingMatcher` compares cues with spoken words (same language) or speech
     spans (any language) and writes the `subtitleOffset` default. Refused while generated
     subtitles are on screen.
   - *Translate*: a `.translationTask` on the stage translates lines about 90 s ahead
     (`TranslationPieces` splits speaker lines); the line is replaced when ready. Needs an
     installed language pair (the system prompts to download).
   The speech stream ends on every reload (track switch, quality change, next title) and is
   asked for again. Nothing is sent off the Mac.

`SavedSubtitles` is also what makes internet subtitles load every time the title plays, online,
offline or from a download, and remembers which one was last on screen.

## 5. Downloads and offline mode

`Downloads/DownloadStore.swift` downloads the original file (no transcode) with a plain
`URLSession` (default configuration, two concurrent transfers, `httpMaximumConnectionsPerHost`
2), with resume data saved per title and flushed at quit (`suspendForQuit`).

- Files: `~/Movies/Mezzanine/<Show>/<Show> SxxExx Title.ext` (readable names; the sandbox has
  the Movies entitlement), plus artwork, clear logo and subtitle files beside the video.
- Manifest and resume data: `Application Support/Mezzanine/Downloads/` (`manifest.json`,
  `resume-<id>.data`). Each record keeps the title's Plex JSON (markers, chapters, streams) so
  pages and playback work with no server.
- Keep rules: per show, "keep the next N unwatched episodes downloaded"; `DownloadStore` tops
  up and clears watched episodes it added.
- Removal asks once (window-level `DownloadRemoval`), and a finished file goes to the Trash.
- `localFile(for:)` makes a downloaded copy play instead of the server's, even online.
- Offline mode: `AppShell.isOffline` is true when onboarding is complete, there is no client,
  the session phase is `.failed`, and something is downloaded. The shell then shows only the
  Downloads page (search hidden, "Offline" badge). `PlaybackCoordinator.playOffline` plays from
  saved details and sends no activity.
- `OfflineProgress` records where offline playback stopped (UserDefaults, per server) and
  `AppShell` replays it when the client returns: past 90 % becomes a scrobble, otherwise a stopped
  timeline. Never sent under `-MezzanineNoActivity`.
- Debug: `-ForceOffline YES` makes `SessionStore.restore` behave as if Plex is unreachable.

## 6. Home, shelves, Quick Open, commands, keys

**Home shelves.** Home is built from `HomeLayout` / `ShelfSpec` (Kit), saved by
`HomeLayoutStore` as JSON in UserDefaults per server and Plex Home profile. `HomeLayout.mainScope`
is the main Home; a library's section key is that library's Shelves layout. A shelf source is a
Plex hub (global or per library), a collection, a playlist, or a smart rule. `HomeModel`
resolves each spec into a `Shelf` (hubs, collection and playlist items through the client;
smart rules through `LibraryIndex.items(_ rule:)`), drops hidden and empty shelves, and keeps
keyboard focus (`ShelfFocus`). A hub the server no longer offers shows only in the editor.
Defaults (nothing saved yet) are Plex's own rows. Missing-layout fallback is
`HomeLayoutStore.saved(scope) == nil`.

**Smart shelves.** `SmartRule` is a list of `SmartCondition`s (all must hold) plus sections,
kinds, sort and size. 11 fields: watch state, genre (include/exclude), decade, minimum rating,
and so on (see `SmartCondition.Field`). `LibraryIndex+Smart.swift` turns a rule into one SQL
`WHERE`; `SmartShelfSheet` edits rules with a live count and preview.

**Edit in Place** (`ShelfEditor.swift`, ⌘E): shelves fold into strips; drag or ⌥↑/⌥↓ reorders,
Space hides, Return renames or edits rules, ⌫ removes, all undoable; saves as you go.

**Quick Open** (`Navigation/QuickOpen.swift`, ⌘K): titles from the index, Play Next Episode,
Resume, Go To, and shelf actions. Shelf actions that need Home on screen wait in
`AppCommandCenter.pendingHomeAction`.

**Commands.** `AppCommandCenter` (`Navigation/AppCommands.swift`) is the bridge between the
menu bar and the window: selection, back/forward stacks, search text, which actions are enabled
(`canPlay`, shelf editing, modal guards), pending sheets (artwork picker, download removal,
profile PIN) and player-menu state. `MezzanineCommands` builds the menus. Rule: every keyboard
shortcut has a menu item.

**Player keys.**
- `PlayerKey` (`Player/PlayerShortcuts.swift`) enumerates the rebindable player actions (28),
  each with a title, group and default `KeyBinding`.
- `PlayerShortcuts` stores only changes from the defaults, resolves conflicts (a key taken from
  another action moves it and reports it), and offers a SwiftUI key equivalent so the Playback
  menu shows each key. Settings ▸ Shortcuts and Help ▸ Keyboard Shortcuts (⌘/) read it.
- `PlayerKeyRouter` is a local `NSEvent` key-down monitor installed while the stage is on
  screen. It runs ahead of the menus: typing in a field is safe, a focused control gets Space
  first, and the menus only ever see ⌘/⌃ keys. Fixed keys (Return, Esc, 0-9, ⌘⇧S) are handled in
  `PlayerStage.handleKey` before the rebindable table.
- Esc steps out one layer at a time: panel page, panel, Up Next, full screen, player.
- While the player is open the shell behind it is disabled and hidden from VoiceOver, and
  `WindowChrome` hides the title bar strip and toolbar.

## 7. Persistence

| What | Where | Notes |
| --- | --- | --- |
| plex.tv account token | Keychain, service `<bundleID>.plex`, one generic-password item per account (`Session/Keychain.swift`) | Never logged. Release `com.mezzanine.mac.plex`, Debug `com.mezzanine.mac.debug.plex` |
| Plex Home profile token | Keychain, same service, separate account | Cleared on sign-in and when switching back to the owner |
| Subtitle API keys, OpenSubtitles password/sign-in token | Keychain, service `<bundleID>.subtitles` | Set in Settings ▸ Subtitles |
| Local library index | `Application Support/Mezzanine/Index/<server>-<user>.sqlite` | GRDB pool, migrations `v1`, `v2`; rebuildable from the server |
| Downloads manifest, resume data | `Application Support/Mezzanine/Downloads/` | Video files in `~/Movies/Mezzanine/` |
| Saved internet subtitles, generated subtitles | `Application Support/Mezzanine/Subtitles/<server>/<title>/` | `generated.srt` + `.json` for speech-made lines |
| Image cache | `Caches/<bundleID>/Images` | 512 MB LRU; Settings ▸ Clear Cache |
| Snapshots | `~/Pictures/Mezzanine/` | Also copied to the clipboard unless `SnapshotNoClipboard` |
| UserDefaults (the ones that matter) | `plexClientIdentifier` (stable per install, never change), the saved server id, `onboardingComplete`, `bingeSettings.v1`, `postPlayMovies`, `soundSetups.v1`, shortcut overrides (`PlayerShortcuts`), per-scope shelf layouts (`HomeLayoutStore`), `artworkOverrides.v1.<server>-<user>`, `cleanPosters`, `subtitleLanguages`, `subtitleScale`, `subtitleBackground`, `subtitleOffset`, `translateSubtitles`, offline-progress queue, `settingsTab`, `playerStatsVisible`, `lastSidebarItem` (the section restored at launch, skipped under `-ApplePersistenceIgnoreState`) | `@AppStorage` for view-local ones |

Debug builds are bundle ID `com.mezzanine.mac.debug` (Release is `com.mezzanine.mac`, the test
bundle `com.mezzanine.mac.tests`). Debug has its own sandbox container
(`~/Library/Containers/com.mezzanine.mac.debug`), defaults and Keychain items, so test runs never
change the installed app's settings or sign-in. In Debug, `SessionStore.restore` seeds the
Keychain from the `MEZZANINE_DEV_TOKEN` environment variable when no token exists; only
`Scripts/dev-run.sh` sets it (from `.mezzanine-live.env`, mode 600, gitignored).

## 8. Testing

- **Unit tests**: `cd MezzanineKit && swift test`. Swift Testing, target `MezzanineKitTests`,
  real-response fixtures in `Tests/MezzanineKitTests/Fixtures`. Covers decoding, connection
  racing (stub transport), index and sync, binge rules, smart shelves, subtitle search and
  ranking, transcode URL building, on-device subtitle logic (cue building, timing, SRT,
  translation pieces).
- **Live tests**: `Scripts/live-test.sh` loads the dev token into the environment only and runs
  `MezzanineLiveTests` with `MEZZANINE_LIVE=1`; suites are skipped without it. Read-only: no
  timeline, scrobble or rating calls.
- **Opt-in speech test**: `MEZZANINE_SPEECH=/path/speech.aiff swift test --filter
  SpeechListenerLiveTests` runs the real recognizer on an `say -o` file.
- **Scripted Lab matrix** (DEBUG): `Scripts/dev-run.sh -LabAutoMatrix YES` plays the codec rows
  and prints route, first-frame and seek timings. Required before committing an AetherEngine bump.
- **Manual driving**: Debug launch flags (`-MezzanineAutoplay`, `-PlayerKeyScript`,
  `-HomeKeyScript`, `-MezzanineOpenWindow`, ...). The full list and cautions are in `CLAUDE.md`
  (section "Manual testing aids"); do not duplicate it here. Always include
  `-MezzanineNoActivity YES` (`Scripts/dev-run.sh` does).
- Reviews: each UI milestone ends with an impeccable finish review and an HIG review
  (see `docs/PROGRESS.md`).

## 9. Invariants and gotchas

- **No play history while testing.** Anything that reaches `/:/timeline`, scrobble or rating
  lands in Plex, Tautulli, Trakt and Playbill. Use `-MezzanineNoActivity YES`. Choosing a *Plex*
  subtitle result writes a sidecar on the server; only choose internet results in tests.
  Transcode flags start real server sessions: keep runs short, use `-MezzanineAutoClose`, check
  `Scripts/plex.sh pms /transcode/sessions`.
- **Engine isolation.** Only `MezzaninePlayback` imports AetherEngine. The app must not use engine
  types; add the Mezzanine type and map it inside `MezzaninePlayer`. AetherEngine is pinned
  exactly.
- **Tokens.** Header only (`X-Plex-Token`), never in a URL, a cache key or a log
  (`PlexURLs.redacted`). `ImagePipeline` sends the token only to the current server host.
  `NoRedirectDelegate` stops token replay. Subtitle sites get no Plex token and may follow
  redirects.
- **Lenient decoding.** Plex JSON mixes types (`ratingKey` is sometimes a number). Decode
  through `Plex/Models/Lenient.swift`. The index stores raw JSON, so schema drift in
  `PlexMetadata` does not need a migration.
- **Stable client identifier.** `plexClientIdentifier` ties the token, Authorized Devices and
  playback sessions together; do not regenerate it.
- **Menu commands have no environment.** Pass stores into `MezzanineCommands`; reading
  `@Environment` there crashed Debug launch.
- **Never mutate a `@Binding` array twice in one transaction** (remove then insert): the second
  read sees the stale array and duplicates. Build the new array, assign once (hit in shelf
  reordering).
- **Now Playing artwork handler** runs on MediaPlayer's own queue. It is built in a
  `nonisolated` helper in `MezzaninePlayer`; a main-actor closure traps.
- **One player, reused.** `MezzaninePlayer` lives for the app's life. Reloads end the speech
  audio stream, so anything fed by `speechAudio()` must re-ask after a load.
- **Updates.** `AppUpdater` (Sparkle 2, Release only) needs the sandbox pieces together:
  `SUEnableInstallerLauncherService`, the `-spks`/`-spki` mach-lookup exceptions, and Sparkle's
  helpers re-signed with our identity (`Scripts/sign-sparkle.sh`; Xcode leaves them ad-hoc). The
  `SUPublicEDKey` must match the Keychain key (account `mezzanine`) and the CI secret.
- **Plex Companion (remote control).** `MezzanineKit/Companion/`: `CompanionGDM` (UDP 32412, group
  239.0.0.250; HELLO/BYE to 32413), `CompanionHTTPServer` (one request per connection, port 32500 or
  any free one), `CompanionService` (routes `/resources`, `/player/playback/*`, `/player/timeline/*`,
  keeps subscribers, pushes timelines to `<controller>/:/timeline`). App side: `RemoteControl`
  (commands to `PlaybackCoordinator`/`MezzaninePlayer`, the timeline from them). Controllers talk to
  the player directly (the PMS only lists it at `/clients`), so Wi-Fi client isolation breaks it.
  Like other Plex players there is no request auth; callbacks go only to the requesting address and
  `playMedia` only plays the signed-in server's titles.
- **Full-screen title strip.** AppKit keeps the title bar in a separate window as an opaque band.
  `WindowChrome` hides it while the player owns the window; verify with full-display captures
  (`screencapture -D 1`), not window captures.
- **Speech word starts** run edge to edge; always `SpokenWord.tightened` before building cues,
  or lines land up to 1 s early. Generated subtitles come back on screen, and Match Timing is
  refused then: delete `generated.srt` between tests.
- **Local Network permission** is tied to the binary; a new build may re-prompt, and a denial
  looks like "offline" (-1009). `SessionStore.diagnoseUnreachable` tells them apart.
- **Image cache keys** must never contain credentials or the host of the current server.
- **Index is a cache.** Browsing never asks the server; deletions and unwatched marks arrive
  only on the daily full pass (or a count mismatch), and the index is updated locally on
  playback stop and on mark watched. If browsing looks stale, check `LibrarySync` first.
- **Debug container vs installed app.** Debug and Release never share defaults, Keychain items or
  the index; `Scripts/install.sh` builds Release into `/Applications/Mezzanine.app`.
- **UI process.** Every UI surface gets an `/impeccable` round and an HIG review; every player
  action gets a rebindable key and a menu item (`CLAUDE.md`).

### Where the code differs from the original plan

The plan's "Architecture" section is the intended design; these parts are not implemented or
were built differently:

- No `PlaybackEngine` protocol (the `Package.swift` comment still mentions one); `MezzaninePlayer`
  is the adapter and is concrete.
- No `Plex/Live` websocket; sync is a 10-minute timer plus local updates on playback.
- No `Media` folder (`PlaybackPlan`, `BIFIndex`): the delivery ladder lives in
  `PlaybackCoordinator`, and scrub previews use the engine's cached stills plus a second
  `FrameExtractor` reader, not BIF files.
- `Activity` is in the app (`Player/ActivityReporter.swift`), not in the Kit.
- No Trakt integration (skipped by the owner, M10).
- Downloads use a default `URLSession`, not a background session.
- Subtitle upload from OpenSubtitles results to the server is not done: only Plex-source results
  are stored on the server; internet results stay on this Mac (`SavedSubtitles`).
- No mini player or pop-out player (PiP and AirPlay exist). The app-level `MezzanineTests` folder is not described here.

## 10. Distribution and updates

```
Scripts/release.sh x.y.z ─ bump + tag ─▶ CI (Release, xcode-27) ─▶ Scripts/build-release.sh
   Release build (build number = commit count) ─▶ sign-sparkle.sh ─▶ dmgbuild DMG ─▶ sign_update
   ─▶ Scripts/ci/publish.sh (deploy key) ─▶ mezzanine-releases: staging/ commit
   ─▶ Publish workflow: GitHub Release + releases.json + appcast.xml, history reset to one commit
   ─▶ Scripts/github-release.sh: the same DMG as a GitHub Release on this repo (downloads)
App: AppUpdater ─▶ SPUStandardUpdaterController ─▶ raw.githubusercontent.com/…/appcast.xml
   ─▶ DMG from the release ─▶ EdDSA check ─▶ installer XPC service ─▶ installs on quit
```

- `--local` runs the same build and publish from the Mac (login Keychain identity and Sparkle key),
  waits for the public repo to publish, then pushes the tag; CI sees the tag published and stops.
- The public repo holds only the feed, `releases.json` (last ten) and its publish tool; DMGs live
  in GitHub Releases. Its README explains the one-time Open Anyway (signed, not notarized: there is
  no Developer ID certificate).
