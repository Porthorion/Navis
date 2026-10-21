#!/usr/bin/env bash
# tool/release.sh — Local release script for Navis.
#
# Builds selected release artifacts, bumps pubspec.yaml, tags/merges/pushes,
# and publishes the assets plus a signed update manifest to R2
# (tool/r2_publish.sh, docs/release/release-r2.md). With --forgejo it also creates a
# Forgejo release, which is how 1.4.x installs find 1.5.0.
#
# Usage:
#   ./tool/release.sh <version> [options]
#
# Options:
#   --build-only              Stage validated assets locally; never tag or publish
#   --publish-from=<dist/tag>  Publish a verified staged bundle without building
#   --skip-checks              Skip ./tool/check.sh
#   --ipa                      Shortcut for --targets=android,ios
#   --targets=<csv>            Build targets: android,ios,macos,linux,windows
#   --all-platforms            Same as --targets=android,ios,macos,linux,windows
#   --linux-package=<mode>     Linux output: bundle (default), deb, rpm or all
#   --windows-package=<mode>   Windows output: zip (default) or exe (Inno Setup)
#   --linux-ssh=<user@host>    Build Linux on remote builder (used on non-Linux hosts)
#   --windows-ssh=<user@host>  Build Windows on remote builder (used on non-Windows hosts)
#   --linux-remote-dir=<path>  Remote Linux work dir relative to remote HOME
#   --windows-remote-dir=<path> Remote Windows work dir relative to remote HOME
#   --macos-notarize           Sign + notarize macOS app bundle before packaging
#   --channel=<stable|dev>     Release/update channel (default: stable)
#   --prerelease               Force prerelease=true in release metadata
#   --forgejo                  Also publish a Forgejo release (only for the 1.5.0 bridge)
#   --github                   Publish GitHub (automatic for stable releases)
#   --no-github                Emergency opt-out: GitHub-source users miss this release
#   --allow-existing-version   Rebuild or retry a version whose release tag already exists
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

# Never ship the test-only updater elevator, including inherited Flutter defines.
if [[ "${NAVIS_TEST_UPDATE_ELEVATOR+x}" == x ]]; then
  echo 'Error: NAVIS_TEST_UPDATE_ELEVATOR is test-only and cannot be set for releases.' >&2
  exit 1
fi
IFS=',' read -r -a inherited_dart_defines <<< "${DART_DEFINES:-}"
for define in ${inherited_dart_defines[@]+"${inherited_dart_defines[@]}"}; do
  [[ -n "${define}" ]] || continue
  decoded_define="$(printf '%s' "${define}" | openssl base64 -d -A)"
  if [[ "${decoded_define}" == NAVIS_TEST_UPDATE_ELEVATOR=* ]]; then
    echo 'Error: NAVIS_TEST_UPDATE_ELEVATOR is test-only and cannot be set for releases.' >&2
    exit 1
  fi
done

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
PUBLISH_FORGEJO=false
PUBLISH_GITHUB=false
NO_GITHUB=false
BUILD_ONLY=false
PUBLISH_FROM=""
PUBLISH_FROM_SET=false
CHANNEL_EXPLICIT=false
BUILD_OPTIONS_SET=false

for arg in "$@"; do
  case "${arg}" in
    --ipa|--targets=*|--all-platforms|--linux-*|--windows-*|--macos-notarize) BUILD_OPTIONS_SET=true ;;
  esac
  case "${arg}" in
    --build-only) BUILD_ONLY=true ;;
    --publish-from=*) PUBLISH_FROM="${arg#--publish-from=}"; PUBLISH_FROM_SET=true ;;
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
    --channel=*) UPDATE_CHANNEL="${arg#--channel=}"; CHANNEL_EXPLICIT=true ;;
    --prerelease) FORCE_PRERELEASE=true ;;
    --allow-existing-version) ALLOW_EXISTING_VERSION=true ;;
    --forgejo) PUBLISH_FORGEJO=true ;;
    --github) PUBLISH_GITHUB=true ;;
    --no-github) NO_GITHUB=true ;;
    v*.*) VERSION="${arg}" ;;
    *)
      echo "Unknown argument: ${arg}"
      echo "Usage: ./tool/release.sh <version> [--build-only | --publish-from=<dist/tag>] [--skip-checks] [--ipa] [--targets=<csv>] [--all-platforms] [--linux-package=<bundle|deb|rpm|all>] [--windows-package=<zip|exe>] [--linux-ssh=<user@host>] [--windows-ssh=<user@host>] [--linux-remote-dir=<path>] [--windows-remote-dir=<path>] [--macos-notarize] [--channel=<stable|dev>] [--prerelease] [--allow-existing-version] [--forgejo] [--github | --no-github]"
      exit 1
      ;;
  esac
done

if [[ -z "${VERSION}" ]]; then
  echo "Usage: ./tool/release.sh <version> [--build-only | --publish-from=<dist/tag>] [--skip-checks] [--ipa] [--targets=<csv>] [--all-platforms] [--linux-package=<bundle|deb|rpm|all>] [--windows-package=<zip|exe>] [--linux-ssh=<user@host>] [--windows-ssh=<user@host>] [--linux-remote-dir=<path>] [--windows-remote-dir=<path>] [--macos-notarize] [--channel=<stable|dev>] [--prerelease] [--allow-existing-version] [--forgejo] [--github | --no-github]"
  echo "  e.g. ./tool/release.sh v0.3.0 --targets=android,macos"
  exit 1
fi

if [[ "${PUBLISH_FROM_SET}" == true ]]; then
  if [[ -z "${PUBLISH_FROM}" || "${BUILD_ONLY}" == true || "${BUILD_OPTIONS_SET}" == true ]]; then
    echo "Error: --publish-from requires a directory and cannot be combined with --build-only or build options."
    exit 1
  fi
  TARGETS_SPEC=""
fi

LINUX_PACKAGE_MODE="$(echo "${LINUX_PACKAGE_MODE}" | tr '[:upper:]' '[:lower:]')"
if [[ ! "${LINUX_PACKAGE_MODE}" =~ ^(bundle|deb|rpm|all)$ ]]; then
  echo "Error: --linux-package must be bundle, deb, rpm or all"
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

# Run before loading secrets, then again after staged metadata is loaded.
validate_github_channel() {
  if [[ "${NO_GITHUB}" == true && "${PUBLISH_GITHUB}" == true ]]; then
    echo 'Error: --github and --no-github cannot be combined.' >&2; exit 1
  fi
  if [[ "${PUBLISH_GITHUB}" == true && "${UPDATE_CHANNEL}" != stable ]]; then
    echo 'Error: GitHub publication is stable-only; use R2 for dev releases.' >&2; exit 1
  fi
  if [[ "${UPDATE_CHANNEL}" == stable && "${FORCE_PRERELEASE}" == true && "${NO_GITHUB}" == false ]]; then
    echo 'Error: --prerelease on stable requires explicit --no-github; use dev for prereleases.' >&2; exit 1
  fi
}
validate_github_channel

# Validate the namespace locally; build-only must not run R2's remote checks.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/r2_tags.sh"
if ! navis_r2_valid_tag "${VERSION}" "${UPDATE_CHANNEL}"; then
  echo "Error: Invalid release tag for channel ${UPDATE_CHANNEL}: ${VERSION}"
  exit 1
fi

# ─── Version ────────────────────────────────────────────────────────────────
SEMVER="${VERSION#v}"
IFS='.' read -r MAJOR MINOR PATCH <<< "${SEMVER%%[-+]*}"
BUILD_NUMBER=$(( (10#${MAJOR} * 10000) + (10#${MINOR} * 100) + 10#${PATCH} ))

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

if [[ "${PUBLISH_FROM_SET}" == false && "${BUILD_ANDROID}" == "false" && "${BUILD_IOS}" == "false" && "${BUILD_MACOS}" == "false" && "${BUILD_LINUX}" == "false" && "${BUILD_WINDOWS}" == "false" ]]; then
  echo "Error: No valid build targets selected."
  exit 1
fi

# ─── Env file ───────────────────────────────────────────────────────────────
# Publication always requires the release key, even if local dev builds opt in
# to debug signing. Fail before loading secrets or running the quality gates.
if [[ "${BUILD_ANDROID}" == "true" && ! -f "${SCRIPT_DIR}/../android/key.properties" ]]; then
  echo "Error: android/key.properties is required for Android releases." >&2
  exit 1
fi

if [[ -f "${SCRIPT_DIR}/release.env" ]]; then
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/release.env"
fi

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/lastfm_key_defines.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/scan_artifact_secret.sh"

LINUX_SSH_TARGET="${LINUX_SSH_TARGET:-${NAVIS_LINUX_SSH:-}}"
WINDOWS_SSH_TARGET="${WINDOWS_SSH_TARGET:-${NAVIS_WINDOWS_SSH:-}}"
LINUX_REMOTE_DIR="${LINUX_REMOTE_DIR:-${NAVIS_LINUX_REMOTE_DIR:-.navis/remote-linux-build}}"
WINDOWS_REMOTE_DIR="${WINDOWS_REMOTE_DIR:-${NAVIS_WINDOWS_REMOTE_DIR:-.navis/remote-windows-build}}"
WINDOWS_FLUTTER_DIR="${NAVIS_WINDOWS_FLUTTER_DIR:-}"

# ─── Validate env ───────────────────────────────────────────────────────────
if [[ "${PUBLISH_FORGEJO}" == "true" && "${BUILD_ONLY}" == false ]]; then
  : "${FORGEJO_URL:?Set FORGEJO_URL in tool/release.env}"
  : "${FORGEJO_REPO:?Set FORGEJO_REPO in tool/release.env}"
  : "${FORGEJO_TOKEN:?Set FORGEJO_TOKEN in tool/release.env}"
fi

if [[ "${BUILD_ANDROID}" == "true" && -z "${NAVIS_LASTFM_API_KEY:-}" ]]; then
  echo "Error: NAVIS_LASTFM_API_KEY is required for Android release builds."
  echo "Set it in tool/release.env, for example:"
  echo "  NAVIS_LASTFM_API_KEY=your_lastfm_api_key"
  exit 1
fi

# ─── Validate tools ─────────────────────────────────────────────────────────
REQUIRED_TOOLS=(jq git sha256sum)
if [[ "${PUBLISH_FROM_SET}" == false ]]; then REQUIRED_TOOLS+=(flutter openssl); fi
if [[ "${BUILD_ONLY}" == false ]]; then REQUIRED_TOOLS+=(curl openssl); fi

for tool in "${REQUIRED_TOOLS[@]}"; do
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
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/release_dist.sh"
if [[ "${PUBLISH_FROM_SET}" == true ]]; then
  load_release_dist
fi

# shellcheck source=lib/github_release.sh
source "${SCRIPT_DIR}/lib/github_release.sh"
validate_github_channel
if [[ "${BUILD_ONLY}" == false && "${UPDATE_CHANNEL}" == stable && "${FORCE_PRERELEASE}" == false && "${NO_GITHUB}" == false ]]; then
  PUBLISH_GITHUB=true
fi
if [[ "${NO_GITHUB}" == true && "${BUILD_ONLY}" == false ]]; then
  echo 'WARNING: --no-github: GITHUB-SOURCE USERS WILL NOT SEE THIS RELEASE.' >&2
fi
if [[ "${PUBLISH_GITHUB}" == true && "${BUILD_ONLY}" == false ]]; then
  navis_github_preflight "${VERSION}" "${ALLOW_EXISTING_VERSION}"
fi

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

# The Last.fm key is bundled masked (key XOR a per-build random pad) through a
# private defines file, not on the script's own command lines. This deters casual extraction;
# it is not secrecy. See docs/release/release-secrets.md.
SECRET_TMP_DIR=""
LASTFM_DEFINES_FILE=""
DIST_TMP_DIR=""
R2_PUBLISHED=false
GITHUB_VERIFIED=false
cleanup_release_secrets() {
  local status=$?
  if [[ "${R2_PUBLISHED}" == true && "${PUBLISH_GITHUB}" == true && "${GITHUB_VERIFIED}" != true ]]; then
    echo 'ERROR: R2 succeeded but GitHub is not verified. Update sources may be out of sync.' >&2
    printf 'Resume: ' >&2
    printf '%q ' ./tool/release.sh "${VERSION}" "--publish-from=${PUBLISH_FROM}" --allow-existing-version --skip-checks --github >&2
    printf '\n' >&2
    [[ "${status}" != 0 ]] || status=1
  fi
  if [[ -n "${DIST_TMP_DIR}" ]]; then rm -rf "${DIST_TMP_DIR}"; fi
  if [[ -n "${SECRET_TMP_DIR}" ]]; then
    rm -rf "${SECRET_TMP_DIR}"
  fi
  exit "${status}"
}
trap cleanup_release_secrets EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [[ "${PUBLISH_FROM_SET}" == false && -n "${NAVIS_LASTFM_API_KEY:-}" ]]; then
  mkdir -p "${SCRIPT_DIR}/../build"
  SECRET_TMP_DIR="$(mktemp -d "$(cd "${SCRIPT_DIR}/../build" && pwd)/navis-secrets.XXXXXX")"
  LASTFM_DEFINES_FILE="${SECRET_TMP_DIR}/lastfm-defines.json"
  navis_write_lastfm_defines_file "${LASTFM_DEFINES_FILE}" "${NAVIS_LASTFM_API_KEY}"
  DART_DEFINE_ARGS+=("--dart-define-from-file=$(to_windows_host_path "${LASTFM_DEFINES_FILE}")")
fi

# Fail the release when an artifact still carries the plaintext Last.fm key.
scan_release_artifact() {
  local artifact="$1" status=0
  if [[ -z "${NAVIS_LASTFM_API_KEY:-}" ]]; then
    return 0
  fi
  echo "==> Scanning $(basename "${artifact}") for the plaintext Last.fm key..."
  scan_artifact_for_secret "${artifact}" "${NAVIS_LASTFM_API_KEY}" || status=$?
  case "${status}" in
    0) ;;
    1)
      echo "Error: $(basename "${artifact}") contains the plaintext Last.fm API key."
      exit 1
      ;;
    *)
      echo "Error: could not scan $(basename "${artifact}") for the Last.fm API key."
      exit 1
      ;;
  esac
}

# ─── Clean tree ─────────────────────────────────────────────────────────────
if [[ -n "$(git status --porcelain)" ]]; then
  echo "Error: Working tree is not clean. Commit or stash changes first."
  git status --short
  exit 1
fi

CURRENT_BRANCH="$(git branch --show-current)"
if [[ -z "${CURRENT_BRANCH}" ]]; then
  echo "Error: Release operations require a named branch, not a detached HEAD."
  exit 1
fi
SOURCE_COMMIT="$(git rev-parse HEAD)"
if [[ "${PUBLISH_FROM_SET}" == true && "${SOURCE_COMMIT}" != "${DIST_SOURCE_COMMIT}" ]]; then
  echo "Error: HEAD differs from the staged source commit (${DIST_SOURCE_COMMIT}). Check out that commit before publishing."
  exit 1
fi
if [[ "${BUILD_ONLY}" == true && ( -e "${SCRIPT_DIR}/../dist/${VERSION}" || -L "${SCRIPT_DIR}/../dist/${VERSION}" ) ]]; then
  echo "Error: dist/${VERSION} already exists; keep the verified bundle or move it before rebuilding."
  exit 1
fi

# ─── Existing version guard ─────────────────────────────────────────────────
# A version has shipped once its tag exists. pubspec.yaml is not the signal:
# development sets it to the coming version as soon as work on it starts.
PUBSPEC="${SCRIPT_DIR}/../pubspec.yaml"
REQUESTED_PUBSPEC_VERSION="${SEMVER}+${BUILD_NUMBER}"
CURRENT_PUBSPEC_VERSION="$(sed -n 's/^version: //p' "${PUBSPEC}" | head -1)"
TAG_GUARD_ARGS=("${VERSION}")
if [[ "${ALLOW_EXISTING_VERSION}" == "true" ]]; then
  TAG_GUARD_ARGS+=("--allow-existing-version")
fi
if [[ "${BUILD_ONLY}" == true ]]; then TAG_GUARD_ARGS+=(--local-only); fi
"${SCRIPT_DIR}/release_tag_guard.sh" "${TAG_GUARD_ARGS[@]}"
if [[ "${PUBLISH_FROM_SET}" == true ]] && git rev-parse -q --verify "refs/tags/${VERSION}" >/dev/null; then
  if [[ "$(git rev-parse "${VERSION}^{commit}")" != "${DIST_SOURCE_COMMIT}" ]]; then
    echo "Error: Existing tag ${VERSION} differs from the staged source commit."
    exit 1
  fi
fi
if [[ ( "${BUILD_ONLY}" == true || "${PUBLISH_FROM_SET}" == true ) && "${CURRENT_PUBSPEC_VERSION}" != "${REQUESTED_PUBSPEC_VERSION}" ]]; then
  echo "Error: The two-phase release requires pubspec.yaml at ${REQUESTED_PUBSPEC_VERSION}; commit that version before building."
  exit 1
fi
if [[ "${CURRENT_PUBSPEC_VERSION}" == "${REQUESTED_PUBSPEC_VERSION}" ]]; then
  echo "==> pubspec.yaml is already at ${REQUESTED_PUBSPEC_VERSION} (set during development)."
fi

# ─── R2 preconditions ───────────────────────────────────────────────────────
# Fail before building or tagging if the R2 publish at the end cannot succeed.
if [[ "${BUILD_ONLY}" == false ]]; then
  "${SCRIPT_DIR}/r2_publish.sh" check --tag="${VERSION}" --channel="${UPDATE_CHANNEL}"
fi

# ─── Checks ─────────────────────────────────────────────────────────────────
if [[ "${SKIP_CHECKS}" == "false" ]]; then
  echo "==> Running quality checks (./tool/check.sh)..."
  "${SCRIPT_DIR}/check.sh"
else
  echo "==> Skipping quality checks (--skip-checks)."
fi

if [[ "${BUILD_ONLY}" == false && "${PUBLISH_FROM_SET}" == false ]]; then
# ─── Version bump ───────────────────────────────────────────────────────────
echo "==> Bumping pubspec.yaml to ${SEMVER}+${BUILD_NUMBER}..."
sed -i.bak "s/^version: .*/version: ${SEMVER}+${BUILD_NUMBER}/" "${PUBSPEC}"
rm -f "${PUBSPEC}.bak"

fi

if [[ "${PUBLISH_FROM_SET}" == false ]]; then
# ─── Build artifacts ────────────────────────────────────────────────────────
ASSET_FILES=()
ASSET_NAMES=()

# Every release target strips Dart debug info into local symbol files. It stays
# local under build/symbols/<platform>/<version> for symbolising traces.
set_symbol_args() {
  local symbols_dir="${SCRIPT_DIR}/../build/symbols/$1/${VERSION}"
  mkdir -p "${symbols_dir}"
  SYMBOL_ARGS=("--split-debug-info=${symbols_dir}")
}

build_android_apks() {
  local variant="$1"
  local symbols_dir="${SCRIPT_DIR}/../build/symbols/android/${VERSION}/${variant}"
  local split_args=()
  [[ "${variant}" != split-per-abi ]] || split_args+=(--split-per-abi)
  clean_android_release_outputs
  mkdir -p "${symbols_dir}"
  local build_args=(build apk --release --flavor sideload
    "--split-debug-info=${symbols_dir}" "${split_args[@]}" "${DART_DEFINE_ARGS[@]}")
  # Gradle needs the host JDK when invoked from a Flatpak sandbox.
  if [[ -n "${FLATPAK_ID:-}" ]]; then
    local flutter_bin
    flutter_bin="$(command -v flutter)"
    /usr/bin/flatpak-spawn --host -- bash -c '
      export PATH="$1:$HOME/.local/bin:$PATH"
      export NAVIS_SELF_UPDATE=true
      cd "$2"
      shift 2
      flutter "$@"
    ' navis-android-build "$(dirname "${flutter_bin}")" "${SCRIPT_DIR}/.." "${build_args[@]}"
  else
    flutter "${build_args[@]}"
  fi
  echo "    Debug symbols -> ${symbols_dir}"
}

stage_android_apk() {
  local APK_PATH="$1" APK_ASSET_NAME="$2"
  local APK_ASSET="${SCRIPT_DIR}/../${APK_ASSET_NAME}"
  remove_release_asset "${APK_ASSET}"
  if [[ ! -f "${APK_PATH}" ]]; then
    echo "Error: APK not found at ${APK_PATH}"
    exit 1
  fi
  cp "${APK_PATH}" "${APK_ASSET}"
  scan_release_artifact "${APK_ASSET}"
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

    # key.properties storeFile is relative to android/app/
    STORE_FILE_ABS="${SCRIPT_DIR}/../android/app/${STORE_FILE}"
    EXPECTED_CERT_SHA256="$(STORE_PASSWORD="${STORE_PASSWORD}" keytool -list -v \
      -keystore "${STORE_FILE_ABS}" \
      -storepass:env STORE_PASSWORD \
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
  else
    echo "Error: android/key.properties is required to validate the release signer." >&2
    exit 1
  fi

  echo "==> Validating APK release strings..."
  validate_apk_strings "${APK_ASSET}"

  echo "    APK metadata/signing/strings OK"
}

if [[ "${BUILD_ANDROID}" == "true" ]]; then
  export NAVIS_SELF_UPDATE=true
  DART_DEFINE_ARGS+=("--dart-define=NAVIS_SELF_UPDATE=true")
  echo "==> Building universal Android APK..."
  build_android_apks universal
  # Copy outside build/app before the split build cleans or replaces its outputs.
  stage_android_apk "${SCRIPT_DIR}/../build/app/outputs/flutter-apk/app-sideload-release.apk" \
    "${ASSET_PREFIX}-${VERSION}.apk"

  echo "==> Building per-architecture Android APKs..."
  build_android_apks split-per-abi
  for abi in arm64-v8a armeabi-v7a x86_64; do
    stage_android_apk "${SCRIPT_DIR}/../build/app/outputs/flutter-apk/app-${abi}-sideload-release.apk" \
      "${ASSET_PREFIX}-${VERSION}-android-${abi}.apk"
  done
fi

if [[ "${BUILD_IOS}" == "true" ]]; then
  echo "==> Building iOS IPA (ad-hoc)..."
  set_symbol_args ios
  flutter build ipa --release --export-method ad-hoc "${SYMBOL_ARGS[@]}" "${DART_DEFINE_ARGS[@]}"

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
  scan_release_artifact "${IPA_ASSET}"
  ASSET_FILES+=("${IPA_ASSET}")
  ASSET_NAMES+=("${IPA_ASSET_NAME}")
  echo "    IPA -> ${IPA_ASSET_NAME}"
fi

if [[ "${BUILD_MACOS}" == "true" ]]; then
  echo "==> Building macOS app..."
  set_symbol_args macos
  flutter build macos --release "${SYMBOL_ARGS[@]}" "${DART_DEFINE_ARGS[@]}"

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
  scan_release_artifact "${MACOS_ASSET}"
  ASSET_FILES+=("${MACOS_ASSET}")
  ASSET_NAMES+=("${MACOS_ASSET_NAME}")
  echo "    macOS -> ${MACOS_ASSET_NAME}"
fi

if [[ "${BUILD_LINUX}" == "true" ]]; then
  if [[ "${UNAME}" == "Linux" ]]; then
    echo "==> Building Linux release in Ubuntu 22.04..."
    set_symbol_args linux
    linux_args=("--package=${LINUX_PACKAGE_MODE}" "--version=${VERSION}" "--asset-prefix=${ASSET_PREFIX}"
      "${SYMBOL_ARGS[@]}" "${DART_DEFINE_ARGS[@]}")
    # The container script reads these from its environment.
    export NAVIS_DEB_MAINTAINER="${NAVIS_DEB_MAINTAINER:-}"
    NAVIS_FLUTTER_SDK="${NAVIS_FLUTTER_SDK:-$(dirname "$(dirname "$(readlink -f "$(command -v flutter)")")")}"
    export NAVIS_FLUTTER_SDK
    if [[ -n "${FLATPAK_ID:-}" ]]; then
      /usr/bin/flatpak-spawn --host --env=NAVIS_FLUTTER_SDK="${NAVIS_FLUTTER_SDK}" \
        --env=NAVIS_DEB_MAINTAINER="${NAVIS_DEB_MAINTAINER}" \
        -- "${SCRIPT_DIR}/linux/build_in_container.sh" "${linux_args[@]}"
    else
      "${SCRIPT_DIR}/linux/build_in_container.sh" "${linux_args[@]}"
    fi
  else
    echo "==> Building Linux artifacts on remote host (${LINUX_SSH_TARGET})..."
    "${SCRIPT_DIR}/remote_build_linux.sh" \
      --ssh="${LINUX_SSH_TARGET}" --version="${VERSION}" \
      --asset-prefix="${ASSET_PREFIX}" --package="${LINUX_PACKAGE_MODE}" \
      --channel="${UPDATE_CHANNEL}" --lastfm-defines-file="${LASTFM_DEFINES_FILE}" \
      --remote-dir="${LINUX_REMOTE_DIR}" --repo-root="${SCRIPT_DIR}/.."
  fi
  linux_names=()
  if [[ "${LINUX_PACKAGE_MODE}" == bundle || "${LINUX_PACKAGE_MODE}" == all ]]; then
    linux_names+=("${ASSET_PREFIX}-${VERSION}-linux.tar.gz")
  fi
  if [[ "${LINUX_PACKAGE_MODE}" == deb || "${LINUX_PACKAGE_MODE}" == all ]]; then
    linux_names+=("${ASSET_PREFIX}-${VERSION}-linux-amd64.deb")
  fi
  if [[ "${LINUX_PACKAGE_MODE}" == rpm || "${LINUX_PACKAGE_MODE}" == all ]]; then
    linux_names+=("${ASSET_PREFIX}-${VERSION}-linux-x86_64.rpm")
  fi
  for name in "${linux_names[@]}"; do
    asset="${SCRIPT_DIR}/../${name}"
    [[ -f "${asset}" ]] || { echo "Error: Missing Linux artifact: ${name}"; exit 1; }
    scan_release_artifact "${asset}"
    ASSET_FILES+=("${asset}")
    ASSET_NAMES+=("${name}")
    echo "    Linux -> ${name}"
  done
fi

if [[ "${BUILD_WINDOWS}" == "true" ]]; then
  if [[ "${OS:-}" == "Windows_NT" ]]; then
    echo "==> Building Windows bundle..."
    set_symbol_args windows
    flutter build windows --release "${SYMBOL_ARGS[@]}" "${DART_DEFINE_ARGS[@]}"

    WINDOWS_RELEASE_DIR="${SCRIPT_DIR}/../build/windows/x64/runner/Release"
    if [[ ! -d "${WINDOWS_RELEASE_DIR}" ]]; then
      echo "Error: Windows release dir not found at ${WINDOWS_RELEASE_DIR}"
      exit 1
    fi

    scan_release_artifact "${WINDOWS_RELEASE_DIR}"

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
      --lastfm-defines-file="${LASTFM_DEFINES_FILE}" \
      --remote-dir="${WINDOWS_REMOTE_DIR}" \
      --flutter-dir="${WINDOWS_FLUTTER_DIR}" \
      --repo-root="${SCRIPT_DIR}/.."
    if [[ ! -f "${WINDOWS_ASSET}" ]]; then
      echo "Error: Remote Windows artifact was not fetched (${WINDOWS_ASSET_NAME})."
      exit 1
    fi
  fi

  scan_release_artifact "${WINDOWS_ASSET}"

  ASSET_FILES+=("${WINDOWS_ASSET}")
  ASSET_NAMES+=("${WINDOWS_ASSET_NAME}")
  echo "    Windows -> ${WINDOWS_ASSET_NAME}"
fi

fi # build artifacts

generate_release_notes() {
  echo "==> Generating release notes for ${VERSION}..."
  RELEASE_BODY="$(dart tool/generate_release_notes.dart "${VERSION}" 2>/dev/null)" || true
  if [[ -z "${RELEASE_BODY}" ]]; then
    RELEASE_BODY="## Navis ${VERSION} (${UPDATE_CHANNEL})"
    echo "    No changelog entry found — using generic release body."
  else
    echo "    Release notes generated successfully."
  fi
}

if [[ "${BUILD_ONLY}" == true ]]; then
  if [[ -n "$(git status --porcelain)" || "$(git rev-parse HEAD)" != "${SOURCE_COMMIT}" ]]; then
    echo "Error: Source changed during the build; commit it and rebuild before staging."
    exit 1
  fi
  generate_release_notes
  stage_release_dist
  exit 0
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
# A main that was already ahead stays ahead, so the tag would not match the binaries.
if [[ "${PUBLISH_FROM_SET}" == true && "$(git rev-parse HEAD)" != "${DIST_SOURCE_COMMIT}" ]]; then
  echo "Error: main is at $(git rev-parse --short HEAD), not the staged source commit ${DIST_SOURCE_COMMIT}; refusing to tag."
  exit 1
fi

if git rev-parse -q --verify "refs/tags/${VERSION}" >/dev/null; then
  # Only reachable with --allow-existing-version (see the version guard).
  echo "==> Reusing existing tag ${VERSION}."
else
  echo "==> Tagging ${VERSION} on main..."
  git tag -a "${VERSION}" -m "Release ${VERSION} (${UPDATE_CHANNEL})"
fi

echo "==> Pushing main, ${CURRENT_BRANCH}, and tag ${VERSION}..."
git push origin main
git push origin "${CURRENT_BRANCH}"
git push origin "${VERSION}"

git checkout "${CURRENT_BRANCH}"

# ─── Generate release notes from changelog_data ─────────────────────────────
if [[ "${PUBLISH_FROM_SET}" == false ]]; then
  generate_release_notes
fi

# Retain a checksummed bundle before R2 changes so every GitHub failure can
# resume without rebuilding, including direct build-and-publish runs.
if [[ "${PUBLISH_GITHUB}" == true && "${PUBLISH_FROM_SET}" == false ]]; then
  SOURCE_COMMIT="$(git rev-parse HEAD)"
  stage_release_dist --recovery
fi

# ─── Publish to R2 ──────────────────────────────────────────────────────────
NOTES_FILE="$(mktemp)"
printf '%s\n' "${RELEASE_BODY}" > "${NOTES_FILE}"
echo "==> Publishing ${VERSION} to R2 (channel=${UPDATE_CHANNEL})..."
if [[ -z "${SECRET_TMP_DIR}" ]]; then SECRET_TMP_DIR="$(mktemp -d)"; fi
VERIFIED_MANIFEST="${SECRET_TMP_DIR}/manifest.json"
GITHUB_CHECKSUMS="${SECRET_TMP_DIR}/SHA256SUMS"
"${SCRIPT_DIR}/r2_publish.sh" publish --tag="${VERSION}" --channel="${UPDATE_CHANNEL}" \
  --manifest-out="${VERIFIED_MANIFEST}" --checksums-out="${GITHUB_CHECKSUMS}" --notes-file="${NOTES_FILE}" "${ASSET_FILES[@]}"
R2_PUBLISHED=true
rm -f "${NOTES_FILE}"

# ─── Create Forgejo release (1.5.0 bridge only) ─────────────────────────────
if [[ "${PUBLISH_FORGEJO}" == "true" ]]; then
  # Keep the token out of curl's argv. The existing EXIT trap removes this
  # header together with the other release secrets, even on upload failure.
  if [[ -z "${SECRET_TMP_DIR}" ]]; then
    SECRET_TMP_DIR="$(mktemp -d)"
  fi
  FORGEJO_AUTH_HEADER_FILE="$(mktemp "${SECRET_TMP_DIR}/forgejo-header.XXXXXX")"
  chmod 600 "${FORGEJO_AUTH_HEADER_FILE}"
  printf 'Authorization: token %s\n' "${FORGEJO_TOKEN}" > "${FORGEJO_AUTH_HEADER_FILE}"

  echo "==> Creating Forgejo release ${VERSION} (channel=${UPDATE_CHANNEL}, prerelease=${RELEASE_PRERELEASE})..."
  RELEASE_RESPONSE=$(curl -sf -X POST \
    "${FORGEJO_URL}/api/v1/repos/${FORGEJO_REPO}/releases" \
    -H "@${FORGEJO_AUTH_HEADER_FILE}" \
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

  for i in "${!ASSET_FILES[@]}"; do
    asset_file="${ASSET_FILES[$i]}"
    asset_name="${ASSET_NAMES[$i]}"
    echo "==> Uploading ${asset_name} to Forgejo..."
    curl -sf -X POST \
      "${FORGEJO_URL}/api/v1/repos/${FORGEJO_REPO}/releases/${RELEASE_ID}/assets?name=${asset_name}" \
      -H "@${FORGEJO_AUTH_HEADER_FILE}" \
      -F "attachment=@${asset_file}" >/dev/null
    echo "    Uploaded ${asset_name}"
  done
fi

# ─── Publish the verified R2 envelope and identical artifacts to GitHub ─────
if [[ "${PUBLISH_GITHUB}" == true ]]; then
  git push github main "${VERSION}"
  github_notes="${SECRET_TMP_DIR}/release-notes.md"
  {
    echo '## Download'
    echo
    echo 'Choose Porthorion downloads or the identical GitHub attachments below.'
    echo 'Both updater sources use the same signed manifest and artifact checks.'
    echo
    for asset in "${ASSET_FILES[@]}"; do
      name="$(basename "${asset}")"
      echo "- [${name}](https://downloads.porthorion.com/navis/releases/${VERSION}/${name})"
    done
    echo
    printf '%s\n' "${RELEASE_BODY}"
  } > "${github_notes}"
  navis_github_publish "${VERSION}" "${RELEASE_PRERELEASE}" "${github_notes}" \
    "${VERIFIED_MANIFEST}" "${ASSET_FILES[@]}" "${GITHUB_CHECKSUMS}"
  GITHUB_VERIFIED=true
fi

# Artifacts stay on disk until every publish step has succeeded, so a failed
# upload can be retried from the retained release bundle.
if [[ "${PUBLISH_FROM_SET}" == false ]]; then rm -f "${ASSET_FILES[@]}"; fi

echo ""
echo "==> Done! Release ${VERSION} published."
echo "    https://downloads.porthorion.com/navis/channels/${UPDATE_CHANNEL}/manifest.json"
