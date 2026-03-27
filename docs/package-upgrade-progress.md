# Package Upgrade Progress

> **Navis** — Subsonic/OpenSubsonic music player  
> Plan: [docs/package-upgrade-plan.md](package-upgrade-plan.md)  
> Started: 2026-03-28  
> Completed: 2026-03-28

> **Baseline:** commit `a44eb7a` (branch `dev`)

---

## Overall Status

| Phase | Description | Status |
|-------|-------------|--------|
| Phase 1 | Safe patch updates (5 packages) | ✅ Done |
| Phase 2 | Code generation chain (4 packages) | ✅ Done |
| Phase 3 | Drift stack (3 packages) | ✅ Done |
| Phase 4 | Riverpod minor update (1 package) | ✅ Done |
| Phase 5 | Logger minor update (1 package) | ✅ Done |

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
| 2a | json_annotation | `^4.9.0` → `^4.11.0` | ✅ | |
| 2b | json_serializable | `^6.11.2` → `^6.13.0` | ✅ | capped at 6.13.0 — 6.13.1 requires analyzer >=10 which conflicts with riverpod_lint 3.1.3 (analyzer ^9) |
| 2c | freezed | `^3.2.3` → `^3.2.5` | ✅ | |
| 2d | build_runner | `^2.12.2` → `^2.13.1` | ✅ | |

### Phase 2 Checklist

- [x] Update 4 version constraints in `pubspec.yaml`
- [x] `flutter pub get` succeeds with no version conflicts
- [x] `dart run build_runner build --delete-conflicting-outputs` succeeds (570 outputs written in 23s)
- [x] Regenerated files diff shows only cosmetic changes (no logic changes)
  - [x] `lib/src/api/models/*.g.dart` (13 files)
  - [x] `lib/src/features/auth/domain/server_config.g.dart`
  - [x] `.freezed.dart` files (API models + domain models)
- [x] `flutter analyze` — 226 issues (pre-existing, unchanged)
- [x] `flutter test` — +342 -14 (14 pre-existing failures, unchanged)

> **Note:** `json_serializable 6.13.1` was immediately incompatible: it requires `analyzer >=10.0.0` while `riverpod_lint 3.1.3` pins `analyzer ^9.0.0`. Capped at `^6.13.0` which resolves to 6.13.0 — still an upgrade from 6.11.2. Upgrade plan document updated to reflect this constraint.

---

## Phase 3: Drift Stack

> `drift_dev 2.32.x` requires `drift >=2.32.0 <2.33.0`.  
> All 3 version bumps must be applied simultaneously. Code regeneration required.  
> **Highest risk phase — run full database test suite after regeneration.**

| Step | Package | Change | Status | Notes |
|------|---------|--------|--------|-------|
| 3a | drift | `^2.31.0` → `^2.32.1` | ✅ | |
| 3b | drift_dev | `^2.31.0` → `^2.32.1` | ✅ | unblocked by removing inactive `riverpod_lint` |
| 3c | drift_flutter | `^0.2.5` → `^0.3.0` | ✅ | |

### Phase 3 Checklist

- [x] Remove inactive `riverpod_lint` dev dependency (unblocks analyzer constraint)
- [x] Update 3 version constraints in `pubspec.yaml`
- [x] `flutter pub get` succeeds (analyzer jumped to 10.0.1)
- [x] `dart run build_runner build --delete-conflicting-outputs` succeeds (570 outputs in 22s)
- [x] `flutter analyze` — 228 issues (226 pre-existing + 2 new `use_null_aware_elements` hints surfaced by analyzer 10.x on pre-existing code; no errors/warnings)
- [x] `flutter test` — +342 -14 (14 pre-existing failures, unchanged)

---

## Phase 4: Riverpod Minor Update

> Standalone update, no coupling with other phases.  
> No code changes. No regeneration required.

| Step | Package | Change | Status | Notes |
|------|---------|--------|--------|-------|
| 4a | flutter_riverpod | `^3.2.1` → `^3.3.1` | ✅ | |

### Phase 4 Checklist

- [x] Update version constraint in `pubspec.yaml`
- [x] `flutter pub get` succeeds
- [x] `flutter analyze` — 226 issues (pre-existing, unchanged)
- [x] `flutter test` — +342 -14 (14 pre-existing failures, unchanged)

---

## Phase 5: Logger Minor Update

> Standalone update, no coupling with other phases.  
> No code changes. No regeneration required.

| Step | Package | Change | Status | Notes |
|------|---------|--------|--------|-------|
| 5a | logger | `^2.6.2` → `^2.7.0` | ✅ | |

### Phase 5 Checklist

- [x] Update version constraint in `pubspec.yaml`
- [x] `flutter pub get` succeeds
- [x] `flutter analyze` — 226 issues (pre-existing, unchanged)
- [x] `flutter test` — +342 -14 (14 pre-existing failures, unchanged)

---

## Final End-to-End Verification

Phase 3 (drift stack) is blocked — see Phase 3 section. All other phases complete.

- [x] `flutter pub get` — clean resolution
- [x] `dart run build_runner build --delete-conflicting-outputs` — all outputs up to date (1 output written, rest skipped)
- [x] `flutter analyze` — 226 info hints (all pre-existing, no new errors/warnings from upgrades)
- [x] `flutter test` — +342 -14 (14 pre-existing failures, unchanged from baseline)
- [ ] `flutter build apk --release` — not run (optional; CI gated)
- [ ] Full manual smoke test (requires device + Subsonic server):
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

| # | Phase | Package | Issue | Resolution |
|---|-------|---------|-------|------------|
| 1 | 2 | json_serializable | `6.13.1` requires `analyzer >=10.0.0 <13.0.0`; incompatible with `riverpod_lint 3.1.3` (`analyzer ^9.0.0`) | Capped at `^6.13.0` (resolves to 6.13.0) |
| 2 | 3 | drift stack | `drift_dev >2.31.0` requires `analyzer >=10.0.0`; `riverpod_lint 3.1.3` pins `analyzer ^9.0.0`. Entire stack was locked. | Removed inactive `riverpod_lint` (its runner `custom_lint` was already commented out — zero rules were firing). Drift stack upgraded successfully. |

| Date | Phase | Package | Issue | Resolution |
|------|-------|---------|-------|------------|
| — | — | — | — | — |
