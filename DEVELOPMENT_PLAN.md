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
| Android `compileSdkVersion` | **35** (Android 15) | Required for edge-to-edge enforcement and latest platform APIs |
| Android `targetSdkVersion` | **35** | Meets current Play policy baseline. Re-check Play requirements before each release cut. |
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
│   │   │   ├── domain/                   # PlayQueue, PlayerState
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
  - `compileSdkVersion` 35, `targetSdkVersion` 35, `minSdkVersion` 24 (Android 7.0) — required by `audio_service`, covers 95%+ of devices. Re-check target/compile SDK against Play policy before every release.
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
| Play queue | `getPlayQueue()`, `savePlayQueue(ids, current, position)` |

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
- `Artist`, `ArtistInfo`, `Album`, `AlbumInfo`, `Song`, `Genre`, `Playlist`, `SearchResult3`, `LyricsList`, `StructuredLyrics`, `LyricLine`, `PlayQueue`, `ServerCapabilities`.
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
| `/library` | Library | Tabbed: Artists, Albums, Songs, Genres |
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
- Manual "Force Full Sync" button in Settings.

**Sync progress**: Show a subtle progress indicator (linear progress bar at top of library screens) during initial sync. Don't block the UI — whatever has been synced so far is immediately browsable.

### 3.2 — Library UI

**NavigationBar** (bottom): Home, Library, Search, Settings — four tabs for the main shell.

#### Home Screen (`/`)

The home screen is a discovery feed, not just a static landing page. Vertical scrollable list of horizontal carousels:

- **Recently Played** — from local `play_history` table. Horizontal album art carousel.
- **Recently Added** — `getAlbumList2(type: 'newest')`. Horizontal album card carousel.
- **Most Played** — `getAlbumList2(type: 'frequent')`. Horizontal carousel.
- **Random Albums** — `getAlbumList2(type: 'random')`. Refreshes on pull-to-refresh.
- **Starred** — `getStarred2()`. Shows starred albums/songs.

Each carousel card shows cover art + album name + artist name. Tap → album detail.

#### Library Screen (`/library`)

Tabbed interface with tabs: **Artists**, **Albums**, **Songs**, **Genres**.

**Artists tab**:
- Alphabetically sorted list with section headers (A, B, C...) and a fast scroll index on the right edge.
- Each artist row: artist image (or placeholder), name, album count.
- Tap → Artist detail.

**Albums tab**:
- Grid of album covers (2-3 columns depending on screen width).
- Sort options (dropdown or chips): Name, Artist, Year, Recently Added.
- Each card: cover art, album name, artist name, year.
- Tap → Album detail.

**Songs tab**:
- Flat list of all tracks, sorted alphabetically by default.
- Sort options: Title, Artist, Album, Duration.
- Each row: track title, artist, album name, duration, overflow menu.
- Tap → play immediately and queue remaining songs.

**Genres tab**:
- List of genres with song/album counts.
- Tap → filtered album/song list for that genre.

#### Artist Detail Screen (`/library/artists/:id`)

- Header: artist image (from `getArtistInfo2`), artist name.
- Bio section: collapsible artist biography text from `getArtistInfo2`.
- Albums grid: all albums by this artist, sorted by year descending.
- "Play all" and "Shuffle" buttons.
- Star/unstar button.
- Similar artists section (from `getArtistInfo2.similarArtist`) — horizontal scrollable row of artist chips/cards.

#### Album Detail Screen (`/library/albums/:id`)

This is the most important browsing screen. Must load instantly from local cache.

- Header: large cover art with a parallax/collapse effect on scroll (SliverAppBar with `flexibleSpace`).
- Below header: album name, artist name (tappable → artist detail), year, genre, track count, total duration.
- Action row: Play, Shuffle, Star, Download (pin for offline), overflow menu.
- Track list: numbered by disc/track, with duration. Each track has a context menu (long-press) with: Play Next, Add to Queue, Add to Playlist, Star, Download, Go to Artist, Go to Album.
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
- `StarButton` — animated star/unstar toggle.
- `CacheBadge` — "Cached" / "Downloaded" / "Temporary" indicators.

### 3.4 — Context Menus & Actions

Long-press (or trailing icon menu) on any song, album, or artist triggers a bottom sheet with contextual actions:

**Song context menu**:
- Play Next
- Add to Queue
- Add to Playlist...
- Go to Album
- Go to Artist
- Star / Unstar
- Download for Offline
- Share (copy Subsonic link)

**Album context menu**:
- Play
- Shuffle
- Play Next
- Add to Queue
- Star / Unstar
- Download for Offline
- Go to Artist

**Artist context menu**:
- Play All
- Shuffle All
- Star / Unstar

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
- Optionally sync with the server via `savePlayQueue()` / `getPlayQueue()` for cross-device continuity (if server supports it).

**Audio focus** (via `audio_session`):
- Duck volume when receiving transient interruptions (navigation prompts, notifications).
- Pause on prolonged interruptions (phone calls, other media apps).
- Resume after transient interruptions end.

### 4.2 — Play Queue Persistence

While the queue data model and save triggers are implemented in 4.1, the restoration and cross-device sync logic is a distinct deliverable:

- Restore queue on app launch from drift `play_queue` + `play_queue_items`.
- Resume playback position from `positionMs` — seek to saved position.
- Cross-device sync via `savePlayQueue()` / `getPlayQueue()` (gated behind a settings toggle, default off).

### 4.3 — Streaming Quality

The `NavisAudioHandler` observes the current network type via `connectivity_plus` and resolves stream URLs using the matching quality profile from Settings.

- **Wi-Fi profile**: uses the Wi-Fi streaming quality and Wi-Fi transcode format settings.
- **Non-Wi-Fi profile**: uses the Non-Wi-Fi (cellular) streaming quality and format settings.
- Default: Wi-Fi = Original (no transcoding), Non-Wi-Fi = 192 kbps MP3.
- When the network type changes mid-playback, the current track continues at its original quality. The next track in the queue uses the new profile.
- If both quality and format are "Original", no `maxBitRate` or `format` params are added to the stream URL — the server sends the original file.

### 4.4 — Audio Quality Details

`just_audio` decodes FLAC, ALAC, MP3, AAC, Opus, Vorbis natively on both Android and iOS. No custom codec work needed.

**Android-only features** (conditionally exposed in settings):
- Equalizer via `just_audio`'s `AndroidEqualizer` — user-adjustable frequency bands.
- Loudness enhancer via `AndroidLoudnessEnhancer`.
- Skip silence detection.

These are gated behind platform checks and hidden on iOS.

**ReplayGain** (volume normalization):
- If the server provides ReplayGain tags in track metadata, respect them.
- `just_audio` supports volume adjustment per source — apply ReplayGain offset as a volume multiplier.
- Setting to enable/disable volume normalization.

---

## Phase 5: Now Playing & Lyrics

**Goal**: Polished now-playing experience with synced lyrics support.

### 5.1 — Mini Player

A compact bar that sits above the `NavigationBar` in the shell scaffold. Always visible when something is in the queue.

**Layout**: Cover art thumbnail (40x40) | Track title + Artist (marquee / scrolling text if too long) | Play/Pause button | Small linear progress bar along the bottom edge.

**Interactions**:
- Tap anywhere (except play/pause) → navigate to full Now Playing screen.
- Swipe left/right → skip to next/previous track.

### 5.2 — Now Playing Screen

Opens as a full-screen route or expanding bottom sheet from the MiniPlayer.

**Layout (top to bottom)**:
1. Drag handle / down-chevron to dismiss.
2. Large cover art (takes ~40-50% of screen height). Consider a subtle background blur of the cover art behind the entire screen.
3. Track title (bold, larger font) — marquee if too long.
4. Artist name (tappable → artist detail) — album name (tappable → album detail).
5. Seek bar with elapsed time (left) and remaining time (right). Draggable.
6. Control row: Shuffle | Previous | Play/Pause (large, prominent) | Next | Repeat mode.
7. Bottom action row: Star button | Lyrics button | Queue button | Overflow menu (audio quality info, go to album, share).

**Animations**:
- Hero animation for cover art when transitioning from MiniPlayer or album detail.
- Smooth transition between MiniPlayer and full Now Playing.

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
- On Now Playing screen, tapping the lyrics button crossfades between the cover art view and the lyrics view. The cover art shrinks to a small thumbnail in the top corner when lyrics are shown, or the lyrics overlay the cover art with a translucent background.

### 5.4 — Queue Screen

Accessible from Now Playing via the queue button. Shows as a bottom sheet or separate route.

- Currently playing track highlighted at the top.
- "Up Next" section: list of upcoming tracks.
- Drag handles on each row for reorder.
- Swipe-to-remove on each row.
- "Clear Queue" action.
- "Save as Playlist" action — prompts for playlist name, calls `createPlaylist`.
- Each track row: cover art thumbnail, title, artist, duration, drag handle.

### 5.5 — Sleep Timer

Accessible from the Now Playing overflow menu, NOT buried in settings.

- Presets: 15 min, 30 min, 45 min, 1 hour, end of current track.
- Custom duration picker.
- Active timer shown as a countdown in the Now Playing screen.
- Fade out audio over last 30 seconds before sleep.

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
- ReplayGain / volume normalization: off / track / album.
- Skip silence: on/off (Android only).
- Scrobble to server: on/off, threshold slider (50–90%).
- Resume on launch: on/off — whether to auto-restore the last play queue.
- Cross-device play queue sync: on/off — sync queue with server via `savePlayQueue` / `getPlayQueue`.

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

Use the `animations` package (Material Design motion system) for all page-level transitions:

- Hero animation for cover art: album grid → album detail → now playing. Seamless image transition.
- Mini Player → Now Playing expansion: smooth slide-up animation.
- Page transitions: `SharedAxisTransition` (horizontal axis for peer navigation like tab switches, vertical axis for parent-child like list → detail). `FadeThroughTransition` for top-level destination changes (bottom nav tabs). `OpenContainer` for list items that expand into detail screens (optional, for a premium feel).
- Skeleton loading placeholders (shimmer) while data loads, not spinners. The `ShimmerPlaceholder` widget is built in Phase 3 — Phase 10 audits that it's used consistently everywhere.
- Pull-to-refresh with Material 3 refresh indicator.

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

- Light haptic on star/unstar.
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
| 3 | Library populates after sync. Album detail loads from local DB instantly. Pull-to-refresh triggers re-sync. Artists/Albums/Songs/Genres tabs work. Home screen carousels populate. Context menus function on all items. 10K+ library scrolls at 60fps. |
| 4 | Streams music from Navidrome. Background audio continues with screen off. Lock screen controls work. Notification shows track info + controls. Gapless playback between consecutive tracks. Scrobble appears in Navidrome play history. Queue persists across app restarts. Playback position saved periodically (kill app mid-track, relaunch, confirm position is near where it was). Network type change triggers correct quality profile on next track. |
| 5 | Now Playing screen renders correctly. Mini Player visible and interactive. Synced lyrics auto-scroll on a Navidrome server with lyrics support. Unsynced lyrics display. Seek-by-tap on lyric lines works. Cover art ↔ lyrics toggle works. Sleep timer counts down and stops playback. |
| 6 | Search returns results from server. No result caching. Recent searches stored and displayed. Tap results navigate correctly. Pagination works for large result sets. |
| 7 | Playlists list populates. Create, rename, delete playlists reflected on server. Add/remove/reorder tracks in playlists syncs to server. |
| 8 | Rolling cache grows as tracks are streamed. LRU eviction respects rolling cache size limit without touching permanent cache. Permanent pin downloads a track in chosen quality via the download queue. Pinned content plays without network. Download queue shows progress, supports pause/cancel/reorder. Wi-Fi-only downloads pause on cellular. "Offline Only" filter shows both rolling (with temporary badge) and permanent cached songs. Promoting a rolling-cached song to permanent works without re-download. Storage stats show rolling cache, permanent cache, and cover art separately. |
| 9 | All settings persist across restarts. Wi-Fi vs cellular streaming quality switches automatically based on network type. Theme mode (Light/Dark/OLED/System) and color scheme (Dynamic/Preset/Custom) apply immediately on change, with a quick Light Mode toggle in settings and independent light-mode vs dark-mode color palette selections preserved when switching modes. Equalizer functional on a physical Android device. Cache management controls (rolling vs permanent) work correctly and show accurate stats. |
| 10 | Hero animations for cover art work smoothly. Skeleton loading replaces spinners. No accessibility warnings from Flutter Inspector. All strings externalized. Haptic feedback on key actions. Edge-to-edge correct on Android 15 and Android 16 emulators. Predictive back gesture works with go_router. Logger output visible in debug, silent in release (with auth params redacted). App recovers gracefully from force-kill (play queue restored, download queue re-queued). Material motion transitions (SharedAxisTransition, FadeThroughTransition) visible on page navigations. Update checker: mock Forgejo API returns newer version → banner appears; returns same version → no banner; network unavailable → silent failure, no crash. |
| 11 | AudioMuse smart queue appends tracks when configured. UI elements hidden when AudioMuse not configured. Similar artists/albums display. Fallback to Subsonic data when AudioMuse is off. |

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
- **Android Auto / CarPlay**: `audio_service` provides the foundation. Requires implementing a browsable media tree (`MediaItem` hierarchy for artists/albums/playlists). Addable without architectural changes.
- **Tablet / Desktop layout**: Responsive layouts with `NavigationRail` instead of `NavigationBar` on wide screens. Side-by-side list + detail views. `LayoutBuilder` or `MediaQuery` breakpoints.
- **Chromecast / DLNA**: Cast audio to external devices. Requires a casting package and UI affordances. Independent of the core playback engine.
- **Widgets**: Home screen widget showing current track with basic controls.
- **Wear OS / Apple Watch**: Companion app for playback control.
- **Import/export**: Import playlists from M3U files. Export starred items.
- **Custom server endpoints**: Support non-standard Subsonic API extensions beyond OpenSubsonic.
- **Persistent log file**: Add a developer-only setting to write logs to a file for troubleshooting. Ship with it disabled.
- **Analytics / crash reporting**: Optional, privacy-respecting crash reporting (e.g., Sentry self-hosted). Must be opt-in given the GPL-3.0 license and privacy-conscious user base.
