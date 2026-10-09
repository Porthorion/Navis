#!/usr/bin/env bash
# tool/r2_publish.sh — publish Navis update artifacts and a signed manifest to R2.
#
# Navis 1.5.0+ reads https://downloads.porthorion.com/navis/channels/<channel>/manifest.json.
# See docs/release-r2.md for the bucket layout, manifest schema and key handling.
#
# Usage:
#   ./tool/r2_publish.sh publish --tag=<vX.Y.Z> --channel=<stable|dev|staging> [--notes-file=<md>] FILE...
#   ./tool/r2_publish.sh verify  --channel=<stable|dev|staging>
#   ./tool/r2_publish.sh check   --tag=<vX.Y.Z> --channel=<stable|dev|staging>
#
# publish uploads each FILE to navis/releases/<tag>/ (never overwriting a different
# file), rewrites SHA256SUMS, then signs and uploads the channel manifest last, and
# finally runs verify. Re-running the same publish is safe: identical files are skipped.
# Publishing more files for the tag the channel already points at (for example the
# Windows installer after the Linux run) adds them to that manifest.
# verify downloads the public manifest, checks its signature against the key pinned in
# lib/src/utils/constants.dart, and checks every asset's size and SHA-256.
# check runs publish's preconditions only (settings, signing key, channel order);
# release.sh runs it before building and tagging.
#
# Settings come from tool/release.env: R2_ACCOUNT_ID, R2_BUCKET, R2_PREFIX,
# R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, NAVIS_UPDATE_SIGNING_KEY (publish and check).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUBLIC_BASE="https://downloads.porthorion.com"

usage() {
  sed -n '7,10p' "${BASH_SOURCE[0]}" | sed 's/^# //'
  exit 1
}

MODE="${1:-}"
[[ "${MODE}" =~ ^(publish|verify|check)$ ]] || usage
shift

TAG=""
CHANNEL=""
NOTES_FILE=""
FILES=()
for arg in "$@"; do
  case "${arg}" in
    --tag=*) TAG="${arg#--tag=}" ;;
    --channel=*) CHANNEL="${arg#--channel=}" ;;
    --notes-file=*) NOTES_FILE="${arg#--notes-file=}" ;;
    --*) echo "Unknown option: ${arg}" >&2; usage ;;
    *) FILES+=("${arg}") ;;
  esac
done

[[ "${CHANNEL}" =~ ^[a-z]+$ ]] || { echo "Error: --channel must be lowercase letters (stable, dev, staging)." >&2; exit 1; }

if [[ -f "${SCRIPT_DIR}/release.env" ]]; then
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/release.env"
fi
: "${R2_PREFIX:=navis}"
PUBLIC_ROOT="${PUBLIC_BASE}/${R2_PREFIX}"
MANIFEST_KEY="channels/${CHANNEL}/manifest.json"

for tool in curl jq openssl sha256sum base64; do
  command -v "${tool}" >/dev/null || { echo "Error: '${tool}' is required." >&2; exit 1; }
done

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

# The Ed25519 public key the app trusts (base64 of the raw 32 bytes).
pinned_public_key() {
  # dart format may wrap the value onto the next line.
  grep -A1 'updateSigningPublicKey *=' "${SCRIPT_DIR}/../lib/src/utils/constants.dart" \
    | grep -o "'[A-Za-z0-9+/=]*'" | head -1 | tr -d "'"
}

# Writes a PEM public key for openssl from a base64 raw Ed25519 key.
write_public_pem() {
  local raw_b64="$1" out="$2"
  {
    echo "-----BEGIN PUBLIC KEY-----"
    { printf '\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00'; echo -n "${raw_b64}" | base64 -d; } | base64
    echo "-----END PUBLIC KEY-----"
  } > "${out}"
}

# ─── S3 API helpers (curl SigV4; R2 region is "auto") ───────────────────────
s3_url() { echo "https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com/${R2_BUCKET}/${R2_PREFIX}/$1"; }
s3_curl() {
  curl -sS --aws-sigv4 "aws:amz:auto:s3" --user "${R2_ACCESS_KEY_ID}:${R2_SECRET_ACCESS_KEY}" "$@"
}

# Prints the sha256 recorded on an existing object, "none" when the object is
# absent, or fails on any other response.
remote_sha256() {
  local headers status
  headers="$(s3_curl -I "$(s3_url "$1")")"
  status="$(echo "${headers}" | head -1 | awk '{print $2}')"
  case "${status}" in
    200) echo "${headers}" | tr -d '\r' | awk -F': ' 'tolower($1)=="x-amz-meta-sha256"{print $2}' | grep . || echo "unknown" ;;
    404) echo "none" ;;
    *) echo "Error: HEAD $1 returned ${status}" >&2; return 1 ;;
  esac
}

upload() {
  local file="$1" key="$2" content_type="$3" cache_control="$4" sha="$5" status
  status="$(s3_curl -o "${WORK_DIR}/upload.out" -w '%{http_code}' -T "${file}" \
    -H "Content-Type: ${content_type}" \
    -H "Cache-Control: ${cache_control}" \
    -H "x-amz-meta-sha256: ${sha}" \
    "$(s3_url "${key}")")"
  if [[ "${status}" != "200" ]]; then
    echo "Error: upload of ${key} failed (${status}): $(cat "${WORK_DIR}/upload.out")" >&2
    return 1
  fi
}

content_type_for() {
  case "$1" in
    *.apk) echo "application/vnd.android.package-archive" ;;
    *.exe) echo "application/vnd.microsoft.portable-executable" ;;
    *.zip) echo "application/zip" ;;
    *.deb) echo "application/vnd.debian.binary-package" ;;
    *.tar.gz) echo "application/gzip" ;;
    *) echo "application/octet-stream" ;;
  esac
}

# Manifest asset key for a release file name (matches UpdateInstallMode names).
asset_key_for() {
  case "$1" in
    *.apk) echo "androidApk" ;;
    *-windows-installer.exe) echo "windowsInstaller" ;;
    *-windows.zip) echo "windowsPortable" ;;
    *-macos.zip) echo "macosBundle" ;;
    *-linux-amd64.deb) echo "linuxDeb-amd64" ;;
    *-linux-arm64.deb) echo "linuxDeb-arm64" ;;
    *-linux.tar.gz) echo "linuxPortable" ;;
    *) echo "" ;;
  esac
}

semver_core() { local v="${1#v}"; v="${v%%[-+]*}"; echo "${v}"; }
# Succeeds when $1 > $2 (semver core).
semver_gt() {
  [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" == "$1" ]]
}

verify() {
  local pinned
  pinned="$(pinned_public_key)"
  [[ -n "${pinned}" ]] || { echo "Error: updateSigningPublicKey not found in constants.dart" >&2; return 1; }
  write_public_pem "${pinned}" "${WORK_DIR}/pinned.pem"

  echo "==> Verifying ${PUBLIC_ROOT}/${MANIFEST_KEY}"
  curl -sSf -H 'Cache-Control: no-cache' "${PUBLIC_ROOT}/${MANIFEST_KEY}?v=$(date +%s)" -o "${WORK_DIR}/envelope.json"
  jq -r '.payload' "${WORK_DIR}/envelope.json" | base64 -d > "${WORK_DIR}/verify-payload.json"
  jq -r '.signature' "${WORK_DIR}/envelope.json" | base64 -d > "${WORK_DIR}/verify-sig.bin"
  openssl pkeyutl -verify -pubin -inkey "${WORK_DIR}/pinned.pem" -rawin \
    -in "${WORK_DIR}/verify-payload.json" -sigfile "${WORK_DIR}/verify-sig.bin" >/dev/null \
    || { echo "Error: manifest signature does not verify against the pinned key." >&2; return 1; }
  echo "    signature OK"

  local payload_channel
  payload_channel="$(jq -r '.channel' "${WORK_DIR}/verify-payload.json")"
  [[ "${payload_channel}" == "${CHANNEL}" ]] || { echo "Error: manifest channel is ${payload_channel}" >&2; return 1; }
  echo "    version $(jq -r '.version' "${WORK_DIR}/verify-payload.json"), channel ${payload_channel}"

  local failed=0 key url sha size
  while IFS=$'\t' read -r key url sha size; do
    if [[ "${url}" != "${PUBLIC_ROOT}/"* ]]; then
      echo "    ${key}: FAIL url is not under ${PUBLIC_ROOT}/"; failed=1; continue
    fi
    # The query string bypasses the edge cache so the origin object is checked.
    curl -sSf "${url}?verify=$(date +%s)" -o "${WORK_DIR}/asset"
    local got_sha got_size
    got_sha="$(sha256sum "${WORK_DIR}/asset" | awk '{print $1}')"
    got_size="$(stat -c %s "${WORK_DIR}/asset")"
    if [[ "${got_sha}" == "${sha}" && "${got_size}" == "${size}" ]]; then
      echo "    ${key}: OK (${size} bytes)"
    else
      echo "    ${key}: FAIL sha/size mismatch"; failed=1
    fi
    rm -f "${WORK_DIR}/asset"
  done < <(jq -r '.assets | to_entries[] | [.key, .value.url, .value.sha256, (.value.size|tostring)] | @tsv' "${WORK_DIR}/verify-payload.json")
  [[ "${failed}" == "0" ]] || { echo "Error: verification failed." >&2; return 1; }
  echo "==> Verified."
}

if [[ "${MODE}" == "verify" ]]; then
  verify
  exit 0
fi

# ─── Publish ────────────────────────────────────────────────────────────────
[[ "${TAG}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Error: --tag must look like v1.5.1" >&2; exit 1; }
[[ "${MODE}" == "check" ]] || (( ${#FILES[@]} > 0 )) || { echo "Error: no files given." >&2; exit 1; }
: "${R2_ACCOUNT_ID:?Set R2_ACCOUNT_ID in tool/release.env}"
: "${R2_BUCKET:?Set R2_BUCKET in tool/release.env}"
: "${R2_ACCESS_KEY_ID:?Set R2_ACCESS_KEY_ID in tool/release.env}"
: "${R2_SECRET_ACCESS_KEY:?Set R2_SECRET_ACCESS_KEY in tool/release.env}"
: "${NAVIS_UPDATE_SIGNING_KEY:?Set NAVIS_UPDATE_SIGNING_KEY in tool/release.env}"
[[ -r "${NAVIS_UPDATE_SIGNING_KEY}" ]] || { echo "Error: cannot read ${NAVIS_UPDATE_SIGNING_KEY}" >&2; exit 1; }

# Refuse to sign with a key the app does not trust.
SIGNING_PUB="$(openssl pkey -in "${NAVIS_UPDATE_SIGNING_KEY}" -pubout -outform DER | tail -c 32 | base64)"
if [[ "${SIGNING_PUB}" != "$(pinned_public_key)" ]]; then
  echo "Error: NAVIS_UPDATE_SIGNING_KEY does not match updateSigningPublicKey in constants.dart." >&2
  exit 1
fi

VERSION="$(semver_core "${TAG}")"

# Never move a channel backwards.
current_status="$(curl -s -o "${WORK_DIR}/current.json" -w '%{http_code}' "${PUBLIC_ROOT}/${MANIFEST_KEY}?v=$(date +%s)")"
if [[ "${current_status}" == "200" ]]; then
  current_version="$(jq -r '.payload' "${WORK_DIR}/current.json" | base64 -d | jq -r '.version')"
  if [[ "${current_version}" != "${VERSION}" ]] && ! semver_gt "${VERSION}" "${current_version}"; then
    echo "Error: ${CHANNEL} is already at ${current_version}; refusing to publish ${VERSION}." >&2
    exit 1
  fi
fi

if [[ "${MODE}" == "check" ]]; then
  echo "==> R2 publish preconditions OK for ${TAG} on ${CHANNEL}."
  exit 0
fi

# A release is often published in several runs (one per package or host). When
# the channel already points at this tag, keep its assets and add the new ones.
ASSETS_JSON='{}'
if [[ "${current_status}" == "200" && "$(jq -r '.payload' "${WORK_DIR}/current.json" | base64 -d | jq -r '.tag')" == "${TAG}" ]]; then
  write_public_pem "$(pinned_public_key)" "${WORK_DIR}/pinned.pem"
  jq -r '.payload' "${WORK_DIR}/current.json" | base64 -d > "${WORK_DIR}/current-payload.json"
  jq -r '.signature' "${WORK_DIR}/current.json" | base64 -d > "${WORK_DIR}/current-sig.bin"
  openssl pkeyutl -verify -pubin -inkey "${WORK_DIR}/pinned.pem" -rawin \
    -in "${WORK_DIR}/current-payload.json" -sigfile "${WORK_DIR}/current-sig.bin" >/dev/null \
    || { echo "Error: the current ${CHANNEL} manifest is not signed by the pinned key." >&2; exit 1; }
  ASSETS_JSON="$(jq -c '.assets' "${WORK_DIR}/current-payload.json")"
  echo "==> Adding to the existing ${TAG} manifest ($(jq -r 'keys | join(", ")' <<< "${ASSETS_JSON}"))"
fi
for file in "${FILES[@]}"; do
  name="$(basename "${file}")"
  key="$(asset_key_for "${name}")"
  if [[ -z "${key}" ]]; then
    echo "==> Skipping ${name} (no updater install mode)"
    continue
  fi
  sha="$(sha256sum "${file}" | awk '{print $1}')"
  size="$(stat -c %s "${file}")"
  object="releases/${TAG}/${name}"
  existing="$(remote_sha256 "${object}")"
  if [[ "${existing}" == "none" ]]; then
    echo "==> Uploading ${name} (${size} bytes)"
    upload "${file}" "${object}" "$(content_type_for "${name}")" "public, max-age=31536000, immutable" "${sha}"
  elif [[ "${existing}" == "${sha}" ]]; then
    echo "==> ${name} already uploaded, skipping"
  else
    echo "Error: ${object} already exists with different content; release files are never overwritten." >&2
    exit 1
  fi
  ASSETS_JSON="$(jq -c --arg k "${key}" --arg url "${PUBLIC_ROOT}/${object}" --arg sha "${sha}" --argjson size "${size}" \
    '. + {($k): {url: $url, sha256: $sha, size: $size}}' <<< "${ASSETS_JSON}")"
done
[[ "${ASSETS_JSON}" != '{}' ]] || { echo "Error: no updater assets among the given files." >&2; exit 1; }

# SHA256SUMS lists every asset of the tag, so it changes as runs add assets.
jq -r '.assets | to_entries[] | "\(.value.sha256)  \(.value.url | split("/") | last)"' \
  <<< "{\"assets\": ${ASSETS_JSON}}" | sort -k2 > "${WORK_DIR}/SHA256SUMS"
SUMS_NAME="SHA256SUMS"
[[ "${CHANNEL}" == "stable" ]] || SUMS_NAME="SHA256SUMS.${CHANNEL}"
upload "${WORK_DIR}/SHA256SUMS" "releases/${TAG}/${SUMS_NAME}" "text/plain; charset=utf-8" "no-cache" \
  "$(sha256sum "${WORK_DIR}/SHA256SUMS" | awk '{print $1}')"

NOTES=""
[[ -n "${NOTES_FILE}" ]] && NOTES="$(cat "${NOTES_FILE}")"
jq -cn \
  --arg channel "${CHANNEL}" --arg version "${VERSION}" --arg tag "${TAG}" \
  --arg published "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg notes "${NOTES}" \
  --arg notes_url "${NAVIS_RELEASE_NOTES_URL:-}" --argjson assets "${ASSETS_JSON}" \
  '{schema: 1, channel: $channel, version: $version, tag: $tag, published_at: $published, assets: $assets}
   + (if $notes == "" then {} else {notes: $notes} end)
   + (if $notes_url == "" then {} else {notes_url: $notes_url} end)' \
  > "${WORK_DIR}/payload.json"
openssl pkeyutl -sign -inkey "${NAVIS_UPDATE_SIGNING_KEY}" -rawin \
  -in "${WORK_DIR}/payload.json" -out "${WORK_DIR}/payload.sig"
jq -cn --arg payload "$(base64 -w0 "${WORK_DIR}/payload.json")" --arg signature "$(base64 -w0 "${WORK_DIR}/payload.sig")" \
  '{payload: $payload, signature: $signature}' > "${WORK_DIR}/manifest.json"

echo "==> Publishing ${MANIFEST_KEY} -> ${TAG}"
upload "${WORK_DIR}/manifest.json" "${MANIFEST_KEY}" "application/json" "no-cache" \
  "$(sha256sum "${WORK_DIR}/manifest.json" | awk '{print $1}')"

verify
