# Building Linux + Windows Releases From One Mac

## Goal
Produce `android`, `ios`, `macos`, `linux`, and `windows` artifacts by running commands from this Mac only.

## Hard Constraint
Flutter desktop builds are host-specific:
- `flutter build linux` must run on Linux.
- `flutter build windows` must run on Windows.

Because of this, the Mac release flow now supports SSH-orchestrated remote builders (typically local VMs on the same Mac).

## Recommended Architecture
1. Keep the main repo on macOS (your primary machine).
2. Run a Linux VM and a Windows VM locally (Parallels/UTM/VMware).
3. Enable SSH on both VMs.
4. Run `tool/release.sh` on macOS with remote builder flags (or env vars).

This keeps release orchestration centralized on the Mac while respecting Flutter host requirements.

## New Scripts
- `tool/remote_build_linux.sh`
- `tool/remote_build_windows.sh`

Both scripts:
- archive local source from macOS
- upload to the remote builder over SSH/SCP
- run Flutter build remotely
- package artifacts remotely
- copy artifacts back to the repo root on macOS

## Release Script Integration
`tool/release.sh` now supports:
- `--linux-ssh=<user@host>`
- `--windows-ssh=<user@host>`
- `--linux-remote-dir=<path>`
- `--windows-remote-dir=<path>`

When the current host cannot build Linux/Windows natively, `release.sh` automatically uses these remote builders.

## Configure `tool/release.env`
Add:

```bash
NAVIS_LINUX_SSH="linux-builder"
NAVIS_WINDOWS_SSH="windows-builder"
NAVIS_LINUX_REMOTE_DIR=".navis/remote-linux-build"
NAVIS_WINDOWS_REMOTE_DIR=".navis/remote-windows-build"
```

You can also pass these per-command via flags instead of env vars.
If you need custom ports/keys, define `linux-builder` and `windows-builder`
in `~/.ssh/config`.

## Linux Builder Requirements
Install on Linux VM:

```bash
sudo apt-get update
sudo apt-get install -y clang cmake ninja-build pkg-config libgtk-3-dev libmpv-dev tar
```

Install Flutter and ensure `flutter` is on `PATH` for non-interactive SSH shells.

For Debian packaging mode, also install:

```bash
sudo apt-get install -y dpkg-dev
```

## Windows Builder Requirements
Install on Windows VM:
- Flutter SDK + `flutter` on `PATH`
- Visual Studio C++ build tools (Desktop development with C++)
- CMake + Ninja
- Optional for installer mode: Inno Setup 6 (`ISCC.exe` on `PATH`)
- OpenSSH Server enabled and running

### Enable OpenSSH Server (Windows)
Run PowerShell as Admin:

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Start-Service sshd
Set-Service -Name sshd -StartupType Automatic
```

## Build Examples (from macOS)

```bash
# Full multi-platform release from Mac, using remote Linux+Windows builders
./tool/release.sh v1.2.3 --all-platforms

# Linux only through remote Linux VM
./tool/release.sh v1.2.3 --targets=linux --linux-package=deb --linux-ssh="linux-builder"

# Windows installer through remote Windows VM
./tool/release.sh v1.2.3 --targets=windows --windows-package=exe --windows-ssh="windows-builder"
```

## Standalone Remote Build Helpers

```bash
./tool/remote_build_linux.sh --ssh="linux-builder" --version=v1.2.3 --package=bundle
./tool/remote_build_windows.sh --ssh="windows-builder" --version=v1.2.3 --package=zip
```

## Notes
- Remote builders should be treated as disposable build workers.
- Keep secrets/signing material scoped to the specific platform host where needed.
- If release asset upload is done by `release.sh`, artifacts must be copied back to macOS first (handled automatically by the remote scripts).
