#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

server_variant="${NAVIS_CODEC_SERVER_VARIANT:-OpenSubsonic}"
device_id="${NAVIS_CODEC_DEVICE_ID:-}"

if [[ $# -ge 1 ]]; then
  device_id="$1"
fi
if [[ $# -ge 2 ]]; then
  server_variant="$2"
fi

if [[ -z "${device_id}" ]]; then
  echo "[phase4-codec-closeout] Missing device id."
  echo "[phase4-codec-closeout] Usage: ./tool/phase4_codec_closeout.sh <device-id> [server-variant]"
  echo "[phase4-codec-closeout] Tip: run 'flutter devices' or 'adb devices -l' to discover ids."
  exit 2
fi

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "[phase4-codec-closeout] Required command not found: $1" >&2
    exit 2
  fi
}

run_test_and_require_execution() {
  local test_path="$1"
  local output_file
  output_file="$(mktemp)"

  echo "[phase4-codec-closeout] flutter test ${test_path} -r expanded"
  if ! flutter test "${test_path}" -r expanded 2>&1 | tee "${output_file}"; then
    rm -f "${output_file}"
    echo "[phase4-codec-closeout] Test command failed: ${test_path}" >&2
    exit 1
  fi

  if has_all_tests_skipped "${output_file}"; then
    rm -f "${output_file}"
    echo "[phase4-codec-closeout] Test did not execute (all skipped): ${test_path}" >&2
    exit 1
  fi

  rm -f "${output_file}"
}

require_cmd flutter
require_cmd adb

has_all_tests_skipped() {
  local output_file="$1"
  if command -v rg >/dev/null 2>&1; then
    rg -q "All tests skipped\\." "${output_file}"
    return
  fi

  grep -q "All tests skipped\." "${output_file}"
}

adb -s "${device_id}" get-state >/dev/null

date_utc="$(date -u +%F)"
device_model="$(adb -s "${device_id}" shell getprop ro.product.model | tr -d '\r')"
android_version="$(adb -s "${device_id}" shell getprop ro.build.version.release | tr -d '\r')"

run_test_and_require_execution "test/src/features/player/data/playback_source_resolver_test.dart"
run_test_and_require_execution "test/src/features/player/data/navis_audio_handler_test.dart"

echo ""
echo "[phase4-codec-closeout] Automated preflight passed."
echo "[phase4-codec-closeout] Continue runtime matrix protocol from docs/troubleshooting.md:"
echo "  1) flutter clean"
echo "  2) flutter pub get"
echo "  3) adb -s ${device_id} uninstall com.navis.app.navis"
echo "  4) flutter run -d ${device_id}"
echo "  5) Verify one track per codec + restore + background continuity"
echo ""
echo "[phase4-codec-closeout] Evidence row templates (paste into docs/troubleshooting.md and PROGRESS.md):"
for codec in FLAC ALAC MP3 AAC Opus Vorbis; do
  echo "| ${date_utc} | ${server_variant} | ${device_model} (Android ${android_version}) | ${codec} | file / lockCachedStream / directStream | pass/fail | none / lock->direct / DSP-degraded | runtime row |"
done

echo ""
echo "[phase4-codec-closeout] Suggested evidence command line:"
echo "  NAVIS_CODEC_DEVICE_ID=${device_id} NAVIS_CODEC_SERVER_VARIANT=${server_variant} ./tool/phase4_codec_closeout.sh"
