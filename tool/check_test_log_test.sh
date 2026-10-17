#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tool/lib/check_test_log.sh
source "${SCRIPT_DIR}/lib/check_test_log.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/navis-check-log-XXXXXX")"
trap 'rm -rf "${tmp}"' EXIT

fail() {
  echo "check_test_log_test: $*" >&2
  exit 1
}

expect_ok() {
  printf '%b' "$1" >"${tmp}/test.log"
  assert_no_test_failures "${tmp}/test.log" || fail "expected success"
}

expect_failed() {
  printf '%b' "$1" >"${tmp}/test.log"
  if (assert_no_test_failures "${tmp}/test.log") >"${tmp}/output" 2>&1; then
    fail "expected failure"
  fi
  grep -qF -- "$2" "${tmp}/output" || fail "missing matching line"
  grep -qF '[check] Flutter test log failed' "${tmp}/output" || fail "missing failure message"
}

expect_ok '00:01 +10: All tests passed!\n'
expect_failed '00:01 +10 -2: Some tests failed.\n' '00:01 +10 -2: Some tests failed.'
expect_failed '04:07 +8465 ~1 -2: loading test.dart [E]\nBad state: Cannot close sink while adding stream.\nOne or more uncaught errors occurred shutting down:\nBad state: Cannot add event while adding stream.\n' '04:07 +8465 ~1 -2: loading test.dart [E]'
expect_ok '00:01 +10 ~1: All tests passed!\n'
# Exercise each signal independently, including ANSI inside a count and CR updates.
expect_failed '00:00 +0: loading test.dart\r\033[32m00:01 +10 \033[31m-2\033[0m: failing\rshutdown\n' '00:01 +10 -2: failing'
expect_failed 'Some tests failed.\n' 'Some tests failed.'
expect_failed 'One or more uncaught errors occurred shutting down:\n' 'One or more uncaught errors occurred shutting down:'
expect_ok '00:00 +1 -2: earlier progress\r00:01 +10 ~1 -0: All tests passed!\n'
expect_failed '00:00 +0: loading test.dart\r00:01 -1: loading test.dart [E]\n' '00:01 -1: loading test.dart [E]'

echo 'check_test_log_test: ok'
