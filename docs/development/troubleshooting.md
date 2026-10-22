# Troubleshooting

## Diagnostics cannot find the Linux database

The desktop database now lives at
`~/.local/share/com.navis.app.navis/navis.sqlite.sqlite`. Diagnostics tools
prefer it and use `~/Documents/navis.sqlite.sqlite` only when the new file is
absent and the legacy file exists. For an isolated clone of another profile,
set `NAVIS_DIAGNOSTICS_PRIMARY_DB=/absolute/path/to/navis.sqlite.sqlite`.
Interactive sync presets also accept `--scenario-source`; that flag takes
precedence over the environment override. Do not move or reset the primary
database to make diagnostics find it.

## Linux desktop entry does nothing / "Could not find the program 'navis'"

Symptom:
- Clicking Navis in the application menu does not start the app
- KDE logs `Could not find the program 'navis'`
- `gio launch ~/.local/share/applications/com.navis.app.navis.desktop` fails to
  load the desktop file

Cause:
- A user-level desktop file with `Exec=navis` was installed for Wayland icon
  matching, but no `navis` binary was on `PATH`. GLib 2.88+ rejects that file.

Fix:

```bash
./tool/dev_app.sh linux-icon
```

This installs `~/.local/bin/navis` and rewrites the desktop `Exec` to that
absolute path. Build a Linux bundle first (`./tool/dev_app.sh linux` or
`flutter build linux`) so the launcher has something to exec.

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
flutter test test/src/database/navis_database_test.dart test/src/database/migrations/navis_migration_test.dart -r expanded
```

If you cannot install system packages (no sudo), use a local symlink fallback:

```bash
mkdir -p /tmp/navis-sqlite
ln -sf /lib/x86_64-linux-gnu/libsqlite3.so.0 /tmp/navis-sqlite/libsqlite3.so
LD_LIBRARY_PATH="/tmp/navis-sqlite:${LD_LIBRARY_PATH:-}" flutter test test/src/database/navis_database_test.dart test/src/database/migrations/navis_migration_test.dart -r expanded
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
dart run build_runner build
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
   - `com.ryanheise.audioservice.NavisAudioService` `<service>` declaration
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
| 2026-08-26 | OpenSubsonic | SM-S948B (Android 16) | Vorbis (transcoded) | `lockCachedStream` | pass | none observed | Wi-Fi 320 kbps; original FLAC cache correctly bypassed for the active Vorbis profile; 75.34 s buffered |
| 2026-08-26 | OpenSubsonic | SM-S948B (Android 16) | Opus (transcoded) | `lockCachedStream` | pass | none observed | Wi-Fi 320 kbps; active Android media session at 1.22 s with 75.74 s buffered |

Provisional closeout decision (2026-02-23):
- Accepted to proceed toward Phase 5 based on automated preflight + FLAC/AAC/MP3 runtime evidence.
- Opus and Vorbis are certified through server transcoding, not native-catalog
  samples. Each was selected in **Settings → Playback** and played from a
  different source format on a physical Android device.

For failures, always capture:
1. Song id and codec/container.
2. Resolver source kind transitions (`file`, `lockCachedStream`, `directStream`).
3. Full player error stack from logs.

## Playback diagnostics matrix

Use this quick matrix to classify failures:

1. Bootstrap failure:
- Symptoms: `Playback initialization failed`, `timed out after 5s`, bootstrap gate remains blocked.
- Recovery: after ten seconds, use **Reset library cache and retry** (keeps
  downloads and your session), **Sign out (keep local data)**, or **Sign out
  and clear local data**. Before sign-in, choose **Continue to sign in**; a
  later playback attempt will offer the same recovery actions if audio remains
  unavailable.
- Checks:
  - run `flutter clean && flutter pub get`
  - reinstall app (`adb uninstall com.navis.app.navis`)
  - rerun `flutter run -d <device>`
 - Note:
   - bootstrap now has late-success recovery; if initialization completes shortly after timeout, logs include `Audio bootstrap recovered after timeout`.
2. Source fallback failure:
- Symptoms: queue restore/play action fails around lock-cached source setup.
- Expected: resolver should fall back from lock-cached stream to direct stream.
- Desktop caching: Linux, Windows, and macOS play direct HTTPS streams while
  a sidecar download fills the rolling cache. A completed sidecar file should
  appear in Cache & Storage and replay locally. Desktop recovery streams keep
  the sidecar cache path. Android uses `LockCachingAudioSource` for single-pass
  streaming and caching, with direct-stream fallback if lock-cache setup or
  playback fails.
- Checks:
  - on Android, inspect source transitions (`lockCachedStream -> directStream`);
    on desktop, check sidecar activity and completed-file registration.
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
5. Slow or failed seek in an uncached or transcoded song:
- Symptoms: the seek bar holds the target for a long time, or the seek reports
  that the position could not be reached, mostly on first plays over a slow or
  mobile connection.
- Checks:
  - `GET /v1/playback/status`: `seekEvents[].unsettled` names the rule that
    ended each settlement probe; `sourceKind` and `cacheActivity` show whether
    the seek waited for a linear transcode's download.
  - reproduce with `tool/live_seek_stress.py --throttle-kbps 6000` (see the
    development workflow).
- Transcoded seeks reopen the stream with `timeOffset` when the server
  advertises OpenSubsonic `transcodeOffset`: a seek event with
  `path: transcodeOffset` and a non-zero `positionOffsetMs` in the playback
  status. Without the capability, or at original quality, the cache-wait path
  applies. See "Transcode-offset seeking" in `docs/architecture.md`.

6. Position moved back or a song restarted with no user action:
- Symptoms: Android steps back about 5 s after a stream cut; a desktop song
  plays to its end and starts again from the beginning.
- `PlaybackAnomalyRecorder` watches for this without changing playback. It
  prints a record when the position of the same song moves back more than
  2 s with no seek, navigation, loop or stop to explain it (`backwardJump`),
  or when a song that reached its last 10 s plays again from under 3 s within
  10 s (`replayNearEnd`, same entry or another entry holding the same song,
  never Repeat One). One record per kind per song, at most 20 per run.
- Read it: records go through `debugPrint`, so they print in release and
  profile builds too (`AppLogger` drops everything without asserts and is not
  used). On Android: `adb logcat -s flutter | grep PLAYBACK_ANOMALY` (logcat
  tag `flutter`). On desktop: the process stdout, or
  `journalctl --user -f | grep PLAYBACK_ANOMALY` under systemd. The first line is a JSON header (`kind`, `fromMs`, `toMs`, `sourceKind`,
  `loopMode`, `shuffle`, `crossfade`, `gapless`, `processingState`,
  `sameEntry`); each following line is one transport event of the last 30 s,
  with `t` in ms relative to detection (`pb` playback events with
  `updatePositionMs`/`updateTimeAgoMs`, `pos` samples, `disc`, `index`,
  `seek`, `seekDone`, `recovery`, `stall`, `reload`, `restartCompleted`).
  Records hold no URLs, song ids, titles or account data. Windows has no
  console, so use the diagnostics API there.
- `GET /v1/playback/status`: `anomalies` holds the last 5 records. Only the
  newest carries its events; older ones keep the header and an `eventCount`.

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

## Mix and Instant Radio troubleshooting

**Server Mix** uses portable Subsonic similarity first. An empty batch can
mean the server has no recommendations for that seed, including while a server
plugin is still indexing. Try another song or use **Instant Radio**, which can
draw from eligible liked, recent, and local songs. The client does not infer a
plugin's analysis progress from an empty response.

**Last.fm · Same Vibes** needs a valid Last.fm key to use Last.fm matches.
Last.fm has no similar tracks for most songs released since about 2015, so for
those Navis mixes from the top tracks of similar artists (the debug log shows
`source=artistSimilar`).
When the service has only a few playable library matches, Navis keeps them
and fills from standard server similarity where available. A rejected key or
rate limit is shown as an actionable failure rather than retried on every
playback update.

Home's **Liked only** and **Downloaded only** filters apply to every Instant
Radio track. Downloaded only requires a permanent file; ordinary offline
radio can also use a valid rolling-cache file. If radio reports no eligible
music, relax the filters or download more songs. A catalog listing by itself
does not make an offline song playable.


## Library content after a server rescan: scan, sync, repair, review, and cache reset

Use the right tool for each failure mode:

- **Server scan changed files or IDs.** Navis observes the server's scan
  status during scheduled checks. After a completed scan, the next eligible
  check collects and promotes a fresh snapshot automatically; no action is
  required. If collection overlapped a scan, promotion is deferred and the
  snapshot recollects safely.
- **Navis synchronization stale or interrupted.** Use
  Settings → Sync → Check for updates. It runs bounded discovery and reports
  partial progress; the remainder stays queued for the next check.
- **Repair Library.** Use Settings → Sync → Repair Library when the local
  catalog looks structurally wrong (wrong albums, drifted metadata, repeated
  failures). It runs in the background from Sync Settings, keeps downloads and
  the committed library browsable, and relinks proven replacements while
  preserving favorites and ratings. On mobile data it asks once per repair;
  that approval covers its own retries and survives brief disconnects, and is
  always cleared on completion, cancellation, sign-out, or restart.
- **Unavailable items review.** Items the server no longer reports but that
  still own favorites, history, or downloads appear in
  Settings → Sync → Unavailable items. There you can find a replacement match
  manually, keep an item for later, or remove it from Liked. Navis never
  deletes these silently.
- **Cache reset.** Destructive and last-resort: it erases recoverable caches
  and rebuilds the library, and is only needed for the explicit
  cache-upgrade/reset prompts. Ordinary repair does not clear artwork or
  downloaded audio.

If artwork looks wrong after a rescan, run Repair Library once: it refreshes
covers whose entries changed without clearing the rest of the artwork cache.
