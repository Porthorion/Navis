#!/usr/bin/env bash
# Sourced helper: fail a release when a plaintext secret ships in an artifact.
#
# scan_artifact_for_secret <artifact> <secret>
#   <artifact> is a file or a directory. Archives are unpacked and searched
#   recursively (up to 4 levels): zip/apk/aab/ipa/jar, tar/tar.gz/tgz and deb.
#   Returns 0 when the secret is absent, 1 when it is found (the artifact path
#   is reported, never the secret) and 2 when the scan itself cannot run (empty
#   secret, missing artifact, or an archive that cannot be unpacked), so a tool
#   failure is never read as "clean".
#
# The secret is handed to grep through a private pattern file, not argv.

_scan_secret_max_depth=4

# _scan_secret_grep <pattern-file> <path>   (0 = found)
_scan_secret_grep() {
  if [[ -d "$2" ]]; then
    grep -raFq -f "$1" -- "$2"
  else
    grep -aFq -f "$1" -- "$2"
  fi
}

# _scan_secret_unpack <archive> <dest>   (returns 0 when unpacked, 3 when the
# file is not an archive type this scanner unpacks, 2 on an unpack failure)
_scan_secret_unpack() {
  local archive="$1" dest="$2" lower
  lower="$(printf '%s' "${archive}" | tr '[:upper:]' '[:lower:]')"
  case "${lower}" in
    *.zip | *.apk | *.aab | *.ipa | *.jar)
      command -v unzip >/dev/null 2>&1 || return 2
      # unzip exits 1 for warnings (e.g. duplicate names); anything higher
      # means the archive was not read.
      local status=0
      unzip -q -o -d "${dest}" "${archive}" >/dev/null 2>&1 || status=$?
      [[ ${status} -le 1 ]] || return 2
      ;;
    *.tar.gz | *.tgz | *.tar)
      tar -xf "${archive}" -C "${dest}" >/dev/null 2>&1 || return 2
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
      ;;
    *)
      return 3
      ;;
  esac
}

# _scan_secret_walk <pattern-file> <path> <label> <depth>
_scan_secret_walk() {
  local patterns="$1" path="$2" label="$3" depth="$4"

  if _scan_secret_grep "${patterns}" "${path}"; then
    echo "scan: plaintext secret found in ${label}" >&2
    return 1
  fi

  # Directories: look inside every nested archive.
  if [[ -d "${path}" ]]; then
    local nested status=0
    while IFS= read -r -d '' nested; do
      _scan_secret_walk "${patterns}" "${nested}" "${label}!${nested#"${path}"/}" \
        "${depth}" || status=$?
      [[ ${status} -eq 0 ]] || return "${status}"
    done < <(find "${path}" -type f \( -iname '*.zip' -o -iname '*.apk' \
      -o -iname '*.aab' -o -iname '*.ipa' -o -iname '*.jar' -o -iname '*.tar' \
      -o -iname '*.tar.gz' -o -iname '*.tgz' -o -iname '*.deb' \) -print0)
    return 0
  fi

  if [[ "${depth}" -ge "${_scan_secret_max_depth}" ]]; then
    return 0
  fi

  local unpacked unpack_status=0
  unpacked="$(mktemp -d "${TMPDIR:-/tmp}/navis-scan-XXXXXX")"
  _scan_secret_unpack "${path}" "${unpacked}" || unpack_status=$?
  case "${unpack_status}" in
    0)
      local walk_status=0
      _scan_secret_walk "${patterns}" "${unpacked}" "${label}" \
        "$((depth + 1))" || walk_status=$?
      rm -rf "${unpacked}"
      return "${walk_status}"
      ;;
    3)
      rm -rf "${unpacked}"
      return 0
      ;;
    *)
      rm -rf "${unpacked}"
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

  local patterns status=0
  patterns="$(umask 077 && mktemp "${TMPDIR:-/tmp}/navis-scan-pattern-XXXXXX")"
  printf '%s\n' "${secret}" >"${patterns}"
  _scan_secret_walk "${patterns}" "${artifact}" "${artifact}" 0 || status=$?
  rm -f "${patterns}"
  return "${status}"
}
