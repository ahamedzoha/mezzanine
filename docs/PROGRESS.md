# Progress

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
