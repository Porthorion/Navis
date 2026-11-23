#!/usr/bin/env bash
# Hermetic checks for the macOS DMG release wiring: the DMG is an accepted staged
# asset but never an updater (manifest) asset. No build, signing or upload.
# Optional env: R2_SCRIPT / DIST_LIB override the files under test.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail() { echo "macos_dmg_test: $*" >&2; exit 1; }
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
