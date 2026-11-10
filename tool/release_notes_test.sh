#!/usr/bin/env bash
# Asserts release.sh falls back only on generator exit 2 ("no changelog entry"),
# stops on any real release-notes failure, and never hides the generator's
# stderr. Runs the real helper with a fake dart, never a release.
# Usage: ./tool/release_notes_test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/release_notes.sh
source "${SCRIPT_DIR}/lib/release_notes.sh"

fail() { echo "release_notes_test: $*" >&2; exit 1; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/navis-release-notes-test-XXXXXX")"
trap 'rm -rf "${tmp}"' EXIT

VERSION=v1.2.3
UPDATE_CHANNEL=stable

# Stand-in for the Dart generator: controlled output, stderr and status.
dart() {
  printf '%s' "${FAKE_STDOUT:-}"
  printf '%s' "${FAKE_STDERR:-}" >&2
  return "${FAKE_STATUS:-0}"
}

grep -q 'lib/release_notes.sh' "${SCRIPT_DIR}/release.sh" ||
  fail "release.sh does not source lib/release_notes.sh"
if grep -Fq 'generate_release_notes.dart "${VERSION}" 2>/dev/null' "${SCRIPT_DIR}/release.sh"; then
  fail "release.sh still discards the generator's stderr"
fi

# Exit 0 with notes: use them verbatim.
FAKE_STATUS=0
FAKE_STDOUT=$'## Notes\n- fixed things'
FAKE_STDERR=''
generate_release_notes >"${tmp}/out" 2>"${tmp}/err" ||
  fail "exit 0 was rejected"
[[ "${RELEASE_BODY}" == "${FAKE_STDOUT}" ]] ||
  fail "generated body was not used: ${RELEASE_BODY}"
grep -q 'Release notes generated successfully' "${tmp}/out" ||
  fail "success message missing"

# Exit 2: the only legitimate "no changelog entry" case.
FAKE_STATUS=2
FAKE_STDOUT=''
FAKE_STDERR='No changelog found for version 1.2.3.'
generate_release_notes >"${tmp}/out" 2>"${tmp}/err" ||
  fail "exit 2 was rejected"
[[ "${RELEASE_BODY}" == "## Navis ${VERSION} (${UPDATE_CHANNEL})" ]] ||
  fail "exit 2 did not use the generic body: ${RELEASE_BODY}"
grep -q 'generic release body' "${tmp}/out" ||
  fail "fallback message missing"

# Every other non-zero exit is a real failure: stop and keep stderr visible.
for status in 1 64 255; do
  FAKE_STATUS="${status}"
  FAKE_STDOUT=''
  FAKE_STDERR="generator crashed with ${status}"
  if ( generate_release_notes >"${tmp}/out" 2>"${tmp}/err" ); then
    fail "exit ${status} was accepted"
  fi
  grep -q "release notes generator failed for ${VERSION} (exit ${status})" "${tmp}/err" ||
    fail "exit ${status} lacked a clear error"
  grep -q "generator crashed with ${status}" "${tmp}/err" ||
    fail "exit ${status} hid the generator's stderr"
done

# Exit 0 with no output is also a broken generator, not "no notes".
FAKE_STATUS=0
FAKE_STDOUT=''
FAKE_STDERR=''
if ( generate_release_notes >"${tmp}/out" 2>"${tmp}/err" ); then
  fail "empty output was accepted"
fi
grep -q 'returned empty notes' "${tmp}/err" ||
  fail "empty output lacked a clear error"

echo "release_notes_test: ok"
