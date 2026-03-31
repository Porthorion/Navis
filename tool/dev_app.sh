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
#   ./tool/dev_app.sh linux [flutter-run-args...]
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

# Optional env bootstrap (matches release flow). Allows defining:
# NAVIS_LASTFM_API_KEY=...
if [[ -f "${SCRIPT_DIR}/release.env" ]]; then
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/release.env"
fi

DART_DEFINE_ARGS=("--dart-define=NAVIS_UPDATE_CHANNEL=dev")
if [[ -n "${NAVIS_LASTFM_API_KEY:-}" ]]; then
  DART_DEFINE_ARGS+=("--dart-define=NAVIS_LASTFM_API_KEY=${NAVIS_LASTFM_API_KEY}")
fi

echo "==> Dev app identity"
echo "    NAVIS_APP_ID_SUFFIX=${NAVIS_APP_ID_SUFFIX}"
echo "    NAVIS_APP_NAME=${NAVIS_APP_NAME}"
echo "    NAVIS_UPDATE_CHANNEL=dev"
if [[ -n "${NAVIS_LASTFM_API_KEY:-}" ]]; then
  echo "    NAVIS_LASTFM_API_KEY=provided"
else
  echo "    NAVIS_LASTFM_API_KEY=missing (Same Vibes will fallback)"
fi

case "${MODE}" in
  run)
    flutter run --debug "${DART_DEFINE_ARGS[@]}" "$@"
    ;;
  linux)
    # Install user-level desktop file + icon before running so Wayland
    # compositors (GNOME, KDE Plasma, etc.) resolve the app icon via app-id.
    # Safe to run repeatedly — only installs/updates local user files.
    echo "==> Installing user-level desktop entry for Wayland icon support"
    _icon_dir="${HOME}/.local/share/icons/hicolor/256x256/apps"
    _app_dir="${HOME}/.local/share/applications"
    mkdir -p "${_icon_dir}" "${_app_dir}"
    cp -f "lib/src/icon/Navis_Icon_Dark.png" "${_icon_dir}/navis.png"
    cp -f "linux/packaging/com.navis.app.navis.desktop" \
          "${_app_dir}/com.navis.app.navis.desktop"
    gtk-update-icon-cache "${HOME}/.local/share/icons/hicolor" \
      --ignore-theme-index --quiet 2>/dev/null || true

    flutter run -d linux --debug "${DART_DEFINE_ARGS[@]}" "$@"
    ;;
  apk)
    flutter build apk --release "${DART_DEFINE_ARGS[@]}" "$@"
    ;;
  *)
    echo "Unknown mode: ${MODE}"
    echo "Usage: ./tool/dev_app.sh <run|linux|apk> [flutter args...]"
    exit 1
    ;;
esac
