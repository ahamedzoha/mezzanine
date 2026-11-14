---
version: 1
slug: "mezzanine-downloads-downloadsview-swift"
primary_target: "Mezzanine/Downloads/DownloadsView.swift"
related_targets: ["Mezzanine/Downloads/DownloadStore.swift", "Mezzanine/Detail/DetailParts.swift"]
---

## Scope

M11: offline downloads inside the settled Bias Light world. The Downloads page (a sidebar
item), the Download control on title pages and episode rows, and playback from downloaded
files (online or offline). Mode: Operate. The owner picked "By Title" (surface roll
seed:a090b4aa8c5f2ce441cd151fddbd6ad8, deal 3·1·6) over "Queue and Shelf" and "Storage First".
Code-led; the wireframe card rides at the finish review.

Audience/job: the owner before a trip or a night in bed away from the LAN: pick a few films
or the next episodes of a show, forget about them, watch offline, clear space later. His wife:
pointer-first, finds the Download button on a title page.

## Direction contract

THESIS: Downloads are kept by title, the way they're watched: a show is one entry with its
episodes inside, and a rule keeps its next episodes ready.

OWN-WORLD: unchanged Bias Light. Graphite ground, raised list rows, ink type, lilac only for
the selected title's name and the primary action. Progress is an ink line, never coloured.

FIRST VIEWPORT: toolbar title "Downloads", subtitle "38 GB on this Mac · 112 GB free". Left
column (300 pt, solid raised list on the gutter): each title's poster thumb (32 × 48), name,
and one meta line ("6 episodes · 4.2 GB", "Film · 2.3 GB", or "Downloading · 1.1 of 2.3 GB ·
3 min left" with a 2 pt ink progress line under it). Right: the selected title: its backdrop
as a 160 pt strip dissolving into the room with the clear logo or title, a ruled caption,
then (shows) the keep rule pop-up ("Keep the next 3 unwatched episodes") and episode rows
(code and title, size, quality, status or progress, Play, Remove). Films show their single
file row. Remove All for the title at the end.

STORY: title page ▸ Download (film) or Download ▸ Next 3 Unwatched / This Season / Keep 3
Unwatched Downloaded (show) ▸ the Downloads page fills as files arrive ▸ play from the page,
the title page or Home (a downloaded copy always plays instead of the server's) ▸ remove when
done, or let the keep rule clear watched episodes.

FORM: signature move = the arrival: a downloading row's ink progress line becomes the title's
ruled hairline when it completes (the caption line style of the whole app), no colour, no
checkmark animation. Everything else standard native list, pop-up and buttons.

FINISH: finish review against this contract and the By Title wireframe, HIG pass, DESIGN.md
section.

## Constraints

- Owner's rules: no translucent panels, nothing centred or floating, no focus rings on custom
  rows (selection = lilac title + raised-hover fill), whole row clickable, clear space under
  the toolbar, no pointing-hand cursor.
- Every action has a key and a menu item (File ▸ Download ⌘S? no: ⌥⌘D Download on a title page;
  Delete removes the selected download; Space or Return plays).
- Files live in Movies ▸ Mezzanine (human-readable names); the token never leaves the server's
  host; downloads never write play history while testing.

## Open decisions

- Converted (smaller) copies: Original only in this build; Plex's download transcode later.
- Offline Home: the sidebar shows Downloads only, with a quiet "Offline" note, when the server
  can't be reached.
