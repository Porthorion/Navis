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
  local assets=("$@" "${manifest}") args
  if gh release view "${tag}" --repo "${repo}" --json tagName >/dev/null 2>&1; then
    args=(release upload "${tag}" --repo "${repo}" --clobber)
  else
    args=(release create "${tag}" --repo "${repo}" --title "Navis ${tag}" --notes-file "${notes}")
    [[ "${prerelease}" != true ]] || args+=(--prerelease)
  fi
  gh "${args[@]}" "${assets[@]}" || return 1
  release="$(gh release view "${tag}" --repo "${repo}" --json assets)" || return 1
  for asset in "${assets[@]}"; do
    name="$(basename "${asset}")"
    size="$(wc -c < "${asset}")"
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
