---
name: Mezzanine
description: A native macOS 26 Plex client. A near-black graphite room lit by the film on screen.
colors:
  graphite: "#0E0F11"
  raised: "#1A1C20"
  raised-hover: "#24272C"
  ink: "#F2F2F0"
  ink-secondary: "rgba(242, 242, 240, 0.66)"
  ink-tertiary: "rgba(242, 242, 240, 0.46)"
  rule: "rgba(242, 242, 240, 0.14)"
  lilac: "#A08CFF"
  on-lilac: "#0E0F11"
typography:
  title-card:
    fontFamily: "Big Shoulders Display, SF Pro Display"
    fontSize: "92px"
    fontWeight: 800
    lineHeight: 1
    letterSpacing: "-1px"
  room-message:
    fontFamily: "SF Pro"
    fontSize: "22px"
    fontWeight: 600
  shelf-title:
    fontFamily: "SF Pro"
    fontSize: "17px"
    fontWeight: 600
  body:
    fontFamily: "SF Pro"
    fontSize: "14px"
    fontWeight: 400
  button:
    fontFamily: "SF Pro"
    fontSize: "14px"
    fontWeight: 600
  caption:
    fontFamily: "SF Pro"
    fontSize: "13px"
    fontWeight: 500
    fontFeature: "tnum"
  card-title:
    fontFamily: "SF Pro"
    fontSize: "13px"
    fontWeight: 600
  card-meta:
    fontFamily: "SF Pro"
    fontSize: "12px"
    fontWeight: 400
    fontFeature: "tnum"
rounded:
  badge: "4px"
  control: "8px"
  poster: "12px"
  panel: "16px"
  still: "12px"
  capsule: "999px"
spacing:
  xs: "4px"
  s: "8px"
  m: "14px"
  l: "20px"
  xl: "32px"
  xxl: "48px"
  gutter: "40px"
components:
  button-primary:
    backgroundColor: "{colors.lilac}"
    textColor: "{colors.on-lilac}"
    typography: "{typography.button}"
    rounded: "{rounded.capsule}"
    height: "34px"
    padding: "0 18px"
  button-secondary:
    backgroundColor: "{colors.raised}"
    textColor: "{colors.ink}"
    typography: "{typography.button}"
    rounded: "{rounded.capsule}"
    height: "34px"
    padding: "0 16px"
  button-secondary-hover:
    backgroundColor: "{colors.raised-hover}"
  poster-card:
    backgroundColor: "{colors.raised}"
    textColor: "{colors.ink}"
    typography: "{typography.card-title}"
    rounded: "{rounded.poster}"
    width: "150px"
  poster-card-focused:
    textColor: "{colors.lilac}"
  play-disc:
    backgroundColor: "{colors.ink}"
    textColor: "{colors.graphite}"
    rounded: "{rounded.capsule}"
    size: "34px"
---

# Design System: Mezzanine

## Overview

**Creative North Star: "Bias Light"**

Mezzanine is a dark room with one light source: the film you are looking at. A near-black graphite ground carries the interface; the focused title throws its own colour across it, the way a bias light washes a wall behind a television. Chrome has no hue of its own. Every colour on screen belongs to a film, its artwork or the room light derived from it. The single exception is one lilac, spent on the primary action and the current selection.

The system is quiet and precise. Type is SF Pro at small, exact sizes; titles without a logo are set once, large and heavy, like a title card. Facts are numbers rather than adjectives, joined by " · ". Nothing floats in the middle of the window: text and messages sit on a 40 pt gutter, left-aligned, below the toolbar.

Native macOS 26 is the material. Liquid Glass belongs to the system chrome and to player controls; content is solid.

**Key Characteristics:**
- Graphite room, never pure black; the room light follows focus.
- One accent (lilac), two jobs: primary action, current selection.
- Focus is lift, shadow, lilac caption, room light and a play disc. No rings.
- Left-aligned on a 40 pt gutter; one ruled caption of facts under each title.
- Solid surfaces over art; glass only on toolbar, sidebar and player controls.
- Every key has a menu item; every hit target is the whole control.

## Colors

A matte graphite room, warm-white ink, one lilac. All other hue is borrowed from the films.

### Primary
- **Lilac** (`colors.lilac`): the primary capsule button (Play, Resume, Skip Intro, Sign In), and the title of the focused poster, which marks the current selection. Nothing else is lilac. On a screen it appears on the primary button and at most one caption.

### Neutral
- **Graphite** (`colors.graphite`): the room, the window background, the floor of the room light, and type set on lilac or on the play disc.
- **Raised** (`colors.raised`) and **Raised Hover** (`colors.raised-hover`): poster placeholders, the poster well, solid secondary buttons and their hover.
- **Ink** (`colors.ink`): primary type, icons, the progress fill, the play disc.
- **Ink Secondary** (`colors.ink-secondary`): captions, card meta, messages. About 7:1 on graphite and still AA over the room light.
- **Ink Tertiary** (`colors.ink-tertiary`): quiet supporting marks only.
- **Rule** (`colors.rule`): the 48 pt by 1 pt hairline above the hero caption, separators.

### Room light (derived, not tokenised)
The focused title's four UltraBlur corner colours, each mixed 25% back toward graphite, are laid on a 2 by 2 mesh gradient at 0.74 opacity (0.36 under Reduce Transparency). A graphite ramp (0, 0.12, 0.62 opacity, top to bottom) pulls the lower room back to a steady ground so shelves always read on dark. With nothing focused the room is plain graphite.

### Named Rules
**The Borrowed Colour Rule.** Chrome carries no hue. Colour comes from artwork and the room light; the only exception is lilac.
**The One Lilac Rule.** Lilac is for the primary action and the current selection. Not for links, badges, toggles or decoration.
**The Steady Floor Rule.** The room light fades to graphite toward the bottom; text and posters never sit on saturated colour.

## Typography

**Title Face:** Big Shoulders Display (OFL, variable weight, bundled), fallback SF Pro compressed heavy
**UI Face:** SF Pro (system)

**Character:** SF Pro stays out of the way; the title card face is tall, narrow and loud, and appears only where a film has no logo of its own.

### Hierarchy
- **Title card** (800, 92 pt, tracking -1, capitals, up to two lines, scales to 50%): the hero title, only when a title has no clearLogo. Also the sign-in wordmark at 72 pt.
- **Room message** (600, 22 pt): loading, empty and error headings.
- **Shelf title** (600, 17 pt): the row heading on the gutter.
- **Body** (400, 14 pt): hero summary (ink at 86%, four lines, 560 pt measure), message detail (480 pt measure).
- **Button** (600, 14 pt): capsule labels.
- **Caption** (500, 13 pt, tabular figures): the hero's ruled caption and fact lines.
- **Card title** (600, 13 pt): under posters, one line.
- **Card meta** (400, 12 pt, tabular figures): "26 min left", "S2 E3", year, season count.

### Named Rules
**The Title Card Rule.** Big Shoulders is used at weight 800, in capitals, for a title with no logo, and nowhere else in the UI.
**The Numbers Rule.** Captions state facts in tabular figures, separated by " · ". Examples: "2019 · 1 h 38 min · 4K · HEVC · E-AC-3 5.1 · 26 min left". Codecs read H.264, HEVC, AV1, E-AC-3, TrueHD, DTS; channels 2.0, 5.1, 7.1. No adjectives.

## Layout

A single content column starts on a 40 pt gutter (`spacing.gutter`); hero text, shelf titles, shelf posters, grids and room messages all align on it. The hero sits at the bottom of a block 360 to 560 pt tall (48% of window height), its text column at most 62% of window width, its backdrop filling the right 74% and dissolving left into the room and down into the shelves. Details expand downward and push the shelves; they never grow up under the toolbar.

Shelves are horizontal rows of 150 pt posters (2:3) at 20 pt spacing, 14 pt below the shelf title; vertical rhythm between hero and shelves is 32 pt. Library and search are adaptive grids: 110 to 260 pt columns (per-library, remembered), 20 pt column gap, 32 pt row gap, 40 pt side padding. Room messages are left-aligned on the gutter, 48 pt below the top, never centred.

Space scale: 4, 8, 14, 20, 32, 48.

## Elevation & Depth

Depth is tonal plus the room light: graphite ground, raised surfaces one step lighter, posters standing on soft black shadows. Shadows respond to focus; they are not decoration at rest. Liquid Glass is reserved for system chrome (toolbar, sidebar) and the player's controls, tinted black over media. Content never gets glass.

### Shadow Vocabulary
- **Poster at rest** (`black 30%, blur 8, y 4`).
- **Poster focused** (`black 60%, blur 22, y 14`): with a 1.045 scale from the bottom edge (cards, 1.04 in grids) and a 4 pt lift.
- **Play disc** (`black 35%, blur 6, y 2`).
- **Player glass** (`glassEffect regular, tint black 55%`): controls over the picture only.

### Named Rules
**The Glass Is Chrome Rule.** Liquid Glass appears only on toolbar, sidebar and player controls. Never on posters, captions, panels or messages.
**The No Bleed Rule.** No translucent panels that let content show through behind text.

## Shapes

Continuous (squircle) corners. Posters and stills 12 pt, controls 8 pt, badges 4 pt; buttons and the play disc are full capsules and circles. Posters are clipped to their corner; the progress bar is a 3 pt capsule inset 10 pt, riding up to 54 pt when the play disc is shown. The only line is the 1 pt hairline over the hero caption.

## Components

### Buttons
- **Primary:** lilac capsule, graphite label, 34 pt high, 18 pt side padding. Pressed: 82% lilac, 0.97 scale in 0.16 s. One per screen. Whole capsule is the target.
- **Secondary:** solid raised capsule (`raised`, `raised-hover` on hover or press), ink label, 34 pt high. Never translucent over art.
- **Play disc:** 34 pt solid ink circle, graphite play glyph, bottom-right of a focused poster, inset 10 pt. The pointer's route to play; fully clickable.

### Poster card (shelf and grid)
Poster, then title (card title) and one line of facts (card meta). The pointer lifts the poster at once (spring 0.18); focus, by arrow keys or by the pointer resting 120 ms: the poster lifts, shadow deepens, title turns lilac, the play disc fades in, and the room light follows. No ring. Single click focuses; double click or Return opens the title's page; Space or the play disc plays. Watched titles carry a quiet hueless check in the top-right corner (graphite disc, ink check), never a colour. Hovering never scrolls; only keyboard moves scroll to the focused card. Pointer cursor stays the arrow, not the pointing hand.

### Hero
Backdrop right, logo or title card left at the bottom of the block, one 48 pt hairline, one caption line, then Play (primary) and Details (secondary). Title change crossfades in 0.32 s; Home prefetches every shelf title's backdrop and logo so the swap never waits on the server. Details toggle with I.

### Navigation
Native sidebar (system glass) with Home and Libraries; native toolbar with search (prompt "Titles, people, collections"), Sort menu and a poster-size slider in libraries. Selection uses the system selection tinted ink. Dark scheme forced.

### Room message
Heading, detail, optional small spinner; left-aligned on the gutter below the toolbar.

### Player stage
Opens from the hero or poster frame, then fills the window; the room light drops to 0 over 0.6 s. Controls (close, title and transport panel) are Liquid Glass tinted black; scrub bar is ink capsules. Skip Intro and Skip Credits are primary buttons sliding in from the trailing edge. Subtitles are 26 pt semibold white with a black shadow.

### Motion
- **Light** crossfades: ease-out 0.32 s.
- **Objects** (scroll, details, stage): spring, response 0.26, no bounce. **Pointer lift:** spring 0.18, immediate on hover. **Stage:** opens 0.34, closes 0.3.
- **Quick** state changes: ease-out 0.16 s.
- **Hover dwell** before the room and hero follow: 120 ms (the card itself lifts immediately).
- **Reduce Motion:** objects become a 0.2 s crossfade, no lift or scale; light keeps crossfading. **Reduce Transparency:** room light drops to 0.36.

### Keyboard
Arrows move focus and scroll (← at the first column returns to the sidebar; Home/End jump); Return opens, Space plays; I toggles the summary on Home; ⌘[ or Esc goes back; ⌘↑ goes to the enclosing folder; ⌃⌘1–⌃⌘4 switch layout; ⌘F searches; ⌘1 Home, ⌘2 to ⌘9 libraries (Go menu); ⌘= and ⌘− resize posters. In the player: Esc closes, Space or K pauses, J and L seek 10 s, arrows seek 10 s, S or Return skips, F toggles full screen. Every key is also a menu item.

## Do's and Don'ts

### Do:
- **Do** keep chrome hueless; let artwork and the room light supply colour.
- **Do** use lilac (`#A08CFF`) only for the primary action and the current selection.
- **Do** show focus as lift, shadow, lilac caption, room light and play disc.
- **Do** make the whole button the hit target (capsule, disc, card).
- **Do** use solid raised surfaces for secondary controls and anything over art.
- **Do** left-align messages and text on the 40 pt gutter, clear of the toolbar.
- **Do** write captions as facts in tabular figures joined by " · ", with a hairline above.
- **Do** crossfade light at 0.32 s, move objects with spring 0.26 and no bounce, and fall back to crossfade under Reduce Motion.
- **Do** give every shortcut a menu item.

### Don't:
- **Don't** put Liquid Glass on content; toolbar, sidebar and player controls only.
- **Don't** draw focus rings or use system focus effects on content.
- **Don't** use translucent panels with content bleeding through behind text.
- **Don't** centre or float content in the window; no centred empty or loading states.
- **Don't** use the pointing-hand cursor on cards.
- **Don't** scroll on hover; only keyboard moves scroll.
- **Don't** add a second accent, a coloured badge, or tint chrome with a film's colour.
- **Don't** use Big Shoulders for anything but a logo-less title card.

## Library layouts

- **Posters** (2:3, density 110–260 pt), **Wide** (16:9 backdrop with the clear logo at bottom-left), **List** (56 pt rows: 32×48 poster, title, then right-aligned tabular columns Year · Length · Rating · Quality), **Folders** (personal-media libraries: one click opens a folder; rows carry "N sections · M videos").
- The toolbar item set is constant across layouts (Layout · Filter · Sort · Poster size); items that don't apply are disabled, never removed, so nothing shifts.
- Filters live in one menu (Watch State, Genre, Decade, Resolution as single-choice submenus showing their value; HDR and 5.1 or More as toggles). Active filters show as removable chips under the toolbar with Clear All pinned at the end.

## Onboarding

A solid graphite column (40 %) beside a wall of the library's own posters (edge to edge, under the title bar). The MEZZANINE wordmark sits at a fixed 38 % height; each step's content grows below it. Cells resolve blur-to-sharp in a diagonal sweep as the index reads; the room light takes a new poster's colours every 4 s (held still under Reduce Motion). The window hides its title (buttons stay) during onboarding and hides all chrome while a film plays.

## Player (Bare Picture)

- The film fills the window; chrome shows on pointer movement or any key and hides after 2.5 s (never while paused, a panel is open, or VoiceOver runs). The cursor hides with it.
- Top-left: the title's clear logo (≤ 300 × 84 pt, soft shadow) with the episode line (S3 E10 · Title) under it; text title when there is no logo. Top-right: round dark-glass close (40 pt).
- Bottom: elapsed and remaining times (card meta, tabular) sitting just above a 2 pt edge scrub (ink 30 %, played ink, intro/credits ink 50 %); it thickens to 6 pt under the pointer with a glass time tooltip. While paused, a small "Paused" label leads the time row (bottom-left, never centred).
- Bottom-right icon row (40 pt dark-glass circles): AirPlay (native path), Picture in Picture, ⋯. Skip sits to the left of the row, never on it.
- ⋯ opens a 360 pt panel: a solid graphite body (95 %) over a glass rim with a 1 pt rule border, so a bright frame never shows through the rows. Audio, Subtitles, Sound, Speed rows with current values; each opens in place with a back header (Esc steps back). Long track lists scroll inside the panel (≤ 260 pt). Subtitles include Find Subtitles… (Plex's OpenSubtitles search, saved to the server), size 60–200 %, background box, timing ±0.1 s.
- Skip Intro / Next Episode / Skip Credits: the only full button, lilac, with a fill that drains as the marker plays. Auto-skip rules can skip silently (a "Skipped intro" readout confirms).
- Up Next: at the final credits marker (else 30 s before the end) the picture shrinks to its own aspect ratio (Plex width × height) on the 48 pt gutter, rounded 16 pt, width capped so it never meets the card (window − 380 − 3 × 48). The card (380 pt: still 380 × 214, title, three lines of synopsis, Play Now with countdown ring, Hide, "Starts in N s") shares the picture's top edge on the same 48 pt inset; the pair is centred vertically. All other chrome hides while it shows, except close. Reduce Motion: the same layout, reached by a 0.25 s ease instead of the spring. Still Watching? replaces it after N episodes or H hours.
- The video is an AppKit layer: rounding is painted over it in the stage black (`PictureCorners`), not clipped. Files with letterboxing baked into a 16:9 frame show their bars inside the rounded picture.
- Transient glyphs (play, pause, ±10) flash centred in a 70 pt glass circle for 0.65 s; sound changes show a corner readout with a volume bar to 400 % and a tick at 100 %.
- Click toggles play; double click toggles full screen.

## Detail page

- Hero: full-width backdrop dissolving into the room, clear logo (≤ 620 × 170 pt), ruled caption, tagline, then Play/Resume (lilac; on shows "Resume S2 E4"), Trailer, and Mark Watched. On shows and seasons the button names its scope ("Mark Show Watched") and confirms first, because it changes every episode.
- Progress under the hero buttons always carries its caption: "S2 E4 · 26 min left" (shows) or "26 min left" (films).
- Episode rows: one click plays (pointer-first), focus follows the click; the still's progress runs flush along its bottom edge (3 pt on a dark track) so the hover play disc never sits on it.
- Keys: ↑/↓ walk the page section by section (hero, about, episodes, cast, extras, related) and episode by episode inside the list; ↑ from the first episode returns to the hero. ⌥←/⌥→ change season. Return plays the focused episode, Space plays the primary title. W toggles the focused episode, else the episode Play would start; never the whole series from a key.
- Scrolled-to sections land with a 24 pt lead under the toolbar.

## Player keys

- Every player key is rebindable (Settings ▸ Shortcuts: click a key, press the new one; ⌫ removes, Esc cancels) and is a Playback menu item showing its current key. Defaults: Space/K play-pause · ←/J, →/L 10 s · ⇧←/⇧→ 1 min · ⌥←/⌥→ or Page Up/Down chapters · , . frames · [ ] speed · S skip · N / ⇧N next / previous episode · ↑ ↓ volume · M mute · D dialogue · ⌥N night · A audio track · C subtitle track · ⇧C subtitle options · G / H subtitles ∓0.1 s · F full screen · ⌥P PiP · O options panel · I playback info.
- Fixed: Return skips (or plays Up Next now), Esc backs out one layer, 0–9 jump to 0–90 %, ⌘⇧S snapshot (Pictures ▸ Mezzanine, and the clipboard).
- Keys reach the player through `PlayerKeyRouter` before the menus, so a letter typed into a field (Find Subtitles) always types. With Full Keyboard Access, Space/Return/arrows drive a focused control first.
- Feedback: a top-right readout names what changed ("Subtitles: English (SDH)", "Chapter 3 · Title", "1.25× speed"), announced to VoiceOver.
- Playback info (I): a solid graphite card top-left under the title mark — route, video, decoder, audio path, output device and profile, volume, start and seek times.
- Scrub hover: a 200 pt frame preview above the bar (the engine's cached segments near the playhead, a second reader's nearest keyframe elsewhere), with the chapter name and time; chapter starts are small gaps in the bar.
- Help ▸ Keyboard Shortcuts (⌘/) lists every key, read-only, with Change Keys… into Settings.

## Delivery (direct play first)

- Mezzanine always plays the original file. If it won't open, it asks Plex to remux it (streams copied into HLS), then to convert it, and says so once ("Direct play failed · remuxed by the server").
- ⋯ ▸ Quality: Original (the server does no work), Original converted, and caps for slow links (20 / 12 / 8 Mbps 1080p, 4 / 2 Mbps 720p). Switching keeps the position. Playback info names the delivery.
- The failure panel offers Convert on the Server while the original was playing.
- Multi-version titles (rare here): Version menu beside Play on movie pages; Play Version in an episode's context menu.
- Plex has no transcode profile for platform "macOS": transcode URLs carry `X-Plex-Client-Profile-Name=Generic` plus Mezzanine's target (HLS/MPEG-TS, H.264/HEVC, AAC/AC-3/E-AC-3), and a decision request precedes `start.m3u8`. Closing (or quitting) stops the session.
