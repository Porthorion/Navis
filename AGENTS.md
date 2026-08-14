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
4. Define runtime acceptance and regression scenarios before editing. Reproduce
   an existing bug through the running app when applicable.
5. Implement the smallest vertical slice with focused automated tests.
6. Complete the mandatory runtime validation loop below for any change that
   can affect app behavior.
7. Run `./tool/check.sh` before considering work done.
8. Update docs per the checklist above.

### Mandatory runtime validation loop

Static analysis and automated tests are necessary but are not sufficient for a
runtime-affecting change. Repeat this loop until the implementation is complete:

1. Use the relevant focused diagnostics script when one exists. Otherwise
   launch Navis on the current system with an isolated test profile; Linux is
   the default target for platform-neutral work.
2. Confirm startup through the authenticated app API health endpoint, then use
   existing feature endpoints. If required control or observation is missing,
   add a narrow endpoint, contract tests, and a focused script before testing.
3. Drive the acceptance scenario through the app API and assert the response,
   observable state, persisted effects, logs, and absence of new errors. An
   **app API** is a control or observation surface executed by the running
   Navis process. Direct database edits, process-exists checks, or calls that
   bypass production providers/controllers do not qualify.
4. For every visible Flutter change, capture the meaningful state through
   `POST /v1/presentation/screenshot`, open the PNG with image-viewing
   capability, inspect the affected region, and record the result. File
   existence alone is not visual confirmation.
5. Add deterministic widget coverage for behavior and semantics. Add component
   goldens for stable shared, adaptive, layout, clipping, painting, or color
   contracts; do not use live-data full-screen goldens.
6. Fix every implementation, regression, visual, or observability gap, then
   restart from an isolated state and repeat.
7. After focused iterations pass, run `./tool/check.sh`, relaunch cleanly, and
   repeat the final acceptance and relevant regression scenarios.

The evidence order above is mandatory. AT-SPI, accessibility D-Bus traversal,
Dogtail, xdotool, wmctrl, OCR/window scraping, and similar external desktop
automation are not Navis app APIs and must not be used as substitutes. Do not
enable accessibility services, override `NO_AT_BRIDGE`, or alter the desktop
session. AT-SPI is allowed only when the task explicitly tests the platform
accessibility bridge and the user authorizes it. **App-owned semantics** means
values returned by the authenticated diagnostics API or asserted in Flutter
widget tests, never the live accessibility tree.

Target selection:

- Platform-neutral behavior requires Linux runtime validation.
- Platform-specific behavior requires a Linux startup smoke test plus runtime
  validation through the affected platform or its authoritative service API.
- If the required platform is unavailable, report the work as unverified or
  blocked. Do not claim completion unless the user explicitly accepts deferred
  platform validation.

Documentation-only changes and metadata changes proven not to affect runtime
behavior are exempt from launching the app. See `docs/development-workflow.md`
for the detailed cross-platform procedure and API safety contract.

**Blocker protocol:** if blocked for more than ~30 minutes, record in `PROGRESS.md`: what is blocked, what was tried, exact error, proposed next action. Do not silently skip tasks.

**Task done criteria:** implementation wired into the production app path;
relevant tests added or updated; the runtime loop completed with a clean
restart when the change can affect runtime; `./tool/check.sh` passes; docs
updated; and `PROGRESS.md` updated when applicable. For runtime-affecting work,
final handoff or progress evidence must name the runtime target and isolated
profile mode, scenarios exercised, app or native service APIs used, observed
results and log review, visual/semantics evidence when relevant, retest
iterations, final quality-gate result, and clean-restart result. Visible changes
must identify each inspected app-owned screenshot. Never record credentials,
bearer tokens, private server URLs, cloned user data, or unredacted screenshots.

---

## 3. Commands and quality gates

```bash
# Bootstrap (Flutter ≥ 3.44, pub get)
./tool/bootstrap.sh          # or: make bootstrap

# Code generation (after Freezed / Drift / JSON model changes)
make gen                     # dart run build_runner build
make gen-watch               # watch mode

# Branding (canonical SVG -> runtime/platform raster assets)
./tool/generate_platform_icons.sh  # requires ImageMagick

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
./tool/dev_app.sh linux-icon  # refresh content-addressed desktop icon/cache
./tool/dev_app.sh auto       # Android Auto
./tool/dev_app.sh dhu        # Desktop Head Unit
./tool/verify_android_auto_manifest.sh  # Android Auto manifest/APK contract
./tool/sync_diagnostics.sh clone  # isolated Linux profile sync/API suite
./tool/sync_diagnostics.sh throughput  # isolated single-repair throughput sample
./tool/sync_diagnostics.sh full-rescan  # isolated live-scale Repair Library trace + preparing-state capture
./tool/sync_diagnostics.sh cache-alias  # isolated live cache/identity migration probe
./tool/sync_diagnostics.sh primary-certification  # backed-up final live check
./tool/sync_target_lane_diagnostics.sh  # isolated Home↔Library, target/catalog boundary, and durable schedule/cooldown Settings suite
./tool/manual_discovery_diagnostics.sh  # isolated offline-reconnect unchanged-indexes new-album check
NAVIS_MANUAL_DISCOVERY_OMIT_EXISTING=1 NAVIS_MANUAL_DISCOVERY_FORCE_MANUAL_RESUME=1 ./tool/manual_discovery_diagnostics.sh  # partial artist response must retain existing offline albums
./tool/repair_confirmation_diagnostics.sh  # isolated explicit large-deletion repair gate
./tool/volume_memory_diagnostics.sh  # isolated desktop-volume restart suite
./tool/playback_indicator_diagnostics.sh clone  # isolated song-indicator suite
./tool/presentation_diagnostics.sh clone / home  # app-owned screenshot suite
NAVIS_DIAGNOSTICS_AUDIO_BOOTSTRAP_FAIL_ATTEMPTS=2 ./tool/presentation_diagnostics.sh clone / bootstrap-retry  # startup retry + loading screenshot suite
NAVIS_PRESENTATION_SEARCH_QUERY='query' ./tool/presentation_diagnostics.sh clone /search search  # Search ordering + screenshot
NAVIS_PRESENTATION_SEARCH_QUERY='unmatched-query' NAVIS_PRESENTATION_FORCE_SEARCH_REMOTE_FAILURE=1 ./tool/presentation_diagnostics.sh clone /search search-failure  # clone-only Search failure-state screenshot
./tool/desktop_layout_diagnostics.sh  # Desktop View/Mini Player resize + screenshot suite
./tool/auth_lifecycle_diagnostics.sh clone  # isolated first-sync/logout suite

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
| Android scheduling | androidx.work:work-runtime-ktx | 2.11.2 |

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
- Playback bootstrap keeps the loading gate visible during failures and retries every three seconds until ready. Timeout and stale/late completion guards remain active; clone diagnostics may inject initial failures only through `NAVIS_DIAGNOSTICS_AUDIO_BOOTSTRAP_FAIL_ATTEMPTS` and observe safe attempt state through `GET /v1/playback/bootstrap/status`.

### Provider organization (`lib/src/providers/app_providers.dart`)

- **Composition root** (~2700 lines): database, API clients, audio, cache, cross-feature wiring.
- `app_providers.dart` **does** import feature modules for DI wiring. This is intentional.
- Feature providers live in `lib/src/features/<name>/presentation/*_provider.dart`.
- Avoid **circular** feature↔feature imports.
- **Never** instantiate `NavisDatabase` outside Riverpod (hard-fail in tests).
- Async client callbacks must capture stable dependencies rather than a
  provider `Ref`; network changes may dispose an API client while its response
  accounting is still completing.

### Playback data flow

```
User action → queueProvider (QueueController)
  → NavisAudioHandler
  → PlaybackSourceResolver
      permanent cache → rolling lock-cache → direct stream
  → playbackSnapshotProvider → UI
```

Source resolution priority: **Permanent cache** → **Rolling cache (LRU lock-cache)** → **Stream**

Desktop playback volume is local to each installation. `PlaybackVolumeController`
applies live changes to the audio handler, coalesces slider persistence, and
stores the current and last-audible levels in `app_settings`. Audio bootstrap
hydrates and applies that level before queue restoration. Mobile volume remains
session-only, and transient ducking, ReplayGain, crossfade, and sleep-timer
fades must never overwrite the remembered desktop level.

Native desktop playback on Linux, Windows, and macOS uses direct HTTPS for the
active deck (Range-seekable under media_kit) plus a sidecar rolling-cache
download to the quality-keyed cache path. Mobile keeps single-pass
`LockCachingAudioSource`. Ordinary direct HTTPS playback bypasses just_audio's
request-header proxy on desktop. Completed sidecar files remain the
authoritative cache byte/count totals, while `rollingCacheActivityProvider`
exposes an active write before registration finishes.

`PlaybackSnapshot` is a structural stream: track, queue, playing/processing,
duration, repeat/shuffle, loading, and liked changes are broadcast, but routine
position/buffer ticks only update the handler's current snapshot. Timeline UI
and desktop media bridges must consume `positionStream`; seek bars consume the
track-keyed `bufferStateStream` so late buffer events cannot leak onto a new
song. Known song metadata is authoritative for timeline duration, especially
while transcoded decoder duration is still growing. Windows SMTC coalesces
normal timeline writes to roughly once per second, while track changes and seek
discontinuities update immediately.

Song rows derive their shared `inactive`, `current`, or `loading` presentation
from `song_playback_indicator.dart`. While switching, `loadingSongId` is the
effective selected song; otherwise `currentSongId` remains selected even when
paused. Exact-song lists match by ID, while queue views prefer `currentIndex`
so duplicate IDs highlight only the active occurrence.

Android Auto is phone projection through the Android `MediaBrowserService`,
not an app UI rendered on the head unit. The manifest must register the
canonical `com.ryanheise.audioservice.AudioService` component because the
plugin binds and starts that exact class during playback initialization. The
service exposes the handler-owned `AutoMediaTreeService`. Keep the root at four
browsable tabs (`Liked`, `Recent`, `Playlists`, `Library`). `Liked` owns quick-play
actions and liked songs/albums; `Library` owns optional Downloads plus Albums,
Artists, and Genres. Song browse IDs may carry album, playlist, liked, recent,
download, or genre context, but persisted and transport queue IDs remain raw
Subsonic song IDs. Projected search must put songs and playlists first and
fall back to the local database within the Android for Cars 10-second
content-load limit.

Queue replacement is two-phase for album-style queues: phase 1 prepares only
the tapped song in the transport queue so playback starts quickly; phase 2
fills the remaining audio sources. During phase 2, `PlaybackSnapshot.queueSongIds`
may expose a pending logical queue so the UI can show the full requested order
before every transport item is prepared. Queue mutation UI must treat
`PlaybackSnapshot.hasPendingLogicalQueue` as read-only/loading state.

Transport intent is user-prioritized. Play and pause do not wait behind queue
fill or seek-recovery work; seeks are last-write-wins, and newer seeks, skips,
selections, or pauses invalidate stale recovery/autoplay. Position persistence
runs through a coalescing background scheduler after the transport effect.
On mobile, lock-cache seek recovery loads the active song as a direct stream at
the requested position, then restores the logical queue in cancellable
background phase-2 batches, without permanently bypassing later lock-cache
plays. Desktop seeks use the direct HTTPS source and skip that recovery path.
Keep `loadingSongId` visible as soon as selection begins.

The secondary audio deck is lazy. Create and synchronize it only while
crossfade is enabled; disabling crossfade must cancel the transition and
dispose the inactive deck. A clone of a lock-cached source must be a direct
stream on the inactive deck; two `LockCachingAudioSource` instances cannot own
the same `.part` path.

Startup cache maintenance must finish before queue restoration or external
media-session Play requests can create lock-cache partial files. Concurrent
empty-queue Play requests share one fallback queue preparation so they cannot
supersede each other.

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

- `LibrarySyncPlanner` selects among `probe`, `targetedHydration`,
  `deltaReconcile`, `catalogSnapshot`, `compatibilityAudit`, and `fullRepair`.
  Callers submit a `LibrarySyncRequest`; they must not choose an execution scope.
- `AdaptiveLibrarySyncCoordinator` is the single run/retry owner. Durable work
  and provider profiles live in `library_sync_state` / `library_sync_work` via
  `LibrarySyncDao`. Interrupted running work returns to the queue on startup;
  terminal work remains terminal until an explicit user request reactivates it.
  Targeted work keys include the target kind so same-ID artists, albums, and
  playlists cannot collide, but executor/API calls must receive the raw entity
  ID without that durable-key prefix. Once a catalog candidate is promoted,
  its broad task is completed in the same promotion transaction; any
  unavailable albums continue as targeted hydration. A restart after promotion
  must never replay the broad repair while auxiliary work is still finishing.
- Durable work transitions are explicit: completed, cancelled, failed, and
  awaiting-confirmation rows are not runnable. Only an explicit compatible
  user action may reactivate a terminal row; cancellation must never fall
  through to the next automatic lifecycle pass.
- Complete catalog snapshots collect into generation-keyed candidate artist,
  album, and song tables that app providers never watch. Page checkpoints and
  pending hydration survive cancellation or restart, while the previously
  committed catalog remains the only visible library. Only a fully validated
  candidate may be promoted in one database transaction; that transaction
  applies identity aliases before cleanup, preserves playback/download/cache
  dependencies, advances `currentGeneration`, and removes unseen rows.
  Fresh candidates must discard page checkpoints from an abandoned reuse of
  the same generation, and checkpoint counts must match collected candidate
  rows before promotion. A snapshot with reported albums but no collected
  albums is invalid and must preserve the committed catalog.
  Full collection prefers `getArtists`; if that endpoint is unsupported, use
  the compatible `getIndexes` artist index before failing the candidate.
  Large candidate promotion reads must chunk ID lookups below SQLite's bound
  variable limit. An `applying` candidate is resumable after a rolled-back
  apply failure so completed hydration is not downloaded again.
  Deletion analysis runs only after candidate song collection and safe
  carry-forward; tracks for a candidate album still awaiting authoritative
  detail hydration are not stale-song deletion evidence.
- Before promotion, schema-v57 candidate rows are classified in resumable
  keyset pages as changed or unchanged. The final transaction upserts only
  changed rows once, streams deletion anti-joins, and emits one catalog change;
  never restore whole-catalog materialization or the duplicate song upsert.
  Candidate analysis yields between pages and reduces its page size during
  playback or slow database responses. Cache-file unlinking happens after the
  database commit so filesystem latency cannot extend the visibility switch.
  A foreground full-catalog candidate starts its album-detail fallback at
  eight concurrent requests and ramps to 24 on Wi-Fi when idle. While audio is
  active, an explicit Repair Library remains bounded but uses four to eight
  Wi-Fi requests so its final fallback cannot collapse to the ordinary
  two-request interactive cap; ordinary background and interactive hydration
  remain capped at their smaller platform limits and back off only after
  transport retries.
  Its empty-query `search3` bulk-song pagination must advance by the returned count and
  continue after short pages: compatible servers may silently cap the requested
  page size, and stopping on that cap would incorrectly trigger the slow
  per-album fallback. After a completed bulk index, a capped stable tail may
  carry forward locally verified songs before detail fallback only when the
  candidate's core album metadata and expected song count exactly match; new,
  changed, incomplete, or unverified albums must still use `getAlbum`.
- Song-hydration progress is durable: it advances only after an album's songs
  are written and the album is marked hydrated. Catalog/metadata stages use an
  indeterminate activity indicator because their page totals are estimates,
  not one continuous percentage.
- Native database access uses WAL with one Drift read-pool connection so app
  queries do not queue behind candidate-catalog writes. Keep one
  `NavisDatabase` in Riverpod; its pooled reader and writer remain internal to
  that instance.
- `catalogGeneration` on canonical rows is the last generation that changed
  that row. `library_sync_state.currentGeneration` is the authoritative
  committed-catalog generation; unchanged rows are not rewritten to advance
  their marker.
- Local star and rating mutations are journaled while a candidate is being
  collected. Promotion and starred reconciliation preserve those newer local
  values, including across candidate restarts and the final apply transaction,
  and pending star queue actions always win over an older server snapshot.
  A star missing from one successful `getStarred2` response is an absence
  candidate, not an immediate unstar: only a second independent successful
  absence may clear it. A returned star or pending/concurrent local mutation
  clears the candidate.
- Interactive artist, album, and playlist hydration is deduplicated and
  high-priority. Album hydration normally uses one request and one transaction;
  song-bearing targets still run conservative identity reconciliation so
  cached remote songs auto-merge without invalidating playback or cache
  ownership.
- Liked content and playlist headers are explicit auxiliary targets. Server
  liked-state reconciliation must exclude pending local star/unstar actions.
  Playlist header upserts must be non-destructive: preserve unchanged cached
  memberships, prune only IDs absent from the authoritative header list, and
  enqueue new or changed playlist contents as durable targeted hydration.
- Automatic library sync is **low-data by default** after initial sync.
- Android automatic sync is scheduled through one WorkManager periodic request
  per opaque profile key, not the foreground timer. It uses `UPDATE`, an
  unmetered or connected constraint matching the durable policy, and a
  separate `KEEP` catch-up request. Its headless Dart entrypoint runs the same
  planner/coordinator with `androidWorker` execution ownership; it must never
  bootstrap UI, audio, playback, notifications, or diagnostics. The
  `library_sync_execution_lease` serializes the headless engine with the
  foreground controller, while redacted WorkManager observations remain on
  `library_sync_state`. The durable Android-only capability flag defaults off
  and is enabled for internal builds only with
  `NAVIS_ENABLE_ANDROID_BACKGROUND_SYNC=true`. A worker validates its opaque
  profile key against the active profile before any request, so a late
  cancelled/replaced schedule cannot run the new account. Manual-only and
  logout reconciliation clear the persisted requested cadence; relevant
  enable/network/interval changes use the separate `KEEP` catch-up request.
- Automatic broad catalog work defers while Navis is backgrounded or playing;
  an explicit user refresh may resume queued broad work in the foreground so a
  requested refresh is not silently postponed behind it.
  A queued `fullRepair` is user-owned and must not resume from startup,
  reconnect, resume, or periodic automation; only an explicit Repair Library
  action may resume it.
- `LibrarySyncController` coalesces overlapping app-level sync requests and
  returns their final shared result. Never treat an in-flight state as a
  terminal failure. Startup/periodic work must wait for the credential-backed
  engine to become available rather than publishing a transient unavailable
  engine as metadata-sync failure; an explicit user retry may report a real
  unavailable engine. Pending durable hydration resumes on the configured
  automatic interval or an explicit user action; never add a short forced
  continuation loop. Never route away from a ready session for ordinary sync
  completion. Confirmed missing detail entities remain on their route with a
  user-controlled return to Library.
- A failed automatic sync remains failed until the next configured sync
  interval, a reconnect, or an explicit manual retry. Do not add short forced
  retry loops that repeatedly restart the same failing metadata pass.
- Isolate non-fatal artist and album endpoint failures. Commit usable entities,
  keep only unfinished IDs pending, and continue them in bounded foreground
  passes. Authentication, authorization, database, and invariant failures still
  fail the pass. Persist only safe diagnostics (stage, endpoint, entity ID,
  exception type, attempts), never exception messages or credentials.
- Do not reintroduce periodic/daily full rebaseline scans from `syncIfStale()`.
  Full library repair belongs behind explicit Repair Library or a dedicated
  sync-model migration gate.
- Incremental sync uses the server-provided `getIndexes.lastModified` cursor.
  Local completion time is only for scheduling/UI; do not advance the server
  cursor until every candidate in the response has been verified and its album
  hydration has completed.
- An explicit Check for updates is a bounded delta/discovery operation, not an
  automatic freshness-gated probe. It must inspect the first five newest-album
  pages (500 entries) even when `getIndexes` is unchanged, then commit, defer,
  or fail discovered work
  before reporting success. An offline manual check must retain that delta work
  for eligible resume rather than downgrade it to an indexes-only probe; on a
  metered network, broad discovery requires the explicit one-time mobile-data
  override and the ordinary action remains a cheap probe.
- Long-lived library engines must read live network policy from the root
  `ProviderContainer`, not their construction `Ref`: provider-local reads can
  retain the first offline policy across reconnect. Keep the engine/coordinator
  stable while policy changes; do not watch connectivity merely to rebuild it.
- Normalize protocol field names at the API boundary before models enter sync
  logic. In particular, the standard `getArtist` response uses singular
  `artist.album`; Navis's `Artist.albums` model must receive that normalized
  list so existing-artist album discovery can schedule authoritative hydration.
- A returned index is a gated artist snapshot, not a changed-artist feed.
  Persist continuation state and drain it in bounded passes (48 artists on
  non-cellular networks, 24 for a manual cellular refresh). Non-cellular
  continuation passes run quietly while the app remains foregrounded.
- When a newer server cursor arrives during a pending artist audit, prioritize
  newly reported/suspicious artists, preserve the untouched tail, and move
  already-verified artists behind it. A fresh local completion timestamp must
  not suppress persisted pending verification.
- Run the bounded newest-album health probe every 12 hours. Every explicit
  refresh must scan its five-page discovery window regardless of the reliable `getIndexes`
  cursor, stage its discrepant on-server albums for normal song hydration and
  identity/cache reconciliation, and must not wait for the
  rotating artist audit to reach their artist. Servers with unsupported or
  unreliable indexes use bounded artist/newest-album verification on normal
  non-cellular syncs and retry `getIndexes` daily.
- Starred content and playlist headers use the 12-hour auxiliary window.
  Genres refresh after catalog changes/repair or every seven days; playlist
  contents hydrate on interaction. Do not fetch auxiliary domains on every
  hourly no-op catalog probe.
- App version/build changes do not imply a full resync. Use
  `requiredLibrarySyncModelVersionProvider` only when a storage/sync contract
  change truly requires a one-time repair. Sync model `56` is the current
  one-time gate for the schema-v56 candidate-catalog contract; a promoted
  catalog records the gate even when unavailable albums remain queued for
  targeted hydration.
- Search, recommendation, instant-mix, and queue metadata is provisional until
  authoritative sync confirms it. Keep provisional parents out of normal
  browsing and reconcile song IDs only by same ID, one unique recording MBID,
  or one unique exact metadata match with compatible track/disc and duration
  within three seconds. Ambiguous matches must remain local.
- User-facing Navis Search deduplicates local and `search3` results by ID, then
  orders each entity type by relevance tier, on-server before external within
  a tier, and original stable order. Keep this presentation policy out of the
  shared API client and non-presentation matching workflows. An exact remote
  match must still outrank a weaker on-server match.
- External-catalog provenance is separate from provisional lifecycle state.
  API `isExternal` values are authoritative; only absent values may fall back
  to the observed `ext-*`, `remote-*`, and `pl-deezer-*` ID families. Persist
  provenance in `artists.is_external`, `albums.is_external`, and
  `songs.is_external`; never infer it from cover-art IDs, cache/download state,
  local indexing, or `is_provisional`. Broad catalog candidates exclude
  external entries. Exact external artist/album hydration remains provisional
  and may expose provisional children on that detail page, while ordinary
  library browsing continues to hide them. Canonical catalog writes always
  clear `is_external`, so an item imported into the server library loses its
  remote-source marker. Remote provenance is informational: grids use a
  neutral artwork pill, dense rows and players use an inline label, and detail
  screens use a metadata chip. On-server items remain unlabeled, Remote plus
  Downloaded/Cached states are shown independently, and Hero artwork excludes
  the source indicator. Every song-list implementation, including Home,
  ListenBrainz weekly recommendations, liked songs, artist top tracks, Match
  Flow, queues, and downloads, must hide the artwork overlay and compose its
  subtitle with `RemoteSourceMetadataLine`. Metadata truncates before the
  fixed-width indicator; adding provenance must not change row height or
  leading/trailing alignment. Shared track and weekly rows keep a 64 dp
  minimum height for local/remote parity. Keep each Remote indicator's one
  stable semantics node in the normal render tree. Its explanatory desktop
  hover label uses a visual-only `OverlayEntry`, excluded from semantics;
  do not wrap Remote indicators in Material `Tooltip`/`RawTooltip` because
  Flutter 3.44 `OverlayPortal` semantics reparenting can retain stale attached
  children during repeated show/hide cycles.
- Apply proven song-ID aliases to the audio handler before deleting the
  provisional row. Preserve an active losing cache file, resolve late cache
  completions through persisted aliases, and replay aliases during audio
  bootstrap so synchronization cannot invalidate the active remote source.
- A detail 404 or an album omitted by one artist-detail response is only a
  deletion candidate. Incremental artist reconciliation may add/update but
  must never delete catalog rows; a complete catalog snapshot must confirm
  removal. Deletion sets over 10% of an entity type or 500 songs require the
  same remote fingerprint twice before removal. The
  pending fingerprint/count is durable, shown in Sync Settings, and must be
  explicitly confirmed there before the follow-up Repair Library action can
  apply it.
- Transport may perform at most one immediate retry (including `Retry-After`).
  Later attempts belong to durable work with a 15-minute exponential cooldown,
  a six-hour cap, and an endpoint circuit after three consecutive failures.
- Cellular automation is limited to a hard conditional `getIndexes` probe
  (one request, retries disabled) plus urgent interactive targeted hydration.
  Catalog enumeration, audits, repairs, starred/genres/playlist-header sync,
  and pending broad hydration remain queued for an unmetered network unless the
  user grants an ephemeral one-time mobile-data override. Metered Wi-Fi follows
  the same policy when native metering reports the link as metered. An explicit
  foreground Check for updates is narrower than that override: it may inspect
  one 50-album newest page and hydrate at most three changed albums, with no
  artist sweep or bulk-song index; remaining work stays durable for Wi-Fi or
  the explicit broad-data action.
- Durable work carries a `work_class` of `interactive` or `background`. User-
  opened artist/album/playlist targets upgrade to interactive; engine catalog
  page checkpoints and pending-album drains stay background. Live
  `SyncNetworkPolicy` is re-checked at execution boundaries; an unmetered-to-
  metered transition checkpoints and returns `deferred` without failing the
  work.
- Interactive metered hydration is capped at 16 MiB per response and 32 MiB
  per interaction. Budget exhaustion defers the durable work and does not count
  as an endpoint failure.
- Default setting **Background sync only on unmetered networks** is enabled.
  Sync Settings surfaces updates-available messaging and a one-time
  **Sync using mobile data** action.
- Home discovery polls the startup sync gate and refreshes through the
  completion bridge; it does not subscribe its stream to sync progress. Do not
  add redundant direct sync watches around the derived ListenBrainz discovery
  stream; a large repair can otherwise invalidate the root provider scope
  during `HomeScreen.build`.

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
- `SessionRoutePhase` tracks loading, unauthenticated, initial-sync-required,
  or ready. First-time catalog collection runs from the normal shell: a newly
  authenticated profile lands on Home immediately and exposes the same sync
  status/retry UI while its first candidate is collected.
- **No top-level `/now-playing` route** — player is embedded in the shell.
- `appRouterProvider` keeps one `GoRouter` instance and refreshes its
  auth/first-sync redirects through a `ValueNotifier`. Do not watch a
  timestamp-bearing config provider in its construction: sync completion may
  briefly re-evaluate session readiness, but must never recreate the router or
  reset the current location.
- `NavService` (`navigation_service.dart`) for app-level navigation.
- Album detail navigation may carry the tapped source's Hero tag in
  `GoRouterState.extra`. Album-card sources must pass that exact tag through
  `NavService.openAlbumDetail(..., heroTag: ...)`; the detail screen must use
  it instead of regenerating a generic tag. Deep links and non-art entry
  points intentionally omit it and use the calm route-only fallback.
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
| `compactDesktop` | 800–1007 dp |
| `standardDesktop` | 1008–1599 dp |
| `ultraWideDesktop` | ≥ 1600 dp |

Desktop runtime never falls back to the phone bottom-navigation, tablet rail,
or compact-landscape shells. Desktop View requires 800×600 logical pixels and
always reserves its full-width bottom player, including the localized empty
state with an operable volume control. That 116 px player keeps Favorite,
Lyrics, Queue, and Mini Player directly visible in a fixed four-action row at
every valid Desktop width; its volume row stays directly below. Invalid
playback actions retain their 44 px slots with reason-specific disabled
semantics instead of disappearing. The same-window Mini Player defaults to
720×405 on every entry and may then be manually resized down to the enforced
560×360 logical minimum. Mini Player persistence retains its screen position,
not an arbitrary prior size. Its tight composition is selected from both usable
width and height, centers metadata, and constrains its content canvas; volume
sits below transport/actions and expands across the available metadata pane. If
a window manager reports a smaller size, Navis blocks the invalid player and
restores 720×405 bounds at the retained position.
Mini Player window actions are compact transparent floating icons at the
top-right edge, deliberately above rather than over the metadata pane. Hide them whenever
an embedded Queue, Lyrics, or settings panel is active so they cannot intercept
that panel's controls; use a short opacity transition rather than a hard
appearance/disappearance, and keep hover feedback on the icon glyph without a
background fill. Compact Queue panels keep themselves mounted until their
reverse slide/fade completes, so close, Back, and swipe dismissals are as smooth
as opening. The default 720×405 entry retains the rich Mini Player
composition; use the tight layout only below its usable size threshold.
Always-on-top is available only where the platform can honour it. Linux Wayland
deliberately disables it with an explanation because the compositor owns
normal-window stacking; retain the stored preference for a later supported
session such as Windows or X11.
Crossing the 800×600 boundary is mediated by `DesktopWindowController`; it snapshots
valid Desktop bounds in `window_state.json` v3, always starts the app in
Desktop View with those bounds (including after a Mini Player shutdown),
restores maximized Desktop state, keeps Mini position separately, and uses `screen_retriever` work areas
to keep windows visible. Bounds reported after Desktop has already crossed its
minimum must never replace the last valid Desktop restoration target.
`desktop_layout_diagnostics.sh` closes one pass in Mini Player and asserts the
clean restart returns to the preceding 800×600 Desktop View.
Resize-transition gates must remain height-aware and keep both decisions
reachable at the 560×360 OS minimum; use a scroll fallback for text scaling or
native frame reductions instead of allowing a gate to overflow.

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
| **Schema version** | 65 |
| **Tables** | 31 |
| **DAOs** | 16 |

DAOs: `AppSettingsDao`, `ServerDao`, `LibraryDao`, `LibrarySyncDao`, `LibrarySyncCandidateDao`, `SongIdentityDao`, `PlaylistDao`, `CacheDao`, `DownloadQueueDao`, `HistoryDao`, `PlayQueueDao`, `MatchFlowDao`, `ScrobbleDao`, `StarSyncDao`, `ListenBrainzFeedbackDao`, `NetworkUsageDao`.

- Stepwise migrations in `navis_database.dart`.
- **Always** update `test/src/database/migrations/navis_migration_test.dart` when changing schema.
- Access only through DAOs — no raw SQL in feature code.
- `library_sync_state.next_automatic_check_at` is the per-server automatic
  schedule deadline. It is distinct from `next_eligible_at` (retry/circuit
  cooldown); automatic lifecycle events may only run catalog work when this
  durable deadline is due. The controller must reload `next_eligible_at` as
  `LibrarySyncState.nextRetryAt`, and Sync Settings must show it separately so
  a cooldown never appears to be unexplained background syncing.
- `library_sync_operation_ledger` retains the last 50 safe aggregate catalog
  promotion and confirmed-starred-absence mutations per server. Each entry is
  written in the same transaction as its change and includes only reason,
  timestamp, and before/after/removal counts; never IDs, names, URLs, paths,
  or credentials. Sync Settings reads this durable ledger and shows the newest
  operation that actually removed local rows, so a later no-op check cannot
  erase the user-visible explanation for a disappearance.
- `library_sync_execution_lease` provides one expiring, heartbeat-renewed
  broad-sync owner per server across foreground and Android headless Flutter
  engines. Only the holder may renew or release it. Android schedule and
  worker observations are fields on `library_sync_state`; they contain only
  requested interval, opaque WorkManager ID/state/attempts, timing, and a
  bounded terminal/stop category.
- `server_config.is_authenticated` separates the retained non-secret
  server/account profile from an active credential session. Profile identity
  is normalized base URL plus trimmed username; same-profile login updates the
  row in place, while replacement is an explicit destructive operation.

### Session lifecycle

`SessionLifecycleService` is the only logout path. It is single-flight and
best-effort, but authentication invalidation is always attempted in `finally`.
Teardown closes the Subsonic client, awaits library-sync and download
cancellation, resets both playback decks/radio/media-session state and the
persisted queue, clears transient mix/timer/overlay/error state, then removes
pending server mutations and durable work. Keep-data logout retains the
committed catalog, completed caches/downloads, history, playlists, Match Flows,
sync tuning, and device settings while marking the profile unauthenticated.
Full wipe, initial-sync cancellation, and confirmed profile replacement use
`ServerDataResetService` to remove all server-scoped rows, audio files, and
cover art before deleting the retained profile.

`LibrarySyncController` owns first and subsequent catalog runs from the normal
shell. Unmetered setup starts automatically; offline setup waits for Retry and metered setup requires
the existing one-time mobile-data override. Only an atomically promoted
catalog (`currentGeneration > 0`, with legacy `lastSynced` fallback) unlocks
the shell; non-applying auxiliary/hydration gaps may continue with a warning.
`tool/auth_lifecycle_diagnostics.sh clone` validates this on Linux with two
isolated database/cache profiles, a deterministic loopback Subsonic fixture,
and a mode-600 fixture credential that never touches device secure storage.
Clone diagnostics also replace the external-scrobble credential store with an
empty process-local store and disable Last.fm so they cannot read device tokens
or contact personalized third-party discovery services.

### Hero animation tags

Use `buildCoverArtHeroTag(...)` from `lib/src/common_widgets/hero_cover_art.dart`:

```
cover_art_{context}_{entityId-or-coverArtId}
```

Contexts include: `album_grid`, `album_detail`, `now_playing`, `mini_player`.

Album tags must include the immutable album/entity ID whenever one exists;
cover-art IDs alone can collide. During an album-detail Hero flight,
`HeroCoverArt` keeps the source image size/cache key, shape, and decoded image
path stable. Do not add a destination-specific shuttle or a competing route
slide for Hero-driven album navigation.

### Desktop audio

`JustAudioMediaKit` is initialized in `main.dart` for Linux/Windows/macOS. On macOS in **debug** mode, media_kit init is skipped to keep hot-restart stable — override with `--dart-define=NAVIS_ENABLE_MEDIA_KIT_DEBUG=true`.

Desktop clients restore Navis's per-installation playback volume, including
muted state and the last audible level used by Unmute. Validate this lifecycle
with `./tool/volume_memory_diagnostics.sh`.

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
| **Android** | `audio_service` media session and Android Auto phone projection in `features/auto/`; constrained WorkManager background library sync is internally gated and uses a headless Dart entrypoint; manifest service class must remain the canonical plugin `AudioService` |
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
