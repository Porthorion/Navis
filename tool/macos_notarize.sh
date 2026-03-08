#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./tool/macos_notarize.sh --app <path/to/App.app> --output <path/to/output.zip> [options]

Options:
  --identity=<name>         codesign identity (default: $MACOS_SIGN_IDENTITY)
  --notary-profile=<name>   notarytool keychain profile (default: $MACOS_NOTARY_PROFILE)
  --help                    Show this help

Required environment (if options omitted):
  MACOS_SIGN_IDENTITY
  MACOS_NOTARY_PROFILE

This script:
  1) signs the .app bundle
  2) submits a zip to Apple notary service and waits
  3) staples the notarization ticket
  4) emits a final distributable zip at --output
EOF
}

APP_PATH=""
OUTPUT_PATH=""
IDENTITY="${MACOS_SIGN_IDENTITY:-}"
NOTARY_PROFILE="${MACOS_NOTARY_PROFILE:-}"

for arg in "$@"; do
  case "${arg}" in
    --app=*) APP_PATH="${arg#--app=}" ;;
    --output=*) OUTPUT_PATH="${arg#--output=}" ;;
    --identity=*) IDENTITY="${arg#--identity=}" ;;
    --notary-profile=*) NOTARY_PROFILE="${arg#--notary-profile=}" ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: ${arg}" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "${APP_PATH}" || -z "${OUTPUT_PATH}" ]]; then
  echo "Error: --app and --output are required." >&2
  usage
  exit 1
fi

if [[ -z "${IDENTITY}" ]]; then
  echo "Error: missing signing identity. Set --identity or MACOS_SIGN_IDENTITY." >&2
  exit 1
fi

if [[ -z "${NOTARY_PROFILE}" ]]; then
  echo "Error: missing notary profile. Set --notary-profile or MACOS_NOTARY_PROFILE." >&2
  exit 1
fi

if [[ ! -d "${APP_PATH}" || "${APP_PATH##*.}" != "app" ]]; then
  echo "Error: --app must point to a .app bundle. Got: ${APP_PATH}" >&2
  exit 1
fi

for tool in codesign xcrun ditto mktemp; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    echo "Error: required tool '${tool}' not found." >&2
    exit 1
  fi
done

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

APP_NAME="$(basename "${APP_PATH}")"
NOTARY_ZIP="${TMP_DIR}/${APP_NAME%.app}-notary.zip"

echo "==> Signing ${APP_NAME}..."
codesign \
  --force \
  --deep \
  --options runtime \
  --timestamp \
  --sign "${IDENTITY}" \
  "${APP_PATH}"

echo "==> Verifying signature..."
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"

echo "==> Creating notary upload archive..."
ditto -c -k --keepParent "${APP_PATH}" "${NOTARY_ZIP}"

echo "==> Submitting to Apple notary service (profile: ${NOTARY_PROFILE})..."
xcrun notarytool submit "${NOTARY_ZIP}" \
  --keychain-profile "${NOTARY_PROFILE}" \
  --wait

echo "==> Stapling notarization ticket..."
xcrun stapler staple "${APP_PATH}"
xcrun stapler validate "${APP_PATH}"

mkdir -p "$(dirname "${OUTPUT_PATH}")"
echo "==> Creating notarized distributable zip..."
ditto -c -k --keepParent "${APP_PATH}" "${OUTPUT_PATH}"

echo "==> Notarized artifact ready: ${OUTPUT_PATH}"

