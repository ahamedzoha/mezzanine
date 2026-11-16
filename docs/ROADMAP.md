# Mezzanine roadmap

Written 2026-11-16, after 0.2.3. Nothing here is built yet; the owner picks the order. Status of
what exists lives in `docs/PROGRESS.md`; the binding look in `DESIGN.md`. Every UI surface below
still gets an `/impeccable` round before it's built and an `apple:hig-reviewer` pass before it
ships, and every action gets a menu item and a rebindable key (CLAUDE.md). Keys named below are
proposals: check each against the shortcut table (`PlayerShortcuts`, `AppCommands`) when built.

The owner's stack: Plex, Tautulli, Playbill (`~/Code/playbill`, the owner's own), Seerr (formerly
Jellyseerr), Sonarr, Radarr, Bazarr, Kometa, qBittorrent, Prowlarr. Mezzanine must stay a
complete Plex client for people who run **only Plex**.

Contents: 1 Principles · 2 Services architecture · 3 Phase 1, Plex only · 4 Phase 2, Seerr ·
5 Phase 3, Sonarr and Radarr · 6 Phase 4, Bazarr · 7 Phase 5, Tautulli and Playbill ·
8 Not planned · 9 Testing and safety · 10 Open questions · 11 Parked

---

## 1. Principles

1. **Plex is the only requirement.** Every other service is optional, off until added, and the
   app never shows an empty button, a dead shelf or an error for a service that isn't there.
2. **Features ask for capabilities, not services.** A screen asks "can someone request titles?",
   "is there an upcoming calendar?", "are there play stats?"; a registry answers with whichever
   connected service provides it, else a Plex-only fallback, else the feature is hidden.
3. **Owner tools and member tools are different.** API keys for Sonarr, Radarr, Tautulli and
   Bazarr are admin power over the server: features built on them only light up on a Mac where
   the owner entered those keys. Seerr and Playbill sign each person in with their own Plex
   account, so a member using Mezzanine against the owner's server gets them too, with their own
   permissions and history.
4. **Nothing is written to a service without the person asking.** Requests, searches, subtitle
   downloads, ratings and watchlist changes are explicit actions with clear feedback, never side
   effects of browsing.
5. **Keys live in the Keychain** (as the subtitle keys do: `<bundleID>.services`), never in
   defaults, logs or URLs. Logs redact them (`PlexURLs.redacted` style).
6. **Same bar as the rest of the app.** Async loads drop stale answers (request identity or
   generation), rows are keyed by item identity (never `.id(position)`), everything works from
   the keyboard, Bias Light throughout.

---

## 2. Services architecture

### 2.1 Settings ▸ Services

A new Settings tab (`server.rack`), one row per service: name, address, status dot (connected,
unreachable, key refused, version too old), last check, and **Add…** / **Edit…** / **Remove**.

- **Add a service** sheet: pick the kind (Seerr, Sonarr, Radarr, Bazarr, Tautulli, Playbill),
  enter the address (`http://192.168.1.x:5055` or `https://seerr.example.com`), then either
  **Sign in with Plex** (Seerr, Playbill: uses the Plex token Mezzanine already holds) or an
  **API key** field (Sonarr, Radarr, Bazarr, Tautulli: "Settings ▸ General ▸ API Key" in each).
  **Test** calls the service's status endpoint and shows its name and version before saving.
- Each service can be turned off without removing it.
- Footer: "Mezzanine works with Plex alone. These add requests, upcoming episodes, server
  subtitles and stats."
- Optional later: **Find on my network**, probing the Plex server's own host for the default ports
  (Seerr 5055, Sonarr 8989, Radarr 7878, Bazarr 6767, Tautulli 8181). The probe never sends keys.

### 2.2 Kit layout

`MezzanineKit/Sources/MezzanineKit/Services/`:

| File | What |
|---|---|
| `ServiceKind.swift` | The six kinds, default ports, auth style (plexSSO or apiKey), the capabilities each offers |
| `ServiceConfig.swift` | Saved per service: kind, base URL, enabled, the Plex user it was added under; the secret goes to the Keychain |
| `ServiceHTTP.swift` | Shared transport: JSON, timeouts (5 s), redaction, `Retry-After`, `401/403` mapped to "key refused" |
| `SeerrClient.swift`, `SonarrClient.swift`, `RadarrClient.swift`, `BazarrClient.swift`, `TautulliClient.swift`, `PlaybillClient.swift` | Thin typed clients, lenient decoding (as `Lenient.swift`) |
| `Capabilities.swift` | Protocols: `RequestProvider`, `DownloadStatusProvider`, `UpcomingProvider`, `MissingEpisodesProvider`, `ServerSubtitleProvider`, `StatsProvider`, `LeavingSoonProvider`, `RecapProvider` |
| `TitleIdentity.swift` | Maps a Plex item to external ids and back (below) |

App side: `Mezzanine/Services/ServiceRegistry.swift` (`@MainActor @Observable`): loads configs,
checks health (at launch, on wake, every 10 min), and vends the capability providers. Views read
`registry.requests`, `registry.upcoming`, etc., all optional.

### 2.3 Capabilities and fallbacks

| Capability | Provided by | Plex-only fallback |
|---|---|---|
| Watchlist | Plex account (Discover API) | is the fallback: works for everyone |
| Request a missing title | Seerr | Plex Watchlist (Seerr's watchlist sync, if the owner turned it on, requests it) |
| Request / download status | Seerr; Sonarr/Radarr queue (owner) | none (hidden) |
| Upcoming episodes and films | Sonarr calendar; Radarr calendar | none (hidden) |
| Missing episodes in a season | Sonarr | none (seasons list what's on the server, as today) |
| Find a better copy | Sonarr / Radarr (owner) | none |
| Server-side subtitles and sync | Bazarr | Find Subtitles' current sources and on-device Match Timing |
| Stats, year in review | Tautulli | Plex watch history (lighter) |
| Who's watching now | Tautulli (owner) or Plex `/status/sessions` (owner) | Plex sessions |
| Leaving soon, personal recap | Playbill | none (hidden) |

### 2.4 Title identity

Every service names titles differently. Plex items already carry external ids (`externalGuids`,
requested with `includeGuids=1`): `tmdb://`, `tvdb://`, `imdb://`.

- Films: TMDB id (Seerr, Radarr), IMDb as a fallback.
- Shows: TVDB id (Sonarr), TMDB id (Seerr). Episodes: show id plus season and episode numbers
  (Sonarr's own episode ids come from `GET /api/v3/episode?seriesId=`).
- The other way (a Seerr search result to a Plex item): look the TMDB id up in the local index.
  The GRDB index gains an `external_ids` table, filled during sync, indexed by `(kind, id)`.
- Items without external ids (personal media, Courses) simply have no service features.

### 2.5 Networking

- LAN addresses work as they are (`NSAllowsLocalNetworking` is already set). Public HTTPS names
  need nothing extra.
- **Authentik:** if a service sits behind Authentik forward-auth on `*.example.com`, the app's API
  calls are redirected to a login page. Either give the API paths a bypass in Authentik/NPM
  (`/api/*` with the service's own key check) or add the service by LAN address. The Test button
  detects an HTML login page and says so plainly.
- Away from home: services reachable only on the LAN show "Not reachable from here" and their
  features hide; nothing errors.

### 2.6 Effort

S ≈ one working session, M ≈ two to three, L ≈ a week of sessions. Phase sizes include the design
round, HIG review, tests and docs.

---

## 3. Phase 1 — Plex only (every user)

### 3.1 Watchlist · M

- **What:** the Plex account's watchlist (shared with every Plex app). Add or remove from a title
  page (W is taken for Watched: **⇧W**, Item ▸ Add to Watchlist), from search results, and from
  titles that aren't on the server (see 4.2's search, which needs no Seerr for watchlisting).
- **Home:** a "Watchlist" shelf (a Plex-account source, alongside hubs, collections, playlists and
  smart shelves in Edit Shelves). On-server items play; others show "Not on this server".
- **API (plex.tv, account token, verify in the spike):** list
  `GET https://discover.provider.plex.tv/library/sections/watchlist/all`; add/remove
  `PUT https://discover.provider.plex.tv/actions/addToWatchlist?ratingKey=<id>` and
  `…/removeFromWatchlist`, where `<id>` is the Discover key from the item's `plex://` guid. Map to
  the server with `guid` (local index lookup).
- **Seerr bonus:** with Seerr's per-user watchlist sync on, adding to the watchlist also requests
  the title; Mezzanine mentions it once ("Seerr requests titles you add").
- **Edge cases:** managed Home users have no plex.tv watchlist (the API refuses): hide the feature
  for them. Watchlisted items later added to the server switch from "Not on this server" to
  playable on the next index sync.

### 3.2 Your ratings · S

- Star rating (½-star steps, 0–10 in Plex) on title pages and episode rows, Item ▸ Rate ▸, keys
  ⌥1…⌥5 (rebindable), and an optional "Rate it?" row on the post-play card for films.
- **API:** `PUT /:/rate?key=<ratingKey>&identifier=com.plexapp.plugins.library&rating=<0–10>`
  (−1 clears). Writes the account's rating; shown in Plex everywhere; Trakt picks it up once M10
  exists.
- A smart-shelf rule "My rating ≥ n" joins the rule builder (the index stores `userRating`).

### 3.3 Playlists, Play Next and Shuffle · M

- **Add to Playlist** (Item ▸ Add to Playlist ▸ list of video playlists, New Playlist…) from title
  pages, episode rows and grids (context menu). Playlist pages (already reachable as shelves) get
  reorder (drag, ⌥↑/⌥↓), remove (⌫) and Play / Shuffle.
- **Play Next / Add to Queue** while something plays: a queue panel in the player's ⋯ menu ("Up
  next: 3"), Up Next autoplay follows the queue before the next episode.
- **Shuffle** a show, a season or a collection (Item ▸ Shuffle, ⌥S).
- **API:** playlists `POST /playlists?type=video&title=…&smart=0&uri=server://<machineID>/com.plexapp.plugins.library/library/metadata/<keys>`,
  add `PUT /playlists/<id>/items?uri=…`, move `PUT /playlists/<id>/items/<itemID>/move?after=…`,
  delete item `DELETE /playlists/<id>/items/<itemID>`. Queues: `POST /playQueues?type=video&uri=…&shuffle=1&continuous=1`,
  then `PUT /playQueues/<id>?…` to add. Using Plex play queues keeps the queue visible to other
  Plex apps.

### 3.4 Smarter downloads · S

Already built: per-show **Keep Downloaded** (next 1/3/5/10 unwatched, watched ones cleared). Add:

- **Keep shows I'm watching downloaded** (Settings ▸ Downloads): applies "next 2" to every show in
  Continue Watching, and drops the rule when a show leaves it for 30 days.
- **Before a trip…** (File ▸ Before a Trip…): one sheet that tops up every in-progress show to N
  episodes and adds unwatched watchlist films that are on the server, with the total size shown
  before starting.
- **Storage budget:** a cap (e.g. 50 GB); rule-made downloads stop at the cap and say so; manual
  downloads may exceed it after a confirm.

### 3.5 Built into macOS · M–L

- **Spotlight** (S): index titles from the local GRDB index into `CSSearchableIndex` (title, year,
  show, poster thumbnail); opening a result opens its page. Re-indexed after each sync; removed on
  sign-out; per-profile domains so a switch swaps them.
- **Shortcuts and Siri** (M): App Intents with a `TitleEntity` (query from the index): "Resume
  Watching", "Play Next Episode of <show>", "Open <title>", "Play Random Unwatched Episode of
  <show>". Shows up in Spotlight's actions and the Shortcuts app.
- **Widgets** (M): Continue Watching (small: the next episode with progress; medium: three), Up
  Next, and Upcoming (when Sonarr is connected). Needs a widget extension target and an App Group
  (`53H97L5ZK5.com.mezzanine.shared`; team-prefixed groups need no provisioning profile on macOS)
  holding a small JSON snapshot written after each Home load; the widget opens
  `mezzanine://title/<ratingKey>` (a URL scheme the app gains).

### 3.6 Stats from Plex history · S–M

- A **Stats** page (sidebar ▸ On This Mac? or Profile menu ▸ Your Stats): hours this week/month/
  year, days in a row, top shows and films, most rewatched, by weekday and hour.
- **API:** `GET /status/sessions/history/all?accountID=<id>&sort=viewedAt:desc` (paged). Plex keeps
  views, not durations; durations come from item lengths. Tautulli replaces this with exact
  numbers when connected (7.1).

### 3.7 Your phone as a remote · L (spike first)

- **Goal:** Mezzanine appears as a player in the Plex iPhone app ("Play on: Mezzanine on
  MacBook"), so you browse on the phone and the Mac (feeding the HDMI receiver) plays; pause, seek,
  skip, audio and subtitle choice from the phone.
- **How (research spike, 1 session):** the Plex companion protocol: an HTTP server on port 32500
  (`/resources`, `/player/playback/playMedia|play|pause|stop|seekTo|skipNext|skipPrevious|setStreams`,
  `/player/timeline/poll|subscribe`), discovery over GDM (UDP multicast) and/or publishing the
  player through plex.tv resources. The spike checks which discovery current Plex mobile apps use
  in 2026 before committing. The sandbox already has `network.server`.
- **Couch mode** (optional, M): View ▸ Couch Mode: larger type and cards, focus always visible,
  everything reachable with arrows/Return/Esc and a media remote (MPRemoteCommandCenter already
  wired for Now Playing).

---

## 4. Phase 2 — Services framework and Seerr

### 4.1 Framework · M

Section 2 in full: Settings ▸ Services, the registry, Keychain storage, health checks, title
identity table in the index, capability protocols with Plex fallbacks, and DEBUG fixtures for every
client (recorded JSON under `MezzanineKit/Tests/Fixtures/Services/`).

### 4.2 Request · M

- **Search finds what you don't have:** the search panel and See All grid gain a section "Not on
  the server" (from Seerr's search: posters, year, overview), below on-server results. Without Seerr
  the section is filled by Plex Discover search and offers only Add to Watchlist.
- **Request** (lilac primary on those cards and pages; Item ▸ Request…, proposed ⌘R): films
  request in one step; shows open a sheet to pick
  seasons (All, latest, specific), showing which seasons are already on the server. Respect the
  person's Seerr permissions and quota (`/api/v1/auth/me` → permissions, quota left), and show
  "Needs approval" when auto-approve is off.
- **Status everywhere:** a small status line on cards and title pages: Requested · Approved ·
  Downloading 42 % (ETA 18 min) · Partly available · Available. Polled every 60 s while visible,
  every 10 min otherwise.
- **Your requests** shelf (Edit Shelves source "Seerr: My Requests"), newest first.
- **When it arrives:** the existing new-episode notifier gains "Severance is ready to watch"
  for requested titles that appear in the index (matched by external id), clicking opens it.
- **API (Seerr, Overseerr-compatible `/api/v1`):** sign-in `POST /auth/plex {authToken}` (session
  cookie, per person; re-auth on 401); `GET /auth/me`; search `GET /search?query=&page=`; details
  `GET /movie/<tmdbId>`, `GET /tv/<tmdbId>` (includes `mediaInfo.status` 1–5 and `downloadStatus`
  with sizes and ETA); request `POST /request {mediaType, mediaId, seasons, is4k}`; mine
  `GET /request?filter=all&requestedBy=<id>&take=50&sort=added`.
- **Owner extras:** an Approve / Decline row on pending requests from other users (needs the
  manage-requests permission), a "Pending requests" count in the sidebar.

---

## 5. Phase 3 — Sonarr and Radarr (owner)

### 5.1 Upcoming · M

- **Upcoming shelf** for shows you watch: "Severance · S2 E5 · Friday" (air date in your time
  zone, "Tonight", "Tomorrow", then weekday, then date), next 14 days; films with digital release
  dates from Radarr for watchlisted or requested films. Episodes already downloaded show "Ready".
- **Show pages:** "Next episode airs Friday" under the hero when Sonarr knows.
- **API:** Sonarr `GET /api/v3/calendar?start=&end=&includeSeries=true` (episodes with
  `airDateUtc`, `hasFile`, series `tvdbId`); filter to shows the profile watched in the last 90
  days (index). Radarr `GET /api/v3/calendar?start=&end=` (`inCinemas`, `digitalRelease`,
  `physicalRelease`, `tmdbId`).

### 5.2 Missing episodes · S

- In a season's episode list, episodes Sonarr knows but the server doesn't have appear as quiet
  placeholders: "E7 · The Dinner · not downloaded yet" or "airs 21 Nov", no play button.
- **API:** `GET /api/v3/series?tvdbId=` then `GET /api/v3/episode?seriesId=` (`hasFile`,
  `monitored`, `airDateUtc`).

### 5.3 Download progress · S

- Title pages and the Upcoming shelf show "Downloading 42 % · 18 min left" for queued items.
- **API:** `GET /api/v3/queue?includeEpisode=true&includeSeries=true` (Sonarr),
  `GET /api/v3/queue?includeMovie=true` (Radarr): `size`, `sizeleft`, `timeleft`, `status`,
  `trackedDownloadState`. Torrent client details are never shown.

### 5.4 Find a better copy · S (owner, destructive part behind a confirm)

- For a file that won't play, has the wrong language or a bad encode: Item ▸ **Search for Another
  Copy** asks Sonarr/Radarr to search (`POST /api/v3/command {name: "EpisodeSearch",
  episodeIds}` / `{name: "MoviesSearch", movieIds}`), which only upgrades within the quality
  profile. **Replace This File…** additionally deletes the current file first
  (`DELETE /api/v3/episodefile/<id>` / `moviefile/<id>`) after a confirm that names the file.
- Offered automatically after the player's fallback ladder fails ("This file won't play. Search for
  another copy?").

---

## 6. Phase 4 — Bazarr (owner)

- **Find Subtitles gains "Server (Bazarr)"** as a source: search Bazarr's providers for the title
  and language, pick a result, Bazarr downloads it next to the file, Plex picks it up (a refresh of
  the item), and every device gets it. Results show provider, score, hearing-impaired and forced
  flags. Without Bazarr the panel is as today.
- **Fix timing on the server:** "Out of sync?" in the subtitle panel offers **Sync on Server**
  (Bazarr's sync with the audio) next to the on-device Match Timing; the server copy is replaced, so
  every device benefits.
- **Missing subtitles badge** on title pages when Bazarr reports wanted languages missing.
- **API (`/api`, header `X-API-KEY`; verify exact parameters in the phase spike):**
  `GET /api/episodes?episodeid[]=` and `GET /api/movies?radarrid[]=` (subtitles, missing); manual
  search `GET /api/providers/episodes?episodeid=` / `/api/providers/movies?radarrid=`; download
  `POST` the same paths with the chosen result; sync `PATCH /api/subtitles` (action `sync`).
  Bazarr ids are Sonarr episode ids and Radarr movie ids, so this phase needs Phase 3's mapping.
- Writes files on the server: test only against a throwaway title the owner names (9).

---

## 7. Phase 5 — Tautulli and Playbill

### 7.1 Stats and Year in review (Tautulli) · M

- The Stats page (3.6) with exact numbers: watch time from real play durations, devices and
  players, by hour/day heat map, streaks, top genres, completion rate; per Home profile (Tautulli
  user id = Plex account id).
- **Year in review** (December, and on demand): a full-window sequence of cards (total hours, top
  show, most rewatched film, longest binge, first and last watch of the year), shareable as an
  image (Playback ▸ Snapshot's save pipeline).
- **Owner: who's watching now** (sidebar footer or Settings ▸ Server): active streams with user,
  title, device, direct play or transcode and bandwidth (`get_activity`).
- **API:** `/api/v2?apikey=…&cmd=get_history|get_home_stats|get_user_watch_time_stats|get_user_player_stats|get_plays_by_date|get_activity|get_users`.
  The key is admin power: stats for other profiles show only on the owner's Mac.

### 7.2 Playbill · M here + M in Playbill

Playbill has no outside API today (only its own web routes). The plan adds a small, versioned,
generic one to Playbill (useful to any Playbill install, not just Mezzanine):

- **Auth:** `Authorization: Bearer <plex token>`; Playbill validates it with plex.tv
  (`/api/v2/user`), checks the account is a member of the server, and caches the result 10 min.
- **Endpoints (proposal):** `GET /api/v1/leaving-soon` (items with Plex ratingKey/guid, removal
  date, reason); `GET /api/v1/me/recap?month=YYYY-MM` (what the monthly recap email contains);
  `GET/PUT /api/v1/me/subscriptions` (digest, arrivals, recap on/off).
- **In Mezzanine:** a **Leaving soon** shelf and a "Leaves 30 Nov" badge on cards and title pages;
  **Your month** (the recap) on the Stats page; Settings ▸ Services ▸ Playbill ▸ Emails with the
  three switches.
- **Playbill side work:** the API routes, tests, docs in its README, and a release. Playbill is
  live and emails real people: the subscriptions endpoint changes real sends, so it's built and
  tested in Playbill's local dev (`PLAYBILL_MAIL_DRY_RUN=1`) first.

---

## 8. Not planned (and why)

- **qBittorrent, Prowlarr:** no value in a player; Sonarr/Radarr already report download progress,
  and a media app shouldn't show torrent or indexer details.
- **Kometa:** nothing to build. Its collections already appear as Plex collections (shelves, Edit
  Shelves sources), and Settings ▸ Library ▸ Show original posters already strips its overlays.
  Possible later: respect Kometa's "promote to home" collection flags as default shelves.
- **Watch together (SharePlay):** large and narrow (both people need Mezzanine and access to the
  same server). Revisit after Phase 5 if wanted.

---

## 9. Testing and safety

Live services are the owner's production. The rules extend CLAUDE.md's "never write play
history while testing":

| Service | Safe to call while developing | Never in tests without the owner naming a test item |
|---|---|---|
| Plex | metadata, hubs, history, playlists list | rating, watchlist add/remove, playlist create/edit, play queues (they are visible to other apps) |
| Seerr | `auth/me`, search, details, request lists | `POST /request` (starts real downloads), approve/decline |
| Sonarr / Radarr | calendar, series/movie lookup, episodes, queue | any `command` (search), file deletes |
| Bazarr | status, episode/movie subtitle state, provider search results | download, sync, delete (write files on the server) |
| Tautulli | all `get_*` | anything else (none needed) |
| Playbill | `GET` endpoints | `PUT /me/subscriptions` against the live install |

- Every client gets fixture tests (recorded JSON, no network) and opt-in live read-only tests
  (`MEZZANINE_SERVICES=1 swift test --filter ServiceLiveTests`, reading keys from
  `.mezzanine-live.env`, which stays gitignored and mode 600).
- DEBUG builds get `-ServicesDryRun YES`: write calls are logged with their redacted request and
  not sent, so request and search flows can be exercised on screen.

---

## 10. Open questions for the owner

1. Where should the services be reached from: LAN addresses only, or the `*.example.com` names
   (and are any behind Authentik forward-auth)?
2. Seerr: is watchlist sync on for you (so Add to Watchlist already requests)? Do members request
   in Seerr today, and should Mezzanine show them approve/decline on your Mac?
3. Playbill: is a small public API in Playbill fine (it's open source)?
4. Stats: owner-only at first, or each Home profile sees their own?
5. Phone remote: worth the spike now, or after Phases 1–2?
6. Order: the recommendation is 3.1 Watchlist → 4.1–4.2 Services + Seerr → 3.4 Smarter
   downloads → 5 Sonarr/Radarr → 3.5 macOS integration → 3.7 remote spike → 6 Bazarr → 7.

---

## 11. Parked (from earlier)

- M10 Trakt: needs the owner's Trakt API app.
- OpenSubtitles and Subdl keys for Find Subtitles.
- First live run of Translate; audio profiles on each output (as the owner watches).
- Cast's Connecting/Cancel and failure panels seen on the TV.
