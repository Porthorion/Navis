# Copilot Instructions for Navis

`AGENTS.md` at the repository root is the canonical guide for AI coding agents.
Use it first; this file is a short compatibility summary.

## Commands

Use the repo scripts as the source of truth:

```bash
# Bootstrap dependencies and verify toolchain
./tool/bootstrap.sh
# or
make bootstrap

# Full quality gate: format check, codegen, analyze, migration tests,
# critical reliability tests, then full test suite
./tool/check.sh
# or
make check

# Code generation (Freezed, JSON serialization, Drift)
make gen
# or
dart run build_runner build --delete-conflicting-outputs

# Watch code generation
make gen-watch

# Static analysis / lint
flutter analyze --no-fatal-infos
# Note: custom_lint is currently disabled in pubspec and skipped by check.sh

# Format check
dart format --set-exit-if-changed .

# Full tests
flutter test

# Coverage
flutter test --coverage

# Run a single test file
flutter test test/path/to/foo_test.dart

# Targeted migration test used by the quality gate
flutter test test/src/database/migrations/navis_migration_test.dart -r expanded

# Dev sidecar app (installs alongside stable app)
./tool/dev_app.sh run -d <device-id>
./tool/dev_app.sh apk
```

## High-level architecture

Navis is a multi-platform Flutter Subsonic/OpenSubsonic client. The app boots from `lib/main.dart`, creates a root Riverpod `ProviderContainer`, wraps the app in `UncontrolledProviderScope`, and renders `NavisApp` from `lib/src/app.dart`.

The app is structured around:

- **Riverpod as DI and state management**: global infrastructure providers live in `lib/src/providers/app_providers.dart` and expose the database, settings, network clients, audio bootstrap, cache managers, and playback streams.
- **Feature-first modules** under `lib/src/features/<feature>/` with `data/`, `domain/`, and `presentation/` layers.
- **go_router shell navigation** in `lib/src/routing/app_router.dart` using `StatefulShellRoute.indexedStack`; the main player UI is embedded in `AppShell`, not exposed as a separate now-playing route.
- **Drift-backed local storage** in `lib/src/database/navis_database.dart`; the live schema version is `52`, with explicit stepwise migrations and DAO-based access.
- **Audio pipeline** centered on `NavisAudioHandler` and `PlaybackSourceResolver`: playback prefers permanent cached files first, then rolling lock-cached files, then direct streaming, and exposes UI state through `playbackSnapshotProvider`.
- **Adaptive shell/runtime behavior** in `lib/src/routing/desktop_layout.dart` and `app_shell.dart`: desktop runtime enables pointer/shortcut affordances, while layout switches between bottom-nav, rail, and wide desktop shell based on viewport size.

## Key conventions

- **Do not instantiate app infrastructure ad hoc.** `NavisDatabase`, settings repositories, audio handler state, and cache managers are expected to come from Riverpod providers or explicit provider overrides. `./tool/check.sh` treats `"It looks like you've created the database class NavisDatabase multiple times"` as a hard failure.
- **Keep feature providers inside their feature.** `app_providers.dart` is the composition root and may import feature modules for dependency injection. Avoid circular feature imports.
- **Be careful what rebuilds the router.** `appRouterProvider` intentionally watches only auth state via `.select(...)`; watching the full server config can rebuild `GoRouter` and reset navigation.
- **Respect audio bootstrap flow.** `NavisApp(requirePlaybackBootstrap: true)` triggers `audioBootstrapControllerProvider`; UI should read playback state through `playbackSnapshotProvider` / `playerStateProvider` instead of creating handler state on its own.
- **Preserve playback source priority.** Changes around caching or playback should keep the resolver order: permanent cache -> rolling cache -> direct stream.
- **Adaptive behavior is split between layout and input policy.** `AdaptiveContext` decides shell composition; `AdaptiveInputPolicy` controls shortcuts, pointer affordances, right-click menus, and escape behavior.
- **Desktop audio init is special on macOS debug builds.** `main.dart` skips `just_audio_media_kit` initialization on debug macOS unless `--dart-define=NAVIS_ENABLE_MEDIA_KIT_DEBUG=true` is set.
- **Tests rely on shared helpers, not manual setup.** Use `createTestDatabase()` / `withTestDatabase()` from `test/helpers/test_database.dart` for database-backed tests, and `setAdaptiveTestViewport()` from `test/helpers/adaptive_test_harness.dart` for deterministic adaptive widget tests.
- **Certain runtime warnings are release blockers.** `./tool/check.sh` fails if test output contains `"It looks like you've created the database class NavisDatabase multiple times"` or `"Tried to modify a provider while the widget tree was building"`.
- **Hero tags follow a fixed pattern.** Use `buildCoverArtHeroTag(...)` from `lib/src/common_widgets/hero_cover_art.dart`; the tag shape is `cover_art_{context}_{entityId-or-coverArtId}`.
- **Listen Together / Voyage is retired.** Do not wire Voyage networking,
  session state, playback sync, queue sync, settings controls, or visible entry
  points unless the feature is explicitly reintroduced. The remaining
  `lib/src/features/group_listening/` files are hidden placeholders only.
