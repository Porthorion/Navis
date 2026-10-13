#!/usr/bin/env bash
# tool/release_tag_guard.sh — refuse to release a version that already shipped.
#
# Usage:
#   ./tool/release_tag_guard.sh <tag> [--allow-existing-version] [--local-only]
#
# A version has shipped once its release tag (e.g. v1.4.1) exists, locally or
# on origin; tool/release.sh creates and pushes that tag. pubspec.yaml is not
# the signal: work on the next version sets it early (docs/development/agentic-engineering.md
# "Versioning"), so it already names a version that has not been released.
#
# --local-only checks only local tags for build-only staging; it never contacts
# origin. Publication must repeat the full guard on release day.
#
# Exits 0 when the release may proceed. With --allow-existing-version an
# existing tag is accepted for an intentional rebuild or retry, and a tag that
# exists only on origin is fetched so the release reuses it.
set -euo pipefail

TAG=""
ALLOW_EXISTING_VERSION=false
LOCAL_ONLY=false
for arg in "$@"; do
  case "${arg}" in
    --local-only) LOCAL_ONLY=true ;;
    --allow-existing-version) ALLOW_EXISTING_VERSION=true ;;
    -*)
      echo "Unknown option: ${arg}" >&2
      exit 2
      ;;
    *) TAG="${arg}" ;;
  esac
done
if [[ -z "${TAG}" ]]; then
  echo "Usage: ./tool/release_tag_guard.sh <tag> [--allow-existing-version] [--local-only]" >&2
  exit 2
fi

local_tag=false
if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
  local_tag=true
fi

remote_tags=""
if [[ "${LOCAL_ONLY}" == false ]] && ! remote_tags="$(git ls-remote --tags origin "refs/tags/${TAG}")"; then
  echo "Error: could not read tags from origin to check whether ${TAG} was already released." >&2
  exit 1
fi
remote_tag=false
if [[ -n "${remote_tags}" ]]; then
  remote_tag=true
fi

if [[ "${local_tag}" == "false" && "${remote_tag}" == "false" ]]; then
  exit 0
fi

where="locally"
if [[ "${local_tag}" == "true" && "${remote_tag}" == "true" ]]; then
  where="locally and on origin"
elif [[ "${remote_tag}" == "true" ]]; then
  where="on origin"
fi

if [[ "${ALLOW_EXISTING_VERSION}" == "false" ]]; then
  echo "Error: ${TAG} was already released (the tag exists ${where})." >&2
  echo "Release a new version, or pass --allow-existing-version for an intentional rebuild or retry." >&2
  exit 1
fi

if [[ "${local_tag}" == "false" ]]; then
  git fetch -q origin "refs/tags/${TAG}:refs/tags/${TAG}"
fi
echo "    ${TAG} already exists ${where}; reusing it (--allow-existing-version)."
