# Live mode (sync off) — design, 1.6

Status: design, awaiting owner approval. Target: 1.6. Not yet planned or built.
Date: 2026-11-09. Issue: #413.

## Intent

Navis today syncs a server's whole library into the local database before
the app is usable, and most screens read from that copy. On very large
servers (the test server has over 56k songs) the first sync is a long
wait, and some people simply don't want a full copy on their device.

Live mode is an opt-in alternative: **sync off**. Every page asks the
server for its data when it opens and fills in as responses arrive, the
way sync-less Subsonic clients (Tempus and others) work. A user with a
huge library logs in and is browsing and playing within seconds.

The owner's framing: live mode must not be a cut-down app. Users choose a
tradeoff (speed of setup and freshness vs. offline completeness and local
speed), not a different product.

## Goals

- A per-server **Enable Sync** setting, on by default, choosable before the
  first login and changeable later.
- With sync off, first login goes straight to Home once the minimum Home
  data has loaded. No sync screen.
- Every page works live. Where the server cannot answer, the feature is
  greyed out with an explanation (see "Unavailable features"), never
  broken.
- Downloads, the rolling cache and stream playback keep working, in the
  existing order (permanent download → rolling cache → stream).
- Smooth scrolling through thousands of items, never restarting from the
  top.
- No manual refresh needed for normal use; pull-to-refresh exists as an
  override.

## Non-goals

- No snapshots of browsed pages for offline use. Offline in live mode
  means downloaded content. Users who want more turn sync on.
- No exact A–Z / scrollbar jumping on unbounded lists in the first
  version (search is the fast path for "I want Billie Eilish").
- No library-wide totals in live mode ("4,812 albums").
- Multi-server support is out of scope; the setting is stored per saved
  server so it carries over if that ever arrives.
- Not a 1.5.x feature.

## Anti-goals (would make it a failure even if it technically works)

1. **Scroll lag** on large lists. Thousands of items must stay usable.
2. **Lists that restart.** Scrolling down, or going into an album and back,
   must never re-show page 1 and lose your place.
3. **Silent data loss** when switching sync off: play history, queue,
   playlists, likes, downloads or pending server writes disappearing.
4. Features that look available and then fail.

## User-facing behaviour (decided by the owner)

### The setting

- **Login screen:** an "Enable Sync" switch, default on, with a one-line
  description. Suggested copy (builder may polish): "Keeps a copy of your
  library on this device for fast browsing and offline use. Turn off to
  browse your server live, with no waiting."
- **Settings:** the same switch under the server/configuration settings.
- **Per server:** stored with the saved server config (next to
  `lastSynced` in `server_config_table.dart`). Navis remembers it for that
  server unless the user changes it at login.

### First login with sync off

Navis probes the server (existing `ping` / OpenSubsonic extensions flow),
loads the minimum Home data, and goes to Home. No sync progress screen.

### Turning sync off (sync → live)

A confirmation dialog. Confirming removes the synced library from the
device; cancelling, or dismissing the dialog, turns the switch back on.
Reasons (owner): avoid future migration problems and don't keep a stale
copy for no reason.

What gets removed vs kept is defined in "Data model" below. Copy must say
downloads and history stay, e.g. "Remove synced library from this device?
Your downloads, history and playlists stay."

### Turning sync on (live → sync)

Confirmation: "Navis will need to sync to the server. This can take a
minute (depending on your server size). Start now?" Confirming opens the
normal sync screen; Navis builds the full library and enables sync-only
features. Cancelling leaves live mode on *(my call, mirrors the other
direction)*.

### Offline / unreachable in live mode

Each page shows what the device has (downloads, and details of songs
saved on demand, see Data model). If there is nothing, the page is empty
with a reason: **"Client is Offline"** (no network) or **"Server
Unreachable"** (network up, server not answering). Downloads play
normally.

### Unavailable features

- Default: features that cannot work live stay **visible but greyed out**
  with "Available with sync on."
- One app-wide switch: **"Hide features unavailable in live mode"**. On:
  every greyed-out feature disappears. Shown only while the current server
  is live; when sync is on it is greyed out and every feature shows.
- Granular hiding uses the existing per-feature toggles (genre page
  `showGenresPageProvider`, Home module visibility). No new per-feature
  switches.

### Lists, scrolling and freshness

- **Paging:** album lists load by offset in pages from the server
  (`getAlbumList2` with `size`/`offset`), and the next page is requested
  before the user reaches the end. Artist and genre lists come back in one
  response.
- **Never restart:** loaded pages are kept in memory for the session and
  only appended to. Going into a detail page and back restores the same
  items and scroll position.
- **Rows:** fixed height with placeholders while loading, so the list does
  not jump.
- **Cover art:** request thumbnail sizes via `getCoverArt` `size`, never
  full-size art in lists.
- **Expiry:** a loaded list expires after **5 minutes** (owner said 5–10;
  5 is my call). Returning after that loads fresh; returning within keeps
  position. **Pull-to-refresh** reloads anytime and replaces "resync" in
  live mode. Changing sort order starts the list fresh.
- **Optional, not in v1 unless the owner asks:** on return, quietly check
  the first page of "Recently Added" and insert new albums at the top.
- **Jumping:** scrollbar drag / A–Z on unbounded lists is approximate or
  absent in v1; the builder chooses (estimate, or load the landed region).

### Search

- Uses the server's `search3`. Slower per keystroke is accepted.
- The existing 300 ms debounce stays (`debouncedSearchProvider`,
  `search_controller_provider.dart:141`).
- **Stale responses must be discarded:** a slow reply for an older query
  must never overwrite a newer one.
- Offline in live mode: search covers downloaded/saved songs only *(my
  call)*.

## Data model (the key technical decision)

**Finding:** live mode cannot drop the `songs` / `albums` / `artists`
tables. Many offline-critical paths join or reference them (survey,
verified):

- Queue restore inner-joins `songs` (`play_queue_dao.dart`, `_queueRowsQuery`).
- Playlist songs inner-join `songs` (`playlist_dao.dart`, `watchPlaylistSongs`).
- `play_history.song_id` references `songs` with **`onDelete: cascade`**
  (`play_history_table.dart:8-9`): deleting songs deletes history.
- `scrobble_queue`, `listenbrainz_feedback_queue`, `play_queue_items`,
  `playlist_songs` have FKs to `songs`; `PRAGMA foreign_keys = ON`
  (`navis_database.dart:310`).
- `download_queue` and `cached_tracks` store only ids; all labels, file
  naming (`download_service.dart` `_resolvePermanentPathForEntry`) and
  the metadata-gaps view come from `songs`.
- Star/rating writes (`star_sync_dao.dart`) no-op for unknown songs.
- Now-playing / OS media metadata reads `songByIdProvider` / `albumProvider`.

**Decision: "no bulk sync", not "no database".** In live mode the library
tables become an **on-demand metadata store**: a song/album/artist row is
written when the user touches it (plays, queues, downloads, stars, rates,
adds to a playlist or match flow, or a playlist/album page shows it, at
the builder's discretion). Reuse the existing provisional-row path that
already maps API `Song` → `SongsTableCompanion`
(`queue_provider.dart:563-606`) and `getSong` / `getSongPayload`.
Browse pages themselves render from API responses, not from these rows.

The sync-lifecycle columns (`isProvisional`, `catalogGeneration`,
`serverDeletedAt` in `songs_table.dart`) assume sync semantics; the
builder must define how live mode sets and interprets them so the sync
engine does not treat on-demand rows as stale or deleted, and so turning
sync on later reconciles cleanly.

**Downloads carry their own metadata.** Permanent downloads must keep
title, artist, album, album id and cover id independent of library rows,
so a downloaded file survives any library removal. Where that lives
(columns on `cached_tracks` / `download_queue`, or guaranteed retained
rows) is the builder's call; it needs a schema bump (see project rule on
schema versions after a dev publish).

**Sync → live removal keeps** every row still referenced by: downloads
(permanent and in progress), play history, the saved queue, playlists
(server and local), match flows, likes/ratings and their pending dispatch,
scrobble and ListenBrainz queues, and anything else the builder finds with
an FK or join to these tables. Everything else in the library tables,
plus sync-only tables (sync work/ledger/leases, scan observations, search
text index, album-artist index, genre index, etc.), is removed. Because of
the cascade on `play_history`, removal must never be a blunt table wipe.
This is the riskiest part of the feature and gets a dedicated failing
test first.

## Login / routing

Today `initialSyncRequiredProvider`
(`session_route_provider.dart:121-133`) returns true for any profile with
`lastSynced == null`, and the router redirects to `/initial-sync`. Live
mode needs a recorded "live and ready" state for the profile so routing
goes to onboarding/Home without a catalog. Minimum Home calls: `ping` +
`getAlbumList2` (newest, random, frequent, recent) + `getStarred2` +
`getPlaylists`, all already implemented in `subsonic_api_client.dart`.

## Inventory summary

Full survey (file:line evidence for every row):
`docs/plans/Live_Mode_1-6_Inventory.md`. Highlights:

**Already live:** Home recently added / random / frequent albums, album
and artist info, online search, lyrics, Instant Mix / Same Vibes,
internet radio, rolling cache, server/integration settings.

**Easy live version (direct endpoint):** albums (paged `getAlbumList2`),
artists (`getArtists`), album detail (`getAlbum`), artist detail
(`getArtist`), liked songs/albums/artists (`getStarred2`), playlists
(`getPlaylists`, `getPlaylist` entries), genre list (`getGenres`), genre
songs (`getSongsByGenre`), genre albums (`getAlbumList2?type=byGenre`,
needs a server-support check), recently played albums
(`getAlbumList2?type=recent`).

**Missing client endpoints to add:** `getGenres`, `getSongsByGenre`,
`getTopSongs`.

**Needs a new approach:** Most Played songs and Recently Played songs
(no global server ranking/history; local `play_history` can still feed
Recently Played for songs played on this device), albums-by-year view,
artist "featured on" albums, artist top tracks matching, You Might Like,
ListenBrainz / Deezer matching against the library, downloaded-only
filters (intersect server lists with the local download set), artist
"play all", Android Auto browse tree and media-session contexts.

**No server equivalent (greyed out in live mode):** library totals,
partial-album / completeness detection, sync settings / repair /
unavailable-review screens, library cache rebuild.

The builder decides per "new approach" item whether to rebuild it on
server calls, approximate it, or grey it out, and records the decision in
the plan. Owner preference: maximise what works.

## Constraints

- Project rules: never instantiate `NavisDatabase` outside Riverpod; never
  mutate a provider during build; keep download → rolling cache → stream
  order; no credentials in logs.
- Silent self-healing policy: transient live-fetch failures retry
  invisibly; notices only when the user must act (offline/unreachable).
- iOS/Android parity, plus desktop.
- Reuse first: existing `SubsonicApiClient`, provisional-row mapping,
  existing reachability/offline providers (`searchIsOfflineProvider` and
  peers), existing visibility toggles, existing sync screen for live→sync.

## Clarifications after builder check (coordinator's calls unless marked)

1. **Scope of v1.** Owner: every feature should work live; greying out is
   for features that truly cannot. So discovery (You Might Like, Deezer,
   ListenBrainz) is rebuilt on server calls where possible, and
   **Android Auto must browse live** (it cannot be greyed out in a car):
   rebuild its tree from `getArtists` / `getArtist` / `getAlbum` /
   `getStarred2` / `getAlbumList2`. Phasing may ship browse + play +
   downloads first and discovery in a later 1.6 phase, but 1.6 ships with
   all of it. *(Pending owner confirmation.)*
2. **Expiry vs. "never restart".** The anti-goal applies within a visit
   and within the 5-minute window: a list never resets while you scroll
   or when you return within 5 minutes. Expiry is checked only when a
   page is re-entered, never mid-scroll. After expiry, re-entering loads
   fresh from the top, the same as pull-to-refresh.
3. **Offline rendering.** Library tabs fall back to their existing
   downloaded-only views (the DAO `downloadedOnly` paths, e.g.
   `library_dao.dart:705`) over on-demand rows; Downloads works as today;
   other pages (genre detail, artist detail without saved rows, etc.)
   show the "Client is Offline" / "Server Unreachable" empty state. No new
   per-page offline implementations.
4. **External/remote rows on removal.** Remote catalog rows (`isExternal`,
   `ext-deezer-*`) follow the same rule as server rows: kept if anything
   references them, otherwise removed (they are re-fetched on demand).
   Deezer/Last.fm/ListenBrainz match stores and other external caches are
   not library tables and are kept.
5. **Upgrade gate.** Live profiles skip the library cache-upgrade rebuild
   route (`app_router.dart` `cacheSystemUpgradeRequired`), since there is
   no catalog to rebuild. Download, cache and schema migrations still run
   as normal; the builder must check each upgrade step for live profiles.
6. **Scroll bar.** On the 56k-song test server: scroll through 2,000+
   loaded albums on a mid-range Android device and on desktop with no
   visible jank, measured with the existing UI heartbeat / runtime
   profiler (no UI-isolate stalls over one frame budget attributable to
   the list). Evidence goes in the PR.

## Left to the builder

- State shape for paged live lists (provider design, page size, prefetch
  threshold, memory cap).
- How browse widgets that take Drift rows today (`AlbumCard` takes
  `AlbumsTableData`) accept API models: adapters vs. shared view models.
- Exact on-demand row triggers and the lifecycle-column semantics.
- Where download metadata lives.
- Jumping behaviour on unbounded lists.
- Per-item decisions for the "new approach" list.
- Phasing (suggested: data model + removal + login gate first, then
  browse pages, then the rest).

## Risk

Risky per project rules (state machine for the switch, migration/schema,
data deletion). Full lifecycle: Opus plan, failing tests first, Sonnet
build, fresh Sonnet + Opus review before merge.
