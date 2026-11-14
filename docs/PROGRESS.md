# Progress

Plan: `~/.claude/plans/eventual-plotting-storm.md` (M0 spikes → D design → M1–M13).

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

Open (M0):
- [ ] First package build (FFmpegBuild is a 380 MB clone).
- [ ] S2 engine matrix on all 12 Lab rows; compare against Infuse.
- [ ] S3 audio on each output.
- [ ] S4 endpoint captures (subtitle download/upload, poster select, timeline on a test item).
- [ ] S5 grid perf, S6 seamless next episode.
