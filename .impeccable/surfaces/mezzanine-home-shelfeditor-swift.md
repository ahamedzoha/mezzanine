---
version: 1
slug: "mezzanine-home-shelfeditor-swift"
primary_target: "Mezzanine/Home/ShelfEditor.swift"
related_targets: ["Mezzanine/Home/SmartShelfSheet.swift", "Mezzanine/Navigation/QuickOpen.swift", "Mezzanine/Home/HomeModel.swift"]
---

## Scope

M7: the owner builds Home. Three pieces inside the settled Bias Light world: (1) Edit Home, the
in-place shelf editor on Home and on each library's Shelves layout; (2) the smart-shelf rule
sheet; (3) ⌘K Quick Open. Mode: Operate (the task is arranging and finding; the art stays the
only colour). Owner picked "Edit in Place" over "Say It" (typed rules in ⌘K) and "Shelf
Composer" (separate window). Code-led; the wireframe card rides at the finish review.

Audience/job: the owner, keyboard-first, shaping Home a few times a month and opening titles
by name daily; his wife pointer-first, who must be able to hide a shelf or add a collection
without a key.

## Direction contract

THESIS: Home rearranges itself. Editing happens where you watch: the shelves fold to strips
you can grab, and fold back into posters when you're done.

OWN-WORLD: unchanged Bias Light: graphite ground, raised strips, ink type, lilac only for the
selected strip's title and the sheet's primary button. No new colour, no glass on content.
Strips are solid raised surfaces (#1A1C20), 72 pt tall, 12 pt continuous corners, on the
40 pt gutter.

STORY: ⌘E (or Edit in the toolbar) → the hero folds up and every shelf collapses into a strip
in place → drag or ⌥↑/⌥↓ to reorder, Space or the switch to hide, Return to rename or edit
rules → Add Shelf at the end: Plex rows, a collection, a playlist, a smart shelf → ⌘E or Done
unfolds them back into poster rows, in the new order.

FIRST VIEWPORT (editing): toolbar shows Done (prominent) where Edit was; no hero; a quiet
one-line note on the gutter ("Drag to reorder. Hidden shelves stay here, dimmed."); strips
stacked at 8 pt spacing: grip ≡, title (card title; lilac when selected), source line (card
meta: "Plex · Continue Watching", "Collection · IMDb Top 250 · 44", "Smart · Unwatched ·
Comedy · 1990s"), a peek of the first five posters at 32 × 48, hide switch, ⋯ menu. Hidden
strips drop to ink tertiary with the peek desaturated. Add Shelf is the last strip, a dashed
1 pt rule outline with a + and a menu.

RULE SHEET: native sheet 640 pt: Name field (placeholder is the auto name), Libraries pop-up,
rule rows (field pop-up · value control · −/+), "Match all of these" fixed, Sort and Show up to
pop-ups, then a live preview: up to ten 64 pt posters and the count ("38 titles"), refreshing
as rules change (index answers in ms). Cancel / Add Shelf (lilac).

QUICK OPEN (⌘K): a solid graphite panel (raised, 1 pt rule border, 16 pt corners) dropping
from under the toolbar, left-aligned on the content gutter, 620 pt wide, never centred. Field
first; sections Titles (poster thumb, title, ruled caption), Go To (Home, each library,
Settings), Actions (Edit Home, New Smart Shelf, Resume <first Continue Watching>, Play Next
Episode of <matching show>). ↑/↓ select (selected row title lilac, raised-hover fill), Return
runs, ⌘Return plays a title, Esc closes. Empty query shows Continue Watching and Go To.

FORM: signature move = the fold: shelves collapse from poster rows into strips and back with
matched geometry (each strip's poster peek is literally the shelf's first posters shrinking),
spring 0.26, no bounce; Reduce Motion → 0.2 s crossfade. Everything else is standard native
controls (pop-ups, switches, text fields, menus).

FINISH: finish review against this contract and the Edit in Place wireframe, HIG pass,
DESIGN.md sections for Edit Home, smart shelves and Quick Open.

## Constraints

- Owner's rules: no translucent panels with content bleeding through (Quick Open and strips
  are solid); nothing centred or floating; no focus rings on custom controls (selection =
  lilac title + raised-hover fill); whole strip clickable; clear space under the toolbar; no
  pointing-hand cursor.
- Every action has a key and a menu item (View ▸ Edit Home ⌘E, File ▸ New Smart Shelf… ⌘N
  while editing, Go ▸ Quick Open ⌘K); every key path has a pointer path.
- Layouts persist per server + Plex Home profile; Plex hubs that vanish (server change) show as
  a strip "Not on this server" rather than disappearing.

## Open decisions

- Per-library shelves: libraries get a fifth layout, Shelves, defaulting to Plex's own hubs for
  that library, edited with the same ⌘E.
