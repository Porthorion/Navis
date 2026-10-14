# Android playback startup investigation — 2026-10-14

Branch: `fix/startup-hang`. No commits or stashes were made.

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
