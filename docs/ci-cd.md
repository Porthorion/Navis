# Quality Gates & Releases

All quality gates and release publishing run locally. There is no CI runner — `tool/check.sh` and `tool/release.sh` replace what Forgejo Actions workflows would do.

Windows media-session changes additionally require the Windows-only isolated
GMTC validation command described in `docs/development-workflow.md`:
`tool/windows_smtc_diagnostics.ps1`. It runs after Linux smoke and focused
tests; it is not a replacement for `./tool/check.sh`.
The seek gate sends `TimeSpan` ticks to GMTC and checks the paused position
within 500 ms of five seconds. Restored playback and real play/pause commands
are checked again after restart, with app-owned screenshots retained.

`tool/dev_app.sh run -d linux` accepts interactive, isolated sync/setup
presets. Their profile-mode clone and fixture flows are documented in
`docs/dev-testing-builds.md`; they are exploratory launchers, not quality-gate
replacements. Changes to their launch or preparation behavior require focused
scenario tests (`python3 -m unittest tool.dev_sync_scenario_test`), the Linux
app/API runtime loop, and this repository gate. Clone launchers seed
app-support state such as the What's New marker under `<root>/support/`, where
desktop clone builds keep it (see `docs/development-workflow.md`).

Artist queue changes additionally verify early playback and background queue
growth without a modal using `python3 tool/artist_playback_diagnostics.py`.
This bounded Linux fixture gate verifies a three-release artist starting with
one loaded album, Play/Shuffle membership, remote streaming, automatic partial
recovery, expanded cached release hydration, repeated append occurrences,
queue persistence and clean restart. It uses a disposable copied database,
loopback server, process-local credentials and app-owned screenshots; inspect
its PNGs as described in `docs/development-workflow.md`.

Changes to the desktop media_kit adapter's mpv properties or the bundled
libmpv additionally run `python3 tool/stream_open_diagnostics.py`. This bounded
Linux fixture gate requires that a 404 stream never reaches a yt-dlp on `PATH`
(libmpv's ytdl hook stays off), that ordinary streams still play, and that an
Azuracast-style ICY radio station plays and stops through its station card,
and that a stream served with an untrusted certificate is refused
(`tls-verify`).

Regenerate Windows SMTC licence notices after Rust dependency changes with
`python3 tool/generate_rust_notices.py` (see `release-windows.md`). The script
uses the locked Windows graph and locally fetched Cargo registry sources. Licence
file matching ignores case. A crate without a licence file gets full text for
every SPDX identifier from tracked `tool/data/spdx/` templates; unsupported
fallbacks fail generation. Identical texts share a notice reference.

The colour-name table is generated separately with
`dart run tool/generate_color_names.dart`; `build_runner` does not own it.
Keep its pinned CSV and output together (see `tool/data/color_names/README.md`).

Android Gradle release tasks require `android/key.properties` unless
`NAVIS_ALLOW_DEBUG_SIGNED_RELEASE=1` explicitly permits local debug signing.
Named release tasks fail during configuration; aggregate tasks selecting release
variants fail before task execution. Debug/profile tasks keep their fallback.
`tool/dev_app.sh apk` and `dhu` opt in for local dev APKs (an explicit `0`
retains the strict check). `tool/check.sh` builds no release APKs.
`test/tool/android_release_signing_test.dart` exercises the publication
preflight and local dev opt-in in temporary fixtures with a fake Flutter
executable, without builds, launches or credentials.

Windows libmpv uses an LGPL pin with verified Forgejo/R2/upstream fallbacks;
remote builds no longer seed the obsolete media_kit archive. Run
`cmake -P tool/libmpv_download_test.cmake` for offline cache, retry and cleanup
checks (downloads are simulated). See `release-windows.md` for pin updates.

## Quality Gate (`tool/check.sh`)

Run before every commit (automatically enforced if the pre-commit hook is enabled):

```bash
./tool/check.sh
```

Checks performed (in order, fail-fast):
1. `/tmp` disk-space preflight
2. Linux desktop-entry installer (`tool/linux_desktop_entry_test.sh`)
3. Native equalizer response/PCM fixtures (`tool/equalizer_native_test.sh`)
   and the Last.fm key masking / artifact secret scan shell tests
   (`tool/lastfm_key_defines_test.sh`, `tool/scan_artifact_secret_test.sh`;
   fake key and synthetic artifacts, runnable on their own to debug a failure)
4. `./tool/dart_format.sh --check` (reports without rewriting; excludes
   vendored CargoKit, which is checked from its own directory)
5. `dart run build_runner build`
6. `flutter analyze --no-fatal-infos`
7. Drift migration tests
8. Critical routing/provider/playback/library sync test suite
9. Full `flutter test`
10. Coverage when `CI=true`

Native EQ fixtures use an available JDK, or Android Studio's bundled JDK.
`ANDROID_STUDIO_JDK` may select an alternate JDK directory. They validate
filter responses, measured PCM gain, headroom, channel isolation, and bypass;
they do not replace Android build and actual device/runtime validation.

The script also checks `/tmp` disk space before starting to prevent misleading test hangs.
Captured test logs also reject the repeated `node.built` and `!child.attached`
semantics assertions. The focused runtime gate for these failures is
`./tool/presentation_diagnostics.sh clone / tooltip-semantics`; it checks the
Home player tooltips with app-owned semantics before and after clean restart.

Android Auto projection manifest validation is available as a focused manual
gate:

```bash
./tool/verify_android_auto_manifest.sh
```

It checks that release discovery metadata and the canonical
`com.ryanheise.audioservice.AudioService` are present and no privileged
media-browser bind permission blocks Android Auto.

Mix and radio runtime checks use an isolated Linux diagnostics clone. The
clone-only `/v1/mix/*` API exercises production providers and queue commits;
an optional Last.fm key file must be owned by the current user and mode 600.
The normal build-time Last.fm key precedence remains unchanged.

Rapid playback navigation has a focused Linux runtime gate:

```bash
NAVIS_DIAGNOSTICS_CREDENTIAL_PATH=/path/to/private-password-file \
NAVIS_DIAGNOSTICS_USERNAME=your-username \
python3 tool/rapid_playback_diagnostics.py
```

The credential file must be a private regular file. The runner clones the
local database, sends overlapping Next/Previous bursts through the authenticated
production handler, checks Pause during a row selection and the final player
state, captures an app-owned screenshot, and repeats the status check after a
clean restart. Evidence lives
under `build/rapid-playback/`. Run it for navigation, queue loading, and player
recovery or adapter changes in addition to `./tool/check.sh`; set
`NAVIS_RAPID_QUEUE_LENGTH=500` for the large-queue case.

Seeking, lyric-follow interaction and audio-adapter changes also require
`python3 tool/seek_reliability_diagnostics.py --platform linux`, and the Android
variant on a disposable emulator when available (see development workflow).
The muted synthetic profile tests early/overlapping seeks, Play/Pause preservation,
backward bursts, completed caches and WAV/MP3/FLAC/Opus with Range fault modes,
then repeats after a clean start. Keep unsupported/failing Range outcomes distinct
from supported seek acceptance. Retain app-owned screenshots and separate platform
evidence under `build/seek-reliability/`; this runtime gate complements the unit,
widget and full quality checks. For changes to seek settlement, recovery or
remote loading, also run `tool/live_seek_stress.py` against a disposable live
account, throttled and unthrottled, on Linux and an Android emulator (see
"Live-server seek stress" in the development workflow); it needs credentials,
so it is a manual gate, not part of `check.sh`.

Android Auto's service-first regression has a separate Android phone-emulator
gate. It builds only the `.dev` sidecar, force-stops it, and binds an external
MediaBrowser client without launching `MainActivity`:

```bash
./tool/android_auto_cold_start_diagnostics.sh
```

The debug sidecar install permits a version downgrade while retaining sidecar
app data, so a newer local dev build does not block this gate.

The diagnostic requires exactly one running, non-automotive Android emulator.
It asserts the service connects within 10 seconds, exposes the four Navis root
tabs, completes audio bootstrap, and emits no fatal Android or Flutter logs.
It complements, but does not replace, the physical-phone DHU projection check.

Library sync metered-network guardrails are exercised by the clone diagnostics
suite (`./tool/sync_diagnostics.sh clone`). Its post-report Library screenshot
is an app-owned artifact for visual verification of the pending hydration
notice. The suite records the matching idle sync status after the performance
sample so Library tab queries do not alter that sample. The saved report's
`databaseCanarySlowSamples` trace attributes reads above 100 ms to their sync
phase and observed event-loop delay without changing the canary thresholds.
`slowFrameSamples` records build/raster detail and approximate sync phase for
frames over the 100 ms maximum. Automatic cellular work remains a single
probe, while a foreground manual check is certified as
`manualMeteredLimitedDiscovery` with one newest-album page, no artist sweep or
bulk-song index, and no more than three album details.
The harness verifies those counts against the durable attempts created after
each action, so an earlier repair result cannot satisfy a later guardrail.
It can simulate network cost overrides without cellular hardware. The focused
action-correlation regression check is `python3 -m unittest
tool.sync_diagnostics_action_test`.

`tool/perf_diagnostics.py` is a manual before/after measurement tool, not a
gate: it needs a real server credential file and the network, and its numbers
depend on the host. Run it around performance-sensitive changes and record the
comparison, as in `docs/audits/performance-audit-2026-09-30.md`.

Target-hydration controller isolation has a separate clone-only Linux gate:

```bash
./tool/sync_target_lane_diagnostics.sh
```

It seeds distinct future per-server automatic and retry-cooldown deadlines in
the isolated fixture, then uses the production automatic-sync endpoint to
prove that the app does not start or relabel catalog work before its normal
deadline. It drives a repeated
Home-to-Library-to-Liked transition through the live router and the same
Library-section provider as the visible rail, asserting that catalog status,
aggregate catalog counts, and the controller ledger are unchanged. It then
repeats the Home-to-Liked navigation while the clone is explicitly offline,
then sends an album target request through the production controller and makes
the same assertion while that request is active. It captures the Liked and
Sync Settings presentations and repeats the health/status/screenshot checks
after a clean restart, asserting that the automatic deadline itself did not
move and that both reported deadlines equal the persisted sync-state row. The
retry cooldown must also be unchanged unless a catalog check ran after the
restart (for example, an interrupted Check for updates in the cloned profile).
A completed or budget-limited partial check must have cleared it, and a failed
one must have scheduled a new one. The clone uses the desktop secure-storage
password; when that store is locked or unavailable, set
`NAVIS_DIAGNOSTICS_CREDENTIAL_PATH` to a private password file. The gate stops
with an explicit error if the clone loses its server session.
It also exports and validates the bounded redacted sync ledger, ensuring target
hydration is attributable without sensitive server or library fields and reaches
a recorded terminal transition rather than merely being accepted.

Unchanged-cursor manual album discovery has its own isolated Linux gate:

```bash
./tool/manual_discovery_diagnostics.sh
```

It copies the primary database into an isolated profile, points it at a
loopback Subsonic fixture that adds one album to a known artist without moving
`getIndexes.lastModified`, and invokes the running app's Check for updates API
while the running app is offline. The gate verifies deferred delta discovery in
the redacted ledger, restores Wi-Fi, and invokes the production automatic entry
point to prove the queued user work runs before its otherwise-future automatic
deadline. It observes only a narrow authenticated album-existence contract,
checks the resumed terminal ledger for `getIndexes`, newest-list, artist-detail,
and album-detail calls, then opens the discovered album after a clean restart.
It rejects blank compositor screenshots and never sends data to a real server.
With `NAVIS_MANUAL_DISCOVERY_OMIT_EXISTING=1` and
`NAVIS_MANUAL_DISCOVERY_FORCE_MANUAL_RESUME=1`, the same isolated gate returns
a partial artist detail and proves a user Check for updates retains an omitted
existing sibling album while importing the new one.

The live clone suite requires the no-override cellular Repair Library action
to defer for `waitingForMobileConsent` before creating repair work or sending
requests. A false `updatesAvailable` value is valid for this consent state.

Large-deletion repair confirmation has a separate deterministic gate:

```bash
./tool/repair_confirmation_diagnostics.sh
```

It creates a fixture candidate with enough server-missing rows to require the
production confirmation boundary, verifies that the committed catalog survives
the pending state and a clean restart, then issues the explicit confirming
Repair Library action and verifies atomic promotion plus its durable redacted
before/after/removal operation-ledger entry. The fixture is isolated and never
modifies a configured server or primary profile. It stamps the clone with the
current library sync model so an older source export cannot start an unrelated
model-upgrade repair during the confirmation restart. The fixture also uses
the production ten-minute sync lease so the large local promotion can finish
without the diagnostic default's six-second expiry. Its inspected Sync Settings
screenshots accompany a saved `repair-confirm-report.json`; the gate also
requires its artist-count database canary to stay within 100 ms at p95 and
500 ms at maximum during the confirmation repair. The screenshot capture must
show the matching `Last library change` summary, proving the
durable evidence is visible to the user as well as the diagnostics API.

First-login and logout ownership are exercised separately with:

```bash
./tool/auth_lifecycle_diagnostics.sh clone
./tool/auth_lifecycle_diagnostics.sh partial
./tool/auth_lifecycle_diagnostics.sh existing-catalog
```

This clone-only Linux profile gate covers the `/initial-sync` route, offline
recovery and app-owned screenshots, safe catalog promotion and restart,
playback-to-sign-out teardown, queue/activity cleanup, and setup cancellation,
including a new sign-in in the same process after a cancel.
The `partial` mode separately proves that a committed catalog with only
incomplete album details opens Home, retains its incomplete state across a
clean restart, and later hydrates the missing tracks through automatic sync.
The `existing-catalog` mode proves that keep-data sign-out and sign-in returns
a completed profile to Home. It also proves that a wipe sign-out or a
cancelled setup followed by a new sign-in starts a fresh setup in the same
process, and that an interrupted first setup with an already promoted catalog
leaves `/initial-sync` through a full scan instead of repeating incremental
discovery. The `partial` mode also repeats manual cache reset and Repair
Library in one process.
It uses a deterministic loopback Subsonic fixture and isolated credential file;
it never reads device third-party credentials or enables personalized Last.fm
or ListenBrainz discovery, and it must never be run in primary-certification
mode.

`tool/presentation_diagnostics.sh` may enable the clone-only
`cachedListenBrainzPresentation` override for an explicit weekly-playlist
route. That path reads only the isolated weekly cache through production
providers; it does not copy, validate, log, or return ListenBrainz credentials
or usernames.
For a remote Search playback capture, it verifies a ready player and advancing
position through the authenticated playback status before accepting the result;
the `playing` flag alone does not prove that audio started.
Its optional remote-seek path verifies resumed progress after a 30-second seek
on both sides of a clean restart.
It may also enable `artistTopTracksPresentationFixture` for an explicit local
artist Top Tracks route. That fixture supplies deterministic rows through the
production provider and never requires a Last.fm key or contacts the configured
server.

Leaving a custom download folder has a focused isolated Linux gate:

```bash
./tool/download_folder_diagnostics.sh
```

An empty clone profile signs in to the loopback lifecycle fixture and
downloads the fixture song into app storage. It then chooses a fixture folder
inside the run root that already holds a user's copy of the song, and turns
the folder off through the Downloads settings switch and its confirmation
dialog. After a clean restart it chooses the folder again, then switches to a
second folder that holds its own copy of the song, which must be adopted in
place. The gate snapshots every file in both folders (path, size, sha256) and
requires the snapshots to stay unchanged from the moment each folder is
chosen. It never reads the primary profile or a real download
folder. Open the `folder-on`, `turn-off-dialog`, `folder-off` and
`restart-folder-off` screenshots. It supplements but does not replace
`./tool/check.sh`, and does not cover Android SAF folders.

Desktop volume restart behavior has a focused manual runtime gate:

```bash
./tool/volume_memory_diagnostics.sh
```

It launches the Linux profile app against an isolated clone, authenticates via
the app API, and verifies volume, mute, Unmute, persistence, and clean restart.
It supplements but does not replace `./tool/check.sh`.

Playback settings autosave has a focused manual runtime gate:

```bash
./tool/playback_settings_diagnostics.sh
```

It signs an isolated clone in to the loopback fixture, flips Scrobbling on the
mounted Playback settings screen, and verifies that the ListenBrainz account,
unmetered-only background sync and desktop volume survive the save and a clean
restart, and that neither the save nor a desktop volume write restarts weekly
ListenBrainz discovery. It supplements but does not replace `./tool/check.sh`.

Current-song row presentation has a focused isolated Linux runtime gate:

```bash
NAVIS_DIAGNOSTICS_PRIMARY_DB=/absolute/path/to/navis.sqlite.sqlite \
  ./tool/playback_indicator_diagnostics.sh clone
```

It verifies authenticated app startup, current/inactive indicators, paused
marker persistence, song switching, app-owned screenshots, log cleanliness,
and a clean restart. The agent must open and inspect the generated PNGs; file
creation alone is not visual confirmation. It supplements but does not replace
`./tool/check.sh`. Set
`NAVIS_QUALITY_GATE_RESULT=passed` for the final post-gate run so its sanitized
validation record includes the quality-gate result.

Visible Flutter changes without a more focused scenario use the generic
presentation gate:

```bash
NAVIS_DIAGNOSTICS_PRIMARY_DB=/absolute/path/to/navis.sqlite.sqlite \
  ./tool/presentation_diagnostics.sh clone / home
```

It drives the live router through the authenticated Navis API, waits for the
acknowledged destination route to settle, and captures the Flutter surface
before and after a clean restart. It validates artifact
containment, PNG metadata, hashes, and permissions, but the agent remains
responsible for opening both images and inspecting the affected region.
AT-SPI and external desktop automation are not substitutes for this gate.
For Search ordering and presentation, set
`NAVIS_PRESENTATION_SEARCH_QUERY`, use route `/search`, and optionally set
`NAVIS_PRESENTATION_SEARCH_REQUIRE_MIXED=1`; the harness asserts relevance-
first/source-tie ordering through the production provider and captures the
settled results before and after restart.
For the recoverable empty failure state, use an intentionally unmatched query
with `NAVIS_PRESENTATION_FORCE_SEARCH_REMOTE_FAILURE=1`. This clone-only switch
sets the authenticated diagnostics override before the production Search
provider runs; it must never be used outside the isolated clone profile.
Set `NAVIS_PRESENTATION_OPEN_NOW_PLAYING=1` to capture the current clone
profile's Now Playing overlay without depending on remote stream playback.
Set `NAVIS_PRESENTATION_SEARCH_FILTER=songs` and
`NAVIS_PRESENTATION_SEARCH_PLAY_REMOTE=1` to additionally play the first remote
song through the production queue path and capture its Now Playing metadata.
For the real Albums filtered-empty state, run
`NAVIS_PRESENTATION_LIBRARY_FILTER_QUERY='no-match' ./tool/presentation_diagnostics.sh clone /library library-filtered-empty`.
For Radio's equivalent, run
`NAVIS_PRESENTATION_RADIO_FILTER_QUERY='no-match' ./tool/presentation_diagnostics.sh clone '/library?section=radio' radio-filtered-empty`.
The Radio path enables a deterministic station fixture; both drive the
production Library filter through its authenticated diagnostics control and
capture the state before and after a clean restart.
For a populated Artist Top Tracks review, run
`NAVIS_PRESENTATION_ARTIST_TOP_TRACKS_FIXTURE=1 ./tool/presentation_diagnostics.sh clone '/library/artists/<artist-id>/top-tracks' artist-top-tracks`.
It applies deterministic clone-only rows before navigating to the production
detail screen.
For the persistent error-notice treatment, run
`NAVIS_PRESENTATION_ERROR_NOTICE=1 ./tool/presentation_diagnostics.sh clone / error-notice`.
It posts a bounded diagnostics-only error to the mounted global notice host,
then captures the visible recovery surface before and after a clean restart.

Desktop layout changes also run the isolated window-mode scenario:

```bash
NAVIS_DIAGNOSTICS_PRIMARY_DB=/absolute/path/to/navis.sqlite.sqlite \
  ./tool/desktop_layout_diagnostics.sh
```

The scenario exercises the authenticated window API and captures 1306×853
standard, 1159×678 short, 887×900 compact, and minimum 800×600 Desktop View.
It also captures the canonical 720×405 Mini Player, its manually resized
560×360 minimum, the Desktop transition gate at both 799×599 and the short
799×444 edge case, the Mini transition gate, canonical Keep Mini restoration,
and a clean Linux profile restart. Desktop captures must retain Favorite,
Lyrics, Queue, Mini Player, and the full volume control without overflow; Mini
captures must keep volume below transport/actions and centered tight metadata,
and every transition choice must remain fully visible. The diagnostic
re-observes the settled Flutter surface after desktop resize or restart
transitions before final capture, so an intermediate compositor frame cannot
count as visual evidence.

### Branding Regeneration

When the canonical `lib/src/icon/Navis_Logo.svg` changes, run:

```bash
./tool/generate_platform_icons.sh
```

This ImageMagick-backed generator refreshes the runtime PNG sources and all
Android, iOS, macOS, Linux, and Windows icon outputs. Android adaptive and
status-bar variants and every macOS downscale are part of the generated
contract. Desktop and Android launchers must retain transparent pixels outside
the circular badge; iOS is intentionally flattened to the required opaque
canvas. Inspect representative platform outputs over light and dark
backgrounds, including the smallest notification/desktop sizes, before running
`./tool/check.sh`.

On Linux, `./tool/dev_app.sh linux` installs a content-addressed user icon, a
`~/.local/bin/navis` launcher, and a desktop file whose `Exec` is that
absolute launcher path, then refreshes the desktop/icon caches before launch.
Use `./tool/dev_app.sh linux-icon` to perform only that cache-safe refresh.
The launcher runs only the release bundle (`./tool/dev_app.sh linux-release`);
`tool/linux_desktop_entry_test.sh` fails if it can run a profile or debug
bundle, which diagnostics scripts overwrite with clone builds.

### Core Gate

Use for the focused release checks when the full development test matrix is not
required:

```bash
./tool/release_gate_core.sh
./tool/release_gate_core.sh --quick
```

## Release (`tool/release.sh`)

Builds selected release artifacts, tags the commit, creates a Forgejo release, and uploads all assets — all from the local machine.

### Setup (one-time)

1. Install `jq`:
   ```bash
   # macOS
   brew install jq
   # Linux
   sudo apt install jq
   ```

2. Create `tool/release.env` with your Forgejo credentials (this file is git-ignored):
   ```bash
   FORGEJO_URL="https://your-forgejo-instance.com"
   FORGEJO_REPO="your-user/Navis"
   FORGEJO_TOKEN="your-api-token"
   ```

3. Ensure the script is executable:
   ```bash
   chmod +x tool/release.sh
   ```

### Usage

```bash
./tool/release.sh v0.2.0
./tool/release.sh v0.2.0 --channel=dev
./tool/release.sh v0.2.0 --targets=android,macos
./tool/release.sh v0.2.0 --all-platforms
./tool/release.sh v0.2.0 --targets=linux --linux-package=deb
./tool/release.sh v0.2.0 --targets=windows --windows-package=exe
./tool/release.sh v0.2.0 --targets=macos --macos-notarize
./tool/release.sh v0.2.0 --targets=linux,windows --linux-ssh="linux-builder" --windows-ssh="windows-builder"
./tool/release.sh v0.2.0 --allow-existing-version
```

Or via Makefile:
```bash
make release VERSION=v0.2.0
```

### What it does

1. Fails if the requested version was already released, meaning its tag
   (for example `v1.4.1`) exists locally or on origin
   (`tool/release_tag_guard.sh`), unless `--allow-existing-version` is passed
   for an intentional rebuild or retry; the retry then reuses that tag instead
   of creating it. `pubspec.yaml` already naming the version is expected:
   development starts the next version as soon as work on it begins (see
   "Versioning" in [agentic-engineering.md](agentic-engineering.md)), so the
   script reports it and continues. It also fails when it cannot read origin's
   tags. `tool/release_tag_guard_test.sh` covers these cases in
   `tool/check.sh`.
2. Requires `android/key.properties` when Android is selected, before loading
   secrets or running gates. Publication never accepts the local debug-signing
   opt-in, and signer validation fails if the properties file disappears.
   Runs `./tool/check.sh` unless `--skip-checks` is passed.
3. Builds selected artifacts for requested targets (`android`, `ios`, `macos`, `linux`, `windows`).
   Android release builds clean stale Flutter/Gradle APK outputs before
   building and remove any same-name root release asset before copying the new
   APK.
   Linux target can output either portable `bundle` (tar.gz) or `.deb`
   (`--linux-package=deb`). Debian package output is architecture-aware
   (`linux-<arch>.deb`) and includes a launcher binary and desktop entry.
   Windows target can output `.zip` (default) or Inno Setup `.exe` installer
   (`--windows-package=exe`). macOS target can optionally sign + notarize +
   staple before packaging (`--macos-notarize`). On non-Linux/non-Windows
   hosts, Linux/Windows desktop builds can be delegated to remote SSH builders
   (`--linux-ssh`, `--windows-ssh`).
4. Validates Android APK package name, version name/code, signing certificate,
   retired active Listen Together/Voyage string absence, and the Artist Top
   Tracks Album Queue marker before upload.
5. Passes `--dart-define=NAVIS_UPDATE_CHANNEL=<stable|dev>` to Flutter builds.
   The bundled Last.fm key goes in as a masked pair (see "Last.fm key" below),
   not as a plain define.
6. For `--channel=dev`, defaults Android sidecar identity to `.dev` / `Navis Dev`.
7. Creates an annotated git tag and pushes main/current branch/tag.
8. Creates a Forgejo release with `prerelease=true` for dev channel (or when `--prerelease` is passed).
9. Uploads all built assets to the release.

After each artifact is built, `release.sh` searches it for the plaintext
Last.fm key and fails the release before anything is tagged or uploaded if it
appears. APK, AAB, IPA, macOS zip and Windows zip are unpacked; tarballs
(gzip, xz, zstd, bzip2) and `.deb` files (via `dpkg-deb`, or `ar` plus the
compressed `data.tar.*` inside) are extracted; nested archives are followed up
to four levels deep. A Windows Inno Setup `.exe` is compressed and can only be
scanned as raw bytes, so the unpacked Windows release directory is scanned
before it is packaged: by `release.sh` on a Windows host, and by
`tool/windows/scan_release_secret.ps1` on the remote Windows builder (it
recovers the key from the masked defines in memory only). An artifact that
cannot be unpacked (a missing decompressor such as `xz` or `zstd`, a corrupt
archive, or nesting beyond the depth cap) fails the scan rather than passing
it, and so does any `grep`, `find`, temporary-file or extraction error: a
scanner failure is never read as "secret absent".

Use `--allow-existing-version` only when intentionally rebuilding a version
that was already tagged, such as retrying failed artifact publication. Normal
releases advance the version so installed apps can detect updates; which
increment to use is set out in "Versioning" in
[agentic-engineering.md](agentic-engineering.md). Before 2026-10-03 the guard
compared `pubspec.yaml` instead of the tag, so a version set early on `dev`
needed this flag; it no longer does.

### Release channels

- `stable` channel assets are named `navis-<tag>.*`
- `dev` channel assets are named `navis-dev-<tag>.*`

The app updater uses `NAVIS_UPDATE_CHANNEL` to prefer channel-matching assets.

### Required environment variables

| Variable | Description |
|---|---|
| `FORGEJO_URL` | Forgejo instance URL (e.g. `https://forgejo.example.com`) |
| `FORGEJO_REPO` | Repository path (e.g. `user/Navis`) |
| `FORGEJO_TOKEN` | API token with release write access |

Optional variables:

| Variable | Description |
|---|---|
| `NAVIS_DEB_MAINTAINER` | Maintainer string for Linux Debian package metadata |
| `MACOS_SIGN_IDENTITY` | Developer ID Application signing identity used by `--macos-notarize` |
| `MACOS_NOTARY_PROFILE` | `xcrun notarytool` keychain profile name used by `--macos-notarize` |
| `NAVIS_LINUX_SSH` | Default SSH target for remote Linux builder |
| `NAVIS_WINDOWS_SSH` | Default SSH target for remote Windows builder |
| `NAVIS_LINUX_REMOTE_DIR` | Remote Linux working dir relative to remote HOME |
| `NAVIS_WINDOWS_REMOTE_DIR` | Remote Windows working dir relative to remote HOME |
| `NAVIS_WINDOWS_FLUTTER_DIR` | Optional Windows-host Flutter SDK directory for remote builds |

Set these in `tool/release.env` or export them in your shell.

`NAVIS_LASTFM_API_KEY` is required for Android and Play builds and bundled in
every target when set.

### Last.fm key

The Last.fm API key is bundled so most users never have to supply one. Builds
do not pass it as `--dart-define=NAVIS_LASTFM_API_KEY=...`:

- `tool/lib/lastfm_key_defines.sh` generates a fresh random pad per build and
  writes `NAVIS_LASTFM_API_KEY_MASKED` (key XOR pad) and
  `NAVIS_LASTFM_API_KEY_PAD` (both hex) to a mode-600 JSON file passed with
  `--dart-define-from-file`, so neither value is on the scripts' own command
  lines (Flutter may forward defines to its child processes, so this is hygiene,
  not a guarantee). The file is deleted when the script exits.
- `AppConstants.lastFmApiKey` XORs the pair back at runtime. A plain
  `NAVIS_LASTFM_API_KEY` define is still accepted when the pair is absent, so
  local `flutter run --dart-define=...` keeps working.
- `release.sh`, `dev_app.sh`, `play_release.sh`, `remote_build_linux.sh` and
  `remote_build_windows.sh` all use it. The remote scripts take
  `--lastfm-defines-file=<path>`; the Linux builder receives it over ssh stdin
  into a mode-600 file and the Windows builder over scp into its remote work
  directory, and each deletes it when the build ends. The source archive sent
  to builders excludes `tool/release.env`.
- `play_release.sh` requires the key and scans the App Bundle too.

This deters casual extraction (a `strings` search of the binary no longer finds
the key). It is not secrecy: the app must hold the key to use it, anyone running
it can recover it, and a Last.fm API key is a client identifier rather than a
credential. No Last.fm shared secret is bundled or used.

### Additional packaging prerequisites

Android builds use AGP 9.3.1, the checksum-pinned Gradle 9.5.0 wrapper and Kotlin
2.4.20 with built-in Kotlin enabled. Compile SDK remains 37, target SDK 36,
minimum SDK 24 and Java/Kotlin bytecode target 17. Flutter 3.47.5 still calls
legacy variant APIs, so `android.newDsl=false` is required despite built-in
Kotlin support. This is the compatibility setting described in Flutter's
[migration guide](https://docs.flutter.dev/release/breaking-changes/migrate-to-built-in-kotlin/for-app-developers).
Remove it when stable Flutter supports the public AGP API surface; AGP 10 must
not be adopted while that legacy dependency remains. Plugin-owned Media3
versions remain resolved by just_audio rather than independently overridden.

The owned Windows SMTC adapter uses the tracked
`third_party/navis_windows_smtc/Cargo.lock` workspace lockfile. CargoKit builds
with `--locked`; dependency updates must regenerate and review this workspace
lock rather than allowing release builds to resolve a different Rust graph.
Do not use a nested `rust/Cargo.lock` as the dependency source of truth.
CargoKit's artifact hash includes the workspace manifest and authoritative lock
for workspace members, so dependency-only fixes and release-profile changes
cannot reuse an artifact keyed solely by unchanged Rust source.
Bootstrap resolves the owned packages' development dependencies as well as the
root app graph, so a fresh checkout can analyze their generators and drivers.

Remote Windows builds prepare the SQLite DLL from the exact root-lockfile
release before contacting the builder. `tool/sqlite3_windows_asset.py` verifies
the download against `asset_hashes.dart` in that resolved Pub package; the
Windows script checks the transferred hash again and uses the supported native
hook's bundled-file source. Missing downloads, wrong release metadata or hash
mismatches fail the build. No older DLL cache fallback or published hook-source
patch is used. The local host needs the resolved Pub cache and network access
to obtain the DLL; the Windows host can remain offline for this native asset.
The asset helper's success/failure tests run in `tool/check.sh`.

- Windows installer mode (`--windows-package=exe`)
  - Requires Inno Setup 6 (`ISCC.exe`) on the Windows build host.
  - Install from https://jrsoftware.org/isdl.php and ensure `ISCC.exe` is on `PATH`.
- macOS notarization mode (`--macos-notarize`)
  - Requires a valid Developer ID Application certificate in keychain.
  - Requires a configured `notarytool` keychain profile:
    ```bash
    xcrun notarytool store-credentials navis-notary-profile \
      --apple-id "<apple-id>" \
      --team-id "<team-id>" \
      --password "<app-specific-password>"
    ```

Credential governance and secure handling reference:
`docs/release-secrets.md`

Remote desktop build architecture and setup:
`docs/multi-os-build-from-mac.md`

## Dependency Health (manual)

Run periodically to check for outdated packages:

```bash
flutter pub outdated
dart pub outdated
```

Or via Makefile:
```bash
make outdated
```

## Release Workflow Summary

The intended flow for shipping a feature or fix:

1. Work on `dev` branch (or a `phase/` branch merged into `dev`).
2. Run `./tool/check.sh` — all checks pass.
3. Commit with Conventional Commits format.
4. When ready to release: merge `dev` → `main`.
5. Run `./tool/release.sh v0.x.0` from `main`.
6. The script handles everything: checks, build, tag, Forgejo release, APK upload.

The manual discovery gate also calls `GET /v1/library/album?verifySongs=true`
(with the fixture album `id`) and requires `persistedSongCount` before and after
restart. A hydration flag or declared server count alone is insufficient proof
that an album's tracks were actually stored.

For sync/outbox changes, the loopback manual-discovery gate accepts
`NAVIS_ANNOTATION_FIXTURE=true` and verifies offline favorites/ratings delivery
using exact typed Subsonic parameters. It enables delivery only to the isolated
loopback fixture and discards copied pending annotations. Sync interaction traces
can reset diagnostics metrics and drive the mounted Albums scroll controller
through clone-only authenticated API endpoints; inspect resulting screenshots
and keep timing interpretation consistent with `docs/development-workflow.md`.


Android worker certification can use the isolated profile-sidecar fixture
contract in `development-workflow.md`. The opt-in
`NAVIS_DIAGNOSTICS_ANDROID_WORKER_FIXTURE` permits that sidecar's production
secure storage for cross-engine session recovery; it is ignored outside an
Android clone build with a nonempty application suffix. This is separate from
the default in-memory clone credential workflow and from primary certification.

The auth/manual-discovery fixture returns album-specific detail identities for
both its existing and newest album, and an explicit not-found error for unknown
IDs. This permits worker continuation tests to verify every declared fixture
album without accidentally exercising an unrelated identity-mismatch failure.

Large clone-mode first-sync certification can set
`NAVIS_SYNC_DIAGNOSTICS_LEASE_SECONDS=600` at compile time to retain production
lease duration during atomic promotion. `tool/dev_app.sh` applies that value to
its interactive sync presets. Keep the default accelerated lease for
interrupted-owner scenarios; neither mode bypasses the write fence.


Attempt-telemetry changes require migration coverage for schema v77, bounded
phase/transport retention, retry attribution, interrupted recovery, privacy and
terminal-row immutability. In the isolated Linux repair/restart loop, capture
`GET /v1/sync/attempts` and check that the report's `reportedAttempt.attemptId`
matches `sync.runAttemptId` even when auxiliary work completes later. Verify
request/byte totals, publication-phase ordering and the same persisted attempt
after restart. Telemetry capture completion alone is not sync completion.

Frame-attribution changes preserve the legacy build-plus-raster `frames` field
and test independent `frameBuild`, `frameRaster` and `frameSpan` timing, the
5,000-sample cap and atomic window reset. Runtime evidence must state library
size, playback/sync activity and renderer; a no-sync scrolling control cannot
stand in for playback-under-sync certification.

### Responsive layout evidence

For changes to bounded grids, adaptive song rows, Home shelves/carousel,
station cards or desktop playback-time layout, run the focused geometry,
settings migration, occurrence-action, timer and shell regressions, then the
normal full gate. `tool/presentation_diagnostics.sh clone / responsive-layout`
records the initial/restarted Linux pane matrix, preference persistence and
clean logs through authenticated production owners. Its extra captures must
be opened and assessed; Android touch and orientation require separate
sidecar runtime evidence. The clone-only appearance endpoint contract tests
protect input validation, targeted persistence and certification-mode isolation.

For the album-motion/number-header follow-up, the `responsive-polish` label
adds real album-opening and scoped Liked paging actions on both launches.
Inspect all captures and retain the timed route, hover/accessibility, keyboard
paging and number-column alignment tests. The library-action contract tests
reject unsupported payloads, unauthenticated requests and primary certification.

Playback adjustment changes additionally use
`./tool/playback_adjustment_diagnostics.sh` for the isolated Linux runtime,
native PCM frequency checks (440→550 Hz at locked 1.25×, unchanged pitch after
unlocking), linked preset persistence, the desktop player Speed popover and
speed-shortcut round trip, the mini Equalizer popover, preset selection and
return-to-origin navigation, and restart loop. Capture requires PulseAudio/PipeWire
tools and NumPy. The quality gate includes the new conversion/controller, paired
handler, storage, API and responsive widget regression tests through the full
suite; native device/host coverage must still be reported separately.

### Equalizer release evidence

The quality gate includes native JVM response/PCM fixtures as well as Dart,
controller, migration, and adaptive widget tests. `tool/equalizer_diagnostics.sh`
adds real Linux output measurements and restart/screenshots; APK builds and the
isolated Android API driver add native bridge/lifecycle evidence. These checks
do not replace physical Android listening or Windows/macOS runtime validation.
See [equalizer.md](equalizer.md).

EQ validation includes the v85 working-draft migration, independent
preset/mode recovery, grouped editing history, precision-preserving band
editors, and clone-only presentation controls. The Linux EQ diagnostics driver
checks preview/cancel with captured PCM as well as persistence and screenshots;
the Android driver checks the corresponding native status and mounted controls
in an isolated sidecar.

Graph EQ validation additionally covers coordinate mapping, precise inline
editing, gesture cancellation/grouped Undo, checkpoint failures and stale edits,
overlap selection, keyboard/large-text layouts, AutoEQ round trips, and a measured
32-band runtime profile through authenticated presentation diagnostics.

Windows SMTC diagnostics use `--no-pub` with a prepared dependency graph,
allow up to five minutes for native build/startup, and wait for restored app
presentation before capturing screenshots. On failure they retain only selected
playback-state fields for diagnosis. Windows PowerShell 5.1 cleanup terminates
the task-owned process tree if authenticated shutdown does not finish.

Apple native runtime checks are deferred by the project owner while Apple
development is unavailable. Record that limitation instead of blocking
non-Apple upgrade handoff or claiming an Apple pass. Emulator media-browser
and MediaSession tests are Android integration evidence; full DHU projection
requires the full Google Android Auto phone component and remains a separate
check. See `docs/android-auto-testing.md` for the seeded Dev fixture gate.
