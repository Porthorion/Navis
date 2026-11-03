#!/usr/bin/env bash
# Hermetic tests for linux/install.sh: isolated HOME, throwaway Ed25519 key,
# no network. A COPY of the script gets the test key, a fixture-serving
# transport() and a tty path; the shipped file has no test hooks.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALL="${REPO_ROOT}/linux/install.sh"

fail() { echo "linux_install_test: FAIL: $*" >&2; [[ -z "${out:-}" ]] || printf '%s\n' "${out}" | head -20 >&2; exit 1; }
pass() { echo "ok - $1"; }
[[ -f "${INSTALL}" ]] || fail "linux/install.sh does not exist"
for t in jq openssl base64 tar sha256sum; do command -v "${t}" >/dev/null || fail "${t} is required"; done

tmp="$(mktemp -d "${TMPDIR:-/tmp}/navis-install-test-XXXXXX")"
trap 'rm -rf "${tmp}"' EXIT
unset XDG_DATA_HOME XDG_CACHE_HOME XDG_CONFIG_HOME XDG_STATE_HOME
HOME_DIR="${tmp}/home dir"   # a space on purpose
out=''; rc=0

# --- keys and the patched copy --------------------------------------------
key="${tmp}/key.pem"; other_key="${tmp}/other.pem"
openssl genpkey -algorithm ed25519 -out "${key}" 2>/dev/null
openssl genpkey -algorithm ed25519 -out "${other_key}" 2>/dev/null
pub_b64() { openssl pkey -in "$1" -pubout -outform DER | tail -c 32 | base64 -w0; }

mkdir -p "${tmp}/stubs"
cat > "${tmp}/transport.sh" <<'STUB'
transport() {
  printf '%s\n' "$1" >> "${FX_LOG}"
  case "$1" in
    */manifest.json) cp "${FX_MANIFEST}" "$2" ;;
    *.tar.gz) cp "${FX_TARBALL}" "$2" ;;
    *) return 1 ;;
  esac
  printf '%s' "${FX_EFFECTIVE:-$1}"
}
STUB
copy="${tmp}/install.sh"
awk -v stub="${tmp}/transport.sh" '/^transport\(\) \{/{while((getline l < stub)>0) print l; skip=1} !skip{print} skip&&/^\}/{skip=0}' "${INSTALL}" \
  | sed -e "s|^PINNED_KEY=.*|PINNED_KEY='$(pub_b64 "${key}")'|" -e 's|^TTY=.*|TTY="${TEST_TTY:-/nonexistent}"|' -e 's|^SYSTEM_APP=.*|SYSTEM_APP="${TEST_SYSTEM_APP:-/nonexistent/navis}"|' > "${copy}"
grep -q 'FX_LOG' "${copy}" || fail "transport() was not replaced in the test copy"
grep -q "$(pub_b64 "${key}")" "${copy}" || fail "PINNED_KEY was not replaced in the test copy"
grep -q 'TEST_TTY' "${copy}" || fail "TTY was not replaced in the test copy"
grep -Eq 'FX_|TEST_' "${INSTALL}" && fail "shipped script contains a test hook"

# --- stubs: only what the host cannot be trusted to provide ----------------
printf '#!/bin/sh\n[ -z "${TEST_LDD_MISSING:-}" ] || printf "\\t%%s => not found\\n" ${TEST_LDD_MISSING}\nexit 0\n' > "${tmp}/stubs/ldd"
printf '#!/bin/sh\n[ "$1" = -m ] && echo "${TEST_ARCH:-x86_64}"\n' > "${tmp}/stubs/uname"
printf '#!/bin/sh\necho "glibc ${TEST_GLIBC:-2.39}"\n' > "${tmp}/stubs/getconf"
printf '#!/bin/sh\necho "${TEST_UID:-1000}"\n' > "${tmp}/stubs/id"
# mv fails for the final swap (<data>/navis.new -> <data>/navis) when asked to.
cat > "${tmp}/stubs/mv" <<'STUB'
#!/bin/sh
if [ -n "${TEST_MV_FAIL:-}" ]; then
  case "$1" in */navis.new) exit 1 ;; esac
fi
exec /usr/bin/env -i PATH=/usr/bin:/bin mv "$@"
STUB
chmod +x "${tmp}/stubs/"*
export PATH="${tmp}/stubs:${PATH}"
export FX_LOG="${tmp}/fx.log"

# --- fixtures ---------------------------------------------------------------
# build_tarball VERSION -> ${tmp}/dl/navis-vVERSION-linux.tar.gz (root has no top dir, like release)
build_tarball() {
  local v="$1" b="${tmp}/bundle-$1"
  rm -rf "${b}"; mkdir -p "${b}/lib" "${b}/data/icons/hicolor/256x256/apps" "${tmp}/dl"
  printf '#!/bin/sh\necho navis-stub-%s\n' "${v}" > "${b}/navis"; chmod +x "${b}/navis"
  echo so > "${b}/lib/libapp.so"
  cp "${REPO_ROOT}/linux/packaging/com.navis.app.navis.desktop" "${b}/data/"
  echo png > "${b}/data/icons/hicolor/256x256/apps/navis.png"
  tar -czf "${tmp}/dl/navis-v${v}-linux.tar.gz" -C "${b}" .
}
# make_manifest VERSION TARBALL ; overrides: M_CHANNEL M_SCHEMA M_URL M_KEY M_DUP M_TAMPER
make_manifest() {
  local v="$1" t="$2" sha
  sha="$(sha256sum "${t}" | cut -d' ' -f1)"
  jq -cn --arg v "${v}" --arg sha "${sha}" --arg ch "${M_CHANNEL:-stable}" --argjson schema "${M_SCHEMA:-1}" \
    --arg url "${M_URL:-https://downloads.porthorion.com/navis/releases/v${v}/navis-v${v}-linux.tar.gz}" \
    '{schema: $schema, channel: $ch, version: $v, tag: ("v" + $v), published_at: "2026-11-03T00:00:00Z",
      assets: {linuxPortable: {url: $url, sha256: $sha, size: 4},
               linuxDeb: {url: "https://downloads.porthorion.com/navis/releases/x.deb", sha256: ("0" * 64), size: 1}},
      build: 5, notes: "Mentions \"channel\":\"dev\" and \"version\":\"9.9.9\" in prose"}' > "${tmp}/payload.json"
  [[ -z "${M_DUP:-}" ]] || sed -i 's/"channel":"stable",/"channel":"stable","channel":"stable",/' "${tmp}/payload.json"
  openssl pkeyutl -sign -inkey "${M_KEY:-${key}}" -rawin -in "${tmp}/payload.json" -out "${tmp}/payload.sig"
  [[ -z "${M_TAMPER:-}" ]] || sed -i "s/\"version\":\"${v}\"/\"version\":\"9.9.9\"/" "${tmp}/payload.json"
  jq -cn --arg payload "$(base64 -w0 "${tmp}/payload.json")" --arg signature "$(base64 -w0 "${tmp}/payload.sig")" \
    '{payload: $payload, signature: $signature}' > "${tmp}/manifest-$v.json"
  export FX_MANIFEST="${tmp}/manifest-$v.json" FX_TARBALL="${t}"
}
# release VERSION: fixtures for a valid release of VERSION
release() { build_tarball "$1"; make_manifest "$1" "${tmp}/dl/navis-v$1-linux.tar.gz"; }

fresh() { rm -rf "${HOME_DIR}" "${FX_LOG}"; mkdir -p "${HOME_DIR}"; : > "${FX_LOG}"; }
run() { rc=0; mkdir -p "${tmp}/tmpdir"; out="$(cd "${tmp}" && TMPDIR="${tmp}/tmpdir" HOME="${HOME_DIR}" bash "${copy}" "$@" 2>&1 </dev/null)" || rc=$?; }
want_rc() { [[ "${rc}" == "$1" ]] || fail "$2: expected exit $1, got ${rc}"; }
want_fail() { [[ "${rc}" != 0 ]] || fail "$1: expected a refusal, got success"; }
want_out() { printf '%s' "${out}" | grep -Eqi -- "$1" || fail "$2: output lacks /$1/"; }

DATA="${HOME_DIR}/.local/share"; APP="${DATA}/navis"; LAUNCHER="${HOME_DIR}/.local/bin/navis"
DESKTOP="${DATA}/applications/com.navis.app.navis.desktop"; IM="${DATA}/navis.install-manifest"
ICON="${DATA}/icons/hicolor/256x256/apps/navis.png"
not_installed() { [[ ! -e "${APP}" && ! -L "${LAUNCHER}" && ! -e "${DESKTOP}" ]] || fail "$1: something was installed"; }
no_leftovers() { [[ -z "$(ls -A "${DATA}" 2>/dev/null | grep -E '^navis\.(new|old)$' || true)" ]] || fail "$1: navis.new/navis.old left behind"; }

# --- 0. the pinned key matches what the app trusts --------------------------
app_key="$(grep -A1 'updateSigningPublicKey *=' "${REPO_ROOT}/lib/src/utils/constants.dart" | grep -o "'[A-Za-z0-9+/=]*'" | head -1 | tr -d "'")"
[[ -n "${app_key}" ]] || fail "could not read updateSigningPublicKey"
grep -q "^PINNED_KEY='${app_key}'\$" "${INSTALL}" || fail "PINNED_KEY differs from AppConstants.updateSigningPublicKey"
pass "pinned key equals constants.dart"

# --- 1. valid install, latest stable ----------------------------------------
fresh; release 1.5.2
run --yes
want_rc 0 "valid install"
[[ -L "${LAUNCHER}" && "$(readlink -f "${LAUNCHER}")" == "${APP}/navis" ]] || fail "launcher is not a symlink into the app dir"
[[ "$("${LAUNCHER}")" == navis-stub-1.5.2 ]] || fail "launcher does not run the bundle"
[[ "$(ls -A "${APP}" | tr '\n' ' ')" == "data lib navis " ]] || fail "app dir holds more than the tarball root: $(ls -A "${APP}")"
grep -q 'channels/stable/manifest.json' "${FX_LOG}" || fail "CLI mode did not read the stable manifest"
grep -q 'releases/v1.5.2/navis-v1.5.2-linux.tar.gz' "${FX_LOG}" || fail "tarball not fetched from the manifest URL"
[[ "$(sed -n 's/^Exec=//p' "${DESKTOP}")" == "\"${APP}/navis\" %U" ]] || fail "Exec not an absolute quoted path: $(sed -n 's/^Exec=//p' "${DESKTOP}")"
[[ "$(sed -n 's/^TryExec=//p' "${DESKTOP}")" == "${APP}/navis" ]] || fail "TryExec wrong"
grep -q '^Icon=navis$' "${DESKTOP}" || fail "Icon key changed"
[[ -f "${ICON}" ]] || fail "icon not installed"
grep -q "^path ${ICON}\$" "${IM}" && grep -q "^path ${DESKTOP}\$" "${IM}" && grep -q "^path ${LAUNCHER}\$" "${IM}" && grep -q "^path ${APP}\$" "${IM}" || fail "install manifest incomplete"
grep -q '^version 1.5.2$' "${IM}" || fail "install manifest lacks version"
no_leftovers "valid install"
[[ -z "$(ls -A "${tmp}/tmpdir")" ]] || fail "temp dir leaked"
pass "valid install (symlink launcher, tarball-root-only app dir, desktop entry, manifest, no leftovers)"
if command -v desktop-file-validate >/dev/null 2>&1; then desktop-file-validate "${DESKTOP}" || fail "desktop-file-validate"; fi

# --- 2. local tarball mode ---------------------------------------------------
fresh; release 1.5.2
run --yes "${tmp}/dl/navis-v1.5.2-linux.tar.gz"
want_rc 0 "local tarball"
grep -q 'github.com/Porthorion/Navis/releases/download/v1.5.2/manifest.json' "${FX_LOG}" || fail "local mode did not fetch the tagged GitHub manifest"
grep -q 'tar.gz' "${FX_LOG}" && fail "local mode downloaded a tarball"
[[ "$("${LAUNCHER}")" == navis-stub-1.5.2 ]] || fail "local install broken"
pass "local tarball mode"

# --- 3. integrity refusals ---------------------------------------------------
fresh; build_tarball 1.5.2; M_TAMPER=1 make_manifest 1.5.2 "${tmp}/dl/navis-v1.5.2-linux.tar.gz"
run --yes; want_fail "tampered payload"; want_out 'signature' "tampered payload"; not_installed "tampered payload"
pass "tampered manifest payload refused"

fresh; M_KEY="${other_key}" make_manifest 1.5.2 "${tmp}/dl/navis-v1.5.2-linux.tar.gz"
run --yes; want_fail "wrong signing key"; want_out 'signature' "wrong signing key"; not_installed "wrong key"
pass "manifest signed by another key refused"

fresh; release 1.5.2; echo extra >> "${tmp}/dl/navis-v1.5.2-linux.tar.gz"   # manifest hash no longer matches
run --yes; want_fail "wrong hash"; want_out 'sha-?256|checksum|hash' "wrong hash"; not_installed "wrong hash"
pass "tarball hash mismatch refused"

fresh; release 1.5.2; cp "${tmp}/dl/navis-v1.5.2-linux.tar.gz" "${tmp}/dl/navis-v1.5.3-linux.tar.gz"
run --yes "${tmp}/dl/navis-v1.5.3-linux.tar.gz"; want_fail "version mismatch"; want_out 'version' "version mismatch"; not_installed "version mismatch"
pass "manifest version != tarball filename version refused"

fresh; build_tarball 1.5.2; M_CHANNEL=dev make_manifest 1.5.2 "${tmp}/dl/navis-v1.5.2-linux.tar.gz"
run --yes; want_fail "wrong channel"; want_out 'channel' "wrong channel"; not_installed "wrong channel"
M_SCHEMA=2 make_manifest 1.5.2 "${tmp}/dl/navis-v1.5.2-linux.tar.gz"
run --yes; want_fail "wrong schema"; want_out 'schema' "wrong schema"; not_installed "wrong schema"
pass "wrong channel and wrong schema refused"

fresh; build_tarball 1.5.2; M_DUP=1 make_manifest 1.5.2 "${tmp}/dl/navis-v1.5.2-linux.tar.gz"
run --yes; want_fail "duplicate field"; not_installed "duplicate field"
pass "field duplicated in the signed payload refused"

# --- 4. URL allowlist --------------------------------------------------------
fresh; build_tarball 1.5.2; M_URL='https://evil.example/navis-v1.5.2-linux.tar.gz' make_manifest 1.5.2 "${tmp}/dl/navis-v1.5.2-linux.tar.gz"
run --yes; want_fail "non-allowlisted url"; not_installed "non-allowlisted url"
grep -q 'evil.example' "${FX_LOG}" && fail "non-allowlisted URL was requested"
pass "manifest URL outside the allowlist is never requested"

fresh; release 1.5.2
FX_EFFECTIVE='https://evil.example/x' run --yes; want_fail "redirect to bad host"; not_installed "redirect to bad host"
FX_EFFECTIVE='https://release-assets.githubusercontent.com/x' run --yes; want_rc 0 "redirect to GitHub CDN"
pass "redirect to a bad host refused, GitHub CDN allowed"

# --- 5. environment guards ---------------------------------------------------
fresh; release 1.5.2
nocurl="${tmp}/nocurl"; mkdir -p "${nocurl}"
for c in bash sh env sed grep awk tr cut tail head sort rm mv cp ls mkdir mktemp cat date readlink ln basename dirname chmod printf uname id wc openssl sha256sum tar base64 ldd getconf find install; do
  p="$(command -v "${c}" 2>/dev/null || true)"; [[ -z "${p}" ]] || ln -sf "${p}" "${nocurl}/${c}"
done
rc=0; out="$(cd "${tmp}" && HOME="${HOME_DIR}" PATH="${nocurl}" "$(command -v bash)" "${copy}" --yes 2>&1 </dev/null)" || rc=$?
want_fail "missing tool"; want_out 'curl' "missing tool"; not_installed "missing tool"
pass "missing tool listed before anything happens"

fresh; release 1.5.2
TEST_UID=0 run --yes; want_fail "root"; want_out 'root' "root"; not_installed "root"
TEST_ARCH=aarch64 run --yes; want_fail "arch"; want_out 'x86_64' "arch"; not_installed "arch"
TEST_GLIBC=2.31 run --yes; want_fail "glibc"; want_out '2\.35' "glibc"; not_installed "glibc"
TEST_LDD_MISSING='libgtk-3.so.0 libsecret-1.so.0' run --yes; want_fail "missing libs"; want_out 'libgtk-3.so.0' "missing libs"; want_out 'libgtk-3-0' "missing libs"; not_installed "missing libs"
pass "root, non-x86_64, old glibc and missing shared libraries refused"

fresh; release 1.5.2
run; want_fail "no tty and no --yes"; want_out 'tty|--yes' "no tty"; not_installed "no tty"
pass "no tty and no --yes refuses"

printf 'y\n' > "${tmp}/tty-yes"
fresh; release 1.5.2
TEST_TTY="${tmp}/tty-yes" run; want_rc 0 "tty confirmation"; [[ -x "${APP}/navis" ]] || fail "tty-confirmed install missing"
pass "tty confirmation installs (prompts do not use stdin)"

# --- 6. upgrades, rollback, foreign installs ----------------------------------
fresh; release 1.5.2; run --yes
mkdir -p "${DATA}/com.navis.app.navis" "${DATA}/other-app"; echo db > "${DATA}/com.navis.app.navis/navis.sqlite"; echo keep > "${DATA}/other-app/f"
echo stale > "${APP}/stale-file"
release 1.5.3; run --yes; want_rc 0 "reinstall"
[[ "$("${LAUNCHER}")" == navis-stub-1.5.3 ]] || fail "upgrade did not replace the app"
[[ ! -e "${APP}/stale-file" ]] || fail "old app dir content survived the swap"
[[ -f "${DATA}/com.navis.app.navis/navis.sqlite" && -f "${DATA}/other-app/f" ]] || fail "user data touched"
grep -q '^version 1.5.3$' "${IM}" || fail "install manifest not updated"
no_leftovers "reinstall"
pass "reinstall over an existing install keeps user data"

release 1.5.4; TEST_MV_FAIL=1 run --yes; want_fail "failed swap"
[[ "$("${LAUNCHER}")" == navis-stub-1.5.3 && -f "${APP}/lib/libapp.so" ]] || fail "failed swap did not restore the old copy"
no_leftovers "failed swap"
pass "failed swap restores the old copy"

# older local tarball: warn and continue (owner decision D3)
release 1.5.1; run --yes "${tmp}/dl/navis-v1.5.1-linux.tar.gz"; want_rc 0 "older tarball"; want_out 'older' "older tarball"
[[ "$("${LAUNCHER}")" == navis-stub-1.5.1 ]] || fail "older tarball not installed"
pass "older local tarball warns but installs"

fresh; release 1.5.2; mkdir -p "${APP}"; echo mine > "${APP}/manual"
run --yes; want_fail "foreign app dir with --yes"; [[ -f "${APP}/manual" ]] || fail "foreign dir was removed"
printf 'y\ny\n' > "${tmp}/tty-y2"; TEST_TTY="${tmp}/tty-y2" run; want_rc 0 "foreign dir confirmed"; [[ ! -e "${APP}/manual" ]] || fail "foreign dir not replaced after confirmation"
pass "install without a manifest is foreign: only an interactive yes replaces it"

fresh; release 1.5.2; touch "${tmp}/system-navis"; chmod +x "${tmp}/system-navis"
TEST_SYSTEM_APP="${tmp}/system-navis" run; want_fail "system package, no tty"; not_installed "system package"
TEST_SYSTEM_APP="${tmp}/system-navis" run --yes; want_rc 0 "system package with --yes"
pass "an existing system package install is asked about"

fresh; release 1.5.2; mkdir -p "$(dirname "${LAUNCHER}")"; echo '#!/bin/sh' > "${LAUNCHER}"
run --yes; want_fail "foreign launcher"; [[ ! -L "${LAUNCHER}" ]] || fail "foreign launcher replaced"
pass "foreign launcher is not replaced under --yes"

# --- 7. uninstall and purge ---------------------------------------------------
fresh; release 1.5.2; run --yes
mkdir -p "${DATA}/com.navis.app.navis" "${DATA}/icons/hicolor/256x256/apps"; echo db > "${DATA}/com.navis.app.navis/navis.sqlite"
echo other > "${DATA}/icons/hicolor/256x256/apps/other.png"; echo keep > "${DATA}/unrelated"
run --uninstall; want_rc 0 "uninstall"
[[ ! -e "${APP}" && ! -e "${LAUNCHER}" && ! -e "${DESKTOP}" && ! -e "${ICON}" && ! -e "${IM}" ]] || fail "uninstall left installed files"
[[ -f "${DATA}/unrelated" && -f "${DATA}/icons/hicolor/256x256/apps/other.png" && -f "${DATA}/com.navis.app.navis/navis.sqlite" ]] || fail "uninstall removed unrelated files or user data"
run --uninstall; want_fail "uninstall twice"
pass "uninstall removes exactly the manifest paths"

fresh; release 1.5.2; run --yes
mkdir -p "${DATA}/com.navis.app.navis"; echo db > "${DATA}/com.navis.app.navis/navis.sqlite"
run --purge --yes; want_fail "purge without tty"; [[ -d "${APP}" && -f "${DATA}/com.navis.app.navis/navis.sqlite" ]] || fail "purge acted without confirmation"
printf 'nope\n' > "${tmp}/tty-no"; TEST_TTY="${tmp}/tty-no" run --purge; want_fail "purge wrong word"
[[ -d "${APP}" && -f "${DATA}/com.navis.app.navis/navis.sqlite" ]] || fail "purge acted on a wrong confirmation"
printf 'purge\n' > "${tmp}/tty-purge"; TEST_TTY="${tmp}/tty-purge" run --purge; want_rc 0 "purge"
[[ ! -e "${APP}" && ! -e "${DATA}/com.navis.app.navis" ]] || fail "purge left the app or its data"
pass "purge needs a typed confirmation from the tty"

# --- 8. XDG_DATA_HOME ----------------------------------------------------------
fresh; release 1.5.2
XDG_DATA_HOME='relative/dir' run --yes; want_rc 0 "relative XDG"; [[ -x "${APP}/navis" ]] || fail "relative XDG_DATA_HOME was not ignored"
fresh; release 1.5.2; mkdir -p "${tmp}/xdg data"
XDG_DATA_HOME="${tmp}/xdg data" run --yes; want_rc 0 "absolute XDG"; [[ -x "${tmp}/xdg data/navis/navis" ]] || fail "absolute XDG_DATA_HOME ignored"
pass "XDG_DATA_HOME honoured only when absolute"

run --help; want_rc 0 "--help"; want_out 'usage' "--help"
pass "--help"

echo "linux_install_test: all passed"
