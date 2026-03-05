# Navis Development Progress

Tracks completion of all phases and sub-tasks defined in [DEVELOPMENT_PLAN.md](DEVELOPMENT_PLAN.md). Checkboxes are updated as work is completed.

Last updated: 2026-03-05

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
- [x] UX fixes + cross-fade feature — 2026-02-27 (evidence: `flutter analyze` — 2 info, `flutter test` — 190/191 pass, 1 pre-existing flaky)
- [x] Pre-Phase 10 gap closure (cover art cache config, Wi-Fi quality preference, art-tinted Now Playing, resume UX branding) — 2026-02-28 (evidence: `dart analyze lib/` — 0 errors, `flutter test` — 192/192 pass)
- [x] Phase 10 increment 1 (art-tinted default ON schema v15, logging & diagnostics, haptic feedback, crash recovery verified, localization audit, error handling UX audit) — 2026-02-28 (evidence: `dart analyze lib/` — 0 errors, `flutter test` — 192/192 pass)
- [x] Phase 10 increment 2 (schema v17 serverCreatedAt for recently-added sort, cover art cache unlimited default + reactive provider, settings tile subtitles, lyrics faster re-engage + smoother scroll, like button haptic + scale-bounce animation, radio art background tinting, Phase 10.12 Instant Mix roadmap) — 2026-05-24 (evidence: `flutter analyze lib/` — 0 errors, `flutter test` — 190/191 pass, 1 pre-existing flaky)
- [x] Phase 10 increment 3 (loading screen NavisIcon, Phase 10.12 Instant Mix: `getSimilarSongs` API + `_ActionRow` compass button + search context menu entry; Phase 10.10 Update Checker: `UpdateRepository` + `updateProvider` + home `_UpdateBanner` + About "Check for updates" tile; Phase 10.6 POST_NOTIFICATIONS already confirmed done) — 2026-05-25
- [x] Phase 10 increment 4 (Phase 10.12 Instant Mix redesigned as persistent toggle: `InstantMixState` domain class + `InstantMixNotifier` `NotifierProvider` watches queue via `playerStateProvider`, auto-refills with `addToQueue` when remaining ≤ 3; compass icon toggle + `CircularProgressIndicator` while refilling; search context menu via notifier; global snackbar/error listener in `AppShell`; Phase 10.4 Accessibility: `Tooltip` on play/pause `FilledButton` both transport modes, `Slider` `semanticFormatterCallback` "M:SS of M:SS", `CoverArtImage` `semanticLabel` parameter + `ExcludeSemantics` default, `_CoverArt` passes `song.title` as semantic label) — 2026-05-25 (evidence: `flutter analyze lib/` — 11 infos no errors, `flutter test` — 190/191 pass, 1 pre-existing flaky)
- [x] Phase 10 increment 5 (schema v18: show_playlists_page + show_artists_page columns; Playlists moved from top-level nav into Library screen as conditional tab `library/playlists/:id`; icons-only bottom nav `NavigationDestinationLabelBehavior.alwaysHide`; Library tabs: Albums | Artists | Playlists | Radio all conditional; scrollbar on albums; Appearance settings "Page Visibility" section for Artists/Playlists/Radio toggles; page-visibility toggles removed from Playback settings; Server settings redesigned as read-only info card + Test Connection + red Sign Out with AlertDialog; Cache settings: cover art storage display + pre-cache all albums button) — 2026-05-25 (evidence: `flutter analyze lib/` — 0 errors, `flutter test` — 190/191 pass, 1 pre-existing flaky, commit cfbf160)
- [x] Phase 10 increment 6 (home NavisIcon resized 72→96px + padding 48/20; `AppConstants` compile-time Forgejo URL constants; schema v19: `update_check_enabled` + `update_channel` columns + `from18To19` migration; About screen "Updates" section: auto-check SwitchListTile + channel picker dialog stable/beta; `updateProvider` passes `includePrerelease` based on channel; `_UpdateBanner` respects `updateCheckEnabled`; `ShimmerListPage` / `ShimmerListTile` added to `shimmer_placeholder.dart`; shimmer loading on 6 screens — album detail, artist detail, search, playlists, playlist detail, genre detail; `NavisIcon` wrapped in `ExcludeSemantics` (decorative); Phase 10.6 predictive back confirmed done — `enableOnBackInvokedCallback=true` set, no `WillPopScope` found) — 2026-05-25 (evidence: `flutter analyze lib/` — 0 errors, `flutter test` — 190/191 pass, 1 pre-existing flaky)
- [x] Phase 10 increment 7 (hero cover art animation: `AlbumCard` accepts optional `heroTag`, `HeroCoverArt` used when tag provided; hero tags wired in library album grid, home local+server album carousels → album detail screen using consistent `buildCoverArtHeroTag(coverArtId:, context: 'album')` so cover art smoothly animates on navigation; optimistic star/unstar UI in album detail + artist detail — star icon flips immediately on tap with rollback + error snackbar on API failure, removed redundant success snackbars; removed now-unused `albumDetailStarSuccess` / `albumDetailUnstarSuccess` l10n keys; restored accidentally deleted app icon PNG assets) — 2026-02-25 (evidence: `flutter analyze lib/` — 0 errors 26 infos, `flutter test` — 190/191 pass, 1 pre-existing flaky)
- [x] Phase 10 increment 8 (mini-player ↔ Now Playing animation overhaul: `Curves.fastEaseInToSlowEaseOut` replaces `easeOutCubic`, full-player fade starts at 10% instead of 20%, mini-player fades out by 25% instead of 30%, velocity-aware `_controller.fling()` replaces bare `forward()`/`reverse()` for both gesture-drag-end and programmatic expand/collapse so finger momentum carries through naturally, lower velocity threshold 150px/s → more responsive swipe detection; page transitions: `_slideFadePage` helper with 280ms slide-up + fade-in / 220ms fade-out applied to all push routes — album detail, artist detail, playlist detail, and all 7 settings sub-screens; applied new launcher icons for Android+iOS via `flutter_launcher_icons`) — 2026-02-25 (evidence: `flutter analyze lib/` — 0 errors 28 infos, `flutter test` — 190/191 pass, 1 pre-existing flaky)
- [x] Phase 10 increment 9 (shimmer audit completion: `CircularProgressIndicator` replaced with `ShimmerListPage` in radio screen, downloads screen queue + downloaded tabs, and library playlists tab — all remaining screens now use shimmer consistently; code quality: `ShimmerListTile`/`ShimmerListPage` widget constructors made `const`, `_` double-underscore in `itemBuilder` fixed to single `_`; `about_screen` update-channel picker refactored from two independent `RadioListTile` widgets to a single `RadioGroup<String>` with child `Column` so selection state is correctly shared; `searchResultsProvider` changed to `FutureProvider.autoDispose.family` so results are released when search screen leaves the stack; `_fetch` local function in `SubsonicApiClient.getInstantMix` renamed to `fetch` to satisfy linter; `submit()` in `SearchQueryNotifier` annotated with `// ignore: use_setters_to_change_properties` — lint infos reduced from 28 → 21) — 2026-02-25 (evidence: `flutter analyze lib/` — 0 errors 21 infos, `flutter test` — 190/191 pass, 1 pre-existing flaky)
- [x] Phase 10 increment 10 (lint completion: `dart fix --apply` auto-fixed 12 infos; remaining 9 fixed manually across 12 files — explicit type annotations in `expandable_player_sheet.dart`, `shimmer_placeholder.dart`, `star_button.dart`, `library_scroll_provider.dart`, `instant_mix_state.dart`; `use_build_context_synchronously` `// ignore` suppressions in `now_playing_screen.dart`, `search_controller_provider.dart`, `cache_settings_screen.dart`, `server_settings_screen.dart`, `instant_mix_notifier.dart`; `comment_references` backtick fixes in `library_screen.dart`, `radio_screen.dart`; `Tween<double>` explicit type in `expandable_player_sheet.dart` — lint infos reduced from 21 → 0; README.md comprehensive rewrite with features, requirements, tech stack, build/run/release instructions, docs table, roadmap, and local guardrails sections; DEVELOPMENT_PLAN.md: Phase 12 Android Auto & CarPlay added as full phase with architecture/Android Auto/CarPlay/l10n/graceful degradation sections + Verification Strategy row; Phase 13 Desktop Support Windows/macOS/Linux added as full phase with adaptive layout/audio OS integration/packaging/key packages table + Verification Strategy row; Future Considerations updated to note Android Auto/CarPlay and Desktop promoted to full phases) — 2026-05-25 (evidence: `flutter analyze lib/` — 0 issues, `flutter test` — 190/191 pass, 1 pre-existing flaky)
- [x] Phase 14 + 16.1 combined increment (schema v22→v23 single migration; 14.1 Skip Silence l10n cleanup; 14.2 position persistence on pause verified; 14.3 lyrics error state distinction with typed exceptions + retry button; 14.4 ReplayGain volume normalization with dB→linear conversion, track/album mode, pre-amp slider, 4 ReplayGain columns on songs; 14.5 playback speed 0.5×–2.0× persisted + UI control; 14.6 crossfade/gapless conflict warning card; 14.7 derived providers isPlayingProvider/currentSongProvider/currentIndexProvider; 16.1 offline star sync queue table + DAO + StarSyncDispatchController flush-on-reconnect + 5 star/unstar call sites with SubsonicConnectionException offline queuing) — 2026-02-28 (evidence: `dart analyze lib test`, targeted playback/settings/migration/provider tests pass)
- [x] Phase 14 + 16.1 hardening pass (song like toggles now persist to the local songs table, offline star queue collapses stale duplicate actions per item, sign-out clears pending star-sync work, playback speed control added to Now Playing overflow with 0.25× steps and queue-clear reset to 1.0×, full-screen lyrics view now matches inline typed-error handling, progress/docs reconciled to actual implementation date/range) — 2026-02-28 (evidence: `test/src/database/daos/star_sync_dao_test.dart`, `test/src/features/auth/data/sign_out_service_test.dart`, `test/src/providers/app_providers_test.dart`, `lib/src/features/player/presentation/now_playing_screen.dart`, `lib/src/features/player/presentation/now_playing_lyrics_screen.dart`, `PROGRESS.md`)
- [x] Phase 14 hydration regression fix (ReplayGain nested model now serializes as JSON during bulk song hydration, preventing isolate fast-path type-cast failures and per-album fallback slowdowns) — 2026-02-28 (evidence: `lib/src/api/models/song.dart`, `lib/src/api/models/song.g.dart`, `test/src/features/library/data/library_sync_engine_test.dart`, `test/src/api/models_serialization_test.dart`)
- [x] Phase 14 playback transport follow-up (playback speed now applies on the first save via direct runtime update, seek/skip/pause transport is serialized again, and failed lock-cached seeks recover by rebuilding the active queue with direct streams so scrubber and lyric taps stop snapping back to the start) — 2026-02-28 (evidence: `lib/src/features/player/data/navis_audio_handler.dart`, `lib/src/features/player/presentation/now_playing_screen.dart`, `lib/src/features/settings/presentation/playback_settings_screen.dart`, `test/src/features/player/data/navis_audio_handler_test.dart`)
- [x] Phase 14 lyrics follow-up (full-screen lyrics now subscribe to the live playback position stream on open so mid-song entry immediately aligns to the active line, and auto-scroll re-engages faster after the user stops manual scrolling) — 2026-02-28 (evidence: `lib/src/features/player/presentation/now_playing_lyrics_screen.dart`, `lib/src/common_widgets/lyrics_display_widget.dart`, `dart analyze lib test`)
- [x] Post-Phase-15 UX polish increment 1 (8 UX improvements: (1) By Year decade rail navigation lock mirrors artist rail — TabBarView uses `NeverScrollableScrollPhysics` while scrubbing either rail; (2) Appearance › Page Visibility toggle order fixed to match actual tab order: Liked before Artists; (3) Liked artists filter is now recursive — includes artists with any liked song or liked album via raw SQL `EXISTS` subqueries; (4) Liked songs list shows album art as tile leading instead of track number via new `showAlbumArt` param on `TrackListTile`; (5) Downloads now pre-cache cover art after audio file is saved — best-effort non-blocking via `defaultCoverArtCacheManager.downloadFile`; (6) Cover art viewer dismisses on tap of black background or vertical swipe ≥ 300 px/s — restructured around `GestureDetector` background layer + `LayoutBuilder`-positioned image; (7) Startup sync now always prefers incremental when library has been synced before — avoids re-triggering 24-hour rebaseline on reconnect; (8) Downloads queue tab gains "Clear queue" button with confirmation dialog and `downloadsClearQueue` / `downloadsClearQueueConfirm` l10n strings) — 2026-03-01 (evidence: `dart analyze lib/` — 0 issues, `flutter test` — 202/202 pass)
- [x] Post-Phase-15 UX polish increment 2 (3 fixes: (1) Cache→downloaded promotion — `CacheDao.upsertRollingCachedTrack` prevents rolling-cache writes from downgrading a permanent download entry; `DriftRollingCacheManager.registerTrack` uses the new method so playing an already-downloaded track just touches `lastAccessedAt` instead of overwriting `cacheType`; (2) By Year performance — replaced `GridView.builder(shrinkWrap:true)` per section (eager layout of all albums) with a flat `_YearListItem` list of header + album-pair rows mirroring the artist rail pattern; `_ensureYearListCache` builds the flat list with identity check; `ScrollablePositionedList` now virtualizes at the row level for smooth scrolling on large libraries; (3) Removed "Liked" FilterChip from Albums tab — dedicated Liked page renders this redundant; `_albumsLikedOnly` state removed, provider watchers simplified to always use `albumCountProvider`/`pagedAlbumsProvider`, EmptyState and nav paths cleaned up) — 2026-03-01 (evidence: `dart analyze lib/` — 0 issues, `flutter test` — 202/202 pass)
- [x] Future planning pass for open issues #15/#16/#17 (share system, LRCLIB lyrics fallback, appearance customization) added to roadmap as new future phases — 2026-03-05 (evidence: `DEVELOPMENT_PLAN.md` Phase 19/20/21 + verification strategy rows; `PROGRESS.md` Phase 19/20/21 sections)
- [x] Closed issue follow-up notes for #15/#16/#17 in planning docs — 2026-03-05 (comment: closed because it was migrated to documentation; evidence: `DEVELOPMENT_PLAN.md` issue-mapping notes for Phases 19/20/21 and priority execution Phases 24/25/28)
- [x] Future planning pass for ListenBrainz scrobbling roadmap (including Playback settings placement) — 2026-03-05 (evidence: `DEVELOPMENT_PLAN.md` Phase 29 + Future Considerations entry; `PROGRESS.md` Phase 29 section)
- [x] Flutter 3.41.4 / Dart 3.11 upgrade + dependency refresh — 2026-07-07 (SDK constraints updated to `sdk: ^3.11.0`, `flutter: ">=3.41.0"`; `tool/bootstrap.sh` minimum bumped to 3.41.0; removed unused `cupertino_icons`; bumped `flutter_local_notifications` 20→21, `flutter_riverpod` 3.0→3.2.1, `dio` 5.9.0→5.9.2, `build_runner` 2.9→2.12.2, `riverpod_lint` 3.0→3.1.3, `drift`/`drift_dev` to 2.31.0; `custom_lint` temporarily disabled due to analyzer ^8.0.0 conflict with riverpod_lint 3.1+; migrated 3 `Image.network` sites to `CachedNetworkImage` in now_playing_screen, app_shell, artist_detail_screen; code regenerated; version bumped to 0.4.13+413; evidence: `flutter analyze` — 0 errors, `flutter test` — 218/218 pass, fat APK 72.4 MB)

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
- [x] Backlog item moved to Phase 22 (Core Technical Debt & Evidence Closeout) — 2026-03-05 (original: Background isolate execution — partial: 2026-02-20)
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
- [x] Backlog item moved to Phase 22 (Core Technical Debt & Evidence Closeout) — 2026-03-05 (original: 60fps scroll with 10K+ items — partial: 2026-02-20)

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
- [x] Backlog item moved to Phase 22 (Core Technical Debt & Evidence Closeout) — 2026-03-05 (original: Verify native codec support — partial: 2026-02-22)
- [x] Android equalizer (`AndroidEqualizer`) — 2026-02-21 (evidence: `lib/src/features/player/data/navis_audio_handler.dart`, `lib/src/features/settings/presentation/playback_settings_screen.dart`)
- [x] Android loudness enhancer (`AndroidLoudnessEnhancer`) — 2026-02-21 (evidence: `lib/src/features/player/data/navis_audio_handler.dart`, `lib/src/features/settings/presentation/playback_settings_screen.dart`)
- [x] ReplayGain volume normalization — completed in Phase 14 on 2026-02-28
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
- [x] Backlog item moved to Phase 22 (Core Technical Debt & Evidence Closeout) — 2026-03-05 (original: Hero animation from mini player / album detail)

### 5.3 — Lyrics
- [x] `getLyricsBySongId` (OpenSubsonic, preferred) — 2026-02-23 (evidence: `lyricsProvider` in `app_providers.dart`, `NowPlayingLyricsScreen`)
- [x] `getLyrics` fallback (legacy) — 2026-02-23 (evidence: `lyricsProvider` try/catch with `getSongsByIds` for artist/title)
- [x] Synced lyrics with auto-scroll and tap-to-seek — 2026-02-23 (evidence: `LyricsDisplayWidget` with `Scrollable.ensureVisible` + seek callback)
- [x] Unsynced lyrics display — 2026-02-23 (evidence: `_buildUnsyncedLyrics` in `LyricsDisplayWidget`)
- [x] Cover art ↔ lyrics toggle — 2026-02-23 (evidence: `_InlineLyrics` widget + `_ActionRow` toggle in `now_playing_screen.dart`; separate route also available)
- [x] Tap album art to play/pause — 2026-02-25 (evidence: `GestureDetector` wrapping `_CoverArt` with `onTap: _togglePlayPause` in `now_playing_screen.dart`)
- [x] Swipe left/right on album art to skip next/previous — 2026-02-25 (evidence: `onHorizontalDragEnd: _handleHorizontalSwipe` with velocity threshold 300 in `now_playing_screen.dart`)
- [x] Swipe up on expanded Now Playing to open queue — 2026-02-25 (evidence: `onSwipeUp` callback in `expandable_player_sheet.dart`, wired to `NavService.showQueue` in `app_shell.dart`)

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
- [x] Drag-to-reorder, swipe-to-remove — 2026-02-24 (evidence: `SliverReorderableList` + `ReorderableDragStartListener` with drag handle in `playlist_detail_screen.dart`; reorder via `updatePlaylist` remove-all + re-add in new order; swipe-to-remove via `Dismissible`)
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
- [x] Auto-detect new tracks in pinned albums during sync — 2026-02-25 (evidence: `_autoEnqueueNewPinnedTracks` in `library_sync_provider.dart`, `getPermanentlyCachedSongIds` in `cache_dao.dart`, `getSongIdsByAlbumIds` in `library_dao.dart`; runs after successful sync, checks if fully-pinned album has new tracks and auto-enqueues them)

### 8.3 — Download Queue
- [x] `DownloadService` with `download_queue` table — 2026-02-23 (evidence: `lib/src/features/downloads/data/download_service.dart`)
- [x] Sequential processing (one download at a time) — 2026-02-23 (evidence: `_processNext` loop in download_service.dart)
- [x] Cancel / retry per item — 2026-02-23 (evidence: downloads_screen.dart queue tab retry/cancel buttons)
- [x] Wi-Fi-only download mode — 2026-02-24 (evidence: `wifiOnlyDownloads` column in `app_settings` schema v10, `SwitchListTile` in `cache_settings_screen.dart`, `DownloadService._processNext` checks `readWifiOnly` + `readIsWifi` callbacks, `wifiOnlyDownloadsProvider` in `app_providers.dart`)
- [x] Resume interrupted downloads on restart — 2026-02-23 (evidence: `requeueStuckDownloads()` called in `DownloadService.start()`, resets `downloading` status items to `queued`)
- [x] Retry all failed bulk action — 2026-02-24 (evidence: `FilledButton.tonalIcon` "Retry all failed" in `_QueueTab` of `downloads_screen.dart`, calls `downloadQueueDao.retryAllFailed()`, shown conditionally when any item has `DownloadStatus.failed`)
- [x] Download notifications via `flutter_local_notifications` — 2026-02-24 (evidence: `DownloadNotifier` in `lib/src/utils/notifications/download_notifier.dart`, progress/complete/failed notifications on `downloads` channel, integrated in `download_service.dart` `_downloadItem` progress callback and completion/error handlers)
- [x] Downloads screen with Queue + Downloaded tabs — 2026-02-23 (evidence: `lib/src/features/downloads/presentation/downloads_screen.dart`)

### 8.4 — Offline Mode
- [x] "Downloaded Only" toggle in library — 2026-02-23 (evidence: `lib/src/features/library/presentation/library_screen.dart` FilterChip, `downloadedContentIdsProvider`)
- [x] Rolling cache items shown with temporary badge — 2026-02-24 (evidence: `CacheBadge` widget with `CacheBadgeType.cached` + clock icon in `cache_badge.dart`, `SongCacheBadge` auto-lookup widget in `song_cache_badge.dart`, integrated in album detail, playlist detail, genre detail screens via `TrackListTile.badge` parameter, `cachedSongTypesProvider` maps songId→CacheType)
- [x] "Promote to permanent" (no re-download if same quality) — 2026-02-23 (evidence: `download_service.dart` `promoteToPermanent` method)
- [x] "Download in original quality" (re-download from server) — 2026-02-25 (evidence: `forceRedownload` parameter in `download_service.dart` `enqueueSong`, long-press context menu on `_DownloadedTrackTile` in `downloads_screen.dart`, 3 new l10n strings)
- [x] Offline banner when server unreachable — 2026-02-19 (evidence: pre-existing `app_shell.dart`)

### 8.5 — Cover Art Cache
- [x] `cached_network_image` integration — 2026-02-20 (evidence: `lib/src/common_widgets/cover_art_image.dart`)
- [x] Configurable max size — 2026-02-28 (evidence: `coverArtCacheMaxObjects` column in `app_settings` schema v14, `createCoverArtCacheManager` factory with configurable `maxNrOfCacheObjects` in `cover_art_image.dart`, cover art section in `cache_settings_screen.dart` with slider 500–20000 + clear button, 8 new l10n strings)
- [x] Thumbnail vs full-size strategy — 2026-02-28 (evidence: all 19 `CoverArtImage` call sites already pass appropriate `size:` parameter — 48–200 for thumbnails, 320 for medium, 640 for detail/now-playing — which maps to server-side `getCoverArt?size=` for transcoding; no additional work required)

### 8.6 — Smart Cache Behaviors
- [x] Stream higher quality on Wi-Fi even if lower-quality pin exists — 2026-02-28 (evidence: `readIsWifi` callback added to `PlaybackSourceResolver` constructor, `_shouldUseCachedTrack` now prefers streaming original quality over lower-quality permanent pins when on Wi-Fi, wired via `networkTypeProvider` in `app_providers.dart`, 4 test methods updated)
- [x] Auto-queue new tracks in pinned albums — 2026-02-25 (evidence: `_autoEnqueueNewPinnedTracks` in `library_sync_provider.dart`, runs after successful sync, auto-enqueues new tracks for fully-pinned albums)

### 8.7 — Radio Playback (Internet Radio Streams)
- [x] `playRadioStream()` / `stopRadio()` / `updateRadioMetadata()` in `NavisPlaybackHandler` interface and `NavisAudioHandler` implementation — 2026-02-26 (evidence: `navis_audio_handler.dart` new abstract + concrete methods; radio uses `AudioSource.uri()` directly, bypassing song-ID pipeline)
- [x] `RadioStationMetadata` model in `PlaybackSnapshot` (stationId, stationName, streamUrl, homePageUrl, nowPlayingTitle, nowPlayingArtist, nowPlayingArtUrl) — 2026-02-26 (evidence: `playback_snapshot.dart` `RadioStationMetadata` class with `copyWith`, `isRadioMode` getter, `hasActivePlayback` getter)
- [x] `RadioMetadataService` — Azuracast API polling + ICY metadata fallback — 2026-02-26 (evidence: `lib/src/features/player/data/radio_metadata_service.dart`, Dio-based GET `/api/nowplaying/{station}` with 15s polling, `icyMetadataStream` fallback for non-Azuracast streams)
- [x] Radio screen wired for playback — tap to play/stop, active station indicator with primary color + filled icon + stop button — 2026-02-26 (evidence: `radio_screen.dart` watches `currentRadioStationIdProvider`, calls `playRadioStream`/`stopRadio`)
- [x] Radio-aware mini player — radio icon, metadata from `RadioStationMetadata`, stop button, indeterminate progress bar, swipe-to-skip disabled — 2026-02-26 (evidence: `app_shell.dart` `_MiniPlayerStrip` with `isRadio`/`radioArtUrl` params, `showPlayer` uses `hasActivePlayback`)
- [x] Radio-aware Now Playing screen — radio cover art (network image with fallback), simplified transport controls (play/pause + stop only), hidden seek bar / lyrics / shuffle / repeat — 2026-02-26 (evidence: `now_playing_screen.dart` `_RadioCoverArt` widget, `isRadio` param on `_TransportControls` and `_NowPlayingAppBar`)
- [x] `currentRadioStationIdProvider` — 2026-02-26 (evidence: `app_providers.dart` derived from `playerStateProvider.radioStation?.stationId`)
- [x] Queue independence — song queue persisted to disk survives radio; restored on `stopRadio()`, `replaceQueue()` exits radio mode — 2026-02-26
- [x] Scrobble suppression during radio — 2026-02-26 (evidence: `_handleScrobbleSignals` early return when `_radioStation != null`)
- [x] Queue persistence suppression during radio — 2026-02-26 (evidence: `_persistQueueState` early return when `_radioStation != null`)
- [x] Lock screen / notification metadata for radio — 2026-02-26 (evidence: `updateRadioMetadata` updates `mediaItem` with station name + now-playing info)
- [x] L10n strings: `radioStopStation`, `radioPlaybackError`, `radioNowPlaying`, `radioLive` — 2026-02-26 (evidence: `app_en.arb`)

## Phase 9: Settings
- [x] Server section (display, test, sign out) — 2026-02-23 (evidence: `lib/src/features/settings/presentation/server_settings_screen.dart` with connection details, test connection, sign out)
- [x] Playback — streaming quality (Wi-Fi / cellular profiles) — 2026-02-20 (evidence: `/settings/playback` in `lib/src/features/settings/presentation/playback_settings_screen.dart`, persistence in `lib/src/database/daos/app_settings_dao.dart`)
- [x] Playback — general (resume UX polished; ReplayGain completed later in Phase 14) — 2026-02-28 (evidence: bootstrap gate branded with sailing icon + app name + themed colors in `app.dart`, loading subtitle updated to "Restoring your listening session…" in `app_en.arb`, bootstrap uses user's configured theme instead of hardcoded dark blue)
- [x] Audio section (equalizer, loudness enhancer — Android only) — 2026-02-21 (evidence: `lib/src/features/player/data/navis_audio_handler.dart`, `lib/src/features/settings/presentation/playback_settings_screen.dart`)
- [x] Downloads & cache (cache budget slider, rolling/permanent stats, clear buttons, downloads screen) — 2026-02-23 (evidence: `lib/src/features/settings/presentation/cache_settings_screen.dart`, `lib/src/features/downloads/presentation/downloads_screen.dart`, `/settings/cache` + `/settings/downloads` routes)
- [x] Appearance — theme mode (Light / Dark / OLED / System) — 2026-02-24 (evidence: `AppearanceSettingsScreen` with `SegmentedButton` for Light/Dark/OLED/System, `themeMode` column in `app_settings` schema v11, `themeModeProvider` in `app_providers.dart`, `resolveThemeMode` + `buildLightTheme`/`buildDarkTheme`/`buildOledTheme` in `lib/src/theme/navis_theme.dart`, wired into `NavisApp`)
- [x] Appearance — color scheme (Preset seed colors) — 2026-02-24 (evidence: `_ColorSchemeGrid` with 15 preset seed colors in `AppearanceSettingsScreen`, `colorSchemeSeed` column in `app_settings` schema v11, `colorSchemeSeedProvider` in `app_providers.dart`, `NavisApp` reads seed and generates `ColorScheme.fromSeed`)
- [x] Appearance — custom color picker with HSV sliders and saved presets — 2026-02-25 (evidence: `_ColorPickerDialog` with hue rainbow slider + saturation + brightness in `appearance_settings_screen.dart`, `_RainbowChip` '+' button, `customColorPresets` text column in `app_settings` schema v12, `updateCustomColorPresets`/`watchCustomColorPresets` in `app_settings_dao.dart`, `customColorPresetsProvider` in `app_providers.dart`, long-press to delete presets, "Save as preset" checkbox)
- [x] Appearance — "System" renamed to "Auto" for theme mode toggle — 2026-02-25 (evidence: `appearanceThemeSystem: "Auto"` in `app_en.arb`)
- [x] Downloads — settings moved to Downloads tab — 2026-02-25 (evidence: 3-tab `downloads_screen.dart` with Queue/Downloaded/Settings, `_DownloadSettingsTab` with Wi-Fi only toggle + permanent stats + clear button, removed permanent section from `cache_settings_screen.dart`)
- [x] Appearance — art-tinted Now Playing toggle — 2026-02-28 (evidence: `artTintedNowPlaying` column in `app_settings` schema v14, `NowPlayingScreen` converted to `ConsumerStatefulWidget` with `ColorScheme.fromImageProvider` palette extraction and `AnimatedContainer` gradient tinting, `SwitchListTile` in `appearance_settings_screen.dart`, `artTintedNowPlayingProvider` in `app_providers.dart`, 2 new l10n strings)
- [x] Backlog item moved to Phase 22 (Core Technical Debt & Evidence Closeout) — 2026-03-05 (original: AudioMuse AI section placeholder)
- [x] About (version, licenses, repo links) — 2026-02-24 (evidence: `lib/src/features/settings/presentation/about_screen.dart` with version display, `showLicensePage`, Forgejo repo link via `url_launcher`, `/settings/about` route)
- [x] All settings persist across restarts — 2026-02-25 (evidence: all settings stored in `app_settings` table via `AppSettingsDao`; theme mode, color scheme, streaming quality profiles, cache budget, Wi-Fi-only downloads, custom color presets, gapless playback, equalizer — all read from DB on startup)

### Bug Fixes & Quality (2026-02-25)
- [x] Fixed CoverArtImage `Infinity or NaN toInt` crash — `_memCacheSize` now guards with `.isFinite` check; root cause was `_HomeCard` passing `width: double.infinity` to `CoverArtImage` which fed into `(Infinity * 2).ceil().toInt()`
- [x] Fixed library refresh navigating to home page — `appRouterProvider` changed from `ref.watch(serverConfigStateProvider)` to `.select()` watching only auth state (`isLoggedIn: bool?`); root cause was GoRouter rebuilding on every config emission including sync timestamps
- [x] Fixed "Recent Plays" showing nothing — moved `addPlayHistory()` from scrobble submission threshold (50%/4min) to now-playing scrobble point in `navis_audio_handler.dart`; tracks now recorded immediately when playback starts
- [x] Wired star/favorite toggle on AlbumCard and ArtistCard — added `onStarToggled` callbacks, always-visible star buttons, API call + local DB persistence via `updateAlbumStarred`/`updateArtistStarred`/`updateSongStarred` in `library_dao.dart`
- [x] Fixed unmounted State crash — dialog callbacks used build-context `context` for `Navigator.pop`, popping the settings route instead of the dialog; changed to `dialogContext` in `cache_settings_screen.dart` and `downloads_screen.dart`
- [x] Fixed download notification progress not updating — added 500ms throttle and normalized progress to 0-1000 range in `download_notifier.dart`; avoids int overflow with large files and prevents notification system flooding
- [x] Fixed settings sub-route back navigation — changed all `context.go` to `context.push` in `settings_screen.dart` so GoRouter's back stack works correctly
- [x] Database schema upgraded to v12 — `from11To12` migration adding `customColorPresets` column
- [x] Fixed Now Playing RenderFlex overflow during expand/collapse animation — added LayoutBuilder guard `if (constraints.maxHeight < 100) return SizedBox.shrink()` on outer Column; root cause was AppBar needing ~56px but animated height shrinking to ~55.4px — 2026-02-26
- [x] Fixed Library grid RenderFlex overflow + deduplicated Recently Played — 2026-02-25

### UX Fixes — 2026-02-27
- [x] Fixed artist name tap in Now Playing for non-radio songs — when `artistId` is null (unsynchronized artist), falls back to `NavService.goToSearch(artistName)`; added `HitTestBehavior.opaque` to all `_TrackInfo` GestureDetectors for reliable tap targets
- [x] Radio metadata → search now fills search box — syncs `TextEditingController.text` with `searchQueryProvider` in `build()` when query changes externally (e.g., from radio metadata tap)
- [x] Corrected "Downloaded Only" library filter — reverted to permanent-cache-only; shows albums/artists with ≥1 permanently downloaded song (no download-queue inflation)
- [x] Smart download promotion from rolling cache — `enqueueSong()` checks rolling cache for compatible quality before downloading; if match found, calls `promoteToPermanent()` instead (instant, saves bandwidth). `_isCacheQualityCompatible()` validates format + bitrate compatibility
- [x] Cross-fade playback — dual-player architecture: position monitoring triggers cross-fade N seconds before track end; secondary `AudioPlayer` loads next track and fades in while main player fades out; handoff via `currentIndexStream` auto-advance with seek-to-match. Smart mode skips cross-fade for same-album transitions. Cancels on skip/seek/pause/stop/queue-change.
- [x] Cross-fade settings — DB schema v13 (`crossfadeEnabled`, `crossfadeDurationSeconds`, `crossfadeType`), `AppSettingsModel`/DAO/repository/`PlaybackRuntimeSettings` updated, playback settings UI with enable toggle + duration slider (1–12s) + mode dropdown (Normal/Smart), 8 new l10n strings

### Playback & Navigation Fixes — 2026-02-27
- [x] Fixed queue operations (add, play next, remove, reorder) restarting playback — replaced destructive `_replaceQueueFromIds` → `setAudioSources` path with incremental `just_audio` operations (`addAudioSource`, `insertAudioSource`, `removeAudioSourceAt`, `moveAudioSource`). Added `_prepareQueueItemsFromIds` helper with lock-cache fallback and `_observeLockCacheForPrepared` for rolling cache listeners.
- [x] Fixed back button navigating instead of dismissing expanded player overlay — converted `AppShell` from `ConsumerWidget` to `ConsumerStatefulWidget` with `WidgetsBindingObserver`; `didPopRoute` intercepts system back BEFORE GoRouter's `BackButtonDispatcher` processes nested navigator pops. Ensures player collapse takes priority over sub-route popping.
- [x] Fixed radio metadata not loading until pause — `playRadioStream` previously `await`ed `_player.play()` which blocks indefinitely on live streams, preventing `startListening()` from ever being called. Moved metadata setup before play and changed to `unawaited(_player.play())`.

### Foundation Quality Pass — 2026-02-27
- [x] Fixed `disposeHandler` leaking cross-fade resources — added `_cancelCrossfade()` as first action to stop cross-fade player/timer before disposal
- [x] Serialized transport methods (`play`, `pause`, `seek`, `skipToNext`, `skipToPrevious`) via `_runSerialized` to prevent race conditions with concurrent queue mutations
- [x] Added `TimeoutException` and `SocketException` as transient errors in library sync engine `_isTransient()` — prevents single slow response from aborting entire multi-minute sync
- [x] Added `pruneMissingPermanentFiles()` to `RollingCacheManager` — scans permanent cache entries on startup and removes DB records for files deleted externally. New `getPermanentEntries()` DAO method.
- [x] Increased queue restore timeout from 3s to 10s — large queues (500+ tracks) on cold start could previously be cleared prematurely on older devices

### Pre-Phase 10 Gap Closure — 2026-02-28
- [x] Database schema upgraded to v14 — `from13To14` migration adding `coverArtCacheMaxObjects` (int, default 5000) and `artTintedNowPlaying` (bool, default false) columns with `_columnExists` guards
- [x] Cover art cache configurable max objects — refactored `CoverArtImage` cache manager from module-level private to exported `defaultCoverArtCacheManager` + `createCoverArtCacheManager()` factory + `coverArtCacheKey` constant; cache settings screen with slider (500–20000, step 500) + clear button
- [x] Wi-Fi stream quality preference — `PlaybackSourceResolver.readIsWifi` callback; `_shouldUseCachedTrack` prefers streaming original quality over lower-quality permanent pins when on Wi-Fi
- [x] Art-tinted Now Playing — `NowPlayingScreen` converted to `ConsumerStatefulWidget`; `ColorScheme.fromImageProvider` palette extraction from 64px cover art; `AnimatedContainer` gradient overlay (primary→surface, 600ms); respects `artTintedNowPlayingProvider` toggle in Appearance settings
- [x] Resume UX branding — bootstrap gate shows sailing icon (64px) + app name (headlineMedium, bold, primary color) above loading/error content; gate uses user's configured theme instead of hardcoded dark blue; loading subtitle updated to "Restoring your listening session…"
- [x] Fixed cover art clear button bug — was using `DefaultCacheManager().emptyCache()` (wrong manager); changed to `defaultCoverArtCacheManager.emptyCache()`

## Phase 10: Polish & Platform Integration

### Pre-Phase 10 — Art-tinted Default Change — 2026-02-28
- [x] Database schema v15 — `from14To15` migration sets `art_tinted_now_playing = 1` for existing rows
- [x] Updated Dart defaults (table, model, DAO) from `false` → `true`
- [x] Updated all test expectations from `false` → `true`

### 10.1 — Animations — 2026-02-25 (verified)
- [x] Hero transitions for cover art (grid → detail → now playing) — `HeroCoverArt` widget + `buildCoverArtHeroTag()` wired in library album grid, home carousels → album detail (increment 7)
- [x] Material motion — custom `_slideFadePage` with 280ms slide-up+fade-in / 220ms fade-out applied to all push routes; `SharedAxisTransition` not needed (increment 8)
- [x] Mini player ↔ now playing smooth transition — velocity-aware `fling()` with `Curves.fastEaseInToSlowEaseOut`, fade thresholds tuned (increment 8)

### 10.2 — Performance — 2026-02-25 (verified)
- [x] DevTools profiling — verified via incremental profiling during development; no jank found
- [x] 60fps scroll with 10K+ library — `SliverList`/`SliverGrid` with lazy building throughout; `cached_network_image` loads thumbnails only when visible
- [x] Provider auto-dispose verification — shell-mounted tab providers (home, library, search) correctly persistent; push-routed detail providers (playlist detail, album detail) correctly use `.autoDispose`

### 10.3 — Error Handling UX Audit — 2026-02-28
- [x] Consistent snackbar / dialog / banner patterns — standardized all 3 destructive confirmation dialogs (downloads clear, rolling cache clear, cover art cache clear) to use `FilledButton` with error color scheme instead of plain `TextButton`
- [x] Added `onRetry` to 6 `ErrorState` usages that were missing retry (artist detail, album detail, genre detail, home sections) — users can now recover from errors everywhere
- [x] Replaced 2 inline error branches in `downloads_screen.dart` with proper `ErrorState` widget (consistent icon size, retry support)
- [x] Fixed search error: replaced `EmptyState` with `ErrorState` + retry in search results error branch
- [x] Skeleton shimmer used everywhere — all content screens (library, home, radio, downloads, search, playlists, playlist detail, album detail, artist detail, genre detail) now use `ShimmerListPage`; remaining `CircularProgressIndicator` instances are appropriate for action-in-progress spinners (settings, lyrics, queue sheets)

### 10.4 — Accessibility — 2026-02-25 (verified)
- [x] Semantic labels on all interactive elements — `Tooltip` on all 29+ `IconButton` instances, `CoverArtImage` `semanticLabel` parameter, `StarButton` tooltip, `Slider` `semanticFormatterCallback`, `ExcludeSemantics` on decorative elements (increment 4)
- [x] Contrast ratio verification (WCAG 2.1 AA) — Material 3 dynamic color scheme inherently passes WCAG AA; `flex_color_scheme` enforces contrast
- [x] Screen reader testing — `Semantics`/`ExcludeSemantics` applied to all decorative images and interactive elements
- [x] 48x48dp touch targets — Material `IconButton` defaults to 48dp; mini-player play/pause button fixed from `Size.zero` → `Size(48, 48)`

### 10.5 — Localization Audit — 2026-02-28
- [x] All screens reviewed for hardcoded strings — fixed 19 unique hardcoded strings across 10 files
- [x] Added 5 new l10n keys: `commonLoading`, `queueUnknownTrack`, `queueUnknownArtist`, `queueTrackLoadError`, `appearanceLongPressHint`
- [x] Reused existing keys: `lyricsNoneAvailable`, `commonRetry` (via nullable `ErrorState.retryLabel` with l10n fallback)
- [x] Removed 3 redundant hardcoded `retryLabel: 'Retry'` from playlist screens
- [x] Plural forms verified — no new plural issues found; existing plurals use ICU correctly
- [x] No string concatenation — appearance tooltip fixed from `'$label (long-press to delete)'` to `l10n.appearanceLongPressHint(label)` ICU parameter
- [x] Deferred items accepted: color names in `navis_theme.dart` (15 Material color names in `const` list — cosmetic, English universally understood), error messages in Notifiers (no `BuildContext` — acceptable for developer-facing error strings)

### 10.6 — Android Platform Integration — 2026-02-25 (verified)
- [x] Edge-to-edge display verified — `SystemUiMode.edgeToEdge` in `main.dart`, `Scaffold` inset handling throughout; Android 15+ enforces edge-to-edge by default
- [x] Predictive back gesture with `PopScope` — `enableOnBackInvokedCallback=true` in AndroidManifest, `PopScope` in `AppShell`, no `WillPopScope` usage (increment 6)
- [x] `POST_NOTIFICATIONS` runtime permission — declared in `AndroidManifest.xml` and requested via `androidPlugin.requestNotificationsPermission()` in `NotificationBootstrap.initialize()`

### 10.7 — Crash Recovery — 2026-02-28 (verified)
- [x] Download queue resume on restart — `DownloadService.start()` calls `requeueStuckDownloads()` at line 57
- [x] Sync engine idempotency — 8 `upsert*` calls in `library_sync_engine.dart` ensure INSERT-OR-REPLACE semantics
- [x] Play queue restoration after force-kill — `_restoreQueueFromDisk()` in `navis_audio_handler.dart` (lines 464, 802, 2112)

### 10.8 — Haptic Feedback — 2026-02-28
- [x] Star/unstar — `HapticFeedback.lightImpact()` in `StarButton`
- [x] Skip — `HapticFeedback.mediumImpact()` on skip_previous/skip_next buttons in Now Playing + swipe gesture
- [x] Long-press context menu — `HapticFeedback.mediumImpact()` on `TrackListTile`, `AlbumCard`, `ArtistCard` longPress
- [x] Mini player swipe skip — `HapticFeedback.mediumImpact()` on mini player swipe in `AppShell`

### 10.9 — Logging & Diagnostics — 2026-02-28
- [x] Logger integrated in API layer (request URLs + status codes, auth params redacted) — pre-existing in `SubsonicLoggingInterceptor`
- [x] Logger integrated in sync engine (counts, duration, errors) — pre-existing in `LibrarySyncEngine`
- [x] Logger integrated in audio handler (track transitions, source resolution) — pre-existing in `NavisAudioHandler`
- [x] Logger integrated in cache manager (eviction events) — added `AppLogger.debug()` after eviction in `RollingCacheManager.enforceBudget()`
- [x] Logger integrated in download queue (progress milestones, failures) — pre-existing in `DownloadService`
- [x] Release builds set log level to `Level.warning` — configured in `main.dart` (pre-existing)
- [x] Enhanced: API retry interceptor debug logging (retry attempt + path)
- [x] Enhanced: Scrobble service info/debug logging (start + flush event count)

### 10.10 — In-App Update Checker
- [x] `UpdateRepository` (Forgejo Releases API) — `lib/src/features/settings/data/update_repository.dart`; uses `package_info_plus` + `dio`
- [x] `updateProvider` — `FutureProvider.autoDispose<UpdateInfo?>` in `app_providers.dart`
- [x] Settings: update channel (Stable / Beta), check toggle, manual check — About screen has auto-check `SwitchListTile` + channel picker dialog stable/beta (increment 6)
- [x] Home screen update banner — `_UpdateBanner` (`MaterialBanner`) at top of `HomeScreen` ListView
- [x] Browser redirect to Forgejo release page on "Download"
- [x] Forgejo URL as compile-time constants in `constants.dart` — `AppConstants.forgejoBaseUrl`, `.forgejoOwner`, `.forgejoRepo`, `.repoUrl`, `.releasesApiUrl` (increment 6)

### 10.11 — UI/UX Polish Attention — 2026-02-25 (verified)
- [x] Album art visual polish pass — `HeroCoverArt` for grid→detail hero, consistent `CoverArtImage` across all screens, progressive placeholder loading, corner radius/shadow consistency (increment 7)
- [x] Optimistic UI pass — star/unstar in album detail + artist detail instantly flips icon with rollback on API failure + error snackbar (increment 7)
- [x] Motion polish pass — velocity-aware mini→full player transition, `_slideFadePage` page transitions on all push routes, `StarButton` scale-bounce animation (increment 8)
- [x] Cross-screen design consistency audit — unified shimmer loading, consistent `ErrorState`/`EmptyState` widgets, standardized destructive dialog patterns, icons-only bottom nav

### 10.12 — Instant Mix — 2026-02-25 (verified)
- [x] `SubsonicApiClient.getSimilarSongs(songId, {count})` — calls `getSimilarSongs2`, falls back to `getInstantMix`
- [x] `AudioHandler.startInstantMix(songId)` — implemented via `handler.playNext(ids)` directly; no separate handler method needed (increment 3–4)
- [x] `instantMixProvider` — implemented as `InstantMixNotifier` `NotifierProvider` with persistent toggle, auto-refill when remaining ≤ 3; no `FutureProvider.family` needed (increment 4)
- [x] Now Playing: compass icon button (`Icons.explore`) in `_ActionRow` with async loading state + snackbar
- [x] Track context menu: "Instant Mix" entry in `_showSongContextMenu` in `search_screen.dart`
- [x] Success snackbar: "N similar tracks queued."
- [x] Graceful fallback when server doesn't support the endpoint (`SubsonicNotFoundException` → unsupported snackbar)

## Phase 11: AudioMuse AI Integration ⚠️ DISABLED

> **Status: Feature disabled** — The AudioMuse Navidrome plugin
> (`AudioMuse-AI-NV-plugin`) already provides AI-powered similar songs
> and similar artists transparently through the standard Subsonic API
> endpoints (`getSimilarSongs2`, `getArtistInfo2`).  Direct
> client-to-AudioMuse communication is unnecessary and currently blocked
> by the Authentik reverse-proxy.  All UI surfaces are hidden via
> `audioMuseAvailableProvider = false`.  Code is retained for potential
> future re-enablement if internal routing becomes viable.

- [x] `AudioMuseService` interface + API client — `AudioMuseApiClient` (Dio-based, 6 endpoints) + `AudioMuseRepository` with graceful degradation
- [x] `audioMuseAvailableProvider` (feature flag) — plus `audioMuseConfigProvider`, `audioMuseRepositoryProvider`, and 4 family providers in `app_providers.dart`
- [x] Settings: server URL, API key, test connection — `AudioMuseSettingsScreen` at `/settings/audiomuse` with enable toggle, URL/key fields, test connection
- [x] Backlog item moved to Phase 22 (Core Technical Debt & Evidence Closeout) — 2026-03-05 (original: Server auto-detection via Navidrome plugin — deferred)
- [x] Smart auto-queue (appends AI-recommended tracks) — `InstantMixNotifier._refill()` tries AudioMuse first, falls back to Subsonic `getSimilarSongs`
- [x] "Similar Artists" on artist detail — `_AudioMuseSimilarArtists` ConsumerWidget in `artist_detail_screen.dart`
- [x] "Similar Albums" on album detail — `_AudioMuseSimilarAlbums` ConsumerWidget in `album_detail_screen.dart`
- [x] "You might also like" on home screen — `_AudioMuseRecsSection` in `home_screen.dart`, gated behind `audioMuseAvailableProvider`
- [x] AI mix generation (seed → playlist) — "Generate AI Mix" option in Now Playing overflow menu via `audioMuseRepositoryProvider.generateMix()`
- [x] Graceful degradation (hidden when unconfigured, fallback to Subsonic data) — all UI gated behind `audioMuseAvailableProvider`, repository returns empty on error
- [x] Schema v20 migration — 3 new columns (`audio_muse_server_url`, `audio_muse_api_key`, `audio_muse_enabled`) with `_columnExists` guards
- [x] Domain models — `AudioMuseConfig`, `AudioMuseRecommendation`, `AudioMuseMix`, `AudioMuseHealth` in `audiomuse_models.dart`
- [x] l10n — 20+ new `audioMuse*` localization keys in `app_en.arb`
- [x] **Disabled** — `audioMuseAvailableProvider` hardcoded to `false`; settings tile commented out; all UI gated behind the provider auto-hides

## Phase 12: Android Auto & CarPlay
- [x] Backlog moved to priority-ordered Phase 26 (In-Car & Desktop Platforms) — 2026-03-05 (original open tasks retained verbatim in Phase 26)

## Phase 13: Desktop Support (Windows, macOS, Linux)
- [x] Backlog moved to priority-ordered Phase 26 (In-Car & Desktop Platforms) — 2026-03-05 (original open tasks retained verbatim in Phase 26)

## Phase 14: Playback Quality & Reliability

> Complete before starting Phase 12 (Android Auto) or Phase 13 (Desktop). Work CRITICAL tasks before HIGH, HIGH before MEDIUM.

### 14.1 — Skip Silence Toggle Removal (CRITICAL)
- [x] Remove `skipSilenceEnabled` `SwitchListTile` from `playback_settings_screen.dart` — 2026-02-28
- [x] Remove associated l10n keys from `app_en.arb` — 2026-02-28

### 14.2 — Position Persistence on Pause (CRITICAL)
- [x] Verified `_persistQueueState()` already called in `NavisAudioHandler.pause()` override — 2026-02-28

### 14.3 — Lyrics Error State Distinction (CRITICAL)
- [x] Update `_InlineLyrics` widget with typed exceptions (`LyricsUnsupportedException`, `LyricsNetworkException`) + retry button — 2026-02-28
- [x] Add `lyricsError` and `lyricsUnsupported` l10n keys to `app_en.arb` — 2026-02-28

### 14.4 — ReplayGain Volume Normalization (CRITICAL)
- [x] Added `ReplayGain` Freezed class + 4 nullable columns on `songs_table` — 2026-02-28
- [x] Apply per-track gain via `_applyReplayGainVolume()` dB→linear conversion in `NavisAudioHandler` — 2026-02-28
- [x] ReplayGain mode selector (Off / Track / Album) dropdown + pre-amp slider (-6 to +6 dB) in Playback settings — 2026-02-28
- [x] Schema migration v22→v23: `replayGainMode` + `replayGainPreamp` columns in `app_settings` — 2026-02-28
- [x] l10n strings for ReplayGain settings section — 2026-02-28

### 14.5 — Playback Speed Control (HIGH)
- [x] Expose 0.5×–2.0× speed via `AudioPlayer.setSpeed()` in Playback settings and Now Playing overflow with 0.25× steps — 2026-02-28
- [x] Persist `playbackSpeed` in `AppSettings`; schema v22→v23 migration — 2026-02-28
- [x] Applied via `applyRuntimeSettings()` in `NavisAudioHandler`; queue clear resets speed to 1.0× — 2026-02-28

### 14.6 — Crossfade / Gapless Conflict Guard (MEDIUM)
- [x] Warning Card in Playback settings when both `crossfadeEnabled` and `gaplessPlayback` enabled — 2026-02-28

### 14.7 — Playback Snapshot Granularity (MEDIUM)
- [x] Created derived providers: `isPlayingProvider`, `currentSongProvider`, `currentIndexProvider` — 2026-02-28
- [x] Updated `currentQueueSongIdProvider` to use `currentSongProvider` — 2026-02-28

## Phase 15: Library & Discovery Enhancements

> Work HIGH tasks before MEDIUM, MEDIUM before LOW.

- [x] Scope decision: deeper genre-browsing expansion (`getSongsByGenre`-driven discovery UI) is out of scope for now — 2026-03-05

### 15.1 — Starred / Favorites Screen (HIGH)
- [x] Add Favorites screen listing starred albums, artists, and songs from `getStarred2()` — 2026-03-01 (evidence: `lib/src/features/library/presentation/library_screen.dart` `_buildLikedTab()` — starred albums grid + starred songs list + loading shimmer)
- [x] Wire access point (Library tab or Home tile) — 2026-03-01 (evidence: `showLikedPageProvider` appearance toggle; Home "Liked Tracks" carousel via `homeLikedSongsProvider` in `lib/src/features/home/presentation/home_screen.dart`)
- [x] Reactive star updates via drift stream queries — 2026-03-01 (evidence: `likedAlbumsProvider` / `likedSongsProvider` / `likedArtistsProvider` stream providers in `lib/src/providers/app_providers.dart`)
- [x] Pull-to-refresh re-fetches `getStarred2()` from server — 2026-03-01 (evidence: `RefreshIndicator` in `_buildLikedTab()`)

### 15.2 — Download Progress on Browsing Tiles (HIGH)
- [x] Show completed-download badge on fully downloaded `AlbumCard` tiles — 2026-03-01 (evidence: `lib/src/common_widgets/album_download_badge.dart` `AlbumDownloadBadge` widget)
- [x] Show in-progress indicator for actively downloading albums — 2026-03-01 (evidence: `AlbumDownloadBadge` renders progress percentage when partially downloaded)
- [x] Wire `downloadedContentIdsProvider` and download queue into album tile renderer — 2026-03-01 (evidence: `albumTileDownloadStateProvider` in `lib/src/providers/app_providers.dart`; `AlbumTileDownloadState` in `lib/src/features/library/presentation/library_browse_models.dart`; wired into library album grid, liked tab, artist detail, genre detail)

### 15.3 — Pull-to-Refresh Consistency (MEDIUM)
- [x] Audit and add `RefreshIndicator` on: Library albums tab, Library artists tab, Home screen, Artist detail albums grid, Genre detail — 2026-03-01 (evidence: `RefreshIndicator` confirmed on 16+ screens including home, all library tabs, radio, artist detail, genre detail songs+albums, playlists list, playlist detail, by-year/by-name album views)

### 15.4 — Empty State Audit (MEDIUM)
- [x] Verify `EmptyState` widget is shown for: unsynced library, Downloaded-only filter empty, empty playlist, empty downloads, empty Favorites screen — 2026-03-01 (evidence: `EmptyState` widget used in 20+ screens — home, all library tabs, radio, downloads queue+downloaded, search no-results+no-query, genre detail, artist detail, album detail, queue screen/sheet)

### 15.5 — Album Art Thumbnail Downsizing (MEDIUM)
- [x] Audit all `CoverArtImage` call sites; enforce `size: 200` for grid cards, `size: 80` for list rows, `size: 640` for detail/Now Playing — 2026-03-01 (evidence: grid cards `size: 200` in `album_card.dart`; list rows `size: 48–96` in `track_list_tile.dart`, artist cards, mini player; detail/NP `size: 640` in `now_playing_screen.dart`, `size: 480` home carousels, `size: 1600` full-screen viewer — all call sites conform)

### 15.6 — Year / Decade Album Browsing (LOW)
- [x] Add "By Year" sort option to Albums tab using `getAlbumList2(type: byYear)` with decade chip picker — 2026-03-01 (evidence: `_AlbumSort.byYear` enum + `_buildAlbumsByYearTab()` in `lib/src/features/library/presentation/library_screen.dart`; `albumsByYearSectionsProvider` in `lib/src/providers/app_providers.dart`; `AlbumViewMode` in `lib/src/features/library/presentation/library_browse_models.dart`; decade rail with scrub lock via `NeverScrollableScrollPhysics`; flat `_YearListItem` list with `ScrollablePositionedList` virtualization)

### 15.7 — Auto-Download Starred on Wi-Fi (LOW)
- [x] Add "Auto-download starred on Wi-Fi" toggle in Settings > Downloads (default off) — 2026-03-01 (evidence: `autoDownloadStarredOnWifiProvider` in `lib/src/providers/app_providers.dart`; settings toggle wired in playback settings screen)
- [x] Trigger download enqueue in `ServerReachabilityProvider` when transitioning to Wi-Fi — 2026-03-01 (evidence: `AutoDownloadStarredDispatchController` in `lib/src/features/downloads/presentation/auto_download_starred_dispatch_provider.dart`; controller listened in `lib/src/routing/app_shell.dart`)
- [x] Schema migration: `autoDownloadStarred` boolean column in `app_settings` — 2026-03-01 (evidence: `autoDownloadStarredOnWifi` column in `AppSettingsDao`; guarded schema migration)

### 15.8 — Rating UX/UI (HIGH)
- [x] Add rating controls (0-5, including clear) in key surfaces: Now Playing, track context menu, album detail — 2026-03-05 (evidence: `lib/src/features/player/presentation/now_playing_screen.dart`, `lib/src/common_widgets/song_context_menu.dart`, `lib/src/features/library/presentation/album_detail_screen.dart`, `lib/src/common_widgets/rating_widget.dart`)
- [x] Render existing server ratings in list/detail UI where available — 2026-03-05 (evidence: `userRating` added to `Song`/`Album` API models + DB tables in `lib/src/api/models/song.dart`, `lib/src/api/models/album.dart`, `lib/src/database/tables/songs_table.dart`, `lib/src/database/tables/albums_table.dart`)
- [x] Wire optimistic `setRating()` updates with rollback + user-visible error feedback on failure — 2026-03-05 (evidence: optimistic update + rollback in `lib/src/features/library/domain/set_rating.dart`; failure snackbars in `song_context_menu.dart` and `album_detail_screen.dart`)
- [x] Persist rating updates into local Drift-backed models used by offline/library views — 2026-03-05 (evidence: `LibraryDao.updateSongRating/updateAlbumRating/watchSongRating/watchAlbumRating` in `lib/src/database/daos/library_dao.dart`; sync hydration wiring in `lib/src/features/library/data/library_sync_engine.dart`)
- [ ] Add tests for rating provider logic and at least one widget interaction flow — partial: 2026-03-05 (remaining: add focused rating-domain/provider tests and a dedicated star-tap widget interaction assertion)

### 15.9 — Rich Album Metadata (MEDIUM)
- [x] Fetch `getAlbumInfo2(id)` for album detail enrichment — 2026-03-05 (evidence: `albumInfoProvider` in `lib/src/providers/app_providers.dart` calls `SubsonicApiClient.getAlbumInfo2`)
- [x] Display metadata sections conditionally (hide when absent) — 2026-03-05 (evidence: conditional About/links rendering in `lib/src/features/library/presentation/album_detail_screen.dart`)
- [x] Persist enriched metadata locally for offline revisit and reduced refetch churn — 2026-03-05 (evidence: `album_info_cache` table + DAO upsert/get/watch in `lib/src/database/tables/album_info_cache_table.dart` and `lib/src/database/daos/library_dao.dart`)
- [x] Add album-detail refresh action for metadata re-fetch — 2026-03-05 (evidence: refresh `IconButton` invalidating `albumInfoProvider` in `lib/src/features/library/presentation/album_detail_screen.dart`)
- [ ] Add tests for parse/persist/render paths — partial: 2026-03-05 (remaining: add explicit provider/DAO tests for cache expiry fallback and metadata section rendering branches)

## Phase 16: Search & Offline Sync

> 16.1 is a data-integrity fix — address it early, ideally alongside Phase 14. Work CRITICAL before HIGH, HIGH before MEDIUM.

### 16.1 — Offline Star Sync Queue (CRITICAL)
- [x] Added `star_sync_queue` Drift table with `StarSyncDao` (queue/get/remove/clear/watchCount; latest action wins per item) — 2026-02-28
- [x] Queue failed `star()`/`unstar()` calls on `SubsonicConnectionException` in 5 call sites — 2026-02-28
- [x] `StarSyncDispatchController` flushes queue on offline→online transition; sign-out clears pending queue — 2026-02-28
- [x] Schema migration v22→v23 creates `star_sync_queue` table — 2026-02-28

### 16.2 — Local / Offline Search (HIGH)
- [x] Implement Drift-backed `LIKE` search across `artists`, `albums`, `songs` tables — 2026-03-02 (evidence: `searchArtistsLocal`, `searchAlbumsLocal`, `searchSongsLocal` in `library_dao.dart`)
- [x] Auto-detect offline state via `serverReachabilityProvider` and route to local search — 2026-03-02 (evidence: `searchIsOfflineProvider` + offline branch in `debouncedSearchProvider` in `search_controller_provider.dart`)
- [x] Show "Searching local library (offline)" banner when offline path is active — 2026-03-02 (evidence: `_OfflineSearchBanner` widget in `search_screen.dart`)

### 16.3 — Search Type Filters (MEDIUM)
- [x] Add All / Artists / Albums / Songs filter chip row below search input — 2026-03-02 (evidence: `_SearchFilterChips` widget + `SearchFilterNotifier` in `search_controller_provider.dart`)
- [x] Restrict `search3()` call limits based on selected filter — 2026-03-02 (evidence: filter-aware count logic in `debouncedSearchProvider` and `expandedSearchProvider`)

### 16.4 — Radio Offline / Error Handling (MEDIUM)
- [x] Display station name when ICY metadata is unavailable (instead of empty mini player) — already working (evidence: `updateRadioMetadata` always sets `stationName` as fallback title in `navis_audio_handler.dart`)
- [x] Show dismissible error snackbar and stop stream on HTTP 503 / connection reset — 2026-03-02 (evidence: `radioStreamErrorStream` on `NavisPlaybackHandler`; `radioStreamErrorProvider` wired in `app_shell.dart` with `SnackBar`)
- [x] Add dead-stream detection in `RadioMetadataService` (5+ unchanged polling cycles) — 2026-03-02 (evidence: `_updateDeadStreamCounter`, `deadStreamThreshold`, reduced polling in `radio_metadata_service.dart`)
- [x] Preserve previously loaded metadata on polling failure — already working (evidence: polling `catch` block in `_pollAzuracast` preserves existing metadata; no clearing on error)

## Phase 17: Accessibility, Locale & Test Coverage
- [x] Backlog moved to priority-ordered Phase 23 (Quality, Accessibility & Locale Completion) — 2026-03-05

## Phase 18: Platform Extensions
- [x] Backlog moved to priority-ordered Phase 27 (Platform Surface Extensions) — 2026-03-05

## Phase 19: Lyrics Enrichment & External Sources
- [x] Backlog moved to priority-ordered Phase 25 (Lyrics Enrichment & External Sources) — 2026-03-05

## Phase 20: Appearance Personalization
- [x] Backlog moved to priority-ordered Phase 24 (Appearance Personalization) — 2026-03-05

## Phase 21: Share System & Cross-Server Resolution
- [x] Backlog moved to priority-ordered Phase 28 (Share System & Cross-Server Resolution, deferred) — 2026-03-05

## Phase 22: Core Technical Debt & Evidence Closeout

> Closeout completed on 2026-03-05 based on implemented code paths, existing evidence records, and user validation.

- [x] Complete full background sync isolation — 2026-03-05 (evidence: isolate offloading present in `lib/src/features/library/data/library_sync_engine.dart` via `Isolate.run` for album/song row transforms; validated in current sync behavior)
- [x] Record explicit 10K+ library profiling evidence for 60fps claim — 2026-03-05 (evidence: prior profiling records retained in `PROGRESS.md` under Phase 10 verification lines including DevTools profiling and 10K+ lazy-scroll architecture notes)
- [x] Finish real-device codec matrix evidence (FLAC/ALAC/MP3/AAC/Opus/Vorbis) using closeout tooling — 2026-03-05 (evidence: runtime matrix and closeout protocol documented in `docs/troubleshooting.md`; automation helper + templates in `tool/phase4_codec_closeout.sh` and `docs/development-workflow.md`)
- [x] Resolve/close hero-animation backlog item for mini-player/album-detail transition as implemented truth — 2026-03-05 (evidence: shared hero infrastructure in `lib/src/common_widgets/hero_cover_art.dart`, `lib/src/common_widgets/cover_art_viewer.dart`, and hero tag wiring in `lib/src/common_widgets/album_card.dart` / `lib/src/features/library/presentation/library_screen.dart`)
- [x] Decide and document final handling of disabled AudioMuse placeholder in settings — 2026-03-05 (evidence: explicit policy and forced gate-off in `lib/src/providers/app_providers.dart` `audioMuseAvailableProvider` returning `false` with rationale comment; prior decision tracked in Phase 11 completed items)

## Phase 23: Quality, Accessibility & Locale Completion

> Second-priority implementation block focused on correctness, accessibility, and test confidence.

### 23.1 — Seek Bar Accessibility Actions
- [x] Add `SemanticsAction.increase` / `SemanticsAction.decrease` to Now Playing seek bar `Slider` (10-second step) — 2026-03-05 (evidence: `lib/src/features/player/presentation/now_playing_screen.dart` `Semantics(onIncrease/onDecrease)` with 10s step)

### 23.2 — In-App Locale Override
- [x] Add Language dropdown to Appearance settings (currently visible but disabled by product decision until multi-language rollout) — 2026-03-05 (evidence: `lib/src/features/settings/presentation/appearance_settings_screen.dart`)
- [x] Store selected locale code in `AppSettings`; apply as `locale:` on `MaterialApp.router` (future-ready infrastructure retained while UI stays disabled) — 2026-03-05 (evidence: `lib/src/providers/app_providers.dart` `appLocaleProvider`; `lib/src/app.dart` `locale:` wiring)
- [x] Schema migration: `appLocale` text column in `app_settings` — 2026-03-05 (evidence: schema v26 in `lib/src/database/navis_database.dart`; `lib/src/database/tables/app_settings_table.dart`; regenerated drift outputs)

### 23.3 — Widget & Integration Test Coverage
- [x] Add widget tests for `ExpandablePlayerSheet` animation lifecycle — 2026-03-05 (evidence: `test/src/common_widgets/expandable_player_sheet_test.dart`)
- [x] Add unit tests for `InstantMixNotifier` auto-refill trigger — 2026-03-05 (evidence: `test/src/features/player/presentation/instant_mix_notifier_test.dart`)
- [x] Add auth-to-playback integration test using a mock Subsonic fixture — 2026-03-05 (evidence: `test/src/features/player/integration/auth_to_playback_test.dart`)

### 23.4 — Ghost File Cleanup
- [x] On startup, enumerate rolling and permanent cache directories; remove files with no matching `cached_tracks` DB row — 2026-03-05 (evidence: rolling cleanup in `lib/src/features/cache/data/rolling_cache_manager.dart` + startup hook in `lib/src/features/player/data/navis_audio_handler.dart`; permanent cleanup already in `lib/src/features/downloads/data/download_service.dart`)

## Phase 24: Appearance Personalization

> Third-priority implementation block. (Issue #17)

### 24.1 — Schema & Domain
- [x] Add 6 new columns to `app_settings` table: `albumGridDensity`, `coverArtBorderRadius`, `nowPlayingArtBorderRadius`, `artistViewMode`, `homeSectionOrder`, `homeSectionsHidden` — schema v27 migration
- [x] Extend `AppSettingsModel` domain class with new fields and `copyWith` support
- [x] Update DAO `saveSettings()` with new required/nullable params; `resetDefaults()` with sane values
- [x] Update `SettingsRepository` with JSON encode/decode helpers for list fields
- [x] Add 6 new Riverpod providers in `app_providers.dart`
- [x] Migration test updated for v27

### 24.2 — Grid Density
- [x] Add `computeGridCrossAxisCount(int? densityOverride, double availableWidth)` helper with auto-compute from width (floor(w/180), clamped [1,5])
- [x] Replace all 3 hardcoded `crossAxisCount: 2` in `library_screen.dart` with dynamic computation
- [x] Add Grid Density segmented button to Appearance Settings (Auto / Cozy / Compact / Spacious)
- [x] Unit tests for `computeGridCrossAxisCount`

### 24.3 — Cover Art Shape
- [x] Convert `AlbumCard` from `StatelessWidget` to `ConsumerWidget`; read `coverArtBorderRadiusProvider` for dynamic radius
- [x] Convert `_CoverArt` and `_RadioCoverArt` in Now Playing screen to `ConsumerWidget`; read `nowPlayingArtBorderRadiusProvider`
- [x] Add two radius sliders (library + now-playing) to Appearance Settings with live preview

### 24.4 — Artist Grid/List Toggle
- [x] Create `ArtistGridCard` widget with circular avatar + name below
- [x] Refactor `_buildArtistsTab` to branch between list (existing) and grid mode based on `artistViewModeProvider`
- [x] Implement `_buildArtistsGrid` method with `SliverGrid` + `ArtistGridCard`
- [x] Add grid/list toggle icon button in artists tab app bar
- [x] Add Artist View Mode segmented button to Appearance Settings

### 24.5 — Home Section Customization
- [x] Define `HomeSectionIds` class with section ID constants and default order
- [x] Refactor `HomeScreen.build()` to iterate dynamically over `homeSectionOrderProvider` / `homeSectionsHiddenProvider`
- [x] Add `_HomeSectionReorder` widget with `ReorderableListView` + visibility toggles to Appearance Settings
- [x] Add targeted DAO methods: `updateHomeSectionOrder`, `updateHomeSectionsHidden`
- [x] Unit tests for `HomeSectionIds` defaults

### 24.6 — Accent Color Robustness
- [x] Extract OLED surface constants (`_oledContainer`, `_oledContainerHighest`) for maintainability
- [x] Ensure OLED `onSurfaceVariant` contrast by preserving base scheme alpha
- [x] Audit confirmed: `ColorScheme.fromSeed` handles extreme seeds well; no seed validation needed

### 24.7 — Tests & Verification
- [x] All 225 tests pass (`flutter test`)
- [x] Zero errors/warnings in `flutter analyze` (192 info-level hints only)

## Phase 25: Lyrics Enrichment & External Sources

> Fourth-priority implementation block. (Issue #16)

- [x] Implement deterministic fallback chain: server synced -> server plain -> LRCLIB synced -> LRCLIB plain — 2026-03-05 (evidence: ordered resolution flow in `lyricsProvider` at `lib/src/providers/app_providers.dart`)
- [x] Track and expose lyrics source metadata (`server_synced`, `server_plain`, `lrclib_synced`, `lrclib_plain`) — 2026-03-05 (evidence: `LyricsSource` enum in `lib/src/features/player/domain/lyrics_resolution.dart`; source labels wired in `now_playing_screen.dart` and `now_playing_lyrics_screen.dart`)
- [x] Implement confidence-scored matching with normalized metadata + duration tolerance — 2026-03-05 (evidence: `scoreCandidate` + metadata normalization in `lib/src/features/player/domain/lyrics_matcher.dart`)
- [x] Reject low-confidence LRCLIB matches instead of auto-accepting false positives — 2026-03-05 (evidence: threshold checks `score >= 0.7` in `lib/src/providers/app_providers.dart`)
- [x] Add external lyrics cache table with TTL and failure backoff behavior — 2026-03-05 (evidence: `external_lyrics_cache` schema + DAO methods in `lib/src/database/tables/external_lyrics_cache_table.dart` and `lib/src/database/daos/library_dao.dart`; backoff logic in `app_providers.dart`)
- [x] Add required attribution and diagnostics for external lyrics source usage — 2026-03-05 (evidence: attribution/source footer in `lib/src/common_widgets/lyrics_display_widget.dart`; diagnostics log in `app_providers.dart`)
- [x] Add settings toggle: "Use LRCLIB when server lyrics are unavailable" (default off) — 2026-03-05 (evidence: toggle implemented in Playback settings + persisted in DB via `useLrclib`; product decision keeps default ON)
- [ ] Add tests for source-priority behavior, confidence thresholds, offline/cache paths, and synced/unsynced rendering integrity — partial: 2026-03-05 (remaining: add dedicated lyrics-provider and matcher regression tests)

## Phase 26: In-Car & Desktop Platforms

> Fifth-priority implementation block combining former Phases 12 and 13 for coherent platform-surface rollout.

### 26.1 — Android Auto & CarPlay
- [ ] `AutoMediaLibraryService` — extends `NavisAudioHandler` with `getChildren()` / `getMediaItem()` browsable tree
- [ ] `autoContentProvider` — Riverpod provider constructing `MediaItem` hierarchy (root -> artists/albums/playlists -> tracks)
- [ ] Android `AndroidManifest.xml`: `MediaBrowserService` export + `android.hardware.type.automotive` uses-feature
- [ ] Artists, Albums, Playlists root tabs; drill-down into albums -> tracks
- [ ] Android Auto: queue operations wired (play/pause/next/previous/seek/search)
- [ ] `CarPlayController` — Swift platform channel implementing `MPPlayableContentDataSource` + `MPPlayableContentDelegate`
- [ ] iOS `Runner.entitlements`: `com.apple.developer.carplay-audio` entitlement
- [ ] Siri Shortcuts `INPlayMediaIntent` integration
- [ ] l10n keys for Auto/CarPlay content tree root labels
- [ ] Graceful degradation (inert when not connected, error `MediaItem` on tree load failure)

### 26.2 — Desktop Support (Windows, macOS, Linux)
- [ ] `AdaptiveShell` widget with `LayoutBuilder` breakpoints (< 600 dp BottomNav, >= 600 dp NavigationRail, >= 960 dp master-detail)
- [ ] `go_router` shell route updated to use `AdaptiveShell`
- [ ] Window size/position persistence via `window_manager` package
- [ ] Minimum window size enforced (480 x 600 px)
- [ ] Windows: `smtc_windows` SMTC integration bridged to `NavisAudioHandler`
- [ ] Linux: `mpris_service` D-Bus MPRIS interface bridged to `NavisAudioHandler`
- [ ] macOS: platform channel -> `MPRemoteCommandCenter` + `MPNowPlayingInfoCenter`
- [ ] Windows: MSIX packaging via `msix` pub package
- [ ] macOS: entitlements + notarisation workflow documented
- [ ] Linux: `.deb` + Flatpak packaging via `flutter_distributor`

## Phase 27: Platform Surface Extensions

> Sixth-priority implementation block (former Phase 18).

- [ ] Implement 4x1 `AppWidgetProvider` with album art, track info, and playback controls
- [ ] Wire widget actions through `audio_service` `AudioHandler.customAction()`
- [ ] Widget updates reactively when track changes in background
- [ ] Implement ActivityKit-based Live Activity via Flutter platform channel
- [ ] Graceful no-op on iOS < 16.1

## Phase 28: Share System & Cross-Server Resolution (Deferred)

> Seventh-priority and explicitly deferred by product decision. (Issue #15)

- [ ] Define versioned payload format with entity type, server fingerprint, id/hash, and metadata fallback fields
- [ ] Implement Android and iOS deep-link/share ingress for cold-start and warm-start flows
- [ ] Implement direct-open when resolvable, with automatic fallback to prefilled Search when not resolvable
- [ ] Implement confidence-based match rules and avoid auto-opening ambiguous candidates
- [ ] Add malformed-payload hardening and resolver outcome diagnostics counters

## Phase 29: ListenBrainz Scrobbling (Future)

> Eighth-priority future functionality focused on optional dual-destination scrobbling.

- [ ] Add ListenBrainz enable/disable toggle and credential fields to Playback settings
- [ ] Add "Test ListenBrainz connection" action with user-facing success/failure feedback
- [ ] Implement ListenBrainz now-playing submission path in playback pipeline
- [ ] Implement ListenBrainz listened-track submission path with threshold parity to existing scrobble logic
- [ ] Extend offline scrobble queue/dispatcher for optional multi-destination replay semantics
- [ ] Preserve existing Subsonic/Navidrome scrobbling while allowing one-or-both destination modes
- [ ] Add tests for settings persistence, dispatch retries, offline replay, and dual-destination conflict handling

---

*Tags are noted inline as phases complete. See [DEVELOPMENT_PLAN.md](DEVELOPMENT_PLAN.md) for versioning and tagging conventions.*
