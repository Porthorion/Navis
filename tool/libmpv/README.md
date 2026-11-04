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
See [the Linux release guide](../../docs/release/release-linux.md) for the current pin,
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
[the release guide](../../docs/release/release-windows.md#bundled-libmpv).
The build does not upload or publish anything. Ubuntu packages are not
snapshot-pinned, so compare BUILDINFO on rebuilds; equal hashes are not promised
across toolchain updates. Remove only task-owned Docker images and build caches.

## macOS

`build_macos_lgpl.sh` builds an audio-only universal (arm64 + x86_64)
`Mpv.xcframework` natively on a Mac, with the same mpv and FFmpeg commits as
Linux and Windows (`eb0ee1031590b3f369a5b783e8aa91eeaaded7e6` and `151814650`)
and the same static libass, libplacebo (with submodules), FreeType, FriBidi and
HarfBuzz versions and source digests as Windows. FFmpeg keeps the Windows audio
component set (native decoders, MP4/Ogg/Matroska/WAV demuxers, HLS/MPEG-TS, ICY
HTTP, filters `volume`, `biquad`, `equalizer`, `atempo`, `aresample`, format
conversion) but uses Apple's SecureTransport for TLS, so HTTPS streams are
verified against the macOS system trust store with no bundled CA file or TLS
library. mpv is `-Dgpl=false`, libmpv only, CoreAudio output, no video or
Cocoa. `patches/mpv-macos-coreaudio-channelmap.patch` is the only source
change: the pinned mpv commit sets the AUHAL ChannelMap property from an
AudioChannelLayout, which current macOS rejects (error -50, so no sound);
mpv master removed that call and so does the patch. mpv's own
`osdep/utils-mac.c`, which the CoreAudio output needs but
mpv's meson only builds with Cocoa, is compiled separately (unmodified) and
linked in; the script fails if any symbol is left to dynamic lookup, which
would otherwise crash at the first CoreAudio call. zlib is the macOS system
library. Nothing from Homebrew or MacPorts is
linked: `nasm` is the only build tool beyond Xcode, git, curl and python3
(meson and jinja2 are installed into a private venv), and the script fails if
`otool -L` shows any library outside `/usr/lib` and `/System/Library/Frameworks`.
The deployment target is 12.0, the same as `macos/Podfile` and the Runner.

```bash
df -h /                        # needs a few GB: one architecture is built at a time
tool/libmpv/build_macos_lgpl.sh
```

Defaults: scratch in `~/Library/Caches/navis-libmpv-build` (`WORK`, outside the
repository; downloaded sources are cached in `src/`, each architecture's build
tree is deleted once its stripped dylib is staged), output in
`$WORK/out/libmpv-macos-universal-lgpl-<date>/` (`OUT`, `ARTIFACT_DATE`). The
script verifies that FFmpeg's `config.h` has SecureTransport and neither GPL nor
nonfree, that the filters are compiled in, that the binary strings carry mpv's
`-Dgpl=false` and FFmpeg's LGPL line, the deployment target of both slices and
the system-only linkage and no dynamic-lookup symbols, then runs a native playback smoke on both slices
(arm64, and x86_64 under Rosetta), once with the null and once with the real
CoreAudio output at volume 0 (`SKIP_COREAUDIO_SMOKE=1` on a host without audio),
with the app's `scaletempo` + `volume` + `biquad` + `equalizer` chain and an
exact seek. Output: the tarball
`libmpv-macos-universal-lgpl-<date>.tar.gz` (`Mpv.xcframework`, BUILDINFO.txt,
the build script, FFmpeg configure flags and component list), `SOURCES.md`,
`BUILDINFO.txt`, `SHA256SUMS` and every source archive in `src/`.

To publish a build, the release operator uploads the tarball, `SOURCES.md`,
`BUILDINFO.txt`, `patches/` and the contents of `src/` together to
`navis/third-party/libmpv-macos-universal-lgpl-<date>/` on R2, with no flat
copy, and keeps older folders. The vendored package
`third_party/media_kit_libs_macos_audio/macos/fetch_libmpv.sh` pins the
tarball name, that URL and its SHA-256; update all three, and the SOURCES.md
URL in `assets/licenses/libmpv-macos-NOTICE.txt` plus its test, for a new build.
Until the upload exists (or to test a rebuild), point the pod install at the
local file, whose SHA-256 must still equal the pin:

```bash
NAVIS_LIBMPV_MACOS_ARCHIVE="$HOME/Library/Caches/navis-libmpv-build/out/libmpv-macos-universal-lgpl-<date>/libmpv-macos-universal-lgpl-<date>.tar.gz" \
  flutter build macos --profile
```

The build does not upload or publish anything. Xcode/SDK versions are not
pinned: compare BUILDINFO on rebuilds, since equal hashes are not promised.
Remove `$WORK` (except `out/` and `src/` until the upload is done) afterwards.
