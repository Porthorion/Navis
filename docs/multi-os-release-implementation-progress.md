# Multi-OS Release Implementation Progress

Last updated: 2026-03-08

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

## Execution log (2026-03-07 to 2026-03-08)

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

### G. Desktop audio backend bootstrap alignment
- Status: in progress
- Actions:
  - Added `media_kit_libs_macos_audio` to desktop audio runtime dependencies.
  - Initialized `just_audio_media_kit` during app startup on desktop platforms before playback bootstrap.
  - Set desktop media backend title to `Navis` for native mixer/process labeling consistency.
- Evidence:
  - `flutter pub add media_kit_libs_macos_audio`
  - `lib/main.dart` (`_initializeDesktopAudioBackend`, called from `main()`)
  - `flutter analyze lib/main.dart`
  - `flutter test test/src/features/player/data/navis_audio_handler_test.dart`
- Change control:
  - Applied as local working-tree changes only (no commit/push in this step).

### H. Machine preflight automation for multi-OS releases
- Status: in progress
- Actions:
  - Added host readiness script `tool/multi_os_host_preflight.sh` with:
    - deterministic tool checks (`flutter`, `dart`, `git`, `cmake`, `ninja`)
    - macOS-specific checks for Xcode CLT, `xcodebuild`, CocoaPods, `adb`
    - install-command hints for macOS, Linux, and Windows hosts
    - optional `--auto-fix` (best-effort Homebrew installs on macOS)
    - optional `--doctor` to append `flutter doctor -v` output
  - Documented script usage in `docs/development-workflow.md`.
- Evidence:
  - `./tool/multi_os_host_preflight.sh --help`
  - `./tool/multi_os_host_preflight.sh`
  - `docs/development-workflow.md` section `Multi-OS Host Preflight`
- Findings from this host run:
  - CocoaPods missing on current macOS machine.
  - `ANDROID_SDK_ROOT` not exported in environment (Flutter can still discover default path).
- Change control:
  - Applied as local working-tree changes only (no commit/push in this step).

### I. Host readiness execution on current macOS machine
- Status: in progress
- Actions:
  - Executed preflight with autofix and doctor output capture.
  - Installed missing host dependencies via Homebrew:
    - `cocoapods`, `cmake`, `ninja`, `pkgconf`, `openjdk@21`
    - `android-commandlinetools` cask
  - Accepted pending Android SDK licenses.
  - Re-ran preflight + doctor to validate toolchain state.
- Evidence:
  - `./tool/multi_os_host_preflight.sh --auto-fix --doctor`
  - `yes | flutter doctor --android-licenses`
  - `./tool/multi_os_host_preflight.sh --doctor`
- Result:
  - Android toolchain is now fully green in `flutter doctor -v`.
  - CocoaPods is now installed (`1.16.2`).
  - Root Apple setup has now been completed by user:
    - `sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer`
    - `sudo xcodebuild -runFirstLaunch`
  - Current remaining warning is simulator-runtime availability (`flutter doctor` still reports `Unable to get list of installed Simulator runtimes`).
  - For this project’s active multi-OS release scope (Android/macOS/Windows/Linux), simulator runtime absence is non-blocking for macOS desktop artifacts.

### J. Linux native packaging hardening
- Status: in progress
- Actions:
  - Enhanced `--linux-package=deb` packaging in `tool/release.sh`:
    - architecture-aware `.deb` naming (`linux-<arch>.deb`)
    - launcher wrapper installed in `/usr/bin/<package>`
    - desktop entry installed in `/usr/share/applications`
    - app icon installation under hicolor icon path
    - standards-aligned Debian control fields with configurable maintainer
    - deterministic root ownership in package build via `dpkg-deb --root-owner-group`
  - Updated release docs to reflect new Linux package behavior.
- Evidence:
  - `tool/release.sh` (`--linux-package=deb` block)
  - `bash -n tool/release.sh`
  - `docs/ci-cd.md`
  - `docs/dev-testing-builds.md`
- Change control:
  - Applied as local working-tree changes only (no commit/push in this step).

### L. CocoaPods integration baseline + desktop build validation
- Status: in progress
- Actions:
  - Kept Flutter/CocoaPods integration files generated by platform readiness setup as tracked source:
    - `ios/Podfile`, `macos/Podfile`
    - Pod xcconfig includes in iOS/macOS Flutter xcconfig files
  - Updated host preflight to surface missing Xcode simulator runtimes explicitly as warning (non-blocking for macOS-only desktop releases).
  - Validated macOS desktop release build on current machine.
- Evidence:
  - `xcrun simctl list runtimes`
  - `./tool/multi_os_host_preflight.sh --doctor`
  - `flutter build macos --release --dart-define=NAVIS_UPDATE_CHANNEL=stable`
- Result:
  - Desktop build succeeds (`build/macos/Build/Products/Release/Navis.app`).
  - Build emits warnings from third-party pods (`sqlite3`, `audio_session`) but no fatal errors.

### K. Windows installer + macOS notarization release scaffolding
- Status: in progress
- Actions:
  - Added optional Windows installer mode to release automation:
    - `--windows-package=zip|exe` (default `zip`)
    - `exe` mode invokes Inno Setup compiler via `tool/windows/build_inno_installer.ps1`
  - Added optional macOS notarization mode:
    - `--macos-notarize` in `tool/release.sh`
    - implemented helper `tool/macos_notarize.sh` for sign/notarize/staple/archive
  - Added optional release environment keys in `tool/release.env.example` for Debian maintainer + macOS notarization credentials.
  - Updated release workflow docs for new packaging modes and prerequisites.
- Evidence:
  - `tool/release.sh` arg parsing and platform packaging blocks
  - `tool/windows/build_inno_installer.ps1`
  - `tool/macos_notarize.sh --help`
  - `bash -n tool/release.sh`
  - `bash -n tool/macos_notarize.sh`
  - `docs/ci-cd.md`, `docs/dev-testing-builds.md`, `docs/development-workflow.md`
- Change control:
  - Applied as local working-tree changes only (no commit/push in this step).

### M. MacBook testing playbook + core release gate
- Status: completed
- Actions:
  - Added `tool/release_gate_core.sh` for strict release checks without `custom_lint`.
  - Added Make targets:
    - `make release-gate-core`
    - `make release-gate-core-quick`
  - Added dedicated MacBook test playbook:
    - `docs/macos-testing-playbook.md`
  - Linked testing flow into development docs and README docs index.
- Evidence:
  - `tool/release_gate_core.sh --help`
  - `bash -n tool/release_gate_core.sh`
  - `docs/macos-testing-playbook.md`
  - `docs/development-workflow.md`
  - `Makefile`
  - `README.md`

### N. Release secret-handling baseline
- Status: completed
- Actions:
  - Added `docs/release-secrets.md` to define credential classes, storage policy, and Apple notary keychain flow.
  - Linked the secrets doc from CI/release documentation.
- Evidence:
  - `docs/release-secrets.md`
  - `docs/ci-cd.md`

### O. Desktop UX redesign v1 implementation (feature-flagged core surfaces)
- Status: in progress
- Actions:
  - Added persisted desktop rollout setting and build-default wiring:
    - DB schema bumped to `31`
    - new setting column `desktop_ui_v1_enabled`
    - build define default support via `NAVIS_DESKTOP_UI_V1_DEFAULT`
  - Added desktop foundation layer:
    - `DesktopLayoutClass` resolver (`compact`, `standard`, `ultraWide`)
    - desktop `ThemeExtension` tokens (`DesktopTokens`)
    - reusable desktop primitives (`DesktopFrame`, `DesktopPanel`, `DesktopListRow`, etc.)
  - Added desktop command registry and shortcut handling:
    - `Cmd/Ctrl+K` search focus
    - `Cmd/Ctrl+J` queue toggle
    - `Space`, arrow transport bindings with text-field conflict guard
  - Implemented desktop shell composition path behind feature flag:
    - desktop workspace frame
    - desktop player bar
    - preserved mobile/tablet shell behavior unchanged
  - Implemented desktop adaptations for core surfaces:
    - Home: framed desktop header + panel rhythm + denser rows
    - Search: command-first desktop search layout + desktop list rows + right-click song menu path
    - Library: desktop-framed header/tabs + pane container
    - Settings index: grouped desktop cards + desktop feature toggle control
    - Now Playing: desktop-wide mode activation when desktop UI v1 is enabled
  - Extended desktop context-menu behavior in shared widgets:
    - `showSongContextMenu` supports desktop popup-menu path via right-click anchor.
    - `showAlbumContextMenu` supports desktop popup-menu path via right-click anchor.
    - Home/Library/Genre album cards and desktop song rows now pass secondary-click anchors, preserving mobile long-press behavior.
  - Applied desktop polish pass to core playback/library surfaces:
    - Now Playing desktop-wide mode now keeps transport controls visible and uses compact desktop-aware control sizing.
    - Now Playing wide layout uses stronger two-pane presentation (art panel framing + elevated metadata panel) for desktop readability.
    - Library liked songs section now renders desktop-native rows (cover, metadata rhythm, duration, contextual actions) when desktop UI v1 is enabled.
  - Added focused tests:
    - `test/src/routing/desktop_layout_test.dart`
    - `test/src/routing/desktop_commands_test.dart`
- Evidence:
  - Codegen: `flutter pub run build_runner build --delete-conflicting-outputs`
  - Analyzer (focused paths): `flutter analyze ...`
  - Test passes:
    - `flutter test test/src/routing/desktop_layout_test.dart test/src/routing/desktop_commands_test.dart`
    - `flutter test test/src/database/daos/app_settings_dao_test.dart test/src/features/settings/presentation/playback_settings_screen_test.dart test/src/providers/app_providers_test.dart test/src/routing/app_shell_navigation_test.dart`
    - `flutter test test/src/routing/app_shell_navigation_test.dart test/src/features/auth/presentation/login_screen_test.dart`
    - `flutter test test/src/routing/app_shell_navigation_test.dart test/src/features/library/presentation/library_screen_test.dart`
- Change control:
  - Applied as local working-tree changes only (no commit/push in this step).

## Open work for plan implementation
- Machine readiness
  - Optional for future iOS scope: install Simulator runtimes so `flutter doctor` no longer reports `Unable to get list of installed Simulator runtimes`.
  - Optional for future iOS scope: confirm runtimes via `xcrun simctl list runtimes`.
- Host matrix
  - Prepare native Windows build host and native Linux build host.
  - Validate secret distribution process on at least one additional release operator machine.
- Packaging path
  - Finalize Windows installer format and signed distribution path.
  - Finalize Linux `.deb` + portable bundle artifact pipeline.
  - Finalize macOS notarization and distribution verification workflow.
- QA and release gate
  - Add/verify targeted tests for platform-specific update/install paths.

## Change-control note
If commit scope needs to include platform scaffolding files later, that transition should happen in a dedicated commit set after this `0.8.0` app-first stabilization point.
