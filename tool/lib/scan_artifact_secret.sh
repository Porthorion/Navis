#!/usr/bin/env bash
# Sourced helper: fail a release when a plaintext secret ships in an artifact.
#
# scan_artifact_for_secret <artifact> <secret>
#   <artifact> is a file or a directory. Archives are unpacked and searched
#   recursively (up to 4 levels): zip/apk/aab/ipa/jar, tar and compressed tar
#   (gz, xz, zstd, bzip2) and deb. Returns 0 when the secret is absent, 1 when
#   it is found (the artifact path is reported, never the secret) and 2 when
#   the scan itself cannot run or finish: empty secret, missing artifact, an
#   archive that cannot be unpacked (corrupt, or its decompressor is missing),
#   or nesting deeper than the cap. A tool failure is never read as "clean".
#
# The secret is handed to grep through process substitution, so it is on
# neither argv nor disk.

_scan_secret_max_depth=4

# _scan_secret_grep <secret> <path>   (0 = found)
_scan_secret_grep() {
  if [[ -d "$2" ]]; then
    grep -raFq -f <(printf '%s\n' "$1") -- "$2"
  else
    grep -aFq -f <(printf '%s\n' "$1") -- "$2"
  fi
}

# _scan_secret_unpack <archive> <dest>   (returns 0 when unpacked, 3 when the
# file is not an archive type this scanner unpacks, 2 on an unpack failure)
_scan_secret_unpack() {
  local archive="$1" dest="$2" lower base
  lower="$(printf '%s' "${archive}" | tr '[:upper:]' '[:lower:]')"
  base="$(basename "${lower}")"
  case "${lower}" in
    *.zip | *.apk | *.aab | *.ipa | *.jar)
      command -v unzip >/dev/null 2>&1 || return 2
      # unzip exits 1 for warnings (e.g. duplicate names); anything higher
      # means the archive was not read.
      local status=0
      unzip -q -o -d "${dest}" "${archive}" >/dev/null 2>&1 || status=$?
      [[ ${status} -le 1 ]] || return 2
      return 0
      ;;
    *.tar | *.tar.gz | *.tgz | *.tar.xz | *.txz | *.tar.zst | *.tzst | \
      *.tar.bz2 | *.tbz2)
      # tar detects the compression itself; a missing decompressor fails it.
      tar -xf "${archive}" -C "${dest}" >/dev/null 2>&1 || return 2
      return 0
      ;;
    *.deb)
      if command -v dpkg-deb >/dev/null 2>&1; then
        dpkg-deb -x "${archive}" "${dest}" >/dev/null 2>&1 || return 2
      else
        command -v ar >/dev/null 2>&1 || return 2
        local abs
        abs="$(cd "$(dirname "${archive}")" && pwd)/$(basename "${archive}")"
        (cd "${dest}" && ar x "${abs}") >/dev/null 2>&1 || return 2
      fi
      return 0
      ;;
  esac
  # Members `ar x` pulls out of a deb (data.tar.xz, control.tar.zst, ...) are
  # tarballs whatever their suffix; failing to read one must not read as clean.
  case "${base}" in
    data.tar.* | control.tar.*)
      tar -xf "${archive}" -C "${dest}" >/dev/null 2>&1 || return 2
      return 0
      ;;
  esac
  return 3
}

# _scan_secret_walk <secret> <path> <label> <depth>
_scan_secret_walk() {
  local secret="$1" path="$2" label="$3" depth="$4"

  local grep_status=0
  _scan_secret_grep "${secret}" "${path}" || grep_status=$?
  case "${grep_status}" in
    0) echo "scan: plaintext secret found in ${label}" >&2; return 1 ;;
    1) ;;
    *) echo "scan: could not read ${label}; refusing to call it clean." >&2; return 2 ;;
  esac

  # Directories: look inside every nested archive.
  if [[ -d "${path}" ]]; then
    local nested status=0 listing
    listing="$(mktemp "${TMPDIR:-/tmp}/navis-scan-list-XXXXXX")" || return 2
    if ! find "${path}" -type f \( -iname '*.zip' -o -iname '*.apk' \
      -o -iname '*.aab' -o -iname '*.ipa' -o -iname '*.jar' -o -iname '*.tar' \
      -o -iname '*.tar.gz' -o -iname '*.tgz' -o -iname '*.tar.xz' \
      -o -iname '*.txz' -o -iname '*.tar.zst' -o -iname '*.tzst' \
      -o -iname '*.tar.bz2' -o -iname '*.tbz2' -o -iname '*.deb' \
      -o -name 'data.tar.*' -o -name 'control.tar.*' \) -print0 >"${listing}"; then
      rm -f "${listing}"
      return 2
    fi
    while IFS= read -r -d '' nested; do
      _scan_secret_walk "${secret}" "${nested}" "${label}!${nested#"${path}"/}" \
        "${depth}" || status=$?
      [[ ${status} -eq 0 ]] || break
    done <"${listing}"
    rm -f "${listing}" || return 2
    return "${status}"
  fi

  if [[ "${depth}" -ge "${_scan_secret_max_depth}" ]]; then
    echo "scan: ${label} is nested more than ${_scan_secret_max_depth} archives deep; refusing to call it clean." >&2
    return 2
  fi

  local unpacked unpack_status=0
  unpacked="$(mktemp -d "${TMPDIR:-/tmp}/navis-scan-XXXXXX")" || return 2
  _scan_secret_unpack "${path}" "${unpacked}" || unpack_status=$?
  case "${unpack_status}" in
    0)
      local walk_status=0
      _scan_secret_walk "${secret}" "${unpacked}" "${label}" \
        "$((depth + 1))" || walk_status=$?
      rm -rf "${unpacked}" || return 2
      return "${walk_status}"
      ;;
    3)
      rm -rf "${unpacked}" || return 2
      return 0
      ;;
    *)
      rm -rf "${unpacked}" || return 2
      echo "scan: could not unpack ${label}; refusing to call it clean." >&2
      return 2
      ;;
  esac
}

scan_artifact_for_secret() {
  local artifact="${1-}" secret="${2-}"
  if [[ -z "${secret}" ]]; then
    echo "scan: no secret supplied; nothing to scan for." >&2
    return 2
  fi
  if [[ ! -e "${artifact}" ]]; then
    echo "scan: artifact not found: ${artifact}" >&2
    return 2
  fi
  _scan_secret_walk "${secret}" "${artifact}" "${artifact}" 0
}
