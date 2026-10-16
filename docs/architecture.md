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
  - The shell's battery tip remembers Later and sheet dismissal for 14 days in
    `battery_tip_snoozed_at.txt` in application support, using the same
    device-local file pattern as the changelog marker. Open Settings does not
    snooze the tip; no database schema change is needed.
  - `androidBackgroundSyncReconcilerProvider` owns native WorkManager
    scheduling reconciliation and constructs its scheduler directly; sync domain
    logic remains in the library planner/coordinator.
  - Foreground and worker staleness use the same configured interval minus
    a 5% tolerance clamped to 10–120 seconds; manual-only uses 24 hours.
    Worker terminal status records duration, including cancellation and
    bootstrap failures.
  - `navisBackgroundSyncEntrypoint` is a retained, UI-free headless Dart
    entrypoint. It loads the active encrypted credentials and builds only the
    database/API/sync pipeline through `LibrarySyncExecutionBootstrap`, the
    same production bootstrap used by foreground sync. It validates the
    opaque native profile key before any request and holds the same durable
    execution lease as foreground catalog work, so a late worker cannot run a
    replaced account or overlap a visible sync. The foreground app preempts a
    live worker lease and continues its committed progress (see the sync
    ownership and hand-off paragraph under the execution lease).
    `FlutterEngineBackgroundSyncSession` disables the embedding's automatic
    generated plugin registration and uses the allowlist next to the worker:
    `JniPlugin` and `JniFlutterPlugin` for path_provider's application context,
    `FlutterSecureStoragePlugin` for credentials, and `ConnectivityPlugin` for
    network policy. Drift/sqlite3 and HTTP use FFI/Dart. Native metering and
    `NavisAudioServiceProbe` observe policy through the existing app channels;
    the worker never registers audio_service, just_audio, audio_session,
    notifications, or other playback/media plugins. Attaching audio_service
    to a short-lived worker would share its static media-browser connection
    and handler callbacks with the foreground playback engine.
  - Its `BackgroundSyncPolicyTracker` observes connectivity changes and
    refreshes native metering and audio-session activity every two seconds during
    the pass. The coordinator and engine consume that current policy at their
    existing eligibility gates, so a metered transition defers later broad
    work instead of retaining startup
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
  - `AudioBootstrapController` owns one handler construction. Its five-second
    presentation deadline exposes slow-start recovery but never retires the
    pending session future or starts a competing handler. Completed failures
    can retry after three seconds. Native audio_service configure has a bounded
    five-second wait and retains its single process-wide initialization; a
    permanently pending configure requires a process restart. Explicit session
    teardown fences and disposes late results before a successor construction.
    No native plugin rebind is performed.
  - Handler readiness includes local volume and audio-session initialization
    after construction and binding. A stall keeps the five-second bootstrap
    deadline and Restart Navis recovery reachable; completed local failures
    dispose the handler and retry silently. Readiness excludes saved-queue
    restoration and network source preparation. Saved queue metadata, occurrence order,
    shuffle/repeat, selected index and position restore asynchronously through
    the existing queue lane, and publish immediately to the mini player and
    media session. Play, seek, navigation, queue edits or explicit media-session
    Prepare materialize sources through the existing download → rolling cache
    → stream resolver. Cache maintenance runs before source preparation, outside
    startup readiness; generation checks keep late restoration from replacing
    newer commands. Queue replacement, clear and radio admission discard lazy
    restore state, and first Play checks transport/queue ownership before any
    fallback replacement. Previous uses the saved logical position until the
    native source is ready, restarting at zero past three seconds. Snapshot
    publication preserves active radio media-session metadata.
    An unavailable saved source retains the existing explicit
    Play fallback to recent/liked music.
  - Five seconds after the overlay appears, its recovery panel offers Restart
    Navis and Copy details alongside secondary cache reset and sign-out. Android
    restart uses MainActivity's device channel to launch a NEW_TASK|CLEAR_TASK
    activity and kill the old process. The same PlaybackRecoveryService owns
    clipboard copying; About's version row exposes it through a hidden long-press
    and the existing AppNotice confirmation.
  - Android Auto can invoke Dart before `MainActivity` exists. Navis creates
    the provider container and starts audio bootstrap immediately, while
    `AndroidUiBootstrapGate` defers `SystemChrome`, notification, diagnostics
    UI, and `runApp` work until the first Android `resumed` lifecycle state.

- **Android Auto phone projection**
  - The app-owned `com.ryanheise.audioservice.NavisAudioService` subclass is the
    exported native `MediaBrowserService`. Narrow app-owned redirects route the
    plugin's explicit base-service binding and foreground start to it. The plugin
    still delegates browse requests to the shared `NavisAudioHandler`.
  - `AutoMediaTreeService` builds the local database-backed browse tree. Its
    four root tabs are Liked, Recent, Playlists, and Library, stored once per
    service instance. Collection projections cap browse lists and liked songs
    at 500 items; album and playlist tracks remain uncapped. Liked exposes
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
  - See `docs/platforms/android-auto-testing.md` for DHU validation and
    `docs/platforms/android-auto-real-car-testing.md` for trusted-store real-car checks.

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
- `reorderQueueProvider` - Reorder queue items

**queue_current_row_centering.dart**: `QueueSheet` (phone overlay, compact-wide
overlay, embedded and wide Now Playing panels) and `QueueScreen` wrap their
list in `QueueCurrentRowCentering`, which once per open jumps (no animation,
so reduced motion needs no case) to the playing row: an estimate from the
measured row extent, then `Scrollable.ensureVisible(alignment: 0.5)` on the
real `QueueTrackRow`, repeated for a few frames while lazily built rows
resolve and change height. `queueCurrentIndex` supplies the logical index and
is null for radio, an unknown index or a queue still being replaced, which
means no scroll. Offsets clamp at the list ends, so short queues do not move.
The widget stops at the first user scroll and never re-centres on track
changes or rebuilds. Because the list now opens scrolled, the phone overlay
(`app_shell_queue_overlay.dart`) lets a downward drag that starts outside the
list (header, drag handle) move the sheet even when the list is not at the top.

**providers/app_providers.dart** (player state):
- `lyricsProvider` - Lyrics for a song
- `playerStateProvider` - Playback state

#### Library Feature (`lib/src/features/library/presentation/`)

**library_sync_provider.dart**:
- `librarySyncEngineProvider` - Sync engine instance
- `librarySyncControllerProvider` - Sync state and controls
- `syncStaleAfterForInterval` - Shared foreground/worker staleness function
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
  carry it: one controller helper persists schedule changes and updates
  session-matching status; the controller keeps it on progress frames and,
  after every catalog run, reloads both `next_automatic_check_at` and the failure
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
- Schema 43 (Navis 1.0.0) is the supported upgrade floor. Older test-era
  databases drop all user tables, indexes, views, and triggers with foreign
  keys disabled, then run the same creation and defaults as a fresh install.
  Schema 43 and later preserve data through an ordered migration-step table.
  The steps, index creation, settings defaults and `user_version` commit in
  one transaction, so a failure or lock timeout part-way leaves the previous
  schema and data intact and a reopen reruns the whole upgrade from the same
  version. This matters for the v75→76 playlist-membership copy and the v46
  scrobble-queue rebuild, which cannot be re-entered after a partial run.
- Schema v71 adds redacted sync diagnostics history alongside the durable
  `library_sync_work` queue: `library_sync_run_request`,
  `library_sync_run_attempt`, and `library_sync_run_outcome`. Schema v93
  drops the write-only `library_sync_provider_profile` and
  `library_sync_repair_session` observations; operational provider/candidate
  state remains in `library_sync_state`; the mobile-data grant stays in memory.
  The immutable `LibrarySyncRequest` carries origin, intent, target, and an
  ephemeral metered grant. The scheduler resolves it into immutable
  `SyncExecutionPlan` endpoint/page/hydration/byte/concurrency limits before
  dispatch. History records the contract version and target-derived intent;
  the legacy grant, priority, target identifier, and resumption columns remain
  neutral. Consent is never restored from a history row or durable work.
  Terminal history retains only enums, aggregate counts, and timestamps for
  90 days; a target key is cleared on completion,
  so neither diagnostics nor Settings history retains IDs, titles, URLs,
  credentials, or filesystem paths.
  Pre-v71 work is no longer imported into typed run history. Startup still
  resumes interrupted work and typed attempts independently; the persisted
  legacy origin/reason enum indices and planner-version column remain stable.
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
  Sync Settings uses this first usable-catalog date only when no later catalog
  update, sync-state timestamp, or server-config sync timestamp exists.
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
- Drift caches a failed open or migration on its executor for the life of the
  database. `NavisDatabase()` and `NavisDatabase.atPath` therefore open
  through a reopening executor inside the sync write fence
  (fence(reopening(lazy(native)))). When opening fails with `SQLITE_BUSY` or
  `SQLITE_LOCKED`, including when nested in drift's isolate errors, it closes
  that executor's connections and isolates and opens a fresh one, up to three
  attempts, each waiting up to the 5 s busy bound, 1 s and 2 s apart; concurrent queries share one open. It
  replaces the executor before the final rethrow, so the next query opens
  afresh instead of rethrowing a cached error. Other errors still surface
  unchanged, and the database file is never reset or deleted to recover.
  Failed and recovering attempts are recorded as bounded `databaseOpen`
  startup events.
- All transactional writes go through `NavisDatabase.transaction`, including
  DAO calls routed by `NavisDaoTransactions`. Drift 2.35 announces nested
  savepoint updates on the root stream store before the outer commit, so WAL
  readers can re-read old data and otherwise remain stale. The outermost call
  uses a database-specific zone key and creates root `tableUpdates()` outside
  Drift's transaction zone. It starts listening inside the transaction action,
  once the writer lock is held, collects premature root announcements with
  their update kinds, then drains their pending asynchronous deliveries and
  cancels the listener before committing. Cancellation detaches the root
  broadcast listener synchronously; its completion future is not awaited,
  because Drift's `Stream.multi` pipe chains cancellation through a root-zone
  future that can strand subsequent commit work in Flutter's FakeAsync queue.
  After a successful commit it replays only those collected updates with
  `notifyUpdates`. Drift dispatches the outer transaction's own tables after
  commit; these are not collected or
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

**Library providers**:
- Artist, album, and song providers shared by Library presentation screens
  live in `lib/src/providers/app_providers.dart`.
- Route-local state and scroll/section coordination remain in the dedicated
  presentation providers beside their owning screens.

#### Auth Feature (`lib/src/features/auth/presentation/`)

**server_config_provider.dart**:
- `serverConfigProvider` - Server configuration controller
- `serverConfigStateProvider` - Server config state
- `serverConfigRepositoryProvider` - Config repository

**server_reachability_provider.dart**:
- `serverReachabilityControllerProvider` - Server reachability state;
  `retryNow()` backs the shell offline banner's Retry (see "Offline banner
  and the top inset")

#### Retired Listen Together Feature

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

Credential redaction treats URL user info as a credential: request logging and
free-text error redaction strip it, and OS media URL guards reject it. The server password and URL user info use separate keys in the existing secure
credential store, with a memory-only fallback when platform storage is unavailable.
Drift stores the credential-free URL; active configs merge user info back in memory
for HTTP and media Basic authentication, including Android background sync. Loads
scrub legacy URLs once; signed-out profiles are scrubbed without restoring secrets.
Both sign-out modes delete both keys. A full wipe also clears the ListenBrainz
secure token, username, token-valid flag and scrobbling enablement through the
existing store and targeted settings writer; keep-data sign-out retains them.
Credential deletion failures reach teardown warning reporting. Profile identity
excludes URL credentials.

Credential read failures are transient and must never sign the user out or
delete secure data. Auth and external scrobble storage disable Android's
`resetOnError` while retaining the default namespace and ciphers. The auth
store throws `CredentialReadException` when a platform read fails without a
session fallback; only a successful read returning a missing or empty password
marks the retained profile signed out. A password-only session fallback also
allows absent optional URL credentials when platform storage is unavailable.
After hydration, credential stream errors retain the active session and API
client; a later row emission or refresh re-reads storage. Provider bootstrap
retries this exception with `navisProviderRetry`; after those retries are
exhausted, each audio bootstrap retry invalidates the failed credential provider
before hydration, bounded by the existing bootstrap cadence. Clone diagnostics
also retry a failed backing credential load on the next read. The headless
Android worker reports `transientFailure` with `retry: true`. Sync reads fail
the attempt without changing authentication. The playback bootstrap overlay offers “Continue to
sign in” only after the server config resolves to null; loading and error states
keep the existing authenticated recovery actions.

Connection probes always start with token authentication, regardless of the
reported API version. Only Subsonic code 41 (token authentication unsupported)
permits a legacy retry. That retry is blocked for non-loopback HTTP servers and
asks the user to connect over HTTPS; code 40 never sends a reversible password.

`buildSubsonicAuthQuery` (`lib/src/api/subsonic_auth_interceptor.dart`) is the
single builder of the `u`/`v`/`c`/`f` and token (`s`, `t`) or legacy (`p`)
parameters. `SubsonicAuthInterceptor` uses it for API requests and
`SubsonicApiClient` uses it for stream, download and cover-art URLs; add new
auth parameters there, not at call sites.

Navis retains one local server/account profile. Its stable identity is the
normalized server base URL plus trimmed username. Schema v61 stores
`server_config.is_authenticated` separately from the non-secret profile:
keep-data logout clears secure credentials and marks the row signed out without
discarding its committed catalog, sync generation, provider tuning, timestamps,
or Navis capability metadata. Reauthenticating the same identity updates that
row in place. A different identity must traverse the explicit destructive
replacement boundary before its credentials can be stored. Only keep-data
logout, wipe logout and `clear()` delete the stored password. Reading the
active server while no row is authenticated returns nothing and leaves the
password alone, because sign-in stores the password before it marks the row
authenticated. An earlier read path deleted it in that gap, so a sign-in after
a keep-data logout lost its password and the next credential read (for
example an artist page's targeted sync) signed the user out again.

Routing derives a compact `SessionRoutePhase`. A newly authenticated profile
without a usable catalog stays on the full-screen `/initial-sync` rebuild route.
Promotion alone does not admit Home. A complete run requires no blocking album
hydration, artist verification, or candidate and durable full-sync evidence
(`server_config.last_synced` or `library_sync_state.last_catalog_synced_at`).
Pending albums with valid persisted incomplete server-detail classifications
do not block completion or freshness; they remain queued for retries.
A validated catalog published in that run is also usable when every remaining
canonical album has a valid incomplete-detail classification. The controller
stores `library_sync_state.initial_catalog_usable_at` for both successful and
partial incomplete-detail completion, and keeps the completion warning.
Successful completion remains current; the partial exception admits onboarding
or Home across restarts without claiming full freshness. All full-screen rebuild
reasons share the incomplete-detail completion predicate. Other failed, deferred,
or partial runs keep retry and sign-out actions; offline and metered conditions
retain their retry/consent behavior. Pending albums continue through eligible incremental
checks. First setup owns catalog sync until readiness: startup, automatic
checks, and Android workers defer without arming or persisting a new automatic
deadline. Android reports this as `deferredSetup`. Setup waits for any active
catalog run and queued successor before reading the committed generation and
choosing its first-catalog request or full scan. Successful readiness records
also stamp the required sync model and cache epoch before the controller's
catalog future completes. Startup and cache-upgrade checks drain active catalog
work before reading readiness and installation stamps, including when the engine
has already published `last_synced`. Server-state and readiness listeners schedule work in
the controller's async zone rather than inheriting the executor's write fence.
Readiness restarts the automatic schedule at now plus the configured interval
and resumes the startup pass, avoiding a redundant sync-model repair. Without
that gate an automatic run started at launch could publish the catalog first and
turn setup's queued request into discovery that cannot publish, ending setup at "could not be set up". First
setup without a committed catalog requests the planner's first-catalog
snapshot. When a committed generation (or `last_synced`) already exists
without readiness evidence, for example after an interrupted setup and
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
   forward`. Android clone diagnostics require a sidecar package and an
   isolated database/cache root in that package's scoped storage.
2. Clone mode opens an isolated database and cache tree. Primary certification
   uses the normal profile only with the launcher's backup and mutation
   restrictions.
3. After `runApp`, the server binds to IPv4 loopback on an ephemeral port,
   creates a random bearer token, and writes its port, token, process ID, and
   mode to a handshake file. Linux/macOS profiles apply mode `0600`; Windows
   relies on its per-user diagnostics directory and does not invoke a POSIX
   permission command before starting the request loop. On Android, the host
   receives the handshake from the app-owned native bridge in
   `getExternalFilesDir(null)/navis-diagnostics`. Android startup resolves
   `isSidecar` by comparing `PackageInfo.packageName` with `com.navis.app.navis`
   and creates `artifactRoot` below `getExternalStorageDirectory()`, which maps
   to the same app-specific external files directory. These lookups use the
   application context and do not wait for MainActivity to attach to
   audio_service's warmed engine. Clone bootstrap checks identity and creates
   the directory before Drift opens. The `com.navis.app/diagnostics_handshake`
   activity channel retains `publish`/`clear` and the sidecar fixture-tree
   lookup; the bridge validates and replaces the bounded handshake before
   the loopback server begins serving.
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
package's scoped external diagnostics directory, while all route and feature
controls remain disabled. `GET /v1/presentation/status` reports the live route and
viewport plus post-bootstrap app readiness,
`POST /v1/presentation/navigate` drives the real `GoRouter`, and
`POST /v1/presentation/screenshot` waits for a completed, animation-settled
frame before writing a 1.0-ratio PNG below the validated artifact root
(`"pixelRatio":"device"` captures at the device's resolution instead, for
marketing screenshots). The server creates filenames,
returns only relative path/dimension/digest metadata, and protects the
screenshots directory and files with modes `0700` and `0600`. Non-route UI uses
narrow production-controller actions such as the queue/Now Playing
`POST /v1/presentation/player-overlay`; the control plane has no generic
coordinate-click interface. Clone-only `POST /v1/presentation/press
{"key":"<ValueKey>"}` calls the production callback of the onstage button with
that widget key (or the first enabled button inside it) and reports `pressed`;
it never synthesises pointer input.
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

Sync diagnostics expose terminal `durableRuns` history through
`GET /v1/sync/ledger`, with request/attempt IDs, typed origin/intent/target/plan,
safe outcomes and aggregate counts. `GET /v1/sync/attempts` supplies redacted
endpoint telemetry. This history is a diagnostics record; `library_sync_work`
remains the durable scheduling queue. Action diagnostics wait for the controller
request to settle before correlating newly completed history rows, including
companion auxiliary work.

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
secure storage. `GET /v1/session/status` reports the route-owned initial-login
rebuild controller when mounted, falling back to the session phase and catalog
sync status when no controller exists. Observation never instantiates a rebuild.
The initial-sync retry/mobile/cancel routes act on that same mounted controller
and return conflict when it is inactive. Cancel uses `cancelAndSignOut`, keeping
local data just as the screen does; there is no second setup state machine.
Clone-only `GET`/`POST /v1/presentation/library-rebuild` reports the route-owned
full-screen rebuild controller for a given `reason`, and can `retry` or press
its `cancelAndSignOut`. It reports `inactive` rather than instantiating an
unmounted controller, because instantiation starts a rebuild. The
`existing-catalog` mode uses these to verify keep-data sign-out, cancellation
and wipe sign-out followed by a new sign-in in the same process. The mounted
rebuild controller watches session identity, so a new session starts a new visit
and supersedes the old run.

Clone-only `POST /v1/session/connect` validates and saves a server session
through the production connection service without starting a rebuild merely to
build its response. The required rebuild screen owns the interactive first-sync
request; the library controller coalesces
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
`docs/development/development-workflow.md` for the mandatory validation loop and
target-selection rules.

## UI Component Organization

### Theme and design tokens (`lib/src/theme/`)

- Schema 97 adds `app_settings.now_playing_background`: `tinted` (default),
  `artwork` or `plain`. The guarded 92→97 migration maps the retained legacy
  `art_tinted_now_playing` boolean to `tinted`/`plain`. The enum model field and
  `nowPlayingBackgroundProvider` are authoritative. The retained boolean is
  only a historical migration source: active writes, full saves and resets do
  not update it, and there is no legacy model field, provider or DAO writer.
  Appearance uses the production DAO's targeted writers consistently;
  SettingsRepository maps and saves the typed model and onboarding changes.
- App-wide Density covers Home and lists using the existing `home_density`
  column, with `comfortable` (default) or `compact`. `densityProvider` exposes
  `NavisDensity`; the model's `homeDensity` is typed too. Home reads the same
  provider directly, with no string provider or legacy DAO writer.
  Unknown stored values and unloaded settings use the defaults. The background
  choice joins the setup highlights registry for 1.5.0; Density
  is a renamed existing setting (it also tightens playlists and artist lists)
  and has no New tag. Both appear in diagnostics.
- Now Playing Background (`now_playing_backdrop.dart`, `now_playing_artwork_background.dart`):
  `NowPlayingBackdrop` owns image resolution, tint prewarming, failure fallback
  and surface decoration for both `NowPlayingScreen` and the desktop lyrics
  view. The desktop lyrics header uses `nowPlayingArtworkPanelFill` too.
  Art-Tinted is the existing tint/gradient (solid under Flat). Plain is the
  theme `surface` (black in OLED). Artwork decodes the standard 600 px cover
  through the shared `coverArtImageProviderFor` source resolver at 96 px
  (`ResizeImage`). Permanent downloaded artwork works offline; connected
  refreshes use the cover revision in the existing cache manager key. The layer
  renders the decoded thumbnail once through a `PictureRecorder` with a
  clamped Gaussian blur (sigma 5 in thumbnail pixels), then draws it with
  `RawImage`/`BoxFit.cover` and medium filtering inside a `RepaintBoundary`.
  There is no live blur or overscale during playback or crossfades. The
  keep-alive `nowPlayingArtworkCacheProvider` coalesces pending preparation
  by source/revision key and keeps a four-entry LRU; eviction and provider
  disposal release cache-owned images, while each mounted/fading layer owns
  a clone until disposal. The app shell watches
  `nowPlayingArtworkPrewarmProvider` on Artwork setting and track/source
  changes, outside the paused player sheet, with background cover-load
  interest. Both the player and queue keep their Stack and artwork scope
  mounted across tinted/Artwork/plain changes, retaining body state. The layer
  lays `NavisColorStyleData.nowPlayingArtworkVeil` over it
  (adaptive: the smallest alpha keeping both `onSurface` and the accent-coloured
  title at 5.0:1 against the shared cover field's usable-cell average (from
  `coverColourFieldProvider((id, revision))`), within dark 0.30-0.80, OLED
  0.72-0.92 so it still reads as OLED, and light 0.58-0.88; fixed
  0.68/0.8/0.68 until the average is known) and adds a 0.15 veil over the
  bottom fifth. The previous cover stays until the next one
  decodes, then crossfades over `MotionPolicy.surface`. Cover-id art uses
  the worker's field for its veil; radio/URL art uses the cached average
  computed from the same decoded thumbnail.
  Veil colour changes animate over `MotionPolicy.tint` (zero with reduced
  motion); desktop lyrics retains its higher text-across-cover floor.
  The decode listener disposes every received image handle, including stale
  callbacks, and detaches once on success or failure. Failed source keys are
  remembered by the layer and reported after async preparation,
  selecting Art-Tinted without retrying on position rebuilds. A new source or
  revision can resolve again. Flat has no blur, so
  Artwork falls back to the Flat solid tint (OLED + Flat stays black); radio or
  external art uses the same allowed-artwork path as the tint, and with no
  image Artwork falls back to the tinted look. Tint extraction only runs when a
  tint is drawn. While the Artwork layer is shown, the split-layout lyrics
  and right panes, the embedded queue sheet and the wide side-panel sheets
  paint a translucent veil (`nowPlayingArtworkVeilBase` at 0.45) instead of
  an opaque surface so the art stays visible: `NowPlayingArtworkLayerScope`
  (`now_playing_artwork_scope.dart`) is set around the Now Playing body and
  panels read it through `nowPlayingArtworkPanelFill`. Without the layer, and
  under Flat, they stay opaque. The expanded Now Playing backdrop publishes its
  image provider, source key and cover average after the frame through
  `nowPlayingPublishedBackdropProvider`, with owner-checked cleanup when hidden,
  switched away from Artwork, or disposed. The phone queue overlay outside the
  Now Playing subtree reuses that same prepared blur through the shared cache in
  `NowPlayingArtworkBackground` beneath its own active artwork scope. A queue
  opened from Home with Now Playing collapsed, or under Flat, stays opaque.
  The adaptive veil keeps `onSurface`,
  `onSurfaceVariant` and the accent title at 5.0:1. In OLED the Art-Tinted
  gradient's top colour is capped at HCT tone 10, and with OLED + Flat the
  Now Playing Background selector notes that Now Playing stays black.
- Density is provided by `NavisDensityScope` (`navis_density_scope.dart`,
  placed in `MaterialApp.builder` from `densityProvider`). List rows read
  `NavisDensityScope.of(context)`; without a scope they are Comfortable.
  Compact: `AdaptiveTrackRow` min height 64→52 and vertical padding 8→4 (an
  explicit `minHeight`/`padding`/`leadingExtent` still wins), track covers
  48→40 (`TrackListTile`, `AdaptiveTrackHeader` leading width follows), library
  playlist rows 48→40 covers with dense `ListTile`, artist list rows 40→36
  covers with dense `ListTile`; Home keeps reading the same value. Row action
  buttons keep their 48 px targets.

- `navis_theme.dart`: `buildLightTheme`, `buildDarkTheme` and
  `buildOledTheme` take the user's seed (or the dynamic album colour) and a
  colour style, get a `ColorScheme` from `buildStyledColorScheme`, and
  delegate to one shared builder. Typography, component themes and theme
  extensions are defined only in that builder. `NavisApp` constructs only the
  active brightness/OLED variant and reuses a per-app eight-entry LRU cache
  (`NavisThemeCache`) keyed by seed, brightness, OLED, style, Flat, Flat areas,
  corners and colour adjustment.
  Unrelated settings rebuilds reuse complete themes; new album seeds build
  only the visible variant, and switching back can reuse a cached theme.
  OLED cards, dialogs and sheets
  take their colours from the scheme's container roles, whose chroma styled
  schemes cap at 2 so they read black-ish. OLED chrome is true black: the
  phone mini player, desktop sidebar and desktop player bar are `surface`
  (`#000000`) with a hairline `outlineVariant` separator like the navigation
  bar, never a tinted container.
- Colour styles (`navis_color_style.dart`, `navis_style_schemes.dart`,
  `navis_color_style_data.dart`) are a second axis next to the theme mode:
  Neutral, Pastel, Immersive and Night each work with Light, Dark, OLED and
  Auto.
  - Stored in `app_settings.color_style` (schema 97) as `neutral`, `pastel`,
    `immersive` or `night`; fresh installs, upgraded rows and resets use
    `neutral`. `colorStyleProvider` resolves it through
    `NavisColorStyle.parse`, which falls back to Neutral while settings load
    or for unknown values.
  - Schema 97 also persists `oled_for_auto`, `night_schedule_enabled`,
    `night_schedule_start_minutes`, `night_schedule_end_minutes` and
    `flat_surfaces`. Fresh installs, upgrades and resets disable all three
    switches and use a 22:00–07:00 Night window; DAO writes clamp minutes to
    0–1439. Targeted updates preserve the other appearance settings.
    `oledForAutoProvider`, `flatSurfacesProvider` and `nightScheduleProvider`
    expose these settings with the same defaults while settings load.
  - `effectiveColorStyleProvider` overrides the user's style with Night inside
    the enabled local-time window, including windows spanning midnight. The
    start is inclusive, the end exclusive, and equal times never activate.
    An overrideable `nowProvider` and a disposable boundary timer, capped at
    fifteen minutes, recheck wall time after suspend without changing the saved
    style. Resume invalidation in `app.dart` remains in place. `app.dart`
    uses this effective style and selects OLED for Auto's dark theme when
    `oledForAuto` is enabled. `flatSurfacesProvider` drives Flat rendering.
  - Schema 99 adds `flat_areas` (integer mask, default 7) and
    `album_art_colored_shade` (boolean, default false) in one guarded upgrade.
    `FlatAreas` is the immutable model value: bit 1 selects surfaces (panels,
    shadows, glows and fade strips), bit 2 selects Now Playing (backgrounds,
    panels and mini player), and bit 4 selects text over artwork (album-card
    captions and album/playlist headers). The mask accepts only 0–7; resets
    restore all areas and disable coloured shade. `flatAreasProvider` and
    `albumArtColoredShadeProvider` expose the defaults while settings load or
    fail. DAO targeted writers preserve unrelated settings; onboarding Finish
    writes these settings only when changed from the entry snapshot.
    `NavisColorStyleData.flat` remains the master switch; `flatSurfaces`,
    `flatNowPlaying` and `flatArtworkText` each combine it with the corresponding
    area. All three theme builders, the theme cache key and setup preview carry
    the mask. With all areas selected, Flat retains its previous behaviour.
    Schema 100 adds `album_art_shade` (boolean, default false); its guarded
    99→100 step enables it for rows with `album_art_colored_shade = 1`, preserving
    existing colour choices. Replaying the step preserves later shade choices.
    `AppSettingsModel.albumArtShade`, `updateAlbumArtShade(enabled:)` and
    `albumArtShadeProvider` carry the parent setting. `albumArtColoredShade`
    remains the independent Use Cover Color flag; disabling Shade retains it.
    `albumTitleShadeModeProvider` exposes `AlbumTitleShade.classic` when Shade
    is off, `dark` when only Shade is on, and `color` when both are on. Loading
    and failed settings resolve to classic; resets disable both flags.
    Onboarding Finish diffs each flag against its entry snapshot, preserving
    concurrent writes to unchanged choices. `SetupHighlight.albumArtShade`
    owns the single 1.5.0 parent tag and retains the `albumArtColoredShade`
    storage key so existing acknowledgements survive.
    The authenticated, clone-gated `/v1/presentation/appearance` endpoint
    returns `flatAreas` as an integer and `albumArtShade` / `albumArtColoredShade`
    as booleans; POST validates their types and mask bounds before any targeted
    writes. Either shade flag can be set independently.
  - Colour and Brightness tuning (`ColorAdjustment`) layer on every style,
    including Neutral, in Light, Dark and OLED. Vividness and depth are integer
    steps −5…+5, default zero. `buildStyledColorScheme` runs the HCT
    `adjustColorScheme` post-pass after the style recipe. Zero/zero returns the
    original scheme without round-tripping any channels. Vividness multiplies
    accent/fixed/container, surface and outline chroma by `1 + 0.1 × vividness`;
    errors and on-colour text stay unchanged at Tint 0 (except repaired
    container ink), as do pure black and white roles.
    The mud guard covers the same roles as the muddy-band test (containers,
    surfaces, and primary/secondary in dark modes): at tone 24.5–50.5 their
    chroma is capped at 24, but never below the style's own (muted) chroma, so
    every Color step is monotonic and a Brightness-only change leaves the
    accents untouched. Light ink accents and inverse roles are not capped.
    Pure black/white accents remain unchanged by intensity and brightness.
    OLED containers target chroma at most 1.5 to keep decoded RGB chroma
    below 3. Depth moves the surface family and outlineVariant:
    Light +5 lowers tone by 4.5, −5 lifts by 4 (cap 99); Dark ±5 moves tone
    by ∓6 (floor 2). OLED surface, surfaceDim and surfaceContainerLowest stay
    black; the other surface containers move at most ±3 tones (floor 2).
    The Light deeper range is smaller than the initial −7 proposal to preserve
    the existing 3:1 accent contrast on Pastel's highest surface.
  - Accent role contract (all styles and modes):

    | Role | API / scheme colour | Purpose |
    |---|---|---|
    | Solid | `playButtonFill(scheme)` / `onPlayButtonFill(scheme)` | Main Play everywhere; primary/onPrimary under Accent |
    | Tonal | `secondaryContainer` / `onSecondaryContainer`; `tonalControlFill(scheme)` / `onTonalControlFill(scheme)` | Secondary filled controls and selection indicators |
    | Neutral | `surfaceContainerHighest` / `outline` | Inactive tracks, off states and boundaries |
    | Ink | `primary` and readable `onSurfaceVariant` | Plain accent icons and supporting text |

    The scheme builder separates primary/secondary containers from `surface`,
    `surfaceContainer` and `surfaceContainerHigh` by at least 5 tones in Light
    and 4 in Dark/OLED. It targets another 0.6 tone for RGB rounding, and
    compensates on-container ink to keep 4.5:1. The same guard runs after
    tuning. Light Pastel fills use the accent hue at chroma 20 near tone
    82–84, rather than almost-white pink; other Light recipes start at tone
    82 so lowering a gamut-clipped fill does not preserve unnecessarily low
    chroma. Pastel retains its accent/artwork softness caps. Normal filled
    buttons use Material's solid primary defaults in Light Pastel too.
  - Tint runs after intensity and brightness. At Tint 0 it performs no colour
    conversion, so existing adjusted colours retain their exact channels.
    Light page tone interpolates toward `88 + brightness shift`, with a
    floor of 84; page chroma interpolates toward at least 24 at Tint 5,
    independent of the near-grey baseline, with HCT clipping to sRGB. Near
    white, a warm accent hue can shrink the gamut: page tone gains just enough
    headroom (still ≥84) to keep the first Tint step from losing chroma.
    Light follows the accent hue. The Low/Container/High panels progressively
    become 7/5/3 tones lighter than the page, with chroma targets 6/9.6/12;
    Lowest/Bright become near-white. At Tint 5, Highest stays 6 tones below
    paper for inactive controls. Light primary and family ink are deepened as needed
    for 3:1 against every surface role, onSurfaceVariant for 4.5:1 and
    onSurface for 7:1. Dark retains its surface tones and style surface hue,
    targeting chroma 22 while respecting the muddy-band guard. OLED retains
    pure-black surface/Dim/Lowest and caps all other surfaces at chroma 1.5
    before RGB conversion (decoded chroma ≤3).
  - Controls is independent of surface tint. `ColorAdjustment.controls`
    reaches `NavisColorStyleData.controls` and the existing theme-cache key.
    White Controls use opaque white Play/FAB fills and tone-35 accent glyphs
    (≥4.5:1), with secondary fills made by compositing white over `surface` at
    50% in Light (more visible tint) and 80% in Dark/OLED (glyph contrast).
    `controlEdge` supplies an accent hairline at 25% opacity in
    Light, otherwise null. Plain icons retain readable scheme ink.
    The shared builder themes Slider (white track/thumb, inset 2 dp accent
    ring, Highest inactive track), Switch, NavigationBar, FilledButton,
    selected SegmentedButton/Chip and FAB colours. Flutter's one
    FilledButtonTheme cannot distinguish solid and tonal constructors:
    the UI must route tonal buttons through the tonal API explicitly.
    IconButtonTheme likewise stays shape-only because filling it would
    fill plain IconButtons, and the FAB is always the solid action (Material's
    default is a container). Widgets therefore take the role through
    `NavisColorStyleData.playStyleOf(context)` / `tonalStyleOf(context)` (or
    the `playButtonStyle(scheme)` / `tonalButtonStyle(scheme)` instance
    methods), which return a `ButtonStyle` with the role's fill, glyph and,
    in Light White, the `controlEdge` hairline, disabled states untouched;
    `circular: true` keeps icon buttons round. Routed solid: mini player Play
    (phone, rail and compact), desktop player bar Play (now `IconButton.filled`,
    it was a filled-tonal button), desktop mini player Play, entity Play
    (`EntityActionBar`, labelled and compact), album-card hover Play, You Might
    Like play, the Equalizer save button and the FAB. Routed tonal: Shuffle,
    Instant Radio (`FilledButton.tonalIcon`, no hand-set colours), every
    `FilledButton.tonal*` and `IconButton.filledTonal`, rail and sub-navigation
    tile selection, the Navigation Bar indicator (theme), the Navbar style
    picker, EQ band chips, the Downloads count badge and the Equalizer quick
    action when open. Spinners inside Play buttons use `onPlayButtonFill`.
    A toggle passes `selected`: on is the tonal fill, off is the neutral role,
    an outlined button without a fill (`outlineVariant`, `onSurfaceVariant`),
    because Material's off container sat within 0.1 contrast of the tonal fill
    on tinted pages and left on and off indistinguishable (Home Liked and
    Downloaded). Kept as they are, because they are status or decoration and
    not controls: notices and EQ banners, artwork placeholders, the New tag,
    download badge, queue-shuffle badge and shortcut-capture highlight.
  - Schema 101 (unreleased) stores `color_vividness`,
    `surface_depth_light`, `surface_depth_dark`, `surface_tint_light` and
    `surface_tint_dark` with zero defaults, `control_color` TEXT (default
    `accent`, alternative `white`), plus
    the `appearance_looks` JSON TEXT library (default `[]`) and nullable
    `selected_appearance_look_id`. Tuning presets and their selected id were
    removed from this unshipped schema; Looks are the only appearance preset
    system. Every 100→101 column addition is guarded;
    the branch-only `surface_depth` definition was replaced before shipping.
    `ColorTuning` clamps intensity and both brightness steps to −5…+5,
    and `lightTint` / `darkTint` to 0…5. Its `controls` enum and
    `copyWith` preserve all axes during partial edits. `forMode(dark:)`
    resolves to `ColorAdjustment(vividness, depth, tint, controls)`: Light
    uses light depth/tint; Dark and OLED share dark depth/tint. `app.dart`
    resolves the active variant
    before looking up the existing theme cache. Theme extensions, caption
    workers, memo keys and cover caches still carry only resolved adjustments.
    `colorTuningProvider` exposes persisted tuning (identity while loading or
    failed); `colorTuningPreviewProvider` offers nullable `preview` / `clear`,
    and `effectiveColorTuningProvider` combines preview ?? persisted. Setup
    previews its draft and Finish diffs each tuning axis and Controls, preserving
    concurrent changes to unedited axes. Settings uses the effective colour style for the
    Fine-Tune band, so a scheduled Night window agrees with the rendered app;
    the Night Schedule control still receives the saved style.
  - `ColorTuningController` exposes tuning state, `preview`, `clearPreview`
    and `commit`, sharing the existing settings stream, preview provider and
    targeted DAO writes. It has no preset library or selection state.
    Look names reuse playback's `validatePresetName` in `common/preset_names.dart`
    (trim, nonempty, reserved Default, case-insensitive uniqueness excluding
    the target). Look libraries decode leniently, discarding corrupt records
    and duplicate ids or names. Save returns `PresetResult<AppearanceLook>`;
    update, rename, delete and restore return nullable `PresetFailure`.
  - Cache & Storage's Reset section offers **Delete all presets**. Its destructive
    confirmation clears Looks, Speed & Pitch libraries and selections in one
    `AppSettingsDao.deleteAllPresets` transaction, including retired
    `color_tuning_presets` / `selected_color_tuning_preset_id` columns when
    present in early development databases. Current sound and appearance values
    are preserved; schema 102 is unchanged. The Looks write lane wraps the
    playback persistence lane so pending saves finish before the reset and later
    saves cannot replay an old library. Playback also observes external preset
    writes and preserves explicitly cleared selections at normal speed across
    later appearance saves. Unsupported saved playback presets retain a Delete
    menu action; Normal is built in and cannot be deleted. Delete failures use app notices.
  - Looks (`AppearanceLook`, version 1, `AppearanceSnapshot`,
    `AppearanceLooksController`) capture all appearance choices: theme mode,
    OLED-for-Auto, saved colour style, nullable accent seed, dynamic album
    colour, Night Schedule enable/start/end, both album-title shade flags,
    intensity, both brightness values, both tint values and Controls directly,
    Flat switch and area mask, corners, library/carousel/Now Playing/artist artwork shapes,
    artwork size and legacy grid-column override, density, artist view mode,
    and Now Playing background. Excluded: Home section order/visibility,
    page visibility/order and Desktop Navbar (they organize content and
    navigation), and language, saved accent swatches and Home recommendation
    auto-advance (a Look changes how Navis looks, never its language, your
    saved colours or behaviour).
    `capture` records nullable-setting clear flags so a saved automatic seed or
    grid size can be restored. JSON decoding is per field: missing,
    unknown or invalid values preserve current settings; explicit null clears
    those two nullable settings. Unsupported Look versions are discarded.
    `applyAppearanceSnapshot` writes supplied appearance columns in one DAO
    transaction. Decoding silently ignores the retired `tuningPresetId` key;
    captured tuning values always apply. The controller offers `apply`,
    `restore`, `saveAsNew`, `update`, `rename` and `delete`; its selected id is
    the first Look exactly matching a fresh capture by value.
    `apply(id)` returns the complete appearance captured **before** applying
    the Look, or null for an unknown id or failure. The UI can keep that
    snapshot for Undo and pass it to `restore(previous)`. Apply and restore
    update appearance and the derived selected marker in one DAO transaction.
    Restoration includes theme mode, automatic (null) accent seed, null legacy
    grid-column override, and every tuning value and Controls. Undo restores
    Custom when no Look matches, or re-selects a previously matching Look by value.
    Reset restores appearance defaults and retains the Look library.
    Controllers serialize writes and acknowledge the committed row through
    the existing settings watch before publishing results; there is no second
    persistence store.
  - Artwork adaptation scales each style's maximum chroma with vividness and
    shifts its Light/Dark tone window by depth; Neutral only scales chroma.
    Artwork scrims keep their existing recipe and Now Playing retains its OLED
    tint-tone cap. Caption worker messages carry vividness and depth, and the
    existing caption memo and album-card dedupe keys include both values.
    No separate cover cache is introduced. `SetupHighlight.colorTuning`
    uses the stable `colorTuning` key for the 1.5.0 setup registry.
    `/v1/presentation/appearance` accepts/returns `colorVividness` and
    `surfaceDepthLight` / `surfaceDepthDark` (integers −5…+5),
    `surfaceTintLight` / `surfaceTintDark` (integers 0…5) and
    `controlColor` (`accent` / `white`), with the whole request
    validated before DAO writes. Omitting an axis preserves its saved value.
    GET also returns the derived selected Look id and Look library count.
    Clone-only `GET /v1/presentation/looks` lists ids and names;
    `POST /v1/presentation/looks/apply` applies `{"id":"..."}` through the
    production controller, returning 404 for an unknown id.
  - Flat (`flatSurfacesProvider`, `NavisColorStyleData.flat`) is orthogonal to
    theme mode and colour style: it removes depth effects so the style's solid
    colours read stronger. `app.dart` passes it to `buildLightTheme`,
    `buildDarkTheme` and `buildOledTheme`, which record it in the extension and
    make `ColorScheme.shadow`, `ThemeData.shadowColor` and the OLED dialog
    shadow transparent when the surfaces area is selected. The following Flat
    behaviour applies within each selected area: the Home You Might Like
    section (phone, tablet and desktop, which includes the Trending hero) draws
    no wash, band, gradient or tint at all and sits directly on the page
    background, with its captions in the normal on-surface colours (the cover
    card's flat-mode shadow rule is unchanged); art-tinted Now Playing is one
    solid colour (adapted tint at `nowPlayingTintAlpha` over `surface`, see
    `nowPlayingSurfaceDecoration`) and plain `surface` when the art tint is
    off; decorative gradients become their solid end colour; hand-drawn drop
    shadows and the seek-preview blur are dropped for opaque container fills.
    Exceptions that stay: OLED + Flat Now Playing is plain
    `surface` (black), never the solid tint (`NavisColorStyleData.oled`, set by `buildOledTheme`); the legibility
    gradients behind white text over artwork stay under Flat (see
    `NavisColorStyleData.artworkScrim` below).
    Kept deliberately: the shimmer animation, the scroll-edge fade mask
    (`quick_panel.dart`; it signals scrollable overflow) and focus/selection
    styling.
  - Neutral reproduces the original schemes (`tonalSpot` light, `fidelity`
    dark, black OLED overrides) except that dark and OLED primary, secondary
    and tertiary containers in a warm hue (`isWarmHue`, reds through olive)
    in the muddy band are replaced by the same hue at chroma 20; cool hues
    and `errorContainer` retain their Material colours except for the
    primary/secondary tonal distinctness post-pass. The other styles use
    hand-built role tables over HCT instead of Material's fixed tone table.
  - Rules every styled scheme keeps, enforced by
    `test/src/theme/navis_style_schemes_test.dart`: containers and surfaces
    never sit at tone 25–50 with chroma above 24 (the brick-red and olive
    "mud" the `fidelity` scheme produces from saturated covers); dark tones
    rotate yellow hues away from khaki; OLED backgrounds stay `#000000`;
    text and control pairs meet contrast minimums.
  - A seed with almost no chroma (the default white) gets the sea-glass hue
    (190°) in Pastel and Immersive; Night moves accents into the rose-to-amber
    range.
  - The three styles are separated by rule, not taste, and
    `navis_style_schemes_test.dart` enforces it for every seed, mode and style:
    across the key roles (primary, secondary, tertiary, the three containers,
    `surface`, `surfaceContainer`, `surfaceContainerHighest`) Pastel's maximum
    HCT chroma is at most 60% of Immersive's and under 85% of Night's, and its
    artwork-adapted colours (Home wash, captions, Now Playing
    solid) are under 60% of Immersive's.
    - **Pastel** is macaron soft: the seed supplies the hue only. Accent
      chroma is 16 (muted seed) to 24 (vivid seed), 20 for the default white,
      so a neon cover never passes through. Dark and OLED accents sit at tone
      86, light ink at tone 47 (white text keeps 4.5:1, chroma at most 24),
      containers at chroma 12 (dark, tone 30) and 20 (light, tone 82–84),
      surfaces at chroma 6-7: a plum dusk (warm accents sit on
      `pastelDuskHue`) or a faint tinted paper at tone 95 (warm hues shift up
      to 25° toward peach, `pastelPaperHue`). Error is a soft rose
      (chroma 26 dark, 30 light ink) and `success` is a pastel mint
      (chroma 22-24).
    - **Immersive** keeps rich accents (chroma at least 36, dark accents at
      tone 77 so they stay saturated within the sRGB gamut) and deep tinted
      surfaces (dark chroma up to 20).
    - **Night** stays warm and low-blue: hue 15-95, accent chroma 24-40,
      umber surfaces and warm-white text.
    Before this revision Pastel's accents passed the seed's chroma through
    (light ink 42-48, dark accents 26-44 at tone 82) and Immersive's were
    gamut-limited to the same values at tone 82, so a red or blue seed gave
    identical dark accents in both styles.
  - `NavisColorStyleData` (a ThemeExtension) adapts colours sampled from
    artwork for the Home cover wash and the Now Playing tint, sets their veil
    and tint opacity, and supplies the `success` colour. Artwork itself and
    text drawn over artwork are never restyled.
    - `adaptArtColor` follows each style's no-mud logic on dark and OLED
      schemes. Pastel clamps every cover to chroma 13 at tone 88-94 in light
      themes and chroma 12 at tone 26-34 in dark and OLED ones (high-key
      chalk, dusky soft), and rotates warm hues toward its plum dusk
      (`pastelDuskHue`, 60% blend, up to 85% for yellows) so an orange cover
      reads rose or plum, not terracotta. Because Use Cover Color
      captions and the Now Playing tint (and its Flat solid) all derive from
      this colour, they inherit the cap. Immersive keeps the hue but caps warm
      chroma at 22 below tone 35 (wine or mahogany, not brown; yellows still go
      through `mudGuardHue`). Night's umber is intended and unchanged. Neutral
      returns the raw colour.
    - `artworkScrim` is the colour of the black gradients behind white text
      over artwork (artist hero, Home showcase, hero, playlist and album
      cards, the album title shadow): Neutral `#000000`; Pastel a deep plum
      (dusk hue, tone 7, chroma 10); Immersive the accent hue (tone 6, chroma
      12); Night umber (tone 6, chroma 10). Alphas and stops are unchanged and
      text stays white. `ArtworkScrim` (`artwork_scrim.dart`) draws it. The
      former Flat caption-band experiment and its provider were removed.
    - Light styled schemes put `surfaceContainerLow` (bottom sheets, cards),
      `surfaceContainer` (popup menus) and `surfaceContainerHigh` (dialogs)
      3, 5 and 7 tone steps below the tinted paper at Tint 0. Tint progressively
      reverses this ladder to lighter, softer panels.
  - Appearance and onboarding pick a style with `ColorStyleSelector`, whose
    tiles are painted from each style's real scheme (their inner radii follow
    Corner Style); the accent grid fills each swatch with the accent the selected style
    will use (a pastel box under Pastel) and shows the raw seed as a small inner
    dot, so Night's near-identical accents stay distinguishable. Every main
    Play uses the shared solid action API in `NavisColorStyleData`
    (`playButtonFill`/`playStyleOf`). Flat
    also drops the album-card caption fade for a solid `CaptionTint.fill` block, the selected-swatch glow and the
    anchored popover's black shadow.
  - Fine-Tune Colors is one row in Appearance (`ColorTuningOption` in
    `appearance_options.dart`: title, New tag, a summary subtitle and a
    trailing chevron, like the switch rows beside it) that opens a panel
    (`color_tuning_panel.dart`, `showColorTuningPanel`) through the Speed and
    Pitch shell, `showQuickPanel`: an anchored popover (440 wide, up to 680
    high) on desktop, a sheet capped at 88% on touch layouts, with the title,
    a live summary and Reset pinned. The row's summary is "Default" or the
    steps that are not zero ("Intensity +2 · Brightness +1 · Tint 3 · White
    controls", Brightness and Tint being the mode on screen; with only the
    other mode adjusted, "Light Brightness −3" or "Dark Tint 2"); the panel
    header shows the same summary. Brightness is the opposite of the stored
    depth: the ruler, readout and summary show `−depth`, so + is Lighter and
    − is Deeper while the settings, Looks and diagnostics keep the stored
    depth (+ deeper).
    The panel body is **Intensity** (Muted to Vivid), a **Backgrounds** group
    and a **Controls** group. Backgrounds holds a compact **Light | Dark**
    `SegmentedButton` beside its title and two rulers it drives,
    **Brightness** (Deeper on the left to Lighter on the right, −5…+5) and **Tint** (None to Full,
    0…5, readout "None" at 0, and the − stepper stops there). Controls is an
    **Accent | White** `SegmentedButton` that commits at once, with a note
    saying what White does. Each ruler is a `ColorTuningRulerRow`: the Speed and Pitch `AdjustmentRuler`
    in whole-step mode (`snapStep: 1`, value = the step −5…+5, 64 px a step,
    small ticks every 8 px between steps, the haptics described under the
    ruler below), laid out like the Speed and Pitch row (− stepper, ruler, +
    stepper via the shared `RulerStepButton`, a readout of "Default", "+2",
    "−3", end captions that stay left-to-right in RTL). The
    **Light | Dark** switch picks which mode's Brightness and Tint the rulers
    edit (Dark covers OLED, which shares Dark's values); it starts on the mode
    on screen and changes no value by itself. When it is on the other mode, a
    one-line caption says where the change shows ("Applies in Light mode",
    "Applies in Dark and OLED"). Intensity and Controls are shared by every
    mode.
    Each ruler carries a `RulerBand`: one colour per step (eleven, six for
    Tint), built with
    `buildStyledColorScheme` from a `ColorTuningBasis` (previewed seed, style,
    the mode on screen and whether it is OLED, and whether Dark would be OLED)
    and the other axis, never from the ambient theme, so they hold still while
    the app recolours around them. The ruler paints them as one linear gradient
    with a stop on each step's tick (clipped to the rounded strip, faded at the
    edges, hairline frame; each tick takes the ink of the nearest step).
    Intensity paints `primary` in the mode on screen (its needle is the live
    primary, with `onPrimary` ticks). Brightness paints the selected mode's
    `surface` at depth −step (the lightest swatch is the rightmost), so Light shows paper and Dark its own surfaces, or
    `surfaceContainerHigh` for OLED, where surface stays black. Tint paints the
    same roles at tints 0…5 (the real page background of the selected mode,
    with the current Intensity and Brightness), and under OLED adds the note
    "OLED keeps pure black, so Tint only colors the panels." The Intensity and
    Brightness strips and their keys include the Tint and Controls.
    The host owns the values: `showColorTuningPanel` takes a
    `ValueListenable<ColorTuningBasis>` and a `ValueListenable<ColorTuning>`
    that it keeps, plus `onPreview` (each whole
    step while a ruler moves), `onCommit` (drag release, stepper, keyboard,
    Reset) and `onPreviewEnd` (the panel went away mid-drag). The body keeps
    what it shows, follows the notifier when something else changes the value
    (applying a Look, a failed save restoring the old value) and glides the
    rulers there, and never yanks a ruler mid-gesture for the echo of an
    earlier preview. Reset commits `ColorTuning.none` and is disabled at
    Default. Settings keeps the tuning notifier in step with
    `colorTuningControllerProvider`, maps `onPreview` to
    `ColorTuningController.preview` and `onCommit` to `commit` (a persistence
    failure shows an error notice and the controller restores the saved value),
    and passes `onPreviewEnd: clearPreview`; setup keeps a notifier of its own
    over its draft and writes `colorVividness`, both depths, both tints and
    `controlColor` on every call.
    Settings also feeds the basis from providers (`effectiveColorSchemeSeedProvider`,
    which includes the Dynamic Album Color, `effectiveColorStyleProvider`,
    theme mode and Use OLED When Dark), so the strips, the needle and the
    hint follow the track while the panel is open; setup passes a fixed basis
    built from its draft.
  - The panel adds two one-line `bodySmall` notes. Beside Reset, only where the
    host has Looks (`looksHint`, Settings) and the values are not Default:
    "Save this as part of a Look in Appearance." Under the Intensity captions,
    when the −5 and +5 primaries of the current basis (same depth and mode)
    differ by less than 11 HCT chroma: "Pick an accent color to see
    Intensity." when the seed's own chroma is under `achromaticSeedChroma`
    (8), else "This style is already close to its most colorful here." The
    threshold comes from measuring the spread over hues, seed chromas, styles
    and Light/Dark/OLED: only a colourless seed in Neutral Dark/OLED and
    Pastel Dark in warm hues (about 10) fall below it.
  - Fine-Tune Colors has no preset picker. Its intensity, Light/Dark
    brightness and tint values and Controls are saved as part of Looks. Setup continues to edit its
    draft until Finish.
  - `AdjustmentRuler` (Speed and Pitch and Fine-Tune) draws its focus outline
    only while `FocusManager.highlightMode` is traditional (keyboard), so a
    tap or drag leaves no outline.
  - Looks have one control, `AppearanceLooksOption` (same file), at the top of
    Settings › Appearance above Theme and tagged by
    `SetupHighlight.appearanceLooks`: a heading, a subtitle and a
    `PresetPicker` over the saved Looks, with "Custom" while the appearance
    matches none and a ⋮ menu offering Save Current as New Look, Update,
    Rename and Delete through `AppearanceLooksController`; choosing a Look
    applies it and raises an "Applied {name}" notice with Undo (six seconds,
    `showAppNotice`) that calls `restore` with the snapshot `apply` returned;
    a failed restore shows the existing failure notice. The clone-only apply
    endpoint offers no Undo. With no Looks the picker reads Custom and the
    subtitle points at the menu. Setup does not show Looks (they write settings directly).
  - Decision record:
    [decisions/2026-10-07-colour-styles.md](decisions/2026-10-07-colour-styles.md).
  - Settings › Appearance (`appearance_settings_screen.dart`) has four
    sections under one `AppearanceHeading` (`appearance_layout.dart`), below
    the Looks picker:
    Theme (Theme Mode, Use OLED When Dark in Auto only), Color (Color Style,
    the Fine-Tune Colors row, Night Schedule, Accent Color, then Dynamic Album Color
    directly under the accent grid, whose note names the switch, then Album Art
    Shade with its Use Cover Color sub-switch), Shape & Layout (Flat Surfaces
    with its three area switches revealed while Flat is on, Corner Style,
    Artwork Shape with its three selectors, Artwork Size, Density, Artist View
    Mode) and Now Playing (Now Playing Background). Home Sections, Page
    Visibility and Desktop Navigation stay collapsed below. Night Schedule
    shows its explanation while off and the time pills while on; with Night as
    the chosen style the switch is locked off and says so. `app.dart` re-checks
    the scheduled style when the app resumes.
  - Settings and setup share the option widgets and one `AppearanceOptionSet`
    (`appearance_options.dart`), whose `AppearanceOptionKind` order (OLED,
    Fine-Tune Colors, Night Schedule, Flat Surfaces, Corner Style, Density,
    Now Playing Background) is the relative order in both places; Fine-Tune
    Colors and Night Schedule sit under Color Style in Settings, Night
    Schedule beside Color Style in setup and Fine-Tune Colors under "More
    appearance options". `AppearanceLayout`, an
    inherited widget, gives every shared control its left gutter (16 in
    Settings, 0 in setup) so headings and controls share one edge.
- `navis_tokens.dart`:
  - `NavisSpace` and `NavisRadius` are compile-time spacing and radius
    scales.
  - Corner Style: `NavisCornerStyle` (`rounded` default, `soft`, `square`) is
    persisted in `app_settings.corner_style` (schema 97). The guarded 92→97
    migration defaults existing rows to `rounded`. `SettingsRepository`
    saves it through `updateCornerStyle` or `saveSettings`; `cornerStyleProvider`
    derives it from `appSettingsProvider`, falling back to `rounded` while
    loading or on error. It is watched in `app.dart` and passed as `corners:`
    to the three theme builders. `NavisShapeData` (a ThemeExtension,
    `NavisShapeData.of(context)`) carries the xs..xl radii and the control
    (button/chip/indicator) corner; component themes and
    `NavisTokens.panelRadius` (the style's `xl`) are built from it, and
    every style sets explicit component shapes so a Corner Style switch
    interpolates real shapes (a null shape would lerp through a square one and
    snap). `rounded` (labelled "Pill" in the UI; the stored key stays
    `rounded`) encodes the shapes Material renders today: stadium buttons,
    segmented buttons, icon buttons and navigation indicators, a 16 px FAB, a
    28 px dialog and 28 px top sheet corners, and the 4 px `menuTheme`; only
    `snackBarTheme` stays unset. `NavisShapeData.lerp` interpolates the radii
    and the `scaled()` mapping (`softWeight`/`squareWeight`). Soft is distinct
    from Pill: 14 px rounded-rectangle controls (not pills), `xl` 32 for
    dialogs and sheets and 1.5x steps elsewhere; Square uses 4 px controls.
    Soft and Square also theme `menuTheme` (md) and `snackBarTheme` (sm); play, shuffle, transport and mini-player buttons pass
    `NavisShapeData.circularIconButtonStyle` (or `CircleBorder`) to stay round. Artwork keeps following Artwork Shape. Users choose it in Settings > Appearance
    (Shape & Layout, after Flat Surfaces, via `CornerStyleOption`) and on the
    setup Appearance step under "More appearance options". The setup preview
    theme uses the draft's color style, Flat Surfaces and Corner Style.
    Screens read radii through `NavisShapeData.of(context)` (named steps,
    `controlAll` for badges/tags, `scaled(n)` for one-off literals that must
    stay identical in `rounded`); circles, dots, drag handles, skeletons and
    painter internals keep fixed radii.
  - `NavisTokens` is a ThemeExtension for theme-dependent values: sidebar width,
    panel elevation, hover opacity, and colour roles `ColorScheme` lacks: the quiet
    warning container and the `success` foreground for completed or
    confirmed states. Read it with `NavisTokens.of(context)`.
  - Artwork radii follow the user's Appearance shape settings, not these
    scales. `artwork_shape.dart` maps a setting (`square`, `rounded`,
    `circle`) and the artwork's rendered size to corners with
    `artworkBorderRadius`: rounded is 4 below 40 px, 8 below 96 px and 12
    otherwise, so row thumbnails and cards share one look. `ArtworkShapeRole`
    names the setting a surface follows (Artwork Shape for album, song and
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
  scheme when dynamic album colour is enabled. Both it and Now Playing prewarm
  use `artworkColorScheme`: decode, Material's 112px scaling and RGBA readback
  stay on the UI isolate; `Isolate.run` quantizes the raw pixel ints to 128
  colours and scores the seed, then the UI isolate builds the scheme with
  the requested brightness and variant. Decoded dimensions are checked before
  scaling can truncate an edge to zero. Extremely thin artwork keeps the default
  tint/theme seed; loading retains its five-second timeout and extraction errors
  stay best-effort. Caption tints use the separate `CoverColourWorker` path.
- Custom accent labels use `settings/domain/color_namer.dart`: nearest CIE76
  colour in CIELAB (sRGB D65), ignoring alpha, with lazily cached table Lab
  values. The MIT meodai/color-names table is generated from the pinned
  filtered CSV; see `tool/data/color_names/README.md` for regeneration.
- Fonts: the bundled Inter variable font (`assets/fonts/`, SIL OFL 1.1,
  licence registered in `app_licenses.dart`). Scripts Inter lacks use the
  platform's per-glyph fallback.
- Bundled licence registration: `main.dart` calls `registerBundledLicenses`
  from `app_licenses.dart`. Inter, AutoEq and color-names appear on every
  platform; mimalloc appears on Linux and Rust crate notices on Windows. The
  Rust notice generator matches upstream licence files without case sensitivity
  and supplies tracked SPDX full-text templates for missing files, preserving
  Cargo authors for MIT attribution. Every crate references full licence text.
  Windows and Linux register the bundled libmpv/FFmpeg source offer and full
  LGPL-2.1 text. Both release bundles use LGPL builds. About supplies the
  Porthorion copyright line.
- Guard: `test/src/theme/design_token_guard_test.dart` ratchets literal radii,
  font sizes and colours per file outside `lib/src/theme/`.
- Decision record:
  [decisions/2026-09-30-design-foundation.md](decisions/2026-09-30-design-foundation.md).

Shared utility ownership: `utils/semver.dart` parses and compares release cores
for changelog/setup discovery and update selection, accepting leading `v`,
build and label suffixes. `captionContrast` owns WCAG contrast maths for
captions, veils and theme brand roles (the latter compare raw RGB as before).
`NightSchedule` owns Dart schedule defaults; Drift table defaults retain their
SQL literals. `NavisShapeData.xl` owns panel radii, including desktop panels and
anchored popovers; `NavisTokens` no longer duplicates that shape value.

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
- **Height is script-independent:** the panel is always three
  `_ShowcaseLine`s (artist line reserved even when empty), each a one-line
  `Text` in a `SizedBox` of its style's line height with a forced strut
  (`StrutStyle.fromTextStyle(..., forceStrutHeight: true)`), so Japanese or
  Arabic fallback-font metrics cannot make the section taller than Latin.
  The desktop pager's height is fixed by `_heroHeightFor`. Under Flat the
  section has no background at all on any layout (see "Flat" above).

**Desktop:** the art, track list and cover strip are unchanged. The panel
header adds the same reason line and a compact Play/Shuffle pair.

**Colour wash (`_ShowcaseColourWash`, both layouts):**
- `coverColourFieldProvider` returns a cover's 3×3 colour grid from the
  app-wide `CoverColourSampler` (see "Cover colour sampling" below). It only
  reads a cover that is already on the device and retries a missing one a few
  times (1, 2, 4 s) while the wash is watching it.
- `CoverColourFieldPainter` draws the grid as a vertex-coloured mesh
  (`Canvas.drawVertices`). The GPU shades it smoothly at any width, where a
  stretched thumbnail pixelates on wide displays. The mesh overscans its box
  and is clipped to it.
- A veil of the page colour covers it (lighter in light themes and on
  desktop), so it needs no offscreen layer while idle.
- Changing covers interpolates the nine colours over 400 ms; reduced motion
  switches instantly.

**Album card captions.** The shade plumbing exposes three tiers through
`albumTitleShadeModeProvider` (`settings/domain/album_title_shade.dart`):
classic (Shade off, the default) is `_DarkShadeLabel` (key
`albumCardDarkShade`): white text over a see-through `ArtworkScrim` (the style's
`artworkScrim`, as on the artist hero) that keeps the whole cover visible; dark
(Album Art Shade on, Use Cover Color off) is `_OverlayFadeLabel` with
`stagedFade` in the page colour, darkened by 35% black in dark themes, the same
shape as the colour shade (a short fade, then solid under the text); color
(both on) is that shade tinted from the cover through `_CoverTintLabel`, with
fill and text adjusted for 4.5:1 contrast. Classic and dark require no cover
sampling. Settings › Appearance and setup show
Album Art Shade (New tag) with an indented Use Cover Color switch revealed by
`AppearanceSubOptionReveal` while Shade is on; both are disabled with a note
under Flat text over artwork. An album title is never more than one line:
`MarqueeText` (`marquee_text.dart`) is a plain `Text` when it fits, otherwise it
rests ~1.75 s, scrolls to the end at 35 px/s, rests ~0.8 s and snaps back, with
one `AnimationController` inside a `RepaintBoundary`. It runs only while
visible (`TickerMode` plus `VisibilityDetector`), becomes a still ellipsised line
under reduced motion (`MotionPolicy`), and exposes the full title as its
semantics label. Subtitles stay single-line ellipsis. A scrolling title never
settles `pumpAndSettle`, and `test/flutter_test_config.dart` zeroes the
`VisibilityDetector` debounce so tests leave no pending timer. The Home
Recently added / Frequent carousel card is `AlbumCardContent`, the raw-field
body that `AlbumCard` wraps, so it shares `AlbumCardLabel` and
`AlbumCardCaptionLayout` and follows the same tiers (its former hard-coded dark scrim is now the opt-in dark tier; the
default is the page fade like every other Home album carousel), and its shelf
adds `albumCardExtraHeight` under Flat. `CoverReadyScope` is the shared cover
readiness tracker for both cards. With Flat text over artwork
(`NavisColorStyleData.flatArtworkText`)
the caption moves below an unobstructed cover (`AlbumCardCaptionLayout`, key
`albumCardCaptionBelow`) and nothing is sampled. In that layout every host
reserves `albumCardExtraHeight` (one title line and one subtitle line, measured
at the ambient text scale) under its square cover: `ResponsiveContentSliverGrid` (`mainAxisExtent`), the Home New
releases and local album shelves, the artist page's missing-albums shelf, the
Library liked-albums shelf and the By Year pairs (which size themselves). The
phone album and weekly playlist headers likewise show the art with no fade or
overlaid title under Flat text over artwork and put the title at the top of the
content under it.

**Cover colour sampling (`cover_colour_sampler.dart`).** Shared by this wash
and the cover-tinted album-card caption (Album Art Shade with Use Cover Color). Until the
tint is known, and for cards without a cover-art id (including external album
cards), the caption falls back to the page-background fade and scheme text
colours. Cards remain square in grids and rails unless the caption sits below
the art. Each caption has its own
`RepaintBoundary`; a lone tint on an idle list fades in, while bursts and
arrivals during scrolling apply instantly. Sampling is built so that scrolling
never pays for it:
- *Sampling gate.* `AlbumCard` passes `CoverArtImage.onImageReady` to its
  `AlbumCardLabel` as `coverReady`, so a card samples only after the same
  visibility and load-window logic that loads its artwork has shown the
  cover. `CoverArtImageReadyNotification` also carries whether the bounded
  image resolved synchronously, through regular and hero covers. A synchronous
  memory hit requests its tint on the next event turn without the settle delay,
  while the list is idle. Other arrivals wait `kCoverTintSettleDelay` (150 ms)
  built and idle before requesting. The existing `isScrollingNotifier` cancels
  that one-shot wait when scrolling starts and schedules it when scrolling
  stops; there is no per-card polling timer. Flutter's deferred-loading recommendation remains
  a final check before sampling. Cards that fly past never request. Known
  colours are read synchronously from `peekCoverColourField` on the first frame.
- *Local files only.* `decodeLocalCoverColour` reads the permanent artwork
  store file or the rolling-cache file (`getFileFromCache`) and decodes it
  natively at 24 px (`ImmutableBuffer.fromFilePath`, `ImageDescriptor`,
  `targetWidth/Height`). The decode bypasses `PaintingBinding.imageCache`, so
  tiny tint images never evict real artwork. Remote cache lookup tries the
  sizes the showcase actually loads: 600 px for album cards/heroes, 480/420
  px for playlist mosaics, then 96 px for the mini-cover strip. It never
  fetches; a cover not on the device yields null. A nonzero revision samples
  only that revision's remote cache key, so an older permanent copy cannot
  be recorded as the refreshed artwork.
- *Off the UI isolate.* `CoverColourWorker` (`cover_colour_worker.dart`) is a
  long-lived worker isolate, started on first use
  (`coverColourWorkerProvider`; tests inject `InlineCoverColourWorker`). The
  UI isolate only hands it the 2 KB RGBA buffer and receives plain ints. It
  does the pixel averaging, the `captionTintFor` maths (HCT conversions and
  tone search) and all persistence: read, merge, trim to 5000, encode and
  atomic write of the colour file, debounced 2 s. A card derives its tint
  through `resolveCaptionTint` (memoised in `caption_tint_resolver.dart`),
  during dependency/widget changes and field subscription callbacks. Build
  only renders the applied tint. Each applied tint resets its instant/fade
  decision; queued results stay behind the frame dispatcher. Memo and card
  dedupe keys contain only sampled ARGB, colour style and darkness; these are the only arguments
  sent to the worker. Track-driven accent hue changes reuse the tint.
- *Burst control.* Results reach cards through `FrameBudgetDispatcher`
  (`frame_budget_dispatcher.dart`): at most three tint repaints start per
  frame, the rest follow on later frames. A throwing callback rearms remaining
  work in `finally`, while Flutter still reports the exception. A card also
  never starts sampling
  while its list is scrolling at all (`isScrollingNotifier`) or Flutter
  recommends deferred loading.
- *Bounded scheduling.* Each request tracks interest on a dedicated
  `CoverArtLoadCoordinator` (`coverColourLoadCoordinatorProvider`, two active
  slots, no critical reserve) under the key `tint:<cover cache key>`, then
  acquires a slot. A decode still queued when its last card is gone is
  cancelled by the coordinator's stale-interest logic. A separate instance is
  used because the artwork coordinator's slots also gate real artwork
  downloads, which tint decodes must never delay. Caption requests are visible;
  You Might Like meshes and Now Playing artwork backdrops use
  `backgroundCoverColourFieldProvider` on the same sampler. At most one
  background decode occupies the two slots, leaving room for a caption.
  Requests for one cover and revision share one decode, promoted by caption
  interest when queued. Missing-art retry counts are scoped to request priority.
- *Persistent cache.* Fields resolve from the memory LRU (512), then from
  the worker's copy of `cover_colour_fields.bin` in the application support
  directory (newest 5000 entries), then by decoding. The newest 512 entries
  warm the memory LRU when the store opens. A file, not a Drift table: the
  data is a disposable cache that needs no queries, relations or migration.
  The file records a hash of the server URL and user name (never
  credentials); another account reads as empty. Opening another scope also
  clears the session-long worker map and pending dirty state before loading;
  only fresh same-scope entries merge. The sampler resets the memory LRU and
  its missing-art retry counts when the account changes. NCF2 stores the sampled
  artwork
  revision alongside each field; NCF1 files load with revision zero and are
  upgraded on the next save.
- *Lazy artwork refresh.* The provider takes `(coverId, revision)`, while
  memory and disk retain one field per cover id. Album cards and the Home
  album showcase pass the existing `coverArtRevision` from library metadata
  to both artwork and sampling. A revision bump refreshes only when a visible
  caller requests that cover, through the same settle/scroll gate, two-slot
  coordinator, worker and frame-budgeted caption dispatcher. Unshown covers
  do no work. The old field and derived caption tint remain visible until
  their replacements are ready; an older in-flight decode cannot overwrite
  a newer cached revision. Unchanged revisions reuse the field without file
  stats or image decoding. URL-only external album cards have no Subsonic
  cover id/revision and retain the existing caption fallback.

Paging, auto-advance and the test/diagnostics keys
`home-random-hero-carousel(-page-N)` are unchanged. The hero's items and
Trending Now are described in "Deezer on Home".

### Changelog and What's New (`lib/src/features/changelog/`)

**Data.** `changelog_data.dart` is a `const` list of `ChangelogVersion`s,
newest first. It has no imports, so it is the single source for the app and
for `tool/generate_release_notes.dart`, which renders the release notes (the manifest `notes` field, and the Forgejo release body with `--forgejo`)
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

**Home card (`ChangelogDiscoveryCard`, drawn in `HomeNoticeCard`).** It is
inline and non-blocking (design-ux-audit D5). `changelogToShowProvider` calls
`resolveChangelogDiscovery`: it returns nothing once the running version is
recorded in `changelog_seen_version.txt` (Application Support), otherwise the
running release plus the newest *major* in the unseen range (last seen,
current]. So a jump from 1.3.1 to 1.4.1 still features 1.4.
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
  - `confirm_dialog.dart` - `showConfirmDialog` (Cancel/confirm alert with
    optional destructive styling and confirm key) and `confirmRemoveDownload`

- **Player UI**
  - `expandable_player_sheet.dart` - Mini player ↔ now playing transition
  - `lyrics_display_widget.dart` - Synced/unsynced lyrics display

- **State Widgets**
  - `empty_state.dart` - Empty state with icon and message
  - `error_state.dart` - Error state with retry
  - `async_body.dart` - Loading, error-with-Retry and data body for an `AsyncValue`
  - `shimmer_placeholder.dart` - Loading skeleton
  - `loading_indicator.dart` - Progress indicator

Small in-memory caches with a fixed capacity use `BoundedLruMap`
(`lib/src/utils/bounded_lru_map.dart`, optional eviction callback for disposing
values) instead of hand-rolling `remove(keys.first)` eviction.

- **Actions**
  - `star_button.dart` - Star/unstar action
  - `context_menu.dart` - Bottom sheet context menu
  - `preset_picker.dart` - `PresetPicker` (dropdown plus save, update, rename
    and delete menu over any named presets) and `TextEntryDialog`

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

### Now Playing phone layout

Portrait phones (compact width, not wide-embedded) size the Now Playing body
with `NowPlayingPhoneLayout.compute` (`now_playing_phone_layout.dart`), a pure
function of the body width and height (inside the handle, status bar and
bottom inset), the text scaler, and whether the source is radio or external.
`_PhoneNowPlayingColumn` (`now_playing_phone_body.dart`) renders its result.
Standard, split, tablet, desktop and compact-wide layouts keep their own
geometry.

- **Class by body height.** Short < 620 dp, normal 620-829, tall >= 830. Short
  uses 20/15 sp title/artist with the album folded into one "Artist · Album"
  line (each part still tappable, each ellipsized). Normal is the long-standing
  20/15/13 sp. Tall steps up to 24/17/14 sp and, from 380 dp wide, a 62 dp Play
  button (`_TransportControls.large`) with 34 dp icon and 32 dp skip icons.
- **Priority order.** Controls get their real height first and are pinned to
  the bottom: title block, info pager (line and dots), seek bar, transport,
  action row, bottom gap. Block heights are modelled from the Material 3 line
  heights (`ceil`ed like the rendered text) and pinned to the rendered widgets
  by `now_playing_phone_layout_widget_test.dart`. The artwork is the flexible
  element: it shrinks on short screens and grows up to the width minus its
  margin (24 dp, easing to 16 dp between 780 and 860 dp of body height).
- **Gaps (min to max dp).** Handle to art 4-16, art to title 12-28, title to
  info 8-16, info to seek 8-20, seek to transport 8-24, transport to actions
  8-16, bottom 8-16. One shared factor `t` interpolates every gap.
- **Sizing order.** (1) Artwork up to its maximum with minimum gaps; (2) raise
  `t` until the gaps reach their maximum; (3) the remaining slack goes 60%
  above the artwork (lowering the composition toward the thumb) and 40% between
  artwork and title. Radio, which has no info line, seek bar or action row,
  shares the slack 40/30/30 above the artwork, between artwork and title, and
  between title and transport.
- **Small screens.** The artwork may shrink below its preferred 62% of the
  width (capped at 320 dp) down to 45% (120-200 dp). On short phones only, the
  info pager is dropped when the artwork would otherwise fall below the
  preferred size. If even the floor does not fit (very large text,
  `scalesUpper`) the artwork and title are scaled down together
  (`FittedBox`) to the room above the controls. Nothing in the phone body
  scrolls: a scroll view there took the swipe-down-to-dismiss drag (reported
  with Arabic titles) and there is no height at which the controls flatten
  into one scroll view. (The inline lyrics list scrolls inside its own cover
  square by design.)
- **Script-independent text.** The title, artist and album lines render with a
  forced strut at the modelled line height (`titleStrut`, `artistStrut`,
  `albumStrut`, built from the style so the Latin pixels are unchanged), so an
  Arabic or CJK fallback font cannot make the title block taller than the
  budget. Radio artist links share one bounded, ellipsized row on portrait
  phones, so every visible link remains tappable and the Live label stays
  inside the title block. The title block is also clipped to its modelled
  height. Anything the model leaves over collects above the cover, and a few
  dp of misjudged height are clipped,
  never an overflow.
- **Exact squares.** The cover, its placeholder, radio art and the inline
  lyrics slot render in a `SizedBox.square` of the computed size.

Why: Gramophone, Auxio, Namida, Retro, Metrolist and Symfonium all give the
controls their real size at the bottom and let the cover absorb height ("the
cover has last priority for space"), growing to the width minus a 16-24 dp
margin; only slack beyond that becomes space around the cover. Gaps follow a
4/8/12/16/20/24 rhythm with a minimum and maximum instead of fixed values, and
titles sit at 20-24 sp with the artist at 15-19 sp. The previous layout stopped
the cover at the width, centred the leftover height as two equal holes, and
switched to a top-aligned scroll below 700 dp that clipped the action row and,
with three-button navigation, the Play button.

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
whose lyrics may be in another language. Schema 92 deletes only legacy
LRCLIB cache rows (camelCase and snake_case sources) once during upgrade;
server lyrics and all newly fetched edition-aware lyrics survive reopen.
The schema version is the durable completion marker, so no settings column
or repeated TTL-based purge is needed. Downloaded audio files are unaffected.
Downloaded songs whose LRCLIB cache entries were purged are eligible for the
existing `DownloadService` lyrics backfill on startup; it runs only on Wi-Fi
and refetches through the lyrics resolver when LRCLIB lookups are enabled.
Those lyrics may therefore be unavailable offline until a Wi-Fi startup
backfills them (or an allowed on-demand lookup fetches them).

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
- `/library/artists/:id` and `/library/artists/:id/top-tracks` - Artist detail
  and its top-tracks playlist; `?name=` names an artist the library may not hold
  yet
- `/library/albums/:id` - Album detail; `?name=` and `&artist=` name an album
  the library may not hold yet
- `/library/playlists/:id` - Playlist detail
- `/library/listenbrainz/:sourcePatch` - ListenBrainz weekly playlist
- `/library/liked-albums`, `/library/liked-artists` - Full liked lists
- `/search` - Search
- `/settings` - Settings
- `/settings/server` (Server Information), `/settings/integrations`,
  `/settings/cache`, `/settings/downloads`, `/settings/sync`,
  `/settings/playback`, `/settings/equalizer`, `/settings/appearance`,
  `/settings/about`, `/settings/unavailable-items`
- `/settings/playback/match-flow` and `/settings/playback/match-flow/:flowId/search`
- `/settings/about/changelog`, `/settings/about/privacy`
- `/settings/desktop-window`, `/settings/shortcuts` - desktop only; other platforms are redirected to `/settings`

The retired `/settings/group-listening` path redirects to Server Information
(`/settings/server`) and `/settings/external-services` to Integrations
(`/settings/integrations`); neither is shown in navigation. A location that
matches no route shows a localized not-found page with a Home action.

`appRouterProvider` owns one stable `GoRouter` instance. Authentication and
first-sync phase changes refresh its redirects in place rather than rebuilding
the router: timestamp and catalog-state updates during ordinary sync may
briefly re-evaluate session readiness, but they must preserve the current
location.

`CacheSystemUpgradeService` derives the cache epoch from `PackageInfo.version`
as `major * 1000 + minor` (1.5.0 → 1005), ignoring patch and build numbers.
The cache-renewal gate waits for package metadata and the durable cache-system
marker alongside the authentication phase. A committed profile with any different
epoch (including newer or legacy 0–3 markers) is routed to
`/library-rebuild?reason=cache-upgrade` before onboarding or the normal shell.
A never-synced profile adopts the epoch and continues initial setup, using the
same usable-catalog evidence as initial-login routing. Validated initial
catalog readiness stamps the epoch in its readiness transaction. Package-info
errors or a five-second metadata timeout are logged and skip renewal without
changing the stored marker; unreadable stored markers keep it pending.
The rebuild clears only recoverable library and rolling-cache data, preserves
permanent downloads, performs a full catalog scan, and records the new marker
only after that scan promotes successfully. A failed or cancelled rebuild, or
an unreadable marker, keeps the renewal pending until it can be resolved.
Completion goes directly
to versioned onboarding when it is required; otherwise it opens Home. Ordinary
settings updates must not refresh the router.

Setup update highlights live in `features/onboarding/domain/setup_highlights.dart`
and `presentation/setup_highlights_provider.dart`. The registry selects the
newest eligible release using the shared changelog semver helpers and package
metadata, ignoring build and label suffixes. A newer highlight release replaces
the group. Highlights survive the next minor release, then expire: the 1.4.x
registry still applies in 1.5.x, but not in 1.6.0+ or a new major. The eight options
are Color Style, OLED for Auto, Night Schedule, Flat Surfaces, Flat areas
(tagged on the first area switch), Album Art Shade, Now Playing
Background and Corner Style; Density is an existing setting and has no New tag.

Schema 97 persists nullable `setup_highlights_seen` (JSON array of stable
`SetupHighlight.storageKey` values), `setup_highlights_seen_release` and
`setup_card_dismissed_release`. Branch-only migrations 93–97 are consolidated
into one guarded `from92To97`; every column guard allows partially upgraded
93–96 installs to finish safely. Versions 91–92 remain unchanged. The legacy
background backfill runs only when `now_playing_background` is newly added.

`pendingSetupHighlightsProvider` subtracts seen options from the current release
and is empty during loading, required onboarding, expiry, or after acknowledging
that release (or a later one). `SetupHighlightsService.markOptionSeen(option)`
atomically adds one key through the existing repository/DAO transaction; it is
idempotent and preserves concurrent option acknowledgements. Unknown or malformed
stored keys do not acknowledge other options. `setupHighlightsCardVisibleProvider`
is hidden when pending is empty or the invitation was dismissed for this release.
`dismissCard()` hides only the invitation. Finish in any mode calls `markSeen()`
to clear all tags for the release; Skip calls it only for non-review setup that
was required at hydration. Fresh installs suppress tags and acknowledge the
release on first completion. All acknowledgement writes are targeted and excluded
from full settings saves; defaults and resets clear them. The clone-only
`POST /v1/presentation/setup-highlights/reset` clears the set and both release
markers in a transaction; the integrations settings dump exposes all three.

The look step shows the appearance options through the same callback-driven
widgets as Settings › Appearance (`settings/presentation/appearance_options.dart`).
Theme Mode, Color Style, Night Schedule and Accent Color are always visible;
Album Art Shade (with Use Cover Color) sits after the accent hint. A "More
appearance options" group (`SettingsCollapsibleGroup`, children built only
while open) holds Use OLED When Dark (Auto only), the Fine-Tune Colors row
(its panel edits the draft and has no preset picker), Flat
Surfaces (with its Panels and Shadows, Now Playing and Text Over Artwork
switches while Flat is on), Corner Style, Density and Now Playing Background,
in Settings' relative order. It starts open when any of them carries a pending
tag (OLED only counts in Auto, the Flat areas only while Flat is on) and closed
otherwise. The step shows the "Scroll for more" hint like the other
steps. Choices write only to the draft that Finish
saves through `SettingsRepository.saveOnboardingChanges`: it compares against
the hydrated entry snapshot and uses existing targeted DAO writers, preserving
unchanged fields written elsewhere meanwhile (including desktop volume). Custom
presets and integration switches likewise write only when changed. The preview
theme mirrors `app.dart`: OLED for OLED mode or Auto with
OLED When Dark at dark platform brightness, and `flat:` from the draft. The
night schedule never switches the preview by time. Options whose
`SetupHighlight` is pending carry a `NewFeatureTag` (`common_widgets/`).
`HighlightedAppearanceOption` wraps each tagged option in Settings and setup:
once at least half of it has been on screen (a `VisibilityDetector`, once per
screen visit) it calls `markOptionSeen`, so only options the user actually saw
lose their tag on the next visit. Tags render from `AppearanceVisitScope`'s
per-visit snapshot of the pending highlights (taken when the Appearance screen
or setup step is entered, which also decides whether the setup expander opens),
so a tag stays visible while the user is on the screen. Hidden options (OLED outside Auto, a closed expander) never
mark. On Settings home `settingsHasNewOptionsProvider` tags the Appearance and
Run Quick Customization rows ("Has new options"); OLED does not count while it
is hidden. Home shows `SetupHighlightsCard` ("New appearance options")
while `setupHighlightsCardVisibleProvider` is true. Tapping it opens the
onboarding review without acknowledging anything; its close button only calls
`dismissCard`. Home shows one notice: the Integrations notice, else the setup
card, else the What's New row.

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

Onboarding has four steps (look, listening, queue and downloads, Integrations)
kept in one draft that Finish saves and Skip discards; the Integrations step is
described under "External integration policy". The screen keeps its size when
the keyboard opens (`resizeToAvoidBottomInset: false`) and pads itself by
`MediaQuery.viewInsetsOf`, so the step list ends at the keyboard. On compact
layouts the header and the actions step aside while the keyboard is up. The step
list and its rows are keyed, and the "scroll for more" hint sits above the list,
hidden while the keyboard is up and once the list is scrolled to (or within 24
dp of) its end, back when scrolled up: inserted into the list it used to shift
the rows, rebuild the focused token field and close the keyboard again. The
token and key fields have their own focus nodes, validate on the keyboard's Done
action, show and hide their value, show errors on the field and are locked while
validating.

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
  one. The screen's local type-to-filter query persists across section changes
  for keyboard input and clone-diagnostics commands alike. Diagnostics can
  explicitly clear the query with an empty or null `query`; repeated queries
  are new commands, so a query can be reapplied after the UI clears it.
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

The breakpoints are the constants `kAdaptiveMediumWidth` (600) and
`kAdaptiveExpandedWidth` (840) in `routing/desktop_layout.dart`; use them
instead of literal widths.

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

### Offline banner and the top inset

While the session's server is unreachable, every shell mode shows
`ShellOfflineBanner` (`lib/src/routing/shell_offline_banner.dart`) above the
tab pages. `ShellOfflineBannerFrame` owns the top inset while the banner is
visible:
- On Android, which runs edge to edge, the banner pads its content below the status bar. The banner itself is a transparent strip holding an inset, rounded `surfaceContainerHigh` tile (a 32 px quiet-warning disc, the message, a tonal Retry and a close button; Flat Surfaces draws it unfilled with an outline), and the 48 px `contentHeight` includes the tile's vertical inset.
- The frame strips the top padding from the `MediaQuery` it hands to the pages.

Pages keep using `SafeArea` and primary `AppBar`s as usual, and do not add the status bar height a second time. Only the content part of the banner animates. The status bar strip comes and goes together with the padding it replaces, so pages never jump by the status bar height. The `MediaQuery` wrapper is always present, so toggling the banner never rebuilds the pages.

The banner's Retry action calls `ServerReachabilityController.retryNow()`. That method:
- checks the server at once, or joins a check that is already running;
- leaves the status at `offline` until the check finishes, so the banner stays up while the check runs.

The banner's message is one line, and its close button tucks it away: `shellOfflineBannerDismissedProvider` (`ShellOfflineBannerDismissed`) holds a dismissed flag that collapses the banner through the same animation (notices follow it) and shows `ShellOfflineChip`, a small floating "Offline" chip in the shell's body `Stack` that takes no layout space on phone, rail or desktop. Tapping the chip clears the flag and expands the banner. The flag also turns on by itself when `showRetryBanner` becomes false after repeated failures (the former "Offline mode" strip is gone), and is reset whenever the status leaves `offline`, so the next outage shows the banner again.

`ShellOfflineBannerScope` wraps the shell's `Scaffold` body and owns the one animation that reveals and hides the banner. The shell places `AppNoticeHost` through `ShellOfflineBannerExtentBuilder`, which follows that same animation, so a notice stays 12 px below the banner on every frame. Interrupted toggles and reduced motion are included, and a notice never moves over a banner that is still collapsing. The extent assumes the banner's one-line `contentHeight`. With very large text the message wraps and the banner grows taller.

The frame decides whether the banner is present from the animation's value, not from a `dismissed` status. A zero-length (reduced motion) animation updates its value before its status. A controller created already showing the banner never reports a jump straight to `dismissed`.

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

The [responsive layout plan](history/completed-plans/Responsive_Layout_Overhaul_Plan.md)
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

## Database file location

Linux, Windows and macOS store `navis.sqlite.sqlite` in the application support
directory; Android and iOS use application documents. `database_location.dart`
resolves both through path_provider, preserving clone diagnostics overrides.
Before opening on desktop, a missing support database is migrated from documents
along with any `-wal`, `-shm` and `-journal` files. Cross-device copies are size
verified before originals are deleted. Failure restores transferred files and
falls back to documents; a rollback failure preserves the remaining copy and
fails opening rather than choosing an incomplete database. An existing support
database wins and leaves legacy files untouched. No schema changes are involved.

## External integration policy

External HTTP clients use a shared ASCII User-Agent containing the current
Navis version, `https://navis.porthorion.com` and `support@porthorion.com`,
including radio metadata, AutoEQ, cover-art fetching and update requests.

External browser links use `launchExternalHttpUrl`, which accepts only hosted
HTTP(S) addresses. MusicBrainz release-group links require a UUID identifier.

Navis talks to its own Subsonic server and, optionally, to external services:
Deezer, Last.fm, ListenBrainz, LRCLIB, the update feed, AutoEQ, radio station
streams and artwork the server links to. The user decides which, per service
and per feature. Everything is on by default, and a master "Online services"
switch means "Navis only talks to your server" when off. See
[the decision record](decisions/2026-10-04-external-integrations-policy.md).

ListenBrainz credentials are deleted on every server sign-out, with the
connection reset even if deletion fails. Teardown logs failures and continues.
Disconnect in Integrations instead retains the connection when deletion fails
and shows a retry notice.

The provider-held LRCLIB client shares a Retry-After cooldown across exact
lookups, search and downloads. HTTP 429/503 pauses requests until the supplied
seconds or HTTP-date (60 seconds without valid guidance). Lyrics use cached
or server alternatives without warning spam; backfill stops the current pass
after a rate limit. Subsonic shares the HTTP Retry-After parser.

Last.fm `track.getsimilar` responses are cached for 24 hours in
`IntegrationJsonCache` under `lastfm.similar-tracks`, keyed by normalized artist
and track (case and whitespace). The client is the shared layer for Same Vibes
and Instant Radio. Successful empty responses are cached; request errors are
not. Each entry records its request limit, so a larger request refreshes an
undersized entry and smaller reads return only the requested number of tracks.
Cache I/O uses the existing asynchronous read and atomic-write path.

ListenBrainz connection validation and listen submissions distinguish explicit token
rejection (`valid: false`, HTTP 401/403), integration policy blocking, rate
limiting (HTTP 429 and `X-RateLimit` budgets), and service unavailability
(documented-endpoint HTTP 404/410/5xx, non-JSON/HTML responses, malformed
validation responses and transport failures). Settings and onboarding share
localized reason-specific copy, including the HTTP status when available.
An unavailable response never clears credentials or changes token validity;
the existing scrobble retry queue retains listens for later dispatch within
its normal retention window. Requests keep the documented
[`/1/validate-token` and `/1/submit-listens` paths](https://listenbrainz.readthedocs.io/en/latest/users/api/core.html)
and explicitly follow up to five same-origin redirects, preserving authorization,
method and POST data on 307/308; cross-origin and HTTPS downgrade redirects
are refused without forwarding credentials. No response body or token enters
these exceptions or connect-flow logs.

ListenBrainz listen submissions observe `X-RateLimit-Remaining: 0` and
`X-RateLimit-Reset-In`, holding subsequent dispatches for the stated seconds
(up to five minutes). Malformed headers are ignored. Client and dispatcher
retain the deadline; deferred events stay queued without retry penalties,
and Subsonic delivery continues independently.

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
  lose the virtual playlists at once. The check is repeated after every wait
  (the stored token, the caches, the startup idle delay), and its requests carry
  a `CancelToken` cancelled when the provider rebuilds, so turning the switch
  off while the token is read sends no token validation. Artist Top Songs
  likewise re-reads `lastfm.topSongs` after its Last.fm cache read and passes
  its `CancelToken` to `artist.getTopTracks`; the guard interceptor checks only
  the service, so feature switches rely on these call-site rechecks.
- **Enforcement, in two layers.** *Call-site gates* make a section hide itself
  instead of failing: Same Vibes (`lastfm.sameVibes`), the radio fill
  (`lastfm.radio`), artist Top Songs (`deezer.topSongs` or `lastfm.topSongs`,
  via `artistTopSongsAllowedProvider`; with neither, the section and the "This
  Is" card are hidden), scrobbling and feedback (their credential readers return
  no token), lyrics (`useLrclibProvider` is `allows(lrclib.lyrics)`; the
  download service takes a `readLyricsAllowed` callback instead of reading the
  column), the update tile and provider, the AutoEQ dialog (search still uses
  the bundled catalogue; refresh and download are disabled) and the weekly
  playlists stream. Gates use `allows(feature)`, which includes the credential
  check, except weekly playlists (`isEnabled`, see above). *The guard
  interceptor* is defense in depth. `createExternalDio(service, ...)`
  (`features/integrations/data/external_dio.dart`) builds the `Dio` of every
  external client (Deezer, Last.fm, ListenBrainz, LRCLIB, the update repository
  and service, AutoEQ, and the radio `RadioMetadataService` inside
  `NavisAudioHandler`) from `externalDioFactoryProvider`.
  `IntegrationGuardInterceptor` rejects a request, before it leaves the device,
  when the master switch or that service's switch is off. It checks the service
  level only; whether a feature is on is the call site's decision. A call the
  user started (key or token validation, "Check now", the update download and
  AutoEQ refresh/download) sets `options.extra['navis.userInitiated']` (see
  `userInitiatedOptions`) and bypasses the service switch, never the master
  switch. `ListenBrainzApiClient.validateTokenDetails` sets it only when its
  caller passes `userInitiated: true` (Integrations and onboarding), so the
  weekly stream's automatic revalidation obeys the service switch. The policy is
  read per request, so clients that already exist obey later changes.
  `NavisAudioHandler` receives `readRadioPlaybackAllowed`, checked before any
  transport or queue changes: the master switch permits external streams, and
  the configured server host remains allowed when it is off. Host matching is
  case-insensitive. A missing callback preserves standalone handler compatibility.
  It also receives `readRadioMetadataAllowed`, which
  `RadioMetadataService` checks before every Azuracast poll and which stops the
  polling while it is false (ICY metadata, carried by the stream
  itself, is unaffected). Policy changes refresh the current station immediately:
  disabling replaces the API song and artwork with available ICY metadata, or
  clears the song metadata so the station name is displayed and the source is
  `none`. Missing ICY artist/artwork fields clear the previous API values.
  Re-enabling restarts polling
  unless the candidate API already failed its initial probe. Re-enabling an
  unconfirmed candidate starts a fresh two-failure probe budget. Restarting the
  station retries detection for a rejected candidate. The audio handler
  lives outside Riverpod, so it also takes a `createRadioMetadataDio` factory.
  Two failed initial polls (HTTP, timeout, malformed JSON or missing
  `now_playing.song`) abandon the candidate
  API for that station and immediately apply the latest ICY title. A station
  with a successful API response keeps polling through transient failures.
  Requests from an earlier station/listening generation cannot publish metadata.
  Switching stations stops metadata listeners before replacing the station or
  awaiting its source load; a current failed source load also stops them.
  Superseded radio failures cannot clear station state or report failure. Radio
  card callbacks use the queue selection epoch to discard stale errors; a
  successful retry dismisses its earlier radio error notice by notice identity.
  Policy-driven artwork refreshes retain the current song title and artist in
  the system media item. Rebinding the same station to a replacement player preserves the source
  of its displayed metadata until a fresh update arrives.
  Playback diagnostics report the active radio station, stream host only, last
  applied metadata source, displayed title/artist and artwork hosts plus opaque
  URL hashes for displayed and published media-item artwork for that station only.
  Artwork URLs, credentials, paths, queries and fragments are never emitted.
  The diagnostics station comes from current handler state rather than the last
  broadcast snapshot, and its
  published artwork is null while the new station loads;
  see the field contract in [development-workflow.md](development/development-workflow.md).
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
  `dynamic_accent_provider.dart`) apply the same check. Artist header URL
  selection and prewarm checks are pure. External image lifecycle and fetch
  boundaries report refusals to `ArtworkCallRecorder`; allowed requests are
  counted only by the HTTP transport.
- **Observability.** `IntegrationCallRecorder`
  (`integrationCallRecorderProvider`) is an in-memory ring buffer (200 calls,
  100 spans) fed by the guard interceptor, the shared `ArtworkCallRecorder`
  image boundary, and `recorder.span(name, counts, duration)`. All external
  image HTTP hops (including redirects) are recorded under the `artwork`
  service, regardless of which service/feature permits the image. The
  `CoverArtHttpFileService` records status and elapsed time through response
  body consumption, with transport, HTTP and invalid-image failures as `error`.
  Signature validation accepts JPEG, PNG, GIF, WebP, BMP, ICO, TIFF and
  AVIF/HEIC/HEIF image brands so system art retains those server formats.
  Image lifecycle and fetch-time refusals record `blocked` through the same
  boundary; build methods and repeated system permission checks are pure.
  Refusals are deduplicated by service, host and redacted path in a bounded
  200-destination LRU, cleared when the integration policy changes. Repeated
  refusals refresh their LRU position without changing counters or call history;
  an evicted destination can record again. Own-server hosts and cache hits
  add no requests. The main cover-art cache, AudioService's dedicated art cache,
  Windows SMTC's guarded loader and `PlaybackArtCache` all use this transport;
  `PlaybackArtCache` retains its durable/offline files and atomic writes. The
  integration recorder stores service, method, path (no host, query or headers),
  status, duration and `ok`/`error`/`serviceError`/`blocked`, plus per-service
  counters. User identifiers after `/user/` or `/users/` are replaced with `*` before path
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
  are written only when changed on Finish, through
  `setExternalIntegrationsEnabled` and `setIntegrationEnabled` (service keys
  only; feature switches are untouched); Finish then writes
  `updateIntegrationsNoticeDismissed(dismissed: true)`. Skip writes nothing, so
  the defaults (all on) stay and the 1.5.0 notice stays pending. Last.fm is
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
  `docs/development/development-workflow.md`.

Deezer, Last.fm, ListenBrainz, LRCLIB and Subsonic share
`AppConstants.userAgent`, derived from the newest changelog version. A client
header regression test checks it against `pubspec.yaml` so release versions
cannot silently drift. Last.fm key unmasking accepts hexadecimal digits only;
signed or whitespace-prefixed pairs are rejected.

### Deezer and artist Top Songs

Deezer's public API (`api.deezer.com`) needs no key. `DeezerApiClient`
(`lib/src/api/deezer_api_client.dart`) is built by `deezerApiClientProvider`
through `externalDioFactoryProvider`, so the guard and the call recorder apply,
with 8-second timeouts. One `DeezerRequestLimiter` per client keeps every Deezer
feature together under 5 requests per second and 4 in flight, at most 2 of the 5
for background requests. Deezer documents a quota of about 50 requests per 5
seconds, but answered code 4 while Navis started at most 32 per 5 seconds from
one IP, and at 5 per second still for 17 of the 106 requests of a fresh first
launch (Home's warm-up with an artist page opened during it). The real budget is
lower than documented and may be shared with the user's server, which also calls
Deezer (a server with a Deezer remote source searches it for every `search3`),
so Navis cannot know it. Waiting requests start in order, except that foreground
ones (the artist page and the other pages the user opens) always go before
`background` ones (Home's New Releases, its artist resolution and the Trending
chart); background requests start whenever no foreground one waits and their own
rate allows. Cancelled waiters fail promptly, even during a pause, and consume
neither the total nor the background start budget, including cancellation after
a slot is granted but before the request callback runs. Deezer reports errors as
HTTP 200 with `{"error": {"type", "message", "code"}}`: code 4 (quota) pauses
the shared limiter for 5 seconds initially, doubling consecutive quota pause
episodes up to 80 seconds. Concurrent answers from requests already in flight
share one episode. A successful answer (including code 800) resets the backoff
only if its request started at or after the latest pause ended. The pause is set
before releasing the request slot, so every Deezer request waits it out, and the
request that hit it is retried after the pause: up to 3 times for a foreground
request, once for a background one; code 800 ("no data") reads as an empty
result, and any other code throws `DeezerApiException`. Endpoints used so far:
`/search/artist`, `/artist/{id}/top`, `/search/track`, `/artist/{id}`,
`/artist/{id}/related`, `/artist/{id}/albums` and `/chart/0/tracks`; new ones go
through `getJson` to inherit the limiter and error handling. The models
(`DeezerArtist`, `DeezerAlbum`, `DeezerTrack` in
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
  (`deezer.topSongs`) first, then Last.fm (`lastfm.topSongs`), then none, up to
  50 songs. Deezer takes `/artist/{id}/top?limit=50`; whenever that gives fewer
  than 50 (none in some regions, a handful for niche artists: one for Masayoshi
  Soken when measured), `/search/track?q=<name>&limit=100` fills the list.
  Search tracks are kept only when their `artist.id` is the resolved id (results
  include covers and remixes by others), one per
  `normalizeMetadataKeepingEdition` title and never an edition already listed
  (so "Wonder" and "Wonder (Japanese Version)" both stay while a remaster folds
  in), most popular first. If the search fill fails, successful top tracks
  remain available and the partial response is not cached; cancellation still
  stops the load. Deezer failing or knowing nothing hands the whole list to
  Last.fm; fewer than 10 Deezer songs get Last.fm's songs not already listed
  appended, without listener counts. Each source caches its answer for 24 hours
  (the Deezer entry keeps the top and search parts; an entry written before the
  search fill reads as a miss). The result is a list of neutral
  `ArtistTopTrackSeed`s (`features/library/domain/artist_top_track.dart`: rank,
  title, artist, source, Deezer popularity, Last.fm listeners, album, length,
  Deezer track id). Only Last.fm seeds carry listeners, so only they show a
  number.
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
  the local pass yields to the event queue every 4 open seeds to keep Home
  scrolling responsive while resolving artist top songs and Trending;
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
- When the request ends the page settles only on real data: the entity is stored
  (a remote album songs-hydrated, a remote artist with albums), or a remote
  artist has none and the hydration succeeded (`detailHydrationConfirmed`; no
  request, a partial or a skipped one confirms nothing). Loading is bounded:
  after `kDetailHydrationTimeout` (20 seconds, for example while the request
  waits behind a running library sync) the page shows the failure state, and a
  late answer still fills it. The controller remembers a successful hydration
  that found an artist without albums for the server session
  (`artistConfirmedWithoutAlbums`, cleared with the per-session hydration set),
  so a reopen that needs no request still shows the artist as empty. Anything
  else, including a request or library read that throws, a failed, cancelled or
  network-deferred request (`detailHydrationFailed`), or an artist, album or
  album-list stream that cannot be read, ends in `DetailLoadFailedView`: "Could
  Not Load This Artist/Album", Retry (which also re-reads a failed stream), and
  "Search for <name>" (artists filter, or albums with "title artist") when a
  name is known.
- The name comes from the stored row, else from the route: `NavService`
  `openArtistDetail(…, name:)` and `openAlbumDetail(…, name:, artistName:)`
  add `?name=` and `&artist=` (`AppRoutes.detailNameParam` /
  `detailArtistParam`). Every link to an artist or album that may not be
  stored passes them: search results, song menus (library, album, playlist,
  search), album artist links, the artist and album menus, Fans Also Like, Missing Albums and New Releases. Library lists and
  Now Playing links open stored entities only.
- A page showing its entity carries `detailPageShownKey`, which the
  diagnostics release-card control reads.
- Refresh (`DetailRefreshButton`, on every artist and album page) and Retry
  re-run the hydration (`refreshArtist`, `requestTarget(album)`). A page
  that already shows its entity keeps it and reports a failed refresh with a
  notice.

### Deezer on the artist page

Three more artist-page features use Deezer, each behind its own switch and each
hiding itself or falling back when the switch is off, Deezer has nothing or a
request fails. The providers are in
`features/library/presentation/artist_deezer_providers.dart`, keyed by
`ArtistPageKey` `(artistId, name)`. They share `artistDeezerIdProvider` (the
resolver above), which is only watched after a feature switch has been checked,
so with all three off the page sends nothing to Deezer. `DeezerCatalog`
(`features/integrations/data/deezer_catalog.dart`, `deezerCatalogProvider`)
reads `/artist/{id}`, `/artist/{id}/related`, and `/artist/{id}/albums` through
the disk cache: artist details and related artists 7 days, albums 24 hours, "not
on Deezer" included; errors are not cached. The resolver shares one resolution
between callers asking for the same library artist and name at once (Top Songs
and these sections on a first visit).

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
- **Fans Also Like** (`deezer.similarArtists`, `artistFansAlsoLikeProvider`).
  Deezer's related artists are matched to the library by `normalizeMetadata`
  name through `libraryArtistNameIndexProvider` (`LibraryArtistNameIndexCache`
  in `features/library/data/library_artist_name_index.dart`): one index of every
  library artist, keyed in a background isolate for more than 64 artists, kept
  until the artists table changes (drift `tableUpdates`, so a sync or a remote
  artist written by search marks it stale) and rebuilt on the next lookup, so a
  sync's many artist batches cost one rebuild and an artist page costs one map
  lookup per related artist. Between library namesakes a server artist beats a
  remote one, then more albums. `fansAlsoLikeEntries` puts library artists
  first, each group in Deezer's order, and drops the page artist.
  `SimilarArtistsSection`
  (`features/library/presentation/similar_artists_section.dart`) draws it in the
  same two-row grid as the server's Similar Artists, which it replaces when it
  has artists: library artists keep their art and open their page; others show
  the Deezer photo with the Remote mark and open the server's remote artist
  `ext-deezer-artist-<id>` (`SimilarArtistEntry.deezerArtistId`) on a remote
  artist page (see *Remote artist and album pages*), which offers a search for
  the name when the server cannot provide it. The server's Similar Artists show
  as soon as Deezer has nothing or fails, or when Deezer has not answered within
  2.5 seconds (`kFansAlsoLikeServerFallbackDelay`); whichever list shows first
  stays, so a late Deezer answer never swaps it.
- **Missing Albums** (`deezer.missingAlbums`, `artistMissingAlbumsProvider`).
  Hidden, without asking Deezer, while the library albums load, when the artist
  is remote or when any of its albums, own or Featured In, is remote: the
  server's remote catalogue (Octo-Fiesta) always wins. Otherwise
  `missingDeezerAlbums` (`features/library/domain/missing_albums.dart`) keeps
  record types `album` and `ep` (singles belong to Home's new releases,
  compilations are left out), drops a Deezer album that a library album (own or
  featured) holds as `ext-deezer-album-<id>` or under the same
  `normalizeMetadataKeepingEdition` title, so remaster and deluxe packaging
  match while "(Japanese Version)" stays its own album, and lists them newest
  first, one per edition. A `ContentShelf` of `ExternalAlbumCard`s
  (`common_widgets/`, the `AlbumCard` look and `AlbumCardLabel`, with a
  policy-checked cover URL) follows the album grids, subtitled "2021 • EP".
  Cards take `ContentLayout.shelfCardExtent`, the size Home's album carousels
  also use (smaller under Home's compact density). A card opens the server's
  remote album `ext-deezer-album-<id>` (`remoteDeezerAlbumId`) with its title
  and artist as route names, on a remote album page that plays like any album
  and offers a search when the server cannot provide it. The card takes the
  feature it belongs to, so Home's new releases reuse it; its "2021 • EP" label
  and cover come from
  `features/integrations/presentation/deezer_release_labels.dart`. (The release
  sheet with a "Search your server" button that cards opened before was retired
  in favour of these pages; the user expects a missing album to open and play
  like any album.)

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
  `ExternalAlbumCard`s: a one-line (scrolling) title and an artist line, like
  the other album carousels.
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
- A library sync does not clear its store:
  `homeTrendingSyncRefreshBridgeProvider` re-runs it after a sync that succeeded
  fully or partly (unless a refresh started meanwhile, as Home's pull to refresh
  does), so the library pass picks up synced copies and only songs due for their
  daily check are searched. Sign-out and the library cache reset clear the
  store.
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

**Hero albums.** The random album showcase prefers releases with at least three
songs (unknown counts qualify), preserving source order within the preferred
and shorter groups before taking up to twelve albums. Shorter releases fill
any remaining slots, including when every candidate is short. Server random,
liked discovery and local downloaded/liked/offline candidates reuse their
existing song counts without additional API requests.

**Hero items.** `HomeRandomShowcaseItem` is `sealed`: a
`HomeRandomShowcaseAlbum`, or a `HomeRandomShowcasePlaylist` (sealed too:
`HomeRandomShowcaseListenBrainz` or `HomeRandomShowcaseTrending`). The hero
widgets switch over them exhaustively. Playlists share one look through
`isLoading`, `coverArtIds` and `localizedTitle`: a `PlaylistCoverMosaic`
(`listenbrainz_playlist_artwork.dart`; weekly playlists show ListenBrainz's own
image when there is one), the title, an availability line ("12 of 50 available",
"12 tracks available, matching") and a reason ("ListenBrainz", "Popular on
Deezer"). Tapping a playlist opens its page; only albums show Play. On desktop a
playlist's page lists its songs, Trending's numbered by chart position with
unmatched songs in place; a row plays like a weekly song (the whole playlist's
playable songs from it with Album Queue on, match flows collapsed).

**1.5.0 notice** (`IntegrationsNoticeCard`,
`features/integrations/presentation/integrations_notice_card.dart`). A
one-time row in the What's New row's place: "New in 1.5.0" and "Navis can now
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
(`common_widgets/home_notice_card.dart`), the shared notice tile: a
`surfaceContainerHigh` tile (Flat Surfaces: unfilled with a 1 px
`outlineVariant` border) with the Corner Style `lg` radius, a leading 40 px
`NoticeIconDisc` (or a custom `leading` such as a release cover), a
`titleSmall` w600 title, a two-line `bodySmall` subtitle, an optional compact
close button and optional actions (`NoticeAction`: a text secondary and a
tonal primary built from `NavisColorStyleData.tonalStyleOf`, never solid, per
the accent contract). Each caller keeps its own text and actions. The Home
update-ready element (`_UpdateTile` in `home_support_widgets.dart`, which
replaced the `MaterialBanner`) is the same tile: title "Navis {version} is
ready", a delivery-specific body, a "Release notes" text action, the tonal
Install / Download / Open in Play Store action, and a close button that
invalidates `updateProvider` as the old Dismiss did.

**Notice roles.** `NoticeIconDisc` (`common_widgets/notice_icon_disc.dart`)
is the circular icon mark shared by every notice surface and defaults to
`tonalControlFill` / `onTonalControlFill`, so notices follow the colour
style and the Controls (Accent | White) setting; no notice hard-codes a
colour. Transient notices (`_NoticePill` in `app_notice.dart`) are one neutral
raised pill (elevation 3, Corner Style control radius) for every kind, and
only the 30 px disc carries the kind: info is tonal, success is
`NavisTokens.success` over the pill, error is `errorContainer` /
`onErrorContainer` (no full error fill or border). The offline banner and
`ShellOfflineChip` use `NavisTokens.quietWarningContainer` /
`onQuietWarningContainer`. `EmptyState` shows a 64 px tonal disc over its
title and a secondary-coloured subtitle.

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

Home and Library pulls (including Library tabs and Liked see-all pages) call
`checkForUpdatesFromPull`. This uses the same integrations policy and forced
check request, bypassing the 24-hour throttle only when the master, Updates
service and `updates.automatic` switches are on. A temporary manual listener
keeps the auto-disposed provider active until it resolves and closes on
completion or widget disposal. Home uses its existing update tile; Library
shows an info notice, “Update available”, with a View action opening the
existing update dialog, once per available version and build. `UpdateInfo`
retains the verified manifest version and build in `notificationKey`, so a
newer dev build sharing a version can show another notice. `UpdateCheckStore`
reads and merges `lastCheckAt` and `notifiedVersion` in the same JSON file;
both writers tolerate corrupt state and preserve the other key. Only Library
notice calls record the key after showing; Home's banner is unchanged.
Null and error results are silent. Neither refresh
callback waits for the update check.

- `data/update_repository.dart` — fetches the channel's signed manifest from
  `AppConstants.updateBaseUrl` (R2, see [release-r2.md](release/release-r2.md)), verifies it,
  and selects the platform asset by manifest key using `detectInstallMode()`. Returns
  `UpdateInfo` (with `downloadUrl`, `assetFileName`, `sha256` and `size`) when a newer
  version is available. A manifest that fails any check is dropped (the reason is kept
  for diagnostics) and reads as "no update".
- `data/update_service.dart` — downloads each desktop artifact into a fresh private
  `navis_update_*` work directory under `getTemporaryDirectory()`. POSIX downloads
  require `chmod 700` on that directory before writing any contents. Navis then
  verifies the artifact and applies the update. Diagnostics overrides of the temp base are
  preserved. Android retains `<cache>/navis_updates/` for its FileProvider.
  Distribution is resolved at runtime:
  - **Sideload Android APK builds** (`NAVIS_SELF_UPDATE=true`) download the
    APK and invoke the system installer via a gated `MethodChannel`.
  - **Google Play installs** (detected via install-source metadata, or Play AAB builds
    with `NAVIS_SELF_UPDATE=false`) open the Play Store listing instead of sideloading.
  - **Desktop** runs a platform-appropriate apply strategy:
  - **Linux deb:** `pkexec dpkg -i` + relaunch.
  - **Linux RPM/AUR:** package-manager updates. These use root-owned `/opt/navis`
    and the existing write-access check shows Download Manually for normal users.
    The detector still selects Debian mode, so an offer requires `linuxDeb-amd64`;
    the published `linuxRpm-x86_64` key is for download consumers only. See
    [release-linux.md](release/release-linux.md) for the Ubuntu 22.04 build and package flow.
  - **Linux portable / Windows portable / macOS:** extracts the archive to a staging
    subdirectory of the downloaded artifact's private work directory, writes a
    self-deleting shell/batch script inside that same work directory, launches it
    detached, and exits. The script replaces the running bundle, relaunches the app, and
    cleans up automatically.
  - **Windows installer:** launches the Inno Setup installer with `/SILENT /CLOSEAPPLICATIONS`.
    Its silent relaunch uses `runasoriginaluser` so Navis resumes without installer elevation.
- `data/update_install_mode.dart` — `UpdateInstallMode` enum and `detectInstallMode()`
  function. Detects the current install type from filesystem heuristics (e.g. presence of
  `unins000.exe` for Windows installer mode; executable under `/opt/navis` for Linux deb).
- `data/archive_utils.dart` — cross-platform archive extraction (`tar`, `ditto`, PowerShell
  `Expand-Archive`).
- `data/update_scripts.dart` — generates the platform-specific updater scripts (`.sh` for
  Linux/macOS, `.bat` for Windows). Scripts include rollback on failure and self-delete
  after successful update. Unix scripts retain `chmod 700`; their enclosing private
  directory protects them before chmod as well. Windows batch paths escape percent
  signs; `robocopy` codes 0–7 succeed, while codes 8+ remove the partial target, restore
  the backup, clean staging and the script, and exit without relaunching. The current
  backup is deleted only after a successful copy. A failed initial backup rename also
  aborts before copying.
- `domain/update_info.dart` — immutable value object with an `UpdateDelivery` mode.
  `downloadUrl`, `sha256` and `size` hold the direct asset URL and its manifest digest for
  self-update paths; Play redirects omit them.
- `domain/update_delivery_resolver.dart` — maps platform, build capability, and Android
  install source to `UpdateDelivery` (`selfUpdate`, `storeRedirect`, ...).

### Signed manifest and download verification

`UpdateRepository.checkForUpdate` reads
`https://downloads.porthorion.com/navis/channels/<channel>/manifest.json`, a signed
envelope (`payload` and `signature`, both base64). It accepts the manifest only if all of
these hold; each failure is recorded as a reject reason and nothing is offered:

- the Ed25519 signature verifies against `AppConstants.updateSigningPublicKey`
  (`invalid_signature`, `malformed_envelope`);
- `schema` is 1 and `channel` equals the build's channel (`unsupported_schema`,
  `wrong_channel`);
- `version` is newer than the installed version, or on dev/staging only, semver
  is equal and the optional signed integer `build` exceeds
  `PackageInfo.buildNumber` (`version_not_newer`). Stable and manifests without
  `build` use semver alone; malformed build values reject as `malformed_payload`;
- the platform's asset key exists (`missing_asset`). Keys are the `UpdateInstallMode`
  names, with `linuxDeb-<arch>` (`amd64` or `arm64`) for Debian packages; Debian never
  falls back across architectures. Android's existing `com.navis.app/distribution`
  `getInstallSource` response includes `primaryAbi` from `Build.SUPPORTED_ABIS[0]`.
  For `arm64-v8a`, `armeabi-v7a` and `x86_64`, the updater prefers
  `androidApk-<abi>` when present, otherwise `androidApk` (universal). Unknown or
  unavailable ABIs also use universal. This adds optional asset keys while
  retaining schema 1 and existing manifests;
- the asset URL is HTTPS under `AppConstants.updateBaseUrl`, and its `sha256` and `size`
  are well formed (`invalid_asset_url`, `invalid_asset_sha256`, `invalid_asset_size`).

A transport failure is not a reject: it surfaces through the provider's error state, and
a successful fetch keeps the 24-hour check throttle. The release notes link comes from
the manifest's `notes_url` only when it is an HTTPS URL on `navis.porthorion.com`;
otherwise "Download Manually" opens `AppConstants.updateManualDownloadUrl`.

`UpdateService.downloadArtifact` refuses a URL outside the update host or a missing
digest, then checks the downloaded file's size and SHA-256 against the manifest before
returning its path. A mismatch deletes the file and throws `UpdateIntegrityException`;
the dialog shows "The update download was damaged. Try again." Nothing is installed or
extracted before that check passes, which replaces the old "smaller than 10 KB" guard.

`GET /v1/diagnostics/update` returns the last manifest check (URL, time,
`signatureValid`, `payloadVersion`, `assetKey`, `rejectReason`, `tag`) and
`POST /v1/diagnostics/update/check` forces a check through the same providers as
About's Check now. `POST /v1/diagnostics/update/download` forces a check and then runs
the production download and integrity check without installing anything; it adds
`downloaded`, `artifactPath` and `downloadError` (`integrity_mismatch` for a size or
SHA-256 mismatch). With the body `{"apply": true}` on desktop it then runs the production
apply (`applyDesktopUpdate`) after responding, which replaces the running build and exits;
this is how a clone proves the whole R2-to-installed path. The GET route is available in every diagnostics mode; the POST
routes are clone-only. See [release-r2.md](release/release-r2.md) for publishing and key handling.

### Write-access guard

Before starting any download, `UpdateService.canApplyUpdate(mode)` probes the target
directory for write access. If the directory is not writable (e.g. app installed to
`/Applications` by an admin user, or a read-only portable location), the update dialog
shows a "Download Manually" prompt linking to the release notes page (or the website
download page) instead of attempting
a doomed automatic update.

### Startup cleanup

`UpdateService.cleanupStaledUpdates()` is called on every desktop app launch. It removes
`.backup` directories next to the bundle and leftover `navis_update_*` directories
under the same `getTemporaryDirectory()` base, including legacy staging directories.
POSIX cleanup checks the directory owner against the current UID; Windows uses its
per-user temp base. Cleanup skips symlinks, does not follow nested symlinks, and
ignores individual deletion errors. Updater scripts may leave the private work
directory for this startup cleanup.

### Release transport credentials

The optional Forgejo bridge in `tool/release.sh` supplies its Authorization header
from a mode-600 file in the private release secrets directory via curl `-H @file`
(requires curl 7.55 or newer). Release creation and asset uploads share that file;
the existing EXIT trap removes the directory on success or failure. The token is
not passed in curl's command-line arguments.

### Update channel

The update channel (`stable` or `dev`) is baked in at compile time via
`--dart-define=NAVIS_UPDATE_CHANNEL=dev`. The channel selects the manifest
(`channels/dev/manifest.json` or `channels/stable/manifest.json`), and a manifest whose
signed `channel` differs is rejected. This ensures sidecar/dev builds never suggest a
stable release as an upgrade. Builds with another channel name (for example `staging`)
read that channel's manifest; see [release-r2.md](release/release-r2.md).

The Last.fm API key used by "Same Vibes" instant mix mode is injected at build
time as a masked pair, `NAVIS_LASTFM_API_KEY_MASKED` (key XOR a per-build random
pad) and `NAVIS_LASTFM_API_KEY_PAD`, both hex, passed through
`--dart-define-from-file`. `AppConstants.lastFmApiKey` XORs them back once at
runtime and returns an empty key for a missing, malformed or mismatched pair. A
plain `NAVIS_LASTFM_API_KEY` define is still accepted when the pair is absent so
local dev runs work. Masking deters casual extraction and is not secrecy: a
Last.fm API key is a client identifier and no shared secret is used. See
[ci-cd.md](development/ci-cd.md#lastfm-key) for the build scripts and the post-build
artifact scan.

### Recommendation sessions

Song-based **Server Mix** and **Last.fm · Same Vibes** are the two Instant Mix
modes. Settings › Integrations › Last.fm › "Same Vibes mixes" chooses between
them (`preferredMixModeProvider`); Server Mix is used whenever the policy does
not allow `lastfm.sameVibes`. Server Mix calls the standard Subsonic
`getSimilarSongs2` endpoint, then the original `getSimilarSongs` when
unsupported. The existing Navidrome `getInstantMix` endpoint is a final
compatibility fallback only when both standard endpoints are unsupported.
AudioMuse's installed Navidrome plugin answers the standard similarity calls
through the server; the client neither calls AudioMuse directly nor attributes
generic server results to it.

A mix starts from the song its caller chose, which need not be the one
playing (Android Auto starts mixes from browsed songs): the first refill uses
the requested seed and later refills follow the current song. Starting a mix
keeps only the seed in the queue, clearing deferred played history and upcoming
songs even when the player already holds only the seed, so the first refill
treats only the seed as already queued; songs from an earlier mix still behind
it are fair recommendations again. Similarity endpoints know only server ids, so a remote
seed (an Octo-Fiesta `ext-` id) mixes from the library copy `getSong` maps it
to, when the server has one. `RecommendationService.libraryCopyId` owns that
lookup for both recommendations and the Server Mix seed-availability provider.
Server Mix asks for that copy before reporting unsupported, and Same Vibes looks
it up (even while the remote seed plays) for its server fallback. Neither mode
queues the copy or the remote original right behind the seed. A remote seed
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
The audio handler requires Personal Radio and preferred-mix callbacks at
construction so these actions also work before the Flutter shell registers
its callbacks.
The Home action awaits an actual queue insertion before opening Now Playing.
Personal Radio, Server Mix and Same Vibes start background refills with eight
tracks remaining after the current song. An unavailable Next at the Personal
Radio queue tail records one pending skip in the notifier and starts the
existing refill if one is due. After a successful recommendation append, it
advances to the first inserted track only while the same session owns the queue
and the requested tail occurrence is still current. Leaving that occurrence,
stopping radio or replacing the session drops the pending skip; repeated Next
requests while waiting do not skip multiple newly inserted tracks.

`RecommendationSessionCoordinator` owns one generation and cancellation scope
across these automatic modes. Each initial fetch and refill uses its own cancel
token, tracked by the session only while in flight and released on success or
failure. Ending a session cancels its in-flight requests; later requests receive
pre-cancelled tokens. Completed refill responses are not retained by the session.
Replacement queues, queue clear, internet radio,
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

Background refills retry with backoff. After five consecutive failed refills
Same Vibes, Server Mix and Personal Radio stop refilling at `retryExhausted`;
later playback snapshots, a cleared error notice or an expired backoff do not
resume them. A verified network recovery re-arms Personal Radio's exhausted
refill within its existing recommendation session, but only after network
failures; rate limits, invalid keys and unsupported servers keep their backoff. Starting a mix again also
re-arms refills.

## Startup and resume evidence

`AppLogger` writes typed, identity-free startup events to a private app-support
ring (`startup-timeline.jsonl`, up to 200 events and 32 KB). Native WorkManager
records entry and terminal outcome, including pre-engine deferrals/failures,
in its separate locked ring (`startup-worker.jsonl`, up to 100 events). Copy
validates both schemas and merges them by time, staying below 64 KB. Events
include process startup, warm lifecycle changes, bootstrap attempt/timing and
failure category, queue restoration timing, reconciliation results and restart
use. URLs, accounts, tokens, titles and media IDs cannot be passed to this API.
Nothing is uploaded automatically; the privacy diagnostics text describes local
retention until copying.

The existing LibrarySyncController lifecycle listener captures the writer
connection's `PRAGMA main.data_version` before backgrounding. Resume compares it
on that same connection using a short exclusive Drift scope, not a pooled
reader. An external commit announces all mapped tables once (SQLite supplies no
table list), so existing subscriptions re-query, invalidates identity caches,
reapplies durable aliases and reloads persisted sync state. Checks are bounded,
coalesced and do not recreate the database or sync engine. A resumed foreground
worker with a live durable Android lease or an unfinished recent start keeps a
one-second reconciliation timer until completion or expiry. Each tick reads
worker completion before comparing data_version, including a final comparison
when the run ends. The timer stops on backgrounding, session change, disposal,
or worker completion, with a nine-minute observation budget; it is not a
permanent database poll. Every foreground resume restarts observation independently
of an in-flight connectivity/reachability reconciliation. After at least 30
seconds away, the same reconciliation refreshes connectivity and native
metering through their existing providers, then joins the existing reachability
probe. Initial connectivity also includes a fresh platform check. Subsonic
transport timeouts/connection closure retry only read-only GET endpoints;
mutating GETs such as scrobbles and playlist edits are never replayed.

Both the native audio-service probe and Dart's `defersBackgroundSync` policy
reserve priority for playing/loading/buffering. A paused queue remains visible
and published while allowing background sync. Independent paused wake-lock
release is unavailable in the current plugin; see the
[1.5.1 follow-ups](plans/idle-robustness-followups.md).

## Data Flow

### Silent playback recovery

Android declares the app-owned `com.ryanheise.audioservice.NavisAudioService`
subclass. `NavisApplication` redirects audio_service 0.18.19's explicit browser
binding, and the service redirects its hard-coded foreground start, to this
component. MediaBrowser discovery, notification controls and Android Auto still
use the plugin's media session. After `super.onCreate()`, the subclass restores
a missing static listener only if the plugin retains its handler interface.
One guarded reflection method owns the two private field accesses; a JVM
contract test checks their names, static modifiers and listener types. Its
custom action forces the Dart projection to republish metadata, the windowed
queue and playback state even when their identities have not changed. No plugin
removal or engine reattachment occurs.

Vendored just_audio abandons denied audio-focus requests, then retries twice
with 200/400 ms delays. Exhaustion completes Play with `AudioFocusDeniedException`.
just_audio reports `playing` only once focus is granted, so a load during the
request cannot start native playback and a denial never publishes Playing.
Navis retains the requested transport generation and retries silently with a
1–8 second backoff for at most two minutes (`NavisPlaybackTimeouts.focusRetry`);
it then stays paused, publishes the paused state and records the timeout in the
startup timeline. The retry state clears when a playback event reports the
granted focus. Pause, Stop, selection and disposal cancel pending intent;
transient interruptions block automatic retries until they end, and the resume
then gets a fresh budget. While a retry is pending the media button cancels it
like Pause, and Play asks again at once within the same budget; a Play that
instead re-arms song recovery leaves no budget behind for later automatic plays. An explicit
Play (app, notification, media button, Android Auto) overrides a transient
interruption: it abandons the cached focus request and asks again. A late
denied activation cannot release a newer Play's focus. Permanent focus loss
still permits a later explicit Play.

Lock-cache origin and range fetches have cancellable 15-second connection and
header deadlines and a 30-second body-progress deadline. Failed partial files
are discarded and requests may restart. `networkReconciliationProvider` shares
the existing bounded connectivity, metering and server-reachability check
between resume and playback, and reports device connectivity separately from
server reachability. Scoped container subscriptions keep these bounded
checks active even when UI provider listeners are paused, and metering is read
after connectivity settles so a retired future cannot stall reconciliation.
`networkReconcilingProvider` is true while that check runs: the download and
scrobble readers (`networkSettled`) then report not settled, so downloads admit
no new workers and requeue a failure without spending a retry, and scrobble
dispatch returns before touching saved deadlines. Each service is kicked once
(`processQueuedDownloads`, `flushDue`) when the check ends. The hold is bounded
to 15 seconds and clears itself, recording a `resumeReachability` timeout in the
startup timeline; running download workers are never cancelled.
Downloads also yield to a loading song: `downloadServiceProvider` listens to
`playerStateProvider` and passes only "loading, not radio" plus the song id to
`DownloadService.yieldToPlayback`. New workers wait while the stream loads, at
most 15 seconds once per track, and the pump restarts when loading ends or the
bound passes. Running workers continue and live radio never holds downloads;
the permanent download → rolling cache → stream order is unchanged.
Native just_audio error fields and legacy stream errors share one recovery
path; repeated native error data is deduplicated. Android captures ExoPlayer's
current position before publishing an error and switching to idle, so recovery
uses the native failure position rather than the last ready-event position. An offline song retains its
position and play intent without spending the reload retry. The pending request
belongs to that song: a natural advance or queue edit that changes the current
song drops it. Before reloading, recovery checks that the player is still idle,
loading or buffering, so a stream that recovered by itself is never reloaded or
rewound. Pause and Play supersede the pending request. Play on a remote song
whose native player reported a failure re-prepares it once, at a seek target
that is still waiting or else at its position, and waits again while offline;
a song that was never prepared (gapless off) simply plays. The handler records
the failure itself and forgets it at the next queue load or player progress,
because just_audio keeps an old error code on an idle player after a new load.
A seek during the wait moves the recovery target instead of seeking the failed
player, and still applies if the song plays again by itself, including when
Play arrives while the network check runs. While a load or another seek owns
the song, Play and seek take their normal path; a Play during a reload starts
the reloaded song. If the reloaded song fails again while the rest of the
queue is still loading, the Play waits and restarts recovery once that load
completes; only an error-free event that is not idle clears the failure. Song and station state remain buffering while waiting, preserving OS
transport controls.
Verified recovery after an observed outage re-arms the song's reload allowance
so a later outage does not skip it.
Network wait retries back off from 3 to 24 seconds. The audio handler's network
signal fires when the server answers again or the device reconnects; it is
created once per handler initializer, not per bootstrap attempt. Internet radio
retains its station after a transient source/network error and reconnects
through the queue lane, unless a newer user command superseded it. Stations are
third-party hosts, so radio waits only for device connectivity, never for the
Navidrome server. Android reports Media3's `PlaybackException.errorCode` and,
for a bad HTTP status, the status: connection and timeout failures are
transient; 4xx statuses, missing files, unsupported or malformed content and
decoder failures are permanent. media-kit reports every source failure as code
1, which stays transient. Transient reconnection stops after ten minutes of
failures while the device is online (`NavisPlaybackTimeouts.radioRecovery`):
being offline waits silently without spending it, and only time spent failing
counts. A station that reconnects carries over its failure time until it has
played for a minute (`radioHealthyPlay`), so one that connects and drops again
still stops while one that mostly plays on a flaky network keeps going. A
permanent failure or an exhausted budget stops the station, restores the previous queue paused and shows one
"Radio stream unavailable" notice, since only the user can pick another
station. A new Play during an older
reconciliation re-arms its own recovery after that check finishes. Verified
reachability also re-arms exhausted personal-radio refills without replacing
recommendation-session
ownership. Automatic recovery records identity-free events in the private
startup timeline and does not publish a playback-failure notice.

### Playback Flow

Radio accepts only hosted HTTP(S) stream URLs and keeps them in handler memory,
never `MediaItem.extras`. AzuraCast polling is derived only from `/listen/` or
`/hls/` stream paths; station homepages do not create polling endpoints.

1. User taps album/track → `QueueController.replace()`
2. Queue controller calls `NavisAudioHandler.replaceQueue()`
3. Audio handler resolves sources via `PlaybackSourceResolver`
4. Source resolver checks: completed permanent download → eligible rolling cache
   → stream. Permanent downloads always win regardless of streaming quality,
   Cached First, or network settings. Rolling entries retain profile matching
   unless Cached First, cellular cache preference, or offline playback applies.
   Successful rolling-source resolution refreshes its LRU access timestamp.
   Permanent-source resolution leaves the cache row unchanged: downloads are
   excluded from LRU eviction, and touching them during large queue fills would
   repeatedly invalidate the Downloads queries and reorder their results.
5. Audio handler updates structural state through `playbackSnapshotProvider`
   plus lightweight timeline updates through `positionStream` and the
   track-keyed `bufferStateStream`
6. UI reacts to structural snapshots without rebuilding for routine position
   or buffer ticks; timeline widgets subscribe to the lightweight streams

`playbackSnapshotProvider` attaches its live broadcast subscription before
seeding the current snapshot, using the same `Stream.multi` ownership pattern
as the buffer-state provider, so no snapshot is lost between the seed and the
subscription.

Phone Now Playing reads the live `playerStateProvider`. The app shell watches
a deduped `_ShellPlayback` selection that ignores seek settlement, positions
and queue contents, so it must not hand its `playback` down: an
`overrideWithValue(playback)` scope around Now Playing (stale since queue
paging added the dedupe) froze the seek bar on every seek target, and with
Repeat One for good. Seek bars read their position through
`watchDisplayedPlaybackPosition` (`playback_seek_bar_style.dart`), which
watches the position stream and `pendingSeekPosition` on every build, so a
skipped `??` branch cannot drop the stream subscription. Shell and seek bar
widget tests cover both.

`NavisAudioHandler` keeps its fields, public API and audio-service overrides in
`navis_audio_handler.dart`. Private helpers are grouped in part files using
private extensions on the handler within the same library:

| Concern | Part file |
|---|---|
| Crossfade decks | `navis_audio_handler_crossfade.dart` |
| Android Auto loading and browse refresh | `navis_audio_handler_android_auto.dart` |
| Persistence and restore | `navis_audio_handler_persistence.dart` |
| Released queue window | `navis_audio_handler_queue_window.dart` |
| Queue loading and source preparation | `navis_audio_handler_queue_loading.dart` |
| Queue edits and identity aliases | `navis_audio_handler_queue_editing.dart` |
| Transport and navigation | `navis_audio_handler_navigation.dart` |
| Seek and stall recovery | `navis_audio_handler_recovery.dart` |
| Rolling-cache observation and sidecar activity | `navis_audio_handler_cache.dart` |
| Radio metadata setup and mix dispatch | `navis_audio_handler_radio.dart` |
| Startup and native queue diagnostics | `navis_audio_handler_diagnostics.dart` |
| Media-session state, listeners and sound application | `navis_audio_handler_media_session.dart` |

Helpers that directly reference class static members remain in the class, as do
source-guarded player construction and initialization. Subscription cleanup
also stays in the class so the analyzer can track cancellation of its fields.

`StreamingQuality` belongs to the player domain. The composition root selects
the active profile and injects it into the source resolver; the resolver does
not import application providers for the value type.

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
(both on pinned LGPL libmpv; see [release-windows.md](release/release-windows.md#bundled-libmpv)
and [release-linux.md](release/release-linux.md#bundled-lgpl-libmpv)).
Windows uses the Navis mingw-w64 cross-build under `tool/libmpv/`, with
static media dependencies and captured corresponding sources, WASAPI output,
and Schannel TLS. Its DLL imports only Windows system libraries; the vendored
plugin downloads the verified archive from the sole per-build R2 URL.
Linux startup uses `bootstrap/bundled_libmpv.dart` to select
`lib/libmpv.so.2` beside the resolved executable when present, otherwise it
leaves media_kit system lookup in place. CMake bundles the verified x86_64 pin
by default; `NAVIS_BUNDLE_LIBMPV=OFF` supports system-mpv development builds.
`navisEqualizerSupported()` decides availability for both the controller and the
handler; unsupported backends disable the entry. Modes, exact preset semantics, AutoEQ provenance,
headroom, migration, and validation limits are maintained in
[equalizer.md](features/equalizer.md).

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
1× stays centred. Large text falls back to a centred wrap. Presets use the shared, data-driven `PresetPicker`
(`common_widgets/preset_picker.dart`): a `DropdownMenu` over `PresetPickerEntry`
values (Custom while `selectedId` is null, Normal, then saved presets;
unsupported ones disabled with a tooltip) and a ⋮ menu to save as new, update,
rename or delete (with confirmation) the current or originating preset
(`updateId` and `manageId`). `PresetPickerLabels` carries every string, and the
async callbacks (`onSelect`, `onSaveNew`, `onUpdate`, `onRename`, `onDelete`)
own persistence; `onSaveNew` and `onRename` return the error shown inline in
the name dialog. The panel supplies the Speed and Pitch wording and
`PlaybackAdjustmentController` calls. Its `TextEntryDialog` also serves exact
entry, which allows two decimals and decimal commas, validated inline.

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
applies. A whole-step ruler (`snapStep`, the colour rulers) uses
`snapTickFeedback` instead: a selection click on each line, one every 8 px
(same 12 ms throttle) and drawn as small ticks, a light impact exactly when the
rounded step changes, which is when the preview colour changes, and a medium
impact when that step is the reset value (0); crossing the zero line itself
stays a click. The − and + buttons sit at the ends of the ruler they move, in a row
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
Cache & Storage does not look idle before registration. Desktop partial-byte
diagnostics read the active sidecar attempt's received byte count, including
its generation-specific partial write. A generation-scoped terminal callback
clears activity on success, cancellation, or failure; an older attempt finishing
cleanup cannot clear a newer attempt's activity. Every desktop source is
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

The vendored desktop adapter observes libmpv's `metadata`
property through media_kit 1.2.6's `NativePlayer.observeProperty`. It reads
`metadata/by-key/icy-title`, `icy-name` and `icy-url` with `getProperty`, mapping
these to just_audio's ICY info and headers. Only `icy-title` supplies a song
title; `media-title` is ignored because mpv substitutes a URL or filename
before stream metadata arrives. Until then Navis displays the station name.
Genre metadata is ignored. A changed title emits a playback metadata event; source loads and playlist entry changes clear the old metadata.
Reads check the native `path` and a revision token so a previous source cannot
publish a late title. Observers are removed before native player disposal.
Android/iOS keep the native just_audio ICY path.

Remote stream recovery is generation- and song-scoped. A failed remote source
receives one retry at its current (or user-requested seek) position: a
lock-cached source rebuilds as a direct stream, while a direct stream reloads
at that position. A second failure marks the song failed and advances to the
next playable queue item when available, retaining the latest Play/Pause
intent. A failed retry yields to a newer transport command or selection before
advancing. Seek recovery also detects a remote
seek that landed correctly but remains buffering. Background phase-2 queue
fill failures never reload or clear the active start item. Loading an uncached
remote (external) song has `NavisPlaybackTimeouts.remoteLoad` (45 s) rather
than the 12 s load deadline: the server fetches the whole file before it sends
the first byte, which on a first play routinely took longer, and the abandoned
load left the song idle even after its sidecar download finished. Before the
player opens such a song, the handler warms the stream with a two-byte request
and waits (cancelled by any newer command) until the first response bytes
arrive. It then cancels the probe body even when the server ignores Range,
rather than downloading the whole song before playback. This is needed because
the players give up on a silent connection long before the server has the file
(ExoPlayer after 8 s, also through the lock-cache proxy) and the server answers
at once afterwards. Manual Next, Previous and queue taps use the same
warm-up for an external target backed by a remote source (including remembered
remote rows), with the remote-load deadline for both native seek and reload.
Local files retain the four-second control deadline. A timed-out navigation
rebuilds at the requested occurrence first; only a failed rebuild advances.
The requested `loadingSongId` remains visible through that recovery.

On Android a lock-cache download otherwise ran to completion after the player
had moved on; on a slow link a skipped song's download starved the new song,
whose first load then timed out. When the current song changes, downloads of
songs other than the current and next ones are cancelled
(`LockCachingAudioSource.cancelDownload`, a Navis addition to the vendored
just_audio) and their partial files discarded; desktop already keeps a single
sidecar download.

The mobile lock-cache proxy rejects a ranged response with an unknown content
length with HTTP 500 and closes it. It cannot construct a valid `Content-Range`
without the end byte; returning an error lets ordinary remote-source recovery
retry with direct streaming instead of leaving the native request unanswered.
Sized ranges and reads from the completed cache file keep their normal responses.

Album-style queue replacement is lazy: the active transport queue prepares the
tapped song first, then fills the remaining sources in phase 2. Phase 1 pauses
and stops the active player and cancels/pauses the crossfade deck before remote
warm-up. It publishes the selected song's metadata immediately when its row is
known, with `isLoading` and `loadingSongId`, before resolving or warming its source.
`_mediaItemForSong` builds both pending and source-resolved items with the same
title, artist, album, duration and resolver-owned art URI; final publication
adds source extras and cached artwork. `_supersedeQueueWork`, the existing
queue-replacement metadata anchor and `_emitSnapshot` keep snapshots and
`_setCurrentMediaItem`/`mediaItem` on that pending target while old native index
events arrive. Queue replacement (IDs or supplied rows), navigation (including
deferred jumps), recovery and eager setup use this authority. The UI's existing
`PlaybackStartupObserver.beginPlaybackSelection` also accepts its provisional
song row before `QueueController` persists/readbacks API results, so search,
Trending and recommendation taps publish without waiting for that work.
When provisional persistence starts over radio, the existing station and metadata
subscription stay alive until the queue loader accepts the replacement. Failed
persistence republishes that station's current metadata; radio callbacks cannot
replace the pending song media item while persistence is in progress.
Generation/token checks reject superseded preparations before publishing or
applying sources. When failure is handled, metadata returns to the source the
player actually holds, or clears for an empty player. Pending display does not
start a scrobble session for a song the player has not reached; audio_service
reports loading while the selected source is unready and retains native queue
coordinates. Android notifications/lock screen/AVRCP and the existing MPRIS and
SMTC media-item subscriptions receive the same publication as Now Playing,
mini players and the desktop bar. A hung stop retires the deck and continues
loading the selected song on the rebuilt player. Failed phase-1 loads realign
the materialised queue and current item with an empty rebuilt player before
recovery. Abandoned players receive independent fire-and-forget mute and pause
requests before stop/dispose, so a hung cleanup cannot leave them playing.
Stall watching, remote failure recovery and ReplayGain lookup wait while a
selection is loading or a logical queue replacement is pending. Snapshot and
media-session metadata are published from the same resolved queue item.
ID and supplied-row inputs share one replacement lifecycle for admission, lane execution, early logical
persistence, fill, completion and timeout advance. The ID adapter canonicalizes
identities before Match Flow expansion and reads rows inside the lane. The row
adapter rereads local retired identities and local Match Flow expansions; mixed
queues containing external rows retain every supplied row and bypass expansion.
Replacement row resolution checks cancellation before either loading or clearing
the queue; empty-result clears retain generation ownership across native awaits.
Timeout recovery retains the adapter's IDs or rows in play order without reshuffling.
Advancement follows the next resolved occurrence mapped back to its input position,
preserving duplicate occurrences when rows are missing during resolution.
Eager queue loading and saved-queue restoration keep their separate contracts.
If library rows are missing during ID resolution, Match Flow expansion, or a canonical
reread, the selected occurrence is remapped past those missing rows; duplicate
song occurrences keep their relative position. While phase 2 is loading, `PlaybackSnapshot.queueSongIds` can represent the pending logical
queue rather than the prepared transport queue, with
`hasPendingLogicalQueue == true`. Queue UIs should display those IDs but avoid
remove, reorder, or play-index actions until the transport queue catches up.
Player transport controls distinguish that background queue fill from an
unready selected remote source. They also show remote buffering after the
queue operation ends and show the pending target's metadata immediately. A ready
selected source keeps its play/pause icon even if the rest of the queue is still
filling.

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
that MPRIS, SMTC and Android media sessions see. Skip capabilities compare
the logical index with the logical length, so Next is unavailable at the end
even when played history has been released. System queue skips,
removals and inserts convert materialised positions to logical positions at the
handler boundary, after the projection wrapper adds its queue-window offset.
System remove-at and insert commands use the logical queue edit API; inserting
into an empty queue loads the supplied song through the ordinary add path.
Replacing, restoring, or rebuilding a queue longer than 256 songs materialises
32 songs before and 32 after the start song; earlier songs go to the head and
later ones to the tail. When fewer than 12 materialised songs remain after the current one, one
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
stays deferred with the songs farther from the window: following songs in
the tail or earlier songs in the head. Tail releases back off and retry; a
backward jump can release the playable head suffix and leaves unavailable
history queued for a later attempt. Shuffled queues defer like any other (see Shuffle below).
Repeat-all stays off natively while the initial logical queue is filling,
anything is deferred on either side, or shuffle is on for a multi-song queue.
The player never wraps early; the reported repeat mode is the user's, and at
the end of the last song Navis starts the next pass itself. If the selected
song completes before the initial fill finishes, the shared completion path
continues at the next logical occurrence once filling settles. Only Repeat One
may loop the temporary one-song playlist.
`GET /v1/playback/status` reports `materializedLength`, `deferredLength`,
`deferredHeadLength` and release counters. The queue window model test
(`queue window model` in
`test/src/features/player/data/navis_audio_handler_navigation_test.dart`)
runs 500 seeded random sequences of navigation, auto-advance, edits and
shuffle and pre-shuffled replacements (including cold external HTTP selections)
against a tiny window. It checks all active, inactive and retired players against
snapshot/media-session metadata on every structural emission, then the queue,
index, native playlist and saved queue after each settled step;
`NAVIS_QUEUE_MODEL_SEEDS` changes the count.

Shuffle is owned by Navis, not the player (`_shuffleEnabled`,
`navis_shuffle_order.dart`). Native shuffle is never enabled: it can order
only what the player holds, and media_kit's `playlist-shuffle` physically
reorders mpv's playlist while just_audio keeps the old order, so the song
reported as playing was not the song heard. Instead the logical queue is
always the play order, so the Queue shows the real order and next/previous
step by one. Turning shuffle on keeps the history and the current song and
shuffles the rest; a queue started with shuffle on begins at the chosen song
with the others shuffled. The unshuffled order is kept in `_originalOrder`
(entity Shuffle callers pass the optional `originalOrder` of their unshuffled
IDs alongside pre-shuffled rows, so the handler preserves the supplied order
and never shuffles it twice). Supplying that order also enables shuffle mode,
including its persisted toggle state. Android Auto’s Shuffle liked projection passes
the same original order through the row-loading adapter. It is reconciled lazily with edits
(`reconcileOriginalRanks`: songs matched by occurrence, a song played next
lands after the current song, appended songs go last, removed songs drop).
Turning shuffle off restores that order around the current song without
interrupting it (`_rearrangeQueue`). If a native rearrangement times out, the
handler restores the captured queue/current occurrence and rolls back shuffle
mode and original ranks; the resulting state is still persisted and emitted.
Schema v88 saves each queue row's
unshuffled position in `play_queue_items.original_order` next to its play
position, so a shuffled queue restores in the order it was playing; a queue
saved by an older build (shuffle on, no original order) keeps its history and
current song and shuffles the rest. Repeat-all completion, forward Next at the
end, and Play on a completed shuffled queue share one next-pass operation. It
uses the existing shuffle helper and queue rearrangement, retains original
ranks and every occurrence, and chooses a first song different from the one
that just ended whenever another song exists. A random draw matching the old
order is changed when an alternative is available (a two-song queue has only
one order with a different starting song). Paused Next keeps playback paused.
Normal crossfades can start the next shuffled pass when the whole queue fits
the player; their outgoing occurrence stays last so a failed prewarm still
stops at the correct boundary. Released-window and Smart-mode wraps continue
through completion and navigation. Remote rows keep
their own row whenever a materialised song returns to the tail (reorders,
deferred ranges, far jumps, seek recovery, crossfade deck sync): the
handler remembers the rows of materialised remote songs instead of re-reading
their ids, which would drop them or swap in a matched local song.

Every native queue edit runs under a timeout, including single removals and
moves. Native index/playback events wait until a queue edit's Dart mirror agrees with
the native sequence, so an insertion cannot temporarily publish another song.
Song-scoped state is refreshed when the mirror commits. A timeout rebuilds both
players, leaving the active one empty, so queue edits reload the materialised
queue into the rebuilt player at the same
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
An indexed jump resets this readiness and replaces the pending position before
loading the entry. A zero position accompanying the jump needs no native seek,
since the entry starts at zero; non-zero positions wait for the new entry's
initialization or duration event, rather than the previous cached duration.
Seeks on the current entry without a jump keep their existing behavior.
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
every source. A startup, deferred-retry or post-radio restore timeout keeps the
saved queue instead of deleting it. Radio Stop returns after stopping the stream; its
background restore and the restore after a terminal radio failure share this
preservation policy. Stopping radio, or a terminal radio failure, restores the
previous queue paused, exactly like startup restore: it never resumes playback
on its own.
This is intended (owner decision 2026-10-09), not a gap to close. Before releasing the lane it cancels the restore token,
retires its load generation, and replaces the native player, so a late native
load or its inner deadline cannot change a newer selection. Eager restores
(up to 64 songs) carry the same cancellation ownership through source
preparation and native apply; late completions and failures cannot pause
playback, publish metadata, or clear saved state.
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
Position and publishes Rate on every speed change. Interface-specific property
descriptors generate MPRIS introspection and individual/bulk reads; method and
property-write dispatch remain separate. Windows SMTC has no rate,
so `WindowsSmtcBridge` publishes its timeline in real listening time and
converts SMTC seek and skip requests back to track time.

A scrobble and play-history session belongs to the playing queue entry: songs
inserted, released, or moved before it shift its index without starting a new
session, and neither does refreshing its metadata in place. Disposing the
scrobble service disables timer scheduling before cancellation; in-flight
flushes and database timer-sync results cannot recreate timers afterwards.

Queue replacement prefetches lyrics only for the selected song and the next
two; batched artist admits prefetch none. `lyricsProvider` watches just the playing item's lookup metadata, so a
track change or artwork re-emit does not re-run every cached lookup.

Each selection keeps a bounded, redacted startup timeline in the handler. A
remote Search selection starts it before provisional database writes. The
handler then records source resolution, selected-source apply, player readiness,
and the first advancing position. `GET /v1/playback/status` exposes the latest
16 attempts as `startupAttempts` for authenticated diagnostics; those entries
contain elapsed milliseconds and source kind but no song ID, title, or URL.

The handler owns audio-session interruptions and noisy-route pauses; all native
players disable just_audio automatic interruption handling. An interruption
resumes only if its captured transport generation is still current, so a user
Pause or new selection during it is retained. System media-button toggles also
use the interrupted play intent, so Pause during focus loss cannot become Play.
Ducking and volume restoration have the same handler owner.

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
running beside it. It was deferred on 2026-10-04 so that the 1.5.0 seek fixes
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
acknowledges a selection before network startup ends. just_audio keeps
`playing` true after the last song ends, so the handler records the
transition into `completed` (when it is not continuing into unloaded songs)
and publishes playback as paused until Play, a seek or any other processing
state. The UI, headset button and system controls then show Play, and one
press restarts the queue. Only the transition counts, because the desktop
backend can keep reporting `completed` while a restarted song plays.

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
Radio URLs likewise remain in handler-owned station state, including after
now-playing metadata refreshes; radio startup failure messages contain only
the stream host.
Cover art reaches the system as a local file: `PlaybackArtCache` caches the
current cover on Android, Linux and Windows (`artCacheFile` extra), MPRIS
publishes it as `file://` and SMTC loads it with `StorageFile`. The Windows
bridge publishes a local file URI; the Dart SMTC adapter converts it to a
backslash path (`StorageFile` rejects forward slashes with
`0x800700A1`) named for the image type (`typedSystemArtFile`: the cache names
every cover `.jpg`, and Windows picks the decoder by extension, so a PNG cover
showed no image); either mistake leaves the overlay without a cover. Windows
never receives an HTTP(S) thumbnail. Remote art without a cached song cover
(radio included) loads through `GuardedSystemArtworkLoader` and the shared
`coverArtCacheManagerProvider`, using the same feature-tagged key and headers
as `ExternalArtworkImage` for radio. The loader checks the current policy
before cache access and after completion; the file service checks dispatch
and redirects. External radio art requires `radio.nowPlaying` and the artwork
host's service, and master off permits no external requests. The bridge keeps
one artwork fetch active, coalesces pending changes to the latest item and
ignores completions superseded by a station, track, artwork or policy change.
Refused or failed loads retain text metadata with no thumbnail and are not
retried on every timeline tick. Unchanged title, artist, album and local
thumbnail do not invoke native metadata updates; playback and timeline writes
can repeat. A failed native apply remains retryable. Other media sessions may
publish credential-free radio artwork URLs (`uriCarriesCredentials`).
On Android, `RealTimeProjectionAudioHandler` maps
every credential-bearing `artUri` it publishes (metadata, the queue window,
browse, search and `getMediaItem` results) through `AndroidSystemArt` to
`content://<applicationId>.artwork/cover/<key>`, served read-only by the
exported `NavisArtworkProvider` from the same cache. Keys are the first 32 hex
characters of HMAC-SHA256 over the cover ID, with a random 32-byte per-install
secret persisted in app support storage and loaded before media-service setup.
The provider accepts exactly 32 lowercase hex characters, so other apps cannot
probe known cover IDs. Old cache filenames are ignored through a `navis_art_v2_` file prefix. Android
Auto can open these URIs from its own process. The content URI is published only once the cover
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
position from `positionStream` and detects seek discontinuities there, including
while paused, emitting `Seeked` in track-time microseconds. A handler seek's
pending target suppresses intermediate timeline and snapshot jumps; clearing
that target at settlement emits one signal when the same track reached it.
Successive seeks remain independent without a debounce timer. Same-track checks
prevent track changes from being reported as seeks; MPRIS commands suppress
automatic detection while seeking and emit one explicit signal. Windows SMTC
coalesces routine timeline updates to about one per second and sends track
changes and seek discontinuities immediately. The Windows runner assigns `com.navis.app.navis` before Flutter
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
the same partial cache file.

Both decks use `handleInterruptions: false`: Navis owns interruption/noisy
handling for the session. The vendored Android ExoPlayer always applies audio
attributes with `handleAudioFocus=false`; `audio_session` shares a single,
idempotent Android focus request, so starting the incoming deck does not request
competing focus or pause the outgoing deck. Genuine OS interruptions still
cancel the fade and pause both decks.

The cellular gate introduced by `331311eb` (mobile data optimization) now applies
to opening a remote incoming source, rather than disabling all crossfade. The
runtime setting keeps the user's crossfade intent and passes
`crossfadeAllowStreaming=false` on cellular. A fade resolves its target through
the existing source resolver with streaming forbidden: permanent download →
completed rolling cache → refusal. The inactive deck holds only that local
song during the overlap, so remote neighbours cannot be prefetched by the
second player. At handoff it inserts/appends the rest of the queue using the
existing prepared-source cloning path, preserving the incoming position and
occurrence. One shared load deadline bounds the entire handoff preparation,
including row lookup, source resolution and native queue edits. Failure restores
the outgoing deck, and token checks reject late preparation results. A remote
target keeps the ordinary single-deck transition and
reports `crossfade.disabledReason=cellular`. Cellular gapless/preload policy is
unchanged; a setting-disabled fade reports `disabledReason=setting`.

The play lifetime Future is observed for failures without awaiting playback
completion. The existing fade timer waits for incoming `playing` and `ready`
before reducing the outgoing volume, serializes and awaits volume writes, and
uses the shared ReplayGain/user-volume/ducking base for each song. Mute and
volume changes preserve ramp proportions. Each awaited fade write rechecks the
current volume base before advancing, so an intervening mute or duck cannot be
overwritten by the old base. If a swap is superseded while listener cancellation
awaits, the unchanged active deck regains its listeners unless the handler is
disposing. Play/ramp failures log, increment phase counters, retain a credential-free `lastFailure`, cancel the incoming
deck and restore the outgoing volume for sequential fallback. This establishes
player state, not audible output: physical-device listening remains necessary.

Crossfade starts after pending seeks settle. Normal crossfade with Repeat One
prepares that same materialised queue entry on
the inactive deck at position zero, overlaps the ending and fresh start, then
uses the existing deck handoff and listener rebinding. The queue occurrence,
metadata and repeat mode stay the same; position and media-session state switch
to the incoming deck and the new position is persisted. Each completed
self-handoff starts one new scrobble/play-history session, while prewarming or
cancellation does not; the outgoing session's submission threshold is checked
before the fade begins. Smart mode never self-crossfades under Repeat One,
even without album metadata. Songs shorter than twice the fade duration loop
natively, and changing to Smart or leaving Repeat One cancels a pending
self-crossfade. A native wrap that wins the race with preparation cancels that
fade and leaves the next ending eligible; preparation time is deducted from
the wait to the self-fade boundary. Repeat Off/All retain their existing
next-entry and wrap rules.

Queue edits do not wait for a fade, so the deck
is checked by content, not length: before a fade the deck is loaded unless it
holds exactly the materialised queue (song ids, canonical ids matching); an
edit that lands while it loads makes it load once more, and a second change
degrades that transition to gapless (`prewarm_failed`). Prewarming has the
load deadline; a timeout retires only the inactive deck so a late native load
cannot take over, while the active queue keeps playing sequentially. The
incoming deck must still hold the queue, at the next song, when the fade
starts, and still hold
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
inactive deck length and match, outcome counts by phase, `disabledReason`,
`lastFailure`, and active `outgoing`/`incoming` deck maps with `playing`,
`volume`, `positionMs`), `queueLane` (the
running work's kind and age, and the waiting kinds) and `recovery` (the stage
of the latest seek or stall recovery). The native order is read from each
source's `MediaItem` tag, or for an Android lock-cached stream, which is built
before its `MediaItem` and carries no tag, from its stream URL's `id`
(`navisNativeSourceSongId`).

Windows and Linux playback wrappers share a private base that delegates the
playback, startup-observer and batch-editor contracts without wrapping streams.
Each public wrapper owns its platform bridge. Teardown begins delegate cleanup
immediately, disposes the bridge, then awaits handler disposal.

On Android and iOS, audio_service is initialized once per process with a
`SwitchAudioHandler`. Each session attaches a new real-time projection and
playback handler to that registration. Teardown switches the service to an idle
handler and closes the old projection's subscriptions and streams, so reconnecting
in the same process can bootstrap playback again.
Session teardown also clears the abandoned bootstrap future and attempt gate.
Saving an authenticated session restarts an existing bootstrap controller; a
normal playback request can also initialize a fresh handler without a forced
retry. The stopped bootstrap state remains failed until either request.

Handler teardown starts full cleanup synchronously through `beginTeardown`;
`disposeHandler` awaits the same cached future, including decks, artwork,
sidecar, subscriptions, browse notifications and owned stream controllers.

Startup waits for cache maintenance before restoring or synthesizing a queue,
so stale partial-file cleanup cannot race a new lock-cache download. If the OS
sends duplicate Play requests while the queue is empty, they share pending
preparation; the newest Play restarts it if superseded work left no playable
queue. Only the latest transport intent may admit fallback. Load ownership is
captured after saved restoration's own generation changes, so an unavailable
large queue can still fall back. Recent, liked and radio fallbacks honor the
Play intent through the existing queue-loading path and start playback. Before
admission they recheck the originating transport generation, play intent and load
ownership. Radio carries that guard through its recommendation fetch; a newer
Pause or Stop discards the unadmitted fallback. After provisional admission,
startup-selection ownership and queue-loading play intent guard later awaits.

Now Playing receives a handler-owned `TransportVisualCue` for every manual
Previous/Next outcome, regardless of whether it originated from touch, swipe,
keyboard, headset, or an external media session. Successful manual changes use
a 220 ms clean artwork handoff: the previous cover drops away, the new cover
settles without lateral travel, and metadata fades upward only after artwork
settles. Automatic advances use a short non-directional focus fade.
Previous restarts the first queue song even within three seconds when there
is no previous entry; Repeat All retains its wrap to the last entry. Both
in-app navigation and the previous-action rules restart at that edge.
Restart-current and unavailable-edge requests retain the same artwork and use
one small dynamic-color edge pulse rather than a floating icon; no UI animation
delays audio transport. Reduced motion applies direct state changes with
accessible feedback only. The clone-only presentation API can drive these
states without starting audio or modifying a queue.

### Sync Flow

Android library-sync and download notifications resolve localized strings through
callbacks only when a notification is about to be shown, after Android runtime and
progress-throttle checks. They use the current app language override, otherwise
the platform language, with English fallback. Constructing the notification
collaborators does not read locale settings or open the database for localization.

1. Callers submit a `LibrarySyncRequest` through the coordinator-facing
   `LibrarySyncEngine.requestSync` interface. This immutable request carries
   origin, intent, target, and an ephemeral network grant shared by
   planning, admission, and execution. Priority, coalescing identity, interaction
   policy, circuit probing, and diagnostics-history intent derive from those
   fields; the durable contract version is stamped at history insertion.
   The request distinguishes automatic catalog checks, manual catalog checks,
   Repair Library, target hydration, and auxiliary refreshes.
   `LibrarySyncPlanner` selects the smallest safe plan: probe, targeted
   hydration, delta reconciliation, catalog snapshot, compatibility audit, or
   full repair. The scheduler admits one immutable `SyncExecutionPlan` per
   run, including its endpoint allowlist and data/concurrency budget.
2. `AdaptiveLibrarySyncCoordinator` serializes runs. The `library_sync_work`
   table is the durable queue for deduplication, cooldowns, checkpoints, and
   resume; the run request/attempt/outcome tables are diagnostics history,
   retaining the chosen plan and redacted terminal result alongside the work
   queue. The coordinator restores interrupted attempts. Its
   `SyncPlanExecutor` receives the selected immutable plan directly through
   `executeSyncPlan`. `DriftLibrarySyncEngine` implements only that executor
   contract: catalog execution requires a plan, whose kind and request intent
   determine repair, discovery, audit, or hydration continuation. Freshness
   gating belongs to the coordinator, and catalog runs never absorb auxiliary
   refreshes. Recovery and execution share lease acquisition, write fencing,
   and release; execution alone adds the periodic heartbeat. Endpoint aliases
   live on `SyncEndpoint`. One `LibrarySyncPlanKind` selects planning and
   execution budgets; only the diagnostics-history boundary maps its durable
   work names to the older stored plan indices and diagnostics labels.
   Planning derives conditional-index support directly from the active server
   capabilities JSON, without a state-table provider-profile mirror. A backend
   fingerprint change discards the old Navis sync capabilities, durable work,
   and candidate state while preserving provider capability metadata. Replanning
   to another coalescing key completes the superseded request as `skipped`;
   terminal completion is idempotent for shared waiters. Execution requests
   retain their ephemeral network grant. Durable inserts stamp the contract
   version and leave the legacy grant, priority, target identifier, and resume
   lineage columns at neutral values; no persisted coalescing key restores
   network consent.
   The coordinator deduplicates durable work, measures
   requests/bytes, and owns cooldown/circuit policy. Targeted work
   keys are namespaced by entity kind, so equal server IDs in different
   domains remain independent. The coordinator removes that namespace before
   passing an entity ID to a hydrator or server endpoint. Sync work
   uses one pure `librarySyncWorkAllowed` gate at planning, work selection,
   admission, and live request boundaries. Automatic broad work defers while
   Navis is backgrounded or playing. Queued manual discovery retains its
   explicit intent when an automatic foreground pass resumes it, including
   during playback. Its durable checkpoint restores intent, never a network
   grant: metered admission needs permission from the current request. The
   constrained Android background executor may run while hidden when playback
   is idle. Before creating its Flutter engine, the native worker probes the
   same-process audio_service session and records `deferredPlayback` when its
   processing state is non-idle, including paused sessions. It returns success
   so the next periodic dispatch can try again. During a pass, the headless
   policy tracker polls `isPlaybackActive` on the background-sync channel every
   two seconds; coordinator and engine gates read that cached flag. Hard probes
   retain their existing playback exemption at these gates. An unavailable
   playback probe conservatively defers work. Sync Settings presents the
   `deferredPlayback` outcome as "deferred playback", and diagnostics retains
   that bounded category. An explicit user refresh may resume queued broad work
   in the foreground, including during playback. Explicit catalog and auxiliary
   work continues if the app is then hidden, including with current mobile-data
   grants. Automatic visibility/playback gates and the idle-only hidden Android
   worker limit still apply. Interactive entity hydration can
   run during foreground playback; hidden foreground execution defers it,
   retaining the former request-scope visibility limit. Engine checkpoints
   use the admitted request scope's live policy, so a paused queue's current
   song ID cannot veto an otherwise eligible automatic pass.
   `LibrarySyncController` also coalesces overlapping app-level requests onto
   one terminal result, so setup, startup, user, and reconnect callers cannot
   mistake an in-flight state for a failed sync. A pull to refresh on the
   Library tabs and the Liked "see all" pages starts its sync through
   `triggerLibrarySyncFromPull` (`library_sync_provider.dart`), which returns
   once the controller reports running or failed (at most 800 ms) so the pull
   spinner does not stay for the whole sync; progress and failures show in
   `LibrarySyncStatusBanner`, which those Liked pages show too. Home and these
   Library pulls also start a policy-gated, forced app update check without
   waiting for it; Library shows a notice only when an update is available
   (see Update Checker). Artist detail
   uses `RefreshIndicator.noSpinner` because its own header shows the refresh.
   One startup task owns the pass
   through session resets; epoch checks reject stale completion, and engine
   readiness schedules a successor only after that task drains. Pending durable
   work resumes only through the configured automatic interval or an explicit action; there
   is no short continuation timer. A queued full repair is the exception: it
   remains resumable but dormant until an explicit Repair Library action, never
   a startup, reconnect, resume, periodic pass, or Check for updates. Resume
   re-arms the periodic timer for at most one due staleness check; it never
   also schedules a startup pass. A startup or periodic caller also treats a
   not-yet-constructed credential-backed engine as pending rather than failure, then restarts its startup pass once the
   engine is available. When an explicit Check for updates reaches a deliberate
   page, entity, request, byte, or duration limit after doing work, it returns
   `partial` and preserves its checkpoint for the next pass. The same limit on
   automatic work remains `deferred`; offline, metered, playback, and
   background policy gates always remain `deferred`.
   Pending album details downgrade a successful catalog run to `partial` and
   withhold its catalog timestamp only when they block freshness. Albums whose
   incomplete server-detail classification still matches their current metadata
   do not block; other failures and unclassified pending work still do.
3. Reliable providers use conditional `getIndexes(ifModifiedSince)` as a cheap
   automatic check. The response is a conditional artist index, not a change
   feed, so its cursor advances only after every candidate and blocking
   hydration completes. Server-incomplete album details do not withhold the
   cursor after full promotion, hydration-only continuation, or incremental
   verification. Hard probes restore persisted freshness and classify the
   current pending albums against the same durable evidence, so unchanged
   probes preserve the Sync Settings server-incomplete notice. The next manual
   check can therefore use the saved cursor instead of restarting a full artist audit. An explicit refresh is not
   freshness-gated: it runs bounded
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
   waits for an unmetered connection, the user disabling the unmetered-only
   setting, or one-time mobile-data consent for broad discovery. Discrepant
   on-server albums use ordinary song hydration and identity/cache reconciliation, so a new album does not wait
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
   catalog snapshot can carry forward locally verified songs only when its plan
   permits the bulk-song endpoint and the candidate's core album metadata and
   expected song count exactly match. Explicit Repair Library always hydrates
   the remaining albums authoritatively instead of carrying their songs forward.
   New, changed, or incomplete albums remain on the authoritative `getAlbum`
   fallback.
   Hydration progress advances only after an album has been written and marked
   hydrated; albums merely observed in a bulk search page are not presented as
   complete. Library shows hydration progress only while a run is active.
   Between runs the remaining backlog (`pendingHydrationCount`) appears as a
   status line in Sync settings, worded as a server-data problem when
   `onlyIncompleteAlbumDetails` says every pending album returned incomplete
   details with evidence matching their current metadata. The server-scoped
   `capabilitiesJson` Navis namespace stores `libraryIncompleteAlbumEvidence`,
   an album-ID-to-fingerprint map encoded as JSON. Fingerprints use the same
   name, artist ID/name, song count, duration, and cover art fields as song
   hydration change detection. Only non-conflicting incomplete responses add
   entries. Unchanged, unattempted albums retain them across runs; a new detail
   attempt revokes its entry before requesting data. Hydration, 404, transient,
   conflict, fatal, or interrupted attempts leave it revoked unless a new
   non-conflicting incomplete response is observed. Metadata changes, hydrated
   rows, and catalog removals invalidate entries when the pending set is read.
   Capability writes merge into the latest server JSON through the engine's
   existing helper. Classification is separate from transport, 404,
   authentication, network, and budget failures. Identity or track-membership
   conflicts are marked as conflicting snapshots by album validation and still
   block verification.
   Such server-incomplete albums stay in `pendingHydrationCount`
   and are retried on later eligible runs, but do not block current freshness,
   sync timestamps, or the artist-index cursor. A Library notice would never
   clear, because runs are budgeted and
   such albums stay pending. Catalog discovery remains indeterminate because
   its page total is an estimate and does not share a stable denominator with
   song hydration.
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
   Concurrency backs off by two workers after a batch with a 429/5xx, timeout,
   connection error, or transport retry.
   Multi-album detail batches yield during song-row conversion while keeping
   reconciliation and identity matching on the complete fetched batch.
6. The transport interceptor owns at most one immediate idempotent retry and
   honors `Retry-After`. Durable work owns later attempts with exponential
   cooldown. Three consecutive failures open the endpoint circuit; user and
   interaction requests may probe it early. The request contract retains resume
   and reconnect origins that also allow an early probe, but the foreground
   controller currently submits startup, reconnect, and scheduled checks with
   the timer origin. Resume only re-arms the periodic timer. These automatic
   passes respect the circuit cooldown. The cooldown is exposed
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
   Album Queue applies to every song list the same way: a tap queues the
   whole list from that row when it is on and plays only that song when it is
   off. The shared helpers in `play_song_in_collection.dart`
   (`playSongInCollection`, `playTableSongInCollection`,
   `playSongIdInCollection`) hold that rule for Trending and "This Is" rows
   (index among the resolved songs; unresolved rows do not play), Home Most
   Played, Recently Played and the desktop album list, album and playlist
   detail rows, Artist Top Tracks, weekly playlists and Downloads. Liked lists
   keep their own `shouldQueueLikedPlayback` rule (Album Queue and Liked
   Queue), and Play, Shuffle, search results and the song context menu's
   "Play now" keep their own behaviour. Downloads "Play now" follows Album
   Queue, like its row taps.
9. With **Background Sync Only on Unmetered Networks** enabled and no broad
   mobile-data grant, fresh metered automation is a hard probe: one conditional
   `getIndexes` request with retries disabled. Turning that setting off permits
   ordinary automatic delta work on cellular or metered Wi-Fi. A current bounded
   mobile-data grant also permits queued automatic delta work; fresh automatic
   planning with only that bounded grant still selects a probe. Automatic
   playback and visibility limits remain in force. Interactive artist/album/playlist
   hydration remains allowed with 16 MiB/response and 32 MiB/interaction budgets.
   Enumeration, audits, starred and playlist-header sync, pending broad
   hydration, and Repair Library stay deferred unless the user grants an
   ephemeral one-time mobile-data override or disables the unmetered-only
   setting. Live network policy is re-checked at page and hydration boundaries;
   a transition to a restricted metered connection without a current grant
   checkpoints and returns `deferred`. Cancellation returns work to the queue.
10. Starred content and playlist headers are independent auxiliary targets.
    Catalog checks and repairs do not update them as incidental executor work;
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
    `library_sync_state.lastAuxiliarySyncedAt` column: the coordinator
    advances it from completed starred/playlist-header work rows, independently
    of catalog execution. The retired per-server capabilities-JSON timestamp
    is no longer read or written. The catalog circuit breaker does not
    suppress these independent endpoints.
    Genres are not synchronized: there is no genre target, endpoint or stored
    genre data (see "Genres are not a Navis concept").
    Starred reconciliation
    excludes queued local star/unstar actions until they reach the server.
    Favorites, ratings, artwork revisions, and identity reference updates
    announce update-only Drift writes, avoiding delete-cascade invalidation
    of dependent tables.
    Playlist headers upsert without replacing parent rows, so an unchanged
    header refresh cannot cascade-delete cached membership. The authoritative
    header list prunes confirmed server deletions and queues new, count-changed,
    or metadata-changed playlist contents for resumable targeted hydration.
    Explicit favorites include referenced external/provisional identities while
    ordinary library enumeration remains canonical. Best-effort detail
    hydration of incomplete starred songs stops at the first non-successful
    album result and shares the outer run’s cancellation and transport state;
    cancellation still terminates the enclosing sync. Sync requests use
    per-request cancel tokens, held only while in flight, so completed responses
    are not retained. Targeted operations share
    one terminal-state runner that clears active hydration on every result.
    Album and playlist budget or incomplete-detail stops retain one pending
    hydration. Auxiliary policy and response-budget stops report deferred;
    malformed or incomplete auxiliary snapshots still fail.
    Membership in a starred snapshot counts as a favorite even when its optional
    timestamp is absent.
    Eligible automatic catalog checks inspect at most two newest-album pages
    each configured due interval, even with an unchanged artist cursor; manual
    checks inspect at most five. A recorded discovery-debt streak
    (`libraryDiscoveryDebtStreak`, persisted per server when a check hits its
    page cap without ever reaching known, unchanged content) keeps the probe
    on schedule and widens the admitted automatic delta-reconciliation budget
    to five pages until known content is reached, retaining the same request,
    byte, duration, and hydration limits; a streak past the escalation threshold
    (`discoveryDebtEscalationStreak`) hands deep discovery to a queued delta
    reconciliation. Automatic discovery defers during playback or
    hidden foreground execution; fresh metered automation without background
    permission or a broad grant remains a hard probe.
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
  `retainOrRemoveServerSongs`. Album deletion and detail reconciliation use
  that same chunked retention path. Retained rows keep their cache files; only
  removed rows release file paths, which the caller deletes after its outer
  transaction commits. An isolated media-fetch 404/410 during a
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
  evidence and local mutation journals. If the canonical song already has a
  download-queue entry, remapping discards the old identity’s queue entries and
  keeps the canonical entry intact; otherwise it moves the old entries. It
  writes the typed `entity_identity_aliases` table, shared across profiles.
  Schema 94 imports legacy song aliases as authoritative over typed song
  conflicts, keeps the newest remaining alias per entity type and old ID,
  clears song alias profile ownership, enforces that key, and removes the
  legacy song alias table; sign-out and data reset clear
  typed aliases. Cache and download ownership validation is storage-kind aware: Android SAF content URIs are
  validated through the platform bridge, never `File.exists()`. Identity
  remapping preserves every cache-row column, including storage kind; rolling
  cache pruning also recognizes content URIs even on legacy filesystem rows.
- **Album/artist relinking.** Candidate staging tables carry
  `release_mbid`/`artist_mbid` (schema 80) promoted from OpenSubsonic
  `musicBrainzId` fields; `EntityIdentityReconciler` runs inside the
  promotion transaction after rows are preserved and before stale-row
  deletion, and maps albums/artists only from a unique stable MBID on both
  sides or an unambiguous song-membership mapping with compatible metadata.
  Song, album and artist MBIDs share whitespace trimming and case normalization.
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
  Settings. The settings action and authenticated diagnostics `/v1/sync/repair`
  route both enter through `LibrarySyncController.repairLibrary`. The coordinator
  owns an in-memory repair session whose mobile-data grant is applied at
  admission — before planning or durable work is joined — and survives retries
  and reconnects within the run. The grant is never persisted: completion, cancellation, sign-out, account change, and app
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
  the sync controller's deduplicated targeted requests under the coordinator
  lease so widgets retry the resulting cover identity. A server cover whose
  load times out is also retried by
  `CoverArtImage` itself, once per cache key after
  `kCoverArtTimeoutRetryDelay`, instead of keeping its placeholder until the
  page is reopened; a second timeout keeps the placeholder (external artwork
  is not retried). Changing the cover identity cancels a pending retry, as
  does removing the widget.

### Cache Flow

The shared cover-art manager strips URL user info and Subsonic authentication
parameters before passing URLs and default URL keys to `flutter_cache_manager`.
Its guarded HTTP service signs only the active server's exact cover endpoint
with current credentials, after queue admission and before dispatch. URLs for
other origins or paths never receive server authentication. AudioService uses the
same request-time signing through the current API accessor for HTTP session art
on iOS/macOS. HTTPS redirects to HTTP are refused. Riverpod owns both the shared
`navis_cover_art_cache_v2` and AudioService's `navis_system_artwork_cache_v2`
managers. Startup removes both old JSON/SQLite repositories (including temporary
and journal files) and their old image directories under temporary storage.
The v3 completion marker is written only after all cleanup succeeds, so profiles
which ran the earlier v2 metadata-only cleanup also receive the complete purge.
Ordinary artwork is refetched; permanent download artwork remains in its separate
durable store. Both keep-data and full sign-out, server-data reset, library-cache
reset, and Settings “clear covers” clear both managers. Cover storage accounting
sums both current directories without following links. Desktop diagnostics clones
use the same cache keys below their redirected `<root>/cache` temporary directory,
so the managers and storage accounting share the isolated artwork folders.
External artwork display and radio Now Playing prewarm share
`externalArtworkImageProvider`, wrapped by
`boundedDecode` with a 1024×1024 fit bound. Both edges are capped without
upscaling, and display reuses the prewarmed decode without an image fade. The
HTTP file service rejects a declared body larger than 20 MiB and aborts when
streamed bytes exceed that limit, including chunked, redirected and discarded
bodies. It uses the existing forced transport reset to stop an oversized body,
records an error outcome, and releases the coordinator slot.

Cover loads reuse `CoverArtLoadCoordinator`: four active slots, with one
reserved for critical artwork and three shared slots. Background work occupies
at most two shared slots, leaving room for an on-screen cover. `CoverArtImage`
registers visible interest only for actual viewport overlap (or visibility
notification); cards in its one-screen preload window register background
interest. Interest uses the HTTP request key (`coverArtImageCacheKey(id, size)`),
without the disk-cache revision, so targeted revision covers receive the same
priority and cancellation. A queued request created with live interest is
cancelled when its last interest leaves, including background preloads;
uninterested warmups retain their existing lifetime. In-flight requests finish.
Track-change Now Playing visual prewarm is background; the displayed Now
Playing cover retains critical priority.

Server-provided file extensions use a shared ASCII alphanumeric allowlist (1–10
characters, otherwise `bin`). Rolling audio and SAF staging filenames hash song
identities; generated native paths must stay inside their root. Permanent
download naming throws when all 100 collision candidates are occupied.

1. Playback starts → on Android/iOS `LockCachingAudioSource` writes the
   consumed stream into the rolling cache without a second download. Desktop
   (media_kit) cannot seek that proxy, so it streams over HTTPS while a
   sidecar download fills the rolling cache: each uncached track is fetched
   twice (a FLAC is typically 25–50 MB, and transcoding runs twice on the
   server). This is a deliberate cost of seekable desktop playback.
2. After flushing and publishing the complete file →
   `RollingCacheManager.registerTrack()`. The mobile lock-cache source emits
   100% only after closing its write sink and renaming `.part` into place.
   A small file that
   holds a Subsonic error document is deleted instead of registered: Navidrome
   answers a stream it cannot serve with HTTP 200 and that document, and
   playback prefers the rolling cache over streaming, so keeping it would fail
   the song until eviction. Startup pruning removes such entries left by older
   builds, and the desktop sidecar refuses HTML, JSON and XML responses before
   writing anything.
3. Rolling registration checks and writes under one database transaction,
   so a concurrent permanent download cannot be downgraded to rolling.
   Cache manager reads the current budget and enforces it via LRU eviction
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
   only persisted, owned `*.navis-part` files from a custom folder without
   following links; folder scans ignore them. Promoting a rolling-cache file reuses an
   existing destination only when its size matches. Resetting server data (a full
   sign-out or server switch) removes the library rows but deletes only
   Navis-owned audio files; files inside the custom folder and Android SAF
   documents stay where they are.
   Leaving a custom folder follows the same rule. Turning it off (after a
   confirmation when a folder is configured) or choosing a different folder
   moves only downloads stored in Navis's own directory. Every file in the
   folder being left, filesystem or SAF, stays where it is under its own name,
   whether Navis downloaded or
   adopted it; Navis records no difference between the two. Navis forgets
   reachable `cached_tracks` rows before the setting changes, so startup
   normalization never moves them out later. Unavailable roots and missing or
   inaccessible files keep their records and bytes. With custom storage off,
   startup repair and normalization operate only inside the app-owned `audio`
   directory; retained user-folder references neither get deleted nor hold the
   app-storage queue, even after a restart. The folder's sidecar remains,
   so choosing that folder again re-adopts the files through the usual scan.
   That scan runs before the switch, so the import checks registration again
   when it commits: a file whose song lost its download in the switch is
   adopted rather than skipped as already registered. Choosing the active
   folder again moves nothing. Files count as inside the new folder through
   any spelling of its path or theirs, links resolved.
   Android uses a persisted Storage Access Framework tree URI rather than a
   filesystem path. A folder that a version before 1.2.8 stored as a plain
   path is turned off at startup under the same leaving rule: Navis forgets
   reachable downloads inside it before the setting changes and leaves the
   files where they are, and choosing the folder again as an Android folder
   runs the usual scan. The cached-track storage kind distinguishes Android SAF
   document locators from ordinary filesystem entries; SAF reads, writes,
   relocation, deletion, and offline playback go through the Android
   ContentResolver bridge and never overwrite unmanaged documents. Before a
   tree is activated Navis proves it can create, write, and remove a temporary
   Navis-owned probe document; a provider that fails that check remains
   unselected.
   The native bridge attempts to persist read/write grants before that probe.
   A `SecurityException` from a non-persistable grant is logged and leaves
   usability to the writable probe, including for app-owned diagnostics trees.
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
   any script match) instead of normalizing the whole library. The caller
   refreshes first, and title lookup accepts only the current key version and
   unchanged raw metadata, excluding stale entries. FLAC
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
9. Playback prefers completed permanent downloads unconditionally → eligible
   rolling cache → stream. Only rolling entries are filtered by the active
   streaming profile; Cached First, cellular cache preference, and offline
   playback permit any completed rolling profile.
10. Every app major/minor version change renews committed library and recoverable
   rolling-cache metadata through the mandatory full-screen rebuild. Patch
   releases keep the same epoch; legacy cache markers also require renewal.
   Fresh profiles without a committed catalog adopt the current epoch without
   a reset, and first setup stamps it when catalog readiness is recorded.
   **Repair Library** is the
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
   first login, cache upgrade, Settings cache reset, and playback recovery; ordinary
   Repair Library runs in the background from Sync Settings. It blocks ordinary
   navigation until the catalog is committed, keeps users in place with retry,
   metered-data, and sign-out recovery options on failure, and only then opens
   Home. `LibraryCacheResetService` deliberately preserves permanent downloads
   and their files; the upgrade marker is written only after that full scan.
   The reset keeps exactly the song rows referenced by `play_queue_items`,
   their albums, and artists referenced by those songs or albums. Queue items
   cascade on song deletion; retained songs and parents become provisional.
   On-server songs awaiting reconfirmation also receive `pendingRebuild`
   catalog availability, excluding them from normal search even with queue or
   download references. This is distinct from isolated-404 suspicion, which
   remains searchable. Saved queue occurrences and playback state stay in the
   database throughout the rebuild, including failed scans and process restarts;
   live queue clears, edits, and shuffle persistence use their existing paths.
   No snapshot, post-scan restoration, or schema change is needed. Authoritative
   sync force-applies re-observed provisional song and parent metadata by ID,
   including ratings and explicit null values, and clears availability/provisional
   markers. Provisional albums cannot carry old songs forward as authoritative
   hydration. Unresolved candidate albums defer absence confirmation until
   hydrated. Missing queued songs follow normal reconciliation: they are retained
   as confirmed-missing with `serverDeletedAt` regardless of parent IDs, and
   excluded from normal library selection. Existing playback source resolution
   prunes an unavailable retained song and its saved queue occurrences when no
   permanent download remains. An empty queue still clears the whole library.

### Download quality, concurrency and artwork

**Quality preference.** Every download action calls `requestDownloadQuality`
(`download_quality_sheet.dart`); single-song menus share
`downloadSongWithQualityPrompt` (picker, enqueue, queued notice). It reads the saved preference from the
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
its real extension and bitrate. HTML, JSON and XML responses fail immediately
as `notAudio` and are never registered. Originals with a response Content-Length
must have exactly that many bytes before publication. Transcodes may carry an
estimated length, so only non-empty content and the same audio content-type
gate are required.
Empty or short original files fail as `truncated`; part files are deleted and
the whole song restarts from zero on retry. Interrupted transfers are never
resumed.

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
(5 s × 2^retry, capped at three retries, in memory; a restart retries at once)
before the pump starts it again, and `markForRetry` notifies queue watchers.
`processQueuedDownloads` completes once no worker is running. The Android
progress notification aggregates every transfer in flight.

**Failure reasons and connectivity.** Schema 103 adds nullable `failure_reason`
(a `DownloadFailureReason` name), `failure_detail` (short sanitized status/byte
counts), and `finish_journal` to `download_queue`. `from102To103` uses guarded
column additions; shipped schema 102 is unchanged. The Downloads failed rows,
DownloadNotifier failure body and download diagnostics expose the reason.
A write-time storage/access failure also posts one held-download notification
with its reason when the hold starts.
Manual Retry and Retry all reset reasons and attempts; starting a retry clears
its prior reason, and success removes the queue row. HTTP 404/410 (`notFound`)
and error documents (`notAudio`) fail immediately without backoff; HTTP 5xx,
network/timeout errors and truncation use the existing bounded backoff. The
existing `networkTypeProvider` listener pumps the same service when connectivity
returns. Offline queues have zero workers, and failures observed after a
connection loss return to queued without increasing attempts. HTTP 401/403 and
filesystem permission loss hold the queue for an explicit repair action.

**Capacity and storage holds.** Each worker checks destination free bytes
against the song size for originals or duration × bitrate / 8 for transcodes,
plus 10% and a 16 MiB margin. Capacity reservations share the existing serialized
finish gate so concurrent workers cannot spend the same free bytes. Album and
playlist enqueue estimates only newly queued songs; insufficient room issues
one notice through the existing folder-notice stream. Native capacity queries
use StatFs on Android, filesystem attributes on Apple targets (with a bundled
DiskSpace/E174.1 privacy reason), statvfs on Linux and GetDiskFreeSpaceExW on
Windows. Unavailable capacity reports are skipped; write-time storage errors
still hold work. SAF provider write/probe exhaustion is held separately from
private staging exhaustion. Automatic rechecks never clear a provider hold
from staging free space: provider capacity is unknown, so an explicit storage
repair/resume is required to try again. A repeated provider failure holds again.
SAF providers cannot report free space through the current
bridge: only the app-private staging filesystem is checked, and provider
ENOSPC/EDQUOT is handled on write. `noSpace` extends DownloadFolderProblem and
the same Downloads banner, cancellation and five-second storage recheck.
Preflight holds allow already admitted transfers to finish; write-time
exhaustion cancels active transfers. The hold
returns items to queued with `noSpace`, without burning retries or failing each
remaining song. Freeing space or choosing storage resumes the existing queue.

Original-response length validation compares `Content-Length` only for
unencoded/identity bodies: native Dio decompresses gzip, so encoded wire
length does not describe stored audio. Empty decoded payloads still fail,
and native transport/decompression errors still retry without registration.

**Recoverable finish and cleanup.** After integrity validation, the queue row
journals the destination, verified size/digest, format/bitrate and optional SAF
tree/relative path before rename/upload. Identity tags may change bytes, so the
intent is updated before SAF upload or registration. After publication it
records the published phase and exact locator returned by the provider.
Once the final file exists, cache upsert and queue removal commit together in
the existing DAO transaction.
Startup replays journaled final files only when size and digest agree; missing
or invalid files are requeued, and part files always restart from zero. Missing
permanent-cache files are requeued when library metadata still permits a
server download. Filesystem absence requires an explicit missing-path errno;
`stat`/`exists` can hide access failures and do not authorize record removal.
Permission and I/O failures retain permanent records, including local-only
songs, and finish intents until storage returns. Startup repair completes
before workers start. Deferred recovery belongs to the service lifecycle:
teardown invalidates its generation and awaits it before server data can be
cleared. Reconciliation checks the generation after
storage waits and inside registration transactions to reject stale writes.
Unknown custom-folder audio has no finish intent and is left to the explicit
adoption/rescan flow.
Before a transfer creates its part file, the existing queue journal records
its exact path. Custom-root cleanup requires that persisted ownership and does
not follow links. Unowned suffix files are preserved and logged. SAF trees are
never swept for suffix files; only app-private SAF staging parts are removed.
Finish journals name a part only while verifying the actual part file; updates
after rename never infer another part pathname. SAF uploads retain the existing
document MIME type and provider capability contract. The bridge checks the
copied byte count and removes its own document on a write error; startup verifies
a journaled upload's digest. Mismatching destinations are preserved and logged:
an intended pathname or a previous publication does not prove ownership of
replacement contents. Conflict journals retain the path for the orphan sweep
until the queue starts a new transfer.
Native write errors retain errno
classification. No provider rename capability is required.
The app-owned orphan sweep runs after journal reconciliation and protects
pending journal paths. Playback priority remains permanent download → rolling
cache → stream.

**Custom-folder configuration holds.** `PermanentDownloadPathResolver` requires
an existing custom filesystem root and probes it with a disposable Navis-owned
write; it never recreates a missing mount. Unset, missing and inaccessible
roots report `DownloadFolderUnavailableException` / `DownloadFolderProblem`.
`DownloadService` checks the destination before queue workers and rolling-cache
promotion; Android trees use the existing `AndroidSafStorage.validateWritableTree`
bridge to check persisted access and safe replacement. Permission loss during a
transfer is also a configuration hold, including filesystem errors wrapped by
Dio. Workers return to `queued` without increasing retry counts or scheduling
backoff; other transient transfer failures retain the existing backoff.
A no-space hold clears when no queued items remain, even while offline or
paused; unset, missing and inaccessible folder problems persist with an empty
queue. The service exposes hold changes through `downloadFolderProblemProvider`,
and Downloads shows the existing filled-card notice pattern with **Choose folder**
and **Use app storage** actions across tabs. Both reuse the same picker,
confirmation and app-lifetime `CustomDownloadFolderController` as Settings.
**Use app storage** skips confirmation when the configured path is unset or
blank. Disabling custom storage does not require the previous root to be
writable or even present: relocation uses it only as a pruning boundary,
preserves unreachable records, commits app storage, and resumes the held queue.
Cancelling the picker preserves the previous setting; a chosen folder is saved
only after validation and relocation, with path/kind/enablement committed in a
transaction. Folder setting changes and explicit queue processing recheck access
and resume work when usable. A held root is also probed every five seconds so
reconnected storage or restored access resumes automatically, without retrying
transfers or incrementing failure counts. A permission failure below a writable
root requires an explicit folder action; a root probe cannot establish its repair. One app notice is emitted per unresolved hold when
a download is requested (`downloadFolderNoticeProvider`, consumed by the shell);
startup detection alone does not issue that notice. Holds are rederived at
startup and require no database schema change.

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
`docs/development/development-workflow.md`).

- Never load the whole songs table to pick a few rows. Use bounded DAO queries
  (`getSongsSorted`, `getRandomSongs`, `getSongsByIds`) or SQL aggregates.
- Local song search runs against `song_search_text`, a derived index of each
  song's normalized title, artist, and album. A row is current only while its
  `source` column equals the song's raw fields, so no song write path needs to
  maintain it: stale or missing rows are normalized by the search itself and
  rewritten by `scheduleSongSearchIndexRefresh`, which also runs from deferred
  startup maintenance. Normalization keeps letters and numbers from every script
  and folds Latin diacritics and common Arabic letter variants. The SQL
  prefilter requires each query token as an in-order subsequence, which every
  ranked match (exact, prefix, substring, token, fuzzy) satisfies, so ranking is
  unchanged. Since schema 87 each row also stores `match_title`, `match_artist`,
  and `match_album` in the `normalizeMetadata` form (rows without them count as
  stale). The `source` ends with `metadataKeyVersion`, so rows keyed by an older
  normalizer are stale for track matching and the same lazy refresh re-keys
  them; no migration is needed when the normalizer changes. Key version 3 folds
  half-width kana and composes dakuten/handakuten in both search text and
  matching keys. Search reads accept every key version (including pre-versioned
  sources) while raw metadata is unchanged, avoiding per-keystroke normalization
  of the whole library on the UI isolate. The background refresh still re-keys
  old rows, including `\u001f1` sources; old folding behavior remains until it
  finishes. Search returns ranked song rows before scheduling the stale-row
  check on the event queue; that check is skipped while a shared refresh runs,
  and failures are logged. Key version 4 repairs featured credits in square
  brackets and unclosed-bracket handling. `getTrackMatchCandidates` selects only
  songs that could match a list of external tracks (artist top songs,
  ListenBrainz recommendations) under `LocalTrackMatchSnapshot` rules: equal
  title keys, or artist keys that are equal, contain or are contained, or share
  a word. Artist keys shorter than two Unicode characters require equality in
  both the DAO and snapshot fallback. A snapshot built from those makes the same
  matches as one built from the whole library. Snapshot construction yields
  every 500 rows during candidate normalization and title indexing. Its artist
  fallback lazily caches rune lengths and multi-rune token sets per distinct
  normalized artist, tests each artist once per query, and filters the original
  candidate list to preserve row order. The DAO's artist rules are tested in
  `Isolate.run` with plain string keys and seed keys/tokens, once per distinct
  `match_artist` key (indexed, like `match_title`), not once per song. SQL stays
  unchanged, and matching songs are read through the two key indexes. Raw
  candidate rows are mapped to `SongsTableData` in order, yielding between
  chunks of `kLocalTrackMatcherSnapshotYieldChunkSize` (500), so large results
  do not block the UI isolate for the entire mapping pass;
  `debugTrackMatchCandidatesByFullScan` keeps the per-song query as the test
  reference. Candidate selection starts a refresh only when stale rows exist, or
  joins one already running, and waits at most two seconds. Fresh indexes
  trigger no refresh writes. Normalization runs in an isolate; a slow refresh
  keeps running in the background while matching includes safe stale-row
  candidates, as it does for concurrent changes or failed writes.
- Matching external metadata (Last.fm, ListenBrainz, LRCLIB, Subsonic
  search) to library songs, albums and artists uses two keys from
  `lib/src/utils/metadata_normalization.dart`. `normalizeMetadata` is the
  fuzzy key: it folds full-width ASCII, half-width kana and the ideographic
  space, composes kana voicing marks, and folds case, Latin
  diacritics and Arabic letter variants, drops parenthesized qualifiers and
  featured credits, and keeps letters and digits of every script, so
  Japanese, Korean, Arabic and accented titles get real keys.
  `normalizeMetadataKeepingEdition` is the same but keeps bracketed and
  " - " qualifiers. A bracket starting with "feat" or "ft" is a featured
  credit and is dropped; the trailing featuring rule applies only outside
  closed brackets (unclosed brackets do not mask credits), preserving
  locations such as "(Live at Ft. Worth)". "Wonder" and
  "Wonder (Japanese Version)" share a
  fuzzy key but not an edition key. Mastering and packaging qualifiers
  (remasters, bare years, deluxe/anniversary editions, explicit/clean,
  mono/stereo, album/single/original version, bonus track) are not
  editions and are dropped from it. Matchers (`pickBestTrackMatch`, Same
  Vibes mapping, LRCLIB, the exact library lookups behind player metadata
  navigation) prefer the candidate whose edition key equals the expected
  one. Same Vibes applies its minimum score before edition/availability
  tie-breaks. Within a matching edition, album navigation with artist context
  prefers an exact raw name, then the smallest id. Song navigation uses that
  tie-break only when candidates share a nonempty artist ID or album ID, so
  mastering duplicates stay usable. Name-only song namesakes across different
  identities and unfiltered edition ties return no match and leave navigation
  to the search fallback.
  Candidate edition keys are computed once on first access.
  `pickBestTrackMatch` drops another edition only when a passing
  same-edition candidate has at least as good artist and album scores, and
  never when that would turn a unique match ambiguous. Radio recording
  identity uses the edition key without spaces, computed once per song per
  batch. Changing `normalizeMetadata`
  output requires bumping `metadataKeyVersion`. Last.fm validates both its
  resolved artist and per-track credits with this Unicode-aware fuzzy key, so
  unrelated CJK names are rejected and Latin accents fold consistently. Empty
  normalized keys fall back to trimmed, case-insensitive raw equality,
  preserving symbol-only artists such as "!!!".
- Related-artist links and name-based artist navigation share a cached
  `LibraryArtistNameIndex`, invalidated by artist-table updates. Exact keys are
  tried first; a miss uses `looseArtistKey` to find candidates but links only
  one exact normalized candidate name. Loose comparison folds punctuation to
  word boundaries, preserves the word sequence, and permits a leading article or
  "&"/"and" difference. Joining or splitting words requires album corroboration
  in the Deezer resolver; "Black Star" cannot link "Blackstar" without that
  evidence. Bracketed words remain significant in loose links: "The Streets
  (UK)" may link "Streets UK", but cannot link "Streets". Different leading
  articles never match. Navigation requires one row on both exact and loose
  paths; duplicate rows are ambiguous. Related links may select the
  server/more-albums/id preference among duplicate rows of the single matching
  name group.
- The artist page reads its albums through `album_artist_index`, a derived table
  of each album's artist keys (`i:<id>` for the album artist and each credit,
  `n:<normalized name>` for a name-only album artist and each credited name),
  current only while its `source` equals the album's raw artist id, name, and
  credits plus `metadataKeyVersion`. Readers repair stale rows before querying,
  so no album write path maintains it. `watchArtistAlbumBuckets` re-reads only
  the artist's candidate albums (plus albums of the artist's songs) at most four
  times a second, classifies them with the same rules as before, and emits only
  changes; `getArtistPlaybackSnapshot` uses the same candidates.
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
  in-memory temp storage, and a 64 MiB WAL size limit. Each connection waits
  for a held lock through a Dart busy handler bounded at 5 s (10 ms sleeps on
  Drift's database isolate) instead of `PRAGMA busy_timeout`: SQLite's
  `nanosleep` wait is cut short by the Dart profiler's SIGPROF in debug and
  profile builds on Linux (and by the same mechanism Android), so it gave up
  within about 30 ms, and
  the pragma would replace the handler. Deferred startup
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
`docs/development/development-workflow.md` from a clean isolated state.

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

Ownership and hand-off. A live lease blocks every other acquirer except one
case: a `foreground` acquirer takes over a live `androidWorker` lease (the SQL
condition in `acquireExecutionLease`), so opening the app never waits for a
background pass. Foreground against foreground, and a worker against anyone,
still get `leaseHeld` until expiry. Whenever an acquire replaces another token
(preemption or expiry; not a clean release, which deletes the row, nor a
same-token re-acquire), the same transaction requeues that server's `running`
work rows (checkpoint, attempt count, `not_before` and error type unchanged),
returns `running` run requests to `queued` and marks their attempts
`recovered`. The fenced-out owner's next write throws `SyncLeaseLostException`,
its heartbeat cancels transport, and it reports `leaseHeld`; `completeSyncRun`
ignores a recovered attempt and never lets a caller without an attempt finish
a request someone else is running, so the old owner cannot write a shared
request's outcome. The new owner continues from committed progress: page
checkpoints, the resumable candidate generation (boundary pages re-verified),
`applying` promotion, and pending-hydration markers. A foreground coordinator
that has not yet recovered this process takes over in its recovery step and
resumes the requeued catalog work in the same request; an already-recovered one
plans first, runs its own plan, and the requeued catalog work runs on the next
catalog check. An acquire that times out on another connection's writer lock
(for example a long worker promotion) is reported as `leaseHeld`, not as a
failed run.

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
check completion (including its durable next-deadline write), timer-arm and
schedule-reset tasks, persisted-state loading, and Android schedule reconciliation
before returning. Cancellation suppresses automatic rearming and Android
reconciliation until the session's existing restart path enables them again.
Sign-out then cancels native Android work before clearing server data and
credentials. The drained controller forgets its scheduled profile, so the later
config-null notification does not launch a second cancellation status write.
Sync-state upserts, including automatic deadlines and Android worker/scheduler
observations, select an existing server parent in the same SQL statement; a late
write for a deleted server is a no-op. Diagnostics shutdown and sign-out use this
barrier before database disposal or profile deletion; synchronous provider
disposal alone cannot await these owners.

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
