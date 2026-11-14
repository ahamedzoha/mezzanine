---
version: 1
slug: "mezzanine-player-playerstage-swift"
primary_target: "Mezzanine/Player/PlayerStage.swift"
related_targets: []
---

## Scope

The player (`Mezzanine/Player/`): Experience mode — the film leads; chrome appears on pointer movement or keys and leaves after 2.5 s. Users: the owner (keyboard, binges), his wife (pointer).

## Direction contract

THESIS: Bare Picture. Nothing but the film; controls are a hairline and a corner. Refuses the category default of a thick transport bar with a row of icon buttons over the picture.

OWN-WORLD: DESIGN.md: dark glass (black 55–62 % tint) only on player controls; ink type; one lilac element at a time (Skip Intro / Next Episode / Play Now); the title's clear logo top-left (owner's request, as in Jellyfin's TV apps), episode line under it.

STORY: You watch; when you move, you see what's playing (its logo), where you are (a hairline), and one ⋯ for audio, subtitles, sound and speed. At the credits the picture steps aside for the next episode.

FIRST VIEWPORT: Full-bleed film. On movement: vignette top and bottom; clear logo (≤300×84) + episode line top-left on the 40 pt gutter; glass close top-right; ⋯ bottom-right; elapsed and remaining times above a 2 pt bottom-edge scrub (6 pt with a time tooltip on hover; intro/credits brighter). Skip Intro (lilac, draining fill) left of ⋯ while a marker plays.

FORM: Bare Picture (owner picked the dealt lead over Corners and Floating Pill). seed:359585515d5f333a. Signature: Up Next — the picture shrinks into the top-left corner (spring 0.5) while the next episode's still, title, synopsis and a countdown ring arrive at the right; Play Now / Hide; autoplay crosses seasons; Still Watching after N episodes.

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
