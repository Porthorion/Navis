#!/usr/bin/env bash
# Runs inside Dockerfile.windows; no target libraries come from distro packages.
set -euo pipefail

MPV_COMMIT=eb0ee1031590b3f369a5b783e8aa91eeaaded7e6
FFMPEG_COMMIT=151814650
LIBASS_VERSION=0.17.5
LIBPLACEBO_VERSION=v7.360.1
FREETYPE_VERSION=2.13.3
FRIBIDI_VERSION=1.0.16
HARFBUZZ_VERSION=10.2.0
ZLIB_VERSION=1.3.1
PREFIX=/opt/deps
TARGET=x86_64-w64-mingw32
JOBS="${JOBS:-6}"
ARTIFACT_DATE="${ARTIFACT_DATE:-$(date -u +%Y%m%d)}"
[[ "$ARTIFACT_DATE" =~ ^[0-9]{8}$ ]] || exit 1
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1791849600}"
export CC="${TARGET}-gcc-posix" CXX="${TARGET}-g++-posix"
export AR="${TARGET}-ar" RANLIB="${TARGET}-ranlib" STRIP="${TARGET}-strip"
export CFLAGS='-O2' CXXFLAGS='-O2' LDFLAGS='-static -static-libgcc -static-libstdc++'
export PKG_CONFIG_LIBDIR="${PREFIX}/lib/pkgconfig" PKG_CONFIG_PATH=
mkdir -p /src /out/src && cd /src

fetch() {
  local url="$1" archive="$2" digest="${3:-}"
  curl -fsSL --connect-timeout 30 --max-time 300 --retry 3 -o "$archive" "$url"
  if [[ -n "$digest" ]]; then echo "$digest  $archive" | sha256sum -c -; fi
  cp "$archive" /out/src/
}
fetch "https://github.com/FFmpeg/FFmpeg/archive/${FFMPEG_COMMIT}.tar.gz" "ffmpeg-${FFMPEG_COMMIT}.tar.gz" b2434397ae2b5f0bbc7f6a6072a31c610e4bd3b5f9d5e91b569615d3b49c46e7
fetch "https://github.com/mpv-player/mpv/archive/${MPV_COMMIT}.tar.gz" "mpv-${MPV_COMMIT}.tar.gz" 0fd93908f9c564cfe94e3f01adb7a4e0db1bef30a5475ce8a1e79af799670211
fetch "https://github.com/libass/libass/releases/download/${LIBASS_VERSION}/libass-${LIBASS_VERSION}.tar.xz" "libass-${LIBASS_VERSION}.tar.xz" 2dca25c0e0c837ddf00b52011b3f82cac1e4ddd3ad018227806b0c2288864acc
fetch "https://downloads.sourceforge.net/project/freetype/freetype2/${FREETYPE_VERSION}/freetype-${FREETYPE_VERSION}.tar.xz" "freetype-${FREETYPE_VERSION}.tar.xz" 0550350666d427c74daeb85d5ac7bb353acba5f76956395995311a9c6f063289
fetch "https://github.com/fribidi/fribidi/releases/download/v${FRIBIDI_VERSION}/fribidi-${FRIBIDI_VERSION}.tar.xz" "fribidi-${FRIBIDI_VERSION}.tar.xz" 1b1cde5b235d40479e91be2f0e88a309e3214c8ab470ec8a2744d82a5a9ea05c
fetch "https://github.com/harfbuzz/harfbuzz/releases/download/${HARFBUZZ_VERSION}/harfbuzz-${HARFBUZZ_VERSION}.tar.xz" "harfbuzz-${HARFBUZZ_VERSION}.tar.xz" 620e3468faec2ea8685d32c46a58469b850ef63040b3565cde05959825b48227
fetch "https://zlib.net/fossils/zlib-${ZLIB_VERSION}.tar.gz" "zlib-${ZLIB_VERSION}.tar.gz" 9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23
# Release tarballs omit libplacebo's submodules. Capture the recursive checkout.
git clone --quiet --depth 1 --recurse-submodules --shallow-submodules \
  --branch "$LIBPLACEBO_VERSION" https://github.com/haasn/libplacebo.git "libplacebo-${LIBPLACEBO_VERSION}"
[[ "$(git -C "libplacebo-${LIBPLACEBO_VERSION}" rev-parse HEAD)" == cee9b076f2c63104ccfd497fa79c39a867293ec4 ]]
git -C "libplacebo-${LIBPLACEBO_VERSION}" rev-parse HEAD > /out/libplacebo-commit.txt
git -C "libplacebo-${LIBPLACEBO_VERSION}" submodule status --recursive > /out/libplacebo-submodules.txt
tar --sort=name --mtime="@$SOURCE_DATE_EPOCH" --owner=0 --group=0 --numeric-owner \
  --exclude=.git -cf - "libplacebo-${LIBPLACEBO_VERSION}" | gzip -n > "/out/src/libplacebo-${LIBPLACEBO_VERSION}.tar.gz"

cat > /cross.ini <<CROSS
[binaries]
c = '$CC'
cpp = '$CXX'
ar = '$AR'
strip = '$STRIP'
windres = '${TARGET}-windres'
dlltool = '${TARGET}-dlltool'
pkg-config = '/pkg-config-static'
[host_machine]
system = 'windows'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
[properties]
needs_exe_wrapper = true
[built-in options]
c_args = ['-O2']
cpp_args = ['-O2']
c_link_args = ['-static', '-static-libgcc', '-static-libstdc++']
cpp_link_args = ['-static', '-static-libgcc', '-static-libstdc++']
CROSS
# Meson must consume Libs.private for our static dependencies, never host .pc files.
printf '#!/bin/sh\nexec pkg-config --static "$@"\n' > /pkg-config-static
chmod +x /pkg-config-static

# zlib supplies HTTP deflate and mpv's compressed container support.
tar xf "zlib-${ZLIB_VERSION}.tar.gz"
(cd "zlib-${ZLIB_VERSION}" && CHOST="$TARGET" ./configure --prefix="$PREFIX" --static && make -j"$JOBS" && make install)
tar xf "freetype-${FREETYPE_VERSION}.tar.xz"
(cd "freetype-${FREETYPE_VERSION}" && ./configure --host="$TARGET" --prefix="$PREFIX" \
  --enable-static --disable-shared --with-zlib=yes --with-bzip2=no --with-png=no \
  --with-harfbuzz=no --with-brotli=no && make -j"$JOBS" && make install)
tar xf "fribidi-${FRIBIDI_VERSION}.tar.xz"
meson setup "fribidi-${FRIBIDI_VERSION}/build" "fribidi-${FRIBIDI_VERSION}" \
  --cross-file=/cross.ini --prefix="$PREFIX" --libdir=lib --default-library=static \
  --wrap-mode=nofallback -Ddocs=false -Dtests=false -Dbin=false
ninja -C "fribidi-${FRIBIDI_VERSION}/build" -j"$JOBS" install
tar xf "harfbuzz-${HARFBUZZ_VERSION}.tar.xz"
meson setup "harfbuzz-${HARFBUZZ_VERSION}/build" "harfbuzz-${HARFBUZZ_VERSION}" \
  --cross-file=/cross.ini --prefix="$PREFIX" --libdir=lib --default-library=static \
  --wrap-mode=nofallback -Dauto_features=disabled -Dfreetype=enabled \
  -Dtests=disabled -Dutilities=disabled -Ddocs=disabled
ninja -C "harfbuzz-${HARFBUZZ_VERSION}/build" -j"$JOBS" install
tar xf "libass-${LIBASS_VERSION}.tar.xz"
(cd "libass-${LIBASS_VERSION}" && ./configure --host="$TARGET" --prefix="$PREFIX" \
  --enable-static --disable-shared --disable-fontconfig --enable-directwrite \
  --disable-libunibreak && make -j"$JOBS" && make install)
meson setup "libplacebo-${LIBPLACEBO_VERSION}/build" "libplacebo-${LIBPLACEBO_VERSION}" \
  --cross-file=/cross.ini --prefix="$PREFIX" --libdir=lib --default-library=static \
  --wrap-mode=nofallback -Dauto_features=disabled \
  -Dvulkan=disabled -Dopengl=disabled -Dd3d11=disabled -Dglslang=disabled \
  -Dshaderc=disabled -Dlcms=disabled -Ddemos=false -Dtests=false
ninja -C "libplacebo-${LIBPLACEBO_VERSION}/build" -j"$JOBS" install

# Native audio decoders only. MPEG-TS is retained for HLS; native AES/crypto
# permits encrypted HLS. No optional target dependency is autodetected.
tar xf "ffmpeg-${FFMPEG_COMMIT}.tar.gz"
cd FFmpeg-*/
ffmpeg_flags=(
  --prefix="$PREFIX" --target-os=mingw32 --arch=x86_64 --enable-cross-compile
  --cross-prefix="${TARGET}-" --cc="$CC" --cxx="$CXX" --pkg-config=/pkg-config-static
  --enable-static --disable-shared --disable-programs --disable-doc --disable-debug
  --disable-autodetect --disable-everything --disable-avdevice --disable-hwaccels
  --enable-network --enable-schannel --enable-zlib --enable-avfilter
  --enable-decoder=mp3,mp3float,mp3adu,mp3adufloat,mp3on4,mp3on4float,aac,aac_fixed,aac_latm,flac,alac,opus,vorbis,ac3,eac3,mp1,mp1float,mp2,mp2float
  --enable-decoder=pcm_alaw,pcm_mulaw,pcm_s8,pcm_u8,pcm_s16le,pcm_s16be,pcm_u16le,pcm_u16be,pcm_s24le,pcm_s24be,pcm_u24le,pcm_u24be,pcm_s32le,pcm_s32be,pcm_u32le,pcm_u32be,pcm_s64le,pcm_s64be,pcm_f16le,pcm_f24le,pcm_f32le,pcm_f32be,pcm_f64le,pcm_f64be,pcm_s24daud,pcm_bluray,pcm_dvd,pcm_lxf,pcm_s16le_planar,pcm_s24le_planar,pcm_s32le_planar,pcm_s16be_planar,pcm_s8_planar
  --enable-demuxer=mp3,aac,flac,mov,ogg,matroska,wav,hls,mpegts,ac3,eac3,aiff,ape,asf,au,concat,data
  --enable-parser=mpegaudio,aac,aac_latm,flac,opus,vorbis,ac3
  --enable-protocol=file,http,https,tcp,tls,udp,rtp,crypto,data,concat,concatf,hls,httpproxy
  --enable-filter=volume,biquad,equalizer,atempo,aformat,aresample,anull,anullsrc,abuffer,abuffersink,asplit,amix,pan,atrim,asetpts,afade
  --extra-cflags="-I$PREFIX/include" --extra-ldflags="-L$PREFIX/lib -static -static-libgcc -static-libstdc++"
)
./configure "${ffmpeg_flags[@]}"
printf '%q ' "${ffmpeg_flags[@]}" > /out/FFMPEG-CONFIGURE.txt
printf '\n' >> /out/FFMPEG-CONFIGURE.txt
make -j"$JOBS" && make install
cp config_components.h /out/FFMPEG-COMPONENTS.txt
for filter in VOLUME EQUALIZER BIQUAD ATEMPO ARESAMPLE AFORMAT; do
  grep -Fx "#define CONFIG_${filter}_FILTER 1" config_components.h
  "$TARGET-nm" "$PREFIX/lib/libavfilter.a" | grep "ff_af_${filter,,}$" > /dev/null
done
cd /src

tar xf "mpv-${MPV_COMMIT}.tar.gz"
mpv_flags=(
  --cross-file=/cross.ini --prefix=/opt/mpv --libdir=lib --buildtype=release
  --wrap-mode=nofallback -Dauto_features=disabled -Dgpl=false -Dlibmpv=true
  -Dcplayer=false -Ddefault_library=shared -Dwasapi=enabled -Dwin32-threads=enabled
  -Dzlib=enabled -Dlua=disabled -Djavascript=disabled -Dlibarchive=disabled
  -Dlibbluray=disabled -Ddvdnav=disabled -Ddvda=disabled -Drubberband=disabled
  -Duchardet=disabled -Dlcms2=disabled -Dvapoursynth=disabled -Dzimg=disabled
  -Dcdda=disabled -Ddvbin=disabled -Dlibcurl=disabled -Dcplugins=disabled
  -Dx11=disabled -Dwayland=disabled -Dgl=disabled -Degl=disabled -Dvulkan=disabled
  -Dd3d11=disabled -Ddirect3d=disabled -Dd3d-hwaccel=disabled -Dd3d9-hwaccel=disabled
  -Dvaapi=disabled -Dvdpau=disabled -Ddrm=disabled -Dgbm=disabled
  -Dsdl2-video=disabled -Dcaca=disabled -Dsixel=disabled -Djpeg=disabled
  -Dlibavdevice=disabled -Dalsa=disabled -Dpulse=disabled -Dpipewire=disabled
  -Dopenal=disabled -Djack=disabled -Dsdl2-audio=disabled -Doss-audio=disabled
  -Dsndio=disabled -Dwin32-smtc=disabled -Dmanpage-build=disabled
  -Dhtml-build=disabled -Dpdf-build=disabled
  '-Dc_link_args=-static -static-libgcc -static-libstdc++ -lstdc++'
)
meson setup "mpv-${MPV_COMMIT}/build" "mpv-${MPV_COMMIT}" "${mpv_flags[@]}"
ninja -C "mpv-${MPV_COMMIT}/build" -j"$JOBS" install
cp /opt/mpv/bin/libmpv-2.dll /out/libmpv-2.dll
"$STRIP" --strip-unneeded /out/libmpv-2.dll
mkdir -p /out/include/mpv
cp /opt/mpv/include/mpv/*.h /out/include/mpv/
cp /opt/mpv/lib/libmpv.dll.a /out/libmpv.dll.a

# A bounded Windows-ABI smoke under Wine checks the DLL itself and Navis's
# combined filters, without requiring audio hardware or a graphical session.
cat > /out/verify_windows.c <<'C'
#include <mpv/client.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
static void check(int status) {
    if (status < 0) { fprintf(stderr, "mpv: %s\n", mpv_error_string(status)); exit(1); }
}
int main(void) {
    mpv_handle *mpv = mpv_create();
    if (!mpv) return 1;
    check(mpv_set_option_string(mpv, "vo", "null"));
    check(mpv_set_option_string(mpv, "vid", "no"));
    check(mpv_set_option_string(mpv, "ao", "null"));
    check(mpv_set_option_string(mpv, "audio-pitch-correction", "no"));
    check(mpv_set_option_string(mpv, "af", "@navis_tempo:scaletempo:scale=1.25,@navis_eq:lavfi=[volume=-3dB:precision=double,biquad=b0=1:b1=0:b2=0:a0=1:a1=0:a2=0:precision=f64:transform=tdii,equalizer=f=1000:t=q:w=1:g=1]"));
    check(mpv_initialize(mpv));
    const char *load[] = {"loadfile", "Z:/out/verify-tone.wav", NULL};
    check(mpv_command(mpv, load));
    int ready = 0;
    for (int i = 0; i < 100; ++i) {
        mpv_event *event = mpv_wait_event(mpv, 0.1);
        if (event->event_id == MPV_EVENT_END_FILE) {
            fprintf(stderr, "Unexpected end before playback\n"); return 1;
        }
        double position = 0;
        if (mpv_get_property(mpv, "time-pos", MPV_FORMAT_DOUBLE, &position) >= 0 && position > 0.2) { ready = 1; break; }
    }
    if (!ready) { fprintf(stderr, "Filtered playback did not advance\n"); return 1; }
    const char *seek[] = {"seek", "2", "absolute+exact", NULL};
    check(mpv_command(mpv, seek));
    ready = 0;
    for (int i = 0; i < 100; ++i) {
        mpv_wait_event(mpv, 0.1);
        double position = 0;
        if (mpv_get_property(mpv, "time-pos", MPV_FORMAT_DOUBLE, &position) >= 0 && position >= 2) { ready = 1; break; }
    }
    mpv_terminate_destroy(mpv);
    if (!ready) { fprintf(stderr, "Seek did not settle\n"); return 1; }
    puts("Windows DLL smoke passed: init, WAV decode, scaletempo/volume/biquad/equalizer, advancing playback and seek.");
    return 0;
}
C
python3 - <<'PY'
import math, struct, wave
with wave.open('/out/verify-tone.wav', 'wb') as audio:
    audio.setparams((1, 2, 48000, 0, 'NONE', 'not compressed'))
    audio.writeframes(b''.join(struct.pack('<h', int(5000 * math.sin(2 * math.pi * 440 * i / 48000))) for i in range(480000)))
PY
"$CC" -O2 /out/verify_windows.c -I/out/include /out/libmpv.dll.a \
  -static -static-libgcc -o /out/verify-windows.exe
if ! WINEDEBUG=-all WINEPREFIX=/tmp/navis-wmpv-wine timeout 60 \
  /usr/lib/wine/wine64 /out/verify-windows.exe > /out/WINDOWS-SMOKE.txt 2>&1; then
  cat /out/WINDOWS-SMOKE.txt >&2
  exit 1
fi
cat /out/WINDOWS-SMOKE.txt
rm /out/verify-tone.wav /out/verify-windows.exe

strings /out/libmpv-2.dll > /tmp/libmpv-strings.txt
if grep -E -- '--enable-(gpl|nonfree)' /tmp/libmpv-strings.txt > /dev/null; then
  echo 'Forbidden FFmpeg licence configuration' >&2; exit 1
fi
grep -F -- '-Dgpl=false' /tmp/libmpv-strings.txt > /dev/null
python3 - "mpv-${MPV_COMMIT}/build" <<'PY'
import json, subprocess, sys
options = json.loads(subprocess.check_output(['meson', 'introspect', '--buildoptions', sys.argv[1]]))
assert next(x['value'] for x in options if x['name'] == 'gpl') is False
PY
"$TARGET-objdump" -p /out/libmpv-2.dll | awk '/DLL Name:/ {print $3}' | sort -fu > /out/IMPORTED-DLLS.txt
# Explicit allowlist: the produced engine must have no redistributable DLLs.
while IFS= read -r dll; do
  case "${dll,,}" in
    advapi32.dll|avrt.dll|dwmapi.dll|imm32.dll|pathcch.dll|shcore.dll|uxtheme.dll|api-ms-win-core-path-l1-1-0.dll|bcrypt.dll|crypt32.dll|dwrite.dll|gdi32.dll|kernel32.dll|msvcrt.dll|ncrypt.dll|ntdll.dll|ole32.dll|oleaut32.dll|secur32.dll|shell32.dll|shlwapi.dll|ucrtbase.dll|user32.dll|uuid.dll|version.dll|winmm.dll|ws2_32.dll) ;;
    *) echo "Non-system DLL import: $dll" >&2; exit 1 ;;
  esac
done < /out/IMPORTED-DLLS.txt
{
  echo "Navis Windows x86_64 LGPL libmpv ($ARTIFACT_DATE)"
  echo "mpv $MPV_COMMIT (-Dgpl=false)"
  echo "FFmpeg $FFMPEG_COMMIT (LGPL-2.1-or-later; Schannel TLS)"
  echo "libass $LIBASS_VERSION; libplacebo $LIBPLACEBO_VERSION"
  echo "FreeType $FREETYPE_VERSION; FriBidi $FRIBIDI_VERSION; HarfBuzz $HARFBUZZ_VERSION; zlib $ZLIB_VERSION"
  echo "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH; JOBS=$JOBS"
  echo 'Base: ubuntu:24.04@sha256:f610ab94648195aa356059f5b41d6085c9d4d903c072430cdd1af7bdb646106b'
  echo; echo 'Toolchain (runtime libraries linked statically):'
  "$CC" --version
  dpkg-query -W gcc-mingw-w64-x86-64-posix g++-mingw-w64-x86-64-posix mingw-w64-common mingw-w64-x86-64-dev binutils-mingw-w64-x86-64
  echo "libgcc: $("$CC" -print-libgcc-file-name)"
  echo "libstdc++: $("$CXX" -print-file-name=libstdc++.a)"
  echo "winpthreads: $("$CC" -print-file-name=libwinpthread.a)"
  echo; echo 'FFmpeg configure flags:'; cat /out/FFMPEG-CONFIGURE.txt
  echo; echo 'mpv meson flags:'; printf '%q ' "${mpv_flags[@]}"; echo
  echo; echo 'Imported Windows system DLLs:'; cat /out/IMPORTED-DLLS.txt
  echo; echo 'Windows ABI smoke (Wine, null audio output):'; cat /out/WINDOWS-SMOKE.txt
  echo; echo 'libplacebo commit and recursive submodules:'
  cat /out/libplacebo-commit.txt /out/libplacebo-submodules.txt
  echo; echo 'Verified: no --enable-gpl/--enable-nonfree strings; mpv gpl=false; compiled volume/equalizer/biquad/atempo/aresample/aformat filters.'
} > /out/BUILDINFO.txt
cp /Dockerfile.windows /out/Dockerfile.windows
cp /build.sh /out/build_windows_lgpl.sh
cp /cross.ini /out/cross.ini
archive="libmpv-windows-x86_64-lgpl-${ARTIFACT_DATE}.zip"
rm -f "/out/$archive"
(cd /out && zip -X "$archive" libmpv-2.dll libmpv.dll.a include/mpv/*.h BUILDINFO.txt Dockerfile.windows build_windows_lgpl.sh cross.ini)
(cd /out && sha256sum "$archive" libmpv-2.dll src/* > SHA256SUMS)
{
  echo "# Navis Windows LGPL libmpv ($ARTIFACT_DATE)"
  echo
  echo "\`$archive\` is Navis's audio-only x86_64 Windows playback engine."
  echo "Archive SHA-256: \`$(sha256sum "/out/$archive" | cut -d' ' -f1)\`."
  echo 'The DLL is replaceable and only imports Windows system DLLs. See BUILDINFO.txt for configuration, toolchain versions and imports.'
  echo
  echo '## Versions and licences'
  echo
  echo "- mpv $MPV_COMMIT: LGPL-2.1-or-later with gpl=false."
  echo "- FFmpeg $FFMPEG_COMMIT: LGPL-2.1-or-later; no GPL or nonfree options, Schannel TLS."
  echo "- libass $LIBASS_VERSION: ISC."
  echo "- libplacebo $LIBPLACEBO_VERSION: LGPL-2.1-or-later; includes FastFloat (MIT/Apache-2.0/Boost alternatives), glad (MIT generator; Khronos headers), Vulkan-Headers (Apache-2.0/MIT), Jinja and MarkupSafe (BSD-3-Clause), and Nuklear (MIT/public-domain alternatives) source submodules, even though GPU backends are disabled."
  echo "- FreeType $FREETYPE_VERSION: FreeType License (FTL), selected instead of its GPL alternative."
  echo "- FriBidi $FRIBIDI_VERSION: LGPL-2.1-or-later."
  echo "- HarfBuzz $HARFBUZZ_VERSION: MIT-style Old MIT licence; see COPYING."
  echo "- zlib $ZLIB_VERSION: Zlib."
  echo '- mingw-w64 CRT and winpthreads: permissive licences; GCC libgcc/libstdc++: GPL with GCC Runtime Library Exception. Toolchain versions are in BUILDINFO.txt. No other distro target libraries are linked.'
  echo
  echo '## Corresponding source in this folder'
  echo
  echo 'All source archives listed below are in this folder (upload the contents of src/ alongside SOURCES.md). Original licence/copyright texts are retained in each archive. libplacebo includes recursive submodule sources. The binary ZIP includes the Dockerfile and build script; BUILDINFO.txt, configuration/component lists and submodule provenance also accompany it.'
  echo
  echo '| Source archive | SHA-256 |'
  echo '|---|---|'
  for source in /out/src/*; do printf '| `%s` | `%s` |\n' "${source##*/}" "$(sha256sum "$source" | cut -d' ' -f1)"; done
  echo
  echo 'Source URLs and pinned release digests are recorded in build_windows_lgpl.sh; libplacebo is captured from https://github.com/haasn/libplacebo with its recursive submodules at the commit in BUILDINFO.txt.'
  echo
  echo '## Rebuild'
  echo
  echo 'On an x86_64 Linux host, put Dockerfile.windows and build_windows_lgpl.sh in the same directory and run:'
  echo '```bash'
  echo 'docker build -f Dockerfile.windows -t navis-libmpv-windows-lgpl .'
  echo "docker run --rm -e JOBS=6 -e ARTIFACT_DATE=$ARTIFACT_DATE -v \"\$PWD/out:/out\" navis-libmpv-windows-lgpl"
  echo '```'
  echo 'The recipe downloads pinned sources, builds static dependencies and a stripped shared libmpv-2.dll, verifies licence configuration, required filters and system-only imports, and packages a CMake-extractable ZIP. Ubuntu package repositories are not snapshot-pinned, so toolchain updates can change the binary hash; inspect BUILDINFO.txt when rebuilding. Preserve this folder and its sources for users of this build.'
} > /out/SOURCES.md
printf 'Built /out/%s\n' "$archive"
