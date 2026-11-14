# Mezzanine — notes for agents

Private native macOS 26 client for the owner's Plex Media Server (replaces Infuse). Read
`docs/PROGRESS.md` first (status and open items), then the approved plan
`~/.claude/plans/eventual-plotting-storm.md`, `docs/ARCHITECTURE.md` (once written),
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
Scripts/install.sh                        # Release build → /Applications/Mezzanine.app
```

Build output goes to `build.noindex/` (Spotlight skips it).

## Layout

- `MezzanineKit/` local SPM package, non-isolated code:
  - `MezzanineKit` — Plex client (plex.tv auth/resources, `ConnectionRacer`, `PlexServerClient`,
    models with lenient decoding), `AudioProfile`/`VolumeLevel`, later the GRDB index.
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
`-MezzanineAutoSeek <s>` `-MezzanineAutoClose <s>` `-PlayerChromePinned YES`
`-PlayerOptionsOpen YES` `-PlayerOptionsPage search|subtitles|audio` `-FindSubtitlesChoose YES` (picks the first non-Plex result; local only) `-PlayerFullScreen YES` `-PlayerKeyScript "i,c,shift+right,!snapshot"`
(real key events through the router; menus ignore keys while the app is in the background, so
⌘ items use `!action`) `-ScrubHoverAt 0.6` `-SnapshotNoClipboard YES`; detail:
`-MezzanineOpen <ratingKey>` `-DetailSection cast`; windows: `-MezzanineOpenWindow shortcuts|settings`
with `-settingsTab shortcuts`. Debug builds are `com.mezzanine.mac.debug` (own container,
defaults and Keychain item), so test runs never change the installed app's settings or sign-in; delivery: `-PlayerQuality remux|convert|8000` `-ForceDirectFail YES`
(each starts a real transcode on the server: keep runs short, let the player close itself
(`-MezzanineAutoClose`) so the session stops, and check `Scripts/plex.sh pms /transcode/sessions`).

Shelves: `-HomeSeedShelves YES` (smart shelf, collection, hidden row), `-HomeEditing YES`,
`-HomeKeyScript "down,opt+down,space"`, `-SmartShelfSheet YES`, `-CollectionPicker YES`,
`-QuickOpenQuery "after"` (`_` for empty). Window snapshots of an attached sheet fail: capture
`-MezzanineOpenWindow sheetPreview -SheetPreviewKind rules|picker|artwork|opensubtitles` instead.

Subtitles: Find Subtitles' sources live in `MezzanineKit/Subtitles/`; the keys in the Keychain
(`<bundleID>.subtitles`). Never choose a Plex result while testing (it writes a sidecar on the
server); internet results only write under the Debug container's Application Support.
Debug builds open onboarding unless launched with `-onboardingComplete YES`.

SwiftUI gotcha: never mutate a `@Binding` array twice in one transaction (remove, then insert):
the second read sees the stale array and duplicates the element. Build the new array, assign once.

Full screen: AppKit moves the title bar into a separate window and keeps it as an opaque band over
the content even with the toolbar hidden (pinned, or revealed with the menu bar). While the player
owns the window, `WindowChrome` sets `.autoHideToolbar` and also hides that strip window outright,
re-applying on full-screen, key, screen and app-activation changes. Verify with full-display
captures (`screencapture -D 1`): window captures (`-l`) never include the strip.

## Server

Owner's server "Example Plex Server" (PMS 1.43.5, a homelab container): LAN
`https://192-168-1-20.<hash>.plex.direct:32400` (resolves fine through Pi-hole) and
`https://plex.example.com` (NPM, HTTP/2). The account also sees a friend's shared server, so
multi-server must keep working. Library facts and read-only DB query recipes:
`the owner's private homelab notes`. Homelab rules: the `homelab` skill.
