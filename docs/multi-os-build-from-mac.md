# Multi-OS Builds from macOS

This guide covers release builds where macOS drives Linux and Windows desktop
artifacts through SSH-accessible builders, usually local VMs on the same Mac.
The macOS host still owns the release script, R2 upload and manifest signing, signing secrets,
and final asset naming.

## When to use this flow

Use this when running:

```bash
./tool/release.sh v1.0.5 \
  --targets=linux,windows \
  --linux-ssh="linux-builder" \
  --windows-ssh="windows-builder"
```

The release script packages the local source tree, sends it to each remote
builder, runs the platform build there, copies the completed artifacts back to
the repository root, and publishes them to R2 with the signed manifest.

## macOS host requirements

- Flutter and Dart versions matching `pubspec.yaml`.
- `git`, `curl`, `jq`, `ssh`, and `scp` on `PATH`.
- `tool/release.env` with the R2 settings, `NAVIS_UPDATE_SIGNING_KEY` (see
  [release-r2.md](release-r2.md)) and any bundled release defines:
  - `R2_ACCOUNT_ID`, `R2_BUCKET`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`
  - `FORGEJO_URL`, `FORGEJO_REPO`, `FORGEJO_TOKEN` (only with `--forgejo`)
  - optional `NAVIS_LASTFM_API_KEY` (bundled masked; see
    [ci-cd.md](ci-cd.md#lastfm-key))
- SSH key access to each builder without interactive prompts.

Do not store secrets on the remote builders unless the platform build itself
requires them. The host passes the release channel to the remote scripts as
arguments. The masked Last.fm key defines travel as a private file (ssh stdin to
the Linux builder, scp to the Windows builder), not on the scripts' own command lines, and the
builder deletes the file when the build ends; `tool/release.env` is excluded
from the source archive.

## Linux builder requirements

- A Linux environment supported by Flutter desktop builds.
- Flutter on `PATH`.
- `tar`, `git`, and standard build tooling for Linux desktop apps.
- Packaging tools for the selected mode:
  - `--linux-package=bundle`: standard Flutter Linux build dependencies.
  - `--linux-package=deb`: Debian packaging tools required by the release
    script.

Remote output names follow the release asset contract:

- `navis-vX.Y.Z-linux.tar.gz`
- `navis-vX.Y.Z-linux-<arch>.deb`

For dev-channel releases the prefix becomes `navis-dev`.

## Windows builder requirements

- A Windows host reachable over SSH.
- Flutter on `PATH`.
- PowerShell available to the SSH session.
- Visual Studio desktop build prerequisites for Flutter Windows.
- Inno Setup 6 on `PATH` when using `--windows-package=exe`.

Remote output names follow the release asset contract:

- `navis-vX.Y.Z-windows.zip`
- `navis-vX.Y.Z-windows-installer.exe`

For dev-channel releases the prefix becomes `navis-dev`.

## Configuration

Set builder targets in `tool/release.env` to avoid repeating command flags:

```bash
NAVIS_LINUX_SSH=linux-builder
NAVIS_WINDOWS_SSH=windows-builder
NAVIS_LINUX_REMOTE_DIR=.navis/remote-linux-build
NAVIS_WINDOWS_REMOTE_DIR=.navis/remote-windows-build
```

Command-line flags override these values:

```bash
./tool/release.sh v1.0.5 \
  --targets=linux,windows \
  --linux-ssh="linux-builder" \
  --windows-ssh="windows-builder" \
  --linux-package=deb \
  --windows-package=exe
```

## Verification

Before relying on remote builders for a release:

1. Run `./tool/check.sh` on the macOS host.
2. Confirm SSH access:
   ```bash
   ssh linux-builder "flutter --version"
   ssh windows-builder "flutter --version"
   ```
3. Run a remote-only release build with an unpublished dev tag or with upload
   disabled in a disposable test branch.
4. Confirm copied artifacts exist at the repository root and match the expected
   asset names.
5. Confirm the published R2 assets and manifest match the active channel
   (`./tool/r2_publish.sh verify --channel=<channel>`):
   stable uses `navis-*`; dev uses `navis-dev-*`.

## Troubleshooting

- If the release script cannot find `ssh` or `scp`, install the macOS command
  line tools or provide those binaries on `PATH`.
- If a builder cannot run Flutter non-interactively, log in over SSH and accept
  any first-run prompts before starting the release.
- If Windows package cache transfer fails, clear the remote work directory and
  rerun the release command.
- If a builder produces artifacts but the host cannot copy them back, check the
  configured remote directory and SSH user's file permissions.
