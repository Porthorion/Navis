# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

`AGENTS.md` is the canonical and most up-to-date agent guide. Prefer it when
this file conflicts with code or newer docs.

Before declaring any runtime-affecting task complete, follow the mandatory
runtime validation loop in `AGENTS.md` and its detailed procedure in
`docs/development-workflow.md`. Static checks and `flutter test` alone are not
sufficient completion evidence.

## What This Is

Navis is a multi-platform Subsonic/OpenSubsonic music client (Android, iOS, macOS, Linux, Windows) built with Flutter. Key features: gapless audio playback, offline cache + permanent downloads, adaptive UI (phone/tablet/desktop), synced lyrics, scrobbling, and smart queue generation.

Listen Together / Voyage is retired for now. Do not wire Voyage networking,
session state, playback sync, queue sync, settings controls, or visible entry
points unless the feature is explicitly reintroduced. The remaining
`lib/src/features/group_listening/` files are hidden placeholders only.

## Commands

```bash
# Bootstrap (validates Flutter/Dart versions, runs pub get)
./tool/bootstrap.sh       # or: make bootstrap

# Code generation (Freezed, JSON serialization, Drift)
make gen                  # or: dart run build_runner build --delete-conflicting-outputs
make gen-watch            # watch mode

# Quality gate (format → codegen → analyze → migration/critical tests → full tests)
./tool/check.sh           # or: make check

# Individual checks
dart format --set-exit-if-changed .   # format check
flutter analyze && dart run custom_lint  # lint (custom_lint currently disabled in pubspec)
flutter test              # or: make test
flutter test --coverage   # or: make test-coverage

# Run a single test file
flutter test test/path/to/foo_test.dart

# Dev app builds (uses separate app ID to coexist with release)
./tool/dev_app.sh run -d <device-id>
./tool/dev_app.sh apk

# Release
./tool/release.sh v1.2.3
./tool/release.sh v1.2.3 --targets=android,ios,macos
./tool/release.sh v1.2.3 --all-platforms
```

**check.sh critical test gates** — these two patterns are treated as hard failures:
- `"It looks like you've created the database class NavisDatabase multiple times"` — means a provider is being instantiated outside Riverpod DI
- `"Tried to modify a provider while the widget tree was building"` — means an illegal provider mutation

## Architecture

### Stack
- **State management**: Riverpod v3 (providers as DI container, no service locators)
- **Navigation**: go_router with `StatefulShellRoute.indexedStack`
- **Database**: Drift (SQLite), schema v36, 19 tables, 10 DAOs, reactive streams
- **Models**: Freezed + JSON serializable (API models), Freezed only (domain models)
- **Audio**: `just_audio` + `audio_service`; desktop uses `just_audio_media_kit`
- **Build-time config**: `--dart-define=NAVIS_LASTFM_API_KEY=...`, `--dart-define=NAVIS_UPDATE_CHANNEL=dev`

### Directory Layout

```
lib/src/
├── api/            # HTTP clients: SubsonicApiClient, LastFmApiClient, LrclibClient
│   └── models/     # Freezed + JSON API response models
├── database/       # Drift DB class, table definitions, DAOs
├── features/       # Feature-first MVVM modules (see below)
├── providers/      # app_providers.dart — global infrastructure providers
├── routing/        # go_router config, adaptive shell, keyboard shortcuts
├── common_widgets/ # Shared UI components
├── theme/          # Material 3 theming, dynamic accent, desktop tokens
└── utils/          # Logger, constants, connectivity helpers
```

### Feature Module Structure

Each feature under `lib/src/features/<name>/` follows this layout:
```
data/        # Repositories, services, API integrations, DAOs
domain/      # Immutable value objects, state enums, business logic
presentation/ # Screens (ConsumerWidget/ConsumerStatefulWidget), *_providers.dart
```

### Provider Organization Rules

1. **Global infrastructure** lives in `lib/src/providers/app_providers.dart` (database, API client, connectivity, settings)
2. **Feature providers** live inside feature directories — import from `app_providers` but never the reverse
3. Feature `*_providers.dart` files often re-export for convenience
4. Avoid circular imports between features

### Playback Data Flow

```
User action → QueueController → NavisAudioHandler
  → PlaybackSourceResolver (permanent cache → rolling cache → stream)
  → updates playbackSnapshotProvider → UI reacts
```

Source resolution priority: **Permanent cache** → **Rolling cache (LRU)** → **Stream**

### Adaptive Layout

`AdaptiveLayoutClass` classifies screen width into buckets:
- `phoneCompact` < 550 dp → bottom nav
- `tabletMedium` < 840 dp → bottom nav (landscape → rail)
- `tabletExpanded` < 1200 dp → navigation rail
- `desktopWide` ≥ 1200 dp → persistent side rail

`AdaptiveInputPolicy` (separate from layout) governs: `enableKeyboardShortcuts`, `enableRightClickMenus`, `enableHoverEffects`.

Desktop keyboard shortcuts are centralized in `DesktopCommands` with a **text-input guard** (suppresses hotkeys while typing) and a **route guard** (shortcuts only fire on their target screen).

### Desktop Audio

`JustAudioMediaKit` is initialized in `main.dart` for Linux/Windows/macOS. On macOS in debug mode, media_kit init is skipped to keep hot-restart stable — override with `--dart-define=NAVIS_ENABLE_MEDIA_KIT_DEBUG=true`.

### Testing Patterns

- `AdaptiveTestHarness` — standard widget tree wrapper for tests
- `TestDatabase` — in-memory Drift database for unit/widget tests
- Use `ProviderContainer` overrides to mock providers (no service locator to replace)
- Migration tests are run separately from unit/widget tests in `check.sh`

### Hero Animation Tag Convention

```dart
'cover_art_{context}_{coverArtId}'
// contexts: album_grid, album_detail, now_playing, mini_player
```

## Issue Tracking

The repo is on a self-hosted Forgejo instance at `https://git.porthorion.com/khalifa/Navis`. `gh` CLI does **not** work here — use the Forgejo REST API with the token from `~/.git-credentials`:

```bash
TOKEN=$(grep porthorion ~/.git-credentials | sed 's|.*:\(.*\)@.*|\1|')

# List open issues
curl -s "https://git.porthorion.com/api/v1/repos/khalifa/Navis/issues?state=open&type=issues&limit=50" \
  | python3 -c "import sys,json; [print(f'#{i[\"number\"]}: {i[\"title\"]}') for i in json.load(sys.stdin)]"

# Close an issue with a comment
curl -s -X POST ".../issues/N/comments" -H "Authorization: token $TOKEN" -H "Content-Type: application/json" -d '{"body":"..."}'
curl -s -X PATCH ".../issues/N" -H "Authorization: token $TOKEN" -H "Content-Type: application/json" -d '{"state":"closed"}'
```

Commits reference fixed issues as `fix(#N):` or `(issue #N)` — close these when merging/finishing a branch.
