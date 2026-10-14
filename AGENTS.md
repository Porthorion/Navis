# Navis agent guide

Navis is a GPL-3.0-or-later Flutter client for Subsonic/OpenSubsonic servers. It targets Android, iOS, macOS, Linux, and Windows.
The current version and supported SDK constraints live in `pubspec.yaml`.

## Start here

1. Read [docs/README.md](docs/README.md), then the relevant subsystem document.
2. Read [docs/development/agentic-engineering.md](docs/development/agentic-engineering.md) before
   changing implementation, tooling, or documentation.
3. Inspect the relevant implementation, interfaces, callers, configuration,
   and tests before editing. Search before loading unrelated large files.
4. Make the smallest complete change and update required documentation in the
   same change. Record material removals or deprecations in
   [docs/history/removed-features.md](docs/history/removed-features.md).
5. Select focused validation first. Runtime-affecting work must complete the
   runtime loop in [docs/development/development-workflow.md](docs/development/development-workflow.md).
6. Update `docs/project/progress.md` with completion evidence. New implementation
   plans belong in `docs/plans/`; completed plans go in
   `docs/history/completed-plans/`.
7. Review the complete diff and run `./tool/check.sh` before handoff, except
   for documentation-only changes where proportional validation is sufficient.

`AGENTS.md` is the concise, always-loaded entry point. The canonical workflow,
definition of done, documentation lifecycle, and tool-neutral policy are in
`docs/development/agentic-engineering.md`; do not duplicate that policy in tool-specific
files. More-specific instructions, if present, override this file for their
directory.

## Project map

```
lib/main.dart                 # bootstrap and root ProviderContainer
lib/src/api/                  # Subsonic, Last.fm, LRCLIB clients/models
lib/src/database/             # Drift database, migrations, tables, DAOs
lib/src/features/<feature>/   # feature-first data/domain/presentation modules
lib/src/providers/            # application composition root
lib/src/routing/              # go_router, adaptive shell, desktop commands
lib/src/common_widgets/       # shared UI
test/src/                     # mirrors lib/src/
tool/                         # bootstrap, diagnostics, quality, release scripts
docs/                         # active and historical documentation
third_party/                  # tracked, vendored runtime dependencies
```

The application is a single Flutter app, not a monorepo. Its main boundaries
are feature modules, the Riverpod composition root, Drift persistence, and
platform runners/services. See `docs/architecture.md` for the detailed data
flows and platform contracts.

## Non-negotiable engineering rules

- Use Riverpod for application infrastructure. Never instantiate
  `NavisDatabase` outside provider DI; tests hard-fail on this warning.
- `app_providers.dart` is the composition root and may import features for DI;
  do not create circular feature-to-feature dependencies.
- Do not mutate providers during widget build. Handle all `AsyncValue` states.
- Preserve playback source priority: permanent download → rolling cache →
  direct stream. Read the playback section of `docs/architecture.md` first.
- Preserve the router's narrow auth refresh contract; do not rebuild it from
  broad/timestamped configuration state.
- Navigate through `NavService` and build locations with `AppRoutes`
  (`lib/src/routing/`); never write route strings or call GoRouter directly
  from features. A source guard test enforces this.
- Database changes require a stepwise migration, generated Drift output, and
  `test/src/database/migrations/navis_migration_test.dart` updates.
- After Freezed, JSON, Drift table, or DAO changes run `make gen` and commit
  the generated source required by the repository workflow.
- User-visible behavior changes require an entry in
  `lib/src/features/changelog/changelog_data.dart`, the single source for the
  in-app changelog and the release notes that
  `tool/generate_release_notes.dart` renders.
- If the version in `pubspec.yaml` is already released (its `v<version>` tag
  exists), start the next version before new work: bump it and add its
  changelog entry. Patch +0.0.1 for fixes, minor +0.1.0 for reworks, major
  only for a milestone; see "Versioning" in `docs/development/agentic-engineering.md`.
- Listen Together/Voyage is retired. Do not restore its networking, sessions,
  settings, queue sync, or visible UI without an explicit product decision.
- Genres are not a Navis concept: no genre page, route, Library section, Home
  shelf, search filter, Android Auto node, sync/scan input, catalog-change
  signal, recommendation input or diagnostics field without an explicit
  product decision. `test/src/architecture/no_genre_feature_test.dart`
  enforces this for `lib/`.
- Never commit credentials, put real values in examples, reset unrelated work,
  weaken tests/security, or silently make public breaking changes.

## Validation

```bash
./tool/bootstrap.sh
make gen                         # model, JSON, Drift changes
flutter test test/path/to/test.dart
flutter analyze --no-fatal-infos
./tool/check.sh                  # required for implementation work
```

`check.sh` runs formatting, code generation, analysis, migration and critical
reliability tests, then the full test suite. It also treats ad-hoc database
construction and provider mutation during build as hard failures. Use
`docs/development/development-workflow.md` for isolated diagnostics, app API control,
screenshots, and platform-specific validation; use `docs/development/ci-cd.md` for release
and CI-equivalent gates.

The dead-code gate checks public Dart declarations, l10n keys, declared assets
and font families, missing directory-asset loads, and direct dependencies.
New findings (including test-only declarations), stale baseline entries, and
empty reasons fail. Production code used only by tests must be deleted or marked
`@visibleForTesting` as a deliberate test seam; annotated declarations are
excluded from findings. References from release/dev scripts in `tool/` count as
real use, excluding the checker itself. Record other deliberate exceptions with
a factual, non-empty reason in `tool/dead_code_baseline.json`. Use
`dart run tool/dead_code_check.dart --update` to shrink the baseline; new entries
without reasons go to a pending file and the update is refused.

Android runtime evidence can use a temporary emulator that you create, use
and delete yourself; see "Temporary Android emulators" in
`docs/development/development-workflow.md`. Never wipe or uninstall from an emulator you
did not start.

For visible Flutter changes, inspect an app-owned screenshot from
`POST /v1/presentation/screenshot`. Use the authenticated Navis diagnostics API
for runtime control; do not substitute AT-SPI, OCR, xdotool, window scraping,
or accessibility services unless an explicitly authorized accessibility bridge
test requires them.

## Documentation ownership

| Change | Update |
|---|---|
| Architecture, routing, providers, playback, adaptive layout | `docs/architecture.md` |
| Schema or migration | relevant architecture detail + migration test |
| Quality gate or `tool/*` behavior | `docs/development/ci-cd.md` and `docs/development/development-workflow.md` |
| User-visible behavior | `changelog_data.dart` (feeds the release notes) |
| Platform support or public capability | `README.md` and relevant docs |
| Material removal/deprecation | `docs/history/removed-features.md` |
| Engineering workflow/policy | `docs/development/agentic-engineering.md` and this entry point if needed |

Keep active docs current; historical docs explain prior behavior and must not
be presented as current implementation. `docs/project/development-plan.md` and `docs/project/progress.md`
are planning/evidence records, not implementation authority.

## Platform notes

- Android Auto is MediaBrowserService projection, not a Flutter head-unit UI.
  Keep the canonical `com.ryanheise.audioservice.AudioService` registration.
- Linux uses the app-owned D-Bus MPRIS bridge; Windows uses the tracked
  `third_party/navis_windows_smtc` Rust/WinRT adapter; macOS media controls
  remain incomplete. See architecture and platform testing documents.
- Desktop media-kit initializes on Linux, Windows, and macOS. Debug macOS
  skips it unless `NAVIS_ENABLE_MEDIA_KIT_DEBUG=true` is supplied.

## Repository operations

Development happens in Porthorion's private repository (remote `origin`). The public
source is `https://github.com/Porthorion/Navis` (remote `github`): only `main`,
`dev` and version tags are pushed there, never feature branches, and public
issues live on GitHub. The maintainer clone gives `origin` two push URLs
(Forgejo and GitHub), so one `git push origin dev` updates both with no runner
or mirror; GitHub pull requests are merged locally and pushed back the same way.
Never force-push shared branches.

Branches: `main` is exactly what has been released (it changes only on release
day, then gets the `vX.Y.Z` tag); `dev` collects work for the next version;
`release/X.Y` is cut from `dev` when a version enters final testing and then
accepts fixes only, never features. Every fix that lands on `release/X.Y` is
merged back into `dev`. Test builds and the final release are built from
`release/X.Y`, which merges into `main` on release day. Hotfixes for a shipped
version branch from `main` (or the release branch) and merge back to both.
Feature and fix branches stay local and short-lived. Forgejo's public `khalifa/Navis` keeps only a README and
the 1.5.0 bridge release for 1.4.x updaters. Never print credential material.

Tool compatibility entry points are `.cursor/rules/navis-agents.mdc`,
`CLAUDE.md`, `GEMINI.md`, and `.github/copilot-instructions.md`. They are
intentional short pointers to this guide and the canonical policy.
