#!/usr/bin/env bash
set -euo pipefail

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
