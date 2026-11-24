# Mezzanine — notes for agents

Private native macOS 26 client for the owner's Plex Media Server (replaces Infuse). Read
`docs/PROGRESS.md` first (status and open items), `docs/ROADMAP.md` for what's next (optional
service integrations; Plex alone must stay a complete app), then the approved plan
`~/.claude/plans/eventual-plotting-storm.md`, `docs/ARCHITECTURE.md`,
`PRODUCT.md`, `DESIGN.md`.

**UI/UX is the top priority.** Every UI surface gets an `/impeccable` round before it's built
and an `apple:hig-reviewer` pass before its milestone closes. Every player action gets a
rebindable key and a menu item. Binge flow (skip intro/credits, Up Next autoplay) is a
first-class feature.

## Commands

```bash
cd MezzanineKit && swift test             # core unit tests
Scripts/live-test.sh                      # read-only checks vs the real server (.mezzanine-live.env)
Scripts/plex.sh pms /library/sections     # read-only Plex API helper (GET only, token never printed)
xcodebuild -project Mezzanine.xcodeproj -scheme Mezzanine -destination 'platform=macOS' \
  -derivedDataPath build.noindex/DerivedData build
Scripts/install.sh                        # Release build → /Applications/Mezzanine.app (local only)
Scripts/release.sh 0.3.0                  # ship: bump, tag, push → CI publishes, installs update
Scripts/release.sh 0.3.0 --local          # same, built and published from this Mac (no CI minutes)
```

## Releases and updates

- Ship a version with `Scripts/release.sh <x.y.z>` after adding a `## <x.y.z>` section to
  `CHANGELOG.md` (owner-facing notes; Sparkle's update window shows them). The script bumps
  `MARKETING_VERSION`, commits "Release x.y.z", tags `vx.y.z` and pushes; the `Release` workflow
  (`.github/workflows/release.yml`, runner `xcode-27`, Xcode 27.2) tests, builds, re-signs
  Sparkle's helpers (`Scripts/sign-sparkle.sh`), makes the DMG (`Scripts/build-release.sh`,
  dmgbuild + `Scripts/dmg/`) and stages it in the public `ahamedzoha/mezzanine-releases` repo
  through a deploy key; that repo's Publish workflow creates its Release and the appcast entry and
  resets its history. The same DMG becomes a GitHub Release on this repo (`Scripts/github-release.sh`),
  the page people download from. Installed copies download it and install on quit.
- `CI` (`.github/workflows/ci.yml`) builds unsigned and runs the kit tests on every push and PR
  (free on a public repo). README screenshots: `Scripts/screenshots/` (capture, then frame; the
  profile row is blurred).
- The Release workflow runs on tags and "Run workflow"; `--local` builds on the Mac instead.
- Build number = `git rev-list --count HEAD` (local installs too), so releases always compare newer.
- Secrets (private repo): `MAC_CERT_P12`/`MAC_CERT_PASSWORD` (the Apple Development identity,
  expires 2027-08-27: renew, re-export, reset both), `SPARKLE_ED_KEY` (EdDSA private key; the
  original is in the login Keychain, account `mezzanine`; `SUPublicEDKey` in `Info.plist` must
  match), `RELEASES_DEPLOY_KEY` (write access to mezzanine-releases only). Never print them.
- Debug builds never run the updater (`AppUpdater.isAvailable` is false); test updates with real
  releases. Commits in the public repo use the owner's GitHub no-reply address.

Build output goes to `build.noindex/` (Spotlight skips it).

## Layout

- `MezzanineKit/` local SPM package, non-isolated code:
  - `MezzanineKit` — Plex client (plex.tv auth/resources, `ConnectionRacer`, `PlexServerClient`,
    models with lenient decoding), `AudioProfile`/`VolumeLevel`, the GRDB index, subtitle sources,
    on-device speech (`OnDevice/`). Architecture map: `docs/ARCHITECTURE.md`.
  - `MezzaninePlayback` — `MezzaninePlayer`, the **only** code that imports AetherEngine.
    The app uses Mezzanine's own types (`PlayerStatus`, `PlayerTrack`, `PlayerCue`).
- `Mezzanine/` app target, MainActor by default. `Lab/` is DEBUG-only (the M0 spike harness).

## Rules

- **Never write play history while testing.** Timeline/scrobble/rating calls reach Plex,
  Tautulli, Trakt and the owner's Playbill newsletters. Launch Debug builds with
  `-MezzanineNoActivity YES`; the Lab window never reports activity. Live tests are read-only.
- The dev token lives in `.mezzanine-live.env` (mode 600, gitignored); the app's token lives in
  the Keychain. Never print, log or commit either. Tokens travel as the `X-Plex-Token` header,
  not in URLs; `PlexURLs.redacted` strips them from anything logged.
- AetherEngine is pinned to an exact version (it releases almost daily). Bump it deliberately,
  then re-run the Lab matrix (`Lab ▸` every row) before committing.
- Plex JSON is loose about types: decode through the `lenient*` helpers in `Lenient.swift`.
- Commit as the owner, with no Claude attribution (no `Co-Authored-By` trailer); push to the
  private `origin` (github.com/ahamedzoha/mezzanine).

## Manual testing aids (DEBUG)

`-MezzanineNoActivity YES` · `-ApplePersistenceIgnoreState YES` · Lab window: Window ▸ Lab
(or the Open Lab button on the placeholder root). Player: `-MezzanineAutoplay <ratingKey>`
`-MezzanineAutoSeek <s>` `-MezzanineAutoClose <s>` `-MezzanineAutoplayDelay <s>` `-MiniExpandAfter <s>` `-NotifyTest YES` (posts one new-episode notification) `-PlayerChromePinned YES`
`-PlayerOptionsOpen YES` `-PlayerOptionsPage search|subtitles|audio|picture` `-FindSubtitlesChoose YES` (picks the first non-Plex result; local only) `-PlayerFullScreen YES` `-PlayerKeyScript "i,c,shift+right,!snapshot"`
(`~3` waits 3 s, `!fs` toggles full screen directly) `-SelectBehindAfter 14` (switches the page under the player)
(real key events through the router; menus ignore keys while the app is in the background, so
⌘ items use `!action`) `-ScrubHoverAt 0.6` `-SnapshotNoClipboard YES`; detail:
`-MezzanineOpen <ratingKey>` `-DetailSection cast`; windows: `-MezzanineOpenWindow shortcuts|settings`
with `-settingsTab shortcuts`. Debug builds are `com.mezzanine.mac.debug` (own container,
defaults and Keychain item), so test runs never change the installed app's settings or sign-in; delivery: `-PlayerQuality remux|convert|8000` `-ForceDirectFail YES`
(each starts a real transcode on the server: keep runs short, let the player close itself
(`-MezzanineAutoClose`) so the session stops, and check `Scripts/plex.sh pms /transcode/sessions`).

Sidebar and top bar: `-SidebarSelect "slice:unwatched:1"` (a `SidebarItem` storage key), `-ActivityOpen YES`, `-WindowSize 900x600`,
`-SidebarKeyScript "down,right,down"` (prints `SIDEBAR` with the selection after each key).
`TitleActions` writes (watched marks, Continue Watching removal) print `ACTION …` and send nothing under `-MezzanineNoActivity YES`.

Shelves: `-HomeSeedShelves YES` (smart shelf, collection, hidden row), `-HomeEditing YES`,
`-HomeKeyScript "down,opt+down,space"`, `-SmartShelfSheet YES`, `-CollectionPicker YES`,
`-QuickOpenQuery "after"` (`_` for empty), `-SearchQuery "south"` (types into the toolbar search; logs `SEARCHPANEL`). Window snapshots of an attached sheet fail: capture
`-MezzanineOpenWindow sheetPreview -SheetPreviewKind rules|picker|artwork|opensubtitles` instead.

Subtitles: Find Subtitles' sources live in `MezzanineKit/Subtitles/`; the keys in the Keychain
(`<bundleID>.subtitles`). Never choose a Plex result while testing (it writes a sidecar on the
server); internet results only write under the Debug container's Application Support.
Debug builds open onboarding unless launched with `-onboardingComplete YES`.

On-device subtitles (M12): `MezzanineKit/OnDevice/` (SpeechListener over SpeechAnalyzer, CueBuilder,
TimingMatcher, SRT, TranslationPieces); the app side is `Mezzanine/Subtitles/OnDeviceSubtitles.swift`,
fed by `MezzaninePlayer.speechAudio()` (AetherEngine's audio tap, centre channel, ~10 s ahead on the
native route; it ends on every reload and is re-installed). Real recognizer test, opt-in:
`MEZZANINE_SPEECH=/path/speech.aiff swift test --filter SpeechListenerLiveTests` (`say -o speech.aiff "…"`).
Word ranges run edge to edge, so starts are capped by `SpokenWord.tightened` (else lines land up to 1 s
early). Debug builds print `HEARD`, `MATCHING`, `MATCH`, `TAP ENDED`; run
`script -q /dev/null Scripts/dev-run.sh … < /dev/null` so prints reach a log line by line. A title's generated
subtitles (`generated.srt` + `.json` in its Subtitles folder) come back on screen if they were on, and
then Match Timing is refused: delete them between tests. Set the Debug Timing with
`defaults write ~/Library/Containers/com.mezzanine.mac.debug/Data/Library/Preferences/com.mezzanine.mac.debug.plist subtitleOffset -float 3`
(an `-subtitleOffset` launch argument would shadow what the app writes).

Google Cast: `MezzanineKit/Cast/` (discovery, `CastMessage` codec, `CastSession`), app side
`Mezzanine/Player/CastController.swift`. Casting tests play on the owner's living-room TV
("Family room TV"): say so before running them, keep them short (`-CastTo Family -CastStopAfter 25`
with `-MezzanineAutoplay`), and never quit the app mid-cast in a script without stopping it.
Leftover player on the TV: `MEZZANINE_CAST=stop swift test --filter CastLiveTests/stopsRunningReceiver`.
Discovery check: `MEZZANINE_CAST=1 swift test --filter CastLiveTests/findsDevices`.

SwiftUI gotcha: a NavigationStack draws a pushed page above anything overlaid on the stack, so
panels that must float over every page (Quick Open, the search panel) hang on the page itself
(`PagePanels` in AppShell, top page only). Check new overlays on a title page too:
`Scripts/ui-case.sh detail-search 13 -MezzanineOpen 11998 -SearchQuery alien` (captures every display).
Async loads that fill a list (search, season episodes, folders) must drop their answer when a
newer request started (`Task.isCancelled` or compare the request after the await): three bugs came
from a slower, older answer landing last.

Remote control (Plex Companion): `MezzanineKit/Companion/`, app side `Mezzanine/Remote/RemoteControl.swift`.
Debug builds print `REMOTE …` (searches, commands). Check it without a phone: run the Debug build
(`-MezzanineNoActivity YES`), then `Scripts/companion-check.py $(Scripts/plex.sh pms /identity | jq -r .MediaContainer.machineIdentifier)`
(GDM search, resources, subscribe, play/pause/seek/stop); the server lists the player at
`Scripts/plex.sh pms /clients`. A phone can only control it when the two can reach each other
(the owner's 5 GHz Wi-Fi isolates wireless clients: `CLAUDE.local.md`).

SwiftUI gotcha: never give ForEach rows a position as identity (`.id(column)` for ScrollViewReader):
it overrides the item key, and after a reload reorders the list the old cards stay on screen (Continue
Watching kept the finished episode until a restart). Scroll with the item key (`proxy.scrollTo(item.ratingKey)`).

SwiftUI gotcha: never mutate a `@Binding` array twice in one transaction (remove, then insert):
the second read sees the stale array and duplicates the element. Build the new array, assign once.

Full screen: AppKit moves the title bar into a separate window and keeps it as an opaque band over
the content even with the toolbar hidden (pinned, or revealed with the menu bar). While the player
owns the window, `WindowChrome` sets `.autoHideToolbar` and also hides that strip window outright,
re-applying on full-screen, key, screen and app-activation changes. SwiftUI and AppKit re-show the
toolbar on their own (a 52 pt opaque band pinned over the film and its logo until something
re-applied), so in full screen `WindowChrome` also watches the toolbar (KVO), the strip window and a
1 s check, re-applying on drift (full screen only: hiding the toolbar in a window resizes it by 20 pt).
DEBUG: `-ChromeTrace YES` logs the strip state, `-ToolbarDriftAfter 14` forces the drift,
`-ChromeWatchOff YES` disables the watch for comparison. Verify with full-display
captures (`screencapture -D 1`): window captures (`-l`) never include the strip.

## Server

The owner's server details (addresses, homelab notes, the casting TV) are in `CLAUDE.local.md`
(gitignored; read it if it exists). The account sees more than one server (the owner's and a
friend's shared one), so multi-server must keep working. `Scripts/plex.sh` needs `PLEX_SERVER`
in `.mezzanine-live.env`.
