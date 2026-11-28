---
version: 1
slug: "mezzanine-music-sleeve-swift"
primary_target: "Mezzanine/Music/"
related_targets: ["Mezzanine/Navigation/Sidebar.swift", "Mezzanine/Navigation/AppShell.swift", "Mezzanine/Navigation/SearchPanel.swift", "Mezzanine/Navigation/QuickOpen.swift"]
---

## Scope

Music M1: the Music library's screens in the owner's Plex client, built to direction C "Sleeve" (chosen 2026-11-28 from three sketches, kept local). Root, Albums, Artists, Songs, Playlists, the album, artist and playlist pages, the docked Now Playing bar, and Music in the search panel and Quick Open. Mode: Experience on the root and pages (the art leads), Operate on Songs. The Now Playing room, lyrics, Up Next sheet, radio and organizing facets are later milestones (M3, M4, M5).

Audience/job: the owner at his desk, in a dim room, putting on an album or a mix with one click while a film is not playing; browsing by cover; his wife occasionally, pointer-first.

Chosen sketch: `.impeccable/review/music-m1/sketch-c-sleeve.html` (local, gitignored). Code-led build in the same Bias Light world as Home (DESIGN.md binds: graphite room, one lilac for the primary action and the current selection, Liquid Glass only on toolbar, sidebar and player controls, no focus rings, left-aligned on the 40 pt gutter, captions as facts joined by " · " in tabular figures).

## Direction contract

THESIS: A record sleeve on a shelf: the cover is the room. Art stays square (albums, playlists) or round (people), the cover's own colours wash the left of the window, and the list sits on steady graphite beside it. Refuses the category default: a dense table or a carousel of rounded cards under a hero banner, with a coloured accent for the playing row.

OWN-WORLD: Bias Light unchanged. Room light is the focused sleeve's four UltraBlur corners (mixed 25 % toward graphite). The playing row's title is the one lilac on a page, next to the Play button. The playing mark is the ink level glyph, never colour.

STORY: Open Music and see eight covers; rest the pointer on one and the room takes its colour, its caption names it; one click opens it, the disc plays it. On an album page the sleeve stays put and the songs scroll; one click on a song plays it and the album carries on after it. The bar at the bottom follows you to every page.

FIRST VIEWPORT (root): a 4 × 2 wall of 200 pt covers with 8 pt gaps (408 pt tall) on the gutter; beside it (under it below 1,084 pt of content width) the page name (22 pt), one facts line ("507 artists · 820 albums · 3,367 songs · 12 playlists") and a lilac Shuffle All. Under the wall a 48 pt hairline and the focused cover's caption (title lilac, then "Artist · year · N songs"); the first cover is named until the pointer rests on another. No video-style hero. Then Plex's own music rows as 150 pt shelves.

FORM: Sleeve, as drawn. Medium room light on album, artist and playlist pages (left 760 pt only, 56 % opacity, fading out left to right under a 30 % solid); full room light elsewhere (74 %).

## Measurements

- **Wall:** 4 columns × 2 rows, tile 200 pt (shrinks to fit, minimum 90), 8 pt gap, 12 pt art radius, shadow `0 4 8 / .4`.
- **Cards (grids, shelves):** square art, 12 pt radius; round for artists. Grid columns adaptive 170…220 pt, 20 pt gutters, 22 pt rows. Shelf cards 150 pt, 20 pt apart. Title 12 pt semibold ink-secondary (lilac when focused), one line of facts 12 pt tertiary shown only while lifted (space kept). Lift: scale 1.04, 4 pt up, shadow `0 14 22 / .6`; play disc 34 pt ink at the art's bottom-right, 10 pt in. Pointer lifts at once; focus follows after 120 ms; the room follows focus. A click opens the page; the disc plays. No watched mark, no clean-poster lookup.
- **Sleeve pages:** left column = 40 pt gutter + art + 24 pt; art 340 pt wide, squeezing with the window to 190 pt (38 % of the content width). The left column does not scroll with the list (it scrolls alone only if the window is too short). Right column = the rest minus a 40 pt trailing gutter.
- **Left column stack:** art with the deep shadow (`0 22 44 / .6` + `0 4 10 / .4`); name 22 pt semibold, 20 pt below; artist 15 pt secondary (a link to the artist page); a 48 × 1 hairline, then the caption lines (13 pt medium, secondary, tabular); Play (lilac capsule 34 pt), Shuffle (raised capsule; icon only below 280 pt of art), ⋯ (34 pt raised circle).
- **Album caption:** line 1 "1997 · 12 songs · 53 min" (an EP, single, live record or compilation adds its type first); line 2 "FLAC · 24-bit · 96 kHz · Label" (the most common file quality among the songs, then the label). **Artist caption:** "Country · genre · 7 albums · 61 songs", then the bio (4 lines, More).
- **Song rows (album, Popular):** 40 pt, 8 pt corners, 12 pt side padding; columns number 32 · [28 pt thumbnail] · title (15 pt medium) · plays 60 · time 52, 12 pt gaps. Hover or keyboard focus fills raised. The playing row: title lilac, the number cell is the level glyph (animates only while playing, still under Reduce Motion). A song by another artist than the album's shows the server's credit after the title, tertiary. Discs: a "Disc N" caption (12 pt semibold, tertiary) above each group when there is more than one. Plays drop below 340 pt.
- **Songs / playlist table:** 36 pt rows (playlist 40), columns # · 28 pt thumbnail · Title · Artist · Album · Time · Plays · Quality ("FLAC 24/96", "MP3 320"); title 13 pt medium; Quality drops under 860 pt, Plays under 700 pt, Album under 560 pt. Header 28 pt with a 1 pt rule.
- **Artist page right column:** Popular (5 rows with thumbnails), Discography (one 150 pt shelf per release kind: Albums, EPs, Singles, Live, Compilations, Soundtracks, Remixes, oldest first), Similar Artists (round shelf). Section headings 17 pt semibold.
- **Now Playing bar:** docked at the bottom of the page on top, 12 pt from the sides and bottom, 64 pt tall, 16 pt radius, Liquid Glass (black tint .35), 1 pt rule border, 2 pt ink progress line along the bottom edge (a 14 pt scrub target above it). Left: 48 pt art (8 pt radius), title 13 pt semibold, "Artist · Album" 12 pt secondary; the whole block opens the playing album. Centre (true centre): elapsed, previous, 34 pt ink play disc with a graphite glyph, next, remaining. Right: "N up next", AirPlay, volume (84 pt). Width classes by the bar's width: ≥ 1,000 pt everything; 700…1,000 no volume; below 700 art, name and play only.
- **Colour:** lilac is the Play buttons, the playing row's title, the focused card's title and the wall caption's title: one of them per area. Never a badge, never an icon.

## Constraints

- Owner's rules (DESIGN.md): no translucent panels with content bleeding through (the bar is the player-control class, the one exception); no centred content in empty space (messages sit on the gutter); no focus rings (Increase Contrast adds a 2 pt ink outline); whole buttons clickable; clear space under the toolbar; arrow cursor on cards.
- Every action is a key and a menu item; every key has a pointer path.
- Reduce Motion: no lift or scale, level glyph still. Reduce Transparency: room light 0.36. Increase Contrast: tertiary text resolves toward ink, rules to 40 %.
- Async loads drop stale answers; ForEach identity is the item's key, never a position; a page change from a sidebar click is deferred (`Sidebar.deferredSelection`).
- No coloured stand-ins for missing art: a raised well with a quiet note or microphone.

## Open decisions

- The bar must live on each page, not outside the navigation stack: a stack draws a pushed page above anything outside it, safe-area insets included (checked on a pushed album and a title page).
- The Now Playing room (M3): the bar opens the playing album until then. Stations and Radio (M4): no row until then.
