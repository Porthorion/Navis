# Android Background Sync Recovery Plan

**Status:** internal implementation exists; public enablement is blocked on the
closure work and physical-device certification below
**Owner:** Navis library-sync architecture  
**Last reviewed:** 2026-08-13
**Related:** [sync-reliability-recovery-plan.md](sync-reliability-recovery-plan.md)

## Decision

Implement Android automatic library sync with a native **WorkManager** bridge
that invokes a deliberately minimal, headless Dart sync entrypoint. Keep the
existing Dart planner, coordinator, durable work queue, candidate promotion,
cooldown, and operation ledger as the sole sync domain implementation.

Do **not** use an in-app `Timer`, an exact alarm, an implicit network receiver,
or a permanently running foreground service as the background scheduler.

WorkManager is the Android-recommended persistent scheduler for periodic data
sync. It survives normal process death and device reboot, applies network and
power constraints, and is explicitly intended for work that must complete
after the visible app exits. It is opportunistic, not an exact clock: periodic
work has a minimum 15-minute interval and may be delayed by Doze, quotas, or
other system constraints. [Android task scheduling](https://developer.android.com/develop/background-work/background-tasks/persistent), [periodic work requests](https://developer.android.com/develop/background-work/background-tasks/persistent/getting-started/define-work)

## Current implementation and why it is not certified

The original in-process timer is still deliberately cancelled when the app
backgrounds. That is correct: it is only the foreground convenience timer, not
an Android executor. The current internal build now also has a WorkManager
bridge: `AndroidBackgroundSyncScheduler`, `NavisBackgroundSyncWorker`, and the
retained `navisBackgroundSyncEntrypoint`. It uses unique periodic `UPDATE`, a
separate unique `KEEP` catch-up request, an opaque profile key, a headless
Flutter engine, and the existing database execution lease.

That is necessary architecture, but it is not proof that background sync works
on a real phone. The capability is still disabled by default through
`NAVIS_ENABLE_ANDROID_BACKGROUND_SYNC`; no physical-device matrix has certified
process death, reboot, constraints, or cancellation. It must not be described
as fixed for release users yet.

The earlier quiet failure has also changed shape rather than disappeared:

1. `configurePeriodic()` and `enqueueCatchup()` return `scheduled`/
   `enqueued` immediately after calling WorkManager. They do not await the
   returned `Operation`, so a native enqueue failure can be persisted as a
   false success.
2. The worker maps an engine-ready timeout or any unclassified Kotlin exception
   to `Result.retry()` without a durable terminal category. The last persisted
   state can therefore remain `running`, while the user sees only a later
   WorkManager retry.
3. The headless runner snapshots connectivity and metering once, then passes a
   constant policy callback to a potentially long sync. A Wi-Fi-to-cellular
   transition after worker start can therefore violate the intended live
   background policy until the pass ends.
4. `AudioManager.isMusicActive()` reports device-wide audio, not Navis-owned
   playback. It can defer Navis because another app is playing, and it cannot
   prove that Navis itself is inactive after a process restart.
5. Native coverage is only JVM-level scheduling/result-mapping tests. It does
   not instantiate WorkManager with `WorkManagerTestInitHelper`, drive a
   `TestDriver`, run a headless Flutter engine, or verify a device after Navis
   is swiped away/killed.

Android's own guidance is the reason these are release blockers: WorkManager
is persistent and constraint-aware, but execution is eventual and a regular
worker has a ten-minute execution ceiling. Its returned `Operation` is the
acknowledgement that enqueueing completed; treating the call itself as success
removes the only reliable observation point. [WorkManager API](https://developer.android.com/reference/androidx/work/WorkManager.html),
[updating enqueued work](https://developer.android.com/develop/background-work/background-tasks/persistent/how-to/update-work)

## Studied closure register (2026-08-13)

This is the source of truth for the remaining Android work. P0 items block
enabling the feature outside internal builds; P1 items block calling it
diagnosable and predictable; P2 items improve supportability after launch.

| Priority | Finding in current code | Required correction | Evidence required before closure |
| --- | --- | --- | --- |
| P0 | Native scheduling methods report success before the `Operation` completes. | Make channel scheduling asynchronous/off-main and await the WorkManager `Operation`. Persist `platformFailure` with a safe reason when it fails; do not overwrite a known-good schedule until the replacement is acknowledged. | Android integration test injects an enqueue failure and asserts the durable state is not `scheduled`; device diagnostics agrees with WorkManager. |
| P0 | Timeout and catch-all Kotlin failure return `retry` but do not durably record what happened. | Define a native outcome hand-off that survives a Dart/bootstrap failure (redacted `Data` output or a small native persisted record read during reconciliation). On timeout, record `engineTimeout`; on cancellation/system stop, record `stoppedBySystem`; cap bootstrap retry attempts and record the cap. | Force ready timeout, Dart channel failure, and cancellation; reopening Navis shows the correct durable category, attempt count, and no stale `running` state. |
| P0 | Headless policy is captured once before `requestSync`. | Supply a live policy reader that re-checks connectivity plus native metering at each coordinator/engine gate. If policy becomes ineligible, checkpoint/defer without continuing broad work. | Start unmetered, switch to metered during a controllable pass, and prove no additional broad endpoint calls occur after the transition. |
| P0 | No instrumented Worker or physical-device certification exists. | Move/add `work-testing` under `androidTestImplementation`; add tests using `WorkManagerTestInitHelper`/`TestDriver` for periodic delay, constraints, `UPDATE`, `KEEP`, retry, and cancellation. Then run the full physical-device matrix below. | Test artifacts plus authenticated app API, WorkManager state, DB state, logs, and an inspected Settings screenshot from Android 12, 14, and target-SDK hardware. |
| P1 | `isMusicActive()` is global-device audio, not Navis playback state. | Replace it with a durable Navis-owned playback-session marker written by the playback service, or classify it as `foreignAudioActive` and allow the normal planner/lease decision. Never label a foreign app as Navis playback. | Test with another audio app active and with Navis active; the recorded defer reason distinguishes both cases. |
| P1 | Periodic and catch-up requests have different unique names. Both can boot a headless engine at once; the DB lease prevents catalog corruption but not needless engine/bootstrap work. | Add a very early durable dispatch gate before engine bootstrap, or make catch-up consult the periodic work state and skip when a current periodic dispatch is already running. Keep the database lease as the final authority. | Trigger both names concurrently and prove one engine reaches Dart, one clear `leaseHeld`/`alreadyDispatching` outcome, and no duplicated endpoints. |
| P1 | Status reads `LiveData` with a two-second observer/latch and maps finished work to `none`. | Prefer a suspend/future WorkManager query off the main thread, retain the latest terminal native state/output and generation, and expose a bounded `statusUnavailable` rather than silently treating timeout as no work. | Simulated delayed/unavailable query leaves the last durable outcome intact and records `statusUnavailable`; Settings and diagnostics agree. |
| P2 | The eight-minute Dart timeout is intentionally below WorkManager's ten-minute regular-worker ceiling, but no measured budget protects shutdown/checkpoint time on slow devices. | Add stage deadlines and a watchdog budget: stop new catalog work before the native deadline, checkpoint, then report a durable timed-out/deferred result. Do not make ordinary metadata sync a foreground service. | Slow-network/device test completes checkpoint and engine disposal before WorkManager stop; no forced service or battery-optimization exemption is requested. |
| P2 | The feature flag is compile-time and only says enabled/disabled in durable state. | Preserve the conservative flag for rollout, but add a build/channel-visible capability reason and an internal kill switch that cancels native work on disable. | Toggle in an internal build, verify cancellation, then verify no late old-profile work can touch the new session. |

The test-driver requirement is not cosmetic: Android documents it as the
deterministic way to make constraints and periodic intervals eligible without
waiting in a test. [WorkManager integration testing](https://developer.android.com/develop/background-work/background-tasks/testing/persistent/integration-testing)

### Required implementation order

1. **Make scheduling truthful.** Await native enqueue/cancel operations and
   persist a bounded outcome for every native path before changing settings
   presentation. This removes the current false `scheduled` success.
2. **Make worker death truthful.** Add the native fallback outcome record,
   cancellation handshake, retry cap, and stale-running recovery. A worker
   that cannot start Dart is exactly the case that must still be observable.
3. **Make eligibility live and ownership precise.** Re-read network cost while
   the pass runs; replace the global-audio heuristic; add the early dispatch
   gate. The existing SQLite lease remains the final catalog-write lock.
4. **Prove the bridge under Android's scheduler.** Add instrumented
   WorkManager tests before touching the release flag. Unit tests of names and
   enum mapping are useful, but cannot prove a Worker is eligible, starts, or
   survives process loss.
5. **Certify then roll out gradually.** Run the device matrix, keep the
   feature internal while collecting redacted terminal categories, then enable
   only after the acceptance criteria pass. A user force-stop remains an
   explicit platform limitation, not a bug to paper over.

## Product contract

| Situation | Required behavior |
| --- | --- |
| App visible | Existing controller owns automatic/manual/repair work. No native worker is started for the same run. |
| App backgrounded or process killed | WorkManager may start one bounded automatic pass when its constraints allow. |
| Wi-Fi/unmetered-only enabled | The native request requires `NetworkType.UNMETERED`; no broad download is started on cellular or metered Wi-Fi. |
| User permits background sync on metered data | The request requires `NetworkType.CONNECTED`; the Dart planner still applies byte budgets and durable policy. |
| Manual Check for updates | Runs immediately through the foreground controller. It is never silently converted to a periodic worker. |
| Repair Library | Never auto-resumed by WorkManager. It remains an explicit foreground, confirmation-aware action. |
| Active playback | The worker exits without broad work and records a safe defer reason. Playback never competes with a catalog write. |
| No authenticated session or unavailable secure credential | No network request. Record a redacted terminal reason and await the next app login. |
| User force-stops Navis | Do not promise a background run. Android will not resume app work until the user launches the app again. |

“Background” here is intentionally **eventual**, not “at precisely 10:00.” The
Settings UI must state the next requested cadence and the most recent platform
run/outcome, without claiming that Android guaranteed an exact execution time.

## Target architecture

```mermaid
flowchart LR
  S["Sync settings or login"] --> N["AndroidBackgroundSyncScheduler"]
  N --> W["Unique WorkManager request\nconstraints + periodic cadence"]
  W --> K["NavisBackgroundSyncWorker"]
  K --> E["Headless FlutterEngine\nbackground entrypoint"]
  E --> L["durable SQLite execution lease"]
  L --> C["Existing planner + coordinator + engine"]
  C --> D["catalog/work/state/operation ledger"]
  D --> U["Sync Settings + foreground controller"]
```

### 1. Native scheduler, not a second sync implementation

Add a small Kotlin `AndroidBackgroundSyncScheduler` and a
`NavisBackgroundSyncWorker : CoroutineWorker` under
`android/app/src/main/kotlin/com/navis/app/navis/`.

- Add `androidx.work:work-runtime-ktx` and `androidx.work:work-testing` at a
  pinned current stable version compatible with the repository's Android Gradle
  Plugin and target SDK. Record the selected version in `AGENTS.md` and the
  Android dependency documentation when implementation begins.
- Expose only scheduling/cancellation/status over a narrow method channel:
  `configurePeriodic`, `enqueueCatchup`, `cancel`, and `status`.
- Use a server-profile-derived opaque hash as input and in the unique work
  name. Never pass a server URL, username, password, album, or song ID through
  WorkManager `Data`, notifications, logs, or diagnostics.
- On login, logout, server replacement, interval changes, and the metering
  preference changing, reconcile the native schedule. Logging out or replacing
  a server cancels its native work before credentials/catalog ownership change.

### 2. One unique periodic request per active profile

Use one named periodic request such as
`navis.library.automatic.<opaque-profile-key>.v1`.

- Interval: the selected 15/30/60/120/360/720 minutes. Manual-only (`0`)
  cancels it. Never try to emulate sub-15-minute execution.
- Constraints: `UNMETERED` when the existing setting is enabled; `CONNECTED`
  when the user explicitly permits metered background sync. Do not add
  charging/idle constraints by default because they can starve normal library
  discovery.
- Use `enqueueUniquePeriodicWork(..., UPDATE, request)` when the interval or
  constraints change. `UPDATE` avoids cancelling an already-running worker and
  preserves its enqueue timing; `REPLACE`/`CANCEL_AND_REENQUEUE` would recreate
  the scheduling race that this recovery is intended to remove. [Unique work
  API](https://developer.android.com/reference/androidx/work/WorkManager),
  [periodic UPDATE semantics](https://developer.android.com/reference/androidx/work/ExistingPeriodicWorkPolicy)
- The periodic worker asks the existing planner for an `automatic` catalog
  request. The planner may choose a cheap probe, resumable safe work, or a
  no-op. It must never select full repair automatically.

### 3. One unique catch-up request, only when useful

Use a separate named `OneTimeWorkRequest` only to promptly drain already
durable, eligible automatic work after a relevant local change (for example,
the user enables background sync or changes from metered to unmetered policy).

- Use a distinct unique name and `ExistingWorkPolicy.KEEP` so repeated
  connectivity/settings signals cannot enqueue a storm.
- Apply the same network constraint as periodic work.
- Do not use expedited work for normal catalog polling. It has quotas and is
  intended for user-important work that finishes in a few minutes.
- Do not chain catch-up work behind periodic work: the database lease is the
  cross-process source of serialization.

WorkManager offers named unique work specifically to keep one active instance
of a logical job, but that alone cannot serialize it with the foreground
Flutter controller. [Managing unique work](https://developer.android.com/develop/background-work/background-tasks/persistent/how-to/manage-work)

### 4. Headless Dart entrypoint

Do not start normal `main()` from a Worker: it bootstraps UI, audio, playback,
and presentation services that do not belong in a background metadata pass.

Add a retained, top-level Dart entrypoint such as:

```dart
@pragma('vm:entry-point')
Future<void> navisBackgroundSyncEntrypoint() async { /* no runApp */ }
```

The Worker creates a new `FlutterEngine` (prefer a `FlutterEngineGroup` when a
visible engine exists), registers plugins, starts that entrypoint, sends one
strictly typed `runAutomaticBackgroundSync` command, awaits one terminal result
with a timeout, and destroys its engine in `finally`.

The Dart entrypoint must:

1. call `WidgetsFlutterBinding.ensureInitialized()` but never `runApp()`;
2. create a minimal provider container containing only database, credentials,
   server configuration, network policy, API client, planner/coordinator, and
   network usage reporting;
3. load the active server through the normal repository and obtain credentials
   from the existing encrypted storage plugin—never from Worker input;
4. invoke the exact existing `LibrarySyncRequest.automatic` production path;
5. close the container/database and return only a redacted result code,
   counters, and timing to Kotlin.

Flutter supports independent engines and background Dart execution, but each
engine has independent plugin instances and state. That is why this design
requires plugin registration and a durable database lease rather than relying
on the foreground controller's in-memory `_inFlight` future. [FlutterEngine
API](https://api.flutter.dev/javadoc/io/flutter/embedding/engine/FlutterEngine.html),
[Flutter multi-engine guidance](https://docs.flutter.dev/add-to-app)

### 5. Cross-engine execution lease

Add a schema migration for `library_sync_execution_lease`:

| Field | Purpose |
| --- | --- |
| `server_id` (primary key) | One lease per retained profile. |
| `owner_token` | Random opaque worker/controller identity. |
| `owner_kind` | `foreground` or `androidWorker`; safe diagnostic category only. |
| `started_at`, `heartbeat_at` | Detect abandoned work after a killed process. |
| `expires_at` | Allows recovery after a bounded, conservative stale threshold. |

Acquire/renew/release this lease transactionally through `LibrarySyncDao`.
Every broad catalog execution path—foreground and Android Worker—must acquire
it before planning network work, heartbeat during long runs, and release in a
`finally` block. If another owner holds a fresh lease, the worker records
`leaseHeld` and returns success; its next scheduled opportunity can try again.
It must not run concurrently, spin retries, or steal a non-expired lease.

This is necessary because WorkManager uniqueness covers native work only,
whereas an active Flutter app and a headless Flutter engine can otherwise each
create their own in-memory coordinator.

### 6. One durable result model

Keep domain results in the existing sync tables and operation ledger. Add a
small Android execution record (either a dedicated per-server table or fields
on `library_sync_state`) containing only:

- last native schedule reconciliation time and requested cadence;
- latest WorkManager ID/state/attempt count;
- latest worker started/completed time and duration;
- redacted terminal category: `succeeded`, `noWorkDue`, `deferredPolicy`,
  `leaseHeld`, `credentialUnavailable`, `transientFailure`, `permanentFailure`,
  `stoppedBySystem`;
- safe WorkManager stop reason when available.

Settings should show “Android background sync” separately from the normal
catalog deadline: requested interval, last Android attempt, result/defer reason,
and whether Android is waiting for unmetered connectivity. It must never show
credentials, server identity, raw exceptions, or claim a future OS execution
time as guaranteed.

Use the same bounded redacted diagnostics policy as sync. Android WorkManager
can expose stop reasons and scheduling state; retain those safe categories so
quiet failures become actionable rather than invisible. [WorkManager
diagnostics guidance](https://developer.android.com/blog/posts/deeper-performance-considerations)

## Result and retry rules

| Outcome | Worker result | Durable state |
| --- | --- | --- |
| Planner succeeds, has no work, or safely defers | `success` | Store terminal category; retain coordinator's normal next deadline. |
| Another valid lease is active | `success` | `leaseHeld`; no retry loop. |
| Network constraint not met | WorkManager waits before starting | Show constraint/defer state when observed. |
| Normal transport failure handled by coordinator | `success` | Coordinator persists its own retry/circuit cooldown; do not create a second competing backoff. |
| Worker/engine bootstrap failure before coordinator owns the pass | bounded `retry` | Record safe bootstrap category; cap by WorkManager backoff and surface it. |
| Authentication/credential/schema invariant failure | `failure` or `success` after durable terminal record | Do not retry endlessly; require normal app recovery/login. |
| System stops long worker | let cancellation propagate | Preserve durable work/checkpoints and stop reason; next eligible schedule resumes safely. |

The critical rule is that WorkManager scheduling backoff cannot compete with
`library_sync_state.next_eligible_at`. The coordinator remains the single owner
of sync-domain retry/circuit policy; WorkManager retries only failures that
prevented reaching that owner at all.

## Foreground services, notifications, and battery policy

Normal automatic sync should use regular constrained WorkManager work. Do not
start a foreground service merely to make periodic metadata sync survive.

If a future **user-initiated**, clearly visible operation genuinely exceeds a
worker’s short execution budget, evaluate a foreground/long-running worker
separately, with a truthful notification and the correct Android foreground
service type. Android 12+ restricts starting foreground services from the
background, and Android 14+ requires valid service types; metadata sync is not
a justification to reuse the media-playback service. [Foreground-service
restrictions](https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start),
[Android 14 foreground-service requirements](https://developer.android.com/about/versions/14/behavior-changes-14)

Do not request battery-optimization exemption as a prerequisite for this
feature. WorkManager is designed to cooperate with Doze and system quotas.
Provide a support hint only after recorded, device-specific repeated stops,
never an automatic prompt.

## Delivery sequence

### Phase A — contracts and persistence

1. Add background-sync domain types, the execution lease DAO, Android execution
   status persistence, migrations, and migration tests.
2. Extract a non-UI sync bootstrap factory shared by foreground and headless
   execution. Prove it does not create audio handlers, player state, app shell,
   notifications, or diagnostics HTTP server.
3. Add deterministic DAO/coordinator tests for lease contention, expiry,
   release-on-error, credential absence, and worker result mapping.

### Phase B — native scheduling

1. Add WorkManager dependencies and Kotlin scheduler/worker classes.
2. Implement schedule reconciliation on signed-in session changes and Settings
   changes, using unique periodic `UPDATE` and unique one-time `KEEP`.
3. Add a narrow Android method-channel contract plus unit tests for generated
   interval, network constraint, opaque name, cancellation, and error mapping.
4. Add a debug-only, authenticated app-owned diagnostic observation endpoint;
   it may report redacted native schedule/state but must not schedule work or
   expose sensitive WorkManager input.

### Phase C — headless execution

1. Add the retained Dart entrypoint and strict Worker-to-Dart command/result
   protocol.
2. Register required plugins on the worker engine, including encrypted
   credential storage and path/database support.
3. Wire cancellation from `CoroutineWorker` to Dart/coordinator cancellation,
   then wait for durable checkpoint completion before engine teardown.
4. Enforce the cross-engine lease in every broad execution path.

### Phase D — UI and rollout

1. Present the Android execution status in Sync Settings and the existing
   redacted diagnostics surface.
2. Gate the capability behind a durable Android-only feature flag, default off
   for the first internal build. Preserve current foreground behavior while it
   is off.
3. Enable for internal testers, inspect stop reasons/attempt categories, then
   enable by default only after the physical-device matrix passes.

## Required validation

### Implementation status (2026-08-12)

Phases A–D are implemented behind the durable Android-only internal feature
flag (`NAVIS_ENABLE_ANDROID_BACKGROUND_SYNC=true`): schema v65 adds the
cross-engine lease and redacted execution status; the Android module uses
WorkManager 2.11.2; the Worker launches the retained headless Dart entrypoint;
and Sync Settings renders the requested cadence and latest safe outcome.
Focused Dart/DAO/widget tests and Android scheduler unit tests pass. The
physical-device matrix below remains mandatory before the flag is enabled by
default. The shared `LibrarySyncExecutionBootstrap` now constructs both
foreground and headless production sync pipelines; the headless command also
validates its opaque profile key against the active retained profile before it
can make a request.

Static tests do not prove Android background behavior. Every implementation
iteration must include Linux startup smoke plus Android device validation using
the Android scheduler as the authoritative platform API.

| Scenario | Required evidence |
| --- | --- |
| Schedule creation/update | Android unit test and `WorkManager` test driver assert one named periodic request, correct interval, `UPDATE`, and network constraint. |
| Constraint wait | Test driver holds/releases constraints; device `dumpsys jobscheduler` shows the job’s unmet network condition. |
| App swiped away | Physical device: schedule, leave the app, let WorkManager run, reopen; authenticated app API proves the durable terminal record and local catalog effect. |
| Process death | Kill only Navis’s process, allow the scheduled worker, reopen and assert ledger/state/checkpoints. Do not confuse this with user force-stop. |
| Reboot | Schedule then reboot a test device; verify WorkManager reschedules and one eligible pass completes. |
| Foreground overlap | Begin a foreground sync, trigger worker, prove exactly one lease owner and no duplicate endpoint calls/catalog mutation. |
| Metered Wi-Fi/cellular | Verify `UNMETERED` worker does not run; allow the explicit setting and verify bounded `CONNECTED` behavior. |
| Playback and repair | Verify background worker defers during playback and never resumes a pending repair. |
| Cancellation/system stop | Force a test stop reason; prove durable work/checkpoints survive and the next attempt is bounded. |
| Visual handoff | On reopening, capture and inspect Sync Settings through the app-owned screenshot API; it must show the native attempt/defer/outcome and no clipping. |

Use WorkManager’s test driver for deterministic constraints/delay/stop cases,
and Android Studio Background Task Inspector plus `adb shell dumpsys
jobscheduler` for device diagnosis. [WorkManager TestDriver](https://developer.android.com/reference/androidx/work/testing/TestDriver), [Background Task Inspector guidance](https://developer.android.com/blog/posts/deeper-performance-considerations)

## Acceptance criteria

The Android background-sync issue is fixed only when all are true:

1. A signed-in Android device has one durable, correctly constrained native
   schedule per active server profile.
2. A normal app background/process-death path can complete one safe automatic
   pass without reopening Navis first.
3. The worker never duplicates a foreground run, resumes a repair, bypasses
   candidate confirmation, or mutates the catalog without the same operation
   ledger guarantees as foreground sync.
4. Metered restrictions, secure credential unavailability, system stops, and
   authentication failures are visible as safe durable categories—not silent
   failures.
5. Physical-device tests cover at least Android 12, Android 14, and the
   current target-SDK device image; the app API, native scheduler state,
   persisted effects, logs, and inspected Settings screenshot agree.

## Explicit limitations

- WorkManager provides reliable **eventual** scheduling, not exact cadence.
- OEM battery managers can delay work; capture stop reasons and constraints
  rather than pretending every delay is an app failure.
- A user force-stop is a deliberate platform stop and is outside the guarantee
  until the user opens Navis again.
- This plan is Android-only. iOS background refresh needs a separately designed
  native lifecycle and must not be inferred from WorkManager.
