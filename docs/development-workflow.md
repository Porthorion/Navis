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

When Android SDK/device is not available locally, you can still verify app startup behavior with Linux desktop:

```bash
flutter run -d linux
```

This is a local workaround and does not replace Android runtime validation.
