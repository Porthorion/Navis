# Quality Gates & Releases

All quality gates and release publishing run locally. There is no CI runner — `tool/check.sh` and `tool/release.sh` replace what Forgejo Actions workflows would do.

## Quality Gate (`tool/check.sh`)

Run before every commit (automatically enforced if the pre-commit hook is enabled):

```bash
./tool/check.sh
```

Checks performed (in order, fail-fast):
1. `/tmp` disk-space preflight
2. `dart format --set-exit-if-changed .`
3. `dart run build_runner build`
4. `flutter analyze --no-fatal-infos`
5. Drift migration tests
6. Critical routing/provider/playback/library sync test suite
7. Full `flutter test`
8. Coverage when `CI=true`

The script also checks `/tmp` disk space before starting to prevent misleading test hangs.

Android Auto projection manifest validation is available as a focused manual
gate:

```bash
./tool/verify_android_auto_manifest.sh
```

It checks that release discovery metadata and the canonical
`com.ryanheise.audioservice.AudioService` are present and no privileged
media-browser bind permission blocks Android Auto.

Library sync metered-network guardrails are exercised by the clone diagnostics
suite (`./tool/sync_diagnostics.sh clone`), which can simulate network cost
overrides without cellular hardware.

Target-hydration controller isolation has a separate clone-only Linux gate:

```bash
./tool/sync_target_lane_diagnostics.sh
```

It seeds a future per-server automatic deadline in the isolated fixture, then
uses the production automatic-sync endpoint to prove that the app does not
start or relabel catalog work before that deadline. It drives a repeated
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

Large-deletion repair confirmation has a separate deterministic gate:

```bash
./tool/repair_confirmation_diagnostics.sh
```

It creates a fixture candidate with enough server-missing rows to require the
production confirmation boundary, verifies that the committed catalog survives
the pending state and a clean restart, then issues the explicit confirming
Repair Library action and verifies atomic promotion. The fixture is isolated
and never modifies a configured server or primary profile.

First-login and logout ownership are exercised separately with:

```bash
./tool/auth_lifecycle_diagnostics.sh clone
```

This clone-only Linux profile gate covers the `/initial-sync` route, offline
recovery and app-owned screenshots, safe catalog promotion and restart,
playback-to-sign-out teardown, queue/activity cleanup, and setup cancellation.
It uses a deterministic loopback Subsonic fixture and isolated credential file;
it never reads device third-party credentials or enables personalized Last.fm
or ListenBrainz discovery, and it must never be run in primary-certification
mode.

`tool/presentation_diagnostics.sh` may enable the clone-only
`cachedListenBrainzPresentation` override for an explicit weekly-playlist
route. That path reads only the isolated weekly cache through production
providers; it does not copy, validate, log, or return ListenBrainz credentials
or usernames.

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
Set `NAVIS_PRESENTATION_SEARCH_FILTER=songs` and
`NAVIS_PRESENTATION_SEARCH_PLAY_REMOTE=1` to additionally play the first remote
song through the production queue path and capture its Now Playing metadata.

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
and every transition choice must remain fully visible.

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

On Linux, `./tool/dev_app.sh linux` installs a content-addressed user icon and
refreshes the desktop/icon caches before launch. Use
`./tool/dev_app.sh linux-icon` to perform only that cache-safe icon refresh.

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
