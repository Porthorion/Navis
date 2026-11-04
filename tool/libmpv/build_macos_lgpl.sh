#!/usr/bin/env bash
# Builds Navis's audio-only LGPL libmpv for macOS (universal arm64 + x86_64)
# natively on a Mac. Everything media-related is linked statically into one
# Mpv.framework; the only dynamic dependencies are macOS system libraries.
# Homebrew/MacPorts tools (nasm) are build tools only: PKG_CONFIG_LIBDIR is
# confined to the per-arch prefix and the result is checked with otool -L.
#
#   tool/libmpv/build_macos_lgpl.sh            # output: $OUT (see below)
#   REUSE_STAGE=1 tool/libmpv/build_macos_lgpl.sh   # skip arches already staged
#
# Env: ARTIFACT_DATE (YYYYMMDD), JOBS, WORK (scratch, default
# ~/Library/Caches/navis-libmpv-build), BUILD_BASE (per-arch build trees,
# default /private/tmp/navis-libmpv-build: outside $HOME so mpv's and FFmpeg's
# compiled-in configuration strings carry no home path), OUT, MACOS_MIN
# (default 12.0, must match macos/Podfile and the Runner target).
set -Eeuo pipefail

MPV_COMMIT=eb0ee1031590b3f369a5b783e8aa91eeaaded7e6
FFMPEG_COMMIT=151814650
LIBASS_VERSION=0.17.5
LIBPLACEBO_VERSION=v7.360.1
FREETYPE_VERSION=2.13.3
FRIBIDI_VERSION=1.0.16
HARFBUZZ_VERSION=10.2.0
MESON_VERSION=1.6.1
JINJA2_VERSION=3.1.4
MACOS_MIN="${MACOS_MIN:-12.0}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
ARTIFACT_DATE="${ARTIFACT_DATE:-$(date -u +%Y%m%d)}"
[[ "$ARTIFACT_DATE" =~ ^[0-9]{8}$ ]] || { echo 'ARTIFACT_DATE must be YYYYMMDD' >&2; exit 1; }
WORK="${WORK:-$HOME/Library/Caches/navis-libmpv-build}"
NAME="libmpv-macos-universal-lgpl-${ARTIFACT_DATE}"
OUT="${OUT:-$WORK/out/$NAME}"
BUILD_BASE="${BUILD_BASE:-/private/tmp/navis-libmpv-build}"
# Compilers record source paths (__FILE__, debug info); map the build root to
# a neutral one.
PREFIX_MAP="-ffile-prefix-map=$BUILD_BASE=/navis-build -fdebug-prefix-map=$BUILD_BASE=/navis-build"
SCRIPT="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
PATCH_DIR="$(dirname "$SCRIPT")/patches"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1791849600}"
export MACOSX_DEPLOYMENT_TARGET="$MACOS_MIN"

# System tools first so MacPorts/Homebrew binutils never shadow Apple's.
VENV="$WORK/venv"
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$VENV/bin:/opt/local/bin:/opt/homebrew/bin"
for tool in nasm python3 git curl; do
  command -v "$tool" > /dev/null || { echo "Missing build tool: $tool" >&2; exit 1; }
done
free_kb=$(df -k "$WORK" 2> /dev/null | awk 'NR==2 {print $4}' || true)
if [[ -n "${free_kb:-}" && "$free_kb" -lt 3145728 ]]; then
  echo "Less than 3 GB free for $WORK; refusing to build." >&2; exit 1
fi

mkdir -p "$WORK/src" "$OUT/src" "$WORK/stage" "$BUILD_BASE"
# Quiet step output goes here; the tail is shown if a step fails.
STEPS="$WORK/steps.log"; : > "$STEPS"
trap 'tail -60 "$STEPS" >&2' ERR
if [[ ! -x "$VENV/bin/meson" ]]; then
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet --no-cache-dir "meson==$MESON_VERSION" "jinja2==$JINJA2_VERSION"
fi

# ---------------------------------------------------------------- sources
sha_of() { shasum -a 256 "$1" | cut -d' ' -f1; }
fetch() {
  local url="$1" archive="$2" digest="${3:-}"
  if [[ ! -f "$WORK/src/$archive" ]]; then
    curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 30 --max-time 600 --retry 3 -o "$WORK/src/$archive.tmp" "$url"
    mv "$WORK/src/$archive.tmp" "$WORK/src/$archive"
  fi
  if [[ -n "$digest" && "$(sha_of "$WORK/src/$archive")" != "$digest" ]]; then
    echo "SHA-256 mismatch for $archive" >&2; rm -f "$WORK/src/$archive"; exit 1
  fi
  cp "$WORK/src/$archive" "$OUT/src/"
}
# Same archives and digests as build_windows_lgpl.sh (zlib is the macOS system one).
fetch "https://github.com/FFmpeg/FFmpeg/archive/${FFMPEG_COMMIT}.tar.gz" "ffmpeg-${FFMPEG_COMMIT}.tar.gz" b2434397ae2b5f0bbc7f6a6072a31c610e4bd3b5f9d5e91b569615d3b49c46e7
fetch "https://github.com/mpv-player/mpv/archive/${MPV_COMMIT}.tar.gz" "mpv-${MPV_COMMIT}.tar.gz" 0fd93908f9c564cfe94e3f01adb7a4e0db1bef30a5475ce8a1e79af799670211
fetch "https://github.com/libass/libass/releases/download/${LIBASS_VERSION}/libass-${LIBASS_VERSION}.tar.xz" "libass-${LIBASS_VERSION}.tar.xz" 2dca25c0e0c837ddf00b52011b3f82cac1e4ddd3ad018227806b0c2288864acc
fetch "https://downloads.sourceforge.net/project/freetype/freetype2/${FREETYPE_VERSION}/freetype-${FREETYPE_VERSION}.tar.xz" "freetype-${FREETYPE_VERSION}.tar.xz" 0550350666d427c74daeb85d5ac7bb353acba5f76956395995311a9c6f063289
fetch "https://github.com/fribidi/fribidi/releases/download/v${FRIBIDI_VERSION}/fribidi-${FRIBIDI_VERSION}.tar.xz" "fribidi-${FRIBIDI_VERSION}.tar.xz" 1b1cde5b235d40479e91be2f0e88a309e3214c8ab470ec8a2744d82a5a9ea05c
fetch "https://github.com/harfbuzz/harfbuzz/releases/download/${HARFBUZZ_VERSION}/harfbuzz-${HARFBUZZ_VERSION}.tar.xz" "harfbuzz-${HARFBUZZ_VERSION}.tar.xz" 620e3468faec2ea8685d32c46a58469b850ef63040b3565cde05959825b48227
# Release tarballs omit libplacebo's submodules; capture the recursive checkout.
PLACEBO_ARCHIVE="libplacebo-${LIBPLACEBO_VERSION}.tar.gz"
if [[ ! -f "$WORK/src/$PLACEBO_ARCHIVE" ]]; then
  rm -rf "$WORK/src/libplacebo-${LIBPLACEBO_VERSION}"
  git clone --quiet --depth 1 --recurse-submodules --shallow-submodules \
    --branch "$LIBPLACEBO_VERSION" https://github.com/haasn/libplacebo.git "$WORK/src/libplacebo-${LIBPLACEBO_VERSION}"
  [[ "$(git -C "$WORK/src/libplacebo-${LIBPLACEBO_VERSION}" rev-parse HEAD)" == cee9b076f2c63104ccfd497fa79c39a867293ec4 ]]
  git -C "$WORK/src/libplacebo-${LIBPLACEBO_VERSION}" rev-parse HEAD > "$WORK/src/libplacebo-commit.txt"
  git -C "$WORK/src/libplacebo-${LIBPLACEBO_VERSION}" submodule status --recursive > "$WORK/src/libplacebo-submodules.txt"
  tar --exclude=.git -C "$WORK/src" -czf "$WORK/src/$PLACEBO_ARCHIVE" "libplacebo-${LIBPLACEBO_VERSION}"
  rm -rf "$WORK/src/libplacebo-${LIBPLACEBO_VERSION}"
fi
cp "$WORK/src/$PLACEBO_ARCHIVE" "$OUT/src/"
cp "$WORK/src/libplacebo-commit.txt" "$WORK/src/libplacebo-submodules.txt" "$OUT/"

# ------------------------------------------------------------ per-arch build
# Components shared by every arch are recorded from the first one built.
FFMPEG_FLAGS_COMMON=(
  --enable-static --disable-shared --enable-pic --disable-programs --disable-doc
  --disable-debug --disable-autodetect --disable-everything --disable-avdevice
  --disable-hwaccels --enable-network --enable-securetransport --enable-zlib
  --enable-avfilter
  --enable-decoder=mp3,mp3float,mp3adu,mp3adufloat,mp3on4,mp3on4float,aac,aac_fixed,aac_latm,flac,alac,opus,vorbis,ac3,eac3,mp1,mp1float,mp2,mp2float
  --enable-decoder=pcm_alaw,pcm_mulaw,pcm_s8,pcm_u8,pcm_s16le,pcm_s16be,pcm_u16le,pcm_u16be,pcm_s24le,pcm_s24be,pcm_u24le,pcm_u24be,pcm_s32le,pcm_s32be,pcm_u32le,pcm_u32be,pcm_s64le,pcm_s64be,pcm_f16le,pcm_f24le,pcm_f32le,pcm_f32be,pcm_f64le,pcm_f64be,pcm_s24daud,pcm_bluray,pcm_dvd,pcm_lxf,pcm_s16le_planar,pcm_s24le_planar,pcm_s32le_planar,pcm_s16be_planar,pcm_s8_planar
  --enable-demuxer=mp3,aac,flac,mov,ogg,matroska,wav,hls,mpegts,ac3,eac3,aiff,ape,asf,au,concat,data
  --enable-parser=mpegaudio,aac,aac_latm,flac,opus,vorbis,ac3
  --enable-protocol=file,http,https,tcp,tls,udp,rtp,crypto,data,concat,concatf,hls,httpproxy
  --enable-filter=volume,biquad,equalizer,atempo,aformat,aresample,anull,anullsrc,abuffer,abuffersink,asplit,amix,pan,atrim,asetpts,afade
)

build_arch() {
  local arch="$1" triple ffarch cpu_family cpu_name
  case "$arch" in
    arm64) triple=aarch64-apple-darwin; ffarch=arm64; cpu_family=aarch64; cpu_name=arm64 ;;
    x86_64) triple=x86_64-apple-darwin; ffarch=x86_64; cpu_family=x86_64; cpu_name=x86_64 ;;
    *) echo "unknown arch $arch" >&2; exit 1 ;;
  esac
  local root="$BUILD_BASE/build-$arch" prefix="$BUILD_BASE/build-$arch/prefix"
  rm -rf "$root"; mkdir -p "$prefix" "$root/tree"
  local flags="-arch $arch -mmacosx-version-min=$MACOS_MIN -isysroot $SDK"
  export CC="clang -arch $arch" CXX="clang++ -arch $arch"
  export CFLAGS="-O2 -mmacosx-version-min=$MACOS_MIN -isysroot $SDK $PREFIX_MAP -I$prefix/include"
  export CXXFLAGS="$CFLAGS"
  export LDFLAGS="-mmacosx-version-min=$MACOS_MIN -isysroot $SDK -L$prefix/lib"
  export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig" PKG_CONFIG_PATH=
  # Meson must consume Libs.private for the static dependencies.
  printf '#!/bin/sh\nexec pkg-config --static "$@"\n' > "$root/pkg-config-static"
  chmod +x "$root/pkg-config-static"
  export PKG_CONFIG="$root/pkg-config-static"
  cat > "$root/cross.ini" <<CROSS
[binaries]
c = ['clang']
cpp = ['clang++']
objc = ['clang']
ar = 'ar'
strip = 'strip'
pkg-config = '$root/pkg-config-static'
[host_machine]
system = 'darwin'
cpu_family = '$cpu_family'
cpu = '$cpu_name'
endian = 'little'
[properties]
needs_exe_wrapper = false
[built-in options]
c_args = ['-arch', '$arch', '-mmacosx-version-min=$MACOS_MIN', '-isysroot', '$SDK', '-ffile-prefix-map=$BUILD_BASE=/navis-build', '-fdebug-prefix-map=$BUILD_BASE=/navis-build', '-O2']
cpp_args = ['-arch', '$arch', '-mmacosx-version-min=$MACOS_MIN', '-isysroot', '$SDK', '-ffile-prefix-map=$BUILD_BASE=/navis-build', '-fdebug-prefix-map=$BUILD_BASE=/navis-build', '-O2']
objc_args = ['-arch', '$arch', '-mmacosx-version-min=$MACOS_MIN', '-isysroot', '$SDK', '-ffile-prefix-map=$BUILD_BASE=/navis-build', '-fdebug-prefix-map=$BUILD_BASE=/navis-build', '-O2']
c_link_args = ['-arch', '$arch', '-mmacosx-version-min=$MACOS_MIN', '-isysroot', '$SDK', '-lc++']
cpp_link_args = ['-arch', '$arch', '-mmacosx-version-min=$MACOS_MIN', '-isysroot', '$SDK']
objc_link_args = ['-arch', '$arch', '-mmacosx-version-min=$MACOS_MIN', '-isysroot', '$SDK']
CROSS
  local cross="$root/cross.ini"
  cd "$root/tree"

  tar xf "$WORK/src/freetype-${FREETYPE_VERSION}.tar.xz"
  (cd "freetype-${FREETYPE_VERSION}" && ./configure --host="$triple" --prefix="$prefix" \
    --enable-static --disable-shared --with-zlib=yes --with-bzip2=no --with-png=no \
    --with-harfbuzz=no --with-brotli=no >> "$STEPS" 2>&1 && make -j"$JOBS" >> "$STEPS" 2>&1 && make install >> "$STEPS" 2>&1)
  tar xf "$WORK/src/fribidi-${FRIBIDI_VERSION}.tar.xz"
  meson setup "fribidi-${FRIBIDI_VERSION}/build" "fribidi-${FRIBIDI_VERSION}" \
    --cross-file="$cross" --prefix="$prefix" --libdir=lib --default-library=static \
    --wrap-mode=nofallback -Ddocs=false -Dtests=false -Dbin=false >> "$STEPS" 2>&1
  ninja -C "fribidi-${FRIBIDI_VERSION}/build" -j"$JOBS" install >> "$STEPS" 2>&1
  tar xf "$WORK/src/harfbuzz-${HARFBUZZ_VERSION}.tar.xz"
  meson setup "harfbuzz-${HARFBUZZ_VERSION}/build" "harfbuzz-${HARFBUZZ_VERSION}" \
    --cross-file="$cross" --prefix="$prefix" --libdir=lib --default-library=static \
    --wrap-mode=nofallback -Dauto_features=disabled -Dfreetype=enabled \
    -Dtests=disabled -Dutilities=disabled -Ddocs=disabled >> "$STEPS" 2>&1
  ninja -C "harfbuzz-${HARFBUZZ_VERSION}/build" -j"$JOBS" install >> "$STEPS" 2>&1
  # Subtitles are unused in an audio-only app; skip libass's asm and use CoreText fonts.
  tar xf "$WORK/src/libass-${LIBASS_VERSION}.tar.xz"
  (cd "libass-${LIBASS_VERSION}" && ./configure --host="$triple" --prefix="$prefix" \
    --enable-static --disable-shared --disable-fontconfig --enable-coretext \
    --disable-asm --disable-libunibreak >> "$STEPS" 2>&1 && make -j"$JOBS" >> "$STEPS" 2>&1 && make install >> "$STEPS" 2>&1)
  tar xf "$WORK/src/$PLACEBO_ARCHIVE"
  meson setup "libplacebo-${LIBPLACEBO_VERSION}/build" "libplacebo-${LIBPLACEBO_VERSION}" \
    --cross-file="$cross" --prefix="$prefix" --libdir=lib --default-library=static \
    --wrap-mode=nofallback -Dauto_features=disabled \
    -Dvulkan=disabled -Dopengl=disabled -Dd3d11=disabled -Dglslang=disabled \
    -Dshaderc=disabled -Dlcms=disabled -Ddemos=false -Dtests=false >> "$STEPS" 2>&1
  ninja -C "libplacebo-${LIBPLACEBO_VERSION}/build" -j"$JOBS" install >> "$STEPS" 2>&1

  # FFmpeg: no --enable-gpl/--enable-nonfree (LGPL-2.1+). TLS is Apple's
  # SecureTransport, so the system trust store is used with no bundled CA file.
  tar xf "$WORK/src/ffmpeg-${FFMPEG_COMMIT}.tar.gz"
  cd FFmpeg-*/
  local ffmpeg_flags=(
    --prefix="$prefix" --target-os=darwin --arch="$ffarch" --enable-cross-compile
    --cc=clang --cxx=clang++ --pkg-config="$root/pkg-config-static"
    "${FFMPEG_FLAGS_COMMON[@]}"
    --extra-cflags="$flags $PREFIX_MAP -I$prefix/include" --extra-ldflags="$flags -L$prefix/lib"
  )
  ./configure "${ffmpeg_flags[@]}" >> "$STEPS" 2>&1
  make -j"$JOBS" >> "$STEPS" 2>&1 && make install >> "$STEPS" 2>&1
  # Compiled-in proof of the filters Navis needs (EQ chain uses volume + biquad).
  grep -Fx '#define CONFIG_SECURETRANSPORT 1' config.h >> "$STEPS" 2>&1
  grep -Fx '#define CONFIG_GPL 0' config.h >> "$STEPS" 2>&1
  grep -Fx '#define CONFIG_NONFREE 0' config.h >> "$STEPS" 2>&1
  for filter in VOLUME EQUALIZER BIQUAD ATEMPO ARESAMPLE AFORMAT; do
    grep -Fx "#define CONFIG_${filter}_FILTER 1" config_components.h >> "$STEPS" 2>&1
    nm "$prefix/lib/libavfilter.a" 2> /dev/null | grep -i "ff_af_$(echo "$filter" | tr 'A-Z' 'a-z')\$" >> "$STEPS" 2>&1
  done
  if [[ ! -f "$WORK/stage/FFMPEG-COMPONENTS.txt" ]]; then
    cp config_components.h "$WORK/stage/FFMPEG-COMPONENTS.txt"
    printf '%q ' "${ffmpeg_flags[@]}" > "$WORK/stage/FFMPEG-CONFIGURE.txt"
    printf '\n' >> "$WORK/stage/FFMPEG-CONFIGURE.txt"
  fi
  cd "$root/tree"

  tar xf "$WORK/src/mpv-${MPV_COMMIT}.tar.gz"
  # The only source change: mpv eb0ee1031590's CoreAudio output sets the AUHAL
  # ChannelMap property from an AudioChannelLayout, which current macOS rejects
  # (-50) so no sound plays. mpv master removed that call; so does the patch.
  patch -p1 -d "mpv-${MPV_COMMIT}" < "$PATCH_DIR/mpv-macos-coreaudio-channelmap.patch" >> "$STEPS" 2>&1
  # mpv's meson only compiles osdep/utils-mac.c (cfstr_get_cstr/cfstr_from_cstr,
  # which the CoreAudio output calls) when Cocoa is on, and Cocoa drags in the
  # Swift/GL window code. With Cocoa off the link would leave both symbols to
  # dynamic lookup and crash at the first CoreAudio call, so build mpv's own
  # unmodified file here and link the object in.
  local utils_obj="$root/tree/utils-mac.o"
  clang -arch "$arch" -mmacosx-version-min="$MACOS_MIN" -isysroot "$SDK" $PREFIX_MAP -O2 \
    -I"mpv-${MPV_COMMIT}" -c "mpv-${MPV_COMMIT}/osdep/utils-mac.c" -o "$utils_obj"
  local mpv_flags=(
    --cross-file="$cross" --prefix="$prefix/mpv" --libdir=lib --buildtype=release
    --wrap-mode=nofallback -Dauto_features=disabled -Dgpl=false -Dlibmpv=true
    -Dcplayer=false -Ddefault_library=shared -Dcoreaudio=enabled -Dzlib=enabled
    -Diconv=disabled -Dlua=disabled -Djavascript=disabled -Dlibarchive=disabled
    -Dlibbluray=disabled -Ddvdnav=disabled -Ddvda=disabled -Drubberband=disabled
    -Duchardet=disabled -Dlcms2=disabled -Dvapoursynth=disabled -Dzimg=disabled
    -Dcdda=disabled -Ddvbin=disabled -Dlibcurl=disabled -Dcplugins=disabled
    -Dcocoa=disabled -Dswift-build=disabled -Dmacos-cocoa-cb=disabled
    -Dmacos-media-player=disabled -Dmacos-touchbar=disabled -Dgl=disabled
    -Dgl-cocoa=disabled -Dplain-gl=disabled -Dvulkan=disabled
    -Dvideotoolbox-gl=disabled -Dvideotoolbox-pl=disabled -Davfoundation=disabled
    -Dsdl2-video=disabled -Dcaca=disabled -Dsixel=disabled -Djpeg=disabled
    -Dlibavdevice=disabled -Dopenal=disabled -Djack=disabled -Dsdl2-audio=disabled
    -Dmanpage-build=disabled -Dhtml-build=disabled -Dpdf-build=disabled
  )
  printf '%q ' "${mpv_flags[@]}" > "$WORK/stage/MPV-MESON-FLAGS.txt"
  printf '\nthen: meson configure -Dc_link_args=<arch/min/sysroot flags> -lc++ <mpv osdep/utils-mac.c compiled unmodified>\n' >> "$WORK/stage/MPV-MESON-FLAGS.txt"
  meson setup "mpv-${MPV_COMMIT}/build" "mpv-${MPV_COMMIT}" "${mpv_flags[@]}" >> "$STEPS" 2>&1
  # Added after configuration: meson's framework probes would not link with it.
  meson configure "mpv-${MPV_COMMIT}/build" \
    "-Dc_link_args=-arch $arch -mmacosx-version-min=$MACOS_MIN -isysroot $SDK -lc++ $utils_obj" >> "$STEPS" 2>&1
  ninja -C "mpv-${MPV_COMMIT}/build" -j"$JOBS" install >> "$STEPS" 2>&1
  cp "$prefix/mpv/lib/libmpv.2.dylib" "$WORK/stage/libmpv-$arch.dylib"
  strip -x "$WORK/stage/libmpv-$arch.dylib"
  if [[ ! -d "$WORK/stage/include" ]]; then cp -R "$prefix/mpv/include" "$WORK/stage/include"; fi
  python3 - "mpv-${MPV_COMMIT}/build" <<'PY'
import json, subprocess, sys
options = json.loads(subprocess.check_output(['meson', 'introspect', '--buildoptions', sys.argv[1]]))
assert next(x['value'] for x in options if x['name'] == 'gpl') is False
PY
  cd "$WORK"
  if [[ "${KEEP_TREE:-0}" != 1 ]]; then rm -rf "$root"; fi   # intermediate build tree: only the stripped per-arch dylib is kept
}

# REUSE_STAGE=1 keeps already staged per-arch dylibs (resume after a later failure).
if [[ "${REUSE_STAGE:-0}" != 1 ]]; then rm -rf "$WORK/stage"; fi
mkdir -p "$WORK/stage"
for arch in arm64 x86_64; do
  [[ -f "$WORK/stage/libmpv-$arch.dylib" ]] || build_arch "$arch"
done

# ------------------------------------------------------------ framework
FW="$OUT/Mpv.xcframework/macos-arm64_x86_64/Mpv.framework"
rm -rf "$OUT/Mpv.xcframework"
mkdir -p "$FW/Versions/A/Headers" "$FW/Versions/A/Resources"
lipo -create -output "$FW/Versions/A/Mpv" "$WORK/stage/libmpv-arm64.dylib" "$WORK/stage/libmpv-x86_64.dylib"
install_name_tool -id '@rpath/Mpv.framework/Versions/A/Mpv' "$FW/Versions/A/Mpv"
cp "$WORK/stage/include/mpv/"*.h "$FW/Versions/A/Headers/"
cat > "$FW/Versions/A/Resources/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleExecutable</key><string>Mpv</string>
	<key>CFBundleIdentifier</key><string>com.porthorion.navis.Mpv</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>Mpv</string>
	<key>CFBundlePackageType</key><string>FMWK</string>
	<key>CFBundleShortVersionString</key><string>2.0.0</string>
	<key>CFBundleVersion</key><string>${ARTIFACT_DATE}</string>
	<key>LSMinimumSystemVersion</key><string>${MACOS_MIN}</string>
</dict>
</plist>
PLIST
(cd "$FW/Versions" && ln -s A Current)
(cd "$FW" && ln -s Versions/Current/Mpv Mpv && ln -s Versions/Current/Headers Headers && ln -s Versions/Current/Resources Resources)
codesign --force --sign - --timestamp=none "$FW"
cat > "$OUT/Mpv.xcframework/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AvailableLibraries</key>
	<array>
		<dict>
			<key>BinaryPath</key><string>Mpv.framework/Mpv</string>
			<key>LibraryIdentifier</key><string>macos-arm64_x86_64</string>
			<key>LibraryPath</key><string>Mpv.framework</string>
			<key>SupportedArchitectures</key><array><string>arm64</string><string>x86_64</string></array>
			<key>SupportedPlatform</key><string>macos</string>
		</dict>
	</array>
	<key>CFBundlePackageType</key><string>XFWK</string>
	<key>XCFrameworkFormatVersion</key><string>1.0</string>
</dict>
</plist>
PLIST
BIN="$FW/Versions/A/Mpv"

# ------------------------------------------------------------ verification
lipo -info "$BIN" | grep -q 'x86_64 arm64\|arm64 x86_64' || { echo 'Not a universal binary' >&2; exit 1; }
otool -L "$BIN" | awk '/^\t/ {print $1}' | sort -u > "$OUT/LINKED-LIBRARIES.txt"
while IFS= read -r lib; do
  case "$lib" in
    /usr/lib/*|/System/Library/Frameworks/*|@rpath/Mpv.framework/Versions/A/Mpv) ;;
    *) echo "Non-system library linked: $lib" >&2; exit 1 ;;
  esac
done < "$OUT/LINKED-LIBRARIES.txt"
rm -f "$OUT/DEPLOYMENT-TARGETS.txt"
for arch in arm64 x86_64; do
  build_info="$(vtool -arch "$arch" -show-build "$BIN")" || { echo "vtool failed for the $arch slice" >&2; exit 1; }
  awk -v a="$arch" '/minos/ {print a ": minos " $2}' <<< "$build_info" >> "$OUT/DEPLOYMENT-TARGETS.txt"
  # Every minos line must equal MACOS_MIN, and there must be at least one.
  awk -v want="$MACOS_MIN" '/minos/ {n++; if ($2 != want) bad = 1} END {exit !(n > 0 && !bad)}' <<< "$build_info" \
    || { echo "$arch slice has no minos $MACOS_MIN (or has another minos)" >&2; exit 1; }
done
# A symbol left to dynamic lookup is a link gap that only crashes at runtime.
# nm itself failing is also a failure, so its output is captured first.
nm_out="$(nm -m "$BIN")" || { echo 'nm failed on the framework binary' >&2; exit 1; }
if grep -q 'dynamically looked up' <<< "$nm_out"; then
  grep 'dynamically looked up' <<< "$nm_out" >&2
  echo 'Unresolved symbols left for dynamic lookup' >&2; exit 1
fi
strings -a "$BIN" > "$WORK/stage/strings.txt"
# The shipped binary must not carry the builder's home directory.
if [[ -n "${HOME:-}" && "$HOME" != / ]] && grep -F -- "$HOME" "$WORK/stage/strings.txt" > /dev/null; then
  echo "The binary contains the builder's home path ($HOME)" >&2; exit 1
fi
if grep -E -- '--enable-(gpl|nonfree)|nonfree and unredistributable' "$WORK/stage/strings.txt" > /dev/null; then
  echo 'Forbidden FFmpeg licence configuration' >&2; exit 1
fi
grep -F -- '-Dgpl=false' "$WORK/stage/strings.txt" > /dev/null || { echo 'mpv -Dgpl=false string missing' >&2; exit 1; }
grep -F -- 'LGPL version 2.1 or later' "$WORK/stage/strings.txt" > /dev/null || { echo 'FFmpeg LGPL string missing' >&2; exit 1; }
grep -F -- '--enable-securetransport' "$WORK/stage/strings.txt" > /dev/null || { echo 'securetransport string missing' >&2; exit 1; }
if grep -Ei 'mbedtls|openssl|gnutls' "$WORK/stage/strings.txt" | grep -F -- '--enable-' > /dev/null; then
  echo 'Unexpected TLS library in FFmpeg configuration' >&2; exit 1
fi

# Native smoke on both slices (x86_64 runs under Rosetta): the app's af chain
# (scaletempo + lavfi volume/biquad/equalizer), a WAV decode and an exact seek.
SMOKE="$WORK/stage/smoke"; mkdir -p "$SMOKE"
python3 - "$SMOKE/tone.wav" <<'PY'
import math, struct, sys, wave
with wave.open(sys.argv[1], 'wb') as audio:
    audio.setparams((1, 2, 48000, 0, 'NONE', 'not compressed'))
    audio.writeframes(b''.join(struct.pack('<h', int(5000 * math.sin(2 * math.pi * 440 * i / 48000))) for i in range(480000)))
PY
cat > "$SMOKE/smoke.c" <<'C'
#include <mpv/client.h>
#include <stdio.h>
#include <stdlib.h>
static void check(int status) {
    if (status < 0) { fprintf(stderr, "mpv: %s\n", mpv_error_string(status)); exit(1); }
}
static double pos(mpv_handle *mpv) {
    double p = -1;
    if (mpv_get_property(mpv, "time-pos", MPV_FORMAT_DOUBLE, &p) < 0) return -1;
    return p;
}
int main(int argc, char **argv) {
    mpv_handle *mpv = mpv_create();
    if (!mpv) return 1;
    check(mpv_set_option_string(mpv, "vo", "null"));
    check(mpv_set_option_string(mpv, "vid", "no"));
    check(mpv_set_option_string(mpv, "ao", argv[2]));
    check(mpv_set_option_string(mpv, "volume", "0"));
    check(mpv_set_option_string(mpv, "audio-pitch-correction", "no"));
    check(mpv_set_option_string(mpv, "af", "@navis_tempo:scaletempo:scale=1.25,@navis_eq:lavfi=[volume=-3dB:precision=double,biquad=b0=1:b1=0:b2=0:a0=1:a1=0:a2=0:precision=f64:transform=tdii,equalizer=f=1000:t=q:w=1:g=1]"));
    check(mpv_initialize(mpv));
    const char *load[] = {"loadfile", argv[1], NULL};
    check(mpv_command(mpv, load));
    int ready = 0;
    for (int i = 0; i < 100 && !ready; ++i) {
        mpv_event *e = mpv_wait_event(mpv, 0.1);
        if (e->event_id == MPV_EVENT_END_FILE) { fprintf(stderr, "ended before playback\n"); return 1; }
        ready = pos(mpv) > 0.2;
    }
    if (!ready) { fprintf(stderr, "filtered playback did not advance\n"); return 1; }
    const char *seek[] = {"seek", "2", "absolute+exact", NULL};
    check(mpv_command(mpv, seek));
    ready = 0;
    for (int i = 0; i < 100 && !ready; ++i) { mpv_wait_event(mpv, 0.1); ready = pos(mpv) >= 2; }
    mpv_terminate_destroy(mpv);
    if (!ready) { fprintf(stderr, "seek did not settle\n"); return 1; }
    printf("macOS libmpv smoke passed (ao=%s): init, WAV decode, scaletempo/volume/biquad/equalizer, advancing playback and seek.\n", argv[2]);
    return 0;
}
C
: > "$OUT/MACOS-SMOKE.txt"
# ao=coreaudio plays a muted (volume 0) tone on the default output and proves
# the CoreAudio path really runs; SKIP_COREAUDIO_SMOKE=1 for hosts without audio.
smoke_aos=(null coreaudio)
[[ "${SKIP_COREAUDIO_SMOKE:-0}" != 1 ]] || smoke_aos=(null)
for arch in arm64 x86_64; do
  clang -arch "$arch" -mmacosx-version-min="$MACOS_MIN" -O1 "$SMOKE/smoke.c" -I"$WORK/stage/include" \
    "$BIN" -Wl,-rpath,"$OUT/Mpv.xcframework/macos-arm64_x86_64" -o "$SMOKE/smoke-$arch"
  for ao in "${smoke_aos[@]}"; do
    printf '[%s] ' "$arch" >> "$OUT/MACOS-SMOKE.txt"
    arch -"$arch" "$SMOKE/smoke-$arch" "$SMOKE/tone.wav" "$ao" >> "$OUT/MACOS-SMOKE.txt" 2>&1 || { cat "$OUT/MACOS-SMOKE.txt" >&2; exit 1; }
  done
done
cat "$OUT/MACOS-SMOKE.txt"
rm -rf "$SMOKE"

# ------------------------------------------------------------ metadata
cp "$WORK/stage/FFMPEG-COMPONENTS.txt" "$OUT/"
# Recorded flags name the build root; publish the neutral path instead.
for f in FFMPEG-CONFIGURE.txt MPV-MESON-FLAGS.txt; do
  sed -e "s|$BUILD_BASE|/navis-build|g" -e "s|$WORK|/navis-work|g" -e "s|$HOME|~|g" "$WORK/stage/$f" > "$OUT/$f"
done
cp "$SCRIPT" "$OUT/build_macos_lgpl.sh"
mkdir -p "$OUT/patches" && cp "$PATCH_DIR"/*.patch "$OUT/patches/"
{
  echo "Navis macOS universal LGPL libmpv ($ARTIFACT_DATE)"
  echo "mpv $MPV_COMMIT (-Dgpl=false, libmpv only, CoreAudio output) + patches/mpv-macos-coreaudio-channelmap.patch"
  echo "FFmpeg $FFMPEG_COMMIT (LGPL-2.1-or-later; SecureTransport TLS, system trust store)"
  echo "libass $LIBASS_VERSION (CoreText); libplacebo $LIBPLACEBO_VERSION"
  echo "FreeType $FREETYPE_VERSION; FriBidi $FRIBIDI_VERSION; HarfBuzz $HARFBUZZ_VERSION; zlib: macOS system libz"
  echo "Deployment target: macOS $MACOS_MIN; slices arm64 + x86_64; SDK: $SDK"
  echo "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH; JOBS=$JOBS; meson $MESON_VERSION; jinja2 $JINJA2_VERSION"
  echo; echo 'Toolchain:'; clang --version; xcodebuild -version; nasm --version
  echo; echo 'FFmpeg configure flags (arm64; x86_64 differs only in -arch/--arch):'; cat "$OUT/FFMPEG-CONFIGURE.txt"
  echo; echo 'mpv meson flags:'; cat "$OUT/MPV-MESON-FLAGS.txt"; echo
  echo; echo 'Linked system libraries (otool -L; nothing else is allowed):'; cat "$OUT/LINKED-LIBRARIES.txt"
  echo; echo 'Deployment targets:'; cat "$OUT/DEPLOYMENT-TARGETS.txt"
  echo; echo 'Native smoke (null audio output):'; cat "$OUT/MACOS-SMOKE.txt"
  echo; echo 'libplacebo commit and recursive submodules:'; cat "$OUT/libplacebo-commit.txt" "$OUT/libplacebo-submodules.txt"
  echo; echo 'Verified: no --enable-gpl/--enable-nonfree strings; mpv gpl=false; FFmpeg LGPL string and securetransport present; compiled volume/equalizer/biquad/atempo/aresample/aformat filters; only Apple system libraries linked; universal arm64+x86_64.'
} > "$OUT/BUILDINFO.txt"
rm -f "$OUT/libplacebo-commit.txt" "$OUT/libplacebo-submodules.txt"
if [[ -n "${HOME:-}" && "$HOME" != / ]] && grep -lF -- "$HOME" "$OUT"/*.txt; then
  echo "Published metadata contains the builder's home path ($HOME)" >&2; exit 1
fi
archive="${NAME}.tar.gz"
rm -f "$OUT/$archive"
tar --no-xattrs -czf "$OUT/$archive" -C "$OUT" Mpv.xcframework BUILDINFO.txt build_macos_lgpl.sh patches \
  FFMPEG-CONFIGURE.txt FFMPEG-COMPONENTS.txt MPV-MESON-FLAGS.txt LINKED-LIBRARIES.txt
(cd "$OUT" && shasum -a 256 "$archive" src/* > SHA256SUMS)
{
  echo "# Navis macOS LGPL libmpv ($ARTIFACT_DATE)"
  echo
  echo "\`$archive\` is Navis's audio-only universal (arm64 + x86_64) macOS playback engine, packaged as \`Mpv.xcframework\` for package:media_kit."
  echo "Archive SHA-256: \`$(sha_of "$OUT/$archive")\`."
  echo "The framework is replaceable; it links only Apple system libraries and frameworks. Deployment target: macOS $MACOS_MIN. See BUILDINFO.txt for configuration, toolchain and linked libraries."
  echo
  echo '## Versions and licences'
  echo
  echo "- mpv $MPV_COMMIT: LGPL-2.1-or-later with gpl=false, plus one source patch (patches/mpv-macos-coreaudio-channelmap.patch, also in the archive) that drops mpv's CoreAudio ChannelMap call, which current macOS rejects; mpv master removed the same call."
  echo "- FFmpeg $FFMPEG_COMMIT: LGPL-2.1-or-later; no GPL or nonfree options; TLS through Apple SecureTransport (a system framework)."
  echo "- libass $LIBASS_VERSION: ISC."
  echo "- libplacebo $LIBPLACEBO_VERSION: LGPL-2.1-or-later; includes FastFloat (MIT/Apache-2.0/Boost alternatives), glad (MIT generator; Khronos headers), Vulkan-Headers (Apache-2.0/MIT), Jinja and MarkupSafe (BSD-3-Clause), and Nuklear (MIT/public-domain alternatives) source submodules, even though GPU backends are disabled."
  echo "- FreeType $FREETYPE_VERSION: FreeType License (FTL), selected instead of its GPL alternative."
  echo "- FriBidi $FRIBIDI_VERSION: LGPL-2.1-or-later."
  echo "- HarfBuzz $HARFBUZZ_VERSION: MIT-style Old MIT licence; see COPYING."
  echo '- zlib, libc++ and the CoreAudio/CoreText/Security frameworks are macOS system components, dynamically linked, not distributed.'
  echo
  echo '## Corresponding source in this folder'
  echo
  echo 'All source archives listed below are in this folder (upload the contents of src/ alongside SOURCES.md). Original licence/copyright texts are retained in each archive. libplacebo includes recursive submodule sources. The binary archive includes the build script; BUILDINFO.txt, configuration/component lists and submodule provenance also accompany it.'
  echo
  echo '| Source archive | SHA-256 |'
  echo '|---|---|'
  for source in "$OUT"/src/*; do printf '| `%s` | `%s` |\n' "${source##*/}" "$(sha_of "$source")"; done
  echo
  echo 'Source URLs and pinned release digests are recorded in build_macos_lgpl.sh; libplacebo is captured from https://github.com/haasn/libplacebo with its recursive submodules at the commit in BUILDINFO.txt.'
  echo
  echo '## Rebuild'
  echo
  echo 'On a Mac with Xcode, nasm, git, curl and python3 (meson and jinja2 are installed into a private venv), run:'
  echo '```bash'
  echo "ARTIFACT_DATE=$ARTIFACT_DATE ./build_macos_lgpl.sh"
  echo '```'
  echo 'The script downloads the pinned sources, builds each architecture in turn with static dependencies, merges them with lipo, verifies the licence configuration, required filters, deployment target and system-only linkage, runs a playback smoke on both slices, and packages the archive. Xcode and SDK versions are not pinned; compare BUILDINFO.txt on rebuilds. Preserve this folder and its sources for users of this build.'
} > "$OUT/SOURCES.md"
printf 'Built %s/%s\n' "$OUT" "$archive"
