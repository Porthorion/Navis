#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

cd "${REPO_ROOT}"

if ! command -v magick &>/dev/null; then
  echo "Error: ImageMagick 'magick' is required to generate platform icons." >&2
  exit 1
fi

CANONICAL_MARK="lib/src/icon/Navis_Logo.svg"
LIGHT_MARK="lib/src/icon/Navis_Logo_Light.png"
DARK_MARK="lib/src/icon/Navis_Logo_Dark.png"
ADAPTIVE_FOREGROUND="lib/src/icon/Navis_Adaptive_Foreground.png"
APP_ICON="lib/src/icon/Navis_App_Icon.png"

magick -background none -density 256 "${CANONICAL_MARK}" \
  -resize 1024x1024 -strip "${LIGHT_MARK}"
magick "${LIGHT_MARK}" -channel RGB -fill '#242424' -colorize 100 \
  +channel -strip "${DARK_MARK}"
magick -size 1024x1024 xc:none \
  -fill '#111111' -draw 'circle 512,512 904,512' \
  "${LIGHT_MARK}" -compose over -composite -strip "${APP_ICON}"
magick "${APP_ICON}" -strip "${ADAPTIVE_FOREGROUND}"

if [[ "$(magick "${APP_ICON}" -format '%[fx:p{0,0}.a]' info:)" != '0' ]]; then
  echo "Error: App icon canvas must remain transparent outside the badge." >&2
  exit 1
fi

dart run flutter_launcher_icons

ANDROID_COLORS="android/app/src/main/res/values/colors.xml"
if [[ -n "$(tail -c 1 "${ANDROID_COLORS}")" ]]; then
  printf '\n' >>"${ANDROID_COLORS}"
fi

magick "${APP_ICON}" \
  -define icon:auto-resize=256,128,64,48,32,24,16 \
  "windows/runner/resources/app_icon.ico"

for size in 16 24 32 48 64 128 256 512; do
  icon_dir="linux/packaging/icons/hicolor/${size}x${size}/apps"
  mkdir -p "${icon_dir}"
  magick "${APP_ICON}" -resize "${size}x${size}" -strip "${icon_dir}/navis.png"
done

for size in 16 32 64 128 256 512 1024; do
  magick "${APP_ICON}" -resize "${size}x${size}" -strip \
    "macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_${size}.png"
done

for spec in mdpi:48 hdpi:72 xhdpi:96 xxhdpi:144 xxxhdpi:192; do
  density="${spec%%:*}"
  size="${spec##*:}"
  magick "${APP_ICON}" -resize "${size}x${size}" -strip \
    "android/app/src/main/res/mipmap-${density}/ic_launcher_navis.png"
done

for spec in mdpi:108 hdpi:162 xhdpi:216 xxhdpi:324 xxxhdpi:432; do
  density="${spec%%:*}"
  size="${spec##*:}"
  magick "${ADAPTIVE_FOREGROUND}" -resize "${size}x${size}" -strip \
    "android/app/src/main/res/drawable-${density}/ic_launcher_foreground.png"
done

for spec in mdpi:24 hdpi:36 xhdpi:48 xxhdpi:72 xxxhdpi:96; do
  density="${spec%%:*}"
  size="${spec##*:}"
  magick "${LIGHT_MARK}" -resize "${size}x${size}" -strip \
    "android/app/src/main/res/drawable-${density}/ic_stat_navis_light.png"
done

magick "${LIGHT_MARK}" -resize 24x24 -strip \
  "android/app/src/main/res/drawable/ic_stat_navis_light.png"
