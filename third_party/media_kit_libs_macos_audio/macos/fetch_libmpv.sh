#!/bin/sh
# Provides macos/Frameworks/Mpv.xcframework from Navis's pinned libmpv archive.
# Run by the podspec on every `pod install`; a non-zero exit fails the build.
#
# Order: a verified cached archive, then $NAVIS_LIBMPV_MACOS_ARCHIVE (a local
# file, e.g. straight from tool/libmpv/build_macos_lgpl.sh before it is
# uploaded), then the per-build downloads.porthorion.com URL. Whatever supplies
# the archive, its SHA-256 must equal LIBMPV_SHA256 below.
set -eu

LIBMPV="libmpv-macos-universal-lgpl-20261104.tar.gz"
LIBMPV_URL="https://downloads.porthorion.com/navis/third-party/libmpv-macos-universal-lgpl-20261104/${LIBMPV}"
LIBMPV_SHA256="6930a6847b7edc3ff87fc92b9882b496aaa60dcb0c07d4888358c94de598a380"

cd "$(dirname "$0")"
cache=".cache/${LIBMPV}"
stamp="Frameworks/.libmpv-sha256"

sha_ok() { [ -f "$1" ] && [ "$(shasum -a 256 "$1" | cut -d' ' -f1)" = "$LIBMPV_SHA256" ]; }

if [ -d Frameworks/Mpv.xcframework ] && [ "$(cat "$stamp" 2>/dev/null)" = "$LIBMPV_SHA256" ]; then
  exit 0
fi

mkdir -p .cache
if ! sha_ok "$cache"; then
  rm -f "$cache"
  if [ -n "${NAVIS_LIBMPV_MACOS_ARCHIVE:-}" ]; then
    [ -f "$NAVIS_LIBMPV_MACOS_ARCHIVE" ] || {
      echo "media_kit_libs_macos_audio: NAVIS_LIBMPV_MACOS_ARCHIVE does not exist: $NAVIS_LIBMPV_MACOS_ARCHIVE" >&2
      exit 1
    }
    cp "$NAVIS_LIBMPV_MACOS_ARCHIVE" "$cache.tmp"
  else
    echo "media_kit_libs_macos_audio: downloading $LIBMPV_URL" >&2
    curl -fsSL --retry 3 --connect-timeout 30 --max-time 300 -o "$cache.tmp" "$LIBMPV_URL" || {
      rm -f "$cache.tmp"
      echo "media_kit_libs_macos_audio: could not download $LIBMPV_URL" >&2
      echo "Set NAVIS_LIBMPV_MACOS_ARCHIVE to a local $LIBMPV (see tool/libmpv/README.md)." >&2
      exit 1
    }
  fi
  mv "$cache.tmp" "$cache"
  if ! sha_ok "$cache"; then
    rm -f "$cache"
    echo "media_kit_libs_macos_audio: SHA-256 mismatch for $LIBMPV (expected $LIBMPV_SHA256)." >&2
    exit 1
  fi
fi

rm -rf Frameworks
mkdir -p Frameworks
tar -xzf "$cache" -C Frameworks Mpv.xcframework
[ -f Frameworks/Mpv.xcframework/Info.plist ] || {
  echo "media_kit_libs_macos_audio: $LIBMPV has no Mpv.xcframework." >&2
  exit 1
}
echo "$LIBMPV_SHA256" > "$stamp"
