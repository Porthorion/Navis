#!/usr/bin/env bash
# Assert tool/lib/scan_artifact_secret.sh finds a plaintext secret in plain
# files, directories and (nested) archives, passes clean artifacts, refuses to
# call an unreadable artifact clean, and never prints the secret. Uses a fake
# key and synthetic artifacts only.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/scan_artifact_secret.sh"

fail() {
  echo "scan_artifact_secret_test: $*" >&2
  exit 1
}

tmp="$(mktemp -d "${TMPDIR:-/tmp}/navis-scan-test-XXXXXX")"
trap 'rm -rf "${tmp}"' EXIT
# A private TMPDIR makes the "no scratch left behind" check exact.
mkdir -p "${tmp}/scratch"
export TMPDIR="${tmp}/scratch"

FAKE_KEY="fake0123456789abcdefFAKE0123456789"
out="${tmp}/out.txt"

# expect_status <want> <artifact> <description>
expect_status() {
  local want="$1" artifact="$2" what="$3" got=0
  scan_artifact_for_secret "${artifact}" "${FAKE_KEY}" >"${out}" 2>&1 || got=$?
  [[ "${got}" -eq "${want}" ]] || fail "${what}: wanted status ${want}, got ${got}"
  if grep -qF -- "${FAKE_KEY}" "${out}"; then
    fail "${what}: scanner output leaked the secret"
  fi
}

mkdir -p "${tmp}/src/lib" "${tmp}/src/clean"
printf 'header\0\0%s\0\0tail' "${FAKE_KEY}" >"${tmp}/src/lib/libapp.so"
printf 'nothing to see here\n' >"${tmp}/src/clean/readme.txt"
# Make the zipped payloads compressible so a raw grep of the archive misses them.
python3 - "${tmp}" "${FAKE_KEY}" <<'PY'
import sys, zipfile, io
tmp, key = sys.argv[1], sys.argv[2]
secret_payload = (b"padding " * 400) + key.encode() + (b" padding" * 400)
clean_payload = b"padding " * 800

def make_zip(path, files):
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        for name, data in files.items():
            z.writestr(name, data)

make_zip(tmp + "/leaky.apk", {"lib/arm64-v8a/libapp.so": secret_payload})
make_zip(tmp + "/clean.apk", {"lib/arm64-v8a/libapp.so": clean_payload})
make_zip(tmp + "/leaky.aab", {"base/lib/libapp.so": secret_payload})
make_zip(tmp + "/leaky.ipa", {"Payload/Runner.app/App": secret_payload})

inner = io.BytesIO()
with zipfile.ZipFile(inner, "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("deep/libapp.so", secret_payload)
make_zip(tmp + "/nested.zip", {"outer.txt": b"x", "inner.zip": inner.getvalue()})
PY

# 1. Plain file and directory.
expect_status 1 "${tmp}/src/lib/libapp.so" "plain file with the secret"
expect_status 0 "${tmp}/src/clean/readme.txt" "plain clean file"
expect_status 1 "${tmp}/src" "directory containing the secret"
expect_status 0 "${tmp}/src/clean" "clean directory"

# 2. Compressed zip-family artifacts (a raw grep alone would miss these).
if grep -aqF -- "${FAKE_KEY}" "${tmp}/leaky.apk"; then
  fail "fixture is not compressed; the archive test would prove nothing"
fi
expect_status 1 "${tmp}/leaky.apk" "apk with the secret"
expect_status 1 "${tmp}/leaky.aab" "aab with the secret"
expect_status 1 "${tmp}/leaky.ipa" "ipa with the secret"
expect_status 0 "${tmp}/clean.apk" "clean apk"
expect_status 1 "${tmp}/nested.zip" "zip nesting a zip with the secret"

# 3. Tarballs: compressed bundle, and a tarball carrying a leaky apk.
tar -czf "${tmp}/leaky.tar.gz" -C "${tmp}/src" lib
tar -czf "${tmp}/clean.tar.gz" -C "${tmp}/src" clean
tar -czf "${tmp}/wrapped.tar.gz" -C "${tmp}" leaky.apk
expect_status 1 "${tmp}/leaky.tar.gz" "tarball with the secret"
expect_status 0 "${tmp}/clean.tar.gz" "clean tarball"
expect_status 1 "${tmp}/wrapped.tar.gz" "tarball carrying a leaky apk"

# 4. A directory holding a leaky archive (an unpacked .app or bundle).
mkdir -p "${tmp}/bundle/data"
cp "${tmp}/leaky.apk" "${tmp}/bundle/data/asset.apk"
expect_status 1 "${tmp}/bundle" "directory carrying a leaky archive"

# 5. A corrupt archive must not be reported clean.
printf 'this is not a zip' >"${tmp}/corrupt.apk"
expect_status 2 "${tmp}/corrupt.apk" "corrupt apk"

# 6. Usage errors.
expect_status 2 "${tmp}/does-not-exist.apk" "missing artifact"
got=0
scan_artifact_for_secret "${tmp}/clean.apk" "" >/dev/null 2>&1 || got=$?
[[ "${got}" -eq 2 ]] || fail "empty secret must be refused (status ${got})"

# 7. The scan leaves no scratch directories or pattern files behind.
leftover="$(find "${TMPDIR}" -mindepth 1 | wc -l)"
[[ "${leftover}" -eq 0 ]] || fail "scan left ${leftover} scratch entries behind"

echo "scan_artifact_secret_test: ok"
