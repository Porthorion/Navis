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

## Optional Pre-commit Hook

Enable local guardrails:

```bash
git config core.hooksPath .githooks
chmod +x .githooks/pre-commit
```

This runs `./tool/check.sh` before each commit.

## Runtime Verification

Preferred runtime targets for this project are Android and iOS.

When Android SDK/device is not available locally, you can still verify app startup behavior with Linux desktop:

```bash
flutter run -d linux
```

This is a local workaround and does not replace Android runtime validation.
