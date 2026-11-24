# Changelog

What's new in each version of Mezzanine. `Scripts/release.sh <version>` needs a section here;
the update window shows it.

## 1.0.0 — 2026-11-24

- Play Next and Add to Queue on any film, episode or show; the queue plays before the next episode.
  Q shows it in the player.
- Shuffle and Shuffle Unwatched for shows, seasons, collections and playlists.
- Your Plex watchlist: in the sidebar, as a Home shelf, and on title pages (⇧W). Titles that aren't
  on your server say so.
- Films and shows in Spotlight (Settings ▸ Library turns it off).
- Shortcuts and Siri: Resume Watching, Play Next Episode, Open Title, Surprise Me.
- Surprise Me and Activity are in the toolbar on title and collection pages too.
- The window no longer shrinks to its smallest size when a film opens.

## 0.5.0 — 2026-11-24

- Sleep timer (⌥S, or Playback ▸ Sleep Timer): stop after 15 to 90 minutes, or at the end of the
  episode or film. The sound fades out first; Return keeps watching.
- What did they say? (W): back ten seconds with subtitles, which go off again by themselves.
- The player shows when the film ends by the clock. T goes to a time you type.
- Picture subtitles (Blu-ray and DVD) are drawn at the size and place the disc gave them. Before, a
  short line could fill the window's width. The Size setting still applies.
- Help ▸ Save Diagnostics Report… writes crashes, hangs and the playback log to a file, without
  names, titles, addresses or tokens. Nothing is sent.

## 0.4.0 — 2026-11-24

- A fuller sidebar: what you're watching with posters and progress, libraries that open into
  Unwatched, In Progress, Recently Added and Collections with counts, collections and smart shelves
  you pin, download progress, and how the server is reached.
- The top bar shows facts under each page's title, All / Films / Shows on Home, Surprise Me (⇧⌘R)
  and an activity button (⌥⌘A). Search lists your recent searches.
- Collections have their own pages. Pin one to the sidebar from its page or its menu.
- Right-click any title, or use the new Item menu, to mark it watched or unwatched, take it out of
  Continue Watching, play it from the start or go to its show. W marks the title in focus.
- A title marked unwatched shows as unwatched everywhere at once.
- The In Progress filter now works in TV libraries.
- Turning the volume above 100 % no longer stops the film at every step. A run of volume keys or a
  drag on a sound slider is applied once, and most steps up or down now change the loudness at once
  with no pause.
- Titles of a library you removed from Plex no longer show up in search and smart shelves.
- Checking the library in the background writes far less to disk.
- Plex's dashboard shows Mezzanine's real version.

## 0.3.3 — 2026-11-23

- Mezzanine no longer quits when the Mac's sound output changes, such as connecting AirPods or
  plugging in headphones while the app is in the background.

## 0.3.2 — 2026-11-16

- The screen no longer dims or goes to sleep in the middle of a film. While a video plays (in the
  player or the mini player) Mezzanine keeps the Mac awake; paused, closed or casting to a TV, the
  Mac sleeps as usual.
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
