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
#   ./tool/dev_app.sh auto [flutter-run-args...]
#   ./tool/dev_app.sh dhu [flutter-run-args...]
#
# Examples:
#   ./tool/dev_app.sh run -d R5CX14TVQEE
#   ./tool/dev_app.sh apk
#   ./tool/dev_app.sh auto                  # AAOS emulator (no DHU needed)
#   ./tool/dev_app.sh dhu -d R5CX14TVQEE   # phone + Desktop Head Unit
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

    # libmpv (media_kit backend) lives in brew — expose it only for this run.
    export LD_LIBRARY_PATH="/home/linuxbrew/.linuxbrew/lib:${LD_LIBRARY_PATH:-}"
    flutter run -d linux --debug "${DART_DEFINE_ARGS[@]}" "$@"
    ;;
  apk)
    flutter build apk --release "${DART_DEFINE_ARGS[@]}" "$@"
    ;;
  auto)
    # Run on an Android Automotive OS (AAOS) emulator — no DHU or phone needed.
    # The emulator already embeds the car UI; Navis will appear in its media app drawer.
    #
    # Auto-detects any running AAOS emulator by matching "car" in `flutter devices`
    # output.  Pass -d <id> to override.
    if [[ "$*" != *"-d "* && "$*" != *"--device-id "* ]]; then
      AUTO_DEVICE=$(flutter devices 2>/dev/null \
        | grep -i "car" \
        | grep -oP '• \K\S+' \
        | head -1)
      if [[ -z "${AUTO_DEVICE}" ]]; then
        echo "ERROR: No Android Automotive emulator found."
        echo "  Start one in Android Studio → Device Manager → choose a Car target."
        echo "  Or pass -d <device-id> explicitly."
        exit 1
      fi
      DEVICE_ARGS=("-d" "${AUTO_DEVICE}")
      echo "==> Detected AAOS emulator: ${AUTO_DEVICE}"
    else
      DEVICE_ARGS=()
      echo "==> Using device from arguments"
    fi
    echo ""
    echo "  After launch, open the media app drawer in the emulator to find 'Navis Dev'."
    echo "  The browse tree (Playlists / Artists / Albums / Liked / Recent / Random Mix)"
    echo "  is served directly via MediaBrowserService — no Desktop Head Unit needed."
    echo ""
    flutter run --debug "${DEVICE_ARGS[@]}" "${DART_DEFINE_ARGS[@]}" "$@"
    ;;
  dhu)
    # Run on a phone AND launch the Desktop Head Unit (DHU) so you can test
    # Android Auto projection in parallel.
    #
    # Usage: ./tool/dev_app.sh dhu -d <phone-device-id>
    #
    # The DHU binary is resolved from $ANDROID_SDK_ROOT, $ANDROID_HOME, or
    # ~/Android/Sdk in that order.
    ANDROID_SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-${HOME}/Android/Sdk}}"
    DHU_BIN="${ANDROID_SDK}/extras/google/auto/desktop-head-unit"

    if [[ ! -x "${DHU_BIN}" ]]; then
      echo "ERROR: DHU not found at ${DHU_BIN}"
      echo "  Install it: Android Studio → SDK Manager → SDK Tools tab →"
      echo "  'Android Auto Desktop Head Unit Emulator'"
      exit 1
    fi

    echo "==> Forwarding Android Auto port (tcp:5277)…"
    adb forward tcp:5277 tcp:5277

    echo ""
    echo "  On your phone: Android Auto → Settings → tap Version 10× to unlock"
    echo "  Developer settings → tap ⋮ → Developer settings → Start head unit server"
    echo ""

    # Run the Flutter app on the phone in the background, then launch the DHU.
    echo "==> Starting Navis Dev on phone…"
    flutter run --debug "${DART_DEFINE_ARGS[@]}" "$@" &
    FLUTTER_PID=$!

    echo "==> Launching Desktop Head Unit…"
    # On modern Linux, libc++.so.1 / libc++abi.so.1 are not in the system path.
    # Resolve them from the NDK (which ships them) and Android Studio's LLDB plugin,
    # then fall back to the plain DHU binary for macOS / CI.
    NDK_LIB=$(ls -d "${ANDROID_SDK}"/ndk/*/toolchains/llvm/prebuilt/linux-x86_64/lib 2>/dev/null | sort -V | tail -1)
    LLDB_LIB="${HOME}/android-studio/plugins/android-ndk/resources/lldb/lib64"
    EMULATOR_LIB="${ANDROID_SDK}/emulator/lib64"
    EXTRA_LD=""
    [[ -d "${NDK_LIB}" ]] && EXTRA_LD="${NDK_LIB}"
    [[ -d "${LLDB_LIB}" ]] && EXTRA_LD="${EXTRA_LD}:${LLDB_LIB}"
    [[ -d "${EMULATOR_LIB}" ]] && EXTRA_LD="${EXTRA_LD}:${EMULATOR_LIB}"
    if [[ -n "${EXTRA_LD}" ]]; then
      LD_LIBRARY_PATH="${EXTRA_LD}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "${DHU_BIN}" || true
    else
      "${DHU_BIN}" || true
    fi

    # When DHU exits, also stop the flutter run session.
    kill "${FLUTTER_PID}" 2>/dev/null || true
    ;;
  *)
    echo "Unknown mode: ${MODE}"
    echo "Usage: ./tool/dev_app.sh <run|linux|apk|auto|dhu> [flutter args...]"
    exit 1
    ;;
esac
