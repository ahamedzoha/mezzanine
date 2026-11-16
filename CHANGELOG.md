# Changelog

What's new in each version of Mezzanine. `Scripts/release.sh <version>` needs a section here;
the update window shows it.

## 0.2.3 — 2026-11-16

- Continue Watching shows the episode you stopped on as soon as you close the player. After an
  episode ended and the next one played, the row could keep the earlier episode until a restart.
- Rows on Home and in libraries always redraw in the right order after they refresh.
- The episode that just ended is marked watched in the library right away when the next one
  starts, not only when the player closes.

## 0.2.2 — 2026-11-15

- Fixed: switching seasons on a show's page now shows that season's episodes. Before, some rows
  kept the previous season's titles, details and thumbnails.

## 0.2.1 — 2026-11-15

- The first update delivered by Mezzanine's own updater. Nothing else changes.

## 0.2.0 — 2026-11-15

- Mezzanine now updates itself: new versions download in the background and install when you
  quit. Settings ▸ Updates has the switches; Mezzanine ▸ Check for Updates… looks right away.
  An update never interrupts a film: it waits until the player closes.
- Installs from a disk image (drag Mezzanine into Applications).
- Google Cast: Play On picks This Mac or a TV; Cancel while connecting; Resume on This Mac or
  Try Again if the TV can't play it.
- Mini player, new-episode notifications, picture size (Fit, Fill, Zoom) and faster starts.
- Full screen: the empty grey bar that sometimes stayed at the top after the menu bar slid in
  is gone.
