#!/usr/bin/env bash
# Navis per-user installer for Linux (x86_64, glibc 2.35+). No root needed.
#
#   install.sh [--yes] [TARBALL]   install the latest stable release, or the
#                                  given navis-vX.Y.Z-linux.tar.gz
#   install.sh --uninstall         remove what this script installed
#   install.sh --purge             uninstall and also delete Navis settings and data
#
# Everything is checked before the first file is written: the release manifest
# must carry a valid Ed25519 signature from the key pinned below (the same key
# the app trusts for updates), and the tarball must match the signed SHA-256.
set -euo pipefail

# The whole body is one brace group, so bash parses all of it before running
# any of it: a download cut off mid-file is a syntax error, not a partial run.
{

# Same value as AppConstants.updateSigningPublicKey (raw 32-byte key, base64).
# tool/linux_install_test.sh fails if the two ever differ.
PINNED_KEY='vSq61OOmfZS6CNYHeddKudoDAjZa179002wz/wnKtGk='
TTY=/dev/tty
SYSTEM_APP=/opt/navis/navis
STABLE_MANIFEST_URL='https://downloads.porthorion.com/navis/channels/stable/manifest.json'
RELEASES_URL='https://github.com/Porthorion/Navis/releases/download'
APP_ID=com.navis.app.navis
# Cloudflare rejects bare curl user agents.
USER_AGENT='Navis-installer/1'
MAX_MANIFEST=1048576
MAX_TARBALL=1073741824

YES=0 MODE=install TARBALL=''
DATA='' CONFIG='' CACHE='' LAUNCHER='' DESKTOP='' MANIFEST='' FILE='' PAYLOAD=''
TMP='' NEW='' OLDDIR='' APP='' NEW_IN_PLACE=0 COMMITTED=0
VERSION='' ASSET_URL='' ASSET_SHA=''
CREATED=() FRESH=()   # CREATED: paths recorded in the manifest; FRESH: those that did not exist before this run

die() { echo "install.sh: $*" >&2; exit 1; }
say() { echo "==> $*"; }

usage() {
  cat <<'EOF'
Usage: install.sh [--yes] [TARBALL]
       install.sh --uninstall
       install.sh --purge
       install.sh --help

Installs Navis into ~/.local/share/navis with a launcher in ~/.local/bin.
TARBALL is a downloaded navis-vX.Y.Z-linux.tar.gz; without it the latest
stable release is downloaded. --yes answers the install question (it never
answers questions about replacing files this script did not create).
EOF
}

cleanup() {
  local rc=$? p keep_old=0
  trap '' INT TERM HUP   # a second signal must not interrupt the restore below
  # Before the commit point only: undo what this run did. Once COMMITTED the
  # new install is the truth and nothing here may roll it back.
  if [[ ${COMMITTED} != 1 ]]; then
    if [[ -n ${OLDDIR} && ( -e ${OLDDIR}/app || -L ${OLDDIR}/app ) ]]; then
      rm -rf "${APP}" || true
      if mv "${OLDDIR}/app" "${APP}"; then
        echo "install.sh: restored the previous Navis install" >&2
      else
        keep_old=1
        echo "install.sh: could not restore the previous install; it is kept at ${OLDDIR}/app" >&2
      fi
    elif [[ ${NEW_IN_PLACE} == 1 ]]; then
      rm -rf "${APP}" || true
    fi
    for p in ${FRESH[@]+"${FRESH[@]}"}; do rm -rf -- "${p}" || true; done
    if [[ -n ${MANIFEST} ]]; then rm -f -- "${MANIFEST}.tmp" || true; fi
  fi
  if [[ -n ${OLDDIR} && ${keep_old} == 0 ]]; then
    chmod -R u+w "${OLDDIR}" 2>/dev/null || true
    rm -rf "${OLDDIR}" || echo "install.sh: could not remove ${OLDDIR}; it is safe to delete" >&2
  fi
  if [[ -n ${NEW} ]]; then rm -rf "${NEW}" || true; fi
  if [[ -n ${TMP} ]]; then rm -rf "${TMP}" || true; fi
  exit "${rc}"
}
trap cleanup EXIT

# --- prompts: always from the terminal, because stdin is the pipe in `curl | bash`
tty_open() {
  [[ -z ${TTY_OPEN:-} ]] || return 0
  if ( : <"${TTY}" ) 2>/dev/null; then exec 3<"${TTY}"; TTY_OPEN=1; return 0; fi
  return 1
}
prompt() { # TEXT -> REPLY
  tty_open || return 1
  printf '%s ' "$1" >&2
  IFS= read -r REPLY <&3 || REPLY=''
}
confirm() { # --yes answers this one
  [[ ${YES} == 1 ]] && return 0
  prompt "$1 [y/N]" || die "$1 Needs a terminal to ask; rerun with --yes."
  [[ ${REPLY} =~ ^[Yy] ]]
}
confirm_foreign() { # replacing something we did not create: --yes never answers
  prompt "$1 [y/N]" || die "$1 This needs an interactive terminal (--yes does not apply); nothing was changed."
  [[ ${REPLY} =~ ^[Yy] ]] || die "aborted; nothing was changed"
}

# --- network: transport() is the only code that talks to the network
check_url() { # URL [redirect]
  local u="$1"
  [[ ${u} != *..* ]] || die "refusing suspicious URL: ${u}"
  [[ ${u} =~ ^https://downloads\.porthorion\.com/navis/[A-Za-z0-9._/-]+$ ]] && return 0
  [[ ${u} =~ ^https://github\.com/Porthorion/Navis/releases/download/[A-Za-z0-9._/-]+$ ]] && return 0
  # GitHub serves release assets from its CDN.
  if [[ ${2:-} == redirect && ${u} =~ ^https://(objects|release-assets)\.githubusercontent\.com/[^[:space:]]+$ ]]; then return 0; fi
  die "refusing to use a URL outside the allowed hosts: ${u}"
}
transport() { # URL OUT MAX_BYTES -> prints the final URL after redirects
  curl -fsSL --proto '=https' --proto-redir '=https' --max-redirs 5 \
    --connect-timeout 20 --max-filesize "$3" \
    -A "${USER_AGENT}" -o "$2" -w '%{url_effective}' "$1"
}
# The redirect target is checked once the response is in (curl cannot veto a
# hop); integrity never rests on it, only on the signature and the SHA-256.
fetch() { # URL OUT MAX_BYTES
  local final
  check_url "$1"
  final="$(transport "$1" "$2" "$3")" || die "download failed: $1"
  check_url "${final}" redirect
}

# --- manifest: verify the signature first, then read only the verified bytes
only() { # REGEX LABEL [TEXT] -> the single match, else die
  local text="${3-${PAYLOAD}}" found
  found="$(grep -oE -- "$1" <<<"${text}" || true)"
  [[ -n ${found} && $(wc -l <<<"${found}") -eq 1 ]] || die "manifest has no single ${2} entry"
  printf '%s' "${found}"
}
verify_manifest() { # ENVELOPE_FILE -> VERSION ASSET_URL ASSET_SHA
  local envelope="$1" re payload_b64 sig_b64 pem="${TMP}/pinned.pem" obj
  re='^\{"payload":"([A-Za-z0-9+/=]+)","signature":"([A-Za-z0-9+/=]+)"\}$'
  [[ $(wc -l <"${envelope}") -le 1 && $(<"${envelope}") =~ ${re} ]] || die "malformed release manifest"
  payload_b64="${BASH_REMATCH[1]}" sig_b64="${BASH_REMATCH[2]}"
  printf '%s' "${payload_b64}" | base64 -d > "${TMP}/payload.json" 2>/dev/null || die "malformed release manifest"
  printf '%s' "${sig_b64}" | base64 -d > "${TMP}/payload.sig" 2>/dev/null || die "malformed release manifest"
  {
    echo "-----BEGIN PUBLIC KEY-----"
    { printf '\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00'; printf '%s' "${PINNED_KEY}" | base64 -d; } | base64
    echo "-----END PUBLIC KEY-----"
  } > "${pem}"
  openssl pkeyutl -verify -pubin -inkey "${pem}" -rawin -in "${TMP}/payload.json" -sigfile "${TMP}/payload.sig" >/dev/null 2>&1 \
    || die "the release manifest signature does not verify against the pinned Navis key; nothing was installed"
  PAYLOAD="$(<"${TMP}/payload.json")"
  only '"schema":1[,}]' 'schema 1' >/dev/null
  only '"channel":"stable"[,}]' 'stable channel' >/dev/null
  VERSION="$(only '"version":"[0-9]+\.[0-9]+\.[0-9]+"' version)"; VERSION="${VERSION#*:\"}"; VERSION="${VERSION%\"}"
  obj="$(only '"linuxPortable":\{[^{}]*\}' linuxPortable)"
  ASSET_URL="$(only '"url":"[^"]+"' 'linuxPortable url' "${obj}")"; ASSET_URL="${ASSET_URL#*:\"}"; ASSET_URL="${ASSET_URL%\"}"
  ASSET_SHA="$(only '"sha256":"[0-9a-f]{64}"' 'linuxPortable sha256' "${obj}")"; ASSET_SHA="${ASSET_SHA#*:\"}"; ASSET_SHA="${ASSET_SHA%\"}"
}

# --- host checks
version_ge() { [[ $(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1) == "$2" ]]; }
need_tools() {
  local t missing=()
  for t in curl openssl sha256sum tar base64 ldd; do command -v "${t}" >/dev/null 2>&1 || missing+=("${t}"); done
  [[ ${#missing[@]} -eq 0 ]] || die "missing required tools: ${missing[*]}"
  [[ $(openssl version) =~ ^OpenSSL\ ([0-9]+) && ${BASH_REMATCH[1]} -ge 3 ]] || die "OpenSSL 3 or newer is required to verify signatures"
}
check_platform() {
  local glibc
  [[ $(uname -m) == x86_64 ]] || die "Navis for Linux is built for x86_64 only (this machine is $(uname -m))"
  glibc="$(getconf GNU_LIBC_VERSION 2>/dev/null || true)"; glibc="${glibc#glibc }"
  [[ ${glibc} =~ ^[0-9]+\.[0-9]+ ]] || die "glibc 2.35 or newer is required (this system does not report glibc)"
  version_ge "${glibc}" 2.35 || die "glibc 2.35 or newer is required (found ${glibc})"
}

# Quote a path for a desktop-file Exec key only when the spec requires it
# (same rule as tool/dev_app.sh; GLib 2.88 treats unconditional quotes as part of the path).
desktop_exec_quote() {
  local value="$1"
  if [[ ${value} =~ ^[A-Za-z0-9._/=+-]+$ ]]; then printf '%s' "${value}"; return; fi
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "${value}"
}

paths() {
  [[ ${HOME:-} == /* ]] || die "HOME must be an absolute path"
  local v
  v="${XDG_DATA_HOME:-}"; [[ ${v} == /* ]] || v="${HOME}/.local/share"
  while [[ ${v} == */ && ${v} != / ]]; do v="${v%/}"; done   # never record `share//navis`
  DATA="${v}"
  v="${XDG_CONFIG_HOME:-}"; [[ ${v} == /* ]] || v="${HOME}/.config"; CONFIG="${v}"
  v="${XDG_CACHE_HOME:-}"; [[ ${v} == /* ]] || v="${HOME}/.cache"; CACHE="${v}"
  for v in "${HOME}" "${DATA}" "${CONFIG}" "${CACHE}"; do
    [[ ${v} != *[[:cntrl:]]* ]] || die "refusing a directory path with control characters"
  done
  APP="${DATA}/navis"
  DESKTOP="${DATA}/applications/${APP_ID}.desktop"
  LAUNCHER="${HOME}/.local/bin/navis"
  MANIFEST="${DATA}/navis.install-manifest"
}

# Only the paths this installer creates; a damaged or edited manifest cannot widen that.
allowed_path() {
  local p="$1"
  [[ ${p} != *..* && ${p} != *[[:cntrl:]]* ]] || return 1
  [[ ${p} == "${APP}" || ${p} == "${LAUNCHER}" || ${p} == "${DESKTOP}" ]] && return 0
  # Icons are files (or symlinks); a directory there is never ours to remove.
  [[ ${p} == "${DATA}/icons/hicolor/"?* && ( ! -d ${p} || -L ${p} ) ]]
}
refresh_caches() {
  if command -v update-desktop-database >/dev/null 2>&1; then update-desktop-database "${DATA}/applications" >/dev/null 2>&1 || true; fi
  if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -f -t -q "${DATA}/icons/hicolor" >/dev/null 2>&1 || true
  fi
}
do_uninstall() {
  local line p
  [[ -f ${MANIFEST} ]] || die "no install manifest at ${MANIFEST}; nothing to uninstall"
  # Validate every path before deleting any.
  while IFS= read -r line || [[ -n ${line} ]]; do
    [[ ${line} == "path "* ]] || continue
    allowed_path "${line#path }" || die "install manifest lists a path this installer never creates: ${line#path } (installed with a different XDG_DATA_HOME?); nothing was removed"
  done < "${MANIFEST}"
  while IFS= read -r line || [[ -n ${line} ]]; do
    [[ ${line} == "path "* ]] || continue
    p="${line#path }"
    if [[ ${p} == "${LAUNCHER}" && ( ! -L ${p} || $(readlink "${p}") != "${APP}/navis" ) && ( -e ${p} || -L ${p} ) ]]; then
      echo "left ${p}: it no longer points at this install" >&2; continue
    fi
    if [[ ${p} == "${DESKTOP}" && -f ${p} ]] && ! { sed -n 's/^Exec=//p' "${p}" | grep -qF -- "${APP}"; }; then
      echo "left ${p}: it no longer starts this install" >&2; continue
    fi
    rm -rf -- "${p}"
  done < "${MANIFEST}"
  rm -f -- "${MANIFEST}"
  refresh_caches
  say "Navis was uninstalled. Settings and data were left in place (use --purge to delete them)."
}

do_purge() {
  local d dirs=()
  for d in "${DATA}/${APP_ID}" "${CONFIG}/${APP_ID}" "${CACHE}/${APP_ID}"; do [[ -e ${d} ]] && dirs+=("${d}"); done
  [[ -f ${MANIFEST} || ${#dirs[@]} -gt 0 ]] || die "nothing to purge"
  prompt "This also permanently deletes Navis settings, cache and data: ${dirs[*]:-nothing}. That includes permanent downloads, which live in ${DATA}/${APP_ID}, a folder a .deb/.rpm install of Navis shares. Type 'purge' to continue:" \
    || die "--purge needs an interactive terminal; nothing was removed"
  [[ ${REPLY} == purge ]] || die "aborted; nothing was removed"
  if [[ -f ${MANIFEST} ]]; then do_uninstall; fi
  for d in "${dirs[@]}"; do rm -rf -- "${d}"; done
  say "Settings and data were deleted. Saved sign-ins live in your system keyring and were not touched."
}

# --- install
fetch_release() {
  local base
  if [[ -n ${TARBALL} ]]; then
    base="${TARBALL##*/}"
    [[ ${base} =~ ^navis-v([0-9]+\.[0-9]+\.[0-9]+)-linux\.tar\.gz$ ]] || die "expected a file named navis-vX.Y.Z-linux.tar.gz, got ${base}"
    [[ -f ${TARBALL} ]] || die "no such file: ${TARBALL}"
    local want="${BASH_REMATCH[1]}"
    say "Verifying release v${want}"
    fetch "${RELEASES_URL}/v${want}/manifest.json" "${TMP}/envelope.json" "${MAX_MANIFEST}"
    verify_manifest "${TMP}/envelope.json"
    [[ ${VERSION} == "${want}" ]] || die "the signed manifest is for version ${VERSION}, but the tarball is ${want}"
    # Hash and unpack a private copy, so the file cannot change after the check.
    cp -- "${TARBALL}" "${TMP}/navis.tar.gz"
    FILE="${TMP}/navis.tar.gz"
  else
    say "Reading the signed stable release manifest"
    fetch "${STABLE_MANIFEST_URL}" "${TMP}/envelope.json" "${MAX_MANIFEST}"
    verify_manifest "${TMP}/envelope.json"
    say "Downloading Navis ${VERSION}"
    fetch "${ASSET_URL}" "${TMP}/navis.tar.gz" "${MAX_TARBALL}"
    FILE="${TMP}/navis.tar.gz"
  fi
  local got
  got="$(sha256sum < "${FILE}")"; got="${got%% *}"
  [[ ${got} == "${ASSET_SHA}" ]] || die "the tarball's SHA-256 does not match the signed manifest; nothing was installed"
}

listed() { [[ -f ${MANIFEST} ]] && grep -qxF -- "path $1" "${MANIFEST}"; }

check_existing() {
  local installed=''
  if [[ -f ${MANIFEST} ]]; then
    installed="$(sed -n 's/^version //p' "${MANIFEST}" | head -n1)"
  elif [[ -e ${APP} || -L ${APP} ]]; then
    confirm_foreign "${APP} exists but was not created by this installer. Replace it?"
  fi
  if [[ -e ${LAUNCHER} || -L ${LAUNCHER} ]] && [[ $(readlink "${LAUNCHER}" 2>/dev/null || true) != "${APP}/navis" ]]; then
    confirm_foreign "${LAUNCHER} exists and does not point at this install. Replace it?"
  fi
  # tool/dev_app.sh writes this same file name for development builds.
  if [[ -e ${DESKTOP} || -L ${DESKTOP} ]] && ! listed "${DESKTOP}"; then
    confirm_foreign "${DESKTOP} exists and was not created by this installer. Replace it?"
  fi
  if [[ -x ${SYSTEM_APP} ]]; then
    confirm "A system package install of Navis exists at ${SYSTEM_APP}. Add a separate per-user copy anyway?" || die "aborted"
  fi
  if [[ -n ${installed} && ${installed} != "${VERSION}" ]] && version_ge "${installed}" "${VERSION}"; then
    echo "warning: this is an older release (${VERSION}) than the installed ${installed}; installing it anyway" >&2
  fi
  confirm "Install Navis ${VERSION} into ${APP}?" || die "aborted; nothing was changed"
}

unpack() {
  local listing missing d
  listing="$(tar -tzf "${FILE}")" || die "cannot read the tarball"
  if grep -Eq '(^|/)\.\.(/|$)|^/' <<<"${listing}"; then die "the tarball contains unsafe paths"; fi
  mkdir -p "${DATA}"
  # An interrupted earlier run can leave the previous install parked beside the app dir.
  for d in "${APP}".old.*; do
    if [[ -e ${d}/app && ! -e ${APP} && ! -L ${APP} ]]; then mv "${d}/app" "${APP}"; fi
    rmdir "${d}" 2>/dev/null || true
  done
  # Unique sibling names: a user's own navis.new / navis.old must never be touched.
  NEW="$(mktemp -d "${APP}.new.XXXXXX")"
  OLDDIR="$(mktemp -d "${APP}.old.XXXXXX")"
  chmod 755 "${NEW}"
  tar -xzf "${FILE}" -C "${NEW}" --no-same-owner
  [[ -f ${NEW}/navis && -x ${NEW}/navis && ! -L ${NEW}/navis && -d ${NEW}/lib && -f ${NEW}/data/${APP_ID}.desktop ]] \
    || die "the tarball does not look like a Navis bundle"
  missing="$(LD_LIBRARY_PATH="${NEW}/lib" ldd "${NEW}/navis" 2>&1 | grep 'not found' || true)"
  if [[ -n ${missing} ]]; then
    printf '%s\n' "${missing}" >&2
    die "shared libraries are missing (listed above). Debian/Ubuntu: sudo apt install libgtk-3-0 libsecret-1-0 libpulse0 libasound2 (libasound2t64 on newer releases). Fedora: sudo dnf install gtk3 libsecret pulseaudio-libs alsa-lib"
  fi
}

# State flips only after each move succeeds, so cleanup() can tell what to undo.
swap_in() {
  if [[ -e ${APP} || -L ${APP} ]]; then mv "${APP}" "${OLDDIR}/app"; fi
  mv "${NEW}" "${APP}"
  NEW=''; NEW_IN_PLACE=1
}

track() { # PATH: record for the manifest; remember it for cleanup if it is new
  CREATED+=("$1")
  if [[ ! -e $1 && ! -L $1 ]]; then FRESH+=("$1"); fi
}

integrate() {
  local exec_quoted line f rel staged
  mkdir -p "$(dirname "${LAUNCHER}")" "${DATA}/applications"
  # A symlink, not a wrapper: the in-app updater replaces the directory that
  # holds the resolved executable, which must be the app dir.
  track "${LAUNCHER}"
  ln -sfn "${APP}/navis" "${LAUNCHER}"
  # GLib 2.88+ refuses a desktop file whose Exec is not an absolute path or found in PATH.
  exec_quoted="$(desktop_exec_quote "${APP}/navis")"
  # Write a sibling and rename it over the target, so a symlink there is replaced, never followed.
  staged="$(mktemp "${DESKTOP}.XXXXXX")"
  FRESH+=("${staged}")
  while IFS= read -r line || [[ -n ${line} ]]; do
    case "${line}" in
      Exec=*) printf 'Exec=%s %%U\nTryExec=%s\n' "${exec_quoted}" "${APP}/navis" ;;
      TryExec=*) ;;
      *) printf '%s\n' "${line}" ;;
    esac
  done < "${APP}/data/${APP_ID}.desktop" > "${staged}"
  chmod 644 "${staged}"
  track "${DESKTOP}"
  mv -f "${staged}" "${DESKTOP}"
  while IFS= read -r -d '' f; do
    rel="${f#"${APP}/data/icons/hicolor/"}"
    track "${DATA}/icons/hicolor/${rel}"
    install -Dm644 "${f}" "${DATA}/icons/hicolor/${rel}"
  done < <(find "${APP}/data/icons/hicolor" -type f -print0 2>/dev/null)
  CREATED+=("${APP}")
  {
    echo "# Written by the Navis installer; --uninstall removes exactly the paths below."
    echo "version ${VERSION}"
    printf 'path %s\n' "${CREATED[@]}"
  } > "${MANIFEST}.tmp"
  mv "${MANIFEST}.tmp" "${MANIFEST}"
  COMMITTED=1; NEW_IN_PLACE=0
  # Past the commit point, removing the parked copy is best-effort: a read-only
  # subdir or a signal here must never bring the old install back.
  chmod -R u+w "${OLDDIR}" 2>/dev/null || true
  rm -rf "${OLDDIR}" || echo "warning: could not remove the previous copy at ${OLDDIR}; it is safe to delete" >&2
  OLDDIR=''
  refresh_caches
}

install_main() {
  need_tools
  check_platform
  TMP="$(mktemp -d "${TMPDIR:-/tmp}/navis-install.XXXXXX")"
  fetch_release
  check_existing
  unpack
  swap_in
  integrate
  say "Navis ${VERSION} is installed in ${APP}"
  case ":${PATH}:" in
    *":${HOME}/.local/bin:"*) ;;
    *) echo "note: ${HOME}/.local/bin is not on your PATH; start Navis from the app menu or add it to PATH." >&2 ;;
  esac
  if command -v apt-get >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1; then
    echo "tip: the .deb/.rpm packages on the releases page also keep Navis updated through your package manager." >&2
  fi
}

main() {
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --yes|-y) YES=1 ;;
      --uninstall) MODE=uninstall ;;
      --purge) MODE=purge ;;
      --help|-h) usage; exit 0 ;;
      -*) usage >&2; die "unknown option: ${arg}" ;;
      *) [[ -z ${TARBALL} ]] || die "only one tarball can be given"; TARBALL="${arg}" ;;
    esac
  done
  [[ $(id -u) != 0 ]] || die "run this as your own user, not root: it installs under your home directory"
  paths
  case "${MODE}" in
    uninstall) do_uninstall ;;
    purge) do_purge ;;
    *) install_main ;;
  esac
}

main "$@"
exit $?
}
