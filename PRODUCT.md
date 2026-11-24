# Product

<!-- impeccable:product-schema 1 -->

## Platform

macos

Native macOS 26 app (SwiftUI with AppKit where needed), not a web wrapper. Apple's Human
Interface Guidelines for macOS are binding; an `apple:hig-reviewer` pass gates every UI
milestone.

## Users

- **The owner** (primary, daily). Runs the Plex server himself (homelab), knows his library
  intimately, lives on the keyboard. Watches mostly at the desk (MacBook Pro M5 built-in XDR,
  or a 1440p SDR monitor at arm's length), sometimes in bed with the laptop and trackpad in a
  dark room, occasionally sends to the living-room TV. Binge-watches series over days.
- **His wife** (occasional). Uses Mezzanine from her own macOS user account on her own Mac,
  signed in as her own Plex Home profile. Mouse/trackpad first, will not learn shortcuts: every
  keyboard path must have an obvious pointer path, and onboarding must work without help.

## Product Purpose

Watch the owner's Plex library on a Mac with no compromises: every file direct-plays (the
server never transcodes, the Mac stays cool), sound is loud and clear on whatever output is
connected, subtitles are always findable and right, and moving through the library and through
a season is faster and more pleasant than in Infuse, the current tool. Success: Infuse gets
deleted, and a week-long binge never needs the mouse or a settings trip.

## Positioning

A personal Plex client built around one real library and one real setup, not a generic
player. What a neighbouring app can't truthfully copy:
- Direct play for nearly every codec the library holds (FFmpeg demux + VideoToolbox through
  AetherEngine), so the homelab server never transcodes.
- Loudness tuned per output device (MacBook speakers, 2.1 desk speakers with the LFE folded
  in, AirPods with spatial audio kept, HDMI receiver passthrough), switched automatically.
- The library as the owner shapes it: his own shelves and smart rules over Plex's real
  structure (collections, playlists, libraries like Courses), answered instantly from a local
  index.

## Operating Context

- Server: the owner's Plex Media Server on the LAN (plex.direct) and remotely through
  `plex.example.com`; the account also sees one friend's shared server.
- Library: ~275 movies, 65 shows, a "Courses" folder-style library, Music (left to Plexamp).
  Mostly 1080p/720p SDR H.264/HEVC; many 5.1 tracks (AAC, E-AC-3, AC-3); embedded and
  sidecar subtitles in SRT, VobSub, PGS and ASS. Intro and credits markers exist for many
  episodes.
- Plex Home is on: profiles with optional PINs.
- Outputs in use: MacBook speakers, 2.1 speakers, AirPods/headphones, HDMI receiver or
  soundbar, AirPlay to the TV.
- Tautulli and the owner's Playbill newsletters read Plex play history, so plays must be
  reported accurately (and never during testing).

## Capabilities and Constraints

Confirmed for v1:
- Onboarding: Plex sign-in, server and Home profile pick, library warm-up, audio check,
  subtitle preferences. Under two minutes, every step skippable.
- Library: every Plex library in the sidebar, collections, playlists, browse by genre, year
  and person; grid density control; poster, landscape, list and detailed-list views; sort and
  view remembered per library; artwork picker; codec badges.
- Home: user-built shelves (Plex hubs, pinned collections and playlists, rule-based smart
  shelves), reorderable and per library.
- Player: direct play with server-transcode fallback; full keyboard map (rebindable, every key
  also in a menu); skip intro and credits by key, button or automatic rule; Up Next autoplay
  with countdown and per-show rules; "Still watching?" (optional); chapters; scrub previews;
  PiP, pop-out and mini player; speed; volume to 400 %; dialogue lift; night mode; audio and
  subtitle delay; stats overlay.
- **Casting is a must:** AirPlay to the owner's TV (native). Google Cast is wanted; macOS has
  no official Cast SDK, so it needs the open Cast v2 protocol and the TV-side decoder decides
  what direct-plays. Miracast has no macOS support (open decision: confirm the user accepts
  AirPlay + Cast).
- Subtitles: styled overlay, offset, sidecars, Plex's own subtitle search (OpenSubtitles via
  the server), OpenSubtitles.com directly, upload back to Plex; on-device translation and
  generated subtitles (M12).
- Trakt sync, Plex Home switching, offline downloads.
- Constraints: macOS 26 only; public, signed but not notarized (Sparkle updates); app sandbox;
  token never in URLs or logs; testing never writes play history.

## Brand Commitments

- Name: **Mezzanine** (chosen by the owner).
- Voice: **quiet and precise**. Apple-like, short labels, no jokes, the words get out of the
  way. Empty states and onboarding say what to do next in one line.
- Must not resemble the sibling apps Trove (gold, "dark screening room") or Alexandria
  (lapis), and must not borrow Plex's orange.

## Evidence on Hand

- Real library data and artwork through the dev token (`Scripts/plex.sh`), captured fixtures
  in `MezzanineKit/Tests/MezzanineKitTests/Fixtures/`.
- Per-item art: poster, background, clearLogo (title logo), UltraBlurColors (four corner
  colours from the art), cast photos, episode thumbnails.
- No testimonials, metrics or marketing claims exist; none are needed (private app).

## Product Principles

1. **The film is the interface.** Artwork, the picture and the sound lead; chrome appears when
   asked for and leaves without a trace.
2. **Never make the server work.** Direct play first; anything that would transcode is a
   visible, deliberate choice.
3. **Every action has a key, and every key has a visible path.** The owner never needs the
   mouse; his wife never needs the keyboard.
4. **The library is his, not Plex's defaults.** Shelves, order, density and artwork bend to
   the owner; Plex's real structure is never hidden.
5. **Binges are seamless.** The next episode, the intro skip and the right audio and subtitle
   tracks happen without a decision.

## Accessibility & Inclusion

- Full keyboard operation, VoiceOver labels on every control, Reduce Motion and Reduce
  Transparency honoured, Dynamic Type-friendly sizing where macOS supports it.
- Subtitles readable at desk and TV distance; hearing-impaired tracks clearly marked.
- A dark-room use case: no bright flashes on transitions, dimmed chrome during playback.
