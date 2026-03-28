# Releasing Navis for Linux

Navis for Linux is distributed in two formats:

| Format | Filename | Target audience |
|---|---|---|
| Debian package | `navis-v0.x.y-linux-amd64.deb` | Debian, Ubuntu, Mint, Pop!\_OS, Kali, Raspberry Pi OS, etc. |
| Portable bundle | `navis-v0.x.y-linux.tar.gz` | Fedora, Arch, Gentoo, NixOS, openSUSE, Alpine, any distro |

Both formats are supported by the built-in auto-updater. **Ship both formats per release**
to cover the full Linux user base.

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
  libgtk-3-dev libmpv-dev \
  dpkg-dev jq curl git
```

`dpkg-dev` is only required for `.deb` packaging; the rest is needed for all Linux builds.

### 2. Flutter SDK

```bash
flutter --version          # Flutter 3.x stable
flutter doctor -v
```

### 3. Forgejo token

Create `tool/release.env` (git-ignored):

```bash
FORGEJO_URL="https://git.porthorion.com"
FORGEJO_REPO="khalifa/Navis"
FORGEJO_TOKEN="<personal-access-token-with-write:release>"
```

---

## Format 1: Debian Package (`.deb`)

### What it installs

| Path | Content |
|---|---|
| `/opt/navis/` | App binary + native libraries + Flutter assets |
| `/usr/bin/navis` | Launcher wrapper script |
| `/usr/share/applications/navis.desktop` | Desktop entry (application menu) |
| `/usr/share/icons/hicolor/512x512/apps/navis.png` | App icon |

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

### Known limitation: missing `libmpv` dependency

The current Debian control file declares `Depends: libgtk-3-0` but does not list `libmpv`.
On clean Ubuntu installs, audio will not work until the user installs it separately:

```bash
sudo apt install libmpv2
```

This will be corrected in a future release by updating the `Depends` line in
`tool/release.sh` to `Depends: libgtk-3-0, libmpv2 | libmpv1`.

### Auto-updater behavior

The auto-updater detects `.deb` mode when the running executable path starts with
`/opt/navis` — which is always the case for a `dpkg`-installed app.

Update flow:
1. Downloads `navis-vX.Y.Z-linux-amd64.deb`.
2. Runs `pkexec dpkg -i <path>` — the user sees a polkit authentication dialog.
3. After `dpkg` exits cleanly, the app relaunches from `Platform.resolvedExecutable`.

If `pkexec` is unavailable on the user's system, the auto-updater surfaces a
"Download Manually" prompt instead of failing silently.

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
1. Downloads `navis-vX.Y.Z-linux.tar.gz`.
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

## Publishing Both Formats in One Release

The release script creates the Forgejo release on its first run. Running it a second time
for the same tag will error because the release already exists. Use this two-step approach:

### Step 1 — Full release with the `.deb`

```bash
./tool/release.sh v0.x.y --targets=linux --linux-package=deb
```

This creates the Forgejo release, uploads the `.deb`, bumps pubspec, tags, and pushes.

### Step 2 — Build `.tar.gz` and upload separately

```bash
# Build the portable bundle (no publish)
flutter build linux --release --dart-define=NAVIS_UPDATE_CHANNEL=stable

BUNDLE_DIR=$(find build/linux -type d -path "*/release/bundle" | head -1)
tar -czf navis-v0.x.y-linux.tar.gz -C "${BUNDLE_DIR}" .

# Upload to the existing release via Forgejo API
source tool/release.env
RELEASE_ID=$(curl -sf \
  "${FORGEJO_URL}/api/v1/repos/${FORGEJO_REPO}/releases/tags/v0.x.y" \
  -H "Authorization: token ${FORGEJO_TOKEN}" | jq -r '.id')

curl -sf -X POST \
  "${FORGEJO_URL}/api/v1/repos/${FORGEJO_REPO}/releases/${RELEASE_ID}/assets?name=navis-v0.x.y-linux.tar.gz" \
  -H "Authorization: token ${FORGEJO_TOKEN}" \
  -F "attachment=@navis-v0.x.y-linux.tar.gz"

rm navis-v0.x.y-linux.tar.gz
```

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

The `libmpv` runtime is not yet listed in the package `Depends`. The user needs to install
it manually:

```bash
sudo apt install libmpv2    # Ubuntu 22.04+
```

### Auto-updater: `pkexec` not found

`pkexec` is part of the `polkit` package:

```bash
sudo apt-get install -y policykit-1
```

If `pkexec` is unavailable, the auto-updater will fail at the apply stage and show the
"Download Manually" option directing the user to the releases page.

### `dpkg-deb: error: failed to open package info file`

This usually means `dpkg-dev` is not installed on the build host:

```bash
sudo apt-get install -y dpkg-dev
```
