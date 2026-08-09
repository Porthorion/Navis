# Development Workflow

This document defines the local workflow expected before opening or merging changes.

## Bootstrap

Run once after clone:

```bash
./tool/bootstrap.sh
```

What it does:
- validates `flutter` and `dart` are installed
- checks Flutter minimum and active baseline expectations
- runs `flutter pub get`

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

For a Linux dev sidecar, refresh the user-level desktop entry and its
content-addressed icon without launching the app:

```bash
./tool/dev_app.sh linux-icon
```

`./tool/dev_app.sh linux` performs the same refresh automatically. The
content-derived icon name prevents Wayland compositor caches from retaining a
previous brand asset under the generic `navis` name.

Android uses the cache-busting `ic_launcher_navis` resource ID for both stable
and sideload/dev manifests. Keep that ID aligned across launcher generation,
the manifest contract test, and Android Auto manifest verification. Its
adaptive background remains transparent; the foreground owns the complete
circular badge.

## Multi-OS Host Preflight

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

Run before each commit/PR:

```bash
./tool/check.sh
```

Checks performed:
- Dart formatting (`dart format --set-exit-if-changed .`)
- code generation (`build_runner`)
- static analysis (`flutter analyze --no-fatal-infos`)
- migration and critical regression suites
- full tests (`flutter test`)

The script fails fast when `/tmp` is critically low to avoid misleading test hangs.

## Mandatory Runtime Validation

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
| Windows media integration | Linux startup smoke plus the Windows app and SMTC |
| macOS or iOS integration | Linux startup smoke plus the affected Apple target and its supported platform interface |

MPRIS, SMTC, MediaBrowser, and corresponding Apple interfaces are authoritative
only for their OS-owned integration. They do not replace the Navis API for
ordinary Flutter state. If the affected target is unavailable, mark the work
unverified or blocked; only the user may explicitly accept deferred validation.

### Linux app API

The existing Linux profile diagnostics path is the starting control plane:

- `SyncDiagnosticsServer` is enabled only for a Linux profile build with valid
  diagnostics defines.
- `tool/sync_diagnostics.sh clone` demonstrates the supported isolated launch,
  handshake, authenticated requests, restart, reporting, and shutdown flow.
- Current observation endpoints include `GET /v1/health`,
  `GET /v1/sync/status`, `GET /v1/playback/status`, and
  `GET /v1/diagnostics/report`. Actions use feature-scoped `POST` endpoints;
  `POST /v1/shutdown` provides clean termination.
- Presentation automation uses clone-only `GET /v1/presentation/status`,
  `POST /v1/presentation/navigate`, and
  `POST /v1/presentation/screenshot`. Navigation accepts local app routes;
  status distinguishes render-boundary readiness from the post-bootstrap app
  frame, while screenshots capture the Flutter surface at a deterministic 1.0
  pixel ratio and return only protected artifact metadata.
- Clone-only `POST /v1/presentation/search` submits a real query through the
  production Search providers, navigates to `/search`, waits for the final
  cached/API merge, and returns sanitized ordered IDs, relevance tiers, and
  on-server/remote classifications for acceptance assertions.
- The narrow `POST /v1/presentation/player-overlay` action shows or hides the
  queue or Now Playing through `playerOverlayStackProvider`; add similarly
  narrow production-controller actions for non-route UI instead of simulating
  coordinate clicks.
- Desktop volume memory exposes `GET /v1/playback/volume`, clone-only
  `POST /v1/playback/volume` with a numeric `value` from 0 through 1, and
  clone-only `POST /v1/playback/volume/toggle-mute`. The status response
  reports controller, persisted, and handler values without exposing media or
  server data.
- Song-row presentation exposes the read-only
  `GET /v1/presentation/song-indicator?songId=<id>` endpoint. It reports only
  production indicator and presentation roles; it never returns song metadata.

Authentication lifecycle work uses:

```bash
./tool/auth_lifecycle_diagnostics.sh clone
```

The script creates isolated database/cache profiles, uses the authenticated
`/v1/session/*` API to create a first-sync state through
`ServerDataResetService`, exercises offline recovery, captures app-owned setup
screenshots, waits for safe promotion, verifies a clean restart, starts real
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
Session status is deliberately bounded to route/sync phases, queue counts, and
playback/activity flags; URLs, usernames, credentials, and tokens are forbidden.

The sync diagnostics script runs its own catalog test sequence. For unrelated
features, add the smallest focused launcher or scenario script that reuses the
same lifecycle rather than pretending the sync sequence tested that feature.
Do not document or call an endpoint until its implementation and contract test
exist.

Use the generic presentation scenario for an app-owned runtime screenshot:

```bash
NAVIS_DIAGNOSTICS_PRIMARY_DB=/absolute/path/to/navis.sqlite.sqlite \
  ./tool/presentation_diagnostics.sh clone / home
```

It checks presentation readiness, navigates through the live `GoRouter`,
waits for transient Flutter animations to settle, captures the requested route
before and after a clean restart, validates PNG
signature, digest, dimensions, containment, and permissions, and records the
artifact paths under `build/presentation-diagnostics/`. The agent must open and
inspect both PNGs; the script intentionally cannot certify visual correctness
from file existence alone.

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
capture the selected remote result in Now Playing.

Use the focused volume-memory scenario for desktop volume changes:

```bash
./tool/volume_memory_diagnostics.sh
```

It launches a Linux profile build against one isolated clone three times. The
scenario sets 37%, verifies a clean restart, persists mute across another
restart, then verifies that Unmute returns to 37%. Sanitized JSON responses and
the local app log are retained under `build/volume-memory-diagnostics/`.

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
After `./tool/check.sh` passes, set `NAVIS_QUALITY_GATE_RESULT=passed` on the
final invocation so the sanitized runtime-validation record captures the gate.

### App API extension and safety contract

Every diagnostic or agent-control surface must:

- Be unavailable in production release builds, bind only to loopback on an
  ephemeral port, and require a random bearer token communicated through a
  mode-`0600` handshake file.
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

This runs the full quality gate, builds a release APK, tags the commit, creates a Forgejo release, and uploads the APK. See [ci-cd.md](ci-cd.md) for setup details.

For Android releases, `tool/release.sh` cleans stale APK build outputs before
building, removes an existing same-name root release asset before copying, and
fails publication if the final APK metadata/signature or release string
sentinels do not match the expected release.

`tool/release.sh` fails when `pubspec.yaml` already contains the exact requested
release version. Use a new version for normal releases; reserve
`--allow-existing-version` for intentional rebuilds or failed-release retries.

Advanced release packaging options:

```bash
# Linux native package
./tool/release.sh v0.2.0 --targets=linux --linux-package=deb

# Windows installable .exe (Inno Setup)
./tool/release.sh v0.2.0 --targets=windows --windows-package=exe

# macOS signed + notarized artifact
./tool/release.sh v0.2.0 --targets=macos --macos-notarize
```

Pre-release builds (from `dev` branch when needed):

```bash
./tool/release.sh v0.3.0-beta.1
```

Tags containing `-alpha`, `-beta`, `-rc`, or `-dev` are automatically marked as pre-release on Forgejo.

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
```

Defaults used by this script:

- `NAVIS_APP_ID_SUFFIX=.dev`
- `NAVIS_APP_NAME="Navis Dev"`
- `--dart-define=NAVIS_UPDATE_CHANNEL=dev`
- `--dart-define=NAVIS_SELF_UPDATE=true`
- Android builds use the `sideload` flavor and emit
  `build/app/outputs/flutter-apk/app-sideload-release.apk`.

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

When Android SDK/device is not available locally, you can still verify app startup behavior with Linux desktop:

```bash
flutter run -d linux
```

This is a local workaround and does not replace Android runtime validation.

### Linux Sync Diagnostics

After `./tool/check.sh` passes, exercise catalog promotion against a consistent
clone of the configured library and the real server:

```bash
NAVIS_DIAGNOSTICS_PRIMARY_DB=/absolute/path/to/navis.sqlite.sqlite \
  ./tool/sync_diagnostics.sh clone
```

The profile-only launcher stores its authenticated loopback handshake, logs,
JSON report, and database checks under `build/sync-diagnostics/`. It rewrites
cached-file paths in the clone so cancellation, restart, and deletion tests
cannot unlink primary cache files. Clone mode can simulate metered/cellular
policy through diagnostics overrides and asserts hard-probe, interactive
hydration, budget, and one-time override guardrails without requiring a real
modem.

Run primary certification only after the clone suite passes:

```bash
./tool/sync_diagnostics.sh primary-certification
```

Primary mode refuses to start beside another Navis process, disables mutation
and cancellation endpoints, requires the normal Linux database path, and
retains a timestamped SQLite online backup in
`~/Documents/navis-certification-backups` unless
`NAVIS_DIAGNOSTICS_BACKUP_ROOT` overrides that location.

## MacBook Testing Guide

For complete MacBook test procedures (quick smoke, full regression, release/notarization validation), use:

`docs/macos-testing-playbook.md`
