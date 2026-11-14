---
version: 1
slug: "mezzanine-onboarding-onboardingview-swift"
primary_target: "Mezzanine/Onboarding/OnboardingView.swift"
related_targets: []
---

## Scope

Onboarding (first run, and after sign-out): `Mezzanine/Onboarding/`. Mode: Operate (finish setup), inside the Bias Light world (DESIGN.md). Users: the owner once; his wife on her own Mac account, pointer-first, without help. Under two minutes; every later step skippable.

Steps in M1: sign in (plex.tv PIN, browser detects approval) → server (only when the account sees more than one) → profile (only when Plex Home has more than one user; PIN for protected profiles) → library warm-up (the local index reads every library). Audio check (M4) and subtitle preferences (M5) join later as steps 5–6.

## Direction contract

THESIS: Your own library is the welcome. As the index reads, your posters fill a wall across the window and the room takes their light; setup is one quiet column beside it. Refuses the category default of a centred wizard card with dots and Next buttons.

OWN-WORLD: DESIGN.md unchanged: graphite room, ink type, one lilac primary per step, Big Shoulders title card for MEZZANINE, ruled captions for facts, room light from the wall's posters.

STORY: You see the app's name and one line, sign in once, and watch your own films arrive; the last step opens straight into Home.

FIRST VIEWPORT: Left 40%: solid graphite column; content anchored to the lower third on the 40 pt gutter: MEZZANINE title card, one line, the step's single control (lilac). Right 60%: the poster wall, edge to edge, cells appearing blur-to-sharp as the index reads them, dimmed until the last step; a soft fade where wall meets column. Before sign-in the wall is empty graphite cells, no fake posters.

FORM: Poster Wall (surface round: owner picked dealt structure #2 over Express and One Page). seed:0d9ae57aa20e6984. Signature: cells resolve in a slow diagonal sweep as titles sync; the room light crossfades to a newly arrived poster every few seconds; finishing brightens the whole wall, then the window becomes Home.

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance

## Constraints

Owner's rules as in DESIGN.md (no translucent column over the wall: the column is solid; no centred floating content; whole buttons; Reduce Motion: no sweep, cells crossfade). Voice: quiet and precise. Pointer-first users must never need a key.
