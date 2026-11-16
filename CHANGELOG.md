# Changelog

What's new in each version of Mezzanine. `Scripts/release.sh <version>` needs a section here;
the update window shows it.

## Unreleased

- Remote control from Plex apps is now off by default (Settings ▸ Playback): Plex's current
  iPhone and Android apps only cast to Google Cast devices, not to Plex players like Mezzanine.

## 0.3.1 — 2026-11-16

- The Plex iPhone and Android apps only list players on your Plex account. Settings ▸ Playback ▸
  Plex mobile apps ▸ Show in Plex Apps… opens Plex's page in your browser; approve Mezzanine
  once and it appears in the apps' cast list from then on.

## 0.3.0 — 2026-11-16

- Control Mezzanine from the Plex app on your phone or from Plex Web: Mezzanine shows up as a
  player on your network. Pick it to play a title on the Mac, then pause, seek, skip and change
  audio or subtitles from the phone. Settings ▸ Playback has the switch. The phone and the Mac
  need to reach each other on the network (some routers keep Wi-Fi devices apart).

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
