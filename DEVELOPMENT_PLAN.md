# Navis Development Plan

A Flutter-based Subsonic/OpenSubsonic music player client targeting Android and iOS, built primarily with agentic AI assistance. Licensed under GPL-3.0.

---

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Stack Validation (2026-02-18)](#stack-validation-2026-02-18)
- [SDK & Platform Requirements](#sdk--platform-requirements)
- [Git Strategy & Releases](#git-strategy--releases)
- [Execution Workflow](#execution-workflow)
- [Core Dependencies](#core-dependencies)
- [Project Structure](#project-structure)
- [Phase 0: Project Bootstrap & Tooling](#phase-0-project-bootstrap--tooling)
- [Phase 1: Core Infrastructure](#phase-1-core-infrastructure)
- [Phase 2: Authentication & Server Setup](#phase-2-authentication--server-setup)
- [Phase 3: Library Browsing & Metadata Sync](#phase-3-library-browsing--metadata-sync)
- [Phase 4: Audio Playback Engine](#phase-4-audio-playback-engine)
- [Phase 5: Now Playing & Lyrics](#phase-5-now-playing--lyrics)
- [Phase 6: Search](#phase-6-search)
- [Phase 7: Playlists](#phase-7-playlists)
- [Phase 8: Offline & Cache Management](#phase-8-offline--cache-management)
- [Phase 9: Settings](#phase-9-settings)
- [Phase 10: Polish & Platform Integration](#phase-10-polish--platform-integration)
- [Phase 11: AudioMuse AI Integration](#phase-11-audiomuse-ai-integration)
- [Phase 12: Android Auto & CarPlay](#phase-12-android-auto--carplay)
- [Phase 13: Desktop Support (Windows, macOS, Linux)](#phase-13-desktop-support-windows-macos-linux)
- [Phase 14: Playback Quality & Reliability](#phase-14-playback-quality--reliability)
- [Phase 15: Library & Discovery Enhancements](#phase-15-library--discovery-enhancements)
- [Phase 16: Search & Offline Sync](#phase-16-search--offline-sync)
- [Phase 17: Accessibility, Locale & Test Coverage](#phase-17-accessibility-locale--test-coverage)
- [Phase 18: Platform Extensions](#phase-18-platform-extensions)
- [Phase 19: Lyrics Enrichment & External Sources](#phase-19-lyrics-enrichment--external-sources)
- [Phase 20: Appearance Personalization](#phase-20-appearance-personalization)
- [Phase 21: Share System & Cross-Server Resolution](#phase-21-share-system--cross-server-resolution)
- [Phase 22: Core Technical Debt & Evidence Closeout](#phase-22-core-technical-debt--evidence-closeout)
- [Phase 23: Quality, Accessibility & Locale Completion](#phase-23-quality-accessibility--locale-completion)
- [Phase 24: Appearance Personalization (Priority Execution)](#phase-24-appearance-personalization-priority-execution)
- [Phase 25: Lyrics Enrichment & External Sources (Priority Execution)](#phase-25-lyrics-enrichment--external-sources-priority-execution)
- [Phase 26: In-Car & Desktop Platforms (Priority Execution)](#phase-26-in-car--desktop-platforms-priority-execution)
- [Phase 27: Platform Surface Extensions (Priority Execution)](#phase-27-platform-surface-extensions-priority-execution)
- [Phase 28: Share System & Cross-Server Resolution (Deferred Priority)](#phase-28-share-system--cross-server-resolution-deferred-priority)
- [Phase 29: ListenBrainz Scrobbling (Future Priority)](#phase-29-listenbrainz-scrobbling-future-priority)
- [Phase 30: Discovery System (Idea Backlog)](#phase-30-discovery-system-idea-backlog)
- [Phase 31: Adaptive Convergence Program (Desktop + Tablet + Phone)](#phase-31-adaptive-convergence-program-desktop--tablet--phone)
- [AI Agent Development Guidelines](#ai-agent-development-guidelines)
- [Verification Strategy](#verification-strategy)
- [Key Technical Decisions](#key-technical-decisions)
- [Future Considerations](#future-considerations)

---

## Architecture Overview

| Concern | Choice | Rationale |
|---|---|---|
| State management | `flutter_riverpod` + codegen | Native async handling (`AsyncValue`), no `BuildContext` dependency (needed for background audio handler), auto-dispose, family providers for parameterized data |
| Audio engine | `just_audio` | Gapless playback, `LockCachingAudioSource`, `ConcatenatingAudioSource`, native FLAC/MP3/AAC/Opus/Vorbis decoding, Android equalizer |
| Background audio | `audio_service` | Lock screen controls, notification media controls, headset button handling, Android Auto / CarPlay foundation |
| HTTP client | `dio` | Interceptors (Subsonic auth injection), request cancellation, streaming responses, file downloads |
| Local database | `drift` + `drift_flutter` | Relational model fits music data (artists → albums → tracks). Reactive queries (streams) feed Riverpod. Type-safe. Schema migrations. Isolate support. `drift_flutter` handles platform-specific SQLite setup automatically. |
| Image caching | `cached_network_image` | Memory + disk LRU cache, placeholder/error widgets, custom headers for Subsonic auth |
| Offline downloads | `background_downloader` | Native platform download managers (URLSession on iOS, WorkManager on Android), pause/resume, progress tracking, survives app kill |
| Routing | `go_router` | Declarative, shell routes for persistent scaffold, deep linking |
| Theming | `flex_color_scheme` + `dynamic_color` | Full Material 3 support, 66+ built-in schemes, OS-based dynamic color on Android/macOS/Windows/Linux |
| Models | `freezed` + `json_serializable` | Immutable, value equality, copyWith, union types, JSON serialization — all generated |
| Architecture pattern | Feature-first MVVM | Each feature self-contained with data/domain/presentation layers. Scales well. Clear boundaries. |

---

## Stack Validation (2026-02-18)

### Verdict

The selected stack is a strong and current fit for this app's requirements: large music libraries, background playback, resilient offline downloads, and reactive/dynamic UI behavior.

### Why This Stack Fits

| Requirement | Validation |
|---|---|
| App-scale routing | `go_router` remains the Flutter team's recommended router package for most apps. |
| Large library performance | Flutter performance guidance supports this plan's lazy list/grid + split-build strategy for 10K+ item datasets. |
| Reactive data + persistence | `drift` supports reactive queries, transactions, and isolate/threaded DB access suitable for large local libraries and sync pipelines. |
| Background playback | `just_audio` + `audio_service` remains the standard pairing for advanced playback + lock screen/notification controls. |
| Complex offline downloads | `background_downloader` supports persistent task queues with pause/resume/status tracking and native backends. |
| Connectivity behavior | `connectivity_plus` is appropriate for network-type hints, but server reachability must still be verified via API calls (`ping()`). |

### Constraints To Keep In Mind

- `background_downloader` has platform caveats (especially iOS background limits and paused-task resume edge cases). Design queue UX/retry states around those constraints.
- `just_audio` has known Android Gradle Plugin compatibility caveats (avoid AGP 8.6/8.7).
- Play target API deadlines change over time; re-validate `targetSdkVersion` before each release cut.

### Sources

- Flutter routing guidance (`go_router`): https://docs.flutter.dev/ui/navigation
- Flutter performance best practices: https://docs.flutter.dev/perf/best-practices
- Flutter large lists guidance: https://docs.flutter.dev/cookbook/lists/long-lists
- `go_router`: https://pub.dev/packages/go_router
- `flutter_riverpod`: https://pub.dev/packages/flutter_riverpod
- `drift`: https://pub.dev/packages/drift
- `just_audio`: https://pub.dev/packages/just_audio
- `audio_service`: https://pub.dev/packages/audio_service
- `background_downloader`: https://pub.dev/packages/background_downloader
- `connectivity_plus`: https://pub.dev/packages/connectivity_plus
- Play target API policy: https://support.google.com/googleplay/android-developer/answer/11926878?hl=en

---

## SDK & Platform Requirements

| Requirement | Minimum | Notes |
|---|---|---|
| Flutter SDK (minimum supported) | **>= 3.32.0** | Compatibility floor for declared package constraints |
| Flutter SDK (active development baseline) | **3.41.x stable** | Keep day-to-day development and primary CI on current stable (Flutter 3.41 was released on February 11, 2026) |
| Dart SDK (minimum supported) | **>= 3.8.0** | Compatibility floor for package constraints and language features used in the codebase |
| Dart SDK (active development baseline) | **3.10.x** | Paired with Flutter 3.41.x stable |
| Android `minSdkVersion` | **24** (Android 7.0) | Required by `audio_service`. Covers 95%+ of active devices. |
| Android `compileSdkVersion` | **36** (Android 16) | Required by current Android plugin stack and latest platform APIs |
| Android `targetSdkVersion` | **36** | Meets current Play policy baseline. Re-check Play requirements before each release cut. |
| iOS deployment target | **16.0** | Keep this under explicit review. Only raise when dependency requirements or product needs require it. |

Pin Flutter SDK version in the project using an `.fvmrc` or `pubspec.yaml` environment constraint:

```yaml
environment:
  sdk: ^3.8.0
  flutter: ">=3.32.0"
```

CI should run against both the minimum supported constraint and the active development baseline to catch compatibility regressions early.

---

## Git Strategy & Releases

### Branching Model

- **`main`** — always deployable, always passes `flutter analyze` and tests. Tagged releases are cut from here.
- **`dev`** — active development branch. All feature work is committed here. Merged to `main` when a phase is complete and verified.
- **Phase branches** (optional) — `phase/0-bootstrap`, `phase/1-core`, etc. Branch from `dev`, merge back into `dev` when the phase passes verification. Useful for keeping `dev` stable between phases.

### Commit Conventions

Use [Conventional Commits](https://www.conventionalcommits.org/) for all commit messages:

| Prefix | When to use | Example |
|---|---|---|
| `feat:` | New feature or screen | `feat: add album detail screen with track list` |
| `fix:` | Bug fix | `fix: rolling cache eviction not respecting size limit` |
| `refactor:` | Code restructuring, no behavior change | `refactor: extract cover art widget to common_widgets` |
| `docs:` | Documentation changes | `docs: update caching.md with rolling cache internals` |
| `test:` | Adding or updating tests | `test: add subsonic api client unit tests` |
| `chore:` | Build config, dependencies, tooling | `chore: bump drift to 2.31.0` |
| `style:` | Formatting, no code change | `style: run dart format` |
| `perf:` | Performance improvement | `perf: lazy-load album grid images` |

- Each commit is **atomic** — one logical change per commit. Don't bundle unrelated changes.
- No vague messages: `chore: update stuff`, `fix: fixes`, `misc: changes` are not acceptable.
- Body is optional but encouraged for non-trivial changes. Explain *why*, not *what* (the diff shows what).

### Versioning & Releases

Follow [Semantic Versioning](https://semver.org/) — `MAJOR.MINOR.PATCH`:

- **MAJOR** — breaking changes to user-facing functionality (e.g., data migration that can't be rolled back).
- **MINOR** — new features, new phases completed (e.g., offline support added).
- **PATCH** — bug fixes, performance improvements, minor polish.

**Pre-1.0 convention**: While in active development (Phases 0–10), use `0.x.y` versions. Each completed phase bumps the minor version:

| Milestone | Version | Tag |
|---|---|---|
| Phase 0+1+2 complete (app logs in) | `0.1.0` | `v0.1.0` |
| Phase 3 complete (library browsing) | `0.2.0` | `v0.2.0` |
| Phase 4+5 complete (playback + now playing) | `0.3.0` | `v0.3.0` |
| Phase 6+7 complete (search + playlists) | `0.4.0` | `v0.4.0` |
| Phase 8 complete (offline/cache) | `0.5.0` | `v0.5.0` |
| Phase 9 complete (settings) | `0.6.0` | `v0.6.0` |
| Phase 10 complete (polish) — **first stable** | `1.0.0` | `v1.0.0` |
| Phase 11 (AudioMuse AI) | `1.1.0` | `v1.1.0` |
| Phase 14 complete (playback quality + reliability) | `1.2.0` | `v1.2.0` |
| Phase 15 complete (library + discovery enhancements) | `1.3.0` | `v1.3.0` |
| Phase 16 complete (search + offline sync) | `1.4.0` | `v1.4.0` |
| Phase 17 complete (accessibility + locale + test coverage) | `1.5.0` | `v1.5.0` |
| Phase 18 complete (platform extensions) | `1.6.0` | `v1.6.0` |
| Phase 12 complete (Android Auto & CarPlay) | `2.0.0` | `v2.0.0` |
| Phase 13 complete (desktop support) | `2.1.0` | `v2.1.0` |

Bug fixes on any version bump the patch: `0.3.1`, `1.0.1`, etc.

### Tagging & Release Notes

- **Tag every version** on `main` after merging from `dev`: `git tag -a v0.3.0 -m "Playback engine and Now Playing screen"`.
- **Pre-release tags** for builds shared before a milestone is fully complete: `v0.3.0-rc.1` (release candidate), `v0.3.0-beta.1` (beta). These are tagged on `dev` or a phase branch, not `main`.
- **Release notes** accompany each tag. Keep them concise:
  - What's new (features added in this version).
  - What's fixed (bugs resolved).
  - Known issues (if any).
  - No AI-generated fluff. Just the facts.
- Update `version:` in `pubspec.yaml` to match the tag before tagging. Flutter uses `version: 0.3.0+7` format where `+7` is the build number (incremented on every build, never reset).

### Merge Workflow

1. Complete a phase on `dev` (or phase branch → `dev`).
2. Run full verification criteria for that phase.
3. Bump version in `pubspec.yaml`.
4. Merge `dev` → `main` (fast-forward or merge commit, no squash — preserve commit history).
5. Tag `main` with the version and publish the release: `./tool/release.sh v0.x.0`.
   The script runs quality checks, builds the APK, tags, creates the Forgejo release, and uploads the APK.

### Progress Tracking

A `PROGRESS.md` file in the repository root serves as the canonical progress tracker. It contains a checkbox list mirroring every phase and sub-task in this plan. Forgejo renders checkboxes natively, so the repo's web view shows visual progress at a glance.

- The AI agent checks boxes and adds completion dates as tasks are finished.
- Feature releases (tags) are noted inline with the phase they correspond to.
- This file is version-controlled — progress history is visible in git log.
- Forgejo Issues may be used later for bug tracking and user-facing feature requests, but `PROGRESS.md` is the primary development tracker.

### Local Quality Gate & Release Tooling

There is no CI runner configured on the Forgejo instance. All quality gates and release publishing run **locally** via scripts in `tool/`.

**Quality gate** (`tool/check.sh`):

Run before every commit (enforced via optional pre-commit hook). Steps:

1. `dart format --set-exit-if-changed .` — fail if formatting drift exists.
2. `dart run build_runner build --delete-conflicting-outputs` — regenerate code.
3. `flutter analyze` — fail on analyzer issues.
4. `dart run custom_lint` — fail on custom lint violations.
5. `flutter test` — fail on test failures.

**Release script** (`tool/release.sh`):

Run from the local machine to publish a versioned release with APK to Forgejo. Steps:

1. Run `./tool/check.sh` — full quality gate. Fails fast if anything is wrong.
2. `flutter build apk --release` — build the release APK.
3. Create an annotated git tag and push it.
4. Determine release type from tag: tags containing `-alpha`, `-beta`, `-rc`, or `-dev` are marked as pre-release; clean semver tags (e.g., `v1.0.0`) are marked as stable.
5. Create a Forgejo Release via the API.
6. Upload the APK as a release asset.

**Release script setup**:

1. Install `jq`: `sudo apt install jq`.
2. Create `tool/release.env` (git-ignored) with your Forgejo credentials:
   ```bash
   FORGEJO_URL="https://your-forgejo-instance.com"
   FORGEJO_REPO="your-user/Navis"
   FORGEJO_TOKEN="your-api-token"
   ```
   Alternatively, export these as environment variables.
3. `chmod +x tool/release.sh` (already executable in the repo).

**Usage**:
```bash
./tool/release.sh v0.2.0          # stable release
./tool/release.sh v0.3.0-beta.1   # pre-release (auto-detected)
```

**Dependency health checks** (manual, periodic):

Run these locally whenever you want to check for outdated dependencies:
```bash
flutter pub outdated
dart pub outdated
```

Known follow-up sweep (2026-03-27): prioritize `drift`, `drift_flutter`, `drift_dev`, and `json_serializable`, then review the transitive analyzer/sqlite/win32 chain before the next release hardening pass.

**Tooling maintenance rule (mandatory for AI agent sessions)**:
- Any change to quality gates, test commands, Flutter/Dart versions, or release packaging must be reflected in `tool/check.sh` and/or `tool/release.sh` in the same task/PR.
- Record tooling updates in `PROGRESS.md` with date + evidence, same as code/test tasks.

---

## Execution Workflow

This section is the operational contract for day-to-day implementation, especially when work is done incrementally by an AI coding agent.

### Session Start (Every Work Session)

1. Read `DEVELOPMENT_PLAN.md` and `PROGRESS.md`.
2. Pick exactly one small unchecked task (or one tightly-coupled pair) as the active scope.
3. Confirm the touched files expected for that task before editing.
4. Implement the smallest vertical slice that is testable/runnable.

### Mandatory Task Loop

1. Implement code + tests together (or in the same session before task close-out).
2. Run local quality gate:
   - Preferred: `./tool/check.sh`
   - Fallback: `dart format --set-exit-if-changed . && dart run build_runner build --delete-conflicting-outputs && flutter analyze && dart run custom_lint && flutter test`
3. Fix all failing checks before moving to another task.
4. Update `PROGRESS.md` immediately with completion date and evidence note.
5. Commit one logical change using Conventional Commits.

### Blocker Protocol

- If blocked for more than 30 minutes, record the blocker in `PROGRESS.md` under a blockers section with:
  - what is blocked,
  - what was tried,
  - exact error message,
  - proposed next action.
- Do not silently skip blocked tasks and mark unrelated items complete.

### Task Done Criteria

A task is complete only when all are true:

- Implementation is in place and wired into the app flow.
- Relevant tests were added or updated.
- Quality gate commands pass locally.
- `PROGRESS.md` is updated with date/evidence.
- Any affected file in `docs/` is updated for non-trivial behavior changes.

---

## Core Dependencies

### Runtime

| Package | Purpose |
|---|---|
| `flutter_riverpod` + `riverpod_annotation` | State management and reactive data binding |
| `just_audio` | Core audio playback engine |
| `audio_service` | Background playback, media session, lock screen / notification controls |
| `audio_session` | Audio focus management (ducking, interruptions) |
| `dio` | HTTP client with interceptors |
| `drift` + `drift_flutter` | Local SQLite database with reactive queries. `drift_flutter` replaces manual `sqlite3_flutter_libs` + `path_provider` wiring — handles database file location and native SQLite binary loading automatically. |
| `cached_network_image` + `flutter_cache_manager` | Album art caching with placeholders. `flutter_cache_manager` used directly to configure custom max cache size for cover art (default 500 MB). |
| `background_downloader` | Offline track downloads via native platform APIs |
| `flutter_local_notifications` | Download progress and completion notifications |
| `go_router` | Declarative routing with shell routes |
| `flex_color_scheme` | Material 3 theming with presets and seed colors |
| `dynamic_color` | OS wallpaper / accent-based dynamic theming |
| `flutter_secure_storage` | Encrypted credential storage |
| `shared_preferences` | Simple key-value settings persistence |
| `connectivity_plus` | Network state detection |
| `path_provider` | Platform file system paths |
| `crypto` | MD5 hashing for Subsonic auth tokens |
| `uuid` | Salt generation |
| `rxdart` | Stream combinators for audio state |
| `freezed_annotation` | Immutable model annotations |
| `json_annotation` | JSON serialization annotations |
| `scrollable_positioned_list` | Synced lyrics scrolling to current line |
| `palette_generator` | Extract dominant color from album art for Now Playing tint |
| `animations` | Material Design motion system — `SharedAxisTransition`, `FadeThroughTransition`, `OpenContainer` for Material 3 page transitions |
| `logger` | Structured, color-coded logging for debug and error tracking |
| `intl` | Localization / internationalization — message formatting, date/number formatting |
| `permission_handler` | Runtime permission requests (e.g., `POST_NOTIFICATIONS` on Android 13+) |
| `package_info_plus` | App version and build number at runtime (used by the in-app update checker) |

**SDK dependencies** (in `pubspec.yaml` under `flutter:`):
- `flutter_localizations: sdk: flutter` — required for Material/Cupertino localization delegates.
- `flutter_test: sdk: flutter` — unit/widget test framework.
- `integration_test: sdk: flutter` — device/emulator integration test framework.

### Dev

| Package | Purpose |
|---|---|
| `build_runner` | Code generation runner |
| `freezed` | Immutable model code generation |
| `json_serializable` | JSON serialization code generation |
| `drift_dev` | Drift table/DAO code generation |
| `riverpod_generator` | Provider code generation. Note: v4.x generates code targeting Riverpod 3.x internals. The `@riverpod` annotation syntax is unchanged from v2.x — version jump reflects internal code generation changes, not annotation API changes. |
| `riverpod_lint` | Riverpod-specific lints and assists |
| `very_good_analysis` | Comprehensive lint rule set |
| `custom_lint` | Custom lint runner |
| `mocktail` | Mocking for unit and widget tests |

---

## Project Structure

```
lib/
├── main.dart
├── src/
│   ├── app.dart                          # MaterialApp, theme, ProviderScope
│   ├── api/
│   │   ├── subsonic_api_client.dart      # Dio wrapper, all endpoint methods
│   │   ├── subsonic_auth_interceptor.dart # Auto-injects auth params
│   │   ├── subsonic_error.dart           # Typed API error exceptions
│   │   └── models/                       # Freezed API response models
│   │       ├── artist.dart
│   │       ├── album.dart
│   │       ├── song.dart
│   │       ├── playlist.dart
│   │       ├── search_result.dart
│   │       ├── lyrics.dart
│   │       ├── genre.dart
│   │       ├── server_info.dart
│   │       └── subsonic_response.dart
│   ├── database/
│   │   ├── navis_database.dart           # Drift database definition
│   │   ├── tables/                       # Drift table schemas
│   │   ├── daos/                         # Data access objects
│   │   └── converters/                   # Drift type converters
│   ├── routing/
│   │   └── app_router.dart               # GoRouter config, guards, routes
│   ├── features/
│   │   ├── auth/
│   │   │   ├── data/                     # AuthRepository
│   │   │   ├── domain/                   # ServerConfig model
│   │   │   └── presentation/             # LoginScreen, server setup
│   │   ├── home/
│   │   │   └── presentation/             # HomeScreen (discovery feed)
│   │   ├── library/
│   │   │   ├── data/                     # LibraryRepository, SyncEngine
│   │   │   ├── domain/                   # Artist, Album, Song, Genre
│   │   │   └── presentation/             # Tabs, grids, detail screens
│   │   ├── player/
│   │   │   ├── data/                     # NavisAudioHandler, PlaybackCacheManager
│   │   │   ├── domain/                   # PlaybackSnapshot, PlayerState
│   │   │   └── presentation/             # NowPlaying, MiniPlayer, Queue, Lyrics
│   │   ├── search/
│   │   │   ├── data/                     # SearchRepository
│   │   │   ├── domain/                   # SearchResult
│   │   │   └── presentation/             # SearchScreen
│   │   ├── playlists/
│   │   │   ├── data/                     # PlaylistRepository
│   │   │   ├── domain/                   # Playlist model
│   │   │   └── presentation/             # List, detail, create/edit
│   │   ├── downloads/
│   │   │   ├── data/                     # RollingCacheManager, DownloadQueueManager, OfflineRepository
│   │   │   ├── domain/                   # DownloadTask, CachedTrack, CacheType
│   │   │   └── presentation/             # DownloadQueueScreen, StorageOverview
│   │   ├── settings/
│   │   │   ├── data/                     # SettingsRepository
│   │   │   ├── domain/                   # AppSettings model
│   │   │   └── presentation/             # Settings screens
│   │   └── audiomuse/
│   │       ├── data/                     # AudioMuseService
│   │       ├── domain/                   # Recommendation models
│   │       └── presentation/             # SmartQueueSheet, SimilarContent
│   ├── common_widgets/
│   │   ├── cover_art_image.dart
│   │   ├── track_list_tile.dart
│   │   ├── album_card.dart
│   │   ├── artist_card.dart
│   │   ├── loading_indicator.dart
│   │   ├── error_state.dart
│   │   ├── empty_state.dart
│   │   ├── star_button.dart
│   │   ├── context_menu.dart
│   │   ├── cache_badge.dart              # "Cached" / "Downloaded" / "Temporary" indicators
│   │   └── pull_to_refresh.dart
│   └── utils/
│       ├── constants.dart
│       ├── extensions.dart
│       ├── duration_format.dart
│       ├── app_logger.dart                # Singleton Logger instance
│       └── connectivity.dart
lib/l10n/
    └── app_en.arb                         # English localization strings
l10n.yaml                                  # Localization config
docs/                                      # Development documentation (see AI guideline #17)
test/
    (mirrors lib/src/ structure)
tool/
├── bootstrap.sh                            # Local env bootstrap (sdk checks, deps)
├── check.sh                                # Canonical local quality gate command
└── release.sh                              # Build, tag, and publish release to Forgejo
drift_schemas/                             # Exported drift schemas for migration testing
```

---

## Phase 0: Project Bootstrap & Tooling

**Goal**: Runnable blank app with all tooling configured.

### Tasks

- [ ] Initialize Flutter project with `flutter create` (org: pick a suitable reverse-domain, e.g. `com.navis.app`), targeting Android + iOS.
- [ ] Configure `analysis_options.yaml`:
  - Include `very_good_analysis` rules.
  - Disable `public_member_api_docs` (unnecessary overhead for a solo project).
  - Add `riverpod_lint` as a custom lint plugin.
- [ ] Set up `pubspec.yaml` with all dependencies listed in [Core Dependencies](#core-dependencies).
- [ ] Create the full directory structure under `lib/src/` as shown in [Project Structure](#project-structure).
- [ ] Configure Android manifest (`android/app/src/main/AndroidManifest.xml`):
  - Permissions: `INTERNET`, `WAKE_LOCK`, `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_MEDIA_PLAYBACK`, `POST_NOTIFICATIONS` (required on Android 13+ / API 33+ for download progress and completion notifications from `flutter_local_notifications`).
  - Do **not** enable global `android:usesCleartextTraffic="true"` by default.
  - Use `android:networkSecurityConfig="@xml/network_security_config"` and allow cleartext only where required (e.g., localhost proxy and explicitly approved insecure self-hosted endpoints).
  - `compileSdkVersion` 36, `targetSdkVersion` 36, `minSdkVersion` 24 (Android 7.0) — required by current Android plugin stack and `audio_service`, covers 95%+ of devices. Re-check target/compile SDK against Play policy before every release.
  - Enable Java 8 desugaring for `flutter_local_notifications`.
  - Enable `android:enableOnBackInvokedCallback="true"` on `<application>` for predictive back gesture support (Android 13+).
- [ ] Configure edge-to-edge display for Android 15+:
  - Android 15 (API 35) enforces edge-to-edge by default. Ensure all screens use `SafeArea`, `MediaQuery.viewInsetsOf()`, or `Scaffold` body insets properly.
  - Test that the MiniPlayer + NavigationBar do not overlap system gesture areas.
  - Use `SystemChrome.setEnabledSystemUIMode` (not deprecated `setEnabledSystemUIOverlays`) only where needed (Now Playing fullscreen). Validate behavior on Android 15+ and Android 16/API 36 where edge-to-edge opt-out is no longer available.
- [ ] Create Android notification channels programmatically on app startup:
  - `playback` channel: media playback notification (used by `audio_service`).
  - `downloads` channel: download progress and completion (used by `flutter_local_notifications`).
  - Channels must be created before any notification is posted (Android 8+ requirement).
- [ ] Request `POST_NOTIFICATIONS` runtime permission at an appropriate time (e.g., when the user first pins content for offline, or on first app launch with explanation).
- [ ] Configure iOS (`ios/Runner/Info.plist`):
  - `UIBackgroundModes` → `audio`.
  - Prefer scoped ATS exceptions (`NSExceptionDomains`, `NSAllowsLocalNetworking`) instead of unconditional `NSAllowsArbitraryLoads`. If global arbitrary loads are unavoidable for user-provided HTTP servers, document the security trade-off and App Store review rationale.
  - Set `MinimumOSVersion` to 16.0 in Xcode project settings.
- [ ] Set up a centralized `Logger` instance (using the `logger` package). Create `lib/src/utils/app_logger.dart` with a singleton logger configured for debug and release modes (verbose in debug, warnings+ in release). All modules import and use this logger instead of `print()`.
- [ ] Set up local developer tooling scripts:
  - `tool/bootstrap.sh`: verifies toolchain versions, runs `flutter pub get`, and prints next commands.
  - `tool/check.sh`: canonical quality gate used by humans and AI agents.
- [ ] Set up `build_runner` code generation. Create a `Makefile` (optional) with aliases to tooling commands:
  - `gen`: `dart run build_runner build --delete-conflicting-outputs`
  - `gen-watch`: `dart run build_runner watch --delete-conflicting-outputs`
  - `test`: `flutter test`
  - `test-coverage`: `flutter test --coverage`
  - `lint`: `flutter analyze && dart run custom_lint`
  - `format`: `dart format .`
  - `format-check`: `dart format --set-exit-if-changed .`
- [ ] Add an optional local pre-commit hook that runs at least `format-check` and `flutter analyze` on changed files.
- [ ] Scaffold `main.dart`, `app.dart` with `ProviderScope`, `MaterialApp.router`, and a placeholder home screen.
- [ ] Verify: `flutter run` launches without errors, `build_runner build` succeeds, and `./tool/check.sh` passes end-to-end.

---

## Phase 1: Core Infrastructure

### 1.1 — Subsonic API Client

**Location**: `lib/src/api/`

The API client wraps all communication with the Subsonic/OpenSubsonic server. Every endpoint is a typed method returning a `freezed` model.

**Authentication**:
- Token-based (API >= 1.13.0): `t = md5(password + salt)`, random `s` per request.
- Legacy password fallback (API < 1.13.0): `p = enc:hex(password)`.
- `SubsonicAuthInterceptor` appends `u`, `t`, `s`, `v`, `c`, `f` params to every request automatically.
- **Always set `f=json`** in every request. The Subsonic API defaults to XML; without this parameter, responses would require an XML parser instead of `json_serializable`. The interceptor hardcodes `f=json` — this is not configurable.
- Auth method selected based on server API version reported by `ping()`.

**Required endpoint methods**:

| Category | Methods |
|---|---|
| System | `ping()`, `getOpenSubsonicExtensions()` |
| Browsing | `getArtists()`, `getArtist(id)`, `getAlbum(id)`, `getSong(id)`, `getArtistInfo2(id)`, `getAlbumInfo2(id)`, `getGenres()` |
| Lists | `getAlbumList2(type, size, offset)`, `getRandomSongs(size)`, `getSongsByGenre(genre)`, `getStarred2()`, `getNowPlaying()` |
| Search | `search3(query, artistCount, albumCount, songCount, artistOffset, albumOffset, songOffset)` |
| Playlists | `getPlaylists()`, `getPlaylist(id)`, `createPlaylist(name, songIds)`, `updatePlaylist(id, ...)`, `deletePlaylist(id)` |
| Media | `streamUrl(id, maxBitRate?, format?)` (builds URL, does not fetch), `downloadUrl(id)`, `getCoverArtUrl(id, size?)` |
| Lyrics | `getLyricsBySongId(id)` (OpenSubsonic), `getLyrics(artist?, title?)` (legacy fallback) |
| Annotation | `star(id)`, `unstar(id)`, `setRating(id, rating)`, `scrobble(id, submission?)` |
| Radio | `getInternetRadioStations()` |

**Server capabilities**:
- On login, call `getOpenSubsonicExtensions()`. Store the result as a `ServerCapabilities` model.
- Features like synced lyrics (`getLyricsBySongId`), transcode offset, etc. gated behind capability checks.
- Graceful degradation: if an endpoint is unsupported, the UI hides or disables the corresponding feature.

**Error handling**:
- Parse Subsonic error codes into typed exceptions: `SubsonicAuthException` (40), `SubsonicForbiddenException` (50), `SubsonicNotFoundException` (70), `SubsonicGenericException`.
- Network errors (timeouts, DNS failures) wrapped as `SubsonicConnectionException`.
- All exceptions carry a human-readable message for UI display.

**Dio configuration**:
- Base options: `connectTimeout: 15 seconds`, `receiveTimeout: 30 seconds`, `sendTimeout: 15 seconds`.
- For streaming/download URLs, use a longer `receiveTimeout` (5 minutes) or disable it.
- Retry interceptor: automatically retry on `SocketException`, `TimeoutException`, HTTP 502/503/504 — up to 3 retries with exponential backoff (1s, 2s, 4s). Do not retry on 4xx client errors.
- Cancel tokens: when navigating away from a screen, cancel pending API requests for that screen’s data (e.g., cancelling a `search3` call when the search screen is popped). Pass `CancelToken` instances through repositories to providers.
- Logging interceptor: in debug mode, log request method + URL + status code + duration via the app `Logger`. Omit request/response bodies and redact sensitive query params (`u`, `t`, `s`, `p`) before logging.

**Freezed API models**:
- `SubsonicResponse<T>` — generic wrapper with status and optional error.
- `Artist`, `ArtistInfo`, `Album`, `AlbumInfo`, `Song`, `Genre`, `Playlist`, `SearchResult3`, `LyricsList`, `StructuredLyrics`, `LyricLine`, `InternetRadioStation`, `ServerCapabilities`.
- Each model has `fromJson` factory for deserialization from the Subsonic JSON response.

### 1.2 — Local Database

**Location**: `lib/src/database/`

A `drift` SQLite database that serves as the source of truth for the UI. The library UI never reads directly from the API — it reads from the local database, which is populated by the sync engine.

**Tables**:

| Table | Key Columns | Purpose |
|---|---|---|
| `server_config` | `id`, `name`, `url`, `username`, `apiVersion`, `capabilities`, `lastSynced` | Server connection info (password stored separately in `flutter_secure_storage`) |
| `artists` | `id`, `name`, `albumCount`, `coverArt`, `starred` | Cached artist list |
| `albums` | `id`, `name`, `artistId`, `artistName`, `songCount`, `duration`, `year`, `genre`, `coverArt`, `starred`, `playCount` | Cached album list |
| `songs` | `id`, `title`, `albumId`, `artistId`, `artistName`, `albumName`, `track`, `discNumber`, `duration`, `bitRate`, `contentType`, `suffix`, `size`, `coverArt`, `starred`, `playCount` | Cached song list |
| `genres` | `name`, `songCount`, `albumCount` | Genre metadata |
| `playlists` | `id`, `name`, `songCount`, `duration`, `owner`, `isPublic`, `coverArt`, `comment` | Cached playlist list |
| `playlist_songs` | `playlistId`, `songId`, `sortOrder` | Playlist membership and ordering |
| `cached_tracks` | `songId`, `filePath`, `fileSize`, `format`, `bitRate`, `lastAccessedAt`, `cacheType` (rolling/permanent), `downloadStatus` | Rolling cache and permanent offline manifest |
| `download_queue` | `id`, `songId`, `albumId`, `playlistId`, `quality`, `format`, `status` (queued/downloading/paused/complete/failed), `progress`, `addedAt`, `priority` | Managed download queue for offline pins |
| `play_history` | `songId`, `playedAt` | Local play history for recently played |
| `recent_searches` | `query`, `searchedAt` | Recent search terms |
| `play_queue` | `id`, `currentIndex`, `shuffleMode`, `repeatMode`, `positionMs`, `updatedAt` | Persisted play queue state (one row, upserted) |
| `play_queue_items` | `queueId`, `songId`, `sortOrder` | Ordered tracks in the persisted play queue |

**DAOs**: `ServerDao`, `LibraryDao`, `PlaylistDao`, `CacheDao`, `DownloadQueueDao`, `HistoryDao`, `PlayQueueDao`.

All queries that feed the UI return `Stream<List<T>>` for reactive updates. When the sync engine writes new data, the UI updates automatically through drift's stream queries flowing into Riverpod providers.

Schema versioned from v1 with incremental migrations for future changes.

**Database correctness and performance defaults**:
- Enable and verify SQLite foreign keys (`PRAGMA foreign_keys = ON`) in initialization.
- Add indexes for common query patterns (e.g., artist sort, album by artist/year, song by album/track, queue order columns).
- Prefer explicit transactions for multi-table writes (sync batches, playlist edits, cache promotion) to keep state coherent.

**Database initialization** (via `drift_flutter`):
- Use `drift_flutter`'s `driftDatabase()` helper to create the `NativeDatabase` — it handles locating the correct database file path and loading the native SQLite binary on each platform. No manual `sqlite3_flutter_libs` or `path_provider` wiring needed.
- Open the database on the main isolate but run heavy queries on a background isolate via `NativeDatabase.createInBackground()`. Drift handles cross-isolate communication.

**Migration strategy**:
- Every schema change bumps the `schemaVersion` integer in the `@DriftDatabase` annotation.
- Each migration is a named function (e.g., `from1To2`, `from2To3`) registered in the `migration` getter.
- Migrations run sequentially: opening a v1 database on v3 code runs `1→2` then `2→3`.
- Use `drift_dev`’s `schema` tool to export each version’s schema for testing: `dart run drift_dev schema dump lib/src/database/navis_database.dart drift_schemas/`.
- Write migration unit tests that open an older schema, run migrations, and verify the new schema’s tables and columns exist.
- Never delete columns or tables in production migrations — only add or alter. If a column must be removed, leave it unused and clean up in a future major version.

### 1.3 — Riverpod Provider Architecture

Providers are organized within each feature's `presentation/` or `data/` directory. Key global providers:

| Provider | Type | Purpose |
|---|---|---|
| `serverConfigProvider` | `AsyncNotifier` | Active server configuration. `null` if not logged in. |
| `subsonicApiProvider` | `Provider` | `SubsonicApiClient` instance configured from `serverConfigProvider`. |
| `navisDatabaseProvider` | `Provider` | Singleton `NavisDatabase` instance. |
| `connectivityProvider` | `StreamProvider` | Network connectivity state. |

Feature providers follow the pattern:
- `artistsProvider` — streams artists from local DB.
- `albumProvider(id)` — family provider, streams album + its songs from DB.
- `albumListProvider(type)` — family provider for album lists (recent, frequent, random, etc.).
- `searchResultsProvider(query)` — async, always hits live API.
- `playerStateProvider` — wraps `AudioHandler` playback state streams.
- `queueProvider` — current play queue with manipulation methods.
- `lyricsProvider(songId)` — fetches lyrics from API, caches result.
- `downloadProgressProvider(songId)` — download state for offline pins.
- `downloadQueueProvider` — live list of all download queue items (active, queued, failed).
- `rollingCacheStatsProvider` — current rolling cache size, max size.
- `permanentCacheStatsProvider` — total permanent cache size with per-album breakdown.
- `networkTypeProvider` — current Wi-Fi vs cellular state, drives streaming quality selection.
- `activeStreamingQualityProvider` — resolved bitrate/format based on current network type and settings.

### 1.4 — Routing

**Location**: `lib/src/routing/app_router.dart`

Uses `go_router` with a `ShellRoute` for the main app scaffold (bottom NavigationBar + persistent MiniPlayer).

**Route table**:

| Path | Screen | Notes |
|---|---|---|
| `/login` | Login screen | Shown if no server configured |
| `/` | Home | Discovery feed — redirect target after login |
| `/library` | Library | Tabbed: Albums (default), Artists (+ optional Radio tab) |
| `/library/artists/:id` | Artist detail | Albums grid + bio |
| `/library/albums/:id` | Album detail | Track list, cover art, actions |
| `/search` | Search | Live API search |
| `/playlists` | Playlists list | All playlists |
| `/playlists/:id` | Playlist detail | Track list with reorder |
| `/settings` | Settings | All app settings |
| `/settings/server` | Server settings | Edit server, reconnect |
| `/settings/cache` | Cache management | Rolling cache, permanent cache, cover art stats |
| `/settings/playback` | Playback settings | Wi-Fi / cellular quality, transcoding |
| `/settings/appearance` | Appearance | Theme mode, color scheme |
| `/downloads` | Download Queue | Queue, downloaded, storage overview |
| `/now-playing` | Now Playing | Full-screen player |

**Route guard**: If `serverConfigProvider` returns `null`, redirect all routes to `/login`.

The MiniPlayer is rendered inside the `ShellRoute`'s scaffold, floating above the `NavigationBar`, and persists across all shell routes. Tapping it navigates to `/now-playing`.

---

## Phase 2: Authentication & Server Setup

**Goal**: User can connect to a Subsonic/Navidrome server and the app remembers the connection.

### Login Flow

1. User enters server URL, username, password.
2. App calls `ping()` to validate connection and detect API version.
3. If successful, calls `getOpenSubsonicExtensions()` to populate `ServerCapabilities`.
4. Stores server config in drift. Password stored separately in `flutter_secure_storage`.
5. Redirects to home screen.

### Server Config Screen

- View current server connection info (name, URL, username, API version, server type).
- "Test Connection" button to re-validate.
- "Sign Out" button to clear credentials and return to login.
- Edit server URL, username, password.

### Auto-Reconnect

- On app launch, attempt `ping()` to the configured server.
- If server is unreachable, show an offline banner at the top of the app. Allow browsing cached library data and playing cached/pinned tracks.
- Periodic retry in background (every 30 seconds) while offline.
- Treat `connectivity_plus` as a network-type hint only. Online/offline truth is determined by actual server reachability (`ping()` / lightweight endpoint call), not interface status alone.

### Security

- Passwords never stored in plaintext. `flutter_secure_storage` uses Android Keystore / iOS Keychain.
- Token auth preferred. Salt regenerated per request.
- HTTPS preferred but HTTP supported for self-hosted servers.

### Phase 2 Implementation Notes (2026-02-19)

- `Settings` now includes a working `Server` section (`/settings/server`) with current connection details, editable credentials, test/save actions, and sign-out controls.
- Reachability is now maintained by a dedicated controller (`ServerReachabilityStatus`: checking/online/offline) that derives truth from `ping()`, retries every 30s while offline, and uses connectivity changes as recheck hints only.
- `AppShell` displays a global offline banner while authenticated and unreachable, with retry cadence messaging.
- Sign-out now supports two explicit paths:
  - `Sign out (keep local data)` clears credentials/server profile only.
  - `Sign out and clear local data` clears credentials plus local metadata tables and attempts best-effort cached-file deletion.
- URL policy now accepts both `https://` and `http://`; HTTP remains explicitly warned as insecure in auth/server settings UI.

---

## Phase 3: Library Browsing & Metadata Sync

**Goal**: Full music library browsable from local cache. Album pages load instantly.

**Cross-cutting concerns introduced in this phase** (not deferred to Phase 10):
- **Localization**: From this phase onward, all user-facing strings go into `app_en.arb`. Build the `AppLocalizations` pattern now — retrofitting string extraction later is painful.
- **Skeleton/shimmer loading**: Build the `ShimmerPlaceholder` widget in `common_widgets/` during this phase. Every list and grid from Phase 3 onward uses shimmer loading, not spinners.
- **Error and empty state widgets**: Build `ErrorState` (with retry callback) and `EmptyState` (with contextual message) in `common_widgets/`. Use them for every `AsyncValue.error` and empty data case from Phase 3 onward.

### 3.1 — Sync Engine

**Location**: `lib/src/features/library/data/library_sync_engine.dart`

The sync engine pulls metadata from the server and stores it in the local drift database.

**Initial sync** (first connection to a server):
1. `getArtists()` → insert all artists into `artists` table.
2. For each artist, `getArtist(id)` → insert albums into `albums` table. Batch requests with concurrency limit (4-6 simultaneous) to avoid overwhelming the server.
3. For each album, `getAlbum(id)` → insert songs into `songs` table. Same batching.
4. `getGenres()` → insert into `genres` table.
5. `getPlaylists()` → insert into `playlists` table (playlist songs fetched on-demand when user opens a playlist).
6. Store `lastSynced` timestamp in `server_config`.

**Incremental sync** (subsequent launches):
- Use `getIndexes(ifModifiedSince: lastSynced)` to detect which artists/albums changed.
- Only re-fetch modified data.
- Update `lastSynced` on completion.

**Sync runs in a background isolate** (drift supports cross-isolate database access) so the UI never janks during sync.
Implementation note (2026-02-20): Current implementation offloads heavy album/song companion transformation through `Isolate.run`; full orchestration on a dedicated background isolate remains a follow-up optimization.

**Sync triggers**:
- On app launch (if last sync > configurable threshold, default 1 hour).
- Pull-to-refresh on any library screen.
- Manual "Force Full Sync" button in Sync Settings (`/settings/sync`).

**Sync progress**: Show a subtle progress indicator (linear progress bar at top of library screens) during initial sync. Don't block the UI — whatever has been synced so far is immediately browsable.

### 3.2 — Library UI

**NavigationBar** (bottom): Home, Library, Search, Playlists, Settings.

#### Home Screen (`/`)

The home screen is a discovery feed, not just a static landing page. Vertical scrollable list of horizontal carousels:

- **Recently Played** — from local `play_history` table. Horizontal album art carousel.
- **Recently Added** — `getAlbumList2(type: 'newest')`. Horizontal album card carousel.
- **Most Played** — `getAlbumList2(type: 'frequent')`. Horizontal carousel.
- **Random Albums** — `getAlbumList2(type: 'random')`. Refreshes on pull-to-refresh.
- **Liked** — `getStarred2()`. Shows liked albums/songs.

Each carousel card shows cover art + album name + artist name. Tap → album detail.

#### Library Screen (`/library`)

Tabbed interface with tabs: **Albums** (default first tab), **Artists**, and optional **Radio** (controlled by settings).

Rationale: Albums is the most frequently used browse surface for large libraries, so Library opens on Albums while Artists remains one swipe away.

**Albums tab**:
- Grid of album covers (2-3 columns depending on screen width).
- Sort options (dropdown): Newest, Name, Artist.
- Each card: cover art, album name, artist name, year.
- Tap → Album detail.

**Artists tab**:
- Alphabetically sorted list with section headers (A, B, C...) and a fast scroll index on the right edge.
- Each artist row: artist image (or placeholder), name, album count.
- Tap → Artist detail.

**Radio tab (foundation in scope, full UX deferred)**:
- Populated from server radio stations (`getInternetRadioStations` compatible behavior).
- Must remain compatible with ICY metadata updates and AzuraCast stations.
- Settings toggle under Playback settings can hide/show the Radio tab.
- Library songs browsing is intentionally removed from the top-level Library tabs in favor of Artists/Albums-first navigation.

#### Artist Detail Screen (`/library/artists/:id`)

- Header: artist image (from `getArtistInfo2`), artist name.
- Bio section: collapsible artist biography text from `getArtistInfo2`.
- Albums grid: all albums by this artist, sorted by year descending.
- "Play all" and "Shuffle" buttons.
- Like/unlike button.
- Similar artists section (from `getArtistInfo2.similarArtist`) — horizontal scrollable row of artist chips/cards.

#### Album Detail Screen (`/library/albums/:id`)

This is the most important browsing screen. Must load instantly from local cache.

- Header: large cover art with a parallax/collapse effect on scroll (SliverAppBar with `flexibleSpace`).
- Below header: album name, artist name (tappable → artist detail), year, genre, track count, total duration.
- Action row: Play, Shuffle, Like, Download (pin for offline), overflow menu.
- Track list: numbered by disc/track, with duration. Each track has a context menu (long-press) with: Play Next, Add to Queue, Add to Playlist, Like, Download, Go to Artist, Go to Album.
- If album is partially or fully pinned for offline, show a download status indicator.
- Currently playing track highlighted in the list.

### 3.3 — Common Widgets

Build the shared widget library used by all subsequent phases. These live in `lib/src/common_widgets/`.

- `ShimmerPlaceholder` — skeleton loading widget using `LinearGradient` animation on `Container`. No external package needed.
- `ErrorState` — displays error message with retry callback. Used for all `AsyncValue.error` states.
- `EmptyState` — displays contextual message (e.g., "No albums found"). Used for all empty data cases.
- `CoverArtImage` — wraps `cached_network_image` with auth headers, placeholder, error fallback.
- `TrackListTile` — standard song row (title, artist, album, duration, overflow menu).
- `AlbumCard` — grid card (cover art, album name, artist name).
- `ArtistCard` — list row or card (artist image, name, album count).
- `StarButton` — animated like/unlike toggle (heart icon).
- `CacheBadge` — "Cached" / "Downloaded" / "Temporary" indicators.

### 3.4 — Context Menus & Actions

Long-press (or trailing icon menu) on any song, album, or artist triggers a bottom sheet with contextual actions:

**Song context menu**:
- Play Next
- Add to Queue
- Add to Playlist...
- Go to Album
- Go to Artist
- Like / Unlike
- Download for Offline
- Share (copy Subsonic link)

**Album context menu**:
- Play
- Shuffle
- Play Next
- Add to Queue
- Like / Unlike
- Download for Offline
- Go to Artist

**Artist context menu**:
- Play All
- Shuffle All
- Like / Unlike

### 3.5 — Localization Setup

From this phase onward, all user-facing strings go into `app_en.arb`. Build the `AppLocalizations` pattern now — retrofitting string extraction later is painful.

- Configure `l10n.yaml` at the project root: `arb-dir: lib/l10n`, `template-arb-file: app_en.arb`, `output-localization-file: app_localizations.dart`.
- Enable `generate: true` in `pubspec.yaml`.
- Create `lib/l10n/app_en.arb` with all Phase 3 user-facing strings.
- All widgets use `AppLocalizations.of(context)!.stringKey` — no hardcoded strings.

---

## Phase 4: Audio Playback Engine

**Goal**: High-quality audio playback with background support, gapless transitions, and queue management.

### 4.1 — NavisAudioHandler

**Location**: `lib/src/features/player/data/navis_audio_handler.dart`

Extends `audio_service`'s `BaseAudioHandler` with `QueueHandler` and `SeekHandler` mixins.

**Internal state**:
- `AudioPlayer` from `just_audio` — the actual audio engine.
- `ConcatenatingAudioSource` — the playback queue as an audio source list for gapless playback.

**Source resolution per track**:
1. Check `CacheDao` — if track is pinned offline with a local file → `AudioSource.file(path)`.
2. Check `CacheDao` — if track has a playback cache file → `AudioSource.file(path)`, update `lastAccessedAt`.
3. Otherwise → `LockCachingAudioSource(streamUrl, headers: authHeaders, cacheFile: File(rollingCachePath))` — streams from server and simultaneously caches to disk at a path controlled by the app inside the rolling cache directory.

**Rolling cache integration**: When `LockCachingAudioSource` finishes downloading a track, the `NavisAudioHandler` registers the cached file with `RollingCacheManager.registerTrack(songId, filePath, fileSize, format, bitRate)`. The manager inserts a row into `cached_tracks` with `cacheType = 'rolling'` and runs LRU eviction if the rolling cache exceeds its size limit. On subsequent plays, step 2 above finds the file via `CacheDao` and serves it directly as `AudioSource.file()` — no network needed. This is documented in detail in `docs/caching.md`.

`streamUrl` is built by `SubsonicApiClient.streamUrl(id)` with optional `maxBitRate` and `format` params based on user settings and current network type (Wi-Fi vs cellular).

**Queue operations** (exposed as methods on the handler):
- `playFromQueue(index)` — jump to a specific queue position.
- `addToQueue(songs)` — append to end.
- `playNext(songs)` — insert after current track.
- `removeFromQueue(index)` — remove by position.
- `reorderQueue(oldIndex, newIndex)` — drag-to-reorder.
- `clearQueue()` — clear everything.
- `replaceQueue(songs, startIndex)` — replace entire queue (used for "Play Album" etc.).
- Shuffle mode and repeat mode (off, one, all) toggled via standard `audio_service` controls.

**Scrobbling**:
- When a track has been playing for > 50% of its duration OR > 4 minutes (whichever is first), call `scrobble(id, submission: true)`.
- At the start of each track, call `scrobble(id, submission: false)` (the "now playing" notification to the server).
- Configurable: user can disable scrobbling in Settings.

**Play queue persistence**:
- On every track change, save the current queue, current track index, and playback position to the local drift `play_queue` and `play_queue_items` tables.
- **Periodic position persistence**: Save the current playback position every 10–15 seconds to the `play_queue` table (update `positionMs` and `updatedAt`). This ensures that if the app is killed by the OS mid-track, the user can resume close to where they left off — not from the start of the track.
- On app launch, restore the queue and offer to resume (or auto-resume based on a setting).
- Cross-device queue sync is intentionally out of product scope; queue persistence remains local-only.

**Audio focus** (via `audio_session`):
- Duck volume when receiving transient interruptions (navigation prompts, notifications).
- Pause on prolonged interruptions (phone calls, other media apps).
- Resume after transient interruptions end.

### 4.2 — Play Queue Persistence

While the queue data model and save triggers are implemented in 4.1, restoration behavior remains a distinct deliverable:

- Restore queue on app launch from drift `play_queue` + `play_queue_items`.
- Resume playback position from `positionMs` — seek to saved position.
- Queue state remains local-only (`play_queue` + `play_queue_items`) and restores on launch.

### 4.3 — Streaming Quality

The `NavisAudioHandler` observes the current network type via `connectivity_plus` and resolves stream URLs using the matching quality profile from Settings.

- **Wi-Fi profile**: uses the Wi-Fi streaming quality and Wi-Fi transcode format settings.
- **Non-Wi-Fi profile**: uses the Non-Wi-Fi (cellular) streaming quality and format settings.
- Default: Wi-Fi = Original (no transcoding), Non-Wi-Fi = 192 kbps MP3.
- When the network type changes mid-playback, the current track continues at its original quality. The next track in the queue uses the new profile.
- If both quality and format are "Original", no `maxBitRate` or `format` params are added to the stream URL — the server sends the original file.

### 4.4 — Audio Quality Details

`just_audio` decodes FLAC, ALAC, MP3, AAC, Opus, Vorbis natively on both Android and iOS. No custom codec work needed.

Implementation status note (2026-02-21):
- Deterministic codec-path verification is now covered in automated tests (`playback_source_resolver_test.dart` matrix for file/lock-cached/direct and `navis_audio_handler_test.dart` fallback semantics).
- `tool/check.sh` includes codec-critical tests in the critical reliability stage.
- Real-device runtime verification remains required per `docs/troubleshooting.md` matrix runbook before Phase 5 sign-off.

**Android-only features** (conditionally exposed in settings):
- Equalizer via `just_audio`'s `AndroidEqualizer` — user-adjustable frequency bands.
- Loudness enhancer via `AndroidLoudnessEnhancer`.
- Skip-silence is intentionally not exposed for music playback.

These are gated behind platform checks and hidden on iOS.

**ReplayGain** (volume normalization):
- Deferred to post-Phase-5. Current Phase 4 closure excludes ReplayGain due server metadata variability and validation risk.

---

## Phase 5: Now Playing & Lyrics

**Goal**: Polished now-playing experience with synced lyrics support.

### 5.1 — Mini Player

A compact bar that sits above the `NavigationBar` in the shell scaffold. Always visible when something is in the queue.

**Layout**: Cover art thumbnail (40x40) | Track title + Artist (marquee / scrolling text if too long) | Play/Pause button | Small linear progress bar along the bottom edge.

**Interactions**:
- Tap anywhere (except play/pause) → expand to full Now Playing screen.
- Swipe up → expand to full Now Playing screen (animated transition).
- Swipe left/right → skip to next/previous track.

### 5.2 — Now Playing Screen

Embedded as an expanding overlay sheet within the `AppShell`, not a separate route. The `ExpandablePlayerSheet` widget manages the animated transition between mini player and full Now Playing. The bottom navigation bar hides when expanded.

**Layout (top to bottom)**:
1. Down-chevron to collapse back to mini player.
2. Large cover art (fills available space above controls). Lyrics toggle replaces cover art in the same region — no layout shift.
3. Track title (bold, larger font) — marquee if too long.
4. Artist name — album name.
5. Seek bar with elapsed time (left) and remaining time (right). Draggable.
6. Control row: Shuffle | Previous | Play/Pause (large, prominent) | Next | Repeat mode.
7. Bottom action row: Like button (heart icon) | Lyrics button | Queue button | Overflow menu (go to album, go to artist).

**Navigation gestures**:
- Swipe down on Now Playing → collapse to mini player.
- Swipe up on Now Playing → open queue screen.
- Back button / system back → collapse to mini player.
- Down arrow button → collapse to mini player.

**Animations**:
- Smooth crossfade transition between mini player and full Now Playing via `AnimationController`.
- Mini player fades out while full player fades in during expansion.
- Bottom navigation bar hides/shows with the expansion state.

### 5.3 — Lyrics

Lyrics support is a core feature, not an afterthought.

**Data fetching strategy**:
1. When a track starts playing, check `ServerCapabilities` for `getLyricsBySongId` (OpenSubsonic extension).
2. If supported → call `getLyricsBySongId(id)`. This returns `StructuredLyrics` which may contain multiple lyrics entries (different languages, synced vs unsynced).
3. If not supported → fall back to `getLyrics(artist, title)` which returns plain unsynced lyrics.
4. Cache the result locally (in-memory or drift) to avoid re-fetching on repeat plays.

**Synced lyrics display**:
- Full-screen or half-screen overlay on the Now Playing screen (toggled by the lyrics button).
- Lines displayed in a scrollable list.
- Current line highlighted (larger font, primary color) and auto-scrolled to center.
- Past lines dimmed. Upcoming lines in normal weight.
- Tap on a lyric line → seek playback to that timestamp.
- Use `scrollable_positioned_list` for smooth programmatic scrolling to the active line.

**Unsynced lyrics display**:
- Plain scrollable text view (no auto-scrolling since there are no timestamps).
- User can manually scroll.

**No lyrics available**:
- Show a subtle message: "No lyrics available" with no further UI clutter.

**Lyrics view toggle**:
- On Now Playing screen, tapping the lyrics button swaps between cover art and lyrics within the same `Expanded` region. The controls below (track info, seek bar, transport, action row) remain in a fixed position — toggling lyrics never shifts any other UI element.

### 5.4 — Queue Screen

Accessible from Now Playing via the queue button. Shows as a bottom sheet or separate route.

- Currently playing track highlighted at the top.
- "Up Next" section: list of upcoming tracks.
- Drag handles on each row for reorder.
- Swipe-to-remove on each row.
- "Clear Queue" action.
- "Save as Playlist" action — prompts for playlist name, calls `createPlaylist`.
- Each track row: cover art thumbnail, title, artist, duration, drag handle.

---

## Phase 6: Search

**Goal**: Fast, live search across the server's music library.

### Search Screen (`/search`)

- Search bar at the top with autofocus when navigated to.
- Debounced input: 300ms delay before firing `search3()` to avoid hammering the server on every keystroke.
- **No caching of search results** — always hits the live API.
- Results grouped into three sections: **Artists**, **Albums**, **Songs** — each showing the top 5 results with a "Show all" link that expands to full results.
- Empty state: show recent searches from `recent_searches` table. Tapping a recent search re-executes it.
- Clear recent searches button.

**Result interactions**:
- Tap an artist result → artist detail screen.
- Tap an album result → album detail screen.
- Tap a song result → play immediately, queue remaining song results.
- Long-press any result → context menu (same as library context menus).

**Pagination**: For "Show all" expanded results, paginate using `search3` offset params. Load more on scroll.

---

## Phase 7: Playlists

**Goal**: Full playlist management — view, create, edit, delete, reorder.

### Playlists List Screen (`/playlists`)

- List of all playlists from local DB (synced from server).
- Each row: cover art (mosaic of first 4 track covers, or playlist cover if server provides one), playlist name, track count, total duration.
- "Create Playlist" floating action button.
- Pull-to-refresh to re-sync playlists from server.

### Playlist Detail Screen (`/playlists/:id`)

- Header: playlist cover art, name, description, track count, total duration.
- Action row: Play, Shuffle, Download for Offline, Edit, Delete.
- Track list with drag-to-reorder (sends `updatePlaylist` to server on drop).
- Swipe-to-remove (sends `updatePlaylist` with updated song list).
- Each track row: standard song layout with context menu.

### Create / Edit Playlist

- Dialog or screen with name field and optional description.
- Create: calls `createPlaylist(name)`.
- Adding songs: from any song/album/playlist context menu → "Add to Playlist" → picker showing all playlists + "Create New".

### Sync

- Playlist metadata synced during the main sync engine run.
- Playlist songs (membership and order) fetched on-demand when the user opens a playlist (`getPlaylist(id)` → store in `playlist_songs` table).
- Changes (add, remove, reorder) sent to server immediately and also reflected in local DB.

---

## Phase 8: Offline & Cache Management

**Goal**: A dual-layer cache system — rolling cache for automatic playback caching with LRU eviction, and permanent cache for user-pinned offline content. The two have independent storage budgets.

### 8.1 — Rolling Cache (Automatic)

Every track streamed via `LockCachingAudioSource` is automatically cached to disk as it plays. This is transparent to the user — subsequent plays of the same track skip network loading. Tracks in the rolling cache are evicted automatically when space is needed.

**RollingCacheManager** (`lib/src/features/downloads/data/rolling_cache_manager.dart`):
- Tracks all rolling-cached files in drift `cached_tracks` table with `cacheType = 'rolling'`.
- Enforces a configurable max size (default 2 GB, adjustable in Settings).
- When the cache exceeds the limit, evicts the least-recently-accessed rolling-cache files until under the limit.
- **Rolling cache storage is independent of permanent cache storage.** If the user sets a 2 GB rolling cache limit and has 5 GB of permanent downloads, they still get the full 2 GB of rolling cache.
- Exposes: `currentRollingCacheSize`, `maxRollingCacheSize`, `clearRollingCache()`, `removeTrackFromRollingCache(songId)`.
- The quality/format of rolling-cached files matches whatever the user streamed (determined by Wi-Fi vs cellular quality settings at the time of playback).

### 8.2 — Permanent Cache / Offline Pinning (User-Driven)

Users explicitly choose what to keep permanently for offline playback. Permanent cache is never evicted by the rolling cache manager — it is only removed by the user.

**Pinning options**:
- Pin a single song (from context menu, now playing, or the "Offline Only" view for rolling-cached songs).
- Pin an entire album (from album detail or context menu).
- Pin an entire playlist (from playlist detail or context menu).

**Quality choice at pin time**:
When the user chooses to pin content, show a quality selection dialog:
- **Original quality** — downloads the original file via the `download` endpoint (FLAC, etc.). Largest file size. Best quality.
- **High (320 kbps)** — downloads via `stream` endpoint with `maxBitRate=320`.
- **Medium (192 kbps)** — `maxBitRate=192`.
- **Low (128 kbps)** — `maxBitRate=128`.
- **Use default** — uses the setting from Settings > Downloads > Default offline quality.

The chosen quality is stored in the `cached_tracks` table so the UI can display it.

### 8.3 — Download Queue System

All permanent cache downloads go through a managed download queue.

**Download queue** (`lib/src/features/downloads/data/download_queue_manager.dart`):
- When the user pins a song/album/playlist, individual track download tasks are added to the `download_queue` table.
- Queue is processed sequentially (or up to N concurrent, configurable: 1/2/3/5 in Settings).
- Uses `background_downloader` per track — downloads survive app kill and device restart.
- Each task tracks: `songId`, source (album/playlist/individual), quality, format, status (queued / downloading / paused / complete / failed), progress percentage.
- Failed downloads auto-retry up to 3 times with exponential backoff, then marked as failed for user review.
- **Wi-Fi only downloads**: configurable in Settings. If enabled, queued downloads wait until Wi-Fi is available. If the device switches from Wi-Fi to cellular mid-download, the active download pauses and resumes when Wi-Fi returns.
- **Platform caveat handling**: iOS background tasks can expire and paused tasks may not always restore resume data after restart. Queue manager must detect this and fall back to clean re-queue/retry with clear user-visible status.

**Download Queue Screen** (`/downloads`):
Accessible from Settings or a dedicated navigation entry.

Three sections in a tabbed or segmented layout:

1. **Queue** — active and queued downloads:
   - Each row: track name, album art thumbnail, quality badge, progress bar (for active), status badge (queued/paused/failed).
   - Swipe-to-cancel individual tracks.
   - Long-press or multi-select to cancel entire albums or playlists from the queue.
   - "Pause All" / "Resume All" bulk actions.
   - Drag-to-reorder queue priority.
   - Failed downloads shown with a retry button.

2. **Downloaded** — permanently cached content:
   - Grouped by album or playlist (however the user pinned it), with individual songs listed under each.
   - Each item shows: file size, quality/format badge, date downloaded.
   - Swipe-to-remove individual songs. Remove entire album/playlist via overflow menu.
   - "Remove All" with confirmation dialog.

3. **Storage** — overview:
   - Rolling cache: "X.X GB / Y GB" with a progress bar and "Clear" button.
   - Permanent cache: "X.X GB" with breakdown by album/playlist.
   - Cover art cache: "X MB" with "Clear" button.
   - Total storage used by Navis.
   - Available device storage.

### 8.4 — Offline Mode & "Offline Only" Filter

**Offline mode** (automatic):
- When the device is offline (detected via `connectivity_plus`), the library UI shows an "Offline" banner and filters to only content available locally (both rolling cache and permanent cache).

**"Offline Only" filter** (manual):
- A toggle in the Library screen (chip or switch) that filters to offline-available content even when online.
- Songs from the **permanent cache** display normally with a download/pin icon.
- Songs from the **rolling cache** display with a distinct "temporary" badge (e.g., a clock icon or "Cached" chip) to clearly communicate they may be evicted.
- Rolling-cached songs in this view have an action to:
  - **"Keep Permanently"** — promotes the existing rolling cache file to permanent cache (moves the file, updates `cacheType` from `rolling` to `permanent` in the DB). No re-download needed. The file retains whatever quality it was streamed in.
  - **"Download in Original Quality"** — if the rolling cache file was transcoded (e.g., 192 kbps on cellular), the user can choose to download the original quality file instead. This queues a fresh download via the download queue and removes the rolling cache copy once the permanent download completes.

### 8.5 — Cover Art Cache

Handled by `cached_network_image` and its underlying `flutter_cache_manager`.

- Thumbnails: `getCoverArtUrl(id, size: 300)` — used in lists, grids, mini player.
- Full size: `getCoverArtUrl(id)` — used in Now Playing, album detail header.
- LRU eviction managed automatically by `flutter_cache_manager`.
- Configurable max size in Settings (default 500 MB).

### 8.6 — Smart Cache Behaviors

- If a user plays a permanently cached track that was downloaded in a lower quality, and they are on Wi-Fi, the app streams the original quality from the server for playback (configurable: "Always use best available" in Settings).
- When an album is pinned, new tracks added to that album on the server are auto-detected during sync and queued for download at the same quality the album was originally pinned in.
- Pinning an artist pins all their current albums. New albums by the artist are NOT auto-pinned (to avoid surprises), but a notification could suggest it.

---

## Phase 9: Settings

**Goal**: Well-organized settings screen following Material 3 patterns. Grouped into logical sections.

### Settings Screen Structure

The main settings screen is a list of setting groups. Tapping a group navigates to a detail screen. Simple toggles can be inline.

**Server**
- Server name, URL, username (display only).
- "Test Connection" button.
- "Sign Out" → clears credentials, returns to login.
- Server capabilities summary (what the server supports).

**Playback — Streaming Quality**

Split into Wi-Fi and Non-Wi-Fi (cellular / mobile data) profiles. The app detects the active network type via `connectivity_plus` and applies the corresponding profile in real-time (mid-queue, the next track uses the new profile; the current track continues at its original quality).

- **Wi-Fi streaming quality**: Original (no transcoding) / 320 kbps / 256 kbps / 192 kbps / 128 kbps.
- **Wi-Fi transcode format**: Original / MP3 / Opus. Only applies when a bitrate limit is set (selecting "Original" quality ignores this).
- **Non-Wi-Fi streaming quality**: Original / 320 kbps / 256 kbps / 192 kbps / 128 kbps. Defaults to 192 kbps.
- **Non-Wi-Fi transcode format**: Original / MP3 / Opus. Defaults to MP3.
- When both quality and format are "Original", the `stream` URL has no `maxBitRate` or `format` params — the server sends the original file untouched.
- A summary label shows the active profile: e.g., "Currently streaming: Original (Wi-Fi)" or "Currently streaming: 192 kbps MP3 (Cellular)".

**Playback — General**
- Gapless playback: on/off (on by default).
- ReplayGain / volume normalization: deferred post-Phase-5.
- Scrobble to server: on/off, threshold slider (50–90%).
- Resume on launch: on/off — whether to auto-restore the last play queue.
- Show Radio page: on/off (default on).

**Audio** (Android only section, hidden on iOS)
- Equalizer: toggle + frequency band sliders.
- Loudness enhancer: toggle + gain slider.

**Downloads & Cache**
- Default offline download quality: Original / 320 / 192 / 128 kbps. Used when the user selects "Use default" at pin time.
- Default offline transcode format: Original / MP3 / Opus.
- Wi-Fi only downloads: on/off. When on, queued downloads pause on cellular and auto-resume on Wi-Fi.
- Max concurrent downloads: 1 / 2 / 3 / 5.
- **Rolling cache size limit**: slider (500 MB / 1 GB / 2 GB / 5 GB / 10 GB / Unlimited). Default 2 GB. This is independent of permanent cache storage.
- Current rolling cache usage + "Clear Rolling Cache" button.
- Permanent cache usage (with breakdown link → Downloads screen).
- Cover art cache usage + "Clear" button.
- Total storage used by Navis.
- "Manage Downloads" link → navigates to the Download Queue Screen.
- "Always use best available quality for cached tracks": on/off. When on and on Wi-Fi, streams original quality even if the local permanent cache file is transcoded.

**Appearance**

Theme mode and color scheme are independent settings, giving users full control over the visual style.

*Phase alignment note*:
- App default is dark mode from early development (pre-Phase 9) to prioritize mobile listening UX and reduce eye strain in low-light usage.
- Full appearance controls remain in Phase 9 scope: Light/Dark/OLED/System selector, quick Light Mode toggle in settings, and complete persisted theme preferences.

*Theme mode*:
- **Light** — standard light theme.
- **Dark** — standard dark theme with dark gray surfaces.
- **OLED / Pure Black** — dark theme with true `#000000` backgrounds and surfaces. Saves battery on AMOLED screens.
- **System** — follows the device's light/dark setting. When System is selected and the device is in dark mode, a sub-option controls whether to use Dark or OLED.

*Color scheme*:
- **Dynamic** (default on supported devices) — derives the color palette from the OS wallpaper / accent color via `dynamic_color`. Falls back to a built-in default on unsupported devices.
- **Preset themes** — a curated selection of `flex_color_scheme` palettes (e.g., Material Blue, Deep Purple, Teal, Indigo, Sakura, etc.). Shown as a grid of color swatches the user taps to preview and select.
- **Custom** — user picks a primary seed color from a color wheel or hex input. `flex_color_scheme` generates a full M3 `ColorScheme` from that seed, applied to both light and dark variants.
- **Mode-aware palette variants** — maintain independent palette selections for light and dark families so switching Light/Dark keeps intentional colorways in each mode instead of forcing one shared palette.

*Additional*:
- Theme preview: changing either setting immediately previews the result in real-time. No "Apply" button needed.
- Album art-tinted Now Playing: optional setting where the Now Playing screen's background tint is derived from the dominant color of the current track's cover art (computed once per track, cached).

**AudioMuse AI** (shown only when integration is available or for configuration)
- Enable AudioMuse: on/off.
- AudioMuse server URL: text field.
- Connection status indicator.

**About**
- App version and build number.
- Open-source licenses (Flutter's built-in license page).
- Links: source code repository, issue tracker.

---

## Phase 10: Polish & Platform Integration

**Goal**: Quality-of-life features that elevate the app from functional to polished. Note: localization string extraction, skeleton/shimmer loading, and error/empty state widgets are built in Phase 3 and used throughout all subsequent phases — they are not deferred to this phase.

### Animations & Transitions

Use Flutter's built-in animation primitives (`AnimationController`, `CurvedAnimation`, `CustomTransitionPage`) for all transitions — the `animations` package is not needed:

- Hero animation for cover art: album grid → album detail. `HeroCoverArt` widget wraps `CoverArtImage` with a `Hero`; `buildCoverArtHeroTag()` generates a consistent tag from `coverArtId + context`. Tags wired in library album grid and home carousels. **Implemented.**
- Mini Player → Now Playing expansion: velocity-aware `AnimationController.fling()` with `Curves.fastEaseInToSlowEaseOut`; full-player fades in from 10%, mini-player fades out by 25%. **Implemented.**
- Page transitions: `_slideFadePage` helper (`CustomTransitionPage`) provides 5% slide-up + fade-in (280ms) on push, fade-out (220ms) on pop, applied to all detail and settings sub-routes. `SharedAxisTransition`/`FadeThroughTransition` from the `animations` package are not used — custom transitions provide equivalent quality without the extra dependency.
- Skeleton loading placeholders (shimmer) while data loads, not spinners. `ShimmerPlaceholder`, `ShimmerListTile`, and `ShimmerListPage` widgets cover all list/grid screens. **Audit complete — all screens use shimmer.**
- Pull-to-refresh with Material 3 refresh indicator. **Implemented on all list screens.**

### UI/UX Polish Track (Pre-Phase-5 Attention)

- Album art presentation pass:
  - Improve visual treatment of cover art cards (consistent crop behavior, corner radius, shadow depth, spacing rhythm, and text contrast overlays where needed).
  - Add progressive image loading polish (placeholder -> image fade-in, reduced layout shift).
  - Ensure visual consistency between Home carousels, Albums grid, Album detail hero, and mini-player artwork.
- Interaction polish:
  - Add optimistic UI for star/unstar and queue/cache actions with rollback on failure.
  - Standardize success/failure feedback timing to avoid jittery snackbars and repeated status flashes.
- Motion polish:
  - Add intentional micro-transitions for list-to-detail navigation and queue mutations.
  - Keep transitions snappy and deterministic (no long spring tails on routine actions).
- Design-system consistency:
  - Normalize spacing, typography hierarchy, icon sizing, and hit targets across Home, Library, Search, and Settings.
  - Audit all reusable tiles/cards so visual behavior is uniform in loading/error/empty/data states.

### Performance

- Large library support: test with 10,000+ tracks. `SliverList` / `SliverGrid` with lazy building.
- Image loading: thumbnails only load when visible (automatic with `cached_network_image` in a `ListView`). No full-size images in grids.
- Sync engine runs in a background isolate — zero UI jank.
- Provider auto-dispose: providers for screens that are no longer in the navigation stack are automatically cleaned up.
- Debounced search input and scroll-based lazy loading.
- Const constructors on all stateless widgets and widget subtrees where possible.

### Error Handling UX

- **Transient errors** (network timeout, temporary server error): Snackbar with retry action.
- **Auth errors** (expired token, wrong password): Dialog forcing re-login.
- **Server unreachable**: Offline banner with automatic retry. Browsing cached content still works.
- **Empty states**: Friendly, non-generic messages. E.g., "No albums found" with a suggestion to check the server, not just a blank screen.
- **Loading states**: Skeleton shimmer for lists/grids. Circular indicator only for full-screen waits.

### Accessibility

- Semantic labels on all interactive elements and icons.
- Sufficient contrast ratios per WCAG 2.1 AA.
- Screen reader tested navigation flows.
- Touch targets minimum 48x48 dp.
- Focus traversal order makes sense for keyboard/switch navigation.

### Localization Setup (started in Phase 3, audited here)

- Configure `flutter_localizations` (SDK dependency) and the `intl` package.
- Enable `generate: true` in `pubspec.yaml` for synthetic localization code generation.
- Create `lib/l10n/` directory with `app_en.arb` as the primary ARB file.
- All user-facing strings extracted to ARB files using `AppLocalizations.of(context)!.stringKey` pattern.
- Use ICU message syntax in ARB files for plurals and parameterized strings.
- Ship with English. Structure supports adding languages later by adding `app_xx.arb` files.
- Configure `l10n.yaml` at the project root: `arb-dir: lib/l10n`, `template-arb-file: app_en.arb`, `output-localization-file: app_localizations.dart`.
- **Phase 10 audit**: Review all screens for hardcoded strings that missed extraction. Verify plural forms. Ensure no string concatenation — use ICU message parameters instead.

### Haptic Feedback

- Light haptic on like/unlike.
- Medium haptic on skip track.
- Selection haptic on long-press context menu open.

### Android Platform Integration

- **Edge-to-edge (Android 15+/16+)**: Android 15 enforces edge-to-edge by default, and Android 16/API 36 no longer allows opting out via `SystemChrome.setEnabledSystemUIMode`. All screens must account for system bar insets. Use `SafeArea` or `Scaffold` inset handling, and test on Android 15 and Android 16 emulators to verify no content is hidden behind status/navigation bars or gesture areas.
- **Predictive back gesture (Android 13+)**: With `enableOnBackInvokedCallback` enabled, swipe-back shows a preview of the previous screen. Ensure `go_router`’s navigator cooperates with the system back gesture — `PopScope` (replaces deprecated `WillPopScope`) should be used for screens that need to intercept back (e.g., confirming discard of unsaved playlist edits). Test that the mini-player and bottom sheet Now Playing dismiss correctly with predictive back.
- **Runtime permissions**: Request `POST_NOTIFICATIONS` (API 33+) before posting download notifications. Use `permission_handler` or manual platform channels. Show a rationale dialog explaining why notifications are needed.

### Logging & Diagnostics

- Use the `Logger` singleton initialized in Phase 0 throughout all layers:
  - **API layer**: Log request URLs and response status codes (no bodies or credentials). Redact auth query params before logging.
  - **Sync engine**: Log sync start, per-entity counts fetched/inserted, sync duration, errors.
  - **Audio handler**: Log track transitions, source resolution (cache hit vs stream), playback errors.
  - **Cache manager**: Log eviction events (which files removed, bytes freed, new cache size).
  - **Download queue**: Log download start, progress milestones (25/50/75/100%), failures with error details.
- In release builds, set log level to `Level.warning` to suppress debug noise.
- Logs are ephemeral (console only). No persistent log files shipped to production. If needed later, a log-to-file mechanism can be added behind a developer setting.

### Crash Recovery

- **Download queue recovery**: On app launch, check `download_queue` for tasks with status `downloading`. These were interrupted by an app kill. Reset them to `queued` and let the download manager re-attempt. `background_downloader` handles native-level resumption for partially downloaded files.
- **Sync engine recovery**: If the app was killed mid-sync, the `lastSynced` timestamp was never updated. On next launch, the sync engine detects the stale timestamp and re-runs the sync from where it can (it’s idempotent — re-inserting data uses `INSERT OR REPLACE`).
- **Database integrity**: On first launch after a crash, drift’s database will already be in a consistent state (SQLite is ACID-compliant). No manual recovery needed. If the database file is corrupted (extremely rare), detect the open failure and offer to reset the local database (re-sync from server).
- **Play queue**: The periodic position save (every 10–15s) ensures minimal data loss on crash. On relaunch, the `play_queue` table has the last known state.

### In-App Update Checker

The app checks for updates against the project's Forgejo Releases API. No app store dependency, no third-party services — just the same Forgejo server that hosts the source code.

**Implementation**:

- `UpdateRepository` in `lib/src/features/settings/data/`:
  - Calls `GET https://{forgejo-host}/api/v1/repos/{owner}/{repo}/releases` on app launch.
  - Throttled to once per 24 hours (tracked via `shared_preferences`).
  - Parses release tags. Filters by pre-release flag based on the user's chosen update channel.
  - Compares latest remote version against the local version from `package_info_plus`.
  - Returns `UpdateInfo?` — null if up to date, populated if an update exists.

- `updateProvider` — `@riverpod` async provider that calls `UpdateRepository.checkForUpdate()`. Auto-disposes.

- **Settings** (under "About" or a dedicated "Updates" subsection):
  - "Update channel": **Stable** (default — only non-prerelease tags) or **Beta** (includes `-alpha`, `-beta`, `-rc` tags).
  - "Check for updates": on/off toggle (default on).
  - "Check now" button for manual checks.

- **UI**:
  - Non-intrusive banner at the top of the Home screen when an update is available: "Navis vX.Y.Z available" with a dismiss button and an "Update" button.
  - "Update" button on Android: opens the browser to the Forgejo release page where the user can download the APK. If the `REQUEST_INSTALL_PACKAGES` permission and a `FileProvider` are configured, optionally download the APK directly and trigger Android's package installer intent.
  - On iOS: opens the browser to the release page (direct install not possible outside App Store / TestFlight).
  - Settings > About shows current version and update status.

- **Forgejo URL configuration**:
  - The Forgejo instance URL, repo owner, and repo name are compile-time constants in `lib/src/utils/constants.dart`. Not user-configurable — hardcoded to the project's Forgejo repo.

### 10.12 — Instant Mix

**Goal**: Let the user start an on-the-fly radio-style queue seeded by any song, using the OpenSubsonic `getSimilarSongs2` / `getInstantMix` endpoints.

**API**:
- `GET /rest/getSimilarSongs2?id={songId}&count=50` — returns songs similar to the given track (by Last.fm or Subsonic's built-in similarity engine, depending on server config).
- `GET /rest/getInstantMix?id={songId}&count=50` — same intent; some servers alias this. Prefer `getSimilarSongs2`; fall back to `getInstantMix` if the former returns an error.

**UX**:
- Entry points:
  - Now Playing screen: compass icon button (`Icons.explore`) placed alongside the queue button in `_ActionRow`.
  - Track context menu (long-press): "Start Instant Mix" menu item.
- Tapping "Instant Mix" calls the API, inserts the returned songs into the play queue after the current track (replacing any existing auto-queue tail), and immediately starts playing.
- Show a brief snackbar: "Instant Mix started — N similar tracks queued."
- If the server does not support the endpoint (404 / `70 Not Found`), show an error snackbar: "Instant Mix not supported by this server."

**Implementation**:
- `SubsonicApiClient.getSimilarSongs(String songId, {int count = 50}) → Future<List<Song>>` — new method.
- `AudioHandler.startInstantMix(String songId)` — calls the API, builds a `ConcatenatingAudioSource` tail, and inserts it after the current index.
- `instantMixProvider` — `@riverpod` future provider (fire-and-forget, exposes loading state for the button spinner).
- No persistent storage — Instant Mix is ephemeral and lives only in the current queue.
- The compass button is hidden when no song is currently playing or when the server is not connected.

---

## Phase 11: AudioMuse AI Integration

**Goal**: Optional AI-powered smart queuing and discovery, gated behind configuration. This is the differentiator.

This phase is developed after the core app (Phases 0–10) is complete and stable. AudioMuse integration is entirely modular — the app works fully without it.

### Architecture

**Location**: `lib/src/features/audiomuse/`

- `AudioMuseService` — API client for communicating with the AudioMuse server.
- `AudioMuseRepository` — wraps the service, handles errors, provides data to the UI.
- Riverpod provider `audioMuseAvailableProvider` — `bool`, whether AudioMuse is configured and reachable. All AudioMuse UI elements observe this and hide themselves when `false`.

### Configuration

- In Settings > AudioMuse AI:
  - Server URL text field.
  - API key field (if required).
  - "Test Connection" button.
  - Enable/disable toggle.
- Investigate whether the Navidrome AudioMuse plugin adds REST endpoints to the Navidrome server itself. If so, the client may only need the Navidrome URL (already known) plus plugin endpoint paths.

### Features (when enabled)

**Smart Auto-Queue**:
- When the play queue runs out of tracks, instead of stopping, AudioMuse provides AI-recommended tracks that flow naturally from what was playing.
- Alternatively, a "Smart Queue" button in the Now Playing / Queue screen that fetches recommendations and appends them.
- The queue appends 10-20 tracks at a time. When the user reaches the last few, auto-fetch more.
- Source: AudioMuse API call with the current track ID (and optionally recent play history) as context.

**Similar Content Discovery**:
- On Artist detail screen: "Similar Artists" section powered by AudioMuse (in addition to or replacing the Subsonic-provided similar artists).
- On Album detail screen: "You might also like" section.
- On Now Playing screen: "Similar tracks" in the overflow menu.

**Mix Generation**:
- "Create AI Mix" feature accessible from Home screen.
- User selects a seed (artist, album, genre, mood keyword) → AudioMuse generates a playlist of tracks from the user's library.
- Result presented as a temporary queue or saveable as a playlist on the server.

### Graceful Degradation

- Every AudioMuse UI element checks `audioMuseAvailableProvider` before rendering.
- If AudioMuse is not configured or unreachable, these elements simply don't appear. No error states, no empty placeholders — they're invisible.
- The "Similar Artists" section on an artist detail page falls back to Subsonic's `getArtistInfo2.similarArtist` data when AudioMuse is unavailable.
- The auto-queue feature, when AudioMuse is off, falls back to simple behavior: stop after the queue ends, or optionally loop, or play random songs from the library.

---

## Phase 12: Android Auto & CarPlay

**Status (2026-03-05)**: Backlog moved to **Phase 26** for priority-ordered execution. This section is retained for historical planning context.

**Goal**: Extend media playback to in-car displays. `audio_service` already provides the `MediaItem` foundation — this phase builds the browsable media tree and platform integrations for Android Auto and Apple CarPlay.

This phase is developed after the core app (Phases 0–10) is complete and stable. Android Auto and CarPlay integration is entirely modular — the app works fully without it.

### Architecture

**Location**: `lib/src/features/auto/`

- `AutoMediaLibraryService` — extends `NavisAudioHandler` to implement the browsable media tree. Overrides `getChildren()` and `getMediaItem()` for Android Auto's `MediaBrowserService`.
- `autoContentProvider` — Riverpod provider that constructs the `MediaItem` hierarchy (root → artists/albums/playlists → tracks).
- `CarPlayController` — manages the `MPPlayableContentDataSource` tab bar and content tree for iOS CarPlay via a platform channel.

### Android Auto

- Declare `android.media.browse.MediaBrowserService` in `AndroidManifest.xml` under the existing `AudioService` service tag with `android:exported="true"`.
- Add `android.hardware.type.automotive` as a `<uses-feature>` declaration with `required="false"`.
- Implement browsable root: Playlists, Artists, Albums as three top-level `MediaItem` tabs.
- Each tab expands into a list of items; artist items drill into albums; albums list their tracks.
- Queue operations (play, pause, next, previous, seek) are already handled by `NavisAudioHandler` — no changes required.
- Search support: implement `onSearch()` in the handler to forward queries to the existing search provider.

### Apple CarPlay

- Add `com.apple.developer.carplay-audio` entitlement to `Runner.entitlements` (requires Apple Developer program membership and CarPlay entitlement request for App Store submission).
- Implement `MPPlayableContentDataSource` and `MPPlayableContentDelegate` via a native Swift platform channel in `ios/Runner/`.
- Content tree mirrors the Android Auto hierarchy: root tabs → artists/albums/playlists → tracks.
- Voice-safe minimal UI: large tap targets (minimum 44 pt), no text input fields, navigation driven entirely by the content tree.
- Support Siri Shortcuts integration (`INPlayMediaIntent`) to allow voice-initiated playback.

### l10n

- Add l10n keys for "Artists", "Albums", "Playlists", "Queue", "Search" as used in `MediaItem` title strings for the Auto/CarPlay content tree.

### Graceful Degradation

- Android Auto integration is inert on non-automotive Android devices and on iOS.
- CarPlay integration is inert on non-CarPlay-connected iOS devices and on Android.
- The core app is completely unaffected when neither in-car platform is connected.
- If the browsable tree fails to load (network error), return a single error `MediaItem` with a user-readable message rather than crashing.

---

## Phase 13: Desktop Support (Windows, macOS, Linux)

**Status (2026-03-05)**: Backlog moved to **Phase 26** for priority-ordered execution. This section is retained for historical planning context.

**Goal**: First-class desktop builds with an adaptive layout for large screens, platform-native audio OS integration (SMTC / MPRIS / macOS media keys), and distributable packaging for each platform.

This phase is developed after Phase 10 and can be developed in parallel with Phase 11, as no Phase 11 code is required.

### Responsive Layout

**Location**: `lib/src/common_widgets/adaptive_shell.dart`

- `AdaptiveShell` widget using `LayoutBuilder`:
  - Width < 600 dp: `NavigationBar` at bottom (existing mobile layout).
  - Width ≥ 600 dp: `NavigationRail` on the left, content fills the remaining width.
  - Width ≥ 960 dp: side-by-side master-detail — navigation rail + list panel on the left, detail panel on the right (e.g., album list + album detail simultaneously visible).
  - Width ≥ 1200 dp: Spotify-style desktop shell — a simple left navigation column with an extended mini player docked directly under navigation, plus a dominant right content workspace for the active route.
- `go_router` shell route updated to use `AdaptiveShell` instead of the current `ScaffoldWithNavbar`.
- Window size and position persistence via the `window_manager` package: save width, height, and maximised state to shared preferences on resize, restore on launch.
- Minimum window size enforced: 480 × 600 px.

### Audio OS Integration

`just_audio` already runs on desktop. `audio_service` is Android/iOS only — desktop platforms require separate media key and now-playing integrations:

- **Windows**: `smtc_windows` package — integrates with the Windows System Media Transport Controls (SMTC). Provides thumbnail, track metadata, and hardware play/pause/next/previous key support. Bridged to `NavisAudioHandler` event stream.
- **Linux**: `mpris_service` package — exposes the `org.mpris.MediaPlayer2` D-Bus interface. Enables media key support and desktop environment now-playing widgets (GNOME Shell, KDE Plasma). Bridged to `NavisAudioHandler`.
- **macOS**: Platform channel calling `MPRemoteCommandCenter` and `MPNowPlayingInfoCenter`. Enables Control Centre now-playing widget, Touch Bar controls (older MacBooks), and hardware media key support.

### Packaging & Distribution

- **Windows**: MSIX package generated via the `msix` pub package. Configurable from `pubspec.yaml`. Signable with a self-hosted certificate or Microsoft Store certificate. CI artifact: `build/windows/runner/Release/*.msix`.
- **macOS**: App bundle produced by the Flutter toolchain. Required entitlements: `com.apple.security.network.client` (outbound networking), `com.apple.security.cs.allow-jit` (for Flutter engine). Notarisable via `xcrun notarytool` for Gatekeeper compliance. CI artifact: `build/macos/Build/Products/Release/Navis.app` (zipped).
- **Linux**: `.deb` package via `flutter_distributor` or manual `dpkg-deb`. Flatpak manifest for sandboxed distribution on Flathub. CI artifact: `build/linux/x64/release/bundle/` (tarball).

### Database

`drift` uses the `sqlite3` package which is compiled via `sqlite3_flutter_libs` on desktop — no schema or DAO changes are required.

### Key Package Additions

| Package | Platform | Purpose |
|---|---|---|
| `window_manager` | All desktop | Window size/position control and persistence |
| `smtc_windows` | Windows | SMTC now-playing and media key integration |
| `mpris_service` | Linux | D-Bus MPRIS media player interface |
| Platform channel (Swift) | macOS | `MPRemoteCommandCenter` / `MPNowPlayingInfoCenter` |
| `msix` | Windows | MSIX packaging |
| `flutter_distributor` | Linux | `.deb` / Flatpak packaging |

---

## Phase 14: Playback Quality & Reliability

**Development order note**: Complete this phase before starting Phases 12 (Android Auto) and 13 (Desktop). These are foundational audio and UX improvements that affect the entire playback pipeline.

Work through tasks in priority order within this phase: CRITICAL first, then HIGH, then MEDIUM. Do not start a lower-priority task until all higher-priority tasks pass verification.

### 14.1 — Skip Silence Toggle Removal (CRITICAL)

Remove the `skipSilenceEnabled` toggle from the Playback settings screen. `just_audio` does not support skip-silence for music playback; the toggle has no runtime effect and misleads users into thinking a feature is active when it is not. The DB column may remain as a migration artifact — simply do not expose it in the settings UI.

**Files to touch**: `lib/src/features/settings/presentation/playback_settings_screen.dart` — remove the `SwitchListTile` and any provider watch for `skipSilenceEnabled`. Remove the associated l10n key from `app_en.arb` if it becomes unused after removal.

### 14.2 — Position Persistence on Pause (CRITICAL)

The 15-second periodic position timer is the only current persistence trigger. If the app is killed immediately after the user pauses, up to 15 seconds of position is lost. Add an explicit `_persistQueueState()` call in the `pause()` override so position is always flushed at pause time.

**Files to touch**: `lib/src/features/player/data/navis_audio_handler.dart` — add `_persistQueueState()` in the `pause()` override alongside the existing stop/skip persistence calls.

### 14.3 — Lyrics Error State Distinction (CRITICAL)

The `_InlineLyrics` widget currently displays the same `lyricsNoneAvailable` message for three distinct situations:
1. The server does not support the lyrics endpoint.
2. A network or API error occurred while fetching.
3. The track has no lyrics in the server's database.

Each state needs an accurate user-facing message so users do not misinterpret a temporary network failure as permanent absence of lyrics.

**Files to touch**: `lib/src/features/player/presentation/now_playing_screen.dart` — update the `AsyncValue` error/data branch in the lyrics widget to differentiate exception types. `lib/l10n/app_en.arb` — add `lyricsError` ("Could not load lyrics. Check your connection.") and `lyricsUnsupported` ("Lyrics not supported by this server.") keys.

### 14.4 — ReplayGain Volume Normalization (CRITICAL)

Read `replayGain` data from the `Song` model and apply per-track gain normalization before each track starts. This prevents jarring volume jumps between tracks mastered at different levels.

**Required**:
- Confirm `replayGain` fields (`trackGain`, `albumGain`, `trackPeak`, `albumPeak`) are present in the `Song` Freezed model (the Subsonic API returns them). Add if missing.
- In `NavisAudioHandler`, before starting each track, compute the gain value from `song.replayGain` (prefer track gain, fall back to album gain, fall back to 0 dB) and apply via `_player.setVolume()` with an appropriate linear amplitude conversion.
- Add a **ReplayGain** setting in Settings > Playback > General: mode selector (Off / Track Gain / Album Gain; default Off) and a pre-amp slider (−6 dB to +6 dB, default 0 dB).
- l10n strings for the new settings entries.
- Schema migration: add `replayGainMode` (text enum: `off`/`track`/`album`) and `replayGainPreamp` (real, default 0.0) columns to `app_settings`.

### 14.5 — Playback Speed Control (HIGH)

Expose playback speed (0.5× to 2.0× in 0.25× steps) via `AudioPlayer.setSpeed()`. Surface the control in the Now Playing overflow menu or as a persistent chip near the seek bar.

- Persist selected speed in `AppSettings` (new `playbackSpeed` real column, default 1.0).
- Display current speed on the control as a text label (e.g., "1.5×").
- Reset to 1.0× on queue clear.
- Schema migration required.

### 14.6 — Crossfade / Gapless Conflict Guard (MEDIUM)

Enabling both `crossfadeEnabled` and `gaplessPlayback` simultaneously creates conflicting playback architectures. When both are enabled, show a warning chip in Playback settings explaining that the combination is unsupported and recommend disabling one. Optionally, auto-disable gapless when crossfade is turned on (and vice versa) to prevent the conflict silently.

### 14.7 — Playback Snapshot Granularity (MEDIUM)

`playerStateProvider` emits on every position tick (100–200 ms). Any widget that watches this full snapshot rebuilds at audio clock frequency. Derive targeted providers to reduce rebuild scope:
- `isPlayingProvider` — `bool`, derived from snapshot.
- `currentSongProvider` — `Song?`, derived from snapshot.
- `currentIndexProvider` — `int?`, derived from snapshot.

Update all widgets that only need is-playing state or current song metadata to watch a targeted provider. Widgets that render seek progress continue watching the full snapshot.

---

## Phase 15: Library & Discovery Enhancements

**Development order note**: Can be developed in parallel with Phase 14 for HIGH-priority tasks, but depends on Phase 14 being complete before this phase is signed off.

Work through tasks in priority order: HIGH → MEDIUM → LOW.

Scope guard: deeper genre-browsing expansion (`getSongsByGenre`-driven UI surfaces) is out of scope for the current roadmap and should not be scheduled in this phase.

### 15.1 — Starred / Favorites Screen (HIGH)

Add a dedicated **Favorites** screen that surfaces all starred content. Access point: a "Favorites" tab within the Library screen (alongside Albums, Artists), or a "Favorites" tile in the Home screen navigating to the full screen.

- Three sections: Starred Albums, Starred Artists, Starred Songs — each showing a scrollable list/grid.
- Data from `getStarred2()` API, synced to local DB during the standard sync engine run.
- Reactive: `star()` / `unstar()` actions on any screen immediately reflect here via drift stream queries.
- Pull-to-refresh re-fetches `getStarred2()` and updates local DB.
- Tap items navigate to the existing album/artist detail screens.

**Note**: The Home screen "Liked" carousel already uses `getStarred2()` for a limited subset. This screen is the full browsing surface.

### 15.2 — Download Progress on Browsing Tiles (HIGH)

Album tiles in the library grid should reflect download state without requiring navigation to the Downloads screen.

- Fully downloaded albums: a small completed-download badge (reuse existing `CacheBadge` pattern).
- Partially downloaded / actively downloading: a progress overlay or dot indicator driven by `downloadQueueProvider`.
- Updates reactively as downloads complete.

**Files to touch**: `lib/src/common_widgets/album_card.dart`, `lib/src/features/library/presentation/library_screen.dart` — wire `downloadedContentIdsProvider` and download queue state into album tile renderers.

### 15.3 — Pull-to-Refresh Consistency (MEDIUM)

Audit all browsable list and grid screens to confirm `RefreshIndicator` is present and correctly wired. Screens to audit: Library albums tab, Library artists tab, Home screen (section carousels), Artist detail albums grid, Genre detail. Add any missing `RefreshIndicator` wrappers and ensure they trigger the correct data re-fetch.

### 15.4 — Empty State Audit (MEDIUM)

Verify every content screen displays a meaningful `EmptyState` widget (not a blank screen) when:
- Library has never been synced.
- A filter ("Downloaded Only") leaves no matching content.
- A playlist is empty.
- Downloads list is empty.
- Favorites screen has no starred items.

The `EmptyState` widget already exists in `common_widgets/`. This is an audit and wiring pass to ensure consistent usage.

### 15.5 — Album Art Thumbnail Downsizing (MEDIUM)

In list and grid views, `CoverArtImage` should request appropriately sized thumbnails from the server and constrain in-memory decode size. Serving full-resolution art in album grid cells wastes significant memory with large libraries.

Guidelines by context:
- Album grid cards (small): server `size: 200` + `memCacheWidth: 200`.
- List rows (artists, tracks, search results): server `size: 80` + `memCacheWidth: 80`.
- Detail headers / Now Playing: server `size: 640` (unchanged).

Audit all `CoverArtImage` call sites and confirm the `size:` parameter is appropriately set for each context.

### 15.6 — Year / Decade Album Browsing (LOW)

Add a "By Year" option to the Albums tab sort/filter controls. Use `getAlbumList2(type: 'byYear', fromYear: X, toYear: Y)` to retrieve albums within a year range. A decade chip row (1960s, 1970s, ..., 2020s) provides intuitive filtering without requiring a custom date-range slider.

### 15.7 — Auto-Download Starred on Wi-Fi (LOW)

When the device connects to Wi-Fi (and Wi-Fi-only downloads is enabled), automatically enqueue downloads for starred albums and songs not yet permanently downloaded.

- Gate behind a new settings toggle in Settings > Downloads: "Auto-download starred on Wi-Fi" (off by default).
- Trigger in `ServerReachabilityProvider` when transitioning to online via Wi-Fi.
- Feeds the existing `DownloadService` queue — no separate download path.
- Schema migration: add `autoDownloadStarred` boolean column to `app_settings`.

### 15.8 — Rating UX/UI (HIGH)

Add first-class rating support so users can both view existing server ratings and update them from key surfaces.

- Wire `setRating(id, rating)` to rating controls on Song, Album, and Artist related contexts where actionable today (at minimum: Now Playing, track context menu, album detail).
- Show existing rating values from server metadata in list/detail UI (do not show a stale default when no rating exists).
- Define a clear rating interaction model: 0 (clear) and 1-5 star values.
- Ensure optimistic UI with rollback/error feedback on network failure, matching existing star/unstar UX standards.
- Persist and sync rating changes into local Drift rows used by offline/library rendering.
- Add focused tests for provider/controller logic and one widget-level rating interaction path.

### 15.9 — Rich Album Metadata (MEDIUM)

Enrich album detail with server-provided metadata from `getAlbumInfo2(id)` where available.

- Fetch and display richer album fields (for example: notes/description, external links, and metadata payload that is not present in base `getAlbum`).
- Keep current album detail layout resilient: hide sections when metadata is absent instead of showing placeholders.
- Cache enriched metadata locally to reduce repeated API calls and support offline revisit.
- Add manual refresh affordance on album detail to re-pull metadata when needed.
- Add tests for metadata parsing, DAO persistence, and the conditional UI states (present vs absent).

---

## Phase 16: Search & Offline Sync

**Development order note**: The CRITICAL task (16.1) should be addressed early — ideally alongside Phase 14 since it is a data-integrity bug, not a UI feature. The HIGH and MEDIUM tasks follow naturally.

Work through tasks in priority order: CRITICAL → HIGH → MEDIUM.

### 16.1 — Offline Star Sync Queue (CRITICAL)

Currently, `star()` / `unstar()` API calls that fail due to connectivity produce silent divergence: the local DB holds the new state but the server never receives the update. The optimistic UI (Phase 10) correctly flips the icon immediately, but connectivity failures are not queued for retry.

**Implementation**:
- Add a `star_sync_queue` Drift table: `itemId`, `itemType` (song/album/artist), `action` (star/unstar), `queuedAt`.
- When a `star()` / `unstar()` API call fails with `SubsonicConnectionException`, insert a row into `star_sync_queue` instead of silently dropping the operation.
- `ServerReachabilityProvider.onTransitionToOnline()` flushes the queue: re-issues each pending star/unstar in order, removes successfully processed rows.
- Schema migration required.

### 16.2 — Local / Offline Search (HIGH)

When the server is unreachable, `search3()` fails and the search screen shows an error. Fall back to a Drift-backed local search across the cached `artists`, `albums`, and `songs` tables using `LIKE '%query%'` pattern matching.

- Auto-detect offline state via `serverReachabilityProvider`.
- Show a subtle inline banner: "Searching local library (offline)" when the offline path is active.
- Offline search results navigate to the same detail screens as online results.
- No change to the online search path.

### 16.3 — Search Type Filters (MEDIUM)

Add a filter chip row below the search input: **All** | **Artists** | **Albums** | **Songs**. Selecting a filter sets the non-selected type counts to 0 in the `search3()` call and collapses the irrelevant result sections. State lives only for the lifetime of the current search session.

### 16.4 — Radio Offline / Error Handling (MEDIUM)

Improve radio stream failure modes:
- When ICY metadata is unavailable, display the station name (always known) in the mini player and Now Playing screen instead of showing empty metadata.
- On stream error (HTTP 503, connection reset, timeout), show a dismissible error snackbar ("Radio stream unavailable") and stop the stream rather than silently hanging.
- In `RadioMetadataService`, add dead-stream detection: if the now-playing metadata has not changed for 5+ consecutive polling cycles, reduce polling frequency and display the station name only.
- Distinguish "polling failed" from "no metadata available" — a polling failure must not clear metadata that was previously loaded successfully.

---

## Phase 17: Accessibility, Locale & Test Coverage

**Status (2026-03-05)**: Backlog moved to **Phase 23** for priority-ordered execution. This section is retained for historical planning context.

**Development order note**: All tasks in this phase are LOW priority. Complete Phase 16 before starting Phase 17. Tasks can be distributed across sessions as capacity allows.

### 17.1 — Seek Bar Accessibility Actions (LOW)

The Now Playing seek bar `Slider` already exposes `semanticFormatterCallback` (Phase 10.4). Add `SemanticsAction.increase` and `SemanticsAction.decrease` so screen reader users can step forward and backward in 10-second increments without gesturing directly on the slider track.

### 17.2 — In-App Locale Override (LOW)

Add a "Language" dropdown to Appearance settings that allows users to override the display locale explicitly, independent of the system locale. Store the selected locale code (e.g., `"en"`, `"fr"`) in `AppSettings`. Apply by passing the stored locale as `locale:` on `MaterialApp.router`. Supported locales enumerate from `AppLocalizations.supportedLocales`. Schema migration required.

Current product decision (2026-03-05): keep the Language control visible but disabled (non-changeable) while only English is supported. Keep persistence and wiring in place for future multi-language rollout.

### 17.3 — Widget & Integration Test Coverage (LOW)

Add missing test coverage for:
- `ExpandablePlayerSheet` animation lifecycle: open from mini player, close with back button, velocity-fling gesture.
- `InstantMixNotifier` auto-refill: verify the trigger fires correctly when remaining queue count drops to ≤ 3.
- `SmartQueueNotifier` if the architecture retains a distinct implementation.
- Auth-to-playback integration test using a mock Subsonic fixture: login → library sync → enqueue → play.

### 17.4 — Ghost File Cleanup (LOW)

`pruneMissingPermanentFiles()` already removes DB records for files deleted externally from disk. Add the complementary scan: on startup, enumerate the rolling cache and permanent cache directories and remove any files that do not have a corresponding `cached_tracks` row in the DB. Prevents accumulation of orphaned files from previous installs or interrupted writes.

---

## Phase 18: Platform Extensions

**Status (2026-03-05)**: Backlog moved to **Phase 27** for priority-ordered execution. This section is retained for historical planning context.

**Development order note**: All tasks are LOW priority. Complete Phase 17 before starting Phase 18. Phase 18 adds new platform surfaces — the core app must be fully stable before investing in platform extensions.

### 18.1 — Android Home Screen Widget (LOW)

A 4×1 Android `AppWidgetProvider` showing:
- Album art thumbnail.
- Track title and artist.
- Previous / Play-Pause / Next controls.
- Optional progress bar if the widget API permits it.

Use the `home_widget` pub package or a native Android implementation bridged via a platform channel. Widget actions call `NavisAudioHandler` through `audio_service`'s `AudioHandler.customAction()`.

### 18.2 — iOS Live Activity / Dynamic Island (LOW) *(Stretch Goal)*

Implement a Live Activity via the ActivityKit framework using a Flutter platform channel. Displays current track title, artist, and playback controls on the Dynamic Island and Lock Screen for iOS 16.1+. Graceful no-op on unsupported iOS versions. This is a stretch goal dependent on Flutter's evolving ActivityKit support.

---

## Phase 19: Lyrics Enrichment & External Sources

**Status (2026-03-05)**: Backlog moved to **Phase 25** for priority-ordered execution. This section is retained for historical planning context.

**Issue mapping**: Forgejo issue #16 (LRCLIB support)
**Issue status note (2026-03-05)**: closed because it was migrated to documentation.

**Development order note**: This phase is future work and should start only after Phase 18. It is independent from share-system work.

### 19.1 — Lyrics Source Priority Pipeline (HIGH)

Extend the lyrics flow with deterministic source priority so behavior is predictable and debuggable:

1. Subsonic/OpenSubsonic synced lyrics (`getLyricsBySongId`)
2. Subsonic/OpenSubsonic plain lyrics (`getLyrics` fallback)
3. LRCLIB synced lyrics
4. LRCLIB plain lyrics

Requirements:
- Keep existing `LyricsUnsupportedException` and `LyricsNetworkException` semantics.
- Add source metadata (`server_synced`, `server_plain`, `lrclib_synced`, `lrclib_plain`) so UI and diagnostics can explain where lyrics came from.
- Never replace already-loaded synced lyrics with plain lyrics unless explicitly refreshed.

### 19.2 — Strict Match Heuristics for LRCLIB (HIGH)

Issue #16 requires strict matching with low false positives. Implement a confidence-scored matcher:

- Normalize title/artist/album (trim, case-fold, punctuation folding, featuring-artist noise removal).
- Duration tolerance window (for example +/- 2 to 3 seconds).
- Penalize karaoke/live/remix suffix mismatches unless song metadata also contains those markers.
- Require minimum confidence threshold before accepting LRCLIB result.
- If below threshold, return "no lyrics found" rather than low-confidence lyrics.

This keeps behavior conservative across heterogeneous servers and metadata quality.

### 19.3 — Caching, Attribution, and Rate Control (MEDIUM)

Add a dedicated local cache for LRCLIB results to avoid repeated network lookups:

- Drift table for external lyrics cache (song key, normalized query signature, lyrics payload, synced flag, fetchedAt, source).
- TTL-based invalidation (for example 14 to 30 days).
- Backoff/rate limiting for repeated failed lookups per song.
- Attribution in UI/footer where required by LRCLIB terms.

### 19.4 — UX and Control Surface (MEDIUM)

Add an explicit settings toggle in Playback or Lyrics settings:

- "Use LRCLIB when server lyrics are unavailable" (default off for conservative rollout).
- Optional developer diagnostics line in full lyrics screen (source + confidence bucket).

### 19.5 — Test Matrix (MEDIUM)

Add tests for:

- Source-priority order and fallback transitions.
- High-confidence accept vs low-confidence reject.
- Synced vs unsynced rendering and seek behavior unchanged.
- Offline behavior and cache-hit behavior.

---

## Phase 20: Appearance Personalization

**Status (2026-03-05)**: Backlog moved to **Phase 24** for priority-ordered execution. This section is retained for historical planning context.

**Issue mapping**: Forgejo issue #17 (appearance customization enhancements)
**Issue status note (2026-03-05)**: closed because it was migrated to documentation.

**Development order note**: This phase is future work and can proceed independently from share-system work.

### 20.1 — Configurable Grid Density (HIGH)

Implement user-selectable album tile count/density for library-style grids:

- Options: 1, 2, 3, 4 columns (or adaptive presets mapped to those densities).
- Respect responsive breakpoints so small devices do not produce unusable card widths.
- Apply to album-heavy views (Library albums tab, liked albums, genre albums, artist album grids where appropriate).
- Persist setting in `app_settings` and migrate schema accordingly.

### 20.2 — Home Section Customization (HIGH)

Add section visibility and ordering controls for Home:

- Toggle each section on/off (recently played, recently added, most played, random, liked, etc.).
- Optional drag-to-reorder section order.
- "Reset to default layout" action.
- Preserve empty-state behavior when all sections are hidden.

### 20.3 — Accent Color Robustness for Extremes (HIGH)

Issue #17 notes light/white/dark accents not applying well. Add contrast-safe color sanitization:

- Clamp generated on-colors to WCAG-friendly contrast targets.
- Detect near-white and near-black seed colors and shift tone/chroma to keep component legibility.
- Ensure selected accent propagates consistently to app bars, chips, controls, and Now Playing tint interactions.
- Add visual regression snapshots for extreme palettes.

### 20.4 — UX and Accessibility Validation (MEDIUM)

Validate that all personalization controls remain accessible:

- Touch target sizing and labels for density/section controls.
- Stable navigation and no jank when toggling many sections.
- Screen-reader clarity for "hidden" and "shown" states.

---

## Phase 21: Share System & Cross-Server Resolution

**Status (2026-03-05)**: Backlog moved to **Phase 28** and remains explicitly deferred. This section is retained for historical planning context.

**Issue mapping**: Forgejo issue #15 (Share System)
**Issue status note (2026-03-05)**: closed because it was migrated to documentation.

**Status**: Deferred future implementation by product decision. Keep planned, do not execute in current phase sequence.

### 21.1 — Share Payload Contract (HIGH)

Define a durable share payload format that can survive cross-server mismatches:

- Include entity type (`song`/`album`/`artist`), server URL fingerprint, entity ID/hash, and human fallback metadata (title/artist/album/duration).
- Version payload schema to support future expansion without breaking older links.

### 21.2 — Inbound Link/Intent Ingestion (HIGH)

Implement platform ingestion for:

- Android app links / intent filters.
- iOS universal links / URL scheme handling.
- Cold-start and warm-start routing paths.

### 21.3 — Resolver Pipeline (HIGH)

Resolution flow for incoming shares:

1. If source server fingerprint matches active server and ID/hash resolves, open target directly.
2. If direct resolve fails, attempt server lookup from metadata.
3. If still unresolved, navigate to Search with prefilled query and context hint.

This preserves the issue requirement: open exact content when possible, otherwise fallback cleanly to search.

### 21.4 — Cross-Server Conflict Strategy (MEDIUM)

Because Subsonic IDs are server-local, define deterministic fallback behavior:

- Prefer exact metadata+duration proximity over fuzzy title-only match.
- Avoid auto-opening low-confidence matches.
- Surface "best match" result list when multiple candidates score similarly.

### 21.5 — Reliability, Security, and Telemetry (MEDIUM)

- Validate and sanitize all inbound payload fields.
- Protect against malformed deep links and unsupported entity types.
- Add lightweight diagnostics counters (resolved-direct / resolved-fallback / unresolved) for QA visibility.

---

## Phase 22: Core Technical Debt & Evidence Closeout

**Priority**: P1 (highest remaining)

This phase consolidates incomplete core items moved from earlier phases so foundational quality debt is closed before net-new feature surfaces.

**Moved from earlier phases**:
- Phase 3.1: Background sync isolate completion.
- Phase 3.2: 10K+ library profiling evidence capture.
- Phase 4.4: Device codec matrix verification evidence.
- Phase 5.2: Hero transition backlog closeout.
- Phase 9/11: AudioMuse placeholder and auto-detection decision closeout.

**Execution outcomes required**:
- Background sync path is isolate-safe end-to-end under heavy library churn.
- Performance claims include explicit profiler artifacts for large libraries.
- Codec compatibility evidence is documented using closeout tooling and sample sets.
- Deferred UI/backlog placeholders are either completed or explicitly archived with rationale.

## Phase 23: Quality, Accessibility & Locale Completion

**Priority**: P2

Canonical execution phase for former Phase 17 work.

**Scope**:
- Seek bar semantics increase/decrease actions (10-second increments).
- In-app locale override with persisted app locale and schema migration.
- Widget/integration coverage for expandable player and queue refill behaviors.
- Startup ghost-file cleanup for cache directories versus DB truth.

## Phase 24: Appearance Personalization (Priority Execution)

**Priority**: P3

Canonical execution phase for former Phase 20 work (Issue #17).
Issue #17 status note: closed because it was migrated to documentation.

**Scope**:
- Configurable grid density with responsive guardrails.
- Home section show/hide, optional reorder, and reset defaults.
- Accent color robustness for extreme light/dark seeds.
- Accessibility and interaction validation for personalization controls.

## Phase 25: Lyrics Enrichment & External Sources (Priority Execution)

**Priority**: P4

Canonical execution phase for former Phase 19 work (Issue #16).
Issue #16 status note: closed because it was migrated to documentation.

**Scope**:
- Deterministic lyrics source chain: server synced -> server plain -> LRCLIB synced -> LRCLIB plain.
- Source metadata exposure for diagnostics and user transparency.
- Strict confidence-scored LRCLIB matching to minimize false positives.
- External cache, attribution, rate control, and test matrix.

## Phase 26: In-Car & Desktop Platforms (Priority Execution)

**Priority**: P5

Canonical execution phase combining former Phases 12 and 13.

**Scope**:
- Android Auto media tree, search, and queue integration.
- CarPlay content tree and entitlement/platform-channel work.
- Desktop adaptive shell and platform media key integrations (SMTC/MPRIS/macOS media center).
- Spotify-like widescreen desktop UX: left navigation menu with a persistent full-width bottom player (expandable to full-screen lyrics/player mode), and a dominant right-side workspace for active content.
- Tablet and larger-native-window UX with a docked half-column mini player rail target width of 320 px.
- Packaging/distribution workflow hardening for Windows/macOS/Linux.

### Phase 26 Execution Decisions (Locked 2026-03-07)

The following product and architecture choices are locked for this phase and should not be re-opened unless a hard technical blocker appears.

1. Desktop visual direction uses Spotify-style structure on wide windows: left navigation column, full-width playback bar along the bottom, and expandable immersive player surface.
2. Tablet and intermediate-width native windows use a docked mini-player side rail at 320 px before escalating to the full desktop shell.
3. Existing playback stack should be reused where possible; platform-specific divergence is allowed only where required by plugin support limits.
4. Audio foundation work is a gating prerequisite for all Phase 26.2 layout/UI implementation.
5. Packaging priorities are platform-specific: Linux `.deb` first, macOS Apple Silicon first, Windows `.exe` first.

### 26.A Playback Platform Strategy (Gating)

`audio_service` support findings drive the runtime architecture for Phase 26.2.

| Platform | Runtime strategy | Decision |
|---|---|---|
| Android | Keep existing `audio_service` + `just_audio` path | No structural change |
| iOS | Keep existing `audio_service` + `just_audio` path | No structural change |
| macOS | Keep existing `audio_service` + `just_audio` path | No structural change |
| Linux | Keep `audio_service` path and add `audio_service_mpris` plugin | Native MPRIS via federated plugin |
| Windows | Add Windows-specific handler that implements `NavisPlaybackHandler` using `just_audio` + `smtc_windows`; do not call `AudioService.init()` on Windows | Platform-conditional handler split |

Supporting implementation notes:

- Keep `NavisPlaybackHandler` as the app-level contract for all platforms.
- Keep `initNavisAudioHandler()` as the single branching point for runtime handler selection.
- Keep `audio_service` dependency for shared pure-Dart media types used across code (`MediaItem`, shuffle/repeat enums) even when Windows bypasses `AudioService.init()`.
- Add Linux desktop support through `audio_service_mpris` instead of a custom MPRIS bridge.
- Use `smtc_windows` only on Windows for transport controls and metadata sync.
- Current implementation status (2026-03-27): Android media session path is active, Linux MPRIS is active, Windows SMTC is active, and macOS still needs a native `MPRemoteCommandCenter` / `MPNowPlayingInfoCenter` bridge. iOS continues to use the shared `audio_service` path but needs an explicit parity audit for lock-screen/control-center metadata behavior.

Desktop playback limitation accepted for Phase 26:

- `LockCachingAudioSource` rolling cache path is unavailable on Windows/Linux backend path; desktop falls back to direct stream playback plus existing permanent downloads.

### 26.B Adaptive Shell UX Spec

Responsive behavior for one reusable shell implementation:

| Window width | Layout mode | Playback surface behavior |
|---|---|---|
| `< 600` | Existing phone shell | Existing bottom mini-player + expandable sheet behavior |
| `600-959` | Tablet/compact desktop shell | NavigationRail with docked mini-player rail (target 320 px) |
| `960-1199` | Expanded workspace shell | Multi-column content with persistent docked player region |
| `>= 1200` | Full desktop shell | Spotify-style left nav + full-width bottom player + expandable immersive player/lyrics mode |
| `>= 1600` | Ultra-wide tuning | Preserve left nav and bottom player, allow wider content canvas and optional center-constrained reading columns where needed |

### 26.C Desktop Window and Packaging Strategy

Window/runtime baseline:

- Add `window_manager` now for desktop startup sizing, min size, and position persistence.
- Enforce minimum size `480 x 600`.

Distribution baseline by platform:

- Linux: prioritize `.deb` first; add `.AppImage` and Flatpak only if low overhead after `.deb` is stable.
- macOS: prioritize Apple Silicon (`arm64`) support first; document and validate signing/notarization path.
- Windows: prioritize installable `.exe` target for Windows 10/11; keep MSIX as an optional follow-up path, not the first release gate.

### 26.D Phase 26.2 Implementation Sequence

Execute in this order to reduce rework:

1. Playback preflight and runtime split
2. Linux MPRIS enablement via `audio_service_mpris`
3. Windows handler implementation and SMTC bridge
4. macOS native Control Centre / remote-command bridge and iOS media-session parity audit
5. Desktop caching-compatibility guards in source resolver
6. Bootstrap gate hardening so unsupported platform init does not block app launch
7. Adaptive shell rollout with breakpoints and desktop/ultra-wide tuning
8. Full-width desktop bottom player and immersive lyrics/player expansion flow
9. Desktop window persistence and packaging profiles per target OS

### 26.E Dependencies Planned in This Phase

Primary additions for this phase:

- `window_manager`
- `audio_service_mpris`
- `smtc_windows`
- `just_audio_media_kit`
- `media_kit_libs_windows_audio`
- `media_kit_libs_linux`

Keep existing playback deps in place for shared runtime paths:

- `audio_service`
- `just_audio`
- `audio_session` (guarded at runtime where unsupported)

Post-implementation dependency follow-up:

- After the `0.9.0` documentation/release-prep pass, run a targeted dependency sweep over Drift/codegen/tooling and desktop platform packages before the next release hardening pass.

## Phase 27: Platform Surface Extensions (Priority Execution)

**Priority**: P6

Canonical execution phase for former Phase 18 work.

**Scope**:
- Android home screen playback widget with reactive updates.
- iOS Live Activity / Dynamic Island stretch implementation (guarded by platform support).

## Phase 28: Share System & Cross-Server Resolution (Deferred Priority)

**Priority**: P7 (deferred by product decision)

Canonical execution phase for former Phase 21 work (Issue #15).
Issue #15 status note: closed because it was migrated to documentation.

**Scope**:
- Versioned share payload contract and platform ingress paths.
- Deterministic resolver pipeline with direct-open then fallback search.
- Cross-server confidence strategy and ambiguity handling.
- Reliability/security hardening and resolver diagnostics telemetry.

## Phase 29: ListenBrainz Scrobbling (Future Priority)

**Priority**: P8

Future roadmap phase for multi-destination scrobbling support.

**Scope**:
- Add ListenBrainz credentials and enable/disable controls in the existing Playback settings page (alongside current scrobbling controls).
- Implement now-playing and listened-track submissions to ListenBrainz with resilient retry/queue behavior.
- Keep Subsonic/Navidrome scrobbling behavior intact; allow enabling one or both destinations without regressions.
- Add clear status/error UX so users can test and validate ListenBrainz connectivity from settings.
- Add unit/integration tests for dual-destination scrobble dispatch and offline replay semantics.

## Phase 30: Discovery System (Idea Backlog)

**Priority**: P9 (idea backlog, explicitly outside the main execution plan)

Future-facing concept phase similar to Share System deferral: do not schedule as core delivery work until higher-priority platform/reliability phases are complete.

**Scope**:
- Evaluate external discovery providers and shortlist candidates for recommendation sourcing.
- Prototype a pluggable discovery service boundary that can be feature-flagged and removed cleanly.
- Define a desktop/mobile-safe discovery surface (Home module or dedicated page) without coupling core playback/library flows.
- Reuse or clone proven components from an external project only when licensing and maintenance constraints are satisfied.
- Establish privacy and telemetry boundaries before any production rollout.

## Phase 31: Adaptive Convergence Program (Desktop + Tablet + Phone)

**Priority**: P5.5 (execution block immediately after active Phase 26 shell/audio stream)

Canonical execution phase for converging desktop/tablet/phone UX into one adaptive architecture while preserving current product direction.

**Locked defaults (2026-03-23)**:
- Scope: full product convergence (not shell-only).
- Platforms: Android/iOS + macOS/Linux/Windows.
- Behavior model: window-size-first adaptation across runtimes.
- UX direction: keep current desktop/tablet/phone direction; improve consistency and structure.
- Quality gate: strict milestone closeout gate.
- Tracking system: use existing docs only (`DEVELOPMENT_PLAN.md`, `PROGRESS.md`, `docs/multi-os-release-implementation-progress.md`).

### 31.A Goals and outcomes

- One shared adaptive contract consumed by shell and all primary screens.
- No narrow-width desktop overflow/regression in shell/player/navigation surfaces.
- Breakpoint behavior deterministic at all target widths: 480, 599, 600, 839, 840, 959, 960, 1199, 1200, 1599, 1600.
- Progress tracking and evidence formatting standardized for agentic execution.

### 31.B Task identity and status model

- Task ID format: `ACP-M{milestone}-{nn}` (example: `ACP-M2-04`).
- Status values: `backlog`, `ready`, `in_progress`, `blocked`, `done`.
- Definition of done for each task:
  - implemented and locally integrated
  - targeted tests pass
  - no new overflow/regression in the task's adaptive scope
  - evidence added to `PROGRESS.md` and detailed log when required

### 31.C Milestones (M0-M6)

#### M0 — Baseline + tracking setup

- `ACP-M0-01`: add this phase definition and execution contract to `DEVELOPMENT_PLAN.md`.
- `ACP-M0-02`: add ACP checklist sections and task rows to `PROGRESS.md`.
- `ACP-M0-03`: extend `docs/multi-os-release-implementation-progress.md` with ACP execution log and blocker protocol.
- `ACP-M0-04`: record adaptive baseline evidence (tests/analyzer) before structural refactor work.

#### M1 — Unified adaptive contract

- `ACP-M1-01`: introduce shared adaptive context object resolved once per build surface.
- `ACP-M1-02`: keep existing breakpoints unless evidence proves regressions.
- `ACP-M1-03`: replace ad-hoc `isDesktopRuntime + MediaQuery` branching where duplicate logic exists.
- `ACP-M1-04`: add explicit capability/policy abstraction boundary for platform-dependent behavior.

#### M2 — Shell stabilization first

- `ACP-M2-01`: move shell composition to window-size-first behavior for desktop and mobile runtimes.
- `ACP-M2-02`: fix narrow-width desktop player bar overflow and constrained-control behavior.
- `ACP-M2-03`: preserve branch stack continuity and shell overlay back-priority guarantees.
- `ACP-M2-04`: retain keyboard shortcuts and text-input guard behavior.

#### M3 — Screen convergence (full product)

- `ACP-M3-01`: migrate Home adaptive branching to shared contract.
- `ACP-M3-02`: migrate Search adaptive branching to shared contract.
- `ACP-M3-03`: migrate Library adaptive branching to shared contract.
- `ACP-M3-04`: migrate Settings adaptive branching to shared contract.
- `ACP-M3-05`: migrate Now Playing adaptive branching to shared contract.

#### M4 — Input and accessibility hardening

- `ACP-M4-01`: standardize focus traversal behavior across desktop/tablet surfaces.
- `ACP-M4-02`: standardize keyboard and pointer affordances where adaptive modes diverge.
- `ACP-M4-03`: add explicit adaptive input checks to QA matrix.
- `ACP-M4-04`: add a deferred user-toggleable compact player window mode ("Focus Player Mode") that locks the app window to a compact-wide-friendly aspect/size preset and allows quick return to normal adaptive behavior.
- `ACP-M4-05`: polish overlapping keyboard/input systems across desktop surfaces, including quick-search vs library-filter precedence, transport suppression while typing, and cross-platform primary-modifier parity.

#### M5 — Platform capability layer

- `ACP-M5-01`: centralize desktop media capability checks for `audio_service`, `audio_service_mpris`, and `smtc_windows`.
- `ACP-M5-02`: ensure graceful runtime fallback for unsupported feature surfaces.
- `ACP-M5-03`: evaluate dependency hygiene for `audio_service_mpris` version alignment.
- `ACP-M5-04`: extend system media API parity to macOS native `MPRemoteCommandCenter` / `MPNowPlayingInfoCenter` handling and audit iOS media-session parity.
- `ACP-M5-05`: run a dependency hygiene sweep over desktop/audio/adaptive packages before release hardening.

#### M6 — Validation + release readiness

- `ACP-M6-01`: run strict adaptive gate (targeted tests + analyzer + viewport QA matrix).
- `ACP-M6-02`: close remaining ACP tasks with dated evidence in `PROGRESS.md`.
- `ACP-M6-03`: update architecture docs with final adaptive contract ownership and data flow.

### 31.D Agent execution loop

1. Select highest-priority `ready` task without unresolved dependencies.
2. Implement minimal safe vertical slice.
3. Run targeted tests first, then milestone gate.
4. Update `PROGRESS.md` evidence line in same session.
5. If blocked, append exact error + next action to detailed progress doc.

---

## AI Agent Development Guidelines

These rules govern how the AI agent writes code in this project. The human reviewer should enforce these during review.

1. **No comment noise.** Only comment complex logic, non-obvious workarounds, or things a reader would genuinely wonder about. Never comment obvious code. No `// Initialize the controller`, no `// Return the result`, no `// This is a widget that displays...`.

2. **No emoji** in code, comments, commit messages, or UI strings.

3. **No placeholder code.** No `// TODO: Implement`, no functions that return `null` or throw `UnimplementedError`. Every committed function must be functional. If a feature is not yet implemented, the UI simply doesn't show the entry point to it.

4. **Reuse relentlessly.** Before creating a new widget, check `common_widgets/`. Extract any pattern used more than twice into a shared widget or utility. Album cards, track list tiles, cover art images, star buttons, context menus — all shared.

5. **Follow the architecture.** Feature code lives in `features/{name}/{data,domain,presentation}/`. No business logic in widgets. No API calls outside repositories. No direct database access outside DAOs. Providers for state. Repositories for data.

6. **Use code generation.** All models use `freezed`. All providers use `@riverpod`. All database code uses `drift`. Never hand-write `==`, `hashCode`, `copyWith`, `fromJson`/`toJson`, or provider boilerplate.

7. **Const everywhere.** Use `const` constructors for all widgets where parameters are compile-time constants. Use `const` for static values, lists, maps.

8. **Single responsibility.** One widget per file. One provider per concern. One DAO per domain area. Files rarely exceed 200 lines — if they do, split.

9. **Handle all states.** Every `AsyncValue` in the UI must render loading (skeleton/shimmer), error (with retry), and data states. No unhandled error scenarios.

10. **Test alongside.** When implementing a repository, write its unit tests. Minimum: repositories 80% coverage, model serialization 100% round-trip coverage.

11. **Naming conventions.** Files: `snake_case.dart`. Classes: `PascalCase`. Providers: `camelCaseProvider`. Private members: `_prefixed`. No abbreviations except `id`, `url`, `api`, `db`, `ui`.

12. **Formatting.** `dart format` before every commit. Line length 80. Trailing commas on all multi-line argument lists.

13. **Incremental delivery.** Each phase produces a runnable app. Phase 0+1+2 = logs in. Phase 3 = browses library. Phase 4+5 = plays music with lyrics. And so on.

14. **No AI writing style in UI.** User-facing text must be concise, direct, human. No "Oops! Something went wrong!" or "Let's get started!". Error messages describe what happened and what to do: "Could not reach server. Check your connection."

15. **Performance by default.** Use `const`, `SliverList`/`SliverGrid`, lazy loading, isolate sync, provider auto-dispose. Profile with DevTools before each phase is considered complete.

16. **No unnecessary files.** Do not create markdown files, reports, summaries, scratch documents, or any file that is not directly part of the application code, tests, or project documentation described in rule 17. If information belongs somewhere, put it in the right place — don't create a new file for it.

17. **Maintain project documentation.** Keep a `docs/` directory at the project root with focused, up-to-date development documentation. This documentation is the reference for all future development — human or AI.

    **Structure**:
    ```
    docs/
    ├── architecture.md       # High-level architecture, data flow, provider graph
    ├── api-client.md         # Subsonic API client usage, endpoint reference, auth flow
    ├── database.md           # Drift schema, DAOs, migration procedures
    ├── audio-engine.md       # NavisAudioHandler, source resolution, queue management
    ├── caching.md            # Rolling cache, permanent cache, download queue internals
    ├── theming.md            # Theme system, color schemes, OLED mode
    └── contributing.md       # Build instructions, code generation, testing, conventions
    ```

    **Rules**:
    - Every public class and non-trivial function must be documented in the relevant `docs/` file when created or significantly changed. Not full Javadoc — concise descriptions of what it does, its parameters, and any non-obvious behavior.
    - When adding a new feature, update the relevant doc file. When changing a function's signature or behavior, update its doc entry. When changing architecture, update `architecture.md`.
    - Link to `docs/` from the README (see rule 18). The README stays slim; `docs/` holds the depth.
    - Write docs for the reader who needs to understand the codebase to fix a bug, add a feature, or upgrade a dependency. That reader may be a human or an AI agent.
    - Do not duplicate information already in this development plan. The `docs/` directory documents the *implemented* codebase, not the plan.

18. **Keep the README current and human.** Update `README.md` when features are added, setup steps change, or the project evolves. The README must read like a human wrote it — concise, direct, no filler.

    **README guidelines**:
    - Short project description (1-2 sentences).
    - Screenshots or GIFs when there's something visual to show (add as features ship).
    - Features list — brief bullets, not paragraphs.
    - Build/run instructions — minimal, exact commands.
    - Link to `docs/` for anything that needs deeper explanation.
    - No badges wall, no "Table of Contents" for a short README, no AI-generated fluff ("Welcome to Navis!", "Getting Started is easy!", etc.).
    - Tone: like a developer's personal project README — informative, no-nonsense, slightly casual.

19. **Follow the git workflow.** Commit using Conventional Commits (see [Git Strategy & Releases](#git-strategy--releases)). One logical change per commit. Never commit code that fails `./tool/check.sh` (or its fallback equivalent). Version bumps and tags happen as described in the plan — don't invent new versioning schemes.

20. **Update progress tracking.** After completing any task, sub-task, or phase, update `PROGRESS.md` by checking the corresponding checkbox and adding the completion date. If a task is partially complete, note what remains. When a phase is fully complete and tagged, note the version tag inline. Keep the file accurate — it is the primary progress reference for the human and any future AI agent sessions.

21. **Close tasks with evidence.** Every completed task entry in `PROGRESS.md` must include date and short evidence (test command, screenshot path, or key files touched). A checkbox without evidence is incomplete.

22. **Generated code is source-of-truth adjacent.** After any model/provider/database annotation changes, run code generation and commit generated files in the same change.

23. **Secrets and sensitive logging hygiene.** Never commit credentials, tokens, or server-specific secrets. Never log passwords/auth tokens, even in debug mode.

---

## Verification Strategy

Each phase must pass its verification criteria before moving to the next.

Global verification rule for every phase completion:
- `./tool/check.sh` passes locally (or fallback equivalent command chain).
- `PROGRESS.md` is updated with date and evidence for completed items.

| Phase | Criteria |
|---|---|
| 0 | `flutter run` launches a blank app. `build_runner build` succeeds. `dart format --set-exit-if-changed .`, `flutter analyze`, `dart run custom_lint`, and `flutter test` all pass. Directory structure in place. Notification channels created on Android. Logger outputs to console in debug mode. `POST_NOTIFICATIONS` permission request flow works on Android 13+ emulator. |
| 1 | Unit tests pass for `SubsonicApiClient` (mock HTTP). Drift DAO tests pass (in-memory DB). `ping()` succeeds against a real Navidrome server. Freezed models serialize/deserialize correctly. Dio retry interceptor retries on timeout (unit test with mock). Play queue DAO reads/writes correctly. Database migration from v1 to current version tested. |
| 2 | Login flow works end-to-end. Credentials survive app kill + relaunch (auto-login). Sign out clears everything. Offline banner appears when server is unreachable. |
| 3 | Library populates after sync. Album detail loads from local DB instantly. Pull-to-refresh triggers re-sync. Artists/Albums tabs work. Home screen carousels populate. Context menus function on all items. 10K+ library scrolls at 60fps. |
| 4 | Streams music from Navidrome. Background audio continues with screen off. Lock screen controls work. Notification shows track info + controls. Gapless playback between consecutive tracks. Scrobble appears in Navidrome play history. Queue persists across app restarts. Playback position saved periodically (kill app mid-track, relaunch, confirm position is near where it was). Network type change triggers correct quality profile on next track. |
| 5 | Now Playing screen renders correctly as an expandable sheet from mini player. Mini Player visible and interactive — swipe up expands, swipe down collapses. Synced lyrics auto-scroll on a Navidrome server with lyrics support. Unsynced lyrics display. Seek-by-tap on lyric lines works. Cover art ↔ lyrics toggle works without shifting controls. Back button collapses Now Playing. Swipe up on Now Playing opens queue. |
| 6 | Search returns results from server. No result caching. Recent searches stored and displayed. Tap results navigate correctly. Pagination works for large result sets. |
| 7 | Playlists list populates. Create, rename, delete playlists reflected on server. Add/remove/reorder tracks in playlists syncs to server. |
| 8 | Rolling cache grows as tracks are streamed. LRU eviction respects rolling cache size limit without touching permanent cache. Permanent pin downloads a track in chosen quality via the download queue. Pinned content plays without network. Download queue shows progress, supports pause/cancel/reorder. Wi-Fi-only downloads pause on cellular. "Offline Only" filter shows both rolling (with temporary badge) and permanent cached songs. Promoting a rolling-cached song to permanent works without re-download. Storage stats show rolling cache, permanent cache, and cover art separately. |
| 9 | All settings persist across restarts. Wi-Fi vs cellular streaming quality switches automatically based on network type. Theme mode (Light/Dark/OLED/System) and color scheme (Dynamic/Preset/Custom) apply immediately on change, with a quick Light Mode toggle in settings and independent light-mode vs dark-mode color palette selections preserved when switching modes. Equalizer functional on a physical Android device. Cache management controls (rolling vs permanent) work correctly and show accurate stats. |
| 10 | Hero animations for cover art work smoothly. Skeleton loading replaces spinners. No accessibility warnings from Flutter Inspector. All strings externalized. Haptic feedback on key actions. Edge-to-edge correct on Android 15 and Android 16 emulators. Predictive back gesture works with go_router. Logger output visible in debug, silent in release (with auth params redacted). App recovers gracefully from force-kill (play queue restored, download queue re-queued). Material motion transitions (SharedAxisTransition, FadeThroughTransition) visible on page navigations. Update checker: mock Forgejo API returns newer version → banner appears; returns same version → no banner; network unavailable → silent failure, no crash. |
| 11 | AudioMuse smart queue appends tracks when configured. UI elements hidden when AudioMuse not configured. Similar artists/albums display. Fallback to Subsonic data when AudioMuse is off. |
| 12 | Android Auto: browsable media tree visible in a connected Android Auto head unit or emulator (Desktop Head Unit). Artists/Albums/Playlists root tabs expand correctly. Playback controls (play/pause/next/previous/seek) work from the Auto UI. Search returns results. Inert on non-Auto Android devices and on iOS. CarPlay: content tree renders in CarPlay Simulator. Playback controls work. `MPPlayableContentDelegate` receives play commands. Siri Shortcuts `INPlayMediaIntent` triggers playback. Inert on non-CarPlay iOS devices and on Android. |
| 13 | All three desktop targets (`flutter run -d windows`, `-d macos`, `-d linux`) build and launch without errors. `NavigationRail` visible at ≥ 600 dp window width; `BottomNavigationBar` visible at < 600 dp. Master-detail layout active at ≥ 960 dp. Window size and position survive app restart. Windows: SMTC thumbnail and controls appear in the taskbar media flyout; hardware media keys toggle playback. Linux: `playerctl status` reports `Playing`/`Paused`; `playerctl play-pause` toggles playback; `playerctl metadata` shows current track. macOS: Control Centre now-playing widget shows track info and art; keyboard media keys work. MSIX, `.app` bundle, and `.deb` packages build successfully in CI. |
| 14 | `skipSilenceEnabled` toggle is absent from the Playback settings screen. Killing the app immediately after pausing and relaunching places playback within 1 second of the pause point. Lyrics widget shows distinct messages for: no lyrics, fetch error, and unsupported server. ReplayGain applies audible gain normalization when mode is set to Track or Album (audible volume difference between a quietly and a loudly mastered track). Playback speed control visible in Now Playing; speed persists after navigating away and returning. Crossfade + gapless conflict warning visible when both are enabled. Targeted `isPlayingProvider` / `currentSongProvider` derived providers exist and are used by non-seek widgets. |
| 15 | Favorites screen lists starred albums, artists, and songs from `getStarred2()`. Starring from any screen reflects immediately in the Favorites screen via drift stream. Download badges visible on album tiles in the library grid for fully downloaded albums. Every list/grid screen has pull-to-refresh. No blank screens on empty states for all listed scenarios. Album grid thumbnails use size-constrained server requests. Year/decade chip filter returns correct albums from server. Auto-download starred toggle queues downloads when Wi-Fi connects (when enabled). |
| 16 | Starring a song offline queues the action in `star_sync_queue`; reconnecting to the server flushes the queue and the server reflects the correct star state. Search screen returns local drift results with offline banner when server is unreachable. Search type filter chips correctly restrict results to the selected type. Radio stream error produces a dismissible snackbar and stops gracefully; station name displays when ICY metadata is unavailable; previously loaded metadata is not cleared on polling failure. |
| 17 | Seek bar responds to TalkBack / VoiceOver increase/decrease gesture with 10-second step. Language override in Appearance settings changes display locale immediately on selection. `ExpandablePlayerSheet` and `InstantMixNotifier` tests pass. Startup ghost file scan completes without errors and removes orphaned cache files on a device with a simulated orphan. |
| 18 | Android home screen widget displays current track and responds to play/pause/skip. Widget updates when the track changes while the app is in the background. |
| 19 | For songs missing server lyrics, LRCLIB fallback resolves lyrics using strict confidence rules (duration + normalized metadata) and prefers synced lyrics over plain text. Source attribution and cache behavior are visible and deterministic. |
| 20 | User-selected album grid density (1/2/3/4) persists across restarts, Home sections can be hidden/reordered and reset, and extreme accent colors remain legible across core surfaces without contrast regressions. |
| 21 | Shared links open the exact entity when resolvable; otherwise route to prefilled Search fallback. Cold-start and warm-start deep-link ingestion works on Android and iOS, and malformed payloads fail safely without crashes. |
| 31 | Adaptive shell and core screens follow a shared adaptive contract across phone/tablet/desktop; no `RenderFlex overflow` at defined breakpoint matrix widths (480, 599, 600, 839, 840, 959, 960, 1199, 1200, 1599, 1600). Runtime matrix checks confirm expected shell mode behavior on Android/iOS/macOS/Linux/Windows. Regression checks cover route continuity across resize, overlay/back priority, queue/now-playing transitions, and keyboard shortcut behavior with text-focus guards. |

---

## Key Technical Decisions

| Decision | Rationale |
|---|---|
| Riverpod over BLoC | Less boilerplate (especially with codegen). `AsyncValue` natively handles loading/error/data. No `BuildContext` requirement — critical for `AudioHandler` background isolate accessing providers. |
| drift over ObjectBox/Isar | Music data is inherently relational (artists → albums → tracks → playlists). SQL + explicit migrations + transactional consistency is the natural fit. drift's reactive streams and isolate support integrate cleanly with Riverpod. |
| `just_audio` over `audioplayers` | Only `just_audio` offers gapless playback, `LockCachingAudioSource`, `ConcatenatingAudioSource`, and Android equalizer. `audioplayers` is simpler but lacks the features a music player needs. |
| `flex_color_scheme` over raw `ThemeData` | Generates consistent, complete M3 themes with far less code. Dynamic color support. The Themes Playground web tool enables visual theme design without code iteration. |
| Feature-first over layer-first | Each feature is self-contained. Adding or modifying a feature doesn't require touching files scattered across `screens/`, `controllers/`, `models/`, etc. Better for iterative agentic development. |
| Single server (for now) | Reduces data model complexity. Every table would need a `serverId` foreign key with multi-server. One server covers the vast majority of users. Multi-server can be added later by introducing a `serverId` column and a server-switching UI. |
| `download` endpoint for offline pins | `download` returns the original file untouched. `stream` may transcode. Offline pins should preserve the original unless the user explicitly chooses lower quality, in which case `stream` with `maxBitRate` is used. |
| `drift_flutter` over manual SQLite setup | `drift_flutter` encapsulates `sqlite3_flutter_libs` + `path_provider` wiring into a single dependency. Reduces boilerplate, handles platform-specific database file paths automatically, and is the officially recommended approach by the drift author. |
| `animations` for Material motion | The official Material Design motion package from the Flutter team. Provides `SharedAxisTransition`, `FadeThroughTransition`, `OpenContainer` — canonical Material 3 transition patterns that feel native. |
| `logger` over `print()` | Structured, leveled logging with color-coded output in debug. All modules use a shared logger instance. Allows filtering by severity and silencing in release builds. Essential for debugging audio/cache/sync issues. |
| No search result caching | Search results must always be fresh from the server. The library (browsing) is cached; search is not. |

---

## Future Considerations

These are explicitly out of scope for the initial development but designed to be addable later.

- **Multi-server support**: Add a `serverId` foreign key to all data tables. Add a server list/switcher UI. The provider architecture already supports swapping the API client based on active server.
- **Android Auto / CarPlay**: ~~Promoted to **Phase 12**.~~ See Phase 12 for the full implementation plan.
- **Desktop support (Windows, macOS, Linux)**: ~~Promoted to **Phase 13**.~~ See Phase 13 for the full implementation plan including adaptive layout, OS audio integration (SMTC / MPRIS / macOS media keys), and packaging.
- **Chromecast / DLNA**: Cast audio to external devices. Requires a casting package and UI affordances. Independent of the core playback engine.
- **Widgets**: ~~Promoted to **Phase 18**.~~ See Phase 18 for the Android home screen widget and iOS Live Activity implementation plan.
- **Wear OS / Apple Watch**: Companion app for playback control.
- **Import/export**: Import playlists from M3U files. Export starred items.
- **Custom server endpoints**: Support non-standard Subsonic API extensions beyond OpenSubsonic.
- **Persistent log file**: Add a developer-only setting to write logs to a file for troubleshooting. Ship with it disabled.
- **Analytics / crash reporting**: Optional, privacy-respecting crash reporting (e.g., Sentry self-hosted). Must be opt-in given the GPL-3.0 license and privacy-conscious user base.
- **Radio stream playback (Azuracast)**: Stream live radio from Azuracast stations via HLS or direct MP3/AAC mount-point URLs. Display real-time "Now Playing" metadata (title, artist, album art) using Azuracast's WebSocket or polling API (`/api/nowplaying/{station}`). Integrate with the existing `audio_service` pipeline — create a `RadioAudioSource` that wraps an HLS/Icecast URI, feed metadata updates into `MediaItem` so lock-screen and notification controls stay current. Add a Radio tab or section in the library with station list, favorites, and a mini status indicator. Keep radio playback independent from the queue so switching back to library tracks resumes where the user left off. Consider supporting generic Icecast/Shoutcast streams long-term.
- **ListenBrainz scrobbling**: Promoted to **Phase 29**. Add optional dual-destination scrobbling with Playback settings controls and robust offline retry behavior.
- **Discovery system**: Promoted to **Phase 30** as an idea backlog item. Keep this outside the main execution plan until core platform and reliability priorities are complete.
