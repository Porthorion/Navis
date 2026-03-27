# Package Upgrade Plan

> **Navis** — Subsonic/OpenSubsonic music player  
> Date: 2026-03-28  
> Target: 14 packages upgraded across 5 phases  
> Scope: `pubspec.yaml` version bumps + code regeneration only — **zero source code modifications required**

---

## Status Summary

| Category | Count |
|----------|-------|
| Already up to date | 25 packages |
| Require upgrade | 14 packages |
| Require code regeneration | 2 phases (2 & 3) |
| Source code changes required | **None** |

---

## Version Comparison

### Already Up to Date — No Action Needed

| Package | Version |
|---------|---------|
| audio_service | 0.18.18 |
| cached_network_image | 3.4.1 |
| connectivity_plus | 7.0.0 |
| dio | 5.9.2 |
| flutter_cache_manager | 3.4.1 |
| flutter_local_notifications | 21.0.0 |
| flutter_markdown_plus | 1.0.7 |
| flutter_secure_storage | 10.0.0 |
| freezed_annotation | 3.1.0 |
| go_router | 17.1.0 |
| intl | 0.20.2 |
| just_audio | 0.10.5 |
| just_audio_media_kit | 2.1.0 |
| media_kit_libs_linux | 1.2.1 |
| media_kit_libs_macos_audio | 1.1.4 |
| media_kit_libs_windows_audio | 1.0.9 |
| package_info_plus | 9.0.0 |
| path_provider | 2.1.5 |
| scrollable_positioned_list | 0.3.8 |
| smtc_windows | 1.1.0 |
| window_manager | 0.5.1 |
| mocktail | 1.0.4 |
| riverpod_lint | 3.1.3 |
| very_good_analysis | 10.2.0 |
| flutter_launcher_icons | 0.14.4 |

### To Upgrade — 14 Packages

| Package | Current | Target | Type | Risk | Phase |
|---------|---------|--------|------|------|-------|
| audio_session | ^0.2.2 | ^0.2.3 | Patch | Low | 1 |
| audio_service_mpris | ^0.2.0 | ^0.2.1 | Patch | Low | 1 |
| crypto | ^3.0.6 | ^3.0.7 | Patch | Low | 1 |
| url_launcher | ^6.3.1 | ^6.3.2 | Patch | Low | 1 |
| uuid | ^4.5.1 | ^4.5.3 | Patch | Low | 1 |
| json_annotation | ^4.9.0 | ^4.11.0 | Minor | Medium | 2 |
| json_serializable | ^6.11.2 | ^6.13.0 | Minor | Medium | 2 |
| freezed | ^3.2.3 | ^3.2.5 | Patch | Medium | 2 |
| build_runner | ^2.12.2 | ^2.13.1 | Minor | Medium | 2 |
| drift | ^2.31.0 | ^2.32.1 | Minor | High | 3 |
| drift_dev | ^2.31.0 | ^2.32.1 | Minor | High | 3 |
| drift_flutter | ^0.2.5 | ^0.3.0 | Minor | High | 3 |
| flutter_riverpod | ^3.2.1 | ^3.3.1 | Minor | Low | 4 |
| logger | ^2.6.2 | ^2.7.0 | Minor | Low | 5 |

---

## Dependency Constraints

Two hard coupling rules govern the upgrade order:

1. **json_annotation + json_serializable** — `json_serializable 6.13.1` requires `json_annotation >=4.11.0 <4.12.0`. Must be upgraded in the same `pub get` pass.
2. **drift + drift_dev** — `drift_dev 2.32.x` requires `drift >=2.32.0 <2.33.0`. Must be upgraded together.

---

## Phase 1: Safe Patch Updates

**Risk:** Low  
**Estimated time:** 5 minutes  
**Code changes:** None — `pubspec.yaml` only  
**Steps 1a–1e may be applied simultaneously in a single `pubspec.yaml` edit**

---

### 1a — audio_session `^0.2.2` → `^0.2.3`

**What changed:**
- Raised minimum SDK to `^3.6.0` and Flutter to `>=3.27.0`
- No API additions, removals, or signature changes

**Affected files:** None  
**Migration steps:** Update version constraint in `pubspec.yaml` only

---

### 1b — audio_service_mpris `^0.2.0` → `^0.2.1`

**What changed:**
- Updated `dbus` dependency to `^0.7.10`
- Updated `flutter_lints` to `^4.0.0`
- No API changes

**Affected files:** None  
**Migration steps:** Update version constraint in `pubspec.yaml` only

---

### 1c — crypto `^3.0.6` → `^3.0.7`

**What changed:**
- Raised minimum sdk to `^3.4.0`
- No API changes

**Usage in project:**
- `lib/src/api/subsonic_api_client.dart` — MD5 hashing for Subsonic authentication token (`md5.convert(utf8.encode(...))`)

**Affected files:** None  
**Migration steps:** Update version constraint in `pubspec.yaml` only

---

### 1d — url_launcher `^6.3.1` → `^6.3.2`

**What changed:**
- Raised minimum sdk to `^3.6.0`
- No API changes

**Affected files:** None  
**Migration steps:** Update version constraint in `pubspec.yaml` only

---

### 1e — uuid `^4.5.1` → `^4.5.3`

**What changed:**
- Dropped the `sprintf` dependency (internal cleanup)
- No API changes to `Uuid`, `UuidValue`, or any public class

**Usage in project:**
- `lib/src/api/subsonic_api_client.dart` — UUID v4 generation for Subsonic auth salt (`const Uuid().v4()`)

**Affected files:** None  
**Migration steps:** Update version constraint in `pubspec.yaml` only

---

### Phase 1 pubspec.yaml Changes

```yaml
# Before
audio_session: ^0.2.2
audio_service_mpris: ^0.2.0
crypto: ^3.0.6
url_launcher: ^6.3.1
uuid: ^4.5.1

# After
audio_session: ^0.2.3
audio_service_mpris: ^0.2.1
crypto: ^3.0.7
url_launcher: ^6.3.2
uuid: ^4.5.3
```

### Phase 1 Verification

```bash
flutter pub get
flutter analyze
flutter test
```

**Manual smoke test:** Login to a Subsonic server and play a track (exercises audio_session, crypto, and uuid code paths)

---

## Phase 2: Code Generation Chain

**Risk:** Medium  
**Estimated time:** 15 minutes  
**Code changes:** None — code generation only  
**All 4 packages must be upgraded together in a single `pubspec.yaml` edit**

> `json_serializable 6.13.1` hard-requires `json_annotation >=4.11.0 <4.12.0`.  
> Upgrading them separately will cause `pub get` to fail with a version conflict.

---

### 2a — json_annotation `^4.9.0` → `^4.11.0`

**What changed since 4.9.0:**

| Version | Change |
|---------|--------|
| 4.10.0 | `@JsonKey` annotation now supported on constructor parameters (previously class fields only) |
| 4.10.0 | Added `JsonSerializable(createJsonSchema: true)` option for JSON Schema generation |
| 4.10.0 | Raised minimum sdk to `^3.9.0`, meta to `^1.16.0` |
| 4.11.0 | Added `JsonSerializable(dateTimeUtc: true)` option to serialize `DateTime` in UTC |

**Breaking changes:** None  
**Deprecated APIs used:** None — all 20 `@JsonSerializable` classes in this project use APIs stable since 4.0+

**Impact on existing annotations:**

| Pattern | File | Status |
|---------|------|--------|
| `@JsonSerializable(explicitToJson: true)` | `song.dart` | Unchanged |
| `@JsonKey(readValue: _readSampleRateJson)` | `song.dart` | Unchanged |
| `@JsonKey(fromJson: ..., toJson: ...)` | `indexes.dart` | Unchanged |
| `@JsonKey(name: 'index')` | `indexes.dart` | Unchanged |
| `@JsonKey(name: 'public')` | `playlist.dart` | Unchanged |
| `@Freezed(genericArgumentFactories: true)` | `subsonic_response.dart` | Unchanged |

**Affected files:** None — annotation classes themselves have no code to update

---

### 2b — json_serializable `^6.11.2` → `^6.13.0`

**What changed:**
- Now requires `json_annotation >=4.11.0 <4.12.0` (hence the coupling with 2a)
- Minor internal generator improvements; generated output format is functionally identical
- No breaking changes to generated code

> **Constraint note (discovered during implementation):** `json_serializable 6.13.1` requires `analyzer >=10.0.0 <13.0.0`, which conflicts with `riverpod_lint 3.1.3` which pins `analyzer ^9.0.0`. Use `^6.13.0` — the solver then picks 6.13.0, which is fully compatible with both.

**Files that will be regenerated (output identical):**

| File | Class |
|------|-------|
| `lib/src/api/models/song.g.dart` | `Song`, `ReplayGain` |
| `lib/src/api/models/album.g.dart` | `Album` |
| `lib/src/api/models/artist.g.dart` | `Artist` |
| `lib/src/api/models/album_info.g.dart` | `AlbumInfo` |
| `lib/src/api/models/artist_info.g.dart` | `ArtistInfo` |
| `lib/src/api/models/genre.g.dart` | `Genre` |
| `lib/src/api/models/indexes.g.dart` | `Indexes`, `IndexesIndex` |
| `lib/src/api/models/internet_radio_station.g.dart` | `InternetRadioStation` |
| `lib/src/api/models/lyrics.g.dart` | `LyricsList`, `StructuredLyrics`, `LyricLine` |
| `lib/src/api/models/playlist.g.dart` | `Playlist` |
| `lib/src/api/models/search_result3.g.dart` | `SearchResult3` |
| `lib/src/api/models/server_capabilities.g.dart` | `ServerCapabilities`, `OpenSubsonicExtension` |
| `lib/src/api/models/subsonic_response.g.dart` | `SubsonicResponse<T>`, `SubsonicErrorResponse` |
| `lib/src/features/auth/domain/server_config.g.dart` | `ServerConfigModel` |

---

### 2c — freezed `^3.2.3` → `^3.2.5`

**What changed:**
- Raised minimum sdk to `>=3.8.0`
- Raised analyzer requirement to `>=9.0.0 <11.0.0`
- Bug fixes and internal improvements; no API changes

**Breaking changes:** None  
**Impact on existing annotations:** All `@freezed` and `@Freezed(...)` usages unchanged

**Notable usage:** `SubsonicResponse<T>` uses `@Freezed(genericArgumentFactories: true)` — this pattern is stable and will regenerate without changes.

**Files that will be regenerated (output functionally identical):**  
All `.freezed.dart` files alongside Freezed model classes (within the API model files and feature domain models).

---

### 2d — build_runner `^2.12.2` → `^2.13.1`

**What changed:**
- Raised minimum sdk to `^3.7.0`
- Updated analyzer support to `>=8.0.0 <13.0.0`
- No breaking changes to any `build_runner` CLI commands or build configuration

**Affected files:** None — this is a dev tool only, no runtime impact

---

### Phase 2 pubspec.yaml Changes

```yaml
# Before (dependencies)
json_annotation: ^4.9.0

# After (dependencies)
json_annotation: ^4.11.0

# Before (dev_dependencies)
build_runner: ^2.12.2
freezed: ^3.2.3
json_serializable: ^6.11.2

# After (dev_dependencies)
build_runner: ^2.13.1
freezed: ^3.2.5
json_serializable: ^6.13.0   # 6.13.1 incompatible with riverpod_lint 3.1.3
```

### Phase 2 Verification

```bash
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter analyze
flutter test
```

**Expected:** Regenerated `.g.dart` and `.freezed.dart` files show only cosmetic differences (version header comments). No logic changes.

---

## Phase 3: Drift Stack

**Risk:** High  
**Estimated time:** 30 minutes  
**Code changes:** None — code regeneration only  
**All 3 packages must be upgraded together in a single `pubspec.yaml` edit**

> `drift_flutter 0.3.0` is labeled "potentially breaking" in its changelog.  
> In practice, the **only change** is upgrading the internal `sqlite3` Dart package from version 2.x to 3.x.  
> The `driftDatabase()` public API is completely unchanged.  
> The underlying SQLite engine version does not change — only the Dart FFI bindings are updated.

---

### 3a — drift `^2.31.0` → `^2.32.1`

**What changed since 2.31.0:**

| Version | Change |
|---------|--------|
| 2.32.0 | **Internal:** Migrated to `sqlite3` package 3.x. Transparent to Navis — `drift_flutter` / `sqlite3_flutter_libs` absorbs this change |
| 2.32.0 | `serializableConnection()`, `json1`, and `TableMigration` no longer experimental |
| 2.32.0 | Performance improvement for mapping large result sets from joined select statements |
| 2.32.1 | DevTools extension: error messages now selectable |

**Breaking changes affecting Navis:** None

The following drift APIs used in Navis are all **unchanged**:

| API | Used in |
|-----|---------|
| `@DriftDatabase(tables: [...], daos: [...])` | `navis_database.dart` |
| `@DriftAccessor(tables: [...])` | All 10 DAO files |
| `DatabaseAccessor<NavisDatabase>` | All 10 DAO files |
| `MigrationStrategy(onCreate:, onUpgrade:, beforeOpen:)` | `navis_database.dart` |
| `Migrator.createAll()` | `navis_database.dart` |
| `Migrator.createTable()`, `addColumn()`, `alterTable()`, `recreateTable()` | `navis_database.dart` migrations |
| `customStatement(String)` | `navis_database.dart` (PRAGMA statements) |
| `Value<T>` companion class | Multiple DAO files |
| Stream queries (`watch()`, `watchSingle()`) | Multiple DAO files |
| `transaction(() async { ... })` | Multiple DAO files |
| `batch((batch) { ... })` | Multiple DAO files |

---

### 3b — drift_dev `^2.31.0` → `^2.32.1`

**What changed:**
- Code generator updated to match drift 2.32.x
- Must be the **same minor version** as the drift runtime package
- No changes to any builder options or code generation behavior affecting Navis

**Files that will be regenerated:**

| File |
|------|
| `lib/src/database/navis_database.g.dart` |
| `lib/src/database/daos/app_settings_dao.g.dart` |
| `lib/src/database/daos/cache_dao.g.dart` |
| `lib/src/database/daos/download_queue_dao.g.dart` |
| `lib/src/database/daos/history_dao.g.dart` |
| `lib/src/database/daos/library_dao.g.dart` |
| `lib/src/database/daos/play_queue_dao.g.dart` |
| `lib/src/database/daos/playlist_dao.g.dart` |
| `lib/src/database/daos/scrobble_dao.g.dart` |
| `lib/src/database/daos/server_dao.g.dart` |
| `lib/src/database/daos/star_sync_dao.g.dart` |

---

### 3c — drift_flutter `^0.2.5` → `^0.3.0`

**What changed:**
- Internally uses `sqlite3` package 3.x instead of 2.x
- The `driftDatabase()` function signature and behavior are **completely unchanged**:

```dart
// This call in navis_database.dart requires NO changes
static QueryExecutor _openConnection() => driftDatabase(name: 'navis.sqlite');
```

- `DriftNativeOptions` class: all parameters (`shareAcrossIsolates`, `setup`, `isolateDebugLog`, `isolateSetup`) unchanged
- `DriftWebOptions` class: all parameters unchanged

**Risk assessment per usage site:**

| Usage site | Risk | Notes |
|------------|------|-------|
| `lib/src/database/navis_database.dart:73` — `driftDatabase(name:)` | **None** | Public API unchanged |
| `test/helpers/test_database.dart` — `NativeDatabase.memory()` | **Low** | Works with sqlite3 3.x |
| `test/src/database/migrations/navis_migration_test.dart` — `sqlite3.openInMemory()` | **Low** | Direct sqlite3 still functions identically |
| All 35 schema migration steps | **None** | Migration logic does not touch sqlite3 bindings directly |

**Data integrity:** Existing databases created with sqlite3 2.x open correctly under 3.x. The SQLite engine (the C library) version is unchanged — only the Dart wrapper package version incremented.

---

### Phase 3 pubspec.yaml Changes

```yaml
# Before (dependencies)
drift: ^2.31.0
drift_flutter: ^0.2.5

# After (dependencies)
drift: ^2.32.1
drift_flutter: ^0.3.0

# Before (dev_dependencies)
drift_dev: ^2.31.0

# After (dev_dependencies)
drift_dev: ^2.32.1
```

### Phase 3 Verification

```bash
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter analyze
flutter test
```

**High-priority tests to inspect:**

| Test file | Why critical |
|-----------|-------------|
| `test/src/database/migrations/navis_migration_test.dart` | Validates all 35 migration steps and schema integrity |
| `test/src/database/library_dao_test.dart` | Core read operations (artists, albums, songs, genres) |
| `test/src/database/daos/download_queue_dao_test.dart` | Queue insert/update/delete operations |
| `test/src/providers/app_providers_test.dart` | Provider integration with live NavisDatabase instance |
| `test/src/features/downloads/download_service_test.dart` | Download service with DB interactions |
| `test/src/features/cache/data/rolling_cache_manager_test.dart` | Cache DAO operations |

**Manual smoke test:** Launch the app on a device with an existing database. Verify:
1. App opens without database migration errors in the log
2. Previously synced library (artists, albums, songs) is visible
3. Download queue entries are intact
4. Play history is intact
5. Audio plays successfully

---

## Phase 4: Riverpod Minor Update

**Risk:** Low  
**Estimated time:** 5 minutes  
**Code changes:** None — `pubspec.yaml` only

---

### 4a — flutter_riverpod `^3.2.1` → `^3.3.1`

**What changed since 3.2.1:**

| Version | Change |
|---------|--------|
| 3.3.0 | Added `ChangeNotifierProvider(disposeNotifier: false)` — new optional named parameter, fully backward compatible |
| 3.3.1 | Added missing `disposeNotifier` flag on `overrideWith` |

**Breaking changes:** None — purely additive  
**Deprecated APIs:** None used in project

**Impact on existing providers:**

| Provider type | Count | Status |
|---------------|-------|--------|
| `Provider` | ~50+ | Unchanged |
| `StreamProvider` | ~40+ | Unchanged |
| `FutureProvider` | ~15+ | Unchanged |
| `ChangeNotifierProvider` | 1 | Unchanged — `disposeNotifier` parameter is optional with default behavior |

The single `ChangeNotifierProvider<DesktopWindowController>` at `lib/src/routing/desktop_window_controller.dart:582`, imported via `flutter_riverpod/legacy.dart`, continues to work identically without any parameter changes.

---

### Phase 4 pubspec.yaml Changes

```yaml
# Before
flutter_riverpod: ^3.2.1

# After
flutter_riverpod: ^3.3.1
```

### Phase 4 Verification

```bash
flutter pub get
flutter analyze
flutter test
```

**Manual smoke test:** On desktop, verify window management controls (minimize, maximize, close) still function correctly.

---

## Phase 5: Logger Minor Update

**Risk:** Low  
**Estimated time:** 2 minutes  
**Code changes:** None — `pubspec.yaml` only

---

### 5a — logger `^2.6.2` → `^2.7.0`

**What changed:**
- Added `meta` and `clock` as explicit dependencies (were previously transitive)
- Internal improvements to log output formatting
- No changes to `Logger`, `Level`, `LogOutput`, `LogPrinter`, or any public API

**Usage in project:** All usages go through a project-internal logger wrapper — no direct API calls that could be affected.

**Affected files:** None  
**Migration steps:** Update version constraint in `pubspec.yaml` only

---

### Phase 5 pubspec.yaml Changes

```yaml
# Before
logger: ^2.6.2

# After
logger: ^2.7.0
```

### Phase 5 Verification

```bash
flutter pub get
flutter analyze
flutter test
```

---

## Full End-to-End Verification

After all 5 phases are complete:

```bash
# 1. Confirm clean dependency resolution
flutter pub get

# 2. Confirm all generated code is up to date
dart run build_runner build --delete-conflicting-outputs

# 3. Static analysis — zero new errors or warnings
flutter analyze

# 4. Full test suite
flutter test

# 5. Build release APK (Android smoke build)
flutter build apk --release
```

**Manual smoke test checklist:**

- [ ] App launches without errors or database migration failures
- [ ] Login to a Subsonic server works (exercises crypto + uuid + dio)
- [ ] Library syncs: artists, albums, songs, genres appear (exercises drift, stream providers)
- [ ] Audio playback starts and media controls respond (exercises audio_service, audio_session)
- [ ] Download a track and verify it completes (exercises download queue DAO)
- [ ] Search returns results (exercises search providers + API client)
- [ ] Changelog page loads (exercises url_launcher + flutter_markdown_plus)
- [ ] Desktop: window minimize/maximize/close work (exercises window_manager + ChangeNotifierProvider)
- [ ] On Linux: MPRIS media controls work (exercises audio_service_mpris)

---

## Key Decisions

### On drift_flutter 0.3.0 Labeled "Potentially Breaking"

The label refers to the sqlite3 Dart package version jump from 2.x to 3.x. For this project, the risk is effectively zero because:

1. **No direct sqlite3 production usage** — all access goes through `drift_flutter`'s `driftDatabase()` helper
2. **SQLite engine is unchanged** — the C library version stays the same; only the Dart FFI wrapper incremented
3. **Existing databases are compatible** — the on-disk format is identical between sqlite3 2.x and 3.x
4. **`driftDatabase()` API is unchanged** — the single call site at `navis_database.dart:73` requires no modifications

### On Upgrade Ordering

Phases are ordered to minimize rollback scope: low-coupling patches first, then code gen tools (which have no user-visible API surface), then the highest-coupling piece (Drift stack), then standalone minor updates.

### On What Was Excluded

These are already at their latest versions and need no changes:
- Android Gradle Plugin (8.12.1)
- Kotlin plugin (2.2.20)  
- Gradle wrapper (8.14)
- Flutter SDK (>=3.41.0 already specified)

### On What Was Intentionally Skipped

There are pre-release versions available for some packages (e.g., `audio_service_mpris 1.0.0-beta.2`). These have been excluded: pre-release versions are explicitly out of scope for a stability-focused upgrade.
