# Live-mode inventory — Navis (synced DB → on-demand Subsonic API)

Read-only survey of the Navis repository at `dev` 978df9c30 (2026-11-09). Line numbers drift as the branch moves.
Nothing was edited. All evidence is `file:line` in this repo.

**Buckets**

| Bucket | Meaning |
|---|---|
| A | Already works live: calls the Subsonic API today, DB not required |
| B | Easy live version: one standard Subsonic endpoint answers the same question |
| C | Needs a new approach: server answers partially (sort/filter/paging over the whole library, mixed with Deezer/Last.fm/ListenBrainz, local ranking) |
| D | No server equivalent: needs whole-library local data (totals, stats, local-only state, partial-album logic) |
| E | (separate section) offline-critical: downloads/cache/queue/history/scrobble/star/now-playing need song/album/artist rows that today come only from the synced tables |

**Where the data lives.** Feature UI reads Drift models, not API models: `AlbumCard` takes an `AlbumsTableData` row (`lib/src/common_widgets/album_card.dart:59`), and every browse list is a `StreamProvider` over `libraryDao`/`historyDao` composed in the provider root (`lib/src/providers/app_providers.dart:1939-2148`). There is no `lib/src/services/`; the shared layer is `lib/src/providers/app_providers.dart` (composition root) plus `lib/src/utils/` (no library reads except diagnostics: `lib/src/utils/sync_diagnostics_server.dart:1778`).

Cross-cutting facts worth designing around:

- The API `Song` model already carries everything playback/metadata needs: `starred`, `userRating`, `playCount`, `genres`, `replayGain` (`lib/src/api/models/song.dart:8-47`), and `Album` carries `starred`, `userRating`, `playCount`, `songCount`, `artists` (`lib/src/api/models/album.dart:9-30`).
- A `Song` → `SongsTableCompanion` mapping already exists for provisional rows (`lib/src/features/player/presentation/queue_provider.dart:563-606`), so "API model → row" is not new work.
- Several tables have real foreign keys to `songs(id)` with `PRAGMA foreign_keys = ON` (`lib/src/database/navis_database.dart:309-310`): `play_queue_items` (`lib/src/database/tables/play_queue_items_table.dart:12-13`), `scrobble_queue` (`lib/src/database/tables/scrobble_queue_table.dart:10-11`), `listenbrainz_feedback_queue` (`lib/src/database/tables/listenbrainz_feedback_queue_table.dart:10-11`), `playlist_songs` (`lib/src/database/tables/playlist_songs_table.dart:12-13`), `play_history` (`lib/src/database/tables/play_history_table.dart:8-9`). `songs`, `albums`, `artists` are therefore *not* optional in live mode unless those tables change.

---

## 1. Home

| item | file:line evidence | bucket | Subsonic endpoint or why not | notes |
|---|---|---|---|---|
| Recently added albums | `lib/src/features/home/presentation/home_providers.dart:1919-1934` | A | `getAlbumList2?type=newest&size=20` | Already API; renders `List<Album>` (`home_screen.dart:1501-1532`) |
| Random album list (Home) | `home_providers.dart:1963-1979` | A | `getAlbumList2?type=random` | Re-picks after a sync (`_repickAfterLibrarySync`, `home_providers.dart:1944-1961`) |
| Random albums (You Might Like fallback) | `home_providers.dart:1981-1996` | A | `getAlbumList2?type=random` | Same call, separate provider |
| Frequent albums | `home_providers.dart:2877-2893` | A | `getAlbumList2?type=frequent` | |
| Liked songs row (5) | `home_providers.dart:1913-1916` → `library_dao.dart:2552` | B | `getStarred2` (songs) then take 5 | `getStarred2` has no size/offset; slicing is client-side |
| Recently played albums | `home_providers.dart:1936-1941` → `history_dao.dart:66` | B | `getAlbumList2?type=recent` | Local history (`play_history`) also feeds offline; see E |
| Recently played tracks | `home_providers.dart:2872-2875` → `history_dao.dart:34` | C | No "recent songs" endpoint; `getNowPlaying` is current-only | Needs local history or per-song fan-out; no paging equivalent |
| Most played songs | `home_providers.dart:1998-2001` → `library_dao.dart:2603` | C | `getTopSongs` is per-artist only; no global sort by playCount | Would need an aggregate over the whole catalog; server cannot sort songs by play count |
| Downloaded liked songs | `home_providers.dart:2003-2013` | D | — | Intersects `cached_tracks` + `songs.starred`; needs a download-local metadata path (see E) |
| Downloaded recently added albums | `home_providers.dart:2017-2028` | C | `getAlbumList2?type=newest` + local download set | Merge of the two sides |
| Downloaded recently played albums | `home_providers.dart:2033-2045` | C | `getAlbumList2?type=recent` + local download set | |
| Downloaded random albums | `home_providers.dart:2051-2080` | C | `getAlbumList2?type=random` + local download set | Falls back to `getAllAlbums()` (`2058`) |
| Downloaded most played songs | `home_providers.dart:2852-2860` | D | — | Same reason as Most played songs, plus download join |
| Random showcase / "You Might Like" | `home_providers.dart:2085-2200` | C | Mixed: `getAlbumList2?type=random`, `getStarred2`, ListenBrainz cache, Deezer trending | Reads `getAllAlbums()`/`getLikedAlbums()` (`2097-2162`) |
| ListenBrainz Discover stream | `home_providers.dart:716-1290`, matching at `1165`, `1327`, `2345-2400` | C | External (ListenBrainz) + local track matching (`getTrackMatchCandidates`, `getSongsByIds`) | No server involvement; local matching is the blocker |
| Deezer new releases | `lib/src/features/home/presentation/home_deezer_providers.dart:110-197` (dao at `124`) | C | External (Deezer) + local artist→Deezer id resolution via library buckets | |
| Trending Now (Deezer chart) | `home_deezer_providers.dart:307` | C | External + local match store (`artist_top_track_match_store`) | |
| Home "Instant Radio" availability gate | `lib/src/features/home/presentation/home_screen.dart:4524-4534` → `library_dao.dart:1322` | D | — | Whole-library `EXISTS` over songs/cached tracks; live mode needs a different rule |
| Home onboarding warm-up prefetch | `lib/src/features/home/presentation/home_onboarding_warmup.dart:279-360` | C | Inherits every row above | Warms cover art through the API already (`471-505`) |
| Recently liked albums section | `app_providers.dart:2049-2052` (provider) | B | `getStarred2` (albums), sort by `starred` | |

---

## 2. Library (browse)

Section order/enum: `lib/src/features/library/presentation/library_scroll_provider.dart:23-32`.

| item | file:line evidence | bucket | Subsonic endpoint or why not | notes |
|---|---|---|---|---|
| Albums: total count | `app_providers.dart:2018-2023` → `library_dao.dart:1186` | D | No "library totals" endpoint | Used for grid/section header (`library_screen.dart:1248`, `2192`) |
| Albums: paged grid (recentlyAdded/newest/name/artist) | `app_providers.dart:2025-2040` → `library_dao.dart:1207`, `1236`; call sites `library_screen.dart:1257-1258`, `2189` | B → C | `getAlbumList2?type=newest|recent|alphabeticalByName|alphabeticalByArtist` with `size`/`offset` | `AlbumSortOrder` at `library_dao.dart:46`. Server caps page size (commonly 500); infinite scroll over a large library becomes C |
| Albums: year view (grouped by year) | `app_providers.dart:2094-2119` → `library_dao.dart:1226`; UI `library_screen.dart:1477` | C | No year grouping endpoint | Needs paging the whole album list and grouping client-side |
| Liked albums tab | `app_providers.dart:2043-2046` → `library_dao.dart:1159`; UI `library_tabs.dart:770` | B | `getStarred2` (albums) | |
| Liked songs tab | `app_providers.dart:2054-2057` → `library_dao.dart:2561` | B | `getStarred2` (songs) | |
| Liked-album songs (liked tab expansion) | `app_providers.dart:2059-2064` → `library_dao.dart` `watchSongsFromLikedAlbums` | C | `getStarred2` gives album ids; songs need `getAlbum` per album | Fan-out of N album calls |
| Artists tab | `app_providers.dart:1939-1942` → `library_dao.dart:260`; UI `library_screen.dart:976` | B | `getArtists` (already implemented) or `getIndexes` | |
| Liked artists | `app_providers.dart:1944-1947` → `library_dao.dart:271` | B | `getStarred2` (artists) | |
| Playlists tab | `playlist_providers.dart:92-95`, `112-160`; tab `library_tabs.dart:154-160`, sync `218-249` | B | `getPlaylists` | Local+virtual items make it C-shaped, see §5 |
| Genres tab | `genre_providers.dart:26-42`; tab wiring `library_screen.dart:473` | B | `getGenres` | Not implemented in the client yet; see §6 |
| Radio tab | `radio_screen.dart:70-74` | A | `getInternetRadioStations` | Local stations are local-only (`local_radio_stations` table) → D for those rows |
| Downloaded-only filter (all tabs) | `app_providers.dart:2746-2758`, DAO `downloadedOnly` params `library_dao.dart:838-960` | C/E | `getStarred2`/`getAlbumList2` + local `cached_tracks` set | Server cannot filter by "downloaded on this device" |
| Library sync banner/status | `lib/src/features/library/presentation/library_sync_provider.dart:268` (`librarySyncControllerProvider`) | D | — | Whole subsystem is sync-only |
| Unavailable/missing review (entity identity) | `lib/src/features/library/presentation/unavailable_review_screen.dart:14-22`, `199`, `337-460` | D | — | Pure local reconciliation between old/new server ids |
| Required library rebuild (cache upgrade) | `lib/src/features/library/presentation/required_library_rebuild_provider.dart:59-230` | D | — | Blocking screen, see F |

---

## 3. Album / Artist detail

| item | file:line evidence | bucket | Subsonic endpoint or why not | notes |
|---|---|---|---|---|
| Album header + track list | `app_providers.dart:1972-2014` (`watchAlbumById`+`watchSongsByAlbum`); screen `album_detail_screen.dart:262` | B | `getAlbum` | `getAlbum` already normalizes `song`→`songs` (`subsonic_api_client.dart:179-192`) |
| Album detail "hydrate on open" | `album_detail_screen.dart:140-166`, `2382`; controller `library_sync_provider.dart:848` (`requestTarget(album)`) | B | `getAlbum` | Today it syncs the album into the DB then reads it back; live mode calls `getAlbum` directly |
| Album info / bio | `app_providers.dart:2610` (`albumInfoProvider`) | A | `getAlbumInfo2` | |
| Album star | `album_detail_screen.dart:1956-1972` (`starSyncDao.setStarred`) | E → B | `star`/`unstar` | Needs a row to flip today; direct star + optimistic state is the live version |
| Album rating | `app_providers.dart:2089-2093` → DAO | B | `setRating`, `album.userRating` | |
| Album download badge/summary | `app_providers.dart:2120-2148` → `library_dao.dart:1267` | E | — | `watchAlbumDownloadSummaries` joins songs/albums |
| Album "missing tracks"/partial logic | `album_detail_screen.dart:1457-1480` (`countSongsByAlbum`, `library_dao.dart:1366`) | D | — | "Server album has N songs, we hold M" is a local completeness heuristic |
| Artist header + albums | `app_providers.dart:1949-1971` → `library_dao.dart:1133`, `1066`; screen `artist_detail_screen.dart:196-220`, `338-342` | B | `getArtist` (returns `album` list) | |
| Artist "featured in" album bucket | `library_dao.dart:1033-1066` (`ArtistAlbumBuckets`), `album_artist_index` table | C | `getArtist` only returns albums where the artist is the album artist | Featured-in needs `search3`/`getAlbumList2` fan-out or is dropped |
| Artist detail hydrate-on-open | `artist_detail_screen.dart:148-186`; `library_sync_provider.dart:883` (`requestTarget(artist)`) | B | `getArtist` | Same rewrite as album |
| Artist info + similar artists | `app_providers.dart:2667` (`artistInfoProvider`); `artist_detail_screen.dart:1433` | A | `getArtistInfo2` | Deezer can pre-empt the server list (`artist_detail_screen.dart:1368-1433`) |
| Artist top tracks | `lib/src/features/library/presentation/artist_top_tracks_provider.dart:79-206`; resolver `artist_top_track_resolver.dart:59-140` | C | `getTopSongs` (not implemented) + Deezer/Last.fm + `search3` matching | Ranking/matching is local |
| Artist "play all" (random, streaming) | `lib/src/features/library/presentation/artist_playback_controller.dart:255-300` → `getArtistPlaybackSnapshot` (`library_dao.dart:339`) | C | `getArtist` + `getAlbum` fan-out, then shuffle | Progressive hydration is a sync feature |
| Artist missing albums (Deezer) | `artist_deezer_providers.dart:99-140` | C | External + library album list to diff | |
| Artist → Deezer id resolution | `artist_deezer_providers.dart:20-42` (library album buckets) | C | External | |
| Artist stored row lookup | `artist_detail_screen.dart:155-157` | B | `getArtist` | |

---

## 4. Search

| item | file:line evidence | bucket | Subsonic endpoint or why not | notes |
|---|---|---|---|---|
| Online query | `lib/src/features/search/presentation/search_controller_provider.dart:132-290` (call at `210`) | A | `search3` (artist/album/song counts, offsets) | 300 ms debounce (`141-143`) |
| Local/offline query | `search_controller_provider.dart:384-405` (`searchArtistsLocal`/`searchAlbumsLocal`/`searchSongsLocal`) | B → D offline | `search3` when online | `song_search_text` index; offline needs local data by definition |
| Merge + local ranking of local & remote results | `search_controller_provider.dart:147-150`, `226-232` (`rankSearchResult`, `mergeAndRankSearchResults`) | C | — | Live mode has only the remote half; ranking still works on it |
| Genre hits inside search | `search_controller_provider.dart:152-158` → `library_dao.dart:725` | B | `getGenres` + client merge-key filter | Only under "All" |
| Playlist/radio "collection" hits | `search_controller_provider.dart:457-495` | B | `getPlaylists` + `getInternetRadioStations` | Matched in memory, not by `search3` |
| Deezer search boost / top result | `search_controller_provider.dart:298-320`; `lib/src/features/search/domain/deezer_search_boost.dart` | C | External (Deezer) | Merged into the same ranked list |
| Recent searches | `search_controller_provider.dart:50-56` (`historyDao`) | D | — | Local-only state |
| Offline banner | `search_controller_provider.dart:88-92` (`searchIsOfflineProvider`) | A | — | Reachability-based |
| Search result song row star/rating | `lib/src/common_widgets/song_context_menu.dart:56-59` (`songStarredProvider`, `songRatingProvider`) | E | `getStarred2` / `Song.starred` | Menu takes a `SongsTableData` row today (`song_context_menu.dart:48-59`) |
| Android Auto search | `lib/src/features/auto/data/auto_media_tree_service.dart:505-560` | A | `search3` | Local fallback at `544-553` |

---

## 5. Playlists

| item | file:line evidence | bucket | Subsonic endpoint or why not | notes |
|---|---|---|---|---|
| Playlist list | `lib/src/features/playlists/presentation/playlist_providers.dart:92-95` | B | `getPlaylists` | Currently served from `playlists` table |
| Playlist refresh from server | `playlist_providers.dart:218-249` (`playlistSyncProvider`, `playlistDetailSyncProvider`) | B | `getPlaylists`, `getPlaylist` | `playlist_actions.dart:117`, `135` already call these |
| Playlist detail header | `playlist_detail_screen.dart:80-87` → `playlist_providers.dart:265-270` | B | `getPlaylist` | |
| Playlist songs (rows) | `playlist_detail_screen.dart:81`, `566`, `987` → `playlist_providers.dart:251-255` → `playlist_dao.dart:154-169` | E | `getPlaylist` returns `entries: List<Song>` (`lib/src/api/models/playlist.dart:8-20`) | The DAO **inner-joins `songs`**; songs absent from the DB vanish from the playlist. Biggest single E item |
| Playlist list composition (yours / weekly / Trending / others) | `playlist_providers.dart:112-160` | C | `getPlaylists` + ListenBrainz + Deezer trending | Virtual items have no server playlist |
| Device-local playlists | `playlist_dao.dart:31-43` (`createLocalPlaylist`, `id: 'local:<uuid>'`) | D | — | Local-only by design; can be uploaded (`playlist_actions.dart:233-260`) |
| Create / rename / reorder / delete | `playlist_actions.dart:38-260`, `353`, `498-537`; API calls at `117`, `135`, `149` | A/B | `createPlaylist`, `updatePlaylist`, `deletePlaylist` | `playlist_actions.dart:498-502` validates ids via `libraryDao.getSongsByIds` → E |
| Playlist song count / mutation version | `playlist_dao.dart:94-108`, `171-197` | D | — | Reconciliation journals used by the sync engine |
| Playlist covers | `playlist_providers.dart:258-262` → `playlist_dao.dart:110` | E | — | Cover ids come from `playlist_songs` ⋈ `songs.coverArt` |
| Add-to-playlist sheet | `lib/src/features/playlists/presentation/add_to_playlist_sheet.dart` | B | `updatePlaylist` | Song ids are enough; sheet lists playlist rows |
| Ownership / editability | `lib/src/features/playlists/domain/playlist_ownership.dart` | A | `Playlist.owner` vs `serverConfig.username` (`playlist_providers.dart:99-103`) | |

---

## 6. Genres

Genre index is a sync-built table (`song_genre_index_table.dart`), rebuilt at the end of a sync; queries are one-shot and keyed on a sync epoch (`genre_providers.dart:11-23`).

| item | file:line evidence | bucket | Subsonic endpoint or why not | notes |
|---|---|---|---|---|
| Genre list (merged by `genreKey`, counts) | `genre_providers.dart:26-42` → `library_dao.dart:702-723` | B | `getGenres` | Client merge of spellings still works on the response |
| Genre sort by songs/albums | `library_dao.dart:706-717` (`GenreSortOrder`) | B | `getGenres` returns `songCount`/`albumCount` | Sort in memory |
| "Genres pending sync" placeholder | `genre_providers.dart:44-52` (`lastFullSyncAppBuild`) | D | — | Sync-only concept |
| Genre header counts | `genre_providers.dart:54-58` → `library_dao.dart:740` | B | `getGenres` (filter by name) | |
| Genre albums grid (sorted, paged, query-filtered) | `genre_providers.dart:70-92` → `library_dao.dart:838-906` | C | No "albums by genre" endpoint | Requires paging `getSongsByGenre` and deduping album ids, or `search3` by genre |
| Genre songs grid | `genre_providers.dart:95-118` → `library_dao.dart:907-960` | B | `getSongsByGenre` (paged, `count`/`offset`) | **Not implemented in the client**; also mixes sort by artist/album client-side |
| Genre downloaded-only filter | `genre_providers.dart:32`, DAO `_genreDownloadedSql` `library_dao.dart:696-698` | C | — | Device-local download join |
| Genre chips on song/album rows | `lib/src/common_widgets/genre_chips.dart:12-53` | A | `Song.genres` from the API | |
| Genre detail screen | `lib/src/features/library/presentation/genre_detail_screen.dart:68`, `475` | B/C | as above | |
| Genre names in global search | `library_dao.dart:725-739`; caller `search_controller_provider.dart:152-158` | B | `getGenres` | |

---

## 7. Player / queue / now playing

| item | file:line evidence | bucket | Subsonic endpoint or why not | notes |
|---|---|---|---|---|
| Queue contents + edits | `lib/src/features/player/presentation/queue_provider.dart:102-268`, `606-707` | B | client-side | Holds ids + `SongsTableData`; `replaceWithSongs(List<Song>)` already exists (`269`) |
| Queue row read-back from DB | `queue_provider.dart:314-340` (`getSongsByIds`, `replaceWithTableData`) | E | `getSong` per id | If a row is missing, the read-back length check fails and the queue replacement is abandoned |
| Provisional song/album/artist persistence | `queue_provider.dart:460-606` | E | `getSong` payload | Sync-independent path that already writes rows from API models |
| Saved queue restore | `lib/src/database/daos/play_queue_dao.dart:37-59`, table FK `play_queue_items_table.dart:12-13` | E | — | Restore is an **inner join to `songs`**; no row ⇒ song silently dropped from the restored queue |
| Now playing: song + album metadata | `lib/src/features/player/presentation/now_playing_screen.dart:404`, `1603`, `1834-1838`; `media_info.dart:130-142` | E → B | `getSong`, `getAlbum` | |
| Song "server details" panel | `media_info.dart:36-90` (`songServerDetailsProvider`, `getSongPayload`) | A | `getSong` | Raw payload for path/bit depth/channels/BPM |
| Lyrics | `app_providers.dart:2557` (`lyricsProvider`); `lib/src/features/player/data/lyrics_resolver.dart` | A/B | `getLyricsBySongId` (+ LRCLIB) | Cache table `external_lyrics_cache` |
| Instant Mix / Same Vibes | `lib/src/features/player/data/recommendation_service.dart:220-300` (`getSimilarSongs2`, `getInstantMix`) | A | `getSimilarSongs2`, `getInstantMix` | |
| Same Vibes seed/identity lookups | `same_vibes_notifier.dart:1349-1375` (`getAlbumSongCountsByIds`, `getSongsByIds`) | E | — | Canonical artist+title key comes from song rows |
| Smart queue / personal radio | `recommendation_service.dart:113-160` (`getAllSongs`), `personal_radio_notifier.dart:119-170` | C | `getSimilarSongs2`/`getRandomSongs` exist | Eligibility pool + local-shuffle rules are library-wide |
| Radio playback | `navis_audio_handler_radio.dart`, `radio_screen.dart` | A | `getInternetRadioStations`, stream URLs | |
| Play history write | `lib/src/features/player/data/navis_audio_handler_media_session.dart:1583` → `history_dao.dart:24-32` | E | — | `play_history.song_id` FK to `songs` |
| Scrobble to server | `lib/src/features/player/data/scrobble_service.dart`; `subsonic_api_client.dart:698-714` | A | `scrobble` | Offline queue has a FK to `songs` → E |
| Now-playing title/artist for the OS | `navis_audio_handler_media_session.dart` (+ `media_info.dart:130-142`) | E | `getSong` | Falls back to DB rows |
| Star/unstar from player | `now_playing_actions.dart`, `now_playing_metadata_panel.dart` → `star_sync_dao.dart:70-135` | E | `star`, `unstar`, `setRating` | Writes the intent + row state locally, then dispatches (`annotation_sync_dispatcher.dart:125-140`) |
| Android Auto resume fallback | `navis_audio_handler_persistence.dart:211-240` | E/C | `getStarred2` / local history | Queues recently played, then liked songs, then instant radio |
| Playback source resolution | `lib/src/features/player/data/playback_source_resolver.dart:165-320` | E (light) | `stream`/`download` URL | Only touches `libraryDao.deleteLocalOnlySong` (`309`) |
| Replay gain / untagged | `lib/src/features/player/presentation/replay_gain_untagged_provider.dart` | E (light) | `Song.replayGain` | Reads stored rows |

---

## 8. Downloads & cache

| item | file:line evidence | bucket | Subsonic endpoint or why not | notes |
|---|---|---|---|---|
| Download queue rows | `lib/src/database/tables/download_queue_table.dart:12-20` (only ids stored); UI `downloads_screen.dart:429-444`, `584` | E | — | Rows hold `songId`/`albumId`/`playlistId`; every label comes from `songByIdProvider` |
| Enqueue a song | `lib/src/features/downloads/data/download_service.dart:1410-1425` (`getSongsByIds`, `serverDeletedAt` check) | E | `getSong` | |
| Enqueue an album | `download_service.dart:1501-1510` (`watchSongsByAlbum`) | E | `getAlbum` | |
| Permanent downloaded tracks list | `app_providers.dart:2804` (`permanentCachedTracksProvider`); UI `downloads_screen.dart:739`, `827` | E | — | `cached_tracks` has no metadata columns (`cached_tracks_table.dart:12-31`) |
| Download metadata gaps | `lib/src/features/downloads/domain/download_metadata_gaps.dart:30` → `cache_dao.dart:181-215` (inner join `songs`) | E | `getSong` | Orphan cache rows with no `songs` row are skipped by design |
| File naming / folder layout from metadata | `download_service.dart:1660-1685` (`_resolvePermanentPathForEntry(song:)`) | E | `getSong` | Live mode must persist title/artist/album somewhere for the path |
| SAF relocation / path rebase | `download_service.dart:3380-3400`, `3519` | E | — | |
| Redownload / remove | `downloads_screen.dart:915`, `1105-1140` | E | — | |
| Auto-download starred | `downloads_screen.dart:1219-1261` (`getLikedDownloadCandidates`) | E/C | `getStarred2` + local cache set | |
| Download reconciliation screen | `lib/src/features/downloads/presentation/download_reconciliation_screen.dart:158-161` → `library_dao.searchDownloadReconciliationCandidates` (`library_dao.dart:1529`) | C | `search3` | Local fuzzy matching of downloaded files to library songs |
| Repair/missing-file flow | `download_service.dart:2210-2275` (`markSongsSuspectedMissing`) | E/C | — | Writes `songs.serverDeletedAt` |
| Downloaded-only global filter | `app_providers.dart:2781-2798`, `2746-2758` | C | — | Local cache set intersected with server lists |
| Rolling cache | `lib/src/features/cache/data/rolling_cache_manager.dart` | A | `stream` + local bytes | No library reads (checked: no `libraryDao` in the file) |
| Library cache reset | `lib/src/features/cache/presentation/library_cache_reset_provider.dart:46` | D | — | Sync/cache upgrade machinery |
| Cache settings screen | `lib/src/features/settings/presentation/cache_settings_screen.dart:69-169` | A | — | App settings + cache manager only |

---

## 9. Settings

| item | file:line evidence | bucket | Subsonic endpoint or why not | notes |
|---|---|---|---|---|
| Sync settings screen (interval, manual sync, repair, ledger) | `lib/src/features/settings/presentation/sync_settings_screen.dart:34-67`, `437-567`, `618-700` | D | — | Becomes an on/off switch in live mode |
| Sync interval / policy providers | `library_sync_provider.dart:38-56`, `app_providers.dart:582-620` | D | — | |
| Server settings (probe/reconnect/sign-out) | `lib/src/features/settings/presentation/server_settings_screen.dart:38-39`, `264`, `327-329` | A | `ping` via `serverConnectionServiceProvider` | No library reads |
| External integrations settings | `lib/src/features/settings/presentation/playback_settings_screen.dart`, `integrations_settings_screen.dart` | A | — | Stored in `app_settings` |
| Appearance / haptics / desktop / update settings | `lib/src/features/settings/**` (providers at `app_providers.dart:3026-3454`) | A | — | No library reads |
| Privacy screen | `lib/src/features/settings/presentation/privacy_screen.dart` | A | — | No DB references found |
| Unavailable review entry in settings | `sync_settings_screen.dart:933-942` → `unavailable_review_screen.dart` | D | — | Local-only reconciliation |

---

## 10. Match Flow

| item | file:line evidence | bucket | Subsonic endpoint or why not | notes |
|---|---|---|---|---|
| Flow list with songs | `lib/src/features/match_flow/presentation/match_flow_screen.dart:22-23` → `match_flow_dao.dart:46-60` | E | — | `leftOuterJoin(songs)`; missing rows render as no song |
| Song picker list | `match_flow_song_search_screen.dart:107-112` (`getSongsSorted`, `searchCachedSongs`) | B | `search3` / `getAlbumList2` | Without a query it lists 80 library songs |
| Add song to flow | `match_flow_song_search_screen.dart:118` → `match_flow_dao.addSong` | E | `getSong` | `match_flow_songs.songId` is plain text (no FK, `match_flow_songs_table.dart:9-18`) but every read joins `songs` |
| Playback indicator in flow | `match_flow_screen.dart:585` | A | — | Player state only |
| Flow CRUD | `match_flow_screen.dart:85-369` | A | — | Local feature, no server counterpart (by design) |

---

## 11. Integrations

| item | file:line evidence | bucket | Subsonic endpoint or why not | notes |
|---|---|---|---|---|
| Deezer / Last.fm / ListenBrainz clients | `lib/src/api/deezer_api_client.dart`, `lastfm_api_client.dart`, `listenbrainz_api_client.dart` | A | — | External HTTP, no library DB |
| Integration policy / switches | `lib/src/features/integrations/domain/integration_feature.dart:239-330`; `app_providers.dart:1065` | A | — | `app_settings` only |
| Integration notice card | `lib/src/features/integrations/presentation/integrations_notice_card.dart:19-68` | A | — | Reads `appSettingsDao` + onboarding state |
| Deezer id resolution for library artists | `lib/src/features/library/presentation/artist_deezer_providers.dart:20-53` (`artistNameIndex`, album buckets) | C | — | Needs the artist's album names to resolve |
| Deezer "fans also like" / missing albums | `artist_deezer_providers.dart:70-140` | C | — | Diff against the library |
| ListenBrainz weekly playlist matching | `home_providers.dart:1165`, `1327`, `2345-2400` (`getTrackMatchCandidates`, `getSongsByIds`) | C | — | Match by artist+title against the whole catalog |
| Artist top-track matching | `artist_top_track_resolver.dart:98-140`; store `artist_top_track_match_store` | C | `getTopSongs` per artist (not implemented) + `search3` | |
| ListenBrainz feedback queue | table FK `listenbrainz_feedback_queue_table.dart:10-11`; service `listenbrainz_feedback_service.dart` | E | — | Queue needs a `songs` row |
| Deezer artwork / release labels | `lib/src/features/integrations/presentation/deezer_release_labels.dart` | A | — | |

---

## 12. Onboarding / Auth / Auto / Misc

| item | file:line evidence | bucket | Subsonic endpoint or why not | notes |
|---|---|---|---|---|
| Login probe | `lib/src/features/auth/presentation/login_screen.dart:407-460`; `server_connection_service.dart:46-118` | A | `ping` (+ `getOpenSubsonicExtensions`) | Sets `apiVersion`, `useLegacyAuth`, capabilities |
| Login → Home | `login_screen.dart:455-463` (`context.go(AppRoutes.home)`) | A | — | Router may immediately redirect to `/initial-sync`, see F |
| Onboarding screen | `lib/src/features/onboarding/presentation/onboarding_screen.dart:168-223`, `398-400` | A | — | Settings + integrations only; no library reads |
| Onboarding required/version | `lib/src/features/onboarding/presentation/onboarding_provider.dart:18-38` | A | — | `app_settings` |
| Setup highlights | `lib/src/features/onboarding/presentation/setup_highlights_provider.dart:8-40` | A | — | Version-based |
| Sign-out / wipe | `lib/src/features/auth/data/sign_out_service.dart`; `app_providers.dart` wipe plumbing | A | — | |
| Android Auto browse tree | `lib/src/features/auto/data/auto_media_tree_service.dart:151-200` (artists/albums/liked), `232-250`, `307-320`, `356-370`, `424-440` | D | `getArtists`/`getAlbum` could rebuild it, but the tree is built from whole-library lists | `search3` search path already live (`505-560`) |
| Android Auto media session contexts | `lib/src/features/player/data/navis_audio_handler_android_auto.dart:5-204` | C/E | `getStarred2`, `getAlbum`, `getSongsByGenre` | Liked/downloads/recent/genre contexts all read `libraryDao` |
| Album/artist star from context menus | `lib/src/common_widgets/album_context_menu.dart:407-412`, `artist_context_menu.dart:208-220`; `library_screen.dart:2596-2612` | E | `star`/`unstar` | |
| Song context menu | `lib/src/common_widgets/song_context_menu.dart:48-60`, `374-380`, `455-475` | E | — | Typed on `SongsTableData`; star/rating/download state from DB |
| Queue cover-art prefetch | `lib/src/routing/app_shell.dart:405-425` (`getSongsByIds`) | E | `getCoverArt` | |
| Global search history writes | `app_shell.dart:1312`; `navigation_service.dart:450` | D | — | Local-only |
| Diagnostics server | `lib/src/utils/sync_diagnostics_server.dart:1778`, `4470` | D | — | Dev tooling; reads DB views and calls `search3` |
| Equalizer / changelog | `lib/src/features/equalizer/**`, `lib/src/features/changelog/**` | A | — | No library reads |

---

## E. Offline-critical dependencies on synced song/album/artist rows

These are the places where removing the library copy breaks downloads, cache, queue, history or scrobble *even with sync off*. Ordered by risk.

| # | Dependency | file:line evidence | Why it breaks without synced rows |
|---|---|---|---|
| 1 | Queue restore inner-joins `songs` | `lib/src/database/daos/play_queue_dao.dart:37-59`; FK `play_queue_items_table.dart:12-13` | A saved `play_queue_items.song_id` whose `songs` row is gone is dropped by the join (or the insert fails on the FK). Resume after restart loses tracks |
| 2 | Playlist songs inner-join `songs` | `lib/src/database/daos/playlist_dao.dart:154-169`; FK `playlist_songs_table.dart:12-13` | Playlist detail shows only rows present in `songs`, even though `getPlaylist` returned the full `entries` list |
| 3 | Play history insert FK | `lib/src/database/tables/play_history_table.dart:8-9`; write `navis_audio_handler_media_session.dart:1583` | "Recently played" silently stops recording for songs with no row |
| 4 | Scrobble/offline queue FK | `scrobble_queue_table.dart:10-11`; `scrobble_service.dart` | Offline scrobbles cannot be queued without the song row |
| 5 | ListenBrainz feedback queue FK | `listenbrainz_feedback_queue_table.dart:10-11`; `listenbrainz_feedback_service.dart` | Same |
| 6 | Downloads need metadata for path, tags, gaps | `download_service.dart:1410-1425`, `1501-1510`, `1660-1685`, `3380-3400`; `cache_dao.dart:181-215` | Permanent file naming/layout derives from `title/artist/album/albumId/coverArt`; `cached_tracks` stores no metadata at all |
| 7 | Download queue UI labels | `downloads_screen.dart:429-444`, `584`, `827`, `995` (`songByIdProvider`) | Queue rows store only ids |
| 8 | Queue enqueue read-back | `queue_provider.dart:314-340`, `460-606` | If `getSongsByIds` returns fewer rows than requested, `replaceWithTableData` is skipped; provisional upsert is the current mitigation |
| 9 | Star/rating writes | `star_sync_dao.dart:70-160`; callers `toggle_song_star.dart:11-25`, `set_rating.dart:4-12` | Intent is written to the row + queue; `toggleSongStarred` returns null when the song is unknown, so the action no-ops |
| 10 | Now-playing / OS media metadata | `now_playing_screen.dart:404`, `1603`, `1834`; `media_info.dart:130-142`; `navis_audio_handler_media_session.dart` | Title/artist/album for notifications, MPRIS/SMTC come from `songByIdProvider`/`albumProvider` |
| 11 | Same Vibes identity | `same_vibes_notifier.dart:1349-1375` | Canonical artist+title keys used to dedupe mixes are read from rows |
| 12 | Match-flow rows | `match_flow_dao.dart:46-60` | Flow entries render only when the joined song exists |
| 13 | Playlist covers | `playlist_providers.dart:258-262` → `playlist_dao.dart:110-150` | Cover ids come from `playlist_songs ⋈ songs.coverArt` |
| 14 | Android Auto resume fallback | `navis_audio_handler_persistence.dart:211-240` | Falls back to recently played / liked songs from `songs` |
| 15 | Downloads metadata gaps screen | `download_metadata_gaps.dart:30` | Inner join drops orphans by design |

**Conclusion for E:** a live mode can drop *library-wide* caching but cannot drop the `songs`/`albums`/`artists` tables as they are, because queue restore, playlists, history, scrobble and downloads all join them. The cheap path is a "rows on demand" table set: keep `songs` as a per-id metadata cache filled by `getSong`/`getAlbum` (mechanism already exists: `queue_provider.dart:563-606` and `getSongPayload`), and stop deleting/bulk-replacing it. `cached_tracks` should probably gain the few columns the download path needs (title/artist/album/albumId/coverArt) so a downloaded file survives a DB reset.

---

## F. Login / onboarding flow and the sync gate

**What happens today**

1. Login form probes the server: `server_connection_service.dart:46-118` → `ping` (`subsonic_api_client.dart:96`), and `getOpenSubsonicExtensions` (`105-127`) when supported.
2. On success it saves `ServerConfigModel` and navigates to Home: `login_screen.dart:437-463`.
3. The router immediately redirects to `/initial-sync` whenever `SessionRoutePhase.initialSyncRequired` (`app_router.dart:190-198`, `215-224`), which is `AppRoutes.initialSync` (`app_routes.dart:56`) → `RequiredLibraryRebuildScreen(reason: initialLogin)` (`app_router.dart:234-239`).
4. That phase is derived from `initialSyncRequiredProvider` (`session_route_provider.dart:121-133`): if `config.lastSynced == null` and the profile has a persisted id, it calls `isInitialCatalogSetupPending` (`session_route_provider.dart:32-44`) and returns `initialSyncRequired` until a usable catalog is recorded. Errors also fall back to `initialSyncRequired` (`148-155`).
5. `RequiredLibraryRebuildScreen` starts `requiredLibraryRebuildControllerProvider` (`required_library_rebuild_screen.dart:59-95`) which runs `syncNow`/`forceFullSync` (`required_library_rebuild_provider.dart:196-250`), then records readiness (`recordInitialCatalogReadiness`, `session_route_provider.dart:75-118`) and invalidates `initialSyncRequiredProvider` (`required_library_rebuild_provider.dart:247`).
6. Only then does the router allow `/onboarding` (`app_router.dart:204-212`) and Home. `lastSynced` is written by the sync engine (`library_sync_engine.dart:1718`).
7. The full-screen route also gates on blocking album work: `isCompletedInitialSyncRun` / `isUsableIncompleteAlbumSyncRun` (`session_route_provider.dart:47-72`).

**What blocks live mode**

- `initialSyncRequiredProvider` (`session_route_provider.dart:121-133`) treats "no sync ever" as "needs setup forever". A live-mode profile must be recorded as ready without a catalog — there is no such state today (`server_config_table.lastSynced` is the only marker; `navis_database.dart:1744-1775` mirrors it into the sync state table).
- `homeWarmupEligible` (`app_router.dart:190-196`) plus the warm-up prefetch (`home_onboarding_warmup.dart:279-360`) exist only to make the first Home paint fast after a sync; they are unnecessary but harmless in live mode (they already call the API, `471-505`).

**Minimum calls to reach a usable Home in live mode (no sync)**

1. `ping` (auth + version) — `subsonic_api_client.dart:96`; optional `getOpenSubsonicExtensions` for capability gating (`105`).
2. Home rows: `getAlbumList2?type=newest&size=20` (`home_providers.dart:1928`), `getAlbumList2?type=random` (`1973`), `getAlbumList2?type=frequent` (`2886`), `getStarred2` (`home_providers.dart:1914` → needs `getStarred2`), `getPlaylists` (playlist tab/home virtual gating), and `getAlbumList2?type=recent` for the recently-played row.
3. Nothing else is required to paint Home; genres, artists and search are lazy.

So the Home-minimum set is **ping + 3×`getAlbumList2` + `getStarred2` (+`getPlaylists` for the playlists shelf)**, all already implemented.

---

## Subsonic API client (`lib/src/api/subsonic_api_client.dart`)

Client class at `:22`, transport/interceptors at `:26-75` (`SubsonicAuthInterceptor`, `SubsonicLoggingInterceptor`, `SubsonicRetryInterceptor`), root reader `_readRoot` at `:795`, Dio error mapping at `:956-990`.

**Implemented endpoints**

| Endpoint | method | line |
|---|---|---|
| `ping` | `ping()` | 96 |
| `getOpenSubsonicExtensions` | `getOpenSubsonicExtensions()` | 105 |
| `getArtists` | `getArtists()` | 132 |
| `getArtist` | `getArtist(id)` (normalizes `album`→`albums`) | 152 |
| `getAlbum` | `getAlbum(id)` (normalizes `song`→`songs`) | 173 |
| `getSong` | `getSong(id)` / `getSongPayload(id)` | 194 / 200 |
| `getArtistInfo2` | `getArtistInfo2()` | 212 |
| `getAlbumInfo2` | `getAlbumInfo2(id)` | 234 |
| `getAlbumList2` | `getAlbumList2(type, size, offset)` | 243 |
| `getIndexes` | `getIndexes(ifModifiedSince)` | 259 |
| `getRandomSongs` | `getRandomSongs(size)` | 284 |
| `getStarred2` | `getStarred2()` | 297 |
| `getScanStatus` | `getScanStatus()` | 320 |
| `getInstantMix` | `getInstantMix()` | 330 |
| `getSimilarSongs2` | `getSimilarSongs2()` | 353 |
| `getSimilarSongs` (legacy) | `getLegacySimilarSongs()` | 370 / 383 |
| `search3` | `search3(query, counts, offsets)` | 422 |
| `getPlaylists` | `getPlaylists()` | 449 |
| `getPlaylist` | `getPlaylist(id)` | 459 |
| `createPlaylist` | `createPlaylist()` | 478 |
| `createPlaylist` (replace entries) | `replacePlaylistSongs()` | 541 |
| `updatePlaylist` | `updatePlaylist()` | 501 |
| `deletePlaylist` | `deletePlaylist(id)` | 556 |
| `stream` (URL builder) | `streamUrl` | 587 |
| `download` (URL builder) | `downloadUrl` | 592 |
| `getCoverArt` (URL builder) | `coverArtUrl` | 599 |
| `getLyricsBySongId` | `getLyricsBySongId()` | 619 |
| `getLyrics` (legacy) | `getLyrics()` | 631 |
| `star` | `star()` | 660 |
| `unstar` | `unstar()` | 672 |
| `setRating` | `setRating()` | 686 |
| `scrobble` | `scrobble()` | 698 |
| `getUser` | `getUserIsAdmin()` | 715 |
| `createInternetRadioStation` | | 723 |
| `updateInternetRadioStation` | | 739 |
| `deleteInternetRadioStation` | | 756 |
| `getInternetRadioStations` | | 760 |

**Callers worth noting** (which endpoints are currently used by *sync only*, i.e. free to reuse for live mode):
`getArtists`→`library_sync_engine.dart:232`, `getArtist`→`:238`, `getAlbum`→`:248`, `getAlbumList2`→`:294`, `getIndexes`→`:323`, `getStarred2`→`:267`, `getScanStatus`→`:203`, `search3`→`:277` (all in `lib/src/features/library/data/library_sync_engine.dart`).

**Not implemented (needed for bucket B items)**

- `getGenres` — genre list with counts.
- `getSongsByGenre` — paged songs per genre.
- `getTopSongs` — artist top songs (also the only server-side "popularity" list).
- `getAlbumList` (v1), `getMusicDirectory`, `getMusicFolders`, `getNowPlaying`, `getPlayQueue`/`savePlayQueue`, `search2`, `getArtistInfo` (v1).
- No `getAlbumList2?type=highest|starred|alphabeticalByArtist` wrapper is exposed as named helpers; only `type` is passed through, so `alphabeticalByName`, `alphabeticalByArtist`, `byYear`, `byGenre`, `highest`, `starred`, `recent`, `frequent`, `newest`, `random` are all reachable with the existing method.

---

## Open questions / uncertainties

1. **Server "recent" semantics.** I mapped Home "recently played albums" (§1) to `getAlbumList2?type=recent` on the Subsonic spec; I did not verify Navidrome's exact behaviour (whether it is per-user play time vs. anything else). *Guessing on the exact semantics, not on the endpoint existing.*
2. **`getAlbumList2` page-size ceiling.** I assumed servers cap `size` (commonly 500) so "scroll the whole library" becomes bucket C. Not verified against this repo or a live server.
3. **Genre album grid.** Bucket C assumes no albums-by-genre endpoint exists in Subsonic/OpenSubsonic. `byGenre` exists as a `getAlbumList2` type per the spec — if the target servers support `getAlbumList2?type=byGenre&genre=...`, that row moves to B. I could not confirm support from the repo.
4. **`getGenres` merging semantics.** The local genre layer merges spellings by `genreKey` and counts albums per genre with its own rule (`library_dao.dart:702-800`). Whether merged counts will match server `getGenres` counts exactly is unknown; treat the numbers as "server-truth" in live mode.
5. **Playlist "hidden rows" note.** A code comment says Navidrome 0.64 counts rows that `getPlaylist` omits (`playlist_actions.dart:389`, `423`). Whether live playlist counts stay consistent is unverified.
6. **Detail hydration rewrite size.** Album/artist detail currently hydrate-then-read (`album_detail_screen.dart:140-166`, `artist_detail_screen.dart:148-186`). I classified the read as B (one call), but the "partial album"/completeness states (`DetailHydrationPhase`, `countSongsByAlbum`) are D logic that has no server answer; they may need to be dropped or redefined.
7. **`songs` rows as a per-id cache.** E's conclusion (keep `songs` as an on-demand metadata cache) is my recommendation, not an existing design. `isProvisional`/`catalogGeneration`/`serverDeletedAt` columns (`songs_table.dart:74-92`) assume sync lifecycle semantics that live mode would have to reinterpret.
8. **Wikimedia/Last.fm artwork and Deezer `ext-` ids.** Remote catalog rows (`isExternal`, `ext-deezer-*`) flow through the same tables; live mode must keep the `ext-` id rules (`catalog_source.dart`, `song_id_utils.dart`) or remote items disappear. Not audited exhaustively.
9. **Android Auto.** `auto_media_tree_service` builds root children from whole-library lists (`151-200`). I guessed a per-request API rebuild is feasible with `getArtists`/`getArtist`/`getAlbum`; page-size limits on head-unit nested lists are not evaluated.
10. **Counts and totals.** I found no endpoint for "number of albums/artists in library" (`albumCountProvider`, `app_providers.dart:2018`), so any UI that shows a total needs a different presentation (e.g. count only what is loaded). Not verified whether any server extension exposes this (OpenSubsonic does not, to my knowledge).
11. **`getRandomSongs` is implemented but has no feature caller** (only the definition at `subsonic_api_client.dart:284`). It is available for the Home random/most-played replacements but currently unused.
12. **Line numbers** are from the working tree as inspected; they will drift if the branch moves.
