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
#   --windows-package=<mode>   Windows output: zip (default) or exe (Inno Setup)
#   --linux-ssh=<user@host>    Build Linux on remote builder (used on non-Linux hosts)
#   --windows-ssh=<user@host>  Build Windows on remote builder (used on non-Windows hosts)
#   --linux-remote-dir=<path>  Remote Linux work dir relative to remote HOME
#   --windows-remote-dir=<path> Remote Windows work dir relative to remote HOME
#   --macos-notarize           Sign + notarize macOS app bundle before packaging
#   --channel=<stable|dev>     Release/update channel (default: stable)
#   --prerelease               Force prerelease=true on Forgejo release
#   --allow-existing-version   Allow rebuilding when pubspec already has this version
#
# Examples:
#   ./tool/release.sh v0.3.0
#   ./tool/release.sh v0.3.0 --channel=dev
#   ./tool/release.sh v0.3.0 --targets=android,macos --channel=stable
#   ./tool/release.sh v0.3.0 --ipa
#   ./tool/release.sh v0.3.0 --targets=windows --windows-package=exe
#   ./tool/release.sh v0.3.0 --targets=macos --macos-notarize
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
WINDOWS_PACKAGE_MODE="zip"
LINUX_SSH_TARGET=""
WINDOWS_SSH_TARGET=""
LINUX_REMOTE_DIR=""
WINDOWS_REMOTE_DIR=""
WINDOWS_FLUTTER_DIR=""
MACOS_NOTARIZE=false
UPDATE_CHANNEL="stable"
FORCE_PRERELEASE=false
ALLOW_EXISTING_VERSION=false

for arg in "$@"; do
  case "${arg}" in
    --skip-checks) SKIP_CHECKS=true ;;
    --ipa) TARGETS_SPEC="android,ios" ;;
    --targets=*) TARGETS_SPEC="${arg#--targets=}" ;;
    --all-platforms) TARGETS_SPEC="android,ios,macos,linux,windows" ;;
    --linux-package=*) LINUX_PACKAGE_MODE="${arg#--linux-package=}" ;;
    --windows-package=*) WINDOWS_PACKAGE_MODE="${arg#--windows-package=}" ;;
    --linux-ssh=*) LINUX_SSH_TARGET="${arg#--linux-ssh=}" ;;
    --windows-ssh=*) WINDOWS_SSH_TARGET="${arg#--windows-ssh=}" ;;
    --linux-remote-dir=*) LINUX_REMOTE_DIR="${arg#--linux-remote-dir=}" ;;
    --windows-remote-dir=*) WINDOWS_REMOTE_DIR="${arg#--windows-remote-dir=}" ;;
    --macos-notarize) MACOS_NOTARIZE=true ;;
    --channel=*) UPDATE_CHANNEL="${arg#--channel=}" ;;
    --prerelease) FORCE_PRERELEASE=true ;;
    --allow-existing-version) ALLOW_EXISTING_VERSION=true ;;
    v*.*) VERSION="${arg}" ;;
    *)
      echo "Unknown argument: ${arg}"
      echo "Usage: ./tool/release.sh <version> [--skip-checks] [--ipa] [--targets=<csv>] [--all-platforms] [--linux-package=<bundle|deb>] [--windows-package=<zip|exe>] [--linux-ssh=<user@host>] [--windows-ssh=<user@host>] [--linux-remote-dir=<path>] [--windows-remote-dir=<path>] [--macos-notarize] [--channel=<stable|dev>] [--prerelease] [--allow-existing-version]"
      exit 1
      ;;
  esac
done

if [[ -z "${VERSION}" ]]; then
  echo "Usage: ./tool/release.sh <version> [--skip-checks] [--ipa] [--targets=<csv>] [--all-platforms] [--linux-package=<bundle|deb>] [--windows-package=<zip|exe>] [--linux-ssh=<user@host>] [--windows-ssh=<user@host>] [--linux-remote-dir=<path>] [--windows-remote-dir=<path>] [--macos-notarize] [--channel=<stable|dev>] [--prerelease] [--allow-existing-version]"
  echo "  e.g. ./tool/release.sh v0.3.0 --targets=android,macos"
  exit 1
fi

LINUX_PACKAGE_MODE="$(echo "${LINUX_PACKAGE_MODE}" | tr '[:upper:]' '[:lower:]')"
if [[ "${LINUX_PACKAGE_MODE}" != "bundle" && "${LINUX_PACKAGE_MODE}" != "deb" ]]; then
  echo "Error: --linux-package must be 'bundle' or 'deb'"
  exit 1
fi

WINDOWS_PACKAGE_MODE="$(echo "${WINDOWS_PACKAGE_MODE}" | tr '[:upper:]' '[:lower:]')"
if [[ "${WINDOWS_PACKAGE_MODE}" != "zip" && "${WINDOWS_PACKAGE_MODE}" != "exe" ]]; then
  echo "Error: --windows-package must be 'zip' or 'exe'"
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

LINUX_SSH_TARGET="${LINUX_SSH_TARGET:-${NAVIS_LINUX_SSH:-}}"
WINDOWS_SSH_TARGET="${WINDOWS_SSH_TARGET:-${NAVIS_WINDOWS_SSH:-}}"
LINUX_REMOTE_DIR="${LINUX_REMOTE_DIR:-${NAVIS_LINUX_REMOTE_DIR:-.navis/remote-linux-build}}"
WINDOWS_REMOTE_DIR="${WINDOWS_REMOTE_DIR:-${NAVIS_WINDOWS_REMOTE_DIR:-.navis/remote-windows-build}}"
WINDOWS_FLUTTER_DIR="${NAVIS_WINDOWS_FLUTTER_DIR:-}"

# ─── Validate env ───────────────────────────────────────────────────────────
: "${FORGEJO_URL:?Set FORGEJO_URL in tool/release.env}"
: "${FORGEJO_REPO:?Set FORGEJO_REPO in tool/release.env}"
: "${FORGEJO_TOKEN:?Set FORGEJO_TOKEN in tool/release.env}"

if [[ "${BUILD_ANDROID}" == "true" && -z "${NAVIS_LASTFM_API_KEY:-}" ]]; then
  echo "Error: NAVIS_LASTFM_API_KEY is required for Android release builds."
  echo "Set it in tool/release.env, for example:"
  echo "  NAVIS_LASTFM_API_KEY=your_lastfm_api_key"
  exit 1
fi

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
  if ! command -v unzip &>/dev/null; then
    echo "Error: 'unzip' is required for Android APK string validation."
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

if [[ "${BUILD_LINUX}" == "true" && "${UNAME}" != "Linux" && -z "${LINUX_SSH_TARGET}" ]]; then
  echo "Error: Linux builds on non-Linux hosts require --linux-ssh=<user@host> (or NAVIS_LINUX_SSH)."
  exit 1
fi

if [[ "${BUILD_WINDOWS}" == "true" && "${OS:-}" != "Windows_NT" && -z "${WINDOWS_SSH_TARGET}" ]]; then
  echo "Error: Windows builds on non-Windows hosts require --windows-ssh=<user@host> (or NAVIS_WINDOWS_SSH)."
  exit 1
fi

if [[ "${MACOS_NOTARIZE}" == "true" && "${BUILD_MACOS}" != "true" ]]; then
  echo "Error: --macos-notarize requires macOS to be included in --targets."
  exit 1
fi

if [[ "${BUILD_LINUX}" == "true" && "${UNAME}" != "Linux" ]]; then
  for tool in ssh scp; do
    if ! command -v "${tool}" &>/dev/null; then
      echo "Error: '${tool}' is required for remote Linux builds."
      exit 1
    fi
  done
  if [[ ! -x "${SCRIPT_DIR}/remote_build_linux.sh" ]]; then
    echo "Error: ${SCRIPT_DIR}/remote_build_linux.sh is missing or not executable."
    exit 1
  fi
fi

if [[ "${BUILD_WINDOWS}" == "true" && "${OS:-}" != "Windows_NT" ]]; then
  for tool in ssh scp; do
    if ! command -v "${tool}" &>/dev/null; then
      echo "Error: '${tool}' is required for remote Windows builds."
      exit 1
    fi
  done
  if [[ ! -x "${SCRIPT_DIR}/remote_build_windows.sh" ]]; then
    echo "Error: ${SCRIPT_DIR}/remote_build_windows.sh is missing or not executable."
    exit 1
  fi
fi

to_windows_host_path() {
  local path="$1"
  if [[ "${OS:-}" == "Windows_NT" ]] && command -v cygpath &>/dev/null; then
    cygpath -w "${path}"
    return
  fi
  echo "${path}"
}

remove_release_asset() {
  local asset_path="$1"
  if [[ -f "${asset_path}" ]]; then
    rm -f "${asset_path}"
  fi
}

clean_android_release_outputs() {
  echo "==> Cleaning stale Android release outputs..."
  rm -rf "${SCRIPT_DIR}/../.dart_tool/flutter_build"
  rm -rf "${SCRIPT_DIR}/../build/app"
  rm -rf "${SCRIPT_DIR}/../build/flutter_assets"
  rm -rf "${SCRIPT_DIR}/../build/lib"
  rm -rf "${SCRIPT_DIR}/../build/app/outputs/flutter-apk"
  rm -rf "${SCRIPT_DIR}/../build/app/intermediates/flutter/sideloadRelease"
  rm -rf "${SCRIPT_DIR}/../build/app/intermediates/assets/sideloadRelease"
  rm -rf "${SCRIPT_DIR}/../build/app/intermediates/merged_assets/sideloadRelease"
}

validate_apk_strings() {
  local apk_path="$1"
  local extracted_dir
  local apk_strings
  extracted_dir="$(mktemp -d)"
  apk_strings="$(mktemp)"
  unzip -qq "${apk_path}" -d "${extracted_dir}"
  find "${extracted_dir}" -type f -print0 | xargs -0 strings > "${apk_strings}"

  local retired_substrings=(
    "Enable Listen Together"
    "Paste a Voyage invite"
    "Listen Together optimistic queue replace playback failed"
  )
  local retired_string
  for retired_string in "${retired_substrings[@]}"; do
    if grep -F -q -- "${retired_string}" "${apk_strings}"; then
      rm -rf "${extracted_dir}"
      rm -f "${apk_strings}"
      echo "Error: APK contains retired active Listen Together/Voyage string: ${retired_string}"
      exit 1
    fi
  done

  local retired_exact_strings=(
    "Voyage servers"
  )
  for retired_string in "${retired_exact_strings[@]}"; do
    if grep -F -x -q -- "${retired_string}" "${apk_strings}"; then
      rm -rf "${extracted_dir}"
      rm -f "${apk_strings}"
      echo "Error: APK contains retired active Listen Together/Voyage string: ${retired_string}"
      exit 1
    fi
  done

  local required_marker="Album Queue enabled for top tracks"
  if ! grep -F -q -- "${required_marker}" "${apk_strings}"; then
    rm -rf "${extracted_dir}"
    rm -f "${apk_strings}"
    echo "Error: APK is missing expected Artist Top Tracks Album Queue marker: ${required_marker}"
    exit 1
  fi

  rm -rf "${extracted_dir}"
  rm -f "${apk_strings}"
}

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
if [[ -n "${NAVIS_LASTFM_API_KEY:-}" ]]; then
  DART_DEFINE_ARGS+=("--dart-define=NAVIS_LASTFM_API_KEY=${NAVIS_LASTFM_API_KEY}")
fi

# ─── Clean tree ─────────────────────────────────────────────────────────────
if [[ -n "$(git status --porcelain)" ]]; then
  echo "Error: Working tree is not clean. Commit or stash changes first."
  git status --short
  exit 1
fi

CURRENT_BRANCH="$(git branch --show-current)"

# ─── Existing version guard ─────────────────────────────────────────────────
PUBSPEC="${SCRIPT_DIR}/../pubspec.yaml"
REQUESTED_PUBSPEC_VERSION="${SEMVER}+${BUILD_NUMBER}"
CURRENT_PUBSPEC_VERSION="$(sed -n 's/^version: //p' "${PUBSPEC}" | head -1)"
if [[ "${CURRENT_PUBSPEC_VERSION}" == "${REQUESTED_PUBSPEC_VERSION}" && "${ALLOW_EXISTING_VERSION}" == "false" ]]; then
  echo "Error: pubspec.yaml already has version ${REQUESTED_PUBSPEC_VERSION}."
  echo "Use a new release version, or pass --allow-existing-version for an intentional rebuild/retry."
  exit 1
fi

# ─── Checks ─────────────────────────────────────────────────────────────────
if [[ "${SKIP_CHECKS}" == "false" ]]; then
  echo "==> Running quality checks (./tool/check.sh)..."
  "${SCRIPT_DIR}/check.sh"
else
  echo "==> Skipping quality checks (--skip-checks)."
fi

# ─── Version bump ───────────────────────────────────────────────────────────
echo "==> Bumping pubspec.yaml to ${SEMVER}+${BUILD_NUMBER}..."
sed -i.bak "s/^version: .*/version: ${SEMVER}+${BUILD_NUMBER}/" "${PUBSPEC}"
rm -f "${PUBSPEC}.bak"

# ─── Build artifacts ────────────────────────────────────────────────────────
ASSET_FILES=()
ASSET_NAMES=()

if [[ "${BUILD_ANDROID}" == "true" ]]; then
  echo "==> Building Android APK..."
  export NAVIS_SELF_UPDATE=true
  DART_DEFINE_ARGS+=("--dart-define=NAVIS_SELF_UPDATE=true")
  clean_android_release_outputs
  ANDROID_OBFUSCATION_DIR="${SCRIPT_DIR}/../build/obfuscation/android/${VERSION}"
  mkdir -p "${ANDROID_OBFUSCATION_DIR}"
  _apk_define_args="${DART_DEFINE_ARGS[*]}"
  # When running inside a Flatpak sandbox, Gradle cannot find JAVA_HOME.
  # Delegate to the host OS where the full JDK is available.
  if [[ -n "${FLATPAK_ID:-}" ]]; then
    _flutter_bin="$(command -v flutter)"
    /usr/bin/flatpak-spawn --host -- bash -c \
      "export PATH=\"$(dirname "${_flutter_bin}"):\$HOME/.local/bin:\$PATH\"; export NAVIS_SELF_UPDATE=true; cd \"${SCRIPT_DIR}/..\"; flutter build apk --release --flavor sideload --obfuscate --split-debug-info=\"${ANDROID_OBFUSCATION_DIR}\" $(printf '%q ' "${DART_DEFINE_ARGS[@]}")"
  else
    flutter build apk \
      --release \
      --flavor sideload \
      --obfuscate \
      --split-debug-info="${ANDROID_OBFUSCATION_DIR}" \
      "${DART_DEFINE_ARGS[@]}"
  fi

  APK_PATH="${SCRIPT_DIR}/../build/app/outputs/flutter-apk/app-sideload-release.apk"
  APK_ASSET_NAME="${ASSET_PREFIX}-${VERSION}.apk"
  APK_ASSET="${SCRIPT_DIR}/../${APK_ASSET_NAME}"
  remove_release_asset "${APK_ASSET}"

  if [[ ! -f "${APK_PATH}" ]]; then
    echo "Error: APK not found at ${APK_PATH}"
    exit 1
  fi

  cp "${APK_PATH}" "${APK_ASSET}"
  ASSET_FILES+=("${APK_ASSET}")
  ASSET_NAMES+=("${APK_ASSET_NAME}")
  echo "    APK -> ${APK_ASSET_NAME}"
  echo "    Obfuscation symbols -> ${ANDROID_OBFUSCATION_DIR}"

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

    # key.properties storeFile is relative to android/app/
    STORE_FILE_ABS="${SCRIPT_DIR}/../android/app/${STORE_FILE}"
    EXPECTED_CERT_SHA256="$(keytool -list -v \
      -keystore "${STORE_FILE_ABS}" \
      -storepass "${STORE_PASSWORD}" \
      -alias "${KEY_ALIAS}" 2>/dev/null | awk -F': ' '/SHA256:/{gsub(":", "", $2); print tolower($2); exit}')"
    ACTUAL_CERT_SHA256="$(${APKSIGNER_BIN} verify --print-certs "${APK_ASSET}" | awk '/SHA-256 digest/{print tolower($NF); exit}')"

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

  echo "==> Validating APK release strings..."
  validate_apk_strings "${APK_ASSET}"

  echo "    APK metadata/signing/strings OK"
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
  remove_release_asset "${IPA_ASSET}"
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
  remove_release_asset "${MACOS_ASSET}"
  if [[ "${MACOS_NOTARIZE}" == "true" ]]; then
    echo "==> Notarizing macOS app..."
    "${SCRIPT_DIR}/macos_notarize.sh" \
      --app="${MACOS_APP_PATH}" \
      --output="${MACOS_ASSET}"
  else
    ditto -c -k --keepParent "${MACOS_APP_PATH}" "${MACOS_ASSET}"
  fi
  ASSET_FILES+=("${MACOS_ASSET}")
  ASSET_NAMES+=("${MACOS_ASSET_NAME}")
  echo "    macOS -> ${MACOS_ASSET_NAME}"
fi

if [[ "${BUILD_LINUX}" == "true" ]]; then
  if [[ "${UNAME}" == "Linux" ]]; then
    echo "==> Building Linux bundle..."
    # When running inside a Flatpak sandbox (e.g. VS Code Flatpak), clang++ and
    # the system headers are not available. Delegate the build to the host OS.
    if [[ -n "${FLATPAK_ID:-}" ]]; then
      _flutter_bin="$(command -v flutter)"
      /usr/bin/flatpak-spawn --host -- bash -c \
        "export PATH=\"$(dirname "${_flutter_bin}"):\$HOME/.local/bin:\$PATH\"; cd \"${SCRIPT_DIR}/..\"; flutter build linux --release $(printf '%q ' "${DART_DEFINE_ARGS[@]}")"
    else
      flutter build linux --release "${DART_DEFINE_ARGS[@]}"
    fi

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
      DEB_ARCH="$(dpkg --print-architecture 2>/dev/null || true)"
      if [[ -z "${DEB_ARCH}" ]]; then
        case "$(uname -m)" in
          x86_64) DEB_ARCH="amd64" ;;
          aarch64|arm64) DEB_ARCH="arm64" ;;
          *) DEB_ARCH="$(uname -m)" ;;
        esac
      fi
      DEB_APP_NAME="Navis"
      if [[ "${UPDATE_CHANNEL}" == "dev" ]]; then
        DEB_APP_NAME="Navis Dev"
      fi
      DEB_MAINTAINER="${NAVIS_DEB_MAINTAINER:-Navis Team <noreply@example.com>}"

      rm -rf "${DEB_STAGE_DIR}"
      mkdir -p "${DEB_STAGE_DIR}/DEBIAN"
      mkdir -p "${DEB_STAGE_DIR}/opt/${DEB_PACKAGE_NAME}"
      mkdir -p "${DEB_STAGE_DIR}/usr/bin"
      mkdir -p "${DEB_STAGE_DIR}/usr/share/applications"
      mkdir -p "${DEB_STAGE_DIR}/usr/share/icons/hicolor"

      cp -R "${LINUX_BUNDLE_DIR}/." "${DEB_STAGE_DIR}/opt/${DEB_PACKAGE_NAME}/"

      cat > "${DEB_STAGE_DIR}/usr/bin/${DEB_PACKAGE_NAME}" <<LAUNCHER
#!/usr/bin/env bash
exec "/opt/${DEB_PACKAGE_NAME}/navis" "\$@"
LAUNCHER
      chmod 0755 "${DEB_STAGE_DIR}/usr/bin/${DEB_PACKAGE_NAME}"

      cat > "${DEB_STAGE_DIR}/usr/share/applications/${DEB_PACKAGE_NAME}.desktop" <<DESKTOP
[Desktop Entry]
Name=${DEB_APP_NAME}
GenericName=Music Player
Comment=Subsonic/OpenSubsonic music player
Exec=${DEB_PACKAGE_NAME} %U
Icon=${DEB_PACKAGE_NAME}
Terminal=false
Type=Application
Categories=AudioVideo;Audio;Player;
StartupNotify=true
StartupWMClass=navis
MimeType=audio/mpeg;audio/ogg;audio/flac;audio/x-flac;audio/wav;audio/aac;audio/x-m4a;
DESKTOP

      ICON_SOURCE_DIR="${SCRIPT_DIR}/../linux/packaging/icons/hicolor"
      if [[ -d "${ICON_SOURCE_DIR}" ]]; then
        while IFS= read -r icon_path; do
          icon_size="$(basename "$(dirname "$(dirname "${icon_path}")")")"
          install -d "${DEB_STAGE_DIR}/usr/share/icons/hicolor/${icon_size}/apps"
          install -m 0644 "${icon_path}" \
            "${DEB_STAGE_DIR}/usr/share/icons/hicolor/${icon_size}/apps/${DEB_PACKAGE_NAME}.png"
        done < <(find "${ICON_SOURCE_DIR}" -path "*/apps/navis.png" -type f | sort)
      fi

      cat > "${DEB_STAGE_DIR}/DEBIAN/control" <<CONTROL
Package: ${DEB_PACKAGE_NAME}
Version: ${SEMVER}
Section: sound
Priority: optional
Architecture: ${DEB_ARCH}
Maintainer: ${DEB_MAINTAINER}
Depends: libgtk-3-0
Homepage: https://git.porthorion.com/khalifa/Navis
Description: Navis music player
 Subsonic/OpenSubsonic music player built with Flutter.
CONTROL

      DEB_ASSET_NAME="${ASSET_PREFIX}-${VERSION}-linux-${DEB_ARCH}.deb"
      DEB_ASSET="${SCRIPT_DIR}/../${DEB_ASSET_NAME}"
      remove_release_asset "${DEB_ASSET}"
      dpkg-deb --root-owner-group --build "${DEB_STAGE_DIR}" "${DEB_ASSET}" >/dev/null
      rm -rf "${DEB_STAGE_DIR}"

      ASSET_FILES+=("${DEB_ASSET}")
      ASSET_NAMES+=("${DEB_ASSET_NAME}")
      echo "    Linux -> ${DEB_ASSET_NAME}"
    else
      LINUX_ASSET_NAME="${ASSET_PREFIX}-${VERSION}-linux.tar.gz"
      LINUX_ASSET="${SCRIPT_DIR}/../${LINUX_ASSET_NAME}"
      remove_release_asset "${LINUX_ASSET}"
      tar -czf "${LINUX_ASSET}" -C "${LINUX_BUNDLE_DIR}" .
      ASSET_FILES+=("${LINUX_ASSET}")
      ASSET_NAMES+=("${LINUX_ASSET_NAME}")
      echo "    Linux -> ${LINUX_ASSET_NAME}"
    fi
  else
    echo "==> Building Linux artifact on remote host (${LINUX_SSH_TARGET})..."
    rm -f "${SCRIPT_DIR}/../${ASSET_PREFIX}-${VERSION}-linux.tar.gz"
    rm -f "${SCRIPT_DIR}/../${ASSET_PREFIX}-${VERSION}-linux-"*.deb
    "${SCRIPT_DIR}/remote_build_linux.sh" \
      --ssh="${LINUX_SSH_TARGET}" \
      --version="${VERSION}" \
      --asset-prefix="${ASSET_PREFIX}" \
      --package="${LINUX_PACKAGE_MODE}" \
      --channel="${UPDATE_CHANNEL}" \
      --lastfm-key="${NAVIS_LASTFM_API_KEY:-}" \
      --remote-dir="${LINUX_REMOTE_DIR}" \
      --repo-root="${SCRIPT_DIR}/.."

    if [[ "${LINUX_PACKAGE_MODE}" == "deb" ]]; then
      DEB_ASSET="$(find "${SCRIPT_DIR}/.." -maxdepth 1 -type f -name "${ASSET_PREFIX}-${VERSION}-linux-*.deb" | head -1)"
      if [[ -z "${DEB_ASSET}" ]]; then
        echo "Error: Remote Linux deb artifact was not fetched."
        exit 1
      fi
      DEB_ASSET_NAME="$(basename "${DEB_ASSET}")"
      ASSET_FILES+=("${DEB_ASSET}")
      ASSET_NAMES+=("${DEB_ASSET_NAME}")
      echo "    Linux -> ${DEB_ASSET_NAME}"
    else
      LINUX_ASSET_NAME="${ASSET_PREFIX}-${VERSION}-linux.tar.gz"
      LINUX_ASSET="${SCRIPT_DIR}/../${LINUX_ASSET_NAME}"
      if [[ ! -f "${LINUX_ASSET}" ]]; then
        echo "Error: Remote Linux bundle artifact was not fetched (${LINUX_ASSET_NAME})."
        exit 1
      fi
      ASSET_FILES+=("${LINUX_ASSET}")
      ASSET_NAMES+=("${LINUX_ASSET_NAME}")
      echo "    Linux -> ${LINUX_ASSET_NAME}"
    fi
  fi
fi

if [[ "${BUILD_WINDOWS}" == "true" ]]; then
  if [[ "${OS:-}" == "Windows_NT" ]]; then
    echo "==> Building Windows bundle..."
    flutter build windows --release "${DART_DEFINE_ARGS[@]}"

    WINDOWS_RELEASE_DIR="${SCRIPT_DIR}/../build/windows/x64/runner/Release"
    if [[ ! -d "${WINDOWS_RELEASE_DIR}" ]]; then
      echo "Error: Windows release dir not found at ${WINDOWS_RELEASE_DIR}"
      exit 1
    fi

    if [[ "${WINDOWS_PACKAGE_MODE}" == "exe" ]]; then
      WINDOWS_ASSET_NAME="${ASSET_PREFIX}-${VERSION}-windows-installer.exe"
      WINDOWS_ASSET="${SCRIPT_DIR}/../${WINDOWS_ASSET_NAME}"
      remove_release_asset "${WINDOWS_ASSET}"
      WINDOWS_INSTALLER_SCRIPT="${SCRIPT_DIR}/windows/build_inno_installer.ps1"
      if [[ ! -f "${WINDOWS_INSTALLER_SCRIPT}" ]]; then
        echo "Error: Installer script not found at ${WINDOWS_INSTALLER_SCRIPT}"
        exit 1
      fi

      RELEASE_DIR_ARG="$(to_windows_host_path "${WINDOWS_RELEASE_DIR}")"
      OUTPUT_PATH_ARG="$(to_windows_host_path "${WINDOWS_ASSET}")"
      INSTALLER_SCRIPT_ARG="$(to_windows_host_path "${WINDOWS_INSTALLER_SCRIPT}")"

      if command -v powershell.exe &>/dev/null; then
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${INSTALLER_SCRIPT_ARG}" \
          -ReleaseDir "${RELEASE_DIR_ARG}" \
          -Version "${VERSION}" \
          -AssetPrefix "${ASSET_PREFIX}" \
          -OutputPath "${OUTPUT_PATH_ARG}" >/dev/null
      elif command -v pwsh &>/dev/null; then
        pwsh -NoProfile -File "${WINDOWS_INSTALLER_SCRIPT}" \
          -ReleaseDir "${WINDOWS_RELEASE_DIR}" \
          -Version "${VERSION}" \
          -AssetPrefix "${ASSET_PREFIX}" \
          -OutputPath "${WINDOWS_ASSET}" >/dev/null
      else
        echo "Error: --windows-package=exe requires powershell.exe or pwsh."
        exit 1
      fi
    else
      WINDOWS_ASSET_NAME="${ASSET_PREFIX}-${VERSION}-windows.zip"
      WINDOWS_ASSET="${SCRIPT_DIR}/../${WINDOWS_ASSET_NAME}"
      remove_release_asset "${WINDOWS_ASSET}"
      if command -v powershell.exe &>/dev/null; then
        powershell.exe -NoProfile -Command "Compress-Archive -Path '${WINDOWS_RELEASE_DIR//\//\\}\\*' -DestinationPath '${WINDOWS_ASSET//\//\\}' -Force" >/dev/null
      elif command -v zip &>/dev/null; then
        (cd "${WINDOWS_RELEASE_DIR}" && zip -r "${WINDOWS_ASSET}" . >/dev/null)
      else
        echo "Error: Need either powershell.exe or zip to package Windows release."
        exit 1
      fi
    fi
  else
    echo "==> Building Windows artifact on remote host (${WINDOWS_SSH_TARGET})..."
    if [[ "${WINDOWS_PACKAGE_MODE}" == "exe" ]]; then
      WINDOWS_ASSET_NAME="${ASSET_PREFIX}-${VERSION}-windows-installer.exe"
    else
      WINDOWS_ASSET_NAME="${ASSET_PREFIX}-${VERSION}-windows.zip"
    fi
    WINDOWS_ASSET="${SCRIPT_DIR}/../${WINDOWS_ASSET_NAME}"
    rm -f "${WINDOWS_ASSET}"
    "${SCRIPT_DIR}/remote_build_windows.sh" \
      --ssh="${WINDOWS_SSH_TARGET}" \
      --version="${VERSION}" \
      --asset-prefix="${ASSET_PREFIX}" \
      --package="${WINDOWS_PACKAGE_MODE}" \
      --channel="${UPDATE_CHANNEL}" \
      --lastfm-key="${NAVIS_LASTFM_API_KEY:-}" \
      --remote-dir="${WINDOWS_REMOTE_DIR}" \
      --flutter-dir="${WINDOWS_FLUTTER_DIR}" \
      --repo-root="${SCRIPT_DIR}/.."
    if [[ ! -f "${WINDOWS_ASSET}" ]]; then
      echo "Error: Remote Windows artifact was not fetched (${WINDOWS_ASSET_NAME})."
      exit 1
    fi
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

# ─── Generate release notes from changelog_data ─────────────────────────────
echo "==> Generating release notes for ${VERSION}..."
RELEASE_BODY="$(dart tool/generate_release_notes.dart "${VERSION}" 2>/dev/null)" || true
if [[ -z "${RELEASE_BODY}" ]]; then
  PREV_TAG="$(git describe --tags --abbrev=0 HEAD~1 2>/dev/null || echo main)"
  RELEASE_BODY="## Navis ${VERSION} (${UPDATE_CHANNEL})"$'\n\n'"See the [full changelog](${FORGEJO_URL}/${FORGEJO_REPO}/compare/${PREV_TAG}...${VERSION}) for details."
  echo "    No changelog entry found — using generic release body."
else
  echo "    Release notes generated successfully."
fi

# ─── Create Forgejo release ─────────────────────────────────────────────────
echo "==> Creating Forgejo release ${VERSION} (channel=${UPDATE_CHANNEL}, prerelease=${RELEASE_PRERELEASE})..."
RELEASE_RESPONSE=$(curl -sf -X POST \
  "${FORGEJO_URL}/api/v1/repos/${FORGEJO_REPO}/releases" \
  -H "Authorization: token ${FORGEJO_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$(jq -n \
    --arg tag "${VERSION}" \
    --arg name "Navis ${VERSION}" \
    --arg body "${RELEASE_BODY}" \
    --argjson prerelease "${RELEASE_PRERELEASE}" \
    '{tag_name: $tag, target_commitish: "main", name: $name, body: $body, prerelease: $prerelease, draft: false}'
  )")

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
