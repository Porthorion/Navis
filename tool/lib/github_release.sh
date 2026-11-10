#!/usr/bin/env bash
# Shared by release.sh and late r2_publish.sh additions. Call only after R2 verifies.

navis_github_preflight() {
  local tag="$1" allow_existing="$2" remote
  command -v gh >/dev/null || { echo 'Error: gh is required for GitHub updates.' >&2; return 1; }
  gh auth status >/dev/null 2>&1 || { echo 'Error: gh authentication is required for GitHub updates.' >&2; return 1; }
  remote="$(git remote get-url github)" || { echo 'Error: a github remote is required.' >&2; return 1; }
  local repo="${NAVIS_GITHUB_REPO:-Porthorion/Navis}"
  case "${remote}" in
    "https://github.com/${repo}"|"https://github.com/${repo}.git"|"git@github.com:${repo}"|"git@github.com:${repo}.git"|"ssh://git@github.com/${repo}"|"ssh://git@github.com/${repo}.git") ;;
    *) echo 'Error: github remote does not match the release repository.' >&2; return 1 ;;
  esac
  if gh release view "${tag}" --repo "${repo}" --json tagName >/dev/null 2>&1 && [[ "${allow_existing}" != true ]]; then
    echo "Error: GitHub release ${tag} already exists; use --allow-existing-version for additions." >&2
    return 1
  fi
}

navis_github_verify_manifest() {
  local tag="$1" manifest="$2" downloaded
  [[ "${tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-(dev|staging)\.[1-9][0-9]*)?$ ]] || { echo 'Error: invalid GitHub release tag.' >&2; return 1; }
  downloaded="$(mktemp)"
  local url="https://github.com/${NAVIS_GITHUB_REPO:-Porthorion/Navis}/releases/download/${tag}/manifest.json"
  local headers status location hop
  headers="$(mktemp)"
  for hop in 0 1 2 3 4 5; do
    if ! python3 - "${url}" "${NAVIS_GITHUB_REPO:-Porthorion/Navis}" <<'PYURL'
import sys
from urllib.parse import urlsplit, unquote
u = urlsplit(sys.argv[1])
allowed = (u.hostname == 'github.com' and u.path.startswith('/' + sys.argv[2] + '/releases/download/')) or u.hostname in ('objects.githubusercontent.com', 'release-assets.githubusercontent.com')
if not (u.scheme == 'https' and u.port in (None, 443) and not u.username and not u.password and not u.fragment and allowed):
    raise SystemExit('Error: GitHub manifest redirect outside allowed hosts.')
if any(part in ('.', '..') or '/' in part or '\\' in part for part in map(unquote, u.path.split('/'))):
    raise SystemExit('Error: invalid GitHub redirect path.')
PYURL
    then rm -f "${downloaded}" "${headers}"; return 1; fi
    if ! status="$(curl -sS --proto '=https' --max-redirs 0 -D "${headers}" -w '%{http_code}' "${url}" -o "${downloaded}")"; then
      rm -f "${downloaded}" "${headers}"; return 1
    fi
    case "${status}" in
      200) break ;;
      301|302|303|307|308)
        location="$(awk 'tolower($1) == "location:" {sub(/^[^:]*:[[:space:]]*/, ""); sub(/\r$/, ""); print; exit}' "${headers}")"
        if [[ -z "${location}" || "${hop}" == 5 ]]; then rm -f "${downloaded}" "${headers}"; return 1; fi
        url="$(python3 - "${url}" "${location}" <<'PYJOIN'
import sys
from urllib.parse import urljoin
print(urljoin(sys.argv[1], sys.argv[2]))
PYJOIN
)"
        ;;
      *) rm -f "${downloaded}" "${headers}"; echo "Error: GitHub manifest HTTP ${status}." >&2; return 1 ;;
    esac
  done
  rm -f "${headers}"
  if ! cmp -s "${manifest}" "${downloaded}"; then
    rm -f "${downloaded}"
    echo 'Error: GitHub and verified R2 manifest bytes differ.' >&2
    return 1
  fi
  rm -f "${downloaded}"
  echo '    GitHub and verified R2 manifest bytes match.'
}

navis_github_publish() {
  local tag="$1" prerelease="$2" notes="$3" manifest="$4"
  shift 4
  [[ "$(basename "${manifest}")" == manifest.json && -s "${manifest}" ]] || {
    echo 'Error: a verified manifest.json is required.' >&2; return 1;
  }
  local repo="${NAVIS_GITHUB_REPO:-Porthorion/Navis}" asset name size release
  local assets=("$@") args
  # Stable releases also carry the per-user installer. It is not an updater
  # asset: the signed manifest and R2 stay untouched; only the GitHub
  # SHA256SUMS gains its line. The installer is attached once, when the release
  # is created: a late-asset run (--clobber) must neither replace it with a
  # newer checkout's copy nor drop its SHA256SUMS line, so it re-derives the
  # line from the asset already on the release.
  local installer="$(dirname "${BASH_SOURCE[0]}")/../../linux/install.sh" sums='' installer_sum exists=false
  for asset in "$@"; do [[ "$(basename "${asset}")" != SHA256SUMS ]] || sums="${asset}"; done
  if gh release view "${tag}" --repo "${repo}" --json tagName >/dev/null 2>&1; then
    exists=true
    release="$(gh release view "${tag}" --repo "${repo}" --json assets)" || return 1
    if jq -e '[.assets[] | select(.name == "install.sh")] | length > 0' <<< "${release}" >/dev/null; then
      installer_sum="$(gh release download "${tag}" --repo "${repo}" --pattern install.sh --output - | sha256sum | cut -d' ' -f1)" || return 1
      installer=''
    fi
  fi
  if [[ -n "${installer}" ]]; then
    [[ -f "${installer}" ]] || { echo "Error: ${installer} is missing." >&2; return 1; }
    # Bake the released version in as the installer's minimum, so a replayed older signed
    # manifest is refused. The upload keeps the file name install.sh.
    local min="${tag#v}" stamped
    min="${min%%-*}"
    stamped="$(dirname "${manifest}")/install.sh"   # the release work dir, cleaned up with it
    sed "s/^NAVIS_MIN_VERSION=.*/NAVIS_MIN_VERSION='${min}'/" "${installer}" > "${stamped}"
    grep -qx "NAVIS_MIN_VERSION='${min}'" "${stamped}" || { echo 'Error: install.sh has no NAVIS_MIN_VERSION line to fill.' >&2; return 1; }
    installer="${stamped}"
    installer_sum="$(sha256sum < "${installer}" | cut -d' ' -f1)"
    assets+=("${installer}")
  fi
  if [[ -n "${sums}" ]]; then
    { grep -v '  install.sh$' "${sums}" || true; printf '%s  install.sh\n' "${installer_sum}"; } \
      | sort -k2 > "${sums}.new" && mv "${sums}.new" "${sums}"
  fi
  assets+=("${manifest}")
  if [[ "${exists}" == true ]]; then
    args=(release upload "${tag}" --repo "${repo}" --clobber)
  else
    args=(release create "${tag}" --repo "${repo}" --title "Navis ${tag}" --notes-file "${notes}")
    [[ "${prerelease}" != true ]] || args+=(--prerelease)
  fi
  gh "${args[@]}" "${assets[@]}" || return 1
  release="$(gh release view "${tag}" --repo "${repo}" --json assets)" || return 1
  for asset in "${assets[@]}"; do
    name="$(basename "${asset}")"
    size="$(wc -c < "${asset}" | tr -d ' ')"
    jq -e --arg name "${name}" --argjson size "${size}" \
      '[.assets[] | select(.name == $name and .size == $size)] | length == 1' <<< "${release}" >/dev/null || {
      echo "Error: GitHub asset missing or size mismatch: ${name}" >&2; return 1;
    }
  done
  local payload
  payload="$(jq -er '.payload' "${manifest}" | base64 -d)" || return 1
  while IFS=$'\t' read -r name size; do
    jq -e --arg name "${name}" --argjson size "${size}" \
      '[.assets[] | select(.name == $name and .size == $size)] | length == 1' <<< "${release}" >/dev/null || {
      echo "Error: GitHub mirror lacks signed asset: ${name}" >&2; return 1;
    }
  done < <(jq -r '.assets | to_entries[] | [(.value.url | split("/") | last), .value.size] | @tsv' <<< "${payload}")
  navis_github_verify_manifest "${tag}" "${manifest}"
}
