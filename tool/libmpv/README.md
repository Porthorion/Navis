# Navis LGPL libmpv recipes

## Linux

This Ubuntu 22.04 x86_64 recipe builds an audio-only LGPL-2.1+ `libmpv.so.2`
for Navis's Linux bundle. It pins mpv and FFmpeg in `build_linux_lgpl.sh`,
links FFmpeg, libass and libplacebo statically, and keeps desktop system
libraries dynamic. FFmpeg's libavfilter includes the equalizer filters.

From the repository root:

```bash
docker build -t navis-libmpv-lgpl tool/libmpv
docker run --rm -v "$PWD/out:/out" navis-libmpv-lgpl
```

Use an x86_64 host. The build needs network access and writes `libmpv.so.2`,
`include/`, `BUILDINFO.txt`, `Dockerfile`, `build.sh`, source archives under
`src/`, and `SHA256SUMS` to `out/`. `BUILDINFO.txt` records versions and ELF
`NEEDED` libraries. The script rejects FFmpeg `--enable-gpl`/`--enable-nonfree`
strings and requires mpv's embedded `-Dgpl=false` configuration. These checks
consume the complete strings output so shell pipe failures cannot hide a match.
Review source licences and configurations when changing pins; string checks
alone do not establish the licence of every dependency.

Package the binary and recipe with this layout (keep source archives separate):

```bash
mkdir -p out/libmpv-linux-x86_64-lgpl
cp -r out/libmpv.so.2 out/include out/BUILDINFO.txt out/Dockerfile out/build.sh \
  out/libmpv-linux-x86_64-lgpl/
artifact_date=$(date -u +%Y%m%d)
tar -czf "out/libmpv-linux-x86_64-lgpl-${artifact_date}.tar.gz" \
  -C out libmpv-linux-x86_64-lgpl
sha256sum "out/libmpv-linux-x86_64-lgpl-${artifact_date}.tar.gz"
```

Upload to R2 at `navis/third-party/libmpv-linux-x86_64-lgpl-<date>/` that tarball, `SOURCES.md` (versions, source URLs, SHA-256, LGPL configuration
and licence inventory), and every corresponding archive from `out/src/`,
including mpv, FFmpeg, libass and libplacebo with submodules. Preserve older
folders. Upload only into the per-build folder, with no flat copy. Verify the
tarball at `https://downloads.porthorion.com/navis/third-party/libmpv-linux-x86_64-lgpl-<date>/<tarball-name>`.
Update the filename, ordered URLs and SHA-256 in `linux/CMakeLists.txt`, plus
the in-app source location in `assets/licenses/libmpv-ffmpeg-NOTICE.txt`.
See [the Linux release guide](../../docs/release-linux.md) for the current pin,
runtime dependencies and packaging validation.

## Windows

`Dockerfile.windows` and `build_windows_lgpl.sh` cross-build an audio-only
x86_64 `libmpv-2.dll` on digest-pinned Ubuntu 24.04 with mingw-w64. The mpv
and FFmpeg commits match Linux: `eb0ee1031590b3f369a5b783e8aa91eeaaded7e6`
and `151814650`. Static dependencies are libass 0.17.5, libplacebo v7.360.1
(with recursive submodules), FreeType 2.13.3, FriBidi 1.0.16, HarfBuzz 10.2.0
and zlib 1.3.1. Every dependency's source is captured under `out/src/`;
no distro mingw target libraries are used except the toolchain runtime,
winpthreads and GCC exception-covered runtimes, whose versions are recorded.

```bash
artifact_date=$(date -u +%Y%m%d)
output="$PWD/out/libmpv-windows-x86_64-lgpl-${artifact_date}"
mkdir -p "$output"
docker build --force-rm -f tool/libmpv/Dockerfile.windows \
  -t navis-libmpv-windows-lgpl tool/libmpv
docker run --rm -e JOBS=6 -e ARTIFACT_DATE="$artifact_date" \
  -v "$output:/out" navis-libmpv-windows-lgpl
sha256sum "$output/libmpv-windows-x86_64-lgpl-${artifact_date}.zip"
docker image rm navis-libmpv-windows-lgpl
```

The output ZIP has `libmpv-2.dll`, `libmpv.dll.a` and `include/mpv/*.h` at
its root, plus the recipe and BUILDINFO. CMake's libarchive extraction supports
ZIP. Output also includes `SOURCES.md`, `SHA256SUMS`, the sources, FFmpeg
configuration/component lists and the imported-DLL inventory. FFmpeg keeps
native audio codecs, MP4/Ogg/Matroska/WAV demuxers, HLS/MPEG-TS, ICY HTTP,
Schannel HTTPS and encrypted HLS. No GPL/nonfree codecs or video hardware
backends are enabled. The app's EQ chain requires FFmpeg `volume` and
`biquad`; tempo uses mpv's internal `scaletempo`. `equalizer`, `atempo`,
format conversion and resampling are also retained. The recipe verifies
compiled filters, mpv `gpl=false`, licence configuration strings, and a
system-DLL allowlist; it links winpthreads/libgcc/libstdc++ statically.
WASAPI is the only enabled platform audio output; built-in null/PCM outputs
remain available. Font lookup uses DirectWrite, with no fontconfig.

To publish a build, the release operator places the ZIP, `SOURCES.md`,
`BUILDINFO.txt`, supporting output files and every archive from `src/` together
at `navis/third-party/libmpv-windows-x86_64-lgpl-<date>/` on R2. Source links
use files in this folder, with no flat copy. Keep older folders. Update the
Windows vendored CMake filename, its sole R2 URL and SHA-256, plus the Windows
line in `assets/licenses/libmpv-ffmpeg-NOTICE.txt` and its licence test.
Run the offline download checks for both platforms and the licence/changelog
tests; validate real playback on Windows as described in
[the release guide](../../docs/release-windows.md#bundled-libmpv).
The build does not upload or publish anything. Ubuntu packages are not
snapshot-pinned, so compare BUILDINFO on rebuilds; equal hashes are not promised
across toolchain updates. Remove only task-owned Docker images and build caches.
