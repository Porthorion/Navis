#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

cd "${REPO_ROOT}"

if ! command -v magick &>/dev/null; then
  echo "Error: ImageMagick 'magick' is required to generate platform icons." >&2
  exit 1
fi

APP_ICON="lib/src/icon/Navis_App_Icon.png"
LIGHT_MARK="lib/src/icon/Navis_Icon_light.png"

magick -size 1024x1024 xc:'#111111' "${LIGHT_MARK}" -compose over -composite -strip "${APP_ICON}"

magick "${APP_ICON}" \
  -define icon:auto-resize=256,128,64,48,32,24,16 \
  "windows/runner/resources/app_icon.ico"

for size in 16 24 32 48 64 128 256 512; do
  icon_dir="linux/packaging/icons/hicolor/${size}x${size}/apps"
  mkdir -p "${icon_dir}"
  magick "${APP_ICON}" -resize "${size}x${size}" -strip "${icon_dir}/navis.png"
done

for spec in mdpi:48 hdpi:72 xhdpi:96 xxhdpi:144 xxxhdpi:192; do
  density="${spec%%:*}"
  size="${spec##*:}"
  magick "${APP_ICON}" -resize "${size}x${size}" -strip \
    "android/app/src/main/res/mipmap-${density}/ic_launcher.png"
done

for spec in mdpi:108 hdpi:162 xhdpi:216 xxhdpi:324 xxxhdpi:432; do
  density="${spec%%:*}"
  size="${spec##*:}"
  magick "${LIGHT_MARK}" -resize "${size}x${size}" -strip \
    "android/app/src/main/res/drawable-${density}/ic_launcher_foreground.png"
done

