# Releasing Navis from a Linux Host

This document describes how to build and publish Navis release artifacts for all
supported platforms when your primary development machine is Linux.

## Platform Capabilities from Linux

| Platform | Build Host | Method |
|---|---|---|
| Linux | Linux (native) | `flutter build linux` |
| Android | Linux (native) | `flutter build apk` |
| Windows | Windows (remote via SSH) | `tool/remote_build_windows.sh` |
| macOS | macOS only — run release.sh directly on Mac | No `--macos-ssh`; Mac must orchestrate its own build |
| iOS | macOS only | Not scriptable from Linux |

> **Hard constraint:** Flutter desktop builds are strictly host-native. macOS builds
> require running `tool/release.sh` *on the Mac*; there is no remote-SSH path for macOS.
> Windows builds can be delegated to a remote Windows host via SSH from Linux.

---

## Release checklist

- A minor (or major) version bump resets every existing committed library on first launch; patch releases do not (legacy cache markers still renew once).

## Prerequisites

### 1. Flutter SDK

```bash
flutter --version          # Flutter 3.x stable
flutter doctor -v
```

### 2. Native Linux build dependencies

```bash
sudo apt-get update
sudo apt-get install -y \
  clang cmake ninja-build pkg-config \
  libgtk-3-dev libmpv-dev \
  dpkg-dev jq curl git
```

### 3. Android toolchain

Accept Android SDK licenses:

```bash
yes | flutter doctor --android-licenses
```

Keystore and `android/key.properties` must be provisioned locally. See
[release-secrets.md](release-secrets.md).

### 4. Forgejo token

Create `tool/release.env` (git-ignored):

```bash
FORGEJO_URL="https://git.porthorion.com"
FORGEJO_REPO="khalifa/Navis"
FORGEJO_TOKEN="<personal-access-token-with-write:release>"
```

---

## Release Artifacts

All artifacts follow the naming convention `<prefix>-<version>-<platform>.<ext>`:

| Target | Flag | Output filename |
|---|---|---|
| Android APK | `--targets=android` | `navis-v0.x.y.apk` |
| Linux portable bundle | `--targets=linux --linux-package=bundle` | `navis-v0.x.y-linux.tar.gz` |
| Linux Debian package | `--targets=linux --linux-package=deb` | `navis-v0.x.y-linux-amd64.deb` |
| Windows portable | `--targets=windows` | `navis-v0.x.y-windows.zip` |
| Windows installer | `--targets=windows --windows-package=exe` | `navis-v0.x.y-windows-installer.exe` |
| macOS bundle | `--targets=macos` (run on Mac) | `navis-v0.x.y-macos.zip` |

Dev channel assets are prefixed with `navis-dev-` instead of `navis-`.

For full per-platform packaging details see:
- [release-macos.md](release-macos.md)
- [release-linux.md](release-linux.md)
- [release-windows.md](release-windows.md)

---

## Building Linux and Android Locally

```bash
# Android APK only (default)
./tool/release.sh v0.9.0

# Linux portable bundle + Android
./tool/release.sh v0.9.0 --targets=android,linux

# Linux .deb + Android
./tool/release.sh v0.9.0 --targets=android,linux --linux-package=deb
```

> See [release-linux.md](release-linux.md) for instructions on publishing both
> the `.deb` and `.tar.gz` in a single release.

---

## Building Windows via Remote SSH Builder

You need a Windows machine (physical, VM, or cloud) with:
- Flutter SDK on `PATH` for non-interactive SSH shells
- Visual Studio C++ build tools (Desktop development with C++)
- CMake + Ninja
- Inno Setup 6 (`ISCC.exe`) for `--windows-package=exe`
- OpenSSH Server running

### Enable OpenSSH on Windows (PowerShell, as Admin)

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Start-Service sshd
Set-Service -Name sshd -StartupType Automatic
```

### Configure SSH alias on Linux (`~/.ssh/config`)

```
Host windows-builder
    HostName 192.168.x.x
    User YourWindowsUser
    IdentityFile ~/.ssh/id_ed25519
    ServerAliveInterval 60
    ServerAliveCountMax 60
```

### Add to `tool/release.env`

```bash
NAVIS_WINDOWS_SSH="windows-builder"
NAVIS_WINDOWS_REMOTE_DIR=".navis/remote-windows-build"
```

### Run

```bash
# Windows portable ZIP + Android + Linux
./tool/release.sh v0.9.0 --targets=android,linux,windows

# Windows Inno Setup installer
./tool/release.sh v0.9.0 --targets=windows --windows-package=exe
```

The script (`tool/remote_build_windows.sh`) archives the local source, uploads to the
Windows machine over SCP, executes the build remotely, packages the output, and copies the
artifact back to the repo root.

---

## Building macOS

macOS builds **cannot** be delegated from Linux — `tool/release.sh` exits with an error if
`--targets=macos` is passed on a non-macOS host.

Run the macOS release directly on the Mac:

```bash
# On the Mac
export MACOS_SIGN_IDENTITY="Developer ID Application: ..."
export MACOS_NOTARY_PROFILE="navis-notary-profile"
./tool/release.sh v0.9.0 --targets=macos --macos-notarize
```

See [release-macos.md](release-macos.md) for full macOS build and notarization
instructions.

---

## Full Multi-Platform Release

### Android + Linux + Windows (from Linux)

```bash
./tool/release.sh v0.9.0 \
  --targets=android,linux,windows \
  --linux-package=deb \
  --windows-package=exe
```

### Adding macOS

Run the macOS portion separately on the Mac after the Forgejo release exists, then upload
the `.zip` asset via the Forgejo API or web UI. See [release-macos.md](release-macos.md).

---

## Dev Channel Releases

```bash
./tool/release.sh v0.9.0-dev.1 --channel=dev --targets=android,linux
```

Assets will be named `navis-dev-v0.9.0-dev.1.*`. The `dev` channel also sets the Android
sidecar identity (`com.navis.app.navis.dev`) so both channels coexist on the same device.

---

## Troubleshooting

### `Could not find compiler set in environment variable CXX: clang++`

```bash
sudo apt-get install -y clang
export CXX=clang++
export CC=clang
```

### `flutter build linux` fails in CI / Docker

Flutter Linux builds need `libmpv-dev` and a GTK display environment. For headless
environments, set up Xvfb or use a Gtk-capable Docker image.

### Windows remote build times out

Windows Flutter builds can take 3–10 minutes on first run (MSVC compilation). Increase
`ServerAliveInterval` in `~/.ssh/config` (example above).

### Remote artifact not found after Windows build

Verify `flutter` is on `PATH` for non-interactive SSH shells on the Windows host:

```bash
ssh windows-builder "flutter --version"
```

If the command fails, add Flutter to the Windows user's system `PATH` (not just the
interactive shell PATH).
