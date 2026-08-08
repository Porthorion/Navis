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
3. Launch Navis with an isolated profile. Use Linux for platform-neutral work.
4. Call `GET /v1/health` and require a successful authenticated response before
   testing feature behavior.
5. Drive the scenario through the running app's API. Check the response,
   observable provider/domain state, persisted side effects, relevant logs, and
   the absence of new errors. Use status endpoints or bounded polling instead
   of fixed sleeps for asynchronous work.
6. Verify rendered behavior when UI automation is reliable. If the desktop
   environment cannot drive the window, add or use app-owned semantics,
   screenshot capture, or presentation-state observations for visual changes.
7. Stop the app, fix implementation or observability gaps, reset the isolated
   state as needed, and repeat from step 2. A missing control or observation
   endpoint is an implementation gap, not a reason to skip runtime validation.
8. When the focused loop passes, run `./tool/check.sh`, launch a clean app
   instance, and repeat the final acceptance and regression scenarios.

An **app API** is a control or observation interface executed by the running
Navis process and routed through the same production providers, controllers,
repositories, DAOs, and audio handlers as the UI. Unit-test method calls,
direct database edits, checking only that a process exists, and test-only state
changes that bypass the production path do not satisfy this requirement.

### Runtime target selection

Use the same loop on every host, but select the authoritative adapter for the
behavior under test:

| Change | Required runtime evidence |
|--------|---------------------------|
| Platform-neutral app behavior | Linux app launch plus the app API |
| Linux desktop or media integration | Linux app API plus MPRIS or the relevant Linux system API |
| Android or Android Auto | Linux startup smoke plus the Android media-session/MediaBrowser API on a device, emulator, or DHU as appropriate |
| Windows media integration | Linux startup smoke plus the Windows app and SMTC |
| macOS or iOS integration | Linux startup smoke plus the affected Apple target and its supported platform interface |

Direct mouse or keyboard automation may supplement API validation, but is not
the foundation of the contract because desktop environments such as KDE may
not expose reliable external UI control. If the affected target is unavailable,
mark the work unverified or blocked; only the user may explicitly accept
deferred platform validation.

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
- Desktop volume memory exposes `GET /v1/playback/volume`, clone-only
  `POST /v1/playback/volume` with a numeric `value` from 0 through 1, and
  clone-only `POST /v1/playback/volume/toggle-mute`. The status response
  reports controller, persisted, and handler values without exposing media or
  server data.

The sync diagnostics script runs its own catalog test sequence. For unrelated
features, add the smallest focused launcher or scenario script that reuses the
same lifecycle rather than pretending the sync sequence tested that feature.
Do not document or call an endpoint until its implementation and contract test
exist.

Use the focused volume-memory scenario for desktop volume changes:

```bash
./tool/volume_memory_diagnostics.sh
```

It launches a Linux profile build against one isolated clone three times. The
scenario sets 37%, verifies a clean restart, persists mute across another
restart, then verifies that Unmute returns to 37%. Sanitized JSON responses and
the local app log are retained under `build/volume-memory-diagnostics/`.

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
- Add focused server/contract tests and update this document plus
  `docs/architecture.md` when the interface or lifecycle changes.

### Completion evidence

For runtime-affecting work, the final handoff and any applicable `PROGRESS.md`
entry must record, without secrets:

- Runtime target and whether an isolated clone or explicitly approved primary
  certification profile was used.
- Acceptance and regression scenarios exercised.
- App API endpoints and native service APIs used.
- Results, relevant log review, and visual, semantics, or screenshot evidence
  when applicable.
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
