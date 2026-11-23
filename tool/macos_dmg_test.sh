#!/usr/bin/env bash
# Hermetic checks for the macOS DMG release wiring: the DMG is an accepted staged
# asset but never gets a manifest key (helpers and allowlist only; no hdiutil, so
# it runs on Linux CI). The upload, manifest and SHA256SUMS behavior is covered by
# dev_release_test.sh. No build, signing or upload. The layout is written by a pinned
# dmgbuild (no Finder scripting); the checks below read tool/macos_dmg.sh as text.
# Optional env: R2_SCRIPT / DIST_LIB override the files under test.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail() { echo "macos_dmg_test: $*" >&2; exit 1; }
DMG_SCRIPT="${DMG_SCRIPT:-${SCRIPT_DIR}/macos_dmg.sh}"
R2_SCRIPT="${R2_SCRIPT:-${SCRIPT_DIR}/r2_publish.sh}"
DIST_LIB="${DIST_LIB:-${SCRIPT_DIR}/lib/release_dist.sh}"

eval "$(sed -n '/^asset_key_for()/,/^}/p' "${R2_SCRIPT}")"
[[ "$(asset_key_for navis-v1.5.2-macos.zip)" == macosBundle ]] || fail "zip must stay the macosBundle updater asset"
[[ -z "$(asset_key_for navis-v1.5.2-macos.dmg)" ]] || fail "DMG must not get a manifest key"
[[ -z "$(asset_key_for navis-dev-v1.5.2-dev.1-macos.dmg)" ]] || fail "dev DMG must not get a manifest key"
eval "$(sed -n '/^content_type_for()/,/^}/p' "${R2_SCRIPT}")"
[[ "$(content_type_for navis-v1.5.2-macos.dmg)" == application/x-apple-diskimage ]] || fail "DMG content type"

# The staged-bundle allowlist accepts the DMG next to the zip.
tmp="$(mktemp -d "${TMPDIR:-/tmp}/navis-dmg-test-XXXXXX")"
trap 'rm -rf "${tmp}"' EXIT
bundle="${tmp}/v1.5.2"
mkdir -p "${bundle}"
printf 'zip\n' > "${bundle}/navis-v1.5.2-macos.zip"
printf 'dmg\n' > "${bundle}/navis-v1.5.2-macos.dmg"
printf 'navis-v1.5.2-macos.zip\nnavis-v1.5.2-macos.dmg\n' > "${bundle}/assets.txt"
printf 'notes\n' > "${bundle}/release-notes.md"
printf '{"schema":1,"tag":"v1.5.2","channel":"stable","source_commit":"%s","prerelease":false}\n' \
  1111111111111111111111111111111111111111 > "${bundle}/release.json"
source "${DIST_LIB}"
ASSET_NAMES=(navis-v1.5.2-macos.zip navis-v1.5.2-macos.dmg)
release_dist_checksums "${bundle}" > "${bundle}/SHA256SUMS"
VERSION=v1.5.2 PUBLISH_FROM="${bundle}" UPDATE_CHANNEL=stable CHANNEL_EXPLICIT=false FORCE_PRERELEASE=false
ASSET_NAMES=() ASSET_FILES=()
load_release_dist >/dev/null || fail "staged bundle with a macOS DMG was rejected"
[[ "${ASSET_NAMES[*]}" == "navis-v1.5.2-macos.zip navis-v1.5.2-macos.dmg" ]] || fail "DMG missing from loaded assets"
echo "macos dmg: allowlist accepts the DMG, manifest key stays zip-only OK"

# The layout comes from dmgbuild (writes .DS_Store directly), never from Finder:
# Finder scripting hangs without an Automation prompt on a background session.
! grep -Eq 'osascript|tell application|hdiutil (attach|convert)' "${DMG_SCRIPT}" || fail "DMG script must not script Finder"
grep -Eq 'uvx --from "dmgbuild==[0-9]+(\.[0-9]+)+"' "${DMG_SCRIPT}" || fail "DMG script must run a pinned dmgbuild via uvx"
grep -q 'command -v uvx' "${DMG_SCRIPT}" || fail "DMG script must fail early when uvx is missing"
# Render the generated settings file and check what dmgbuild will receive.
command -v python3 >/dev/null || fail "python3 is required for the settings check"
# Take the layout constants from the script itself, so changing them there fails here.
eval "$(grep -E '^(WIN_W|TITLEBAR|VOLNAME)=' "${DMG_SCRIPT}")"
[[ "${VOLNAME:-}" == Navis ]] || fail "volume name must stay Navis"
grep -q -- '-D "background=${ART_DIR}/background.png"' "${DMG_SCRIPT}" || fail "background must be background.png (dmgbuild adds @2x)"
[[ -f "${SCRIPT_DIR}/../assets/macos/dmg/background@2x.png" ]] || fail "background@2x.png missing"
APP_NAME=Navis.app
eval "cat <<SETTINGS
$(sed -n "/<<SETTINGS\$/,/^SETTINGS\$/{//!p;}" "${DMG_SCRIPT}")
SETTINGS" > "${tmp}/settings.py"
python3 - "${tmp}/settings.py" <<'PY' || fail "generated dmgbuild settings are wrong"
import sys
d = {"app": "/x/Navis.app", "icon": "/x/v.icns", "background": "/x/bg.png"}
ns = {"defines": d}
exec(open(sys.argv[1]).read(), ns)
assert ns["format"] == "ULFO", ns["format"]
assert ns["window_rect"] == ((200, 120), (660, 428)), ns["window_rect"]
assert ns["icon_size"] == 128 and ns["text_size"] == 13
assert ns["icon_locations"] == {"Navis.app": (170, 200), "Applications": (490, 200)}, ns["icon_locations"]
assert ns["background"] == "/x/bg.png" and ns["icon"] == "/x/v.icns"
assert ns["files"] == ["/x/Navis.app"] and ns["symlinks"] == {"Applications": "/Applications"}
assert not ns["show_toolbar"] and not ns["show_status_bar"]
PY
echo "macos dmg: dmgbuild settings carry window, icon positions and background OK"
