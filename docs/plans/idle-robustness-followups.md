# Idle robustness follow-ups — 1.5.1

Status: deferred by the owner on 2026-10-14. These are the read-only idle audit's
findings 4, 5, 7, 8 and 10–14, retained for the next version. They are not part
of `fix/startup-hang` acceptance. The startup audit records the current work:
[Android startup investigation](../audits/startup-hang-2026-10-14.md).

## 4. Service destruction with a surviving engine

**Likelihood:** medium; native controls can fail silently when triggered.
AudioService's `onDestroy` clears its static listener even when an activity keeps
the cached Flutter engine alive. A later service instance can retain an existing
plugin handler interface that bypasses listener installation. Notification,
Bluetooth and Android Auto callbacks then return at `listener == null`; app
controls still call the Dart handler directly. Native metadata updates can also
fail with no service instance. Navis does not observe `AudioService.asyncError`.

Trace audio_service 0.18.19's `AudioServicePlugin.onAttachedToEngine`, browser
connection callback and `AudioService.onDestroy`, plus
`lib/src/features/player/data/navis_audio_handler_bootstrap.dart`. Reproduce
with activity recreation around idle service destruction, confirming **engine
survival and service destruction** independently. `am stopservice` alone cannot
order this race while a binding survives; use native instrumentation to order
old destruction and new attachment. Reinstall the listener at service creation
or reconnection, republish state and expose native session health. Do not
restore the rejected remove-and-re-add-plugin rebind.

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

**Likelihood:** medium. Vendored just_audio's lock-cache HttpClient has no
explicit connection or body-progress deadline. Doze/network loss can strand a
transfer, and an overdue playback watchdog can spend its transport/song retry
before network recovery, then skip the track. This also supplied a potential
slow source for the startup-starvation finding.

Inspect `third_party/just_audio/lib/just_audio.dart` lock-cache downloads and
`navis_audio_handler_recovery.dart` remote recovery. Background an uncached
stream, disconnect or force idle during transfer, then reconnect and immediately
Play. Add cancellable connection/header/body-progress deadlines. Reconcile
network health before spending playback recovery, retaining transport-generation
checks, local-source priority and progressive-seek behavior.

## 8. Denied audio focus cached as acquired

**Likelihood:** medium under focus denial. audio_session 0.2.4 stores its focus
request even when Android denies it; later requests can return true because that
object exists. just_audio's denied-focus Play branch sets playing false without
completing its Play completer. Navis issues Play unawaited without a specific
focus-denial outcome. Android 15+ requires appropriate foreground eligibility.

Inspect audio_session's AndroidAudioManager, vendored just_audio's focus branch,
`navis_audio_handler.dart` and `navis_audio_handler_media_session.dart`.
Use instrumentation for a deterministic service-first denial with Launcher in
front; emulator calls characterize interruption but do not guarantee denial.
Clear failed native focus requests and complete denied Play with a typed result.
Surface the failure and check native player/session health before renewed Play.
Preserve explicit Pause/selection generation guards and normal ducking behavior.

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

**Likelihood:** medium. Five background refill failures exhaust the session;
subsequent snapshots/end-of-queue events do not re-arm it when networking
recovers. Internet-radio errors separately stop the station and restore the
previous song queue paused; the ordinary remote watchdog excludes radio.

Inspect `personal_radio_notifier.dart` and
`navis_audio_handler_media_session.dart`. Disconnect near refill threshold long
enough to exhaust retries, reconnect and reopen; repeat for a station stream.
Re-arm on verified connection recovery or explicit Retry while preserving
recommendation-session ownership. Expose station recovery explicitly.

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

Each follow-up needs a focused regression, authoritative affected-platform
runtime evidence and `./tool/check.sh`. Record actual symptoms and ordering;
source-supported races are not proof of the owner's overnight trigger. Keep
fixtures private and disposable, and keep credentials and media identities out
of startup details.
