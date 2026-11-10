#!/usr/bin/env bash
# Sourced by release.sh: build the release body from the app changelog.
#
# generate_release_notes
#   Reads VERSION and UPDATE_CHANNEL, sets RELEASE_BODY. The generator exits 2
#   when the version has no changelog entry; that is the only case allowed to
#   fall back to a generic body. Any other non-zero exit (bad argument, crash,
#   Dart compile error) or empty stdout is a real failure and stops the release
#   before that body can enter the signed manifest.

generate_release_notes() {
  echo "==> Generating release notes for ${VERSION}..."
  local status=0
  RELEASE_BODY="$(dart tool/generate_release_notes.dart "${VERSION}")" || status=$?
  if [[ "${status}" -eq 2 ]]; then
    RELEASE_BODY="## Navis ${VERSION} (${UPDATE_CHANNEL})"
    echo "    No changelog entry found — using generic release body."
    return 0
  fi
  if [[ "${status}" -ne 0 ]]; then
    echo "Error: release notes generator failed for ${VERSION} (exit ${status})." >&2
    exit 1
  fi
  if [[ -z "${RELEASE_BODY}" ]]; then
    echo "Error: release notes generator returned empty notes for ${VERSION}." >&2
    exit 1
  fi
  echo "    Release notes generated successfully."
}
