#!/usr/bin/env bash
# tool/release.sh — Local release script for Navis.
#
# Replaces the old Forgejo Actions release workflow. Runs quality checks,
# builds a release APK, tags the commit, creates a Forgejo release, and
# uploads the APK as a release asset — all from the local machine.
#
# Prerequisites:
#   - jq installed (sudo apt install jq)
#   - Environment variables set (FORGEJO_URL, FORGEJO_REPO, FORGEJO_TOKEN)
#     or a tool/release.env file (sourced automatically, git-ignored)
#   - Flutter SDK on PATH
#   - Android SDK configured for release builds
#
# Usage:
#   ./tool/release.sh <version>
#
# Examples:
#   ./tool/release.sh v0.2.0            # stable release
#   ./tool/release.sh v0.3.0-beta.1     # pre-release (auto-detected)
#
# The script performs these steps in order:
#   1. Validates inputs and prerequisites.
#   2. Runs ./tool/check.sh (format, analyze, lint, tests).
#   3. Builds a release APK (flutter build apk --release).
#   4. Updates the version in pubspec.yaml to match the tag (if needed).
#   5. Creates an annotated git tag and pushes it.
#   6. Creates a Forgejo release via the API (auto-detects pre-release).
#   7. Uploads the APK as a release asset.

set -euo pipefail

VERSION="${1:-}"
if [[ -z "${VERSION}" ]]; then
  echo "Usage: ./tool/release.sh <version>  (e.g. v0.2.0 or v0.3.0-beta.1)"
  exit 1
fi

# Strip leading 'v' for pubspec version (v0.2.0 -> 0.2.0)
SEMVER="${VERSION#v}"

# --- Source optional env file (git-ignored) ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/release.env" ]]; then
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/release.env"
fi

# --- Validate environment ---
: "${FORGEJO_URL:?Set FORGEJO_URL (e.g. https://forgejo.example.com)}"
: "${FORGEJO_REPO:?Set FORGEJO_REPO (e.g. user/Navis)}"
: "${FORGEJO_TOKEN:?Set FORGEJO_TOKEN (API token with release write access)}"

if ! command -v jq &>/dev/null; then
  echo "Error: jq is required but not installed. Install with: sudo apt install jq"
  exit 1
fi

if ! command -v flutter &>/dev/null; then
  echo "Error: flutter is not on PATH."
  exit 1
fi

APK_PATH="build/app/outputs/flutter-apk/app-release.apk"

# --- Pre-flight: quality checks ---
echo "==> Running quality checks (./tool/check.sh)..."
./tool/check.sh

# --- Build release APK ---
echo "==> Building release APK..."
flutter build apk --release

if [[ ! -f "${APK_PATH}" ]]; then
  echo "Error: APK not found at ${APK_PATH}"
  exit 1
fi

# --- Tag ---
echo "==> Tagging ${VERSION}..."
git tag -a "${VERSION}" -m "Release ${VERSION}"
git push origin "${VERSION}"

# --- Determine pre-release ---
PRERELEASE=false
if [[ "${VERSION}" =~ -(alpha|beta|rc|dev) ]]; then
  PRERELEASE=true
fi

# --- Create Forgejo release ---
echo "==> Creating Forgejo release (prerelease=${PRERELEASE})..."
RELEASE_RESPONSE=$(curl -sf -X POST "${FORGEJO_URL}/api/v1/repos/${FORGEJO_REPO}/releases" \
  -H "Authorization: token ${FORGEJO_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{
    \"tag_name\": \"${VERSION}\",
    \"name\": \"${VERSION}\",
    \"body\": \"Release ${SEMVER}\",
    \"prerelease\": ${PRERELEASE}
  }")

RELEASE_ID=$(echo "${RELEASE_RESPONSE}" | jq -r '.id')

if [[ -z "${RELEASE_ID}" || "${RELEASE_ID}" == "null" ]]; then
  echo "Error: Failed to create Forgejo release. Response:"
  echo "${RELEASE_RESPONSE}"
  exit 1
fi

# --- Upload APK ---
echo "==> Uploading APK to release..."
curl -sf -X POST \
  "${FORGEJO_URL}/api/v1/repos/${FORGEJO_REPO}/releases/${RELEASE_ID}/assets?name=navis-${VERSION}.apk" \
  -H "Authorization: token ${FORGEJO_TOKEN}" \
  -F "attachment=@${APK_PATH}" > /dev/null

echo "==> Released ${VERSION} -> ${FORGEJO_URL}/${FORGEJO_REPO}/releases/tag/${VERSION}"
