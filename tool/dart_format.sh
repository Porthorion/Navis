#!/usr/bin/env bash
# Format the Dart sources owned by the quality gates, or verify them without
# writing (--check). tool/check.sh, tool/release_gate_core.sh and the Makefile
# share this so every entry point formats the same file set.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./tool/dart_format.sh [--check]

Formats Dart sources under lib/, test/, tool/ and third_party/, except the
vendored CargoKit build tool (format that from its own directory).

Options:
  --check   Report unformatted files and exit non-zero without rewriting them.
  -h, --help
EOF
}

check=false

for arg in "$@"; do
  case "${arg}" in
    --check) check=true ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: ${arg}" >&2
      usage
      exit 1
      ;;
  esac
done

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# The other third_party packages are path dependencies of the app, so the root
# package config gives the formatter each package's own language version.
# CargoKit's build_tool is a standalone package outside that graph (and outside
# root analysis): unless its dependencies happen to be resolved, the formatter
# applies the enclosing navis_windows_smtc language version, which changes its
# output and rejects valid build_tool syntax. build/ is not scanned because it
# can hold stale copies from other tooling; hidden directories are skipped as
# `dart format <dir>` skips them.
file_list="$(
  find lib test tool third_party \
    \( -name '.*' -o -path 'third_party/*/cargokit' \) -prune \
    -o -type f -name '*.dart' -print | LC_ALL=C sort
)"
mapfile -t files <<<"${file_list}"

if [[ "${check}" == false ]]; then
  dart format "${files[@]}"
  exit 0
fi

status=0
dart format --output=none --set-exit-if-changed "${files[@]}" || status=$?
if [[ "${status}" -eq 1 ]]; then
  echo "[format] Run ./tool/dart_format.sh to apply the reported changes." >&2
fi
exit "${status}"
