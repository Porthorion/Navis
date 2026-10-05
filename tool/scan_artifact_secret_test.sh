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

# 4b. Compressed tarballs other than gzip, and debs read without dpkg-deb
# (the `ar x` path used on hosts such as macOS, whose data.tar.* is xz/zstd).
python3 - "${tmp}" "${FAKE_KEY}" <<'PY'
import io, lzma, sys, tarfile
tmp, key = sys.argv[1], sys.argv[2]

def tar_bytes(payload, mode):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode=mode) as t:
        info = tarfile.TarInfo("opt/navis/libapp.so")
        info.size = len(payload)
        t.addfile(info, io.BytesIO(payload))
    return buf.getvalue()

leaky = (b"padding " * 400) + key.encode() + (b" padding" * 400)
clean = b"padding " * 800

def ar(path, members):
    out = bytearray(b"!<arch>\n")
    for name, data in members:
        out += b"%-16s%-12d%-6d%-6d%-8s%-10d`\n" % (name.encode(), 0, 0, 0, b"100644", len(data))
        out += data
        if len(data) % 2:
            out += b"\n"
    open(path, "wb").write(bytes(out))

for label, payload in (("leaky", leaky), ("clean", clean)):
    xz = lzma.compress(tar_bytes(payload, "w"))
    open(f"{tmp}/{label}.tar.xz", "wb").write(xz)
    ar(f"{tmp}/{label}.deb", [
        ("debian-binary", b"2.0\n"),
        ("control.tar.xz", lzma.compress(tar_bytes(b"Package: navis\n", "w"))),
        ("data.tar.xz", xz),
    ])
open(f"{tmp}/leaky.tar.bz2", "wb").write(
    __import__("bz2").compress(tar_bytes(leaky, "w")))
PY
expect_status 1 "${tmp}/leaky.tar.xz" "tar.xz with the secret"
expect_status 0 "${tmp}/clean.tar.xz" "clean tar.xz"
expect_status 1 "${tmp}/leaky.tar.bz2" "tar.bz2 with the secret"
if command -v zstd >/dev/null 2>&1 && tar --zstd -cf "${tmp}/zstd-probe.tar.zst" -T /dev/null >/dev/null 2>&1; then
  python3 - "${tmp}" <<'PY'
import subprocess, sys
tmp = sys.argv[1]
subprocess.run(["tar", "--zstd", "-cf", tmp + "/leaky.tar.zst", "-C", tmp + "/src", "lib"], check=True)
PY
  expect_status 1 "${tmp}/leaky.tar.zst" "tar.zst with the secret"
fi

# A PATH holding only what the scanner needs, with no dpkg-deb, forces the
# `ar x` fallback; a second one whose tar always fails proves an unreadable data.tar.xz
# fails the scan instead of passing it.
make_shim() {
  local dir="$1" tool path
  shift
  mkdir -p "${dir}"
  for tool in "$@"; do
    path="$(command -v "${tool}" 2>/dev/null || true)"
    [[ -n "${path}" ]] && ln -sf "${path}" "${dir}/${tool}"
  done
  return 0
}
shim_tools="grep tar unzip ar find mktemp tr basename dirname rm cat gzip bzip2 zstd xz"
make_shim "${tmp}/shim-with-xz" ${shim_tools}
make_shim "${tmp}/shim-no-xz" ${shim_tools/ xz/}
# An extraction failure is independent of whether tar has a built-in xz reader.
rm "${tmp}/shim-no-xz/tar"
printf '#!/bin/sh\nexit 2\n' >"${tmp}/shim-no-xz/tar"
chmod +x "${tmp}/shim-no-xz/tar"
[[ ! -e "${tmp}/shim-with-xz/dpkg-deb" ]] || fail "shim must not provide dpkg-deb"

# expect_status_on_path <path> <want> <artifact> <description>
expect_status_on_path() {
  local scan_path="$1" want="$2" artifact="$3" what="$4" got=0
  (
    PATH="${scan_path}"
    scan_artifact_for_secret "${artifact}" "${FAKE_KEY}"
  ) >"${out}" 2>&1 || got=$?
  [[ "${got}" -eq "${want}" ]] || fail "${what}: wanted status ${want}, got ${got}"
  if grep -qF -- "${FAKE_KEY}" "${out}"; then
    fail "${what}: scanner output leaked the secret"
  fi
}
expect_status_on_path "${tmp}/shim-with-xz" 1 "${tmp}/leaky.deb" "deb (ar path) with the secret"
expect_status_on_path "${tmp}/shim-with-xz" 0 "${tmp}/clean.deb" "clean deb (ar path)"
expect_status_on_path "${tmp}/shim-no-xz" 2 "${tmp}/leaky.deb" "deb (ar path) whose data.tar cannot be extracted"
expect_status_on_path "${tmp}/shim-no-xz" 2 "${tmp}/leaky.tar.xz" "tar.xz that cannot be extracted"
expect_status 1 "${tmp}/leaky.deb" "deb with the secret"

# Nesting deeper than the cap is unscannable, not clean.
python3 - "${tmp}" <<'PY'
import io, sys, zipfile
tmp = sys.argv[1]
data = b"nothing here"
for _ in range(6):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("inner.zip" if _ else "leaf.txt", data)
    data = buf.getvalue()
open(tmp + "/deep.zip", "wb").write(data)
PY
expect_status 2 "${tmp}/deep.zip" "archive nested beyond the depth cap"

# 5. A corrupt archive must not be reported clean.
printf 'this is not a zip' >"${tmp}/corrupt.apk"
expect_status 2 "${tmp}/corrupt.apk" "corrupt apk"

# 6. Usage errors.
expect_status 2 "${tmp}/does-not-exist.apk" "missing artifact"
got=0
scan_artifact_for_secret "${tmp}/clean.apk" "" >/dev/null 2>&1 || got=$?
[[ "${got}" -eq 2 ]] || fail "empty secret must be refused (status ${got})"

# Tool errors must fail closed (including a traversal failing after output).
for broken_tool in grep find mktemp; do
  make_shim "${tmp}/shim-${broken_tool}" ${shim_tools}
  rm "${tmp}/shim-${broken_tool}/${broken_tool}"
  printf '#!/bin/sh\nexit 2\n' >"${tmp}/shim-${broken_tool}/${broken_tool}"
  chmod +x "${tmp}/shim-${broken_tool}/${broken_tool}"
  expect_status_on_path "${tmp}/shim-${broken_tool}" 2 "${tmp}/src/clean" "${broken_tool} failure"
done

# 7. The scan leaves no scratch directories or pattern files behind.
leftover="$(find "${TMPDIR}" -mindepth 1 | wc -l)"
[[ "${leftover}" -eq 0 ]] || fail "scan left ${leftover} scratch entries behind"

echo "scan_artifact_secret_test: ok"
