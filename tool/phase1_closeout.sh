#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

require_env() {
  local name="$1"
  local value="${!name-}"
  if [[ -z "${value}" ]]; then
    echo "[phase1-closeout] Missing required environment variable: ${name}" >&2
    exit 2
  fi
}

run_test_and_require_execution() {
  local test_path="$1"
  local output_file
  output_file="$(mktemp)"

  echo "[phase1-closeout] flutter test ${test_path} -r expanded"
  if ! flutter test "${test_path}" -r expanded 2>&1 | tee "${output_file}"; then
    rm -f "${output_file}"
    echo "[phase1-closeout] Test command failed: ${test_path}" >&2
    exit 1
  fi

  if rg -q "All tests skipped\\." "${output_file}"; then
    rm -f "${output_file}"
    echo "[phase1-closeout] Test did not execute (all skipped): ${test_path}" >&2
    echo "[phase1-closeout] Ensure sqlite runtime is available (install libsqlite3-dev)." >&2
    exit 1
  fi

  rm -f "${output_file}"
}

require_env "NAVIS_SMOKE_BASE_URL"
require_env "NAVIS_SMOKE_USERNAME"
require_env "NAVIS_SMOKE_PASSWORD"

run_test_and_require_execution "test/src/database/navis_database_test.dart"
run_test_and_require_execution "test/src/database/migrations/navis_migration_test.dart"

echo "[phase1-closeout] dart run tool/phase1_ping_smoke.dart"
dart run tool/phase1_ping_smoke.dart

echo "Phase 1 close-out checks passed"
