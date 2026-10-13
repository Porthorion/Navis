#!/usr/bin/env bash
# Sourced by release.sh: the local handoff between build and publication.

release_dist_checksums() {
  (cd "$1" && sha256sum -- assets.txt release.json release-notes.md "${ASSET_NAMES[@]}")
}

stage_release_dist() {
  local dist_root="${SCRIPT_DIR}/../dist" i
  mkdir -p "${dist_root}"
  DIST_TMP_DIR="$(mktemp -d "${dist_root}/.${VERSION}.XXXXXX")"
  for i in "${!ASSET_FILES[@]}"; do
    cp "${ASSET_FILES[$i]}" "${DIST_TMP_DIR}/${ASSET_NAMES[$i]}"
  done
  printf '%s\n' "${ASSET_NAMES[@]}" > "${DIST_TMP_DIR}/assets.txt"
  printf '%s\n' "${RELEASE_BODY}" > "${DIST_TMP_DIR}/release-notes.md"
  jq -n --arg tag "${VERSION}" --arg channel "${UPDATE_CHANNEL}" \
    --arg source_commit "${SOURCE_COMMIT}" --argjson prerelease "${RELEASE_PRERELEASE}" \
    '{schema: 1, tag: $tag, channel: $channel, source_commit: $source_commit, prerelease: $prerelease}' \
    > "${DIST_TMP_DIR}/release.json"
  release_dist_checksums "${DIST_TMP_DIR}" > "${DIST_TMP_DIR}/SHA256SUMS"
  # Never replace a bundle the owner may already have verified.
  [[ ! -e "${dist_root}/${VERSION}" && ! -L "${dist_root}/${VERSION}" ]] || {
    echo "Error: dist/${VERSION} already exists."; exit 1;
  }
  mv "${DIST_TMP_DIR}" "${dist_root}/${VERSION}"
  DIST_TMP_DIR=""
  echo "==> Validated release bundle: $(cd "${dist_root}/${VERSION}" && pwd)"
  echo "    Verify: (cd dist/${VERSION} && sha256sum -c SHA256SUMS)"
  local publish_args=("./tool/release.sh" "${VERSION}" "--publish-from=dist/${VERSION}" "--skip-checks")
  if [[ "${PUBLISH_FORGEJO}" == true || ( "${VERSION}" == v1.5.0 && "${UPDATE_CHANNEL}" == stable ) ]]; then
    publish_args+=(--forgejo)
  fi
  if [[ "${ALLOW_EXISTING_VERSION}" == true ]]; then publish_args+=(--allow-existing-version); fi
  printf '    Release day: '
  printf '%q ' "${publish_args[@]}"
  printf '\n'
}

load_release_dist() {
  [[ -d "${PUBLISH_FROM}" && ! -L "${PUBLISH_FROM}" ]] || {
    echo "Error: Release bundle directory not found or is a symlink: ${PUBLISH_FROM}"; exit 1;
  }
  PUBLISH_FROM="$(cd "${PUBLISH_FROM}" && pwd)"
  local name dist_channel prefix expected_sums
  for name in assets.txt release.json release-notes.md SHA256SUMS; do
    [[ -f "${PUBLISH_FROM}/${name}" && ! -L "${PUBLISH_FROM}/${name}" ]] || {
      echo "Error: Missing or symlinked bundle file: ${name}"; exit 1;
    }
  done
  jq -e --arg tag "${VERSION}" '
    .schema == 1 and .tag == $tag and
    (.channel == "stable" or .channel == "dev") and
    (.source_commit | type == "string" and test("^([0-9a-f]{40}|[0-9a-f]{64})$")) and
    (.prerelease | type == "boolean")
  ' "${PUBLISH_FROM}/release.json" >/dev/null || {
    echo "Error: Invalid bundle metadata or requested tag mismatch."; exit 1;
  }
  dist_channel="$(jq -r '.channel' "${PUBLISH_FROM}/release.json")"
  if [[ "${CHANNEL_EXPLICIT}" == true && "${UPDATE_CHANNEL}" != "${dist_channel}" ]]; then
    echo "Error: --channel differs from the staged channel."; exit 1
  fi
  UPDATE_CHANNEL="${dist_channel}"
  DIST_SOURCE_COMMIT="$(jq -r '.source_commit' "${PUBLISH_FROM}/release.json")"
  if [[ "${FORCE_PRERELEASE}" == true && "$(jq -r '.prerelease' "${PUBLISH_FROM}/release.json")" != true ]]; then
    echo "Error: --prerelease differs from the staged metadata."; exit 1
  fi
  FORCE_PRERELEASE="$(jq -r '.prerelease' "${PUBLISH_FROM}/release.json")"
  prefix=navis
  [[ "${UPDATE_CHANNEL}" != dev ]] || prefix=navis-dev
  ASSET_FILES=()
  ASSET_NAMES=()
  while IFS= read -r name || [[ -n "${name}" ]]; do
    case "${name}" in
      "${prefix}-${VERSION}.apk"|"${prefix}-${VERSION}.ipa"|\
      "${prefix}-${VERSION}-android-arm64-v8a.apk"|"${prefix}-${VERSION}-android-armeabi-v7a.apk"|\
      "${prefix}-${VERSION}-android-x86_64.apk"|"${prefix}-${VERSION}-linux.tar.gz"|\
      "${prefix}-${VERSION}-linux-amd64.deb"|"${prefix}-${VERSION}-linux-x86_64.rpm"|\
      "${prefix}-${VERSION}-windows.zip"|"${prefix}-${VERSION}-windows-installer.exe"|\
      "${prefix}-${VERSION}-macos.zip") ;;
      *) echo "Error: Invalid staged asset name: ${name}"; exit 1 ;;
    esac
    [[ -s "${PUBLISH_FROM}/${name}" && ! -L "${PUBLISH_FROM}/${name}" ]] || {
      echo "Error: Missing, empty or symlinked staged asset: ${name}"; exit 1;
    }
    local previous
    for previous in "${ASSET_NAMES[@]}"; do
      [[ "${previous}" != "${name}" ]] || { echo "Error: Duplicate staged asset: ${name}"; exit 1; }
    done
    ASSET_NAMES+=("${name}")
    ASSET_FILES+=("${PUBLISH_FROM}/${name}")
  done < "${PUBLISH_FROM}/assets.txt"
  (( ${#ASSET_FILES[@]} > 0 )) || { echo "Error: Empty staged asset list."; exit 1; }
  # Recompute only the declared safe filenames, rather than trusting checksum
  # input that could name files outside the bundle or omit an asset.
  expected_sums="$(release_dist_checksums "${PUBLISH_FROM}")"
  [[ "${expected_sums}" == "$(cat "${PUBLISH_FROM}/SHA256SUMS")" ]] || {
    echo "Error: Release bundle checksum mismatch."; exit 1;
  }
  RELEASE_BODY="$(cat "${PUBLISH_FROM}/release-notes.md")"
  echo "==> Verified staged bundle (${#ASSET_FILES[@]} assets): ${PUBLISH_FROM}"
}
