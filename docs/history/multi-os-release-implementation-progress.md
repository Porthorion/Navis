# Multi-OS Release Implementation Progress

Last updated: 2026-03-27

Historical execution log. Use [current release procedures](../README.md#start-by-task)
for supported packaging and release workflows.

This document is the detailed execution log for preparing Navis as a native app release across Android, macOS, Windows, and Linux.

## Scope and tracking rules
- This file is the detailed tracker (task-level evidence, environment readiness, command-level validation).
- `docs/project/progress.md` remains the high-level tracker and links here for Phase 26 execution details.
- This file now also carries the detailed execution log for Phase 31 (Adaptive Convergence Program / ACP).
- Entries are append-only unless corrected by a later dated note.

## Current baseline
- Active branch: `dev`
- Target app version: `0.9.0+900`
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
  - Linked `docs/project/progress.md` Phase 26 to this detailed tracker.

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
  - Documented script usage in `docs/development/development-workflow.md`.
- Evidence:
  - `./tool/multi_os_host_preflight.sh --help`
  - `./tool/multi_os_host_preflight.sh`
  - `docs/development/development-workflow.md` section `Multi-OS Host Preflight`
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
  - `docs/development/ci-cd.md`
  - `docs/development/dev-testing-builds.md`
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
  - `docs/development/ci-cd.md`, `docs/development/dev-testing-builds.md`, `docs/development/development-workflow.md`
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
    - `docs/platforms/macos-testing-playbook.md`
  - Linked testing flow into development docs and README docs index.
- Evidence:
  - `tool/release_gate_core.sh --help`
  - `bash -n tool/release_gate_core.sh`
  - `docs/platforms/macos-testing-playbook.md`
  - `docs/development/development-workflow.md`
  - `Makefile`
  - `README.md`

### N. Release secret-handling baseline
- Status: completed
- Actions:
  - Added `docs/release/release-secrets.md` to define credential classes, storage policy, and Apple notary keychain flow.
  - Linked the secrets doc from CI/release documentation.
- Evidence:
  - `docs/release/release-secrets.md`
  - `docs/development/ci-cd.md`

### O. Unified tablet/desktop adaptive UX implementation
- Status: in progress
- Actions:
  - Added desktop foundation layer:
    - `DesktopLayoutClass` resolver (`compact`, `standard`, `ultraWide`)
    - desktop `ThemeExtension` tokens (`DesktopTokens`)
    - reusable desktop primitives (`DesktopFrame`, `DesktopPanel`, `DesktopListRow`, etc.)
  - Added desktop command registry and shortcut handling:
    - `Cmd/Ctrl+K` search focus
    - `Cmd/Ctrl+J` queue toggle
    - `Space`, arrow transport bindings with text-field conflict guard
  - Implemented desktop shell composition as default desktop runtime path:
    - desktop workspace frame
    - desktop player bar
    - preserved mobile/tablet shell behavior unchanged
  - Implemented desktop adaptations for core surfaces:
    - Home: framed desktop header + panel rhythm + denser rows
    - Search: command-first desktop search layout + desktop list rows + right-click song menu path
    - Library: desktop-framed header/tabs + pane container
    - Settings index: grouped desktop cards aligned with tablet behavior
    - Now Playing: desktop-wide mode activation by runtime platform
  - Extended desktop context-menu behavior in shared widgets:
    - `showSongContextMenu` supports desktop popup-menu path via right-click anchor.
    - `showAlbumContextMenu` supports desktop popup-menu path via right-click anchor.
    - Home/Library/Genre album cards and desktop song rows now pass secondary-click anchors, preserving mobile long-press behavior. (Correction 2026-09-30: the Genre surface was later removed by product decision.)
  - Applied desktop polish pass to core playback/library surfaces:
    - Now Playing desktop-wide mode now keeps transport controls visible and uses compact desktop-aware control sizing.
    - Now Playing wide layout uses stronger two-pane presentation (art panel framing + elevated metadata panel) for desktop readability.
    - Library liked songs section renders desktop-native rows (cover, metadata rhythm, duration, contextual actions) on desktop runtime.
  - Added focused tests:
    - `test/src/routing/desktop_layout_test.dart`
    - `test/src/routing/desktop_commands_test.dart`
- Evidence:
  - Codegen: `dart run build_runner build`
  - Analyzer (focused paths): `flutter analyze ...`

### P. ACP M4-04 Desktop Mini Player implementation
- Status: complete on Linux; Windows/macOS native validation pending
- Actions:
  - Replaced the experimental Focus Player preset with explicit Desktop View and same-window Mini Player modes.
  - Added `window_state.json` v3 with last-valid Desktop geometry, retained Mini screen position, maximized Desktop restoration, and optional Mini Player always-on-top state; Mini always enters at canonical 720×405 so expanded prompt bounds cannot loop into the next mode switch, and the legacy database flag remains unused for schema compatibility.
  - Added 400 ms bidirectional resize-transition gates, display work-area clamping through `screen_retriever`, and deterministic authenticated diagnostics controls.
  - Added the dedicated Mini Player surface with volume beneath its transport/actions, persistent Desktop bottom player empty state, and real Desktop Window settings controls.
  - Added focused controller/settings/shell/layout/API tests and six component goldens.
- Evidence:
  - `lib/src/routing/desktop_window_controller.dart`
  - `lib/src/routing/app_shell_desktop_mini_player.dart`
  - `lib/src/features/settings/presentation/desktop_window_settings_screen.dart`
  - `lib/src/routing/app_shell.dart`
  - `test/src/routing/desktop_window_controller_test.dart`
  - `test/src/routing/app_shell_navigation_test.dart`
  - `test/src/features/settings/presentation/desktop_window_settings_screen_test.dart`
  - `tool/desktop_layout_diagnostics.sh`
- Verification note:
  - `./tool/check.sh` passed on 2026-08-09 with 993 tests and one skip.
  - Linux isolated-clone diagnostics at `build/presentation-diagnostics/20260808T221412Z-clone/` passed initial and clean-restart Desktop View at 1306×853, 1159×678, 887×900, and 800×600, 799×599 and short 799×444 Desktop entry gates, the Mini exit gate, canonical 720×405 and minimum 560×360 Mini Player, Keep Mini restoration, screenshot integrity, and log review. All 22 app-owned PNGs were opened and inspected.
  - Windows and macOS resizing, snapping, DPI/display-topology handling, and always-on-top remain unverified.
- Change control:
  - Applied as local working-tree changes only (no commit/push in this step).

### P. ACP baseline and tracker bootstrap (2026-03-23)
- Status: completed (M0 scaffold)
- Context:
  - Execution has moved to branch `main` for ACP documentation and convergence prep.
  - ACP will continue using existing documentation only:
    - `docs/project/development-plan.md` (phase/spec authority)
    - `docs/project/progress.md` (high-level status + dated evidence)
    - this file (detailed execution/blocker log)
- Actions:
  - Added `Phase 31: Adaptive Convergence Program` to `docs/project/development-plan.md`.
  - Added ACP milestone/task checklist (`ACP-M0` through `ACP-M6`) to `docs/project/progress.md`.
  - Captured adaptive baseline tests/analyzer before refactor work.
- Baseline evidence:
  - `flutter test test/src/routing/desktop_layout_test.dart test/src/routing/desktop_commands_test.dart test/src/routing/app_shell_navigation_test.dart`
    - Result: `desktop_layout_test.dart` and `desktop_commands_test.dart` pass; `app_shell_navigation_test.dart` fails.
    - Failure profile: narrow-width desktop runtime currently forces desktop shell path and triggers `RenderFlex overflow` in desktop player bar; multiple expectation mismatches in shell navigation assertions.
  - `flutter analyze lib/src/routing lib/src/features/settings/presentation/settings_screen.dart lib/src/features/home/presentation/home_screen.dart lib/src/features/search/presentation/search_screen.dart lib/src/features/library/presentation/library_screen.dart`
    - Result: no compile errors; info-level lint debt reported on adaptive-heavy paths.
- ACP blocker protocol (effective immediately):
  - Every blocked ACP task must append:
    - Task ID (`ACP-Mx-yy`)
    - exact command or runtime path that failed
    - exact error signature
    - next attempted action
    - unblock condition

### Q. ACP M1+M2 shell stabilization slice (2026-03-25)
- Status: completed for M2 (`ACP-M2-01` through `ACP-M2-04`), partial for M1 (`ACP-M1-01`/`ACP-M1-02`)
- Actions:
  - Added shared adaptive contract in routing:
    - `AdaptiveContext` + `resolveAdaptiveContext` in `lib/src/routing/desktop_layout.dart`
    - keeps current breakpoint behavior while providing one canonical shell decision boundary.
  - Refactored shell to window-size-first composition in `lib/src/routing/app_shell.dart`:
    - full desktop workspace now gated to wide desktop widths
    - non-wide widths use shared bottom-nav/rail/compact-wide modes from adaptive context
    - desktop shortcut layer now remains active on desktop runtimes at all window widths
    - prevented desktop `NavigationBar` leak while full desktop shell is active.
  - Hardened constrained playback chrome:
    - `_DesktopPlayerBar` now uses responsive control density with compact overflow actions
    - `_RailMiniPlayer` control row now includes compact fallback to avoid narrow-width overflows.
  - Extended ACP-focused test coverage:
    - `test/src/routing/desktop_layout_test.dart` (adaptive context behavior)
    - `test/src/routing/desktop_commands_test.dart` (action-handler text-input guard)
    - `test/src/routing/app_shell_navigation_test.dart` (width-first shell expectations + compact desktop shortcuts).
- Evidence:
  - `flutter test test/src/routing/desktop_layout_test.dart test/src/routing/desktop_commands_test.dart test/src/routing/app_shell_navigation_test.dart`
    - Result: pass (27 tests).
  - `flutter analyze lib/src/routing lib/src/features/settings/presentation/settings_screen.dart lib/src/features/home/presentation/home_screen.dart lib/src/features/search/presentation/search_screen.dart lib/src/features/library/presentation/library_screen.dart`
    - Result: no compile errors; existing info-level lint debt remains (57 infos, no new blockers).

### R. ACP M3 Wave 1 convergence (2026-03-25)
- Status: completed for `ACP-M3-01`, `ACP-M3-02`, and `ACP-M3-04`; `ACP-M1-03` advanced to partial.
- Actions:
  - Added adaptive context propagation and fallback resolver in routing:
    - `AdaptiveContextScope` and `resolveAdaptiveContextFor` in `lib/src/routing/desktop_layout.dart`.
    - `AppShell` now provides scoped adaptive context at the shell boundary in `lib/src/routing/app_shell.dart`.
  - Migrated screen adaptive branching from runtime checks to shared adaptive contract:
    - Home uses shared adaptive flags for desktop-wide gating and section/carousel/shimmer density paths.
    - Search uses shared adaptive flags for desktop/tablet/phone selection and recent-search layout padding.
    - Settings uses shared adaptive flags for width-parity mode selection and desktop-wide framing.
  - Added reusable adaptive widget-test viewport utility:
    - `test/helpers/adaptive_test_harness.dart`.
  - Extended adaptive width-matrix widget coverage:
    - Home: `test/src/features/home/presentation/home_screen_test.dart`.
    - Search: `test/src/features/search/search_screen_adaptive_test.dart`.
    - Settings: `test/src/features/settings/presentation/settings_screen_test.dart`.
    - Routing adaptive resolver fallback/scope behavior: `test/src/routing/desktop_layout_test.dart`.
- Evidence:
  - `flutter test test/src/routing/desktop_layout_test.dart test/src/routing/desktop_commands_test.dart test/src/routing/app_shell_navigation_test.dart test/src/features/home/presentation/home_screen_test.dart test/src/features/settings/presentation/settings_screen_test.dart test/src/features/search/search_screen_adaptive_test.dart test/src/features/search/search_screen_focus_test.dart`
    - Result: pass (49 tests).
  - `flutter analyze lib/src/routing lib/src/features/home/presentation/home_screen.dart lib/src/features/search/presentation/search_screen.dart lib/src/features/settings/presentation/settings_screen.dart test/src/features/home/presentation/home_screen_test.dart test/src/features/settings/presentation/settings_screen_test.dart test/src/features/search/search_screen_adaptive_test.dart test/src/routing/desktop_layout_test.dart`
    - Result: no compile errors; existing info-level lint debt remains (45 infos, no new blockers).

### S. ACP M3 Wave 2 convergence (2026-03-25)
- Status: completed for `ACP-M3-03` (Library) and `ACP-M3-05` (Now Playing); `ACP-M1-01` and `ACP-M1-03` completed.
- Actions:
  - Migrated Library to shared adaptive context consumption:
    - replaced runtime+viewport branching with `resolveAdaptiveContextFor(context)` flags in `lib/src/features/library/presentation/library_screen.dart`
    - desktop-native list-row treatment in liked songs now activates only for `desktopWide` (`useDesktopShell`) instead of all desktop runtimes.
  - Migrated Now Playing wide-mode selection to shared adaptive context:
    - `effectiveWideMode` now uses `resolveAdaptiveContextFor(context).useDesktopShell` in `lib/src/features/player/presentation/now_playing_screen.dart`.
  - Extended adaptive widget coverage for Wave 2:
    - updated Library adaptive parity expectation in `test/src/features/library/presentation/library_screen_test.dart` (compact desktop width uses non-desktop list rows, desktop-wide width uses desktop rows)
    - added `test/src/features/player/presentation/now_playing_screen_adaptive_test.dart` to verify narrow desktop widths keep compact presentation and desktop-wide widths switch to wide mode.
- Evidence:
  - `flutter test test/src/routing/desktop_layout_test.dart test/src/routing/desktop_commands_test.dart test/src/routing/app_shell_navigation_test.dart test/src/features/home/presentation/home_screen_test.dart test/src/features/search/search_screen_adaptive_test.dart test/src/features/settings/presentation/settings_screen_test.dart test/src/features/library/presentation/library_screen_test.dart test/src/features/player/presentation/now_playing_screen_transition_test.dart test/src/features/player/presentation/now_playing_screen_adaptive_test.dart`
    - Result: pass (70 tests).
  - `flutter analyze lib/src/routing/desktop_layout.dart lib/src/routing/app_shell.dart lib/src/features/home/presentation/home_screen.dart lib/src/features/search/presentation/search_screen.dart lib/src/features/settings/presentation/settings_screen.dart lib/src/features/library/presentation/library_screen.dart lib/src/features/player/presentation/now_playing_screen.dart test/src/features/library/presentation/library_screen_test.dart test/src/features/player/presentation/now_playing_screen_adaptive_test.dart test/src/features/search/search_screen_adaptive_test.dart`
    - Result: no compile errors; analyzer reports existing info-level lint debt only (81 infos, no new blockers).

### T. ACP usability hardening follow-up (2026-03-25)
- Status: completed (tablet/desktop now-playing interaction + desktop player bar density fix pass)
- Actions:
  - Fixed tablet split-layout lyrics action no-op in `NowPlayingScreen`:
    - split action row now opens fullscreen lyrics route instead of using a no-op callback in `lib/src/features/player/presentation/now_playing_screen.dart`.
  - Added explicit now-playing exit affordance:
    - embedded now-playing now shows a visible collapse/close button (`nowPlayingCloseButton`) when collapse is available.
    - applies across tablet/desktop embedded paths (including desktop-wide full player).
  - Hardened desktop bottom player bar density around 1200px windows:
    - updated control-collapse thresholds in `_DesktopPlayerBar` so compact controls and overflow menu activate earlier.
    - reduces crowding/overlap risk when desktop shell rail consumes horizontal space.
  - Added adaptive tests for the follow-up:
    - `test/src/features/player/presentation/now_playing_screen_adaptive_test.dart` now verifies close button visibility at compact and desktop-wide widths.
    - same suite now verifies split-layout lyrics action opens fullscreen lyrics route.
- Evidence:
  - `flutter test test/src/features/player/presentation/now_playing_screen_adaptive_test.dart test/src/features/player/presentation/now_playing_screen_transition_test.dart test/src/routing/app_shell_navigation_test.dart`
    - Result: pass (19 tests).
  - `flutter analyze lib/src/features/player/presentation/now_playing_screen.dart lib/src/routing/app_shell.dart test/src/features/player/presentation/now_playing_screen_adaptive_test.dart`
    - Result: no compile errors; existing info-level lint debt only (58 infos, no new blockers).

### U. ACP desktop-wide You Might Like redesign (2026-03-26)
- Status: completed (`ACP-M3-06`)
- Actions:
  - Replaced desktop-wide random albums hero carousel with a manual pager in `lib/src/features/home/presentation/home_screen.dart`:
    - desktop-wide now uses `_DesktopRandomAlbumsPager` with explicit left/right controls and mini-cover strip selection.
    - compact desktop, tablet, and phone still use `_RandomAlbumsHeroCarousel` unchanged.
  - Added new desktop-only composition widgets:
    - `_DesktopRandomAlbumPage`, `_DesktopRandomAlbumVisual`, `_DesktopRandomAlbumSongList`, `_DesktopRandomAlbumSongRow`, `_DesktopRandomMiniCoverStrip`.
  - Implemented right-side song list behavior per slice policy:
    - primary source `albumProvider(album.id)` with `songByIdProvider(album.id)` fallback.
    - stable ordering by disc number, track, then title/id.
    - capped visible rows with `_kDesktopRandomSongsPerAlbum = 5`.
    - row interactions wired for queue replace, heart toggle, and anchored menu actions (including right-click).
  - Hardened edge behavior:
    - added deterministic loading-vs-empty handling when album/fallback providers resolve to null.
    - fixed anchor-resolution logic for three-dot menu to avoid analyzer warnings.
  - Extended home widget coverage in `test/src/features/home/presentation/home_screen_test.dart`:
    - width gating (desktop-wide pager vs non-desktop hero carousel)
    - manual paging and no auto-advance expectations
    - song cap behavior
    - queue/heart/menu interaction checks
    - desktop overflow guard at `1200/1366/1600`.
- Evidence:
  - `flutter test test/src/features/home/presentation/home_screen_test.dart test/src/features/home/presentation/home_random_showcase_provider_test.dart`
    - Result: pass (25 tests); no failures.
  - `flutter analyze lib/src/features/home/presentation/home_screen.dart test/src/features/home/presentation/home_screen_test.dart`
    - Result: no compile errors and no new warnings; existing info-level lint debt remains in `home_screen.dart` (`discarded_futures` infos).

### V. ACP desktop-wide You Might Like refinement pass (2026-03-26)
- Status: completed (visual/layout polish + interaction stability)
- Actions:
  - Refined desktop page composition in `lib/src/features/home/presentation/home_screen.dart`:
    - tightened art/list spacing and aligned the two panes as a single visual block.
    - switched album metadata presentation to in-cover overlay treatment for desktop-wide mode.
    - kept left cover and right track panel height-locked so both surfaces stay aligned as viewport changes.
  - Added adaptive capacity logic for the right-side track list:
    - replaced static 5-row-only behavior with available-height-based row capacity.
    - preserves a minimum baseline while allowing additional rows when the desktop viewport has room.
    - updated tests to assert expanded row rendering on taller desktop matrices.
  - Stabilized random recommendations behavior on star toggles:
    - `homeRandomShowcaseProvider` now snapshots liked songs via non-reactive read to avoid reshuffling "You Might Like" while users like/unlike tracks.
    - section still refreshes through explicit invalidation/sync paths.
- Evidence:
  - `flutter test test/src/features/home/presentation/home_screen_test.dart test/src/features/home/presentation/home_random_showcase_provider_test.dart`
    - Result: pass.
  - `flutter analyze lib/src/features/home/presentation/home_providers.dart lib/src/features/home/presentation/home_screen.dart test/src/features/home/presentation/home_screen_test.dart test/src/features/home/presentation/home_random_showcase_provider_test.dart`
    - Result: no compile errors; info-level lint debt only.

### W. ACP M4 Wave A input + focus parity hardening (2026-03-26)
- Status: completed for `ACP-M4-01`, `ACP-M4-02`, `ACP-M4-03`; `ACP-M4-04` remains deferred by design.
- Actions:
  - Added routing-layer adaptive input policy boundary:
    - introduced `AdaptiveInputPolicy`, `AdaptiveInputPolicyScope`, `resolveAdaptiveInputPolicy`, and `resolveAdaptiveInputPolicyFor` in `lib/src/routing/desktop_layout.dart`.
    - policy is derived from `AdaptiveContext` and consumed from shell scope with deterministic fallback for standalone/tests.
  - Hardened shell focus/keyboard model in `lib/src/routing/app_shell.dart`:
    - shell now provides both adaptive context and adaptive input policy scopes.
    - deterministic traversal/focus regions are applied for desktop/tablet interactive layout.
    - queue overlay dismissal now restores focus to invoker when available, else returns focus to shell root.
    - `Esc` precedence is stack-aware: queue/overlay dismiss first, then player collapse.
  - Standardized command/context menu behavior:
    - `buildDesktopShortcutMap` now supports explicit escape inclusion toggling in `lib/src/routing/desktop_commands.dart`.
    - desktop command action handler ignores non-current routes to avoid leaking commands under modal routes.
    - desktop context menus request keyboard focus on open in `lib/src/common_widgets/desktop/desktop_context_menu.dart`.
    - queue overlay binds `Esc` to dismiss through `Shortcuts`/`Actions` for deterministic keyboard close.
  - Extended adaptive input regression coverage:
    - `test/src/routing/desktop_layout_test.dart`: adaptive input policy resolver + scoped fallback checks.
    - `test/src/routing/desktop_commands_test.dart`: text-input guard, escape-map control, route-current guard.
    - `test/src/routing/app_shell_navigation_test.dart`: escape queue-first precedence, queue focus restoration, width matrix checks at `700/840/1200/1366`.
- Evidence:
  - `flutter test test/src/routing/desktop_commands_test.dart test/src/routing/app_shell_navigation_test.dart test/src/routing/desktop_layout_test.dart`
    - Result: pass (39 tests).
  - `flutter test test/src/features/home/presentation/home_screen_test.dart test/src/features/search/search_screen_adaptive_test.dart test/src/features/player/presentation/now_playing_screen_adaptive_test.dart`
    - Result: pass (22 tests).
  - `flutter analyze lib/src/routing lib/src/features/home/presentation/home_screen.dart lib/src/features/search/presentation/search_screen.dart lib/src/features/player/presentation/now_playing_screen.dart`
    - Result: no compile errors; existing info-level lint debt remains and existing non-M4 warning in `now_playing_screen.dart` (`unused_local_variable`) persists.

### X. ACP desktop input and library-filter follow-up (2026-03-27)
- Status: completed
- Actions:
  - Extended the desktop quick-search overlay with explicit result-type filter selection so search intent can be applied before routing into Search.
  - Resolved input-precedence conflicts between the desktop quick-search overlay and the library type-to-filter system.
  - Suppressed transport shortcuts while the library type-to-filter overlay is active so space/arrow input does not leak into playback controls mid-filter.
  - Fixed phone-layout bottom-player reveal behavior by switching from an implicit first-build animation assumption to an explicit slide transition.
  - Completed type-filter parity in Library so albums search across the full collection, artist grid results match the alphabet rail, and radio stations participate in filtering.
  - Re-checked the desktop shortcut implementation for cross-system behavior: primary modifier remains `Cmd` on macOS and `Ctrl` on Windows/Linux, with alternate labels preserved for `Option`/`Alt`.
- Evidence:
  - `lib/src/routing/app_shell.dart`
  - `lib/src/routing/desktop_commands.dart`
  - `lib/src/features/library/presentation/library_screen.dart`
  - `lib/src/features/library/presentation/radio_screen.dart`
  - `test/src/routing/desktop_commands_test.dart`
  - `test/src/features/library/presentation/library_screen_test.dart`

### Y. 0.9.0 documentation and release-prep pass (2026-03-27)
- Status: completed
- Actions:
  - Bumped app metadata to `0.9.0+900` in `pubspec.yaml`.
  - Updated top-level docs to capture the current desktop-input status, recent library filtering fixes, and release readiness notes.
  - Recorded the current dependency backlog from `flutter pub outdated` so package-upgrade work is visible in the plan/progress docs.
  - Clarified system media integration status by documenting that Android, Linux, and Windows paths are active while macOS native media-center integration and iOS parity audit remain pending.
- Evidence:
  - `pubspec.yaml`
  - `README.md`
  - `docs/project/progress.md`
  - `docs/project/development-plan.md`
  - `flutter pub outdated`

### ACP Daily Log Template
- Date:
- Active task IDs:
- Status transitions:
- Commands run:
- Evidence produced:
- Blockers encountered:
- Next actions:

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
