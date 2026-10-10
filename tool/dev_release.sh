#!/usr/bin/env bash
# Build, publish and retain only the current Navis Dev arm64 APK on R2.
# Usage: ./tool/dev_release.sh [--dry-run]
# Dry-run builds/signs locally and prints the remote PUT/VERIFY/DELETE plan.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.."
PUBLISH_ARGS=()
for arg in "$@"; do
  case "${arg}" in
    --dry-run) PUBLISH_ARGS+=(--dry-run) ;;
    *) echo "Usage: ./tool/dev_release.sh [--dry-run]" >&2; exit 1 ;;
  esac
done
# Like release.sh, refuse debug signing before loading any secrets or building.
[[ -f android/key.properties ]] || {
  echo "Error: android/key.properties is required for Android releases." >&2; exit 1;
}
if [[ -f "${SCRIPT_DIR}/release.env" ]]; then
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/release.env"
fi

# Serialize the entire build/publish/cleanup on this coordinator, including
# different worktrees. The allocator has its own lock for manual dev APK builds.
mkdir -p "${HOME}/.cache/navis/dev-releases"
exec 9>"${HOME}/.cache/navis/dev-releases/release.lock"
flock 9
VERSION="$(sed -nE 's/^version: ([0-9]+\.[0-9]+\.[0-9]+)\+.*/\1/p' pubspec.yaml)"
[[ -n "${VERSION}" ]] || { echo "Error: cannot read pubspec version." >&2; exit 1; }
BUILD="$(python3 "${SCRIPT_DIR}/dev_build_number.py")"
TAG="v${VERSION}-dev.${BUILD}"
"${SCRIPT_DIR}/r2_publish.sh" check --tag="${TAG}" --channel=dev --build="${BUILD}"
SYMBOLS_DIR="${HOME}/.cache/navis/dev-releases/${TAG}/symbols"
mkdir -p "${SYMBOLS_DIR}" build/dev-releases
APK="build/dev-releases/Navis-Dev-${VERSION}-${BUILD}-arm64.apk"
echo "==> Building ${TAG}; symbols: ${SYMBOLS_DIR}"
NAVIS_APP_ID_SUFFIX=.dev NAVIS_APP_NAME='Navis Dev' NAVIS_ALLOW_DEBUG_SIGNED_RELEASE=0 \
  "${SCRIPT_DIR}/dev_app.sh" apk --target-platform=android-arm64 \
  --obfuscate "--split-debug-info=${SYMBOLS_DIR}" "--build-number=${BUILD}" "--build-name=${VERSION}"
cp build/app/outputs/flutter-apk/app-sideload-release.apk "${APK}"

# Apply release.sh's metadata and signer checks before any remote write. Never
# print key.properties or passwords; keytool gets its password via environment.
SDK_DIR="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-${HOME}/Android/Sdk}}"
TOOLS_DIR="$(find "${SDK_DIR}/build-tools" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -1)"
[[ -x "${TOOLS_DIR}/aapt" && -x "${TOOLS_DIR}/apksigner" ]] || {
  echo "Error: Android aapt/apksigner build tools are required." >&2; exit 1;
}
BADGING="$("${TOOLS_DIR}/aapt" dump badging "${APK}")"
APK_PACKAGE="$(sed -n "s/^package: name='\([^']*\)'.*/\1/p" <<< "${BADGING}")"
APK_CODE="$(sed -n "s/^package:.* versionCode='\([^']*\)'.*/\1/p" <<< "${BADGING}")"
APK_VERSION="$(sed -n "s/^package:.* versionName='\([^']*\)'.*/\1/p" <<< "${BADGING}")"
[[ "${APK_PACKAGE}" == com.navis.app.navis.dev && "${APK_CODE}" == "${BUILD}" && "${APK_VERSION}" == "${VERSION}" ]] || {
  echo "Error: dev APK package/version metadata does not match the release plan." >&2; exit 1;
}
STORE_FILE="$(sed -n 's/^storeFile=//p' android/key.properties)"
STORE_PASSWORD="$(sed -n 's/^storePassword=//p' android/key.properties)"
KEY_ALIAS="$(sed -n 's/^keyAlias=//p' android/key.properties)"
[[ -n "${STORE_FILE}" && -n "${STORE_PASSWORD}" && -n "${KEY_ALIAS}" ]] || {
  echo "Error: incomplete Android signing properties." >&2; exit 1;
}
[[ "${STORE_FILE}" == /* ]] || STORE_FILE="${SCRIPT_DIR}/../android/app/${STORE_FILE}"
EXPECTED_CERT="$(STORE_PASSWORD="${STORE_PASSWORD}" keytool -list -v -keystore "${STORE_FILE}" \
  -storepass:env STORE_PASSWORD -alias "${KEY_ALIAS}" 2>/dev/null \
  | awk -F': ' '/SHA256:/{gsub(":", "", $2); print tolower($2); exit}')"
ACTUAL_CERT="$("${TOOLS_DIR}/apksigner" verify --print-certs "${APK}" \
  | awk '/SHA-256 digest/{print tolower($NF); exit}')"
[[ -n "${EXPECTED_CERT}" && "${EXPECTED_CERT}" == "${ACTUAL_CERT}" ]] || {
  echo "Error: dev APK release signer mismatch." >&2; exit 1;
}
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/scan_artifact_secret.sh"
if [[ -n "${NAVIS_LASTFM_API_KEY:-}" ]]; then
  scan_artifact_for_secret "${APK}" "${NAVIS_LASTFM_API_KEY}"
fi
"${SCRIPT_DIR}/r2_publish.sh" publish --tag="${TAG}" --channel=dev --build="${BUILD}" \
  --prune-previous "${PUBLISH_ARGS[@]}" "${APK}"
echo "APK download URL: https://downloads.porthorion.com/${R2_PREFIX:-navis}/releases/${TAG}/$(basename "${APK}")"
