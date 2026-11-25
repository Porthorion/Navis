#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./tool/macos_notarize.sh --app=<path/to/App.app> --output=<path/to/output.zip> [options]

Options:
  --identity=<name>         codesign identity (default: $MACOS_SIGN_IDENTITY)
  --notary-key=<AuthKey.p8> --notary-key-id=<id> --notary-issuer=<id>
                            App Store Connect API key (preferred; no keychain needed)
  --notary-profile=<name>   notarytool keychain profile, used without a key
                            (default: $MACOS_NOTARY_PROFILE)
  --help                    Show this help

Required environment (if options omitted):
  MACOS_SIGN_IDENTITY
  MACOS_NOTARY_PROFILE (unless an API key is given)

This script:
  1) signs the .app bundle inside-out (nested code first, then the app with
     hardened runtime and macos/Runner/Release.entitlements)
  2) submits a zip to Apple notary service and waits
  3) staples the notarization ticket
  4) emits a final distributable zip at --output
EOF
}

APP_PATH=""
OUTPUT_PATH=""
IDENTITY="${MACOS_SIGN_IDENTITY:-}"
NOTARY_PROFILE="${MACOS_NOTARY_PROFILE:-}"
NOTARY_KEY="" NOTARY_KEY_ID="" NOTARY_ISSUER=""

for arg in "$@"; do
  case "${arg}" in
    --app=*) APP_PATH="${arg#--app=}" ;;
    --output=*) OUTPUT_PATH="${arg#--output=}" ;;
    --identity=*) IDENTITY="${arg#--identity=}" ;;
    --notary-key=*) NOTARY_KEY="${arg#--notary-key=}" ;;
    --notary-key-id=*) NOTARY_KEY_ID="${arg#--notary-key-id=}" ;;
    --notary-issuer=*) NOTARY_ISSUER="${arg#--notary-issuer=}" ;;
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

# The API key wins over a profile; messages name options, never values.
if [[ -n "${NOTARY_KEY}${NOTARY_KEY_ID}${NOTARY_ISSUER}" ]]; then
  if [[ -z "${NOTARY_KEY}" || -z "${NOTARY_KEY_ID}" || -z "${NOTARY_ISSUER}" ]]; then
    echo "Error: --notary-key, --notary-key-id and --notary-issuer go together." >&2
    exit 1
  fi
  if [[ ! -f "${NOTARY_KEY}" || ! -r "${NOTARY_KEY}" ]]; then
    echo "Error: --notary-key does not point to a readable file." >&2
    exit 1
  fi
  NOTARY_AUTH=(--key "${NOTARY_KEY}" --key-id "${NOTARY_KEY_ID}" --issuer "${NOTARY_ISSUER}")
  NOTARY_AUTH_LABEL="API key"
elif [[ -n "${NOTARY_PROFILE}" ]]; then
  NOTARY_AUTH=(--keychain-profile "${NOTARY_PROFILE}")
  NOTARY_AUTH_LABEL="profile: ${NOTARY_PROFILE}"
else
  echo "Error: missing notary credentials. Set --notary-key, --notary-key-id and --notary-issuer (App Store Connect API key), or --notary-profile / MACOS_NOTARY_PROFILE." >&2
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

ENTITLEMENTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/macos/Runner/Release.entitlements"
if [[ ! -f "${ENTITLEMENTS}" ]]; then
  echo "Error: entitlements file not found: ${ENTITLEMENTS}" >&2
  exit 1
fi

# Sign inside-out: nested code first (find -depth lists children before their
# parents), then the app. Hardened runtime and a secure timestamp everywhere;
# entitlements only on the app, whose main executable is the one that needs
# them. --deep is deprecated for signing and would skip that distinction.
echo "==> Signing nested code in ${APP_NAME}..."
while IFS= read -r -d '' nested; do
  codesign --force --options runtime --timestamp --sign "${IDENTITY}" "${nested}"
done < <(find "${APP_PATH}/Contents" -depth \
  \( -name '*.dylib' -o -name '*.framework' -o -name '*.xpc' -o -name '*.app' \) \
  -print0)

echo "==> Signing ${APP_NAME}..."
codesign \
  --force \
  --options runtime \
  --timestamp \
  --entitlements "${ENTITLEMENTS}" \
  --sign "${IDENTITY}" \
  "${APP_PATH}"

echo "==> Verifying signature..."
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"

echo "==> Creating notary upload archive..."
ditto -c -k --keepParent "${APP_PATH}" "${NOTARY_ZIP}"

echo "==> Submitting to Apple notary service (${NOTARY_AUTH_LABEL})..."
xcrun notarytool submit "${NOTARY_ZIP}" "${NOTARY_AUTH[@]}" --wait

echo "==> Stapling notarization ticket..."
xcrun stapler staple "${APP_PATH}"
xcrun stapler validate "${APP_PATH}"

mkdir -p "$(dirname "${OUTPUT_PATH}")"
echo "==> Creating notarized distributable zip..."
ditto -c -k --keepParent "${APP_PATH}" "${OUTPUT_PATH}"

echo "==> Notarized artifact ready: ${OUTPUT_PATH}"

