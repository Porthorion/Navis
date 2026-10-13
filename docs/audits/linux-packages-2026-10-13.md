# Linux package validation — 2026-10-13

Branch: `feat/linux-packages`. Local version: `1.5.0+10500` (unreleased).
Host: Arch Linux x86_64. No application, emulator or VM was launched, no
`tool/check.sh` was run, and nothing was published to Forgejo, R2 or AUR.

## Changes

- `.gitignore`, `README.md`
- `tool/linux/Dockerfile`
- `tool/linux/build_in_container.sh`
- `tool/linux/container_entry.sh`
- `tool/linux/package_bundle.sh`
- `tool/linux/verify_packages.sh`
- `tool/release.sh`, `tool/remote_build_linux.sh`, `tool/r2_publish.sh`
- `tool/lib/scan_artifact_secret.sh`, `tool/scan_artifact_secret_test.sh`
- `packaging/aur/navis-bin/PKGBUILD`, `packaging/aur/navis-bin/.SRCINFO`
- `lib/src/features/changelog/changelog_data.dart`
- `docs/architecture.md`, `docs/ci-cd.md`, `docs/development-workflow.md`
- `docs/release-linux.md`, `docs/release-from-linux.md`, `docs/release-r2.md`
- This evidence record.

The existing Linux bundle/Debian assembly was extracted into the shared
packaging helper. Local and SSH release builds call the same Ubuntu 22.04
container; `release.sh` retains its obfuscation arguments, defines, artifact
scanning and publication path. New RPM assembly uses the same `/opt/navis`
prefix, desktop template and icons. `linuxRpm-x86_64` is a download key;
RPM/AUR use the existing unprivileged manual-update fallback rather than a
new updater mode. They need `linuxDeb-amd64` in the manifest to receive an
in-app offer. The owner should ship `--linux-package=all`.

## Build and ABI

Commands run locally (default cap 6 GiB, no additional swap; two CPUs/jobs):

```bash
./tool/linux/build_in_container.sh
./tool/linux/build_in_container.sh --package-only --package=all
./tool/linux/build_in_container.sh --package=bundle
```

The final fresh build exited 0 and printed:

```text
✓ Built build/linux/x64/release/bundle/navis
navis maximum GLIBC: 2.34
```

The first attempt failed on worktree metadata outside the mount; source lists
now come from the host. A subsequent build caught a changelog enum typo, which
was corrected. During the first successful build, edits to the still-running
wrapper caused an extra shell command error after packaging; the subsequent
package-only run and fresh build both exited 0. These failures are not counted
as passing builds.

Measured using `objdump -T` on the runner and each ELF library:

```text
navis: GLIBC_2.34
libflutter_linux_gtk.so: GLIBC_2.18
libmpv.so.2: GLIBC_2.35
libflutter_secure_storage_linux_plugin.so: GLIBC_2.32
libmedia_kit_libs_linux_plugin.so: GLIBC_2.2.5
libscreen_retriever_linux_plugin.so: GLIBC_2.2.5
liburl_launcher_linux_plugin.so: GLIBC_2.2.5
libwindow_manager_plugin.so: GLIBC_2.2.5
libsqlite3.so: GLIBC_2.34
Bundle maximum GLIBC: 2.35
```

`file` identifies `navis`, `libapp.so` and `libmpv.so.2` as stripped ELF
objects. AOT split symbols are at `build/obfuscation/linux/v1.5.0/` and are
absent from the packages. Libmpv remains a separate shared library.
All ten ELF SHA-256 checks matched after the fresh rebuild. Every file in
the tar.gz and each installed `/opt/navis` package payload matches the final
bundle (49 files); the final tarball only differs from its earlier packaging
in archive metadata.

## Package installation

```bash
./tool/linux/verify_packages.sh v1.5.0
./tool/linux/verify_packages.sh v1.5.0 fedora:latest
```

Disposable containers are sequential and capped at 2 GiB, no extra swap,
and two CPUs. Ubuntu/Debian use `dpkg -i` followed by `apt-get -f install -y`;
missing dependencies at the first step are expected in bare images. Fedora
uses `dnf --setopt=zchunk=False install -y
/artifacts/navis-v1.5.0-linux-x86_64.rpm`. The default run completed Ubuntu
and Debian; Fedora completed the targeted retry with exit 0.

Ubuntu 22.04 and Debian 12 each printed:

```text
navis 1.5.0 install ok installed
ldd /opt/navis/navis | grep 'not found': (empty)
ldd /opt/navis/lib/*: no missing libraries
Exec=/usr/bin/navis %U
Icon=navis
desktop launcher and 512x512 icon: OK
unprivileged /opt/navis write access: denied (manual update fallback)
```

For library-only inspection, `LD_LIBRARY_PATH=/opt/navis/lib` reproduces
Flutter already being loaded by the runner. The initial enhanced check omitted
this and reported Flutter missing when checking a plugin in isolation; the
corrected checks passed on both Debian-family images. Runner `ldd` uses its
own RPATH without this override.

Fedora latest (Fedora 44) printed:

```text
Warning: skipped OpenPGP checks for 1 package from repository: @commandline
Complete!
navis-1.5.0-1.x86_64
ldd /opt/navis/navis | grep 'not found': (empty)
ldd /opt/navis/lib/*: no missing libraries
Exec=/usr/bin/navis %U
Icon=navis
desktop launcher and 512x512 icon: OK
unprivileged /opt/navis write access: denied (manual update fallback)
```

Fedora's initial mirror timed out fetching zchunk metadata. The retry uses
regular compressed metadata, preserving GPG checks for repository packages;
the locally generated RPM is unsigned, as the command's warning states.
The first RPM install passed linkage/desktop checks but the verifier then
failed because this minimal image has no `su`. Its retry verifies root
ownership and directory mode `0755` instead and exits 0. Fedora's `ldd`
warns about non-executable `.so` files; these ordinary shared-library modes
do not cause missing dependencies.

Image digests used:

```text
ubuntu:22.04 ubuntu@sha256:5ec03bb3441e8b0bf3b4f9cd4629a1ae763010dc3035bb8da3ae6cf026486401
debian:12 debian@sha256:2c037a04925515fdd6ea85ea14a682d0e79931f5e9f5d07b6dbfc6ba12f9e858
fedora:latest fedora@sha256:43b29f65a41eb9c35e1cd5323e3bdf3b655c2357a9f4f1ff2f9c2798e5045d80
```

## AUR and focused checks

A copy of the recipe in `build/linux/aur-test/` replaces only the source URL
with `file://` pointing at the locally built tarball. The final rerun uses a
2 GiB systemd scope, no swap:

```bash
makepkg --printsrcinfo > .SRCINFO
systemd-run --user --scope --quiet -p MemoryMax=2G -p MemorySwapMax=0 -- makepkg -f --nodeps
```

Exit 0; exact relevant output:

```text
==> Validating source files with sha256sums...
    navis-v1.5.0-linux.tar.gz ... Passed
==> Finished making: navis-bin 1.5.0-1 (Tue Oct 13 07:49:43 2026)
```

The recipe uses a real local-validation checksum, not `SKIP`. The owner must
refresh it against the final published release bytes before publishing to AUR.

```bash
flutter test --concurrency=4 --timeout 60s \
  test/src/features/changelog/changelog_data_test.dart \
  test/src/features/changelog/release_notes_markdown_test.dart \
  test/src/app_licenses_test.dart \
  test/src/architecture/update_installer_contract_test.dart
flutter analyze --no-fatal-infos lib/src/features/changelog/changelog_data.dart
./tool/scan_artifact_secret_test.sh
./tool/linux_desktop_entry_test.sh
```

```text
00:00 +26: All tests passed!
No issues found! (ran in 0.1s)
scan_artifact_secret_test: ok
linux_desktop_entry_test: ok
```

Shell syntax and `git diff --check` pass. The container wrapper rejects
`--no-obfuscate` before invoking Docker. Synthetic absent-key scans passed for
all three packages. Scanning a known text inside the real compressed RPM
payload found it as expected. R2 key mapping was inspected without invoking
publication:

```text
navis-v1.5.0-linux.tar.gz -> linuxPortable
navis-v1.5.0-linux-amd64.deb -> linuxDeb-amd64
navis-v1.5.0-linux-x86_64.rpm -> linuxRpm-x86_64
```

Final local artifact SHA-256 values:

```text
bec1107b4aacf4efe9ef613bf9b89b351c6374a3d8b06066942bb9c46c8d6a54  navis-v1.5.0-linux.tar.gz
c88256de7911a983270e3fc10d001e6d2d92ee1993fcdd8eea2b2ac9d2c17c34  navis-v1.5.0-linux-amd64.deb
bc7eb3810210da2b3e21f2c9784905e2c156b3b9177c301cd8f0bb960c515984  navis-v1.5.0-linux-x86_64.rpm
```

Complete local logs are in ignored `build/linux/validation/`: `build.log`,
`package.log`, `install-tests.log`, `makepkg.log`, `flutter-tests.log` and
`asset-scan.log`. SSH/Flatpak execution and GUI/playback runtime checks were
not run; package installation and ELF linkage are the evidence for this task.
