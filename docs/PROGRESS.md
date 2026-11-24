# Progress

## Where things stand (2026-11-15)

Done and installed: M1–M9, M11–M13, multi-source Find Subtitles, app icon, stability sweep,
picture size, prewarm, mini player, new-episode notifications, Google Cast, full-screen chrome
watch, and distribution: Sparkle updates, the DMG installer and release CI (see below).
Ship with `Scripts/release.sh <x.y.z>` (CLAUDE.md ▸ Releases and updates). Next features:
`docs/ROADMAP.md` (Plex-only features first, then optional Seerr, Sonarr/Radarr, Bazarr,
Tautulli and Playbill integrations); the owner picks the order.

Open, waiting on the owner:
- API work, deferred by the owner: OpenSubtitles and Subdl keys (Find Subtitles skips those two
  sources until keys are entered in Settings); M10 Trakt (needs the owner's Trakt API app).
- First live run of Translate (on-device language download).
- Audio profiles on each output (2.1 speakers, AirPods, MacBook, HDMI receiver), as the owner
  watches.
- Cast's Connecting/Cancel and failure panels haven't been seen on the TV (only on the Mac).
- Whether the logo still goes missing in full screen (see the grey-band entry).

Next (owner, 2026-11-16): the phone-as-remote spike (ROADMAP 3.7), then the roadmap order. Later:
a GitHub Pages website that looks professional and asks for donations.

## 2026-11-24 — 0.4 under way: sidebar, top bar, card actions

Plan for 0.4 to 0.6: `~/.claude/plans/immutable-crunching-aho-of-578ae7c0-c3a6-4148-b2ee-a5d1cf805ade.md`
(owner-approved: "Watching + map" sidebar, "useful controls" top bar, three releases).

- Built: `Sidebar`, `PinnedStore`, `ShellToolbar`, `TitlesPage` (collections, pinned pages),
  `TitleActions` (card menus, Item menu, W), recent searches, Home's kind switch and facts.
  `LibraryIndex.count(_:)` shares its WHERE with `items`; `LibrarySync.refresh` re-reads a title
  after a mark (the incremental sync misses unwatched marks).
- Differs from the plan: the sidebar asks `/hubs/continueWatching/items` itself rather than sharing
  Home's hub; both lay the same stops and removals over Plex's answer.
- Found on the way: In Progress never matched shows; ⌘Return on a title page played the page under it.
- Checked on screen (Debug, owner's OK): Home, slices, collections, the activity popover, the
  sidebar's arrow keys (a printed selection after each key), 900 × 600, full screen in and out
  (muted). Fixed from it: rows showed through the server line, a slice whose library was closed
  had no row, a Play disc on collections, a doubled Unwatched chip, clipped popover text. The Debug
  index dropped Courses on connect (0.3.4); no duplicate-geometry faults logged.
- Not checked: the pointer (Continue's Play disc, pin drag), VoiceOver, larger text, Increase
  Contrast, offline, volume above 100 % by ear, the version in Plex's dashboard. Remove from
  Continue Watching has never been sent to the server: try it once on a title the owner names.

## 2026-11-24 — Fixes from field diagnostics (for 0.3.4)

Found by reading the Mac's reports and the unified log (AetherEngine logs there in Release, subsystem
`de.superuser404.AetherEngine`) after a few days' use. No crash report since 0.3.3.

- Volume above 100 %: the boost sits in the engine's shaping, and each change rebuilds the session.
  The owner's 110, 120, 130 % and back rebuilt it six times; the film advanced 2 s in 8.5 s. Boost is
  now built in steps of √2 in gain (`VolumeLevel.builtInBoostDB`), the player's own volume takes
  back the rest, and shaping changes settle for 0.4 s first (the dialogue slider too). The cost: the
  limiter can work up to 3 dB harder than the level needs until the next load. Same key presses on a
  silent test file, real `MezzaninePlayer`, no window: six rebuilds before, one after; loudness exact.
- Disk writes: macOS reported 2.1 GB written in 10.6 h. Every sync loaded and sorted all episodes
  to count them (14.8 MB spilled to disk each time on the owner's index); `LibraryIndex.count(section:kinds:)`
  writes nothing.
- A library removed from Plex stayed in the index (924 Courses titles in search and smart shelves).
  Connecting now drops sections missing from a successful, non-empty list.
- Plex was told version 0.1.0; `PlexIdentity` now reads the app's own.
- Checked later in the Debug app, except the volume by ear and the version at the server. The duplicate
  `matchedGeometryEffect` source in Continue Watching is fixed in 0.4.

## 2026-11-16 — Screen dimmed during playback (0.3.2)

- Owner: the display dimmed and slept mid-film without a key press. AetherEngine sets
  `preventsDisplaySleepDuringVideoPlayback` only on its software renderer; on the native AVPlayer
  route (most files) nothing asked macOS to stay awake, and Mezzanine didn't either. `KeepAwake`
  now holds a `ProcessInfo` activity (`.idleDisplaySleepDisabled`, `.userInitiated`) while a video
  plays in the player or the mini player, loading and seeking included (letting go during a
  rebuffer after a long idle stretch would blank the screen at once); released on pause, close and
  casting. Verified with `pmset -g assertions`: PreventUserIdleDisplaySleep and
  PreventUserIdleSystemSleep while playing, none paused or closed.

## 2026-11-16 — Phone remote parked

- After 0.3.1's plex.tv registration (verified: plex.tv lists Mezzanine as a player with its LAN
  address, like the iPhone's own entry), the iPhone's cast sheet still showed only the Google TV.
  Checks: a logger on the Companion port saw no request from the Plex app (Safari on the phone did
  reach it, so the network is fine); the Debug build logged no GDM search from the phone (only the
  server's); no Plex Bonjour services exist on the LAN. The 2025 Plex mobile apps dropped casting
  to Plex players (Plex forum reports). Owner: skip the remote for now (ROADMAP 3.7). Remote control
  is now off by default (next release); the plex.tv device "Mezzanine" stays in the owner's
  Authorized Devices until removed there.

## 2026-11-16 — Phone as a remote: Plex Companion (0.3.0)

- Owner asked for the remote spike first (ROADMAP 3.7). Research (plex-mpv-shim, Music Assistant's
  Plex Connect, the Plex wiki): players advertise over GDM (UDP 32412, 239.0.0.250; HELLO/BYE to
  32413) and serve `/resources`, `/player/playback/*` and `/player/timeline/*` over HTTP; controllers
  send commands directly to the player and get timelines POSTed to their `/:/timeline`.
- Built `MezzanineKit/Companion/` (GDM over BSD sockets: NWConnectionGroup would need the multicast
  entitlement; a minimal HTTP/1.1 server on NWListener; the protocol actor with subscribers and
  timelines; 7 unit tests) and `RemoteControl` in the app (commands to the player and coordinator,
  which gained a start time for "play from"). Settings ▸ Playback switch, on by default.
- Verified: GDM replies; the PMS searches every few seconds and lists "<the Mac's name> (Debug)"
  at `/clients` (port 32500); `Scripts/companion-check.py` (a scripted controller) played The Wild
  Robot from 10:00, paused, seeked to 20:00, resumed, polled and stopped, with 26 timelines in the
  right states and command ids.
- From the iPhone (on the 2.4 GHz network): "No devices found" was Pi-hole blocking
  `config.claspws.tv` (allowlisted with the owner's OK); then the cast sheet listed only the Google
  TV: the Plex mobile apps list players from plex.tv's device list (the iPhone's own entry has
  `provides=…player,pubsub-player` and its LAN address), never from GDM. Silently linking a player
  with the account token was refused by the safety check (it would authorize a device without the
  owner), so 0.3.1 asks: Settings ▸ Playback ▸ Show in Plex Apps… opens Plex's approval page; once
  approved, every launch publishes the LAN address (`CompanionRegistration`).

## 2026-11-16 — Public repository

- Owner asked to make the repo public with screenshots (profile name blurred) and releases.
- Audit of all 66 commits: no secrets (the one access token in a fixture was always redacted).
  Personal details were there: design-review captures showing real profiles and the server, and
  the home public IP, LAN IP, plex.direct id, machine id, server name and domain in fixtures and
  docs. Owner chose to keep the history but scrub it: `git filter-repo` dropped
  `.impeccable/review/` from every commit and replaced those strings with neutral values
  (TEST-NET IP, `plex.example.com`, "Example Plex Server"), commit messages included; tags
  re-pointed; force-pushed. A bundle of the old history is kept privately on the owner's Mac.
- Owner-specific notes (server, homelab, casting TV) live in the gitignored `CLAUDE.local.md`;
  review captures stay local (gitignored); `Scripts/plex.sh` reads `PLEX_SERVER` from the env file.
- Added: README with framed screenshots (`Scripts/screenshots/`: capture, then frame with the
  profile row blurred), MIT LICENSE (owner's pick, as Playbill), THIRD-PARTY-NOTICES, CONTRIBUTING,
  SECURITY, issue templates, CI on push/PR (free once public), GitHub Releases on this repo for
  every version (`Scripts/github-release.sh`; backfilled 0.2.0–0.2.3). The Sparkle feed stays in
  `mezzanine-releases`.

## 2026-11-16 — Continue Watching kept the finished episode (0.2.3)

- Owner: after True Detective E1 ended and E2 autoplayed, closing the player left E1 in Continue
  Watching until a restart. The server was right (Plex DB: E1 scrobbled 12:18:32, E2 stopped at
  7:06 at 12:21:12) and Home did reload after the close (logged), but every poster row used
  `.id(column)` for ScrollViewReader, which overrode the item key: when a reload reordered the
  row, the old cards stayed on screen (the hero, read straight from the model, was already right).
  Rows now keep the item key and scroll by it (Home shelves, the three library layouts, Courses).
- Hardening: Home lays the last two minutes of local stops over Plex's continue rows
  (`ContinueWatching`, unit-tested) and reads Plex again six seconds after a stop, in case Plex
  answers before it has processed the last report; the episode that ends before Up Next is now
  recorded in the index when the next one starts (it was only recorded on close), with an ended
  item counted at its full length.
- Verified in a Debug run (no activity sent): Rick and Morty S1E2 ended, S1E3 autoplayed, close:
  the row leads with S1E3 and S1E2 is gone; keyboard focus still scrolls the row.

## 2026-11-15 (night, late) — auto-updates, installer, release CI

- Sparkle 2.10.1 (Release builds only): feed and DMGs in the public `ahamedzoha/mezzanine-releases`
  repo (owner's pick; the source stays private), EdDSA key in the login Keychain (account
  `mezzanine`, separate from another project's key found there). Sandbox set-up: installer
  launcher service, mach-lookup exceptions, Sparkle's helpers re-signed with our identity.
  Downloads in the background and installs on quit by default; an update alert never shows over a
  film (gentle reminders defer it until the film closes, mini player included). Mezzanine ▸ Check
  for Updates…, Settings ▸ Updates. HIG review: fixes applied (switches follow Sparkle's state,
  wording, Check Now with progress, icon).
- DMG: dmgbuild (pinned with hashes), light wall with the lilac lamp glow and arrow; Finder draws
  labels dark over a background picture, so a graphite wall was unreadable (tried).
- CI (owner's pick: tags and manual only, Mac minutes bill 10×): `Release` workflow on GitHub's
  `xcode-27` image with Xcode 27.2: kit tests, build (build number = commit count), sign, DMG,
  Sparkle signature, staged to the public repo through a write deploy key scoped to it; the public
  repo's Publish workflow makes the Release and appcast and resets its history. Secrets: the Apple
  Development identity as .p12 (expires 2027-08-27), the Sparkle key, the deploy key.
- No Developer ID certificate, so no notarization: first install needs Open Anyway once (README in
  the releases repo); updates install without it.
- Verified end to end: 0.2.0 shipped with `--local` (26 MB DMG; CI on its tag saw it published
  and stopped), installed from the DMG; 0.2.1 shipped through CI (green in ~6 min: kit tests,
  build, signing, DMG, publish; the first try failed only at publish because the runner's
  unauthenticated GitHub meta call was rate-limited, now the host key is pinned). The installed
  0.2.0 found 0.2.1 (release notes rendered in dark mode), installed it and relaunched: 0.2.1
  (59), signature valid, no quarantine, still signed in, no Keychain prompt.

## 2026-11-15 (last) — full-screen grey band, icon cache

- Owner's report: in full screen a grey bar sometimes stayed at the top after the menu bar slid
  in and out, and the title logo went missing after a few full-screen/window switches; switching
  Spaces fixed both. The bar in the screenshot is exactly 52 pt of #1C1C1C: the toolbar's strip,
  shown again and pinned, over the top of the film where the logo sits. Traces showed SwiftUI
  re-showing the toolbar on its own while the film owns the window, and AppKit silently dropping
  the auto-hide-toolbar option. The chrome was re-applied only on a few notifications (a Space
  switch is one). Now, in full screen, `WindowChrome` re-applies whenever the toolbar's visibility
  changes (KVO), the strip window moves, resizes or is replaced, the title bar loses its
  transparency, and on a 1 s check. Not in a window: hiding the toolbar there resizes the window
  by 20 pt (tried, reverted). The exact trigger didn't reproduce in scripted runs (real
  pointer reveals, toggles, page switches behind the player); forced drift recovers within a
  check, with no re-apply loops. Owner to confirm the logo stays.
- Icon cache: three stale build copies were registered with Launch Services; unregistered,
  re-registered the installed app, cleared the user and system icon caches.

## 2026-11-15 (late) — HIG review fixes: Google Cast, mini player, notifications

- Cast: the button's menu is now a "Play On" picker (This Mac + each TV, current one checked;
  "Looking for TVs…" names the Local Network permission), mirrored in Playback ▸ Play On.
  Connecting shows Cancel; a failure offers Resume on This Mac and Try Again (Try Again reuses
  the remembered stream choice). The position line seeks on click and is adjustable for
  VoiceOver; state changes are announced; the key hint follows rebinding; keys the TV can't
  take say so. Seek and volume are clamped; a load replaced by another is cancelled.
- Mini player: VoiceOver sees one button with the title, state and time, plus Expand/Play/Close
  actions; buttons stay reachable while hidden; ↑/↓ volume works on the tile; the end of a film
  is announced. (The tile's body was split: the long chain timed out the type checker.)
- Notifications: alerts only (no sound); the delegate is set at launch so a click that launched
  the app opens the show; a click while a film owns the window waits until it closes; while
  watching they go to Notification Centre without a banner; more than six shows → five and a
  summary; the checked mark waits while the prompt is unanswered; Settings re-reads the status
  when the app comes forward and offers Allow Notifications… before the first answer.
- Checked: build, kit tests (64), mini tile capture, test banner (Archer S14 E9 with poster).
  No TV cast in this round.

## 2026-11-15 (night) — search panel, owner's bug reports

- Search: results for an earlier keystroke could land last and replace the newer ones ("south"
  showed "so" matches: course "solutions"). Every search now drops its answer when a newer one
  started. Live: "south" → South Park first.
- Search panel (owner asked for Trove's): typing opens a panel under the toolbar field over the
  page (titles, people chips, episodes, See all), ↑↓ ↩ ⌘↩ esc; See all opens the old grid.
- Season chips: picking a season while another loaded could show the other's episodes under the
  wrong chip (Archer: Season 4 highlighted over Season 5's list). Fixed the same way; watched
  episodes now wear the ✓ badge and "Watched".
- Courses: clicking rows while a folder loaded stacked siblings into the path and mixed lists.
  A click now opens from the list on screen; stale loads are dropped; each folder is its own list.
- Search panel didn't show on title pages (a NavigationStack draws pushed pages over overlays on
  the stack; Quick Open had the same bug). Both now hang on the top page; verified with captures
  on a title page, a library page and Home. Ranking: titles starting with the text, then a word
  of the title, then the rest; lessons (personal-media libraries) after films and shows.
- Google Cast (no SDK on macOS: Bonjour discovery, Cast v2 over TLS with a hand-written protobuf
  codec, Default Media Receiver, Plex HLS with a transient token). Live on the owner's
  "Family room TV" (SmartTV 4K): H.264 stereo film played from 10:01 and came back to the Mac;
  Severance (HEVC Main 10, AAC 5.1) failed as copied, so a TV that refuses the file's own
  streams gets H.264 + stereo AAC (remembered per TV), which played. Bugs found and fixed in
  testing: browser parameters, a transcode stop cancelled with its task, resume point after a
  failed cast, position between the TV's reports, stale media statuses, quitting while casting.
- New-episode notifications (owner OK'd the prompt): after each library sync, shows being
  watched (an episode seen in the past year) that gained unwatched episodes get one notification
  with the poster; click opens the show. Settings ▸ Playback ▸ New episodes. Debug test posted
  (Archer S14 E9) after the prompt was allowed.
- Mini player (owner's pick: corner of the window): ⌥M shrinks the film into a 340 pt tile while
  browsing; click or ⌥M grows it back. Verified with captures (shrink, browse, expand).
- Picture size: Fit / Fill / Zoom (Z, ⋯ ▸ Picture, Playback ▸ Picture Size), kept per film or show.
- Faster starts: a title page warms its Play target's file half a second after opening (Home
  warms a poster that keeps focus 0.7 s); home network only, 8 MB each, never for downloads.
  First frame after load: cold 0.8–1.4 s, warmed 0.20–0.22 s (Nobody, Parasite).
- Stability sweep: scripted walkthrough of 13 pages with captures (Home, each library layout,
  Courses folders, title pages and seasons, search and ⌘K on title pages, Downloads, Settings,
  the player panel): all render right. A read-only audit found 24 more places where an older,
  slower answer could land last; all fixed: play requests (a request counter), profile and
  server switches (a connect counter; the account changes with its client), library grids,
  library sync (one pass at a time), Home shelves, episode refreshes, Up Next, suggestions,
  scrub previews per title, Find Subtitles after a title change, artwork kind, downloads
  (ordered manifest writes, profile captured, no orphaned extras, pause vs resume), generated
  subtitles' save timer and listener handle, translations per language pair, the key check,
  folder errors, the onboarding wall, shared image fetches.
- Mark as Watched on a title page waited for a full library re-read before the screen changed
  (the mark reached Plex at once; the owner clicked twice, so one episode shows 2 views). The
  row, its ✓ and the season ticks now change instantly; the library catches up in the background.
- Profiles: avatars never loaded (the image session refused plex.tv's redirect to gravatar).
  Token-free image requests may now follow https redirects; the token still never leaves the
  server's host. Avatars show in the sidebar and beside every profile in the menus.

## 2026-11-15 (evening) — M13 finish: performance pass, full HIG sweep, architecture doc

- Performance (optimized build, LAN, `-MezzanineNoActivity`):
  - Launch: app ready at 0.4 s; Home shelves loaded at 2.5 s (network hubs). Home loaded three
    times at launch (server, index, sync each changed its task id): now debounced into one reload.
  - Idle Home: 0.3 % CPU, energy impact 0.4.
  - Playback, 1080p HEVC with AAC 5.1 (bridged, shaped): 6.5 % of one core, energy impact ~8.
    With Generate from Speech on: 7.5 %, ~9.4.
  - Up Next into the next episode: 33 ms to load, first frame 471 ms later (prewarm works; S6 met).
  - Cold first frame of a new title varies 2.3–4.7 s after load (worth a look at the engine's
    probe/bridge start; open).
  - Bug found: ⌥G pressed while a title loads was dropped. Now it starts when the title is on screen.
- Full HIG sweep (Needs Work) applied:
  - Player menu keys (bare letters) only live while a film plays in the key window: typing in
    Settings or a sheet never pauses or mutes. Closing the window stops the film.
  - Playback menu always visible (dimmed without a film), grouped: Audio and Subtitles ▸, Sound ▸.
  - The section open at quit comes back at launch (not title pages or the player).
  - OpenSubtitles/Subdl sheets: keys trimmed, half an account can't be saved, Remove Key, the key
    field focused.
  - Shortcuts: Restore Defaults asks first; window resizable and not reopened at launch; the
    reference lists Downloads, Play and window keys and the Full Keyboard Access note.
  - Find Subtitles: clicks right after a re-sort are ignored, two-line release names, other rows
    locked while one loads, "every source is turned off" message.
  - Increase Contrast: the focused card gains a 2 pt ink outline.
  - Settings: why Sound adjustments are off for receivers and AirPods, Night mode two-line label,
    the skip key named from its binding, friendly connection names, "None" not "—", a progress
    spinner for Read Library Again, taller minimum window; menu titles without key hints;
    View ▸ Show/Hide Details tracks its state.
- `docs/ARCHITECTURE.md` written (module map, data flow, playback, persistence, gotchas, and
  where the code differs from the plan).
- Still open: S3 audio on each output (needs the owner at each device); Translate's first live
  run; OpenSubtitles/Subdl keys; new-episode notifications (needs the owner's OK); not built:
  mini player / pop-out, aspect and zoom, Google Cast, Trakt (needs the owner's API app).

## 2026-11-15 (afternoon) — M12 on-device subtitles, new app icon

- App icon replaced by the owner's pick: stacked glass slabs with a standing play triangle
  (hand-built from a Gemini reference; `Scripts/make-icon.py` writes the Icon Composer document).
- M12, owner's choices: translation replaces the line; generating starts only when asked; Match
  Timing is a row under Timing. All in ⋯ ▸ Subtitles, Playback menu toggles, ⌥G / ⌥T / ⌥H.
- Generate from Speech: AetherEngine's audio tap (centre channel, ~10 s ahead) into
  SpeechAnalyzer; lines built like a subtitler's (two rows, ~6 s, sentence and pause breaks) and
  kept per title (`generated.srt`), back on screen next time; carries to the next episode.
- Live on Severance S1E2 (no play history): continuous for 90 s, 27 lines, starts within ~0.3 s
  of the official SRT once word starts were tightened (raw recognizer starts absorb the pause
  before a word: up to 1 s early).
- Match Timing to Speech: words matched against the subtitle (any language falls back to speech
  spans). Live: Timing +3.0 s → −0.1 s after 6 lines (~23 s of dialogue). Bug found and fixed in
  testing: a seek now restarts the listening window.
- Translate: `.translationTask` on the stage, lines translated 90 s ahead, swapped in when ready.
  Not live-tested: no language pair is installed on this Mac yet, and the first use shows the
  system's download prompt.
- Kit: `OnDevice/` (SpeechListener, CueBuilder, SRT, TimingMatcher, TranslationPieces) with 13
  tests, plus an opt-in real-recognizer test (`MEZZANINE_SPEECH`).
- Design finish review (fix) and HIG review (Needs Work) applied in one batch: running tasks hold
  the readout (model %, lines matched), problems stay 5 s and live on in the panel, Match says why
  it's disabled (row and menu), menu Generate/Match swap to Stop…, Translate names its language,
  Stop Generating and failed starts put back the previous subtitle, a refused translation pair
  retries on track change, switch rows are whole-row and hueless (One Lilac Rule; also Background
  box and Night mode), readout copy in the house style, privacy wording made exact.

## 2026-11-15 (overnight) — Find Subtitles from every free source

- Owner asked for subtitles searchable from OpenSubtitles and other free popular sources
  (M12 AI subtitles paused for it; no M12 code yet).
- Find Subtitles (⋯ ▸ Subtitles ▸ Find Subtitles…, ⌥F, Playback ▸ Find Subtitles…) asks every
  source at once and fills as each answers: Plex (the server's own OpenSubtitles search),
  OpenSubtitles.com (owner's free API key, optional sign-in, file-hash match from two 64 KiB
  range reads), Subdl (free key; ZIP archives, season packs matched to the episode) and
  Addic7ed through Gestdown (keyless, TV only). Ranked: made for this file, then language
  order, then downloads. Podnapisi left out (unreachable from here).
- Plex results are saved on the server as before; the others are kept on this Mac
  (Application Support ▸ Mezzanine ▸ Subtitles ▸ server ▸ title), load every time the title
  plays (streamed, downloaded or offline) and come back on screen if they were last chosen.
- Settings ▸ Subtitles: one or two search languages, Plex/Addic7ed toggles, Set Up… sheets for
  the OpenSubtitles and Subdl keys (Keychain), Check shows downloads left today.
- Verified live (read-only, no play history): Severance S02E09 found on Plex and Addic7ed, an
  Addic7ed file chosen, shown, kept, and re-selected on the next play. OpenSubtitles and Subdl
  wait for the owner's keys.
- Kit: `Subtitles/` (SubtitleSearch, sources, OpenSubtitles hash, minimal ZIP reader, UTF-8
  conversion), 7 new tests + a live Gestdown test.

## 2026-11-15 (late) — M7 Home shelves, smart shelves, Quick Open

- Owner picked **Edit in Place** on the decision page (over typed rules in ⌘K and a separate
  composer window). Contract: `.impeccable/surfaces/mezzanine-home-shelfeditor-swift.md`.
- Edit Shelves (⌘E): shelves fold into strips (matched geometry), drag or ⌥↑/⌥↓, Space hides,
  Return renames or edits rules, ⌫ removes, everything undoable (⌘Z), Restore Defaults asks
  first; changes save as they happen per server + Plex Home profile. Add Shelf: Plex rows (per
  library), a collection (searchable picker), a playlist, a smart shelf.
- Smart shelves answered by the local index (11 fields, sort, size) with a live preview.
- Libraries gain a Shelves layout (⌃⌘5) with Plex's own rows by default and the same editor.
- Quick Open (⌘K): titles, Play Next Episode of a show, Resume, Go To, shelf actions.
- Design finish review (fix) and HIG review (Needs Work) applied in one batch: undo/confirm,
  focus rings under Full Keyboard Access, selection follows focus, VoiceOver actions and
  announcements, modal/Quick Open guards on menu shortcuts, drag that can't stick, Reduce
  Motion crossfade, unfold in the new order without a reload, picker keyboard and errors.
- Bug found in testing: two mutations of a `@Binding` array in one transaction duplicated a
  moved shelf (now one assignment; layouts de-duplicated on load).
- M8 artwork picker: every poster and background Plex offers, used in Mezzanine only (default)
  or on the Plex server (named button, stays open with what it replaced). HIG review applied.
- M9 profiles: sidebar footer and Mezzanine ▸ Switch Profile, PIN sheet. Fixed: plex.tv's
  `{"users": [...]}` reply never decoded, so profiles (and onboarding's profile step) were empty.
- Fixed before shipping: menu-bar commands have no environment objects (the profile menu
  crashed at launch in Debug); stores are passed in.
- M6 leftover: post-play for films (suggestions at the credits, no autoplay); setting in Playback.
- M11 offline downloads (owner picked By Title): original-quality downloads, resumable, keep
  rules, local playback, offline mode, offline progress sent on reconnect. Design review (fix)
  and HIG review (Needs Work) applied: removals ask and go to the Trash, VoiceOver progress and
  actions, ⇧⌘D / ⌘⌫ / ⌥⌘L, one vocabulary, dissolve and arrival line fixed.
- M10 Trakt skipped for now (owner). Next: M12 AI subtitles; new-episode notifications need the
  owner's OK for the macOS permission prompt.

## 2026-11-15 (night) — player keys, previews, fallback

- Rebindable player keys (28) with Playback menu items, Settings ▸ Shortcuts, Help ▸ Keyboard
  Shortcuts (⌘/); router ahead of the menus (typing in fields is safe). New: 1-min jumps,
  chapters, frame step, speed keys, previous episode, mute, A/C track cycling, G/H subtitle
  timing, 0–9 jumps, playback info (I), ⌘⇧S snapshot to Pictures ▸ Mezzanine.
- Scrub hover previews anywhere in the film (second reader), chapter names and ticks.
- Full screen: no title-bar band over the picture.
- Delivery: direct play → Plex remux → Plex convert, automatically; ⋯ ▸ Quality caps for slow
  links; Convert on the Server in the failure panel; version picker for multi-file titles.
  Live-verified: remux copy/copy, 8 Mbps hardware convert, sessions stop on close.
- Next: HIG leftovers (⌘] forward, semantic fonts), then M7 (Home shelves, ⌘K).

## 2026-11-15 (later) — M2 detail + M3/M6 player reviewed and fixed

- Design finish review (**fix**) and HIG review (**Needs Work**) of the detail page and the Bare
  Picture player; every material item applied:
  - Up Next: picture sized to the video's aspect on the 48 pt gutter, rounded, never overlapping
    the card; card shares its top edge; other chrome hidden except close; Reduce Motion handled.
  - ⋯ panel: solid graphite body over the glass rim, hairline border, scrolling track lists, clear
    of the Skip button. Skip no longer covers the AirPlay / PiP buttons.
  - Paused label in the time row; tighter time stack.
  - Detail: one-click episode play; ↑/↓ section scrolling (movies too); W on a show targets the
    episode in hand, never the series; "Mark Show Watched" + confirmation; captioned progress;
    episode progress no longer under the play disc.
  - HIG: Now Playing, PiP, AirPlay, retry on failure, Esc leaves full screen first, Playback menu
    (Next Episode, PiP, Speed), Settings accessibility, Sign Out confirmation.
- Fixed a crash on every play: the Now Playing artwork handler was main-actor isolated but
  MediaPlayer calls it on its own queue (built in a `nonisolated` helper now).
- Still owed from HIG: ⌘] forward navigation, semantic (Dynamic Type style) fonts.

## 2026-11-15 — M1 done, M2/M3 underway

- **M1 index:** GRDB mirror + FTS5 of every library (Movies 275, TV 65 shows / 4,352 episodes,
  Courses 924). Full sync 3.2 s, incremental 0.17 s, search 1 ms. Libraries read only the index:
  Posters / Wide / List / Folders, filter menu + chips, 7 sorts, per-library memory, watched marks.
  Settings ▸ Library: show original (pre-Kometa) posters, resolved once per title and cached.
- **M1 onboarding:** Poster Wall (owner's pick): sign in → server → Plex Home profile (PIN) →
  library warm-up. Design review **fix** + HIG **Needs Work** → all material items fixed
  (see commit f41daf6). Onboarding shows once (bug that reset it each launch fixed).
- **M3 core:** play-history reporting (timeline heartbeat, stop on close/quit, watched past 90 %),
  live-verified on a throwaway lesson and reverted; `-MezzanineNoActivity` disables it.
- **M2 detail pages:** hero, facts, seasons/episodes, cast, extras, related; Return/double-click
  open, Space plays, ⌘[ / Esc back. Still owed: M2 finish review + HIG pass.
- Player: owns the whole window (no toolbar band), no 30 s resync flicker, snappier motion.

Plan: `~/.claude/plans/eventual-plotting-storm.md` (M0 spikes → D design → M1–M13).

## 2026-11-14 — Design direction chosen

Impeccable direction round (Opus): the owner picked **Bias Light** — each film lights the
room (UltraBlur four-corner wash over graphite, clearLogo titles, one lilac accent). Contract
in `.impeccable/surfaces/mezzanine-home-homeview-swift.md`; PRODUCT.md written. DESIGN.md is
written by the documenter after the Home surface is built and reviewed.
Owner added: AirPlay is a must, Google Cast wanted (Miracast has no macOS support).
Owner runs Kometa for covers (baked-in overlays) → M8 artwork: offer "clean posters"
(the agent original from `/library/metadata/{id}/posters`) as a local display option.

Home build (code-led) → finish review: **fix**. Applied in one batch: toolbar search (⌘F),
Recently Added under Continue Watching, stronger room light, hover never scrolls, Reduce
Motion honoured, top dissolve under the toolbar, left-aligned room messages, no focus ring
(lift + lilac + play disc), toolbar controls no longer lilac, Go menu ⌘1…⌘9, poster size in
View menu (⌘= / ⌘−), focus returns after the player, play grows from the played poster,
hero grows for details. Verdict pass skipped per the cost budget.

DESIGN.md + `.impeccable/design.json` written from the built world; impeccable reverted to
Sonnet. **HIG review: Needs Work → fixed** (highs 1–6 and most mediums/lows): focus outlines on
capsule buttons and re-enabled focus effects on real buttons; Playback menu (plain-key items
exist only while the player is open, so they never eat typing), View ▸ Show Details ⌘I,
Playback ▸ Play ⌘↩; shell disabled + VoiceOver-hidden while the player is open, stage is modal,
Return swallowed in the player; search keyboard navigation and honest states (too short,
failed + retry), query cleared by sidebar/Go; VO default action + progress value on cards;
close button label; HUD stays for VoiceOver and reappears on keys; adjustable scrub bar;
Settings scene (Account tab) and a 900×600 minimum window; Try Again on Home/Library/sections
errors; Increase Contrast (full-ink secondary text, stronger rules, outlined secondary
buttons); density items enabled only on libraries; plural fix; sign-in default/cancel keys;
cursor hides with the HUD. Deferred: GlassEffectContainer for the HUD (rebuilt in M3),
richer card context menus (M2), cards reachable by Tab under Full Keyboard Access (arrow keys
are the route; document in the M13 shortcuts sheet).

## 2026-11-14 — M0 started

Done:
- Repo scaffold (Trove-style raw xcodeproj with synchronized folders, local `MezzanineKit`
  package with `MezzanineKit` + `MezzaninePlayback` products; AetherEngine 7.67.0 exact,
  GRDB 7.12).
- Dev token via plex.tv/link PIN → `.mezzanine-live.env`; `Scripts/plex.sh` read-only helper.
- Real response fixtures (sections, movie/show pages, season, episode + markers + streams,
  movie detail + images, hubs, subtitle search, resources with tokens scrubbed).
- Plex client: identity headers, PIN sign-in, resources, Home users + switch, connection
  racer (LAN wins, remote waits a grace period, relay last, plain-http LAN fallback), server
  client (sections, paged items, incremental `updatedAt>`, detail with markers/chapters,
  children, all leaves, collections, playlists, hubs, search, Plex subtitle search), URL
  builder (part, photo transcode, BIF, redaction).
- `AudioProfile` per output kind + `VolumeLevel` (0–400 %, boost dB above 100 %).
- `MezzaninePlayer` adapter over AetherEngine; Lab window harness with the codec matrix.

Findings:
- **S1:** plex.direct resolves through Pi-hole (no rebind block). LAN identity 44 ms;
  `plex.example.com` also 44 ms over HTTP/2 (split DNS). No relay listed.
- Plex's own subtitle search works without an OpenSubtitles key (results scored, SDH flagged).
- Items carry `UltraBlurColors` (four corner colours) and `clearLogo` images: design material.
- Account sees two servers (owned + a friend's shared one) → keep multi-server.

- **Build:** GitHub git clones crawl at ~90 KB/s here (FFmpegBuild 380 MB), so
  `Scripts/spm-mirrors.sh` builds local tagged mirrors from codeload tarballs (seconds) and
  points SwiftPM and Xcode at them. Package.resolved still records the GitHub URLs.
- **S2 engine matrix (scripted, `Scripts/dev-run.sh -LabAutoMatrix YES`, muted, LAN):** all
  12 rows play. HW decode for H.264, HEVC (incl. 10-bit HDR10) and AV1 (M5); MPEG-4 ASP in AVI
  on the software path. Audio: AAC/AC-3/E-AC-3 (incl. JOC Atmos) stream-copied; DTS, TrueHD,
  Opus bridged to E-AC-3. Subtitles listed: dvdsub, pgssub, ass, srt. First frame 259–1949 ms
  (first load includes warm-up), seeks 63–664 ms. App CPU avg 25 % / peak 54 % of one core
  across constant loads and seeks, RSS ~320 MB. **Server transcode sessions: 0.**
  DV P10 AV1 presented as SDR on the SDR monitor (expected tone-map); HDR10 reported hdr10.

Open (M0):
- [ ] S2 follow-up: steady-state energy on a 2-hour film vs Infuse (Activity Monitor).
- [ ] S3 audio on each output.
- [ ] S4 endpoint captures (subtitle download/upload, poster select, timeline on a test item).
- [ ] S5 grid perf, S6 seamless next episode.
