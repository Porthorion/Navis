#!/usr/bin/env bash
set -euo pipefail

PACKAGE_NAME="${1:-com.navis.app.navis}"
ADB_SERIAL="${2:-${ANDROID_SERIAL:-}}"
LOGCAT_LINES="${NAVIS_ANDROID_AUTO_LOGCAT_LINES:-400}"
TRUSTED_INSTALLERS="${NAVIS_ANDROID_AUTO_TRUSTED_INSTALLERS:-com.android.vending com.skt.skaf.A000Z00040 com.onestore.android.updater com.onestore.android.pkgmgr}"
ANDROID_AUTO_PACKAGES=(
  com.google.android.projection.gearhead
  com.google.android.apps.auto
)

EXIT_CODE=0

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

mark_fail() {
  echo "FAIL: $*" >&2
  EXIT_CODE=1
}

warn() {
  echo "WARN: $*" >&2
}

section() {
  echo
  echo "== $* =="
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

adb_cmd() {
  if [[ -n "${ADB_SERIAL}" ]]; then
    adb -s "$ADB_SERIAL" "$@"
    return
  fi
  adb "$@"
}

adb_shell_clean() {
  adb_cmd shell "$@" 2>/dev/null | tr -d '\r' || true
}

first_non_null() {
  awk '
    $0 != "" && $0 != "null" && $0 != "<null>" {
      print
      exit
    }
  '
}

is_trusted_installer() {
  local installer="$1"
  local trusted

  [[ -n "$installer" && "$installer" != "null" && "$installer" != "<null>" ]] || return 1
  [[ "$installer" != "com.android.shell" ]] || return 1

  for trusted in $TRUSTED_INSTALLERS; do
    [[ "$installer" == "$trusted" ]] && return 0
  done

  return 1
}

find_apksigner() {
  if command -v apksigner >/dev/null 2>&1; then
    command -v apksigner
    return
  fi

  local sdk="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-${HOME}/Android/Sdk}}"
  local candidate
  candidate="$(find "$sdk/build-tools" -maxdepth 2 -type f -name apksigner 2>/dev/null | sort -V | tail -1 || true)"
  [[ -n "$candidate" ]] && printf '%s\n' "$candidate"
}

print_package_version() {
  local package="$1"
  local dump

  dump="$(adb_shell_clean dumpsys package "$package")"
  if [[ -z "$dump" || "$dump" == *"Unable to find package"* ]]; then
    echo "$package: not installed"
    return
  fi

  echo "$package:"
  printf '%s\n' "$dump" | grep -E 'versionName=|versionCode=|firstInstallTime=|lastUpdateTime=' | sed 's/^/  /' || true
}

require_command adb

if ! adb_cmd get-state >/dev/null 2>&1; then
  fail "no adb device available (pass serial as the second argument or set ANDROID_SERIAL if multiple devices are connected)"
fi

section "Target"
if [[ -n "${ADB_SERIAL}" ]]; then
  echo "adb serial: $ADB_SERIAL"
else
  echo "adb serial: default adb target"
fi
echo "package: $PACKAGE_NAME"

if ! adb_shell_clean pm path "$PACKAGE_NAME" | grep -q '^package:'; then
  fail "$PACKAGE_NAME is not installed on the adb target"
fi

section "Package identity"
print_package_version "$PACKAGE_NAME"

section "Installer source"
install_source="$(adb_shell_clean cmd package get-install-source-info "$PACKAGE_NAME")"
installer_line="$(adb_shell_clean pm list packages -i "$PACKAGE_NAME")"

if [[ -n "$install_source" ]]; then
  printf '%s\n' "$install_source"
fi
if [[ -n "$installer_line" ]]; then
  printf '%s\n' "$installer_line"
fi

installer_package="$(
  {
    printf '%s\n' "$installer_line" \
      | sed -nE 's/.* installer=([^ ]+).*/\1/p'
    printf '%s\n' "$install_source" \
      | sed -nE 's/.*(installerPackageName|installingPackageName|initiatingPackageName|Installer package name|Installing package|Initiating package)[:=][[:space:]]*([^, ]+).*/\2/p'
  } | first_non_null
)"

if is_trusted_installer "$installer_package"; then
  echo "OK: installer '$installer_package' is trusted for default real-car Android Auto testing."
else
  mark_fail "installer '${installer_package:-unknown}' is not trusted for default real-car Android Auto visibility. Install $PACKAGE_NAME from Google Play Internal App Sharing or an Internal Test Track, then rerun this script with Android Auto Unknown sources off."
fi

section "Signing certificate"
base_apk="$(adb_shell_clean pm path "$PACKAGE_NAME" | sed -nE 's/^package://p' | head -1)"
if [[ -z "$base_apk" ]]; then
  warn "could not resolve base APK path"
else
  tmp_apk="$(mktemp "/tmp/${PACKAGE_NAME}.XXXXXX.apk")"
  trap 'rm -f "$tmp_apk"' EXIT
  if adb_cmd pull "$base_apk" "$tmp_apk" >/dev/null 2>&1; then
    apksigner_bin="$(find_apksigner || true)"
    if [[ -n "$apksigner_bin" ]]; then
      if ! "$apksigner_bin" verify --print-certs "$tmp_apk" \
        | grep -E 'Signer #[0-9]+ certificate SHA-256 digest|Signer #[0-9]+ certificate DN'; then
        warn "apksigner could not print certificates; trying keytool."
        apksigner_bin=""
      fi
    fi
    if [[ -z "$apksigner_bin" ]] && command -v keytool >/dev/null 2>&1; then
      keytool -printcert -jarfile "$tmp_apk" 2>/dev/null \
        | grep -E 'Owner:|SHA256:' \
        || true
    elif [[ -z "$apksigner_bin" ]]; then
      warn "apksigner/keytool not found; skipping certificate digest"
    fi
  else
    warn "could not pull $base_apk; skipping certificate digest"
  fi
fi

section "Android Auto package"
for auto_package in "${ANDROID_AUTO_PACKAGES[@]}"; do
  print_package_version "$auto_package"
done

section "MediaBrowserService resolver"
resolver_output="$(adb_shell_clean cmd package query-intent-services -a android.media.browse.MediaBrowserService)"
if [[ -n "$resolver_output" && "$resolver_output" != *"Unknown command"* ]]; then
  printf '%s\n' "$resolver_output"
  if printf '%s\n' "$resolver_output" | grep -Fq "$PACKAGE_NAME"; then
    echo "OK: $PACKAGE_NAME is visible in the MediaBrowserService resolver."
  else
    mark_fail "$PACKAGE_NAME is not visible in the MediaBrowserService resolver."
  fi
else
  echo "cmd package query-intent-services unavailable; falling back to dumpsys package."
  package_dump="$(adb_shell_clean dumpsys package "$PACKAGE_NAME")"
  printf '%s\n' "$package_dump" | awk '
    /Service Resolver Table:/ { printing = 1 }
    /Domain verification status:/ { printing = 0 }
    printing
  '
  if printf '%s\n' "$package_dump" | grep -Fq 'android.media.browse.MediaBrowserService'; then
    echo "OK: package dump contains android.media.browse.MediaBrowserService."
  else
    mark_fail "package dump does not show android.media.browse.MediaBrowserService."
  fi
fi

section "Package dump (Android Auto filtered)"
adb_shell_clean dumpsys package "$PACKAGE_NAME" | grep -E \
  'com.google.android.gms.car.application|automotive_app_desc|AudioService|android.media.browse.MediaBrowserService|BIND_MEDIA_BROWSER_SERVICE|car.application.theme|TintableAttributionIcon|installer|versionName=|versionCode=|firstInstallTime=|lastUpdateTime=' \
  || true

section "Media session snapshot"
adb_cmd shell dumpsys media_session | tr -d '\r' | awk -v pkg="$PACKAGE_NAME" '
  index($0, pkg) {
    remaining = 18
  }
  remaining > 0 {
    print
    remaining--
  }
' || true

# MediaPlayerWrapper logs "tried to update with no new data" when Bluetooth
# AVRCP drops a metadata update (a cover added without any other change).
section "Filtered logcat (Android Auto / Bluetooth / AudioService / Navis / crashes)"
adb_cmd logcat -d -v time \
  -s Gearhead AndroidAuto CarService CarAppProjection GmsCar AudioService NavisAudioHandler flutter AndroidRuntime MediaPlayerWrapper AvrcpTargetService AvrcpCoverArtService \
  | tail -n "$LOGCAT_LINES" \
  || true

if [[ "$EXIT_CODE" -ne 0 ]]; then
  echo
  echo "Real-car Android Auto diagnostic failed."
  echo "DHU success can still be valid for local development, but default real-car visibility requires a trusted Play/ONE store install."
fi

exit "$EXIT_CODE"
