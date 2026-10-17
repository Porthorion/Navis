#!/usr/bin/env bash
# Hermetic GitHub publication: every network-facing executable is a stub.
set -euo pipefail
unset NAVIS_GITHUB_REPO
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${tmp}/bin" "${tmp}/assets"
export TEST_GITHUB_LOG="${tmp}/log" TEST_GITHUB_ASSETS="${tmp}/assets"
export PATH="${tmp}/bin:${PATH}"
cat > "${tmp}/bin/git" <<'STUB'
#!/usr/bin/env bash
[[ "${TEST_NO_REMOTE:-}" != 1 ]] || exit 1
printf 'git@github.com:Porthorion/Navis.git\n'
STUB
cat > "${tmp}/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${TEST_GITHUB_LOG}"
if [[ "$1 $2" == 'auth status' ]]; then [[ "${TEST_NO_AUTH:-}" != 1 ]]; exit; fi
if [[ "$1 $2" == 'release view' ]]; then
  [[ -f "${TEST_GITHUB_ASSETS}/exists" ]] || exit 1
  if [[ "$*" == *--json*assets* ]]; then
    python3 - <<'PY'
import json, os
from pathlib import Path
p = Path(os.environ['TEST_GITHUB_ASSETS'])
print(json.dumps({'assets':[{'name':f.name,'size':f.stat().st_size} for f in p.iterdir() if f.name != 'exists']}))
PY
  fi
  exit
fi
if [[ "$1 $2" == 'release create' || "$1 $2" == 'release upload' ]]; then
  touch "${TEST_GITHUB_ASSETS}/exists"
  for arg in "$@"; do
    [[ ! -f "${arg}" ]] || cp "${arg}" "${TEST_GITHUB_ASSETS}/$(basename "${arg}")"
  done
fi
STUB
cat > "${tmp}/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
outfile='' headers='' url=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) outfile="$2"; shift ;;
    -D) headers="$2"; shift ;;
    https://*) url="$1" ;;
  esac
  shift
done
printf 'curl %s\n' "${url}" >> "${TEST_GITHUB_LOG}"
if [[ -n "${TEST_REDIRECT:-}" && "${url}" == https://github.com/* ]]; then
  printf 'HTTP/1.1 302 Found\r\nLocation: %s\r\n\r\n' "${TEST_REDIRECT}" > "${headers}"
  : > "${outfile}"
  printf 302
else
  cp "${TEST_GITHUB_ASSETS}/manifest.json" "${outfile}"
  printf 200
fi
STUB
chmod +x "${tmp}/bin/"*
# shellcheck source=lib/github_release.sh
source "${SCRIPT_DIR}/lib/github_release.sh"
fail() { echo "github_release_test: $*" >&2; exit 1; }
refused() { if "$@" > "${tmp}/error" 2>&1; then fail 'expected refusal'; fi; }
TEST_NO_AUTH=1 refused navis_github_preflight v1.5.0 false
TEST_NO_REMOTE=1 refused navis_github_preflight v1.5.0 false
navis_github_preflight v1.5.0 false
jq -cn --arg payload "$(printf '%s' '{"assets":{"windowsPortable":{"url":"https://downloads.porthorion.com/navis/releases/v1.5.0/navis-v1.5.0-windows.zip","size":9}}}' | base64 -w0)" '{payload:$payload,signature:"disposable-test-fixture"}' > "${tmp}/manifest.json"
printf 'artifact\n' > "${tmp}/navis-v1.5.0-windows.zip"
printf 'sums\n' > "${tmp}/SHA256SUMS"
printf 'notes\n' > "${tmp}/notes.md"
navis_github_publish v1.5.0 false "${tmp}/notes.md" "${tmp}/manifest.json" "${tmp}/navis-v1.5.0-windows.zip" "${tmp}/SHA256SUMS"
cmp "${tmp}/manifest.json" "${TEST_GITHUB_ASSETS}/manifest.json"
for host in objects.githubusercontent.com release-assets.githubusercontent.com; do
  TEST_REDIRECT="https://${host}/fixture" navis_github_verify_manifest v1.5.0 "${tmp}/manifest.json"
done
TEST_REDIRECT=https://evil.com/fixture refused navis_github_verify_manifest v1.5.0 "${tmp}/manifest.json"
if rg -q 'curl https://evil.com' "${TEST_GITHUB_LOG}"; then fail 'untrusted redirect was contacted'; fi
refused navis_github_preflight v1.5.0 false
navis_github_preflight v1.5.0 true
jq -cn --arg payload "$(printf '%s' '{"assets":{"windowsPortable":{"url":"https://downloads.porthorion.com/navis/releases/v1.5.0/navis-v1.5.0-windows.zip","size":9},"windowsInstaller":{"url":"https://downloads.porthorion.com/navis/releases/v1.5.0/navis-v1.5.0-windows-installer.exe","size":10}}}' | base64 -w0)" '{payload:$payload,signature:"disposable-test-fixture"}' > "${tmp}/manifest.json"
printf 'installer\n' > "${tmp}/navis-v1.5.0-windows-installer.exe"
navis_github_publish v1.5.0 false "${tmp}/notes.md" "${tmp}/manifest.json" "${tmp}/navis-v1.5.0-windows-installer.exe" "${tmp}/SHA256SUMS"
rg -q 'release upload .*--clobber' "${TEST_GITHUB_LOG}" || fail 'late asset was not uploaded with clobber'
[[ -f "${TEST_GITHUB_ASSETS}/navis-v1.5.0-windows.zip" ]] || fail 'existing asset lost'
cmp "${tmp}/manifest.json" "${TEST_GITHUB_ASSETS}/manifest.json"
rm "${TEST_GITHUB_ASSETS}/navis-v1.5.0-windows.zip"
refused navis_github_publish v1.5.0 false "${tmp}/notes.md" "${tmp}/manifest.json" "${tmp}/navis-v1.5.0-windows-installer.exe" "${tmp}/SHA256SUMS"
rg -q 'lacks signed asset' "${tmp}/error" || fail 'incomplete mirror was accepted'
printf 'different bytes\n' > "${TEST_GITHUB_ASSETS}/manifest.json"
refused navis_github_verify_manifest v1.5.0 "${tmp}/manifest.json"
# Exercise release.sh's automatic policy from a copy with no release.env.
mkdir -p "${tmp}/repo/tool/lib"
cp "${SCRIPT_DIR}/release.sh" "${SCRIPT_DIR}/r2_publish.sh" "${tmp}/repo/tool/"
cp "${SCRIPT_DIR}/lib/"{r2_tags,lastfm_key_defines,scan_artifact_secret,release_dist,github_release}.sh "${tmp}/repo/tool/lib/"
TEST_NO_AUTH=1 refused "${tmp}/repo/tool/release.sh" v1.5.0 --targets=linux
rg -q 'gh authentication is required' "${tmp}/error" || fail 'stable did not require GitHub early'
TEST_NO_REMOTE=1 refused "${tmp}/repo/tool/release.sh" v1.5.0 --targets=linux
rg -q 'github remote is required' "${tmp}/error" || fail 'stable did not require the github remote'
TEST_NO_AUTH=1 refused "${tmp}/repo/tool/release.sh" v1.5.0 --targets=linux --no-github
rg -q 'GITHUB-SOURCE USERS WILL NOT SEE THIS RELEASE' "${tmp}/error" || fail 'escape hatch warning missing'
rm "${TEST_GITHUB_ASSETS}/exists"
refused "${tmp}/repo/tool/r2_publish.sh" publish --channel=stable --tag=v1.5.0 --github --dry-run "${tmp}/navis-v1.5.0-windows-installer.exe"
rg -q 'create the initial GitHub release with release.sh' "${tmp}/error" || fail 'late publication created a tag without release.sh'
echo 'GitHub release tests passed: mandatory stable preflight, escape hatch, create, late asset, manifest equality and mismatch.'
