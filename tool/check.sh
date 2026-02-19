#!/usr/bin/env bash
set -euo pipefail

min_tmp_kb=262144
tmp_available_kb="$(df --output=avail /tmp | tail -n1 | tr -d ' ')"

if [[ "${tmp_available_kb}" -lt "${min_tmp_kb}" ]]; then
  echo "[check] Insufficient /tmp space: ${tmp_available_kb}KB available; need at least ${min_tmp_kb}KB." >&2
  echo "[check] Free disk space and rerun ./tool/check.sh" >&2
  exit 1
fi

run_step() {
  local label="$1"
  shift
  echo "[check] $label"
  "$@"
}

run_step "format check" dart format --set-exit-if-changed .
run_step "code generation" dart run build_runner build --delete-conflicting-outputs
run_step "analyze" flutter analyze
run_step "custom lint" dart run custom_lint
run_step "tests" flutter test

echo "[check] All checks passed."
