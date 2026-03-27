# Releasing Navis from Linux

This document describes how to build and publish Navis release artifacts for all
supported platforms starting from a Linux development machine.

## Platform Capabilities from Linux

| Platform | Build Host | Method |
|----------|-----------|--------|
| Linux    | Linux (native) | `flutter build linux` |
| Android  | Linux (native) | `flutter build appbundle` / `apk` |
| Windows  | Linux (remote or cross) | SSH to Windows VM/machine |
| macOS    | macOS only | SSH to macOS machine / CI |
| iOS      | macOS only | SSH to macOS machine / CI |

> **Hard constraint:** Flutter desktop builds are strictly host-native. There is
> no practical cross-compilation path for Windows or macOS from Linux without a
> remote builder running the target OS.

---

## Prerequisites (Linux)

### 1. Flutter SDK

```bash
flutter --version          # must be Flutter 3.x stable
flutter doctor -v          # resolve any remaining issues
```

### 2. Native Linux build dependencies

```bash
sudo apt-get update
sudo apt-get install -y \
  clang cmake ninja-build pkg-config \
  libgtk-3-dev libmpv-dev \
  dpkg-dev                 # only needed for .deb packaging
```

### 3. Android toolchain

```bash
# Accept Android licenses
yes | flutter doctor --android-licenses
```

Keystore file and `android/key.properties` must be provisioned locally (see
[release-secrets.md](release-secrets.md)).

### 4. Forgejo token

Create `tool/release.env` (git-ignored):

```bash
FORGEJO_URL="https://git.porthorion.com"
FORGEJO_REPO="khalifa/Navis"
FORGEJO_TOKEN="<personal-access-token-with-write:release>"
```

---

## Building Linux and Android Locally

```bash
# Android release APK + AAB (default target)
./tool/release.sh v0.9.0

# Linux bundle + Android
./tool/release.sh v0.9.0 --targets=android,linux

# Linux .deb package + Android
./tool/release.sh v0.9.0 --targets=android,linux --linux-package=deb
```

All built artifacts land in the repo root as:

| Artifact | Filename |
|----------|---------|
| Android APK | `navis-v0.9.0.apk` |
| Android AAB | `navis-v0.9.0.aab` |
| Linux bundle (.tar.gz) | `navis-linux-v0.9.0.tar.gz` |
| Linux .deb | `navis-v0.9.0.amd64.deb` |

---

## Building Windows via Remote SSH Builder

You need a Windows machine (physical, VM, or cloud) with:
- Flutter SDK on `PATH` for non-interactive SSH shells
- Visual Studio C++ build tools (Desktop development with C++)
- CMake + Ninja
- OpenSSH Server running

### Enable OpenSSH on Windows (PowerShell, as Admin)

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Start-Service sshd
Set-Service -Name sshd -StartupType Automatic
```

### Configure SSH alias (Linux `~/.ssh/config`)

```
Host windows-builder
    HostName 192.168.x.x
    User YourWindowsUser
    IdentityFile ~/.ssh/id_ed25519
```

### Add to `tool/release.env`

```bash
NAVIS_WINDOWS_SSH="windows-builder"
NAVIS_WINDOWS_REMOTE_DIR=".navis/remote-windows-build"
```

### Run

```bash
# Windows ZIP + Android + Linux
./tool/release.sh v0.9.0 --targets=android,linux,windows

# Windows MSIX installer
./tool/release.sh v0.9.0 --targets=windows --windows-package=exe
```

The script (`tool/remote_build_windows.sh`) will:
1. Archive the local source tree
2. Upload to the Windows machine over SCP
3. Execute `flutter build windows` remotely
4. Package the output
5. Copy the artifact back to the repo root

---

## Building macOS / iOS via Remote SSH Builder

macOS builds require Xcode and can only run on Apple hardware or a macOS VM.

### Requirements on the macOS machine

- Xcode + Command Line Tools
- Flutter SDK on `PATH`
- Valid Apple Developer membership (for distribution signing + notarization)
- OpenSSH enabled (System Settings → General → Sharing → Remote Login)

### Configure SSH alias

```
Host mac-builder
    HostName 192.168.x.x
    User yourmacuser
    IdentityFile ~/.ssh/id_ed25519
```

### Add to `tool/release.env`

```bash
NAVIS_LINUX_SSH=""           # leave empty; Linux is built locally
NAVIS_MACOS_SSH="mac-builder"
NAVIS_MACOS_REMOTE_DIR=".navis/remote-macos-build"
```

### Run

```bash
# macOS + Android + Linux
./tool/release.sh v0.9.0 --targets=android,linux,macos

# macOS signed + notarized DMG
./tool/release.sh v0.9.0 --targets=macos --macos-notarize
```

---

## Full Multi-Platform Release from Linux

```bash
./tool/release.sh v0.9.0 \
  --all-platforms \
  --linux-package=deb \
  --windows-package=exe \
  --macos-notarize
```

This will:
1. Build Android APK + AAB natively on Linux
2. Build Linux .deb natively on Linux
3. SSH to the Windows machine, build and retrieve a Windows installer
4. SSH to the macOS machine, build and retrieve a notarized macOS DMG
5. Create a Forgejo release and upload all artifacts

---

## Dev Channel Releases

The dev channel uses a sidecar app identity so both channels can be installed
side-by-side on Android:

```bash
./tool/release.sh v0.9.0-dev.1 --channel=dev --targets=android,linux
```

Artifacts will be named `navis-dev-v0.9.0-dev.1.*`.

---

## Useful Individual Commands

```bash
# Build only, no publish
flutter build apk --release                      # Android APK
flutter build appbundle --release                # Android AAB
flutter build linux --release                    # Linux bundle

# Run tests before releasing
flutter test
./tool/check.sh

# Lint
flutter analyze
```

---

## Desktop Download Info

Downloads initiated inside the app are stored at:

```
<app support dir>/audio/permanent/
```

On Linux this is `~/.local/share/navis/audio/permanent/`.  
On Windows this is `%APPDATA%\navis\audio\permanent\`.  
On macOS this is `~/Library/Application Support/navis/audio/permanent/`.

Notifications for completed downloads are Android-only by design; desktop
platforms do not show system notifications for downloads.

---

## Troubleshooting

### `Could not find compiler set in environment variable CXX: clang++`

```bash
sudo apt-get install -y clang
```

Or if clang is installed but not the default:

```bash
export CXX=clang++
export CC=clang
```

### `flutter build linux` fails in CI / Docker

Flutter Linux builds need `libmpv-dev` and a display-capable environment.
For headless CI, set up a virtual display or use a Gtk-capable Docker image.

### Windows remote build times out

Increase SSH `ServerAliveInterval` in `~/.ssh/config` or pass `-o` flags. Windows
Flutter builds can take 3–5 min on first run.

### MPV `[error] lavf: Failed to create file cache` at runtime

This is suppressed in Navis ≥ 0.9.0 by removing the proxy layer — libmpv now
receives the original HTTPS stream directly.
