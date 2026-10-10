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

`apk` and `dhu` allow debug signing of local dev release-mode APKs when
`android/key.properties` is absent, using `NAVIS_ALLOW_DEBUG_SIGNED_RELEASE=1`.
Set that variable to `0` to require real keys. Published Android releases via
`tool/release.sh` always require the properties file and signer verification.

Defaults used by `tool/dev_app.sh`:

- `NAVIS_APP_ID_SUFFIX=.dev`
- `NAVIS_APP_NAME="Navis Dev"`
- `--dart-define=NAVIS_UPDATE_CHANNEL=dev`

Result:

- Stable package remains `com.navis.app.navis`
- Dev package installs as `com.navis.app.navis.dev`

## Desktop (Testing Without Replacing Stable)

For an interactive Linux setup or sync edge case, launch an isolated copy of
the existing local Navis profile:

```bash
./tool/dev_app.sh run -d linux --first-setup
./tool/dev_app.sh run -d linux --bad-cache
./tool/dev_app.sh run -d linux --force-setup
./tool/dev_app.sh run -d linux --manual-cache-reset
./tool/dev_app.sh run -d linux --playback-recovery
./tool/dev_app.sh run -d linux --partial-album
./tool/dev_app.sh run -d linux --server-error
./tool/dev_app.sh run -d linux --fresh-login
```

`--first-setup` clears server-derived library and sync progress in the copy,
keeps the saved account, and reopens the full-screen first build followed by
onboarding. `--bad-cache` removes the cache-layout version marker so the
production mandatory cache-upgrade route performs its reset and rebuild.
`--force-setup` reopens the first-time customization page on an already usable
catalog. The two cache-reset commands and playback recovery enter their corresponding full-screen
rebuild routes. `--partial-album` and `--server-error` use a local Subsonic
fixture for reproducible incomplete album detail and initial catalog failure;
both begin at first setup. `--fresh-login` starts with an empty local profile
and opens Login.

Append `--offline` or `--metered` to a preset to begin on the matching network
gate. The launcher prints its isolated run directory. From another terminal,
restore or change the simulated network, or repair the fixture response:

```bash
./tool/dev_app.sh scenario build/dev-sync-scenarios/<run-directory> online
./tool/dev_app.sh scenario build/dev-sync-scenarios/<run-directory> offline
./tool/dev_app.sh scenario build/dev-sync-scenarios/<run-directory> metered
./tool/dev_app.sh scenario build/dev-sync-scenarios/<run-directory> server-fix
./tool/dev_app.sh scenario build/dev-sync-scenarios/<run-directory> server-break
```

Presets run a **profile-mode** Linux app because they use the clone-only
authenticated diagnostics controls; ordinary `dev_app.sh run` retains its
debug/hot-reload behavior. They snapshot the default local database at
`~/.local/share/com.navis.app.navis/navis.sqlite.sqlite` into
`build/dev-sync-scenarios/`, falling back to the old Documents database only
when the new file is absent and the old file exists. They never reset that
source, and remove copied download/cache references and outbound queues.
The app keeps its app-support, cache and temporary files in the run directory
(`support/` and `cache/`), so window geometry, update-check state, image caches
and the What's New marker never touch `~/.local/share/com.navis.app.navis/`;
copied credentials stay in memory. Presets other than `--fresh-login` mark the
running version's What's New as seen. An already authenticated local profile is required except for
`--fresh-login`, and the onboarding/repair/cache presets require a usable
catalog. Use `--scenario-source /absolute/path/to/navis.sqlite.sqlite` to
choose another source, or set `NAVIS_DIAGNOSTICS_PRIMARY_DB`; the explicit
flag takes precedence. Each invocation creates a new copy; its directory can be
deleted after the app exits.

The presets use the production 600-second sync lease duration. This keeps a
large first catalog fenced through its atomic promotion; the diagnostics default
of six seconds remains reserved for interruption-owner tests.

For desktop targets, use channel-aware release assets and run from extracted bundles.

Example:

```bash
./tool/release.sh v0.3.1 --channel=dev --targets=linux
./tool/release.sh v0.3.2 --channel=dev --targets=macos
./tool/release.sh v0.3.3 --channel=dev --targets=windows
# macOS orchestration with remote desktop builders
./tool/release.sh v0.3.4 --channel=dev --targets=linux,windows --linux-ssh="linux-builder" --windows-ssh="windows-builder"
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
  - reads `https://downloads.porthorion.com/navis/channels/stable/manifest.json`
- `NAVIS_UPDATE_CHANNEL=dev`
  - reads `https://downloads.porthorion.com/navis/channels/dev/manifest.json`
- `NAVIS_UPDATE_CHANNEL=staging`
  - reads `.../channels/staging/manifest.json`; no shipped build uses it, so it is
    the channel for testing the updater end to end (see [release-r2.md](release-r2.md))

Each manifest is signed and names its channel; a build rejects a manifest for another
channel. Assets are picked by manifest key (`androidApk`, `windowsInstaller`,
`windowsPortable`, `macosBundle`, `linuxDeb-<arch>`, `linuxPortable`), not by file name.
Stable release tags stay plain `vX.Y.Z`; dev/staging additionally accept
`vX.Y.Z-<channel>.<build>`. Equal-version dev/staging offers compare the signed
manifest build with the installed build number. See [release-r2.md](release-r2.md)
for `./tool/dev_release.sh`, the monotonic dev APK counter, dry-run and cleanup.
A channel never moves to an older version/build.

## iOS Note

Automated side-by-side iOS app installation (different bundle identifier) is not yet scripted in this repository.

Current recommendation:

- Keep stable installs intact.
- Use Android sidecar + desktop artifacts for rapid dev-channel testing.
- Add an iOS flavor/bundle-id split when iOS side-by-side testing becomes a priority.
