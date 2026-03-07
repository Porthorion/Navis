#!/usr/bin/env bash
# tool/dev_app.sh — Build/run a sidecar "Navis Dev" app that installs next to stable.
#
# Defaults:
#   - applicationId suffix: .dev
#   - app name: Navis Dev
#   - updater channel: dev
#
# Usage:
#   ./tool/dev_app.sh run [flutter-run-args...]
#   ./tool/dev_app.sh apk [flutter-build-args...]
#
# Examples:
#   ./tool/dev_app.sh run -d R5CX14TVQEE
#   ./tool/dev_app.sh apk
#   NAVIS_APP_ID_SUFFIX=.sidecar NAVIS_APP_NAME="Navis Sidecar" ./tool/dev_app.sh run

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.."

MODE="${1:-run}"
if [[ $# -gt 0 ]]; then
  shift
fi

export NAVIS_APP_ID_SUFFIX="${NAVIS_APP_ID_SUFFIX:-.dev}"
export NAVIS_APP_NAME="${NAVIS_APP_NAME:-Navis Dev}"

DART_DEFINE_UPDATE_CHANNEL="--dart-define=NAVIS_UPDATE_CHANNEL=dev"

echo "==> Dev app identity"
echo "    NAVIS_APP_ID_SUFFIX=${NAVIS_APP_ID_SUFFIX}"
echo "    NAVIS_APP_NAME=${NAVIS_APP_NAME}"
echo "    NAVIS_UPDATE_CHANNEL=dev"

case "${MODE}" in
  run)
    flutter run --debug "${DART_DEFINE_UPDATE_CHANNEL}" "$@"
    ;;
  apk)
    flutter build apk --release "${DART_DEFINE_UPDATE_CHANNEL}" "$@"
    ;;
  *)
    echo "Unknown mode: ${MODE}"
    echo "Usage: ./tool/dev_app.sh <run|apk> [flutter args...]"
    exit 1
    ;;
esac
