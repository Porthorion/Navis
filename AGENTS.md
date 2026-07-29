# AGENTS.md — Navis Agent Guide

This file is the **canonical guide** for AI coding agents working in this repository. Read it at the start of every session. When you change architecture, tooling, conventions, or feature boundaries, **update this file and the relevant project docs in the same change**.

## How to use this file

**Doc hierarchy** (most authoritative first):

1. `AGENTS.md` — operational and architectural contract for agents
2. `docs/*.md` — deep dives on subsystems
3. `README.md` — user-facing overview and quick start
4. `DEVELOPMENT_PLAN.md` / `PROGRESS.md` — roadmap and task tracking (verify against code; the plan may lag)

`CLAUDE.md` and `.github/copilot-instructions.md` exist but may be stale. **This file supersedes them** for accuracy.

### Doc maintenance checklist

Update documentation in the **same change** as your code:

| When your change affects… | Update… |
|---------------------------|---------|
| Architecture, providers, routing, playback, adaptive layout | `AGENTS.md` § Architecture + `docs/architecture.md` |
| Database schema or migrations | `AGENTS.md` § Database + `test/src/database/migrations/navis_migration_test.dart` |
| Quality gates or `tool/*` scripts | `AGENTS.md` § Commands + `docs/ci-cd.md` + `docs/development-workflow.md` |
| User-visible behavior | `lib/src/features/changelog/changelog_data.dart` + `tool/generate_release_notes.dart` |
| New platform capability | `README.md` features + `AGENTS.md` § Platform notes |
| Completed planned work | `PROGRESS.md` (date + evidence) |
| Tooling versions (Flutter/Dart) | `AGENTS.md` § Stack + `README.md` tech table |

Do not create stray markdown reports, summaries, or scratch documents. Put information in the right existing file.

---

## 1. Project identity

Navis is a multi-platform **Subsonic/OpenSubsonic** music client built with Flutter.

| | |
|---|---|
| **Platforms** | Android, iOS, macOS, Linux, Windows |
| **License** | GPL-3.0 (`LICENSE`) — README may say MIT; trust `LICENSE` |
| **Hosting** | Forgejo at `https://git.porthorion.com/khalifa/Navis` — **`gh` CLI does not work** |
| **Current version** | See `pubspec.yaml` (`version:` field) |

**Major capabilities:** gapless/background playback, offline rolling cache + permanent downloads, adaptive UI (phone → tablet → desktop), synced/unsynced lyrics, server scrobbling, external Last.fm/ListenBrainz scrobbling, smart queue / instant mix, Match Flow, Android Auto, AudioMuse integration, channel-aware updater (stable/dev).

---

## 2. Session start workflow

1. Read this file (`AGENTS.md`). Skim `PROGRESS.md` if doing planned roadmap work.
2. Pick **one small, testable scope** — no drive-by refactors.
3. Identify touched files *before* editing.
4. Implement the smallest vertical slice with tests.
5. Run `./tool/check.sh` before considering work done.
6. Update docs per the checklist above.

**Blocker protocol:** if blocked for more than ~30 minutes, record in `PROGRESS.md`: what is blocked, what was tried, exact error, proposed next action. Do not silently skip tasks.

**Task done criteria:** implementation wired in, relevant tests added/updated, `./tool/check.sh` passes, docs updated, `PROGRESS.md` updated if applicable.

---

## 3. Commands and quality gates

```bash
# Bootstrap (Flutter ≥ 3.44, pub get)
./tool/bootstrap.sh          # or: make bootstrap

# Code generation (after Freezed / Drift / JSON model changes)
make gen                     # dart run build_runner build
make gen-watch               # watch mode

# Full quality gate (pre-commit hook runs this)
./tool/check.sh              # or: make check

# Individual checks
dart format --set-exit-if-changed .
flutter analyze --no-fatal-infos
flutter test
flutter test --coverage      # or: make test-coverage
flutter test test/path/to/foo_test.dart

# Dev sidecar app (`.dev` suffix, `Navis Dev`, dev update channel)
./tool/dev_app.sh run -d <device-id>
./tool/dev_app.sh apk
./tool/dev_app.sh linux
./tool/dev_app.sh auto       # Android Auto
./tool/dev_app.sh dhu        # Desktop Head Unit

# Release (runs check unless --skip-checks)
./tool/release.sh v1.2.3
./tool/release.sh v1.2.3 --targets=android,ios,macos
./tool/release.sh v1.2.3 --all-platforms
./tool/release.sh v1.2.3 --allow-existing-version  # intentional rebuild only
```

Android release builds remove stale Flutter/Gradle APK outputs before building,
remove any same-name root release asset before copying, and validate the final
APK package/version/signature plus release string sentinels before upload.

### `check.sh` pipeline (ordered)

1. `/tmp` disk space ≥ 256 MB
2. `dart format --set-exit-if-changed .`
3. `dart run build_runner build`
4. `flutter analyze --no-fatal-infos`
5. Migration tests: `test/src/database/migrations/navis_migration_test.dart`
6. Critical reliability suite (5 files):
   - `test/src/routing/app_router_test.dart`
   - `test/src/providers/app_providers_test.dart`
   - `test/src/features/player/data/playback_source_resolver_test.dart`
   - `test/src/features/player/data/navis_audio_handler_test.dart`
   - `test/src/features/library/presentation/library_sync_provider_test.dart`
7. Full `flutter test`
8. Coverage when `CI=true`

### Hard-fail test output patterns

These strings in test output cause `check.sh` to fail:

- `"It looks like you've created the database class NavisDatabase multiple times"` — ad-hoc DB instantiation outside Riverpod DI
- `"Tried to modify a provider while the widget tree was building"` — illegal provider mutation during build

### Lint note

`custom_lint` / `riverpod_lint` are not dependencies. `make lint` and
`check.sh` use `flutter analyze --no-fatal-infos`.

---

## 4. Stack and versions

| Layer | Package | Version constraint |
|-------|---------|-------------------|
| Flutter | flutter | ≥ 3.44.0 |
| Dart | sdk | ^3.12.0 |
| State | flutter_riverpod | ^3.3.1 |
| Routing | go_router | ^17.1.0 |
| Database | drift + drift_flutter | ^2.32.1 |
| Audio | just_audio + audio_service | ^0.10.5 / ^0.18.18 |
| Models | freezed + json_serializable | ^3.1.0 / ^6.13.1 |
| Desktop audio | just_audio_media_kit | ^2.1.0 |
| Linux media | dbus | ^0.7.10 |
| Windows media | smtc_windows | ^1.1.0 |

**Providers are hand-written** (`NotifierProvider`, `Provider`, `StreamProvider`, etc.) — **not** `@riverpod` codegen. `riverpod_generator` is not in `pubspec.yaml`.

---

## 5. Repository layout

```
lib/src/
├── api/              # SubsonicApiClient, LastFmApiClient, LrclibClient + Freezed models
├── database/         # NavisDatabase, tables, DAOs, migrations
├── features/         # 14 feature modules (see §6)
├── providers/        # app_providers.dart — composition root
├── routing/          # go_router, AppShell, adaptive layout, desktop commands
├── common_widgets/   # Shared UI (cover art, hero tags, player chrome)
├── theme/            # Material 3, dynamic accent, desktop tokens
└── utils/            # Logger, connectivity, notifications bootstrap

test/src/             # Mirrors lib/src/ structure
test/helpers/         # createTestDatabase, setAdaptiveTestViewport, sqliteAvailable
tool/                 # bootstrap, check, release, dev_app scripts
docs/                 # Deep-dive documentation (see §15)
```

**Feature module pattern** (each under `lib/src/features/<name>/`):

```
data/         # repositories, services, API integration
domain/       # value objects, enums, business rules
presentation/ # screens, widgets, *_provider.dart files
```

---

## 6. Feature map

| Feature | Path | Agent notes |
|---------|------|-------------|
| `auth` | `lib/src/features/auth/` | Router watches auth via `.select()` only |
| `library` | `lib/src/features/library/` | Critical test: `library_sync_provider_test.dart` |
| `player` | `lib/src/features/player/` | Highest complexity; preserve source resolver order |
| `cache` | `lib/src/features/cache/` | Rolling cache; resolver priority |
| `downloads` | `lib/src/features/downloads/` | Permanent downloads; download queue |
| `playlists` | `lib/src/features/playlists/` | Playlist CRUD and detail |
| `search` | `lib/src/features/search/` | Desktop quick-search shortcut |
| `home` | `lib/src/features/home/` | Adaptive layout breakpoints matter |
| `settings` | `lib/src/features/settings/` | Scrobble credentials in secure storage |
| `group_listening` | `lib/src/features/group_listening/` | Retired Listen Together; no active UI, Voyage backend, or session code |
| `match_flow` | `lib/src/features/match_flow/` | Collaborative guessing game; `MatchFlowDao` in DB |
| `auto` | `lib/src/features/auto/` | Android Auto — see `docs/android-auto-testing.md` |
| `audiomuse` | `lib/src/features/audiomuse/` | AI integration |
| `changelog` | `lib/src/features/changelog/` | Must sync with `tool/generate_release_notes.dart` |

---

## 7. Architecture essentials

### Boot sequence (`lib/main.dart`)

1. `WidgetsFlutterBinding.ensureInitialized()`
2. Initialize desktop audio backend (`just_audio_media_kit` on macOS/Linux/Windows)
3. Create root `ProviderContainer` via `_createRootProviderContainer()`
4. `audioBootstrapControllerProvider.notifier.ensureInitialized()`
5. `NotificationBootstrap.initialize()`
6. `runApp(UncontrolledProviderScope(container: rootContainer, child: NavisApp(...)))`

- Uses `UncontrolledProviderScope` with a pre-built container — **not** a bare `ProviderScope`.
- `NavisApp(requirePlaybackBootstrap: true)` — UI reads playback via providers; never create handler state ad hoc.

### Provider organization (`lib/src/providers/app_providers.dart`)

- **Composition root** (~2700 lines): database, API clients, audio, cache, cross-feature wiring.
- `app_providers.dart` **does** import feature modules for DI wiring. This is intentional.
- Feature providers live in `lib/src/features/<name>/presentation/*_provider.dart`.
- Avoid **circular** feature↔feature imports.
- **Never** instantiate `NavisDatabase` outside Riverpod (hard-fail in tests).

### Playback data flow

```
User action → queueProvider (QueueController)
  → NavisAudioHandler
  → PlaybackSourceResolver
      permanent cache → rolling lock-cache → direct stream
  → playbackSnapshotProvider → UI
```

Source resolution priority: **Permanent cache** → **Rolling cache (LRU lock-cache)** → **Stream**

Queue replacement is two-phase for album-style queues: phase 1 prepares only
the tapped song in the transport queue so playback starts quickly; phase 2
fills the remaining audio sources. During phase 2, `PlaybackSnapshot.queueSongIds`
may expose a pending logical queue so the UI can show the full requested order
before every transport item is prepared. Queue mutation UI must treat
`PlaybackSnapshot.hasPendingLogicalQueue` as read-only/loading state.

Remote source recovery is layered: lock-cached stream setup or runtime stalls
must first bypass lock caching and retry direct stream playback for that song;
direct-stream failures should mark the song failed and advance to the next
playable queue item when one exists. Phase-2 queue fill failures for non-current
remote items must not leave the active player empty or stuck.

Permanent downloads and rolling→permanent promotion must pre-cache cover art
with `kCoverArtStandardSize`; smaller ad hoc sizes create different cache keys
and can leave offline artwork blank.

When `PlaybackSnapshot.hasActivePlayback` becomes false, `AppShell` must clear
its logical player overlay stack immediately so Back targets the underlying
route. Phone/tablet player chrome may retain the last active presentation only
for its non-interactive exit animation; retained visuals must never retain back
priority or accept input.

Now Playing uses a full directional artwork transition only when the queue
actually changes tracks. Restart-current Previous actions and unavailable Next
actions use a short directional snapback with replay/end-of-queue feedback.

### Library sync data policy

- Automatic library sync is **low-data by default** after initial sync.
- A failed automatic sync remains failed until the next configured sync
  interval, a reconnect, or an explicit manual retry. Do not add short forced
  retry loops that repeatedly restart the same failing metadata pass.
- Isolate non-fatal artist and album endpoint failures. Commit usable entities,
  keep only unfinished IDs pending, and continue them in bounded foreground
  passes. Authentication, authorization, database, and invariant failures still
  fail the pass. Persist only safe diagnostics (stage, endpoint, entity ID,
  exception type, attempts), never exception messages or credentials.
- Do not reintroduce periodic/daily full rebaseline scans from `syncIfStale()`.
  Full library repair belongs behind explicit Force Full Sync or a dedicated
  sync-model migration gate.
- Incremental sync uses the server-provided `getIndexes.lastModified` cursor.
  Local completion time is only for scheduling/UI; do not advance the server
  cursor until every candidate in the response has been verified and its album
  hydration has completed.
- A returned index is a gated artist snapshot, not a changed-artist feed.
  Persist continuation state and drain it in bounded passes (48 artists on
  non-cellular networks, 24 for a manual cellular refresh). Non-cellular
  continuation passes run quietly while the app remains foregrounded.
- When a newer server cursor arrives during a pending artist audit, prioritize
  newly reported/suspicious artists, preserve the untouched tail, and move
  already-verified artists behind it. A fresh local completion timestamp must
  not suppress persisted pending verification.
- Run the bounded newest-album health probe every 12 hours. Servers with
  unsupported or unreliable indexes use bounded artist/newest-album
  verification on normal non-cellular syncs and retry `getIndexes` daily.
- Starred content, genres, and playlists are auxiliary metadata. Do not fetch
  them on every hourly no-op metadata probe; refresh them on manual sync, real
  metadata changes, or the longer auxiliary sync window.
- App version/build changes do not imply a full resync. Use
  `requiredLibrarySyncModelVersionProvider` only when a storage/sync contract
  change truly requires a one-time repair.
- Search, recommendation, instant-mix, and queue metadata is provisional until
  authoritative sync confirms it. Keep provisional parents out of normal
  browsing and reconcile song IDs only by same ID, one unique recording MBID,
  or one unique exact metadata match with compatible track/disc and duration
  within three seconds. Ambiguous matches must remain local.
- Apply proven song-ID aliases to the audio handler before deleting the
  provisional row. Preserve an active losing cache file, resolve late cache
  completions through persisted aliases, and replay aliases during audio
  bootstrap so synchronization cannot invalidate the active remote source.

### Listen Together

- Listen Together / Voyage is retired for now. Do not wire Voyage networking,
  session controllers, queue synchronization, settings, or visible player
  entry points back into the app unless explicitly requested.
- There are no active Listen Together UI entry points. Do not add placeholder
  controls or settings screens unless the feature is explicitly redesigned.
- Legacy Drift columns for Voyage settings remain for compatibility, but app
  settings map them to disabled/empty values and save them as disabled.

### Routing (`lib/src/routing/app_router.dart`)

- `StatefulShellRoute.indexedStack` in `AppShell`.
- **No top-level `/now-playing` route** — player is embedded in the shell.
- `appRouterProvider` must watch auth with `.select(...)` only. Watching the full `serverConfigProvider` rebuilds `GoRouter` and resets navigation.
- `NavService` (`navigation_service.dart`) for app-level navigation.
- Desktop mouse back/forward via `navigation_history_provider.dart`.

### Adaptive layout (`lib/src/routing/desktop_layout.dart`)

**Non-desktop** (`AdaptiveLayoutClass`):

| Class | Width |
|-------|-------|
| `phoneCompact` | < 600 dp |
| `tabletMedium` | 600–839 dp |
| `tabletExpanded` | ≥ 840 dp |

**Desktop** (`DesktopLayoutClass`, when `isDesktopRuntime`):

| Class | Width |
|-------|-------|
| `compactDesktop` | < 1200 dp |
| `standardDesktop` | 1200–1599 dp |
| `ultraWideDesktop` | ≥ 1600 dp |

**Input policy** (`AdaptiveInputPolicy` — use exact field names):

- `enableDeterministicTraversal`
- `enableEscapeOverlayPriority`
- `enableDesktopPointerAffordances`
- `enableSecondaryClickMenus`
- `enableDesktopCommandShortcuts`

`AdaptiveContext` decides shell composition; `AdaptiveInputPolicy` controls shortcuts, pointer affordances, and escape behavior separately.

Desktop shortcuts: `DesktopCommands` (`lib/src/routing/desktop_commands.dart`) with **text-input guard** (suppress while typing) and **route guard** (shortcuts only on target screen).

### Database (`lib/src/database/navis_database.dart`)

| | |
|---|---|
| **Schema version** | 54 |
| **Tables** | 24 |
| **DAOs** | 14 |

DAOs: `AppSettingsDao`, `ServerDao`, `LibraryDao`, `SongIdentityDao`, `PlaylistDao`, `CacheDao`, `DownloadQueueDao`, `HistoryDao`, `PlayQueueDao`, `MatchFlowDao`, `ScrobbleDao`, `StarSyncDao`, `ListenBrainzFeedbackDao`, `NetworkUsageDao`.

- Stepwise migrations in `navis_database.dart`.
- **Always** update `test/src/database/migrations/navis_migration_test.dart` when changing schema.
- Access only through DAOs — no raw SQL in feature code.

### Hero animation tags

Use `buildCoverArtHeroTag(...)` from `lib/src/common_widgets/hero_cover_art.dart`:

```
cover_art_{context}_{entityId-or-coverArtId}
```

Contexts include: `album_grid`, `album_detail`, `now_playing`, `mini_player`.

### Desktop audio

`JustAudioMediaKit` is initialized in `main.dart` for Linux/Windows/macOS. On macOS in **debug** mode, media_kit init is skipped to keep hot-restart stable — override with `--dart-define=NAVIS_ENABLE_MEDIA_KIT_DEBUG=true`.

---

## 8. Code generation

After changes to Freezed models, JSON models, or Drift tables/DAOs:

```bash
make gen
```

Rules:

- Commit generated `*.freezed.dart`, `*.g.dart`, `navis_database.g.dart` in the **same change**.
- API models: Freezed + `@JsonSerializable` in `lib/src/api/models/`
- Domain models: Freezed only (no JSON)
- Database: `@DriftDatabase` + table/DAO classes in `lib/src/database/`

---

## 9. Testing

### Helpers (`test/helpers/`)

| Helper | File | Purpose |
|--------|------|---------|
| `createTestDatabase()` | `test_database.dart` | In-memory Drift database |
| `withTestDatabase()` | `test_database.dart` | Provider overrides with test DB |
| `setAdaptiveTestViewport()` | `adaptive_test_harness.dart` | Deterministic viewport for widget tests |
| `sqliteAvailable` | `test_database.dart` | Skip DB tests when native SQLite missing |

**There is no `AdaptiveTestHarness` widget.** Older docs referencing it are wrong — use `setAdaptiveTestViewport(tester, Size(...))`.

### Conventions

- Mirror `lib/src/` under `test/src/`
- Mock via `ProviderContainer` overrides — no service locator pattern
- Migration tests run separately in `check.sh` before the full suite

### When to add tests

- Repositories, migrations, provider state transitions, playback resolver logic
- Router behavior when touching `app_router.dart`
- Skip trivial "widget renders" tests unless requested

---

## 10. Coding conventions

Distilled from `DEVELOPMENT_PLAN.md` § AI Agent Development Guidelines:

1. **No placeholder code** — no `TODO: Implement`, no `UnimplementedError`. Hide unimplemented UI entry points instead.
2. **No emoji** in code, comments, commits, or UI strings.
3. **Minimal comments** — only non-obvious logic or workarounds.
4. **Feature-first MVVM** — no business logic in widgets; no API calls outside repositories; no DB access outside DAOs.
5. **Handle all `AsyncValue` states** — loading (skeleton/shimmer), error (with retry), data.
6. **`const` everywhere** possible; `dart format` (80 cols); trailing commas on multi-line lists.
7. **Reuse `common_widgets/`** before creating new widgets.
8. **User-facing copy** — concise, direct, human. No cheerleading ("Oops!", "Let's get started!").
9. **Changelog** — user-visible changes need entries in both `changelog_data.dart` and `tool/generate_release_notes.dart`.
10. **Secrets** — never commit credentials; use `tool/release.env` (gitignored) and `flutter_secure_storage`.
11. **Scope discipline** — smallest correct diff; no drive-by refactors.
12. **Commits** — Conventional Commits (`fix(#N):`, `feat:`, etc.); only commit when the user asks.
13. **No stray markdown** — do not create reports, summaries, or scratch docs.

---

## 11. Build-time configuration

Set via `--dart-define` or in `tool/release.env` (gitignored; see `tool/release.env.example`):

| Define | Purpose |
|--------|---------|
| `NAVIS_LASTFM_API_KEY` | Last.fm integration |
| `NAVIS_UPDATE_CHANNEL` | `stable` or `dev` (`dev_app.sh` pins `dev`) |
| `NAVIS_ENABLE_MEDIA_KIT_DEBUG` | Force media_kit on macOS debug builds |
| `NAVIS_APP_ID_SUFFIX` | Dev sidecar app ID suffix (default `.dev`) |
| `NAVIS_APP_NAME` | Dev sidecar display name (default `Navis Dev`) |

---

## 12. Issue tracking (Forgejo)

Repository: `https://git.porthorion.com/khalifa/Navis`

**Do not use `gh` CLI.** Use the Forgejo REST API with the token from `~/.git-credentials`:

```bash
TOKEN=$(grep porthorion ~/.git-credentials | sed 's|.*:\(.*\)@.*|\1|')

# List open issues
curl -s "https://git.porthorion.com/api/v1/repos/khalifa/Navis/issues?state=open&type=issues&limit=50" \
  | python3 -c "import sys,json; [print(f'#{i[\"number\"]}: {i[\"title\"]}') for i in json.load(sys.stdin)]"

# Add comment to issue N
curl -s -X POST "https://git.porthorion.com/api/v1/repos/khalifa/Navis/issues/N/comments" \
  -H "Authorization: token $TOKEN" -H "Content-Type: application/json" \
  -d '{"body":"..."}'

# Close issue N
curl -s -X PATCH "https://git.porthorion.com/api/v1/repos/khalifa/Navis/issues/N" \
  -H "Authorization: token $TOKEN" -H "Content-Type: application/json" \
  -d '{"state":"closed"}'
```

Commits reference issues as `fix(#N):` or `(issue #N)`.

---

## 13. Platform-specific notes

| Platform | Notes |
|----------|-------|
| **macOS debug** | `just_audio_media_kit` skipped unless `NAVIS_ENABLE_MEDIA_KIT_DEBUG=true` |
| **macOS release** | Native Control Centre bridge (`MPRemoteCommandCenter`) still pending |
| **Linux** | MPRIS via the app-owned `dbus` bridge |
| **Windows** | SMTC via `smtc_windows` |
| **Android** | `audio_service` media session; Android Auto in `features/auto/` |
| **iOS** | CarPlay and media-session parity under audit |
| **Listen Together** | Retired; no active UI files remain and no Voyage sibling repo is required |

---

## 14. Anti-patterns (hard failures)

Agents must avoid:

- `NavisDatabase()` outside provider DI
- Mutating providers during widget `build` (`ref.read(...notifier).state = ...` in build methods)
- Watching full `serverConfigProvider` in `appRouterProvider`
- Breaking playback resolver priority (permanent → rolling → stream)
- Schema change without migration + migration test update
- User-visible change without changelog entries in both changelog files
- Architecture or tooling change without updating `AGENTS.md`
- Creating extra markdown files instead of updating existing docs

---

## 15. Documentation index

| Doc | Use for | Known gaps |
|-----|---------|------------|
| `docs/architecture.md` | Provider inventory, UI organization | `library_providers.dart` listed as "planned" but does not exist; `app_providers` import rule oversimplified |
| `docs/development-workflow.md` | Local dev, pre-commit hook setup | |
| `docs/ci-cd.md` | Release flow | Omits migration/critical test suites |
| `docs/troubleshooting.md` | Runtime issues, codec matrix | |
| `docs/dev-testing-builds.md` | Dev sidecar app | |
| `docs/android-auto-testing.md` | Android Auto QA | |
| `docs/release-*.md` | Platform release guides | |
| `DEVELOPMENT_PLAN.md` | Roadmap only | Claims `@riverpod` codegen; mobile-only intro; verify against code |
| `PROGRESS.md` | Task checkboxes | Update with date + evidence when completing work |

---

## 16. Related agent files

These exist but may be stale. **`AGENTS.md` supersedes them:**

| File | Known staleness |
|------|-----------------|
| `CLAUDE.md` | Schema v36 (actual: v52); breakpoints 550dp (actual: 600dp); references `AdaptiveTestHarness` |
| `.github/copilot-instructions.md` | Schema v40 (actual: v52) |

When you find stale information in any doc, fix it in the same change or flag it here.
