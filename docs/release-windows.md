# Releasing Navis for Windows

Navis for Windows is distributed in two formats:

| Format | Filename | Type |
|---|---|---|
| Installer | `navis-v0.x.y-windows-installer.exe` | Inno Setup wizard — recommended for most users |
| Portable bundle | `navis-v0.x.y-windows.zip` | Extract anywhere and run — no installation required |

Both formats are supported by the built-in auto-updater. The installer is the recommended
default; the portable bundle suits environments where installation is restricted (corporate
machines, USB sticks, shared computers).

---

## Bundled libmpv

Windows playback runs on libmpv, which Navis bundles as `libmpv-2.dll`. The
`media_kit_libs_windows_audio` package that provides it is vendored in
`third_party/media_kit_libs_windows_audio/` (see its `NAVIS.md`): upstream's
build is a minimal 2023-09-24 libmpv from an archived repository, without the
FFmpeg `volume` and `biquad` filters the equalizer needs and without FFmpeg
fixes since. Navis pins the LGPL-2.1+ variant from
[zhongfly/mpv-winbuild](https://github.com/zhongfly/mpv-winbuild):
`mpv-dev-lgpl-x86_64-20261006-git-eb0ee10315.7z`, mpv
v0.41.0-1104-geb0ee1031 (`-Dgpl=false`) and FFmpeg N-127222-g151814650
(without `--enable-gpl`), with the `volume` and `biquad` filters present.

CMake tries `https://downloads.porthorion.com/navis/third-party/libmpv-windows-x86_64-lgpl-20261006/<archive-name>`, then the
pinned upstream release. Each attempt is SHA-256 verified; failed or mismatched downloads are
deleted before trying the next URL. A verified build-directory cache works
offline. Extraction is per archive pin. The R2 mirror keeps old Navis versions
buildable when upstream prunes daily releases.

To update the pin:

1. Download an LGPL `mpv-dev-lgpl-x86_64-<date>-git-<rev>.7z` archive from
   upstream; use plain x86_64, not `-v3` (requires AVX2).
2. Verify the published SHA-256, `libmpv-2.dll` and `include/mpv/*.h`.
   `strings libmpv-2.dll | grep -c -- --enable-gpl` must report `0` (grep
   exits 1 for zero matches). Inspect the embedded meson configuration for
   `-Dgpl=false`; confirm the FFmpeg configuration also lacks `--enable-nonfree`
   and that `volume` and `biquad` are available.
3. Upload the binary, `SOURCES.md` (upstream URL, SHA-256, versions, licence
   and build configuration) and the corresponding mpv/FFmpeg source tarballs
   to R2 at `navis/third-party/libmpv-windows-x86_64-lgpl-<date>/`. Preserve
   older folders; the in-app licence notice links to them.
4. Upload only into the per-build folder, with no flat copy. Verify the
   archive SHA-256 there. Update `LIBMPV`, ordered `LIBMPV_URLS` and
   `LIBMPV_SHA256` in the vendored CMake file.
5. Build a profile bundle and verify EQ, speed/pitch, gapless playback,
   seeking and TLS certificate validation; inspect mpv logs for `af` errors.

The remote Windows builder no longer pre-seeds the obsolete 2023 media_kit
archive; only the current CMake pin/cache is used.

---

Windows executable metadata and the Inno installer identify Porthorion as the
publisher. The installer links support and publisher information to
`https://navis.porthorion.com` and includes the 2026 Porthorion copyright.

## Rust crate licence notices

Before packaging after a Rust dependency update, fetch the locked dependencies
(including the Windows target), then regenerate the in-app notice from the
repository root:

```bash
python3 tool/generate_rust_notices.py
```

The script runs `cargo metadata --format-version 1 --filter-platform
x86_64-pc-windows-msvc --locked --offline` in the SMTC Rust directory. It
includes every resolved registry crate, reads its bundled licence files, and
prints each distinct text once with its users. Commit
`assets/licenses/windows-smtc-crates.txt` with dependency changes. A missing
licence file is explicitly reported in the notice inventory and must be
reviewed before distribution. The app registers this notice on Windows only.

## Platform Constraint

Windows builds require a Windows host. On macOS or Linux, delegate to a remote Windows
builder via SSH (see the [Remote Builder](#building-from-a-non-windows-host-remote-builder)
section). The release script is a bash script — on Windows, run it inside **Git Bash**
(bundled with Git for Windows) or WSL.

---

## Build Host Prerequisites

### 1. Flutter SDK

Install Flutter for Windows and ensure `flutter` is on `PATH` for both interactive and
non-interactive shells (required for remote builds).

```powershell
flutter --version
flutter doctor -v
```

### 2. Visual Studio C++ Build Tools

Required by `flutter build windows`. Install the free
[Visual Studio Build Tools 2022](https://visualstudio.microsoft.com/downloads/#build-tools-for-visual-studio-2022):

- Workload: **Desktop development with C++**
- This automatically includes MSVC, Windows SDK, CMake, and Ninja.

You do **not** need the full Visual Studio IDE.

Verify:

```powershell
flutter doctor -v
# Should show: "Visual Studio - develop Windows apps [OK]"
```

### 3. Inno Setup 6 (installer mode only)

Inno Setup is a free, mature installer compiler for Windows.

1. Download from **https://jrsoftware.org/isdl.php** — choose "Inno Setup 6" (not the
   QuickStart Pack).
2. Run the installer with default settings.
3. Verify it is accessible (the release script also checks default installation paths):

```powershell
# Default locations checked automatically:
# C:\Program Files (x86)\Inno Setup 6\ISCC.exe
# C:\Program Files\Inno Setup 6\ISCC.exe

# To add to PATH manually:
[System.Environment]::SetEnvironmentVariable(
  "PATH",
  $env:PATH + ";C:\Program Files (x86)\Inno Setup 6",
  "Machine"
)
```

### 4. `jq` (for the release script)

```powershell
# Via Chocolatey:
choco install jq

# Or: download the binary from https://jqlang.github.io/jq/download/ and add to PATH
```

### 5. R2 publishing settings

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

## Building

```bash
flutter build windows --release --dart-define=NAVIS_UPDATE_CHANNEL=stable
```

Output directory: `build/windows/x64/runner/Release/`

The directory must be packaged **as a whole** — users need `navis.exe`, all `.dll` files,
`flutter_assets/`, and `data/`. Do not distribute just the `.exe`.

---

## Format 1: Inno Setup Installer (`.exe`)

### What it does

- Installs to `%ProgramFiles%\Navis` (user-selectable during install).
- Creates a Start Menu entry.
- Offers an optional desktop shortcut.
- Places `unins000.exe` in the install directory — the file the auto-updater checks to
  detect installer mode.
- LZMA solid-compression for efficient download size.
- Supports silent install via `/SILENT`.

### Building

```bash
./tool/release.sh v0.x.y --targets=windows --windows-package=exe
```

Output: `navis-v0.x.y-windows-installer.exe`

The script invokes `tool/windows/build_inno_installer.ps1`, which generates a temporary
`.iss` script and compiles it with `ISCC.exe`.

### Manual build (without the release script)

```bash
flutter build windows --release --dart-define=NAVIS_UPDATE_CHANNEL=stable

# From PowerShell or Git Bash, invoke the installer script directly:
powershell.exe -NoProfile -ExecutionPolicy Bypass \
  -File "tool/windows/build_inno_installer.ps1" \
  -ReleaseDir "build\windows\x64\runner\Release" \
  -Version "v0.x.y" \
  -AssetPrefix "navis" \
  -OutputPath "navis-v0.x.y-windows-installer.exe"
```

### User installation

Standard: double-click the `.exe` and follow the wizard.

Silent (e.g. IT deployment):

```powershell
.\navis-v0.x.y-windows-installer.exe /SILENT
```

Silent with forced close of any running instance:

```powershell
.\navis-v0.x.y-windows-installer.exe /SILENT /CLOSEAPPLICATIONS
```

### Auto-updater detection

The auto-updater uses installer mode when `unins000.exe` is found next to `navis.exe`.
Inno Setup always places this file there during installation.

### Auto-update flow

1. Downloads `navis-vX.Y.Z-windows-installer.exe` (manifest key `windowsInstaller`).
2. Checks its size and SHA-256 against the signed manifest; a mismatch deletes the file
   and shows "The update download was damaged".
3. Launches it with `/SILENT /CLOSEAPPLICATIONS`.
4. Exits the app immediately.

Inno Setup closes any running Navis instance, installs new files over the existing
installation, and launches the app on completion — all without any user interaction.

---

## Format 2: Portable Bundle (`.zip`)

### What it contains

A `.zip` of the entire `Release/` directory: `navis.exe`, all `.dll` files,
`flutter_assets/`, and `data/`.

### Building

```bash
./tool/release.sh v0.x.y --targets=windows
# or explicitly:
./tool/release.sh v0.x.y --targets=windows --windows-package=zip
```

Output: `navis-v0.x.y-windows.zip`

### User installation

1. Download and extract the `.zip` to any folder (e.g. `C:\Apps\Navis\`).
2. Run `navis.exe`.

No administrator rights required.

### Auto-updater detection

The auto-updater uses portable mode when `unins000.exe` does **not** exist next to
`navis.exe`.

### Auto-update flow

1. Downloads `navis-vX.Y.Z-windows.zip` (manifest key `windowsPortable`) and checks its
   size and SHA-256 against the signed manifest.
2. Extracts using PowerShell `Expand-Archive` to a temp staging directory.
3. Writes a batch updater script to temp and launches it with `cmd /c` (detached), then
   exits the app.

The updater script:
- Waits 2 seconds for the app to exit.
- Removes any leftover `.backup` directory from a previous update.
- Renames the current install directory to `.backup`.
- Uses `robocopy /E` to copy all new files into the install directory.
- Launches `navis.exe`.
- Removes the `.backup` directory and self-deletes.

---

## Publishing Both Formats

`release.sh` builds one Windows package per run (`--windows-package=zip|exe`) and
publishes it to R2 in that run. To ship the other format for the same version, run
`release.sh` again with `--allow-existing-version` and the other `--windows-package`,
or pass the file to `tool/r2_publish.sh publish --tag=<tag> --channel=<channel> <file>`.
When the channel already points at that tag, the publish adds the new asset to the
signed manifest and rewrites `SHA256SUMS`; existing assets are kept.

Windows installs pick their asset by detected install mode: installer installs read
`windowsInstaller` and portable installs read `windowsPortable`. A manifest that lacks the
key for an install reports no update for that install (reject reason `missing_asset`).

---

## Code Signing (Optional, Recommended)

Without a code signature, Windows SmartScreen shows a "Windows protected your PC" warning
the first time users run the installer. The warning disappears automatically once the
file has accumulated enough download reputation — typically after a few hundred installs.

For a signed installer:

1. Purchase a **Code Signing Certificate** from a trusted CA (DigiCert, Sectigo, etc.).
   OV (Organization Validation) is sufficient; EV (Extended Validation) provides immediate
   SmartScreen reputation bypass.

2. Sign the compiled `.exe` with `signtool.exe`:

```powershell
signtool sign `
  /tr http://timestamp.digicert.com `
  /td sha256 `
  /fd sha256 `
  /a navis-v0.x.y-windows-installer.exe
```

Code signing is not currently scripted in `tool/release.sh` and must be done manually
after the installer is built.

---

## Building from a Non-Windows Host (Remote Builder)

### On the Windows builder machine

1. Complete all prerequisites from the "Build Host Prerequisites" section above.

2. Enable OpenSSH Server (PowerShell as Administrator):

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Start-Service sshd
Set-Service -Name sshd -StartupType Automatic
```

Harden it before it receives release builds. Allow key logins only, allow
only the build account, and keep the port reachable from the LAN only:

```powershell
$cfg = "$env:ProgramData\ssh\sshd_config"
# Prepend: the default file ends in a Match block, and sshd keeps the first value.
Set-Content $cfg (@('PasswordAuthentication no', 'AllowUsers <build-user>') + (Get-Content $cfg))
Restart-Service sshd
Set-NetFirewallRule -Name OpenSSH-Server-In-TCP -RemoteAddress LocalSubnet
```

3. Add your public key:

```powershell
$key = "ssh-ed25519 AAAA... your-public-key"
New-Item -Path "$env:USERPROFILE\.ssh" -ItemType Directory -Force
Add-Content "$env:USERPROFILE\.ssh\authorized_keys" $key
```

4. Ensure `flutter` (and `ISCC.exe` for installer mode) are on `PATH` for
   **non-interactive** SSH sessions. Test from the build machine:

```bash
ssh windows-builder "flutter --version"
ssh windows-builder "ISCC.exe /?"        # installer mode only
```

If either command fails, add the tool to the user's system `PATH` in Windows
Environment Variables (not just the interactive shell PATH).

### Configure SSH alias on the build machine (`~/.ssh/config`)

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

### Run from macOS / Linux

```bash
./tool/release.sh v0.x.y --targets=windows --windows-package=exe
```

The remote build script (`tool/remote_build_windows.sh`) archives the local source,
uploads over SCP, builds remotely, packages, and copies the artifact back.

---

## Dev Channel

```bash
./tool/release.sh v0.x.y --channel=dev --targets=windows --windows-package=exe
```

Assets: `navis-dev-v0.x.y-windows-installer.exe` / `navis-dev-v0.x.y-windows.zip`

The Inno Setup AppId for the dev channel is distinct from stable, so both can be installed
side-by-side.

---

## Troubleshooting

### `ISCC.exe` not found

Ensure Inno Setup 6 is installed. The release script checks the two default installation
paths automatically. If installed to a non-default path, add `ISCC.exe` to `PATH`.

### `flutter build windows` fails: `cl.exe not found`

Visual Studio C++ tools are not on `PATH`. Either:

- Open the **x64 Native Tools Command Prompt for VS 2022** before running the build, or
- Ensure "Desktop development with C++" is installed in Build Tools.

### PowerShell `Compress-Archive` fails with "access to path denied"

The output file may be locked. Close any Explorer windows showing the Release directory,
or use the `zip` fallback (available in Git Bash):

```bash
(cd build/windows/x64/runner/Release && zip -r ../../../../navis-v0.x.y-windows.zip .)
```

### Remote build SSH times out

Windows Flutter builds can take 3–10 minutes on first run (MSVC compilation). Increase
`ServerAliveInterval` in `~/.ssh/config` (example above shows 60s × 60 = 1 hour max).

### Auto-update: installer warns instead of running silently

The auto-updater passes `/SILENT /CLOSEAPPLICATIONS`. If the installer is prompting for
UAC elevation, it means it was installed to a location requiring admin rights. Silent
install with elevation: ensure the `.exe` has a manifest requesting elevation. The Inno
Setup script in `tool/windows/build_inno_installer.ps1` installs to `%ProgramFiles%` by
default, which requires elevation — this is handled automatically by Windows UAC.

### Users see SmartScreen warning on first run

This is normal for unsigned binaries. Users should click "More info" → "Run anyway". The
warning disappears after sufficient download reputation accumulates. For immediate bypass,
sign the installer with a code signing certificate (see the [Code Signing](#code-signing-optional-recommended) section).
