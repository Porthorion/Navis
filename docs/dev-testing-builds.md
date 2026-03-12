# Dev Testing Builds (Side-by-Side)

This guide explains how to create and run "dev" builds without overwriting your stable install.

## Goal

- Keep your stable app installed.
- Install/run a separate dev variant.
- Ensure in-app updater checks the correct release channel.

## Android (Fully Side-by-Side)

Use the helper script:

```bash
./tool/dev_app.sh run -d <device-id>
```

Or build a dev APK:

```bash
./tool/dev_app.sh apk
```

Defaults used by `tool/dev_app.sh`:

- `NAVIS_APP_ID_SUFFIX=.dev`
- `NAVIS_APP_NAME="Navis Dev"`
- `--dart-define=NAVIS_UPDATE_CHANNEL=dev`

Result:

- Stable package remains `com.navis.app.navis`
- Dev package installs as `com.navis.app.navis.dev`

## Desktop (Testing Without Replacing Stable)

For desktop targets, use channel-aware release assets and run from extracted bundles.

Example:

```bash
./tool/release.sh v0.3.0-dev.1 --channel=dev --targets=linux
./tool/release.sh v0.3.0-dev.1 --channel=dev --targets=macos
./tool/release.sh v0.3.0-dev.1 --channel=dev --targets=windows
# macOS orchestration with remote desktop builders
./tool/release.sh v0.3.0-dev.1 --channel=dev --targets=linux,windows --linux-ssh="linux-builder" --windows-ssh="windows-builder"
```

Asset naming:

- Stable: `navis-<tag>-...`
- Dev: `navis-dev-<tag>-...`

Recommendation:

- Keep dev artifacts in a separate folder.
- Prefer running dev from unpacked artifact locations instead of replacing an installed stable app.

## Linux Packaging Modes

For Linux target builds, choose output mode:

```bash
./tool/release.sh v0.3.0 --targets=linux --linux-package=bundle
./tool/release.sh v0.3.0 --targets=linux --linux-package=deb
```

- `bundle` -> `tar.gz` portable bundle
- `deb` -> `.deb` package (requires `dpkg-deb` on the Linux build host/builder)

## Updater Channel Mapping

Updater behavior is controlled by compile-time channel:

- `NAVIS_UPDATE_CHANNEL=stable` (default)
  - checks stable releases
  - prefers assets `navis-<tag>.apk`
- `NAVIS_UPDATE_CHANNEL=dev`
  - allows prereleases
  - prefers assets `navis-dev-<tag>.apk`

## iOS Note

Automated side-by-side iOS app installation (different bundle identifier) is not yet scripted in this repository.

Current recommendation:

- Keep stable installs intact.
- Use Android sidecar + desktop artifacts for rapid dev-channel testing.
- Add an iOS flavor/bundle-id split when iOS side-by-side testing becomes a priority.
