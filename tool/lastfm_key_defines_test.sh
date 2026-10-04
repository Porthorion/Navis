#!/usr/bin/env bash
# Assert tool/lib/lastfm_key_defines.sh masks the Last.fm key into a private
# defines file: the key XOR pad round-trips, the plaintext never lands in the
# file, each build gets a fresh pad, and an empty key is refused. Uses a fake
# key only.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/lastfm_key_defines.sh"

fail() {
  echo "lastfm_key_defines_test: $*" >&2
  exit 1
}

tmp="$(mktemp -d "${TMPDIR:-/tmp}/navis-defines-test-XXXXXX")"
trap 'rm -rf "${tmp}"' EXIT

FAKE_KEY="fake0123456789abcdefFAKE0123456789"

# decode <file> -> prints the unmasked key (python mirrors lib/src/utils/constants.dart)
decode() {
  python3 - "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
masked = bytes.fromhex(d["NAVIS_LASTFM_API_KEY_MASKED"])
pad = bytes.fromhex(d["NAVIS_LASTFM_API_KEY_PAD"])
assert len(pad) >= len(masked)
print("".join(chr(m ^ p) for m, p in zip(masked, pad)), end="")
PY
}

first="${tmp}/first.json"
second="${tmp}/second.json"
navis_write_lastfm_defines_file "${first}" "${FAKE_KEY}"
navis_write_lastfm_defines_file "${second}" "${FAKE_KEY}"

# Mode 600, valid JSON with exactly the two defines.
mode="$(stat -c '%a' "${first}" 2>/dev/null || stat -f '%Lp' "${first}")"
[[ "${mode}" == "600" ]] || fail "defines file mode is ${mode}, want 600"
python3 - "${first}" <<'PY' || fail "defines file is not the expected JSON"
import json, sys
d = json.load(open(sys.argv[1]))
assert sorted(d) == ["NAVIS_LASTFM_API_KEY_MASKED", "NAVIS_LASTFM_API_KEY_PAD"], d
assert all(v and all(c in "0123456789abcdef" for c in v) for v in d.values()), d
assert len(d["NAVIS_LASTFM_API_KEY_MASKED"]) == len(d["NAVIS_LASTFM_API_KEY_PAD"]), d
PY

# Round trip, and no plaintext (or its hex) in the file.
[[ "$(decode "${first}")" == "${FAKE_KEY}" ]] || fail "unmasking did not recover the key"
if grep -qF -- "${FAKE_KEY}" "${first}"; then
  fail "defines file contains the plaintext key"
fi
key_hex="$(printf '%s' "${FAKE_KEY}" | od -An -v -tx1 | tr -d ' \n')"
if grep -qF -- "${key_hex}" "${first}"; then
  fail "defines file contains the hex-encoded key"
fi

# A fresh pad (and so a fresh masked value) per build.
cmp -s "${first}" "${second}" && fail "two builds produced identical defines"
[[ "$(decode "${second}")" == "${FAKE_KEY}" ]] || fail "second file does not unmask"

# The mask helper leaves no key material in the caller's environment.
[[ -z "${NAVIS_LASTFM_API_KEY_MASKED}" && -z "${NAVIS_LASTFM_API_KEY_PAD}" ]] ||
  fail "mask variables were not cleared after writing the file"

# An empty key is refused and writes nothing.
if navis_write_lastfm_defines_file "${tmp}/empty.json" "" 2>/dev/null; then
  fail "an empty key must be refused"
fi
[[ ! -e "${tmp}/empty.json" ]] || fail "an empty key left a defines file"

echo "lastfm_key_defines_test: ok"
