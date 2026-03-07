#!/usr/bin/env bash
# tool/release.sh — Local release script for Navis.
#
# Builds selected release artifacts, bumps pubspec.yaml, tags/merges/pushes,
# creates a Forgejo release, and uploads built assets.
#
# Usage:
#   ./tool/release.sh <version> [options]
#
# Options:
#   --skip-checks              Skip ./tool/check.sh
#   --ipa                      Shortcut for --targets=android,ios
#   --targets=<csv>            Build targets: android,ios,macos,linux,windows
#   --all-platforms            Same as --targets=android,ios,macos,linux,windows
#   --linux-package=<mode>     Linux output: bundle (default) or deb
#   --channel=<stable|dev>     Release/update channel (default: stable)
#   --prerelease               Force prerelease=true on Forgejo release
#
# Examples:
#   ./tool/release.sh v0.3.0
#   ./tool/release.sh v0.3.0 --channel=dev
#   ./tool/release.sh v0.3.0 --targets=android,macos --channel=stable
#   ./tool/release.sh v0.3.0 --ipa
#
# Notes:
#   - Channel `dev` defaults to sidecar app identity for Android builds:
#       NAVIS_APP_ID_SUFFIX=.dev, NAVIS_APP_NAME="Navis Dev"
#   - Release assets are channel-prefixed:
#       stable: navis-<tag>.*
#       dev:    navis-dev-<tag>.*

set -euo pipefail

# ─── Args ───────────────────────────────────────────────────────────────────
VERSION=""
SKIP_CHECKS=false
TARGETS_SPEC="android"
LINUX_PACKAGE_MODE="bundle"
UPDATE_CHANNEL="stable"
FORCE_PRERELEASE=false

for arg in "$@"; do
  case "${arg}" in
    --skip-checks) SKIP_CHECKS=true ;;
    --ipa) TARGETS_SPEC="android,ios" ;;
    --targets=*) TARGETS_SPEC="${arg#--targets=}" ;;
    --all-platforms) TARGETS_SPEC="android,ios,macos,linux,windows" ;;
    --linux-package=*) LINUX_PACKAGE_MODE="${arg#--linux-package=}" ;;
    --channel=*) UPDATE_CHANNEL="${arg#--channel=}" ;;
    --prerelease) FORCE_PRERELEASE=true ;;
    v*.*) VERSION="${arg}" ;;
    *)
      echo "Unknown argument: ${arg}"
      echo "Usage: ./tool/release.sh <version> [--skip-checks] [--ipa] [--targets=<csv>] [--all-platforms] [--linux-package=<bundle|deb>] [--channel=<stable|dev>] [--prerelease]"
      exit 1
      ;;
  esac
done

if [[ -z "${VERSION}" ]]; then
  echo "Usage: ./tool/release.sh <version> [--skip-checks] [--ipa] [--targets=<csv>] [--all-platforms] [--linux-package=<bundle|deb>] [--channel=<stable|dev>] [--prerelease]"
  echo "  e.g. ./tool/release.sh v0.3.0 --targets=android,macos"
  exit 1
fi

LINUX_PACKAGE_MODE="$(echo "${LINUX_PACKAGE_MODE}" | tr '[:upper:]' '[:lower:]')"
if [[ "${LINUX_PACKAGE_MODE}" != "bundle" && "${LINUX_PACKAGE_MODE}" != "deb" ]]; then
  echo "Error: --linux-package must be 'bundle' or 'deb'"
  exit 1
fi

UPDATE_CHANNEL="$(echo "${UPDATE_CHANNEL}" | tr '[:upper:]' '[:lower:]')"
if [[ "${UPDATE_CHANNEL}" != "stable" && "${UPDATE_CHANNEL}" != "dev" ]]; then
  echo "Error: --channel must be 'stable' or 'dev'"
  exit 1
fi

# ─── Version ────────────────────────────────────────────────────────────────
SEMVER="${VERSION#v}"
IFS='.' read -r MAJOR MINOR PATCH <<< "${SEMVER%%[-+]*}"
BUILD_NUMBER=$(( (MAJOR * 10000) + (MINOR * 100) + PATCH ))

# ─── Parse targets ──────────────────────────────────────────────────────────
BUILD_ANDROID=false
BUILD_IOS=false
BUILD_MACOS=false
BUILD_LINUX=false
BUILD_WINDOWS=false

IFS=',' read -r -a TARGETS <<< "${TARGETS_SPEC}"
for target in "${TARGETS[@]}"; do
  t="$(echo "${target}" | xargs | tr '[:upper:]' '[:lower:]')"
  case "${t}" in
    android) BUILD_ANDROID=true ;;
    ios) BUILD_IOS=true ;;
    macos) BUILD_MACOS=true ;;
    linux) BUILD_LINUX=true ;;
    windows) BUILD_WINDOWS=true ;;
    "") ;;
    *)
      echo "Error: Unsupported target '${t}'. Allowed: android,ios,macos,linux,windows"
      exit 1
      ;;
  esac
done

if [[ "${BUILD_ANDROID}" == "false" && "${BUILD_IOS}" == "false" && "${BUILD_MACOS}" == "false" && "${BUILD_LINUX}" == "false" && "${BUILD_WINDOWS}" == "false" ]]; then
  echo "Error: No valid build targets selected."
  exit 1
fi

# ─── Env file ───────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/release.env" ]]; then
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/release.env"
fi

# ─── Validate env ───────────────────────────────────────────────────────────
: "${FORGEJO_URL:?Set FORGEJO_URL in tool/release.env}"
: "${FORGEJO_REPO:?Set FORGEJO_REPO in tool/release.env}"
: "${FORGEJO_TOKEN:?Set FORGEJO_TOKEN in tool/release.env}"

# ─── Validate tools ─────────────────────────────────────────────────────────
for tool in jq flutter git curl; do
  if ! command -v "${tool}" &>/dev/null; then
    echo "Error: '${tool}' is required but not found on PATH."
    exit 1
  fi
done

if [[ "${BUILD_ANDROID}" == "true" ]]; then
  if ! command -v keytool &>/dev/null; then
    echo "Error: 'keytool' is required for Android signing validation."
    exit 1
  fi
fi

# ─── Root ───────────────────────────────────────────────────────────────────
cd "${SCRIPT_DIR}/.."

UNAME="$(uname)"
if [[ "${BUILD_IOS}" == "true" || "${BUILD_MACOS}" == "true" ]]; then
  if [[ "${UNAME}" != "Darwin" ]]; then
    echo "Error: iOS/macOS builds require macOS host."
    exit 1
  fi
  if ! command -v xcodebuild &>/dev/null; then
    echo "Error: xcodebuild not found. Install Xcode first."
    exit 1
  fi
fi

if [[ "${BUILD_LINUX}" == "true" && "${UNAME}" != "Linux" ]]; then
  echo "Error: Linux builds require a Linux host."
  exit 1
fi

if [[ "${BUILD_WINDOWS}" == "true" && "${OS:-}" != "Windows_NT" ]]; then
  echo "Error: Windows builds require a Windows host shell."
  exit 1
fi

# ─── Channel defaults ───────────────────────────────────────────────────────
ASSET_PREFIX="navis"
RELEASE_PRERELEASE=false
if [[ "${UPDATE_CHANNEL}" == "dev" ]]; then
  ASSET_PREFIX="navis-dev"
  RELEASE_PRERELEASE=true
  export NAVIS_APP_ID_SUFFIX="${NAVIS_APP_ID_SUFFIX:-.dev}"
  export NAVIS_APP_NAME="${NAVIS_APP_NAME:-Navis Dev}"
fi
if [[ "${FORCE_PRERELEASE}" == "true" ]]; then
  RELEASE_PRERELEASE=true
fi

DART_DEFINE_ARGS=("--dart-define=NAVIS_UPDATE_CHANNEL=${UPDATE_CHANNEL}")

# ─── Clean tree ─────────────────────────────────────────────────────────────
if [[ -n "$(git status --porcelain)" ]]; then
  echo "Error: Working tree is not clean. Commit or stash changes first."
  git status --short
  exit 1
fi

CURRENT_BRANCH="$(git branch --show-current)"

# ─── Checks ─────────────────────────────────────────────────────────────────
if [[ "${SKIP_CHECKS}" == "false" ]]; then
  echo "==> Running quality checks (./tool/check.sh)..."
  "${SCRIPT_DIR}/check.sh"
else
  echo "==> Skipping quality checks (--skip-checks)."
fi

# ─── Version bump ───────────────────────────────────────────────────────────
PUBSPEC="${SCRIPT_DIR}/../pubspec.yaml"
echo "==> Bumping pubspec.yaml to ${SEMVER}+${BUILD_NUMBER}..."
sed -i.bak "s/^version: .*/version: ${SEMVER}+${BUILD_NUMBER}/" "${PUBSPEC}"
rm -f "${PUBSPEC}.bak"

# ─── Build artifacts ────────────────────────────────────────────────────────
ASSET_FILES=()
ASSET_NAMES=()

if [[ "${BUILD_ANDROID}" == "true" ]]; then
  echo "==> Building Android APK..."
  flutter build apk --release "${DART_DEFINE_ARGS[@]}"

  APK_PATH="${SCRIPT_DIR}/../build/app/outputs/flutter-apk/app-release.apk"
  APK_ASSET_NAME="${ASSET_PREFIX}-${VERSION}.apk"
  APK_ASSET="${SCRIPT_DIR}/../${APK_ASSET_NAME}"

  if [[ ! -f "${APK_PATH}" ]]; then
    echo "Error: APK not found at ${APK_PATH}"
    exit 1
  fi

  cp "${APK_PATH}" "${APK_ASSET}"
  ASSET_FILES+=("${APK_ASSET}")
  ASSET_NAMES+=("${APK_ASSET_NAME}")
  echo "    APK -> ${APK_ASSET_NAME}"

  ANDROID_SDK_DIR="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
  if [[ ! -d "${ANDROID_SDK_DIR}/build-tools" ]]; then
    echo "Error: Android build-tools not found under ${ANDROID_SDK_DIR}/build-tools"
    exit 1
  fi
  BUILD_TOOLS_DIR="$(find "${ANDROID_SDK_DIR}/build-tools" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -1)"
  AAPT_BIN="${BUILD_TOOLS_DIR}/aapt"
  APKSIGNER_BIN="${BUILD_TOOLS_DIR}/apksigner"
  if [[ ! -x "${AAPT_BIN}" || ! -x "${APKSIGNER_BIN}" ]]; then
    echo "Error: Could not find executable aapt/apksigner in ${BUILD_TOOLS_DIR}"
    exit 1
  fi

  echo "==> Validating APK metadata/signing..."
  BADGING="$(${AAPT_BIN} dump badging "${APK_ASSET}")"
  APK_PACKAGE="$(echo "${BADGING}" | sed -n "s/^package: name='\([^']*\)'.*/\1/p" | head -1)"
  APK_VERSION_CODE="$(echo "${BADGING}" | sed -n "s/^package:.* versionCode='\([^']*\)'.*/\1/p" | head -1)"
  APK_VERSION_NAME="$(echo "${BADGING}" | sed -n "s/^package:.* versionName='\([^']*\)'.*/\1/p" | head -1)"

  EXPECTED_APK_PACKAGE="com.navis.app.navis${NAVIS_APP_ID_SUFFIX:-}"
  if [[ "${APK_PACKAGE}" != "${EXPECTED_APK_PACKAGE}" ]]; then
    echo "Error: APK package mismatch. Expected ${EXPECTED_APK_PACKAGE}, got ${APK_PACKAGE:-<empty>}"
    exit 1
  fi
  if [[ "${APK_VERSION_NAME}" != "${SEMVER}" ]]; then
    echo "Error: APK versionName mismatch. Expected ${SEMVER}, got ${APK_VERSION_NAME:-<empty>}"
    exit 1
  fi
  if [[ "${APK_VERSION_CODE}" != "${BUILD_NUMBER}" ]]; then
    echo "Error: APK versionCode mismatch. Expected ${BUILD_NUMBER}, got ${APK_VERSION_CODE:-<empty>}"
    exit 1
  fi

  if [[ -f "${SCRIPT_DIR}/../android/key.properties" ]]; then
    STORE_FILE="$(grep -E '^storeFile=' "${SCRIPT_DIR}/../android/key.properties" | cut -d= -f2-)"
    STORE_PASSWORD="$(grep -E '^storePassword=' "${SCRIPT_DIR}/../android/key.properties" | cut -d= -f2-)"
    KEY_ALIAS="$(grep -E '^keyAlias=' "${SCRIPT_DIR}/../android/key.properties" | cut -d= -f2-)"

    if [[ -z "${STORE_FILE}" || -z "${STORE_PASSWORD}" || -z "${KEY_ALIAS}" ]]; then
      echo "Error: key.properties is missing storeFile/storePassword/keyAlias"
      exit 1
    fi

    EXPECTED_CERT_SHA256="$(keytool -list -v \
      -keystore "${STORE_FILE}" \
      -storepass "${STORE_PASSWORD}" \
      -alias "${KEY_ALIAS}" | awk -F': ' '/SHA256:/{gsub(":", "", $2); print tolower($2); exit}')"
    ACTUAL_CERT_SHA256="$(${APKSIGNER_BIN} verify --print-certs "${APK_ASSET}" | awk -F': ' '/Signer #1 certificate SHA-256 digest:/{print tolower($2); exit}')"

    if [[ -z "${EXPECTED_CERT_SHA256}" || -z "${ACTUAL_CERT_SHA256}" ]]; then
      echo "Error: Failed to read APK signing certificate fingerprint."
      exit 1
    fi

    if [[ "${EXPECTED_CERT_SHA256}" != "${ACTUAL_CERT_SHA256}" ]]; then
      echo "Error: APK signer mismatch."
      echo "  Expected: ${EXPECTED_CERT_SHA256}"
      echo "  Actual:   ${ACTUAL_CERT_SHA256}"
      exit 1
    fi
  fi

  echo "    APK metadata/signing OK"
fi

if [[ "${BUILD_IOS}" == "true" ]]; then
  echo "==> Building iOS IPA (ad-hoc)..."
  flutter build ipa --release --export-method ad-hoc "${DART_DEFINE_ARGS[@]}"

  IPA_DIR="${SCRIPT_DIR}/../build/ios/ipa"
  FOUND_IPA="$(find "${IPA_DIR}" -maxdepth 2 -name "*.ipa" | head -1)"
  if [[ -z "${FOUND_IPA}" ]]; then
    echo "Error: IPA not found under ${IPA_DIR}"
    exit 1
  fi

  IPA_ASSET_NAME="${ASSET_PREFIX}-${VERSION}.ipa"
  IPA_ASSET="${SCRIPT_DIR}/../${IPA_ASSET_NAME}"
  cp "${FOUND_IPA}" "${IPA_ASSET}"
  ASSET_FILES+=("${IPA_ASSET}")
  ASSET_NAMES+=("${IPA_ASSET_NAME}")
  echo "    IPA -> ${IPA_ASSET_NAME}"
fi

if [[ "${BUILD_MACOS}" == "true" ]]; then
  echo "==> Building macOS app..."
  flutter build macos --release "${DART_DEFINE_ARGS[@]}"

  MACOS_RELEASE_DIR="${SCRIPT_DIR}/../build/macos/Build/Products/Release"
  MACOS_APP_PATH="$(find "${MACOS_RELEASE_DIR}" -maxdepth 1 -type d -name "*.app" | head -1)"
  if [[ -z "${MACOS_APP_PATH}" ]]; then
    echo "Error: macOS .app bundle not found under ${MACOS_RELEASE_DIR}"
    exit 1
  fi

  MACOS_ASSET_NAME="${ASSET_PREFIX}-${VERSION}-macos.zip"
  MACOS_ASSET="${SCRIPT_DIR}/../${MACOS_ASSET_NAME}"
  ditto -c -k --keepParent "${MACOS_APP_PATH}" "${MACOS_ASSET}"
  ASSET_FILES+=("${MACOS_ASSET}")
  ASSET_NAMES+=("${MACOS_ASSET_NAME}")
  echo "    macOS -> ${MACOS_ASSET_NAME}"
fi

if [[ "${BUILD_LINUX}" == "true" ]]; then
  echo "==> Building Linux bundle..."
  flutter build linux --release "${DART_DEFINE_ARGS[@]}"

  LINUX_BUNDLE_DIR="$(find "${SCRIPT_DIR}/../build/linux" -type d -path "*/release/bundle" | head -1)"
  if [[ -z "${LINUX_BUNDLE_DIR}" ]]; then
    echo "Error: Linux bundle not found under build/linux"
    exit 1
  fi

  if [[ "${LINUX_PACKAGE_MODE}" == "deb" ]]; then
    if ! command -v dpkg-deb &>/dev/null; then
      echo "Error: --linux-package=deb requires dpkg-deb on Linux host."
      exit 1
    fi

    DEB_PACKAGE_NAME="${ASSET_PREFIX}"
    DEB_STAGE_DIR="${SCRIPT_DIR}/../build/linux/deb_stage"
    rm -rf "${DEB_STAGE_DIR}"
    mkdir -p "${DEB_STAGE_DIR}/DEBIAN"
    mkdir -p "${DEB_STAGE_DIR}/opt/${DEB_PACKAGE_NAME}"

    cp -R "${LINUX_BUNDLE_DIR}/." "${DEB_STAGE_DIR}/opt/${DEB_PACKAGE_NAME}/"

    cat > "${DEB_STAGE_DIR}/DEBIAN/control" <<CONTROL
Package: ${DEB_PACKAGE_NAME}
Version: ${SEMVER}
Section: sound
Priority: optional
Architecture: amd64
Maintainer: Navis Team <noreply@example.com>
Description: Navis music player
Channel: ${UPDATE_CHANNEL}
CONTROL

    DEB_ASSET_NAME="${ASSET_PREFIX}-${VERSION}-linux-amd64.deb"
    DEB_ASSET="${SCRIPT_DIR}/../${DEB_ASSET_NAME}"
    dpkg-deb --build "${DEB_STAGE_DIR}" "${DEB_ASSET}" >/dev/null
    rm -rf "${DEB_STAGE_DIR}"

    ASSET_FILES+=("${DEB_ASSET}")
    ASSET_NAMES+=("${DEB_ASSET_NAME}")
    echo "    Linux -> ${DEB_ASSET_NAME}"
  else
    LINUX_ASSET_NAME="${ASSET_PREFIX}-${VERSION}-linux.tar.gz"
    LINUX_ASSET="${SCRIPT_DIR}/../${LINUX_ASSET_NAME}"
    tar -czf "${LINUX_ASSET}" -C "${LINUX_BUNDLE_DIR}" .
    ASSET_FILES+=("${LINUX_ASSET}")
    ASSET_NAMES+=("${LINUX_ASSET_NAME}")
    echo "    Linux -> ${LINUX_ASSET_NAME}"
  fi
fi

if [[ "${BUILD_WINDOWS}" == "true" ]]; then
  echo "==> Building Windows bundle..."
  flutter build windows --release "${DART_DEFINE_ARGS[@]}"

  WINDOWS_RELEASE_DIR="${SCRIPT_DIR}/../build/windows/x64/runner/Release"
  if [[ ! -d "${WINDOWS_RELEASE_DIR}" ]]; then
    echo "Error: Windows release dir not found at ${WINDOWS_RELEASE_DIR}"
    exit 1
  fi

  WINDOWS_ASSET_NAME="${ASSET_PREFIX}-${VERSION}-windows.zip"
  WINDOWS_ASSET="${SCRIPT_DIR}/../${WINDOWS_ASSET_NAME}"

  if command -v powershell.exe &>/dev/null; then
    powershell.exe -NoProfile -Command "Compress-Archive -Path '${WINDOWS_RELEASE_DIR//\//\\}\\*' -DestinationPath '${WINDOWS_ASSET//\//\\}' -Force" >/dev/null
  elif command -v zip &>/dev/null; then
    (cd "${WINDOWS_RELEASE_DIR}" && zip -r "${WINDOWS_ASSET}" . >/dev/null)
  else
    echo "Error: Need either powershell.exe or zip to package Windows release."
    exit 1
  fi

  ASSET_FILES+=("${WINDOWS_ASSET}")
  ASSET_NAMES+=("${WINDOWS_ASSET_NAME}")
  echo "    Windows -> ${WINDOWS_ASSET_NAME}"
fi

# ─── Commit bump ────────────────────────────────────────────────────────────
echo "==> Committing pubspec bump..."
git add pubspec.yaml
if git diff --cached --quiet; then
  echo "    pubspec.yaml already at ${SEMVER}+${BUILD_NUMBER} — skipping commit."
else
  git commit -m "chore: bump version to ${SEMVER}+${BUILD_NUMBER} for release ${VERSION} (${UPDATE_CHANNEL})"
fi

# ─── Merge/tag/push ─────────────────────────────────────────────────────────
echo "==> Merging ${CURRENT_BRANCH} -> main..."
git checkout main
git merge --ff-only "${CURRENT_BRANCH}"

echo "==> Tagging ${VERSION} on main..."
git tag -a "${VERSION}" -m "Release ${VERSION} (${UPDATE_CHANNEL})"

echo "==> Pushing main, ${CURRENT_BRANCH}, and tag ${VERSION}..."
git push origin main
git push origin "${CURRENT_BRANCH}"
git push origin "${VERSION}"

git checkout "${CURRENT_BRANCH}"

# ─── Create Forgejo release ─────────────────────────────────────────────────
echo "==> Creating Forgejo release ${VERSION} (channel=${UPDATE_CHANNEL}, prerelease=${RELEASE_PRERELEASE})..."
RELEASE_RESPONSE=$(curl -sf -X POST \
  "${FORGEJO_URL}/api/v1/repos/${FORGEJO_REPO}/releases" \
  -H "Authorization: token ${FORGEJO_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{
    \"tag_name\": \"${VERSION}\",
    \"target_commitish\": \"main\",
    \"name\": \"Navis ${VERSION}\",
    \"body\": \"## Navis ${VERSION} (${UPDATE_CHANNEL})\\n\\nSee the [full changelog](${FORGEJO_URL}/${FORGEJO_REPO}/compare/$(git describe --tags --abbrev=0 HEAD~1 2>/dev/null || echo main)...${VERSION}) for details.\",
    \"prerelease\": ${RELEASE_PRERELEASE},
    \"draft\": false
  }")

RELEASE_ID="$(echo "${RELEASE_RESPONSE}" | jq -r '.id')"
if [[ -z "${RELEASE_ID}" || "${RELEASE_ID}" == "null" ]]; then
  echo "Error: Failed to create Forgejo release. Response:"
  echo "${RELEASE_RESPONSE}"
  exit 1
fi

# ─── Upload all assets ──────────────────────────────────────────────────────
for i in "${!ASSET_FILES[@]}"; do
  asset_file="${ASSET_FILES[$i]}"
  asset_name="${ASSET_NAMES[$i]}"
  echo "==> Uploading ${asset_name}..."
  curl -sf -X POST \
    "${FORGEJO_URL}/api/v1/repos/${FORGEJO_REPO}/releases/${RELEASE_ID}/assets?name=${asset_name}" \
    -H "Authorization: token ${FORGEJO_TOKEN}" \
    -F "attachment=@${asset_file}" >/dev/null
  echo "    Uploaded ${asset_name}"
  rm -f "${asset_file}"
done

echo ""
echo "==> Done! Release ${VERSION} published."
echo "    ${FORGEJO_URL}/${FORGEJO_REPO}/releases/tag/${VERSION}"
