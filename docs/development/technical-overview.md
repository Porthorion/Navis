# Technical overview

Developer-facing detail moved out of the README. For setup and the quality gate see [development-workflow.md](development-workflow.md); for subsystem design see [architecture.md](../architecture.md).

## Platform Support

| Platform | Status | Notes |
|---|---|---|
| Android | Supported | Primary mobile target; `audio_service` media session, Android Auto phone projection, and internally gated WorkManager library-sync recovery |
| iOS | Unreleased | Configured for iOS 16 (iPhone and iPad), SwiftPM plugins only. Plays through just_audio on AVFoundation (loopback stream proxy; plain-http LAN and https servers verified), with the equalizer (a `MTAudioProcessingTap` in the vendored just_audio Darwin code), system Now Playing through `audio_service` (no iOS runtime evidence yet), keychain sign-in, downloads in the Files app and an accessibility pass; verified on the simulator only, device checks (lock screen, AirPods, interruptions, local network prompt, VoiceOver) are pending. TestFlight and App Store are planned for 1.5.2; CarPlay, Siri, widgets, sleep timer and share links are 1.6. Work items are in the [iOS parity plan](../plans/iOS_Parity_Plan.md) and the [iOS testing playbook](../platforms/ios-testing-playbook.md) |
| macOS | Unreleased | Configured for macOS 12 (universal). Bundles Navis's own LGPL libmpv (equalizer, Fast Seeking and system-trust TLS in release builds; debug builds use AVFoundation); Now Playing and media keys through `audio_service` (`MPNowPlayingInfoCenter`, `MPRemoteCommandCenter`), Dock and Controls menus, login-keychain sign-in and a self-update that rolls back; hardware media keys, AirPods and a real update are not yet runtime-verified. Gaps and work items are in the [macOS parity plan](../plans/macOS_Parity_Plan.md) |
| Linux | Supported | Native desktop build with adaptive shell, shortcuts, MPRIS integration, and bundled LGPL libmpv (x86_64); tar.gz, deb, rpm and AUR binary recipe |
| Windows | Supported | Native desktop build with adaptive shell, shortcuts, SMTC integration, and bundled LGPL libmpv |

Released target baselines:
- Android 7.0 (API 24)
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
- Gradual speed and independent pitch controls with reusable local presets (pitch on Android and desktop media-kit; unavailable on iOS/default Apple backend)
- Gapless/background playback and lock-screen controls
- Queue management, portable Subsonic server mix, Last.fm Same Vibes, balanced Instant Radio, and smart queue behaviors
- Synced/unsynced lyrics with full-screen now playing
- Offline cache plus permanent download modes
- Adaptive phone/tablet layouts plus a desktop-only 800×600 workspace whose persistent bottom player keeps Favorite, Lyrics, Queue, Mini Player, and volume directly visible, alongside a centered same-window Mini Player that opens at 720×405, embeds volume beneath its controls, and resizes down to 560×360
- Keyboard-first desktop controls with platform-aware shortcuts, quick search, queue toggle, playback speed shortcuts, and guarded transport actions while typing
- Desktop volume controls that restore the previous per-installation level and mute state on the next launch
- Channel-aware updater behavior for stable/dev release tracks

## Media Integration Status

- Android: media session and notification metadata are handled through
  `audio_service`; Android Auto projects the phone app's Liked, Recent,
  Playlists, and Library destinations plus search, downloads, queue
  resume, and transport controls over a validated media browser connection.
- Linux: desktop now-playing and media-key integration use the app-owned
  MPRIS bridge over `dbus`.
- Windows: system media transport controls use Navis’s owned manual-SMTC
  Rust/WinRT adapter with a stable Navis session identity.
- Apple builds are not shipped or certified. iOS is verified on the simulator through the authenticated diagnostics API; hardware behaviour is listed in the [iOS testing playbook](../platforms/ios-testing-playbook.md). On macOS, `audio_service`'s Darwin plugin publishes `MPNowPlayingInfoCenter` metadata and handles `MPRemoteCommandCenter` commands; a scripted pass confirmed them, and hardware media keys and AirPods remain a hands-on check in the [macOS testing playbook](../platforms/macos-testing-playbook.md) (see item M1 of the [macOS parity plan](../plans/macOS_Parity_Plan.md)).

## Tech Stack

| Layer | Package | Version |
|---|---|---|
| UI framework | Flutter | ≥ 3.47.5 |
| Language | Dart | ^3.13.0 |
| State management | flutter_riverpod | ^3.4.3 |
| Navigation | go_router | ^18.0.1 |
| Local database | drift + drift_flutter | ^2.35.0 / ^0.3.1 |
| Audio playback | just_audio + audio_service | ^0.10.6 / ^0.18.19 |
| Android background work | WorkManager | 2.12.0 |
| Data classes | freezed_annotation + json_annotation | ^3.1.0 / ^4.12.0 |
| Linux desktop media | dbus | ^0.7.15 |
| Windows desktop media | Navis-owned `navis_windows_smtc` | local Rust/WinRT adapter |

## Dependency Maintenance

The [September dependency upgrade plan](../history/completed-plans/Dependency_Upgrade_Plan.md) tracks
the current upgrade work, compatible versions, major migrations, and runtime
validation gates. The build baseline is Flutter 3.47.5 with Dart 3.13.

The October 2026 upgrade moved Navis to the current Flutter hotfix and current
navigation, artwork, storage, database and Windows components; the
[dependency audit](../audits/dependency-audit-2026-10-01.md) records what
was checked and what stays pinned. Remaining `pub outdated` entries are
blocked by SDK/toolchain or upstream constraints rather than local overrides.

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
