#!/usr/bin/env bash
# Hermetic tests for linux/install.sh: isolated HOME, throwaway Ed25519 key,
# no network. A COPY of the script gets the test key, a fixture-serving
# transport() and a tty path; the shipped file has no test hooks.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALL="${NAVIS_INSTALL_UNDER_TEST:-${REPO_ROOT}/linux/install.sh}"   # override only to replay an older script

fail() { echo "linux_install_test: FAIL: $*" >&2; [[ -z "${out:-}" ]] || printf '%s\n' "${out}" | head -20 >&2; exit 1; }
pass() { echo "ok - $1"; }
[[ -f "${INSTALL}" ]] || fail "linux/install.sh does not exist"
for t in jq openssl base64 tar sha256sum; do command -v "${t}" >/dev/null || fail "${t} is required"; done

tmp="$(mktemp -d "${TMPDIR:-/tmp}/navis-install-test-XXXXXX")"
trap 'chmod -R u+w "${tmp}" 2>/dev/null; rm -rf "${tmp}"' EXIT
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
# mv fails on request (comma list): "new" = the final swap-in, "old" = moving the
# current install aside, "restore" = putting the parked copy back.
cat > "${tmp}/stubs/mv" <<'STUB'
#!/bin/sh
case ",${TEST_MV_FAIL:-}," in
  *,new,*) case "$1" in */navis.new.*) exit 1 ;; esac ;;
  *) ;;
esac
case ",${TEST_MV_FAIL:-}," in
  *,old,*) case "$1" in */navis) exit 1 ;; esac ;;
esac
case ",${TEST_MV_FAIL:-}," in
  *,restore,*) case "$1" in */navis.old.*/app) exit 1 ;; esac ;;
esac
case ",${TEST_MV_FAIL:-}," in
  *,manifest,*) case "$1" in *.install-manifest.tmp) exit 1 ;; esac ;;
esac
exec /usr/bin/env -i PATH=/usr/bin:/bin mv "$@"
STUB
# rm refuses anything under a parked previous install when asked (simulates a failed removal).
cat > "${tmp}/stubs/rm" <<'STUB'
#!/bin/sh
if [ -n "${TEST_RM_FAIL:-}" ]; then
  for a; do case "$a" in */navis.old.*) exit 1 ;; esac; done
fi
exec /usr/bin/env -i PATH=/usr/bin:/bin rm "$@"
STUB
real_install="$(command -v install)"; real_openssl="$(command -v openssl)"
printf '#!/bin/sh
[ -z "${TEST_INSTALL_FAIL:-}" ] || exit 1
exec %s "$@"
' "${real_install}" > "${tmp}/stubs/install"
printf '#!/bin/sh
if [ "$1" = version ] && [ -n "${TEST_OPENSSL_VERSION:-}" ]; then echo "$TEST_OPENSSL_VERSION"; exit 0; fi
exec %s "$@"
' "${real_openssl}" > "${tmp}/stubs/openssl"
for c in update-desktop-database gtk-update-icon-cache; do
  printf '#!/bin/sh
echo "%s $*" >> "%s"
' "${c}" "${tmp}/cache.log" > "${tmp}/stubs/${c}"
done
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
  sha="$(sha256sum < "${t}" | cut -d' ' -f1)"
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

fresh() { chmod -R u+w "${HOME_DIR}" 2>/dev/null || true; rm -rf "${HOME_DIR}" "${FX_LOG}"; mkdir -p "${HOME_DIR}"; : > "${FX_LOG}"; }
run() { rc=0; mkdir -p "${tmp}/tmpdir"; out="$(cd "${tmp}" && TMPDIR="${tmp}/tmpdir" HOME="${RUN_HOME:-${HOME_DIR}}" bash "${SCRIPT:-${copy}}" "$@" 2>&1 </dev/null)" || rc=$?; }
want_rc() { [[ "${rc}" == "$1" ]] || fail "$2: expected exit $1, got ${rc}"; }
want_fail() { [[ "${rc}" != 0 ]] || fail "$1: expected a refusal, got success"; }
want_out() { printf '%s' "${out}" | grep -Eqi -- "$1" || fail "$2: output lacks /$1/"; }

DATA="${HOME_DIR}/.local/share"; APP="${DATA}/navis"; LAUNCHER="${HOME_DIR}/.local/bin/navis"
DESKTOP="${DATA}/applications/com.navis.app.navis.desktop"; IM="${DATA}/navis.install-manifest"
ICON="${DATA}/icons/hicolor/256x256/apps/navis.png"
not_installed() { [[ ! -e "${APP}" && ! -L "${LAUNCHER}" && ! -e "${DESKTOP}" ]] || fail "$1: something was installed"; }
no_leftovers() { [[ -z "$(ls -A "${DATA}" 2>/dev/null | grep -E '^navis\.(new|old)' || true)" ]] || fail "$1: navis.new/navis.old left behind"; }

# --- cases (each runs in its own subshell so one failure does not hide the rest) ---
failures=()
run_case() {
  local name="$1" fn="$2" st
  set +e; ( set -e; "${fn}" ); st=$?; set -e
  if [[ "${st}" == 0 ]]; then echo "ok - ${name}"; else echo "FAIL - ${name}"; failures+=("${name}"); fi
}
tty_answers() { printf '%s' "$1" > "${tmp}/tty-answers"; export TEST_TTY="${tmp}/tty-answers"; }
install_v() { fresh; release "$1"; run --yes; want_rc 0 "install $1"; }
cmd_of() { "${LAUNCHER}"; }

c_pinned_key() {
  local app_key
  app_key="$(grep -A1 'updateSigningPublicKey *=' "${REPO_ROOT}/lib/src/utils/constants.dart" | grep -o "'[A-Za-z0-9+/=]*'" | head -1 | tr -d "'")"
  [[ -n "${app_key}" ]] || fail "could not read updateSigningPublicKey"
  grep -q "^PINNED_KEY='${app_key}'\$" "${INSTALL}" || fail "PINNED_KEY differs from AppConstants.updateSigningPublicKey"
}

c_valid_install() {
  install_v 1.5.2
  [[ -L "${LAUNCHER}" && "$(readlink -f "${LAUNCHER}")" == "${APP}/navis" ]] || fail "launcher is not a symlink into the app dir"
  [[ "$(cmd_of)" == navis-stub-1.5.2 ]] || fail "launcher does not run the bundle"
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
  [[ -z "$(ls -A "${DATA}" | grep -E '^navis\.' | grep -v install-manifest || true)" ]] || fail "sibling temp dirs left"
  if command -v desktop-file-validate >/dev/null 2>&1; then desktop-file-validate "${DESKTOP}" || fail "desktop-file-validate"; fi
}

c_local_tarball() {
  fresh; release 1.5.2
  run --yes "${tmp}/dl/navis-v1.5.2-linux.tar.gz"; want_rc 0 "local tarball"
  grep -q 'github.com/Porthorion/Navis/releases/download/v1.5.2/manifest.json' "${FX_LOG}" || fail "local mode did not fetch the tagged GitHub manifest"
  ! grep -q 'tar.gz' "${FX_LOG}" || fail "local mode downloaded a tarball"
  [[ "$(cmd_of)" == navis-stub-1.5.2 ]] || fail "local install broken"
}

c_backslash_path() { # R3: sha256sum prints a leading backslash for such names
  fresh; build_tarball 1.5.2; mkdir -p "${tmp}/dl/back\\slash"
  cp "${tmp}/dl/navis-v1.5.2-linux.tar.gz" "${tmp}/dl/back\\slash/"
  make_manifest 1.5.2 "${tmp}/dl/back\\slash/navis-v1.5.2-linux.tar.gz"
  run --yes "${tmp}/dl/back\\slash/navis-v1.5.2-linux.tar.gz"; want_rc 0 "backslash path"
  [[ "$(cmd_of)" == navis-stub-1.5.2 ]] || fail "not installed"
}

c_tampered() { fresh; build_tarball 1.5.2; M_TAMPER=1 make_manifest 1.5.2 "${tmp}/dl/navis-v1.5.2-linux.tar.gz"
  run --yes; want_fail tampered; want_out signature tampered; not_installed tampered; }
c_other_key() { fresh; build_tarball 1.5.2; M_KEY="${other_key}" make_manifest 1.5.2 "${tmp}/dl/navis-v1.5.2-linux.tar.gz"
  run --yes; want_fail "other key"; want_out signature "other key"; not_installed "other key"; }
c_bad_hash() { fresh; release 1.5.2; echo extra >> "${tmp}/dl/navis-v1.5.2-linux.tar.gz"
  run --yes; want_fail "wrong hash"; want_out 'sha-?256|checksum|hash' "wrong hash"; not_installed "wrong hash"; }
c_version_mismatch() { fresh; release 1.5.2; cp "${tmp}/dl/navis-v1.5.2-linux.tar.gz" "${tmp}/dl/navis-v1.5.3-linux.tar.gz"
  run --yes "${tmp}/dl/navis-v1.5.3-linux.tar.gz"; want_fail "version mismatch"; want_out version "version mismatch"; not_installed "version mismatch"; }
c_channel_schema() {
  fresh; build_tarball 1.5.2; M_CHANNEL=dev make_manifest 1.5.2 "${tmp}/dl/navis-v1.5.2-linux.tar.gz"
  run --yes; want_fail "wrong channel"; want_out channel "wrong channel"; not_installed "wrong channel"
  M_SCHEMA=2 make_manifest 1.5.2 "${tmp}/dl/navis-v1.5.2-linux.tar.gz"
  run --yes; want_fail "wrong schema"; want_out schema "wrong schema"; not_installed "wrong schema"
}
c_duplicate_field() { fresh; build_tarball 1.5.2; M_DUP=1 make_manifest 1.5.2 "${tmp}/dl/navis-v1.5.2-linux.tar.gz"
  run --yes; want_fail "duplicate field"; not_installed "duplicate field"; }
c_envelope_lines() { # one JSON line only
  fresh; release 1.5.2; cp "${FX_MANIFEST}" "${tmp}/two-line.json"; printf '\n' >> "${tmp}/two-line.json"; export FX_MANIFEST="${tmp}/two-line.json"
  run --yes; want_fail "two-line envelope"; want_out malformed "two-line envelope"; not_installed "two-line envelope"
}

c_bad_asset_urls() {
  local url
  for url in 'https://evil.example/navis-v1.5.2-linux.tar.gz' \
      'https://downloads.porthorion.com/navis/../evil/navis-v1.5.2-linux.tar.gz' \
      'https://github.com/evil/Navis/releases/download/v1.5.2/navis-v1.5.2-linux.tar.gz' \
      'https://objects.githubusercontent.com/x/navis-v1.5.2-linux.tar.gz' \
      'http://downloads.porthorion.com/navis/navis-v1.5.2-linux.tar.gz' \
      'https://downloads.porthorion.com.evil.example/navis/navis-v1.5.2-linux.tar.gz' \
      'https://evildownloads.porthorion.com/navis/navis-v1.5.2-linux.tar.gz' \
      'https://downloads.porthorion.com@evil.example/navis/navis-v1.5.2-linux.tar.gz'; do
    fresh; build_tarball 1.5.2; M_URL="${url}" make_manifest 1.5.2 "${tmp}/dl/navis-v1.5.2-linux.tar.gz"
    run --yes; want_fail "asset url ${url}"; not_installed "asset url ${url}"
    ! grep -q 'tar.gz' "${FX_LOG}" || fail "disallowed URL was requested: ${url}"
  done
}
c_redirects() {
  fresh; release 1.5.2
  FX_EFFECTIVE='https://evil.example/x' run --yes; want_fail "redirect to bad host"; not_installed "redirect to bad host"
  FX_EFFECTIVE='https://release-assets.githubusercontent.com/x' run --yes; want_rc 0 "redirect to GitHub CDN"
}

c_missing_tool() {
  fresh; release 1.5.2
  local nocurl="${tmp}/nocurl" c p; mkdir -p "${nocurl}"
  for c in bash sh env sed grep awk tr cut tail head sort rm mv cp ls mkdir mktemp cat date readlink ln basename dirname chmod printf uname id wc openssl sha256sum tar base64 ldd getconf find install rmdir; do
    p="$(command -v "${c}" 2>/dev/null || true)"; [[ -z "${p}" ]] || ln -sf "${p}" "${nocurl}/${c}"
  done
  rc=0; out="$(cd "${tmp}" && HOME="${HOME_DIR}" PATH="${nocurl}" "$(command -v bash)" "${copy}" --yes 2>&1 </dev/null)" || rc=$?
  want_fail "missing tool"; want_out curl "missing tool"; not_installed "missing tool"
}
c_old_openssl() {
  fresh; release 1.5.2
  TEST_OPENSSL_VERSION='OpenSSL 1.1.1w  11 Sep 2023' run --yes; want_fail "old openssl"; want_out 'OpenSSL 3' "old openssl"; not_installed "old openssl"
}
c_host_guards() {
  fresh; release 1.5.2
  TEST_UID=0 run --yes; want_fail root; want_out root root; not_installed root
  TEST_ARCH=aarch64 run --yes; want_fail arch; want_out x86_64 arch; not_installed arch
  TEST_GLIBC=2.31 run --yes; want_fail glibc; want_out '2\.35' glibc; not_installed glibc
  TEST_LDD_MISSING='libgtk-3.so.0 libsecret-1.so.0' run --yes; want_fail "missing libs"; want_out 'libgtk-3.so.0' "missing libs"; want_out 'libgtk-3-0' "missing libs"; not_installed "missing libs"
}
c_no_tty() { fresh; release 1.5.2; run; want_fail "no tty, no --yes"; want_out 'tty|terminal|--yes' "no tty"; not_installed "no tty"; }
c_tty_confirm() { fresh; release 1.5.2; tty_answers $'y\n'; run; want_rc 0 "tty confirm"; [[ -x "${APP}/navis" ]] || fail "not installed"; }

c_reinstall() {
  install_v 1.5.2
  mkdir -p "${DATA}/com.navis.app.navis" "${DATA}/other-app"; echo db > "${DATA}/com.navis.app.navis/navis.sqlite"; echo keep > "${DATA}/other-app/f"
  echo stale > "${APP}/stale-file"
  release 1.5.3; run --yes; want_rc 0 reinstall
  [[ "$(cmd_of)" == navis-stub-1.5.3 ]] || fail "upgrade did not replace the app"
  [[ ! -e "${APP}/stale-file" ]] || fail "old app dir content survived"
  [[ -f "${DATA}/com.navis.app.navis/navis.sqlite" && -f "${DATA}/other-app/f" ]] || fail "user data touched"
  grep -q '^version 1.5.3$' "${IM}" || fail "install manifest not updated"
  no_leftovers reinstall
}
c_swap_in_fails() {
  install_v 1.5.2; release 1.5.3
  TEST_MV_FAIL=new run --yes; want_fail "swap-in failure"
  [[ "$(cmd_of)" == navis-stub-1.5.2 && -f "${APP}/lib/libapp.so" ]] || fail "failed swap did not restore the old copy"
  no_leftovers "swap-in failure"
}
c_move_aside_fails() { # R1: the old install must survive a failed first move
  install_v 1.5.2; release 1.5.3
  TEST_MV_FAIL=old run --yes; want_fail "move-aside failure"
  [[ "$(cmd_of)" == navis-stub-1.5.2 && -f "${APP}/lib/libapp.so" ]] || fail "old install was damaged by a failed move-aside"
  no_leftovers "move-aside failure"
}
c_integrate_fails_fresh() { # R4
  fresh; release 1.5.2
  TEST_INSTALL_FAIL=1 run --yes; want_fail "integrate failure"
  not_installed "integrate failure"; [[ ! -e "${IM}" && ! -e "${ICON}" ]] || fail "leftovers after a failed fresh install"
  [[ -z "$(ls -A "${DATA}/applications" 2>/dev/null || true)" ]] || fail "desktop temp/file left behind"
  no_leftovers "integrate failure"
}
c_integrate_fails_upgrade() {
  install_v 1.5.2; release 1.5.3
  TEST_INSTALL_FAIL=1 run --yes; want_fail "integrate failure on upgrade"
  [[ "$(cmd_of)" == navis-stub-1.5.2 && -f "${DESKTOP}" && -f "${IM}" ]] || fail "failed upgrade damaged the existing install"
}
c_older_tarball() {
  install_v 1.5.3; release 1.5.1
  run --yes "${tmp}/dl/navis-v1.5.1-linux.tar.gz"; want_rc 0 "older tarball"; want_out older "older tarball"
  [[ "$(cmd_of)" == navis-stub-1.5.1 ]] || fail "older tarball not installed"
}

# floor_copy VERSION: the test copy with the release-time minimum version filled in
floor_copy() {
  sed "s/^NAVIS_MIN_VERSION=.*/NAVIS_MIN_VERSION='$1'/" "${copy}" > "${tmp}/install-floor.sh"
  grep -qx "NAVIS_MIN_VERSION='$1'" "${tmp}/install-floor.sh" || fail "NAVIS_MIN_VERSION line missing from install.sh"
  export SCRIPT="${tmp}/install-floor.sh"
}
c_floor_refuses_older() {
  floor_copy 1.5.2; fresh; release 1.5.1
  run --yes; want_fail "older than floor, --yes"; want_out 'minimum|replay' "floor message"; not_installed "older than floor"
  tty_answers $'y\ny\ny\n'; run; want_fail "older than floor, tty yes"; not_installed "older than floor, tty"
  run --yes "${tmp}/dl/navis-v1.5.1-linux.tar.gz"; want_fail "older tarball under floor"; not_installed "older tarball under floor"
}
c_floor_allows_equal_and_newer() {
  floor_copy 1.5.2; fresh; release 1.5.2; run --yes; want_rc 0 "equal to floor"
  [[ "$(cmd_of)" == navis-stub-1.5.2 ]] || fail "equal release not installed"
  fresh; release 1.5.10; run --yes; want_rc 0 "newer than floor (1.5.10 > 1.5.2)"
  [[ "$(cmd_of)" == navis-stub-1.5.10 ]] || fail "newer release not installed"
}

c_foreign_app() {
  fresh; release 1.5.2; mkdir -p "${APP}"; echo mine > "${APP}/manual"
  run --yes; want_fail "foreign app dir with --yes"; [[ -f "${APP}/manual" ]] || fail "foreign dir removed"
  tty_answers $'n\ny\n'; run; want_fail "answered n"; [[ -f "${APP}/manual" ]] || fail "foreign dir removed after n"; not_installed_launcher
  tty_answers $'y\ny\n'; run; want_rc 0 "foreign dir confirmed"; [[ ! -e "${APP}/manual" ]] || fail "foreign dir not replaced after yes"
}
not_installed_launcher() { [[ ! -L "${LAUNCHER}" ]] || fail "launcher created despite refusal"; }
c_system_package() {
  fresh; release 1.5.2; touch "${tmp}/system-navis"; chmod +x "${tmp}/system-navis"
  TEST_SYSTEM_APP="${tmp}/system-navis" run; want_fail "system package, no tty"; not_installed "system package"
  TEST_SYSTEM_APP="${tmp}/system-navis" run --yes; want_rc 0 "system package with --yes"
}
c_system_package_tty() { # the /opt/navis question, answered on the terminal
  fresh; release 1.5.2; touch "${tmp}/system-navis"; chmod +x "${tmp}/system-navis"
  tty_answers $'n\ny\n'; TEST_SYSTEM_APP="${tmp}/system-navis" run; want_fail "answered n to the system package question"
  want_out 'system package' "question names the system package"; not_installed "system package, answered n"
  tty_answers $'y\ny\n'; TEST_SYSTEM_APP="${tmp}/system-navis" run; want_rc 0 "answered y"; [[ -x "${APP}/navis" ]] || fail "not installed after y"
}
c_relative_home() { fresh; release 1.5.2; RUN_HOME='relative/home' run --yes; want_fail "relative HOME"; want_out 'HOME' "relative HOME"; [[ ! -e "${tmp}/relative" ]] || fail "created files under a relative HOME"; }
c_symlink_launcher_in_bundle() { # a bundle whose navis is a symlink is not a bundle
  fresh; build_tarball 1.5.2; rm "${tmp}/bundle-1.5.2/navis"; ln -s /bin/true "${tmp}/bundle-1.5.2/navis"
  tar -czf "${tmp}/dl/navis-v1.5.2-linux.tar.gz" -C "${tmp}/bundle-1.5.2" .; make_manifest 1.5.2 "${tmp}/dl/navis-v1.5.2-linux.tar.gz"
  run --yes; want_fail "symlinked navis"; want_out 'does not look like' "symlinked navis"; not_installed "symlinked navis"
}
c_trailing_slash_xdg() { # R18: no `share//navis` paths in the manifest
  fresh; release 1.5.2
  XDG_DATA_HOME="${DATA}/" run --yes; want_rc 0 "trailing-slash XDG_DATA_HOME"
  ! grep -q '//' "${IM}" || fail "install manifest records a doubled slash: $(grep '//' "${IM}" | head -1)"
  run --uninstall; want_rc 0 "uninstall without the variable"; [[ ! -e "${APP}" ]] || fail "uninstall left the app"
}
c_cleanup_ignores_signals() { # R19: a second signal must not interrupt the restore
  sed -n '/^cleanup() {/,/^}/p' "${INSTALL}" | grep -q "trap '' INT TERM HUP" || fail "cleanup() does not ignore INT/TERM/HUP"
}
c_foreign_launcher() {
  fresh; release 1.5.2; mkdir -p "$(dirname "${LAUNCHER}")"; echo '#!/bin/sh' > "${LAUNCHER}"
  run --yes; want_fail "foreign launcher"; [[ ! -L "${LAUNCHER}" ]] || fail "foreign launcher replaced"
}
c_foreign_desktop() { # R5
  fresh; release 1.5.2; mkdir -p "$(dirname "${DESKTOP}")"; echo foreign > "${DESKTOP}"
  run --yes; want_fail "foreign desktop file"; [[ "$(cat "${DESKTOP}")" == foreign ]] || fail "foreign desktop file overwritten"; not_installed_launcher
  tty_answers $'y\ny\n'; run; want_rc 0 "foreign desktop confirmed"; grep -q TryExec "${DESKTOP}" || fail "desktop file not replaced after yes"
  # A symlink at the target is replaced, never written through.
  fresh; release 1.5.2; mkdir -p "$(dirname "${DESKTOP}")"; echo victim > "${tmp}/victim"; ln -s "${tmp}/victim" "${DESKTOP}"
  tty_answers $'y\ny\n'; run; want_rc 0 "symlinked desktop confirmed"
  [[ "$(cat "${tmp}/victim")" == victim ]] || fail "install wrote through a symlink"
  [[ ! -L "${DESKTOP}" && -f "${DESKTOP}" ]] || fail "desktop symlink not replaced by a regular file"
}
c_user_new_old_dirs() { # R6
  fresh; release 1.5.2; mkdir -p "${DATA}/navis.new" "${DATA}/navis.old"; echo a > "${DATA}/navis.new/a"; echo b > "${DATA}/navis.old/b"
  run --yes; want_rc 0 "install beside user dirs"
  [[ -f "${DATA}/navis.new/a" && -f "${DATA}/navis.old/b" ]] || fail "user's navis.new / navis.old were touched"
}
c_interrupted_recovery() {
  install_v 1.5.2
  mkdir -p "${APP}.old.CRASH"; mv "${APP}" "${APP}.old.CRASH/app"   # parked by a run that died mid-swap
  release 1.5.3; TEST_LDD_MISSING=libx.so.1 run --yes; want_fail "install failing after recovery"
  [[ "$(cmd_of)" == navis-stub-1.5.2 ]] || fail "interrupted swap was not recovered"
}

c_uninstall() {
  install_v 1.5.2
  mkdir -p "${DATA}/com.navis.app.navis" "${DATA}/icons/hicolor/256x256/apps"; echo db > "${DATA}/com.navis.app.navis/navis.sqlite"
  echo other > "${DATA}/icons/hicolor/256x256/apps/other.png"; echo keep > "${DATA}/unrelated"
  : > "${tmp}/cache.log"
  run --uninstall; want_rc 0 uninstall
  [[ ! -e "${APP}" && ! -e "${LAUNCHER}" && ! -e "${DESKTOP}" && ! -e "${ICON}" && ! -e "${IM}" ]] || fail "uninstall left installed files"
  [[ -f "${DATA}/unrelated" && -f "${DATA}/icons/hicolor/256x256/apps/other.png" && -f "${DATA}/com.navis.app.navis/navis.sqlite" ]] || fail "uninstall removed unrelated files or user data"
  grep -q update-desktop-database "${tmp}/cache.log" && grep -q gtk-update-icon-cache "${tmp}/cache.log" || fail "desktop/icon caches not refreshed after uninstall"
  run --uninstall; want_fail "uninstall twice"
}
c_uninstall_unsafe_manifest() { # R2
  install_v 1.5.2; echo precious > "${HOME_DIR}/precious"; mkdir -p "/${HOME_DIR#/}/.local"
  local bad
  for bad in "${HOME_DIR}/" "${HOME_DIR}/.local" "${HOME_DIR}" "/home/someone-else" "${DATA}/../escape"; do
    cp "${IM}" "${tmp}/im.good"; printf 'path %s\n' "${bad}" >> "${IM}"
    run --uninstall; want_fail "manifest path ${bad}"
    [[ -f "${HOME_DIR}/precious" && -d "${APP}" && -L "${LAUNCHER}" ]] || fail "uninstall deleted something for manifest path ${bad}"
    cp "${tmp}/im.good" "${IM}"
  done
}
c_purge() {
  install_v 1.5.2
  mkdir -p "${DATA}/com.navis.app.navis"; echo db > "${DATA}/com.navis.app.navis/navis.sqlite"
  run --purge --yes; want_fail "purge without tty"; [[ -d "${APP}" && -f "${DATA}/com.navis.app.navis/navis.sqlite" ]] || fail "purge acted without confirmation"
  tty_answers $'nope\n'; run --purge; want_fail "purge wrong word"; want_out 'downloads' "purge warning names downloads"
  [[ -d "${APP}" && -f "${DATA}/com.navis.app.navis/navis.sqlite" ]] || fail "purge acted on a wrong confirmation"
  tty_answers $'purge\n'; : > "${tmp}/cache.log"; run --purge; want_rc 0 purge
  [[ ! -e "${APP}" && ! -e "${DATA}/com.navis.app.navis" ]] || fail "purge left the app or its data"
  grep -q update-desktop-database "${tmp}/cache.log" || fail "caches not refreshed after purge"
}
c_xdg() {
  fresh; release 1.5.2
  XDG_DATA_HOME='relative/dir' run --yes; want_rc 0 "relative XDG"; [[ -x "${APP}/navis" ]] || fail "relative XDG_DATA_HOME was not ignored"
  fresh; release 1.5.2; mkdir -p "${tmp}/xdg data"
  XDG_DATA_HOME="${tmp}/xdg data" run --yes; want_rc 0 "absolute XDG"; [[ -x "${tmp}/xdg data/navis/navis" ]] || fail "absolute XDG_DATA_HOME ignored"
}
c_xdg_control_chars() { # R2
  fresh; release 1.5.2
  XDG_DATA_HOME="${tmp}/ctl"$'\n'"bad" run --yes; want_fail "newline in XDG_DATA_HOME"; want_out control "newline in XDG_DATA_HOME"
  [[ -z "$(ls "${tmp}" | grep '^ctl' || true)" ]] || fail "created a directory for a path with a newline"
}
c_help() { run --help; want_rc 0 help; want_out usage help; }

c_truncated_download() { # R7: a script cut off at `main` must not run
  fresh; release 1.5.2
  local off; off="$(grep -b -o 'main "\$@"' "${copy}" | tail -1 | cut -d: -f1)"
  head -c $((off + 4)) "${copy}" > "${tmp}/truncated.sh"
  SCRIPT="${tmp}/truncated.sh" run; want_fail "truncated script"
  [[ ! -s "${FX_LOG}" ]] || fail "a truncated script ran part of the installer"
}
c_curl_flags() { # R8: the real transport(), with a stub curl that records argv
  fresh; release 1.5.2
  local copy2="${tmp}/install-curl.sh" line n=0
  sed -e "s|^PINNED_KEY=.*|PINNED_KEY='$(pub_b64 "${key}")'|" -e 's|^TTY=.*|TTY="${TEST_TTY:-/nonexistent}"|' "${INSTALL}" > "${copy2}"
  mkdir -p "${tmp}/curlstub"
  cat > "${tmp}/curlstub/curl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "${CURL_LOG}"
prev=''; out=''
for a; do [ "$prev" = -o ] && out="$a"; prev="$a"; last="$a"; done
case "$last" in */manifest.json) cp "${FX_MANIFEST}" "$out" ;; *.tar.gz) cp "${FX_TARBALL}" "$out" ;; esac
printf '%s' "$last"
STUB
  chmod +x "${tmp}/curlstub/curl"; : > "${tmp}/curl.log"
  rc=0; out="$(cd "${tmp}" && CURL_LOG="${tmp}/curl.log" PATH="${tmp}/curlstub:${PATH}" TMPDIR="${tmp}/tmpdir" HOME="${HOME_DIR}" bash "${copy2}" --yes 2>&1 </dev/null)" || rc=$?
  want_rc 0 "install through the real transport"
  while IFS= read -r line; do
    n=$((n + 1))
    for flag in '--proto =https' '--proto-redir =https' '-A Navis-installer' '--connect-timeout' '--max-redirs' '--max-filesize'; do
      [[ "${line}" == *"${flag}"* ]] || fail "curl call lacks ${flag}: ${line}"
    done
  done < "${tmp}/curl.log"
  [[ "${n}" == 2 ]] || fail "expected two curl calls, saw ${n}"
}

c_unsafe_tar_member() {
  fresh; build_tarball 1.5.2
  python3 -I - "${tmp}/bundle-1.5.2" "${tmp}/dl/navis-v1.5.2-linux.tar.gz" <<'PY'
import os, sys, tarfile
src, out = sys.argv[1:3]
with tarfile.open(out, 'w:gz') as t:
    for root, _, files in os.walk(src):
        for f in files:
            p = os.path.join(root, f)
            t.add(p, arcname=os.path.relpath(p, src))
    t.add(os.path.join(src, 'navis'), arcname='../escape')
PY
  make_manifest 1.5.2 "${tmp}/dl/navis-v1.5.2-linux.tar.gz"
  run --yes; want_fail "unsafe tar member"; want_out unsafe "unsafe tar member"; not_installed "unsafe tar member"
}
c_bundle_shape() {
  fresh; build_tarball 1.5.2; rm -rf "${tmp}/bundle-1.5.2/lib"; tar -czf "${tmp}/dl/navis-v1.5.2-linux.tar.gz" -C "${tmp}/bundle-1.5.2" .
  make_manifest 1.5.2 "${tmp}/dl/navis-v1.5.2-linux.tar.gz"
  run --yes; want_fail "bundle without lib"; want_out 'does not look like' "bundle without lib"; not_installed "bundle without lib"
}

c_commit_then_old_removal_fails() { # R12: after the commit point nothing rolls back
  install_v 1.5.2; release 1.5.3
  TEST_RM_FAIL=1 run --yes; want_rc 0 "failed removal of the parked copy"
  [[ "$(cmd_of)" == navis-stub-1.5.3 && -f "${IM}" ]] || fail "the new install was rolled back after the commit"
  grep -q '^version 1.5.3$' "${IM}" || fail "manifest not the new one"
  want_out 'navis\.old\.' "warning names the leftover dir"
}
c_readonly_old_subdir() { # R12: a read-only subdir in the old copy must not undo the upgrade
  install_v 1.5.2; mkdir -p "${APP}/ro"; echo x > "${APP}/ro/f"; chmod 555 "${APP}/ro"
  release 1.5.3; run --yes; want_rc 0 "upgrade over a read-only subdir"
  [[ "$(cmd_of)" == navis-stub-1.5.3 ]] || fail "upgrade was rolled back"
  no_leftovers "read-only subdir"
}
c_restore_fails_keeps_old() { # R13
  install_v 1.5.2; release 1.5.3
  TEST_MV_FAIL=new,restore run --yes; want_fail "swap and restore both fail"
  ls -d "${APP}".old.*/app >/dev/null 2>&1 || fail "the only copy of the old install was deleted"
  [[ -f "$(ls -d "${APP}".old.*/app | head -1)/lib/libapp.so" ]] || fail "parked copy is damaged"
  want_out 'navis\.old\.' "message says where the old copy is"
}
c_uninstall_refuses_icon_dir() { # R14
  install_v 1.5.2; mkdir -p "${DATA}/icons/hicolor/256x256/apps"; echo other > "${DATA}/icons/hicolor/256x256/apps/other.png"
  printf 'path %s\n' "${DATA}/icons/hicolor/256x256" >> "${IM}"
  run --uninstall; want_fail "directory under hicolor"
  [[ -f "${DATA}/icons/hicolor/256x256/apps/other.png" && -d "${APP}" ]] || fail "a directory under hicolor was removed"
}
c_uninstall_leaves_changed_files() { # R15
  install_v 1.5.2
  rm -f "${LAUNCHER}"; printf '#!/bin/sh\n' > "${LAUNCHER}"            # user replaced the launcher
  printf '[Desktop Entry]\nExec=/somewhere/else\n' > "${DESKTOP}"      # and the desktop file
  run --uninstall; want_rc 0 "uninstall with changed files"; want_out 'left' "says what it left"
  [[ -f "${LAUNCHER}" && ! -L "${LAUNCHER}" && -f "${DESKTOP}" ]] || fail "uninstall removed files that are no longer ours"
  [[ ! -e "${APP}" && ! -e "${IM}" ]] || fail "uninstall did not remove the app dir and manifest"
  install_v 1.5.2; ln -sfn /usr/bin/true "${LAUNCHER}"                  # symlink pointing elsewhere
  run --uninstall; want_rc 0 "uninstall with foreign symlink"; [[ -L "${LAUNCHER}" && "$(readlink "${LAUNCHER}")" == /usr/bin/true ]] || fail "foreign launcher symlink removed"
}
c_manifest_tmp_cleaned() { # R16
  install_v 1.5.2; release 1.5.3
  TEST_MV_FAIL=manifest run --yes; rc=0
  [[ ! -e "${IM}.tmp" ]] || fail "manifest temp left behind"
}

# --- run ----------------------------------------------------------------------
run_case "pinned key equals constants.dart" c_pinned_key
run_case "valid install: symlink launcher, tarball-root-only app dir, desktop entry, manifest, no leftovers" c_valid_install
run_case "local tarball mode" c_local_tarball
run_case "R3 local tarball path containing a backslash" c_backslash_path
run_case "tampered payload refused" c_tampered
run_case "manifest signed by another key refused" c_other_key
run_case "tarball hash mismatch refused" c_bad_hash
run_case "manifest version != tarball filename refused" c_version_mismatch
run_case "wrong channel / wrong schema refused" c_channel_schema
run_case "duplicated signed field refused" c_duplicate_field
run_case "multi-line envelope refused" c_envelope_lines
run_case "disallowed asset URLs (host, .., repo prefix, CDN as start, http) never requested" c_bad_asset_urls
run_case "bad redirect host refused, GitHub CDN allowed" c_redirects
run_case "missing tool listed" c_missing_tool
run_case "OpenSSL older than 3 refused" c_old_openssl
run_case "root / arch / glibc / missing libs refused" c_host_guards
run_case "no tty and no --yes refuses" c_no_tty
run_case "tty confirmation installs" c_tty_confirm
run_case "reinstall keeps user data" c_reinstall
run_case "failed swap-in restores the old copy" c_swap_in_fails
run_case "R1 failed move-aside leaves the old install intact" c_move_aside_fails
run_case "R4 failed integrate on a fresh install leaves nothing behind" c_integrate_fails_fresh
run_case "R4 failed integrate on an upgrade keeps the old install" c_integrate_fails_upgrade
run_case "older local tarball warns but installs" c_older_tarball
run_case "release below the baked-in floor refused even with --yes" c_floor_refuses_older
run_case "release at or above the floor installs" c_floor_allows_equal_and_newer
run_case "foreign app dir: --yes refused, n refused, interactive y replaces" c_foreign_app
run_case "system package install is asked about" c_system_package
run_case "R20 /opt/navis question asked on the tty" c_system_package_tty
run_case "R20 relative HOME refused" c_relative_home
run_case "R20 symlinked navis in a bundle refused" c_symlink_launcher_in_bundle
run_case "R18 trailing slash in XDG_DATA_HOME" c_trailing_slash_xdg
run_case "R19 cleanup ignores further signals" c_cleanup_ignores_signals
run_case "foreign launcher not replaced under --yes" c_foreign_launcher
run_case "R5 foreign desktop file / symlink never overwritten or followed" c_foreign_desktop
run_case "R6 user's own navis.new / navis.old untouched" c_user_new_old_dirs
run_case "R11 interrupted-swap recovery" c_interrupted_recovery
run_case "uninstall removes exactly the manifest paths and refreshes caches" c_uninstall
run_case "R2 unsafe manifest paths refused, nothing deleted" c_uninstall_unsafe_manifest
run_case "purge needs typed confirmation, warns about downloads, refreshes caches" c_purge
run_case "XDG_DATA_HOME honoured only when absolute" c_xdg
run_case "R2 control characters in XDG_DATA_HOME refused" c_xdg_control_chars
run_case "--help" c_help
run_case "R7 truncated script does not run" c_truncated_download
run_case "R8 curl flags (proto, proto-redir, UA, timeouts, size cap)" c_curl_flags
run_case "R12 failure after the commit point keeps the new install" c_commit_then_old_removal_fails
run_case "R12 read-only subdir in the old copy" c_readonly_old_subdir
run_case "R13 failed restore keeps the parked old copy" c_restore_fails_keeps_old
run_case "R14 uninstall never removes directories under hicolor" c_uninstall_refuses_icon_dir
run_case "R15 uninstall leaves launcher/desktop file that are no longer ours" c_uninstall_leaves_changed_files
run_case "R16 manifest temp removed on failure" c_manifest_tmp_cleaned
run_case "R11 unsafe tar member refused" c_unsafe_tar_member
run_case "R11 bundle shape checked" c_bundle_shape

if (( ${#failures[@]} )); then
  echo "linux_install_test: ${#failures[@]} case(s) failed" >&2
  exit 1
fi
echo "linux_install_test: all passed"
