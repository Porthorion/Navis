# Navis Development Progress

Tracks completion of all phases and sub-tasks defined in [DEVELOPMENT_PLAN.md](DEVELOPMENT_PLAN.md). Checkboxes are updated as work is completed.

Last updated: 2026-02-19

---

## Tracking Conventions
- Completed item format: `- [x] Task name — YYYY-MM-DD (evidence: command/file)`
- Partially complete format: `- [ ] Task name — partial: YYYY-MM-DD (remaining: short note)`
- If blocked, add/update the `Blockers` section with exact error and next action.

## Current Focus
- [x] Phase 0 end-to-end bootstrap — 2026-02-19 (evidence: `./tool/check.sh`, `flutter run -d linux`)
- [x] Phase 1 close-out verification — 2026-02-19 (evidence: `LD_LIBRARY_PATH="/tmp/navis-sqlite:${LD_LIBRARY_PATH:-}" NAVIS_SMOKE_BASE_URL=... NAVIS_SMOKE_USERNAME=... NAVIS_SMOKE_PASSWORD=... NAVIS_SMOKE_USE_LEGACY_AUTH=true NAVIS_SMOKE_API_VERSION=1.16.1 ./tool/phase1_closeout.sh`)
- [x] Phase 1 close-out automation gate added — 2026-02-19 (evidence: `tool/phase1_closeout.sh`, `tool/phase1_ping_smoke.dart`, `Makefile` target `phase1-closeout`)

## Meta Progress
- [x] Tech stack and methodology validation refresh — 2026-02-18 (evidence: `DEVELOPMENT_PLAN.md` stack validation section + README tech stack update)

## Blockers
- Android mobile runtime validation still blocked — 2026-02-19 (error: `flutter doctor -v` reports missing Android SDK; workaround used for Phase 0 runtime verification: `flutter run -d linux`)

---

## Phase 0: Project Bootstrap & Tooling
- [x] Flutter project creation (`flutter create`) — 2026-02-18 (evidence: `flutter create --org com.navis.app --platforms android,ios --project-name navis .`)
- [x] `analysis_options.yaml` with `very_good_analysis` + `riverpod_lint` — 2026-02-18 (evidence: `analysis_options.yaml`)
- [x] `pubspec.yaml` with all dependencies — 2026-02-19 (evidence: `pubspec.yaml`; command: `flutter pub get`)
- [x] Directory structure under `lib/src/` — 2026-02-18 (evidence: `lib/src/**` skeleton + `.gitkeep`)
- [x] Android manifest (permissions, network security config, SDK versions, predictive back) — 2026-02-19 (evidence: `android/app/src/main/AndroidManifest.xml`, `android/app/src/main/res/xml/network_security_config.xml`, `android/app/build.gradle.kts` with desugaring)
- [x] Programmatic notification channel creation on startup (`playback` + `downloads`) — 2026-02-19 (evidence: `lib/src/utils/notifications/notification_bootstrap.dart`)
- [x] Edge-to-edge configuration for Android 15+ — 2026-02-19 (evidence: `lib/main.dart` `SystemUiMode.edgeToEdge`)
- [x] `POST_NOTIFICATIONS` runtime permission flow — 2026-02-19 (evidence: `NotificationBootstrap.initialize()` + Android permission request)
- [x] iOS `Info.plist` (background audio, ATS, min OS 16.0) — 2026-02-19 (evidence: `ios/Runner/Info.plist`, `ios/Runner.xcodeproj/project.pbxproj`)
- [x] Logger singleton (`app_logger.dart`) — 2026-02-19 (evidence: `lib/src/utils/app_logger.dart`)
- [x] `tool/bootstrap.sh` script (toolchain checks + `flutter pub get`) — 2026-02-18 (evidence: `tool/bootstrap.sh`; command: `./tool/bootstrap.sh`)
- [x] `tool/check.sh` script (format, build_runner, analyze, custom_lint, tests) — 2026-02-18 (evidence: `tool/check.sh`; command: `./tool/check.sh`)
- [x] `build_runner` setup + Makefile/justfile — 2026-02-18 (evidence: `Makefile`; `dart run build_runner build --delete-conflicting-outputs` via `./tool/check.sh`)
- [x] Optional pre-commit hook for local guardrails — 2026-02-19 (evidence: `.githooks/pre-commit`, `README.md` setup instructions)
- [x] ~~Forgejo CI quality gates~~ — removed 2026-02-19 (reason: no Forgejo runner available; replaced by local `./tool/check.sh` + pre-commit hook)
- [x] ~~CI matrix~~ — removed 2026-02-19 (reason: no Forgejo runner; local quality gate via `./tool/check.sh`)
- [x] ~~Weekly dependency maintenance workflow~~ — removed 2026-02-19 (reason: no Forgejo runner; run `flutter pub outdated` / `dart pub outdated` locally or via `make outdated`)
- [x] ~~CI/release coverage collection~~ — removed 2026-02-19 (reason: no Forgejo runner; run `flutter test --coverage` locally via `make test-coverage`)
- [x] ~~Forgejo release publishing automation (Actions)~~ — removed 2026-02-19 (reason: no Forgejo runner; replaced by `./tool/release.sh`)
- [x] ~~Forgejo release workflow YAML parse failure~~ — removed 2026-02-19 (reason: workflow files deleted)
- [x] Local release script (`tool/release.sh`) — 2026-02-19 (evidence: `tool/release.sh`; replaces Forgejo Actions release workflow; builds APK, tags, creates Forgejo release via API, uploads APK asset)
- [x] Makefile updated with `release` and `outdated` targets — 2026-02-19 (evidence: `Makefile`)
- [x] `tool/release.env` added to `.gitignore` — 2026-02-19 (evidence: `.gitignore`)
- [x] Documentation updated for local-only tooling — 2026-02-19 (evidence: `README.md`, `DEVELOPMENT_PLAN.md`, `docs/ci-cd.md`, `docs/development-workflow.md`)
- [x] Scaffold `main.dart` + `app.dart` with `ProviderScope` — 2026-02-18 (evidence: `lib/main.dart`, `lib/src/app.dart`, `lib/src/routing/app_router.dart`)
- [x] `flutter run` launches, `build_runner build` succeeds, `./tool/check.sh` clean — 2026-02-19 (evidence: `flutter run -d linux`, `dart run build_runner build --delete-conflicting-outputs`, `./tool/check.sh`)
- [x] Operational documentation in `docs/` — 2026-02-19 (evidence: `docs/development-workflow.md`, `docs/ci-cd.md`, `docs/troubleshooting.md`)

## Phase 1: Core Infrastructure
### 1.1 — Subsonic API Client
- [x] Dio wrapper with all endpoint methods — 2026-02-19 (evidence: `lib/src/api/subsonic_api_client.dart`, `test/src/api/subsonic_api_client_test.dart`)
- [x] `SubsonicAuthInterceptor` (token auth, `f=json`) — 2026-02-19 (evidence: `lib/src/api/subsonic_auth_interceptor.dart`, `test/src/api/subsonic_auth_interceptor_test.dart`)
- [x] Freezed API response models — 2026-02-19 (evidence: `lib/src/api/models/*.dart`, generated `*.freezed.dart`/`*.g.dart`, `test/src/api/models_serialization_test.dart`)
- [x] OpenSubsonic extension detection (`getOpenSubsonicExtensions`) — 2026-02-19 (evidence: `lib/src/api/subsonic_api_client.dart`, `test/src/api/subsonic_api_client_test.dart`)
- [x] Typed error handling (`SubsonicAuthException`, etc.) — 2026-02-19 (evidence: `lib/src/api/subsonic_error.dart`, `test/src/api/subsonic_error_test.dart`)
- [x] Dio retry interceptor (exponential backoff, skip 4xx) — 2026-02-19 (evidence: `lib/src/api/subsonic_retry_interceptor.dart`, `test/src/api/subsonic_retry_interceptor_test.dart`)
- [x] Dio logging interceptor — 2026-02-19 (evidence: `lib/src/api/subsonic_logging_interceptor.dart`)
- [x] Auth query-param redaction in API logs (`u`, `t`, `s`, `p`) — 2026-02-19 (evidence: `lib/src/api/subsonic_logging_interceptor.dart`, `test/src/api/subsonic_logging_interceptor_test.dart`)
- [x] Cancel token support — 2026-02-19 (evidence: `lib/src/api/subsonic_api_client.dart`, `test/src/api/subsonic_api_client_test.dart`)

### 1.2 — Drift Database
- [x] All table schemas (servers, artists, albums, songs, playlists, playlist_songs, genres, cached_tracks, download_queue, play_history, recent_searches, play_queue, play_queue_items) — 2026-02-19 (evidence: `lib/src/database/tables/*.dart`, `lib/src/database/navis_database.dart`)
- [x] All DAOs (ServerDao, LibraryDao, PlaylistDao, CacheDao, DownloadQueueDao, HistoryDao, PlayQueueDao) — 2026-02-19 (evidence: `lib/src/database/daos/*.dart`)
- [x] Reactive queries (`Stream<List<T>>`) — 2026-02-19 (evidence: DAO watch methods in `lib/src/database/daos/*.dart`)
- [x] SQLite foreign keys enabled and verified (`PRAGMA foreign_keys = ON`) — 2026-02-19 (evidence: `LD_LIBRARY_PATH="/tmp/navis-sqlite:${LD_LIBRARY_PATH:-}" flutter test test/src/database/navis_database_test.dart -r expanded` with `enforces foreign keys` passing)
- [x] Query hotspot indexes added and validated (artists/albums/songs/queue) — 2026-02-19 (evidence: `_createIndexes()` in `lib/src/database/navis_database.dart`)
- [x] Explicit transactions for multi-table writes (sync, playlist edits, cache promotion) — 2026-02-19 (evidence: transactional DAO methods in `lib/src/database/daos/*.dart`)
- [x] Schema versioning + migration strategy — 2026-02-19 (evidence: `schemaVersion`, `from1To2`, `_runMigrations` in `lib/src/database/navis_database.dart`; `drift_schemas/drift_schema_v1.json`)
- [x] `drift_flutter` initialization with `driftDatabase()` — 2026-02-19 (evidence: `_openConnection()` in `lib/src/database/navis_database.dart`)
- [x] Migration unit tests — 2026-02-19 (evidence: `LD_LIBRARY_PATH="/tmp/navis-sqlite:${LD_LIBRARY_PATH:-}" flutter test test/src/database/migrations/navis_migration_test.dart -r expanded`)

### 1.3 — Riverpod Provider Architecture
- [x] `serverConfigProvider` — 2026-02-19 (evidence: `lib/src/features/auth/presentation/server_config_provider.dart`)
- [x] `subsonicApiProvider` — 2026-02-19 (evidence: `lib/src/providers/app_providers.dart`)
- [x] `navisDatabaseProvider` — 2026-02-19 (evidence: `lib/src/providers/app_providers.dart`)
- [x] `connectivityProvider` — 2026-02-19 (evidence: `lib/src/providers/app_providers.dart`)
- [x] `networkTypeProvider` — 2026-02-19 (evidence: `lib/src/providers/app_providers.dart`, `lib/src/utils/connectivity.dart`)
- [x] `activeStreamingQualityProvider` — 2026-02-19 (evidence: `lib/src/providers/app_providers.dart`)
- [x] Feature-specific providers scaffolded — 2026-02-19 (evidence: `lib/src/features/library/presentation/library_providers.dart`, `lib/src/features/search/presentation/search_providers.dart`, `lib/src/features/player/presentation/player_providers.dart`, `lib/src/features/downloads/presentation/download_providers.dart`)

### 1.4 — Routing
- [x] `go_router` setup with `ShellRoute` — 2026-02-19 (evidence: `lib/src/routing/app_router.dart`, `lib/src/routing/app_shell.dart`)
- [x] All route definitions — 2026-02-19 (evidence: route table in `lib/src/routing/app_router.dart`, coverage in `test/src/routing/app_router_test.dart`)
- [x] Auth route guard (redirect to `/login` if not logged in) — 2026-02-19 (evidence: redirect logic in `lib/src/routing/app_router.dart`, `test/src/routing/app_router_test.dart`)

## Phase 2: Authentication & Server Setup
- [x] Login screen (URL, username, password, test connection) — 2026-02-19 (evidence: `lib/src/features/auth/presentation/login_screen.dart`, `test/src/features/auth/presentation/login_screen_test.dart`)
- [x] Server config storage in drift — 2026-02-19 (evidence: `lib/src/features/auth/data/server_config_repository.dart`, `test/src/features/auth/data/server_config_repository_test.dart`)
- [x] Password encryption via `flutter_secure_storage` — 2026-02-19 (evidence: `lib/src/features/auth/data/secure_credential_store.dart`, `pubspec.yaml`)
- [ ] Auto-reconnect on launch with offline banner
- [ ] Reachability-based online/offline status (server ping, not just interface connectivity)
- [ ] Sign out clears all credentials
- [x] ARB string extraction begins — 2026-02-19 (evidence: `lib/l10n/app_en.arb`, `lib/l10n/app_localizations.dart`, `lib/l10n/app_localizations_en.dart`, `lib/src/app.dart`)

## Phase 3: Library Browsing & Metadata Sync
### 3.1 — Sync Engine
- [ ] Full initial sync (artists → albums → songs → genres → playlists)
- [ ] Incremental sync with `ifModifiedSince`
- [ ] Background isolate execution
- [ ] Force re-sync from settings
- [ ] Sync progress indicator

### 3.2 — Library UI
- [ ] Home screen carousels (recently played, recently added, most played, random, starred)
- [ ] Artists tab (alphabetical, fast scroll index)
- [ ] Artist detail screen (albums grid, bio, similar artists)
- [ ] Albums tab (grid, sort options)
- [ ] Album detail screen (cover art, track list, star, download, context menu)
- [ ] Songs tab (flat list, sort options)
- [ ] Genres tab (genre list → filtered content)
- [ ] NavigationBar (Home, Library, Search, Settings)
- [ ] 60fps scroll with 10K+ items

### 3.3 — Common Widgets
- [ ] `ShimmerPlaceholder` skeleton loading widget
- [ ] `ErrorState` widget (with retry)
- [ ] `EmptyState` widget (with contextual message)
- [ ] `CoverArtImage`, `TrackListTile`, `AlbumCard`, `ArtistCard`, `StarButton`, `CacheBadge`

### 3.4 — Context Menus & Actions
- [ ] Context menu bottom sheets (song, album, artist)

### 3.5 — Localization Setup
- [ ] `l10n.yaml` configuration
- [ ] `lib/l10n/app_en.arb` with all Phase 3 strings
- [ ] `AppLocalizations` integration in all Phase 3 screens

## Phase 4: Audio Playback Engine
### 4.1 — NavisAudioHandler
- [ ] `BaseAudioHandler` extension with `just_audio`
- [ ] `ConcatenatingAudioSource` queue management
- [ ] Source resolution (permanent cache → rolling cache → `LockCachingAudioSource`)
- [ ] `LockCachingAudioSource` → `RollingCacheManager.registerTrack()` integration
- [ ] Network-aware quality selection (Wi-Fi vs cellular)
- [ ] Queue operations (play, skip, reorder, clear, replace, playNext, addToQueue)
- [ ] Shuffle + repeat modes
- [ ] Scrobbling (now playing + submission at threshold)
- [ ] Lock screen and notification controls
- [ ] Audio focus / interruption handling (`audio_session`)

### 4.2 — Play Queue Persistence
- [ ] Save queue on every track change
- [ ] Periodic position persistence (every 10–15s)
- [ ] Restore queue on app launch
- [ ] Cross-device sync via `savePlayQueue` / `getPlayQueue` (optional)

### 4.3 — Streaming Quality
- [ ] Wi-Fi quality profile
- [ ] Cellular quality profile
- [ ] Live network type switching
- [ ] No-transcode default (original quality)

### 4.4 — Audio Quality Details
- [ ] Verify native codec support (FLAC, ALAC, MP3, AAC, Opus, Vorbis)
- [ ] Android equalizer (`AndroidEqualizer`) — gated behind platform check
- [ ] Android loudness enhancer (`AndroidLoudnessEnhancer`)
- [ ] ReplayGain volume normalization (from server metadata)

## Phase 5: Now Playing & Lyrics
### 5.1 — Mini Player
- [ ] Persistent bar above NavigationBar
- [ ] Cover art, title, artist, play/pause, progress
- [ ] Tap to expand, swipe to skip

### 5.2 — Now Playing Screen
- [ ] Full-screen cover art with tinted background
- [ ] Seek bar with elapsed/remaining
- [ ] All playback controls
- [ ] Star, lyrics, queue, overflow menu buttons
- [ ] Hero animation from mini player / album detail

### 5.3 — Lyrics
- [ ] `getLyricsBySongId` (OpenSubsonic, preferred)
- [ ] `getLyrics` fallback (legacy)
- [ ] Synced lyrics with auto-scroll and tap-to-seek
- [ ] Unsynced lyrics display
- [ ] Cover art ↔ lyrics toggle

### 5.4 — Queue Screen
- [ ] Drag-to-reorder, swipe-to-remove
- [ ] Clear queue, save as playlist

### 5.5 — Sleep Timer
- [ ] Preset durations + custom + end of track
- [ ] Countdown display on Now Playing
- [ ] Volume fade-out in final 30 seconds

## Phase 6: Search
- [ ] Search screen with debounced input (300ms)
- [ ] `search3` API — live results, no caching
- [ ] Results grouped by artists, albums, songs
- [ ] "Show all" expansion per section + pagination
- [ ] Recent searches persistence
- [ ] Tap → navigate, song tap → play immediately

## Phase 7: Playlists
- [ ] Playlist list screen
- [ ] Playlist detail screen (play, shuffle, download)
- [ ] Drag-to-reorder, swipe-to-remove
- [ ] Create / edit / delete playlists (full CRUD → server)
- [ ] "Add to playlist" from any song context menu
- [ ] On-demand playlist song fetch + local sync

## Phase 8: Offline & Cache Management
### 8.1 — Rolling Cache
- [ ] `RollingCacheManager` with configurable max size
- [ ] LRU eviction by `lastAccessedAt`
- [ ] File tracking in `cached_tracks` (`cacheType = rolling`)
- [ ] Integration with `LockCachingAudioSource` file paths

### 8.2 — Permanent Cache
- [ ] Quality choice dialog on pin (Original / 320 / 192 / 128 / default)
- [ ] Download via `background_downloader`
- [ ] File tracking in `cached_tracks` (`cacheType = permanent`)
- [ ] Pin at album, playlist, or track level
- [ ] Auto-detect new tracks in pinned albums during sync

### 8.3 — Download Queue
- [ ] `DownloadQueueManager` with `download_queue` table
- [ ] Sequential / configurable concurrent processing
- [ ] Pause / cancel / retry per item
- [ ] Wi-Fi-only download mode
- [ ] Resume interrupted downloads on restart
- [ ] Download notifications via `flutter_local_notifications`

### 8.4 — Offline Mode
- [ ] "Downloaded Only" toggle in library
- [ ] Rolling cache items shown with temporary badge
- [ ] "Promote to permanent" (no re-download if same quality)
- [ ] "Download in original quality" (re-download from server)
- [ ] Offline banner when server unreachable

### 8.5 — Cover Art Cache
- [ ] `cached_network_image` with configurable max size
- [ ] Thumbnail vs full-size strategy

### 8.6 — Smart Cache Behaviors
- [ ] Stream higher quality on Wi-Fi even if lower-quality pin exists
- [ ] Auto-queue new tracks in pinned albums

## Phase 9: Settings
- [ ] Server section (display, test, sign out)
- [ ] Playback — streaming quality (Wi-Fi / cellular profiles)
- [ ] Playback — general (gapless, ReplayGain, skip silence, scrobble, resume, queue sync)
- [ ] Audio section (equalizer, loudness enhancer — Android only)
- [ ] Downloads & cache (default quality, Wi-Fi only, concurrency, rolling/permanent/cover art stats, clear buttons)
- [ ] Appearance — theme mode (Light / Dark / OLED / System)
- [ ] Appearance — color scheme (Dynamic / Preset / Custom seed)
- [ ] Appearance — art-tinted Now Playing toggle
- [ ] AudioMuse AI section (placeholder, hidden until Phase 11)
- [ ] About (version, licenses, repo links)
- [ ] All settings persist across restarts

## Phase 10: Polish & Platform Integration
### 10.1 — Animations
- [ ] Hero transitions for cover art (grid → detail → now playing)
- [ ] Material motion (`SharedAxisTransition`, `FadeThroughTransition`)
- [ ] Mini player ↔ now playing smooth transition

### 10.2 — Performance
- [ ] DevTools profiling
- [ ] 60fps scroll with 10K+ library
- [ ] Provider auto-dispose verification

### 10.3 — Error Handling UX Audit
- [ ] Consistent snackbar / dialog / banner patterns
- [ ] Skeleton shimmer used everywhere (audit all screens)

### 10.4 — Accessibility
- [ ] Semantic labels on all interactive elements
- [ ] Contrast ratio verification (WCAG 2.1 AA)
- [ ] Screen reader testing
- [ ] 48x48dp touch targets

### 10.5 — Localization Audit
- [ ] All screens reviewed for hardcoded strings
- [ ] Plural forms verified
- [ ] No string concatenation — ICU message parameters only

### 10.6 — Android Platform Integration
- [ ] Edge-to-edge display verified on Android 15 and Android 16
- [ ] Predictive back gesture with `PopScope`
- [ ] `POST_NOTIFICATIONS` runtime permission

### 10.7 — Crash Recovery
- [ ] Download queue resume on restart
- [ ] Sync engine idempotency
- [ ] Play queue restoration after force-kill

### 10.8 — Haptic Feedback
- [ ] Star/unstar, skip, long-press context menu

### 10.9 — Logging & Diagnostics
- [ ] Logger integrated in API layer (request URLs + status codes, auth params redacted)
- [ ] Logger integrated in sync engine (counts, duration, errors)
- [ ] Logger integrated in audio handler (track transitions, source resolution)
- [ ] Logger integrated in cache manager (eviction events)
- [ ] Logger integrated in download queue (progress milestones, failures)
- [ ] Release builds set log level to `Level.warning`

### 10.10 — In-App Update Checker
- [ ] `UpdateRepository` (Forgejo Releases API)
- [ ] `updateProvider`
- [ ] Settings: update channel (Stable / Beta), check toggle, manual check
- [ ] Home screen update banner
- [ ] APK download or browser redirect
- [ ] Forgejo URL as compile-time constants in `constants.dart`

## Phase 11: AudioMuse AI Integration
- [ ] `AudioMuseService` interface + API client
- [ ] `audioMuseAvailableProvider` (feature flag)
- [ ] Settings: server URL, API key, test connection
- [ ] Server auto-detection via Navidrome plugin
- [ ] Smart auto-queue (appends AI-recommended tracks)
- [ ] "Similar Artists" on artist detail
- [ ] "Similar Albums" on album detail
- [ ] "You might also like" on home screen
- [ ] AI mix generation (seed → playlist)
- [ ] Graceful degradation (hidden when unconfigured, fallback to Subsonic data)

---

*Tags are noted inline as phases complete. See [DEVELOPMENT_PLAN.md](DEVELOPMENT_PLAN.md) for versioning and tagging conventions.*
