# Troubleshooting

## Tests appear to hang or fail unexpectedly

Check temp space first:

```bash
df -h /tmp
```

If full, clear temporary Flutter artifacts and rerun checks:

```bash
rm -rf /tmp/flutter_tools.* /tmp/dart_test* /tmp/flutter_test*
./tool/check.sh
```

## Drift tests are skipped (`All tests skipped`)

Symptom:
- `flutter test test/src/database/navis_database_test.dart -r expanded` ends with `All tests skipped.`
- `flutter test test/src/database/migrations/navis_migration_test.dart -r expanded` ends with `All tests skipped.`

Cause:
- native SQLite development library is missing (`libsqlite3.so`).

Fix (Ubuntu/Pop!_OS):

```bash
sudo apt-get update
sudo apt-get install -y libsqlite3-dev sqlite3
ls -l /usr/lib/x86_64-linux-gnu/libsqlite3.so
```

Then rerun:

```bash
./tool/phase1_closeout.sh
```

If you cannot install system packages (no sudo), use a local symlink fallback:

```bash
mkdir -p /tmp/navis-sqlite
ln -sf /lib/x86_64-linux-gnu/libsqlite3.so.0 /tmp/navis-sqlite/libsqlite3.so
LD_LIBRARY_PATH="/tmp/navis-sqlite:${LD_LIBRARY_PATH:-}" ./tool/phase1_closeout.sh
```

## Android SDK not found

Symptom from `flutter doctor -v`:
- `Unable to locate Android SDK`

Fix:
1. Install Android Studio.
2. Install Android SDK command-line tools and platform SDK 36.
3. Configure Flutter SDK path:

```bash
flutter config --android-sdk <path-to-sdk>
flutter doctor --android-licenses
flutter doctor -v
```

## Linux desktop build fails with missing C++ headers

If you use Linux for local startup validation, install required toolchain packages:

```bash
sudo apt-get install -y clang cmake ninja-build libgtk-3-dev g++ build-essential
```

Rebuild from clean state:

```bash
rm -rf build/linux
flutter run -d linux
```

## Generated files drift in CI

Always run generation before commit:

```bash
dart run build_runner build --delete-conflicting-outputs
```

Then verify no diff:

```bash
git diff --exit-code
```

## Android playback service fails to initialize

Symptoms:
- `MissingPluginException(... audio_service.client.methods ...)`
- `Unable to bind to AudioService. Please ensure you have declared a <service> element`

Checklist:
1. Confirm `/Users/khalifaalzarooni/Documents/forgejo_projects/Navis/android/app/src/main/AndroidManifest.xml` includes:
   - `com.ryanheise.audioservice.AudioService` `<service>` declaration
   - `com.ryanheise.audioservice.MediaButtonReceiver` `<receiver>` declaration
   - `WAKE_LOCK`, `FOREGROUND_SERVICE`, and `FOREGROUND_SERVICE_MEDIA_PLAYBACK` permissions
2. Confirm `/Users/khalifaalzarooni/Documents/forgejo_projects/Navis/android/app/src/main/kotlin/com/navis/app/navis/MainActivity.kt` extends `AudioServiceActivity`.
3. Run a full clean install (required after manifest/plugin changes):

```bash
flutter clean
flutter pub get
adb uninstall com.navis.app.navis
flutter run -d sdk
```

If playback still fails, capture full startup logs and verify that the app prints:
- `Audio handler initialized successfully.`

## Codec verification matrix (release checklist)

Run this protocol on at least one Android device before release:

1. Clean install:
```bash
flutter clean
flutter pub get
adb uninstall com.navis.app.navis
flutter run -d <device>
```
2. First playback: play one track per codec from Library.
3. Restore playback: kill app, relaunch, verify restored queue track plays.
4. Background playback: lock screen / background app and verify playback continuity.
5. Confirm resolver logs report selected source kind for each track:
   - `file`
   - `lockCachedStream`
   - `directStream` (fallback path)

Use this evidence table per validation run:

| Date (UTC) | Server variant | Device | Codec/container | Source kind selected | Playback result | Fallback behavior | Notes |
|---|---|---|---|---|---|---|---|
| YYYY-MM-DD | Subsonic/OpenSubsonic/AzuraCast | device model + Android version | FLAC/ALAC/MP3/AAC/Opus/Vorbis | `file` / `lockCachedStream` / `directStream` | pass/fail | none / lock->direct / DSP-degraded | optional |
| 2026-02-23 | OpenSubsonic | SM-S928B (Android 16) | FLAC | `lockCachedStream` | pass | none observed | from `codec_runtime_raw.log` (`Playback source resolved`, `format=original`) |
| 2026-02-23 | OpenSubsonic | SM-S928B (Android 16) | AAC | `lockCachedStream` | pass | none observed | from `codec_runtime_raw.log` (`Playback source resolved`, `format=aac`, `maxBitRate=320`) |
| 2026-02-23 | OpenSubsonic | SM-S928B (Android 16) | MP3 | `lockCachedStream` | pass | none observed | from `codec_runtime_raw.log` (`Playback source resolved`, `format=mp3`, `maxBitRate=320`) |

Provisional closeout decision (2026-02-23):
- Accepted to proceed toward Phase 5 based on automated preflight + FLAC/AAC/MP3 runtime evidence.
- Remaining caveat: capture Opus runtime row when sample is available.
- Vorbis is currently unavailable in the active library/server catalog, so no runtime row was captured.

Latest automated preflight evidence (tests + metadata template generation):

| Date (UTC) | Server variant | Device | Scope | Result | Evidence |
|---|---|---|---|---|---|
| 2026-02-22 | OpenSubsonic | SM-S928B (Android 16) | `make phase4-codec-closeout DEVICE_ID=R5CX14TVQEE SERVER_VARIANT=OpenSubsonic` | pass | `playback_source_resolver_test.dart` + `navis_audio_handler_test.dart` executed; codec row templates generated |

Note: automated preflight does not replace runtime codec validation; fill the matrix rows above after executing physical-device playback checks.

For failures, always capture:
1. Song id and codec/container.
2. Resolver source kind transitions (`file`, `lockCachedStream`, `directStream`).
3. Full player error stack from logs.

## Playback diagnostics matrix

Use this quick matrix to classify failures:

1. Bootstrap failure:
- Symptoms: `Playback initialization failed`, `timed out after 5s`, bootstrap gate remains blocked.
- Checks:
  - run `flutter clean && flutter pub get`
  - reinstall app (`adb uninstall com.navis.app.navis`)
  - rerun `flutter run -d <device>`
 - Note:
   - bootstrap now has late-success recovery; if initialization completes shortly after timeout, logs include `Audio bootstrap recovered after timeout`.
2. Source fallback failure:
- Symptoms: queue restore/play action fails around lock-cached source setup.
- Expected: resolver should fall back from lock-cached stream to direct stream.
- Checks:
  - inspect logs for source kind transitions (`lockCachedStream -> directStream`)
  - verify authenticated session is present and stream URL resolves.
3. Android DSP initialization failure:
- Symptoms: `Cannot initialize effect engine ... Equalizer ... Error: -3`.
- Expected:
  - playback should degrade to non-DSP mode for the current session and continue.
- Checks:
  - inspect logs for `Disabling DSP pipeline for this session` / `plain player` retry.
  - disable equalizer/loudness in `/settings/playback` if device effects remain unavailable.
4. Local cache proxy policy failure:
- Symptoms: `Cleartext HTTP traffic ... 127.0.0.1 not permitted`.
- Checks:
  - confirm `/Users/khalifaalzarooni/Documents/forgejo_projects/Navis/android/app/src/main/res/xml/network_security_config.xml` allows loopback only (`127.0.0.1`, `localhost`).
  - confirm `/Users/khalifaalzarooni/Documents/forgejo_projects/Navis/android/app/src/main/AndroidManifest.xml` references that network security config.

## Android `VRI` / `SurfaceView` logs while backgrounding

Symptoms:
- logs such as `VRI[MainActivity]`, `SurfaceView ... surfaceDestroyed`, `HWUI CacheManager::trimMemory`.

Expected:
- these logs are normal Android lifecycle noise when the app loses visibility or the screen state changes.
- they are not playback errors by themselves.

Treat as real playback failures only when paired with app-level errors such as:
- `Playback initialization failed`
- `MissingPluginException` / `Unable to bind to AudioService`
- `Playback action failed` with no active queue progress.

## Scrobble queue diagnostics

Symptoms:
- now-playing / submission updates are delayed
- scrobbles only flush after reconnect

Expected behavior:
1. events are enqueued durably in `scrobble_queue`
2. dispatch runs only when:
   - scrobbling is enabled
   - an authenticated session exists
   - server reachability is online
3. failed deliveries are retried with exponential backoff
4. expired events are pruned automatically (`submission=true`: 7 days; now-playing: short retention)

Quick checks:
```bash
flutter test test/src/features/player/data/scrobble_service_test.dart
flutter test test/src/database/daos/scrobble_dao_test.dart
```

If scrobbling appears stuck, verify:
1. `/settings/playback` has scrobbling enabled.
2. reachability banner is not showing offline.
3. app logs do not show repeated terminal `scrobble` API failures.
