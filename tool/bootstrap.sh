#!/usr/bin/env bash
set -euo pipefail

required_flutter_min="3.47.5"
required_flutter_baseline_prefix="3.47"
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"

check_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "[bootstrap] Missing required command: $cmd" >&2
    exit 1
  fi
}

version_ge() {
  local min="$1"
  local current="$2"
  local first
  first="$(printf '%s\n%s\n' "$min" "$current" | sort -V | head -n1)"
  [[ "$first" == "$min" ]]
}

check_cmd flutter
check_cmd dart

echo "[bootstrap] Flutter:"
flutter --version | sed -n '1,3p'

echo "[bootstrap] Dart:"
dart --version 2>&1

flutter_line="$(flutter --version | sed -n '1p')"
flutter_version="$(awk '{print $2}' <<<"$flutter_line")"
flutter_channel="$(awk '{print $5}' <<<"$flutter_line")"

if ! version_ge "$required_flutter_min" "$flutter_version"; then
  echo "[bootstrap] Flutter $flutter_version is below required minimum $required_flutter_min" >&2
  exit 1
fi

if [[ "$flutter_channel" != "stable" ]]; then
  echo "[bootstrap] Warning: expected stable channel; found '$flutter_channel'"
fi

if [[ "$flutter_version" != ${required_flutter_baseline_prefix}* ]]; then
  echo "[bootstrap] Warning: active baseline is ${required_flutter_baseline_prefix}.x; found $flutter_version"
fi

echo "[bootstrap] Running flutter pub get..."
flutter pub get

for package_dir in third_party/navis_windows_smtc third_party/just_audio_media_kit; do
  echo "[bootstrap] Resolving $package_dir development dependencies..."
  (cd "$project_dir/$package_dir" && flutter pub get)
done
echo "[bootstrap] Resolving CargoKit development dependencies..."
(cd "$project_dir/third_party/navis_windows_smtc/cargokit/build_tool" && dart pub get)

echo "[bootstrap] Bootstrap complete."
echo "[bootstrap] Next: ./tool/check.sh"
