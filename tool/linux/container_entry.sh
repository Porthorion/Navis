#!/usr/bin/env bash
set -euo pipefail
repo="$1"; build="$2"; mode="$3"; version="$4"; prefix="$5"; source_list="$6"; shift 6
export HOME=/tmp/navis-builder
mkdir -p "${HOME}" /tmp/navis-work
if [[ "${build}" == true ]]; then
  # Flutter mutates its SDK/cache. The host SDK and pub cache remain read-only.
  cp -a /host-flutter /tmp/flutter
  cp -a /host-pub /tmp/pub-cache
  export PATH="/tmp/flutter/bin:${PATH}" PUB_CACHE=/tmp/pub-cache
  git config --global --add safe.directory /tmp/flutter
  # Copy only tracked/current non-ignored sources; leave host caches and secrets alone.
  tar -C "${repo}" --null -T "${source_list}" -cf - | tar -C /tmp/navis-work -xf -
  cd /tmp/navis-work
  flutter pub get --enforce-lockfile
  args=("$@")
  obfuscate=false; symbols=false; channel=false
  for arg in "${args[@]}"; do
    case "${arg}" in
      --obfuscate) obfuscate=true ;;
      --split-debug-info=*) symbols=true ;;
      --dart-define=NAVIS_UPDATE_CHANNEL=*) channel=true ;;
    esac
  done
  [[ "${obfuscate}" == true ]] || args+=(--obfuscate)
  [[ "${symbols}" == true ]] || args+=("--split-debug-info=${repo}/build/obfuscation/linux/${version}")
  [[ "${channel}" == true ]] || args+=(--dart-define=NAVIS_UPDATE_CHANNEL=stable)
  flutter build linux --release "${args[@]}"
  mkdir -p "${repo}/build/linux/x64/release"
  rm -rf "${repo}/build/linux/x64/release/bundle"
  cp -a build/linux/x64/release/bundle "${repo}/build/linux/x64/release/"
fi
cd "${repo}"
bash tool/linux/package_bundle.sh "${mode}" "${version}" "${prefix}"
