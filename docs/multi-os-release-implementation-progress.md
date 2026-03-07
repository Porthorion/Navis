# Multi-OS Release Implementation Progress

Last updated: 2026-03-07

This document is the detailed execution log for preparing Navis as a native app release across Android, macOS, Windows, and Linux.

## Scope and tracking rules
- This file is the detailed tracker (task-level evidence, environment readiness, command-level validation).
- `PROGRESS.md` remains the high-level tracker and links here for Phase 26 execution details.
- Entries are append-only unless corrected by a later dated note.

## Current baseline
- Active branch: `dev`
- Target app version: `0.8.0+800`
- Release model: incremental commits and pushes on `dev`
- Packaging/scaffolding files for platform folders (`macos/`, `windows/`) are intentionally not included in this app-first commit stream.

## Execution log (2026-03-07)

### A. App code review and stabilization
- Status: completed
- Actions:
  - Ran focused analyzer and changed-suite tests over app/runtime changes.
  - Found regression in `playback_settings_screen_test.dart` caused by autosave UI replacing explicit Save button.
  - Updated tests for autosave debounce flow and reset behavior.
  - Removed unused import warning in `app_shell_navigation_test.dart`.
  - Replaced hardcoded now-playing menu label with localized `l10n.nowPlayingLyrics`.
- Evidence:
  - `flutter test test/src/features/settings/presentation/playback_settings_screen_test.dart`
  - `flutter test test/src/routing/app_shell_navigation_test.dart`
  - `flutter test test/src/api/subsonic_api_client_test.dart test/src/api/subsonic_retry_interceptor_test.dart test/src/features/library/data/library_sync_engine_test.dart test/src/features/player/data/navis_audio_handler_test.dart test/src/providers/app_providers_test.dart test/src/routing/app_shell_navigation_test.dart test/src/features/settings/presentation/playback_settings_screen_test.dart`

### B. Incremental commit/push sequence to 0.8.0 release point
- Status: completed
- Commit/push stream:
  - `c48081b` — `feat(playback): harden audio bootstrap and playback metadata flow`
  - `7df2adb` — `feat(ui): overhaul adaptive shell and now-playing interactions`
  - `3d396a8` — `build(android): allow sidecar identity on release builds`
  - `849a966` — `chore(repo): ignore desktop packaging and ephemeral artifacts`
- Notes:
  - Commits above were pushed incrementally to `origin/dev`.
  - Multi-OS scaffolding files remain uncommitted in this stream by design.

### C. Versioning and release-point prep
- Status: completed
- Actions:
  - Bumped app version in `pubspec.yaml` to `0.8.0+800`.
  - Added `.gitignore` entries for desktop packaging outputs and platform ephemeral artifacts.
  - Linked `PROGRESS.md` Phase 26 to this detailed tracker.

### D. Published release APK with release automation
- Status: completed
- Actions:
  - Ran `./tool/release.sh v0.8.0 --skip-checks` from `dev`.
  - Script built and validated APK metadata/signing, fast-forwarded `main` to current `dev`, created tag `v0.8.0`, published Forgejo release, and uploaded asset `navis-v0.8.0.apk`.
- Evidence:
  - Release URL: `https://git.porthorion.com/khalifa/Navis/releases/tag/v0.8.0`
  - Git operations performed by script:
    - `main` fast-forwarded to commit `0507e82`
    - tag `v0.8.0` pushed

### E. Multi-OS implementation kickoff (post-release)
- Status: in progress
- Actions completed in this kickoff block:
  - Added multi-target/channel-aware release workflow and sidecar tooling/docs.
  - Added desktop runner scaffolding for macOS and Windows to the repository.
- Commits:
  - `ba7ca19` — `feat(release): add multi-target publishing and sidecar workflows`
  - `daa3956` — `chore(platform): add macos and windows desktop runner scaffolding`
- Push status:
  - Both commits pushed to `origin/dev`.

### F. Desktop runtime baseline hardening
- Status: completed
- Actions:
  - Enabled outbound network entitlement for macOS debug and release sandbox profiles.
  - Updated macOS app product name to `Navis`.
  - Updated Windows runner metadata (`FileDescription`, `ProductName`) to `Navis`.
- Evidence:
  - `macos/Runner/DebugProfile.entitlements`
  - `macos/Runner/Release.entitlements`
  - `macos/Runner/Configs/AppInfo.xcconfig`
  - `windows/runner/Runner.rc`
  - `plutil -lint macos/Runner/DebugProfile.entitlements macos/Runner/Release.entitlements macos/Runner/Info.plist`

## Open work for plan implementation
- Machine readiness
  - Complete Xcode installation + first-launch toolchain setup.
  - Install CocoaPods and re-run `flutter doctor -v` until clean for Apple targets.
  - Accept pending Android licenses.
- Host matrix
  - Prepare native Windows build host and native Linux build host.
  - Define signing/notarization credential handling and secure secret flow.
- Packaging path
  - Finalize Windows installer format and signed distribution path.
  - Finalize Linux `.deb` + portable bundle artifact pipeline.
  - Finalize macOS notarization and distribution verification workflow.
- QA and release gate
  - Establish a clean release gate command that does not depend on unavailable lint tools.
  - Add/verify targeted tests for platform-specific update/install paths.

## Change-control note
If commit scope needs to include platform scaffolding files later, that transition should happen in a dedicated commit set after this `0.8.0` app-first stabilization point.
