#!/usr/bin/env bash
# tool/release.sh — Local release script for Navis.
#
# Builds release artefacts (APK required, IPA optional), bumps pubspec.yaml,
# tags the commit, merges into main, and publishes a Forgejo release with the
# build artefacts attached — all from the local machine.
#
# Prerequisites:
#   - jq         (brew install jq  /  sudo apt install jq)
#   - Flutter SDK on PATH
#   - Android SDK configured (for APK)
#   - Xcode + valid signing identity (for IPA, macOS only, pass --ipa flag)
#   - Environment variables set in tool/release.env (git-ignored):
#       FORGEJO_URL    e.g. https://git.porthorion.com
#       FORGEJO_REPO   e.g. khalifa/Navis
#       FORGEJO_TOKEN  API token with "write:release" scope
#   - Copy tool/release.env.example -> tool/release.env and fill in values.
#
# Usage:
#   ./tool/release.sh <version> [--ipa] [--skip-checks]
#
# Examples:
#   ./tool/release.sh v0.3.0              # APK only, full checks
#   ./tool/release.sh v0.3.0 --ipa        # APK + IPA
#   ./tool/release.sh v0.3.0 --skip-checks   # skip ./tool/check.sh (dev only)
#
# Steps performed:
#   1.  Validate inputs, env vars, and required tools.
#   2.  Run ./tool/check.sh (format, analyze, lint, tests) — skippable.
#   3.  Bump version in pubspec.yaml to <semver>+<build-number>.
#   4.  Build release APK  (flutter build apk --release).
#   5.  [--ipa] Build release IPA (flutter build ipa --release --export-method ad-hoc).
#   6.  Commit the pubspec bump on the current branch (dev).
#   7.  Merge dev -> main (fast-forward-only; fails if diverged).
#   8.  Create an annotated git tag on main and push tag + main + dev.
#   9.  Create a Forgejo release (always stable — no pre-releases).
#   10. Upload APK (and IPA if built) as release assets.

set -euo pipefail

# ─── Parse arguments ────────────────────────────────────────────────────────
VERSION=""
BUILD_IPA=false
SKIP_CHECKS=false

for arg in "$@"; do
  case "${arg}" in
    --ipa)          BUILD_IPA=true ;;
    --skip-checks)  SKIP_CHECKS=true ;;
    v*.*)           VERSION="${arg}" ;;
    *)
      echo "Unknown argument: ${arg}"
      echo "Usage: ./tool/release.sh <version> [--ipa] [--skip-checks]"
      exit 1
      ;;
  esac
done

if [[ -z "${VERSION}" ]]; then
  echo "Usage: ./tool/release.sh <version> [--ipa] [--skip-checks]"
  echo "  e.g. ./tool/release.sh v0.3.0"
  exit 1
fi

# Strip leading 'v' for pubspec (v0.3.0 -> 0.3.0)
SEMVER="${VERSION#v}"

# Derive a numeric build number from the semver (e.g. 0.3.0 -> 300, 1.2.3 -> 10203)
IFS='.' read -r MAJOR MINOR PATCH <<< "${SEMVER%%[-+]*}"
BUILD_NUMBER=$(( (MAJOR * 10000) + (MINOR * 100) + PATCH ))

# ─── Source env file ────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/release.env" ]]; then
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/release.env"
fi

# ─── Validate env ───────────────────────────────────────────────────────────
: "${FORGEJO_URL:?Set FORGEJO_URL in tool/release.env (e.g. https://git.porthorion.com)}"
: "${FORGEJO_REPO:?Set FORGEJO_REPO in tool/release.env (e.g. khalifa/Navis)}"
: "${FORGEJO_TOKEN:?Set FORGEJO_TOKEN in tool/release.env (API token with write:release)}"

# ─── Validate tools ─────────────────────────────────────────────────────────
for tool in jq flutter git curl; do
  if ! command -v "${tool}" &>/dev/null; then
    echo "Error: '${tool}' is required but not found on PATH."
    exit 1
  fi
done

if [[ "${BUILD_IPA}" == "true" ]]; then
  if [[ "$(uname)" != "Darwin" ]]; then
    echo "Error: --ipa requires macOS with Xcode installed."
    exit 1
  fi
  if ! command -v xcodebuild &>/dev/null; then
    echo "Error: xcodebuild not found. Install Xcode from the App Store."
    exit 1
  fi
fi

# ─── Ensure working tree is clean ───────────────────────────────────────────
if [[ -n "$(git status --porcelain)" ]]; then
  echo "Error: Working tree is not clean. Commit or stash changes first."
  git status --short
  exit 1
fi

CURRENT_BRANCH="$(git branch --show-current)"

# ─── Quality checks ─────────────────────────────────────────────────────────
if [[ "${SKIP_CHECKS}" == "false" ]]; then
  echo "==> Running quality checks (./tool/check.sh)..."
  "${SCRIPT_DIR}/check.sh"
else
  echo "==> Skipping quality checks (--skip-checks)."
fi

# ─── Bump pubspec.yaml version ──────────────────────────────────────────────
PUBSPEC="${SCRIPT_DIR}/../pubspec.yaml"
echo "==> Bumping pubspec.yaml to ${SEMVER}+${BUILD_NUMBER}..."
# Update version line in pubspec.yaml (matches 'version: X.Y.Z+N' or 'version: X.Y.Z')
sed -i.bak "s/^version: .*/version: ${SEMVER}+${BUILD_NUMBER}/" "${PUBSPEC}"
rm -f "${PUBSPEC}.bak"

# ─── Build APK ──────────────────────────────────────────────────────────────
APK_PATH="build/app/outputs/flutter-apk/app-release.apk"
APK_ASSET="navis-${VERSION}.apk"

echo "==> Building release APK..."
flutter build apk --release

if [[ ! -f "${APK_PATH}" ]]; then
  echo "Error: APK not found at ${APK_PATH}"
  exit 1
fi
cp "${APK_PATH}" "${APK_ASSET}"
echo "    APK -> ${APK_ASSET}"

# ─── Build IPA (optional) ───────────────────────────────────────────────────
IPA_ASSET=""
if [[ "${BUILD_IPA}" == "true" ]]; then
  IPA_DIR="build/ios/ipa"
  IPA_ASSET="navis-${VERSION}.ipa"

  echo "==> Building release IPA (ad-hoc)..."
  flutter build ipa --release --export-method ad-hoc

  # flutter build ipa places the .ipa somewhere under build/ios/ipa/
  FOUND_IPA="$(find "${IPA_DIR}" -name "*.ipa" -maxdepth 2 | head -1)"
  if [[ -z "${FOUND_IPA}" ]]; then
    echo "Error: IPA not found under ${IPA_DIR}"
    exit 1
  fi
  cp "${FOUND_IPA}" "${IPA_ASSET}"
  echo "    IPA -> ${IPA_ASSET}"
fi

# ─── Commit pubspec bump ─────────────────────────────────────────────────────
echo "==> Committing pubspec bump..."
git add pubspec.yaml
git commit -m "chore: bump version to ${SEMVER}+${BUILD_NUMBER} for release ${VERSION}"

# ─── Merge dev -> main ──────────────────────────────────────────────────────
echo "==> Merging ${CURRENT_BRANCH} -> main..."
git checkout main
git merge --ff-only "${CURRENT_BRANCH}"

# ─── Tag on main ────────────────────────────────────────────────────────────
echo "==> Tagging ${VERSION} on main..."
git tag -a "${VERSION}" -m "Release ${VERSION}"

# ─── Push everything ────────────────────────────────────────────────────────
echo "==> Pushing main, ${CURRENT_BRANCH}, and tag ${VERSION}..."
git push origin main
git push origin "${CURRENT_BRANCH}"
git push origin "${VERSION}"

# Switch back to dev branch for continued development
git checkout "${CURRENT_BRANCH}"

# ─── Create Forgejo release (stable only) ───────────────────────────────────
echo "==> Creating Forgejo release ${VERSION} (stable)..."
RELEASE_RESPONSE=$(curl -sf -X POST \
  "${FORGEJO_URL}/api/v1/repos/${FORGEJO_REPO}/releases" \
  -H "Authorization: token ${FORGEJO_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{
    \"tag_name\": \"${VERSION}\",
    \"target_commitish\": \"main\",
    \"name\": \"Navis ${VERSION}\",
    \"body\": \"## Navis ${VERSION}\n\nSee the [full changelog](${FORGEJO_URL}/${FORGEJO_REPO}/compare/$(git describe --tags --abbrev=0 HEAD~1 2>/dev/null || echo main)...${VERSION}) for details.\",
    \"prerelease\": false,
    \"draft\": false
  }")

RELEASE_ID=$(echo "${RELEASE_RESPONSE}" | jq -r '.id')

if [[ -z "${RELEASE_ID}" || "${RELEASE_ID}" == "null" ]]; then
  echo "Error: Failed to create Forgejo release. Response:"
  echo "${RELEASE_RESPONSE}"
  exit 1
fi

# ─── Upload APK asset ───────────────────────────────────────────────────────
echo "==> Uploading APK..."
curl -sf -X POST \
  "${FORGEJO_URL}/api/v1/repos/${FORGEJO_REPO}/releases/${RELEASE_ID}/assets?name=${APK_ASSET}" \
  -H "Authorization: token ${FORGEJO_TOKEN}" \
  -F "attachment=@${APK_ASSET}" > /dev/null
echo "    Uploaded ${APK_ASSET}"
rm -f "${APK_ASSET}"

# ─── Upload IPA asset (if built) ────────────────────────────────────────────
if [[ -n "${IPA_ASSET}" && -f "${IPA_ASSET}" ]]; then
  echo "==> Uploading IPA..."
  curl -sf -X POST \
    "${FORGEJO_URL}/api/v1/repos/${FORGEJO_REPO}/releases/${RELEASE_ID}/assets?name=${IPA_ASSET}" \
    -H "Authorization: token ${FORGEJO_TOKEN}" \
    -F "attachment=@${IPA_ASSET}" > /dev/null
  echo "    Uploaded ${IPA_ASSET}"
  rm -f "${IPA_ASSET}"
fi

echo ""
echo "==> Done! Release ${VERSION} published."
echo "    ${FORGEJO_URL}/${FORGEJO_REPO}/releases/tag/${VERSION}"
