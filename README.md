# Navis

Navis is a Flutter Subsonic/OpenSubsonic music client focused on fast library browsing, reliable offline playback, and adaptive UI across phone, tablet, desktop, and in-car workflows.

## Platform Support

| Platform | Status | Notes |
|---|---|---|
| Android | Supported | Primary mobile target; `audio_service` media session, Android Auto phone projection, and internally gated WorkManager library-sync recovery |
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

- Adaptive, resume-safe library sync with hard low-data probes on metered
  networks, interactive targeted hydration budgets, unmetered-background
  defaults, one-time mobile-data overrides, compatibility fallbacks, guarded
  repair, and atomic catalog promotion, plus server reconciliation for liked
  items, playlist headers, and changed playlist contents. Full repairs compare
  hidden catalog pages first and apply only actual changes, keeping memory and
  the final visibility switch bounded.
- Android uses constrained WorkManager scheduling for eventual automatic
  library checks after normal process death. It respects the sync network
  preference and never promises an exact run time; this capability is enabled
  gradually for internal testing.
- Gapless/background playback and lock-screen controls
- Queue management, portable Subsonic server mix, Last.fm Same Vibes, balanced Instant Radio, and smart queue behaviors
- Synced/unsynced lyrics with full-screen now playing
- Offline cache plus permanent download modes
- Adaptive phone/tablet layouts plus a desktop-only 800×600 workspace whose persistent bottom player keeps Favorite, Lyrics, Queue, Mini Player, and volume directly visible, alongside a centered same-window Mini Player that opens at 720×405, embeds volume beneath its controls, and resizes down to 560×360
- Keyboard-first desktop controls with platform-aware shortcuts, quick search, queue toggle, and guarded transport actions while typing
- Desktop volume controls that restore the previous per-installation level and mute state on the next launch
- Channel-aware updater behavior for stable/dev release tracks

## Media Integration Status

- Android: media session and notification metadata are handled through
  `audio_service`; Android Auto projects the phone app's Liked, Recent,
  Playlists, and Library destinations plus search, downloads, genres, queue
  resume, and transport controls over a validated media browser connection.
- Linux: desktop now-playing and media-key integration use the app-owned
  MPRIS bridge over `dbus`.
- Windows: system media transport controls use Navis’s owned manual-SMTC
  Rust/WinRT adapter with a stable Navis session identity.
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
| Android background work | WorkManager | 2.11.2 |
| Data classes | freezed_annotation + json_annotation | ^3.1.0 / ^4.12.0 |
| Linux desktop media | dbus | ^0.7.10 |
| Windows desktop media | Navis-owned `navis_windows_smtc` | local Rust/WinRT adapter |

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

Start with [`docs/README.md`](docs/README.md) for a task-oriented map of
current reference documents, plans/evidence, and historical records. Agentic
contributors should read [`AGENTS.md`](AGENTS.md) and the canonical
[`docs/agentic-engineering.md`](docs/agentic-engineering.md) before editing.

## License

[GPL-3.0](LICENSE)
