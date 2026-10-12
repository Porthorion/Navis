# Navis dependency upgrade plan

Audit date: 2026-09-27. Status: **implemented and merged into dev on 2026-10-01** (see [Port onto dev](#port-onto-dev-2026-10-01)); Apple, physical Android arm64 and full head-unit projection remain unverified.

This plan covers root Dart dependencies, their resolved transitive graph,
owned packages, the Windows Rust workspace, Android libraries/tooling, and
Apple deployment configuration. Versions are a dated snapshot and must be
resolved again when implementation starts. “Resolvable” means compatible
constraints, not tested runtime compatibility.

## Recommendation

Upgrade in independently reversible compatibility batches. Start with Flutter
hotfixes and Rust advisory fixes; follow with generators/database, state and
plugins, file selection, then the coordinated UI/router migration. Keep Android
toolchain and Windows WinRT migration separately reviewable. Do not run a blanket
major upgrade and treat a successful dependency resolution as completion.

Preserve the existing visual identity, storage format, credential keys, router
lifetime, audio backend patches, and download → cache → direct-stream priority.
There is no reason to change database schema 80 solely for a package upgrade.

## Evidence and scope

- Installed baseline: Flutter 3.47.1, Dart 3.13.1. Manifest floor:
  Flutter >=3.47.1, Dart ^3.13.0.
- Root and both owned Windows Dart packages were checked with `pub outdated`.
- Root major-version dry run resolves successfully and would change 84
  dependencies. It changes five direct constraints, listed below; it does not
  demonstrate builds, tests, native compatibility, or UI correctness.
- [Complete locked Dart/Cargo inventory](../audits/dependency-upgrades-2026-09-27/inventory.md),
  [root resolver report](../audits/dependency-upgrades-2026-09-27/root-outdated.json),
  [SMTC report](../audits/dependency-upgrades-2026-09-27/smtc-outdated.json),
  [CargoKit report](../audits/dependency-upgrades-2026-09-27/cargokit-outdated.json),
  [major dry run](../audits/dependency-upgrades-2026-09-27/root-major-upgrade-dry-run.txt),
  and [advisory query/results](../audits/dependency-upgrades-2026-09-27/advisories.json)
  preserve the evidence, including transitive dependencies.
- OSV queried 399 unique locked Pub/crates.io package-version pairs across the
  local lockfiles. It returned Rust matches below and no Pub matches. This is
  an advisory database snapshot, not proof of absence of vulnerabilities or
  reachability. The resolved Android sideload-release runtime graph was also
  queried: 89 Maven coordinates, no matches. See the
  [native graph](../audits/dependency-upgrades-2026-09-27/android-runtime-dependencies.txt)
  and [Maven advisory evidence](../audits/dependency-upgrades-2026-09-27/android-advisories.json).
  Bundled binaries and system library advisory checks remain a release gate.
- Native Android declaration versions and stable releases were checked against
  Google's Maven metadata. Plugin-owned native versions must be inspected in
  the final resolved Gradle graph rather than overridden independently.
- Existing unrelated working-tree changes must be preserved. Implementation
  should use a clean isolated checkout and establish a passing baseline first.

## Root packages to upgrade

| Dependency | Locked | Target | Handling |
| --- | --- | --- | --- |
| dio | 5.11.0 | 5.11.1 | API/retry/auth interceptor tests |
| logger | 2.7.0 | 2.8.0 | Verify output and credential redaction |
| flutter_riverpod, riverpod | 3.4.2 | 3.4.3 | Upgrade together; provider lifetime/auth tests |
| flutter_local_notifications | 22.3.0 | 22.3.1 | Channels, permission, background notification tests |
| flutter_secure_storage | 11.0.0 | 11.2.0 | Existing credential reads across upgrade and restart |
| flutter_cache_manager | 3.4.2 | 3.4.5 | Changed persistence/error behavior; see below |
| octo_image | 2.1.0 | 2.1.1 | Lazy art, placeholders, error rendering |
| drift | 2.34.3 | 2.35.0 | Upgrade with generator; schema/migration tests |
| drift_dev | 2.34.5 | 2.35.0 | Regenerate tracked sources |
| sqlite3 | 3.5.2 | 3.6.0 | Native asset builds and offline Windows fix |
| build_runner | 2.16.0 | 2.16.1 | Regenerate and inspect graph/output |
| freezed | 4.0.0 | 4.0.2 | Serialization and immutable-model tests |
| file_picker | 12.0.0 | 13.1.0 | Major; upgrade federated implementations together |
| android_file_picker | 1.0.1 | 2.0.0 | Major; paired with file_picker |
| go_router | 17.5.0 | 18.0.1 | Major; coordinated Material/Cupertino migration |
| cached_network_image | 3.4.1 | 4.0.2 | Major; same coordinated UI migration |
| very_good_analysis | 10.3.0 | 11.0.0 | Major; targeted lint fixes, no blanket suppression |

Use compatible transitive updates produced by each batch's solver. The complete
current/upgradable/resolvable/latest comparison is in the resolver reports.
Generator changes include analyzer 14.4.0, build 4.0.11, source_gen 4.3.0,
dart_style 3.1.13, and package_config 3.0.0. Review their combined generated diff.

### Root packages to retain

The current solver reports no newer resolvable direct version for audio_service
0.18.19, audio_session 0.2.4, colornames 0.2.0, connectivity_plus 7.3.1,
crypto 3.0.7, drift_flutter 0.3.1, flutter_markdown_plus 1.0.12, flutter_svg
2.3.0, freezed_annotation 3.1.0, json_annotation 4.12.0, intl 0.20.3,
just_audio 0.10.6, meta 1.19.0, package_info_plus 10.2.1, path_provider 2.1.6,
rxdart 0.28.0, scrollable_positioned_list 0.3.8, url_launcher 6.3.2, uuid
4.6.0, visibility_detector 0.4.0+2, media_kit_libs_windows_audio 1.0.9,
media_kit_libs_linux 1.2.1, media_kit_libs_macos_audio 1.1.4, window_manager
0.5.2, screen_retriever 0.2.2, file 7.0.1, json_serializable 6.14.1,
mocktail 1.0.5, url_launcher_platform_interface 2.3.2, and flutter_launcher_icons
0.14.4. Flutter/flutter_test/flutter_localizations remain SDK dependencies.

Keep owned just_audio_media_kit 2.1.0 and navis_windows_smtc 1.1.0 as local
packages. Preserve the force-seekable media-kit patch and SMTC ownership.
Update their dependencies/tooling where required, not their public APIs merely
because an upstream release exists. Keep indexed scrolling/visibility packages
unless a demonstrated incompatibility requires replacement.

### Explicit holds

| Package | Hold | Reason |
| --- | --- | --- |
| dbus | 0.7.15 | connectivity_plus → nm 0.5.0 and Linux notifications use dbus 0.7 |
| nm | 0.5.0 | Current connectivity_plus constraint excludes 0.6 |
| file_picker_linux | 2.0.0 after picker migration | 2.0.1 requires dbus 0.8 |
| cli_util | 0.4.2 | drift_dev and launcher-icons constraints exclude latest 0.6 |
| cross_file | compatible 0.3.5+5 | Picker ecosystem excludes 0.4 |
| material_color_utilities, test_api | SDK-selected | Do not override Flutter pins; reassess after SDK update |

No dependency_overrides. Revisit these holds when all dependants support the
new versions. Keep prerelease Rust/Flutter bridge releases out of this upgrade.

## Implementation-specific migrations

### Material/Cupertino, router, and artwork

[go_router 18](https://pub.dev/packages/go_router/changelog) and
[cached_network_image 4](https://pub.dev/packages/cached_network_image/changelog)
use separate material_ui/cupertino_ui packages. Navis currently imports
flutter/material.dart throughout its UI and tests.

1. Add explicit material_ui ^1.4.0 and cupertino_ui ^1.1.1 dependencies.
   Migrate UI imports, theme types, NavisApp's MaterialApp.router, dialogs,
   splashFactory types, and widget test harnesses consistently. Keep core
   Flutter widgets/services/gestures imports where appropriate.
2. Preserve colors, typography, density, OLED appearance, adaptive layouts,
   desktop shortcuts/input boundary, bootstrap overlay, and presentation host.
3. Create a handwritten shared delegate list combining AppLocalizations.delegate
   with modern Material/Cupertino/Widgets delegates. The generated
   lib/l10n/app_localizations.dart currently exports legacy delegates; do not
   hand-edit it. Update all application/test delegate consumers.
4. Legacy flutter_markdown_plus still expects legacy ThemeData. The actual
   conflict is MarkdownStyleSheet.fromTheme(theme) in update_dialog.dart.
   Use the upstream temporary MaterialUiCompatibilityBridge around legacy
   descendants and obtain legacy Theme.of(context) below it with a prefixed
   import. Retain required flutter_localizations compatibility. Document this
   deprecated bridge's scope and removal trigger; do not suppress all deprecations.
5. Upgrade go_router only with the migrated app harness. Its new material page
   helper identifies the modern MaterialApp by exact ancestor type; keeping a
   legacy app can silently select different page transitions. Preserve
   appRouterProvider's stable lifetime, SessionRoutePhase listeners and narrow
   refreshListenable contract, redirects, back/forward history, and Hero behavior.
6. Preserve CoverArtImage's custom cache/provider keys, revision invalidation,
   resize bounds, visibility prioritization, Hero tags, and dynamic accent.

Acceptance: existing router/shell/desktop command tests, reduced-motion and UI
goldens, cover-art/cache/decode/Hero tests, multiple locales including RTL,
Library/Lyrics indexed scrolling, phone/desktop viewports, and real app-owned
screenshots in light/dark/OLED modes. Never blindly update goldens to pass.

### File selection and Android SAF

[file_picker 13](https://pub.dev/packages/file_picker/changelog) removes old
arguments and makes PlatformFile.length() nullable. The inspected Navis caller,
downloads_screen.dart::_pickCustomDownloadFolder, already uses androidOptions
and AndroidSAFOptions with lifetime read/write and persistGrant. No obsolete
argument or length call was found there; avoid unnecessary caller rewrites.

Upgrade file_picker/android_file_picker together and inspect all federated
versions. Verify cancel, inaccessible folder, persisted SAF grant after restart,
folder replacement/revocation, download/import, and user-owned directory safety.
Use android_saf_storage_test and permanent-download/import tests, plus an
actual Android document-provider interaction. Desktop native picker smoke is
required too. Preserve iOS UIScene configuration when checking Darwin changes.

### Cache, credentials, and state

[Cache manager 3.4.3–3.4.5](https://pub.dev/packages/flutter_cache_manager/changelog)
changes metadata persistence timing and propagates repository-write failures.
Exercise cover-art persistence, immediate restart, corrupt decode and failed
metadata writes. Confirm artwork failure remains nonfatal to audio downloads
and that scheduling slots release on every error. Preserve four active art
connections and bounded scheduling, cache keys and source priority.

FlutterSecureCredentialStore currently uses default FlutterSecureStorage.
Keep existing navis.auth credential keys and platform options; do not add
biometric requirements. Verify reading credentials written by the previous
build, successful authentication, sign-out removal, and clean restart. Keep
Riverpod DI, AsyncValue handling, disposal and stale-account fences intact.

### Generators, Drift, and SQLite

Upgrade drift/drift_dev together, then sqlite3/build_runner/freezed and
compatible transitive tools. Run make gen; inspect every generated source and
model serialization change. Keep schema 80 unless an actual schema change is
needed; any such change requires a stepwise migration and migration test.

tool/remote_build_windows.sh patches an old sqlite3 hook path
lib/src/hook/description.dart; the installed hook is under hook/compile.
It also searches older cached DLLs as fallback. Replace cache-source patching
with supported hook configuration for an exact-version bundled DLL, verify its
checksum against trusted upstream metadata, and fail clearly if unavailable.
Validate the chosen source configuration with sqlite3 3.6 itself. Test both
fresh native assets and offline Windows packaging; never silently reuse an
unidentified older SQLite binary.

### Windows Rust and bindings

The workspace lock has anyhow 1.0.82 and tokio 1.39.2. A stale nested lock has
anyhow 1.0.75, tokio 1.34.0, and FRB 2.1.0, while the workspace uses FRB 2.13.0.
Both Cargo locks are currently Git-ignored.

- Update compatible Rust dependencies first: anyhow >=1.0.103 fixes
  [RUSTSEC-2026-0190](https://rustsec.org/advisories/RUSTSEC-2026-0190.html);
  tokio >=1.44.2 fixes this branch of
  [RUSTSEC-2025-0023](https://rustsec.org/advisories/RUSTSEC-2025-0023.html).
  Update the backtrace/compression chain away from unmaintained adler
  ([RUSTSEC-2025-0056](https://rustsec.org/advisories/RUSTSEC-2025-0056.html)).
  Re-run advisories on the final graph; do not force arbitrary transitive majors.
- Track one authoritative workspace Cargo.lock; remove the stale nested lock
  from the build workflow. Require --locked in the owned CargoKit build path
  and verify offline bundle/build tooling includes the lock.
- Treat windows 0.58 → 0.62.2 as a separate major migration. Inspect the
  [Windows release notes](https://github.com/microsoft/windows-rs/releases/tag/0.62.0)
  and actual generated signatures: EventRegistrationToken subscriptions become
  i64 tokens; callback reference types/Send bounds change. Adapt
  rust/src/internal/smtc_internal.rs, including all four subscriptions and
  revoke paths, null arguments, ordered publication and teardown.
- Preserve manual SMTC ownership with CommandManager disabled and http(s)-only
  artwork URI handling. Do not change WindowsSmtcSession's public contract.
- Keep FRB runtime/codegen aligned at stable 2.13.0; align manifest SDK floors
  to actual requirements. Upgrade ffigen 19.1 → 22.0 and regenerate with the
  existing YAML configuration; verify FRB/codegen compatibility empirically.

CargoKit has intentionally exact pins. Upgrade them together in its own
manifest/lock: args 2.7.0, collection 1.19.1, convert 3.1.2, crypto 3.0.7,
ed25519_edwards 0.3.2, github 9.26.0, http 1.6.0, logging 1.3.0, path 1.9.1,
source_span 1.10.2, toml 0.18.0, version 3.0.2, yaml 3.1.4; retain hex 0.2.0.
Upgrade lints to 6.1 and test to the nested solver's compatible version.
Verify CrateInfo's TomlDocument.parse(...).toMap() against the new TOML package,
plus cargo/options/rustup/builder tests. The SMTC package's test version is
currently constrained by Flutter; do not copy CargoKit's test target blindly.
Update vendored audio package flutter_lints 3 → 6 without dropping its patch.

### SDK and Android tooling

Use [Flutter 3.47.5 stable](https://github.com/flutter/flutter/blob/stable/CHANGELOG.md)
as the proposed baseline: intervening hotfixes include engine security and
desktop fixes. Update bootstrap/manifest/documentation together after validation.
Use an isolated SDK installation during implementation to preserve rollback.

Current Android: AGP 8.12.1, Gradle 8.14, Kotlin plugin declaration 2.2.20,
compileSdk 37, targetSdk 36, minSdk 24, JVM 17. Built-in Kotlin/new DSL are already
enabled; app does not apply org.jetbrains.kotlin.android. A conservative
proposed compatible tuple is AGP 9.3.1 / Gradle 9.5.0 / Kotlin 2.4.20, rather
than independently selecting every latest version. Re-check
[AGP requirements](https://developer.android.com/build/releases/agp-9-3-0-release-notes)
and [Kotlin compatibility](https://kotlinlang.org/docs/gradle-configure-project.html)
when implementing; latest observed AGP is 9.4.1. Determine whether the unused
external Kotlin declaration should remain with built-in Kotlin. Inspect all
plugin Gradle integrations and AGP9 DSL changes before changing the tuple.

| Native dependency | Declared | Candidate |
| --- | --- | --- |
| Work runtime/testing | 2.11.2 | 2.12.0 |
| androidx.media (app and Auto test client) | 1.7.0 | 1.8.0 |
| concurrent-futures-ktx | 1.2.0 | 1.3.0 |
| documentfile | 1.0.1 | 1.1.0 |
| Guava Android | 33.0.0-android | Recheck latest compatible stable before change |
| androidx.test.ext:junit | 1.2.1 | 1.3.0 |
| androidx.test:runner | 1.6.2 | 1.7.0 |
| JUnit / desugar_jdk_libs | 4.13.2 / 2.1.5 | Retain unless verified requirement changes |

Keep the canonical audio_service MediaBrowserService registration. Do not
replace Android Auto with a Flutter head-unit UI or force plugin-owned Media3
versions. Preserve background sync, SAF DocumentFile access, R8 rules, flavors,
sidecar identity and permissions. Validate debug and minified release builds,
unit/instrumentation tests, notification/background playback, WorkManager
restart/retry, and Android Auto browse/play/control.

Apple configuration needs reconciliation: macOS native files say 10.15 while
README says 12+; iOS native targets say 16 while README says 14+. Check current
Flutter/plugin floors and clarify actual supported/released targets before
changing advertised support. Propose macOS 12 and retaining iOS 16, with no
new Apple feature work. Apple builds/runtime require their own hosts; a Linux
build cannot certify them.

## Ordered execution checklist

- [x] 1. Clean isolated checkout; baseline ./tool/check.sh and isolated runtime;
  preserve old locks/artifact and screenshots. Inventory licenses, bundled
  native binaries and resolved Maven graph/advisories; establish target hosts.
- [x] 2. Flutter stable hotfix baseline and compatible Rust advisory fixes;
  authoritative Cargo lock and locked builds. Focused startup/native loading.
- [x] 3. Generator/Drift/SQLite batch; make gen, schema 80 migration tests,
  serialization/import/download tests, fresh/offline native asset builds.
- [x] 4. Network/Riverpod/credentials/notifications/art-cache compatible batch;
  focused error, disposal, persistence and previous-install credential checks.
- [x] 5. File-picker federated major batch and Android toolchain/native-library
  upgrades implemented; emulator SAF/storage checks pass. Interactive picker,
  physical arm64 and head-unit projection remain explicitly unverified follow-ups.
- [x] 6. Coordinated Material/Cupertino + go_router + cached_network_image batch;
  compatibility bridge/localization work, widget/golden/router checks and
  inspected app-owned screenshots. Preserve established appearance.
- [x] 7. Windows WinRT major/binding generator/CargoKit batch; regenerate,
  nested tests and Windows build plus actual SMTC commands/lifecycle checks.
- [x] 8. very_good_analysis 11; fix new lints proportionately, review async
  semantics, format. Final combined gate, documentation and release evidence.

Each batch: change manifest/config and necessary callers, resolve, inspect lock
diff, run focused tests, review full diff, then proceed. Keep batches independently
revertible. An unexpected API break requires upstream review and caller tracing,
not a speculative rewrite or weakening test/security assertions.

## Acceptance and release gates

| Area | Required evidence |
| --- | --- |
| Whole repository | make gen when applicable; analyzer; ./tool/check.sh; no unreviewed generated drift |
| Database | navis_migration_test; downloads/import/write-fence tests; old profile opens unchanged |
| Routing/state | app_router, app_providers, shell/history/desktop command tests; auth/account transitions |
| Art/UI | cover_art tests; viewport/locale/theme cases; lazy visibility and indexed scrolling; goldens reviewed |
| Playback | resolver/audio-handler tests; download/cache/stream, seek/skip, background, native controls |
| Linux | Real isolated authenticated diagnostics loop, MPRIS, persisted effects, screenshot inspection, clean restart |
| Android | Native builds and device SAF/notification/WorkManager/media-session/Auto evidence |
| Windows | Locked Rust build, native library loading, offline SQLite build, actual SMTC metadata/seek/teardown |
| Apple | Deferred by owner while Apple development is unavailable; record deployment/plugin review and unverified native build/runtime |

For runtime use docs/development-workflow.md: authenticated GET /v1/health,
production control/status APIs, redacted logs, persistence and clean restart.
Visible changes require POST /v1/presentation/screenshot and opening the PNG.
Do not substitute desktop scraping/accessibility automation. Missing target
evidence must be recorded as not run; affected supported releases remain gated.

Update docs/architecture.md for changed integration contracts; docs/ci-cd.md
and development-workflow.md for tooling; README for actual platform floors;
changelog_data.dart and generate_release_notes.dart for user-visible changes;
history/removed-features.md for material removals. Do not claim support beyond
verified implementation. Retain this plan at the root until all gates close.

Rollback the complete failing batch, including locks, generated code and native
configuration; use the prior release artifact. Never downgrade an individual
transitive dependency to conceal an incompatible graph. Validate rollback reads
the same data and credentials; no destructive profile resets.

## Progress record

2026-09-27: Planning inventory, solver dry run, advisory and upstream migration
review completed. Dependency manifests/locks and implementation left unchanged.
Android runtime dependency-report task passed; Flutter warned that the current
Gradle, AGP and Kotlin versions will soon lose support.
No upgrade builds, tests, screenshots or platform certification have been run.
All execution checkboxes remain open.

### Implementation evidence

- Isolated checkout: `/home/khalifa/.codex/worktrees/dependency-upgrades/Navis`.
  Original dirty work is preserved. SDK checkout is its sibling `flutter-sdk`.
- Baseline: after resolving nested package development dependencies,
  `./tool/check.sh` passed (1,626 full-suite tests, one skipped; separate
  migration and critical reliability suites also passed). The first attempt
  failed on missing nested development tools, not application test failures.
- Baseline Linux: `tool/auth_lifecycle_diagnostics.sh clone` passed its
  authenticated isolated-profile lifecycle and clean restart/sign-out checks.
  Evidence is under `build/auth-lifecycle-diagnostics/20260927T105909Z-clone`.
- Flutter 3.47.5 / Dart 3.13.4 installed in the separate SDK checkout. Manifest
  and bootstrap minimum updated. Global Flutter installation is unchanged.
- Rust compatible resolution: anyhow 1.0.104, tokio 1.53.1, backtrace 0.3.76,
  adler2 2.0.1. Tracked workspace Cargo.lock and CargoKit `--locked` added.
  `cargo tree --locked` passed; OSV returned zero matches for 97 crates in
  `rust-after-security-update.json`. Windows build/runtime remain open.
- CargoKit exact pins/dev tools upgraded. Compatible transitive upgrades were
  necessary: old frontend_server_client 3.2 tried to run a removed Dart SDK
  snapshot even with the newer test package. After upgrading the graph, all
  eight CargoKit tests passed and `dart analyze` reported no issues. Provenance
  headers are retained as regular comments to satisfy the new lint rule.
- Drift/drift_dev 2.35.0, sqlite3 3.6.0, Freezed 4.0.2 and build_runner 2.16.1
  resolved and tracked outputs regenerated. Inspected changes are generated
  typing/equality helpers; schema stays 80. The six focused migration,
  write-fence, model serialization, permanent-import, download and credential
  suites passed (78 tests). Combined gate results are recorded below.

- Combined SDK/generator graph: `./tool/check.sh` passed after repairing the
  cover-art widget harness (1,626 tests and one skip). The harness previously
  created plugin-backed I/O in fake time, then delayed and swallowed disposal
  errors. It now stubs paths to a temporary directory, opens the repository
  through `tester.runAsync`, and awaits disposal without suppression. All nine
  cover-art widget tests pass. Root analysis still reports the existing 673
  informational lint findings; no errors or warnings. Lint migration is open.
- Upgraded Linux auth/restart/sign-out lifecycle passed in
  `build/auth-lifecycle-diagnostics/20260927T110355Z-clone`.
- Bootstrap now resolves nested development tools from a fresh checkout;
  the upgraded-SDK bootstrap run passed. CargoKit analysis and its eight tests
  also passed under Dart 3.13.4 after formatting.
- Windows SQLite packaging now requires the exact locked DLL and verifies
  its checksum locally and after transfer. Old cache scanning and package-source
  hook patching are removed. Six offline helper success/failure tests and Bash
  syntax checks pass. The real sqlite3 3.6.0 x64 DLL downloaded successfully,
  is a PE32+ x64 DLL, and matches the published SHA-256
  `c5a4ebf9922c63fa252a01c4679992f1fbaa2762b962b78ba6cbdc5cbf7ca91c`.
  Remote Windows hook/build verification remains open. The helper tests are now
  included in the full gate; the amended gate passed (1,626 tests, one skip).
- CargoKit artifact hashing now includes the workspace manifest and lock;
  otherwise a lock-only security update could reuse an old artifact key.
  Four new regressions prove lock/profile invalidation, stale member-lock
  exclusion and standalone compatibility. All 12 nested tests and analysis
  pass under Dart 3.13.4.

- Picker 13.1.0 / Android picker 2.0.0 and compatible networking, credentials,
  notifications and Riverpod floors resolved. Existing picker callers already
  use the supported API. Focused picker/storage/router/artwork tests passed
  (88), and network/authentication/notification tests passed (25).
- Cache persistence regressions pass: metadata survives immediate close/reopen;
  metadata write failures propagate; an artwork metadata failure preserves the
  completed permanent audio download. Combined cache/download suites passed
  (52 tests).
- Android AGP 9.3.1 / Gradle 9.5.0 / Kotlin 2.4.20 and compatible AndroidX/Guava
  updates compiled successfully, including scheduler unit tests, the Auto test
  client, and the minified sideload release (746 Gradle tasks). Stable Flutter
  3.47.5 still uses the legacy AGP extension, so android.newDsl=false is the
  official compatibility hold; built-in Kotlin remains enabled. Custom app-name
  resources require buildFeatures.resValues=true under AGP 9.
- User requested native device/VM validation after the upgrades finish. Android
  testing must use tool/dev_app.sh (.dev / Navis Dev) to preserve the regular app.
  No Android installation has been performed.

Outstanding: Windows SQLite host build verification, UI/router migration,
WinRT/bindings, final lint upgrade, license/binary review, screenshots and
actual Android/Windows device gates.
No batch is certified complete solely by this partial evidence.

### UI migration in progress

- Migrated 189 application/test import and localization consumers to the
  standalone Material/Cupertino libraries; added a shared handwritten modern
  delegate list. Generated localizations remain untouched. Router 18.0.1 and
  cached_network_image 4.0.2 resolve; analysis has no errors or warnings.
- All 179 executed focused UI/router/theme/artwork tests passed, including
  existing goldens. The command also specified an absent Lyrics test directory;
  that command is not recorded as an overall pass. Actual Lyrics golden cases
  are in the routing suite. No golden baselines were changed.
- Added English and Arabic design-delegate coverage (application strings remain
  English-only) and exercised release-note Markdown through its scoped legacy
  bridge. Compatibility plus library-controller tests passed (29).
- Inspected the pre-migration app-owned Library screenshot under
  build/presentation-diagnostics/20260927T113030Z-clone. Its full restart run
  failed on a real automatic-deadline write after database shutdown. A new
  regression reproduced cancelAndWait returning before that work completed.
  The controller now drains automatic/catalog bookkeeping before database close;
  its focused regression and existing controller suite pass. Post-migration
  screenshot/restart verification is running; no runtime pass is claimed yet.

- Post-migration Library diagnostics passed, including a clean shutdown and
  restart. Both app-owned PNGs were opened and inspected in
  build/presentation-diagnostics/20260927T113537Z-clone; layout, colors, artwork
  and player controls match the pre-migration capture. Theme/locale matrix and
  combined gates remain open.
- Windows 0.62.2 resolves. Event tokens are now i64; Ref callback arguments retain
  as_ref null guards, subscription revocation and manual-command ownership.
  FRB runtime is exactly 2.13.0, aligned with the installed generator. ffigen
  22.0.0 resolves; this project uses generator YAML, not the changed Dart config
  API. The owned package's actual SDK floor is aligned and its analysis passes.
  Its test dependency is held at 1.31.1 because Flutter pins test_api 0.7.12.
  There is no standalone test directory; root Windows bridge tests are the
  harness. Rust formatting passes. Binding generation on Linux fails because
  new Windows crates require a Windows target; regenerate/build on the VM.
- Apple scaffolds are configured consistently at iOS 16 / macOS 12 and described
  as unreleased/unverified. No Apple feature work or certification is claimed.
- very_good_analysis 11.0.0 resolves. Reviewed automatic-fix preview: 1,299 fixes
  in 342 files, predominantly constructor type omission and initializing
  formals. Generated files are absent from the preview. Applying source-only
  fixes; dependency edits from dart fix are excluded. Semantic async review,
  zero-info analysis and combined validation remain open.

### Lint migration checkpoint

- very_good_analysis 11 analysis initially reported 1,660 findings. Automatic
  source fixes reduced the backlog, but some SDK-provided fixes were unsafe:
  unnecessary_unawaited left invalid punctuation, closure-type removal lost
  inference through conditional builders, and integer-literal replacement
  widened pixel values to num. Affected task-owned files were restored from a
  pre-fix snapshot; those fixes are excluded from automatic reapplication.
  Pixel arithmetic now preserves double types explicitly. No lint rules were
  disabled. The repaired analysis has no errors or warnings.
- UI/router/theme/artwork/locale/shutdown/Windows Dart harnesses pass together
  (215 tests). Code generation passes with the new constructor syntax and
  updated generator graph; no schema migration was introduced.
- Async return forwarding is explicit across API, storage, sync, playback and
  provider boundaries. Synchronous Drift aggregate reads are resolved into a
  local value before returning, preserving synchronous read behavior and
  avoiding FutureOr inference from the async return context. Reviewed wrappers
  keep error propagation and callback result values. Combined verification is
  running after these changes.
- Current analyzer backlog: 292 informational findings; zero errors/warnings.
  Remaining manual async, context-lifetime, deprecated API and style repairs
  are unfinished. This is not the final quality gate or a completion claim.

- Combined ./tool/check.sh passes after the repaired mechanical and explicit
  async-return changes: formatting, generation, analysis (292 remaining infos),
  migration/critical reliability checks and the full test suite. The full suite passed 1,633 tests with one skip. Final gate
  must be repeated after the remaining source repairs; infos still block handoff.
- Fresh advisory queries return no matches for 316 exact Pub/Rust versions and
  89 resolved Android runtime Maven versions. Evidence is in
  resolved-advisories.json and resolved-android-advisories.json, alongside the
  resolved Android runtime report. This is database coverage, not a guarantee
  that unreported issues do not exist.
- Refreshed licenses cover 224 unique Pub pairs (all have bundled license files)
  and 93 Rust packages. Allo-isolate declares an Apache license file; the owned
  SMTC Rust package now references its existing MIT license, preserving original
  notices. Final bundled-native-license review remains open.

- Deprecated API migration preserves removal-aware drag indices: local Match
  Flow/playlist/appearance lists now receive final destination indices; queue
  widgets translate them to the unchanged audio-handler insertion contract.
  New forward/backward/unchanged queue callback regressions and migration,
  write-fence, visibility and Match Flow tests passed (63 tests).
- Repaired async-context lifetime checks in review dialogs, album notices,
  search-menu actions and usage-stat reset. Sign-out still awaits both pending
  action deletion Futures. Explicit exception forwarding preserves the original
  Object identity; no replacement error types were introduced. Filesystem
  metadata stays asynchronous in production to preserve UI responsiveness;
  scoped documented exceptions retain this intentional behavior. Isolated
  fixture existence assertions use synchronous local metadata checks.
- Internal mutation now uses local resolved queue/index/checkpoint/exclusion
  values, retaining public parameters and command contracts. Storage/playback/
  recommendation/review/radio/About/sign-out focused suites passed (97 tests).
  Further source review corrected pending queue IDs to use the same resolved
  list as the original implementation. Final verification remains open.
- Analyzer backlog is down to 151 informational findings, no errors/warnings.
  Remaining command Futures, positional compatibility contracts and style
  repairs are still being reviewed; no overall completion is claimed.

### Final source validation checkpoint

- The root analyzer reports no errors, warnings or informational findings after
  the lint-11 migration. Command Futures explicitly retain their background
  execution; conditional animation builders retain typed function inference.
  Existing method/callback contracts have narrow, documented style exceptions
  rather than API changes solely to satisfy property/boolean style preferences.
  No additional global lint rules are disabled.
- Source and generation verification is being repeated through `./tool/check.sh`;
  the earlier 1,633-test result predates the final repairs and is not final proof.
- Windows VM and Android device validation will follow source upgrades, as
  requested. Android installation must use `tool/dev_app.sh` and the `.dev`
  application identity / Navis Dev label, preserving the regular app.

- Final combined source gate passes: generated output, formatting, zero-info
  analysis, 34 migration tests, 168 critical reliability tests, and the full
  suite (1,636 passed, one skipped). CargoKit separately passes 12 tests and
  clean analysis. No golden baselines were changed.
- Refreshed resolver evidence is `resolved-root-outdated.json`: all currently
  resolvable upgrades are installed. Remaining latest-version gaps are
  cli_util, cross_file, dbus, file_picker_linux, material_color_utilities, nm,
  and test_api, constrained by the SDK or dependent package graph. No overrides
  were added to force incompatible versions.

- Fresh Linux light and dark runs pass startup, app-owned screenshot capture and
  clean shutdown/restart. Both initial/restart images have been opened and
  inspected: layout, album artwork, navigation and bottom-player controls are
  intact. Evidence directories: `20260927T121719Z-clone` (light) and
  `20260927T121855Z-clone` (dark), under `build/presentation-diagnostics/`.
- Linux logs retain the pre-existing mpv `Failed to create file cache` message
  (also present in the pre-UI baseline). It is not evidence of a newly introduced
  dependency regression; playback/seek checks still need their own results.

- Fresh OLED startup/restart passes and both screenshots were inspected
  (`20260927T122028Z-clone`). All three themes retain the app's existing visual
  identity; no golden baselines changed.
- Real playback indicator checks pass through play, pause, song replacement and
  clean restart with zero reported load failures. All six queue/player screenshots
  were inspected (`build/playback-indicator-diagnostics/20260927T122159Z-clone`).
- The final Android debug APK builds successfully through `tool/dev_app.sh`.
  APK metadata verifies `com.navis.app.navis.dev`, `Navis Dev`, SDK 37 and
  version `1.4.0-sidecar`; evidence is `android-dev-apk-identity.txt`. Nothing
  has been installed on a device yet.

- Linux MPRIS runtime verification passes against the D-Bus service owned by
  the isolated app PID: matching track metadata, native Pause/Play and
  SetPosition while playing a direct stream, followed by clean API shutdown.
  Sanitized evidence is `linux-mpris-runtime-evidence.json`. An initial test
  harness used a nonexistent lifecycle endpoint; it was corrected to the
  documented `/v1/shutdown` and rerun successfully.
- Remaining acceptance gates require the Windows VM (binding regeneration,
  native Rust/WinRT compilation, offline SQLite packaging and actual SMTC)
  and connected Android device (existing credentials, SAF/pickers,
  notifications, WorkManager and Android Auto). Bundled native binary notices
  must be reviewed against the final platform artifacts before release.
  No release readiness or Windows/Android runtime certification is claimed.

### Native artifact review checkpoint

- `native-artifact-inventory.json` records library paths, byte sizes and SHA-256
  digests for the built Linux profile and Android Dev debug artifacts. Their
  compressed notices are identical. All 200 collected source notice files retain
  every license body, compared using Flutter's component grouping and normalized
  whitespace. This check includes sky_engine's component notices; it does not
  replace Maven/system-library or final release bundle coverage.
- The Linux bundled SQLite engine reports 3.53.4 and source ID
  `2026-07-24 19:02:57 bf7c7f30031888f4e796e429ab3978879485813aaca6f641c7b33e4e09459bcc`.
  Package sqlite3 3.6.0 is the Dart wrapper/native asset distribution version,
  not the SQLite engine version. The engine's dedication is documented by
  [SQLite](https://www.sqlite.org/copyright.html); wrapper notices remain retained.
- Final Linux release and Android Dev release builds are running. Windows native
  artifact and device verification still require the user-provided hosts/device.

- Linux release compilation passes. The initial final Android Dev release build
  passes but its icon tree shaker reports the missing Cupertino icon font.
  The coordinated UI migration now explicitly adds `cupertino_icons` 1.0.9,
  the official stable Flutter icon asset package. No widget/layout API changes
  are needed. Release asset inclusion and warning removal are being checked;
  source validation and lock/advisory/license evidence must be refreshed for
  this added dependency before the final source gate is current again.

- The combined source gate passes again after the font dependency was added:
  1,636 tests passed, one skipped, zero analyzer findings, with generation,
  migration and critical reliability gates passing. `source-validation.json`
  now records the updated lock hash. Advisory/license evidence includes the
  new font dependency: 317 exact Pub/Rust advisory queries, 225 Pub license
  pairs and 93 Rust packages; the font package's fresh OSV query has no matches.

- Final Linux release and Android Dev release/debug builds pass after the font
  addition. Both Android APKs verify `.dev` identity / Navis Dev label and contain
  a nonempty Cupertino font asset. The release missing-font warning is absent.
  Current release/debug notices match across platforms and retain all 201
  collected source notice files, including the newly added font license.
  `native-artifact-inventory.json` and `source-validation.json` contain the
  refreshed evidence. Runtime profile evidence from the prior source gate is
  retained separately; the added asset does not change widget/layout code.

- `android-maven-licenses.json` reviews all 89 exact resolved runtime Maven
  coordinates. Published Google Maven/Maven Central POM declarations and
  cached parent metadata identify licenses where declared. Flutter's four
  engine coordinates are tied to the exact SDK engine revision and its
  sky_engine notice source. This records declared license provenance; it
  does not claim all distribution obligations have been independently certified.
- Completion remains unproven for Windows native generation/build/SQLite/SMTC
  and Android device credentials/SAF/notifications/WorkManager/Auto behavior.
  The device list was checked again and remains empty. The Windows SSH address
  has not been supplied. The source plan and all available local gates remain
  intact; these missing platform results cannot be replaced by Linux tests.

### Completion audit: waiting for platform access

The current root and Rust lock hashes match `source-validation.json`. The final
combined source gate and Linux release / Android Dev release+debug build logs
are terminal and successful. No local build or test process is being waited on.
The latest Android device inventory is empty, and no Windows VM SSH address has
been supplied. These same platform-access prerequisites remain outstanding.

Completion is therefore not proven: Windows binding regeneration, locked native
Rust/WinRT compilation, offline SQLite packaging and actual SMTC behavior require
the Windows VM; Android credential retention, SAF/picker, notification,
WorkManager and Android Auto checks require the connected device. The overall
upgrade objective remains unfinished and release readiness is not claimed.
Resume with the Windows SSH address and connected Android device; Android
installation must retain the `.dev` package identity and Navis Dev label.


## Android emulator validation — resumed 2026-09-27

The user authorized an Android emulator and reiterated use of the Dev app. This
supersedes the earlier device-access blocking condition. The existing Pixel AVD
passed the external cold MediaBrowserService instrumentation check, but lacked
installation space. A fresh `Navis_Dependency_Upgrade` AVD uses the installed
API 37 x86_64 image with 16 KiB pages; no existing emulator apps/data were deleted.
All subsequent installs use `com.navis.app.navis.dev.upgrade`, label **Navis Dev**.

- Built the baseline commit `646275b8` with secure storage 11.0.0 / SQLite wrapper
  3.5.2 and the upgraded implementation with 11.2.0 / 3.6.0 as profile APKs.
  A synthetic fixture login and one-song library were saved in the baseline,
  then reopened after installing the upgraded APK with data preserved. A fixture
  server subsequently verified the recovered password's salted authentication
  token: five authenticated requests accepted, zero rejected; sync succeeded.
- The reopened database remains schema 80, passes `integrity_check`, and has
  zero foreign-key violations. No primary database or real account was used.
- Playback reached ready from streaming and from a permanent SAF download.
  Native MediaSession Play/Pause, file seeking, and a clean queue restart pass.
  Android exposes both the foreground playback notification and completed
  download notification. Test playback stayed muted.
- The native DocumentsProvider fixture exercised production download and
  import code. A denied media read imported no permanent cache entry; restoring
  reads imported one entry. This does not certify interactive system pickers.
- WorkManager held the catch-up job behind its unmetered connectivity constraint.
  After closing the UI and killing only the background app process, restoring
  unmetered Wi-Fi started a new process. The persisted worker result is
  `succeeded`; durable catalog request 8 completed three requests and retained
  the one-song catalog. The original network policy was restored afterward.
- App-owned home/library screenshots were captured and inspected. The initial
  SwiftShader emulator host crashed; testing resumed using ANGLE software
  rendering with the same app data. No app fatal crash was recorded.
- App, fixture server and emulator were stopped after evidence collection.

[Sanitized emulator evidence](../audits/dependency-upgrades-2026-09-27/android-emulator-runtime-evidence.json)
records APK hashes, exact versions, worker observations and screenshot hashes.
The Android cold-start gate covers the canonical MediaBrowserService before
MainActivity; it does not certify an Android Auto head-unit projection session.
Physical arm64 hardware and interactive picker checks remain open, along with
Windows binding regeneration, native build, offline SQLite and SMTC behavior.
The Windows VM connection details have not yet been supplied. Overall completion
is still pending; source checks retain the previously passing 1,636-test gate.


## Windows host discovery — 2026-09-27

The user-provided Windows VM was located in local libvirt as `win11` (four
vCPUs, 8 GiB RAM). It was initially shut off and has now been started for the
authorized Windows validation. Its virtio network uses the default libvirt
network. No saved SSH alias was present, and no QEMU guest-agent channel is
configured; the SPICE channel is not a guest execution API. Windows SSH
username/address has been requested. No Windows source files, system settings,
signing identity, toolchain or installed application were modified.

The next Windows steps remain binding regeneration against FRB 2.13, locked
Rust/native release build, SQLite local-asset offline verification, and actual
SMTC metadata/seek/teardown. The running VM is not evidence that these checks
have passed. Android's interactive picker and head-unit projection remain
separate from the already recorded emulator service/storage evidence.


### Windows access resolved; storage prerequisite

The running VM's address was found through libvirt ARP as `192.168.122.100`.
SSH public-key authentication works for the provided `khalifa` account; no
password was used or saved. The connection-detail blocker is resolved.
Read-only inspection confirms Rust/cargo 1.97.1 and CMake are available, but
Flutter is 3.44.2 / Dart 3.12.2, below the upgraded project's SDK floor; an
isolated pinned SDK is needed. FRB codegen is not yet installed on this host.

The Windows C: drive has only 51,585,024 bytes free (about 49 MiB). The Linux
host has roughly 9 GiB free. The old Flutter 3.41.6 backup occupies 2.24 GB,
while reproducible Navis build folders total under 1 GB; deleting those alone
would not support an isolated new SDK plus native compilation. No backup,
build output, user file or SDK was deleted. Space of at least 8–10 GB inside
the VM, or specific authorized cleanup targets, has been requested. The VM
is left running for the user to arrange space; Windows build/runtime gates
remain unverified. This is the first turn encountering this storage blocker.


### Storage blocker recheck — second consecutive goal turn

Read-only SSH inspection confirms the Windows VM remains running and reachable,
but C: has only 95,481,856 bytes free (about 91 MiB), still insufficient for
the pinned SDK and native build. No cleanup authorization or adequate space
has arrived. The prior turn made progress by resolving SSH access and identifying
the storage prerequisite; this recheck changes no implementation and is not
claimed as upgrade progress. The recorded passing source and Android evidence
remains intact. Windows generation/build/SQLite/SMTC gates still prevent full
completion. The goal remains active while awaiting the requested space.


### Storage blocker confirmed — third consecutive goal turn

SSH inspection again reports only 95,559,680 bytes free on Windows C: (about
91 MiB). The same storage prerequisite has persisted across three consecutive
goal turns. No adequate space or authorized cleanup targets have been provided.
The previous recheck was no progress, not a live-build wait. No build is running;
starting the required isolated SDK/native build with this capacity is infeasible.

The overall goal is blocked, not complete. Resume when at least 8–10 GB is
available in the VM or the user identifies specific cleanup targets. Then
prepare Flutter 3.47.5 / Dart 3.13.4, regenerate FRB 2.13 bindings on Windows,
run the locked Rust/native build and offline SQLite packaging verification,
and exercise actual SMTC metadata, commands, seeking and teardown. Recorded
source and Android emulator checks remain passed; interactive picker and
head-unit projection remain explicitly unverified. No existing SDK, backup,
user data or generated artifact has been deleted to work around this blocker.


## Authorized artifact cleanup and Windows preparation

The user authorized deletion of obsolete Navis files, packages, builds and
screenshots. Removed this task's disposable Android intermediates, generated
Android assets, test cache and completed baseline build directory. Also removed
completed Linux diagnostic database/media copies; final screenshots and
sanitized result files remain. Source worktrees, current APK outputs, native
artifacts, current audit evidence and primary application data are preserved.
These deletions recovered roughly 3.8 GB on the Linux home filesystem.

A scoped Windows cleanup was prepared for the obsolete `.navis/remote-windows-build`
workspace/packages, old Navis installer downloads, the old Navis build's private
pub cache, and generated `build`/`.dart_tool` directories in the Windows source
checkout. It preserves the known libmpv download archive before removing the
old build workspace. SSH stopped responding before authentication; the command
timed out, so no Windows cleanup is claimed. SMB also timed out. A graceful
ACPI shutdown was requested but the VM remains running. User restart or explicit
forced-reset authorization has been requested because a forced reset can
interrupt unsaved Windows work. No forced reset was performed.

Read-only hypervisor inspection shows the VM image is on `/Gaming`, which has
about 230 GB free; the earlier Linux home-space observation is not the VM-image
filesystem capacity. The Windows guest's nearly full C: remains the actual
space prerequisite. No virtual disk was resized or guest-agent channel added.

While access is pending, staged six official Windows artifacts for engine
`af7e796e161ae0bb1ff0758c71a7105418bd9ded`, verified against provider MD5
metadata and recorded SHA-256 hashes. Prepared a source archive from the pinned
Flutter checkout, the upgrade source archive, 273 exact hosted Pub package
folders (including Flutter tools dependencies), and 92 locked runtime crates
with sparse registry metadata. The official Windows FRB 2.13.0 generator
archive matches its published SHA-256 digest. These are prepared inputs, not
Windows generation/build/runtime results.

[Staged Windows input evidence](../audits/dependency-upgrades-2026-09-27/windows-staged-inputs.json)
records the input versions and hashes. Next: restore VM access, perform the
authorized scoped cleanup, install the isolated pinned SDK, regenerate bindings,
and run the remaining native Windows validation.


### Windows access retry after user restart/setup

The user requested another attempt. The VM remains running at the confirmed
address. SSH responds with its OpenSSH-for-Windows banner, and TCP acknowledges
the client handshake bytes, but no SSH key-exchange response arrives. A reduced
algorithm proposal and disabled IP QoS also time out before authentication;
SMB and WinRM ports are unavailable. This is not an authentication rejection or
a missing password. No Windows cleanup/build is claimed. Prepared inputs and
the user's scoped cleanup authorization remain available. Windows-side SSH
service recovery or a confirmed VM restart is needed to continue.


### SSH blocker confirmed — third consecutive retry goal turn

The latest 12-second SSH probe again terminates with timeout exit 124 before
login. The same pre-authentication failure persists across three consecutive
turns since the user's latest retry request. The preceding turn made no
implementation progress; it was a prerequisite recheck, not a running-build
wait. Windows cleanup and native verification have not started. No build or
probe remains running. The scoped cleanup authorization and staged pinned
SDK/source/dependency/generator inputs are preserved.

The goal is blocked, not complete. Restore Windows SSH (for example, restart
the `sshd` service from an elevated Windows PowerShell session) or restart the
VM, then request another retry. Forced reset has not been authorized or
performed. Once connected, perform the approved obsolete Navis cleanup and
continue pinned SDK setup, FRB binding generation, locked native build, offline
SQLite verification and actual SMTC runtime checks. Passing source/Linux/Android
evidence remains valid; outstanding platform checks are not represented as
passed.

### Windows access recovered and isolated SDK validated

The latest retry authenticated successfully with the existing SSH key. Scoped
cleanup removed completed old Navis build/cache/package files and freed about
3.5 GB; shared SDKs and unrelated projects were preserved. The isolated pinned
Flutter 3.47.5 / Dart 3.13.4 SDK runs on Windows, strict offline dependency
resolution preserves the root lockfile SHA, and the adapter passes actual
Windows `cargo check --locked --offline`. Binding generation is still pending:
its cargo-expand helper installation exhausted the system disk. A new blank
32 GiB task-only scratch disk was attached live with unique serial
`navis-upgrade-build`; Windows serial, RAW state and exact size were checked
before initializing it as N:. The task workspace is being copied there.
Existing Windows and unrelated secondary disks were not resized or formatted.
Flutter Windows compilation, SQLite packaging and SMTC runtime verification
remain outstanding. Prior SSH-blocked entries above are historical.

### Windows generation completed on the isolated builder

The task copy comparison and key hashes passed. Removing its original C:
copy recovered about 3 GB. The relocated isolated SDK resolves strictly offline
with the original root and Rust lock hashes unchanged. cargo-expand 1.0.126
was installed with its locked dependency graph on N:. FRB 2.13.0 regeneration
completed on Windows, followed by a passing locked/offline native check. Rust
generated output is identical; Dart generated outputs were copied back from
the real generator (generated ignore lists and declaration/quote ordering).
Automated Dart fixes and formatting found no additional changes.

Review found that the existing SMTC diagnostic seek used milliseconds where
GMTC expects ticks, allowing elapsed playback to satisfy its loose check. The
script now pauses, sends a five-second `TimeSpan` tick value, requires position
within 500 ms while still paused, then resumes playback. Active workflow and
CI documentation record this validation correction. The combined source gate
is being rerun. The Dev Windows build is in progress with the verified SQLite
bundle; runtime evidence is still pending.

### Windows build and first runtime attempt

Dev release (269.7 seconds) and isolated diagnostics profile (172.2 seconds)
compilation passed. The packaged SQLite DLL has the exact required SHA and
loads as SQLite 3.53.4. Both actual Windows Rust tests pass. The generated
bindings and harness changes passed the full source gate again (1,636 tests,
one skipped; zero analysis issues). The first interactive runtime attempt
launched the app and played the fixture, but failed in the pre-existing
PowerShell harness before GMTC commands: WinRT types lacked explicit metadata
qualification, and PowerShell 5.1 represents async operations as interface-less
COM wrappers. The harness now supplies explicit async result types and selects
the matching AsTask overload. Its repeat enum was also corrected to the actual
Windows.Media.MediaPlaybackAutoRepeatMode API. Launch quoting, paused tick-based
seek, restart play/pause delivery and app-owned screenshots are included. The
corrected runtime attempt and final source gate are still required; no SMTC
pass is inferred from successful builds.

### Real Windows seek regression identified

The corrected harness delivered actual Windows play/pause/next/previous
commands, but the paused five-second seek failed. Tracing the real callback
showed WinRT `TimeSpan.Duration` ticks were sent unchanged into a Dart stream
that constructs `Duration(milliseconds: value)`, causing the player to clamp
five seconds to the track end. The adapter now converts ticks to milliseconds
at the native event boundary. A Rust regression covers an actual five-second
Windows TimeSpan, zero, fractional-millisecond ticks and signed positions.
The public Dart duration contract and playback source priority are unchanged.
Native tests and the strict runtime scenario are being rerun; this is not yet
a passing SMTC certification. Paired release notes and final rebuilt artifacts
will follow the successful runtime check.

### Desktop shuffle identity follow-up required by native acceptance

The fixed Windows seek passes the paused five-second check, and actual native
play/pause/next/previous/shuffle/repeat delivery reaches the app. The restart
check fails: the selected song is saved with an index from libmpv's physically
shuffled playlist while queue rows retain their logical order. The owned
media-kit adapter delegates shuffle to a second independent native randomizer,
reports its physical index as the just_audio index, and does not implement
just_audio's `setShuffleOrder` request. This violates the logical occurrence
identity contract and prevents completing the required native restart gate.
No schema migration is needed: the saved queue contract remains logical order.

Before completing Windows certification, keep one explicit mapping from native
playlist positions to just_audio logical occurrence indices, apply the exact
requested permutation through native moves, and translate seeks and current
indices through that mapping. Preserve duplicate occurrences (never match only
by URI), the active source/position during shuffle toggles, queue insertion/
removal/moves, natural advancement, and load replacement. Avoid libmpv's
independent randomizer. Inspect request/stream ordering and stale async work
before editing. Add focused adapter tests with a controlled native-player
substitute plus real Linux and Windows shuffled-restart checks, then rerun the
combined gate and final builds. The permanent/rolling/direct source policy and
the force-seekable customization remain unchanged.

### Desktop shuffle correction and regression gate

The owned adapter now applies just_audio's explicit permutation and translates
physical positions into logical queue occurrences. It retains duplicate sources
without URI matching, serializes order mutations and indexed seeks, and reads
the native playing position after edits instead of trusting a delayed playlist
mirror. Insert/remove/move operations preserve the selected occurrence and
position; terminal completion follows physical playback order. The progressive
force-seekable patch and schema 80 remain intact.

Eight adapter regressions pass (shuffle toggles with delayed cursor events,
permutation updates/natural advance/indexed seeking, insert/remove/moves,
concurrent shuffle/seek, stale-source requests, invalid orders, failed native
move followed by replacement load, terminal completion). Five pure occurrence
map tests pass in the root suite. The combined gate passes 1,641 project tests
with one intentional skip, plus all eight adapter tests, migration/reliability
gates, and zero analysis issues. Native Windows and Linux shuffle/restart
verification is in progress; old artifact hashes do not certify this latest fix.

### Final native playback acceptance

Windows interactive GMTC validation passes with the seek and shuffle fixes:
metadata/capabilities, progressing timeline, play/pause, next/previous, paused
seek to 5 seconds (4.5–5.5-second tolerance), shuffle, repeat, and clean restart
followed by native play/pause. Three native Rust tests pass, including conversion
from WinRT ticks to milliseconds. Evidence is
`docs/audits/dependency-upgrades-2026-09-27/windows-smtc-runtime-evidence.json`.

Linux on an isolated bus passes a three-occurrence queue containing the same
song twice: indexed selection of the second occurrence, paused seek, shuffle
without losing occurrence or position, clean restart restoring that occurrence,
native MPRIS play/pause, and shuffle-off retaining it. The restored app screenshot
was inspected; schema 80 integrity is ok with no foreign-key violations. A retry
of the temporary fixture hit a startup request timeout; allowing its application
startup to settle before sending the queue request produced another passing run.

Final source gate passes again after harness timeout/cleanup/presentation changes:
1,641 project tests, one intentional skip, eight adapter tests, and no analysis
issues. Final Dev release artifacts are rebuilding; earlier hashes are superseded
when those finish. Android physical arm64, interactive picker and full head-unit
projection remain follow-up validation; emulator results are recorded separately.
Apple native builds require a macOS host and remain unverified. None of these
platforms is certified from another platform's build.

### Final artifact and handoff record

Final release builds pass after the seek/shuffle changes: Linux Dev, Windows
Dev (152.8 seconds), and Android Dev sideload (100.9 seconds, 90.9 MB). Android
identity is `com.navis.app.navis.dev`, label `Navis Dev`, min SDK 24 / target 36
/ compile 37; the Cupertino font is packaged. Windows packaged sqlite3.dll
loads, reports SQLite 3.53.4 through wrapper 3.6.0, and matches the exact locked
SHA-256. License notices and native artifact hashes were refreshed from these
final builds.

Implementation remains in the isolated `codex/dependency-upgrades` checkout.
No source changes were committed/pushed and no release was published. The
original checkout and stable app/data remain intact. Temporary Windows build
workspace/SDK are retained on the task-owned N: scratch disk; original Windows
toolchain and existing disks remain unchanged. Previously completed old Navis
artifacts were removed with the user's authorization to recover build space.

Apple native build/runtime verification, physical Android arm64, interactive
picker selection, and full head-unit projection are recorded as unverified and
remain release follow-ups. The supported-target release gates remain in effect;
passing Windows/Linux/emulator checks does not certify those targets.

Final Windows diagnostics rerun also passes after the restored-presentation wait
and PowerShell cleanup changes. Both screenshot checksums were verified and the
restored app screenshot was inspected (no layout failure). Windows copies of the
playlist adapter, occurrence mapper and Rust SMTC implementation match local
source hashes. PowerShell parser reports zero errors. The test app and fixture
have exited and the task-owned scheduled task was removed; the Windows VM and
its task-owned build workspace remain available.

### Owner validation policy and further emulator checks

The owner explicitly accepts ongoing Apple-check deferral because Apple
development is unavailable. Apple is deferred, not an outstanding host request
or a blocker for this upgrade's development handoff; no Apple native pass is
claimed. Android and head-unit checks should use emulation where possible.
Navis remains phone-projected through its MediaBrowserService; there is no
separate Navis head-unit APK or Android Automotive feature added here.

Both phone emulators contain Google's `1.2.565510-stub` Android Auto placeholder.
DHU 2.0 starts and an ADB link can open, but that is not projection negotiation
or media rendering. Full projection requires the full Google Android Auto app
and its head-unit server. The native fixture test additionally passed Downloads
browse/context, playFromMediaId, metadata, play/pause/resume, paused seek to one
second, shuffle and repeat on the existing isolated API-37 emulator profile.
A cold service rerun and the combined source gate are in progress.

The service-only rerun found an actual cold SAF playback failure: the storage
existence channel was registered only by MainActivity, so a downloaded content
URI could not be selected before opening the phone screen. A private tracked
Android Flutter plugin now owns the read-only existence query on each engine
using application context. It introduces no hosted version change, new storage
permission, eager engine or UI dependency. Folder write/import behavior remains
unchanged. Dart storage/source-priority tests and the cold native fixture test
are being rerun; the earlier warm pass alone is not cold playback evidence.

### Cold Android SAF follow-up acceptance

The updated Dev profile passes both external native tests after force-stop, with
zero failures or skips: all four root tabs, downloaded browse/context, SAF
playFromMediaId, metadata, native pause/resume, paused one-second seek, shuffle
and repeat. MainActivity was opened only after the service tests finished.
The SAF status then retained one permanent entry with no missing file or access
renewal. The app-owned screenshot was inspected; the synthetic server was
stopped, so its offline retry banner was expected.

`./tool/check.sh` passes after this fix: 1,642 project tests, one intentional
skip, eight adapter tests, 34 migrations and 168 critical tests; no analyzer
issues. The Android Dev release rebuild passes in 58.2 seconds, retains the
owned plugin GPL notice and Cupertino font, and has package
`com.navis.app.navis.dev` / label `Navis Dev`. The runtime fixture remained
`com.navis.app.navis.dev.upgrade`. Both temporary emulators have been stopped,
task-owned forwards removed, and stable app/data preserved.

The latest Linux profile build succeeded, but its authenticated diagnostics
requests timed out in the isolated session, including a retry that waited for
readiness before issuing playback and an alternate X11 session. The final
unresponsive test app and fixture were stopped. That follow-up runtime result is inconclusive
and is not a new pass. Earlier Linux/Windows native acceptance remains dated
evidence for the desktop fixes; the subsequent graph adds only this owned
Android plugin and changes no hosted versions or desktop runtime code.

Full DHU projection remains unverified because the two emulator images provide
Google's Android Auto placeholder, without the full phone projection component
and head-unit server. Navis continues to support phone projection, with no
separate Navis head-unit APK. Apple checks are owner-deferred.
See `docs/audits/dependency-upgrades-2026-09-27/android-headunit-emulator-evidence.json`
and the updated source/artifact records.

## Port onto dev (2026-10-01)

The upgrade was implemented as uncommitted work on a base 85 commits behind
dev, which had since gained the navigation overhaul, genre removal (schema
89), Navis-owned shuffle, the windowed queue, the Windows EQ and its pinned
libmpv. It was re-applied rather than merged:

1. Manifests, Android/Windows/Rust tooling, the `navis_android_storage`
   plugin, scripts and docs were taken from the upgrade and combined with dev
   where both changed (vendored `just_audio`, the Windows libs package,
   `check.sh`, the SMTC diagnostics script).
2. The mechanical part (material_ui imports and very_good_analysis 11
   automatic fixes, excluding the fixes found unsafe here) was run on dev's
   current code.
3. The upgrade's remaining hand-made code edits were extracted by running the
   same mechanical step on its base and diffing against its result, then
   applied with a three-way merge. Where dev had rewritten the code, dev's
   version was kept.

Not carried over: the media_kit playlist-order mapping and its adapter tests
(superseded by Navis-owned shuffle, where mpv never shuffles) and lint-only
edits in rewritten code. New on top: `onReorderItem` callers use the
already-adjusted index, `PlatformFile.length()` may be null (the EQ import
also checks the bytes read), and the sync drain also waits for an in-flight
catalog sync.

Validation at the port: `./tool/check.sh` (2,228 tests, one skip); Linux
isolated clones of the real library (sync clone matrix with the schema 89
migration, presentation, throughput 99.6 albums/s); the Windows 11 VM on
Flutter 3.47.5 (profile build with the locked windows-rs 0.62 crate,
`windows_smtc_diagnostics.ps1` including the strict paused five-second seek,
EQ regression 14/14, queue/shuffle parity 17/17, schema 89 migration of the
fixture profile, app-owned screenshots). Android was not rebuilt or run in
this port; it was on 2026-10-01 during the release test (profile sidecar on
an API 37 emulator: in-place upgrade from 1.3.1, schema 89, cold-start queue
restore, route tour, Now Playing and Queue back order).

