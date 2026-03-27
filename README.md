# Navis

Navis is a Flutter Subsonic/OpenSubsonic music client focused on fast library browsing, reliable offline playback, and adaptive UI across phone, tablet, desktop, and in-car workflows.

## Platform Support

| Platform | Status | Notes |
|---|---|---|
| Android | Supported | Primary mobile target; `audio_service` media session/notification path active |
| iOS | Supported | Built from macOS/Xcode; playback path active, CarPlay and media-session parity still under audit |
| macOS | Supported | Native desktop build with adaptive shell and shortcuts; native Control Centre bridge still pending |
| Linux | Supported | Native desktop build with adaptive shell, shortcuts, and MPRIS integration |
| Windows | Supported | Native desktop build with adaptive shell, shortcuts, and SMTC integration |

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
- Keyboard-first desktop controls with platform-aware shortcuts, quick search, queue toggle, and guarded transport actions while typing
- Desktop volume controls in the bottom player and desktop-wide now playing surfaces
- Channel-aware updater behavior for stable/dev release tracks

## Media Integration Status

- Android: media session and notification metadata are handled through `audio_service`.
- Linux: desktop now-playing and media-key integration are exposed through MPRIS via `audio_service_mpris`.
- Windows: system media transport controls are bridged through `smtc_windows`.
- macOS: desktop runtime is supported, but native `MPRemoteCommandCenter` / `MPNowPlayingInfoCenter` integration is still planned work.

## Dependency Maintenance

Dependency hygiene is tracked as part of release prep. The current `flutter pub outdated` backlog includes direct upgrades for `drift`, `drift_flutter`, `drift_dev`, and `json_serializable`, with additional transitive follow-up in the analyzer/sqlite/win32 chain.

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
