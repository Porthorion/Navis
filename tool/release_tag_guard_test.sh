#!/usr/bin/env bash
# Assert tool/release_tag_guard.sh refuses only versions whose release tag
# exists. Uses throwaway repositories, never the caller's repository or origin.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="${SCRIPT_DIR}/release_tag_guard.sh"

fail() {
  echo "release_tag_guard_test: $*" >&2
  exit 1
}

tmp="$(mktemp -d "${TMPDIR:-/tmp}/navis-release-tag-guard-XXXXXX")"
cleanup() {
  rm -rf "${tmp}"
}
trap cleanup EXIT

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid

git init -q --bare "${tmp}/origin.git"
git init -q "${tmp}/work"
cd "${tmp}/work"
git remote add origin "${tmp}/origin.git"
printf 'version: 1.4.1+10401\n' >pubspec.yaml
git add pubspec.yaml
git commit -q -m init
git push -q origin HEAD:refs/heads/main

expect_ok() {
  "${GUARD}" "$@" >/dev/null 2>&1 || fail "expected success: $*"
}
expect_refused() {
  if "${GUARD}" "$@" >/dev/null 2>&1; then
    fail "expected refusal: $*"
  fi
}

# pubspec.yaml already names the version, but nothing was tagged: release.
expect_ok v1.4.1

# A local tag means the version shipped (or is mid-release).
git tag -a v1.4.0 -m "Release v1.4.0"
expect_refused v1.4.0
expect_ok v1.4.0 --allow-existing-version

# A tag pushed from another machine counts too; the retry fetches it.
git tag -a v1.3.9 -m "Release v1.3.9"
git push -q origin v1.3.9
git tag -d v1.3.9 >/dev/null
expect_refused v1.3.9
expect_ok v1.3.9 --allow-existing-version
git rev-parse -q --verify refs/tags/v1.3.9 >/dev/null ||
  fail "retry did not fetch the existing remote tag"

# A failed origin lookup must not let a release through unchecked.
git remote set-url origin "${tmp}/missing.git"
expect_refused v1.4.2

expect_refused
expect_refused v1.4.1 --unknown

echo "release_tag_guard_test: ok"
