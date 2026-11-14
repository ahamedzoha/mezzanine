---
version: 1
slug: "mezzanine-home-homeview-swift"
primary_target: "Mezzanine/Home/HomeView.swift"
related_targets: []
---

## Scope

Home (first surface of the new world): `Mezzanine/Home/`. Mode: Experience — the library's artwork leads; chrome recedes. The same world carries library grids, detail, player HUD, Up Next, onboarding and Settings (Operate surfaces inherit it quietly).

Audience/job: the owner at his desk or in bed, in a dim room, resuming what he's in the middle of and browsing his own shelves; his wife occasionally, pointer-first.

Chosen sketch: `.impeccable/mocks/decision/model-pick.html` (Bias Light). Code-led build.

## Direction contract

THESIS: Each film lights the room. The window's ambient colour is the focused title's own four UltraBlur corner colours washing across graphite, like bias lighting behind a screen. Refuses the category default: a flat black grid under an auto-advancing hero carousel with a brand-colour accent.

OWN-WORLD: graphite matte ground #0E0F11, raised #1A1C20, type #F2F2F0, one lilac #A08CFF reserved for the primary action and the current selection. The ambient wash is a four-corner gradient from UltraBlurColors at low opacity behind everything — never glow, never neon edges. Titles speak in the film's clearLogo (fallback: self-hosted Big Shoulders Display, heavy, caps, OFL); UI in SF Pro. A ruled caption names every part: "1080p · HEVC · E-AC-3 5.1".

STORY: Open the app and see what you're in the middle of; resume with one key; browse shelves you built; the room's light tells you where focus is.

FIRST VIEWPORT: Top ~45%: focused title's backdrop fading into graphite, clearLogo left-aligned at display scale (no label above it), then one ruled caption line under it (Series · 3 seasons · 2019 — 1080p · HEVC · E-AC-3 5.1 · 26 min left), then lilac Resume button + Details. Directly below: Continue Watching at full poster size with progress bars, then Recently Added. Sidebar on system glass at left, search in the toolbar, clear space under the toolbar.

FORM: Bias Light (Impeccable's pick, #1 of seven grounded directions; user chose it over the dealt House Lights). seed:3297b9419be603cd. Signature interaction: as focus moves across posters (keyboard or hover-dwell), the room's light crossfades (≈450 ms, ease-out) to that title's UltraBlur and the hero follows; pressing Play zooms the hero into the player and the room goes dark. Motion grammar: crossfade light, matched-geometry for objects, nothing bounces; Reduce Motion → light crossfade only.

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance

## Constraints

- Owner's rules: no translucent panels with content bleeding through; no centred content floating in empty space; no focus rings on custom controls (focus = lift + lilac caption + the room's light); whole button clickable; clear space under the toolbar; glass over bright media stays legible; no pointing-hand cursor on cards.
- Liquid Glass only on toolbar, sidebar, player controls. HIG reviewer gates the milestone.
- Spill must stay subtle (risk named at selection): cap wash opacity so text contrast holds on every title.

## Open decisions

- Exact wash opacity curve and how it behaves over very bright or very saturated art (decide in build, verify on real library titles).
- Hero behaviour when no item is focused yet (first launch: top of Continue Watching).
