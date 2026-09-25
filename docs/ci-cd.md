# Quality Gates & Releases

All quality gates and release publishing run locally. There is no CI runner — `tool/check.sh` and `tool/release.sh` replace what Forgejo Actions workflows would do.

Windows media-session changes additionally require the Windows-only isolated
GMTC validation command described in `docs/development-workflow.md`:
`tool/windows_smtc_diagnostics.ps1`. It runs after Linux smoke and focused
tests; it is not a replacement for `./tool/check.sh`.

`tool/dev_app.sh run -d linux` accepts interactive, isolated sync/setup
presets. Their profile-mode clone and fixture flows are documented in
`docs/dev-testing-builds.md`; they are exploratory launchers, not quality-gate
replacements. Changes to their launch or preparation behavior require focused
scenario tests, the Linux app/API runtime loop, and this repository gate.

## Quality Gate (`tool/check.sh`)

Run before every commit (automatically enforced if the pre-commit hook is enabled):

```bash
./tool/check.sh
```

Checks performed (in order, fail-fast):
1. `/tmp` disk-space preflight
2. Linux desktop-entry installer (`tool/linux_desktop_entry_test.sh`)
3. `dart format --set-exit-if-changed .`
4. `dart run build_runner build`
5. `flutter analyze --no-fatal-infos`
6. Drift migration tests
7. Critical routing/provider/playback/library sync test suite
8. Full `flutter test`
9. Coverage when `CI=true`

The script also checks `/tmp` disk space before starting to prevent misleading test hangs.

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
after a clean restart, asserting that the deadline itself did not move.
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
```

This clone-only Linux profile gate covers the `/initial-sync` route, offline
recovery and app-owned screenshots, safe catalog promotion and restart,
playback-to-sign-out teardown, queue/activity cleanup, and setup cancellation.
The `partial` mode separately proves that a committed catalog with only
incomplete album details opens Home, retains its incomplete state across a
clean restart, and later hydrates the missing tracks through automatic sync.
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

Desktop volume restart behavior has a focused manual runtime gate:

```bash
./tool/volume_memory_diagnostics.sh
```

It launches the Linux profile app against an isolated clone, authenticates via
the app API, and verifies volume, mute, Unmute, persistence, and clean restart.
It supplements but does not replace `./tool/check.sh`.

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
`NAVIS_PRESENTATION_RADIO_FILTER_QUERY='no-match' ./tool/presentation_diagnostics.sh clone '/library#radio' radio-filtered-empty`.
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

1. Fails if `pubspec.yaml` already has the exact requested `version: <semver>+<build>` value, unless `--allow-existing-version` is passed for an intentional rebuild or retry.
2. Runs `./tool/check.sh` unless `--skip-checks` is passed.
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
6. For `--channel=dev`, defaults Android sidecar identity to `.dev` / `Navis Dev`.
7. Creates an annotated git tag and pushes main/current branch/tag.
8. Creates a Forgejo release with `prerelease=true` for dev channel (or when `--prerelease` is passed).
9. Uploads all built assets to the release.

Use `--allow-existing-version` only when intentionally rebuilding the same
release version, such as retrying failed artifact publication. Normal releases
must advance the semver/build so installed apps can detect updates.

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

### Additional packaging prerequisites

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
