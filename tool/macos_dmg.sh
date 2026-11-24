#!/usr/bin/env bash
# Builds the Navis drag-to-Applications DMG for first installs. The self-updater
# keeps using the zip; see docs/release/release-macos.md#dmg-first-installs.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./tool/macos_dmg.sh --app <Navis.app> --output <file.dmg> [--sign-identity <id>] [notary auth]

--sign-identity   codesign the DMG (default: unsigned)
--notary-key <AuthKey.p8> --notary-key-id <id> --notary-issuer <id>
                  notarize and staple with an App Store Connect API key (needs --sign-identity)
--notary-profile  notarize and staple with a notarytool keychain profile instead
                  (needs --sign-identity; an API key wins when both are given)
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ART_DIR="${SCRIPT_DIR}/../assets/macos/dmg"
ICONSET_SRC="${SCRIPT_DIR}/../macos/Runner/Assets.xcassets/AppIcon.appiconset"
# Keep in sync with assets/macos/dmg/background.svg (points, 660x400 canvas).
WIN_W=660 WIN_H=400 ICON_SIZE=128 APP_X=170 APP_Y=190 APPS_X=490 APPS_Y=190
# The window bounds include the title bar, the art is the content area.
TITLEBAR=28
VOLNAME="Install Navis"

APP="" OUT="" IDENTITY="" PROFILE="" NKEY="" NKEY_ID="" NISSUER=""
while (( $# )); do
  case "$1" in
    --app|--output|--sign-identity|--notary-profile|--notary-key|--notary-key-id|--notary-issuer)
      [[ $# -ge 2 ]] || { echo "Error: $1 needs a value." >&2; exit 2; }
      case "$1" in
        --app) APP="$2" ;; --output) OUT="$2" ;;
        --sign-identity) IDENTITY="$2" ;; --notary-profile) PROFILE="$2" ;;
        --notary-key) NKEY="$2" ;; --notary-key-id) NKEY_ID="$2" ;; --notary-issuer) NISSUER="$2" ;;
      esac
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Error: unknown argument $1" >&2; usage >&2; exit 2 ;;
  esac
done
[[ -d "${APP}" && -f "${APP}/Contents/Info.plist" ]] || { echo "Error: --app must be a .app bundle." >&2; exit 2; }
[[ -n "${OUT}" ]] || { echo "Error: --output is required." >&2; exit 2; }
# The API key wins over a profile; messages name options, never values.
NOTARY_AUTH=()
if [[ -n "${NKEY}${NKEY_ID}${NISSUER}" ]]; then
  [[ -n "${NKEY}" && -n "${NKEY_ID}" && -n "${NISSUER}" ]] || { echo "Error: --notary-key, --notary-key-id and --notary-issuer go together." >&2; exit 2; }
  [[ -f "${NKEY}" && -r "${NKEY}" ]] || { echo "Error: --notary-key does not point to a readable file." >&2; exit 2; }
  NOTARY_AUTH=(--key "${NKEY}" --key-id "${NKEY_ID}" --issuer "${NISSUER}")
elif [[ -n "${PROFILE}" ]]; then
  NOTARY_AUTH=(--keychain-profile "${PROFILE}")
fi
[[ ${#NOTARY_AUTH[@]} -eq 0 || -n "${IDENTITY}" ]] || { echo "Error: notarization (--notary-key or --notary-profile) needs --sign-identity." >&2; exit 2; }
APP="$(cd "${APP}" && pwd)"
OUT="$(cd "$(dirname "${OUT}")" && pwd)/$(basename "${OUT}")"
APP_NAME="$(basename "${APP}")"

command -v uvx >/dev/null || { echo "Error: uvx not found; install uv (https://docs.astral.sh/uv/ or: brew install uv)." >&2; exit 1; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/navis-dmg-XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

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
iconutil -c icns "${ICONSET}" -o "${WORK}/vol.icns"

# dmgbuild writes the window layout (.DS_Store) itself, so it needs no GUI session
# and no Finder Automation permission. It builds the HiDPI background from
# background.png + background@2x.png and copies the app with ditto.
cat > "${WORK}/settings.py" <<SETTINGS
files = [defines["app"]]
symlinks = {"Applications": "/Applications"}
icon = defines["icon"]
background = defines["background"]
format = "ULFO"
show_toolbar = False
show_status_bar = False
window_rect = ((200, 120), (${WIN_W}, $((WIN_H + TITLEBAR))))
icon_size = ${ICON_SIZE}
text_size = 13
icon_locations = {
    "${APP_NAME}": (${APP_X}, ${APP_Y}),
    "Applications": (${APPS_X}, ${APPS_Y}),
}
SETTINGS

echo "==> Creating disk image"
rm -f "${OUT}"
uvx --from "dmgbuild==2.0.0" dmgbuild -s "${WORK}/settings.py" \
  -D "app=${APP}" -D "icon=${WORK}/vol.icns" -D "background=${ART_DIR}/background.png" \
  "${VOLNAME}" "${OUT}"

if [[ -n "${IDENTITY}" ]]; then
  echo "==> Signing DMG"
  codesign --force --sign "${IDENTITY}" --timestamp "${OUT}"
  codesign --verify --verbose=2 "${OUT}"
fi
if [[ ${#NOTARY_AUTH[@]} -gt 0 ]]; then
  echo "==> Notarizing DMG"
  xcrun notarytool submit "${OUT}" "${NOTARY_AUTH[@]}" --wait
  xcrun stapler staple "${OUT}"
  xcrun stapler validate "${OUT}"
fi
echo "==> ${OUT}"
