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

The entry point always uses AOT release mode, `--obfuscate`, split debug info
under `build/obfuscation/linux/<tag>` and `NAVIS_UPDATE_CHANNEL=stable` unless
an explicit channel is supplied. `release.sh` passes its existing
`set_obfuscation_args` and Dart defines (including the private Last.fm defines
file) unchanged. Native ELF symbols are stripped before packaging. Symbols
stay local and are never put into release packages. Do not statically link or
obfuscate libmpv: `lib/libmpv.so.2` remains replaceable.

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
`ldd`, desktop Exec/Icon paths and an ordinary user's lack of `/opt/navis`
write access. It never launches Navis. The packaging gate rejects a runner
requiring GLIBC newer than 2.35; also inspect library dependencies after
changing a native dependency or the libmpv pin.

## Package-manager updates

The existing app detector treats executables under `/opt/navis` as Debian
mode. Adding a real RPM update mode would require manifest selection and
installation changes beyond a few-line detector, so RPM/AUR use the existing
write-access fallback: normal users cannot write the root-owned `/opt/navis`
and see **Download Manually** when an update is offered. Update RPMs with
`dnf` and AUR packages with `makepkg`/your AUR helper. Do not run Navis as root
or grant ordinary users write access to the package-managed directory.
An in-app offer currently requires the matching `linuxDeb-amd64` asset in the
manifest even for RPM/AUR; shipping `--linux-package=all` supplies it.
`linuxRpm-x86_64` is published for download consumers, not native app auto-apply.
Portable and Debian updater behavior is described below.

## AUR owner workflow (manual publication)

The `navis-bin` recipe downloads the proprietary portable release, verifies
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

These are owner publication steps, separate from local validation. Verify the
EULA permits the intended distribution: Navis is closed source and proprietary
(`LicenseRef-Navis`); third-party components retain their own licences. Keep
LGPL notices and the corresponding libmpv/FFmpeg source/build recipe available
at their recorded locations. Packaging must preserve the separate shared
libmpv and must never bundle Navis obfuscation symbols.

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
`https://downloads.porthorion.com/navis/third-party/libmpv-linux-x86_64-lgpl-20261007.tar.gz`.
Every attempt is verified, failures are deleted, and the archive is cached in
the CMake build directory. A verified cached archive supports offline builds;
extraction is once per pin, retried if incomplete. The library is installed
into the standard bundle `lib/` directory alongside Flutter's libraries.

To update, use [the build recipe](../tool/libmpv/README.md), check the embedded
mpv `-Dgpl=false` and absence of FFmpeg `--enable-gpl`/`--enable-nonfree`,
and review `BUILDINFO.txt`'s ELF dependencies. Package the library, headers and
recipe under `libmpv-linux-x86_64-lgpl/`, then upload the dated tarball,
`SOURCES.md` and the corresponding source archives to R2 at
`navis/third-party/<release tag>/`, plus the tarball at the flat
`navis/third-party/<tarball-name>` path CMake reads. Update the filename,
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
