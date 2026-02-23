# Navis Development Progress

Tracks completion of all phases and sub-tasks defined in [DEVELOPMENT_PLAN.md](DEVELOPMENT_PLAN.md). Checkboxes are updated as work is completed.

Last updated: 2026-02-23

---

## Tracking Conventions
- Completed item format: `- [x] Task name — YYYY-MM-DD (evidence: command/file)`
- Partially complete format: `- [ ] Task name — partial: YYYY-MM-DD (remaining: short note)`
- If blocked, add/update the `Blockers` section with exact error and next action.

## Current Focus
- [x] Phase 0 end-to-end bootstrap — 2026-02-19 (evidence: `./tool/check.sh`, `flutter run -d linux`)
- [x] Phase 1 close-out verification — 2026-02-19 (evidence: `LD_LIBRARY_PATH="/tmp/navis-sqlite:${LD_LIBRARY_PATH:-}" NAVIS_SMOKE_BASE_URL=... NAVIS_SMOKE_USERNAME=... NAVIS_SMOKE_PASSWORD=... NAVIS_SMOKE_USE_LEGACY_AUTH=true NAVIS_SMOKE_API_VERSION=1.16.1 ./tool/phase1_closeout.sh`)
- [x] Phase 1 close-out automation gate added — 2026-02-19 (evidence: `tool/phase1_closeout.sh`, `tool/phase1_ping_smoke.dart`, `Makefile` target `phase1-closeout`)
- [x] Phase 2 close-out verification — 2026-02-19 (evidence: `./tool/check.sh`, `test/src/features/auth/presentation/server_reachability_provider_test.dart`, `test/src/features/settings/presentation/server_settings_screen_test.dart`, `test/src/features/auth/data/sign_out_service_test.dart`, `test/src/routing/app_router_test.dart`)
- [x] Phase 3 stabilization increment (albums paging + cover art + resumable song hydration) — 2026-02-20 (evidence: `./tool/check.sh`, `lib/src/features/library/presentation/library_screen.dart`, `lib/src/common_widgets/cover_art_image.dart`, `lib/src/features/library/data/library_sync_engine.dart`)
- [x] Phase 3 sync throughput optimization (chunked hydration writes + adaptive concurrency + rebaseline delta hydration) — 2026-02-20 (evidence: `./tool/check.sh`, `lib/src/features/library/data/library_sync_engine.dart`, `lib/src/database/daos/library_dao.dart`, `test/src/features/library/data/library_sync_engine_test.dart`, `test/src/database/library_dao_test.dart`)
- [x] Phase 3 sync throughput + runtime stabilization (bulk-auto hydration fallback, priority hydration queue, Android SDK 36 alignment, home overflow hardening, retry/log cleanup) — 2026-02-20 (evidence: `./tool/check.sh`, `lib/src/features/library/data/library_sync_engine.dart`, `lib/src/features/library/presentation/library_sync_provider.dart`, `lib/src/features/home/presentation/home_screen.dart`, `lib/src/api/subsonic_logging_interceptor.dart`, `android/app/build.gradle.kts`, `test/src/features/library/data/library_sync_engine_test.dart`)
- [x] Phase 4 playback core increment 1 (audio handler bootstrap, playback-backed queue operations, local-file-first source resolver, mini-player strip, queue restore paused on launch) — 2026-02-20 (evidence: `./tool/check.sh`, `lib/src/features/player/data/navis_audio_handler.dart`, `lib/src/features/player/data/playback_source_resolver.dart`, `lib/src/providers/app_providers.dart`, `lib/main.dart`, `lib/src/routing/app_shell.dart`, `test/src/features/player/data/playback_source_resolver_test.dart`)
- [x] Phase 4 increment 2 (Android runtime hardening, `LockCachingAudioSource` rolling cache path, queue `playNext`/`reorderQueue`) — 2026-02-20 (evidence: `./tool/check.sh`, `lib/src/features/cache/data/rolling_cache_manager.dart`, `lib/src/features/player/data/playback_source_resolver.dart`, `lib/src/features/player/data/navis_audio_handler.dart`, `lib/src/providers/app_providers.dart`, `docs/troubleshooting.md`, `test/src/features/cache/data/rolling_cache_manager_test.dart`)
- [x] Phase 4 increment 3 (playback settings persistence/UI + durable scrobble queue with retry/expiry + settings-driven streaming profiles) — 2026-02-20 (evidence: `./tool/check.sh`, `lib/src/features/settings/presentation/playback_settings_screen.dart`, `lib/src/features/player/data/scrobble_service.dart`, `lib/src/database/daos/scrobble_dao.dart`, `lib/src/database/daos/app_settings_dao.dart`, `test/src/features/player/data/scrobble_service_test.dart`, `test/src/features/settings/presentation/playback_settings_screen_test.dart`)
- [x] Phase 4 increment 4 (playback reliability startup gate, strict handler-backed queue actions, persisted gapless/skip-silence settings, and audio-session interruption/noisy handling) — 2026-02-20 (evidence: `./tool/check.sh`, `lib/src/app.dart`, `lib/src/providers/app_providers.dart`, `lib/src/features/player/data/navis_audio_handler.dart`, `lib/src/features/settings/presentation/playback_settings_screen.dart`, `test/widget_test.dart`, `test/src/providers/app_providers_test.dart`, `test/src/database/migrations/navis_migration_test.dart`)
- [x] Phase 4 pre-Phase-5 hardening (bootstrap attempt guarding, queue persistence write-split, migration-path coverage, test DB isolation for routing, and reliability-focused check gates) — 2026-02-21 (evidence: `./tool/check.sh`, `lib/src/providers/app_providers.dart`, `lib/src/features/player/data/navis_audio_handler.dart`, `lib/src/database/daos/play_queue_dao.dart`, `test/src/routing/app_router_test.dart`, `test/src/database/migrations/navis_migration_test.dart`, `tool/check.sh`)
- [x] Phase 4.4 closeout automation helper (device-aware codec preflight script + workflow + make target) — 2026-02-22 (evidence: `tool/phase4_codec_closeout.sh`, `docs/development-workflow.md`, `Makefile`, `flutter test test/src/features/player/data/playback_source_resolver_test.dart test/src/features/player/data/navis_audio_handler_test.dart`)
- [x] Phase 4 pre-Phase-5 transport stabilization (reverted over-gated playback controls, retained safe persistence + queue bounds + seek sanitization, and revalidated core regression suites) — 2026-02-23 (evidence: `lib/src/features/player/data/navis_audio_handler.dart`, `test/src/features/player/data/navis_audio_handler_test.dart`, `flutter test test/src/providers/app_providers_test.dart test/src/features/library/presentation/library_detail_screens_test.dart test/src/features/player/data/navis_audio_handler_test.dart`)
- [x] Phase 4.4 codec verification closeout (provisional) — 2026-02-23 (evidence: deterministic codec matrix tests + critical gate coverage + automated closeout preflight on SM-S928B via `make phase4-codec-closeout DEVICE_ID=R5CX14TVQEE SERVER_VARIANT=OpenSubsonic` + runtime playback evidence for FLAC/AAC/MP3 lock-cached paths from `codec_runtime_raw.log`; accepted caveat: Opus runtime row pending and Vorbis unavailable in current library/server catalog)
- [x] Phase 5 increment 1 (Now Playing screen, enhanced mini player, lyrics screen, sleep timer, NavisPlaybackHandler transport interface) — 2026-02-23 (evidence: `dart analyze lib/ test/`, `flutter test test/src/providers/app_providers_test.dart test/src/features/player/data/navis_audio_handler_test.dart test/src/features/library/presentation/library_detail_screens_test.dart`)
- [x] Phase 5 increment 2 (legacy lyrics fallback, sleep timer volume fade-out, save queue as playlist, inline lyrics toggle, setVolume interface) — 2026-02-23 (evidence: `dart analyze lib/ test/`, all relevant tests pass)
- [x] Phase 5 hardening — Phase 6 prep (removed sleep timer, Star→Like/Heart icon rename, Now Playing layout stability fix, lyrics auto-scroll delay fix, navigation overhaul: expandable player sheet in AppShell with swipe up/down/back gestures, removed /now-playing route, PopScope back-button handling, deprecation fixes) — 2026-02-23 (evidence: `dart analyze lib/` — 0 issues, `flutter test` — 165/165 pass)
- [x] Phase 6 increment 1 (search screen with debounced live search, grouped results by Artists/Albums/Songs, recent searches with clear, tap-to-navigate/play, long-press context menu, Show all/Show less toggle, l10n strings, search controller providers) — 2026-02-23 (evidence: `dart analyze lib/` — 0 errors, `flutter test` — 165/165 pass)
- [x] Phase 6 hardening (RenderFlex overflow fix via Stack layout in AppShell, ExpandablePlayerSheet maxHeight from LayoutBuilder, lyrics timing fix via positionStream at 100-200ms, queue back-button fix via context.push, navigation consistency audit, dead code cleanup, seek bar position stream) — 2026-02-23 (evidence: `dart analyze lib/ test/` — 0 errors, `flutter test` — 165/165 pass)
- [x] Phase 6 post-hardening (Now Playing Column overflow fix via ClipRect during open/close animation, lyrics smart auto-sync: inactivity timer re-engages auto-scroll after 5s of no touch, initial mount scrolls to current lyric line, resume-aware centering) — 2026-02-23 (evidence: `dart analyze lib/` — 0 issues)
- [x] Phase 7 increment 1 (playlists list screen with pull-to-refresh + server sync, create/rename/delete CRUD, playlist detail screen with cover art + track list + play/shuffle + swipe-to-remove, "Add to Playlist" picker in album/search context menus, playlist providers, 65+ l10n strings) — 2026-02-23 (evidence: `dart analyze lib/` — 0 errors, `flutter test` — 165/165 pass)
- [x] Phase 8 increment 1 — Cache Settings Screen (configurable rolling cache budget 500 MB–10 GB with DB persistence via schema v9, rolling/permanent cache stats cards with progress bar, clear rolling/permanent/cover art buttons with confirmation dialogs) — 2026-02-23 (evidence: `dart analyze lib/` — 1 info, `flutter test` — 165/165 pass, commit cab6b83)
- [x] Phase 8 increment 2 — Download Service + Downloads Screen (DownloadService with Dio-based downloads + queue processing, DownloadQualitySheet picker, DownloadsScreen with Queue/Downloaded tabs, album detail + now playing download actions, /settings/downloads route) — 2026-02-23 (evidence: `dart analyze lib/` — 1 info, `flutter test` — 165/165 pass, commit 44f3de6)
- [x] Phase 8 increment 3 — Offline Filter + Playlist Downloads (auto-start DownloadService, playlist detail download button + per-song context menu, "Downloaded" FilterChip in library albums/artists tabs, downloadedContentIdsProvider) — 2026-02-23 (evidence: `dart analyze lib/` — 1 info, `flutter test` — 165/165 pass, commit aa4622a)

## Meta Progress
- [x] Tech stack and methodology validation refresh — 2026-02-18 (evidence: `DEVELOPMENT_PLAN.md` stack validation section + README tech stack update)

## Blockers
- None currently tracked.

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
- [x] Auto-reconnect on launch with offline banner — 2026-02-19 (evidence: `lib/src/features/auth/presentation/server_reachability_provider.dart`, `lib/src/routing/app_shell.dart`, `test/src/routing/app_router_test.dart`)
- [x] Reachability-based online/offline status (server ping, not just interface connectivity) — 2026-02-19 (evidence: `lib/src/features/auth/presentation/server_reachability_provider.dart`, `test/src/features/auth/presentation/server_reachability_provider_test.dart`)
- [x] Sign out clears all credentials — 2026-02-19 (evidence: `lib/src/features/auth/data/sign_out_service.dart`, `lib/src/features/auth/data/server_config_repository.dart`, `test/src/features/auth/data/sign_out_service_test.dart`)
- [x] ARB string extraction begins — 2026-02-19 (evidence: `lib/l10n/app_en.arb`, `lib/l10n/app_localizations.dart`, `lib/l10n/app_localizations_en.dart`, `lib/src/app.dart`)

## Phase 3: Library Browsing & Metadata Sync
### 3.1 — Sync Engine
- [x] Full initial sync (artists → albums → songs → genres → playlists) — 2026-02-20 (evidence: `lib/src/features/library/data/library_sync_engine.dart`, `test/src/features/library/data/library_sync_engine_test.dart`)
- [x] Incremental sync with `ifModifiedSince` — 2026-02-20 (evidence: `lib/src/api/subsonic_api_client.dart` `getIndexes`, `lib/src/api/models/indexes.dart`, `test/src/features/library/data/library_sync_engine_test.dart`)
- [x] Progressive/resumable song hydration with pending-state recovery — 2026-02-20 (evidence: `lib/src/features/library/data/library_sync_engine.dart`, `lib/src/database/daos/library_dao.dart`, `test/src/features/library/data/library_sync_engine_test.dart`)
- [x] Bulk song hydration auto-fast-path with guaranteed fallback to per-album hydration — 2026-02-20 (evidence: `lib/src/features/library/data/library_sync_engine.dart`, `test/src/features/library/data/library_sync_engine_test.dart`)
- [x] Priority hydration queue for visible/recently interacted albums, then background backlog completion — 2026-02-20 (evidence: `lib/src/features/library/presentation/library_sync_provider.dart`, `lib/src/features/library/presentation/library_screen.dart`, `lib/src/features/library/presentation/album_detail_screen.dart`)
- [ ] Background isolate execution — partial: 2026-02-20 (remaining: sync orchestration remains on main isolate; heavy album/song companion transformation is offloaded via `Isolate.run` in `lib/src/features/library/data/library_sync_engine.dart`)
- [x] Force re-sync from settings — 2026-02-20 (evidence: `lib/src/features/settings/presentation/server_settings_screen.dart`, `test/src/features/settings/presentation/server_settings_screen_test.dart`)
- [x] Sync progress indicator — 2026-02-20 (evidence: `lib/src/features/library/presentation/library_screen.dart` `_SyncStatusBanner`)

### 3.2 — Library UI
- [x] Home screen carousels (recently played, recently added, most played, random, starred) — 2026-02-20 (evidence: `lib/src/features/home/presentation/home_screen.dart`, `lib/src/features/home/presentation/home_providers.dart`)
- [x] Artists tab (alphabetical, fast scroll index) — 2026-02-20 (evidence: `lib/src/features/library/presentation/library_screen.dart`)
- [x] Artist detail screen (albums grid, bio, similar artists) — 2026-02-20 (evidence: `lib/src/features/library/presentation/artist_detail_screen.dart`)
- [x] Albums tab (paged grid, SQL sort, large-library friendly loading) — 2026-02-20 (evidence: `lib/src/features/library/presentation/library_screen.dart`, `lib/src/providers/app_providers.dart`, `lib/src/database/daos/library_dao.dart`)
- [x] Album detail screen (cover art, track list, star, download, context menu) — 2026-02-20 (evidence: `lib/src/features/library/presentation/album_detail_screen.dart`)
- [x] Library top-level tabs realigned to Albums + Artists only (songs/genres removed from main Library navigation) — 2026-02-21 (evidence: `lib/src/features/library/presentation/library_screen.dart`, `lib/src/routing/app_router.dart`, `test/src/features/library/presentation/library_screen_test.dart`)
- [x] Library default tab switched to Albums-first (Artists secondary via swipe/tab) — 2026-02-21 (evidence: `lib/src/features/library/presentation/library_screen.dart`, `test/src/features/library/presentation/library_screen_test.dart`)
- [x] Radio foundation (Library tab station list/provider + graceful unsupported handling) — 2026-02-21 (evidence: `lib/src/features/library/presentation/radio_screen.dart`, `lib/src/features/library/presentation/library_screen.dart`, `lib/src/providers/app_providers.dart`)
- [x] Settings toggle to show/hide Radio page — 2026-02-21 (evidence: `lib/src/database/tables/app_settings_table.dart`, `lib/src/features/settings/presentation/playback_settings_screen.dart`, `lib/src/routing/app_shell.dart`)
- [x] NavigationBar realigned to app core destinations only (Home, Library, Search, Playlists, Settings) with Radio hosted inside Library tabs — 2026-02-21 (evidence: `lib/src/routing/app_shell.dart`, `lib/src/features/library/presentation/library_screen.dart`)
- [ ] 60fps scroll with 10K+ items — partial: 2026-02-20 (remaining: explicit large-library profiling/benchmark evidence pending)

### 3.3 — Common Widgets
- [x] `ShimmerPlaceholder` skeleton loading widget — 2026-02-20 (evidence: `lib/src/common_widgets/shimmer_placeholder.dart`)
- [x] `ErrorState` widget (with retry) — 2026-02-20 (evidence: `lib/src/common_widgets/error_state.dart`)
- [x] `EmptyState` widget (with contextual message) — 2026-02-20 (evidence: `lib/src/common_widgets/empty_state.dart`)
- [x] `CoverArtImage`, `TrackListTile`, `AlbumCard`, `ArtistCard`, `StarButton`, `CacheBadge` — 2026-02-21 (evidence: `lib/src/common_widgets/*.dart`, integrations in `lib/src/features/library/presentation/album_detail_screen.dart`, `lib/src/features/home/presentation/home_screen.dart`)

### 3.4 — Context Menus & Actions
- [x] Context menu bottom sheets (song, album, artist) — 2026-02-20 (evidence: `lib/src/features/library/presentation/library_screen.dart`, `lib/src/features/library/presentation/album_detail_screen.dart`)

### 3.5 — Localization Setup
- [x] `l10n.yaml` configuration — 2026-02-20 (evidence: `l10n.yaml`)
- [x] `lib/l10n/app_en.arb` with all implemented Phase 3 strings — 2026-02-20 (evidence: `lib/l10n/app_en.arb`)
- [x] `AppLocalizations` integration in implemented Phase 3 screens — 2026-02-20 (evidence: `lib/src/features/home/presentation/home_screen.dart`, `lib/src/features/library/presentation/library_screen.dart`, `lib/src/features/library/presentation/artist_detail_screen.dart`, `lib/src/features/library/presentation/album_detail_screen.dart`, `lib/src/features/library/presentation/genre_detail_screen.dart`)

## Phase 4: Audio Playback Engine
### 4.1 — NavisAudioHandler
- [x] `BaseAudioHandler` extension with `just_audio` — 2026-02-20 (evidence: `lib/src/features/player/data/navis_audio_handler.dart`, `pubspec.yaml`)
- [x] Queue-backed playback source list management — 2026-02-20 (evidence: `lib/src/features/player/data/navis_audio_handler.dart`, `lib/src/providers/app_providers.dart`)
- [x] Source resolution (permanent cache → rolling cache → `LockCachingAudioSource`) — 2026-02-20 (evidence: `lib/src/features/player/data/playback_source_resolver.dart`, `lib/src/features/cache/data/rolling_cache_manager.dart`)
- [x] `LockCachingAudioSource` → `RollingCacheManager.registerTrack()` integration — 2026-02-20 (evidence: `lib/src/features/player/data/navis_audio_handler.dart`, `lib/src/features/cache/data/rolling_cache_manager.dart`, `test/src/features/cache/data/rolling_cache_manager_test.dart`)
- [x] Network-aware quality selection (Wi-Fi vs cellular) — 2026-02-20 (evidence: `lib/src/features/player/data/playback_source_resolver.dart`, `lib/src/providers/app_providers.dart` `activeStreamingQualityProvider`)
- [x] Queue operations (play, skip, reorder, clear, replace, playNext, addToQueue) — 2026-02-20 (evidence: `lib/src/features/player/data/navis_audio_handler.dart`, `lib/src/providers/app_providers.dart`, `test/src/providers/app_providers_test.dart`)
- [x] Shuffle + repeat modes — 2026-02-20 (evidence: `NavisAudioHandler.setShuffleMode`, `NavisAudioHandler.setRepeatMode`, persisted queue modes in `play_queue`)
- [x] Scrobbling (now playing + submission at threshold) — 2026-02-20 (evidence: `lib/src/features/player/data/navis_audio_handler.dart`, `lib/src/features/player/data/scrobble_service.dart`, `lib/src/database/tables/scrobble_queue_table.dart`, `test/src/features/player/data/scrobble_service_test.dart`)
- [x] Lock screen and notification controls — 2026-02-20 (evidence: `audio_service` init in `lib/src/features/player/data/navis_audio_handler.dart`, startup bootstrap in `lib/main.dart`, `android/app/src/main/kotlin/com/navis/app/navis/MainActivity.kt`)
- [x] Audio focus / interruption handling (`audio_session`) — 2026-02-20 (evidence: `AudioSessionConfiguration.music()` in `lib/src/features/player/data/navis_audio_handler.dart`)
- [x] Startup playback reliability gate (blocking retry flow until handler init succeeds) — 2026-02-20 (evidence: `lib/src/app.dart`, `lib/src/providers/app_providers.dart`, `test/widget_test.dart`)
- [x] Bootstrap timeout hardening with late-success recovery and stale-attempt protection — 2026-02-21 (evidence: `lib/src/providers/app_providers.dart`, `test/src/providers/app_providers_test.dart`)
- [x] DSP non-fatal fallback hardening (queue apply retries with DSP degradation + plain-player recovery path) — 2026-02-21 (evidence: `lib/src/features/player/data/navis_audio_handler.dart`)

### 4.2 — Play Queue Persistence
- [x] Save queue on every track change — 2026-02-20 (evidence: `_persistQueueState` wiring in `lib/src/features/player/data/navis_audio_handler.dart`)
- [x] Periodic position persistence (every 10–15s) — 2026-02-20 (evidence: 15s timer in `lib/src/features/player/data/navis_audio_handler.dart`)
- [x] Restore queue on app launch — 2026-02-20 (evidence: `_restoreQueueFromDisk` in `lib/src/features/player/data/navis_audio_handler.dart`; startup bootstrap in `lib/main.dart`)
- [x] Cross-device queue sync removed from product scope (local queue persistence only) — 2026-02-21 (evidence: `lib/src/api/subsonic_api_client.dart`, `lib/src/providers/app_providers.dart`, `DEVELOPMENT_PLAN.md`)

### 4.3 — Streaming Quality
- [x] Wi-Fi quality profile — 2026-02-20 (evidence: `lib/src/features/settings/presentation/playback_settings_screen.dart`, `lib/src/providers/app_providers.dart`)
- [x] Cellular quality profile — 2026-02-20 (evidence: `lib/src/features/settings/presentation/playback_settings_screen.dart`, `lib/src/providers/app_providers.dart`)
- [x] Live network type switching — 2026-02-20 (evidence: `lib/src/providers/app_providers.dart` `networkTypeProvider` + `activeStreamingQualityProvider`)
- [x] No-transcode default (original quality) — 2026-02-20 (evidence: `AppSettingsModel.defaults()` in `lib/src/features/settings/domain/app_settings.dart`, streaming resolver in `lib/src/features/player/data/playback_source_resolver.dart`)

### 4.4 — Audio Quality Details
- [ ] Verify native codec support (FLAC, ALAC, MP3, AAC, Opus, Vorbis) — partial: 2026-02-22 (implemented: resolver matrix across file/lock-cached/direct paths + handler fallback decision tests + critical gate wiring + `tool/phase4_codec_closeout.sh` evidence helper; remaining: record completed real-device evidence matrix rows)
- [x] Android equalizer (`AndroidEqualizer`) — 2026-02-21 (evidence: `lib/src/features/player/data/navis_audio_handler.dart`, `lib/src/features/settings/presentation/playback_settings_screen.dart`)
- [x] Android loudness enhancer (`AndroidLoudnessEnhancer`) — 2026-02-21 (evidence: `lib/src/features/player/data/navis_audio_handler.dart`, `lib/src/features/settings/presentation/playback_settings_screen.dart`)
- [ ] ReplayGain volume normalization (deferred post-Phase-5)
- [x] Skip-silence option removed from runtime behavior (compatibility field retained only in DB/settings model) — 2026-02-21 (evidence: `lib/src/features/player/data/navis_audio_handler.dart`, `lib/src/features/settings/presentation/playback_settings_screen.dart`, `lib/src/features/settings/domain/app_settings.dart`)

## Phase 5: Now Playing & Lyrics
### 5.1 — Mini Player
- [x] Persistent bar above NavigationBar — 2026-02-23 (evidence: `lib/src/routing/app_shell.dart` `_MiniPlayerStrip`)
- [x] Cover art, title, artist, play/pause, progress — 2026-02-23 (evidence: cover art thumbnail, linear progress bar in `_MiniPlayerStrip`)
- [x] Tap to expand, swipe to skip — 2026-02-23 (evidence: tap→`/now-playing`, horizontal swipe→`skipToNext`/`skipToPrevious`)

### 5.2 — Now Playing Screen
- [x] Full-screen cover art — 2026-02-23 (evidence: `lib/src/features/player/presentation/now_playing_screen.dart` `_CoverArt`; tinted background deferred to polish phase)
- [x] Seek bar with elapsed/remaining — 2026-02-23 (evidence: `_SeekBar` with drag support and ms-precision seek)
- [x] All playback controls — 2026-02-23 (evidence: `_TransportControls` with shuffle, prev, play/pause, next, repeat cycling)
- [x] Star, lyrics, queue, overflow menu buttons — 2026-02-23 (evidence: `_ActionRow` + `_NowPlayingAppBar` overflow; star wiring deferred)
- [ ] Hero animation from mini player / album detail — deferred to Phase 10 polish

### 5.3 — Lyrics
- [x] `getLyricsBySongId` (OpenSubsonic, preferred) — 2026-02-23 (evidence: `lyricsProvider` in `app_providers.dart`, `NowPlayingLyricsScreen`)
- [x] `getLyrics` fallback (legacy) — 2026-02-23 (evidence: `lyricsProvider` try/catch with `getSongsByIds` for artist/title)
- [x] Synced lyrics with auto-scroll and tap-to-seek — 2026-02-23 (evidence: `LyricsDisplayWidget` with `Scrollable.ensureVisible` + seek callback)
- [x] Unsynced lyrics display — 2026-02-23 (evidence: `_buildUnsyncedLyrics` in `LyricsDisplayWidget`)
- [x] Cover art ↔ lyrics toggle — 2026-02-23 (evidence: `_InlineLyrics` widget + `_ActionRow` toggle in `now_playing_screen.dart`; separate route also available)

### 5.4 — Queue Screen
- [x] Drag-to-reorder, swipe-to-remove — 2026-02-23 (evidence: `QueueScreen` with `ReorderableListView` + `Dismissible`)
- [x] Clear queue — 2026-02-23 (evidence: clear action in `QueueScreen` AppBar)
- [x] Save as playlist — 2026-02-23 (evidence: `_showSaveAsPlaylistDialog` + `createPlaylist` API call in `queue_screen.dart`)

### 5.5 — Sleep Timer
- [x] Preset durations + end of track — 2026-02-23 (evidence: `SleepTimerController` with 15/30/45/60 min presets + end-of-track mode)
- [x] Countdown display on Now Playing — 2026-02-23 (evidence: `_NowPlayingAppBar` shows remaining time when sleep timer active)
- [x] Volume fade-out in final 30 seconds — 2026-02-23 (evidence: `SleepTimerController._startTicker` fades over `_fadeDuration`, `NavisPlaybackHandler.setVolume`)

## Phase 6: Search
- [x] Search screen with debounced input (300ms) — 2026-02-23 (evidence: `lib/src/features/search/presentation/search_screen.dart`, `lib/src/features/search/presentation/search_controller_provider.dart`)
- [x] `search3` API — live results, no caching — 2026-02-23 (evidence: `search_controller_provider.dart` `debouncedSearchProvider` with cancel token, `FutureProvider.autoDispose`)
- [x] Results grouped by artists, albums, songs — 2026-02-23 (evidence: `_ArtistResultsSection`, `_AlbumResultsSection`, `_SongResultsSection` in `search_screen.dart`)
- [x] "Show all" expansion per section + pagination — 2026-02-23 (evidence: `_SectionHeader` toggle + `expandedSearchProvider` with offset-based pagination)
- [x] Recent searches persistence — 2026-02-23 (evidence: `recentSearchesProvider` streams from `historyDao.watchRecentSearches()`, clear via `dao.clearAllHistory()`)
- [x] Tap → navigate, song tap → play immediately — 2026-02-23 (evidence: tap artist/album pushes to detail route, song tap replaces queue + context menu with Play Next/Add to Queue/Go to Album/Artist)

## Phase 7: Playlists
- [x] Playlist list screen — 2026-02-23 (evidence: `lib/src/features/playlists/presentation/playlists_screen.dart` with pull-to-refresh, server sync, cover art tiles)
- [x] Playlist detail screen (play, shuffle, download) — 2026-02-23 (evidence: `lib/src/features/playlists/presentation/playlist_detail_screen.dart` with cover art, track list, play/shuffle actions)
- [ ] Drag-to-reorder, swipe-to-remove — partial: 2026-02-23 (implemented: swipe-to-remove via `Dismissible` + `updatePlaylist songIndexesToRemove`; remaining: drag-to-reorder)
- [x] Create / edit / delete playlists (full CRUD → server) — 2026-02-23 (evidence: create dialog + rename dialog + delete confirmation in `playlists_screen.dart`, all via server API)
- [x] "Add to playlist" from any song context menu — 2026-02-23 (evidence: `add_to_playlist_sheet.dart` integrated in album detail + search context menus)
- [x] On-demand playlist song fetch + local sync — 2026-02-23 (evidence: `playlistDetailSyncProvider` fetches `getPlaylist(id)`, upserts songs + join table)

## Phase 8: Offline & Cache Management
### 8.1 — Rolling Cache
- [x] `RollingCacheManager` with configurable max size — 2026-02-23 (evidence: `lib/src/features/settings/presentation/cache_settings_screen.dart` budget slider 500 MB–10 GB, `lib/src/database/daos/app_settings_dao.dart` `watchRollingCacheBudgetMb`, schema v9 migration)
- [x] LRU eviction by `lastAccessedAt` — 2026-02-20 (evidence: `lib/src/features/cache/data/rolling_cache_manager.dart`, `test/src/features/cache/data/rolling_cache_manager_test.dart`)
- [x] File tracking in `cached_tracks` (`cacheType = rolling`) — 2026-02-20 (evidence: `lib/src/features/cache/data/rolling_cache_manager.dart`, `lib/src/database/daos/cache_dao.dart`)
- [x] Integration with `LockCachingAudioSource` file paths — 2026-02-20 (evidence: `lib/src/features/player/data/playback_source_resolver.dart`, `lib/src/features/player/data/navis_audio_handler.dart`)
- [x] Cache settings screen (budget slider, stats cards, clear buttons) — 2026-02-23 (evidence: `lib/src/features/settings/presentation/cache_settings_screen.dart`)

### 8.2 — Permanent Cache
- [x] Quality choice dialog on pin (Original / 320 / 192 / 128) — 2026-02-23 (evidence: `lib/src/features/downloads/presentation/download_quality_sheet.dart`)
- [x] Download via Dio (stream + download endpoints) — 2026-02-23 (evidence: `lib/src/features/downloads/data/download_service.dart`)
- [x] File tracking in `cached_tracks` (`cacheType = permanent`) — 2026-02-23 (evidence: `download_service.dart` upserts permanent CachedTracksTableCompanion on completion)
- [x] Pin at album, playlist, or track level — 2026-02-23 (evidence: album detail download button, playlist detail download button + per-song, now playing overflow menu download)
- [ ] Auto-detect new tracks in pinned albums during sync

### 8.3 — Download Queue
- [x] `DownloadService` with `download_queue` table — 2026-02-23 (evidence: `lib/src/features/downloads/data/download_service.dart`)
- [x] Sequential processing (one download at a time) — 2026-02-23 (evidence: `_processNext` loop in download_service.dart)
- [x] Cancel / retry per item — 2026-02-23 (evidence: downloads_screen.dart queue tab retry/cancel buttons)
- [ ] Wi-Fi-only download mode
- [ ] Resume interrupted downloads on restart
- [ ] Download notifications via `flutter_local_notifications`
- [x] Downloads screen with Queue + Downloaded tabs — 2026-02-23 (evidence: `lib/src/features/downloads/presentation/downloads_screen.dart`)

### 8.4 — Offline Mode
- [x] "Downloaded Only" toggle in library — 2026-02-23 (evidence: `lib/src/features/library/presentation/library_screen.dart` FilterChip, `downloadedContentIdsProvider`)
- [ ] Rolling cache items shown with temporary badge
- [x] "Promote to permanent" (no re-download if same quality) — 2026-02-23 (evidence: `download_service.dart` `promoteToPermament` method)
- [ ] "Download in original quality" (re-download from server)
- [x] Offline banner when server unreachable — 2026-02-19 (evidence: pre-existing `app_shell.dart`)

### 8.5 — Cover Art Cache
- [x] `cached_network_image` integration — 2026-02-20 (evidence: `lib/src/common_widgets/cover_art_image.dart`)
- [ ] Configurable max size
- [ ] Thumbnail vs full-size strategy

### 8.6 — Smart Cache Behaviors
- [ ] Stream higher quality on Wi-Fi even if lower-quality pin exists
- [ ] Auto-queue new tracks in pinned albums

## Phase 9: Settings
- [ ] Server section (display, test, sign out)
- [x] Playback — streaming quality (Wi-Fi / cellular profiles) — 2026-02-20 (evidence: `/settings/playback` in `lib/src/features/settings/presentation/playback_settings_screen.dart`, persistence in `lib/src/database/daos/app_settings_dao.dart`)
- [ ] Playback — general (ReplayGain deferred post-Phase-5, resume UX polish pending)
- [x] Audio section (equalizer, loudness enhancer — Android only) — 2026-02-21 (evidence: `lib/src/features/player/data/navis_audio_handler.dart`, `lib/src/features/settings/presentation/playback_settings_screen.dart`)
- [x] Downloads & cache (cache budget slider, rolling/permanent stats, clear buttons, downloads screen) — 2026-02-23 (evidence: `lib/src/features/settings/presentation/cache_settings_screen.dart`, `lib/src/features/downloads/presentation/downloads_screen.dart`, `/settings/cache` + `/settings/downloads` routes)
- [ ] Appearance — theme mode (Light / Dark / OLED / System) — partial: 2026-02-19 (implemented: app defaults to Dark Mode; remaining: settings UI selector including Light Mode toggle and full persisted mode controls)
- [ ] Appearance — color scheme (Dynamic / Preset / Custom seed) — partial: 2026-02-19 (remaining: mode-aware palette selections for light and dark families + full appearance UI)
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

### 10.11 — UI/UX Polish Attention
- [ ] Album art visual polish pass (cards, hero, placeholders, transitions)
- [ ] Optimistic UI pass (star/queue/cache actions with rollback behavior)
- [ ] Motion polish pass (micro-interactions + consistent transition timing)
- [ ] Cross-screen design consistency audit (spacing, typography, states, icon rhythm)

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
