# Idle robustness follow-ups — 1.5.1

Status: playback findings 4, 7, 8 and 13 are completed for release/1.5.
Android acceptance evidence is recorded in the progress log. Findings 5 and
10–12/14 remain deferred.
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

**Likelihood:** medium for writer contention, low for simultaneous upgrades.
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

**Likelihood:** medium. A killed worker or frozen heartbeat leaves the durable
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

**Likelihood:** medium for contention. Doze can release due download retries,
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

## Deferred to 1.5.1: a seek during a failing reload

If the user seeks while a failed song is reloading and that reload fails
again, the seek target is lost (just_audio ignores a seek during a load).
The one-retry rule then skips to the next song, so the visible effect is small.
Fix in 1.5.1 by carrying a seek made during the reload into the held recovery
record. Found in the batch-2 round-5 review on 2026-10-15.
