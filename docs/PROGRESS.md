# Progress

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
