# Releasing Navis for Linux

Navis for Linux is distributed in two formats:

| Format | Filename | Target audience |
|---|---|---|
| Debian package | `navis-v0.x.y-linux-amd64.deb` | Debian, Ubuntu, Mint, Pop!\_OS, Kali, Raspberry Pi OS, etc. |
| Portable bundle | `navis-v0.x.y-linux.tar.gz` | Fedora, Arch, Gentoo, NixOS, openSUSE, Alpine, any distro |

Both formats are supported by the built-in auto-updater. Ideally ship both formats per
release to cover the full Linux user base; see "Publishing Both Formats" for the current
limit.

---

## Why These Two Formats?

The `.deb` package covers the Debian/Ubuntu family — the large majority of Linux desktop
users. The `.tar.gz` portable bundle is a universal fallback that runs on any Linux distro
without requiring root access or a package manager.

### Why not AppImage?

AppImage is self-contained and runs on most distros, but it requires bundling **all** native
shared libraries inside the image — including `libmpv`, `libGL`, and their transitive
dependencies — using tooling such as `appimagetool` or `linuxdeploy`. This adds significant
build infrastructure and maintenance overhead, and the current target audience is well
covered by the two existing formats. AppImage support can be added in a future release.

---

## Platform Constraint

Linux builds require a Linux host. On macOS or Windows, delegate to a remote Linux builder
via SSH. See [release-from-linux.md](release-from-linux.md) for remote builder setup.

---

## Build Host Prerequisites

### 1. System dependencies

Build on **Ubuntu 22.04 LTS or older** to maximize glibc compatibility. A binary compiled
against Ubuntu 22.04's glibc runs on Ubuntu 24.04; the reverse is not guaranteed. Binaries
built on newer distros may fail with `GLIBC_X.XX not found` on users' older systems.

```bash
sudo apt-get update
sudo apt-get install -y \
  clang cmake ninja-build pkg-config \
  libgtk-3-dev \
  dpkg-dev jq curl git
```

`dpkg-dev` is only required for `.deb` packaging; the rest is needed for all Linux builds.

### 2. Flutter SDK

```bash
flutter --version          # Flutter 3.x stable
flutter doctor -v
```

### 3. R2 publishing settings

Create `tool/release.env` (git-ignored) from `tool/release.env.example`:

```bash
R2_ACCOUNT_ID="<cloudflare-account-id>"
R2_BUCKET="downloads"
R2_PREFIX="navis"
R2_ACCESS_KEY_ID="<r2-access-key-id>"
R2_SECRET_ACCESS_KEY="<r2-secret-access-key>"
NAVIS_UPDATE_SIGNING_KEY="$HOME/.config/navis/update-signing-ed25519.pem"
```

Releases are published to R2 with a signed update manifest. Add `FORGEJO_URL`,
`FORGEJO_REPO` and `FORGEJO_TOKEN` only for the 1.5.0 `--forgejo` bridge release. See
[release-r2.md](release-r2.md) and [release-secrets.md](release-secrets.md).

---

## Format 1: Debian Package (`.deb`)

### What it installs

| Path | Content |
|---|---|
| `/opt/navis/` | App binary + native libraries + Flutter assets |
| `/usr/bin/navis` | Launcher wrapper script |
| `/usr/share/applications/navis.desktop` | Desktop entry (application menu) |
| `/usr/share/icons/hicolor/512x512/apps/navis.png` | App icon |

Debian packages default to `Porthorion <support@porthorion.com>` as maintainer
and `https://navis.porthorion.com` as homepage. `NAVIS_DEB_MAINTAINER` remains
available for custom maintainer metadata in local and remote packaging.

### Building

```bash
./tool/release.sh v0.x.y --targets=linux --linux-package=deb
```

Output: `navis-v0.x.y-linux-amd64.deb`

The architecture suffix is detected automatically from the build host (`amd64`, `arm64`,
etc.) via `dpkg --print-architecture`.

### User installation

```bash
# Option A: apt (resolves missing dependencies automatically)
sudo apt install ./navis-v0.x.y-linux-amd64.deb

# Option B: dpkg (does not resolve dependencies)
sudo dpkg -i navis-v0.x.y-linux-amd64.deb
# If missing dependencies: sudo apt-get install -f
```

After installation, `navis` is available as a system command and appears in the
application menu.

### Bundled LGPL libmpv

Linux x86_64 packages ship LGPL-2.1+ libmpv/FFmpeg as `lib/libmpv.so.2`.
Startup selects that file relative to `Platform.resolvedExecutable`; if absent,
development runs use system libmpv. `NAVIS_BUNDLE_LIBMPV` defaults ON in
`linux/CMakeLists.txt`; developers can set `-DNAVIS_BUNDLE_LIBMPV=OFF` in their
CMake configuration/cache to use system mpv. Other architectures must opt out
until a matching LGPL artefact is published; never package the x86_64 binary
for them. Custom packages without the bundle need their own system-mpv dependency.

The current archive is `libmpv-linux-x86_64-lgpl-20261007.tar.gz`, SHA-256
`759bb6586b4d772bb78a565609dcccc5205741c8b1163c1d47ed3493bf227f6e`.
CMake tries the matching navis-third-party release, then
`https://downloads.porthorion.com/third-party/libmpv-linux-x86_64-lgpl-20261007.tar.gz`.
Every attempt is verified, failures are deleted, and the archive is cached in
the CMake build directory. A verified cached archive supports offline builds;
extraction is once per pin, retried if incomplete. The library is installed
into the standard bundle `lib/` directory alongside Flutter's libraries.

To update, use [the build recipe](../tool/libmpv/README.md), check the embedded
mpv `-Dgpl=false` and absence of FFmpeg `--enable-gpl`/`--enable-nonfree`,
and review `BUILDINFO.txt`'s ELF dependencies. Package the library, headers and
recipe under `libmpv-linux-x86_64-lgpl/`, then publish the dated tarball in
navis-third-party with `SOURCES.md` and the corresponding source archives.
Copy the identical tarball to the R2 fallback path. Update the filename,
ordered URLs and SHA-256 in CMake and the in-app source-location notice.

The Debian package no longer depends on system `libmpv2 | libmpv1`. Its minimal
runtime dependencies are `libgtk-3-0, libpulse0, libasound2`: the recipe enables
both PulseAudio and ALSA, so both shared libraries must load even when only one
output is used. An alternative (`libpulse0 | libasound2`) would be insufficient.
GnuTLS is already supplied by GTK's dependency on CUPS on the Ubuntu 22.04
baseline ([GTK dependencies](https://packages.ubuntu.com/jammy/libgtk-3-0),
[CUPS dependencies](https://packages.ubuntu.com/jammy/libcups2)), so no redundant
`libgnutls30` dependency is added. GTK also supplies the font libraries; inspect
ELF dependencies again for every new pin. Portable bundles still require these
system desktop libraries.

### Auto-updater behavior

The auto-updater detects `.deb` mode when the running executable path starts with
`/opt/navis` — which is always the case for a `dpkg`-installed app.

The manifest key is `linuxDeb-<arch>` (`linuxDeb-amd64` or `linuxDeb-arm64`). An install
only ever uses the key for its own architecture; if the manifest has none, no update is
offered (there is no cross-architecture fallback).

Update flow:
1. Downloads `navis-vX.Y.Z-linux-amd64.deb` (or `-arm64`).
2. Checks its size and SHA-256 against the signed manifest; a mismatch deletes the file
   and shows "The update download was damaged".
3. Runs `pkexec dpkg -i <path>` — the user sees a polkit authentication dialog.
4. After `dpkg` exits cleanly, the app relaunches from `Platform.resolvedExecutable`.

If `pkexec` is missing, or `pkexec`/`dpkg` exits non-zero (including a cancelled
authentication dialog), the update dialog shows "Could not apply the update
automatically." with a "Download Manually" button and no Retry.

---

## Format 2: Portable Bundle (`.tar.gz`)

### What it contains

The `.tar.gz` contains the complete self-contained app bundle: the `navis` binary, all
required shared libraries (`.so` files), and the full Flutter assets tree. Users extract it
anywhere and run `./navis` directly. No root access or installation required.

### Building

```bash
./tool/release.sh v0.x.y --targets=linux --linux-package=bundle
```

Output: `navis-v0.x.y-linux.tar.gz`

### User installation

```bash
mkdir -p ~/apps/navis
tar -xzf navis-v0.x.y-linux.tar.gz -C ~/apps/navis
~/apps/navis/navis
```

To create a desktop shortcut, copy the included `.desktop` file template and adjust the
`Exec=` path to point to the extracted binary.

### Auto-updater behavior

The auto-updater uses portable mode when the executable is **not** under `/opt/navis`.

Update flow:
1. Downloads `navis-vX.Y.Z-linux.tar.gz` (manifest key `linuxPortable`) and checks its
   size and SHA-256 against the signed manifest.
2. Extracts to a temp staging directory using `tar -xzf`.
3. Writes a bash updater script to temp and launches it detached, then exits.

The updater script:
- Waits 2 seconds for the app to exit.
- Backs up the current app directory as `.backup`.
- Moves the new directory into place.
- Relaunches from the new binary (`navis &`).
- Removes the backup and self-deletes.
- If the move fails, **automatically restores the backup** so the app remains usable.

---

## Publishing Both Formats

`release.sh` builds one Linux package per run (`--linux-package=bundle|deb`) and
publishes it to R2 in that run. To ship the other format for the same version, run
`release.sh` again with `--allow-existing-version` and the other `--linux-package`, or
pass the file to `tool/r2_publish.sh publish --tag=<tag> --channel=<channel> <file>`.
When the channel already points at that tag, the publish adds the new asset to the
signed manifest and rewrites `SHA256SUMS`; existing assets are kept. Each install
type reads only its own key (`linuxDeb-<arch>` or `linuxPortable`), and an install
whose key is missing sees no update.

---

## Building from a Non-Linux Host

If your primary machine is macOS or Windows, set up a remote Linux SSH builder:

```bash
# Add to tool/release.env:
# NAVIS_LINUX_SSH="user@linux-builder-ip"
# NAVIS_LINUX_REMOTE_DIR=".navis/remote-linux-build"

./tool/release.sh v0.x.y --targets=linux --linux-package=deb \
  --linux-ssh="user@192.168.x.x"
```

See [release-from-linux.md](release-from-linux.md) for full remote builder setup.

---

## Dev Channel

```bash
./tool/release.sh v0.x.y --channel=dev --targets=linux --linux-package=deb
```

Assets: `navis-dev-v0.x.y-linux-amd64.deb` / `navis-dev-v0.x.y-linux.tar.gz`

---

## Troubleshooting

### `clang++: command not found`

```bash
sudo apt-get install -y clang
export CXX=clang++ CC=clang
```

### `flutter build linux` fails in headless / Docker environments

Flutter Linux builds require a GTK display environment. For headless CI:

```bash
# Set up Xvfb:
sudo apt-get install -y xvfb
Xvfb :99 -screen 0 1024x768x24 &
export DISPLAY=:99
flutter build linux --release
```

### `dpkg: error: requested operation requires superuser privilege`

Building the `.deb` package does not need root — only `dpkg -i` during user installation
does. Use `sudo dpkg -i` or `sudo apt install ./file.deb`.

### Users report audio not working after installing the `.deb`

Current packages include `lib/libmpv.so.2`; keep the complete bundle intact.
Inspect missing system dependencies with `ldd /opt/navis/lib/libmpv.so.2` and
install the package with `apt`. Older releases and opt-out development builds
still need system mpv (`libmpv2` on Debian 12/Ubuntu 23.04+, `libmpv1` on 22.04).

### Auto-updater: `pkexec` not found

`pkexec` is part of the `polkit` package:

```bash
sudo apt-get install -y policykit-1
```

If `pkexec` is unavailable, `Process.run('pkexec', ...)` throws at the apply stage and
the update dialog shows "Could not apply the update automatically." with a "Download
Manually" button that opens the release notes link (or the download page on the Navis
website). There is no separate prompt before the download, and no Retry button.

### `dpkg-deb: error: failed to open package info file`

This usually means `dpkg-dev` is not installed on the build host:

```bash
sudo apt-get install -y dpkg-dev
```
