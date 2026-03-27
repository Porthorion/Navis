# Package Upgrade Progress

> **Navis** — Subsonic/OpenSubsonic music player  
> Plan: [docs/package-upgrade-plan.md](package-upgrade-plan.md)  
> Started: 2026-03-28  
> Completed: —

> **Baseline:** commit `a44eb7a` (branch `dev`)

---

## Overall Status

| Phase | Description | Status |
|-------|-------------|--------|
| Phase 1 | Safe patch updates (5 packages) | ✅ Done |
| Phase 2 | Code generation chain (4 packages) | 🔄 In progress |
| Phase 3 | Drift stack (3 packages) | ⬜ Not started |
| Phase 4 | Riverpod minor update (1 package) | ⬜ Not started |
| Phase 5 | Logger minor update (1 package) | ⬜ Not started |

**Legend:** ⬜ Not started · 🔄 In progress · ✅ Done · ❌ Blocked

---

## Phase 1: Safe Patch Updates

> All 5 version bumps can be applied simultaneously in a single `pubspec.yaml` edit.  
> No code changes. No regeneration required.

| Step | Package | Change | Status | Notes |
|------|---------|--------|--------|-------|
| 1a | audio_session | `^0.2.2` → `^0.2.3` | ✅ | |
| 1b | audio_service_mpris | `^0.2.0` → `^0.2.1` | ✅ | |
| 1c | crypto | `^3.0.6` → `^3.0.7` | ✅ | |
| 1d | url_launcher | `^6.3.1` → `^6.3.2` | ✅ | |
| 1e | uuid | `^4.5.1` → `^4.5.3` | ✅ | dropped sprintf dep, no API changes |

### Phase 1 Checklist

- [x] Update 5 version constraints in `pubspec.yaml`
- [x] `flutter pub get` succeeds
- [x] `flutter analyze` — no new errors (226 pre-existing info hints, unchanged)
- [x] `flutter test` — +342 -14 (14 failures are pre-existing, identical to baseline)
- [ ] Smoke test: login to a Subsonic server and play a track

---

## Phase 2: Code Generation Chain

> `json_serializable 6.13.1` requires `json_annotation >=4.11.0 <4.12.0`.  
> All 4 version bumps must be applied simultaneously. Code regeneration required.

| Step | Package | Change | Status | Notes |
|------|---------|--------|--------|-------|
| 2a | json_annotation | `^4.9.0` → `^4.11.0` | 🔄 | |
| 2b | json_serializable | `^6.11.2` → `^6.13.1` | 🔄 | |
| 2c | freezed | `^3.2.3` → `^3.2.5` | 🔄 | |
| 2d | build_runner | `^2.12.2` → `^2.13.1` | 🔄 | |

### Phase 2 Checklist

- [ ] Update 4 version constraints in `pubspec.yaml`
- [ ] `flutter pub get` succeeds with no version conflicts
- [ ] `dart run build_runner build --delete-conflicting-outputs` succeeds
- [ ] Regenerated files diff shows only cosmetic changes (no logic changes)
  - [ ] `lib/src/api/models/*.g.dart` (13 files)
  - [ ] `lib/src/features/auth/domain/server_config.g.dart`
  - [ ] `.freezed.dart` files (API models + domain models)
- [ ] `flutter analyze` — no new errors
- [ ] `flutter test` — all tests pass

---

## Phase 3: Drift Stack

> `drift_dev 2.32.x` requires `drift >=2.32.0 <2.33.0`.  
> All 3 version bumps must be applied simultaneously. Code regeneration required.  
> **Highest risk phase — run full database test suite after regeneration.**

| Step | Package | Change | Status | Notes |
|------|---------|--------|--------|-------|
| 3a | drift | `^2.31.0` → `^2.32.1` | ⬜ | |
| 3b | drift_dev | `^2.31.0` → `^2.32.1` | ⬜ | |
| 3c | drift_flutter | `^0.2.5` → `^0.3.0` | ⬜ | |

### Phase 3 Checklist

- [ ] Update 3 version constraints in `pubspec.yaml`
- [ ] `flutter pub get` succeeds with no version conflicts
- [ ] `dart run build_runner build --delete-conflicting-outputs` succeeds
- [ ] Regenerated database files reviewed
  - [ ] `lib/src/database/navis_database.g.dart`
  - [ ] `lib/src/database/daos/app_settings_dao.g.dart`
  - [ ] `lib/src/database/daos/cache_dao.g.dart`
  - [ ] `lib/src/database/daos/download_queue_dao.g.dart`
  - [ ] `lib/src/database/daos/history_dao.g.dart`
  - [ ] `lib/src/database/daos/library_dao.g.dart`
  - [ ] `lib/src/database/daos/play_queue_dao.g.dart`
  - [ ] `lib/src/database/daos/playlist_dao.g.dart`
  - [ ] `lib/src/database/daos/scrobble_dao.g.dart`
  - [ ] `lib/src/database/daos/server_dao.g.dart`
  - [ ] `lib/src/database/daos/star_sync_dao.g.dart`
- [ ] `flutter analyze` — no new errors
- [ ] `flutter test` — paying close attention to:
  - [ ] `test/src/database/migrations/navis_migration_test.dart` (all 35 migration steps)
  - [ ] `test/src/database/library_dao_test.dart`
  - [ ] `test/src/database/daos/download_queue_dao_test.dart`
  - [ ] `test/src/providers/app_providers_test.dart`
  - [ ] `test/src/features/downloads/download_service_test.dart`
  - [ ] `test/src/features/cache/data/rolling_cache_manager_test.dart`
- [ ] Smoke test on device with **existing database**:
  - [ ] App launches without database migration errors in log
  - [ ] Previously synced library is intact (artists, albums, songs visible)
  - [ ] Download queue entries are intact
  - [ ] Play history is intact
  - [ ] Audio plays successfully

---

## Phase 4: Riverpod Minor Update

> Standalone update, no coupling with other phases.  
> No code changes. No regeneration required.

| Step | Package | Change | Status | Notes |
|------|---------|--------|--------|-------|
| 4a | flutter_riverpod | `^3.2.1` → `^3.3.1` | ⬜ | |

### Phase 4 Checklist

- [ ] Update version constraint in `pubspec.yaml`
- [ ] `flutter pub get` succeeds
- [ ] `flutter analyze` — no new errors
- [ ] `flutter test` — all tests pass
- [ ] Smoke test (desktop): window minimize/maximize/close controls work

---

## Phase 5: Logger Minor Update

> Standalone update, no coupling with other phases.  
> No code changes. No regeneration required.

| Step | Package | Change | Status | Notes |
|------|---------|--------|--------|-------|
| 5a | logger | `^2.6.2` → `^2.7.0` | ⬜ | |

### Phase 5 Checklist

- [ ] Update version constraint in `pubspec.yaml`
- [ ] `flutter pub get` succeeds
- [ ] `flutter analyze` — no new errors
- [ ] `flutter test` — all tests pass

---

## Final End-to-End Verification

After all phases are marked Done:

- [ ] `flutter pub get` — clean resolution
- [ ] `dart run build_runner build --delete-conflicting-outputs` — all generated code up to date
- [ ] `flutter analyze` — zero errors, zero warnings from upgrades
- [ ] `flutter test` — full test suite passes
- [ ] `flutter build apk --release` — release APK builds successfully
- [ ] Full manual smoke test:
  - [ ] App launches without errors
  - [ ] Login to a Subsonic server
  - [ ] Library syncs: artists, albums, songs, genres appear
  - [ ] Audio playback starts and media controls respond
  - [ ] Download a track and verify it completes
  - [ ] Search returns results
  - [ ] Changelog page loads
  - [ ] Desktop: window minimize/maximize/close work
  - [ ] Linux: MPRIS media controls work

---

## Issues Log

*Record any problems encountered during the upgrade here.*

| Date | Phase | Package | Issue | Resolution |
|------|-------|---------|-------|------------|
| — | — | — | — | — |
