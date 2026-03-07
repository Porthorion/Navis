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

## Quality Gate

Run before each commit/PR:

```bash
./tool/check.sh
```

Checks performed:
- Dart formatting (`dart format --set-exit-if-changed .`)
- code generation (`build_runner`)
- static analysis (`flutter analyze`)
- lint rules (`custom_lint`)
- tests (`flutter test`)

The script fails fast when `/tmp` is critically low to avoid misleading test hangs.

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

This ensures the dev app can live next to stable and the in-app updater checks dev-channel release assets.

When Android SDK/device is not available locally, you can still verify app startup behavior with Linux desktop:

```bash
flutter run -d linux
```

This is a local workaround and does not replace Android runtime validation.
