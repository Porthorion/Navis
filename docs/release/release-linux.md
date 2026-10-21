# Releasing Navis for Linux

Navis ships x86_64 release binaries built against Ubuntu 22.04 (glibc 2.35),
including the separately built, pinned LGPL libmpv. Supported targets are
Ubuntu 22.04+, Debian 12+ and compatible glibc desktop distributions; Alpine's
musl runtime is not supported by these bundles.

| Format | Filename | Install location |
|---|---|---|
| Portable | `navis-vX.Y.Z-linux.tar.gz` | User-selected directory |
| Debian | `navis-vX.Y.Z-linux-amd64.deb` | `/opt/navis` |
| RPM | `navis-vX.Y.Z-linux-x86_64.rpm` | `/opt/navis` |
| AUR binary recipe | `packaging/aur/navis-bin/` | `/opt/navis` |

Keep the portable filename: 1.4.x clients discover that name. Package-manager
installs also provide `/usr/bin/navis`, `/usr/share/applications/navis.desktop`
and all existing hicolor icon sizes under `/usr/share/icons/hicolor`.

## Container build and local packaging

Install Docker on a Linux x86_64 host and give the build account Docker access.
The host needs Flutter on PATH (the version required by `pubspec.yaml`), a
bootstrapped pub cache, Git and `flock`. The release coordinator also needs
`bsdtar` to scan RPM payloads for the bundled plaintext Last.fm key
(`libarchive-tools` on Debian/Ubuntu, `libarchive` on Arch).
No host GTK/compiler/dpkg/rpm toolchain is needed. SSH Linux builders need the
same Docker/Flutter/cache setup.

```bash
# Local only: no signing, tags, pushes, uploads or GUI launch.
NAVIS_LINUX_MEMORY=6g NAVIS_LINUX_CPUS=2 ./tool/linux/build_in_container.sh
# Default: all three formats, version from pubspec.yaml, stable channel.
./tool/linux/build_in_container.sh --package=deb --version=v1.5.0
# Repackage the same verified bundle without rebuilding Flutter.
./tool/linux/build_in_container.sh --package-only --package=all --version=v1.5.0
```

`tool/linux/Dockerfile` installs clang, cmake, ninja, pkg-config, GTK,
libsecret (secure-storage plugin), liblzma, libstdc++ 12, dpkg-deb and rpmbuild
on Ubuntu 22.04. The host SDK and pub cache are mounted read-only and copied
into writable container storage. Current tracked and non-ignored source files
are copied into an isolated workspace; host `.dart_tool`, SDK and pub caches
are not rewritten. Outputs are owned by the invoking user. Allow roughly
8 GiB of temporary disk space for SDK/cache copies and build outputs.
`NAVIS_FLUTTER_SDK` and `PUB_CACHE` override the input locations.

Both image construction and the build have a memory cap (default 6 GiB, no
extra swap); the build defaults to two CPUs and two parallel CMake jobs.
A lock serializes builds across worktrees. Image construction explicitly uses
Docker's legacy builder so its memory flags are honored; Docker must include
that builder.

The entry point defaults to AOT release mode and `--split-debug-info`
under `build/symbols/linux/<tag>` and `NAVIS_UPDATE_CHANNEL=stable` unless
an explicit channel is supplied. `release.sh` passes its existing
`set_symbol_args` and Dart defines (including the private Last.fm defines
file) unchanged. Native ELF symbols are stripped before packaging. Symbols
stay local and are never put into release packages. Dart obfuscation is disabled.
Diagnostics can explicitly select `--build-mode=profile` (the diagnostics API
rejects release mode), with `--build-name` and `--build-number` forwarded to
Flutter so the running app version matches the package under test. Both modes
stage the selected bundle under `build/linux/x64/release/bundle` for packaging.
Do not statically link libmpv: `lib/libmpv.so.2` remains replaceable.

`release.sh` and the SSH builder call this same container entry point.
`tool/linux/package_bundle.sh` contains the extracted existing bundle/Debian
assembly plus RPM assembly; there is no independent publishing pipeline.
The coordinator scans every resulting package, including RPM payloads.

```bash
# Owner's publication command; this builds AND publishes.
./tool/release.sh vX.Y.Z --targets=linux --linux-package=all
# Individual outputs remain available: bundle (default), deb, rpm.
```

Debian dependencies are `libgtk-3-0, libsecret-1-0, libpulse0,
libasound2 | libasound2t64` (the latter accommodates Ubuntu 24.04/Debian 13).
RPM requires `gtk3, libsecret, pulseaudio-libs, alsa-lib`; PulseAudio client
libraries work with a PipeWire PulseAudio server too. RPM also records ELF
runtime requirements and excludes private bundled Flutter/plugin SONAMEs
from global provides/requires. Neither package requires system mpv.
Debian maintainer defaults to `Porthorion <support@porthorion.com>`;
`NAVIS_DEB_MAINTAINER` still overrides it.

```bash
sudo apt install ./navis-vX.Y.Z-linux-amd64.deb
sudo dnf install ./navis-vX.Y.Z-linux-x86_64.rpm
```

## Headless package verification

```bash
./tool/linux/verify_packages.sh v1.5.0
# Retry one distribution if needed:
./tool/linux/verify_packages.sh v1.5.0 fedora:latest
objdump -T build/linux/x64/release/bundle/navis | grep GLIBC_
```

The verification script sequentially installs into disposable Ubuntu 22.04,
Debian 12 and Fedora latest containers, each capped at 2 GiB/two CPUs.
Debian-family checks use `dpkg -i` then `apt-get -f install`; Fedora uses
`dnf install` with zchunk metadata disabled for these fresh containers
(repository package GPG checking remains enabled). It checks the runner AND each dynamically loaded library with
`ldd`, desktop Exec/Icon paths and the installed owner of `/opt/navis/navis`
as root (`dpkg-query -S` on Debian-family images, `rpm -qf` on Fedora). It never launches Navis.
Set `NAVIS_LINUX_PACKAGE_DIR` to an absolute directory to verify isolated
artifacts instead of packages in the repository root. The packaging gate rejects a runner
requiring GLIBC newer than 2.35; also inspect library dependencies after
changing a native dependency or the libmpv pin.

## Package-manager updates

Starting with 1.5.1, Navis asks `dpkg-query -S /opt/navis/navis`, then
`rpm -qf /opt/navis/navis`, which package manager owns the installed executable.
Debian and Fedora/dnf packages can install signed updates in-app through a
polkit prompt. AUR and unknown owners show system package-manager
instructions and never download a Debian/RPM artifact. Do not run Navis as root
or grant ordinary users write access to `/opt/navis`.

Automatic installation works from the first update after 1.5.1; 1.5.0 users
update to 1.5.1 manually or through their package manager. The installed old
updater decides how 1.5.1 is installed.

## AUR owner workflow (manual publication)

The `navis-bin` recipe downloads the official portable release, verifies
its SHA-256, and installs its binary, desktop entry, icons and licence notices.
It does not compile source. Before publication, set `pkgver` and the tarball
SHA-256 to the FINAL released bytes (the checked-in local validation hash must
be refreshed for the published artifact), increment `pkgrel` as appropriate,
and regenerate `.SRCINFO`. Never use `SKIP` for a published binary package.

```bash
sha256sum navis-v1.5.0-linux.tar.gz
cd packaging/aur/navis-bin
makepkg --printsrcinfo > .SRCINFO
# Test a COPY of the recipe with source replaced by the matching file:// URL:
# systemd-run --user --scope -p MemoryMax=2G -p MemorySwapMax=0 -- makepkg -f --nodeps
```

The owner must create an account at https://aur.archlinux.org, add their SSH
public key in the account settings, then:

```bash
git clone ssh://aur@aur.archlinux.org/navis-bin.git
cp packaging/aur/navis-bin/PKGBUILD packaging/aur/navis-bin/.SRCINFO navis-bin/
cd navis-bin
git add PKGBUILD .SRCINFO
git commit -m "Update Navis binary package"
git push
```

These are owner publication steps, separate from local validation. Navis is
GPL-3.0-or-later; third-party components retain their own licences. The bundle
installs `LICENSE` as `data/licenses/GPL-3.0.txt`; Debian copyright and RPM
metadata declare `GPL-3.0-or-later AND LGPL-2.1-or-later`. AUR declares both
licences and copies the bundled notices into `/usr/share/licenses/navis-bin/`. Keep
LGPL notices and the corresponding libmpv/FFmpeg source/build recipe available
at their recorded locations. Packaging must preserve the separate shared
libmpv and must never bundle Navis debug symbols.

## Bundled LGPL libmpv

Linux x86_64 packages ship LGPL-2.1+ libmpv/FFmpeg as `lib/libmpv.so.2`.
Startup selects that file relative to `Platform.resolvedExecutable`; if absent,
development runs use system libmpv. `NAVIS_BUNDLE_LIBMPV` defaults ON in
`linux/CMakeLists.txt`; developers can set `-DNAVIS_BUNDLE_LIBMPV=OFF` in their
CMake configuration/cache to use system mpv. Other architectures must opt out
until a matching LGPL artefact is published; never package the x86_64 binary
for them. Custom packages without the bundle need their own system-mpv dependency.

The current archive is `libmpv-linux-x86_64-lgpl-20261007.tar.gz`, SHA-256
`759bb6586b4d772bb78a565609dcccc5205741c8b1163c1d47ed3493bf227f6e`.
CMake downloads
`https://downloads.porthorion.com/navis/third-party/libmpv-linux-x86_64-lgpl-20261007/libmpv-linux-x86_64-lgpl-20261007.tar.gz`.
Every attempt is verified, failures are deleted, and the archive is cached in
the CMake build directory. A verified cached archive supports offline builds;
extraction is once per pin, retried if incomplete. The library is installed
into the standard bundle `lib/` directory alongside Flutter's libraries.

To update, use [the build recipe](../../tool/libmpv/README.md), check the embedded
mpv `-Dgpl=false` and absence of FFmpeg `--enable-gpl`/`--enable-nonfree`,
and review `BUILDINFO.txt`'s ELF dependencies. Package the library, headers and
recipe under `libmpv-linux-x86_64-lgpl/`, then upload the dated tarball,
`SOURCES.md` and the corresponding source archives to R2 at
`navis/third-party/libmpv-linux-x86_64-lgpl-<date>/` only, with no flat copy.
CMake reads the tarball in that per-build folder. Update the filename,
ordered URLs and SHA-256 in CMake and the in-app source-location notice.

The Debian package no longer depends on system `libmpv2 | libmpv1`. Its minimal
runtime dependencies are `libgtk-3-0, libsecret-1-0, libpulse0,
libasound2 | libasound2t64`: the recipe enables
both PulseAudio and ALSA, so both shared libraries must load even when only one
output is used. An alternative (`libpulse0 | libasound2`) would be insufficient.
GnuTLS is already supplied by GTK's dependency on CUPS on the Ubuntu 22.04
baseline ([GTK dependencies](https://packages.ubuntu.com/jammy/libgtk-3-0),
[CUPS dependencies](https://packages.ubuntu.com/jammy/libcups2)), so no redundant
`libgnutls30` dependency is added. GTK also supplies the font libraries; inspect
ELF dependencies again for every new pin. Portable bundles still require these
system desktop libraries.

### Auto-updater behavior

Debian packages select `linuxDeb-amd64` / `linuxDeb-arm64`; RPM packages select
`linuxRpm-x86_64` / `linuxRpm-aarch64` when published. Missing architecture keys
do not fall back to another architecture or package family. Official RPM
packages target Fedora/RHEL's dnf family; openSUSE/zypper is out of scope.

1. Download the matching artifact and verify signed size and SHA-256.
2. Run one `pkexec /bin/sh -c` script with the path/hash/kind as arguments. The
   user authenticates through their desktop's polkit agent.
3. Copy into a root-owned temporary directory under `/var/tmp`, recheck SHA-256,
   then run `apt-get -o DPkg::Lock::Timeout=120 install -y --no-install-recommends`
   or `dnf install -y` on that copy. The EXIT trap removes the root copy.
4. After a successful installation, relaunch `/opt/navis/navis` and exit the old
   process. Cancelling returns silently to confirm. Missing pkexec/agent shows
   the package-manager screen. Installer stderr stays in logs for diagnosis.
   An integrity failure offers Retry (download and verify again); other install
   failures keep the app alive with Download Manually.

### Package updater runtime diagnostics (R1–R9)

`tool/linux/package_update_diagnostics.sh` uses the existing R2 publisher,
transport and handshake/API helpers. It records private artifacts under
`build/linux-package-update-diagnostics` (override with `--run-dir=PATH` on
**every** command). Run one staging test at a time; it temporarily replaces the
staging manifest and never writes stable/dev. Publication requires an empty or
older staging channel; the existing publisher ordering/signature guards remain
enabled and run before building the update fixtures. Load R2 settings/signing key through
ignored `tool/release.env`; do not enable shell tracing or share handshake files.

```bash
./tool/linux/package_update_diagnostics.sh build
./tool/linux/package_update_diagnostics.sh publish
./tool/linux/package_update_diagnostics.sh run --host=user@debian-host
# Owner supplies/removes the temporary polkit rule before/after R2:
./tool/linux/package_update_diagnostics.sh run --host=user@debian-host --repeat=3
./tool/linux/package_update_diagnostics.sh run --host=user@debian-host --corrupt
./tool/linux/package_update_diagnostics.sh run --host=user@debian-host --manual
./tool/linux/package_update_diagnostics.sh run --containers
./tool/linux/package_update_diagnostics.sh cleanup
```

`build` packages `1.4.N`, where N is a per-run epoch patch number. `publish`
builds signed `N+1` and `N+2` staging packages, corrupts the latter's origin
bytes before the app's first request, and restores the signed `N+1` envelope.
The builder uses profile mode, staging and isolated clone diagnostics defines;
embedded app and package versions match. Each remote run records the original
package state before installation, installs N with sudo, and launches through
`systemd-run --user` with the graphical session's DISPLAY/WAYLAND_DISPLAY,
D-Bus and XDG environment. The session must already be active and its environment
imported into the user manager; the remote systemd must support `ExitType=cgroup`
(Ubuntu 24.04 does). No real library/account is required for the update API.

The temporary R2 polkit rule (test hosts only) must allow `org.freedesktop.policykit.exec` for the test user with the program `/bin/sh`. On Fedora pkexec resolves `/bin/sh` to `/usr/bin/bash`, so match `/bin/sh`, `/usr/bin/sh` and `/usr/bin/bash`. Remove the rule afterwards.

R1 needs the owner at the real polkit prompt. R2 repeats the successful
check/download/apply flow three times with an owner-managed temporary rule.
Automated success requires the expected package version, a new live pid from
`/opt/navis/navis`, the old pid gone, a clean dpkg audit and no
`/var/tmp/navis-update.*` leftovers. The tunnel is closed on exit.

For R3/R4/R5-swap/R6, use `--manual` and the real update dialog: cancel once;
use a graphical session without a polkit agent; replace the artifact while the
dialog is at confirm; or have the owner hold the dpkg frontend's **fcntl** lock
for longer than 120 seconds (flock alone does not contend dpkg's lock). Press
Enter once the expected UI is visible. The harness captures an app-owned
screenshot and user journal, asserts the package/pid stayed unchanged, then
shuts down. Inspect the screenshot, relevant exit-code stderr and UI state;
these assertions alone do not certify the dialog. `--corrupt` separately
asserts `integrity_mismatch` with no installation or relaunch.

R7 uses `run --host=user@fedora-host --family=rpm` on an isolated Fedora graphical
host/VM. With Xvfb, a separately built test elevator must be a **single executable
wrapper** on PATH containing `exec sudo -n "$@"`; this covers dnf/relaunch, not
polkit. R8 remains an owner-run AUR/unknown-owner dialog check with no download,
backed by `update_dialog_test.dart`; do not use the download API for R8 because
that endpoint intentionally bypasses the dialog's capability guard. R9's
`--containers` runs Ubuntu 22.04, Debian 12 and Fedora sequentially, checks
ownership, and executes the actual production root script to upgrade N → N+1
without polkit. It never launches a GUI.

`cleanup` deletes this run's release objects and only deletes the staging
manifest if it still points at this run. It stops the task-owned remote unit,
removes its isolated profile/package transfer and uninstalls the test package
only if no installed package was recorded before the run. An existing package
is retained at the test version: restore it manually. Use a fresh run directory
for another run; never reuse patch URLs cached by the CDN. Preserve evidence
before removing local artifacts. These commands are a recipe, not runtime
acceptance evidence until actually executed.

---

## Portable bundle (`.tar.gz`)

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

## Publishing all formats

`--linux-package=all` builds the bundle once and ships tar.gz, deb and rpm
in one release. Individual formats can still be added to an existing tag via
the owner's `--allow-existing-version` flow or `r2_publish.sh`; see
[release-r2.md](release-r2.md). RPM maps to `linuxRpm-x86_64`, Debian to
`linuxDeb-amd64` and the tarball to `linuxPortable`.

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

### Container build failures

Inspect Docker access, available disk space, the selected Flutter SDK and the
build memory cap. Linux release compilation is headless: it needs no X server,
Xvfb, emulator or GUI application launch. A killed compiler may indicate the
container memory limit was reached; adjust `NAVIS_LINUX_MEMORY` within the host
budget. Use the container entry point rather than the host's newer glibc.

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

`dpkg-deb` is installed in the build image. Inspect the generated package
stage/control and the preceding container log; installing it on the Arch host
is unnecessary. Rebuild the image after changing its dependency list.
