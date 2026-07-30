#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

MANIFEST_PATH="${1:-}"
APK_PATH="${2:-}"

if [[ -z "$MANIFEST_PATH" ]]; then
  for candidate in \
    build/app/intermediates/merged_manifests/sideloadDebug/processSideloadDebugManifest/AndroidManifest.xml \
    build/app/intermediates/merged_manifests/playDebug/processPlayDebugManifest/AndroidManifest.xml \
    build/app/intermediates/merged_manifests/sideloadRelease/processSideloadReleaseManifest/AndroidManifest.xml \
    build/app/intermediates/merged_manifests/playRelease/processPlayReleaseManifest/AndroidManifest.xml \
    android/app/build/intermediates/merged_manifest/debug/processDebugMainManifest/AndroidManifest.xml \
    android/app/build/intermediates/merged_manifest/release/processReleaseMainManifest/AndroidManifest.xml \
    android/app/build/intermediates/merged_manifest/profile/processProfileMainManifest/AndroidManifest.xml \
    android/app/src/main/AndroidManifest.xml; do
    if [[ -f "$candidate" ]]; then
      MANIFEST_PATH="$candidate"
      break
    fi
  done
fi

AUTOMOTIVE_DESC="android/app/src/main/res/xml/automotive_app_desc.xml"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "OK: $*"
}

require_file() {
  [[ -f "$1" ]] || fail "missing file: $1"
}

require_contains() {
  local file="$1"
  local needle="$2"
  local description="$3"
  grep -Fq "$needle" "$file" || fail "$description"
  pass "$description"
}

require_not_contains() {
  local file="$1"
  local needle="$2"
  local description="$3"
  if grep -Fq "$needle" "$file"; then
    fail "$description"
  fi
  pass "$description"
}

find_aapt() {
  if command -v aapt >/dev/null 2>&1; then
    command -v aapt
    return
  fi

  local configured_sdk=""
  if [[ -f android/local.properties ]]; then
    configured_sdk="$(sed -n 's/^sdk\.dir=//p' android/local.properties | head -n 1)"
  fi

  local sdk_root
  for sdk_root in \
    "${ANDROID_SDK_ROOT:-}" \
    "${ANDROID_HOME:-}" \
    "$configured_sdk"; do
    [[ -d "$sdk_root/build-tools" ]] || continue
    local candidate
    candidate="$(
      find "$sdk_root/build-tools" \
        -mindepth 2 \
        -maxdepth 2 \
        -type f \
        -name aapt \
        -perm -u+x \
        -print |
        sort -V |
        tail -n 1
    )"
    if [[ -n "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return
    fi
  done
}

require_file "$MANIFEST_PATH"
require_file "$AUTOMOTIVE_DESC"

echo "Verifying Android Auto manifest metadata in $MANIFEST_PATH"

require_contains \
  "$AUTOMOTIVE_DESC" \
  '<uses name="media"' \
  "automotive_app_desc.xml declares media"

require_contains \
  "$MANIFEST_PATH" \
  'android:name="com.google.android.gms.car.application"' \
  "application-level Android Auto metadata exists"
require_contains \
  "$MANIFEST_PATH" \
  'android:resource="@xml/automotive_app_desc"' \
  "Android Auto metadata points to automotive_app_desc"
require_contains \
  "$MANIFEST_PATH" \
  'android:name="androidx.car.app.TintableAttributionIcon"' \
  "tintable attribution icon metadata exists"
require_contains \
  "$MANIFEST_PATH" \
  'android:name="com.google.android.gms.car.application.theme"' \
  "car app theme metadata exists"
require_contains \
  "$MANIFEST_PATH" \
  'android:name="com.ryanheise.audioservice.AudioService"' \
  "audio_service MediaBrowserService is declared"
require_not_contains \
  "$MANIFEST_PATH" \
  'android:name="com.navis.app.navis.NavisAudioService"' \
  "no incompatible custom MediaBrowserService is declared"
require_contains \
  "$MANIFEST_PATH" \
  'android:label="@string/app_name"' \
  "media service has a label"
require_contains \
  "$MANIFEST_PATH" \
  'android:icon="@mipmap/ic_launcher"' \
  "media service has an icon"
require_contains \
  "$MANIFEST_PATH" \
  'android:exported="true"' \
  "media service is exported"
require_contains \
  "$MANIFEST_PATH" \
  'android:foregroundServiceType="mediaPlayback"' \
  "media service declares mediaPlayback foreground type"
require_contains \
  "$MANIFEST_PATH" \
  'android:name="android.media.browse.MediaBrowserService"' \
  "media browser intent filter exists"
require_not_contains \
  "$MANIFEST_PATH" \
  'android.permission.BIND_MEDIA_BROWSER_SERVICE' \
  "media browser service does not require privileged bind permission"

if [[ -z "$APK_PATH" ]]; then
  for candidate in \
    build/app/outputs/flutter-apk/app-sideload-debug.apk \
    build/app/outputs/flutter-apk/app-play-debug.apk \
    build/app/outputs/flutter-apk/app-sideload-release.apk \
    build/app/outputs/flutter-apk/app-play-release.apk \
    build/app/outputs/flutter-apk/app-debug.apk \
    build/app/outputs/flutter-apk/app-release.apk \
    build/app/outputs/flutter-apk/app-profile.apk; do
    if [[ -f "$candidate" ]]; then
      APK_PATH="$candidate"
      break
    fi
  done
fi

if [[ -n "$APK_PATH" ]]; then
  require_file "$APK_PATH"
  aapt_bin="$(find_aapt)"
  if [[ -n "$aapt_bin" ]]; then
    apk_resources="$("$aapt_bin" dump resources "$APK_PATH")"
    grep -Fq ':xml/automotive_app_desc' <<<"$apk_resources" \
      || fail "APK does not package automotive_app_desc"
    pass "APK packages automotive_app_desc.xml"

    apk_manifest="$("$aapt_bin" dump xmltree "$APK_PATH" AndroidManifest.xml)"
    grep -Fq 'com.ryanheise.audioservice.AudioService' <<<"$apk_manifest" \
      || fail "APK does not declare the canonical audio_service component"
    pass "APK declares the canonical audio_service component"
    if grep -Fq 'com.navis.app.navis.NavisAudioService' <<<"$apk_manifest"; then
      fail "APK declares the incompatible custom media-service component"
    fi
    pass "APK does not declare the incompatible custom media-service component"
  else
    echo "WARN: aapt not found; skipping packaged APK checks" >&2
  fi
fi

echo "Android Auto manifest verification passed."
