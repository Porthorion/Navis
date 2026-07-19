#!/usr/bin/env bash
set -euo pipefail

min_tmp_kb=262144
if df --output=avail /tmp >/dev/null 2>&1; then
  tmp_available_kb="$(df --output=avail /tmp | tail -n1 | tr -d ' ')"
else
  tmp_available_kb="$(df -k /tmp | awk 'NR==2 {print $4}')"
fi

if [[ "${tmp_available_kb}" -lt "${min_tmp_kb}" ]]; then
  echo "[check] Insufficient /tmp space: ${tmp_available_kb}KB available; need at least ${min_tmp_kb}KB." >&2
  echo "[check] Free disk space and rerun ./tool/check.sh" >&2
  exit 1
fi

run_step() {
  local label="$1"
  shift
  local start_seconds="${SECONDS}"
  echo "[check] $label"
  "$@"
  local elapsed=$((SECONDS - start_seconds))
  echo "[check] $label completed in ${elapsed}s"
}

run_step_capture() {
  local label="$1"
  local log_file="$2"
  shift 2
  local start_seconds="${SECONDS}"
  echo "[check] $label"
  set +e
  "$@" 2>&1 | tee "$log_file"
  local status="${PIPESTATUS[0]}"
  set -e
  local elapsed=$((SECONDS - start_seconds))
  echo "[check] $label completed in ${elapsed}s"
  if [[ "${status}" -ne 0 ]]; then
    echo "[check] $label failed. See ${log_file} for details." >&2
    exit "${status}"
  fi
}

assert_no_blocking_warnings() {
  local log_file="$1"
  local patterns=(
    "It looks like you've created the database class NavisDatabase multiple times"
    "Tried to modify a provider while the widget tree was building"
  )

  for pattern in "${patterns[@]}"; do
    if rg -q "${pattern}" "${log_file}"; then
      echo "[check] Blocking warning detected: ${pattern}" >&2
      echo "[check] See ${log_file} for details." >&2
      exit 1
    fi
  done
}

run_step "format check" dart format --set-exit-if-changed .
run_step "code generation" dart run build_runner build
run_step "analyze" flutter analyze --no-fatal-infos
# custom_lint is temporarily disabled pending analyzer/riverpod_lint compatibility
# run_step "custom lint" dart run custom_lint

tmp_log_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_log_dir}"' EXIT

run_step_capture \
  "migration tests (expanded)" \
  "${tmp_log_dir}/migration.log" \
  flutter test test/src/database/migrations/navis_migration_test.dart -r expanded
assert_no_blocking_warnings "${tmp_log_dir}/migration.log"

run_step_capture \
  "critical reliability tests (expanded)" \
  "${tmp_log_dir}/critical.log" \
  flutter test \
  test/src/routing/app_router_test.dart \
  test/src/providers/app_providers_test.dart \
  test/src/features/player/data/playback_source_resolver_test.dart \
  test/src/features/player/data/navis_audio_handler_test.dart \
  test/src/features/library/presentation/library_sync_provider_test.dart \
  -r expanded
assert_no_blocking_warnings "${tmp_log_dir}/critical.log"

run_step_capture \
  "tests" \
  "${tmp_log_dir}/all-tests.log" \
  flutter test
assert_no_blocking_warnings "${tmp_log_dir}/all-tests.log"

if [[ "${CI:-false}" == "true" ]]; then
  run_step "coverage (CI)" flutter test --coverage
fi

echo "[check] All checks passed."
