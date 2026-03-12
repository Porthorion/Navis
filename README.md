# Navis

Navis is a Flutter Subsonic/OpenSubsonic music client focused on fast library browsing, reliable offline playback, and adaptive UI across phone, tablet, desktop, and in-car workflows.

## Platform Support

| Platform | Status | Notes |
|---|---|---|
| Android | Supported | Primary mobile target, side-by-side dev build flow available |
| iOS | Supported | Built from macOS/Xcode |
| macOS | Supported | Native desktop build on macOS |
| Linux | Supported | Built on Linux host or remote Linux builder |
| Windows | Supported | Built on Windows host or remote Windows builder |

Minimum tested versions:
- Android 8.0 (API 26)
- iOS 14+
- macOS 12+
- Ubuntu 22.04+ (or equivalent Linux desktop runtime)
- Windows 10/11

## Core Capabilities

- Library sync from Subsonic/OpenSubsonic servers
- Gapless/background playback and lock-screen controls
- Queue management, instant mix, and smart queue behaviors
- Synced/unsynced lyrics with full-screen now playing
- Offline cache plus permanent download modes
- Adaptive layouts that scale from phone to tablet/desktop
- Channel-aware updater behavior for stable/dev release tracks

## Quick Start

```bash
# bootstrap dependencies and local tooling
./tool/bootstrap.sh

# run on connected device / simulator
flutter run

# full quality gate (format, codegen, analyze, lint, tests)
./tool/check.sh
```

## Release

```bash
# default target: android
./tool/release.sh v1.2.3

# selected targets
./tool/release.sh v1.2.3 --targets=android,ios,macos

# full matrix
./tool/release.sh v1.2.3 --all-platforms
```

### Single-Mac Multi-OS Release Flow

When running release from macOS, Linux and Windows desktop artifacts can be delegated to SSH-accessible builders (typically local VMs on the same Mac):

```bash
./tool/release.sh v1.2.3 \
  --targets=linux,windows \
  --linux-ssh="linux-builder" \
  --windows-ssh="windows-builder"
```

Full setup and builder requirements:
- [`docs/multi-os-build-from-mac.md`](docs/multi-os-build-from-mac.md)

## Dev Channel Sidecar

```bash
./tool/dev_app.sh run -d <device-id>
./tool/dev_app.sh apk
```

This builds a side-by-side dev app (`.dev` suffix, `Navis Dev`) and pins update checks to the `dev` channel.

## Documentation Index

- [`docs/architecture.md`](docs/architecture.md)
- [`docs/development-workflow.md`](docs/development-workflow.md)
- [`docs/ci-cd.md`](docs/ci-cd.md)
- [`docs/dev-testing-builds.md`](docs/dev-testing-builds.md)
- [`docs/macos-testing-playbook.md`](docs/macos-testing-playbook.md)
- [`docs/multi-os-build-from-mac.md`](docs/multi-os-build-from-mac.md)
- [`docs/release-secrets.md`](docs/release-secrets.md)
- [`docs/troubleshooting.md`](docs/troubleshooting.md)

## License

[MIT](LICENSE)
