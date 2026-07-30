# Navis

Navis is a Flutter Subsonic/OpenSubsonic music client focused on fast library browsing, reliable offline playback, and adaptive UI across phone, tablet, desktop, and in-car workflows.

## Platform Support

| Platform | Status | Notes |
|---|---|---|
| Android | Supported | Primary mobile target; `audio_service` media session plus Android Auto phone projection |
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

- Android: media session and notification metadata are handled through
  `audio_service`; Android Auto projects the phone app's Liked, Recent,
  Playlists, and Library destinations plus search, downloads, genres, queue
  resume, and transport controls over a validated media browser connection.
- Linux: desktop now-playing and media-key integration use the app-owned
  MPRIS bridge over `dbus`.
- Windows: system media transport controls are bridged through `smtc_windows`.
- macOS: desktop runtime is supported, but native `MPRemoteCommandCenter` / `MPNowPlayingInfoCenter` integration is still planned work.

## Tech Stack

| Layer | Package | Version |
|---|---|---|
| UI framework | Flutter | ≥ 3.44.0 |
| Language | Dart | ^3.12.0 |
| State management | flutter_riverpod | ^3.3.1 |
| Navigation | go_router | ^17.1.0 |
| Local database | drift + drift_flutter | ^2.32.1 |
| Audio playback | just_audio + audio_service | ^0.10.5 / ^0.18.18 |
| Data classes | freezed_annotation + json_annotation | ^3.1.0 / ^4.12.0 |
| Linux desktop media | dbus | ^0.7.10 |
| Windows desktop media | smtc_windows | ^1.1.0 |

## Dependency Maintenance

A dependency sweep was completed on July 26, 2026. Direct resolvable updates
were applied, direct imports were declared explicitly, and the unused
`audio_service_mpris` dependency was removed after Linux MPRIS moved to the
app-owned `dbus` bridge. Remaining `pub outdated` entries are blocked by
SDK/toolchain or upstream constraints rather than local overrides.

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

## Retired Features

Listen Together / Voyage is currently retired. Its backend integration, queue
synchronization, settings, and user-visible entry points are disabled while a
future implementation is reconsidered.

## External Scrobbling

Subsonic/OpenSubsonic server scrobbling remains independent from optional
third-party scrobbling. Settings > External Services lets users configure:

- Last.fm API key, shared secret, browser authorization, and session
  connection.
- ListenBrainz user token validation.

Last.fm shared secrets, Last.fm session keys, and ListenBrainz tokens are stored
through platform secure storage. Drift stores only non-secret enabled/status
flags. The scrobble queue stores resolved track metadata so Last.fm and
ListenBrainz events can flush after reconnect even if the library row changes.
Invalid Last.fm sessions or ListenBrainz tokens disable that provider until the
user reconnects or validates a new token.

## Google Play Android Releases

Android updates are Play-only for public/release builds. Forgejo releases remain
the canonical desktop artifact and release-notes record.

```bash
tool/play_release.sh --dry-run
tool/play_release.sh --play-track=internal --play-status=draft
```

`tool/play_release.sh` builds `build/app/outputs/bundle/release/app-release.aab`
and uploads it through the Google Play Developer Publishing API when
`PLAY_SERVICE_ACCOUNT_JSON` is set in local `tool/release.env`. Track aliases
are `internal`, `closed` (`alpha`), `open` (`beta`), and `production`; staged
rollouts use `--play-status=inProgress --play-user-fraction=<fraction>`.

## Documentation Index

- [`AGENTS.md`](AGENTS.md) — canonical guide for AI coding agents
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
