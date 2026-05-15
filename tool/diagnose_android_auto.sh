#!/usr/bin/env bash
set -euo pipefail

PACKAGE_NAME="${1:-com.navis.app.navis}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

section() {
  echo
  echo "== $* =="
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

adb_cmd() {
  if [[ -n "${ANDROID_SERIAL:-}" ]]; then
    adb -s "$ANDROID_SERIAL" "$@"
    return
  fi
  adb "$@"
}

require_command adb

if ! adb_cmd get-state >/dev/null 2>&1; then
  fail "no adb device available (set ANDROID_SERIAL if multiple devices are connected)"
fi

section "MediaBrowserService query"
adb_cmd shell cmd package query-intent-services \
  -a android.media.browse.MediaBrowserService

section "Package dump (filtered)"
adb_cmd shell dumpsys package "$PACKAGE_NAME" | grep -E \
  'com.google.android.gms.car.application|automotive_app_desc|AudioService|android.media.browse.MediaBrowserService|BIND_MEDIA_BROWSER_SERVICE|car.application.theme|TintableAttributionIcon' \
  || true

section "Media session snapshot"
adb_cmd shell dumpsys media_session | awk -v pkg="$PACKAGE_NAME" '
  index($0, pkg) {
    remaining = 80
  }
  remaining > 0 {
    print
    remaining--
  }
'

section "Filtered logcat (AudioService / NavisAudioHandler / flutter)"
adb_cmd logcat -d -v time -s AudioService NavisAudioHandler flutter
