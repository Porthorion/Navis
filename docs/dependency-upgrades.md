# Dependency upgrade playbook

This playbook governs routine and security-driven dependency work in Navis. It
applies to root Flutter packages, generated-code tooling, platform plugins, and
the owned packages under `third_party/`. Current source, tests, and active
platform contracts remain authoritative when this document disagrees with a
package migration guide.

## Cadence and inventory

Run the inventory at least monthly, before a release, and immediately for a
security advisory or a platform-toolchain change:

```bash
./tool/bootstrap.sh
flutter pub outdated --json
dart pub deps --style=compact
cd third_party/navis_windows_smtc && flutter pub outdated
```

Record the Flutter/Dart versions, current/resolvable/latest package versions,
transitive changes, minimum SDK and platform requirements, maintainer activity,
release notes, licenses, advisories, and local patches. Do not use
`dependency_overrides` to force an incompatible graph.

Classify each candidate before editing:

| Tier | Examples | Required handling |
| --- | --- | --- |
| Low | Patch-level Dart-only package | Review changelog, resolve, focused test |
| Medium | Plugin, routing, state, or generator minor | Review callers and add focused tests |
| High | SDK, persistence, audio, native plugin, database, or major release | Isolate, certify runtime behavior, retain rollback evidence |

## Upgrade workflow

1. Start from a clean worktree and establish the baseline with focused tests
   and `./tool/check.sh`.
2. Upgrade Flutter/Dart before packages that require a newer SDK. Update
   `pubspec.yaml`, `tool/bootstrap.sh`, native build configuration, and the
   documented support floor as one change.
3. Upgrade one compatibility group at a time: generated-code tools; database
   and SQLite; state/routing; credentials and plugins; audio/desktop adapters.
   Run `flutter pub get` after each manifest update, inspect the lockfile, and
   keep the final release lockfile under version control.
4. Read upstream changelogs and migration guides before changing callers.
   Refactor only for a real API, behavior, lifecycle, security, or native
   requirement. Preserve Riverpod DI, the narrow router refresh contract, and
   permanent download → rolling cache → direct stream playback priority.
5. For Freezed, JSON, or Drift changes run `make gen`; inspect and commit the
   generated sources. Never hand-edit generated files. Database behavior or
   schema changes also require a stepwise migration and migration-test update.
6. Update active documentation, changelog data, and release notes when an
   upgrade changes visible behavior or supported platforms. Record any material
   removal/replacement in `docs/history/removed-features.md`.

## Compatibility and replacement decisions

Treat a dependency as a replacement candidate when it is unmaintained,
incompatible with a supported SDK, exposed to an unresolved security issue, or
blocks a required fix. Compare at least two alternatives for API coverage,
maintenance activity, license, platform support, migration cost, tests, and
runtime behavior. Do not replace a proven dependency solely because it is old.

The current watch list is intentionally retained:

| Dependency | Current role | Decision and review trigger |
| --- | --- | --- |
| `scrollable_positioned_list` | Exact indexed Library and Lyrics navigation | Retain. Re-evaluate for SDK incompatibility, an indexed-navigation defect, or a maintained replacement that preserves variable-height scrolling, position reporting, and existing tests. |
| `visibility_detector` | Defers cover-art work until visible | Retain. Re-evaluate for SDK incompatibility, rendering/lifecycle defect, security issue, or replacement that preserves coalesced visibility semantics. |
| `just_audio_media_kit` (vendored) | Desktop libmpv backend with Navis force-seekable patch | Keep Navis ownership. Rebase only after upstream review and prove direct-stream seeking, cache behavior, MPRIS, Windows SMTC, and that a failed stream's mpv error still reaches stdout through the app's redacting `print` zone. |

## Validation and release gate

Run narrow tests first, then `make gen`, `flutter analyze --no-fatal-infos`, and
`./tool/check.sh`. Validate the final combined graph, not just individual
batches. Cover database migrations and permanent-download import, model
serialization, provider/router behavior, credentials across an app restart,
File Picker SAF persistence, Android notification channels and permission,
Library/Lyrics indexed scrolling, and lazy cover-art visibility.

Runtime-affecting upgrades require the isolated authenticated diagnostics loop
in `development-workflow.md`: launch the real Linux app, check health, drive
production APIs, inspect relevant logs and persisted effects, request and open
an app-owned screenshot for visible behavior, then repeat after a clean restart.
Use MPRIS on Linux, MediaBrowser/Android Auto on Android, GMTC/SMTC on Windows,
and the supported Apple interface on macOS/iOS as the authoritative platform
adapter. If a required host or device is unavailable, record that result as
unverified; never call it passing.

For rollback, retain the previous committed lockfile and release artifact,
revert the whole compatibility batch rather than pinning a single transitive
package, and investigate the first incompatible boundary before retrying.
