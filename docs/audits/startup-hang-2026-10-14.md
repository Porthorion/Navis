# Android playback startup investigation — 2026-10-14

Branch: `fix/startup-hang`. No commits or stashes were made.

## Idle robustness correction and verification

This section supersedes the original timeout-retirement behavior described in
that commit and the earlier overlay assessment below. The earlier worker plugin
isolation remains intact. No native plugin rebind was added. The deterministic
slow-source test reproduced **finding 1** before implementation changes; it does
not establish the owner's exact physical-device overnight trigger.

### Step 0: same uncached saved queue before and after

`Navis_Idle_Test` used API 37 Play Store PS16K x86_64, 4 GB guest RAM, a 10 GB
throwaway data partition and SwiftShader under memory-capped `systemd-run` user
units. All tests used an isolated `.idletest` profile sidecar and the authorized
disposable server. Credentials were sent in memory to the existing connect API,
never written to fixture scripts, build defines or logs. The worker fixture used
the same sidecar secure storage and database as the foreground engine.

The queue contained two songs and zero cached entries. HOME plus `am kill` did
not always terminate the retained media service; after checking the PID, the
sidecar's own `run-as … kill -9` completed process death. No other emulator or
application was killed. Emulator network shaping alone did not reliably delay
source resolution, and an offline-only attempt deferred restoration rather than
reproducing the loop. The successful comparison used the permitted profile-only
12-second stream-source delay, applied after local source checks. This was the
only reproduction instrumentation added before changing startup behavior.

| Observation | Before | After, same 12-second source delay |
|---|---|---|
| Process death confirmed | PID 3903 → 4274 | PID 4538 → 5266 |
| Bootstrap | Attempts 1–5 in 34 seconds, never ready | Attempt 1, ready in 99 ms |
| Presentation deadline | Five-second timeout then three-second retry cadence | No timeout or retry |
| Handler ownership | Late handlers 1–4 discarded as successors began | One construction |
| Queue/network | Startup waited for uncached source preparation | Two metadata items, saved 5-second position, zero native sources |
| Blackholed cold start | Loop with slow source | 0.823 seconds end to end; another run 0.861 seconds |
| Play after network return | Startup remained blocked | Play issued while blackholed; after network returned, streaming reached native position 5,953 ms |

Before logcat starts attempt 1 at 10:46:25.469, times out at 30.472, starts
attempt 2 at 33.473 and discards handler 1 at 35.606. The same ordering repeats.
App-owned `before.png` shows the persistent recovery overlay. After captures
show Home and the restored paused mini player with airplane mode enabled. A
final install/force-stop screenshot run was slower end to end (2.258 seconds),
but still used one ready construction and no network wait; the sub-1.5-second
repeat result is an observation, not an unconditional process-launch guarantee.

Local evidence is in ignored `build/idle-robustness/`: `before.json`,
`before-timeline.txt`, `after-home.json`, `after-home-timeline.txt`,
`home-blackhole-final.png`, and the other inspected app-owned captures.

### Emulator matrix

| Scenario | Result and evidence |
|---|---|
| Warm worker with paused queue, then resume | Actual forced job 23 succeeded in 6,112 ms while PID 5266 survived; paused queue did not defer it |
| Worker catalog commit, open Library refresh | Worker changed a server star, original star state restored afterwards; after 31 seconds away the same open Liked Albums screen changed from empty to the new album |
| Resume reconciliation | Timeline reports `resumeDatabase: changed`, connectivity online, reachability online; Drift announced albums/songs/aliases/sync state and the foreground reloaded durable state |
| Cold worker, open during work | PID 5266 → 6433; bootstrap ready in 415 ms before worker exit; job 32 succeeded in 5,849 ms |
| Cold worker, open after work | PID 6433 → 6648; job 33 succeeded in 4,737 ms; attempt 1 ready |
| System starts canonical AudioService before Activity | PID 6648 → 6841; Launcher remained foreground until explicitly opening Navis; same process ready on attempt 1 |
| Doze | Battery unplugged, forced deep state `IDLE`, then unforced and battery reset; PID 6841 stayed ready on attempt 1 |
| Forced never-ready | Existing attempt gate held forever; one attempt, no retry; timeout recorded at 5,093 ms; inspected recovery panel includes Restart, Copy details, reset and sign-out |
| Restart Navis | NEW_TASK\|CLEAR_TASK launch observed; PID 3777 → 4115, fresh diagnostics handshake and one resumed MainActivity; deliberately retained fault still timed out after relaunch |
| Remove forced fault | Normal profile reinstalled; Home and paused mini player visible under airplane mode |
| Copy details | Production recovery action copied the bounded private timeline; inspected 68-event sample was 5,343 bytes with only allowed fields and no identities |

Each visible scenario used `POST /v1/presentation/screenshot`; PNGs were opened
and inspected. Animated overlay capture waits for frames, so it cannot establish
the exact button appearance time; the widget regression verifies absence at
4,999 ms and presence at 5,000 ms. Native logcat supplies the five-second timeout
ordering. `worker-warm.json`, `emulator-matrix.json`, `restart.json` and
`startup-details.jsonl` retain sanitized local observations.

### Implementation and regressions

The existing AudioBootstrapController now keeps construction ownership across
its presentation timeout. Native configure is bounded without reinitializing
process-wide audio_service callbacks. Saved queue restoration uses the existing
queue lane to publish metadata, index, position and shuffle/repeat before Play
or another transport command materializes sources. Download/cache/stream
priority and stale-generation disposal remain covered by the playback suite.

LibrarySyncController reuses its lifecycle listener, connectivity/metering
providers and reachability controller. A long resume refreshes one coalesced
connection probe. Writer-pinned SQLite `data_version` detects external worker
commits and announces mapped Drift tables, reloads sync state and reapplies
identity aliases. Retryable transport errors are limited to known read-only GET
endpoints; Subsonic mutation GETs remain non-retryable. Native and Dart sync
policies defer only playing/loading/buffering, allowing a paused queue.

AppLogger owns typed private startup events, with a separate locked native
worker ring (200 + 100 events, below 64 KB). PlaybackRecoveryService handles
restart and clipboard copying; About's hidden version long-press uses the same
copy action and AppNotice. Privacy text and the two requested 1.5.0 changelog
entries are updated.

Focused regressions cover single construction, retirement and late generations;
metadata-only uncached restoration and first Play/Prepare/Seek/Next; native
configure timeout; safe retry classification; coalesced long resume and external
SQLite commit refresh; paused playback policy; exact recovery timing/layout;
clipboard/About confirmation; and bounded, sanitized timeline persistence.
Android JVM probe/scheduler tests passed. Linux profile startup reached ready on
attempt 1 in 71 ms; direct streaming advanced native position to 949 ms and
Home's paused player screenshot was inspected. After clean shutdown/restart,
clone credentials (deliberately memory-only, no credential file) were supplied
again through the connect API; the handler then bound in 8 ms and restored two
queue items. This does not certify durable desktop credential storage. The
initial catalog retry completed before the final Home screenshot; an initial
policy deferral and rejected direct song-selection requests were fixture setup
issues, not counted as playback failures.

The owned emulator was stopped, clock/Doze/battery state restored, and only
`Navis_Idle_Test.avd`/`.ini` deleted. The isolated Linux runtime profile was
removed after preserving its identity-free timeline and screenshot. No server
star mutation remains. No commits or stashes were made.

### Limits and deferred work

The physical overnight trigger, real-device audio focus/service-destruction
races and audible output remain unverified. Profile playback was muted and
verified by native processing/position advancement. Independent paused wake-lock
release is unavailable through the current audio_service public API without a
dependency patch; service retention is preserved. Findings 4, 5, 7, 8 and 10–14
are deferred to [the detailed 1.5.1 plan](../plans/idle-robustness-followups.md).

### Changed files in the idle correction

- `android/app/src/main/java/com/ryanheise/audioservice/NavisAudioServiceProbe.java`
- `android/app/src/main/kotlin/com/navis/app/navis/MainActivity.kt`
- `android/app/src/main/kotlin/com/navis/app/navis/NavisBackgroundSyncWorker.kt`
- `android/app/src/main/kotlin/com/navis/app/navis/StartupWorkerTimeline.kt`
- `android/app/src/test/kotlin/com/navis/app/navis/NavisAudioServiceProbeTest.kt`
- `docs/README.md`
- `docs/architecture.md`
- `docs/audits/startup-hang-2026-10-14.md`
- `docs/development/development-workflow.md`
- `docs/plans/idle-robustness-followups.md`
- `docs/project/progress.md`
- `lib/l10n/app_en.arb`
- `lib/l10n/app_localizations.dart`
- `lib/l10n/app_localizations_en.dart`
- `lib/main.dart`
- `lib/src/api/subsonic_retry_interceptor.dart`
- `lib/src/app.dart`
- `lib/src/database/navis_database.dart`
- `lib/src/features/auth/presentation/server_reachability_provider.dart`
- `lib/src/features/changelog/changelog_data.dart`
- `lib/src/features/library/presentation/library_sync_provider.dart`
- `lib/src/features/player/data/navis_audio_handler.dart`
- `lib/src/features/player/data/navis_audio_handler_bootstrap.dart`
- `lib/src/features/player/data/navis_audio_handler_media_session.dart`
- `lib/src/features/player/data/navis_audio_handler_navigation.dart`
- `lib/src/features/player/data/navis_audio_handler_persistence.dart`
- `lib/src/features/player/data/navis_audio_handler_queue_editing.dart`
- `lib/src/features/player/data/navis_audio_handler_queue_loading.dart`
- `lib/src/features/player/data/playback_source_resolver.dart`
- `lib/src/features/player/domain/playback_snapshot.dart`
- `lib/src/features/player/presentation/playback_recovery_provider.dart`
- `lib/src/features/settings/presentation/about_screen.dart`
- `lib/src/providers/app_providers.dart`
- `lib/src/utils/app_logger.dart`
- `lib/src/utils/startup_timeline.dart`
- `lib/src/utils/sync_diagnostics_server.dart`
- `test/src/api/subsonic_retry_interceptor_test.dart`
- `test/src/architecture/android_background_playback_isolation_test.dart`
- `test/src/features/library/presentation/resume_reconciliation_test.dart`
- `test/src/features/player/data/audio_service_configure_timeout_test.dart`
- `test/src/features/player/data/navis_audio_handler_navigation_test.dart`
- `test/src/features/player/domain/playback_snapshot_test.dart`
- `test/src/features/player/presentation/playback_recovery_sheet_test.dart`
- `test/src/features/settings/presentation/about_screen_test.dart`
- `test/src/providers/app_providers_test.dart`
- `test/src/utils/startup_timeline_test.dart`
- `test/widget_test.dart`
- `tool/dead_code_baseline.json`

## Earlier worker-isolation investigation (historical)

## Findings and limits

The owner's overnight `Preparing Playback` hang was **not reproduced** on the
API 37 emulator. Every verified baseline lifecycle scenario below reached authenticated
`/v1/playback/bootstrap/status` with `status: ready`, `attempt: 1`,
`handlerReady: true`, `timedOut: false`, and `retryScheduled: false`.
App-owned screenshots were retrieved and opened. They showed onboarding or
Home (sometimes with the ordinary battery-optimization tip), not a persistent
playback bootstrap overlay.

The registration defect was observed directly: each baseline headless worker
logged duplicate registration attempts for `AudioServicePlugin`,
`AudioSessionPlugin`, and `JustAudioPlugin`. The default `FlutterEngine(context)`
constructor had already registered them before the explicit
`GeneratedPluginRegistrant.registerWith(engine)` call.

Installed audio_service 0.18.19 has process-wide media-browser, controller,
handler-interface and pending-configure state. Its browser's connection callback
belongs to the first plugin instance; `onConnected` returns when that instance's
application context has been cleared by engine detachment. If another client
still exists, detachment does not disconnect that browser. A later configure can
therefore wait for a callback owned by a detached engine. This is a supported
failure sequence from source inspection, not an observed emulator failure or
proof of the owner's exact trigger.

Navis also cached the pending `AudioService.init` future indefinitely. Its
session-handler cache was only invalidated by teardown/errors, while normal
timeouts repeatedly awaited it. Merely clearing the service future would be
unsafe: `AudioService.init` installs process-wide Dart callbacks before awaiting
configure and is documented for one-time initialization.

## Baseline runtime evidence

The new `Navis_Boot_Test` AVD used
`system-images;android-37.0;google_apis_playstore_ps16k;x86_64`, 4 GB RAM,
`-gpu host`, and `-no-snapshot-save`, under a memory-capped user systemd unit.
Its data partition was 10 GB because a 16 GB partition exceeded free host disk
space. No other AVD was copied, modified, stopped, or uninstalled from. The
isolated `.boottest` profile sideload build used the existing worker fixture
flag, real sidecar secure storage, and the same sidecar-owned database for both
engines. Login used the authorized disposable server via the diagnostics connect
body; credentials were not put in scripts, build defines, or logs.

Periodic work was made due by advancing only the throwaway emulator's clock
by 3,700 seconds per worker scenario. Job IDs came from `dumpsys jobscheduler`;
API 37 requires namespace `androidx.work.systemjobscheduler` for the forced
`cmd jobscheduler run -f -n …` call. Thus these were actual worker executions,
not early-run refusals. Process death used HOME, `am kill`, and a sidecar-only
`run-as … kill -9` fallback when the audio service kept the process alive.
Logcat times below are the device's UTC+4 clock, with the deliberate clock
advances included.

| Scenario | PID(s) | Native logcat sequence | Foreground observation |
|---|---|---|---|
| a. HOME, due worker, finish, reopen | 8067 | Job 7: worker start 10:24:45.165; audio plugin registration 45.247; SUCCESS 49.888 | ready at 10:24:54 |
| b. Kill, cold worker, open during work | 8067 → 10049 | Job 15: start 11:26:47.901; registration 47.916; SUCCESS 52.254 | ready at 11:26:51, before worker completion |
| b. Kill, cold worker, open after completion | 10049 → 10243 | Job 16: start 12:28:45.300; registration 45.456; SUCCESS 50.001 | ready at 12:28:56 |
| c. Initial attempt (invalid system wake) | 10243 → 10486 | old process death 12:29:21.883; `am startservice` was rejected for an idle background UID; the first driver missed stderr | foreground ready at 12:29:27; does not count as headless wake evidence |
| d. HOME, force deep idle, wait, unforce, open | 10486 | force-idle at about 12:29:39; eight-second idle; unforce returned ACTIVE | ready at 12:29:50 |
| b. Tighter worker-first overlap | 10486 → 10808 | Job 27: start 13:31:39.367; registration 39.411; SUCCESS 43.811; activity opened one second after dispatch | ready at 13:31:42, before worker completion |
| c. Corrected original-source repetition | 4230 → 4425 | system started media service 22:02:03.146; `flutterEngine warmed up` 03.483; activity opened 05 | ready at 22:02:07 on the same headless PID |

For the corrected c comparison, the five playback/worker implementation files
were temporarily built from `HEAD` while the emulator was stopped. The fix was
saved and restored byte-for-byte in `finally`, with equality checked before
runtime resumed. No commit, stash or unrelated reset was used. The already-built
fixed APK was retained separately and reinstalled for final verification.
The explicit service wake used a ten-second system temporary allowlist for the
sidecar's idle UID; this enables the authorized system-service start without
depending on a prior eligible media session. The fixed repetition verified
Launcher remained resumed while the headless service ran. The allowlist was
removed before final Doze verification.

`Audio bootstrap ready` and timeout messages were unavailable in profile-mode
logcat: Navis's `AppLogger` uses logger's default `DevelopmentFilter`, which
suppresses output when assertions are disabled. The authenticated bootstrap
endpoint supplied readiness evidence. No `### destroying audio handler
interface` or `### UNHANDLED: onConnectionSuspended` line appeared in these
captured Navis sequences. Absence of those lines is not proof against the race.

An additional baseline stop attempt after a cold worker's start found no
matching executing JobScheduler job after WorkManager reassigned its job ID;
it is not cancellation evidence. A brief Wi-Fi interruption after another
cold worker's start also reached ready (PID 6120; worker start 17:49:10.409,
audio registration 10.566, ready by 14, worker SUCCESS 16.629). It did not
reproduce the detached-callback sequence. Reboot reset the emulator clock;
one dispatch refused early execution until that test clock was advanced again.
Only dispatches with an actual worker-start event count as worker scenarios.

## Change and regression evidence

- The worker disables automatic generated registration and registers only
  JNI, JNI Flutter, secure storage, and connectivity. The list lives beside
  the existing session, with its dependency rationale.
- Bootstrap timeout/failure retires the session future. Android retries use
  the existing background-sync channel and `NavisAudioServiceProbe` to rebind
  the pending connection through public embedding plugin lifecycle APIs. The
  probe only uses the cached playback engine and refuses an active session.
  It does not create a replacement engine. The original `AudioService.init`
  is retained so native configure can finish without installing a second set
  of Dart callbacks/observers. Missing activity registration is retried later.
- The Dart architecture guard requires automatic registration to be disabled,
  the worker to use its exact sync allowlist, and playback plugins to be absent.
- The mobile bootstrap regression leaves native configure pending across the
  first timeout, recovers it on retry, verifies exactly one configure call,
  and starts playback with the newer session handler. It uses the package's
  existing platform-interface test seam; that already-resolved package is now
  declared as a direct dev dependency.
- A provider regression leaves the first initializer permanently pending and
  verifies automatic retry reaches a successful second attempt. Existing
  stale-completion, teardown, session rebuilding, projection ownership, and
  queue restoration tests remain in place.

The initial focused architecture/provider/navigation run passed 471 tests.
After correcting one new test-style analyzer info, all three new regressions
passed again. `./tool/check.sh` passed after that correction: 7,890 tests and one existing
skip; formatting, generation, analysis, dead-code, migration and critical
reliability gates passed. Analysis reported 168 pre-existing infos and no
errors/warnings. The temporary four-worker configuration was removed. Fixed
runtime evidence follows.

## Fixed Android runtime evidence

The fixed x86_64 profile sideload APK compiled successfully. Authenticated health
reported schema 103 and the retained catalog (1,827 artists, 5,765 albums,
57,841 songs). All verified a–d cases returned the same first-attempt ready
bootstrap fields as the baseline; all corresponding app-owned PNGs were opened
and showed Home without a persistent playback overlay. Both APKs used the same
isolated profile and encrypted disposable session.

| Scenario | PID(s) | Native logcat sequence | Foreground observation |
|---|---|---|---|
| a. Warm worker, finish, reopen | 3212 | Job 32: start 18:51:52.193; SUCCESS 55.723 | ready at 18:51:59 |
| b. Cold worker, open while running (final repetition) | 4814 → 5103 | Job 50: start 23:05:26.368; activity opened 26; SUCCESS 32.088 | ready at 23:05:28, before completion; then waited for SUCCESS |
| b. Cold worker, finish, reopen | 3874 → 4173 | Job 43: start 21:58:51.422; SUCCESS 58.539; native audio-service warming 21:58:59.166, after foreground open | ready at 21:59:00; persisted worker result `succeeded`, 6,899 ms |
| c. System media-service wake (final repetition) | 4639 → 4814 | started-service process 22:02:55.272; native engine warmed 55.577; activity opened 57 | ready at 22:02:59 on the headless PID |
| d. Deep idle after the final system wake | 4814 | temporary allowlist removed; force-idle 22:02:59; unforce at about 22:03:07 returned ACTIVE | ready at 22:03:10 |

No duplicate audio_service/audio_session/just_audio registration line appeared
in these fixed worker sequences. The final overlapping worker persisted
`succeeded`, duration 5,551 ms, with scheduling state `scheduled`; foreground
sync independently reported `leaseHeld`, as expected while the worker owned
catalog work. This proves the allowlisted headless pipeline can authenticate,
read its database and complete real sync without playback plugins.

An earlier back-to-back driver run killed its still-running overlap worker
before the next case could find a rescheduled job ID. That attempted after-work
case is excluded; the independently repeated after-completion case above
observed actual worker SUCCESS before reopening. The initial fixed c attempt
also encountered Android's idle-UID service restriction, and a media dispatch
had no eligible session. Only the verified system-started headless repetitions
count as c results.

The sidecar was force-stopped and uninstalled, its ADB forwards removed, the
owned emulator stopped, and `Navis_Boot_Test` deleted. The original AVDs were
untouched. Raw logs, PNGs, APK copies and temporary source backups are local
test artifacts and are removed after the Linux smoke; this audit preserves
the sanitized timeline.

Linux startup smoke used `./tool/dev_app.sh run -d linux --fresh-login --no-pub`
under a separate memory-capped systemd unit after Android was stopped and
deleted. Authenticated `/v1/health` returned clone mode, schema 103 and an empty
catalog; `/v1/playback/bootstrap/status` returned first-attempt ready with no
timeout/retry. The app-owned `linux-startup-smoke` PNG was opened and showed
the normal Login page without the startup overlay. The app was shut down
through authenticated `/v1/shutdown`, then its owned launcher and fresh profile
were removed. Runtime implementation matched the source that passed the gate;
later changes only finalized this audit and the progress evidence.

Unverified: the owner's physical phone and a real overnight soak; an actual
native callback-drop hang and execution of the native rebind against that hang.
The controlled configure-stall regression verifies the Dart retry/single-init
contract, not an observed dropped Android callback. No failing emulator
sequence can honestly be claimed from this investigation.

## Overlay-removal assessment

The overlay is an application startup choice: it blocks interaction until
handler construction and retained queue setup finish. It is not required by
Android's media service. The router is already built underneath it.

`audioHandlerStateProvider` is consumed directly only inside the composition
root; features use its nullable `audioHandlerProvider` alias. Snapshot, position,
buffer, media-item and radio streams already provide idle/null/empty fallbacks.
Home, Library, Search, Settings and the shell can render while playback is
unavailable; this audit found no direct handler force-unwrap at those consumers.

The behavior needing attention is early playback interaction:

- `QueueController._requireHandler` throws the typed playback-unavailable
  exception for album/artist/playlist/download play, shuffle and queue edits.
  Its existing error stream/recovery sheet can handle failure, but a deliberate
  wait/retry or disabled-control policy is still needed for ordinary startup.
- `togglePlayPause`, mini/desktop player transports, Now Playing seek and
  repeat/shuffle controls, desktop media commands and `RadioScreen` station
  actions contain null no-ops. They would not crash, but early taps can be lost.
- Equalizer and playback-adjustment controllers already defer engine hydration
  or attach on handler arrival; validate persisted settings and readiness UI.
  Onboarding settings skip immediate runtime application when the handler is
  absent and must retain correct later hydration.
- Keep eager headless playback initialization for Android Auto and system media
  startup. Separate browsing readiness from playback readiness without changing
  authentication, queue restoration, session teardown or first-play selection
  ownership. Other awaits before `runApp` can still affect perceived cold start.

Estimate: one to two engineering days for the overlay/action-state change and
focused tests, plus roughly one day for cold-start, failure/recovery, restored
queue, process-death and system-media validation. This is an estimate, not a
new implementation plan. The overlay was not redesigned in this task.

## Changed files

| Files | Purpose |
|---|---|
| `android/app/src/main/kotlin/com/navis/app/navis/NavisBackgroundSyncWorker.kt` | Disable automatic registration and define the sync plugin allowlist |
| `android/app/src/main/java/com/ryanheise/audioservice/NavisAudioServiceProbe.java` | Recover a pending connection through the cached engine's public plugin lifecycle |
| `android/app/src/main/kotlin/com/navis/app/navis/MainActivity.kt` | Expose recovery on the existing internal background-sync channel |
| `lib/src/features/player/data/navis_audio_handler_bootstrap.dart` | Recover the pending Android service while preserving a single init |
| `lib/src/providers/app_providers.dart` | Retire failed session futures and invoke recovery on retry |
| `test/src/architecture/android_background_playback_isolation_test.dart` | Guard the worker's construction and plugin set |
| `test/src/features/player/data/navis_audio_handler_navigation_test.dart` | Exercise stalled configure, recovery, single init and subsequent playback |
| `test/src/providers/app_providers_test.dart` | Exercise automatic success after a permanently pending first attempt |
| `pubspec.yaml`, `pubspec.lock` | Declare the existing platform interface as a direct test dependency, without changing its version |
| `lib/src/features/changelog/changelog_data.dart` | Add the requested 1.5.0 fix entry |
| `docs/architecture.md` | Document worker plugin ownership and bootstrap recovery |
| `docs/project/progress.md`, this audit | Record validation, timeline, cleanup and verification limits |

## Follow-up (2026-10-14)

The native rebind (`NavisAudioServiceProbe.recoverPendingConnection`) was removed after a read-only review: removing the only MediaBrowser binding can queue the idle AudioService for destruction, whose `onDestroy` then clears the listener the re-added plugin just installed, so notification and Android Auto commands would be ignored until restart. Only the background-engine plugin isolation and the session-future retirement remain.


## Review follow-up

The five P2 findings from the review of `ecc21594` are fixed without commits
or stashes. Existing transport generations, preparation-lane cancellation,
bootstrap deadline and resume reconciliation remain the owners of recovery.

| Finding | Root fix | Regression and result |
|---|---|---|
| Local initialization escaped readiness | Bootstrap awaits `waitUntilReady()` before binding/publishing the handler; failed local initialization disposes it and uses the existing silent retry. Saved-queue and network preparation remain outside readiness. | `bootstrap includes local initialization (failure: false/true)` — both failed before and pass after. `bootstrap readiness excludes saved queue restoration` also passes with restoration blocked. |
| Cancelled first Play replaced newer selection | Queue replacement/clear discard lazy restore state; preparation checks transport/load ownership after awaits and before fallback admission. Normal lane cancellation cannot proceed into fallback. | `cancelled first Play preserves newer queue (replacement: false/true)` — both failed before and pass after, retaining an empty queue or the newer album selection. |
| First Previous ignored saved position | Navigation uses the restored logical position until a source exists; restart decisions prepare at zero rather than the saved offset. | `first Previous uses saved position (index: 0/1, seconds: 2/42)` — all four pass; three failed before, while the later-item/two-second control already passed. |
| Radio lost system metadata | Radio admission clears restore state; song snapshot reconciliation cannot overwrite an active radio media item. | `radio after metadata restore retains station media-session metadata` — failed before and passes after, including no null publication after the station item. |
| Worker committed after resume comparison | A foreground one-second watcher follows a durable Android worker lease or unfinished recent start, reusing the database/alias/state reconciliation. Completion is read before the final version comparison. Completion, backgrounding, session change and disposal stop it; stale starts expire and transient alias failures retry silently. | `worker commit after resume refreshes catalog and aliases (lease: false/true, retry: false/true)` — the two commit races failed before; all three cases pass after and verify polling stops after completion. |

The three focused suites initially passed 488 tests. The final selected run
passed 14 tests, including the added alias-retry case, saved-queue readiness
boundary and existing offline-restoration control. The original regressions
produced ten failures before implementation changes, covering every finding.

`./tool/check.sh` passed: 7,942 full-suite tests and one existing skip,
plus 96 migration and 246 critical reliability tests. Formatting, generation,
analysis, dead-code and the script/native gates passed. No new analyzer
errors or warnings were introduced.

Linux runtime used an isolated three-song loopback fixture and authenticated
app API. After a clean restart, metadata restored the later item at 41,999 ms
(native rounding of the 42-second seek), paused, with zero prepared native
sources. First Previous retained that item and restarted at zero; queue clear
also passed. The post-gate repeat passed the same assertions and waited for
app-owned `appReady` before capture. The inspected PNG shows Home with an
empty player and no bootstrap overlay. Both app instances shut down through
the authenticated API; fixture credentials and handshake files were removed.
Android device/OS-control and physical overnight verification were not repeated
for this Dart follow-up; the controlled regressions are the evidence for the
local-init stall and cross-engine commit races.


- P2 follow-up (2026-10-14): overlapping empty-queue Plays now carry the existing transport/load ownership and play intent through radio preparation to provisional queue admission; a newer Pause or Stop discards the unadmitted fallback, matching recent/liked semantics. Four integrated cases (Pause, Stop, newer queue and newest Play) failed on HEAD and pass after; all 481 focused tests and `./tool/check.sh` pass (7,954 full-suite tests, one existing skip, 96 migration and 246 critical reliability tests; no new analyzer errors/warnings). Post-gate isolated Linux held-fetch Pause and newest-Play controls pass across clean restarts; Stop is covered by the deterministic regression. App-owned screenshot inspected; owned apps stopped and fixture credential/handshake files removed. Read-only self-review found no new races. No commits or stashes.

### Re-review of HEAD: three additional P2 findings

The three new findings are fixed without commits or stashes. Preparation reuses
its existing shared future and the transport/load generations; no new flags or
generation counters were added. All five new defect cases failed on the original
implementation and pass with the fixes. Recovery does not publish internal
errors.

| Finding | Root fix | Regression and result |
|---|---|---|
| Large-queue restoration suppressed fallback | Transport ownership guards restoration; load ownership for asynchronous fallbacks is captured after restoration's internal generation changes. Recent, liked and radio fallback admission honors Play through the existing autoplay queue-loading path. | `large unavailable saved queue falls back on first Play (recent: false/true)` — both failed before and pass after; a 70-song unavailable saved queue falls back to one playable song, starts audio, persists the replacement and publishes no playback error. |
| Second Play inherited superseded preparation | A caller awaits existing preparation, then only the newest transport intent starts fresh preparation if no playable queue remains. Stale callers complete normally. | `second Play restarts superseded recent preparation for the newest command` — failed before and passes after; a held history lookup returns distinct stale/new rows, only the newer row applies, exactly one native source load occurs and playback starts without an error. |
| Rapid pause/resume permanently cancelled the foreground watcher | Each resume starts database reconciliation and worker observation independently of the coalesced connectivity/reachability refresh. Existing epochs cancel stale observation; pause, disposal, completion and the nine-minute budget stop it. Initial database-check failures also hand off to silent watcher recovery. | `worker commit after resume refreshes catalog and aliases (rapid: true, lease: false/true)` — both failed before and pass after while metering remains pending. Catalog subscribers, durable sync state and playback aliases refresh after the external worker commit. Additional pause, dispose and budget controls pass. |

The three focused suites passed 467 tests. The final resume-reconciliation suite
passed all 11 tests, including the three additional lifetime controls. Existing
resume precedence assertions now require successful fallback to play; saved
restore, superseded queue selection and connectivity coalescing controls pass.

Linux runtime used the existing isolated loopback fixture, profile driver and
authenticated app API. Across clean restarts, a 70-occurrence saved queue restored
paused with zero native sources. With streaming forced offline and only the
fallback song available locally, both recent and liked fallback reached one
native source and an advancing position on the first Play. Two concurrent Play
requests from an empty queue also reached one playable song. The inspected
app-owned screenshot shows Home and the paused fallback song, with the ordinary
offline notice and no startup overlay or internal-error presentation. The app
instances shut down through the authenticated API; fixture credential and
handshake files were removed. Android worker lifecycle races are covered by
the deterministic two-connection regressions; physical-device/OS-control and
overnight verification were not repeated for this re-review.

`./tool/check.sh` passed with 7,950 full-suite tests and one existing skip,
96 migration tests and 246 critical reliability tests. Formatting, generation,
analysis, dead-code and all script/native gates passed; analysis reports only
175 pre-existing infos, with no new errors or warnings.

The post-gate repeat used a fresh disposable fixture database after reconnecting
the prior loopback session encountered the host's unavailable libsecret
collection. All first-Play fallback and concurrent-Play assertions passed again
across clean app restarts. The final app-owned PNG was inspected with the same
Home/paused-fallback result. Owned app processes stopped, and no credential or
handshake file remains in the fixture root. Sanitized report and screenshots
are retained under ignored `build/new-review-runtime-1791973286/`.
