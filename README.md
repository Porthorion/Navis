# Navis

A Subsonic / OpenSubsonic music player for Android and iOS, built with Flutter.

## Features

- **Library** — browse artists, albums, and tracks synced from your server
- **Playback** — gapless audio, background playback, lock-screen controls, scrobbling
- **Now Playing** — expandable player sheet with synced and unsynced lyrics
- **Search** — real-time search against your Subsonic server
- **Radio** — internet radio stations from your server
- **Playlists** — create, edit, and reorder playlists synced to the server
- **Offline / Cache** — rolling LRU cache + permanent downloads for offline playback
- **Instant Mix** — auto-queue similar tracks when the queue runs low
- **Settings** — adaptive streaming quality (Wi-Fi vs. cellular), theme (Dynamic / presets / custom, OLED mode), equalizer, cache controls, update notifications
- **Accessibility** — full screen-reader support, semantic labels throughout

## Screenshots

<!-- TODO: add screenshots once UI is stable -->

## Requirements

| Platform | Minimum |
|----------|---------|
| Android  | 8.0 (API 26) |
| iOS      | 14.0 |

Requires a Subsonic-compatible server (Navidrome, Airsonic, etc.) implementing at least API level 1.16.1.

## Tech Stack

| Layer | Library |
|-------|---------|
| State / DI | Riverpod 3 (codegen) |
| Navigation | go_router |
| Database | drift (SQLite) |
| Audio | just_audio + audio_service |
| Network | Dio |
| UI | Material 3 / flex_color_scheme |

## Build & Run

```bash
# First-time setup
./tool/bootstrap.sh

# Run on a connected device
flutter run

# Quality gate (format · generate · analyze · test)
./tool/check.sh
```

## Release

```bash
./tool/release.sh v1.0.0
./tool/release.sh v1.0.0 --channel=dev
./tool/release.sh v1.0.0 --targets=android,macos
```

See [docs/ci-cd.md](docs/ci-cd.md) for Forgejo release setup.

## Dev Sidecar App

```bash
./tool/dev_app.sh run -d <device-id>
./tool/dev_app.sh apk
```

This builds/runs a side-by-side dev app (`.dev` suffix, `Navis Dev`) and pins updater checks to the `dev` channel.

## Documentation

| Doc | Contents |
|-----|----------|
| [docs/architecture.md](docs/architecture.md) | Data flow, provider graph |
| [docs/development-workflow.md](docs/development-workflow.md) | Code generation, conventions |
| [docs/ci-cd.md](docs/ci-cd.md) | Release pipeline, quality gates |
| [docs/dev-testing-builds.md](docs/dev-testing-builds.md) | Side-by-side dev builds and update channel mapping |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Common issues |

## Roadmap

See [DEVELOPMENT_PLAN.md](DEVELOPMENT_PLAN.md) and [PROGRESS.md](PROGRESS.md).

## Local Guardrails

Enable the pre-commit hook (runs `./tool/check.sh` before each commit):

```bash
git config core.hooksPath .githooks
chmod +x .githooks/pre-commit
```

## License

[MIT](LICENSE)
