#!/usr/bin/env bash
# Builds an LGPL libmpv.so.2 into /out. Runs inside the Dockerfile's image.
# FFmpeg, libplacebo and libass are linked statically; system libraries that
# every desktop already has (glibc, GnuTLS, PulseAudio (also served by PipeWire), ALSA,
# FreeType, FriBidi, HarfBuzz, fontconfig, zlib, libstdc++ for libplacebo)
# stay dynamic.
set -euo pipefail

MPV_COMMIT=eb0ee1031590b3f369a5b783e8aa91eeaaded7e6
FFMPEG_COMMIT=151814650
LIBASS_VERSION=0.17.5
LIBPLACEBO_VERSION=v7.360.1

PREFIX=/opt/deps
JOBS="${JOBS:-6}"
export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig:${PREFIX}/lib/x86_64-linux-gnu/pkgconfig"
export CFLAGS="-O2 -fPIC" CXXFLAGS="-O2 -fPIC"
mkdir -p /src /out/src && cd /src

fetch() { curl -fsSL --retry 3 -o "$2" "$1"; cp "$2" /out/src/; }

fetch "https://github.com/FFmpeg/FFmpeg/archive/${FFMPEG_COMMIT}.tar.gz" "ffmpeg-${FFMPEG_COMMIT}.tar.gz"
fetch "https://github.com/libass/libass/releases/download/${LIBASS_VERSION}/libass-${LIBASS_VERSION}.tar.xz" "libass-${LIBASS_VERSION}.tar.xz"
# libplacebo needs its git submodules, which release archives leave out.
git clone --quiet --depth 1 --recurse-submodules --shallow-submodules \
  --branch "${LIBPLACEBO_VERSION}" https://github.com/haasn/libplacebo.git "libplacebo-${LIBPLACEBO_VERSION}"
tar czf "/out/src/libplacebo-${LIBPLACEBO_VERSION}.tar.gz" --exclude=.git "libplacebo-${LIBPLACEBO_VERSION}"
fetch "https://github.com/mpv-player/mpv/archive/${MPV_COMMIT}.tar.gz" "mpv-${MPV_COMMIT}.tar.gz"

# FFmpeg: no --enable-gpl and no --enable-nonfree, so the result is LGPL 2.1+.
tar xf "ffmpeg-${FFMPEG_COMMIT}.tar.gz"
cd FFmpeg-*/
./configure --prefix="${PREFIX}" --enable-static --disable-shared --enable-pic \
  --disable-programs --disable-doc --disable-debug \
  --disable-avdevice \
  --enable-gnutls --enable-zlib \
  --disable-xlib --disable-libxcb --disable-vaapi --disable-vdpau --disable-sdl2
make -j"${JOBS}" && make install
cd /src

tar xf "libass-${LIBASS_VERSION}.tar.xz"
cd "libass-${LIBASS_VERSION}"
./configure --prefix="${PREFIX}" --enable-static --disable-shared --with-pic
make -j"${JOBS}" && make install
cd /src

cd "libplacebo-${LIBPLACEBO_VERSION}"
meson setup build --prefix="${PREFIX}" --default-library=static \
  -Dvulkan=disabled -Dopengl=disabled -Dd3d11=disabled -Dglslang=disabled \
  -Dshaderc=disabled -Dlcms=disabled -Ddemos=false -Dtests=false
ninja -C build -j"${JOBS}" install
cd /src

# mpv: -Dgpl=false; audio outputs only, no video outputs or scripting.
tar xf "mpv-${MPV_COMMIT}.tar.gz"
cd "mpv-${MPV_COMMIT}"
meson setup build --prefix=/opt/mpv --buildtype=release \
  -Dgpl=false -Dlibmpv=true -Dcplayer=false -Ddefault_library=shared \
  -Dlua=disabled -Djavascript=disabled -Dlibarchive=disabled -Dlibbluray=disabled \
  -Ddvdnav=disabled -Drubberband=disabled -Duchardet=disabled -Dlcms2=disabled \
  -Dvapoursynth=disabled -Dzimg=disabled -Dcdda=disabled -Ddvbin=disabled \
  -Dx11=disabled -Dwayland=disabled -Dgl=disabled -Degl=disabled -Dvulkan=disabled \
  -Dvaapi=disabled -Dvdpau=disabled -Ddrm=disabled -Dgbm=disabled -Dsdl2-video=disabled \
  -Dcaca=disabled -Dsixel=disabled -Djpeg=disabled -Dlibavdevice=disabled \
  -Dpulse=enabled -Dalsa=enabled -Dpipewire=disabled -Dopenal=disabled -Djack=disabled \
  -Dsdl2-audio=disabled -Dmanpage-build=disabled -Dhtml-build=disabled -Dpdf-build=disabled \
  -Dc_link_args='-Wl,--push-state,--no-as-needed -lstdc++ -Wl,--pop-state'
ninja -C build -j"${JOBS}" install

lib=$(readlink -f /opt/mpv/lib/x86_64-linux-gnu/libmpv.so.2 2>/dev/null || readlink -f /opt/mpv/lib/libmpv.so.2)
cp "${lib}" /out/libmpv.so.2
strip --strip-unneeded /out/libmpv.so.2
patchelf --set-rpath '$ORIGIN' /out/libmpv.so.2
cp -r /opt/mpv/include /out/include

# Record what was built and check the licence-relevant configuration.
{
  echo "mpv ${MPV_COMMIT} (-Dgpl=false)"
  echo "FFmpeg ${FFMPEG_COMMIT}"
  echo "libass ${LIBASS_VERSION}"
  echo "libplacebo ${LIBPLACEBO_VERSION}"
  echo
  echo "Dynamic dependencies:"
  objdump -p /out/libmpv.so.2 | awk '/NEEDED/ {print "  " $2}'
} > /out/BUILDINFO.txt
strings /out/libmpv.so.2 > /tmp/libmpv-strings.txt
if grep -E -- '--enable-(gpl|nonfree)' /tmp/libmpv-strings.txt > /dev/null; then
  echo "FFmpeg was configured with --enable-gpl or --enable-nonfree" >&2
  exit 1
fi
grep -F -- '-Dgpl=false' /tmp/libmpv-strings.txt > /dev/null || {
  echo "mpv LGPL configuration string is missing" >&2
  exit 1
}
cp /Dockerfile /out/Dockerfile
cp /build.sh /out/build.sh
(cd /out && sha256sum libmpv.so.2 src/* > SHA256SUMS)
echo "Built /out/libmpv.so.2"
