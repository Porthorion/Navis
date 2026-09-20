#!/usr/bin/env bash
# Verifies that Navis's Android Auto MediaBrowserService can cold-start before
# MainActivity. This targets an Android phone emulator; it never installs over
# the stable Navis package.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.."

if ! command -v java >/dev/null 2>&1; then
  navis_studio_jdk="${ANDROID_STUDIO_JDK:-${HOME}/android-studio/jbr}"
  if [[ -x "${navis_studio_jdk}/bin/java" ]]; then
    export JAVA_HOME="${navis_studio_jdk}"
    export PATH="${JAVA_HOME}/bin:${PATH}"
  fi
fi

DEV_SUFFIX="${NAVIS_APP_ID_SUFFIX:-.dev}"
APP_PKG="com.navis.app.navis${DEV_SUFFIX}"
APP_APK="build/app/outputs/flutter-apk/app-x86_64-sideload-debug.apk"

mapfile -t ANDROID_DEVICES < <(adb devices | awk 'NR > 1 && $2 == "device" {print $1}')
if [[ ${#ANDROID_DEVICES[@]} -ne 1 ]]; then
  echo "ERROR: Connect exactly one Android phone emulator before running this diagnostic." >&2
  printf 'Detected devices:\n%s\n' "${ANDROID_DEVICES[*]:-none}" >&2
  exit 64
fi
ADB_SERIAL="${ANDROID_DEVICES[0]}"
ADB_ARGS=(-s "${ADB_SERIAL}")

if [[ "$(adb "${ADB_ARGS[@]}" shell getprop ro.kernel.qemu | tr -d '\r')" != "1" ]]; then
  echo "ERROR: ${ADB_SERIAL} is not an emulator; this diagnostic must not target a physical phone." >&2
  exit 65
fi
if [[ "$(adb "${ADB_ARGS[@]}" shell getprop ro.build.characteristics | tr -d '\r')" == *"automotive"* ]]; then
  echo "ERROR: Use a standard phone emulator, not an Android Automotive image." >&2
  exit 66
fi

echo "==> Building Navis Dev sidecar"
./tool/dev_app.sh apk-debug --target-platform android-x64 --split-per-abi
if [[ ! -f "${APP_APK}" ]]; then
  echo "ERROR: Expected sidecar APK at ${APP_APK}" >&2
  exit 67
fi

echo "==> Installing ${APP_PKG} on ${ADB_SERIAL}"
adb "${ADB_ARGS[@]}" install -r -d "${APP_APK}" >/dev/null
adb "${ADB_ARGS[@]}" shell am force-stop "${APP_PKG}"
adb "${ADB_ARGS[@]}" logcat -c

echo "==> Connecting external MediaBrowser test client without MainActivity"
(
  cd android
  ./gradlew \
    :auto_test_client:connectedDebugAndroidTest \
    -Pandroid.testInstrumentationRunnerArguments.navisTargetPackage="${APP_PKG}"
)

deadline=$((SECONDS + 10))
while (( SECONDS < deadline )); do
  if adb "${ADB_ARGS[@]}" logcat -d -v brief | grep -Fq 'Audio handler init: ready.'; then
    break
  fi
  sleep 1
done

LOGCAT="$(adb "${ADB_ARGS[@]}" logcat -d -v brief)"
if ! grep -Fq 'Audio handler init: ready.' <<<"${LOGCAT}"; then
  echo "ERROR: MediaBrowser connected without a completed Navis audio bootstrap." >&2
  exit 68
fi
if grep -Fq 'Mobile orientation policy: all orientations enabled.' <<<"${LOGCAT}" || \
  grep -Fq 'Edge-to-edge mode enabled.' <<<"${LOGCAT}"; then
  echo "ERROR: UI-only platform setup ran during a headless media-service launch." >&2
  exit 69
fi
if grep -Eiq 'FATAL EXCEPTION|Fatal Exception|MissingPluginException|options cannot be null in notifyChildrenChanged' <<<"${LOGCAT}"; then
  echo "ERROR: Fatal Android or Flutter failure found during cold service start." >&2
  exit 70
fi

echo "PASS: cold MediaBrowserService startup completed before MainActivity."
