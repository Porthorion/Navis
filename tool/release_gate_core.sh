#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./tool/release_gate_core.sh [--quick]

Core release gate that does not depend on custom_lint.

Options:
  --quick   Run formatting, generation, analyze, and critical test suite only.
            Skips the full `flutter test` pass.
  -h, --help
EOF
}

RUN_FULL_TESTS=true

for arg in "$@"; do
  case "${arg}" in
    --quick) RUN_FULL_TESTS=false ;;
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

min_tmp_kb=262144
if df --output=avail /tmp >/dev/null 2>&1; then
  tmp_available_kb="$(df --output=avail /tmp | tail -n1 | tr -d ' ')"
else
  tmp_available_kb="$(df -k /tmp | awk 'NR==2 {print $4}')"
fi

if [[ "${tmp_available_kb}" -lt "${min_tmp_kb}" ]]; then
  echo "[release-gate] Insufficient /tmp space: ${tmp_available_kb}KB available; need at least ${min_tmp_kb}KB." >&2
  exit 1
fi

run_step() {
  local label="$1"
  shift
  local start_seconds="${SECONDS}"
  echo "[release-gate] ${label}"
  "$@"
  local elapsed=$((SECONDS - start_seconds))
  echo "[release-gate] ${label} completed in ${elapsed}s"
}

run_step_capture() {
  local label="$1"
  local log_file="$2"
  shift 2
  local start_seconds="${SECONDS}"
  echo "[release-gate] ${label}"
  set +e
  "$@" 2>&1 | tee "${log_file}"
  local status="${PIPESTATUS[0]}"
  set -e
  local elapsed=$((SECONDS - start_seconds))
  echo "[release-gate] ${label} completed in ${elapsed}s"
  if [[ "${status}" -ne 0 ]]; then
    echo "[release-gate] ${label} failed. See ${log_file}" >&2
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
      echo "[release-gate] Blocking warning detected: ${pattern}" >&2
      echo "[release-gate] See ${log_file}" >&2
      exit 1
    fi
  done
}

tmp_log_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_log_dir}"' EXIT

run_step "format check" dart format --set-exit-if-changed .
run_step "code generation" dart run build_runner build --delete-conflicting-outputs
run_step "analyze" flutter analyze

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

if [[ "${RUN_FULL_TESTS}" == "true" ]]; then
  run_step_capture \
    "full flutter test suite" \
    "${tmp_log_dir}/full.log" \
    flutter test
  assert_no_blocking_warnings "${tmp_log_dir}/full.log"
fi

echo "[release-gate] Core gate passed."

