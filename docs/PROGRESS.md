# Progress

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
