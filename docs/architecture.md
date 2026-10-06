# Navis Architecture Documentation

## Provider Organization

Providers in Navis follow a feature-first organization pattern to improve maintainability and reduce coupling.

### Global Infrastructure Providers

Located in `lib/src/providers/app_providers.dart`:

- **Database & Storage**
  - `navisDatabaseProvider` - Singleton NavisDatabase instance
  - `settingsRepositoryProvider` - Settings persistence
  - `appSettingsProvider` - Reactive settings stream
  - `integrationPolicyProvider` - The external-integration policy (see
    "External integration policy"); denies everything until settings load
  - `updateProvider` selects only settings loading, updates service enablement
    and the automatic-check switch. Unrelated settings or integration changes
    do not repeat update checks.

- **Network & Connectivity**
  - `connectivityProvider` - Network connectivity state
  - `networkTypeProvider` - Resolved network type (wifi/cellular/offline)
  - `syncNetworkPolicyProvider` - Metering-aware sync policy (background vs
  interactive vs hard probe eligibility)

- **Android background sync**
  - `androidBackgroundSyncSchedulerProvider` and
    `androidBackgroundSyncReconcilerProvider` own only native WorkManager
    scheduling reconciliation; sync domain logic remains in the library
    planner/coordinator.
  - `navisBackgroundSyncEntrypoint` is a retained, UI-free headless Dart
    entrypoint. It loads the active encrypted credentials and builds only the
    database/API/sync pipeline through `LibrarySyncExecutionBootstrap`, the
    same production bootstrap used by foreground sync. It validates the
    opaque native profile key before any request and holds the same durable
    execution lease as foreground catalog work, so a late worker cannot run a
    replaced account or overlap a visible sync.
  - Its `BackgroundNetworkPolicyTracker` observes connectivity changes and
    refreshes native metering during the pass. The coordinator and engine
    consume that current policy at their existing eligibility gates, so a
    metered transition defers later broad work instead of retaining startup
    Wi-Fi policy.
  - If engine bootstrap fails before Dart can update the database, the worker
    writes a bounded native fallback outcome under its opaque profile key. The
    next foreground reconciliation imports it once into `library_sync_state`;
    raw errors and profile identities never cross that boundary.
  - Android scheduler state is durable and redacted: opaque work identifiers,
    state, attempts, timing, and bounded terminal categories only. Sync
    Settings presents this as requested eventual cadence, never a guaranteed
    next OS execution time. Native schedule, catch-up, and cancellation calls
    resolve only after their WorkManager `Operation` is acknowledged; an
    acknowledgement failure records `platformFailure` without replacing a
    known-good cadence or work ID. Manual-only cancellation clears its
    persisted cadence only after that acknowledgement, while relevant
    enablement/policy changes enqueue one `KEEP` catch-up request.
  - `subsonicApiProvider` - Configured Subsonic API client

- **Audio System**
  - `audioBootstrapControllerProvider` - Audio handler initialization state
  - `audioHandlerProvider` - Active audio handler instance
  - `audioHandlerStateProvider` - Audio handler state controller
  - `playbackSnapshotProvider` - Current playback state stream
  - `playerStateProvider` - Simplified playback state
  - Linux uses the app-owned `LinuxMprisBridge` over `dbus`; Windows uses
    `WindowsSmtcBridge` backed by the local `navis_windows_smtc` Rust/WinRT
    manual-SMTC adapter; Android, iOS, and macOS use `audio_service`
  - Bootstrap retries every three seconds while initialization fails. Its
    startup gate exposes cache-reset and sign-out recovery after ten seconds;
    an unauthenticated user can continue to Login without waiting for audio.
    A teardown supersedes a hung native attempt without awaiting it, and any
    later handler is disposed. If audio remains unavailable after Login, the
    next playback action opens the same non-blocking recovery sheet.
  - Android Auto can invoke Dart before `MainActivity` exists. Navis creates
    the provider container and starts audio bootstrap immediately, while
    `AndroidUiBootstrapGate` defers `SystemChrome`, notification, diagnostics
    UI, and `runApp` work until the first Android `resumed` lifecycle state.

- **Android Auto phone projection**
  - The canonical `com.ryanheise.audioservice.AudioService` is the exported
    native `MediaBrowserService`. The plugin binds and starts that exact
    component during playback bootstrap, then delegates browse requests to the
    shared `NavisAudioHandler`.
  - `AutoMediaTreeService` builds the local database-backed browse tree. Its
    four root tabs are Liked, Recent, Playlists, and Library. Liked exposes
    quick-play actions plus liked songs/albums; Library contains Downloads
    when available, followed by Albums and Artists.
  - Song browse IDs are opaque and retain album, playlist, liked, recent,
    or download context. `NavisAudioHandler` uses that context to build the
    expected collection queue while keeping raw Subsonic IDs in playback and
    persisted queues.
  - Search merges server artists/albums/songs with local playlists, prioritizes
    songs and playlists with exact matches first, times out server work after
    eight seconds, and falls back to local results.
  - `AndroidAutoBrowseNotifier` owns non-null child-change streams for the
    root, recent, and system-recent parents. This replaces deprecated static
    `notifyChildrenChanged` calls whose null options are rejected by AndroidX.
  - `tool/android_auto_cold_start_diagnostics.sh` validates the service-first
    contract from an external MediaBrowser client on a phone emulator before
    the physical-phone DHU projection smoke test.
  - See `docs/android-auto-testing.md` for DHU validation and
    `docs/android_auto_real_car_testing.md` for trusted-store real-car checks.

- **Cache Management**
  - `rollingCacheManagerProvider` - Rolling cache manager
  - `rollingCacheBudgetBytesProvider` - Live cache size budget read for every
    cache write
  - `rollingCacheActivityProvider` - Active single-pass cache write and
    optional progress before completed-file registration
  - `rollingCacheStatsProvider` - Cache statistics
  - `permanentCacheStatsProvider` - Permanent cache statistics
  - `cachedSongIdsProvider` - Set of cached song IDs

### Feature-Specific Providers

#### Player Feature (`lib/src/features/player/presentation/`)

**queue_provider.dart**:
- `queueProvider` - Current play queue controller
- `currentQueueSongIdProvider` - Currently playing song ID
- `playNextProvider` - Add song to play next
- `reorderQueueProvider` - Reorder queue items

**player_providers.dart** (re-exports):
- Re-exports queue providers for convenience
- `lyricsProvider` - Lyrics for a song
- `playerStateProvider` - Playback state

#### Library Feature (`lib/src/features/library/presentation/`)

**library_sync_provider.dart**:
- `librarySyncEngineProvider` - Sync engine instance
- `librarySyncControllerProvider` - Sync state and controls
- `syncStaleAfterProvider` - Sync staleness threshold
- `library_sync_operation_ledger` retains the last 50 safe aggregate catalog
  promotions and confirmed starred-absence removals per server. The entry is
  committed with the mutation and contains only reason, timestamp and
  before/after/removal counts. Diagnostics may expose this redacted evidence;
  no entity IDs, titles, URLs, filesystem paths, or credentials are stored.
  Sync Settings streams the ledger and presents the latest operation that
  actually removed local rows, rather than the merely latest sync, so a
  following no-op check does not hide the cause of a visible disappearance.
- Automatic catalog checks use the per-server durable
  `library_sync_state.next_automatic_check_at` deadline. The controller owns
  one foreground one-shot timer that re-arms from that value; startup,
  reconnect, resume, and UI reconstruction only ask whether the deadline is
  due. They do not create independent periodic schedules. Manual checks and
  repairs bypass this automatic deadline. Engine progress and results never
  carry it: the controller keeps it on progress frames and, after every
  catalog run, reloads both `next_automatic_check_at` and the failure
  cooldown (`next_eligible_at`) from the persisted row, so status shows the
  deadlines the timer and circuit will use. A check that stops at its time,
  entity, page, request, or byte budget is a successful bounded check: its
  continuation stays queued without a cooldown, the failure circuit closes,
  and the remainder resumes on the next schedule trigger (startup, resume,
  reconnect, or the automatic deadline).
- Durable sync work uses terminal `completed`, `cancelled`, `failed`, and
  `awaitingConfirmation` states. The next app lifecycle event must not revive
  a cancelled operation immediately. A new compatible user action, changed
  evidence version, or a later due catalog observation after the configured
  interval can start new work; identical auxiliary evidence remains cancelled.
  Controller and coordinator queues also capture a cancellation generation:
  cancelling an active check invalidates a stronger repair waiting behind it.
  That waiting command cannot start after cancellation; a later explicit command
  is admitted as new intent. Only still-queued durable work is marked cancelled.
- Schema v71 adds a typed, redacted sync lifecycle beside the retained
  compatibility work mirror: `library_sync_run_request`,
  `library_sync_run_attempt`, `library_sync_run_outcome`,
  `library_sync_provider_profile`, and `library_sync_repair_session`.
  `SyncRunRequest` records a versioned origin, intent, target kind, priority,
  resumption provenance, and metered grant. The scheduler resolves it once
  into immutable `SyncExecutionPlan` endpoint/page/hydration/byte/concurrency
  limits before dispatch. Terminal history retains only enums, aggregate
  counts, and timestamps for 90 days; a target key is cleared on completion,
  so neither diagnostics nor Settings history retains IDs, titles, URLs,
  credentials, or filesystem paths.
- Schema v77 adds nullable, versioned attempt telemetry. Existing attempts retain
  unknown (`null`) evidence. The coordinator checkpoints safe counters and a
  bounded phase/transport timeline every five seconds, on phase changes, and at
  completion through the owning execution's SQL fence. Checkpoints coalesce and
  run outside nested delegate transactions; telemetry failure cannot fail a
  catalog publication. At most 32 phases and 128 transport attempts are retained,
  with omission counts and complete aggregate request/retry/byte/outcome counters.
  Preparing a new controller request clears the preceding attempt identity and
  request counters until the coordinator supplies the new correlation.
  Detail is pruned after seven days during normal terminal-run maintenance;
  aggregate outcomes retain the existing 90-day policy. Cleanup is opportunistic,
  not a guaranteed wall-clock deletion deadline. Request/attempt IDs correlate
  status and reports without including account IDs, entity IDs, URLs, parameters,
  media titles, response bodies or error messages. Routine status/history reads
  exclude the potentially larger telemetry JSON.
  `captureComplete` only means the recorder finished; the attempt row and terminal
  outcome remain authoritative, since process death can occur before terminal
  persistence. Recovered attempts retain their last checkpoint. Transport
  `envelopeAccepted` means protocol parsing succeeded, not that subsequent
  snapshot validation or database publication succeeded. Bytes are observed body
  bytes (with serialized-response fallback), not total network wire usage.
- Schema v78 stores `library_sync_state.initial_catalog_usable_at` separately
  from full-sync timestamps. A validated, promoted first catalog may be usable
  while isolated incomplete album details remain pending; the timestamp is
  written only after the full-screen controller verifies that outcome.
- `requiredLibrarySyncModelVersionProvider` - One-time sync model `57` repair
  gate. It rebuilds the complete server newest feed after the v73 external-row
  repair so persisted libraries receive authoritative Recently Added ranks.
  The repair waits for an unmetered connection, does not remove downloads, and
  a promoted catalog satisfies the gate even when unavailable albums remain
  queued for targeted hydration.
- Fresh catalog candidates clear abandoned page checkpoints for the reused
  generation. Promotion validates checkpoint-to-row counts and refuses an
  empty album candidate when the artist snapshot reports albums, preserving
  the committed catalog instead of applying an incomplete replacement.
- A catalog page checkpoint (version 3) counts only the albums that page added
  to the candidate, written in the same transaction as those rows. A server
  list that shifts while Navis pages it (an album added mid-repair, or ties in
  name order) repeats the boundary album on the next page; counting it twice
  made every resume of that generation fail the count check for up to 24
  hours. Version-2 generations are never resumed. The complete newest-rank
  scan likewise keeps an album's first rank when it reappears, and fails only
  when a page repeats exactly or adds no new album (a server ignoring the
  offset or looping).
- Candidate apply queries chunk large song-ID sets below SQLite's variable
  limit. A rolled-back `applying` generation remains resumable, allowing a
  corrected retry to reuse its fully hydrated candidate. Promotion completes
  the durable broad work item in the same transaction, so a restart cannot
  repeat the catalog scan while independent auxiliary hydration is unfinished.
- Schema-v57 promotion first classifies hidden candidate rows in resumable,
  adaptive keyset pages. The atomic visibility transaction then writes only
  inserted or changed rows once, streams unseen-song anti-joins, applies an
  indexed provisional-song identity plan, and defers cache-file unlinking
  until after commit, including files that lose a song identity remap inside
  the transaction (`SongIdentityReconciler.deferredFileDeletions`), so a
  rolled-back promotion never leaves restored rows pointing at deleted files.
  Explicit relinks from recovery review run outside a promotion and delete
  immediately. Unchanged catalogs therefore avoid metadata rewrites and
  large in-memory ID collections.
- Native Drift access uses WAL plus two pooled readers. Candidate collection
  and classification stay on the writer while an interactive read can proceed
  alongside a long catalog read, without a second `NavisDatabase` or candidate
  visibility in reactive providers.
- All transactional writes go through `NavisDatabase.transaction`, including
  DAO calls routed by `NavisDaoTransactions`. Drift 2.35 announces nested
  savepoint updates on the root stream store before the outer commit, so WAL
  readers can re-read old data and otherwise remain stale. The outermost call
  uses a database-specific zone key and creates root `tableUpdates()` outside
  Drift's transaction zone. It starts listening inside the transaction action,
  once the writer lock is held, collects premature root announcements with
  their update kinds, then drains their pending asynchronous deliveries and
  cancels the listener before committing. After a successful commit it replays
  only those collected updates with `notifyUpdates`. Drift dispatches the
  outer transaction's own tables after commit; these are not collected or
  re-announced. A transaction waiting for the writer lock does not collect
  the preceding transaction's announcements. Nested calls retain Drift's
  savepoints and `requireNew` behavior. Exceptions propagate unchanged without
  replay; the listener is always canceled.
  `customStatement` writers must call `notifyUpdates` for every table a stream
  may watch after their method's transaction succeeds, as `enqueueWork` and
  identity remaps do. When composed inside an outer transaction, these
  announcements are included in its post-commit replay. Ordinary Drift writes
  and batches already announce their tables; raw SQL cannot be inferred by
  this mechanism. Target artist/album hydration retains its explicit library
  announcements and page re-read fallback as additional protection.
- Linux and Windows profile diagnostics use the bearer-authenticated loopback
  control plane. The Linux launcher is `tool/sync_diagnostics.sh`; Windows
  launchers must use the same clone-only, isolated database/cache contract.
  A desktop clone resolves all `path_provider` directories inside
  `NAVIS_SYNC_DIAGNOSTICS_ROOT`.
  API, isolates cloned database/cache paths for fault testing, and permits only
  non-fault-injected operations during backed-up primary certification. The
  read-only `POST /v1/search/source-audit` route runs the real `search3` path
  and accepts bounded song-page count/offset inputs so diagnostics can verify
  server pagination. It returns only result counts plus kind, ID, display
  label, classified source, raw API flag, local-index presence, and provisional
  state; it never exposes credentials, URLs, or stream paths.
  Authenticated `POST /v1/presentation/search` drives the production Search
  providers, navigates to `/search`, waits for the final local/API merge, and
  returns only ordered IDs, relevance tiers, and source classifications for
  runtime and screenshot validation.
- API, playback, download, and artwork response accounting captures the
  long-lived network usage meter directly. It must not read through a disposed
  provider `Ref` when connectivity rebuilds the Subsonic client mid-request.

**library_providers.dart**:
- Artist, album, song, and album-list providers shared by Library presentation
  screens.
- Route-local state and scroll/section coordination remain in the dedicated
  presentation providers beside their owning screens; do not recreate this
  former planned-file boundary in `app_providers.dart`.

#### Auth Feature (`lib/src/features/auth/presentation/`)

**server_config_provider.dart**:
- `serverConfigProvider` - Server configuration controller
- `serverConfigStateProvider` - Server config state
- `serverConfigRepositoryProvider` - Config repository

**server_reachability_provider.dart**:
- `serverReachabilityControllerProvider` - Server reachability state

#### Retired Listen Together Feature (`lib/src/features/group_listening/`)

Listen Together / Voyage is retired for now. There are no active Listen
Together UI entry points and no active Voyage HTTP, websocket, session,
playback sync, or queue coordination paths.

#### Genres are not a Navis concept

By product decision (2026-09-30) Navis has no genre page, route, Library
section, Home shelf, search filter, Android Auto node, sync/scan input,
catalog-change signal, recommendation input or diagnostics field. Server
`genre` fields are ignored when albums are decoded, so a genre-only server edit
is not a catalog change. Schema 89 dropped the `genres` table, the
`albums.genre`, `library_sync_candidate_albums.genre` and
`library_sync_state.last_genres_synced_at` columns, and purged retired
`@genres` sync work and genre-target run history (`target_kind = 6`).
`test/src/architecture/no_genre_feature_test.dart` fails on any `genre`
mention in `lib/` outside generated files, historical changelog data and that
migration step. An Android Auto genre voice intent is an ordinary raw-query
search.

### Import Guidelines

1. **Feature code should import from feature providers first**:
   ```dart
   import 'package:navis/src/features/player/presentation/queue_provider.dart';
   ```

2. **Use global providers only for infrastructure**:
   ```dart
   import 'package:navis/src/providers/app_providers.dart';
   ```

3. **Avoid circular dependencies**:
   - Feature providers can import from `app_providers.dart`
   - `app_providers.dart` may import feature modules for dependency injection
   - Use exports in feature `*_providers.dart` files for convenience

### Provider Lifecycle

- **Auto-dispose**: Most providers auto-dispose when no longer watched
- **Keep-alive**: the database remains app-scoped; the Subsonic client is
  session-scoped and is force-closed during logout
- **Explicit disposal**: Audio handler and cache managers have explicit cleanup

**Retry policy.** Both the root container (`main.dart`) and the Android
background worker's container use `navisProviderRetry`
(`lib/src/providers/provider_retry.dart`) instead of Riverpod 3's default,
which retries any failed provider ten times over about 40 seconds and reports
each attempt as loading. Only failures that can pass on their own (a dropped
connection, `SubsonicConnectionException`, a socket or timeout error, or
HTTP 429/502/503/504/530) are retried, three times within about 1.4 seconds;
an error the server returned, such as an unsupported endpoint, reaches the
error state at once. Nested `ProviderScope`s inherit the policy; tests that
build their own containers keep Riverpod's default unless they pass it.

### Authentication, initial catalog, and teardown

Navis retains one local server/account profile. Its stable identity is the
normalized server base URL plus trimmed username. Schema v61 stores
`server_config.is_authenticated` separately from the non-secret profile:
keep-data logout clears secure credentials and marks the row signed out without
discarding its committed catalog, sync generation, provider tuning, timestamps,
or Navis capability metadata. Reauthenticating the same identity updates that
row in place. A different identity must traverse the explicit destructive
replacement boundary before its credentials can be stored.

Routing derives a compact `SessionRoutePhase`. A newly authenticated profile
without a usable catalog stays on the full-screen `/initial-sync` rebuild route.
Promotion alone does not admit Home. A complete run requires no pending album
hydration, artist verification, or candidate and durable full-sync evidence
(`server_config.last_synced` or `library_sync_state.last_catalog_synced_at`).
The sole partial exception is a validated catalog published in that run whose every
remaining canonical album was attempted in the current run and returned
incomplete detail. The controller then stores
`library_sync_state.initial_catalog_usable_at`; routing can admit onboarding
or Home across restarts without claiming full freshness. All full-screen rebuild
reasons share this partial exception. Other failed, deferred, or partial runs
keep retry and sign-out actions; offline and metered conditions retain their
retry/consent behavior. Pending albums continue through eligible incremental
checks. First setup without a committed catalog requests the planner's
first-catalog snapshot. When a committed generation (or `last_synced`) already
exists without readiness evidence, for example after an interrupted setup and
a keep-data sign-out and sign-in, setup and every retry run the explicit full
scan (`forceFullSync`) that cache upgrade uses: an incremental discovery pass
never publishes a catalog in its own run and stops at per-run budgets, so it
could never satisfy the readiness predicate. A completed profile keeps its
full-sync evidence across keep-data sign-out and returns directly to Home.
The rebuild controller behind every full-screen reason is an autoDispose
family scoped to one route visit. Each visit starts from idle and runs its own
rebuild. A run or a cancel-and-sign-out holds a keep-alive link, so its
readiness or cache-version bookkeeping completes after the route closes, and
the controller is disposed afterwards. A visit is also scoped to one
signed-in session. `build()` watches the active server identity. A quick
sign-out and sign-in can bring back the still-mounted route during its exit
transition, and Riverpod keeps the notifier instance across rebuilds. So a
session change starts a new visit, supersedes earlier runs by epoch, and only
starts work while a session exists. A finished, failed or cancelled visit
therefore never reaches a later sign-in, server change or repeated rebuild
request. Retry within one visit keeps its prepared cache reset. Sign-out steps
fail softly. If a cancel-and-sign-out leaves the session in place, the screen
returns to a failed state with Retry instead of staying on "cancelling".
This policy is recorded in
[the full-screen partial-readiness decision](decisions/2026-09-20-fullscreen-sync-partial-readiness.md).
The shell may observe an authenticated session before the credential-backed
sync engine is constructed. Its automatic startup and periodic passes wait for
that engine and retry their startup pass when it arrives; only an explicit
user-triggered retry exposes a persistent unavailable-engine failure.

All logout callers use the injected, single-flight `SessionLifecycleService`.
Its ordering is API cancellation → awaited sync/download stop → playback/radio
session reset → transient UI/mix/timer reset → pending mutation/work cleanup →
optional server-data/file reset → authentication invalidation in `finally`.
`NavisPlaybackHandler.resetSession()` supersedes transport and queue work,
stops radio metadata, crossfade and cache sidecars, empties both decks and the
media session, persists an empty queue, and emits idle state. Download teardown
tracks progress writes and background cover-art/lyrics/notification tasks so
late completions cannot recreate queue state after `stopAndWait()`.

### Testing

- Feature providers should be tested in their feature test directory
- Mock dependencies using `ProviderContainer` overrides
- Test provider state transitions and error handling

## Agent Runtime Control Plane

The agent runtime API is a non-production control and observation plane for a
real Navis process. It complements automated tests; it does not replace the UI
or introduce a second implementation of feature behavior.

The current implementation starts `SyncDiagnosticsServer` on Linux, Windows,
and Android profile builds:

1. `main.dart` accepts diagnostics only in a supported profile build with a
   valid mode and a desktop handshake path when applicable. Android supports
   read-only `primary-certification` observation with a handshake in the app-specific
   external files directory; host tooling reaches loopback through `adb
   forward`. Clone diagnostics remain desktop-only because their isolated
   database/cache contract is filesystem-owned by the launcher.
2. Clone mode opens an isolated database and cache tree. Primary certification
   uses the normal profile only with the launcher's backup and mutation
   restrictions.
3. After `runApp`, the server binds to IPv4 loopback on an ephemeral port,
   creates a random bearer token, and writes its port, token, process ID, and
   mode to a handshake file. Linux/macOS profiles apply mode `0600`; Windows
   relies on its per-user diagnostics directory and does not invoke a POSIX
   permission command before starting the request loop. On Android, the host
   receives the handshake from the app-owned native bridge in
   `getExternalFilesDir()/navis-diagnostics`; raw Dart I/O cannot create the
   scoped-storage path. Clone Android bootstrap now asks that existing native
   bridge to prepare the scoped directory before Drift opens, and checks the
   sidecar identity first. The bridge validates the bounded record and replaces
   it before the loopback server begins serving.
   The headless background-sync callback is also retained as a
   `@pragma('vm:entry-point')` root-library forwarder in `main.dart`: Android's
   named `DartEntrypoint` resolves from that root library in profile/release
   builds, then delegates to the UI-free library-sync entrypoint.
4. Authenticated feature actions run through the root `ProviderContainer` and
   the same controllers, repositories, DAOs, and audio handler as production
   interactions. Broad sync actions specifically join the production
   `LibrarySyncController`, so diagnostics cannot create a competing repair
   alongside startup or UI work. Status and report endpoints expose bounded, non-secret
   observations for assertions.
5. `POST /v1/shutdown` closes the server, removes the handshake, disposes the
   provider container and diagnostics database, and exits the process.

Clone diagnostics wrap the root Flutter application in a diagnostics-owned
`RepaintBoundary`. Android primary certification uses that same boundary only
for authenticated, read-only screenshot capture; its artifacts stay below the
sidecar's scoped external diagnostics directory, while all route and feature
controls remain disabled. `GET /v1/presentation/status` reports the live route and
viewport plus post-bootstrap app readiness,
`POST /v1/presentation/navigate` drives the real `GoRouter`, and
`POST /v1/presentation/screenshot` waits for a completed, animation-settled
frame before writing a 1.0-ratio PNG below the validated artifact root. The
server creates filenames,
returns only relative path/dimension/digest metadata, and protects the
screenshots directory and files with modes `0700` and `0600`. Non-route UI uses
narrow production-controller actions such as the queue/Now Playing
`POST /v1/presentation/player-overlay`; the control plane has no generic
coordinate-click interface.
After a presentation search, clone-only
`POST /v1/presentation/search/play` can select one of that sanitized result
set through `QueueController.replaceWithSongs`; it exists only to validate the
same remote-result playback and Now Playing path used by the Search UI.

Desktop volume diagnostics use `GET /v1/playback/volume`,
`POST /v1/playback/volume`, and
`POST /v1/playback/volume/toggle-mute`. Mutations are clone-only and invoke
`PlaybackVolumeController`, which in turn applies the real audio handler and
persists through `SettingsRepository`; the control plane never writes the
settings table directly. `tool/volume_memory_diagnostics.sh` repeats this flow
across clean process restarts.

Song-row presentation diagnostics use the read-only
`GET /v1/presentation/song-indicator?songId=<id>` endpoint. It reads the same
production presentation provider as the UI and returns only indicator state,
selection, marker, app-owned semantic roles, and color roles. These values are
not a live accessibility-tree traversal. It does not return song metadata.
`tool/playback_indicator_diagnostics.sh clone` verifies current, inactive,
paused, switched-song, app-owned screenshots, and clean-restart behavior
against an isolated Linux profile.

Weekly-playlist presentation diagnostics can enable the clone-only
`cachedListenBrainzPresentation` override. The production discovery provider
then reads the most recent isolated `listenbrainz_weekly_cache` entry without
copying a secure token, making mixed local/remote rows available to app-owned
screenshots. The override never runs in primary-certification mode and neither
the API response nor runtime evidence exposes the cached username.

Authentication lifecycle diagnostics use bounded `GET /v1/session/status`
plus clone-only initial-sync retry/mobile/cancel, sign-out, and
`reset-initial-state` actions. The reset endpoint invokes production
cancellation/playback/reset services and `ServerDataResetService`; it does not
edit the database directly. `tool/auth_lifecycle_diagnostics.sh clone`
points each isolated clone at a deterministic loopback Subsonic fixture, seeds
its credential from a mode-600 diagnostics file, and exercises offline
recovery, safe promotion, screenshots, restart, real playback-to-sign-out
teardown, and setup cancellation. Clone-mode credential writes and clears stay
in memory, so these destructive actions can never clear or replace device
secure storage. With `passive=1`, `GET /v1/session/status`,
`POST /v1/session/sign-out` and `POST /v1/session/reset-initial-state`
report the session without instantiating the legacy diagnostics setup
controller. That controller starts its own setup run whenever the session
needs one, which would mask the route-owned controller. Clone-only
`GET`/`POST /v1/presentation/library-rebuild` reports the route-owned
full-screen rebuild controller for a given `reason`, and can `retry` or press
its `cancelAndSignOut`. It reports `inactive` rather than instantiating an
unmounted controller, because instantiation starts a rebuild. The
`existing-catalog` mode uses these to verify keep-data sign-out, cancellation
and wipe sign-out followed by a new sign-in in the same process. The legacy
diagnostics setup controller follows the same session scoping. It starts setup
only once the phase requires it, never while the phase is still loading. A
non-passive session call activates it with a lasting subscription. Riverpod
pauses a provider that is only read, and a paused provider would miss a
sign-out or sign-in between two requests.

Clone-only `POST /v1/session/connect` validates and saves a server session
through the production connection service but does not instantiate the legacy
initial-sync controller merely to build its response. The required rebuild
screen owns the interactive first-sync request; the library controller coalesces
any overlapping automatic pass. Observing a newly connected session must not
upgrade it into an interactive Repair Library request.

Cache diagnostics expose sanitized `GET /v1/cache/status`, including whether a
mandatory cache renewal remains pending but never a cache-system version or a
file path. Clone-only
`POST /v1/diagnostics/cache/corrupt` removes the backing file for a named
isolated cache entry, while `POST /v1/cache/maintenance` runs the production
cache-pruning path. Startup performs the same bulk sweep, and playback source
resolution removes an individual missing cache record before streaming fallback
so a live filesystem deletion cannot leave stale cached/downloaded UI state.
Neither endpoint returns local file paths.

New control-plane capabilities should remain feature-scoped, expose separate
action and status/query contracts, return structured errors, and support
deterministic completion or bounded polling. They must have server contract
tests. Direct provider or database mutation is reserved for clearly named
isolated fixture setup and fault injection; normal actions must traverse the
production path.

The security boundary is invariant across future platform adapters: the API is
unavailable in release builds, loopback-only, bearer-authenticated, short-lived,
and must not expose credentials, tokens, private server URLs, stream URLs, or
raw cloned records. Native service APIs remain authoritative for platform
integration only, including MPRIS on Linux, SMTC on Windows, and Android
media-session/MediaBrowser behavior; they do not replace the Navis API for
Flutter state. AT-SPI and other external desktop/accessibility automation are
outside this control plane and prohibited unless the platform accessibility
bridge is explicitly under test with user authorization. See
`docs/development-workflow.md` for the mandatory validation loop and
target-selection rules.

## UI Component Organization

### Theme and design tokens (`lib/src/theme/`)

- `navis_theme.dart`: `buildLightTheme`, `buildDarkTheme` and
  `buildOledTheme` each choose a `ColorScheme` from the user's seed (or the
  dynamic album colour) and delegate to one shared builder. Typography,
  component themes and theme extensions are defined only in that builder.
  OLED differences are expressed there as surface overrides.
- `navis_tokens.dart`:
  - `NavisSpace` and `NavisRadius` are compile-time spacing and radius
    scales.
  - `NavisTokens` is a ThemeExtension for theme-dependent values: frame widths,
    hover/focus opacity, and colour roles `ColorScheme` lacks: the quiet
    warning container and the `success` foreground for completed or
    confirmed states. Read it with `NavisTokens.of(context)`.
  - Artwork radii follow the user's Appearance shape settings, not these
    scales. `artwork_shape.dart` maps a setting (`square`, `rounded`,
    `circle`) and the artwork's rendered size to corners with
    `artworkBorderRadius`: rounded is 4 below 40 px, 8 below 96 px and 12
    otherwise, so row thumbnails and cards share one look. `ArtworkShapeRole`
    names the setting a surface follows (Cover Art Shape for album, song and
    playlist art, Now Playing Art Shape, Artist Card Shape), and
    `artworkShapeProvider(role)` reads it. `CoverArtImage(shape: role)`
    shapes itself from its width and height; surfaces that clip or decorate
    the artwork themselves (cards, Hero covers, playlist mosaics, the mini
    player's radio and remote art, empty artwork slots) call
    `artworkBorderRadius` with their own size. Full-bleed headers and the
    full-screen cover viewer stay unshaped. Before 1.4.1 most rows, the
    queue, the players and Now Playing song covers ignored these settings.
- `motion_policy.dart`: owns every duration, including the reduced-motion
  zero values.
- `dynamic_accent_provider.dart`: samples the current artwork to reseed the
  scheme when dynamic album colour is enabled.
- Fonts: the bundled Inter variable font (`assets/fonts/`, SIL OFL 1.1,
  licence registered in `main.dart`). Scripts Inter lacks use the platform's
  per-glyph fallback.
- Guard: `test/src/theme/design_token_guard_test.dart` ratchets literal radii,
  font sizes and colours per file outside `lib/src/theme/`.
- Decision record:
  [decisions/2026-09-30-design-foundation.md](decisions/2026-09-30-design-foundation.md).

### Home: You Might Like

`you_might_like_widgets.dart` (a part of `home_screen.dart`) renders the
recommendation showcase.

**Phones and tablets: a focused cover flow.**
- **Cover size:** square and uncropped, 62% of the width, capped at 260 px
  (300–320 px on tablets) and at 42% of the screen height so landscape
  still fits.
- **Neighbours:** the page controller's viewport fraction is derived from
  that size so neighbours peek. Their scale and opacity follow the page
  offset continuously.
- **Play:** only the focused cover shows Play, which calls
  `playAlbumById` in `album_context_menu.dart`. ListenBrainz picks open
  their weekly playlist instead.
- **Info panel:** `_ShowcaseInfoPanel` under the carousel crossfades the
  title (tap to open), the artist, and a line such as
  "2023 • 12 songs · Similar to your likes". `_showcaseReasonLabel` maps
  each `HomeRandomShowcaseSource` or ListenBrainz item to its reason.

**Desktop:** the art, track list and cover strip are unchanged. The panel
header adds the same reason line and a compact Play/Shuffle pair.

**Colour wash (`_ShowcaseColourWash`, both layouts):**
- `coverColourFieldProvider` (`cover_colour_field.dart`) decodes the cached
  600 px cover at 24 px (same URL and cache key as the cards, so no new
  request), averages it into a 3×3 colour grid, and keeps the result in a
  64-entry LRU.
- `CoverColourFieldPainter` draws the grid as a vertex-coloured mesh
  (`Canvas.drawVertices`). The GPU shades it smoothly at any width, where a
  stretched thumbnail pixelates on wide displays. The mesh overscans its box
  and is clipped to it.
- A veil of the page colour covers it (lighter in light themes and on
  desktop), so it needs no offscreen layer while idle.
- Changing covers interpolates the nine colours over 400 ms; reduced motion
  switches instantly.

Paging, auto-advance and the test/diagnostics keys
`home-random-hero-carousel(-page-N)` are unchanged. The hero's items and
Trending Now are described in "Deezer on Home".

### Changelog and What's New (`lib/src/features/changelog/`)

**Data.** `changelog_data.dart` is a `const` list of `ChangelogVersion`s,
newest first. It has no imports, so it is the single source for the app and
for `tool/generate_release_notes.dart`, which renders a Forgejo release body
through `release_notes_markdown.dart`.
- Every `x.y.0` release is major (`isMajor`) and shows as `1.4`
  (`displayVersion`).
- A release can carry `released` (`YYYY-MM-DD`), `codename`, `summary`,
  `highlights` and `iconAsset` (SVG or PNG under `assets/changelog/`).
- `ChangelogReleaseCover` draws a release like album art and follows the
  cover-shape preference. It paints the release's asset as a single-colour
  glyph (`BlendMode.srcIn`) in `onPrimary` on `primary`, so one file suits
  both brightnesses and every accent. When there is no asset or it fails to
  load, it draws a typographic cover: the version set large on `primary`.
- Highlight icons are a `ChangelogHighlightIcon` enum, mapped to Material
  icons in `changelog_style.dart`, so the data file needs no Flutter import.
- `changelog_data_test.dart` enforces valid, descending versions and dates,
  3–5 highlights for majors from 1.2.0 on, and that icon files exist.

**Home card (`ChangelogDiscoveryCard`, drawn in `HomeNoticeCard`).** It is inline and non-blocking
(design-ux-audit D5). `changelogToShowProvider` calls
`resolveChangelogDiscovery`: it returns nothing once the running version is
recorded in `changelog_seen_version.txt` (Application Support), otherwise the
running release plus the newest *major* in the unseen range
(last seen, current]. So a jump from 1.3.1 to 1.4.1 still features 1.4.
- It is a flat row styled like a library row.
- With a featured major: a 48 px cover, "Check out 1.4 “Navi”", and one plain
  line naming up to three highlights ("…and 2 more").
- Patch only: "Updated to Navis 1.4.1" and its number of changes.
- Tapping opens `/settings/about/changelog?version=<featured or current>`.
  Opening or dismissing records the running version as seen.

**Changelog screen (`/settings/about/changelog`).** A release reads like an
album page, in the album screen's own grammar rather than banners or cards.
- `ChangelogReleaseHeader`: the cover on the left (112 px phone, 208 px
  desktop), then the codename (or "Navis 1.4"), "Navis 1.4" and
  "Sep 30, 2026 • 90 changes", bottom-aligned like the desktop album header.
  Patches have no cover.
- `ChangelogHighlightList`: highlights as track-style rows (a narrow icon
  column, title, one line), in two columns on desktop.
- `ChangelogReleaseDetails`: an "All changes" section with Library-style
  tabs (All, New, Improved, Fixed), plain paragraphs under plain
  subheadings, and fixes past five behind "Show N more fixes".
- `ChangelogReleaseRow`: a release in a list, with a 48 px cover for majors
  and an empty slot for patches so they sit under their major.
- Phones show the focused release (the `version` query parameter, else the
  newest), then "Earlier releases" rows; tapping one shows it in place. A
  patch adds a "Part of Navis 1.4 “Navi”" row that shows its major.
- The desktop shell keeps the release rows in a list beside the selected
  release.

### Common Widgets (`lib/src/common_widgets/`)

Reusable UI components used across features:

- **Media Display**
  - `cover_art_image.dart` - Album/artist cover art with caching
  - `hero_cover_art.dart` - Cover art with hero animation
  - `track_list_tile.dart` - Playback-aware track list item
  - `song_playback_indicator.dart` - Shared current/loading row state, marker,
    tint, and semantics
  - `album_card.dart` - Album grid card
  - `artist_card.dart` - Artist list/grid card

- **Player UI**
  - `expandable_player_sheet.dart` - Mini player ↔ now playing transition
  - `lyrics_display_widget.dart` - Synced/unsynced lyrics display

- **State Widgets**
  - `empty_state.dart` - Empty state with icon and message
  - `error_state.dart` - Error state with retry
  - `shimmer_placeholder.dart` - Loading skeleton
  - `loading_indicator.dart` - Progress indicator

- **Actions**
  - `star_button.dart` - Star/unstar action
  - `cache_badge.dart` - Cache status indicator
  - `context_menu.dart` - Bottom sheet context menu

### Hero Animation Pattern

Use `HeroCoverArt` widget for cover art that animates between screens:

```dart
HeroCoverArt(
  coverArtId: album.coverArt,
  heroTag: buildCoverArtHeroTag(
    coverArtId: album.coverArt,
    context: 'album_grid',
  ),
  width: 180,
  height: 180,
)
```

Hero tags follow the pattern: `cover_art_{context}_{entityId-or-coverArtId}`.
Use an immutable entity ID for album art whenever one is available so shared
or missing cover art cannot create duplicate tags.

Contexts:
- `album_grid` - Album grid in library
- `album_detail` - Album detail screen
- `now_playing` - Now playing screen
- `mini_player` - Mini player

Desktop and ordinary mobile album-detail navigation use the composed-page
180 ms `MotionPolicy.surface` fade in both directions; reduced motion is
immediate. Desktop requests omit the opening artwork tag, and the album route
enforces that policy for direct, replacement and legacy payloads too. Desktop
detail artwork uses the `album_detail` context so its fallback cannot match
the Library card's `album` tag, while the detail-to-artwork-viewer Hero remains
available. Compact mobile landscape retains its existing shared-artwork flight:
the entry passes its rendered tag to `NavService.openAlbumDetail(...,
heroTag: tag)` and the destination uses it verbatim. `HeroCoverArt` preserves
the source image's cache
size and clipping shape for both push and pop; destination-specific shuttles
and additional album-route travel must not replace that shared flight.

`CoverArtImage` applies the same aspect-preserving decode bounds to cached-file
and admitted network artwork. Ordinary thumbnails retain the existing 2× layout
budget (falling back to the requested size); hero source, flight and destination
retain their shared requested-size budget. Small source images are not upscaled
at decode time. Network rendering uses the existing `OctoImage` renderer with a
bounded `CachedNetworkImageProvider`, and returns its decoded child directly:
rebuilding an `Image` from the unresized provider would bypass the bound. URL,
disk-cache identity, load admission, clipping and provenance remain independent
of the memory decode size. `octo_image` is an explicit dependency at its existing
locked version; this introduces no new renderer or package version.

### Expandable Player Sheet

The `ExpandablePlayerSheet` widget handles the mini player ↔ now playing transition:

```dart
ExpandablePlayerSheet(
  miniPlayer: MiniPlayerWidget(),
  fullPlayer: NowPlayingWidget(),
  isExpanded: isNowPlayingExpanded,
  onToggleExpanded: () => setState(() {
    isNowPlayingExpanded = !isNowPlayingExpanded;
  }),
)
```

Features:
- Smooth height animation
- Drag gesture support
- Velocity-based snap
- Fade transition for content

### Lyrics Display

The `LyricsDisplayWidget` supports both synced and unsynced lyrics:

```dart
LyricsDisplayWidget(
  lyrics: lyricsList,
  currentPosition: playbackPosition,
  onSeek: (position) => audioHandler.seek(position),
)
```

Features:
- Auto-scroll to current line
- Tap to seek (synced lyrics)
- Touch dragging, mouse-wheel and trackpad browsing suspend following; the
  existing 2.5-second grace period starts after the final interaction. A
  re-center button resumes immediately. Obsolete follow animations are
  cancelled without changing audio position; only a lyric tap calls `onSeek`.
- Graceful fallback for unsynced/missing lyrics

`LyricsResolver` looks lyrics up in this order: while `lrclib.lyrics` is
allowed, synced lyrics from LRCLIB first (cached per song), then the server's
lyrics as fallback; otherwise the server only. The switch lives in Settings ›
Integrations › LRCLIB. An LRCLIB result passes on its `normalizeMetadata`
title, artist, album and duration score; among passing results one with the
same edition qualifiers ("(Japanese Version)") wins over another version,
whose lyrics may be in another language.

Apple runners remain unreleased scaffolds. Their native configuration floors
are iOS 16 and macOS 12; Linux validation does not certify either runner. This
upgrade reconciles Podfile/project settings without adding Apple media features.

## UI libraries and localization

Navis uses the standalone `material_ui` and `cupertino_ui` design libraries.
The `cupertino_icons` dependency supplies the icon font referenced by Cupertino
and platform-adaptive library widgets, including release builds.
Application widgets, themes and test harnesses use their types consistently;
`go_router` 18 therefore recognizes the modern `MaterialApp` and preserves its
Material page behavior. Core widgets, services and gestures remain in Flutter.
The handwritten `lib/l10n/navis_localizations.dart` combines Navis strings with
modern design-library delegates. Generated localization output is left intact;
its legacy delegate list is not used by application harnesses. Application
strings currently support English; design-library localization also supports
RTL languages without claiming Navis translations for those languages.

The release-notes Markdown subtree alone uses `MaterialUiCompatibilityBridge`
with a legacy theme below it, because `flutter_markdown_plus` still requires
framework Material types. Remove this scoped, deprecated compatibility utility
when that dependency migrates. The desktop input boundary, presentation host,
bootstrap overlay, theme seeds, OLED colors and router lifetime remain owned by
Navis.

## Routing Structure

Routes are declared in `lib/src/routing/app_router.dart` from the path
segments in `lib/src/routing/app_routes.dart`. `AppRoutes` is the only place
route locations are written: it builds every location, URL-encodes entity ids
into single path segments, and defines `ShellBranch` (the four tab branches in
router order) and `SettingsPage`. A source guard in
`test/src/routing/app_router_test.dart` fails on route string literals outside
`app_routes.dart` and on direct router calls outside `lib/src/routing/` except
a short, justified allowlist (sign-in/out, onboarding, full-screen rebuilds and
the diagnostics API). Another test resolves every `AppRoutes` location against
the real router.

### Main Routes

Full-screen flows, outside the tab shell:

- `/login` - Login screen (unauthenticated)
- `/initial-sync` - recoverable full-screen first-catalog route; it takes priority over versioned onboarding and opens Home only after complete catalog evidence
- `/library-rebuild?reason=…` - mandatory and user-started recoverable library rebuilds
- `/onboarding` - full-screen, versioned first-run customization before normal authenticated routing; `?review=1` re-runs it from Settings

Tab shell (`StatefulShellRoute.indexedStack`, branches Home, Library, Search,
Settings):

- `/` - Home
- `/library?section=<albums|liked|artists|playlists|radio>` - Library; the section is part of the location
- `/library/artists/:id` and `/library/artists/:id/top-tracks` - Artist detail and its top-tracks playlist; `?name=` names an artist the library may not hold yet
- `/library/albums/:id` - Album detail; `?name=` and `&artist=` name an album the library may not hold yet
- `/library/playlists/:id` - Playlist detail
- `/library/listenbrainz/:sourcePatch` - ListenBrainz weekly playlist
- `/library/liked-albums`, `/library/liked-artists` - Full liked lists
- `/search` - Search
- `/settings` - Settings
- `/settings/server` (Server Information), `/settings/integrations`, `/settings/cache`, `/settings/downloads`, `/settings/sync`, `/settings/playback`, `/settings/equalizer`, `/settings/appearance`, `/settings/about`, `/settings/unavailable-items`
- `/settings/playback/match-flow` and `/settings/playback/match-flow/:flowId/search`
- `/settings/about/changelog`, `/settings/about/privacy`
- `/settings/desktop-window`, `/settings/shortcuts` - desktop only; other platforms are redirected to `/settings`

The retired `/settings/group-listening` path redirects to Server Information
(`/settings/server`) and `/settings/external-services` to Integrations
(`/settings/integrations`); neither is shown in navigation. A location that matches no route shows a localized not-found page
with a Home action.

`appRouterProvider` owns one stable `GoRouter` instance. Authentication and
first-sync phase changes refresh its redirects in place rather than rebuilding
the router: timestamp and catalog-state updates during ordinary sync may
briefly re-evaluate session readiness, but they must preserve the current
location.

The cache-renewal gate observes a durable cache-system marker alongside the
authentication phase. An authenticated profile with an older marker is routed
to the mandatory full-screen cache rebuild before onboarding or the normal
shell. It clears only recoverable library and rolling-cache data, preserves
permanent downloads, performs a full catalog scan, and records the new marker
only after that scan promotes successfully. A failed or cancelled rebuild, or
an unreadable marker, keeps the renewal pending until it can be resolved.
Completion goes directly
to versioned onboarding when it is required; otherwise it opens Home. Ordinary
settings updates must not refresh the router.

When a successful required initial-library build or cache renewal immediately
leads to onboarding, the rebuild route carries only an internal eligibility
marker. It becomes the route-scoped `homeWarmup=1` handoff only after the
catalog has committed successfully.
After onboarding's first frame, that one session resolves the configured visible
Home order and filters, selects no more than six unique first-view covers, and
uses the same key and requested size as their Home surfaces. It uses the normal
bounded Home providers but never starts catalog sync, auxiliary refresh, or
ListenBrainz discovery. Artwork requests run one at a time at background
priority, decode only the first three covers into Flutter's image cache, and
stop scheduling when onboarding exits or the app backgrounds. The handoff is
not persisted, is skipped offline, and never runs for repair, reset, failed,
cancelled, or direct-to-Home flows. It asks no online service either (no
Deezer or Last.fm): the user has not reached the Integrations step yet.

Onboarding has four steps (look, listening, queue and downloads,
Integrations) kept in one draft that Finish saves and Skip discards; the
Integrations step is described under "External integration policy". The
screen keeps its size when the keyboard opens (`resizeToAvoidBottomInset:
false`) and pads itself by `MediaQuery.viewInsetsOf`, so the step list ends
at the keyboard. On compact layouts the header and the actions step aside
while the keyboard is up. The step list and its rows are keyed, and the
"scroll for more" hint sits above the list, hidden while the keyboard is up
and once the list is scrolled to (or within 24 dp of) its end, back when
scrolled up: inserted into the list it used to shift the rows, rebuild the focused token
field and close the keyboard again. The token and key fields have their own
focus nodes, validate on the keyboard's Done action, show and hide their
value, show errors on the field and are locked while validating.

### Shell Routes

The app uses `StatefulShellRoute.indexedStack` for persistent navigation. On
non-desktop platforms, shell composition is selected by `resolveAdaptiveShellMode`.
Desktop runtime has only Desktop View and the dedicated same-window Mini Player;
it never renders the phone bottom navigation, expandable player sheet, or tablet
rail mini-player. Desktop View always reserves its bottom player bar, including
when playback is empty. Its right-side action region is stable from the 800 px
minimum upward: Favorite, Lyrics, Queue, and Mini Player remain directly
visible in a 44 px-target row, with mute and the full volume slider on the row
below. Contextually invalid actions keep their slots and expose localized
disabled semantics rather than changing player geometry. There is no separate
`/now-playing` route.

Favorite, Lyrics, Queue, and Mini Player use the shared `NavisTooltip` hover
overlay, also used by Remote indicators. Their accessible label, enabled state,
and tap action stay on the stable target node. The pointer-transparent bubble
is a visual-only `OverlayEntry`: Material tooltips use `OverlayPortal`, which
can leave stale accessibility children when shown below excluded semantics
on Flutter 3.47.1. Removing or hiding the target removes and disposes its entry;
desktop action tooltips also retain long-press display. Other Material tooltips
remain outside excluded semantics subtrees.

### Navigation Intent

Feature code navigates through `NavService`
(`lib/src/routing/navigation_service.dart`), never raw GoRouter calls. Its
helpers dismiss the keyboard, popup routes (on the current tab's navigator as
well as the root) and the player overlay stack before moving.

- **Drill-in** (`openAlbumDetail`, `openArtistDetail`, `openSettingsPage`,
  `openChangelog`, …) pushes onto the current tab, so Back returns to where it
  was opened. go_router keeps a pushed page on the tab it was pushed from even
  when its path is under another branch (an album opened from Home stays on
  Home).
- **Tab switches** use `switchTab(ShellBranch)`; re-selecting the current tab
  returns it to its root and scrolls it to the top. Re-selecting Library keeps
  its section; re-selecting Search also focuses its field.
- **Library sections** use `openLibrarySection`, which writes
  `/library?section=…`. The shell follows that location into
  `librarySectionProvider` from the router's change notification (never during
  build), so returning to the tab, history, deep links and diagnostics select
  the section named. A Library location without a section keeps the current
  one.
- **Page back buttons** use `NavService.back(context, fallback:)`: pop when the
  page has history, otherwise go to the fallback. `returnToLibrary` pops an
  unavailable detail page before switching to Library so it does not linger
  on the origin tab.
- **Mini Player**: links followed from Mini Player (for example the playing
  track's album) first return to Desktop View; when Desktop View is
  unavailable they do nothing.
- `openSearch` (player metadata fallbacks) replaces the Search query and
  records it in search history.

Dialogs and sheets still dismiss themselves with `Navigator.pop`. Transient
result-returning workflows (full-screen lyrics, the Mini Player queue and
lyrics pages, download reconciliation) remain Navigator pages rather than
routes; back closes them like dialogs and history does not record them.

### Back handling

Every back entry point in the shell (Android back via `BackButtonListener` and
`PopScope`, the tab navigators' `NavigatorPopHandler`s, the desktop workspace)
calls one handler, and desktop Escape starts from the same first steps:

1. quick search;
2. the queue (animated close that restores focus to its invoker);
3. a panel inside Now Playing (compact-wide panels, full-screen or inline
   lyrics);
4. Now Playing itself (on desktop this is the lyrics overlay);
5. pop the current tab's page;
6. from another tab's root, switch to Home;
7. at Home root, press back twice within two seconds to exit.

Escape stops after step 4 (then closes a root dialog); it never pops pages.
iOS detail pages without a Hero use `CupertinoPage`, so edge-swipe back works.

### Desktop history

`navigation_history_provider.dart` keeps desktop Back/Forward history. It is
created at launch (`app.dart` listens on desktop) and records a
`NavHistoryEntry` (`navigation_history.dart`) for every router configuration
change that shows the tab shell: the whole `RouteMatchList`, its tab and page
keys. Sign-in, onboarding and full-screen rebuild locations are never
recorded; sign-out clears history; at most 100 entries are kept.

A pop that returns to the previous entry moves back through history rather
than adding an entry. Going back to the page directly beneath the current one
pops it (completing its push future, which the Equalizer uses to restore its
origin); every other move calls `GoRouter.restore` with the recorded snapshot,
rehydrating already-completed push completers, so tabs keep their stacks,
pages keep their state and `extra` payloads survive. `go()` is never used for
history. Overlays are cleared before each move, and history is ignored in Mini
Player.

History is driven by mouse buttons 4/5, the configurable Back/Forward
commands (Alt+Left/Right; Cmd+[ / Cmd+] on macOS) and the Back/Forward buttons
at the top of the desktop sidebar, enabled from history state.

Player overlays are logical shell state, separate from their visual exit
transition. When playback becomes inactive, the shell clears the queue and
now-playing overlay stack synchronously, and all back handlers read that live
state rather than a value captured during an earlier build. On phone and medium
tablet layouts, the last active player presentation is retained as an
`IgnorePointer` only until its slide-down animation finishes.

## Adaptive Shell Architecture

The adaptive shell is the central coordination surface between platform, window size, and input
modality. Its implementation lives in `lib/src/routing/desktop_layout.dart` and
`lib/src/routing/app_shell.dart`.

### Layout Classification

Non-desktop width buckets are resolved by `resolveAdaptiveLayoutClass`:

| Width threshold | `AdaptiveLayoutClass` |
|---|---|
| ≥ 840 dp | `tabletExpanded` |
| 600–839 dp | `tabletMedium` |
| < 600 dp | `phoneCompact` |

Desktop uses a separate classification:

| Width | `DesktopLayoutClass` |
|---|---|
| 800–1007 dp | `compactDesktop` |
| 1008–1599 dp | `standardDesktop` |
| ≥1600 dp | `ultraWideDesktop` |

### Shell Composition

`resolveAdaptiveShellMode` maps layout class + runtime + orientation to a shell mode:

- **Desktop runtime, Desktop View** → desktop workspace with persistent side navigation and bottom player
- **Desktop runtime, Mini Player** → dedicated playback surface. The desktop
  workspace, including the tab shell, stays mounted but hidden (offstage,
  tickers off, focus excluded, laid out at the last Desktop View size) once
  Desktop View has been shown, so returning restores every tab's pages. Page
  shortcuts (tab switches, search, queue, history) are ignored in Mini Player.
- **Tablets (shortest side ≥ 600 dp), ≥ 840 dp wide** → standard rail,
  whatever the aspect ratio
- **Phones in landscape, ≥ 840 dp wide** → standard rail when the rail fits the
  height, otherwise the compact icon rail (compact-wide)
- **All other cases** → bottom navigation bar

Only short viewports get compact-wide; a 16:9 tablet, or a car display of the
same size, uses the standard rail. The top-inset proxy for car bars that do not
report a bottom inset applies only to compact-wide.

Selected destinations use filled icons on the bar and rails. When the sidebar
or rail cannot show the Library section links (phone bottom navigation, the
compact rail, icon-only or auto-hiding desktop sidebars, or a rail too short
for them), the Library page shows its own section bar;
`LibrarySectionNavigationScope` carries the sidebar's decision, which the
sidebar reports after layout.

### AdaptiveContext

`AdaptiveContext` is a value object (with value equality, so its scope only
notifies on real changes) computed once per `AppShell` layout pass and propagated
downward via `AdaptiveContextScope`. It exposes:

- `desktopRuntime` — true on Linux/macOS/Windows
- `desktopWide` — true for the desktop workspace; retained as a compatibility capability flag
- `desktopLayoutClass` — the `DesktopLayoutClass` bucket (narrow / standard / wide)
- `adaptiveLayoutClass` — the shared `AdaptiveLayoutClass` for non-desktop breakpoints
- `useCompactWideLandscape` — compact landscape mode flag for phone-wide layouts

Feature screens call `AdaptiveContextScope.maybeOf(context)` to read the context without
triggering rebuilds on unrelated dimension changes.

### AdaptiveInputPolicy

`AdaptiveInputPolicy` separates capability decisions from layout decisions:

- `enableDeterministicTraversal`
- `enableEscapeOverlayPriority`
- `enableDesktopPointerAffordances`
- `enableSecondaryClickMenus`
- `enableDesktopCommandShortcuts`

The policy is resolved from `AdaptiveContext` by `AdaptiveShell` and propagated via
`AdaptiveInputPolicyScope`. This allows feature screens to adapt their affordances
independently of layout decisions.

### Collection pane geometry

`routing/content_layout.dart` owns pure geometry for bounded album/artist grids,
preview capacity, track-row modes, and station cards. Geometry takes the usable
content pane after navigation and padding; shell classification remains owned
by `AdaptiveContext`. Album and artist grids have no column ceiling: wider
panes add cards while minimum and maximum extents bound their size. Spare width
centers the grid, while sparse final rows retain leading alignment.
`ResponsiveContentSliverGrid` builds collection cells lazily and reserves
measured two-line artist labels at the current text scale.

Schema 81 adds `grid_artwork_size` (`auto`, `small`, `medium`, `large`) and
`home_recommendations_auto_advance` (default false). Migration translates the
legacy `album_grid_density` once: null/invalid → Auto, 1/2 → Large, 3 → Medium,
4/5 → Small. The legacy column remains for compatibility; current collection
grids use artwork size. Auto and Medium share the recommended geometry.
Settings remain installation-local. Targeted updates and full settings drafts
must preserve both new fields.

Home's recent-liked source watches the complete existing recent order; preview
callers filter downloaded content before deriving two screenfuls from pane
capacity. Liked uses one artist shelf and one album shelf before songs, and
keeps Play/Shuffle beside the song section even when only album tracks are
liked. `ContentShelf` preserves its controller on resize and shows pointer
arrows only when more content lies in that direction. Liked Albums suppresses
only its Next arrow's visual tooltip through `showNextTooltip: false`; its
localized accessible name and keyboard/paging behavior remain intact. Other
Home sampling limits remain unchanged. Album pagination checks the post-layout viewport
buffer as well as scroll events, including zero scroll extent, and stops on
loading, errors, incomplete responses, or collection exhaustion.

`AdaptiveTrackRow` and `AdaptiveTrackHeader` share pane/text-scale column
geometry. Compact rows stack metadata, medium rows separate Artist, wide rows
separate Artist and Album. Desktop columns reserve duration outside trailing
actions. Constrained mobile rows measure the formatted duration and place it at
the end of the secondary metadata line, retaining leading artwork/numbers and
48px action targets beside a flexible text block. Long metadata truncates first;
Remote labels, duration and badges may use additional lines inside that block.
Controls move below only when the remaining text area is narrower than 96px
scaled by the current text scaler, and align to the trailing edge. Duration
stays with the text. Normal artwork rows retain their 64px minimum height.
Rows with enough room keep their existing inline duration arrangement. Headers
appear only for full collections. Numbered collections set
`numberColumnExtent` to label their existing numeric area with `#` and the
accessible description Track number: 32px for album/playlist/weekly
lists and 30px within the 82px Artist Top Tracks leading area. Artwork-only
lists leave it null, and compact headers stay hidden. Specialized callers
retain their queue and playlist occurrence callbacks. Artist previews explicitly
reserve 96px for their two mobile actions.
Downloaded library rows use the same presentation; transfer progress is separate.

Desktop recommendation artwork and previews are bounded; narrow desktop panes
use the existing cover card while retaining selected identity. Touch recommendations
are manual by default. The opt-in controller advances after eight eligible seconds
and pauses at least ten seconds after interaction. Home activity, route/modals,
quick search/player overlays, lifecycle, reduced motion, dragging and at-least-half
viewport visibility gate a single timer. Desktop remains manual. Data refresh
retains a stable item or chooses the nearest remaining index.

`DesktopPlaybackProgress` always presents elapsed/total times for ordinary media,
including seek previews. Measured labels sit beside the seek bar or below it;
long scaled labels can occupy separate lines. Unknown duration uses `--:--`;
radio displays LIVE. Accessibility can grow the normal 116px player without
altering transport-button sizes. Radio uses lazy bounded 280–360px station cards
(single full-width column in narrow panes), scaled name space, a safe hostname,
play/stop controls and explicit Now Playing text. Full credential-bearing stream
URLs remain playback inputs and are never displayed in cards.

The [responsive layout plan](completed-plans/Responsive_Layout_Overhaul_Plan.md)
records the completed implementation and validation evidence; implementation
is not a claim of native Android Automotive support.

### Desktop window modes

`DesktopWindowController` owns `desktop` and `miniPlayer` modes above the
router-backed shell so branch stacks and playback survive mode changes. The OS
minimum is 560×360 logical pixels. Desktop View is valid at 800×600 or larger;
Mini Player defaults to 720×405 and uses both usable width and height to choose
its centered, constrained composition. Every Mini Player entry starts at that
canonical size while retaining the last Mini screen position; manual resizing
is allowed only for the current Mini session down to 560×360. Its volume row is
embedded below transport/actions and fills the metadata pane. A window-manager
size below 560×360 is blocked and automatically restored to 720×405. A 400 ms
settled resize across the Desktop boundary blocks the invalid surface and
requests an explicit mode decision. The last valid Desktop bounds, previous
maximized Desktop state, Mini position, and optional Mini Player
always-on-top preference are stored in `window_state.json` v3. Navis always
starts in Desktop View, restoring those Desktop bounds even when the previous
shutdown occurred in Mini Player. Invalid Desktop
bounds and prompt-triggering expanded Mini sizes are never restoration targets.
When no valid Desktop record exists, Navis begins from the useful 1200×760
Desktop candidate and clamps it to the selected display's visible work area
(which already excludes system chrome); on a smaller work area this uses the
available area while retaining the 800×600 Desktop View minimum whenever the
area permits it. Diagnostics expose only the state-record version, restoration
source (`saved`, `fallback`, or `clamped`), and persistence completion—not file
paths or monitor identifiers.
Normal native close is intercepted until the controller has finished writing
the current state record, then released through `window_manager`; a resize
immediately followed by close must therefore retain the latest valid Desktop
bounds rather than relying on an unawaited callback.
The isolated Desktop-layout diagnostics deliberately shuts down from Mini
Player and verifies the following launch starts in Desktop View at the last
validated Desktop bounds.
Mini window controls float as compact transparent icon buttons at the top-right edge,
away from the metadata pane. They disappear whenever Queue, Lyrics, or another
embedded panel is active, so those surfaces retain unobstructed controls. The
controls fade quickly instead of popping when panel visibility changes, and
their hover feedback highlights only the icon glyph. The
compact Queue sheet remains mounted for its reverse slide/fade when closed, so
button, Back, and swipe dismissal match its entrance rather than popping away.
The
default 720×405 entry uses the richer Mini Player composition; the tight layout
is reserved for smaller usable viewports. Always-on-top is shown only when the
current platform can honour the request. Linux Wayland disables the control
because normal-window stacking is compositor-owned; its stored preference is
retained for a future supported session rather than presenting a non-functional
pin.
Legacy Focus Player bounds/settings are imported once. `screen_retriever`
work areas select the display with greatest window intersection and keep the
title bar visible after display or DPI changes.

Clone-only authenticated diagnostics expose `GET /v1/presentation/window`
for mode, bounds, work area, availability, always-on-top, and pending-transition
state. `POST /v1/presentation/window` drives deterministic logical resizing,
mode selection, and transition resolution for the Linux runtime gate.

### Desktop Command System

`DesktopCommands` (`lib/src/routing/desktop_commands.dart`) centralises keyboard shortcut
handling. Commands are guarded before dispatch:

- **Text input guard** — transport and history shortcuts are suppressed when focus is
  inside any `EditableText` descendant, so they do not interfere with text editing
- **Mini Player guard** — page shortcuts are ignored while Mini Player is shown

Defaults: Ctrl/Cmd+F quick search, Ctrl/Cmd+K go to Search and focus its field,
Ctrl/Cmd+1–4 tabs (Ctrl/Cmd+2 cycles sections only on the Library root),
Ctrl/Cmd+J queue, Alt+Left/Right (Cmd+[ / Cmd+] on macOS) history, and Escape
"Close overlay". Escape's persisted action name is still `toggleNowPlaying` for
saved-binding compatibility. Quick search changes its filter with Tab, or with
the arrow keys only while its field is empty.

Configurable bindings persist per action; a saved map that predates an action
keeps that action's default. Playback speed up/down/reset (`speedUp`,
`speedDown`, `speedReset`) default to the primary modifier with unshifted `.`,
`,` and `0`, because Shift changes the logical key of punctuation on many
layouts.

## External integration policy

Navis talks to its own Subsonic server and, optionally, to external services:
Deezer, Last.fm, ListenBrainz, LRCLIB, the update feed, AutoEQ, radio station
streams and artwork the server links to. The user decides which, per service
and per feature. Everything is on by default, and a master "Online services"
switch means "Navis only talks to your server" when off. See
[the decision record](decisions/2026-10-04-external-integrations-policy.md).

- **Model** (`features/integrations/domain/integration_feature.dart`):
  `IntegrationService` (key, host, display name, verification requirement),
  `IntegrationFeature` (stable `<service>.<feature>` key such as
  `deezer.topSongs`, mapped to its service) and `IntegrationPolicy`, a pure
  value object with `==`/`hashCode`. The policy answers
  `allows(feature) = master && !disabled(service) && !disabled(feature) &&
  verified(service)`, `isUserToggleable(feature)` and `lockReason(feature)`
  (`masterOff`, `serviceOff`, `notVerified`, in that precedence).
- **Verification.** Last.fm is verified by `hasLastFmApiKeyProvider` (the bundled
  key, or a stored custom key validated on save); ListenBrainz by
  `listenBrainzTokenValid`, which the existing 401/403 handling clears. Every
  other service needs no credential. `isEnabled(feature)` is `allows` without the
  credential check, for flows that validate the credential themselves, such as
  weekly playlists revalidating a stored ListenBrainz token.
- **Storage** (`app_settings`, schema 91): `external_integrations_enabled`
  (master), `disabled_integrations` (JSON list of disabled service and feature
  keys) and `integrations_notice_dismissed`. Four features keep the column that
  already stored their switch, so no data moved and every reader and diagnostics
  script keeps working: `useLrclib` (`lrclib.lyrics`), `updateCheckEnabled`
  (`updates.automatic`), `listenBrainzScrobblingEnabled`
  (`listenbrainz.scrobbling`) and `legacyInstantMixEnabled`, **inverted**
  (`lastfm.sameVibes`; `legacyInstantMixEnabled == true` means Same Vibes is
  off). Only features without a column live in the JSON set, and a
  column-backed key found there is ignored. The migration also turns
  `listenbrainz.feedback` off for an install with a valid token and scrobbling
  off, which keeps the old coupling of feedback to the scrobbling switch; from
  then on feedback follows only its own policy switches.
- **Writers.** The three new columns are deliberately absent from the full-row
  `AppSettingsDao.saveSettings`, so a stale screen snapshot cannot overwrite
  them (`resetDefaults` resets the master and the JSON set explicitly). They are
  written only by `updateIntegrationPolicy`, `setExternalIntegrationsEnabled`,
  `updateIntegrationsNoticeDismissed` and `setIntegrationEnabled(key, enabled:)`,
  the single path for any feature or service toggle: it writes the legacy column
  for a column-backed feature and otherwise read-modify-writes the JSON set in a
  transaction. The other integration-owned columns (`useLrclib`,
  `updateCheckEnabled`, `legacyInstantMixEnabled`, the Last.fm key and the
  ListenBrainz connection) are written by `AppSettingsDao.saveSettings` only
  when given, and `SettingsRepository.saveSettings` never gives them: they
  change through `setIntegrationEnabled`, `updateLastFmApiKey` (the key
  alone) and `updateListenBrainzConnection`, so a stale screen snapshot cannot
  revert a switch, a key or a token clear. `resetDefaults` resets them through
  those writers.
- **Provider.** `integrationPolicyProvider` selects only scalar settings and the
  raw JSON string, so unrelated settings saves do not rebuild it, and it is
  **fail-closed**: while settings load or have failed it is
  `IntegrationPolicy.denyAll()`. Code that must not trust a possibly loading
  provider (queue actions, `startPreferredMix`) builds the policy from freshly
  read settings with `integrationPolicyFromSettings`. `preferredMixModeProvider`
  is Same Vibes while the policy allows `lastfm.sameVibes` and the server mix
  otherwise.
- **Update checks.** `updateProvider` reads the manual "Check now" request before
  deciding. Only the master and `updates` service switches block a manual check;
  `updates.automatic` blocks only the automatic one. The request is a plain
  field on `UpdateForceCheckNotifier`, not provider state, because the provider
  consumes it while building.
- **Weekly playlists.** `listenBrainzDiscoverStreamProvider` watches
  `isEnabled(listenbrainz.weeklyPlaylists)`. When the gate closes it clears the
  session cache and last-visible list, so the Home hero and Library › Playlists
  lose the virtual playlists at once. The check is repeated after every wait (the
  stored token, the caches, the startup idle delay), and its requests carry a
  `CancelToken` cancelled when the provider rebuilds, so turning the switch
  off while the token is read sends no token validation. Artist Top Songs
  likewise re-reads `lastfm.topSongs` after its Last.fm cache read and passes
  its `CancelToken` to `artist.getTopTracks`; the guard interceptor checks only
  the service, so feature switches rely on these call-site rechecks.
- **Enforcement, in two layers.** *Call-site gates* make a section hide itself
  instead of failing: Same Vibes (`lastfm.sameVibes`), the radio fill
  (`lastfm.radio`), artist Top Songs (`deezer.topSongs` or `lastfm.topSongs`,
  via `artistTopSongsAllowedProvider`; with neither, the section and the "This
  Is" card are hidden), scrobbling and feedback (their credential readers return no
  token), lyrics (`useLrclibProvider` is `allows(lrclib.lyrics)`; the download
  service takes a `readLyricsAllowed` callback instead of reading the column),
  the update banner and provider, the AutoEQ dialog (search still uses the
  bundled catalogue; refresh and download are disabled) and the weekly
  playlists stream. Gates use `allows(feature)`, which includes the credential
  check, except weekly playlists (`isEnabled`, see above). *The guard
  interceptor* is defense in depth. `createExternalDio(service, ...)`
  (`features/integrations/data/external_dio.dart`) builds the `Dio` of every
  external client (Deezer, Last.fm, ListenBrainz, LRCLIB, the update repository and
  service, AutoEQ, and the radio `RadioMetadataService` inside
  `NavisAudioHandler`) from `externalDioFactoryProvider`.
  `IntegrationGuardInterceptor` rejects a request, before it leaves the device,
  when the master switch or that service's switch is off. It checks the service
  level only; whether a feature is on is the call site's decision. A call the
  user started (key or token validation, "Check now", the update download and
  AutoEQ refresh/download) sets `options.extra['navis.userInitiated']` (see
  `userInitiatedOptions`) and bypasses the service switch, never the master
  switch. `ListenBrainzApiClient.validateTokenDetails` sets it only when its
  caller passes `userInitiated: true` (Integrations and onboarding), so the
  weekly stream's automatic revalidation obeys the service switch. The policy is read per request, so clients that already exist obey
  later changes. `NavisAudioHandler` receives `readRadioMetadataAllowed`, which
  `RadioMetadataService` checks before every Azuracast poll and which stops the
  polling for good when it turns false (ICY metadata, carried by the stream
  itself, is unaffected). The audio handler lives outside Riverpod, so it also
  takes a `createRadioMetadataDio` factory.
- **Server-linked images.** `ExternalArtworkImage`
  (`common_widgets/external_artwork_image.dart`) replaces the call sites that
  loaded arbitrary URLs with `CachedNetworkImage` or `Image.network`. It checks
  `integrationAllowsArtworkUri` and then loads through
  `coverArtCacheManagerProvider`; a refused URL shows the caller's own
  placeholder. `integrationFeatureForArtworkUri`
  (`features/integrations/domain/integration_artwork.dart`) is the single
  host-to-feature mapping: the user's server host (`serverHostProvider`) always
  loads; `dzcdn.net` and `deezer.com` map to `deezer.artistImages`; `last.fm`,
  `lastfm*` and `audioscrobbler.com` to `artwork.serverLinked`;
  `listenbrainz.org` and `coverartarchive.org` to
  `listenbrainz.weeklyPlaylists`; any other host to `artwork.serverLinked`.
  Radio art cannot be told by host, so its callers pass `radio.nowPlaying`
  explicitly. `CoverArtHttpFileService` repeats the check at service level
  (`allowUri`: master and service switches only) so code paths that bypass the
  widget are covered, which means radio art also needs the artwork service on.
  When station art is refused or fails to load, the fullscreen radio art viewer
  shows the same radio placeholder as Now Playing instead of a blank area.
  A load that belongs to a feature (radio art) also carries
  `coverArtFeatureHeader` (`coverArtFeatureHeaders(feature.key)`, set by
  `ExternalArtworkImage` and the two URL-style consumers); the service consumes
  it, never sends it, and asks `allowFeatureUri`
  (`integrationAllowsArtworkFeatureKey`: master, service and that feature's
  switch) at the same points as `allowUri`, so a radio download queued before
  `radio.nowPlaying` was switched off is refused instead of dispatched.
  The service checks again once a download slot is granted (a queued cover may
  wait while the policy changes) and follows redirects itself, checking every
  hop before its request is sent and forwarding caller headers only to the
  original origin; a refused hop releases the slot. The OS media session
  receives a radio art URL only while `integrationAllowsRadioArtworkUri`
  allows it: the user's own server always qualifies (Online services off means
  "only your server"), external hosts need radio metadata and the host's
  service. `NavisAudioHandler.updateRadioMetadata` publishes the original
  http(s) URL in `MediaItem.artUri` when allowed and no art when refused (the
  station placeholder shows), so AudioService, which fetches whatever it is
  given with its own unguarded cache, never sees a refused URL. Every policy
  change re-runs `updateRadioMetadata()`, which clears refused art on the next
  update. Only hosted http(s) URLs are published (a hostless `file:` URL never
  counts as the user's server). On Android `AndroidSystemArt` passes the
  http(s) URL through and drops any `file:` URI, which Android Auto cannot open.
  The art AudioService downloads itself uses a dedicated cache manager
  (`systemArtworkCacheKey`, `createSystemArtworkFileService` in
  `navis_audio_handler_bootstrap.dart`) whose file service asks
  `integrationAllowsRadioArtworkUri` after the slot wait, on every redirect hop
  and before dispatch, so an allowed URL cannot redirect to a refused host.
  Feature-tagged loads use their own cache key (`coverArtFeatureCacheKey`), so
  the cache manager never merges them with untagged downloads of the same URL
  (it keeps the first requester's headers).
  It calls `onMissingCover` only for the server's own host (`isServerUri`), so an
  external 404 never asks the server to refresh a cover id. The two URL-style
  consumers (`now_playing_screen.dart`'s radio art provider and
  `dynamic_accent_provider.dart`) apply the same check.
- **Observability.** `IntegrationCallRecorder`
  (`integrationCallRecorderProvider`) is an in-memory ring buffer (200 calls,
  100 spans) fed by the guard interceptor and by `recorder.span(name, counts,
  duration)`. It stores service, method, path (no host, query or headers),
  status, duration and `ok`/`error`/`blocked`, plus per-service counters. User
  identifiers after `/user/` or `/users/` are replaced with `*` before path
  truncation, recording and info logging. The Top Songs pipeline records its
  source fetch, local match and server match as
  spans. Source fetches that throw record `failed: 1` with zero result counts;
  completed fetches record `failed: 0`, including empty results.
- **Settings › Integrations**
  (`features/integrations/presentation/integrations_settings_screen.dart`,
  listed under Connection) is where these switches change after setup; the
  onboarding Integrations step (below) writes the master and service switches
  once, on Finish. It shows the master switch, then the services in four
  groups with a Settings-hub-style group heading (Discovery: Deezer, Last.fm;
  Listening history: ListenBrainz; Now Playing: LRCLIB, Internet radio,
  Artwork; App: Updates, AutoEQ; a group with no applicable service is omitted).
  Each service is a section: a
  `NavisSectionHeader` carrying the service switch, one line saying what is
  sent to which host, the credential (the Last.fm key field in keyless builds,
  "Key included with this build" otherwise; the ListenBrainz token field) and a
  `SwitchListTile` per feature. Every switch writes at once through
  `SettingsRepository.setIntegrationEnabled` /
  `setExternalIntegrationsEnabled`. A locked switch is disabled and its
  subtitle gives `lockReason`; master- or service-locked switches show the
  stored choice that returns when unlocked, unverified ones read as off.
  Token validation records its result with the targeted
  `updateListenBrainzConnection`, not a full-row save, and turns scrobbling on
  only for a new connection; it then refreshes the weekly playlists through
  `refreshWeeklyPlaylistsAfterTokenValidationProvider` (composition root), so
  the Integrations feature never imports Home. A saved Last.fm key is written
  with `updateLastFmApiKey`. A locked service switch's semantics label carries
  its lock reason. The Updates section is hidden where About hides
  update controls (iOS, web). Playback and About hold no copies of these
  switches; About keeps "Check now", disabled while the master or `updates`
  service switch is off. Its service names, the line about what each service
  sends and the lock reasons come from `integration_copy.dart`, shared with
  onboarding.
- **Onboarding Integrations step** (step 4 of `OnboardingScreen`). The master
  switch, then one switch per service (Deezer, Last.fm, ListenBrainz, LRCLIB,
  and Updates except on iOS and web) with the same one-line description, and
  "Fine-tune per feature in Settings › Integrations". The choices live in the
  onboarding draft (`externalIntegrationsEnabled`, `disabledIntegrations`) and
  are written on Finish, after the full-row `saveSettings`, through
  `setExternalIntegrationsEnabled` and `setIntegrationEnabled` (service keys
  only; feature switches are untouched); Finish then writes
  `updateIntegrationsNoticeDismissed(dismissed: true)`. Skip writes nothing, so
  the defaults (all on) stay and the 1.4.3 notice stays pending. Last.fm is
  locked with its reason until a key is verified (bundled, or validated in the
  draft); the key field appears only in keyless builds. The ListenBrainz
  switch is not locked by a missing token: switched on, it shows the token
  field, whose validation (`userInitiated: true`) stores the token at once as
  before. Both fields hide while the master switch or their own service
  switch is off. When setup runs
  again with Online services stored off, the guard (which reads stored
  settings, not the draft) would refuse any check, so Validate is disabled and
  the fields say to finish setup with them on and connect in Settings ›
  Integrations. Every step is built under a `Builder` below the preview
  `Theme`, so step text follows the look chosen in the first step.
- **Diagnostics.** Clone-only `GET/POST /v1/presentation/integrations` reports
  and changes the policy; read-only `GET /v1/diagnostics/integrations` returns
  the recorder's counters, calls and spans in every mode. See
  `docs/development-workflow.md`.

Deezer, Last.fm, ListenBrainz, LRCLIB and Subsonic share
`AppConstants.userAgent`, derived from the newest changelog version. A client
header regression test checks it against `pubspec.yaml` so release versions
cannot silently drift. Last.fm key unmasking accepts hexadecimal digits only;
signed or whitespace-prefixed pairs are rejected.

### Deezer and artist Top Songs

Deezer's public API (`api.deezer.com`) needs no key. `DeezerApiClient`
(`lib/src/api/deezer_api_client.dart`) is built by `deezerApiClientProvider`
through `externalDioFactoryProvider`, so the guard and the call recorder apply,
with 8-second timeouts. One `DeezerRequestLimiter` per client keeps every
Deezer feature together under 5 requests per second and 4 in flight, at most
2 of the 5 for background requests. Deezer documents a quota of about 50
requests per 5 seconds, but answered code 4 while Navis started at most 32
per 5 seconds from one IP, and at 5 per second still for 17 of the 106
requests of a fresh first launch (Home's warm-up with an artist page opened
during it). The real budget is lower than documented and may be shared with
the user's server, which also calls Deezer (a server with a Deezer remote
source searches it for every `search3`), so Navis cannot know it. Waiting
requests start in order, except that foreground ones (the artist page and
the other pages the user opens) always go before `background` ones (Home's
New Releases, its artist resolution and the Trending chart); background
requests start whenever no foreground one waits and their own rate allows.
Cancelled waiters fail promptly, even during a pause, and consume neither
the total nor the background start budget, including cancellation after a slot
is granted but before the request callback runs.
Deezer reports errors as HTTP 200 with `{"error": {"type", "message",
"code"}}`: code 4 (quota) pauses the shared limiter for 5 seconds initially,
doubling consecutive quota pause episodes up to 80 seconds. Concurrent
answers from requests already in flight share one episode. A successful answer
(including code 800) resets the backoff only if its request started at or after
the latest pause ended. The pause is set before releasing
the request slot, so every Deezer request waits it out, and the
request that hit it is retried after the pause: up to 3 times for a
foreground request, once for a background one; code 800 ("no data") reads as
an empty result, and any other code throws `DeezerApiException`. Endpoints
used so far: `/search/artist`, `/artist/{id}/top`, `/search/track`, `/artist/{id}`,
`/artist/{id}/related`, `/artist/{id}/albums` and `/chart/0/tracks`; new ones
go through `getJson` to inherit the limiter and error handling. The models (`DeezerArtist`, `DeezerAlbum`, `DeezerTrack` in
`api/models/deezer_models.dart`) are hand-written, like the ListenBrainz ones,
and round-trip through `toJson` for the cache. In some regions
`/artist/{id}/top` returns no tracks for every artist, so callers must have a
fallback.

- **Cache.** `IntegrationJsonCache`
  (`features/integrations/data/integration_json_cache.dart`,
  `integrationJsonCacheProvider`) keeps one JSON file per entry under
  `<application support>/integration_cache/<namespace>/`, with the key and
  its own expiry inside, written by rename. Clone diagnostics stay isolated
  because the directory comes from `path_provider`, which clones replace.
  `DeezerCache` holds the Deezer namespaces and lifetimes: artist name to id
  30 days ("not on Deezer" 7), artist details and related artists 7 days,
  an artist's albums and track searches 24 hours, charts 6
  hours. It replaced
  `LastFmArtistCache`; files that cache wrote (`lastfm_top_<hash>.json`) are
  no longer read. On the first cache operation, an asynchronous sweep deletes
  only root files matching `^lastfm_top_[0-9a-f]{16}\.json$`; directories,
  symlinks, nested files and other names are untouched. The initialization
  future is shared across concurrent operations; a failed root lookup is
  cleared so the next operation retries. The sweep runs once per cache instance
  (once per launch for the app-owned cache); an entry that cannot be deleted
  does not prevent cleaning up the others. Existence checks during cache
  operations are asynchronous.
- **Artist resolution.** `DeezerArtistResolver`
  (`deezerArtistResolverProvider`) uses the id of a library artist
  `ext-deezer-artist-<id>` directly. Otherwise it reads the cached mapping or
  runs `/search/artist` and keeps only artists whose `normalizeMetadata` name
  equals the library name. Between such namesakes, the one whose Deezer
  albums share the most normalized titles with the library artist's albums
  wins (up to three are compared, one request each); equal overlap goes to the
  most fans. Only when no name is equal, artists whose names
  `artistNamesMatchLoosely` become candidates: one side may carry a leading
  article the other lacks (The, A, An, Los, Las, Le, La, Les, Die, Der; two
  different articles never match, and "The The" keeps its article), "&" reads
  as "and", and spacing and punctuation are ignored. A loose candidate, even a
  single one, is taken only when its Deezer albums share at least one title
  with the library artist's (most shared, then most fans); without library
  album titles no loose match is accepted, so another artist's photo, top
  songs and Missing Albums are never bound to a page on a name alone. So "The
  Black Eyed Peas" (with "Elephunk") resolves to Deezer's "Black Eyed Peas".
  The loose comparison is for resolution only, never for display. Mappings
  are cached by server account (`integrationAccountScopeProvider`, a hash of
  the server URL and username), library artist id and normalized name, so two
  library namesakes or two accounts never share one. They carry a version; a
  "not on Deezer" cached before loose matching existed is asked again. Only a
  decision whose every lookup answered is cached: when an album lookup fails
  (a quota error, a timeout; a cancellation still propagates), the comparison
  stops, nothing is cached, and that call answers without the album evidence
  (no loose match; the namesake with the most fans), so the next visit asks
  again instead of hiding the artist's Deezer sections for a week.
- **Top songs sources** (`ArtistTopTrackSources`,
  `features/library/data/artist_top_track_sources.dart`): Deezer
  (`deezer.topSongs`) first, then Last.fm (`lastfm.topSongs`), then none, up
  to 50 songs. Deezer takes `/artist/{id}/top?limit=50`; whenever that gives
  fewer than 50 (none in some regions, a handful for niche artists: one for
  Masayoshi Soken when measured), `/search/track?q=<name>&limit=100` fills the
  list. Search tracks are kept only when their `artist.id` is the resolved id
  (results include covers and remixes by others), one per
  `normalizeMetadataKeepingEdition` title and never an edition already listed
  (so "Wonder" and "Wonder (Japanese Version)" both stay while a remaster
  folds in), most popular first. If the search fill fails, successful top
  tracks remain available and the partial response is not cached; cancellation
  still stops the load. Deezer failing or knowing nothing hands the
  whole list to Last.fm; fewer than 10 Deezer songs get Last.fm's songs not
  already listed appended, without listener counts. Each source caches its
  answer for 24 hours (the Deezer entry keeps the top and search parts; an
  entry written before the search fill reads as a miss). The result is a list of neutral `ArtistTopTrackSeed`s
  (`features/library/domain/artist_top_track.dart`: rank, title, artist,
  source, Deezer popularity, Last.fm listeners, album, length, Deezer track
  id). Only Last.fm seeds carry listeners, so only they show a number.
- **Providers** (`artist_top_tracks_provider.dart`, keyed by
  `(artistId, name)`): `artistTopTrackSeedsProvider` loads up to 50 seeds and
  stays alive 5 minutes after its last listener. The artist page's
  `ArtistTopTracksSection` watches `artistTopTracksProvider`, a
  `StreamProvider` over the first 10 seeds only; the "This Is" card watches
  the same provider, so the artist page never resolves 50. Only the "This Is"
  page (`artistTopTracksPlaylistProvider`) resolves all of them. The clone-only
  `artistTopTracksPresentationFixture` replaces the seeds.
- **Matching** (`ArtistTopTrackResolver`): remembered matches and Deezer
  tracks the library holds as `ext-deezer-song-<id>` are read in one DAO
  query; then the local pass (`getTrackMatchCandidates` and
  `pickBestTrackMatch`; a source's album and length only add confidence and
  never reject a song that title and artist alone accept);
  then `search3` for what is left, by 4 workers pulling from one queue (no
  batch barrier) with the provider's `CancelToken`, cancelled when the
  provider is disposed. Like the ListenBrainz weekly matcher, a copy on the
  server is preferred over an equally good remote result, and server copies
  the library does not hold yet are stored as provisional rows
  (`persistProvisionalSearchSongs` in `provisional_search_songs.dart`, shared
  with the weekly playlists), so the next local pass finds them. The stream
  emits after the local pass when it found songs and searches follow, and
  once at the end, so rows move at most twice and an empty first result never
  hides the section or flips the card; rows still searched in that first
  emission carry `ResolvedArtistTopTrack.isMatching`. Callers can also ask for
  that emission when nothing is found yet (`yieldPendingRows`), for progress
  batches (`progressEvery`) and for remembered unmatched songs to be searched
  again (`researchUnmatched`); Trending uses them. A search running or
  finished in this session is shared by the section and the page.
- **Remembered matches** (`ArtistTopTrackMatchStore`, namespace
  `top-songs.matches`, one file per server account and library artist; a
  store can use another namespace and keep entries longer, as Trending's
  does): seed key (edition title
  and artist) to song id or unmatched, with when it was checked; remote matches
  keep the whole song. Entries are trusted for 24 hours. Remembered library
  songs must still exist (checked by the same DAO query), and remembered remote
  and unmatched songs go through the local pass again on every visit, so a
  synced copy replaces them; they skip `search3` until they are a day old.
  A store that keeps entries longer than a day (Trending's) searches an
  older remote match again only for a copy on the server: it is never
  replaced by another remote result or lost to a failed search. A remote
  song the library holds as a row (provisional and external: one that was
  played or whose song menu opened, or an `ext-deezer-song-<id>` row) is
  treated the same way: it plays at once, but never counts as a library
  match, so the library pass and the daily upgrade-only check still run
  (the DAO's candidates leave provisional rows out).
  `artistTopTrackMatchSyncBridgeProvider` (watched by the app shell) clears the
  namespace and the session's searches after every library sync that
  succeeded fully or partly, mirroring the ListenBrainz weekly matcher, then
  refreshes the library-relative integration results
  (`refreshIntegrationLibraryResultsProvider`: the resolver, artist pages'
  Deezer ids, top songs and New Releases; Trending refreshes itself), so an
  empty Home result
  does not outlive the sync that fills the library. `clear()` and the
  store's disposal on an account change advance its generation; a resolution
  passes the generation it started under to `save`, so results computed
  before the sync or for the previous account are dropped instead of written
  back. Server-data reset on sign-out (and the library cache reset) also
  deletes the remembered matches (Trending's too) and the Deezer artist
  mappings (`clearIntegrationLibraryCacheProvider`).
- **No source.** With neither source allowed (Online services off, or both
  top-songs switches off), or when none of the first ten songs is in the
  library, the artist page shows neither the section nor the "This Is" card;
  the page's own Shuffle button covers shuffling the artist. The top-songs
  page route keeps a plain empty state ("No Top Tracks") without an action.

### Remote artist and album pages

An artist or album page whose entity the library does not hold yet (a
remote `ext-…` id from search, Fans Also Like, Missing Albums or New
Releases, or a library id not synced yet), or a remote artist without albums
or a remote album without tracks, is fetched before it shows; the page never
reads "Not Found".
- Opening runs the existing hydration through the sync controller:
  `hydrateOpenedArtist` / `hydrateOpenedAlbum`
  (`LibrarySyncController`), the same `getArtist` / `getAlbum` target syncs
  as `registerArtistInteraction` / `registerAlbumInteraction`, returning the
  result (null when none was needed or no server is signed in). Concurrent
  opens of an artist share one request. Rows land as provisional external
  rows, as before. A remote album marked hydrated without a stored track
  is fetched again (`LibraryDao.countSongsByAlbum`). Artist and album
  hydrations are covered by `NavisDatabase.transaction`'s general post-commit
  replay: the nested DAO announcements that could make a WAL reader re-read
  old rows are replayed after commit. The sync engine's explicit artists,
  albums and songs announcements remain as belt-and-braces protection. The
  pages also re-read their artist or album stream when it still misses a row
  the request stored.
- An `ext-…` id is remote whatever its row's flag says. Until the page has
  its minimum (artist: the stored artist with albums the request stored,
  even before the page's album list has read them, or a successful
  hydration that stored none; album: the stored album and, for a remote
  album, at least one track: a remote album without one never shows as an
  empty album), it shows `DetailLoadingView`
  (`features/library/presentation/detail_load_states.dart`) inside the
  page's own scaffold: an app bar with a back button
  (`NavService.back`, the Library when there is no history) and Refresh,
  the artwork and name the library or the route already has, "Loading
  Remote Artist…" / "Loading Remote Album…" ("Loading Artist…" / "Loading
  Album…" for a library id) beside a small spinner, the Remote mark, and a
  still outline of the albums or tracks to come. Everything else (photo,
  biography, Deezer sections, top songs) fills in through its usual
  providers once the page shows.
- When the request ends the page settles only on real data: the entity is
  stored (a remote album songs-hydrated, a remote artist with albums), or a
  remote artist has none and the hydration succeeded
  (`detailHydrationConfirmed`; no request, a partial or a skipped one
  confirms nothing). Loading is bounded: after `kDetailHydrationTimeout`
  (20 seconds, for example while the request waits behind a running library
  sync) the page shows the failure state, and a late answer still fills it.
  The controller remembers a successful hydration that
  found an artist without albums for the server session
  (`artistConfirmedWithoutAlbums`, cleared with the per-session hydration
  set), so a reopen that needs no request still shows the artist as empty. Anything else, including a request or library read that
  throws, a failed, cancelled or network-deferred request
  (`detailHydrationFailed`), or an artist, album or album-list stream that
  cannot be read, ends in `DetailLoadFailedView`: "Could Not Load This
  Artist/Album", Retry (which also re-reads a failed stream), and "Search
  for <name>" (artists filter, or albums with "title artist") when a name is
  known.
- The name comes from the stored row, else from the route: `NavService`
  `openArtistDetail(…, name:)` and `openAlbumDetail(…, name:, artistName:)`
  add `?name=` and `&artist=` (`AppRoutes.detailNameParam` /
  `detailArtistParam`). Every link to an artist or album that may not be
  stored passes them: search results, song menus (library, album, playlist,
  search), album artist links, the artist and album menus, AudioMuse album
  chips, Fans Also Like, Missing Albums and New Releases. Library lists and
  Now Playing links open stored entities only.
- A page showing its entity carries `detailPageShownKey`, which the
  diagnostics release-card control reads.
- Refresh (`DetailRefreshButton`, on every artist and album page) and Retry
  re-run the hydration (`refreshArtist`, `requestTarget(album)`). A page
  that already shows its entity keeps it and reports a failed refresh with a
  notice.

### Deezer on the artist page

Three more artist-page features use Deezer, each behind its own switch and
each hiding itself or falling back when the switch is off, Deezer has nothing
or a request fails. The providers are in
`features/library/presentation/artist_deezer_providers.dart`, keyed by
`ArtistPageKey` `(artistId, name)`. They share `artistDeezerIdProvider` (the
resolver above), which is only watched after a feature switch has been
checked, so with all three off the page sends nothing to Deezer.
`DeezerCatalog` (`features/integrations/data/deezer_catalog.dart`,
`deezerCatalogProvider`) reads `/artist/{id}`, `/artist/{id}/related`,
and `/artist/{id}/albums` through the disk cache: artist details and related
artists 7 days, albums 24 hours, "not on Deezer" included; errors are not cached. The resolver shares one resolution between
callers asking for the same library artist and name at once (Top Songs and
these sections on a first visit).

- **Header photo and fans** (`deezer.artistImages`,
  `artistDeezerDetailsProvider`). `artistHeaderImageUrls`
  (`features/library/domain/artist_header_image.dart`) lists the server's
  photo (large, else medium), then Deezer's `picture_xl`. Empty strings, URLs
  that do not parse, Last.fm's grey star (`isLastFmPlaceholderUrl`, hash
  `2a96cbd8b46e442fc41c2b86b821562f`) and Deezer's picture without a hash are
  left out, and the integration policy filters the rest. The header tries
  them in order: a photo that fails to load hands over to the next after the
  frame, and the plain name header is the last step, never a blank box.
  Failures of photos no longer offered are forgotten, and pull-to-refresh
  gives the header a fresh state, so failed photos are tried again. While
  the server's artist info loads, the name header stands in. The summary line
  under the name is "12 albums • 4.1M fans" (`artistDetailFanCount`, compact
  format). Its album count, and the "Biography · N albums" title, is
  `artistPageAlbumCount`: the larger of the artist row's count and the
  page's listed albums, so the remote albums that opening the page stores
  (an Octo-Fiesta artist list counts only local ones) update it as they
  arrive. The "This Is" card uses the same first photo.
- **Fans Also Like** (`deezer.similarArtists`,
  `artistFansAlsoLikeProvider`). Deezer's related artists are matched to the
  library by `normalizeMetadata` name through
  `libraryArtistNameIndexProvider` (`LibraryArtistNameIndexCache` in
  `features/library/data/library_artist_name_index.dart`): one index of every library artist, keyed in a background isolate for more
  than 64 artists, kept until the artists table changes (drift
  `tableUpdates`, so a sync or a remote artist written by search marks it
  stale) and rebuilt on the next lookup, so a sync's many artist batches cost
  one rebuild and an artist page costs one map lookup per related artist.
  Between library namesakes a server artist beats a remote one, then more
  albums. `fansAlsoLikeEntries`
  puts library artists first, each group in Deezer's order, and drops the page
  artist. `SimilarArtistsSection`
  (`features/library/presentation/similar_artists_section.dart`) draws it in
  the same two-row grid as the server's Similar Artists, which it replaces when
  it has artists: library artists keep their art and open their page; others
  show the Deezer photo with the Remote mark and open the server's remote
  artist `ext-deezer-artist-<id>` (`SimilarArtistEntry.deezerArtistId`) on a
  remote artist page (see *Remote artist and album pages*), which offers a
  search for the name when the server cannot provide it. The server's Similar Artists
  show as soon as Deezer has nothing or fails, or when Deezer has not
  answered within 2.5 seconds (`kFansAlsoLikeServerFallbackDelay`); whichever
  list shows first stays, so a late Deezer answer never swaps it.
- **Missing Albums** (`deezer.missingAlbums`, `artistMissingAlbumsProvider`).
  Hidden, without asking Deezer, while the library albums load, when the
  artist is remote or when any of its albums, own or Featured In, is remote:
  the server's remote catalogue (Octo-Fiesta) always wins. Otherwise `missingDeezerAlbums`
  (`features/library/domain/missing_albums.dart`) keeps record types `album`
  and `ep` (singles belong to Home's new releases, compilations are left out),
  drops a Deezer album that a library album (own or featured) holds as
  `ext-deezer-album-<id>` or under the same `normalizeMetadataKeepingEdition`
  title, so remaster and deluxe packaging match while "(Japanese Version)"
  stays its own album, and lists them newest first, one per edition. A
  `ContentShelf` of `ExternalAlbumCard`s (`common_widgets/`, the `AlbumCard`
  look and `AlbumCardLabel`, with a policy-checked cover URL) follows the album
  grids, subtitled "2021 • EP". Cards take `ContentLayout.shelfCardExtent`,
  the size Home's album carousels also use (smaller under Home's compact
  density). A card opens the server's remote album `ext-deezer-album-<id>`
  (`remoteDeezerAlbumId`) with its title and artist as route names, on a
  remote album page that plays like any album and offers a search when the
  server cannot provide it. The card takes the feature it belongs to, so
  Home's new releases reuse it; its "2021 • EP" label and cover come from
  `features/integrations/presentation/deezer_release_labels.dart`. (The
  release sheet with a "Search your server" button that cards opened before
  was retired in favour of these pages; the user expects a missing album to
  open and play like any album.)

### Deezer on Home

**Section order.** `HomeSectionIds.resolveOrder` and `resolveHidden`
(`features/home/domain/home_section_ids.dart`) turn the saved order and hidden
list into what Home shows; Home, the onboarding artwork warmup and the
Appearance reorder list all use them. A default section a saved order lacks,
such as one added in a later version, goes right after its nearest default
predecessor that is present; unknown and repeated ids are dropped. A saved
hidden list decides every section the user has seen; a section hidden by
default that is in neither saved list (added after 1.4.2) stays hidden.

**New Releases** (`deezer.newReleases`, section id `new_releases`, right under
You Might Like in the default order; a saved order that lacks it gets it
there, one that already places it is left alone). `homeNewReleasesProvider`
(`features/home/presentation/home_deezer_providers.dart`):
- Candidates are up to 30 library artists from `LibraryDao.getTopPlayedArtists`:
  by the summed play count of their songs, liked artists first among equal
  counts; artists without plays count only when liked. When fewer than 30
  qualify (a new account with little play history),
  `LibraryDao.getArtistsByLibraryWeight` fills the rest, ranked after them:
  most liked albums, then most songs, then most albums, leaving out remote
  artists, artists without songs or liked albums, "[Unknown Artist]" and
  "Various Artists". With the switch off, no signed-in account or no
  candidates it returns nothing without asking Deezer. It watches the
  account scope, so signing out empties it and another account recomputes it.
- It then waits for `homeDeezerIdleProvider`: no library sync running, then 3
  seconds (`homeDeezerStartupDelayProvider`), then again no sync running (one
  may have started meanwhile), once per session.
- Three workers read each artist's Deezer id through the resolver (artists it
  cannot identify are skipped) and its first five releases
  (`DeezerCatalog.recentArtistAlbums`, `/artist/{id}/albums?limit=5`, cached 24
  hours apart from the full list), all as background requests: the Deezer
  limiter starts any waiting artist-page request first, so Home's warm-up
  yields to the page you open. An artist whose request fails is skipped;
  the provider lives for the session, and invalidating it (pull to refresh)
  or switching the feature off cancels the requests. The
  `home.newReleases` span counts artists, resolved, failed, releases and those
  in the library.
- `selectNewReleases` (`features/home/domain/new_releases.dart`) keeps releases
  from the last 30 calendar days (today included, announced future dates
  excluded), newest first with the higher-ranked artist first on a tie, one
  per Deezer album and one per edition title of an artist (Deezer lists clean
  and explicit releases apart), at most 12. `libraryAlbumIdForRelease` links a
  release to the library album stored as `ext-deezer-album-<id>` or with the
  same `normalizeMetadataKeepingEdition` title.
- The section hides itself while it first loads, fails or is empty, and under
  the downloaded-only and liked-only filters; a refresh keeps the shown cards.
  `HomeNewReleasesShelf` (`home_new_releases.dart`) is Home's album carousel of
  `ExternalAlbumCard`s: two lines, title and artist, like the other album
  carousels.
- A tap (`openHomeNewRelease`) opens the library album when linked; else the
  server's remote album `ext-deezer-album-<id>`, named by the release title
  and artist, on a remote album page (see *Remote artist and album pages*).
- The onboarding warmup returns no artwork for it, so onboarding never asks
  Deezer. Pull-to-refresh invalidates it.

**Trending Now** (`deezer.trending`). No shelf of its own: a virtual playlist
in the You Might Like hero, after the ListenBrainz weekly playlists and before
the albums, and in Library › Playlists right under the weekly playlists. It
works like the weekly playlists. `homeTrendingProvider`
(`home_deezer_providers.dart`, a `StreamProvider`):
- Returns nothing without asking Deezer while the switch is off, no account
  is signed in or the library has no artists (it watches the account scope,
  like New Releases); otherwise waits for `homeDeezerIdleProvider` and reads
  `/chart/0/tracks?limit=100` (`DeezerCatalog.chartTracks`, cached 6 hours)
  as a background request.
- Matches every chart song with the top-songs matcher on its own resolver
  and store (`trendingTrackResolverProvider`, `trendingMatchStoreProvider`:
  namespace `trending.matches`, key `deezer-chart`, per account, entries kept
  14 days): remembered matches and `ext-deezer-song-<id>` rows, the library
  pass, then `search3` for every song left, whoever the artist, with remote
  results allowed and server copies preferred and stored as provisional rows.
  Remembered remote and unmatched songs are searched again once a day; a
  remote match is then only upgraded to a server copy.
- Emits every chart row at once (`yieldPendingRows`), the unsearched ones
  `isMatching`, then the final rows; unmatched songs stay as rows, so the
  numbering has no gaps. Two searches run at once. A pull to refresh (or the
  page's Retry) calls `homeTrendingRefreshProvider.refresh(manual: true)`:
  six at a time, an update every six finished searches, and remembered
  unmatched songs searched again. That mode applies only to the run the
  request starts (`HomeTrendingRefreshNotifier.takeManual`); any later
  rebuild, such as a switch toggled, is automatic again. A refresh or
  turning the switch off cancels the searches.
- A library sync does not clear its store: `homeTrendingSyncRefreshBridgeProvider`
  re-runs it after a sync that succeeded fully or partly (unless a refresh
  started meanwhile, as Home's pull to refresh does), so the library pass
  picks up synced copies and only songs due for their daily check are
  searched. Sign-out and the library cache reset clear the store.
- Spans: `trending.localMatch`, `trending.serverMatch` and `home.trending`
  (`chart`, `playable`, `remote`, `manual`).
- `homeRandomShowcaseProvider` adds it as a `HomeRandomShowcaseTrending`
  (`HomeRandomShowcaseTrending.forHero`) once at least 8 chart songs are
  playable, unless the downloaded-only or liked-only filter is on; under them
  `homeTrendingProvider` is not even read.
- `playlistLibraryItemsProvider` adds a `PlaylistLibraryItem.trending` after
  the weekly playlists while the switch is allowed and an account is signed
  in, whatever the chart holds (rows are still loading, or there is no chart
  yet), so it can always be found. The virtual rows also stay listed, on
  their own, while the server playlists load or fail to load; a failure
  then shows as the usual error state (with Retry, which reads and syncs the
  server playlists again) as a row under them. Its id `virtual:trending:deezer`
  (`NavService.trendingPlaylistId`) makes `NavService.openPlaylistDetail`
  open the Trending page. The row shows the chart's covers and "N of M
  available • Deezer", like the weekly rows' "… • ListenBrainz".

**Hero items.** `HomeRandomShowcaseItem` is `sealed`: a
`HomeRandomShowcaseAlbum`, or a `HomeRandomShowcasePlaylist` (sealed too:
`HomeRandomShowcaseListenBrainz` or `HomeRandomShowcaseTrending`). The hero
widgets switch over them exhaustively. Playlists share one look through
`isLoading`, `coverArtIds` and `localizedTitle`: a `PlaylistCoverMosaic`
(`listenbrainz_playlist_artwork.dart`; weekly playlists show ListenBrainz's
own image when there is one), the title, an availability line ("12 of 50
available", "12 tracks available, matching") and a reason ("ListenBrainz", "Popular
on Deezer"). Tapping a playlist opens its page; only albums show Play. On
desktop a playlist's page lists its songs, Trending's numbered by chart
position with unmatched songs in place; a row plays like a weekly song (the
whole playlist's playable songs from it with Album Queue on, match flows
collapsed).

**1.4.3 notice** (`IntegrationsNoticeCard`,
`features/integrations/presentation/integrations_notice_card.dart`). A
one-time row in the What's New row's place: "New in 1.4.3" and "Navis can now
use Deezer for top songs, artist photos and new releases. Review
integrations." `integrationsNoticeVisibleProvider` shows it once settings have
loaded, `integrations_notice_dismissed` is false and onboarding is complete
(`onboardingRequiredProvider == false`); Home then shows it instead of
`ChangelogDiscoveryCard`, so the two never stack. Tapping it opens Settings ›
Integrations; tapping it or its close button writes
`updateIntegrationsNoticeDismissed(dismissed: true)`, after which the What's
New row returns if the release is unseen. Finishing onboarding (not skipping
it) also marks it seen, from the onboarding Integrations step. The notice and
the What's New row draw the same frame, `HomeNoticeCard`
(`common_widgets/home_notice_card.dart`: surface, optional leading widget,
title, subtitle and close button); each keeps its own text and actions.

**Trending page** (`AppRoutes.trending`, `/library/trending`,
`NavService.openTrending`). `TrendingDetailScreen` shows
`RankedVirtualPlaylistContent`
(`features/library/presentation/ranked_virtual_playlist_content.dart`), the
layout extracted from the "This Is" page so both share it: artwork, title,
"Deezer chart • 100 songs • 40 of 100 available", Play/Shuffle/Download and
rows numbered by `ResolvedArtistTopTrack.rank`. Rows use the weekly
playlists' treatment (`TrackMatchStatusLabel`, shared with them): a song
still searched shows "Matching" and a disabled hourglass; one found nowhere
is faded with "Not on server" and a Search action; a playable song (library
or remote, with the Remote mark) plays on tap and opens the song menu on
long press, right click or its menu button. A remote song not stored yet is
stored as a provisional row first, as playing it would, so the menu's
queue actions work and its album and artist open as remote pages through
the server.

## Update Checker

The in-app update checker lives in `lib/src/features/settings/`:

Settings › Integrations › Updates holds the automatic check
(`updates.automatic`); About keeps "Check now", which only the master and
`updates` service switches block.


- `data/update_repository.dart` — fetches the Forgejo Releases API, filters by update
  channel, parses semver, and selects the correct platform artifact using
  `detectInstallMode()`. Returns `UpdateInfo` (with `downloadUrl` and `assetFileName`)
  when a newer version is available.
- `data/update_service.dart` — downloads the release artifact into the system temp
  directory and applies the update. Distribution is resolved at runtime:
  - **Forgejo/sideload Android APK builds** (`NAVIS_SELF_UPDATE=true`) download the
    APK and invoke the system installer via a gated `MethodChannel`.
  - **Google Play installs** (detected via install-source metadata, or Play AAB builds
    with `NAVIS_SELF_UPDATE=false`) open the Play Store listing instead of sideloading.
  - **Desktop** runs a platform-appropriate apply strategy:
  - **Linux deb:** `pkexec dpkg -i` + relaunch.
  - **Linux portable / Windows portable / macOS:** extracts the archive to a staging
    directory, writes a self-deleting shell/batch script with rollback logic, launches it
    detached, and exits. The script replaces the running bundle, relaunches the app, and
    cleans up automatically.
  - **Windows installer:** launches the Inno Setup installer with `/SILENT /CLOSEAPPLICATIONS`.
- `data/update_install_mode.dart` — `UpdateInstallMode` enum and `detectInstallMode()`
  function. Detects the current install type from filesystem heuristics (e.g. presence of
  `unins000.exe` for Windows installer mode; executable under `/opt/navis` for Linux deb).
- `data/archive_utils.dart` — cross-platform archive extraction (`tar`, `ditto`, PowerShell
  `Expand-Archive`).
- `data/update_scripts.dart` — generates the platform-specific updater scripts (`.sh` for
  Linux/macOS, `.bat` for Windows). Scripts include rollback on failure and self-delete
  after successful update.
- `domain/update_info.dart` — immutable value object with an `UpdateDelivery` mode.
  `downloadUrl` holds the direct asset URL for self-update paths; Play redirects omit it.
- `domain/update_delivery_resolver.dart` — maps platform, build capability, and Android
  install source to `UpdateDelivery`.

### Write-access guard

Before starting any download, `UpdateService.canApplyUpdate(mode)` probes the target
directory for write access. If the directory is not writable (e.g. app installed to
`/Applications` by an admin user, or a read-only portable location), the update dialog
shows a "Download Manually" prompt linking to the release page instead of attempting
a doomed automatic update.

### Startup cleanup

`UpdateService.cleanupStaledUpdates()` is called on every desktop app launch. It removes
any `.backup` directories and orphaned staging dirs left behind by a previous update
script, preventing accumulation of stale files.

### Update channel

The update channel (`stable` or `dev`) is baked in at compile time via
`--dart-define=NAVIS_UPDATE_CHANNEL=dev`. The `dev` channel matches release assets prefixed
with `navis-dev-`, while the `stable` channel matches assets prefixed with `navis-`. This
ensures sidecar/dev builds never suggest a stable release as an upgrade.

The Last.fm API key used by "Same Vibes" instant mix mode is injected at build time as a
masked pair, `NAVIS_LASTFM_API_KEY_MASKED` (key XOR a per-build random pad) and
`NAVIS_LASTFM_API_KEY_PAD`, both hex, passed through `--dart-define-from-file`.
`AppConstants.lastFmApiKey` XORs them back once at runtime and returns an empty key for a
missing, malformed or mismatched pair. A plain `NAVIS_LASTFM_API_KEY` define is still accepted
when the pair is absent so local dev runs work. Masking deters casual extraction and is not
secrecy: a Last.fm API key is a client identifier and no shared secret is used. See
[ci-cd.md](ci-cd.md#lastfm-key) for the build scripts and the post-build artifact scan.

### Recommendation sessions

Song-based **Server Mix** and **Last.fm · Same Vibes** are the two Instant
Mix modes. Settings › Integrations › Last.fm › "Same Vibes mixes" chooses
between them (`preferredMixModeProvider`); Server Mix is used whenever the
policy does not allow `lastfm.sameVibes`. Server Mix calls the standard Subsonic `getSimilarSongs2` endpoint,
then the original `getSimilarSongs` when unsupported. The existing Navidrome
`getInstantMix` endpoint is a final compatibility fallback only when both
standard endpoints are unsupported. AudioMuse's installed Navidrome plugin
answers the standard similarity calls through the server; the client neither
calls AudioMuse directly nor attributes generic server results to it.

A mix starts from the song its caller chose, which need not be the one
playing (Android Auto starts mixes from browsed songs): the first refill uses
the requested seed and later refills follow the current song. Starting a mix
keeps only the seed in the queue, so the first refill treats only the seed as
already queued; songs from an earlier mix still behind it are fair
recommendations again. Similarity endpoints know only server ids, so a remote
seed (an Octo-Fiesta `ext-` id) mixes from the library copy `getSong` maps it
to, when the server has one: Server Mix asks for that copy before reporting
unsupported, and Same Vibes looks it up (even while the remote seed plays) for
its server fallback. Neither mode queues the copy or the remote original right
behind the seed. A remote seed
without a library copy never borrows the similar songs of an unrelated queue
neighbour. Same Vibes tells queued and merged songs apart by one identity,
`sameVibesCanonicalSongKey` (`normalizeMetadata` artist and
`normalizeMetadataKeepingEdition` title), so a Japanese and an English edition
of a song are both kept.

Home and Android Auto **Instant Radio** use `PersonalRadioNotifier` and the
queue-independent `RecommendationService`. Radio starts with likes and up to
60 distinct recent songs, combines server and Last.fm library matches with
familiar anchors, and fills remaining positions from eligible local songs.
Home captures Liked only and Downloaded only at start. Offline playback uses
verified permanent downloads and, unless Downloaded only is selected, valid
rolling cache files. Android Auto starts the same policy without Home filters.
The Home action awaits an actual queue insertion before opening Now Playing.

`RecommendationSessionCoordinator` owns one generation and cancellation token
across these automatic modes. Replacement queues, queue clear, internet radio,
server session changes, sign-out, or another recommendation activation
invalidate ownership. The queue controller checks ownership within its
serialized recommendation append and reports IDs actually inserted. Every
initial failure reports the session `failed` with an error category, so its
status never stays `preparing` after the mode gave up. Starting a mix supersedes
any refill still running for the previous one: the new session's first refill
starts at once (only a refill of the same session blocks another), and the
superseded refill's songs, errors and retries are dropped by session identity:
none of them may change the new mix's queue (retain or append), state or session
status. A failed initial fetch leaves the existing queue alone; failed initial
queue commits attempt to restore the previous queue and play state. Persisted
recommendation tracks restore as an ordinary queue after restart, without
restarting refills.

## Data Flow

### Playback Flow

1. User taps album/track → `QueueController.replace()`
2. Queue controller calls `NavisAudioHandler.replaceQueue()`
3. Audio handler resolves sources via `PlaybackSourceResolver`
4. Source resolver checks: permanent cache → rolling cache → stream
5. Audio handler updates structural state through `playbackSnapshotProvider`
   plus lightweight timeline updates through `positionStream` and the
   track-keyed `bufferStateStream`
6. UI reacts to structural snapshots without rebuilding for routine position
   or buffer ticks; timeline widgets subscribe to the lightweight streams

Artist Play, Shuffle, and Add to Queue share `ArtistPlaybackController` and
`ArtistPlaybackResolver`. A transactional DAO snapshot applies the same primary
and Featured In release membership as the artist page, then selects all tracks
by album ID, including remote editions and directly credited loose tracks.
Artist metadata is refreshed through the existing targeted sync lane; only
incomplete albums request track hydration. Artist metadata refresh preserves
completed album track snapshots, including provisional remote albums. A larger
advertised track count reopens a previously complete album; mixed local/external
responses may validly contain more rows than the local count. Invalid
artist identities, duplicate release IDs, and underfilled advertised release
lists produce a partial result without replacing stored metadata.

An artist action publishes the first transactional local snapshot immediately;
known playable tracks start through the handler's existing two-phase load before
metadata hydration finishes. With no local tracks, the first available album
starts playback as soon as its target completes. Missing local releases are
hydrated first, then artist metadata is refreshed and newly advertised or enlarged
releases are hydrated. Each snapshot admits only new song IDs in a batch, so
background filling never replaces or restarts an already started queue. The
artist page shows compact progress and an optional stop-loading button; menus
close normally, navigation and playback controls remain available, and no
preparation or failure modal appears. Identical in-flight submissions coalesce;
a different artist or action starts a new selection.

The controller reserves the queue selection generation and rejects late work
after another selection, queue clear, recommendation/radio activation, session
change, or cancellation. Stopping loading preserves playback and stops further
admissions; already admitted native work and shared sync work may finish. Empty
results cannot clear the queue. Offline selection verifies permanent/rolling
cached audio through the storage locator abstraction; online remote tracks retain
direct streaming. A failed starting source advances to the next known track.
Identified tracks omitted by preparation stay in `retainedArtistQueueProvider`
as grey removable rows in both queue views, separate from native playable
indexes. These retained rows last for the current session and clear on queue
replacement/clear, radio, or account changes. Unresolved releases with no track
identities cannot create queue rows. Songs the handler drops after accepting
them (a deferred song that cannot be prepared when released, a move into the
window that fails, a rebuild that cannot prepare a song) are published on
`NavisPlaybackHandler.droppedSongsStream` as `QueueSongsDropped`;
`artistQueueDropRetentionProvider`, kept alive by the app shell with a direct
stream subscription, adds those that belong to the artist queue still in the
player to the same retained rows.

Play orders known releases chronologically and tracks by disc then track. Newly
loaded tracks join the upcoming queue in that order while keeping the current
song and played prefix in place: each admit is one `insertQueueRuns` edit with
one contiguous run per release. Shuffle randomizes available tracks and merges
each new batch at random upcoming positions with one `mergeIntoUpcoming` edit,
without restarting the current song. The current song and the next two keep
their place. Once part of the queue is deferred (see Released queue window),
every song the player holds keeps its place too and new songs are merged among
the deferred ones in Dart only, so an admit makes no native call and never
races a crossfade deck; before that, the rest of the upcoming queue is merged
in Dart after one native range removal. Either way an admit costs O(1) native
operations however many songs it carries (per-song moves made a remote-heavy
artist's Shuffle quadratic and flooded the media session). After a hydrated release, the resolver re-reads
only that album (`getArtistPlaybackAlbum`) instead of the whole catalogue.
Once a user edits the queue, filling preserves that order and appends subsequent
batches. Removed song IDs are not reintroduced by later snapshots. Artist Add to
Queue uses the same incremental batches and preserves every existing occurrence;
ordering applies only to the new suffix. Native append prepares sources
independently and continues past an unavailable source or failed insertion,
then persists successful entries. Upcoming reorders also persist through the
native handler without resetting playback position.
These whole-artist actions disable Match Flow expansion to preserve the selected set
and remote source identities.

Android Auto artist playback still uses its separate local-only album traversal;
sharing this preparation policy and an appropriate car failure surface is a
follow-up, outside this phone/desktop change.

Equalizer state lives in `equalizerProvider` / `EqController`, with a dedicated
`EqRepository` and v85 `eq_presets` / singleton `eq_state` storage. The singleton
atomically persists selection, current curve, and per-preset/per-mode workspaces.
Saved presets, drafts, temporary previews, and applied audio state are separate;
master bypass does not mark a preset modified. The graph editor owns only selection
and temporary text input. Identity-bound graph sessions publish immediate working
curves, coalesce native previews, checkpoint at most every 250 ms, and flush the
final atomic workspace on release or backgrounding. Numeric previews become a
persistent draft only on Done; cancel restores the previous curve. One gesture is
one Undo step. Graph geometry maps authored parameters independently of headroom
and resolves overlapping pointer targets; import previews reuse its renderer.
`EqualizerScreen` composes presentation-only pieces — `EqGraphEditor` with its
`EqGraphPainter`, `EqBandInspector`, `EqNumberEditor`, and `EqActionBar` — and
chooses stacked or side-by-side layouts from `AdaptiveContext` and constraints;
none of them own persistent state or issue native commands directly. The root
hydrates EQ before audio creation; general settings saves omit its fields.
The handler applies typed configurations to both decks and reports desired
versus applied status. Android uses the vendored just_audio Media3 PCM processor;
Linux's and Windows' tracked media-kit adapter owns a combined EQ/tempo chain
(Windows on the pinned full libmpv, see [release-windows.md](release-windows.md#bundled-libmpv)).
`navisEqualizerSupported()` decides availability for both the controller and the
handler; unsupported backends disable the entry. Modes, exact preset semantics, AutoEQ provenance,
headroom, migration, and validation limits are maintained in
[equalizer.md](equalizer.md).

Speed and pitch share a long-lived `playbackAdjustmentsProvider` controller.
Speed is stored and displayed as a multiplier (`1.00×`); independent pitch uses
signed semitones. `PlaybackAdjustments` owns `lockPitchToSpeed` and derives the
effective pitch centrally: locked engine pitch equals speed exactly, while the
readout is `12 × log₂(speed)` rounded to two decimals. Unlocking captures the
full-precision derived semitone value, preserving the sound. Speed-only reset
retains lock; combined reset applies the immutable built-in preset shown as
Normal (stored id `none`: 1×, zero pitch, lock off); new presets cannot use the
names None or Normal. The lock is labelled "Pitch Lock" ("Match pitch to speed.").

Player quick panels share `showQuickPanel`/`QuickPanelScaffold`
(`common_widgets/quick_panel.dart`): a pinned title with a live summary, an
optional header control, a scrolling body with edge fades that appear only
where more content lies, and an optional pinned footer. Desktop runtimes host it
in `showDesktopAnchoredPopover`, which grows from the anchor, draws a tail at it,
and lets the transparent barrier swallow the next click so pressing the same
button again closes the panel. Touch layouts use a content-sized bottom sheet
capped at 88% of the screen; because sheets extend behind Android's navigation
bar, the last pinned row adds the live bottom padding (3-button, gesture or
none) plus any keyboard inset.

`showPlaybackAdjustmentQuickPanel` (`playback_quick_actions.dart`) puts the same
`PlaybackAdjustmentPanel` used in Playback Settings into that shell, with its own
header and combined reset moved to the pinned header and footer. Entry points are
`PlaybackSpeedQuickButton` beside Repeat in the Now Playing transport and desktop
player bar, the Speed & Pitch row of the Now Playing settings sheet/panel, and the
compact desktop Mini Player menu. The button shows the multiplier when speed is
not 1× and tints its icon for pitch-only changes. Both quick buttons share
`quickActionGlyphSlot`, so the transport row is symmetric and Play stays exactly
centred; backends without EQ keep an invisible same-size slot. Compact rows
narrower than 360 logical pixels switch to dense slots with no gaps, drop the
quick buttons only below 296 (440 non-compact), and yield to the desktop volume
slider; the desktop bar drops EQ first below its compact breakpoint.
The transport is symmetric around Play on every platform: Equalizer, Instant
Mix (or Same Vibes, via `togglePreferredMixMode`), Previous | Play | Next,
Repeat, Speed. Shuffle reorders the queue, so it lives in the queue header
(`QueueShuffleToggle` in `features/player/presentation/queue_shuffle_controls.dart`).
While shuffle is on, `QueueShuffleBadge` marks the phone and desktop Queue
buttons, and their accessible labels read "Queue, shuffle on". The compact
Mini Player keeps Shuffle in its More menu. The phone Now Playing action row
is Queue, Like, Lyrics and Settings.
Configurable desktop shortcuts (default Ctrl/Cmd+`.`, `,` and `0`) step speed by
0.10 or reset it through `nudgePlaybackSpeed`, preserving pitch settings, and
confirm with an app notice.

`EqualizerQuickButton` sits beside Instant Mix in both the Now Playing
transport and the desktop bar, and is hidden when `eqCapabilitiesProvider` is unsupported. It opens
`showEqualizerQuickPanel`, a mini equalizer built from `EqQuickControls`
(`features/equalizer/presentation/eq_quick_panel.dart`): the on/off switch in the
header, a read-only `EqGraphEditor` response (176 px in the panel, 136 px
inline, fitted to at least ±12 dB so gentle curves stay visible, dimmed while
off) that opens the full page, and a preset `DropdownMenu` ordered Custom (only
with a draft or while selected), your presets (imports marked with headphones),
then built-ins; its menu scrolls, so any number of AutoEQ profiles stays
compact. Choosing an entry selects it with
`selectPreset(enable: true)`, so picking a sound also turns the EQ on; drafts are
kept exactly as on the full page. The Now Playing settings sheet and the wide
settings panel show the same controls inline as `EqQuickCard` in a "Sound"
section; unsupported backends keep the disabled
`EqualizerEntry` explanation. The settings sheet is a draggable
`DraggableScrollableSheet` and returns a follow-up action, so Speed & Pitch or
the Equalizer page opens only after it has closed.

`NavService.openEqualizer` records whether Now Playing was expanded or Mini
Player active and restores that when the pushed page is popped back to the same
location (not when the person navigates elsewhere). Mini Player first returns to
the full view because `/settings/equalizer` lives in the Settings branch; when
it cannot, the page is pushed over Mini Player. `NavService.closeEqualizer`
flushes edits and pops (Settings when there is no history); the desktop back
arrow and the selected "Close Equalizer" state of `EqualizerQuickButton` (shown
while `GoRouter.state` is on the page) both use it.

Existing precise settings and presets stay exact until that
control is edited; approximation markers distinguish them from the hundredth grid.
New input uses integer hundredths: rulers/arrows/accessibility actions step 0.01,
Shift+Arrow and speed buttons step 0.10, independent pitch buttons step one
semitone; holding a − or + button repeats every 120 ms and persists once on
release. Speed quick-pick chips (0.5×, 0.75×, 1×, 1.25× and 1.5×, filtered by the
backend range) select values in one tap. The chips sit in equal-width slots, so
1× stays centred. Large text falls back to a centred wrap. Presets use a `DropdownMenu` (Custom while edited, Normal,
then saved presets; unsupported ones disabled) with a ⋮ menu to save, update,
rename or delete (with confirmation) the current or originating preset. Exact entry allows two decimals and decimal
commas, validated inline.

Rulers move continuously under a fixed marker with ticks at 0.01 and labels at
0.10 (eight logical pixels per minor tick). They sit flat on the panel with no
fill, glow or outline; a `primary` outline appears only as the keyboard focus
ring, and outer 15% fades show the scale continues. Accent is reserved for the
plain 2 px marker and the neutral line (1.00× speed, 0 semitones), which rises
above the other ticks as a detent mark; range endpoints keep a long tick in the
base color. Tick labels and the value readouts use tabular figures so they do
not shift while dragging. Release settles onto the
nearest supported tick over 140 ms with ease-out motion; the animation never
writes to the engine. Values chosen elsewhere (chips, presets, reset, the − and +
buttons, or pitch following speed) cancel any gesture and glide to the new value.
The glide eases in and out over 160–480 ms, scaled to distance, and ticks for each
line it crosses as a drag would. A read-only (locked) ruler glides silently.
Reduced motion jumps immediately. Drag accumulators clamp at
finite bounds so reversing at an endpoint responds immediately. While dragging,
`rulerTickFeedback` reports the strongest ruler line crossed per update: every
0.01 line gives a selection click (throttled to one per 12 ms of pointer time),
0.10 lines a light impact and the neutral value a medium impact; release
settling and keyboard steps stay silent, and the platform touch-feedback setting
applies. The − and + buttons sit at the ends of the ruler they move, in a row
kept left-to-right because the scale always puts lower values on the left.
Speed has no separate Reset (its 1× chip does that); Pitch shows Reset beside
its heading only while it differs from 0 semitones. Endpoint feedback and the
available bounds appear only once a limit is reached, explaining the disabled
button. With Pitch Lock on, the pitch heading shows a link icon ("Follows playback speed" as tooltip and label), the ruler is read-only at full contrast (`AdjustmentRuler.readOnly`) and still glides with speed, and the inert − and + buttons and Reset are hidden; invisible stand-ins keep the pitch ruler as wide as the speed ruler. Unsupported
backends hide the pitch control and lock and show a single availability note.

Capabilities follow the initialized backend, including debug macOS and fallback.
Android Media3 limits speed/pitch factors to 0.1–8. Desktop media-kit uses mpv
pitch (0.01–100) and scaletempo speed/pitch ratio (minimum 0.01). Selectable
ranges account for the other value and lock mode, rounding finite ends inward
onto hundredths while retaining genuinely unbounded ends. Invalid pairs are
rejected before native setters. Unsupported linked presets remain saved and
visibly unavailable. Restoration retains supported speed with unchanged pitch
and a notice; it does not rewrite presets.

The controller coalesces previews, serializes application and database writes,
and flushes on interaction completion and panel dismissal. Handler confirmed
adjustments streams (including platform wrappers) propagate outside/OS speed
changes into shared state and persistence without replaying setters or overwriting
newer previews. Legacy direct speed setters read the latest pair inside the
handler lane. Both decks, recreation, source recovery and swaps preserve the
pair and lock mode. Native failure rolls both values back; storage failure remains
visible and retryable. Queue clearing does not reset adjustments.

General settings saves omit controller-owned fields, preventing stale autosaves
from overwriting adjustments. Schema v82 introduced pitch, user preset JSON and
selected identity; the stepwise v82→83 migration adds lock defaulting to false.
Older JSON without the flag remains independent and preserves exact values.
Presets retain lock mode and use unique names ignoring case; None is reserved,
immutable and derived in code. Manual edits become Custom with an originating
preset for explicit Update. Deletion keeps the sound; settings reset retains
user presets.

The vendored media-kit adapter verifies the actual mpv pitch and filter scale
because upstream setter errors are logged rather than thrown. Verification failure
propagates to the handler's paired rollback and the UI. The existing progressive
stream force-seekable customization and the disabled ytdl hook (see direct
HTTPS playback below) remain in place.

Desktop volume follows a parallel local-settings path:

1. Audio bootstrap hydrates current and last-audible volume from
   `app_settings`.
2. `PlaybackVolumeController` initializes the handler before queue restoration.
3. Slider changes apply immediately and persist after a short coalescing delay;
   drag completion and mute changes flush deterministically.
4. The next desktop launch restores the exact level, including zero, while
   mobile starts at the session default and does not persist volume.

Linux, Windows, and macOS play remote audio via direct HTTPS (Range-seekable
through media_kit/libmpv) and fill the rolling cache with a sidecar download to
the same quality-keyed path. `LockCachingAudioSource` remains the mobile
single-pass path; its local byte-stream proxy is not reliably seekable under
libmpv. Ordinary direct HTTPS playback bypasses just_audio's request-header
proxy on desktop and passes the Navis user agent to media-kit. A completed
sidecar file is registered once and remains the authoritative cache byte and
track total. `rollingCacheActivityProvider` reports the in-progress write so
Cache & Storage does not look idle before registration. Every desktop source is
a direct stream, so the resolver attaches the sidecar path even when a caller
asks for no lock caching (seek recovery, crossfade decks, songs whose
lock-cached start failed); otherwise a recovery reload cancelled the download
already running for the song.

libmpv therefore opens the credential-bearing `stream.view` URL (and radio
stream URLs) itself. Its built-in ytdl hook would retry any http(s) URL that
fails to open, such as a 404 stream, through a yt-dlp or youtube-dl found on
`PATH`: the full URL becomes a subprocess argument visible to other local users
and is requested again. media_kit 1.2.6 exposes no option for this, so the
vendored adapter sets `ytdl=no` on every player beside `force-seekable`; a
libmpv built without Lua has no hook and ignores the property.
mpv releases up to 0.41 also open https streams without checking the server
certificate (`tls-verify` defaults to off), so a man in the middle could read
the token. `main.dart` sets `JustAudioMediaKit.tlsVerify` on Linux and
Windows and the adapter then sets `tls-verify=yes` on every player; libmpv
uses the system certificate store, and Navis's own API client already
refuses certificates the system does not trust. macOS's bundled mpv 0.36
(Mbed TLS) is left as before until that build is replaced, because its
certificate source has not been verified.
`tool/stream_open_diagnostics.py` guards both at runtime.

Remote stream recovery is generation- and song-scoped. A failed remote source
receives one retry at its current (or user-requested seek) position: a
lock-cached source rebuilds as a direct stream, while a direct stream reloads
at that position. A second failure marks the song failed and advances to the
next playable queue item when available. Seek recovery also detects a remote
seek that landed correctly but remains buffering. Background phase-2 queue
fill failures never reload or clear the active start item. Loading an uncached
remote (external) song has `NavisPlaybackTimeouts.remoteLoad` (45 s) rather
than the 12 s load deadline: the server fetches the whole file before it sends
the first byte, which on a first play routinely took longer, and the abandoned
load left the song idle even after its sidecar download finished. Before the
player opens such a song, the handler warms the stream with a two-byte request
and waits (cancelled by any newer command) until the server answers, because
the players give up on a silent connection long before the server has the file
(ExoPlayer after 8 s, also through the lock-cache proxy) and the server answers
at once afterwards.

On Android a lock-cache download otherwise ran to completion after the player
had moved on; on a slow link a skipped song's download starved the new song,
whose first load then timed out. When the current song changes, downloads of
songs other than the current and next ones are cancelled
(`LockCachingAudioSource.cancelDownload`, a Navis addition to the vendored
just_audio) and their partial files discarded; desktop already keeps a single
sidecar download.

Album-style queue replacement is lazy: the active transport queue prepares the
tapped song first, then fills the remaining sources in phase 2. While phase 2
is loading, `PlaybackSnapshot.queueSongIds` can represent the pending logical
queue rather than the prepared transport queue, with
`hasPendingLogicalQueue == true`. Queue UIs should display those IDs but avoid
remove, reorder, or play-index actions until the transport queue catches up.
Player transport controls distinguish that background queue fill from an
unready selected remote source. They also show remote buffering after the
queue operation ends and use the pending target ID while the previous song's
metadata is still visible. A ready selected source keeps its play/pause icon
even if the rest of the queue is still filling.

#### Released queue window

Long queues are not handed to the native player whole. `NavisAudioHandler`
keeps `_queueItems` and the native playlist one to one and keeps the rest of
the queue in two Dart-only lists (`NavisQueueWindow`,
`navis_queue_window.dart`): a deferred tail of songs still to come and a
deferred head of played songs released from the player. The logical queue is
head + materialised + tail, so a logical index is the native index plus the
head's length; snapshots, persistence and every index-based API (jumps,
remove, reorder, insert runs, merges) use logical indices, while
`playbackState.queueIndex` stays native, paired with the materialised `queue`
that MPRIS, SMTC and Android media sessions see. Replacing, restoring, or
rebuilding a queue longer than 256 songs materialises 32 songs before and 32
after the start song; earlier songs go to the head and later ones to the
tail. When fewer than 12 materialised songs remain after the current one, one
page of 32 is released with a single `addAudioSources` append; once more than
48 played songs (`behind` 32 + `trimSlack` 16) pile up in a long queue, the
oldest beyond 32 move to the head with one range removal. Releases and trims
run as idle queue lane work and never cancel a user command.
`PlaybackSnapshot.queueSongIds` always lists the whole logical queue, so the
Queue UI shows and edits every song. Tapping a deferred song within 64 of the
window (either side) releases through it, and a page more for Previous, then
seeks; farther taps rebuild the player around it, materialising only that
window, and keep the old queue playing if the target cannot load. Removes,
reorders and inserts entirely inside the head or tail are Dart-only; a
reorder reaching into the head releases it first. Songs that cannot be
resolved when released are dropped, except that a song that is only
unplayable for now (offline without a cached copy, or no server session)
stays deferred with every song after it and the release backs off and
retries. Shuffled queues defer like any other (see Shuffle below).
Repeat-all stays off natively while anything is deferred on either side, so
the player never wraps early; the reported repeat mode is the user's, and at
the end of the last song Navis wraps to the first itself.
`GET /v1/playback/status` reports `materializedLength`, `deferredLength`,
`deferredHeadLength` and release counters. The queue window model test
(`queue window model` in
`test/src/features/player/data/navis_audio_handler_navigation_test.dart`)
runs 500 seeded random sequences of navigation, auto-advance, edits and
shuffle against a tiny window and checks the queue, index, native playlist
and saved queue after every step; `NAVIS_QUEUE_MODEL_SEEDS` changes the count.

Shuffle is owned by Navis, not the player (`_shuffleEnabled`,
`navis_shuffle_order.dart`). Native shuffle is never enabled: it can order
only what the player holds, and media_kit's `playlist-shuffle` physically
reorders mpv's playlist while just_audio keeps the old order, so the song
reported as playing was not the song heard. Instead the logical queue is
always the play order, so the Queue shows the real order and next/previous
step by one. Turning shuffle on keeps the history and the current song and
shuffles the rest; a queue started with shuffle on begins at the chosen song
with the others shuffled. The unshuffled order is kept in `_originalOrder`
and reconciled lazily with edits made while shuffled
(`reconcileOriginalRanks`: songs matched by occurrence, a song played next
lands after the current song, appended songs go last, removed songs drop).
Turning shuffle off restores that order around the current song without
interrupting it (`_rearrangeQueue`). Schema v88 saves each queue row's
unshuffled position in `play_queue_items.original_order` next to its play
position, so a shuffled queue restores in the order it was playing; a queue
saved by an older build (shuffle on, no original order) keeps its history and
current song and shuffles the rest. Remote rows keep
their own row whenever a materialised song returns to the tail (reorders,
deferred ranges, far jumps, seek recovery, crossfade deck sync): the
handler remembers the rows of materialised remote songs instead of re-reading
their ids, which would drop them or swap in a matched local song.

Every native queue edit runs under a timeout, including single removals and
moves. A timeout rebuilds both players, which leaves the active one empty, so
queue edits reload the materialised queue into the rebuilt player at the same
song, position and play state before the edit reports its failure, keeping
later edits in the lane consistent. Songs past the release window go back to
the tail. An edit the Dart queue applied first (remove, move) stays applied;
an insert that timed out is not applied.

Seek requests retain their target, selected queue occurrence and generation
through source loading. `PlaybackSnapshot.pendingSeekPosition` keeps all seek
controls at the requested target until settlement or failure; slider gestures
preview locally and commit once on release, including the compact desktop Mini
Player. New requests supersede older requests. Track selection, queue replacement
and account reset cancel them; edits to the same selected occurrence update its
index. Play/Pause intent is independent of temporary native loading states and
survives seeking, including commands issued while recovery is in progress.

Native seeks share the queue mutation lane and have the four-second control
deadline. A stuck call retires its player before later operations can touch the
engine, then reloads the queue using the existing load/reset deadlines. Listener
callbacks from retired players are rejected. Settlement probes are scoped to the
current request and confirm both forward and backward seeks within two seconds
of the target. While a backend waits for data its processing state can flap
between ready and buffering several times a second, so settlement rests on the
native position: a playing request is settled once the position advances from
the target, a paused one once it has held the target for 300 ms. Native
buffering may probe several byte ranges before producing a packet, so it counts
as activity: only a player that is not buffering and neither moves nor fills for
three seconds, or that stays away from the target for three seconds, has
stalled. A probe that is still buffering at the load deadline keeps waiting, up
to `NavisPlaybackTimeouts.seekProgress` (45 s), while the player's own buffer
grew within the last three seconds or the song's cache download (desktop
sidecar or Android lock cache) is at least half done and still receiving
bytes: on a slow link
a far seek in a large file legitimately takes that long, and a reload would
start the same transfer over. When the desktop sidecar file completes first the
probe stops and the song is reloaded from it. Each probe that gives up records
why (`missed target`, `no progress`, `cache complete`, `deadline`) with the
state it saw in the seek's `unsettled` diagnostics. Each current
request permits one recovery attempt, plus a reload from a sidecar file that
completes during it. An exhausted request reports failure and
suppresses automatic stream retries until another explicit transport/selection
request, or until the song has played on normally for five seconds past where
the seek failed, preventing a failed seek from later restarting or skipping the
song without leaving a later, unrelated stall unrecovered.
Diagnostics expose `seek` generation,
requested position, pending flag, stage, outcome and recovery count, with a bounded
`seekEvents` history. On desktop a load's initial position is applied by mpv
itself: the adapter registers a media_kit `on_load` hook that sets mpv's `start`
option for the entry being loaded (media_kit's `on_unload` hook resets it), so
playback begins at the position and nothing from the start of the song is
heard first. libmpv rejects a `seek` sent after `start-file` but before the
file has loaded, and media_kit only logs that error, so retained seeks wait for
mpv's own playback initialization (its `seeking` property, or a native
duration), not media_kit's buffering flag, which `open()` resets to false
before the file loads. Retained positions survive opening and duration events
in either order, including progressive streams that become playable before
native duration is known; one already reached natively is not seeked again.
media_kit's 5 s `network-timeout` is raised to 60 s, above the handler's own
deadlines, so a server that prepares the file before its first byte does not
fail the stream, and its on-disk demuxer cache, which libmpv cannot create
without a cache directory, is turned off. Calls just_audio routes to a player
after a stop retired it are ignored instead of raising media_kit's disposed
assertion. media_kit forwards libmpv decoder error lines as player errors;
"Error decoding audio" (a FLAC frame damaged where a seek landed) is one libmpv
recovers from by skipping the frame, so the adapter only logs it. Failing the
source on it made just_audio dispose a player that was still playing, and the
seek ended with playback stopped. Native position events confirm
landing and the native `seeking` flag keeps an unfinished paused seek buffering;
an interpolated clock cannot certify stalled decoding. The MP3 demuxer's
`usetoc=1` option enables HTTP seeks using its table of contents rather than
building an index by reading from the beginning. It is appended to the existing
native option list without changing protocol restrictions or source quality.
Credential-free
`native.mediaKitTransport` observations expose native playing/buffering/position
seeking and pending initial positions. Completions cannot clear newer positions.

A seek that does not land on a remote stream, a seek that keeps buffering and
a stalled remote stream are recovered by reloading the whole logical queue at
the current song and position (`_rebuildQueueForSeekRecovery`); when the
desktop sidecar file for the current song is complete, that song is loaded
from the file instead of the stream. The current song is reloaded paused,
corrected to the position if the backend ignored its initial position, and
only then resumed according to the latest Play/Pause intent, all before the
rest of the queue is restored, so it is never heard from the start of the song
while a long queue refills. If its independent download is at least
half complete and still progressing, an explicit seek may wait up to the load
deadline for the completed file before falling back to the stream. Three seconds
without download progress ends that wait. Partial files are never loaded.
Either way every queued song, the
deferred head and tail and the user's repeat mode are kept. Recovery cancels a
crossfade in progress and runs as navigation work, so queue edits already
waiting (an artist's next albums) apply first and the queue is captured after
them; the queue counts as loading only once the reload starts, so waiting
behind queue work or a slow database read never stops refills or fades. The
rest of the queue is restored as fill work submitted from inside the
recovery, so an edit made meanwhile applies to the restored queue. Once the
current song is reloaded the rest is always restored and the load completed,
even if a newer seek or Play/Pause command arrives. Position corrections yield
to a newer seek; a current seek resumes according to the latest Play/Pause intent.
When the song cannot be reloaded (a
stream that times out again leaves both players rebuilt empty) the queue
lists are put back rather than left cut down to that song, and the stall
path then skips to the next song by its logical index. A recovery while a
queue replacement is still filling (the player and the queue lists hold only
part of the queue) reads the pending queue's rows before it cancels the fill;
when they cannot all be read, the fill keeps running and nothing is reloaded.
Whatever happens afterwards, the whole pending queue is put back, with the
songs around the current one as deferred entries, so a recovery never leaves
the queue cut down to the song that stalled. Diagnostics record the outcome
`reloaded` only when the player was rebuilt (otherwise `notRebuilt`). Navigation to a song
the player should hold rebuilds the player around it, like a far jump, when
the player no longer holds the materialised queue.

The queue lane (`NavisSupersedingLane`) has five kinds of work. Replacements
supersede everything; navigation cancels replacements, fills and idle work
but lets queued edits finish first; edits (add, play next, remove, reorder,
merges, alias updates) run in FIFO order and are never silently dropped;
fills (the second phase of a restore or seek recovery) wait in order and
cancel nothing, so a skip or edit made between the two phases survives; idle
work (tail releases) runs only on an empty lane. An edit that finds a load
still in progress goes to the back of the lane once; later edits that reach
the front first follow it, so edits apply in the order they were made. An
edit a replacement discards completes with `OperationCancelledException`
rather than success; callers treat that as superseded, not as an error.
Edits apply one batched native
call where possible, fall back to per-song inserts only when a batch fails,
and coalesce their queue save (at most 2 s); navigation keeps a pending
coalesced save, so an edit followed at once by a skip is still persisted. A successful native call made by
an edit is always committed even if a newer command superseded it, so the
Dart queue never diverges from the player. Lane work always runs in the zone
the lane was created in, never the submitter's: drift routes a zone's
database calls to an open transaction, so work started from inside one would
keep using it after it closed.

Song identity aliases (`applySongIdentityAliases`) take effect at once and
the queue catches up as an edit nobody waits for, which saves the queue with
the coalesced save. Sync calls it from inside the hydration transaction,
just before `remapSongIdentity` rewrites the rows (including the saved
queue's); waiting there for queue work deadlocked the database and the queue
lane whenever the lane held work that read the database, or the edit's own
save. Deferred songs are read by canonical id, so a song remapped before the
queue caught up still resolves.

Phase 2 resolves sources concurrently within a batch (8 songs first, then 64)
and applies each batch with one `addAudioSources`/`insertAudioSources` call:
every native insert re-sends the whole (identity) shuffle order and rebuilds the player
sequence, so per-song inserts were quadratic in queue length. Songs after the
selection are appended before the prefix is inserted, so the next track is
ready for gapless playback first. The handler subscribes to just_audio's
shuffle and loop streams with `distinct()`: they are derived from the sequence
state and otherwise re-emit on every insert, each queueing a full queue-state
write. `GET /v1/playback/status` reports `queueFill` stage timings,
`playerSequenceLength`, and persistence-lane counts (`persistence`,
`slowPersistence`) without song identities. On desktop, media_kit/libmpv still
cost roughly linear time per inserted child; the released window keeps that
cost to the materialised part of a queue.

A saved queue larger than 64 songs is restored the same way at startup: the
current song is prepared at its saved position first, and the rest is filled
in the queue lane, so handler readiness and media-session Play do not wait for
every source. A restore timeout keeps the saved queue instead of deleting it.
Permanent-download pruning and orphan rolling-file cleanup still run before
readiness because they guard partial-file ownership.

On Android and Apple platforms audio_service is given
`RealTimeProjectionAudioHandler`, a `CompositeAudioHandler` around the real
handler; the app itself keeps the unwrapped handler. The app, lyrics and
seeking use track time with a separate speed, but Bluetooth AVRCP has no rate
field and many head units, headphones and lock screens tick at 1×. The
projection therefore publishes position, buffered position and duration
divided by the speed, reports 1×, and multiplies system seek requests back to
track time. At 1× it forwards values unchanged, and metadata is republished
only when the item or speed changes. The projection also publishes the system
queue as a window of about 100 songs around the current one, republished only
when those songs change, and maps system queue indices (`skipToQueueItem`,
`removeQueueItemAt`, `insertQueueItem`, `playbackState.queueIndex`) to the full
queue. audio_service sends the whole list over the platform channel on every
queue change, and on Android the platform thread is the UI thread. Linux MPRIS
keeps the spec's track-time
Position and publishes Rate on every speed change. Windows SMTC has no rate,
so `WindowsSmtcBridge` publishes its timeline in real listening time and
converts SMTC seek and skip requests back to track time.

A scrobble and play-history session belongs to the playing queue entry: songs
inserted, released, or moved before it shift its index without starting a new
session, and neither does refreshing its metadata in place.

Queue replacement prefetches lyrics only for the selected song and the next
two; batched artist admits prefetch none. `lyricsProvider` watches just the playing item's lookup metadata, so a
track change or artwork re-emit does not re-run every cached lookup.

Each selection keeps a bounded, redacted startup timeline in the handler. A
remote Search selection starts it before provisional database writes. The
handler then records source resolution, selected-source apply, player readiness,
and the first advancing position. `GET /v1/playback/status` exposes the latest
16 attempts as `startupAttempts` for authenticated diagnostics; those entries
contain elapsed milliseconds and source kind but no song ID, title, or URL.

Playback commands use prioritized intent. Play and pause bypass seek and queue
fill work, seeks are last-write-wins, and later seeks, skips, selections, or
pauses invalidate stale recovery so it cannot resume playback afterward.
Rapid manual Next/Previous requests update a handler-owned desired queue index
from the previous desired index. The queue mutation lane stays owned by one
handler for its lifetime and retains at most one pending replacement, so
cancelled queue work cannot overlap a newer queue mutation on the same player.
During lazy queue fill, manual navigation prepares the requested logical entry
first and then resumes filling the rest. Queue fill tracks the selected entry
by occurrence, so repeated song IDs keep the intended queue position. When
`just_audio` ignores an indexed seek during loading, the handler reloads the
complete source list at the requested index. The snapshot exposes
`pendingQueueIndex` until that transition is confirmed. Desktop sidecar cache
attempts use separate HTTP clients and partial files; cancellation closes the
old client before a new attempt can publish the same cache path.
Transport persistence is coalesced in the background. Queue and position writes
use one ordered persistence chain, so an older delayed position write cannot
commit after a newer queue replacement. The accepted logical queue is saved
after the selected source loads, before background playlist fill completes. On
cold start, the retained server session and the first connectivity event
(bounded by `audioBootstrapConnectivityWait`) are both awaited before the
audio handler restores the queue; remote sources are not misclassified as
unavailable while credentials load, nor as offline because the connectivity
stream has not emitted yet. This matters on Android, where the media service
starts the handler before the gated UI subscribes to connectivity. If the
current song still has no source (offline without a cached copy, or no
session), the restore is deferred (`queueRestoreOutcome: deferred_auth`, with
the resolver's reason in `queueRestoreDeferredReason`) and the saved queue is
kept. `DeferredQueueRestoreController`, kept alive by the app shell, calls
`retryDeferredQueueRestore()` whenever the handler or the Subsonic client
appears; the client is rebuilt on credential and network-type changes. The
retry restores paused, runs as queue-lane edit work that never supersedes a
command, is cancelled by any later queue command, and is skipped once the
user has a queue, radio or a loading selection (a user queue command marks the
deferred restore `superseded`). A Play that finds the queue empty waits for an
in-flight retry instead of restoring twice. `queueRestoreRetries` counts
retries that ran. A seek beyond the downloaded part of an Android
lock-cached song is native when the origin answered the download with byte-range
support (`LockCachingAudioSource.originSupportsRangeRequests`, a Navis addition
to the vendored just_audio): the source fetches that range itself. A linear
origin, such as a Navidrome transcode on a transcode-cache miss (`200`,
`Accept-Ranges: none`), makes the source serve every request from the start of
the song, and ExoPlayer treats a stream of unknown length as unseekable, so a
native seek (even within the buffered part) or a direct-stream reload played
the song from the beginning while the seek bar held the target. Such a seek
(other than to the first second) waits while the lock-cache download
grows (it runs faster than playback; up to `seekProgress`, three seconds without
growth ends it) and then reloads the song from the completed file at the target;
if the file is not complete the seek fails and playback continues where it was.

**Deferred: transcode-offset seeking.** On a slow link that wait can take
10–25 s or more. The established fix is the OpenSubsonic `transcodeOffset`
extension: reopen `stream.view` with `timeOffset=<seconds>` so the server starts
transcoding at the target. Symfonium appears to seek this way, and Navidrome
advertises the extension and has made offset seeks fast with ffmpeg input
seeking. Navis does not use it yet. The offset stream reports time from zero,
so it needs one position-translation layer that every position consumer goes
through: the handler's `_player.position` reads, position and buffered streams,
duration, persistence, scrobbling, lyrics, media sessions, crossfade, end
detection and recovery reloads. The full-file cache download must also keep
running beside it. It was deferred on 2026-10-04 so that the 1.4.3 seek fixes
shipped on their own. If seeking issues come back for transcoded or uncached
songs, heavily consider implementing it next, used only for linear transcodes
whose download will not finish soon and only when the server advertises
`transcodeOffset`, with resume, scrobble and lyrics timing tests and throttled
`tool/live_seek_stress.py` runs.

Lock-cache seek recovery otherwise uses the same two-phase
queue model: load the active song as a direct stream at
the requested position, then restore the remaining logical queue in cancellable
batches. Completed-state Play restarts the queue only after the final prepared
item; it cannot restart a queue that is still filling. `loadingSongId`
acknowledges a selection before network startup ends.

The tracked desktop `just_audio_media_kit` adapter retires an old load waiter
when a new source replaces it. Its queue insertion moves the actual appended
index, keeping libmpv and just_audio playlist order aligned during rapid fill.

The adapter also prints every libmpv log event it receives. media_kit 1.2.6
accepts nothing quieter than `MPVLogLevel.error`, and it derives
`player.stream.error`, which fails a load, from those same error lines, so the
level cannot be lowered. An mpv `stream: Failed to open …` error quotes the full
direct-stream URL, including the replayable `t`/`s` token pair. `main()`
therefore runs the app inside `runWithCredentialRedactedPrint`
(`lib/src/utils/credential_redaction.dart`). Every `print` in the main isolate,
including the adapter's, `debugPrint`, and `AppLogger` output, has the values of
the `u`, `t`, `s`, `p`, and `apiKey` query parameters (literal, HTML-escaped,
percent-encoded or double percent-encoded) replaced with `REDACTED` before it
reaches stdout or the system journal, in every build mode. Errors nothing
handled would otherwise be printed by the engine outside the zone, so
`PlatformDispatcher.instance.onError` is `reportUncaughtErrorRedacted`, which
prints them redacted with the engine's `Unhandled Exception:` wording.
`SubsonicLoggingInterceptor` redacts the
same parameter set from request logs. The zone covers console output only: code
that puts a URL into diagnostics responses or persisted records must still
reduce it itself, as `_diagnosticMediaReference` does. Native writes to stderr
and other isolates are outside the zone; libmpv leaves its own terminal output
off for embedding clients.

Other processes never receive a credential-bearing URL either. The stream URL
is not a `MediaItem` extra (audio_service copies every String extra into the
Android session metadata); the desktop sidecar cache keeps it in the handler.
Cover art reaches the system as a local file: `PlaybackArtCache` caches the
current cover on Android, Linux and Windows (`artCacheFile` extra), MPRIS
publishes it as `file://` and SMTC loads it with `StorageFile`. The Windows
bridge hands over a backslash path (`StorageFile` rejects forward slashes with
`0x800700A1`) named for the image type (`typedSystemArtFile`: the cache names
every cover `.jpg`, and Windows picks the decoder by extension, so a PNG cover
showed no image); either mistake leaves the overlay without a cover. An artwork URL
is published only when it carries no credentials (radio art,
`uriCarriesCredentials`). On Android, `RealTimeProjectionAudioHandler` maps
every credential-bearing `artUri` it publishes (metadata, the queue window,
browse, search and `getMediaItem` results) through `AndroidSystemArt` to
`content://<applicationId>.artwork/cover/<key>`, served read-only by the
exported `NavisArtworkProvider` from the same cache, which Android Auto can
open from its own process. The content URI is published only once the cover
is on disk (the item carries `artCacheFile`, or `PlaybackArtCache.cachedPath`
knows it); until then the item has no art and the download starts. A URI the
provider cannot open yet made audio_service store empty
`METADATA_KEY_ALBUM_ART`, and the following update with the bitmap kept the
same URI, which Bluetooth AVRCP (Android 14+) treats as unchanged and
Android Auto does not reload, so both stayed blank in 1.4.0; a change from
no art to art is shown by both. Browse lists wait up to 1.5 s for their
covers to download (six at a time); a cover not cached yet appears the next
time the list is shown, and queue entries show art once it has been cached.
Before any network fetch, `PlaybackArtCache` copies a downloaded song's cover
from the permanent artwork store (see Cache Flow), so downloaded music shows
its cover offline on every system surface. Both the copy and a download are
written to `<file>.part` and renamed when complete, so the provider and later
launches never use a partial file, and a download whose body stops arriving
for 30 s is abandoned. The app itself keeps the HTTP `artUri`.

The snapshot stored on the handler still receives every timeline update, but
the broadcast snapshot stream emits only structural changes. Linux MPRIS reads
position from `positionStream`; Windows SMTC coalesces routine timeline updates
to about one per second and sends track changes and seek discontinuities
immediately. The Windows runner assigns `com.navis.app.navis` before Flutter
creates a window; the owned Rust adapter uses manual SMTC, retains and revokes
WinRT event tokens, converts incoming seek requests from 100 ns ticks to the
Dart stream's milliseconds, serializes complete state writes, and omits unusable
artwork while retaining text metadata. Interactive seek bars render `bufferStateStream` as a subtle
secondary track and ignore states keyed to another song. For queued songs,
`MediaItem.duration` remains authoritative while a transcoded decoder reports a
growing partial duration; the decoder duration is only a fallback when metadata
is unavailable. The inactive crossfade deck exists only while crossfade is
enabled and is created, synchronized, or disposed as that setting changes.
Its clones of lock-cached sources use direct streams so two decks never rename
the same partial cache file. Queue edits do not wait for a fade, so the deck
is checked by content, not length: before a fade the deck is loaded unless it
holds exactly the materialised queue (song ids, canonical ids matching); an
edit that lands while it loads makes it load once more, and a second change
degrades that transition to gapless (`prewarm_failed`). The incoming deck must
still hold the queue, at the next song, when the fade starts, and still hold
the queue at the hand-over; otherwise the fade is cancelled and the active
player, which holds the queue, continues gaplessly (`deck_mismatch`). No fade
starts while a queue load is in progress, and a song whose transition could
not be prepared ends gaplessly instead of reloading the deck on every
position tick; once another entry plays (or any queue command runs), that
song's transition is tried again the next time it plays. In-place refreshes of a queued song
(artwork, liked state, canonical id) do not count as queue changes
(`_RevisionedList.replaceAt` leaves `structureRevision` unchanged), so they
neither abort a release nor invalidate the deck. `GET /v1/playback/status`
reports `queueSettled`, `playerMatchesQueue`, a `crossfade` block (active,
inactive deck length and match, outcome counts by phase), `queueLane` (the
running work's kind and age, and the waiting kinds) and `recovery` (the stage
of the latest seek or stall recovery). The native order is read from each
source's `MediaItem` tag, or for an Android lock-cached stream, which is built
before its `MediaItem` and carries no tag, from its stream URL's `id`
(`navisNativeSourceSongId`).

Startup waits for cache maintenance before restoring or synthesizing a queue,
so stale partial-file cleanup cannot race a new lock-cache download. If the OS
sends duplicate Play requests while the queue is empty, both await the same
fallback queue preparation instead of cancelling each other.

Now Playing receives a handler-owned `TransportVisualCue` for every manual
Previous/Next outcome, regardless of whether it originated from touch, swipe,
keyboard, headset, or an external media session. Successful manual changes use
a 220 ms clean artwork handoff: the previous cover drops away, the new cover
settles without lateral travel, and metadata fades upward only after artwork
settles. Automatic advances use a short non-directional focus fade.
Restart-current and unavailable-edge requests retain the same artwork and use
one small dynamic-color edge pulse rather than a floating icon; no UI animation
delays audio transport. Reduced motion applies direct state changes with
accessible feedback only. The clone-only presentation API can drive these
states without starting audio or modifying a queue.

### Sync Flow

1. Callers submit a versioned `SyncRunRequest`; the current
   `LibrarySyncRequest` remains a one-release compatibility adapter at the
   outer boundary. The request distinguishes automatic catalog checks, manual
   catalog checks, Repair Library, target hydration, and auxiliary refreshes.
   `LibrarySyncPlanner` selects the smallest safe plan: probe, targeted
   hydration, delta reconciliation, catalog snapshot, compatibility audit, or
   full repair. The scheduler admits one immutable `SyncExecutionPlan` per
   run, including its endpoint allowlist and data/concurrency budget.
2. `AdaptiveLibrarySyncCoordinator` serializes runs, persists the typed
   request/attempt/outcome lifecycle and the chosen plan, mirrors legacy work
   during the compatibility release, restores interrupted attempts, and
   persists provider-profile and repair-session observations. It still uses a
   compatibility executor adapter internally; execution receives the selected
   immutable plan rather than reconstructing the operation from display text
   or checkpoints. The coordinator deduplicates durable work, measures
   requests/bytes, and owns cooldown/circuit policy. Targeted work
   and provider profile, deduplicates durable work, restores interrupted work,
   measures requests/bytes, and owns cooldown/circuit policy. Targeted work
   keys are namespaced by entity kind, so equal server IDs in different
   domains remain independent. The coordinator removes that namespace before
   passing an entity ID to a hydrator or server endpoint. Automatic broad work
   defers while Navis is backgrounded or playing; an explicit user refresh may
   resume queued broad work in the foreground, including during playback.
   `LibrarySyncController` also coalesces overlapping app-level requests onto
   one terminal result, so setup, startup, user, and reconnect callers cannot
   mistake an in-flight state for a failed sync. Pending durable work resumes
   only through the configured automatic interval or an explicit action; there
   is no short continuation timer. A queued full repair is the exception: it
   remains resumable but dormant until an explicit Repair Library action, never
   a startup, reconnect, resume, or periodic pass. Resume re-arms the periodic
   timer and submits at most its one staleness check; it never also schedules a
   startup pass. A startup or
   periodic caller also treats a not-yet-constructed credential-backed engine
   as pending rather than failure, then restarts its startup pass once the
   engine is available. When an explicit Check for updates reaches a deliberate
   page, entity, request, byte, or duration limit after doing work, it returns
   `partial` and preserves its checkpoint for the next pass. The same limit on
   automatic work remains `deferred`; offline, metered, playback, and
   background policy gates always remain `deferred`.
3. Reliable providers use conditional `getIndexes(ifModifiedSince)` as a cheap
   automatic check. The response is a conditional artist index, not a change
   feed, so its cursor advances only after every candidate and hydration
   completes. An explicit refresh is not freshness-gated: it runs bounded
   delta reconciliation and always scans the first five
   `getAlbumList2(type=newest)` pages (500 entries), even when the artist
   cursor is unchanged. Their server positions are the primary Recently Added
   order; entries outside the observed feed sort only by server `created`,
   never a device synchronization timestamp. A full repair pages the complete
   newest feed into the hidden candidate and rejects repeated pagination before
   atomically promoting its ranks. If that explicit request
   is made offline, its durable work remains delta reconciliation and resumes
   when an eligible connection returns; it must never be degraded to an
   indexes-only probe. A queued automatic probe also remains queued rather
   than replacing an explicit discovery request. On a metered connection,
   ordinary Check for updates inspects one bounded 50-album newest page and
   hydrates at most three changed albums; it never runs an artist sweep or
   bulk-song index. Remaining work
   waits for an unmetered connection or the user's one-time mobile-data consent
   for broad discovery. Discrepant on-server albums use ordinary song
   hydration and identity/cache reconciliation, so a new album does not wait
   behind a large rotating artist audit.
   The long-lived engine reads this policy directly from the root provider
   container at operation time; provider-local reads can retain the policy from
   an earlier offline operation after reconnect, while watching it would
   unnecessarily replace an in-flight coordinator.
4. Bulk-capable providers enumerate independent album/song pages with
   `getAlbumList2` and empty-query `search3` (the OpenSubsonic all-library
   form). Full-snapshot pages are
   validated and checkpointed into generation-keyed candidate tables that no
   app provider watches. A restart skips collected pages while users continue
   reading the previous committed catalog. Song pagination advances by each
   response's actual count rather than treating a short page as completion,
   since compatible servers can silently cap the requested result size.
   When a completed bulk index omits a stable tail because of that cap, a later
   repair can carry forward locally verified songs only when the candidate's
   core album metadata and expected song count exactly match. New, changed, or
   incomplete albums remain on the authoritative `getAlbum` fallback.
   Hydration progress advances only after an album has been written and marked
   hydrated; albums merely observed in a bulk search page are not presented as
   complete. Catalog discovery remains indeterminate because its page total is
   an estimate and does not share a stable denominator with song hydration.
   Incompatible providers fall back to
   bounded `getArtists → getArtist → getAlbum` work using the same candidate
   boundary.
   If `getArtists` is unsupported, the collector falls back to the compatible
   `getIndexes` artist index before treating the catalog as unavailable.
5. Unhydrated artist, album, and playlist interactions upgrade matching work to
   interactive priority instead of starting parallel hydrators. Artist detail
   fetches `getArtist` on its first open in each server session (an in-memory
   set of hydrated artist ids, cleared on sign-out or server change together
   with the opens still in flight; an open that started in an earlier session
   enqueues nothing and cannot hold back the new session's open; a succeeded
   result marks the artist, so an offline or deferred open retries next time and
   opens while the server is unreachable skip this check), and on every open
   where the artist is absent, has fewer stored albums than its advertised
   count, or has no advertised count. The session check exists because a
   server's artist list can count local albums only: Octo-Fiesta's `getArtists`
   reports the local count while `getArtist` adds the remote
   `ext-deezer-album-*` releases under the same artist id, which then land in
   the Albums grid with the Remote mark and hide Missing albums. Concurrent
   opens of one artist share one request, and the artist and album pages wait
   for its result while they have nothing to show (see *Remote artist and
   album pages*). Its explicit refresh always requests
   that exact artist rather than a broad catalog run. Artist hydration stores
   the complete release metadata tree, while album hydration remains lazy and
   normally performs one `getAlbum` request plus one song transaction. Releases
   retain their stable provider IDs even when titles match, so distinct editions
   are never hidden. Background detail work adapts from two workers up to eight
   on Wi-Fi, four on other unmetered networks, and one on cellular; active
   playback caps it at two. A foreground full-catalog repair starts its
   per-album fallback at eight workers and may ramp to 24 on idle Wi-Fi. During
   active playback, an explicit repair remains bounded at four to eight Wi-Fi
   workers rather than falling to the ordinary two-worker interactive cap, so a
   server search-result window cannot turn the repair tail into a serial crawl.
   Multi-album detail batches yield during song-row conversion while keeping
   reconciliation and identity matching on the complete fetched batch.
6. The transport interceptor owns at most one immediate idempotent retry and
   honors `Retry-After`. Durable work owns later attempts with exponential
   cooldown. Three consecutive failures open the endpoint circuit; user,
   reconnect, and resume triggers may probe it early. The cooldown is exposed
   as `LibrarySyncState.nextRetryAt`, populated from persisted state at launch
   and reloaded from it after every catalog run. Sync Settings renders it
   separately from `nextAutomaticCheckAt`, so a normal interval and a
   failure-backoff wait cannot be mistaken for one another.
7. Complete snapshots are generation-based. Old rows remain visible and
   reactive queries receive no candidate-page churn until all pages and
   required hydration validate. Promotion is one database transaction that
   upserts the candidate, remaps proven song identities, preserves active
   playback/cache/download dependencies, removes confirmed unseen rows, and
   advances the committed generation. Local likes and ratings made during
   collection are journaled and win over the older candidate snapshot across
   restarts and the atomic apply boundary. After promotion, unavailable albums
   continue as targeted hydration instead of rerunning the broad snapshot. Large
   deletion candidates (over 10% of an entity type or over 500 songs) require
   the same fingerprint twice. The stale-song count is calculated only after
   candidate song collection/carry-forward; tracks belonging to an unresolved
   candidate album are retained until authoritative detail hydration succeeds.
   That fingerprint and its server-missing count are durable; Settings exposes
   the count and requires an explicit Apply library repair confirmation before
   it makes the second repair request.
   Promotion creates review entries for retained unavailable songs without
   replacing existing review decisions, including when the promotion is retried.
   Isolated detail 404s and an album omitted from one artist-detail response
   remain candidates until a complete snapshot confirms deletion; incremental
   artist reconciliation may only add or update catalog rows.
   Starred reconciliation follows the same offline-safety principle: a local
   star absent from one successful `getStarred2` response becomes a durable
   absence candidate, not an immediate unstar. Only its second independent
   successful absence clears the local star; a returned server star or pending
   local mutation clears that candidate.
8. Search and discovery metadata stays provisional. Canonical hydration uses
   same ID, one unique recording MBID, or one unique compatible exact metadata
   match. Proven aliases are applied to playback before provisional cleanup, so
   cached remote songs auto-merge without interrupting the active source; late
   cache completion also resolves through the alias.
   The Navis Search presentation path merges cached and API results by ID and
   orders artists, albums, and songs by relevance tier, source preference, and
   stable input order. Source preference only breaks relevance ties: exact
   remote results stay above weaker on-server matches. This ordering is not
   applied globally to `search3`, synchronization, discovery, or identity
   matching.
   External-catalog provenance is an independent persisted property:
   `isExternal: true` means the item is remote-only, while `false` means it is
   on-server even if Navis has not indexed it locally. Explicit API values win;
   only missing values use the `ext-*`, `remote-*`, and `pl-deezer-*` fallback.
   Broad snapshot candidates discard external rows. Targeted external detail
   trees remain provisional and are visible only through exact artist/album
   relationships; an individual album-detail response is content authority
   only and cannot override already persisted catalog membership or parent
   artist metadata that it omits or contradicts. Canonical promotion clears
   `is_external` only when a catalog-authoritative snapshot later observes the
   item on-server. Cache
   and download ownership do not affect source. Schema v73 repairs legacy
   `ext-*`, `remote-*`, and `pl-deezer-*` rows that were stored as local before
   provenance became reliable, so they no longer leak into Home or Albums.
   Remote status is rendered contextually: a neutral globe-and-Remote pill on
   browsing artwork, an inline label in dense rows and playback metadata, and
   a metadata chip on detail screens. Local/on-server media is intentionally
   unlabeled, and cache/download indicators remain separate availability
   states. Song lists use the shared `RemoteSourceMetadataLine`, which keeps
   the indicator on the subtitle line and lets long metadata truncate first.
   This contract covers Home, ListenBrainz weekly recommendations, liked
   songs, artist top tracks, Match Flow, queues, and downloads; those rows
   suppress artwork overlays and preserve the same height and alignment for
   local and remote entries. Each indicator owns one stable semantic node in
   the normal tree. The desktop hover explanation is a pointer-transparent,
   visual-only `OverlayEntry` with inherited themes and no semantic children;
   it uses the shared `NavisTooltip` to avoid Material `Tooltip`/`RawTooltip`
   and their `OverlayPortal` semantics reparenting on Flutter 3.47.1.
   Browsing song rows share `DesktopSongActions`: the enclosing adaptive row's
   wide mode shows local Like and Download beside More; compact and medium
   modes retain More. Mode depends on usable pane width and text scale. Generic
   callers without a row scope retain the 1100px window-width fallback.
   Remote-only songs receive no local-server controls. Whole-entity playback preserves a mixed
   supplied local/remote list without identity-canonicalizing it into local
   rows or applying ID-based Match Flow expansion, so a matched remote source
   remains in the requested queue. ListenBrainz weekly playlists follow this:
   Play and Shuffle queue every matched song in playlist order
   (`ListenBrainzDiscoverPlaylist.playableSongs`, on the server or remote)
   through `replaceWithSongs`, which saves remote rows as provisional first,
   while Download takes only songs on the server. A row tap in the weekly page
   or the desktop Home panel follows Album Queue
   (`listenBrainzPlaybackFrom`): on, it queues the playlist's matched songs
   from that row, as Artist Top Tracks does; off, only that song. Before
   1.4.1 Play and Shuffle skipped remote matches and taps always played one
   song (single-song taps came from commit `a8b639af`).
9. Metered automation is a true hard probe: one conditional `getIndexes`
   request with retries disabled. Interactive artist/album/playlist hydration
   remains allowed with 16 MiB/response and 32 MiB/interaction budgets.
   Enumeration, audits, starred and playlist-header sync, pending broad
   hydration, and Repair Library stay deferred unless the user grants an
   ephemeral one-time mobile-data override. Live network policy is re-checked
   at page and hydration boundaries; unmetered-to-metered transitions
   checkpoint and return `deferred`. Cancellation returns work to the queue.
10. Starred content and playlist headers are independent auxiliary targets.
    Typed catalog checks and repairs do not update them as incidental work;
    their user-facing states are **Updating liked items** and
    **Updating playlists**, not catalog-sync progress. A scheduled catalog
    check drains each due target (12 hours), preserving its separate playback,
    foreground, offline, metered-network, retry, and backoff policy. An
    explicit Check for updates or Repair Library always drains both companion
    targets with explicit intent, including while playback is active, but still
    respects offline and metered-network limits. Durable per-target completion
    and backoff control freshness independently; a failed auxiliary target
    neither repeats a committed catalog nor suppresses the other target. The
    auxiliary freshness clock is the single
    `library_sync_state.lastAuxiliarySyncedAt` column: the typed coordinator
    advances it from completed starred/playlist-header work rows, the legacy
    combined-run path advances it through a monotonic
    `markAuxiliarySyncedAt` writer, and the retired per-server
    capabilities-JSON timestamp is no longer read or written. The
    catalog circuit breaker does not suppress these independent endpoints.
    Genres are not synchronized: there is no genre target, endpoint or stored
    genre data (see "Genres are not a Navis concept").
    Starred reconciliation
    excludes queued local star/unstar actions until they reach the server.
    Playlist headers upsert without replacing parent rows, so an unchanged
    header refresh cannot cascade-delete cached membership. The authoritative
    header list prunes confirmed server deletions and queues new, count-changed,
    or metadata-changed playlist contents for resumable targeted hydration.
    Explicit favorites include referenced external/provisional identities while
    ordinary library enumeration remains canonical. Membership in a starred
    snapshot counts as a favorite even when its optional timestamp is absent.
    Eligible automatic catalog checks inspect at most two newest-album pages
    each configured due interval, even with an unchanged artist cursor; manual
    checks inspect at most five. A recorded discovery-debt streak
    (`libraryDiscoveryDebtStreak`, persisted per server when a check hits its
    page cap without ever reaching known, unchanged content) keeps the probe
    on schedule and widens the automatic window to five pages until known
    content is reached; a streak past the escalation threshold
    (`discoveryDebtEscalationStreak`) hands deep discovery to a queued delta
    reconciliation. Automatic discovery defers during playback or
    hidden foreground execution, and metered automation remains a hard probe.
    Reliable providers also run a weekly rotating audit;
    incompatible providers use one bounded daily partition, never a periodic
    full scan.
11. Home ListenBrainz discovery polls the startup sync gate and uses the sync
    completion bridge for refreshes instead of subscribing the stream to sync
    progress. Its derived showcase watches the discovery stream once, avoiding
    a reactive dependency diamond during large repairs. From app settings the
    stream selects only the ListenBrainz user name and token-valid flag, so
    unrelated saves (Playback autosave, appearance, desktop volume persistence)
    do not restart it; a validated token refreshes it through
    `listenBrainzDiscoverRefreshEpochProvider`.
    Weekly matches are rechecked on two schedules. Every resolve, including
    the one the bridge starts after each library sync that succeeded or
    partly succeeded, runs the local pass for every recommendation without
    a song on the server, remote matches included; a remote match switches
    to the library copy once its album is on the server and synced, and
    stays remote otherwise. The server is searched (`search3`) for a new
    week, for the per-playlist Match action, and once a day for an unchanged
    week: then unmatched, unclear and remote tracks are searched, a copy on
    the server is preferred over an equally good remote one, and a remote
    match is only ever replaced by a server copy, never by another remote
    result or a failed search. Each playlist's `searchedAt`, stored as its
    weekly cache row's `fetchedAt`, records the last search and is kept by
    local-only saves. Before 1.4.1 remote matches counted as resolved, so they
    never switched, and unmatched tracks were searched again on every
    launch. The bridge skips its refresh when another refresh started after
    the sync finished (Home pull-to-refresh starts a full one), so the full
    refresh is not replaced by a cached re-match. Cached matches take their
    current library rows on load (`_attachListenBrainzLibraryRows`); a song
    the server has deleted reads as unmatched instead of staying playable.
    The stream also yields a resolve whose counts are unchanged when a track's
    matched song or server status changed.

The provider fast/compatibility split and explicit repair terminology follow
the public principles documented by
[Symfonium](https://docs.symfonium.app/wiki/providers/sync-media-provider-data/)
and its
[Subsonic compatibility modes](https://docs.symfonium.app/wiki/providers/subsonic-opensubsonic-media-provider-configuration/).
OpenSubsonic documents the conditional full-index semantics of
[`getIndexes`](https://opensubsonic.netlify.app/docs/endpoints/getindexes/) and
the [`getScanStatus`](https://opensubsonic.netlify.app/docs/endpoints/getscanstatus/)
contract.

#### Scan awareness, catalog availability, and identity recovery

- **Scan detection.** The scheduled probe reads `getScanStatus` once per
  eligible check (no separate polling loop) through the typed
  `SubsonicApiClient.getScanStatus`. Standard `scanning`/`count` fields are
  supported; Navidrome's optional `lastScan` supplies the scan token. A newly
  completed token opens one pending reconciliation (`library_scan_observation`)
  that flows through the existing probe → snapshot path, and collection
  re-observes the token before promotion: if a scan landed mid-collection, the
  candidate's completeness evidence is withheld, the ledger records
  `scanChangedDuringCollection` (with a per-server deferral streak in
  `libraryScanDeferralStreak`), and the resumable planner recollects. After
  three consecutive deferrals the engine waits a bounded window for a running
  scan to finish and releases the promotion once the server is quiet
  (`scanChurnCapRelease` ledger entry) so a continuously rescanning server
  cannot defer full-sync promotion forever. Servers
  without the endpoint are recorded once as unsupported and stay on the
  existing discovery/audit mechanisms.
- **Catalog availability.** Songs, albums, and artists carry a typed
  `catalog_availability` (`present`/`suspectedMissing`/`confirmedMissing`).
  Transport, authentication, rate-limit, and decoding failures never advance
  availability toward missing; only validated catalog evidence does. Items
  that disappear from a validated snapshot but still own user state —
  favorites, ratings, history, queue/playlist references, download ownership,
  or pending mutations — are retained as confirmed-missing instead of being
  deleted (previously only permanent downloads survived). Their
  `serverDeletedAt` marker keeps them out of normal Play All, shuffle, and
  download selection while review entries in `library_recovery_review` keep
  them recoverable; the legacy `removeServerSongsForPromotion` contract is now
  `retainOrRemoveServerSongs`. An isolated media-fetch 404/410 during a
  download records `suspectedMissing` on rows still reading as present —
  suspicion never hides content or advances toward confirmed absence.
  Promotion rewrites re-observed rows with cleared absence markers, and bulk
  selection excludes only validated-absent rows without a complete local
  copy, so offline favorites stay selectable (`_selectableForBulkUse` in
  `LibraryDao`).
- **Identity recovery.** `SongIdentityReconciler` matches on same ID, unique
  recording MBID, then exact normalized title/artist/album with the existing
  three-second duration tolerance — with two hard rules: contradictory
  non-empty MBIDs prohibit metadata-only matching, and ambiguity never merges
  regardless of page order. Matched claims buffer during canonical paging and
  apply at `finalize()` only after the complete replacement set is observed:
  a candidate contended for by several canonical rows is ambiguous for every
  claimant, and a same-identity claim keeps precedence over contested weaker
  claims (targeted hydration finalizes per album batch; promotion finalizes
  across the full candidate set). Candidate sets include retained confirmed-missing
  rows so a later scan can relink them. Rows a promotion itself preserves or
  retains (downloads of a rebuilt album) get a second pass in the same
  promotion, after the stale-song loop and before album/artist relinking, so
  they are relinked by the promoting sync rather than the next one. `remapSongIdentity` merges user state
  with local precedence (a carried like keeps its original timestamp and is
  re-queued to the server through `star_sync_queue`), transfers absence
  evidence, local mutation journals, and writes both the legacy and the typed
  profile-scoped alias tables (`entity_identity_aliases`). Cache and download
  ownership validation is storage-kind aware: Android SAF content URIs are
  validated through the platform bridge, never `File.exists()`.
- **Album/artist relinking.** Candidate staging tables carry
  `release_mbid`/`artist_mbid` (schema 80) promoted from OpenSubsonic
  `musicBrainzId` fields; `EntityIdentityReconciler` runs inside the
  promotion transaction after rows are preserved and before stale-row
  deletion, and maps albums/artists only from a unique stable MBID on both
  sides or an unambiguous song-membership mapping with compatible metadata.
  `remapAlbumIdentity`/`remapArtistIdentity` move song and album references,
  transfer star queue entries, absence evidence, and local mutations, merge
  favorites and ratings with local precedence, and record typed aliases.
  Evidence-less or contested rows keep their user state as provisional rows
  and become review entries with typed reasons.
- **Recovery review.** Pending entries (with evidence generation, reason, and
  saved metadata) surface in Sync Settings → Unavailable items
  (`/settings/unavailable-items`) for songs, albums, and artists with typed
  reason labels. Find match searches the current catalog for any entity type;
  every selection opens a preview dialog showing old and new metadata plus
  the exact references the remap carries over (downloads, playlists, history,
  queue, pending annotations, following songs) before applying through the
  same transaction as automatic recovery, and apply-time revalidation rejects
  a selection whose replacement no longer exists. Entries with recorded
  replacement candidates offer a possible-replacements action. Keep for later
  and Remove from Liked are unchanged. Sync evidence never overwrites a user
  disposition.
- **Repair sessions.** Ordinary Repair Library runs non-blocking from Sync
  Settings. The coordinator owns an in-memory repair session whose
  mobile-data grant is applied at admission — before planning or durable work
  is joined — and survives retries and reconnects within the run. The grant is
  never persisted: completion, cancellation, sign-out, account change, and app
  restart all clear it. The blocking rebuild screen remains only for initial
  login, destructive cache reset, cache upgrade, and playback recovery, where
  no usable catalog exists.
- **Post-upgrade reconciliation.** Bumping `currentLibrarySyncModelVersion`
  arms the startup reconciliation for upgrading installations: the next
  launch schedules exactly one resumable full repair (deferred on cellular
  per policy), and the new version is stamped only when the repair finished
  with a promoted catalog, so a failed attempt retries on the next launch.
- **Artwork identity.** Cover-art cache keys compose cover ID, requested size,
  and a per-entity targeted refresh revision
  (`coverArtImageCacheKey(id, size, revision)`). Revision zero keeps the
  legacy key layout, so existing offline artwork survives the migration.
  Explicit repairs bump the revision only for entities whose server row
  changed — cards, queue surfaces, and the viewer pass the row's revision
  into `CoverArtImage`, so a bump refetches exactly those entries without
  global cache clearing — and the cover-art file service rejects
  HTTP-success payloads whose content type is not an image so error pages
  are never cached as artwork.
- **Artwork failure recovery.** Fetch failures carry a typed category
  (`CoverArtFailureCategory`): missing reference, auth rejection, network
  timeout, invalid payload, or decode failure. `CoverArtRecoveryCoordinator`
  evicts a corrupt or invalid cache entry exactly once per key for a single
  bounded refetch, and coalesces one entity-metadata refresh per missing
  cover reference (cooldown per cover identity per session) routed through
  the sync engine's targeted hydration so widgets retry the resulting cover
  identity. A server cover whose load times out is also retried by
  `CoverArtImage` itself, once per cache key after
  `kCoverArtTimeoutRetryDelay`, instead of keeping its placeholder until the
  page is reopened; a second timeout keeps the placeholder (external artwork
  is not retried).

### Cache Flow

1. Playback starts → on Android/iOS `LockCachingAudioSource` writes the
   consumed stream into the rolling cache without a second download. Desktop
   (media_kit) cannot seek that proxy, so it streams over HTTPS while a
   sidecar download fills the rolling cache: each uncached track is fetched
   twice (a FLAC is typically 25–50 MB, and transcoding runs twice on the
   server). This is a deliberate cost of seekable desktop playback.
2. On completion → `RollingCacheManager.registerTrack()`. A small file that
   holds a Subsonic error document is deleted instead of registered: Navidrome
   answers a stream it cannot serve with HTTP 200 and that document, and
   playback prefers the rolling cache over streaming, so keeping it would fail
   the song until eviction. Startup pruning removes such entries left by older
   builds, and the desktop sidecar refuses HTML, JSON and XML responses before
   writing anything.
3. Cache manager reads the current budget and enforces it via LRU eviction
4. User pins content → Download to permanent cache (see **Download quality,
   concurrency and artwork** below)
5. Permanent download completion and rolling→permanent promotion pre-cache
   cover art using `kCoverArtStandardSize` and keep a durable copy in the
   permanent artwork store
6. A custom permanent-download root is user-owned: Navis records known files
   in its root `.navis-downloads.sqlite` sidecar and can adopt existing files
   only after an explicit preview/confirmation. The sidecar maps relative file
   paths to a profile fingerprint and song ID. Paths inside a download folder
   are compared by key (`DownloadRootIdentity`): the path relative to the
   folder with `/` separators, reached through either the configured or the
   link-resolved spelling of the folder, and case-insensitive on Windows only.
   Sidecar keys written with `\` by older builds still match and are rewritten
   on the next write, and moves never treat the same file under another
   spelling as a separate destination. Supported media tags are a
   best-effort additional identity source. Unknown, ambiguous, and
   profile-mismatched files remain untouched. A transfer is written to
   `<final name>.navis-part` and renamed into place (with retries while
   Windows antivirus holds the new file) only after it completes, then
   tagged and registered, so an interrupted download never appears under a
   song's name. The app shell starts `DownloadService` at launch (it was
   otherwise created only when a download control was first used), and its
   startup after interrupted downloads requeues them and removes
   `*.navis-part` files, and only those, from the active folder without
   following links; folder scans ignore them. Promoting a rolling-cache file reuses an
   existing destination only when its size matches. Resetting server data (a full
   sign-out or server switch) removes the library rows but deletes only
   Navis-owned audio files; files inside the custom folder and Android SAF
   documents stay where they are.
   Leaving a custom folder follows the same rule. Turning it off (after a
   confirmation) or choosing a different folder moves only downloads stored
   in Navis's own directory. Every file in the folder being left, filesystem
   or SAF, stays where it is under its own name, whether Navis downloaded or
   adopted it; Navis records no difference between the two. Navis forgets
   those `cached_tracks` rows before the setting changes, so startup
   normalization never moves them out later. The folder's sidecar remains,
   so choosing that folder again re-adopts the files through the usual scan.
   That scan runs before the switch, so the import checks registration again
   when it commits: a file whose song lost its download in the switch is
   adopted rather than skipped as already registered. Choosing the active
   folder again moves nothing. Files count as inside the new folder through
   any spelling of its path or theirs, links resolved.
   Android uses a persisted Storage Access Framework tree URI rather than a
   filesystem path. A folder that a version before 1.2.8 stored as a plain
   path is turned off at startup under the same leaving rule: Navis forgets
   the downloads inside it before the setting changes and leaves the files
   where they are, and choosing the folder again as an Android folder runs
   the usual scan. The cached-track storage kind distinguishes Android SAF
   document locators from ordinary filesystem entries; SAF reads, writes,
   relocation, deletion, and offline playback go through the Android
   ContentResolver bridge and never overwrite unmanaged documents. Before a
   tree is activated Navis proves it can create, write, and remove a temporary
   Navis-owned probe document; a provider that fails that check remains
   unselected.
   Folder reconciliation first imports only unique manifest, embedded-identity,
   or indexed filename matches. Ambiguous and unknown files enter a transient
   manual-review screen; its local-song picker shows cover art and ranks exact
   title matches with liked songs (including liked-album tracks) first. Closing
   that review leaves unresolved user files untouched. Adopted files are never
   modified or moved: startup normalization leaves every file already inside a
   custom root where it is, the sidecar is their identity record, and adoption writes sidecar
   records in one transaction and cache rows in chunks of 250 (one
   `cached_tracks` notification per chunk). Only files Navis downloads itself
   carry identity tags; they are written to the local file, off the UI
   isolate and only when missing, before its single upload to a SAF folder.
   Legacy matching looks each distinct file title up in `song_search_text`
   (an indexed prefix read in the `normalizeSearchText` form, so titles in
   any script match) instead of normalizing the whole library, and FLAC
   identity reads are bounded to metadata rather than loading complete audio
   files; Android SAF reads identity metadata directly through
   `ContentResolver` without staging audio files. The Android storage channel
   runs on a background task queue (the platform thread is also Flutter's UI
   thread), lists a tree with one provider query per folder, and resolves the
   sidecar by path instead of listing the tree.
   The Downloads settings page retains the latest in-process scan's unresolved
   paths behind a disabled-or-enabled **Manual Matching** entry beneath Rescan.
   Its count badge and description expose how many files still need an explicit
   mapping; completing mappings reduces that count, while a new rescan replaces
   the transient queue. Choosing, disabling and rescanning the folder run in
   the app-lifetime `CustomDownloadFolderController`, one at a time, not in the
   settings page: that page is a tab disposed as soon as another tab is
   shown, and leaving it during a long scan used to stop setup before the
   folder was saved or before Manual Matching was filled in (issue #45). The
   page shows the controller's `busy` state. A clone diagnostics build reads a
   filesystem folder outside its run root as unset
   (`cloneDownloadFolderOutsideRoot`), and `DownloadService` refuses to scan
   or configure such a folder with a `FileSystemException` before any work,
   so a clone can no longer adopt the user's files and then show the folder
   as off.
7. Identity aliases transfer valid rolling/permanent ownership to a proven
   canonical server song ID; ambiguous permanent downloads remain local-only
8. Eviction removes orphan MIME sidecars and garbage-collects unreferenced
   provisional metadata while preserving active partial files and recent
   unowned audio files
9. Playback prefers permanent → rolling → stream
10. A profile migrated before library-cache-system version 2 must clear recoverable
   rolling cache and library metadata once before using the current contract.
   The upgrade prompt can be dismissed, but returns on the next launch until a
   successful reset and committed full catalog scan. **Repair Library** is the
   non-destructive server-catalog reconciliation: its candidate remains hidden
   until atomic promotion, and it preserves downloads, rolling cache, artwork,
   and the visible catalog until then. **Reset Caches & Rebuild Library** is
   the distinct device-storage recovery action: it deletes rolling cache,
   cover-art cache, and local library metadata, preserves permanent downloads,
   then starts a fresh catalog build. Settings keeps these actions in the
   separate **Library synchronization** and **Device Storage & Cache** groups;
   their metered confirmations, history origins, and full-screen progress
   states stay distinct even though both can collect a catalog. Choosing reset enters the
   shared full-screen required-library-rebuild route, which is also used for a
   first login, Repair Library, Settings cache reset, and playback recovery. It blocks ordinary
   navigation until the catalog is committed, keeps users in place with retry,
   metered-data, and sign-out recovery options on failure, and only then opens
   Home. `LibraryCacheResetService` deliberately preserves permanent downloads
   and their files; the upgrade marker is written only after that full scan.

### Download quality, concurrency and artwork

**Quality preference.** Every download action calls `requestDownloadQuality`
(`download_quality_sheet.dart`). It reads the saved preference from the
targeted-only `app_settings` columns `download_quality_mode` (`ask`,
`original`, `transcode`), `download_max_bit_rate` and `download_format`. A
saved mode returns its choice without UI and the queued notice names the
quality (`downloadQueuedNotice`); `ask` shows the picker: Original plus
96–320 kbps in the saved transcode format (MP3, AAC or Opus). While
`download_quality_prompted` is false, the first pick is followed by a
one-time "Always download in …?" dialog. Either answer sets the flag; accepting
saves the mode. Schema 90 adds the columns with the flag false, so every
existing install, with or without downloads, is asked once. Choosing a quality
in Downloads settings also sets the flag. "Change quality" on a downloaded
track always opens the picker. Auto-downloads of liked items use the saved
quality on Wi-Fi (original when the mode is `ask`) and the cellular streaming
profile on mobile data. Full settings drafts never write these columns.

**Original detection.** An original download records the song's bitrate, so
`isOriginalQualityDownload` treats a stored download as original when it has
no bitrate, or the song's own format (`sameAudioFormat`: `m4a`/`mp4`/`aac`
are one family) at no less than the song's bitrate. Enqueueing at Original
therefore skips songs already downloaded in original quality.

**Transcoded transfers.** `stream.view` requests carry
`estimateContentLength=true` so transfers report progress; a transfer without
a length shows an indeterminate bar. After a 2xx response the
`content-type` names the stored format (`downloadedFormatFor`): a server
without the requested encoder that sends the original file stores it under
its real extension and bitrate. HTML, JSON and XML responses are failures and
never registered.

**Concurrency.** `DownloadService` runs a worker pool. `effectiveConcurrency`
is 0 while paused or held by Wi-Fi-only, 1 on cellular, otherwise
`max_concurrent_downloads` (1–4, default 2; `kMaxConcurrentDownloads` bounds
server encoders, device I/O and streaming bandwidth). The pump runs on queue,
network and setting changes and when a worker ends. Only the network transfer
runs in parallel: the finishing step (rename, identity tags, SAF upload,
`cached_tracks` upsert, folder sidecar record, queue row removal) runs one at
a time, and destination paths of transfers in flight are reserved, so two
songs with the same artist and title take the resolver's collision suffix.
Each transfer has its own `CancelToken`. Cancelling an item
(`cancelQueueItem`, `clearQueue`) stops its transfer, deletes the part file
and removes the row. Pausing (`setPaused`, persisted in `downloads_paused`
and read at start before the queue subscription) cancels transfers in flight
and returns their rows to the queue. A failed item waits out its backoff
(5 s × 2^retry, in memory; a restart retries at once) before the pump starts
it again, and `markForRetry` notifies queue watchers. `processQueuedDownloads`
completes once no worker is running. The Android progress notification
aggregates every transfer in flight.

**Permanent artwork store.** `PermanentArtworkStore` keeps one 768 px copy of
each downloaded song's cover in `<app support>/artwork/permanent/<key>.<ext>`
(clone runs: inside the run root), named for its image signature, written
through a part file, and never a non-image payload. It is Navis-owned and
outside any user download folder, so it never becomes an import candidate.
Downloads and promotions store the cover; startup stores covers missing for
existing and adopted downloads (Wi-Fi only) and deletes covers no permanent
download uses; removing downloads prunes it, but never while a download's
song is missing from the library (a rebuild in progress). `CoverArtImage`
renders a stored cover (resized to the requested size): at refresh revision 0
whenever the cache has no entry for that size; at a bumped revision only when
the network load fails, so a refreshed cover still loads fresh online; and
always when there is no server connection. `PlaybackArtCache` copies it for
the system media controls. Reset
Caches and Clear Cover Art keep the store, like permanent downloads; a server
data reset clears it.

Interactive Linux sync presets in `tool/dev_app.sh` run against a disposable
diagnostics clone. The cloned database drops cached-file references, outbound
queues, and any copied custom download root. A desktop clone resolves every
`path_provider` directory inside its diagnostics root
(`CloneDiagnosticsPathProvider`, installed first in `main`), so its rolling
cache, cover-art and image caches, default permanent-download directory and
app-support state (window geometry, update check, What's New marker) are
separate from the primary profile, and testing first setup or a cache reset
cannot delete the primary profile's media. Initial offline/metered overrides are seeded before
the first sync decision; the authenticated diagnostics API can change them
while the scenario is running.

### Performance contracts

These rules keep the UI at 60 FPS and memory bounded with libraries of tens
of thousands of songs. `tool/perf_diagnostics.py` measures them (see
`docs/development-workflow.md`).

- Never load the whole songs table to pick a few rows. Use bounded DAO queries
  (`getSongsSorted`, `getRandomSongs`, `getSongsByIds`) or SQL aggregates.
- Local song search runs against `song_search_text`, a derived index of each
  song's normalized title, artist, and album. A row is current only while its
  `source` column equals the song's raw fields, so no song write path needs to
  maintain it: stale or missing rows are normalized by the search itself and
  rewritten by `scheduleSongSearchIndexRefresh`, which also runs from deferred
  startup maintenance. Normalization keeps letters and numbers from every
  script and folds Latin diacritics and common Arabic letter variants. The SQL
  prefilter requires each query token as an in-order subsequence, which every
  ranked match (exact, prefix, substring, token, fuzzy) satisfies, so ranking
  is unchanged. Since schema 87 each row also stores `match_title`,
  `match_artist`, and `match_album` in the `normalizeMetadata` form (rows
  without them count as stale). The `source` ends with `metadataKeyVersion`,
  so rows keyed by an older normalizer are stale for track matching and the
  same lazy refresh re-keys them; no migration is needed when the normalizer
  changes. Search and downloads-folder matching accept a row of any key
  version whose raw fields match, because `search_text` does not depend on
  it, so a bump never sends search down the stale path. `getTrackMatchCandidates` selects only songs
  that could match a list of external tracks (artist top songs,
  ListenBrainz recommendations) under `LocalTrackMatchSnapshot` rules: equal
  title keys, or artist keys that are equal, contain or are contained, or
  share a word. A snapshot built from those makes the same matches as one
  built from the whole library. The artist rules are tested once per distinct
  `match_artist` key (indexed, like `match_title`), not once per song, and
  the matching songs are read through the two key indexes;
  `debugTrackMatchCandidatesByFullScan` keeps the per-song query as the test
  reference. Deferred maintenance normalizes in an isolate.
- Matching external metadata (Last.fm, ListenBrainz, LRCLIB, Subsonic
  search) to library songs, albums and artists uses two keys from
  `lib/src/utils/metadata_normalization.dart`. `normalizeMetadata` is the
  fuzzy key: it folds full-width ASCII and the ideographic space, case, Latin
  diacritics and Arabic letter variants, drops parenthesized qualifiers and
  featured credits, and keeps letters and digits of every script, so
  Japanese, Korean, Arabic and accented titles get real keys.
  `normalizeMetadataKeepingEdition` is the same but keeps bracketed and
  " - " qualifiers, so "Wonder" and "Wonder (Japanese Version)" share a
  fuzzy key but not an edition key. Mastering and packaging qualifiers
  (remasters, bare years, deluxe/anniversary editions, explicit/clean,
  mono/stereo, album/single/original version, bonus track) are not
  editions and are dropped from it. Matchers (`pickBestTrackMatch`, Same
  Vibes mapping, LRCLIB, the exact library lookups behind player metadata
  navigation) prefer the candidate whose edition key equals the expected
  one. `pickBestTrackMatch` drops another edition only when a passing
  same-edition candidate has at least as good artist and album scores, and
  never when that would turn a unique match ambiguous. Radio recording
  identity uses the edition key without spaces, computed once per song per
  batch. Changing `normalizeMetadata`
  output requires bumping `metadataKeyVersion`.
- The artist page reads its albums through `album_artist_index`, a derived
  table of each album's artist keys (`i:<id>` for the album artist and each
  credit, `n:<normalized name>` for a name-only album artist and each credited
  name), current only while its `source` equals the album's raw artist id,
  name, and credits plus `metadataKeyVersion`. Readers repair stale rows before querying, so no album
  write path maintains it. `watchArtistAlbumBuckets` re-reads only the
  artist's candidate albums (plus albums of the artist's songs) at most four
  times a second, classifies them with the same rules as before, and emits
  only changes; `getArtistPlaybackSnapshot` uses the same candidates.
- Per-song and per-page provider families (`songByIdProvider`,
  `songStarredProvider`, `songDownloadStateProvider`,
  `songPlaybackIndicatorStateProvider`, `pagedAlbumsProvider`, …) are
  auto-disposed. Row-level providers `select` their own entry from shared
  streams instead of opening one database watch per row.
- High-frequency values are published in bounded steps: sync progress through
  `LatestValueThrottle` (status and stage changes immediately, counts at most
  every 250 ms), download progress in whole-percent steps at most twice a
  second, and network usage records aggregated in memory and flushed every
  five seconds.
- Views derived from `cached_tracks` (cache stats, cached and downloaded id
  sets, cache types) emit only when their value changes, since most writes
  (a playback touch, download progress) leave them unchanged. The
  "Downloaded only" album and artist ids come from one join
  (`watchDownloadedContentIds`) instead of reloading every downloaded song
  on each write.
- Position ticks (5–10 Hz) are watched only by leaf widgets inside a
  `RepaintBoundary` (seek sliders, progress bars). The collapsed mobile Now
  Playing stays mounted under a disabled `TickerMode`, which pauses its
  animations and provider listeners.
- Database connections use WAL with `synchronous=NORMAL`, an 8 MiB page cache,
  in-memory temp storage, and a 64 MiB WAL size limit. Deferred startup
  maintenance runs a bounded `PRAGMA optimize`. Reverse-lookup indexes cover
  `songs(artist_id)`, `play_queue_items(song_id)`, `playlist_songs(song_id)`,
  and starred songs.
- Response byte accounting uses Dio's received-byte count; Navidrome gzips
  JSON without `Content-Length`, and re-encoding the decoded body cost two full
  JSON encodes of every large page on the UI isolate.
- Native and OS payloads stay bounded whatever the queue size: the native
  player holds a released window of the queue, the system media session a
  window of about 100 songs, and every queue edit is one batched native call
  (see "Released queue window"). On Android the platform thread is the UI
  thread (merged threads are Flutter's default), so any per-song platform call
  blocks frames.
- Queue changes publish one snapshot with a queue id list that is reused until
  the queue changes, so snapshot comparisons and `queueProvider` are
  identity checks for unchanged queues. The app shell ignores queue-only
  snapshot changes, and queue rows are keyed by song id and occurrence so
  inserting or releasing songs elsewhere does not remount rows.

## Testing Strategy

Automated tests are only the first layer for runtime-affecting work. Completion
also requires launching Navis and repeating the app-API validation loop in
`docs/development-workflow.md` from a clean isolated state.

### Unit Tests
- Provider logic
- Data transformations
- Business rules

### Widget Tests
- Screen rendering
- User interactions
- State transitions

### Integration Tests
- End-to-end flows
- Multi-provider interactions
- Database + API + UI

See individual test files for examples.

### Sync snapshot write safety

Authoritative catalog and auxiliary responses require a present, typed response
container. Missing/malformed containers are failures, not empty snapshots.
Playlist mutation acknowledgements may legitimately omit a snapshot and retain
the protocol-compatible empty-success behavior.
Album detail replacement validates requested identity, unique track IDs, parent
membership and declared counts; unresolved detail retains committed tracks.
Validation compares the declared count with the complete wire response before
projecting canonical tracks. Explicit `isExternal=true` children may reference
their own remote album and are excluded from local membership. Targeted detail
also stores these children with provisional parents; catalog enumeration does
not import them as local entries. Missing provenance does not relax the parent
check. The album header retains the server's advertised count, which can include
remote references; stored local membership is a separate quantity.
Playlist detail validates counts and identities while allowing ordered duplicates.
Canonical writes route external metadata to provisional references; incremental
artist discovery does not schedule external albums for catalog hydration.

Server snapshot writes read pending annotation actions and local mutation markers
inside the commit transaction. A local like, unlike or rating newer than the
snapshot keeps its current value, including after successful outbox delivery.
The latest mutation marker per entity/field is retained across concurrent snapshots.
Canonical and provisional metadata upserts omit primary-key assignments from
their conflict-update clauses. Reassigning an unchanged artist/album/song ID
still makes SQLite recheck child foreign keys; metadata refresh must not invoke
identity changes. Inserts keep their IDs, and actual identity remapping remains
the responsibility of `SongIdentityDao`.
Recently Added reconciliation reads only canonical album IDs and existing ranks,
rather than decoding full album metadata. Both full replacement and bounded
prefix merging preserve their existing ordering rules and skip unchanged writes.
Album reconciliation defers cache unlinking until commit; callers composing an
outer transaction supply the deferred path collection and clean it after that
outer transaction succeeds. Full repair retains its separate confirmation and
atomic promotion contracts.

Promotion progress separates classification (`validatingCandidate`, candidate
status `ready`), publication (`applyingCandidate`, status `applying`) and
post-commit cleanup (`cleaningCandidate`, with the active candidate cleared).
Diagnostics also report separate bounded build, raster and vsync-to-raster-finish
frame windows alongside the historical build-plus-raster sum. These are engine
timings, not a hardware dropped-frame count.
Database-canary phase samples therefore distinguish those intervals. Historical
reports emitted before this separation labelled all three as `applying` and
cannot isolate a transaction stall. Persisted apply duration is sampled inside
the publication transaction; it excludes final ledger/commit overhead.

Sync execution uses a per-server lease for catalog and targeted writes. An opaque,
non-reused owner token is carried through the execution's async scope. The SQL
interceptor validates it while acquiring SQLite's writer lock before mutation,
and checks ownership/expiry again before transaction commit. This covers DAO
batches, custom statements, hidden candidates, publication and durable progress;
a late response from a replaced owner cannot publish. Nested writes roll back
with their outer transaction. Recovery and provider-reset writes use the same
fence. Heartbeat loss also cancels transport. Ordinary playback and local user
edits execute outside the sync scope. This uses the existing lease schema; token
equality plus the database writer lock provides fencing without a new counter.

Schema v74 extends `star_sync_queue` into a durable annotation outbox with a field
(`star` or `rating`), attempt count, next retry time and safe failure category.
Migration preserves existing star/unstar rows. Local favorite/rating writes and
the queued version commit in one transaction through `StarSyncDao`; replacing a
field allocates a new row ID, so an older acknowledgement cannot remove it.
Star and rating intents for the same item coexist. Snapshot application protects
pending ratings as well as favorites.

`AnnotationSyncDispatcher` is the sole production API writer for likes/ratings.
The shared Riverpod instance starts with audio initialization or the shell,
serializes delivery, observes queue changes, and schedules persisted backoff
without requiring a connectivity transition. Authentication failures remain
queued and are released on session change; other errors remain retryable rather
than silently dropping intent. Each acknowledgement checks client/account
identity. Diagnostics builds disable transmission of copied annotations. ID3
album and artist favorite writes use `albumId` and `artistId`; songs use `id`.

#### Sync execution ceilings and track-verification age

Coordinated runs own an async request scope shared with the Subsonic transport.
Endpoint admission, actual retry attempts, byte counts, concurrency and elapsed
limits belong to that scope; unrelated UI traffic is excluded. Automatic passes
have a 30-second, 96-request, 32-album-detail and 32-MiB ceiling (three concurrent
requests). Manual discovery has 60 seconds, 200 requests, 64 details and 64 MiB;
initial/repair snapshots have ten minutes and 512 MiB. Limits defer persisted work
without discarding committed hydration batches. Long Retry-After responses are
scheduled through durable retry state.
The engine obeys the admitted execution plan even when a safely promoted partial
catalog has no full-completion timestamp. Only a plan granting a broad snapshot
can start one; an incremental continuation cannot expand into first-time scanning.

Schema v75 adds `albums.songs_verified_at`. Eligible unmetered catalog passes
verify up to 16 oldest track snapshots aged seven days or unknown. Complete detail
or candidate-song snapshots advance the date; headers and carried-forward local
tracks do not. With a stable catalog and successful eligible checks, full coverage
is bounded by seven days plus `ceil(album_count / 16)` eligible intervals. Offline,
playback deferral, metered policy, failures or competing discovery work extend
wall-clock coverage. Deliberate typed repair verifies tracks omitted by the bulk
index rather than accepting matching album headers as evidence.

Explicit current external-source observations may reclassify previously polluted
canonical IDs through `repairExternalSourceEvidence`, which supports dry-run
counts and records aggregate apply counts. It changes membership flags, retaining
rows, references and files. Prefix inference alone does not authorize this repair.
Deletion confirmation requires a fresh second snapshot and the same exact removed
identities; interrupted candidates also revalidate saved page boundaries.

Schema v76 keys playlist membership by `(playlist_id, sort_order)`, preserving
repeated tracks and ordered occurrences. Migration retains all legacy membership
rows in a deterministic order; song identity remapping updates every occurrence
in place. A separate singleton annotation-dispatch lease serializes outbound
writers across app processes. The one-minute lease renews every ten seconds;
acknowledgement and failure bookkeeping recheck ownership under SQLite's writer
transaction. Process death leaves persisted intent for a later owner. This lease
is independent of catalog sync so local annotations remain responsive during it.

Incremental artist metadata and its traversal cursor commit together before
track hydration. A budget interruption retains completed artists and requeues
failed/unstarted IDs; automatic/manual artist passes additionally cap at 24/48.
Cancellation waits for auxiliary cleanup and prevents later auxiliary domains
from starting. A completed run ignores a late heartbeat result, so it cannot
cancel a newer operation. Diagnostics endpoint accounting comes from the
operation's immutable state, including while status is polled.

The Android network-cost MethodChannel is registered on both the activity and
headless worker messengers through `registerNetworkCostChannel`. Headless sync
therefore receives the same `ConnectivityManager.isActiveNetworkMetered` value
as foreground sync; a missing native bridge still fails conservatively. Worker
engine teardown removes its handler.

Catalog hydration counts and ID selectors exclude provisional and external
references. Explicit remote detail hydration remains available outside that
catalog backlog. Newest discoveries follow explicit user priorities and precede
older pending details; bounded DAO reads preserve caller order before limiting.
A due automatic discovery interval takes precedence over old targeted hydration,
while checks inside the interval can continue pending-only work.

Album/artist header timestamp comparisons use Drift's whole-second storage
precision. Newest-feed header discrepancies only invalidate track hydration when
the album is new/unhydrated or track-relevant fields change. Rating,
play-count and creation-date updates alone preserve verified tracks; independent
age-based verification still covers song-only metadata changes.

### Sync cancellation drain

`LibrarySyncController.cancelAndWait` drains startup work, the engine, automatic
check completion (including its durable next-deadline write), and timer-arm tasks
before returning. Cancellation suppresses automatic rearming until the session's
existing restart path enables it again. Diagnostics shutdown and sign-out use
this barrier before database disposal; synchronous provider disposal alone
cannot await these owners.

### Android SAF availability during service-first playback

The private tracked `navis_android_storage` Flutter plugin registers a read-only
`com.navis.app/permanent_download_playback` channel on every Android engine.
`AndroidSafStorage.exists` uses it to query an already granted content document
with application context. It works when the canonical audio_service service
creates an engine before MainActivity and preserves permanent-download priority.
This does not eagerly create an engine, launch UI, request storage permissions,
or probe writable access. Folder management, import and write operations remain
on the activity-owned storage channel. Android native generated registration is
produced by Flutter; it is not edited manually.
