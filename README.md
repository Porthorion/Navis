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
- Listen Together group sessions backed by Voyage: collaborative default-room playback and queue control, host-only room admin actions, reconnect-aware sync, placeholder room-mode settings, compact session button in the player bar with live state icon, Settings nav badge, and join/leave toasts
- Keyboard-first desktop controls with platform-aware shortcuts, quick search, queue toggle, and guarded transport actions while typing
- Desktop volume controls in the bottom player and desktop-wide now playing surfaces
- Channel-aware updater behavior for stable/dev release tracks

## Media Integration Status

- Android: media session and notification metadata are handled through `audio_service`.
- Linux: desktop now-playing and media-key integration are exposed through MPRIS via `audio_service_mpris`.
- Windows: system media transport controls are bridged through `smtc_windows`.
- macOS: desktop runtime is supported, but native `MPRemoteCommandCenter` / `MPNowPlayingInfoCenter` integration is still planned work.

## Tech Stack

| Layer | Package | Version |
|---|---|---|
| UI framework | Flutter | ≥ 3.41.0 |
| Language | Dart | ^3.11.0 |
| State management | flutter_riverpod | ^3.3.1 |
| Navigation | go_router | ^17.1.0 |
| Local database | drift + drift_flutter | ^2.32.1 |
| Audio playback | just_audio + audio_service | ^0.10.5 / ^0.18.18 |
| Data classes | freezed_annotation + json_annotation | ^3.1.0 / ^4.11.0 |
| Linux desktop media | audio_service_mpris | ^0.2.1 |
| Windows desktop media | smtc_windows | latest |

## Dependency Maintenance

A comprehensive dependency sweep was completed in March 2026 (13 packages upgraded across 5 phases; `riverpod_lint` removed as its runner was already disabled). The current `flutter pub outdated` backlog contains packages that are hard-blocked by transitive constraints from other indirect dependencies and cannot be upgraded without corresponding upstream changes.

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

## Listen Together / Voyage

Navis can bundle one or more Voyage backends at build time for the Listen
Together feature.

Set `NAVIS_VOYAGE_SERVERS` as a `--dart-define` value, or place it in
`tool/release.env` when using the repo scripts:

```bash
NAVIS_VOYAGE_SERVERS="Primary Voyage|https://voyage.example.com,Backup Voyage|https://voyage-backup.example.com"
```

Format rules:

- separate entries with commas or newlines
- use `Label|URL` when you want a friendly server name in the UI
- use a plain URL when the host name is enough as the label

When one bundled server is present, Settings exposes a simple enable/health
check flow. When multiple are present, Settings lets the user pick a server
before enabling Listen Together. Users can also add and delete custom Voyage
servers from Settings; bundled servers remain selectable but cannot be edited.
Custom server URLs are normalized and validated before they are stored.

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

### Listen Together UI

- A compact **session button** appears in the player bar on every surface
  (desktop bar, rail mini-player, landscape strip, portrait strip). The icon
  reflects the current state: idle (outlined people icon), hosting
  (`headset_mic`), listening as a member (filled people icon), or needs
  attention (`sync_problem_outlined` in error colour). Tapping always opens
  the Listen Together bottom sheet.
- A **Settings nav badge** appears when you are in an active room, so you can
  always navigate back to the session panel even when the player is not
  visible.
- **Join/leave toasts** confirm room transitions without covering up the UI.
- Active rooms expose a **Room settings** section with disabled placeholders for
  Shotgun Mode, Host-Only, and Protected while the default collaborative mode
  remains active.

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
