#!/usr/bin/env bash
# Offline checks for third_party/media_kit_libs_macos_audio/macos/fetch_libmpv.sh:
# a COPY of the script gets a fixture digest and an unreachable URL, so nothing
# is downloaded. Needs shasum, so it runs on macOS hosts only.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/third_party/media_kit_libs_macos_audio/macos/fetch_libmpv.sh"
fail() { echo "libmpv_fetch_macos_test: FAIL: $*" >&2; exit 1; }
pass() { echo "ok - $1"; }

if [[ "$(uname -s)" != Darwin ]]; then
  echo "libmpv_fetch_macos_test: skipped (macOS hosts only)"
  exit 0
fi
[[ -f "${SCRIPT}" ]] || fail "fetch_libmpv.sh does not exist"
grep -Eq '^LIBMPV_SHA256="[0-9a-f]{64}"$' "${SCRIPT}" || fail "no 64-hex SHA-256 pin"
if grep -q '^LIBMPV_SHA256="0*"$' "${SCRIPT}"; then fail "SHA-256 pin is the placeholder"; fi
grep -q '^LIBMPV_URL="https://downloads.porthorion.com/navis/third-party/' "${SCRIPT}" || fail "URL is not the Porthorion R2 folder"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/navis-fetch-test-XXXXXX")"
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${tmp}/pkg/Mpv.xcframework"
echo fixture > "${tmp}/pkg/Mpv.xcframework/Info.plist"
tar -czf "${tmp}/good.tar.gz" -C "${tmp}/pkg" Mpv.xcframework
echo not-the-pinned-archive > "${tmp}/bad.tar.gz"
digest="$(shasum -a 256 "${tmp}/good.tar.gz" | cut -d' ' -f1)"

new_copy() { # a fresh package directory whose copy of the script pins ${digest}
  rm -rf "${tmp}/macos"; mkdir -p "${tmp}/macos"
  sed -e "s/^LIBMPV_SHA256=.*/LIBMPV_SHA256=\"${digest}\"/" \
      -e 's|^LIBMPV_URL=.*|LIBMPV_URL="http://127.0.0.1:9/unreachable.tar.gz"|' \
      "${SCRIPT}" > "${tmp}/macos/fetch_libmpv.sh"
}

new_copy
NAVIS_LIBMPV_MACOS_ARCHIVE="${tmp}/good.tar.gz" sh "${tmp}/macos/fetch_libmpv.sh" 2> /dev/null \
  || fail "a local archive with the pinned digest was rejected"
[[ -f "${tmp}/macos/Frameworks/Mpv.xcframework/Info.plist" ]] || fail "xcframework not extracted"
pass "local archive with the pinned digest is extracted"

sh "${tmp}/macos/fetch_libmpv.sh" 2> /dev/null || fail "an up-to-date extraction needed the network"
pass "extracted pin is reused offline"

rm -rf "${tmp}/macos/Frameworks"
sh "${tmp}/macos/fetch_libmpv.sh" 2> /dev/null || fail "a verified cached archive was not reused offline"
pass "verified cached archive is reused offline"

new_copy
if NAVIS_LIBMPV_MACOS_ARCHIVE="${tmp}/bad.tar.gz" sh "${tmp}/macos/fetch_libmpv.sh" 2> "${tmp}/err"; then
  fail "an archive with the wrong digest was accepted"
fi
grep -q 'SHA-256 mismatch' "${tmp}/err" || fail "mismatch not reported"
[[ ! -e "${tmp}/macos/.cache/$(sed -n 's/^LIBMPV="\(.*\)"$/\1/p' "${tmp}/macos/fetch_libmpv.sh")" ]] \
  || fail "the bad archive was kept in the cache"
[[ ! -e "${tmp}/macos/Frameworks" ]] || fail "frameworks extracted from a bad archive"
pass "wrong digest fails and is deleted"

new_copy
if sh "${tmp}/macos/fetch_libmpv.sh" 2> "${tmp}/err"; then fail "unreachable URL did not fail"; fi
grep -q 'could not download' "${tmp}/err" || fail "download failure not reported"
grep -q 'NAVIS_LIBMPV_MACOS_ARCHIVE' "${tmp}/err" || fail "local override not mentioned"
pass "no local archive and no reachable URL fails clearly"

new_copy
if NAVIS_LIBMPV_MACOS_ARCHIVE="${tmp}/missing.tar.gz" sh "${tmp}/macos/fetch_libmpv.sh" 2> "${tmp}/err"; then
  fail "a missing local archive did not fail"
fi
grep -q 'does not exist' "${tmp}/err" || fail "missing archive not reported"
pass "missing local archive fails clearly"
