#!/usr/bin/env bash
set -euo pipefail

# Re-exec with inherited, verified ownership; direct callers and the full gate coordinate.
if [[ "${1:-}" != --locked-check ]]; then
  mkdir -p build/check
  check_evidence="$(mktemp -d build/check/run-XXXXXXXX)"
  echo "[check] retained logs: ${check_evidence}"
  exec python3 "$(dirname "${BASH_SOURCE[0]}")/heavy_lock.py" --owner "${check_evidence}" bash "$0" --locked-check "${check_evidence}"
fi
shift
tmp_log_dir="${1:?missing check evidence directory}"
shift
# The marker only prevents recursion; this wrapper verifies the actual inherited locks.
python3 "$(dirname "${BASH_SOURCE[0]}")/heavy_lock.py" --verify

# shellcheck source=tool/lib/check_test_log.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/check_test_log.sh"

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

step_number=0
run_step() {
  local label="$1"
  shift
  step_number=$((step_number + 1))
  run_step_capture "$label" "${tmp_log_dir}/step-${step_number}.log" "$@"
}

# shellcheck source=tool/lib/check_capture.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/check_capture.sh"

assert_no_blocking_warnings() {
  local log_file="$1"
  assert_no_test_failures "${log_file}"
  local patterns=(
    "It looks like you've created the database class NavisDatabase multiple times"
    "Tried to modify a provider while the widget tree was building"
    "'node.built': is not true"
    "'!child.attached': is not true"
  )

  for pattern in "${patterns[@]}"; do
    if rg -F -q "${pattern}" "${log_file}"; then
      echo "[check] Blocking warning detected: ${pattern}" >&2
      echo "[check] See ${log_file} for details." >&2
      exit 1
    fi
  done
}

run_step "playback harness tooling" python3 tool/playback_harness_test.py
run_step "heavy ownership and capture" python3 tool/validation_gate_test.py
run_step "test log guard" ./tool/check_test_log_test.sh
run_step "linux desktop entry" ./tool/linux_desktop_entry_test.sh
run_step "release tag guard" ./tool/release_tag_guard_test.sh
run_step "dev release and R2 publishing" ./tool/dev_release_test.sh
run_step "GitHub update publication" ./tool/github_release_test.sh
run_step "Last.fm key masking" ./tool/lastfm_key_defines_test.sh
run_step "artifact secret scan" ./tool/scan_artifact_secret_test.sh
run_step "native equalizer response" ./tool/equalizer_native_test.sh
run_step "Windows SQLite asset verification" python3 tool/sqlite3_windows_asset_test.py
run_step "diagnostics profile preparation" python3 tool/diagnostics_profile_test.py
run_step "format check" ./tool/dart_format.sh --check
run_step "code generation" dart run build_runner build
run_step "analyze" flutter analyze --no-fatal-infos
run_step "dead code" dart run tool/dead_code_check.dart
# custom_lint is temporarily disabled pending analyzer/riverpod_lint compatibility
# run_step "custom lint" dart run custom_lint

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
  run_step_capture "coverage (CI)" "${tmp_log_dir}/coverage.log" flutter test --coverage
  assert_no_blocking_warnings "${tmp_log_dir}/coverage.log"
fi

echo "[check] All checks passed."
