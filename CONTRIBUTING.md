# Contributing to Mezzanine

Thanks for helping. Mezzanine is a native macOS 26 Plex client; the bar is "feels like Apple made
it", so UI changes get as much care as code.

## Before you start

- **Open an issue first** for anything bigger than a small fix, so we can agree on the approach.
- Read [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) (how it fits together) and
  [`DESIGN.md`](DESIGN.md) (the design system: graphite, lilac only for the primary action or
  selection, nothing centred, glass only on player controls).
- [`docs/ROADMAP.md`](docs/ROADMAP.md) lists planned work. Integrations with other services
  (Seerr, Sonarr, Radarr, Bazarr, Tautulli) must stay optional: Plex alone is a complete app.

## Set up

- macOS 26 on Apple silicon, Xcode 27.2.
- `cd MezzanineKit && swift test` runs the core tests (no network).
- Build: `xcodebuild -project Mezzanine.xcodeproj -scheme Mezzanine -destination 'platform=macOS' -derivedDataPath build.noindex/DerivedData build`,
  or open `Mezzanine.xcodeproj` and pick your own signing team.
- Debug builds are a separate app (`com.mezzanine.mac.debug`) with their own settings and sign-in.

## Rules that protect real servers

- **Never write watch history while testing.** Launch Debug builds with
  `-MezzanineNoActivity YES`: it turns off timeline and scrobble reports, which otherwise reach
  Plex, Tautulli, Trakt and anything else watching the server.
- Live tests are read-only. Opt-in live tests read credentials from `.mezzanine-live.env`
  (gitignored, mode 600); never commit tokens, and never put a token in a URL or a log.
- Choosing a *Plex* subtitle result writes a file on the server; test with internet results.
- Transcode flags start real server sessions: keep those runs short.

## Code

- Swift 6, strict concurrency. The app target is main-actor by default; `MezzanineKit` is not.
- Only `MezzaninePlayback` imports the playback engine; the app uses Mezzanine's own types.
- Plex JSON is loose about types: decode through the lenient helpers in `Lenient.swift`.
- Async loads that fill a list must drop answers from older requests.
- Lists use the item's identity, never its position (`.id(index)` breaks reloads).
- Every player action gets a menu item and a rebindable key; everything works from the keyboard.
- Add or update tests in `MezzanineKit/Tests` for logic you touch.

## Pull requests

- One topic per PR, a clear description, screenshots for UI changes (blur personal details).
- `swift test` passes and the app builds; CI checks both.
- Write user-facing text in plain, short sentences, sentence case, no jargon.
