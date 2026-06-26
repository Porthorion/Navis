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
#   ./tool/dev_app.sh dhu
#
# Examples:
#   ./tool/dev_app.sh run -d R5CX14TVQEE
#   ./tool/dev_app.sh apk
#   ./tool/dev_app.sh auto                  # AAOS emulator (no DHU needed)
#   ./tool/dev_app.sh dhu                   # builds APK, installs on phone, launches DHU

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

DART_DEFINE_ARGS=("--dart-define=NAVIS_UPDATE_CHANNEL=dev" "--dart-define=NAVIS_SELF_UPDATE=true")
export NAVIS_SELF_UPDATE=true
if [[ -n "${NAVIS_LASTFM_API_KEY:-}" ]]; then
  DART_DEFINE_ARGS+=("--dart-define=NAVIS_LASTFM_API_KEY=${NAVIS_LASTFM_API_KEY}")
fi
if [[ -n "${NAVIS_VOYAGE_SERVERS:-}" ]]; then
  DART_DEFINE_ARGS+=("--dart-define=NAVIS_VOYAGE_SERVERS=${NAVIS_VOYAGE_SERVERS}")
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
if [[ -n "${NAVIS_VOYAGE_SERVERS:-}" ]]; then
  echo "    NAVIS_VOYAGE_SERVERS=provided"
else
  echo "    NAVIS_VOYAGE_SERVERS=missing (Listen Together stays manual-only)"
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
    cp -f "lib/src/icon/Navis_App_Icon.png" "${_icon_dir}/navis.png"
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
    # Build a release APK, install it on the connected phone, verify the app
    # launches, then open the Desktop Head Unit (DHU) for Android Auto testing.
    #
    # Usage:  ./tool/dev_app.sh dhu
    # Requires: one target Android device connected via adb, DHU installed in SDK.
    #
    # The DHU binary is resolved from $ANDROID_SDK_ROOT, $ANDROID_HOME, or
    # ~/Android/Sdk in that order.
    ANDROID_SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-${HOME}/Android/Sdk}}"
    DHU_BIN="${ANDROID_SDK}/extras/google/auto/desktop-head-unit"
    APP_PKG="com.navis.app.navis${NAVIS_APP_ID_SUFFIX}"
    ADB_SERIAL="${ANDROID_SERIAL:-}"

    echo ""
    echo "==> Android Auto visibility note"
    echo "    DHU validates local projection and browse/playback behavior only."
    echo "    DHU success does not imply real-car visibility for sideloaded APKs."
    echo "    For default real-car testing, install both package IDs from Play"
    echo "    Internal App Sharing or an Internal Test Track:"
    echo "      - com.navis.app.navis"
    echo "      - com.navis.app.navis.dev"
    echo "    Sideloaded APKs require Android Auto developer mode + Unknown sources"
    echo "    and are not a supported default-user real-car path."
    echo ""

    if [[ -z "${ADB_SERIAL}" ]]; then
      mapfile -t ADB_DEVICES < <(adb devices | awk 'NR > 1 && $2 == "device" {print $1}')
      if [[ ${#ADB_DEVICES[@]} -eq 0 ]]; then
        echo "ERROR: No adb device found."
        exit 1
      elif [[ ${#ADB_DEVICES[@]} -eq 1 ]]; then
        ADB_SERIAL="${ADB_DEVICES[0]}"
      else
        # Android 11+ wireless debugging can expose the same phone twice:
        # once as the normal USB serial and once as an adb-tls mDNS transport.
        mapfile -t PREFERRED_ADB_DEVICES < <(
          printf '%s\n' "${ADB_DEVICES[@]}" \
            | grep -Ev '^adb-.+\._adb-tls-connect\._tcp$' || true
        )
        if [[ ${#PREFERRED_ADB_DEVICES[@]} -eq 1 ]]; then
          ADB_SERIAL="${PREFERRED_ADB_DEVICES[0]}"
        else
          echo "ERROR: Multiple adb devices found. Choose one with ANDROID_SERIAL:"
          printf '  %s\n' "${ADB_DEVICES[@]}"
          echo "Example: ANDROID_SERIAL=${ADB_DEVICES[0]} ./tool/dev_app.sh dhu"
          exit 1
        fi
      fi
    fi

    ADB_ARGS=(-s "${ADB_SERIAL}")
    echo "==> Using adb device ${ADB_SERIAL}"

    if [[ ! -x "${DHU_BIN}" ]]; then
      echo "ERROR: DHU not found at ${DHU_BIN}"
      echo "  Install it: Android Studio → SDK Manager → SDK Tools tab →"
      echo "  'Android Auto Desktop Head Unit Emulator'"
      exit 1
    fi

    # ── 1. Build release APK ────────────────────────────────────────────────
    echo "==> Building release APK…"
    flutter build apk --release "${DART_DEFINE_ARGS[@]}"

    APK_PATH="build/app/outputs/flutter-apk/app-release.apk"
    if [[ ! -f "${APK_PATH}" ]]; then
      echo "ERROR: APK not found at ${APK_PATH}"
      exit 1
    fi

    # ── 2. Install on phone ─────────────────────────────────────────────────
    echo "==> Installing ${APP_PKG} on device…"
    adb "${ADB_ARGS[@]}" install -r "${APK_PATH}"

    # ── 3. Launch app + verify it is running ────────────────────────────────
    echo "==> Launching ${APP_PKG}…"
    adb "${ADB_ARGS[@]}" shell am start -n "${APP_PKG}/com.navis.app.navis.MainActivity" > /dev/null

    echo "==> Waiting for app to start…"
    for _i in {1..10}; do
      if adb "${ADB_ARGS[@]}" shell pidof "${APP_PKG}" > /dev/null 2>&1; then
        _pid="$(adb "${ADB_ARGS[@]}" shell pidof "${APP_PKG}" | tr -d '\r')"
        echo "    App is running (PID ${_pid})"
        break
      fi
      if [[ ${_i} -eq 10 ]]; then
        echo "ERROR: App did not start within 10 seconds."
        exit 1
      fi
      sleep 1
    done

    # ── 4. Forward Android Auto port ────────────────────────────────────────
    echo "==> Forwarding Android Auto port (tcp:5277)…"
    adb "${ADB_ARGS[@]}" forward --remove-all
    adb "${ADB_ARGS[@]}" forward tcp:5277 tcp:5277

    echo ""
    echo "  On your phone: Android Auto → Settings → tap Version 10× to unlock"
    echo "  Developer settings → tap ⋮ → Developer settings → Start head unit server"
    echo "  If this sideloaded build does not appear in DHU, enable Unknown sources"
    echo "  in Android Auto developer settings. Keep Unknown sources off for the"
    echo "  real-car Play-installed validation path."
    echo ""

    # ── 5. Launch Desktop Head Unit ─────────────────────────────────────────
    echo "==> Launching Desktop Head Unit…"
    # On modern Linux, libc++.so.1 / libc++abi.so.1 are not in the system path.
    # We copy them from the NDK into the DHU directory on first run (idempotent).
    DHU_DIR="$(dirname "${DHU_BIN}")"

    if [[ "$(uname)" == "Linux" ]]; then
      NDK_X86_LIB=$(ls -d "${ANDROID_SDK}"/ndk/*/toolchains/llvm/prebuilt/linux-x86_64/lib/x86_64-unknown-linux-gnu 2>/dev/null | sort -V | tail -1)
      if [[ -n "${NDK_X86_LIB}" ]]; then
        [[ -f "${DHU_DIR}/libc++.so.1"    ]] || cp "${NDK_X86_LIB}/libc++.so.1"    "${DHU_DIR}/" 2>/dev/null || true
        [[ -f "${DHU_DIR}/libc++abi.so.1" ]] || cp "${NDK_X86_LIB}/libc++abi.so.1" "${DHU_DIR}/" 2>/dev/null || true
      fi
    fi

    EXTRA_LD="${DHU_DIR}"
    [[ -d "${ANDROID_SDK}/emulator/lib64" ]] && EXTRA_LD="${EXTRA_LD}:${ANDROID_SDK}/emulator/lib64"

    # Use a named pipe for DHU stdin opened in read+write mode (<>).
    # This prevents stdin from ever sending EOF, keeping the DHU alive even
    # after this shell's stdin is closed.
    DHU_PIPE=$(mktemp -u /tmp/dhu_stdin_XXXXXX)
    mkfifo "${DHU_PIPE}"
    LD_LIBRARY_PATH="${EXTRA_LD}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
      "${DHU_BIN}" <> "${DHU_PIPE}" || true
    rm -f "${DHU_PIPE}"
    ;;
  *)
    echo "Unknown mode: ${MODE}"
    echo "Usage: ./tool/dev_app.sh <run|linux|apk|auto|dhu> [flutter args...]"
    exit 1
    ;;
esac
