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
  card-headline:
    fontFamily: "SF Pro"
    fontSize: "17px"
    fontWeight: 600
  reading:
    fontFamily: "SF Pro"
    fontSize: "15px"
    fontWeight: 400
  body:
    fontFamily: "SF Pro"
    fontSize: "13px"
    fontWeight: 400
  button:
    fontFamily: "SF Pro"
    fontSize: "13px"
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
  shelf-strip:
    backgroundColor: "{colors.raised}"
    textColor: "{colors.ink}"
    typography: "{typography.card-title}"
    rounded: "{rounded.poster}"
    height: "72px"
  shelf-strip-hover:
    backgroundColor: "#1F2226"
  shelf-strip-selected:
    backgroundColor: "{colors.raised-hover}"
    textColor: "{colors.lilac}"
  quick-open-panel:
    backgroundColor: "{colors.raised}"
    textColor: "{colors.ink}"
    rounded: "{rounded.panel}"
    width: "620px"
  quick-open-row-selected:
    backgroundColor: "{colors.raised-hover}"
    textColor: "{colors.lilac}"
    rounded: "{rounded.control}"
    height: "48px"
  smart-shelf-sheet:
    width: "680px"
  collection-picker:
    width: "520px"
---

# Design System: Mezzanine

## Overview

**Creative North Star: "Bias Light"**

Mezzanine is a dark room with one light source: the film you are looking at. A near-black graphite ground carries the interface; the focused title throws its own colour across it, the way a bias light washes a wall behind a television. Chrome has no hue of its own. Every colour on screen belongs to a film, its artwork or the room light derived from it. The single exception is one lilac, spent on the primary action and the current selection.

The system is quiet and precise. Type is SF Pro at small, exact sizes, mapped to macOS text styles so it follows the system Text Size setting; titles without a logo are set once, large and heavy, like a title card. Facts are numbers rather than adjectives, joined by " · ". Nothing floats in the middle of the window: text and messages sit on a 40 pt gutter, left-aligned, below the toolbar.

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
Sizes are the defaults of the macOS text styles they map to (`Theme.Typeface`); they grow and shrink with Accessibility ▸ Display ▸ Text Size. Glyphs inside fixed-size discs keep point sizes.
- **Room message** (`.title`, 600, 22 pt): loading, empty and error headings.
- **Shelf title** (`.title2`, 600, 17 pt): the row heading on the gutter.
- **Card headline** (`.title2`, 600, 17 pt): Up Next, failure panels and picker headings.
- **Reading** (`.title3`, 400, 15 pt): a title's summary and tagline on the detail page.
- **Body** (`.body`, 400, 13 pt): hero summary (ink at 86%, four lines, 560 pt measure), message detail (480 pt measure), the editor's quiet note.
- **Button** (`.body`, 600, 13 pt): capsule labels.
- **Caption** (`.body`, 500, 13 pt, tabular figures): the hero's ruled caption and fact lines.
- **Card title** (`.body`, 600, 13 pt): under posters and on shelf strips, one line.
- **Card meta** (`.callout`, 400, 12 pt, tabular figures): "26 min left", "S2 E3", year, season count, a strip's source line, a Quick Open row's caption and key hint.

### Named Rules
**The Title Card Rule.** Big Shoulders is used at weight 800, in capitals, for a title with no logo, and nowhere else in the UI.
**The Numbers Rule.** Captions state facts in tabular figures, separated by " · ". Examples: "2019 · 1 h 38 min · 4K · HEVC · E-AC-3 5.1 · 26 min left". Codecs read H.264, HEVC, AV1, E-AC-3, TrueHD, DTS; channels 2.0, 5.1, 7.1. No adjectives.

## Layout

A single content column starts on a 40 pt gutter (`spacing.gutter`); hero text, shelf titles, shelf posters, grids and room messages all align on it. The hero sits at the bottom of a block 360 to 560 pt tall (48% of window height), its text column at most 62% of window width, its backdrop filling the right 74% and dissolving left into the room and down into the shelves. Details expand downward and push the shelves; they never grow up under the toolbar.

Shelves are horizontal rows of 150 pt posters (2:3) at 20 pt spacing, 14 pt below the shelf title; vertical rhythm between hero and shelves is 32 pt. Library and search are adaptive grids: 110 to 260 pt columns (per-library, remembered), 20 pt column gap, 32 pt row gap, 40 pt side padding. Room messages are left-aligned on the gutter, 48 pt below the top, never centred.

Space scale: 4, 8, 14, 20, 32, 48.

While editing, the hero is gone and shelves are strips stacked at 8 pt on the same gutter, at most 980 pt wide (see Edit Shelves). A library's Shelves layout uses Home's column unchanged.

## Elevation & Depth

Depth is tonal plus the room light: graphite ground, raised surfaces one step lighter, posters standing on soft black shadows. Shadows respond to focus; they are not decoration at rest. Liquid Glass is reserved for system chrome (toolbar, sidebar) and the player's controls, tinted black over media. Content never gets glass.

### Shadow Vocabulary
- **Poster at rest** (`black 30%, blur 8, y 4`).
- **Poster focused** (`black 60%, blur 22, y 14`): with a 1.045 scale from the bottom edge (cards, 1.04 in grids) and a 4 pt lift.
- **Play disc** (`black 35%, blur 6, y 2`).
- **Player glass** (`glassEffect regular, tint black 55%`): controls over the picture only.
- **Strip selected** (`black 35%, blur 10, y 4`): the soft lift under the selected shelf strip.
- **Strip dragged** (`black 60%, blur 22, y 14`, 1.02 scale): the poster-focused shadow at a strip's size.
- **Quick Open panel** (`black 50%, blur 30, y 16`) over a black 35% scrim.

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

### Edit Shelves
Home edits in place: the owner's shelves fold into strips he can grab, and fold back into posters when he is done. Same world, no new colour; strips are solid.

- **Strip anatomy:** 72 pt tall, 12 pt continuous corners, 14 pt side padding, on the gutter, 8 pt between strips. Left to right: grip (three lines, tertiary, secondary on hover; open-hand cursor), title (card title) over a source line (card meta: "Plex · Continue Watching", "Collection · IMDb Top 250 · 44", "Smart · Unwatched · Comedy · 1990s"), a peek of the shelf's first five posters (32 × 48, 4 pt corners, 4 pt apart), a small show-on-Home switch, a ⋯ menu (rename, move, edit rules, remove). The whole strip is the target; no focus ring.
- **States:** solid raised at rest; hovering lightens it halfway to raised-hover, so hover is always lighter than rest and darker than selected; selected = raised-hover fill, lilac title, soft lift (`Strip selected`). Hidden = title at 60%, source line ink-tertiary, peek desaturated at 45%. Dragged = raised-hover, 1.02 scale, the poster shadow (`Strip dragged`), spring 0.18.
- **The fold:** each strip's five peek posters are the shelf's first five posters, matched in geometry between the poster row and the strip (spring 0.26, no bounce). Reduce Motion: a 0.2 s crossfade.
- **Chrome:** a quiet one-line note on the gutter ("Drag to reorder. Hidden shelves stay here, dimmed."); Restore Default Shelves… beside it, which asks first ("Restore the default shelves?") and says Undo brings the rows back. The last strip is Add Shelf: a dashed 1 pt rule outline, a + and a menu (a Plex row not yet on Home, Collection…, Playlist, Smart Shelf…). Plex rows missing on the current server stay as a strip "Not on this server".
- **From a library's other layouts:** Edit Shelves (and ⌘E) is always live in a library's toolbar; in Posters, Wide or List it switches the library to Shelves and opens the editor there, never a dead greyed button.
- **Toolbar:** "Edit Shelves" becomes a prominent lilac "Done" while editing (Home and each library's Shelves layout); the window subtitle reads "Editing shelves". Done is the screen's primary action.
- **Undo:** every change (move, hide, rename, remove, add, rule edit, restore) is one ⌘Z step with a named Undo item, and is announced to VoiceOver.
- **Keys:** ↑/↓ select; ⌥↑/⌥↓ move the shelf; Space shows or hides; Return renames or edits the rules; ⌫ removes; Esc or ⌘E finishes. They are View-menu items: Edit Shelves / Done Editing Shelves (⌘E), Move Shelf Up, Move Shelf Down, Show or Hide Shelf (Space), Rename Shelf… (Return), Remove Shelf (Delete); File has New Smart Shelf… (⌘N) and Add Collection…. Every key has a pointer path: drag, switch, ⋯ menu, Add Shelf.

**The Fold Rule.** Editing changes the same objects in place: shelf rows fold into strips by matched geometry and back, with a crossfade under Reduce Motion.

### Smart shelves
A native sheet, 680 pt wide, opened from Add Shelf, ⌘N or a strip's Edit Rules.

- **Form:** Name (placeholder is the automatic name), From (libraries pop-up) and Show (kind), then "Titles that match all of these": rule rows ANDed, each a field pop-up, its value control and −/+; Sort by and Show up to pop-ups; a 1 pt rule; the live preview. Cancel and a lilac Add Shelf (Save when editing).
- **Fields:** Genre (is or is not), Decade, Years (between), Watch state, Added within, Minimum rating, Resolution, HDR or Dolby Vision, Channels (5.1 or more, 7.1), Collection, Person.
- **Preview:** up to ten 52 × 78 pt posters and a count in card meta: "38 titles", or "24 of 1,145 titles" when the size limit cuts it short. It refreshes as rules change (the local index answers in milliseconds). Empty: "Nothing in your library matches yet."
- **Scroll:** rules scroll inside the sheet past 280 pt.
- **Collection picker:** "Add a Collection", a 520 × 560 pt sheet of collections with a 24 × 36 thumbnail each, chosen by pointer or keys.

### Quick Open
⌘K opens a command panel over the content; Esc, a click on the scrim, or ⌘K again closes it.

- **Shape:** solid raised panel, 620 pt wide, 16 pt corners, 1 pt rule border, left-aligned on the gutter 14 pt under the toolbar, never centred. A black 35% scrim covers the window; the panel has no glass and nothing shows through it.
- **Anatomy:** a 52 pt search field, a 1 pt rule, then a list up to 420 pt tall in sections: Continue (Resume <title>), Titles (28 × 42 thumbnail, title, ruled caption), Actions (Edit Shelves, New Smart Shelf…, Play Next Episode of <show>), Go To (Home, each library, Settings, with their ⌘ keys as captions). An empty query shows Continue and Go To.
- **Rows:** 48 pt minimum, 8 pt corners. Selected = raised-hover fill, lilac title, and a key hint at the trailing edge in ink-tertiary ("↩ Open · ⌘↩ Play" on a title, "↩ Play", "↩").
- **Keys:** ↑/↓ select, Return runs, ⌘Return plays a title, Esc closes. The selected row is announced to VoiceOver.

### Motion
- **Light** crossfades: ease-out 0.32 s.
- **Objects** (scroll, details, stage): spring, response 0.26, no bounce. **Pointer lift:** spring 0.18, immediate on hover. **Stage:** opens 0.34, closes 0.3.
- **Quick** state changes: ease-out 0.16 s.
- **Hover dwell** before the room and hero follow: 120 ms (the card itself lifts immediately).
- **Reduce Motion:** objects become a 0.2 s crossfade, no lift or scale; light keeps crossfading. **Reduce Transparency:** room light drops to 0.36.

### Keyboard
Arrows move focus and scroll (← at the first column returns to the sidebar; Home/End jump); Return opens, Space plays; I toggles the summary on Home; ⌘[ or Esc goes back; ⌘↑ goes to the enclosing folder; ⌃⌘1–⌃⌘5 switch layout; ⌘F searches; ⌘K opens Quick Open; ⌘E edits shelves (⌘N adds a smart shelf while editing); ⌘[ and ⌘] go back and forward; ⌘1 Home, ⌘2 to ⌘9 libraries (Go menu); ⌘= and ⌘− resize posters. In the player: Esc closes, Space or K pauses, J and L seek 10 s, arrows seek 10 s, S or Return skips, F toggles full screen. Every key is also a menu item.

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
- **Do** show selection on a strip or a Quick Open row as raised-hover fill and a lilac title, with lift only on strips.
- **Do** ask before Restore Default Shelves, and make every shelf change one ⌘Z step.

### Don't:
- **Don't** put Liquid Glass on content; toolbar, sidebar and player controls only.
- **Don't** draw focus rings or use system focus effects on content.
- **Don't** use translucent panels with content bleeding through behind text.
- **Don't** centre or float content in the window; no centred empty or loading states.
- **Don't** use the pointing-hand cursor on cards.
- **Don't** scroll on hover; only keyboard moves scroll.
- **Don't** add a second accent, a coloured badge, or tint chrome with a film's colour.
- **Don't** use Big Shoulders for anything but a logo-less title card.
- **Don't** centre Quick Open or let the scrim-covered content show through the panel.
- **Don't** hide a shelf by deleting it; hidden strips stay, dimmed, so they can come back.

## Library layouts

- **Posters** (2:3, density 110–260 pt), **Wide** (16:9 backdrop with the clear logo at bottom-left), **Shelves** (⌃⌘5; the library's own Home: Plex's hubs for that library by default, shelves of 150 pt posters, edited with the same Edit Shelves and ⌘E, layout kept per server and profile; Filter, Sort and Poster size are disabled here, not removed; an Edit Shelves item joins the toolbar), **List** (56 pt rows: 32×48 poster, title, then right-aligned tabular columns Year · Length · Rating · Quality), **Folders** (personal-media libraries: one click opens a folder; rows carry "N sections · M videos").
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

## Artwork picker (M8)

- Choose Poster… / Choose Background… from a poster's context menu (films, shows, seasons) and the ⋯ button beside the detail hero's actions. One sheet, 860 × 640, solid graphite; Poster | Background segmented control top-right.
- A grid of every picture Plex offers (agents such as TMDB and Fanart.tv, uploads such as Kometa's, the title's own folder): 132 pt posters or 236 pt backgrounds, each with its source as card meta. The picture in use carries the hueless check; the selection lifts (1.04, poster-focus shadow) and its caption turns lilac. Arrows move, Return or a double-click uses it, Esc cancels.
- Apply to: **Mezzanine only** (default; a local choice per server and profile, nothing on the server changes) or **The Plex server** (every app; tools like Kometa may replace it on their next run). The default button names the destination ("Use Poster on Plex Server"); a double-click applies only for Mezzanine; after a server write the sheet stays open and says what it replaced ("Before: Uploaded."). "Remove Mezzanine’s Choice" shows the server's picture again.
- The grid is one keyboard stop (arrows, Home/End); cells read "Fanart.tv poster, 3 of 109" with a Use action for VoiceOver. View ▸ Choose Poster… ⌥⌘P and Choose Background… ⌥⌘B act on the open title page.
- Provider pictures load from Plex's own small renditions; server files go through the server's photo transcoder. The token never leaves the server's host.

## Profiles (M9)

- Plex Home profiles each keep their own index, Continue Watching, watched marks and shelves.
- Sidebar footer: the current profile's avatar and name with a ⌃⌄ chevron; a click opens the profile menu (current one checked, "(PIN)" on protected ones). Mezzanine ▸ Switch Profile holds the same menu. Disabled while a film plays.
- A protected profile asks for its PIN in a 400 pt sheet (avatar, "Switch to Name", secure field, Cancel / Switch); a wrong PIN says "That PIN didn’t match." and clears the field. Switching returns to Home.

## Post-play (films)

- At a film's credits (the final credits marker, else 30 s before the end) the picture shrinks exactly as for Up Next and a 380 pt card offers what to watch next: Plex's first related row's name as the heading (card meta), six films on a 3 × 2 grid of 116 pt posters (unwatched first), then Watch Again and Keep Watching Credits (secondary). No countdown: films never autoplay.
- Arrows choose (3 per row), Return or a click plays, Esc keeps the credits; the selection lifts with a lilac title. Only a moving pointer selects. At the end of the film the card stays until you choose or close.
- Settings ▸ Playback ▸ Films: "Suggest what to watch next at the credits" (on by default).

## Downloads (M11)

- Sidebar ▸ On This Mac ▸ Downloads (Go ▸ Downloads ⌥⌘L). By Title (owner's pick): a 320 pt column of downloaded titles (32 × 48 poster, name, one meta line: "6 episodes · 4.2 GB", "Downloading · 2 files · 1.1 of 2.3 GB · 3 min left", "Paused · 42 %") and the selected title on the right.
- The arrival line: while anything downloads, a 2 pt ink line runs the row's width at its progress; when everything is here it shrinks into the app's 48 pt hairline. No colour, no checkmark. File rows use the same ink line.
- Selected title: a 200 pt backdrop dissolving down and left into the room with the clear logo (or the title), the ruled caption ("1 episode · 62.3 MB · Original quality"), Keep Downloaded (Off, Next Unwatched Episode, Next 3/5/10 Unwatched Episodes) for shows, file rows (one click plays a finished file; Play / Pause / Resume / Retry and Remove as 34 pt raised circles), and Remove Downloaded Episodes… / Remove Download….
- Title pages: Download (films and episodes) becomes "Downloading 42 %" then "Downloaded", each a menu (pause, resume, retry, cancel, Remove Download…); shows offer Next Unwatched Episode / Next 3 / Next 5, All of the season on screen, and Keep Downloaded. Episode rows carry a hueless download mark. File ▸ Download ⇧⌘D, File ▸ Remove Download… ⌘⌫.
- Removing a finished download always asks, once, app-wide; the files go to the Trash. Cancelling an unfinished one is immediate.
- Files: Movies ▸ Mezzanine ▸ "Show/Show S05E03 Title.mkv" or "Title (Year).mkv", with poster, backdrop, clear logo and sidecar subtitles beside each. A downloaded copy always plays instead of the server's ("Downloaded copy" in Playback info).
- Offline (Plex unreachable, something downloaded): the sidebar shows only Downloads with a quiet Offline note and Try Again; search goes away; downloads play from their saved details. Positions watched offline are sent to Plex when it's back.

## Find Subtitles

- The ⋯ panel's Find Subtitles page (⌥F) lists what every source finds as it answers: a caption line "Searching Plex, OpenSubtitles and Addic7ed…" with a small spinner while any are out, then rows of release name and one detail line ("Matches this file · English · Addic7ed · SDH · 214 downloads"). The language appears only when two are searched. No colour, no badges: "Matches this file" leads the line and those rows sort first.
- Choosing a row loads it, selects it and returns to the Subtitles list, which opens scrolled to the track in use. A source that fails says why in one caption line ("Subdl: the API key was refused."); nothing blocks the rest.
- The page ends with Subtitle Sources… (the searched languages as its value), opening Settings ▸ Subtitles. Without the free keys, a caption says what they add.
- Settings ▸ Subtitles: Find Subtitles (language, also search in), Sources (Plex and Addic7ed toggles with one-line explanations; OpenSubtitles.com and Subdl rows with Set Up… / Edit…). Keys are typed in a small sheet (SecureField, Check, Done), never on the main form.
