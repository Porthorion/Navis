# Navis

Navis is a Flutter Subsonic/OpenSubsonic music client focused on fast library browsing, reliable offline playback, and adaptive UI across phone, tablet, desktop, and in-car workflows.

## Platform Support

| Platform | Status | Notes |
|---|---|---|
| Android | Supported | Primary mobile target; `audio_service` media session, Android Auto phone projection, and internally gated WorkManager library-sync recovery |
| iOS | Unreleased scaffold | Configured for iOS 16; requires macOS/Xcode build and runtime validation |
| macOS | Unreleased scaffold | Configured for macOS 12; build/runtime validation and native media controls remain pending |
| Linux | Supported | Native desktop build with adaptive shell, shortcuts, and MPRIS integration |
| Windows | Supported | Native desktop build with adaptive shell, shortcuts, and SMTC integration |

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

## Equalizer

Android, Linux and Windows support dedicated EQ editing, exact presets, AutoEQ import and
offline headphone search. See [the equalizer guide](docs/equalizer.md) for
platform and validation limits.

## Media Integration Status

- Android: media session and notification metadata are handled through
  `audio_service`; Android Auto projects the phone app's Liked, Recent,
  Playlists, and Library destinations plus search, downloads, queue
  resume, and transport controls over a validated media browser connection.
- Linux: desktop now-playing and media-key integration use the app-owned
  MPRIS bridge over `dbus`.
- Windows: system media transport controls use Navis’s owned manual-SMTC
  Rust/WinRT adapter with a stable Navis session identity.
- Apple scaffolds are not shipped or certified. Native macOS `MPRemoteCommandCenter` / `MPNowPlayingInfoCenter` integration remains planned work.

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

The [September dependency upgrade plan](Dependency_Upgrade_Plan.md) tracks
the current upgrade work, compatible versions, major migrations, and runtime
validation gates. The build baseline is Flutter 3.47.5 with Dart 3.13.

The October 2026 upgrade moved Navis to the current Flutter hotfix and current
navigation, artwork, storage, database and Windows components; the
[dependency audit](docs/audits/dependency-audit-2026-10-01.md) records what
was checked and what stays pinned. Remaining `pub outdated` entries are
blocked by SDK/toolchain or upstream constraints rather than local overrides.

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

## Integrations and Scrobbling

Besides your own server, Navis can use a few online services. Settings ›
Integrations lists each one with what it sends and to which host, a switch per
service and per feature, and a master "Online services" switch; with it off,
Navis only talks to your server. Everything is on by default.

- **Deezer** — artist top songs (Last.fm as fallback; with neither, "This
  Is <Artist>" becomes a shuffle of the artist's library songs), artist
  photos and fan counts, "Fans also like", missing albums (hidden when your
  server has its own remote catalogue for the artist), new releases and
  trending songs.
- **Last.fm** — Same Vibes mixes (the Instant Mix mode: on is Same Vibes, off
  is your server's mix), the Instant Radio fill and a top-songs fallback. No
  Last.fm scrobbling. Release builds bundle an API key, masked at build time to
  deter casual extraction (a Last.fm API key is a client identifier, not a
  secret, and Navis uses no shared secret); builds without one show a field for
  your own key.
- **ListenBrainz** — scrobbling, likes (sent as loved) and weekly playlists,
  after its User Token validates.
- **LRCLIB** synced lyrics (server lyrics as fallback), **update checks**,
  **AutoEQ** headphone profiles, **internet radio** now-playing info and
  **artwork** your server links from other sites.

A feature whose service needs a credential stays locked until the key or token
is verified. Subsonic/OpenSubsonic server scrobbling stays independent of
these switches. The ListenBrainz token is stored through platform secure
storage; Drift stores only non-secret status flags. The scrobble queue stores
resolved track metadata so ListenBrainz events can flush after reconnect even
if the library row changes. A rejected ListenBrainz token disables it until the
user validates a new one.

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

Navis bundles the [Inter](https://github.com/rsms/inter) typeface under the
SIL Open Font License 1.1 ([assets/fonts/OFL.txt](assets/fonts/OFL.txt)).
