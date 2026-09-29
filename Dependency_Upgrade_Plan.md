# Navis dependency upgrade plan

Audit date: 2026-09-27. Status: **planned; no dependency upgrades applied**.

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
- [Complete locked Dart/Cargo inventory](docs/audits/dependency-upgrades-2026-09-27/inventory.md),
  [root resolver report](docs/audits/dependency-upgrades-2026-09-27/root-outdated.json),
  [SMTC report](docs/audits/dependency-upgrades-2026-09-27/smtc-outdated.json),
  [CargoKit report](docs/audits/dependency-upgrades-2026-09-27/cargokit-outdated.json),
  [major dry run](docs/audits/dependency-upgrades-2026-09-27/root-major-upgrade-dry-run.txt),
  and [advisory query/results](docs/audits/dependency-upgrades-2026-09-27/advisories.json)
  preserve the evidence, including transitive dependencies.
- OSV queried 399 unique locked Pub/crates.io package-version pairs across the
  local lockfiles. It returned Rust matches below and no Pub matches. This is
  an advisory database snapshot, not proof of absence of vulnerabilities or
  reachability. The resolved Android sideload-release runtime graph was also
  queried: 89 Maven coordinates, no matches. See the
  [native graph](docs/audits/dependency-upgrades-2026-09-27/android-runtime-dependencies.txt)
  and [Maven advisory evidence](docs/audits/dependency-upgrades-2026-09-27/android-advisories.json).
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

- [ ] 1. Clean isolated checkout; baseline ./tool/check.sh and isolated runtime;
  preserve old locks/artifact and screenshots. Inventory licenses, bundled
  native binaries and resolved Maven graph/advisories; establish target hosts.
- [ ] 2. Flutter stable hotfix baseline and compatible Rust advisory fixes;
  authoritative Cargo lock and locked builds. Focused startup/native loading.
- [ ] 3. Generator/Drift/SQLite batch; make gen, schema 80 migration tests,
  serialization/import/download tests, fresh/offline native asset builds.
- [ ] 4. Network/Riverpod/credentials/notifications/art-cache compatible batch;
  focused error, disposal, persistence and previous-install credential checks.
- [ ] 5. File-picker federated major batch with SAF/native picker validation;
  separate Android toolchain/native-library sub-batch and device checks.
- [ ] 6. Coordinated Material/Cupertino + go_router + cached_network_image batch;
  compatibility bridge/localization work, widget/golden/router checks and
  inspected app-owned screenshots. Preserve established appearance.
- [ ] 7. Windows WinRT major/binding generator/CargoKit batch; regenerate,
  nested tests and Windows build plus actual SMTC commands/lifecycle checks.
- [ ] 8. very_good_analysis 11; fix new lints proportionately, review async
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
| Apple | Deployment/plugin checks and actual build/runtime on supported targets; explicit unverified status if unavailable |

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
