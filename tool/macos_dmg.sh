#!/usr/bin/env bash
# Builds the Navis drag-to-Applications DMG for first installs. The self-updater
# keeps using the zip; see docs/release/release-macos.md#dmg-first-installs.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./tool/macos_dmg.sh --app <Navis.app> --output <file.dmg> [--sign-identity <id>] [--notary-profile <profile>]

--sign-identity   codesign the DMG (default: unsigned)
--notary-profile  notarize and staple the DMG (needs --sign-identity)
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ART_DIR="${SCRIPT_DIR}/../assets/macos/dmg"
ICONSET_SRC="${SCRIPT_DIR}/../macos/Runner/Assets.xcassets/AppIcon.appiconset"
# Keep in sync with assets/macos/dmg/background.svg (points, 660x400 canvas).
WIN_W=660 WIN_H=400 ICON_SIZE=128 APP_X=170 APP_Y=200 APPS_X=490 APPS_Y=200
# Finder's window bounds include the title bar, the art is the content area.
TITLEBAR=28
VOLNAME="Navis"

APP="" OUT="" IDENTITY="" PROFILE=""
while (( $# )); do
  case "$1" in
    --app|--output|--sign-identity|--notary-profile)
      [[ $# -ge 2 ]] || { echo "Error: $1 needs a value." >&2; exit 2; }
      case "$1" in
        --app) APP="$2" ;; --output) OUT="$2" ;;
        --sign-identity) IDENTITY="$2" ;; --notary-profile) PROFILE="$2" ;;
      esac
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Error: unknown argument $1" >&2; usage >&2; exit 2 ;;
  esac
done
[[ -d "${APP}" && -f "${APP}/Contents/Info.plist" ]] || { echo "Error: --app must be a .app bundle." >&2; exit 2; }
[[ -n "${OUT}" ]] || { echo "Error: --output is required." >&2; exit 2; }
[[ -z "${PROFILE}" || -n "${IDENTITY}" ]] || { echo "Error: --notary-profile needs --sign-identity." >&2; exit 2; }
APP="$(cd "${APP}" && pwd)"
OUT="$(cd "$(dirname "${OUT}")" && pwd)/$(basename "${OUT}")"
APP_NAME="$(basename "${APP}")"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/navis-dmg-XXXXXX")"
MOUNT=""
cleanup() {
  if [[ -n "${MOUNT}" && -d "${MOUNT}" ]]; then hdiutil detach "${MOUNT}" -force >/dev/null 2>&1 || true; fi
  rm -rf "${WORK}"
}
trap cleanup EXIT

# Refuse a stale "Navis" volume: Finder scripting addresses the disk by name.
[[ ! -e "/Volumes/${VOLNAME}" ]] || { echo "Error: /Volumes/${VOLNAME} is already mounted; eject it first." >&2; exit 1; }

echo "==> Staging ${APP_NAME}"
STAGE="${WORK}/stage"
mkdir -p "${STAGE}/.background"
ditto "${APP}" "${STAGE}/${APP_NAME}"
ln -s /Applications "${STAGE}/Applications"
tiffutil -cathidpicheck "${ART_DIR}/background.png" "${ART_DIR}/background@2x.png" \
  -out "${STAGE}/.background/background.tiff"

echo "==> Building volume icon"
ICONSET="${WORK}/vol.iconset"
mkdir -p "${ICONSET}"
for s in 16 32 128 256 512; do
  cp "${ICONSET_SRC}/app_icon_${s}.png" "${ICONSET}/icon_${s}x${s}.png"
done
cp "${ICONSET_SRC}/app_icon_32.png" "${ICONSET}/icon_16x16@2x.png"
cp "${ICONSET_SRC}/app_icon_64.png" "${ICONSET}/icon_32x32@2x.png"
cp "${ICONSET_SRC}/app_icon_256.png" "${ICONSET}/icon_128x128@2x.png"
cp "${ICONSET_SRC}/app_icon_512.png" "${ICONSET}/icon_256x256@2x.png"
cp "${ICONSET_SRC}/app_icon_1024.png" "${ICONSET}/icon_512x512@2x.png"
iconutil -c icns "${ICONSET}" -o "${STAGE}/.VolumeIcon.icns"

echo "==> Creating disk image"
RW="${WORK}/rw.dmg"
SIZE_MB=$(( $(du -sm "${STAGE}" | cut -f1) + 40 ))
hdiutil create -srcfolder "${STAGE}" -volname "${VOLNAME}" -fs HFS+ -format UDRW -size "${SIZE_MB}m" "${RW}" >/dev/null
ATTACH="$(hdiutil attach "${RW}" -readwrite -noverify -noautoopen)"
MOUNT="$(printf '%s\n' "${ATTACH}" | awk -F'\t' '/\/Volumes\//{print $NF}' | tail -1)"
[[ "${MOUNT}" == "/Volumes/${VOLNAME}" ]] || { echo "Error: unexpected mount point '${MOUNT}'." >&2; exit 1; }
SetFile -a C "${MOUNT}"

echo "==> Laying out the Finder window"
cat > "${WORK}/layout.applescript" <<OSA
tell application "Finder"
  tell disk "${VOLNAME}"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, $((200 + WIN_W)), $((120 + WIN_H + TITLEBAR))}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to ${ICON_SIZE}
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "${APP_NAME}" of container window to {${APP_X}, ${APP_Y}}
    set position of item "Applications" of container window to {${APPS_X}, ${APPS_Y}}
    close
    open
    update without registering applications
    delay 2
    close
  end tell
end tell
OSA
# Finder scripting hangs when no GUI session is available (SSH, locked screen),
# so bound it instead of stalling the release.
perl -e 'alarm shift; exec @ARGV' 180 osascript "${WORK}/layout.applescript" \
  || { echo "Error: Finder layout failed or timed out (needs a logged-in GUI session)." >&2; exit 1; }
[[ -f "${MOUNT}/.DS_Store" ]] || { echo "Error: Finder did not write .DS_Store." >&2; exit 1; }
chmod -Rf go-w "${MOUNT}" || true
sync

detached=false
for _ in 1 2 3 4 5; do
  if hdiutil detach "${MOUNT}" >/dev/null 2>&1; then detached=true; break; fi
  sleep 2
done
[[ "${detached}" == true ]] || { echo "Error: could not detach ${MOUNT}." >&2; exit 1; }
MOUNT=""

echo "==> Compressing"
rm -f "${OUT}"
hdiutil convert "${RW}" -format ULFO -o "${OUT}" >/dev/null

if [[ -n "${IDENTITY}" ]]; then
  echo "==> Signing DMG"
  codesign --force --sign "${IDENTITY}" --timestamp "${OUT}"
  codesign --verify --verbose=2 "${OUT}"
fi
if [[ -n "${PROFILE}" ]]; then
  echo "==> Notarizing DMG"
  xcrun notarytool submit "${OUT}" --keychain-profile "${PROFILE}" --wait
  xcrun stapler staple "${OUT}"
  xcrun stapler validate "${OUT}"
fi
echo "==> ${OUT}"
