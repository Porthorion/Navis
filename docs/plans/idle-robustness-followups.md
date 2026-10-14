# Idle robustness follow-ups — 1.5.1

Status: findings 4, 5, 7, 8, 10 to 14, and the worker hand-off are completed
for release/1.5. Android acceptance evidence is recorded in the progress log.
Remaining 1.5.1 items are listed at the end of this document.
These originated in the read-only idle audit on 2026-10-14. They are not part
of `fix/startup-hang` acceptance. The startup audit records the current work:
[Android startup investigation](../audits/startup-hang-2026-10-14.md).

## 4. Service destruction with a surviving engine

**Completed for 1.5.0 — 2026-10-14.** Android now declares the app-owned
`NavisAudioService` subclass and redirects the plugin's explicit binding and
foreground start to it. Service creation repairs a missing listener when the
plugin still has a handler, then republishes metadata, queue and playback state.
The workaround uses one guarded reflection method, without plugin removal or
engine reattachment.

The JVM contract checks both private field names and listener types; projection
regressions cover republishing unchanged state. Android service-only recreation
preserved the process and Flutter engine, and media-session Pause/Play/Next
worked afterward. See [completion evidence](../project/progress.md#current-focus).

## 5. Failed database opening poisons later retries

**Completed for 1.5.0 — 2026-10-15.** Only the app
engine migrates the database. The Android worker first reads `user_version`
through `NavisDatabase.schemaUpgradePending` and, for any version other than
the current one (older, newer or unreadable) or a missing file, returns
`deferredUpgrade` before any provider read or status write, so it never opens
or migrates. It then runs each period until the app has migrated once. The
regression is `background engines defer while the app has not migrated the
schema`; the worker wiring is one guarded statement that `databaseOverride`
bypasses in tests.

**5b:** the app's database opens through a reopening executor. A
`SQLITE_BUSY`/`SQLITE_LOCKED` failure while opening or migrating discards the
executor, together with Drift's cached error, and opens a fresh connection, up
to three attempts. The executor is replaced before the last rethrow, so a
later query opens again. Other errors are unchanged, and the file is never
reset. Schema upgrades now commit in one transaction with `user_version`, so
a reopen reruns an interrupted upgrade from the old schema (`an upgrade that
fails part-way leaves the old schema and data intact`). Regressions: `a lock held past the busy deadline during open recovers
without restart`, `an upgrade interrupted by a lock reruns safely` and `only
SQLite lock errors count as lock timeouts`. **Busy wait (fixed for 1.5.0):** `PRAGMA busy_timeout` did not wait in
debug and profile builds on Linux, including host tests, and by the same
signal mechanism on Android (not checked on a device). SQLite
sleeps with `nanosleep` and does not resume after `EINTR`. The Dart VM
profiler's SIGPROF therefore cut each sleep short, and the wait gave up within
about 30 ms. The same program waits the full time with `--no-profiler` and as
an AOT release build. Every platform ships the same precompiled `sqlite3`
3.6.0 binary. `_configureNativeDatabase` now installs a Dart busy handler
bounded at 5 s, and both `busy_timeout` pragmas are removed, because the pragma
would replace the handler. Regressions: `a write waits while another
connection holds the lock` and `a lock held past the busy bound fails within
it`.

**Original finding — likelihood:** medium for writer contention, low for simultaneous upgrades.
Worker and foreground open separate WAL connections. WAL permits readers but
only one writer. A migration/index/open operation can exceed the five-second
busy timeout; Drift then caches that executor's opening failure. Later queries
reuse it even after the lock disappears. The sync lease and write fence protect
catalog ownership, not database opening or migration. SQLite opening failures
are not transient-provider retries; audio credential retries keep the executor.

Inspect `lib/src/database/navis_database.dart`, `provider_retry.dart` and
Drift's opening state. Hold a writer/schema lock beyond the busy deadline while
cold-opening a disposable profile, release it and retry without restarting.
Also overlap two first opens against an older disposable schema. Serialize
migration/open-time schema work across engines and replace a failed executor
for classified transient opening failures. Preserve migrations and fencing;
never reset a real database to repair an opening failure.

## 7. Rolling-cache fetch deadlines and recovery ordering

**Completed for 1.5.0 — 2026-10-14.** Vendored just_audio origin/range fetches
have cancellable 15-second connection/header deadlines and a 30-second
body-progress deadline. Failed partial files are discarded and a fresh fetch
can proceed. Playback shares resume's bounded network reconciliation before
spending a reload retry and keeps the selected song, position and play intent
while offline. Android captures the native error position before publishing
idle state, avoiding recovery from a stale ready-event position. Reconciliation
reads the current metering future after
connectivity settles; scoped listeners keep these checks active without UI
listeners. Verified recovery re-arms the retry allowance for a later outage.

Regressions cover connection/header/body stalls, cancellation, fresh fetches,
paused provider listeners, metering replacement, native error fields, repeated
outages and position retention. A JVM regression exercises the real native error
bridge with a 97-second player position and a stale 42-second ready event.
Android airplane-mode evidence is summarized in
[completion evidence](../project/progress.md#current-focus).

## 8. Denied audio focus cached as acquired

**Completed for 1.5.0 — 2026-10-14.** Vendored just_audio abandons a denied
focus request before retrying, makes up to three attempts and completes denied
Play with a typed exception. Navis silently retries the user's current Play
intent with a 1–8 second backoff. Pause, Stop, selection, headphone removal and
disposal cancel it; phone interruptions block retry until they end. A late
denial cannot abandon focus acquired by a newer Play.

Regressions cover cached denial, completion, cancellation, interruptions and
superseded activation. Android's clone-only denial fixture recorded the denial,
released focus and resumed the same advancing song automatically. See
[completion evidence](../project/progress.md#current-focus).

## 10. Worker lease left by process death or freezing

**Completed for 1.5.0 — 2026-10-15.** A due automatic check that returns
`leaseHeld` now persists its next deadline at the foreign lease's expiry (plus
five seconds, never sooner than 30 seconds or later than the normal cadence)
instead of a full interval later; the existing durable-deadline timer re-arms
from it. The native worker timeout now sends the same bounded Dart `cancel`
checkpoint as WorkManager cancellation before engine teardown, so a timed-out
run drains and releases its lease where it can. Regressions: `a lease-held
automatic check retries at lease expiry, not a full interval later` and the
instrumented `realWorkerSendsCancelCheckpointWhenItsRunTimesOut` (compiled but
not run; the single runtime pass covers it).

**Worker hand-off — 2026-10-15 (branch `fix/idle-handoff`).** Opening the app
now takes over a running worker instead of waiting for its lease: a
`foreground` acquire preempts a live `androidWorker` lease, and any takeover
(preemption or expiry) requeues the previous owner's running work, run requests
and attempts in the acquire transaction. This also fixes rows left `running`
after a plain expiry takeover in a process that had already recovered.
`completeSyncRun` now accepts only a still-running attempt, and a caller without
an attempt cannot finish a running request, so the fenced-out worker can no
longer write the shared request's outcome. A lease acquire that times out on a
database lock counts as `leaseHeld`. The foreground continues from committed
progress (page checkpoints, the resumable candidate generation, pending
hydration); there is no new persistence. Foreground against foreground is
unchanged (`leaseHeld`). Regressions: the `worker hand-off` groups in
`library_sync_dao_test.dart`, `sync_write_fence_test.dart` and
`library_sync_regression_test.dart`, the rewritten F09 tests, and the provider
and worker-entrypoint tests. The emulator runtime pass is still pending.

**Original finding — likelihood:** medium. A killed worker or frozen heartbeat leaves the durable
ten-minute lease. Foreground work reports `leaseHeld`; treating that as a
completed automatic check can advance the normal cadence beyond lease expiry.
Opening during a worker does not hand off or cancel its work. Fencing prevents
late old-owner writes, but the native timeout path destroys the engine without
the same explicit Dart cancellation checkpoint as WorkManager cancellation.

Inspect `adaptive_library_sync_coordinator.dart`, `library_sync_provider.dart`
and `NavisBackgroundSyncWorker.kt`. Interrupt a due worker after lease
acquisition, reopen immediately and after expiry. Schedule lease-contention
recovery at expiry rather than normal cadence, and checkpoint timeout
cancellation where possible. Preserve lease fencing and bounded transactions.

## 11. Pending credential reads and memory-only saves

**Completed for 1.5.0 — 2026-10-14.** Secure-storage reads and writes now run
through one serialized, deadline-bounded queue shared by the auth and the
ListenBrainz token stores: a stuck platform channel surfaces as
`CredentialReadException` (unavailable) instead of hanging startup or reading
as a missing password, and the queue waits for a stuck call to settle rather
than overlapping it (a permanently hung plugin makes later calls time out as
unavailable. At startup the 5 s Restart Navis recovery covers that; a plugin that first hangs mid-session leaves credential actions timing out until the app restarts). Failed saves retry with backoff; on Android, where durable persistence
is required, a save that never lands throws instead of declaring a login from
engine-local memory, so a cold start finds no falsely authenticated profile.
Desktop keeps the documented keychain fallback. Routing keeps an initial
config error in the loading phase instead of mapping it to unauthenticated.
Recovery events are recorded once per process in the private startup timeline.
Cross-engine serialization (foreground plus headless worker writing the same
keystore) still needs native work and remains open.

**Likelihood:** low for false sign-in, medium for persistent storage failure.
A failed password save can still allow login through an engine-local memory
fallback. Process death loses it; the worker also has separate memory. A later
successful read of a missing password marks the durable profile signed out.
Thrown reads now retain the session as `CredentialReadException`, disable
`resetOnError` and retry, but a never-completing read has no storage deadline.
The router maps an initial config error to unauthenticated, although the overlay
does not infer sign-out from loading/error. Separate engines have their own
secure-storage workers and no shared initialization/migration transaction.

Inspect `secure_credential_store.dart`, `server_config_repository.dart` and
`session_route_provider.dart`. Inject save failure then cold restart; separately
inject missing, throwing and indefinitely pending reads. Reboot/lock/overlapping
workers characterize real keystore behavior but do not deterministically inject
it. Require durable Android credential persistence before declaring durable
login, bound reads, distinguish unavailable from missing credentials and
serialize native credential initialization/migration.

## 12. ListenBrainz storage failure drops queued events

**Completed for 1.5.0 — 2026-10-14.** An external token read that fails or
hangs now propagates as `CredentialReadException` (bounded by the same kind
of read deadline) instead of returning null. Scrobble dispatch treats an
unreadable token as possibly active, never as absent: ListenBrainz listens
stay queued with backoff, Subsonic delivery continues, and entries are
dropped only for confirmed absence, explicit disabling or an invalid token.
ListenBrainz feedback and the passive token readers defer instead of failing.

**Likelihood:** medium conditional on credential-read failure. External token
storage converts failures into null. With ListenBrainz alone, a resumed flush
can clear the queue; with Subsonic enabled, a ListenBrainz entry can be considered
delivered because its credentials appear absent. This does not sign out the
Subsonic profile.

Inspect `external_scrobble_credentials.dart` and `scrobble_service.dart`.
Queue offline listens and inject a token-read platform exception immediately
before resumed dispatch. Propagate unavailability and defer delivery. Drop
entries only for explicit disabling/removal or confirmed invalid credentials.

## 13. Personal-radio retry exhaustion survives reconnection

**Completed for 1.5.0 — 2026-10-14.** Verified reachability recovery re-arms an
exhausted Personal Radio refill without replacing recommendation-session
ownership. Transient station failures retain the station and reconnect through
the existing queue lane with bounded backoff. Newer user commands cancel the
pending recovery; a new Play while older reconciliation finishes re-arms the
latest request.

A deterministic regression exhausts all five refill attempts and verifies a
successful refill in the same session after recovery. Station regressions cover
native error data and newer Stop/Pause/replacement commands. Android verifies
reconnect and Stop-during-outage with a finite Subsonic stream in radio mode;
Linux's existing stream diagnostic verifies ICY metadata and normal radio
playback/Stop. Live broadcast outage and physical head-unit checks remain
outside this evidence. See [completion evidence](../project/progress.md#current-focus).

## 14. Several overdue subsystems resume together

**14a completed for 1.5.0 — 2026-10-15.** Radio metadata allows one Azuracast
poll in flight per station generation, so a slow response after an unfreeze or
on a poor network no longer stacks later ticks; a station switch, stop or policy
change still polls immediately. Regressions: `a slow Azuracast response never
overlaps the next poll` and `a station switch is not blocked by the previous
station's slow poll`.

**14b completed for 1.5.0 — 2026-10-15.** Downloads and scrobbles wait for the
single-flight resume reconciliation (`networkReconcilingProvider`) through the
existing `readIsOnline` and `readReachable` gates, so a failure during that
window keeps its retry budget and saved scrobble deadlines are untouched. A hard
15-second bound clears the hold on its own and records a `resumeReachability`
timeout in the startup timeline; each service is kicked once when the hold ends.
Regressions: `a stuck reconciliation releases downloads and scrobbles after the
bound`, `reconciliation holds new work and kicks exactly once when it ends` and
`a throwing reconciliation still clears the hold`.

**14c completed for 1.5.0 — 2026-10-15.** New download workers yield while a
network song is loading: `downloadServiceProvider` passes the existing
`playerStateProvider`'s loading flag and song id to
`DownloadService.yieldToPlayback`, which holds new admissions for at most 15
seconds once per track and re-pumps when loading ends. Running workers are never
cancelled and radio never holds downloads. Regressions: `new downloads wait
while a song loads and start when it is ready`, `a stuck loading state releases
downloads after the hold limit`, `a rebuffer of the same track does not hold
again` and `radio buffering never holds downloads` (plus the guard `playback
loading never cancels a running download`).

**Original finding — likelihood:** medium for contention. Doze can release due download retries,
scrobble dispatch, playback watchdogs, radio polling and sync close together.
There is no evidence that every missed periodic timer tick is replayed. Sync
already cancels its background timer and re-arms one durable deadline; scrobbles
have an overlap guard, while radio metadata polling has no equivalent guard.

Inspect `scrobble_service.dart`, `download_service.dart`,
`radio_metadata_service.dart` and `main.dart`. Arrange pending downloads/listens
and a radio/refill session, force idle, change networking, then reopen promptly.
Coalesce overdue work after resume reconciliation, prioritize interactive
playback and allow only one polling request in flight. Retain durable deadlines
and backoff rather than resetting all subsystems.

## Paused playback wake-lock limitation (finding 9)

Paused queues now permit sync, but audio_service's pause wake-lock release is
coupled to foreground demotion. `androidStopForegroundOnPause: false` preserves
the existing media-service lifetime. Its wake lock and release method are
private; no supported independent release exists without changing/vendoring
that plugin. Do not use reflection or alter service retention to release it.
Evaluate an upstream fix or a separately reviewed dependency patch in 1.5.1.

## Acceptance

Each remaining follow-up needs a focused regression, authoritative affected-platform
runtime evidence and `./tool/check.sh`. Record actual symptoms and ordering;
source-supported races are not proof of the owner's overnight trigger. Keep
fixtures private and disposable, and keep credentials and media identities out
of startup details.
