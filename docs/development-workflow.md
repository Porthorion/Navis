# Development Workflow

This document defines the local workflow expected before opening or merging changes.

## Bootstrap

Run once after clone:

```bash
./tool/bootstrap.sh
```

What it does:
- validates `flutter` and `dart` are installed
- checks the Flutter 3.47.5 minimum and active 3.47.x baseline
- resolves root and owned Flutter packages plus CargoKit development dependencies

## Bundled licence notices

`registerBundledLicenses` in `lib/src/app_licenses.dart` owns notices for
non-Dart assets and native libraries. Its tests cover platform filtering and
the enabled Windows/Linux LGPL notices and optional system-library flag
without starting the application. Regenerate Windows Rust notices with `python3 tool/generate_rust_notices.py`; fetch the
locked dependencies first, then commit `assets/licenses/windows-smtc-crates.txt`.
The generator matches licence filenames case-insensitively and uses tracked
`tool/data/spdx/` full-text fallbacks when a crate has no licence file. No text
is fetched at generation or app runtime; unknown fallback identifiers fail.
See `release-windows.md` for the packaging procedure.

Windows libmpv uses an LGPL pin with verified Forgejo/R2/upstream fallbacks;
remote builds no longer seed the obsolete media_kit archive. Run
`cmake -P tool/libmpv_download_test.cmake` for offline cache, retry and cleanup
checks (downloads are simulated). Linux uses the same verified cache/fallback
approach; check it with
`cmake -DDOWNLOAD_SOURCE="$PWD/linux/CMakeLists.txt" -P tool/libmpv_download_test.cmake`.
Run `cmake -P tool/libmpv_bundle_test.cmake` for offline extraction/installation
and opt-out checks. See the Windows/Linux release guides for pin updates.
The Linux LGPL recipe under `tool/libmpv/` builds separately; normal app builds
consume the published archive and do not invoke Docker.

## Colour-name data

After updating the pinned MIT colour-name input, run
`dart run tool/generate_color_names.dart` and commit the generated table.
Provenance and input regeneration are in `tool/data/color_names/README.md`.

Desktop publisher metadata is Porthorion: Windows resource/Inno fields and
macOS copyright configuration. Local and remote Debian packaging share the
Porthorion maintainer default and Navis homepage; keep `tool/release.env.example`
in sync when changing that default.

## Branding Assets

`lib/src/icon/Navis_Logo.svg` is the canonical in-app mark. After changing it,
regenerate every raster and platform icon with:

```bash
./tool/generate_platform_icons.sh
```

The script requires ImageMagick and creates the light, dark, adaptive, and app
PNG sources before refreshing Android launcher/adaptive/status icons, iOS and
macOS icon sets, Linux hicolor icons, and the Windows ICO. It directly
downscales the macOS icon set after launcher generation so grayscale-alpha
artwork remains intact at every size. The launcher master is a dark circular
badge with a transparent outer canvas; Android legacy/adaptive, macOS, Linux,
and Windows outputs must preserve that transparency. iOS stays opaque because
shipping iOS icons cannot contain transparent regions. Open and inspect the
canonical mark, the Android notification icon, and representative
smallest/largest assets for each affected platform over both light and dark
backgrounds; non-empty files or successful generation alone do not prove the
artwork is legible, centred, or free of a baked square canvas.

For a Linux dev sidecar, refresh the user-level desktop entry, a
`~/.local/bin/navis` launcher, and the content-addressed icon without
launching the app:

```bash
./tool/dev_app.sh linux-icon
```

`./tool/dev_app.sh linux` performs the same refresh automatically. The
installed desktop file uses an absolute `Exec` path to that launcher so GLib
2.88+ and KDE/GNOME can resolve it even when `navis` is not on `PATH`. The
launcher execs only `build/linux/x64/release/bundle/navis`; build it with

```bash
./tool/dev_app.sh linux-release
```

which builds the app's own identity on the stable update channel (the
`tool/release.sh` defines) and refreshes the desktop entry. Until 1.4.1 the
launcher ran whichever release, profile or debug bundle was newest, and
every Linux diagnostics script rebuilds the profile bundle as a "Navis
Diagnostics" clone of a copied profile, so the desktop entry quietly opened
the last diagnostics clone, with its own database and the clone's download
folder rules (issue #45).
The content-derived icon name prevents Wayland compositor caches from retaining a
previous brand asset under the generic `navis` name.

Android uses the cache-busting `ic_launcher_navis` resource ID for both stable
and sideload/dev manifests. Keep that ID aligned across launcher generation,
the manifest contract test, and Android Auto manifest verification. Its
adaptive background remains transparent; the foreground owns the complete
circular badge.

## Android signing for local builds

Debug and profile builds retain debug signing when `android/key.properties`
is absent. Release tasks require that file, including aggregate Gradle builds
that select a release variant. For a deliberate local release-mode test only,
set `NAVIS_ALLOW_DEBUG_SIGNED_RELEASE=1`. `tool/dev_app.sh apk` and `dhu`
set this opt-in for their dev APK builds; set it to `0` to enforce real keys.
`tool/release.sh` always requires the properties file and verifies the signer.
Keep signing files, `.env` files and service-account JSON outside version
control; `.gitignore` covers their common names and extensions.

## Multi-OS Host Preflight

Android's pinned AGP 9.3.1 / Gradle 9.5.0 toolchain uses built-in Kotlin.
Retain `android.newDsl=false` for Flutter 3.47.5's remaining legacy variant API
calls. Revisit this setting with a future stable Flutter upgrade; do not enable
the new DSL or move to AGP 10 without a successful app/plugin build migration.

Before preparing artifacts for desktop + mobile targets, run:

```bash
./tool/multi_os_host_preflight.sh --doctor
```

What it does:
- checks toolchain prerequisites for cross-platform release hosts
- prints OS-specific install commands for missing SDKs/tools
- can run best-effort macOS autofix installs with `--auto-fix`
- optionally runs `flutter doctor -v` at the end
- reports missing Xcode Simulator runtimes as a warning (required for iOS simulator work, non-blocking for macOS desktop-only releases)

## Quality Gate

Run bootstrap before checking a fresh checkout. It also resolves development
dependencies in `third_party/navis_windows_smtc`,
`third_party/just_audio_media_kit`, and the nested CargoKit build tool. The root
dependency graph does not include these packages' development tools. For an
isolated package update, run `flutter pub get` in the corresponding Flutter
package or `dart pub get` in CargoKit before checking it.

For Rust changes, use the SMTC workspace manifest and its tracked `Cargo.lock`.
CargoKit passes `--locked` so a missing or stale workspace lock fails the build
rather than resolving new versions implicitly. Regenerate that lock explicitly
when upgrading Rust dependencies.
CargoKit's build tool (`third_party/navis_windows_smtc/cargokit/build_tool`)
is vendored upstream glue in a standalone Dart package with its own SDK
constraint, so the root gates neither analyze nor format it: from the
repository root the formatter would apply the enclosing `navis_windows_smtc`
language version instead of its own. For CargoKit changes, run
`dart format --output=none --set-exit-if-changed .`, `dart analyze` and
`dart test` in its build-tool directory after resolving it. Workspace-hash
regression tests cover dependency-only artifact invalidation and reject stale
member locks as the hash source.

Run before each commit/PR:

```bash
./tool/check.sh
```

Checks performed:
- Linux desktop-entry installer (`tool/linux_desktop_entry_test.sh`)
- Native EQ response/PCM fixtures (`tool/equalizer_native_test.sh`), using an
  available JDK or the Android Studio JDK selected by `ANDROID_STUDIO_JDK`
- Last.fm key masking (`tool/lastfm_key_defines_test.sh`) and the release
  artifact secret scan (`tool/scan_artifact_secret_test.sh`), with a fake key
  and synthetic artifacts
- Windows SQLite asset verification (`tool/sqlite3_windows_asset_test.py`)
- Diagnostics profile preparation (`tool/diagnostics_profile_test.py`): an
  isolated clone, including one from a profile older than schema 91, starts
  with Online services off
- Dart formatting (`./tool/dart_format.sh --check`): `lib/`, `test/`,
  `tool/` and the vendored `third_party/` path dependencies, which the root
  package config resolves to their own language versions; CargoKit is
  excluded as described above. The check never rewrites files; run
  `./tool/dart_format.sh` (or `make format`) to apply what it reports
- code generation (`build_runner`)
- static analysis (`flutter analyze --no-fatal-infos`)
- dead-code ratchet (`dart run tool/dead_code_check.dart`)
- migration and critical regression suites
- full tests (`flutter test`)

The dead-code CLI self-tests invoke its shared library entry point against
temporary fixtures in-process, avoiding a Dart subprocess compilation per check.

The script fails fast when `/tmp` is critically low to avoid misleading test hangs.

The dead-code gate checks public Dart declarations, l10n keys, declared file
assets and font families, missing files loaded from declared asset directories,
and direct dependencies. Generated Dart supplies references but no declarations.
References from release/dev scripts in `tool/` count as real use, excluding
`tool/dead_code_check.dart` and `tool/src/dead_code.dart`. Only `test/` and
`integration_test/` references classify a declaration as test-only. Production
code used only by tests must be deleted or marked `@visibleForTesting` as a
deliberate test seam; annotated declarations are excluded from all findings.
New findings (including test-only declarations), stale baseline entries, and
empty reasons fail. Record other deliberate exceptions with factual reasons in
`tool/dead_code_baseline.json`; `dart run tool/dead_code_check.dart --update`
preserves reasons and removes stale entries. It refuses unreasoned additions,
writing `tool/dead_code_baseline.pending.json` for review instead; an explicit
`--reason "text"` applies only to new entries. The baseline's `dependencyUses`
records the small CLI/builder exception list with reasons and checked evidence;
lint includes are detected from root and vendored analysis options.

The full suite includes the design-token ratchet
(`test/src/theme/design_token_guard_test.dart`). It fails when a file under
`lib/src/` (outside `lib/src/theme/`) adds a literal radius, `fontSize`,
`Color(0x…)` or palette `Colors.*` beyond its recorded count. It also fails
when a count drops until the baseline is lowered with:

```bash
NAVIS_UPDATE_TOKEN_BASELINE=1 flutter test test/src/theme/design_token_guard_test.dart
```

## Mandatory Runtime Validation

For exploratory Linux setup and sync routing, `./tool/dev_app.sh run -d linux`
accepts the isolated presets documented in
[Dev Testing Builds](dev-testing-builds.md). `--first-setup`, `--bad-cache`,
`--force-setup`, the full-screen rebuild entries, and deterministic
`--partial-album`/`--server-error` fixtures create disposable profiles under
`build/dev-sync-scenarios/`. The launcher uses profile-mode clone diagnostics,
so the normal local database, both rolling and cover-art caches, and the real
app-support directory are outside the reset path. Network gates can be seeded at process start with `--offline`
or `--metered` and changed through `dev_app.sh scenario` while it runs. These
interactive presets complement, rather than replace, bounded authenticated
diagnostics scripts and their assertions.

`./tool/check.sh` does not by itself prove that a runtime-affecting change is
complete. Agents must also run the built app, exercise the changed behavior
through an app-owned control surface, inspect the result, fix any gap, and
repeat from a clean restart. Documentation-only changes and metadata changes
proven not to affect runtime behavior are exempt.

### Validation loop

1. Write the acceptance scenario and the closest regression scenario before
   editing. For a bug fix, reproduce the failure through the running app when
   possible.
2. Add or update focused unit, widget, integration, or API-contract tests.
3. Run the relevant focused diagnostics script when one exists. Otherwise
   launch Navis with an isolated profile and use Linux for platform-neutral
   work.
4. Call `GET /v1/health` and require a successful authenticated response before
   testing feature behavior.
5. Drive the scenario through the running app's API. Check the response,
   observable provider/domain state, persisted side effects, relevant logs, and
   the absence of new errors. Use status endpoints or bounded polling instead
   of fixed sleeps for asynchronous work.
   For remote playback startup, inspect `startupAttempts` in
   `GET /v1/playback/status`. Its monotonic elapsed stages distinguish
   provisional persistence, source resolution, player apply, readiness, and
   first advancing position. The source kind and external flag are included;
   song identity and stream URLs are omitted. Compare the client timeline to
   server time-to-first-byte and download stages before attributing a delay.
   For rapid navigation, inspect the redacted `navigation` field in
   `GET /v1/playback/status`. Clone-only `POST /v1/playback/next` and
   `POST /v1/playback/previous` call the production handler and may be sent
   concurrently. Confirm desired and final indexes, pending state, timeout
   count, at most one pending queue mutation, and an advancing position after
   the last input.
6. For a visible Flutter change, call `POST /v1/presentation/screenshot`, open
   the resulting PNG with image-viewing capability, inspect the affected
   region, and record the result. Merely creating a PNG is not confirmation.
7. Use deterministic widget tests for behavior and Flutter semantics. Add
   component goldens when stable layout, clipping, painting, responsive, or
   color output is part of the contract.
8. Stop the app, fix implementation, visual, or observability gaps, reset the
   state as needed, and repeat from step 2. A missing control or observation
   endpoint is an implementation gap, not a reason to skip runtime validation.
9. When the focused loop passes, run `./tool/check.sh`, launch a clean app
   instance, and repeat the final acceptance and regression scenarios.

An **app API** is a control or observation interface executed by the running
Navis process and routed through the same production providers, controllers,
repositories, DAOs, and audio handlers as the UI. Unit-test method calls,
direct database edits, checking only that a process exists, and test-only state
changes that bypass the production path do not satisfy this requirement.

The clone-only `tool/sync_target_lane_diagnostics.sh` may prepare an isolated
database fixture with known future automatic and retry-cooldown deadlines before
launch. That is test setup only: its acceptance assertions use the running
app's authenticated `/v1/sync/automatic` and `/v1/sync/status` endpoints,
including after a clean restart, so they still exercise the production
controller and persistence path.
The same gate reads the bounded redacted `GET /v1/sync/ledger` trace. Its
`durableRuns` field is the cross-restart typed history (origin, intent, target
kind, plan kind, terminal outcome/reason, aggregate request/byte counts, and
timestamps and local request/attempt IDs); it must never contain credentials,
URLs, media/entity IDs, titles, or paths. Run history is a diagnostics record,
not a scheduler input; `library_sync_work` owns the durable queue. Use
`durableOperations` for the separate atomic destructive-mutation audit.

`tool/manual_discovery_diagnostics.sh` is the corresponding bounded
unchanged-cursor discovery gate. It may seed a copied, isolated database and
loopback fixture before launch, but its acceptance action is the running
app's authenticated `POST /v1/sync/check` while offline; it then restores
Wi-Fi and drives the production automatic entry point to resume that queued
manual discovery. It observes both transitions through authenticated status,
durable run history, correlated attempt telemetry, and minimal album-existence
APIs, renders the production detail route, and repeats after clean restart. The fixture must use the standard singular
`artist.album` response shape, because the production client is responsible for
normalizing that protocol shape before sync logic.
For the narrower partial-detail disappearance regression, run it with
`NAVIS_MANUAL_DISCOVERY_OMIT_EXISTING=1` and
`NAVIS_MANUAL_DISCOVERY_FORCE_MANUAL_RESUME=1`. That fixture omits an existing
sibling from `getArtist`, then the running app must add the newest-feed album
without deleting the retained sibling before or after restart.
The forced-manual variant also queues an isolated higher-priority album target
before Wi-Fi reconnect. Its explicit `POST /v1/sync/check` must still record a
`manualCatalogDiscovery` durable terminal run with catalog endpoint evidence
from its correlated attempt, retain the target as durable pending work, and drain that target only through its later
explicit target request.

`tool/repair_confirmation_diagnostics.sh` is the bounded deletion-safety gate.
It marks only its disposable fixture clone current for the library sync model,
so the clean restart tests the pending explicit confirmation rather than an
unrelated model-upgrade repair from an older source export.
The fixture uses the production ten-minute sync lease for the large local
promotion instead of the six-second diagnostics default.
It uses an isolated fixture to require the production repair confirmation
boundary, proves the committed catalog remains untouched across a clean
restart, then verifies that only the explicit confirming repair request
promotes the candidate and that the durable operation ledger records matching
safe before/after/removal counts. Its `repair-confirm-report.json` also checks
the database-canary read latency (p95 ≤ 100 ms, maximum ≤ 500 ms) during the
large repair. It is required after changing repair
promotion, deletion analysis, ledger recording, or the confirmation
presentation. Open the resulting Sync Settings screenshot and verify the
`Last library change` summary matches the authenticated ledger counts; a later
no-op operation must not displace that destructive-operation explanation.

Clone-only `POST /v1/presentation/system-back` delivers the same `popRoute`
message the Android embedding sends for the back button or gesture, and
`POST /v1/presentation/tab` with `{"branch": "home|library|search|settings"}`
sends a real pointer tap to the visible bottom-bar or rail destination. Both
return the location, Library section, player overlay stack and desktop history,
so phone and tablet navigation can be driven on an emulator without injected
OS input.

For reproducible marketing screenshots, `POST /v1/presentation/press
{"key":"<ValueKey>"}` presses a keyed onstage button through its own callback,
`POST /v1/presentation/screenshot {"label":…,"pixelRatio":"device"}` captures
at device resolution, `POST /v1/presentation/appearance` sets every Appearance
option, and `--dart-define=NAVIS_DIAGNOSTICS_SHOWCASE_SEED=<n>` fixes the Home
showcase order.

The navigate endpoint accepts only locations that match an app route. Library section
destinations use the canonical `/library?section=<name>` location, which the
shell maps to the production `librarySectionProvider` exactly as the sidebar and
navigation history do; the older `/library#<name>` form is still accepted and
normalised. The target-lane gate uses `/library?section=liked` to prove that
the Liked surface remains a local read: its status, aggregate catalog counts,
and controller ledger must remain unchanged across the online and explicitly
offline navigation traces.

The required precedence is: focused diagnostics script, existing authenticated
Navis endpoints, then a new narrow endpoint with contract tests and a focused
script. Do not search for an operating-system automation substitute when an
endpoint is missing.

AT-SPI, accessibility D-Bus traversal, Dogtail, xdotool, wmctrl, OCR/window
scraping, and similar external desktop automation are not app APIs. Do not
enable accessibility services, override `NO_AT_BRIDGE`, or change the desktop
session. AT-SPI is permitted only for an explicitly scoped platform
accessibility-bridge task with user authorization. **App-owned semantics** are
values returned by the diagnostics API or asserted by Flutter widget tests;
the live accessibility tree does not qualify.

### Runtime target selection

Use the same loop on every host, but select the authoritative adapter for the
behavior under test:

| Change | Required runtime evidence |
|--------|---------------------------|
| Platform-neutral app behavior | Linux app launch plus the app API |
| Visible Flutter UI | App API state plus an opened and inspected app-owned screenshot |
| Stable layout, color, clipping, or painting | Runtime screenshot plus deterministic component golden |
| Flutter accessibility semantics | Widget semantics tests; AT-SPI only when the platform bridge itself is in scope |
| Linux media-session integration | Linux app API plus MPRIS |
| Android or Android Auto | Linux startup smoke plus the Android media-session/MediaBrowser API on a device, emulator, or DHU as appropriate |
| Windows media integration | Linux startup smoke plus `tool/windows_smtc_diagnostics.ps1` on Windows and GMTC |
| macOS or iOS integration | Deferred by the project owner while Apple development is unavailable; record unverified Apple status |

### Temporary Android emulators

Agents may create a disposable Android Virtual Device for runtime evidence and
must delete it when the work is done. Shared emulators and their installed
sidecars can belong to other sessions: do not wipe, uninstall from, or stop
an emulator you did not start.

- Create the AVD by copying an existing AVD's `config.ini` (not its data) to
  `~/.android/avd/<Name>.avd/` with a new `AvdId`, plus a matching
  `<Name>.ini` whose `path` points there. `avdmanager` is not required. Raise
  `disk.dataPartition.size` (for example to 16G); Android refuses installs
  when less than about 10 % of the data partition is free.
- Boot it with `emulator -avd <Name> -no-snapshot -no-boot-anim -wipe-data`,
  wait for `sys.boot_completed`, and build x86_64-only APKs
  (`--target-platform android-x64`) for it.
- Install only sidecar packages; grant the notification permission to a
  diagnostics sidecar (`pm grant <package>
  android.permission.POST_NOTIFICATIONS`) so the prompt does not block its UI
  bootstrap.
- When finished, stop it with `adb -s <serial> emu kill` and delete
  `~/.android/avd/<Name>.avd` and `<Name>.ini`.

MPRIS, SMTC, MediaBrowser, and corresponding Apple interfaces are authoritative
only for their OS-owned integration. They do not replace the Navis API for
ordinary Flutter state. If the affected target is unavailable, mark the work
unverified or blocked; only the user may explicitly accept deferred validation.
The owner has accepted ongoing deferral of Apple checks in this development
environment. Do not request an Apple host as a prerequisite for completing
non-Apple development; do not record an Apple native build/runtime as passed.

### Shuffle parity diagnostics

Run `python3 tool/shuffle_parity_diagnostics.py` after changing shuffle, queue
order, or the media_kit adapter. It serves a 40-song loopback fixture, launches
an isolated muted Linux profile against an empty database, turns shuffle on,
presses Next five times and lets two tracks advance on their own. Each sample
compares the reported `songId` with the song mpv is playing
(`native.mediaKitCurrent`, reduced to the stream `id` or cache file name so no
credential-bearing URI is reported). It then queues 2,000 songs (the album 50
times), jumps far ahead, near, far back and to both ends, presses Previous 40
times across the released head and lets songs play on; those samples also
check the reported `currentIndex`, that `deferredHeadLength` +
`materializedLength` + `deferredLength` equals the queue, and that
`playerSequenceLength` stays within the released window. The run writes
`build/shuffle-parity-diagnostics/<timestamp>/report.json` and exits 1 when any
sample or control call disagrees. `NAVIS_PARITY_BUNDLE` runs a built profile
bundle instead of `flutter run`.

Clone-only `POST /v1/downloads/enqueue {"songIds": [...]}` queues permanent
downloads through the production download service (a song already in the
rolling cache is promoted instead of downloaded), for download and
interruption checks without driving the UI. Optional `"quality": <kbps>` and
`"format": "mp3"|"aac"|"opus"` request a transcode; `"usePreference": true`
applies the saved download quality instead, as the app's download actions do.

`GET /v1/downloads/status` reports the queue (counts by status and each item's
id, song, status, quality, format and retry count), whether it is paused, the
configured and effective concurrency, the queue ids in progress, the most
downloads seen running at once (`peakActive`), the saved quality preference
and prompt flag, permanent downloads (song, format, bitrate and file base name
only) and the number of stored download covers. Clone-only
`POST /v1/downloads/settings` accepts any of `maxConcurrent`, `paused`,
`qualityMode` (`ask`|`original`|`transcode`), `bitRate`, `format`, `prompted`
and `resetPeak`, through the same service and settings methods as the
Downloads screen, and clone-only `POST /v1/downloads/cancel {"queueId": n}`
cancels one item like the queue's Cancel button. Both return the status.
`tool/download_preferences_diagnostics.sh` drives these against the loopback
fixture server.

A clone copies the source profile's settings, including a custom Downloads
folder that is the user's real one. The download service starts at launch and
moves permanent downloads into that folder, so in clone mode
`AppSettingsDao` reads a filesystem download folder outside
`NAVIS_SYNC_DIAGNOSTICS_ROOT` as unset (Android tree URIs are left alone).
Downloads then stay in the clone's app-support folder under the run root, which
`sync_diagnostics.sh` checks after the run. To test a user folder, point the
clone at a folder inside the run root.

Clone-only `POST /v1/playback/shuffle {"enabled": bool}` and
`POST /v1/playback/repeat {"mode": "none"|"one"|"all"}` drive the production
handler. `GET /v1/playback/status` reports the user's `shuffleEnabled` and,
under `native`, the native index, the native shuffle flag (always false: Navis
owns shuffle, so the native sequence is the play order),
sequence ids (first 64), effective order and `mediaKitCurrent`.

### Stream open diagnostics

Run `python3 tool/stream_open_diagnostics.py` after changing the media_kit
adapter's mpv properties, the libmpv build, or how desktop opens remote
streams or radio. It serves a loopback Subsonic fixture whose `stream.view`
returns 404 for one song, puts a recording `yt-dlp` stand-in first on the
app's `PATH`, and launches an isolated muted Linux profile. It plays the 404
song and requires that the stand-in was never run and the app log has no
`ytdl_hook` line, then requires an ordinary uncached song to advance. Finally
it opens Library > Radio and starts the fixture's Azuracast-style ICY station
(`/listen/fixture/radio.mp3`, `icy-metaint` interleaved MP3) through the
station card. It then requires advancing playback, an `Icy-MetaData: 1`
request, a `/api/nowplaying/fixture` poll and a clean stop. The stand-in records
its argv with `u`, `p`, `s` and `t` values redacted; the
`radio-playing` screenshot should show the fixture's now-playing text. Results
go to `build/stream-open-diagnostics/<timestamp>/report.json`, with exit status
1 on any failed check. Last, it starts a second station whose stream is
served over HTTPS with a throw-away self-signed certificate and requires that
the TLS server sees the connection, that no request completes (libmpv refuses
the certificate) and that the station never plays. It then turns Online
services off (`POST /v1/presentation/integrations {"master": false}`) and
starts a third station whose stream host is `localhost` rather than the
server's `127.0.0.1`: the fixture must see no request from it, radio mode must
stay off, and the `radio-blocked-online-services-off` screenshot should show
the notice explaining why. The station on the server's own host must still
play with Online services off. On Linux it also reads the app's
`/proc/<pid>/maps` and requires that the only libmpv loaded is the bundle's
LGPL `lib/libmpv.so.2`. The radio stream needs
`ffmpeg` with an MP3 encoder and the certificate needs `openssl`.

While an internet radio station is active, authenticated
`GET /v1/playback/status` includes a `radio` object; it is `null` outside radio
mode. Fields are `stationId`, `stationName`, `streamHost` (host only, without
port, path, credentials or query), `metadataSource` (`azuracast`, `icy` or `none`
for the most recently applied metadata), `nowPlayingTitle`, `nowPlayingArtist`,
`nowPlayingArtHost` and `nowPlayingArtHash` (the artwork shown by the app, null
when absent or refused by policy), and `publishedArtHost` and `publishedArtHash`
(the current `MediaItem.artUri` only when its ID matches the active station,
null when absent or while a new station loads). Artwork hosts omit port,
userinfo, path, query and fragment. Artwork hashes are the first 16 hexadecimal
characters of SHA-256 of the full URL: compare hashes to verify displayed and
published artwork agree, or differ from the previous station's artwork, without
exposing URLs or credentials. The station fields use current handler state even
before its next snapshot broadcast. Title,
artist and artwork may be null before metadata arrives. A successful AzuraCast
station retains its metadata during transient API failures; two initial API
failures fall back to available ICY metadata. Integration policy changes stop
or resume polling for the current station without reopening the audio stream.
Re-enabling resumes polling for working or still-unconfirmed now-playing
services; an unconfirmed service gets a fresh two-failure probe budget. A service
rejected after two initial failures stays on ICY metadata until the station is
restarted, which retries detection.
When radio now-playing lookups are off, the API title, artist and artwork are
replaced by the stream's ICY title/artist (`metadataSource: icy`) or cleared
(`nowPlayingTitle` and `nowPlayingArtist` null, `metadataSource: none`), with the
station name used for display. On desktop, the vendored media_kit
adapter obtains ICY titles from libmpv's observed metadata properties; genre
metadata is ignored.

### Artist playback diagnostics

Run `python3 tool/artist_playback_diagnostics.py` for the artist queue regression.
It copies the configured database into a disposable profile, points only that
copy at a loopback Subsonic fixture with three releases, and starts with tracks
for one release. It verifies playback starts before hydration completes,
uninterrupted queue growth, whole-artist Play and Shuffle, persisted queue
membership, advancing native and remote playback, repeated append occurrences,
automatic partial recovery, an expanded cached release, offline unavailable
rows, and clean restart. App-owned compact progress, queue, and complete screenshots and
redacted results are stored under `build/artist-playback-diagnostics/`; inspect
those PNGs before handoff. The fixture uses process-local credentials and muted playback.

Authenticated `GET /v1/artists/playback/status` returns preparation stage, counts,
elapsed time, and completeness flags without artist/album IDs or request errors.
Clone-only `POST /v1/artists/playback` accepts `command=prepare` with `artistId`
and `action=play|shuffle|add`, or `command=cancel` for a pending selection.
Clone-only `POST /v1/presentation/artist-action` activates mounted
`play`, `shuffle`, `cancel`, or the desktop `queue` control. These endpoints
exercise the production controller and buttons; they do not supply queue rows.

### Performance diagnostics

`tool/perf_diagnostics.py` measures frames, memory, provider lifetimes,
playback startup, queue fill, local search and cold restart against a real
Subsonic server with an isolated profile. Every wait inside it is bounded and a
run ends with one `summary.json`/`summary.md` under
`build/perf-diagnostics/runs/`, so it can run in the background without
polling.

```bash
NAVIS_PERF_CREDENTIAL_FILE=build/perf-diagnostics/credentials.json \
  python3 tool/perf_diagnostics.py --label before
```

- The credential file is a mode-600 JSON object with `url`, `username`, and
  `password`. Keep it under the ignored `build/` tree. The password is written
  only to the clone's mode-600 credential file and sent only to
  `POST /v1/session/connect`; it is never logged.
- The default profile clones the normal Navis database once into
  `build/perf-diagnostics/profile` and points the clone at the credential
  file's server and user. `--fresh` starts empty and measures the first sync
  instead, then keeps a `golden.sqlite` snapshot of the synced catalogue.
  Later runs restore that snapshot (when present) and clear the saved queue,
  downloads, and custom download folder, so remote hydration or adopted
  files from an earlier run never change the next run's workload.
- `--scenarios` selects from `idle`, `queue2k`, `queue10k`, `library`,
  `search`, `artist`, `artist-remote`, `folder-import`, and `cold`.
  `--refresh-golden` launches once, lets migrations and startup maintenance
  bring the derived indexes up to date, and saves that as the golden
  snapshot, so later runs measure steady state rather than a one-off rebuild.
  `--skip-build` reuses the last profile build; `NAVIS_PERF_BUNDLE` (Linux) or
  `NAVIS_PERF_APK` (Android) runs a saved build instead, for example an
  unmodified baseline.
- `artist-remote` opens the artist named by `NAVIS_PERF_REMOTE_ARTIST`
  (default `SQUARE ENIX MUSIC`, which has many remote releases on the test
  server), waits for its release metadata, presses Shuffle through
  `POST /v1/presentation/artist-action`, and opens the Queue every five
  seconds while releases hydrate, timing the first frame that shows it
  (`"settle": false` on `POST /v1/presentation/player-overlay`).
- `folder-import` builds `--folder-files` (default 400) small files named
  `<artist>/<title>.<suffix>` from the catalogue (FLAC files get a minimal
  header) and adopts them through `POST /v1/downloads/folder/adopt`, which
  runs the same `CustomDownloadFolderController.choose` as choosing a folder
  in Downloads (preview, configure, import, then the Manual Matching scan) and
  reports `totalMs`, item dispositions and `manualMatchingPending`.
  `GET /v1/downloads/folder/status` reports `enabled`, `configured` (no path),
  `busy` and `manualMatchingPending` from the persisted settings.
  On Android it stages them into the profile-only SAF fixture provider and
  writes `NAVIS_PERF_SAF_LATENCY_MS` (default 2) as a per-call delay, so the
  in-process fixture behaves like the real external-storage provider.
- `--android <serial>` builds and installs the `com.navis.app.navis.perf`
  profile sidecar, keeps its database in private internal storage, and drives
  the same scenarios over `adb forward`. `--android-seed` copies the synced
  Linux profile database into the sidecar first.

The report fields it relies on are part of the authenticated diagnostics API:
`GET /v1/diagnostics/report` includes frame p50/p95/p99 with `over16ms` and
`over33ms` counts, a `frameWindow` rate since the last
`POST /v1/diagnostics/metrics/reset`, `imageCache` usage, and `providers`
(live provider counts and the largest provider families, without family
arguments). `POST /v1/diagnostics/heartbeat {"enabled": true}` requests every
frame and records the wall-clock gap between frames (`frameGap`) and event
loop lag (`eventLoopLag`); a blocked UI or merged platform thread produces no
frames, so frame timings alone cannot show a freeze. The report also counts
`playbackCounters` (snapshot broadcasts, queue emissions and their items,
native player operations) and `tableUpdates` (Drift change notifications per
table) since the last reset. `GET /v1/playback/status` includes `playerSequenceLength`,
`materializedLength`, `deferredLength`, `queueFill` stage timings, and
persistence-lane counts. Read-only
`GET /v1/diagnostics/local-search?query=` times the production local artist,
album and song searches and returns only counts and durations.

Read-only `GET /v1/diagnostics/integrations` answers "is this slow because of
Navis or the API" for every external call. It is available in all diagnostics
modes and returns `counters` per service key (`requests` that left the device,
`blocked` by the policy, `errors` among the requests and `totalMs`), the last
100 `calls` (`service`, `method`, `path`, `status`, `ms`, `outcome`, `blocked`,
`at`) and the last 50 `spans`: named pipeline phases with the sizes they
handled. `outcome` is `ok`, `error` (the request failed or had an error
status), `serviceError` (a success status whose body reports an error: Deezer
answers HTTP 200 with `{"error": {...}}`, so a quota hit, code 4, shows here
with `status` 200; Deezer's code 800, "no data", stays `ok`) or `blocked`.
`errors` counts both `error` and `serviceError` calls. The `artwork` service
includes every external image fetch through the shared artwork HTTP file
service: external artwork widgets (artist, Deezer, ListenBrainz and station
images), Now Playing art and dynamic accents, Windows SMTC, AudioService's OS
art cache and `PlaybackArtCache`. Each external redirect hop is a separate
call; successful image durations include body consumption. HTTP/transport or
invalid-image failures are `error`, with the HTTP status when available. A
policy refusal at an image lifecycle or fetch boundary, after a queue wait or
on a redirect is `blocked` and adds no `requests`. Blocked counters count
distinct refusals by service, host and redacted path within the policy epoch,
using a bounded 200-destination LRU. Rebuilds and repeated system permission
checks add no records; a policy change or eviction from that LRU permits a
new refusal record. Own-server images and cache hits add no requests. Artwork
uses the same path-only redaction (including `/user/` and `/users/` identifiers):
no userinfo, query, fragment, headers or body is retained.

Artist Top Songs records
`topSongs.sourceFetch` (`seeds`, `cacheHit`, `deezer` 1 when Deezer supplied
them, `failed` 1 when the fetch threw, and per step `top`, `searchFill` and
`lastFm` songs), `topSongs.localMatch` (`seeds`, `cached` remembered matches
used,
`candidates` library rows read, `localHits`) and `topSongs.serverMatch`
(`unresolved`, `search3Calls`, `matched`, `remote`, and `upgradeChecks` /
`upgraded`: remembered remote matches searched again for a copy on the
server, and how many found one). The section records them for its ten songs;
the "This Is" page records them for up to 50. Trending Now records the same
pair as `trending.localMatch` and `trending.serverMatch`. The recorder
keeps the path only, never the host, query string, headers or body (Last.fm's
`api_key` lives in the query, Deezer's searched name too, and ListenBrainz
sends `Authorization`), and every call is also logged at info level, which release
builds drop. The buffer lives in memory for the process, so read it right after
the navigation being measured.

### Windows SMTC diagnostics

Run `tool/windows_smtc_diagnostics.ps1` from an isolated current-build
directory on Windows. It requires an isolated copy of a configured database,
an explicit diagnostics credential file, and two playable local song IDs. The
script starts a profile build with the authenticated diagnostics API, then uses
Windows Global Media Transport Controls (GMTC)—not desktop automation—to verify
Navis’s AppUserModelID, metadata, capabilities, transport commands, seek,
shuffle/repeat, timeline progress, and clean restart. Seek uses WinRT ticks
from `TimeSpan`, pauses playback first, and requires the app position to remain
within 500 ms of the five-second target; elapsed playback cannot satisfy this
check. Launch arguments are quoted individually to preserve the diagnostics
app name and paths containing spaces. WinRT types use explicit metadata
qualification and async result types so Windows PowerShell 5.1 COM wrappers
work correctly. After a clean restart it requires the
restored current song and actual GMTC play/pause delivery again. It captures
app-owned screenshots before and after restart. It writes only under its
specified output root and never prints the bearer token, server URL, or media
metadata.

Run it with Windows PowerShell in a multithreaded apartment from the signed-in
desktop session (GMTC is per interactive session, and blocking WinRT calls in
the default single-threaded apartment are cancelled). Over SSH, start it with a
scheduled task that uses an `Interactive` principal. It first turns shuffle and
repeat off through GMTC, so a source database from an earlier run cannot change
the Next and Previous targets.

```powershell
powershell.exe -MTA -File .\tool\windows_smtc_diagnostics.ps1 `
  -SourceDatabase C:\path\to\navis.sqlite.sqlite `
  -CredentialFile C:\path\to\diagnostics-password `
  -SongId first-song-id -SecondSongId second-song-id
```

### Desktop app API

For repeated desktop tooltip accessibility failures, run
`./tool/presentation_diagnostics.sh clone / tooltip-semantics`. It exercises
all four persistent player action tooltips three times on Home, with app-owned
semantics enabled, captures the hovered tooltip, and repeats after clean restart.
The authenticated clone-only `POST /v1/presentation/tooltip` accepts `target`
values `favorite`, `lyrics`, `queue`, `miniPlayer`, or `null` to dismiss. It
dispatches Flutter mouse events to the production controls; it does not use the
operating-system accessibility bridge. Inspect both `*-tooltip` screenshots.
The runner rejects Flutter exception banners and the `node.built` and
`!child.attached` assertion signatures in its runtime log.

When writing a new shell diagnostics script, source
`"$PROJECT_DIR/tool/lib/diagnostics.sh"` after computing `PROJECT_DIR` and reuse
its compatible helpers. The library documents caller-owned globals and arguments;
keep scenario-specific traps, messages and dart-define arrays in the script,
and retain local helpers when their behavior differs from the shared version.

Linux and Windows profile diagnostics share the authenticated control-plane
contract. Android production builds remain observation-only. The planned SAF
download-folder diagnostics must be sidecar-only, restricted to an emulator
fixture tree, reject arbitrary paths, and never be enabled by the stable
package.

The profile source set contains the profile-only
`NavisDiagnosticsDocumentsProvider`. Its fixture tree lives under the profile
app's scoped files directory and is intentionally absent from debug and
release packages; Android requires document providers to be exported, so use
it only through the profile-sidecar diagnostics flow.

SAF fixture mutation is deliberately bounded: diagnostics can configure that
single tree, download a fixture-library track, detach/re-import known cache
ownership, and stage an unindexed copy for inaccessible-document review. The
unindexed copy never becomes a stable-package feature or arbitrary-path file
writer; it exists only to exercise a real `ContentResolver` read failure while
the tree remains otherwise usable.

- `SyncDiagnosticsServer` is enabled only for a supported profile build with
  valid diagnostics defines. Any future Android mutation diagnostics require a
  sidecar package suffix as an additional guard.
- `tool/sync_diagnostics.sh clone` demonstrates the supported isolated launch,
  while `tool/sync_diagnostics.sh throughput` measures one isolated Repair
  Library run without cancellation/restart scenarios affecting its result.
  `tool/sync_diagnostics.sh full-rescan` executes a full Repair Library run
  against an isolated copy of the configured library, records one-second
  planning/hydration traces, clears stale candidate/work rows only in that
  clone so the requested repair starts fresh, and captures the initial
  preparing Flutter frame.
  `tool/sync_diagnostics.sh cache-alias` seeds a cached provisional song only
  in the clone, hydrates its canonical album from the configured server, and
  asserts alias and cache ownership migration.
  handshake, authenticated requests, restart, reporting, and shutdown flow.
- `tool/repair_confirmation_diagnostics.sh` covers the explicit large-deletion
  confirmation lifecycle in an isolated fixture: pending confirmation,
  restart persistence, deliberate confirmation, and atomic promotion.
- `tool/sync_target_lane_diagnostics.sh` launches one isolated Linux clone,
  drives repeated Home-to-Library navigation and then sends
  `POST /v1/sync/target` through the production controller. It asserts neither
  action changes catalog status, verifies distinct automatic and retry
  deadlines, captures Sync Settings, and repeats the health/status/ledger/
  screenshot checks after a clean restart, where the reported deadlines must
  match the persisted sync-state row. It accepts the optional private
  `NAVIS_DIAGNOSTICS_CREDENTIAL_PATH` password file when desktop secure
  storage is locked. Use it when changing navigation,
  catalog/target scheduling, cooldowns, or global sync presentation.
- Current observation endpoints include `GET /v1/health`,
  `GET /v1/sync/status`, `GET /v1/playback/status`,
  `GET /v1/playback/bootstrap/status`, and
  `GET /v1/diagnostics/report`. Actions use feature-scoped `POST` endpoints;
  `POST /v1/shutdown` provides clean termination.
- Presentation automation uses clone-only `GET /v1/presentation/status`,
  `POST /v1/presentation/navigate`, and
  `POST /v1/presentation/screenshot`. Navigation accepts local app routes;
  status distinguishes render-boundary readiness from the post-bootstrap app
  frame, while screenshots capture the Flutter surface at a deterministic 1.0
  pixel ratio and return only protected artifact metadata. Desktop-layout
  captures re-observe that ready surface after resize or restart transitions
  before recording final visual evidence, so an intermediate compositor frame
  cannot count as a clean-restart screenshot.
- Clone-only `POST /v1/presentation/search` submits a real query through the
  production Search providers, navigates to `/search`, waits for the final
  cached/API merge, and returns sanitized ordered IDs, relevance tiers, and
  on-server/remote classifications for acceptance assertions.
- The narrow `POST /v1/presentation/player-overlay` action shows or hides the
  queue or Now Playing through `playerOverlayStackProvider`; add similarly
  narrow production-controller actions for non-route UI instead of simulating
  coordinate clicks.
- Clone-only `POST /v1/presentation/playback-recovery` drives the production
  retry, cache-reset, and sign-out recovery controller after delayed playback
  bootstrap. It accepts only its bounded action names and never exposes
  session secrets.
- Clone-only `POST /v1/presentation/library-filter` applies a type-to-filter
  query through the mounted production Library screen. `{"query": ""}` or
  `{"query": null}` clears it and returns HTTP 200 with `query: ""` and the
  current `section`; whitespace-only strings also clear it. Non-empty strings
  are trimmed and limited to 64 characters; longer strings and non-string,
  non-null values and bodies without the `query` key return HTTP 400. Keyboard
  and diagnostics filters persist when the Library section changes, including
  tab, sidebar and route-driven changes. Repeating a diagnostics query after
  explicitly clearing applies it again.
  `NAVIS_PRESENTATION_LIBRARY_FILTER_QUERY='no-match'` on `/library` captures
  the real Albums filtered-empty state before and after restart. Together with
  the deterministic `radioPresentationFixture` override,
  `NAVIS_PRESENTATION_RADIO_FILTER_QUERY='no-match'` on `/library?section=radio`
  captures the Radio equivalent without querying or modifying the configured
  server.
- `NAVIS_PRESENTATION_ARTIST_TOP_TRACKS_FIXTURE=1` on an existing local
  `/library/artists/<artist-id>/top-tracks` route supplies four deterministic
  Last.fm-shaped rows through the production artist-top-tracks provider. It is
  clone-only and makes the populated detail layout reviewable without using a
  Last.fm key or querying the configured server.
- Clone-only `POST /v1/presentation/notice` sends one bounded status notice to
  the mounted global notice host. `NAVIS_PRESENTATION_ERROR_NOTICE=1` uses it
  to capture the persistent error treatment and its explicit Dismiss action;
  production code never writes the diagnostics provider.
- Desktop volume memory exposes `GET /v1/playback/volume`, clone-only
  `POST /v1/playback/volume` with a numeric `value` from 0 through 1, and
  clone-only `POST /v1/playback/volume/toggle-mute`. The status response
  reports controller, persisted, and handler values without exposing media or
  server data.
- Song-row presentation exposes the read-only
  `GET /v1/presentation/song-indicator?songId=<id>` endpoint. It reports only
  production indicator and presentation roles; it never returns song metadata.
- Mix validation uses clone-only, authenticated `GET /v1/mix/status` and
  `POST /v1/mix/start`, `/v1/mix/stop`, and `/v1/mix/retry`. Start accepts
  `mode` (`server`, `lastfm`, `radio`, or `selected`), a `seedId` for song modes,
  and optional `likedOnly`/`downloadedOnly` booleans for radio. Status reports
  mode, operation generation, seed, request stage, source, candidate and actual
  inserted counts, error category, and retry state, without credentials or
  server URLs. The clone has no Last.fm key by default. Set
  `NAVIS_DIAGNOSTICS_LASTFM_KEY_FILE` to an owned regular mode-600 key file
  only for an isolated authenticated Last.fm run. The diagnostics launcher
  rejects symlinks and permissive file modes.
  Clone-only `POST /v1/playback/queue` replaces the queue with `songIds` (at
  least two) and starts the first. A remote song the library lacks is fetched
  with `getSong` and stored provisionally, as playing a search result stores
  it, so a remote seed can be played before a mix starts; when the server
  answers with its library copy, the requested remote id is still the row
  stored and queued, with the copy's metadata but not its library album and
  artist ids. An id the server does not know returns 404 with that
  `songId`.
  Clone-only `POST /v1/playback/queue-index` accepts a bounded zero-based
  index to advance the production handler and exercise recommendation refills.

Authentication lifecycle work uses:

```bash
./tool/auth_lifecycle_diagnostics.sh clone
./tool/auth_lifecycle_diagnostics.sh partial
./tool/auth_lifecycle_diagnostics.sh existing-catalog
```

The script creates isolated database/cache profiles, uses the authenticated
`/v1/session/*` API to create a first-sync state through
`ServerDataResetService`, exercises offline recovery, captures app-owned setup
screenshots (each waits for the setup screen's own controller state from
`GET /v1/presentation/library-rebuild?reason=initial-login`; the retry after
the failed state presses that screen's Retry through
`POST /v1/presentation/library-rebuild`), waits for safe promotion, verifies a clean restart, starts real
playback, and signs out through `SessionLifecycleService`. A second clone
verifies initial-sync cancellation and restart at login. The clones use a
deterministic loopback Subsonic fixture and a mode-600 fixture credential file;
credential save/clear operations remain memory-wrapped and never modify device
secure storage. Clone diagnostics also use an empty process-local external
credential store and disable Last.fm, so saved ListenBrainz/Last.fm credentials
and personalized discovery services are outside the run. Direct database
changes are limited to pointing the isolated
fixture profile at that loopback process; lifecycle actions run through the
production app API and services.
The `partial` mode uses a second fixture album whose advertised count exceeds
the returned song list. It verifies that a safely promoted first catalog opens
Home with a separate usable marker and pending hydration, remains ready after
clean restart, then fills the missing tracks through the production automatic
sync path after the fixture response is corrected. It captures an app-owned Home
screenshot and keeps the full-sync timestamp null until verification completes.
With the incomplete response restored, it then visits all four full-screen
rebuild routes and verifies each partial catalog reaches Home with the album
still pending, using the durable run ledger for completion evidence.
The `existing-catalog` mode first completes a fixture setup, signs out with
kept data and back in through `POST /v1/session/connect`, and requires Home
without the setup route. It then removes data, makes the fixture album
incomplete so the automatic timer pass cannot finish setup, and signs in
again in the same process. The setup screen's own controller must record a
new catalog run and reach Home. Next it restarts, makes the fixture's second
album detail fail with HTTP 500 during a fresh setup so a catalog is promoted
without readiness evidence, and restores an incomplete response. It then
presses the screen's "Cancel and sign out" through
`POST /v1/presentation/library-rebuild` and signs in again. The new visit
must start automatically, record a `repairLibrary` catalog run (never
`manualCatalogDiscovery`), store the usable marker, open Home with the album
still pending, and stay ready after a clean restart. Session status observes
that same route-owned controller without starting setup. When setup does not
resume, the mode saves the route, controller state, ledger and a screenshot
before failing.
The `partial` mode's rebuild pass visits manual cache reset and Repair
Library a second time in the same process. Each visit must record its own
catalog run. The `clone` mode ends with a third profile that cancels a
waiting setup through `POST /v1/session/initial-sync/cancel` and signs in
again in the same process. Initial-sync actions use the mounted initial-login
rebuild controller, including its keep-data cancellation. The new route visit
must reach `complete` with the session `ready`; observing session status never
creates a setup controller. Cancellation evidence uses the completed sign-out
response, since fast teardown need not expose a transient `cancelling` frame.
The clone-only `POST /v1/diagnostics/sync-foreground` control sets the same
foreground admission provider as Flutter lifecycle events, allowing the
headless desktop fixture to exercise automatic work even when the window is not
focused. `POST /v1/diagnostics/automatic-sync-due` advances only the isolated
profile's durable check deadline so the production automatic entry point can
run immediately. Primary certification rejects both controls.
`GET /v1/sync/status` chooses the newer production-controller run when a UI
rebuild follows an older diagnostics-API run, and reports UI-triggered running
work as active. The durable ledger remains the cross-restart run history.
Session status is deliberately bounded to route/sync phases, queue counts, and
playback/activity flags; URLs, usernames, credentials, and tokens are forbidden.

The sync diagnostics script runs its own catalog test sequence. Its isolated
profile disables the separate destructive cache-layout upgrade route, so the
restart gate certifies committed-catalog preservation rather than performing a
cache reset. It also uses a short, heartbeated execution lease only in that
profile: the script first records the safe `leaseHeld` result after an
interruption, then retries once expiry permits recovery. For unrelated
features, add the smallest focused launcher or scenario script that reuses the
same lifecycle rather than pretending the sync sequence tested that feature.
Do not document or call an endpoint until its implementation and contract test
exist.

Use the generic presentation scenario for an app-owned runtime screenshot:

```bash
NAVIS_DIAGNOSTICS_PRIMARY_DB=/absolute/path/to/navis.sqlite.sqlite \
  ./tool/presentation_diagnostics.sh clone / home
```

It checks presentation readiness, navigates through the live `GoRouter`, then
waits for the acknowledged destination route and transient Flutter animations
to settle before it captures the requested route before and after a clean
restart, validates PNG
signature, digest, dimensions, containment, and permissions, and records the
artifact paths under `build/presentation-diagnostics/`. The agent must open and
inspect both PNGs; the script intentionally cannot certify visual correctness
from file existence alone.

For the responsive layout acceptance matrix, use:

```bash
NAVIS_DIAGNOSTICS_PRIMARY_DB=/absolute/path/to/navis.sqlite.sqlite \
  ./tool/presentation_diagnostics.sh clone / responsive-layout
```

This visits Home, Albums, Liked, Artists and Radio at 800×600 and 2560×1280,
then records Liked scroll position, Small/Large artwork and a filtered collection
on both launches. The large window fits within the local 2560×1380 work area;
window bounds are checked rather than treating a compositor-clamped resize as
success. It enables Artists/Radio only in the isolated clone. The authenticated,
clone-only `GET/POST /v1/presentation/appearance` endpoint accepts
`gridArtworkSize` (auto/small/medium/large),
`homeRecommendationsAutoAdvance` (boolean), `showArtistsPage` and `showRadioPage`
(booleans), and the shape settings `coverArtShape` (square/rounded),
`nowPlayingArtShape` and `artistCardShape` (square/rounded/circle). Updates use
targeted production DAO methods. The same endpoint also accepts `themeMode`
(system/light/dark/oled), `colorStyle` (neutral/pastel/immersive/night),
`colorSchemeSeed` (unsigned 32-bit integer or null to clear), `dynamicAlbumColor`,
`oledForAuto` and `flatSurfaces` (booleans), `cornerStyle`
(rounded/soft/square), `nowPlayingBackground` (tinted/artwork/plain), and
`density` (comfortable/compact). `flatAreas` is an integer mask 0–7;
`albumArtShade` and `albumArtColoredShade` are booleans. Colour tuning uses
`colorVividness`, `surfaceDepthLight` and `surfaceDepthDark` (integers
−5…+5, default 0), `surfaceTintLight` / `surfaceTintDark` (integers
0…5, default 0), and `controlColor` (`accent` or `white`, default `accent`).
All are returned by GET and accepted by POST; invalid values/types or unknown
keys reject the complete request before writes. Omitted axes retain their
values and targeted writes use `updateColorTuning`. The old branch-only `surfaceDepth` key is rejected.
GET also returns `selectedAppearanceLookId` and `appearanceLookCount`; the id
is derived by matching current appearance values. Looks are the only appearance
presets; tuning preset ids and counts are no longer returned.
Authenticated, clone-only `GET /v1/presentation/looks` returns
`{"looks":[{"id":"...","name":"..."}]}`. Clone-only
`POST /v1/presentation/looks/apply {"id":"..."}` applies the Look through
`AppearanceLooksController`, returns 200 with its id, or 404 for an unknown id.
Its three captured tuning values apply directly. Unknown keys or invalid id
types return 400;
normal authentication and mutation gating apply to both endpoints.
`nightSchedule` accepts a nonempty object
with any of `enabled` (boolean), `start` and `end` (integer minutes 0–1439).
Omitted fields retain their values. The entire body is validated before any
write; GET and POST return the resulting appearance values, including the
complete schedule. Normal authentication and `allowsMutations` gating apply;
unknown keys/types and primary certification are rejected.
The script verifies Small and enabled auto-advance persist across clean restart;
desktop recommendations remain manual even with that touch preference enabled.
Inspect the additional PNGs as well as the final pair; file validation alone
is not visual acceptance. Phone touch/carousel/orientation needs an isolated
Android sidecar; Linux resizing does not certify that runtime.

The authenticated, clone-only `GET/POST /v1/presentation/integrations` endpoint
reads and changes the external-integration policy (see "External integration
policy" in `docs/architecture.md`). `GET` returns `master`, `noticeDismissed`,
`disabled` (the sorted JSON set of disabled keys), and for every service and
feature its effective state: `switchOn`, `allowed` (features), `verified`
(services), `toggleable` and the `lock` reason (`masterOff`, `serviceOff`,
`notVerified` or null). `POST` accepts `{"master": bool}` and/or
`{"key": "<service or feature key>", "enabled": bool}`, with `key` and `enabled`
required together. Keys are allowlisted against the enum keys (for example
`deezer`, `deezer.topSongs`, `lastfm.sameVibes`); unknown keys, extra fields and
wrong types return 400. Writes use the production DAO methods, so a
column-backed feature such as `lrclib.lyrics` changes its own column. Primary
certification returns 403. Clone diagnostics scripts that copy a real profile
or build a synthetic one (`tool/perf_diagnostics.py`,
`tool/artist_playback_diagnostics.py`, `tool/playback_adjustment_diagnostics.sh`,
`tool/equalizer_diagnostics.sh`) set `external_integrations_enabled=0`
through `tool/diagnostics_profile.py` so measurements carry no
external-service traffic. A profile older than schema 91 gets the column
added as 0 before startup; the app's 90→91 migration keeps an existing column,
so the clone never starts with the master on. A run that measures an
external service, such as the Top Songs baseline, must turn the master switch
back on through this endpoint and read `GET /v1/diagnostics/integrations`.

The follow-up `responsive-polish` label exercises the actual album-card and
Liked Albums paging callbacks at 1366×900 and 800×600 before and after restart:

```bash
NAVIS_DIAGNOSTICS_PRIMARY_DB=/absolute/path/to/navis.sqlite.sqlite \
  ./tool/presentation_diagnostics.sh clone /library?section=liked responsive-polish
```

Its authenticated clone-only `POST /v1/presentation/library-action` accepts
exactly one `action`: `openFirstAlbum`, `nextLikedAlbums`,
`toggleFirstRadioStation`, `weeklyPlay` or `weeklyLastRow`. It invokes only
the existing onstage album-card callback, the Next button within the keyed
Liked Albums shelf, the first onstage Radio station card's own tap callback
(which plays that station, or stops it when it is already playing), the weekly
playlist page's Play button (`weeklyPlayButton`), or the tap callback of the
last weekly track row that can be played (`weekly-row-<index>`, which follows
Album Queue); arbitrary keys, coordinates and other actions are rejected.
With `cachedListenBrainzPresentation` and a seeded weekly cache, read
`GET /v1/playback/status` afterwards for the queued song ids and start index.
Unavailable controls fail explicitly. The endpoint does not construct a queue,
directly write library data or bypass navigation owners. Inspect every extra screenshot,
including the wide numbered header and the before/after paged shelf. Timed
widget tests verify the transition itself; settled screenshots do not measure
animation duration.

For mobile track-layout diagnostics, clone-only
`POST /v1/presentation/track-action` accepts exactly one `action`: `scrollToLast`,
`revealFirst`, `more`, `download`, `downloadedTab`, `downloadsSettingsTab`,
`downloadsQueueTab`, `customFolderOff`, `confirmCustomFolderOff`, `dragFirstToLast`,
`downloadQuality320`, `downloadQualityAlwaysUse`, or
`downloadQualityAlwaysAsk`. It
exercises mounted shared rows through their scroll owner, menu/download callbacks, Downloads tab
controller, or Flutter touch events on the playlist drag handle. The custom
folder actions call the Downloads settings switch's own callback, only when it
is on (turning it on would open the system folder picker), and press the
turn-off dialog's own confirm button. The download-quality actions call the
open quality picker's 320 kbps row and the one-time "always download in this
quality?" dialog's own buttons. It accepts no
coordinates, arbitrary widget keys, track IDs or destructive delete action.
Missing controls fail explicitly; primary diagnostics reject every mutation.
Use a populated isolated emulator fixture, inspect app-owned captures at phone
and landscape dimensions, and distinguish these from component-only coverage.

To validate a mandatory cache-contract renewal without modifying the primary
profile, use `cache-upgrade` as the label. The isolated clone starts with its
cache marker removed; the script requires the router to hold the initial
navigation on the rebuild route, waits for the screen's production rebuild to
clear the read-only renewal state, then requires the clean restart to reach
onboarding or Home as appropriate:

```bash
NAVIS_DIAGNOSTICS_PRIMARY_DB=/absolute/path/to/navis.sqlite.sqlite \
  ./tool/presentation_diagnostics.sh clone / cache-upgrade
```

To validate the full required-rebuild → onboarding → Home warm-up path, use
`home-warmup`. It removes the cache marker and makes setup pending only in the
isolated clone, waits for the bounded six-cover warm-up to report all selected
cache entries ready, completes onboarding through the production completion
service, verifies that the aggregate warm-up state remains ready on Home, and
captures both the warmed onboarding and Home frames:

```bash
NAVIS_DIAGNOSTICS_PRIMARY_DB=/absolute/path/to/navis.sqlite.sqlite \
  ./tool/presentation_diagnostics.sh clone / home-warmup
```

The diagnostic response contains aggregate target and ready counts only; it
must never expose cover IDs, titles, paths, URLs, or credentials. Open the
resulting Home screenshot as part of the runtime validation loop.

To validate seamless playback startup recovery, set
`NAVIS_DIAGNOSTICS_AUDIO_BOOTSTRAP_FAIL_ATTEMPTS=2` for the same clone-only
presentation command. The launcher injects two failures before audio-handler
construction, asserts the authenticated bootstrap status reports a scheduled
retry, captures the still-loading gate, then verifies normal post-bootstrap
presentation after recovery.

To validate the user recovery controls, inject four failures and set
`NAVIS_PRESENTATION_BOOTSTRAP_RECOVERY=1`. The launcher waits past the
ten-second threshold, captures the startup-recovery UI, drives its production
retry controller through `POST /v1/presentation/playback-recovery`, and then
verifies normal presentation after the fresh bootstrap attempt.

For `/library/listenbrainz/<sourcePatch>` routes, the script enables a
clone-only cached-playlist presentation override through the authenticated
diagnostics API. Navis reads the most recent weekly cache through the
production discovery provider, without copying a ListenBrainz token or
returning the cached username, so remote/local row alignment can be inspected
before and after restart.

For a Search scenario, set `NAVIS_PRESENTATION_SEARCH_QUERY`, navigate to
`/search`, and optionally require both source classes with
`NAVIS_PRESENTATION_SEARCH_REQUIRE_MIXED=1`. The script then invokes
`POST /v1/presentation/search`, validates the relevance/source ordering without
persisting display labels, and captures the settled result list on both runs.
With the songs filter and `NAVIS_PRESENTATION_SEARCH_PLAY_REMOTE=1`, it also
uses `POST /v1/presentation/search/play` plus the player-overlay controller to
capture the selected remote result in Now Playing. When the selected song
remains loading long enough, it captures a separate app-owned
`*-remote-loading-screenshot` before playback completes. The playback check requires
a ready player and an advancing position recorded in the startup timeline;
`playing: true` with an idle player or zero progress is not successful audio
startup. A terminal `queueLoadFailed` stage ends the diagnostic immediately
instead of waiting for the full polling window.
For paired or repeated runs, set `NAVIS_PRESENTATION_REMOTE_SONG_ID` to a remote
ID returned by the search result. The script requires that exact remote result
to be present on both runs, preventing a changing result order from silently
turning a warm replay into a cold test of another song.
Set `NAVIS_PRESENTATION_REMOTE_SEEK=1` with remote playback to seek the selected
track to 30 seconds on both the initial and restarted runs. The script then
requires a ready player with an advancing position at or beyond that point.
For a recoverable Search-failure capture, use an intentionally unmatched query
with `NAVIS_PRESENTATION_FORCE_SEARCH_REMOTE_FAILURE=1`. The clone-only
launcher applies the authenticated diagnostics override before submitting the
query, so the production page can be inspected without introducing a device or
server failure. Cached/local matches must remain visible when they exist; only
an otherwise empty failed search should render the retryable error state.
For an independent Now Playing capture, set
`NAVIS_PRESENTATION_OPEN_NOW_PLAYING=1`; the clone-only launcher opens the
existing production overlay and captures it without starting a remote stream.
For a deterministic transport state, set
`NAVIS_PRESENTATION_TRANSPORT_ACTION` to `baseline`, `manualNext`,
`manualPrevious`, `automaticAdvance`, `restartCurrent`, `unavailableNext`,
`unavailablePrevious`, or `rapidNext`. The authenticated clone-only control
uses local cloned songs only; it never starts audio or alters the persisted
queue.
For an Albums filtered-empty capture, use route `/library` with
`NAVIS_PRESENTATION_LIBRARY_FILTER_QUERY='no-match'`. For Radio's equivalent,
use `/library?section=radio` with `NAVIS_PRESENTATION_RADIO_FILTER_QUERY='no-match'`.
The latter enables a deterministic clone-only station fixture; both paths use
the authenticated Library-filter control and capture the settled state before
and after a clean restart.
For a populated Artist Top Tracks capture, use an existing artist route with
`NAVIS_PRESENTATION_ARTIST_TOP_TRACKS_FIXTURE=1`. The clone-only fixture is
applied through the authenticated diagnostics override before navigation, so
the real detail screen can be reviewed without external Last.fm traffic.
For persistent error-notice review, set `NAVIS_PRESENTATION_ERROR_NOTICE=1`.
The isolated launcher posts the recovery message through the mounted notice
host, validates its accepted level, and captures the visible action without
simulating a device-level error.

Use the focused volume-memory scenario for desktop volume changes:

```bash
./tool/volume_memory_diagnostics.sh
```

It launches a Linux profile build against one isolated clone three times. The
scenario sets 37%, verifies a clean restart, persists mute across another
restart, then verifies that Unmute returns to 37%. Sanitized JSON responses and
the local app log are retained under `build/volume-memory-diagnostics/`.

Use the focused playback-settings scenario when changing how the Playback
settings screen saves, or what restarts weekly ListenBrainz discovery:

```bash
./tool/playback_settings_diagnostics.sh
```

It signs an isolated clone in to the local loopback fixture, with the
ListenBrainz account, unmetered-only background sync off and the desktop volume
seeded before launch. It flips Scrobbling on the mounted Playback settings
screen, then requires those three settings to survive the autosave and a clean
restart. The authenticated clone-only `GET/POST /v1/presentation/playback-settings`
endpoint accepts exactly one `toggle`, `scrobble`, which invokes the keyed
production switch's own callback; it returns only Scrobbling, unmetered-only
sync, ListenBrainz token validity, whether an account name is stored (never the
name), and the persisted desktop volume. Primary certification rejects both
methods. The scenario also requires that neither the desktop volume write nor
either autosave, before and after the restart, restarts weekly ListenBrainz
discovery. It reads the clone-only
`GET /v1/presentation/listenbrainz-discover`, which reads the production
discovery stream (applying any restart still pending while Home is hidden) and
returns only `streamBuilds`, the process-lifetime number of discovery starts,
its `state` (`loading`, `data` or `error`) and `playlistCount`. Primary
certification rejects it. Output is retained under
`build/playback-settings-diagnostics/`.

Use the focused download-folder scenario after changing how Navis enters,
leaves or switches a custom download folder:

```bash
./tool/download_folder_diagnostics.sh
```

It needs no credential file or source profile: an empty clone signs in to the
loopback lifecycle fixture, and both fixture folders live inside the run root,
so the user's real download folder is never involved. It drives the Downloads
settings switch through `POST /v1/presentation/track-action`
(`downloadsSettingsTab`, `customFolderOff`, `confirmCustomFolderOff`), checks
`GET /v1/cache/status` and the clone's settings row, and compares folder
snapshots across a clean restart. Results and screenshots stay under
`build/download-folder-diagnostics/`.

Use the focused desktop window scenario for shell, bottom-player, resize-gate,
or Mini Player changes:

```bash
NAVIS_DIAGNOSTICS_PRIMARY_DB=/absolute/path/to/navis.sqlite.sqlite \
  ./tool/desktop_layout_diagnostics.sh
```

It drives `GET/POST /v1/presentation/window`, captures 1306×853 standard,
1159×678 short, 887×900 compact, and minimum 800×600 Desktop View plus the
canonical 720×405 and minimum 560×360 Mini Player through the app-owned
screenshot endpoint, verifies Keep Mini returns to 720×405, checks the log, and
repeats after a clean restart. Open and inspect every generated PNG, including
the bottom-player action/volume region at each Desktop width and the embedded
Mini Player volume row at both Mini sizes. Inspect both Desktop entry gates
(799×599 and short 799×444) and confirm both choices remain fully visible.

Use the focused song-indicator scenario for shared song-row changes:

```bash
NAVIS_DIAGNOSTICS_PRIMARY_DB=/absolute/path/to/navis.sqlite.sqlite \
  ./tool/playback_indicator_diagnostics.sh clone
```

It starts and pauses songs through the production playback API, polls playback
and presentation state, verifies that the marker moves between songs, reviews
hard-fail log patterns, opens the queue through its narrow app API, captures
current, paused, and switched states, and repeats after a clean restart. Its
app-owned screenshots and widget semantics are the canonical visual evidence;
do not attempt native desktop automation.

For seek and remote-recovery changes, use the synthetic fixture gate:

```bash
python3 tool/seek_reliability_diagnostics.py --platform linux
python3 tool/seek_reliability_diagnostics.py --platform android \
  --android-serial emulator-5590
```

The runner builds a profile with an isolated database and cache, verifies mute
before playback, and exercises WAV, MP3, FLAC and Opus streams. It covers early
and overlapping seeks, backward bursts, paused playback, completed cache files,
and delayed, unsupported and failing Range responses. Two clean process starts
are the default; fresh song IDs keep early cases uncached. Android installs a
unique sidecar package, without clearing another app's data. Use a disposable
emulator created and removed according to the instructions above. `ffmpeg` and
Flutter are required. `--codecs` narrows a diagnostic rerun. Each invocation
requires a fresh output directory and uses new song IDs; reusing an authenticated
fixture profile is rejected so old connection state cannot affect results.

Evidence lives under `build/seek-reliability/`: `report.json` records the requested
target, generation/stage/outcome, settled position, subsequent motion, transport
state, queue identity and synthetic Range requests. Supported/delayed cases must
settle within two seconds of the final target, advance when playing and remain
still when paused.
Delayed decoder range searches can use the load deadline, and keep waiting up
to 45 s while the player's buffer is still growing or the song's cache download
is at least half done and still receiving bytes; a desktop
cache download that completes first ends the wait and the song reloads from the
file. A recovery can also wait for a progressing, at least half-complete desktop
cache download; that wait has the load deadline and ends after three seconds
without progress. Only the completed file can be used for recovery.
Unsupported/failing Range results remain separately visible; they cannot
certify a working server and are never included as passing supported
seek coverage. Review these outcomes for bounded failures and queue/transport
preservation. Screenshots come from `POST /v1/presentation/screenshot`; inspect
the relevant player and lyrics views as well as the runner's startup view.
`seek_cache_diag.py` remains available for a private real-server clone, but the
synthetic gate requires no production credentials. Platform results must be
reported separately; Linux/Android evidence does not certify Windows or Apple.

#### Live-server seek stress

The synthetic fixture serves files from loopback at full speed. To exercise a
real Subsonic server, including first-play transcodes (which a Navidrome
transcode-cache miss serves as a linear stream that ignores `Range`) and remote
songs the server fetches on first play, use a disposable account:

```bash
NAVIS_LIVE_SEEK_CREDENTIALS=/path/creds.json \
  python3 tool/live_seek_stress.py --quality wifi,cellular \
    --sources library,remote --cases far,mid,back,burst,paused \
    --throttle-kbps 6000 --latency-ms 150
```

The credential file is mode-600 JSON (`url`, `username`, `password`); it and
the profile's `password` copy stay under the ignored `build/live-seek/`
directory and are never printed. The runner builds a muted Linux profile with a
fresh isolated database under `build/live-seek/root` (never the user's own
profile or download folder), signs it in, and runs the first catalog sync once;
`--keep-profile --skip-build` reuse it. If a server's first sync stays
`partial` (some albums never hydrate), the profile can be marked usable by
setting `library_sync_state.initial_catalog_usable_at` in that scratch database.
`wifi` and `cellular` select the original and transcoded quality profiles
through the network-type override. Every case plays a song this profile has
never played (`build/live-seek/used-songs.json`). `--throttle-kbps` routes the
app through a loopback reverse proxy with a shared bandwidth limit and added
first-byte latency, which approximates a phone: the development host reaches
the server too fast to show slow-link behaviour. `--android <serial>` runs the
same cases on a disposable emulator: it clean-installs a profile sidecar
(`NAVIS_LIVE_SEEK_APK` selects a prebuilt one, for example a baseline build),
seeds it with the synced Linux profile and reaches the proxy through
`adb reverse`; the run fails fast if the app does not use the proxy.

Each case samples `GET /v1/playback/status` every 100 ms. It passes when the
native position lands within two seconds of the final target and then advances
(or holds, when paused), the outcome is `completed`, the song is unchanged, and
the player never plays forward from near the start of the song (an audible
restart). Traces, including failed starts, go to
`build/live-seek/runs/<stamp>/traces/`, with `report.json` beside them. The
seek's `unsettled` diagnostics name the rule that ended each probe that did not
confirm it. Remote cases make the server fetch those songs.

After `./tool/check.sh` passes, set `NAVIS_QUALITY_GATE_RESULT=passed` on the
final invocation so the sanitized runtime-validation record captures the gate.

### App API extension and safety contract

Every diagnostic or agent-control surface must:

- Be unavailable in production release builds, bind only to loopback on an
  ephemeral port, and require a random bearer token communicated through a
  handshake file. Linux/macOS profiles apply mode `0600`; Windows profiles use
  their isolated per-user diagnostics directory and must not wait for a POSIX
  permission command before serving requests. Android publishes the same
  bounded handshake through an app-owned native bridge to its external-files
  directory. Startup reads package identity through `package_info_plus` and
  creates `navis-diagnostics` below `getExternalStorageDirectory()` (Android's
  `getExternalFilesDir(null)`), without waiting for the activity's
  `com.navis.app/diagnostics_handshake` channel. Keep scoped-storage paths
  platform-resolved rather than hard-coding `/sdcard/Android/data/...`.
- Use an isolated clone of the configured database and cache by default. Use
  primary certification only when explicitly justified, after the clone
  scenario passes, with its backup and mutation restrictions intact.
- Expose feature-scoped actions and state/status queries, deterministic
  completion or bounded polling, structured error responses, and clean
  shutdown.
- Invoke the production app path. Direct state or database mutation is allowed
  only for isolated fixture setup or an explicitly named fault-injection
  operation.
- Avoid returning or logging credentials, bearer tokens, private server URLs,
  raw cloned records, or other sensitive values.
- Store screenshots only below the validated diagnostics root in a mode-`0700`
  directory with mode-`0600` PNGs. Treat them as potentially sensitive local
  artifacts: never commit, upload, embed in logs, or share without redaction.
- Add focused server/contract tests and update this document plus
  `docs/architecture.md` when the interface or lifecycle changes.

For goldens, use fixed fixtures, deterministic themes, and the existing
adaptive viewport helper. Prefer component crops. Avoid live catalog data,
network artwork, continuous animation, and platform-font-dependent full-screen
goldens. Test animations through state transitions and capture stable start/end
states.

### Completion evidence

For runtime-affecting work, the final handoff and any applicable `PROGRESS.md`
entry must record, without secrets:

- Runtime target and whether an isolated clone or explicitly approved primary
  certification profile was used.
- Acceptance and regression scenarios exercised.
- App API endpoints and native service APIs used.
- Results, relevant log review, app-owned screenshot artifacts that were
  actually opened and inspected, and widget/golden evidence when applicable.
- A short summary of fix-and-retest iterations.
- Final `./tool/check.sh` result and the clean-restart runtime result.

## Core Release Gate

Use this focused release-ready gate when the full development test matrix is
not required:

```bash
./tool/release_gate_core.sh
```

Quick mode (skips full `flutter test` pass):

```bash
./tool/release_gate_core.sh --quick
```

## Phase 1 Close-Out Gate

When Phase 1 is ready to close, run the dedicated close-out script:

```bash
export NAVIS_SMOKE_BASE_URL="https://your-subsonic-host"
export NAVIS_SMOKE_USERNAME="your-username"
export NAVIS_SMOKE_PASSWORD="your-password"
# Optional:
export NAVIS_SMOKE_API_VERSION="1.16.1"
export NAVIS_SMOKE_USE_LEGACY_AUTH="false"

./tool/phase1_closeout.sh
# or: make phase1-closeout
```

This gate ensures:
- drift DB tests execute (not skipped)
- migration tests execute (not skipped)
- real-server `ping()` + `getOpenSubsonicExtensions()` smoke succeeds

## Phase 4 Codec Close-Out Gate

Before opening Phase 5 implementation, run the codec close-out preflight and then complete the runtime matrix on a physical Android device:

```bash
./tool/phase4_codec_closeout.sh <device-id> [server-variant]
# or: make phase4-codec-closeout DEVICE_ID=<device-id> [SERVER_VARIANT=OpenSubsonic]
```

Environment alternatives:

```bash
export NAVIS_CODEC_DEVICE_ID="<device-id>"
export NAVIS_CODEC_SERVER_VARIANT="OpenSubsonic"
./tool/phase4_codec_closeout.sh
```

This gate ensures:
- codec-critical tests execute (not skipped)
- device metadata is captured for evidence rows
- matrix row templates are generated for FLAC/ALAC/MP3/AAC/Opus/Vorbis
- release checklist protocol in `docs/troubleshooting.md` is followed end-to-end

## Optional Pre-commit Hook

Enable local guardrails:

```bash
git config core.hooksPath .githooks
chmod +x .githooks/pre-commit
```

This runs `./tool/check.sh` before each commit.

## Publishing a Release

When a feature, bug fix, or phase is complete and merged to `main`:

```bash
./tool/release.sh v0.2.0
```

This runs the full quality gate, builds a release APK, tags the commit, and publishes the APK to R2 with a signed update manifest (a Forgejo release only with `--forgejo`). See [ci-cd.md](ci-cd.md) for setup details.

Optional Forgejo publishing requires curl 7.55+ and reads its Authorization header
from a mode-600 file, cleaned by the release EXIT trap, rather than passing the
token in curl's command-line arguments.

Windows Inno Setup silent updates relaunch Navis as the original user via
`runasoriginaluser`; installation elevation is not carried into the app.

For Android releases, `tool/release.sh` cleans stale APK build outputs before
building, removes an existing same-name root release asset before copying, and
fails publication if the final APK metadata/signature or release string
sentinels do not match the expected release.

`tool/release.sh` fails when the requested version's release tag already
exists, locally or on origin. A version that `dev` already names in
`pubspec.yaml`, because work on it started there, releases normally; reserve
`--allow-existing-version` for intentional rebuilds and failed-release
retries (see [ci-cd.md](ci-cd.md#what-it-does)). Which version to start, and
when, is set out in "Versioning" in
[agentic-engineering.md](agentic-engineering.md).

Advanced release packaging options:

```bash
# Linux local-only packages (Ubuntu 22.04 container; no GUI launch/publish)
./tool/linux/build_in_container.sh --package=all
./tool/linux/verify_packages.sh v1.5.0

# Linux owner release (publishes; see release-linux.md)
./tool/release.sh v0.2.0 --targets=linux --linux-package=deb

# Windows installable .exe (Inno Setup)
./tool/release.sh v0.2.0 --targets=windows --windows-package=exe

# macOS signed + notarized artifact
./tool/release.sh v0.2.0 --targets=macos --macos-notarize
```

Pre-release builds (from `dev` branch when needed):

```bash
./tool/release.sh v0.3.1 --channel=dev
```

The `dev` channel publishes to `navis/channels/dev/manifest.json`, which only dev
builds read. Stable tags must be plain `vX.Y.Z`; `tool/r2_publish.sh` additionally
accepts `vX.Y.Z-dev.<build>` and `vX.Y.Z-staging.<build>` on dev/staging.
Other suffixes (`-beta`, `-rc`) remain rejected. To build/publish the self-updating
arm64 sidecar use `./tool/dev_release.sh`, or `--dry-run` to build locally and
print the remote plan without writes/deletes. Manual `dev_app.sh apk` builds
also allocate a monotonic build number unless overridden. See
[release-r2.md](release-r2.md) for numbering, signing, symbols and cleanup.
Run `./tool/dev_release_test.sh` for the hermetic shell gate (also in `check.sh`).
With `release.sh`, `--prerelease` and the dev channel mark the Forgejo release
(`--forgejo`) as a pre-release.

## Dependency Health

Run periodically to check for outdated packages:

```bash
flutter pub outdated
dart pub outdated
```

Or: `make outdated`

## Runtime Verification

Preferred runtime targets for this project are Android and iOS.

### Android Sidecar Install

To install a temporary debug build on Android without replacing the normally
installed app, set a debug-only package suffix and app name before running the
build:

```bash
export NAVIS_APP_ID_SUFFIX=".sidecar"
export NAVIS_APP_NAME="Navis Sidecar"

flutter run -d <device-id> --debug
```

For this repo's currently attached phone:

```bash
export NAVIS_APP_ID_SUFFIX=".sidecar"
export NAVIS_APP_NAME="Navis Sidecar"

flutter run -d R5CX14TVQEE --debug
```

The sidecar package installs as `com.navis.app.navis.sidecar`, so it lives
next to the regular `com.navis.app.navis` install. Remove it later with:

```bash
adb uninstall com.navis.app.navis.sidecar
```

Unset the variables to go back to the normal package:

```bash
unset NAVIS_APP_ID_SUFFIX
unset NAVIS_APP_NAME
```

### Dev Sidecar Helper Script

Use the helper script to run or build a sidecar app without manually exporting variables each time:

```bash
./tool/dev_app.sh run -d <device-id>
./tool/dev_app.sh apk
./tool/dev_app.sh apk-debug
```

Defaults used by this script:

- `NAVIS_APP_ID_SUFFIX=.dev`
- `NAVIS_APP_NAME="Navis Dev"`
- `--dart-define=NAVIS_UPDATE_CHANNEL=dev`
- `--dart-define=NAVIS_SELF_UPDATE=true`
- Android builds use the `sideload` flavor and emit
  `build/app/outputs/flutter-apk/app-sideload-release.apk`.

`apk-debug` emits an installable debug sidecar and accepts normal Flutter build
arguments. The Android Auto emulator gate uses its x86_64 split APK so it can
fit reliably on a standard phone AVD.

This ensures the dev app can live next to stable and the in-app updater checks dev-channel release assets.

For Android Auto phone-projection work, validate the source or merged manifest
before starting DHU:

```bash
./tool/verify_android_auto_manifest.sh
```

The verifier requires the automotive descriptor, projection metadata, exported
canonical `com.ryanheise.audioservice.AudioService`, media-browser intent
filter, icon/theme metadata, and the absence of the privileged bind permission.
If an APK already exists, it also confirms that the descriptor was packaged.

Before physical-phone DHU validation, run the automated cold-start regression
on a standard Android phone emulator:

```bash
./tool/android_auto_cold_start_diagnostics.sh
```

The command installs only the `.dev` sidecar, force-stops it, then uses an
external MediaBrowser client to start the canonical audio service without ever
launching `MainActivity`. It is intentionally not an AAOS test and does not
replace DHU projection validation.
The sidecar install permits replacing a newer dev build with the diagnostics
build while retaining sidecar app data.

When Android SDK/device is not available locally, you can still verify app startup behavior with Linux desktop:

```bash
flutter run -d linux
```

This is a local workaround and does not replace Android runtime validation.

### Linux Sync Diagnostics

Linux diagnostics and interactive scenario presets share the path resolver in
`tool/diagnostics_profile.py`. The default source is
`~/.local/share/com.navis.app.navis/navis.sqlite.sqlite`. It falls back to
`~/Documents/navis.sqlite.sqlite` only if that legacy file exists and the new
file does not. `NAVIS_DIAGNOSTICS_PRIMARY_DB` overrides clone sources;
`--scenario-source` takes precedence for scenario presets. Primary
certification still requires the normal resolved path, regardless of an override.
Run `python3 -m unittest tool/dev_sync_scenario_test.py tool/diagnostics_profile_test.py`
for fixture-only preparation/path checks, including the shell launchers, without
starting Navis.

After `./tool/check.sh` passes, exercise catalog promotion against a consistent
clone of the configured library and the real server:

```bash
NAVIS_DIAGNOSTICS_PRIMARY_DB=/absolute/path/to/navis.sqlite.sqlite \
  ./tool/sync_diagnostics.sh clone
```

The profile-only launcher stores its authenticated loopback handshake, logs,
JSON report, and database checks under `build/sync-diagnostics/`. It rewrites
cached-file paths in the clone so cancellation, restart, and deletion tests
cannot unlink primary cache files. Clone mode first drains startup work under
the host's real network policy before applying scenario overrides, so a
schema-migrating or mid-repair primary clone cannot leak its startup model
repair into the metered guardrail scenarios. The cellular automatic,
manual-check, and metered-Wi-Fi checks correlate each posted action with
new terminal durable runs and attempt endpoint counts, after the controller
request (including companion auxiliary work) has settled. A
preceding repair's displayed status is not attributed to a later bounded
action. After collecting its performance report, clone mode saves the idle
sync status and captures an app-owned Library screenshot for visual inspection
of the idle Library (between runs it shows no hydration backlog notice; Sync
settings reports the backlog). Capturing after the report keeps the Library
tab's mounted queries out of the benchmark workload.
Clone mode can simulate metered/cellular policy through diagnostics overrides
and asserts hard-probe, interactive hydration, explicit repair-consent deferral
with zero requests,
budget, and one-time override guardrails without requiring a real modem. The
clone suite also certifies the foreground cellular
Check for updates path: exactly one newest-album page, no artist/bulk-song
sweep, and at most three changed-album details. Its authenticated
`recent-albums` observation also proves the Library's production Recently Added
query follows the server's
newest-feed positions first, then server creation date for entries outside that
feed, after the check.

To validate cache migration for a provisional song after the server has
canonicalized it, run the focused clone-only scenario:

```bash
./tool/sync_diagnostics.sh cache-alias
```

It creates a disposable cache row in the clone, uses the running Navis app API
to hydrate the matching real album, and asserts that the persisted identity
alias exists, the old cache row is gone, the canonical row owns the cache, and
the cache file remains present. It never writes to the primary database or
cache directory.

For a live-scale full Repair Library trace without changing primary data, run:

```bash
./tool/sync_diagnostics.sh full-rescan
```

The result records the immediate `preparing` state and captures its app-owned
Flutter frame before durable planning, then records catalog hydration and the
per-album fallback request counts. It clears stale candidate/work state only
in its disposable clone, so an interrupted earlier run cannot replace the
requested full repair. If deletion safety requires confirmation, the clone
runner makes one explicit confirmation pass.

When a newly changed server password has not yet been saved in desktop secure
storage, provide a separately permissioned temporary credential file through
`NAVIS_DIAGNOSTICS_CREDENTIAL_PATH`; the clone reads it without altering the
primary credential store. `NAVIS_DIAGNOSTICS_USERNAME` similarly replaces the
username only in the clone when validating a different account.

Every Linux clone gate that signs in to the configured server accepts that
credential file: the sync, target-lane, presentation (including desktop
layout), rapid-playback, equalizer, speed/pitch, playback-indicator and
seek-cache diagnostics. Use it on hosts whose desktop keyring cannot be read
(for example when the Secret Service `default` alias points at a missing
`login` collection); without it those clones stop at Login and their
presentation steps fail with `DiagnosticsPresentationUnavailable`. Scripts that
do not apply `NAVIS_DIAGNOSTICS_USERNAME` themselves take the account from the
source profile, which `NAVIS_DIAGNOSTICS_PRIMARY_DB` selects, so point it at a
copy whose `server_config.username` names the validation account.

A clone must never reach the source profile's own files. Clone mode ignores the
source's custom download folder, so a copied `cached_tracks` row that still
names a file in the user's download folder would be relocated into the run
folder by the app's own download migration. Every clone gate therefore either
copies the audio it needs into its run folder and rewrites `cached_tracks` to
point there, or deletes the copied `cached_tracks` and `download_queue` rows and
clears the custom download folder settings. As a backstop, a desktop clone build
forgets every `cached_tracks` row whose file lies outside
`NAVIS_SYNC_DIAGNOSTICS_ROOT` at startup, before any service runs (Android
sidecars use their own app-private storage and skip this step). Keep new gates
the same way: copy into the run folder or drop the rows.

A desktop clone also runs as the same OS user as the real app, so its platform
directories would be the real profile's (on Linux,
`~/.local/share/com.navis.app.navis/` and `/tmp`). Before anything resolves a
directory, a Linux or Windows clone build therefore replaces the
`path_provider` platform implementation with `CloneDiagnosticsPathProvider`.
Every caller, including plugins such as `flutter_cache_manager`, then resolves
inside `NAVIS_SYNC_DIAGNOSTICS_ROOT`:

| Platform directory | Clone directory |
|---|---|
| Application support | `<root>/support/` (also the default download root) |
| Temporary, application cache | `<root>/cache/` (shared with the rolling cache) |
| Documents, downloads, library | `<root>/documents/`, `<root>/downloads/`, `<root>/library/` |

A clone therefore starts with its own window geometry, update-check state,
Last.fm and AutoEQ caches, image-cache indexes and What's New marker, and its
startup cache maintenance prunes only the clone's rolling files. Launchers do
not change `XDG_*` or `TMPDIR`, so fonts, GTK settings, mpv and the Secret
Service keyring behave as they do for the real app; the credential file is
still read from its own path. A clone shows the What's New card unless its
launcher writes the running version to
`<root>/support/changelog_seen_version.txt`, as `sync_diagnostics.sh`,
`sync_target_lane_diagnostics.sh`, `repair_confirmation_diagnostics.sh`,
`manual_discovery_diagnostics.sh` and the `dev_app.sh` presets (except
`--fresh-login`) do. Android sidecars are separate packages with their own
storage and keep their platform directories.

Run primary certification only after the clone suite passes:

```bash
./tool/sync_diagnostics.sh primary-certification
```

Primary mode refuses to start beside another Navis process, disables mutation
and cancellation endpoints, requires the normal Linux database path, and
retains a timestamped SQLite online backup in
`~/Documents/navis-certification-backups` unless
`NAVIS_DIAGNOSTICS_BACKUP_ROOT` overrides that location.

### Android read-only scheduler observation

For a connected Android device, build an isolated profile sidecar with the
internal background-sync and diagnostics flags. The user must authenticate in
the sidecar; do not pass credentials as Dart defines or through ADB. The app
publishes the loopback handshake through `getExternalFilesDir()`; retrieve it
from `/sdcard/Android/data/<sidecar-package>/files/navis-diagnostics/handshake.json`
without printing its bearer token, then forward its port with `adb forward`.
Use the token only for authenticated `GET /v1/sync/status`, `GET /v1/health`,
and the read-only `POST /v1/presentation/screenshot` request. Screenshots are
written below that same sidecar-scoped diagnostics directory and must be pulled
and visually inspected; primary Android certification permits no navigation,
scheduling, cancellation, or other mutation.

## MacBook Testing Guide

For complete MacBook test procedures (quick smoke, full regression, release/notarization validation), use:

`docs/macos-testing-playbook.md`

The manual discovery gate also calls `GET /v1/library/album?verifySongs=true`
(with the fixture album `id`) and requires `persistedSongCount` before and after
restart. A hydration flag or declared server count alone is insufficient proof
that an album's tracks were actually stored.

Set `NAVIS_ANNOTATION_FIXTURE=true` when running
`tool/manual_discovery_diagnostics.sh` to also queue offline song/album/artist
favorites and a rating, then verify exact protocol parameters and a drained
outbox after reconnect. This explicitly enables
`NAVIS_DIAGNOSTICS_ANNOTATION_FIXTURE` only for an HTTP loopback server with the
fixture username; ordinary diagnostics still refuse annotation delivery. The
fixture clears copied outbox entries before launch. Its copied catalog is marked
recently track-verified so the one-album fixture does not pretend to serve the
unrelated live library's historical metadata.

Clone-only `POST /v1/presentation/library-scroll` accepts `pixels` (0–100000)
and animates the mounted Albums view through its real scroll controller, returning
the actual position.

Clone-only `POST /v1/presentation/scroll` scrolls the current page's primary
vertical scroll view, such as Home, an artist page or a Settings page, so a
screenshot can show content below the fold. Send exactly one of `{"by": px}`
(−100000 to 100000, relative) or `{"to": px}` (0 to 100000, absolute). The
offset is clamped to the view's extent. The primary view is the largest
vertical scrollable on screen: views in hidden shell tabs, the hidden desktop
workspace and covered pages are skipped, and nested lists lose to the page's
own list. The response is `{"pixels", "maxScrollExtent", "viewportDimension"}`
after the next quiet frame, so lazily built sections are included in the
extent. A page without a scroll view returns 503; invalid bodies return 400;
primary certification returns 403.

Clone-only `POST /v1/presentation/onboarding/step` with `{"step": <0-based int>}`
moves the mounted onboarding screen (`/onboarding?review=1` is the usual way to
open it) to that step through the screen's own step state, as Next and Back do,
so the Integrations step is step 3. The response is `{"step"}`. A step outside
0–3 returns 404, an onboarding screen that is not mounted returns 409, and a
malformed body returns 400.

Clone-only `POST /v1/presentation/onboarding/focus` with
`{"field": "listenBrainzToken" | "lastFmKey" | "none"}` requests focus on that
field's production `FocusNode` on the Integrations step, which opens the
platform soft keyboard on Android, or removes focus (`none`) to close it. The
field is scrolled into the lazily built step list first. The response is
`{"field", "focused"}`. A field that is not shown (the Last.fm key field exists
only in builds without a bundled key, and both fields only on step 3) or an
onboarding screen that is not mounted returns 409. Capture the screenshot after
the keyboard has animated in. The step is checked before any scrolling, so
requesting a field from another step returns 409 without moving that step.

Clone-only `POST /v1/presentation/release-card` taps a Deezer release card
through its own tap handler: `{"surface": "missingAlbums" | "newReleases",
"index": 0}` (`index` is 0-based and defaults to 0) on the mounted artist page's
Missing Albums shelf or Home's New Releases shelf. Cards that are not built yet
(off screen in the shelf or below the fold) are not tappable, so scroll first
with `/v1/presentation/scroll`. A card opens an album page: the library album,
or the server's remote `ext-deezer-album-<id>`, which the page loads from the
server. The response is `{"outcome", "location"}` where `outcome` reports how
that page ended up: `albumPage` (the page marks the album as shown), `failed`
(the server could not provide it, or the library could not be read, and the
page offers Retry and a search), `loading` (still loading after 30 seconds),
`unknown` (an album page showing neither after 30 seconds), `otherPage` (the
location is not an album page) or `none` (the tap did not navigate within 8
seconds); `location` is the route afterwards. A surface with no tappable card
returns 409; an index past the cards returns 404; malformed bodies return 400.
It replaced `POST /v1/presentation/release-sheet` when the release sheet was
retired.

All three return 403 in primary certification and 503 when no presentation
surface is registered.

`POST /v1/diagnostics/metrics/reset` clears frame/canary samples
and playback-failure counts between timed scenarios. Reports include current and
process-lifetime peak RSS. These support controlled sync/playback/scroll trials;
API action latency and build+raster samples are not hardware input-latency or
hardware dropped-frame measurements.
Reports retain `frames` as build-plus-raster for comparison with earlier traces,
and expose `frameBuild`, `frameRaster` and `frameSpan` separately using the same
latest-5,000-sample window. `frameSpan` is Flutter's vsync-to-raster-finish duration;
none of these fields measures presentation by the compositor or audible gaps.
The reset endpoint clears all four windows together. Use the separate phases to
locate UI-thread versus raster cost before choosing a performance change.
`databaseCanarySlowSamples` retains the latest 32 artist-count reads above
100 ms, with their UTC start time, sync phase, elapsed time, and largest
observed event-loop timer delay. The timer delay helps attribute a slow read;
it is not a direct measurement of SQLite execution time. Metrics reset clears
these samples too. The trace contains no SQL arguments or server values.
`slowFrameSamples` likewise retains the latest 32 build-plus-raster frames above
100 ms, with build, raster, span, and total durations. Its UTC time and sync
phase are observed when Flutter delivers the timing callback, so batched
callbacks may label a frame with a slightly later phase. Metrics reset clears
this trace too.


### Isolated Android worker fixture

A profile **clone** sidecar with a nonempty `NAVIS_APP_ID_SUFFIX` may opt into
`NAVIS_DIAGNOSTICS_ANDROID_WORKER_FIXTURE=true`. This uses that sidecar's real
Android secure storage so a separate headless Flutter engine can read the
fixture session after process death. Normal clone diagnostics keep credential
changes in memory. Connect a loopback fixture through authenticated
`POST /v1/session/connect`; never pass real credentials in Dart defines or ADB.
Use a fresh sidecar package and its own `app_flutter/navis.sqlite.sqlite` path
for both foreground and worker access. Observe WorkManager through Android's
JobScheduler service API, and inspect results through authenticated Navis status
and durable history. Primary certification remains read-only.

For a metering/process-death worker check, constrain the emulator fixture Wi-Fi
through Android's network-policy API, enqueue the production catch-up schedule
via a diagnostics background-policy change, close the sidecar activity, and kill
only that background sidecar process. Restoring unmetered Wi-Fi lets WorkManager
start a new process; inspect the persisted worker result and actual song counts
after reopening the sidecar. Restore the emulator's original network policy.
Forcing a periodic JobScheduler job early is insufficient because WorkManager
still enforces its own next-run timestamp.

Diagnostics reports label persisted promotion statistics with
`promotionScope: lastCommittedCatalogPromotion` and `promotionGeneration`.
Those statistics may predate the current incremental check; current endpoint
counts and pending counts come from the active/terminal operation state.

`./tool/dev_app.sh run -d linux --first-setup` and the other interactive clone
presets compile with `NAVIS_SYNC_DIAGNOSTICS_LEASE_SECONDS=600`, the production
lease duration. For a direct large first-sync benchmark, pass that same define.
The default six-second diagnostic lease is deliberately short for
interrupted-owner tests and can expire while a large atomic promotion holds the
database writer. The override is bounded to 1–600 seconds and has no effect
outside diagnostics builds; it does not disable ownership checks.


Authenticated `GET /v1/sync/attempts` returns up to 20 recent active, recovered or
terminal attempts for the active server, including their bounded telemetry.
The `reportedAttempt` field of `GET /v1/diagnostics/report` selects the exact `sync.runAttemptId`,
not the most recent auxiliary attempt; it is null when that status has no attempt.
Sync status and durable outcomes expose request/attempt IDs and start timestamps.
`workSummary` groups durable work by safe target kind, status, cooldown and next
retry time. Work-row, pending-album and pending-artist counts are separate axes
and must not be added together as an operation count.

Inspect `captureComplete`, omitted phase/attempt counts and checkpoint failures
before interpreting a trace. A complete capture is not a durable completion
claim; consult the attempt status and outcome. Request ordinals link retries,
while endpoint totals survive trace truncation. Phase elapsed times include
awaited network/database work; applying-to-cleaning covers publication including
commit, and should not be confused with the narrower persisted reported-apply
counter. Capture evidence before its opportunistic seven-day detail pruning;
aggregate terminal history lasts 90 days. API tests cover redaction, migration,
recovery and correlation; runtime certification should compare the same attempt
before and after a clean restart.

### Speed, pitch and preset diagnostics

Run `./tool/playback_adjustment_diagnostics.sh` for an isolated Linux profile,
synthetic local tone, paired/crossfade settings and track transition,
preset save/select/delete, queue clearing, clean restart and app-owned Settings
and Now Playing screenshots. Open and inspect the PNGs listed
in its screenshot JSON artifacts. The primary database and its downloads are
read-only inputs; the tone and all changes belong to the disposable clone.
The clone disables scrobbling for its synthetic tracks. The audio check requires
`pactl`, `parec` and Python NumPy: it creates a private null sink, captures its
monitor, verifies that locked 1.25× turns 440 Hz into approximately 550 Hz,
and confirms that unlocking and changing speed retains that pitch. It also checks
legacy precise values and linked preset restoration after a clean restart. Only this diagnostic process's streams are routed there;
the sink is removed on exit. `NAVIS_DIAGNOSTICS_AUDIO_DEVICE` selects the mpv
device only in clone diagnostics (normally audio output remains automatic).

`GET /v1/playback/adjustments` reports current/persisted adjustments, selected
identity, presets, backend constraints and engine state. Clone-only
`POST /v1/playback/adjustments` accepts multiplier `speed`, `pitchSemitones`
and boolean `lockPitchToSpeed`, or
`action` (`select`, `save`, `update`, `rename`, `delete`) with `id`/`name` as
appropriate. Legacy `speedPercent` remains supported; supplying both speed
representations is rejected. Independent pitch entry requires unlocking. GET
retains percentage fields alongside multiplier and current/persisted lock fields.
It invokes the production controller and flushes persistence.
Clone-only `POST /v1/playback/queue/clear` clears through the queue controller
and returns adjustment state so retention can be checked.
Invalid, unsupported and failed changes return a failure state. None cannot be
updated/deleted. `POST /v1/presentation/adjustments` reveals the Settings panel;
with `open: true`, it activates the existing Now Playing entry point before
revealing the panel. With `quick: true` it instead presses the first visible
player Speed button (desktop bar or Now Playing transport) through its
production callback and returns `surface` (`popover` or `sheet`). With
`settingsSheet: true` it opens only the phone Now Playing settings sheet
(volume level and Sound section) through its button and returns `surface`
`settingsSheet`, for a screenshot of that sheet. Every
response lists `quickControls`: visible Speed/Equalizer quick buttons with
their key, enabled state and the Speed multiplier label. Clone-only
`POST /v1/presentation/shortcut` accepts `action` `speedUp`, `speedDown` or
`speedReset`, sends that action's current binding through `HardwareKeyboard`
to the shell's production global shortcut handler, and returns the chord
label; poll `GET /v1/playback/adjustments` for the applied speed.
Clone-only `POST /v1/presentation/quick-panel` drives the player quick panels
through production callbacks: `action` `open` or `press` with `target`
`speed`/`equalizer` (press the button; `open` also requires the panel and
returns `surface`), `preset` with a mini-EQ preset id (chooses it in the preset dropdown), or
`openPage` (taps Open Equalizer). `GET /v1/presentation/quick-panel` reports
`quickControls`, the top route `location`, the `playerOverlay` stack and
`miniPlayer`, so return-to-origin can be polled. The script covers the Speed
popover, the shortcut round trip and its notice, the EQ popover and preset
selection (asserted through `GET /v1/equalizer`), and opening and closing the
Equalizer page from both the desktop view and Mini Player.
These controls require normal diagnostics authentication and mutation is
forbidden in primary-certification mode.

### Equalizer diagnostics

See [equalizer.md](equalizer.md) for the platform support and precision contract.
`./tool/equalizer_diagnostics.sh` uses a copied SQLite profile, generated local
tones, and a disposable PulseAudio sink. It captures actual output for a 12 dB
cut, automatic headroom, bypass, and a pitch-shifted cut, verifies persistence
across a clean restart, verifies named/mode drafts and temporary editor
preview/cancel against captured audio, and captures compact/wide graph and
inline-editor app-owned EQ screenshots. Graph drag/Undo/cancel checks and a
32-band sustained-drag profile expose measured frame timings and bounded queues.
It never installs over or edits the primary profile.

The Android driver validates a running isolated sidecar via its owned API:

```bash
python3 tool/android_equalizer_diagnostics.py \
  --handshake <private-handshake> --output <evidence-directory> \
  --serial <android-serial> --package <sidecar-package>
```

Seed the local tone fixtures before launch, keep its database under its private `files/` folder,
and forward the handshake port without printing the token. It checks native
headroom/status, controls, track transition, presets, and background progress,
then checks retained mode drafts and editor preview/cancel, and retrieves the
PNGs from the app's screenshot endpoint. The navigation response must actually
resolve to `/settings/equalizer`; a redirected login screenshot is not EQ evidence.
`--fixture-url http://127.0.0.1:<port>` can connect the local auth-lifecycle test
server after an Android reverse-port mapping; its fixed synthetic credentials
stay inside the test profile. `POST /v1/presentation/dismiss-popup` closes only
app-owned popup routes before capture and is clone-only. Physical-device
listening, Bluetooth, and OEM routes remain separate validation.

Clone-only `POST /v1/presentation/equalizer` operates mounted production controls:
`selectBand`, `dragBand`/`cancelDrag` with zero-based band `index` and finite
`dx`/`dy` in a 600×300 reference graph, `frequency`/`gain`/`q`/`preamp` with a text
`value`, and `done`/`cancel`. `edit` and `apply` remain inline-editor aliases.
`profileGraph` exercises 180 rendered updates in one canceled graph gesture and
returns frame timing measurements; the sidecar driver supplies 32 active filters.
GET EQ status includes preview/checkpoint queue occupancy and cumulative
preview-command/workspace-write counters. `POST /v1/equalizer` additionally supports
`mode`, `custom`, `discard`, `retry`, `preview`, and `cancelPreview`; draft deletion
requires explicit `discardDrafts: true`. All retain normal authentication and
primary-certification mutation restrictions.

Windows SMTC diagnostics use `--no-pub` with a prepared dependency graph,
allow up to five minutes for native build/startup, and wait for restored app
presentation before capturing screenshots. On failure they retain only selected
playback-state fields for diagnosis. Windows PowerShell 5.1 cleanup terminates
the task-owned process tree if authenticated shutdown does not finish.
