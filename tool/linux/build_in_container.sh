#!/usr/bin/env bash
# Local build/package entry point; never signs, tags or publishes.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
image="${NAVIS_LINUX_IMAGE:-navis-linux-builder:22.04}"
memory="${NAVIS_LINUX_MEMORY:-6g}"
cpus="${NAVIS_LINUX_CPUS:-2}"
sdk="${NAVIS_FLUTTER_SDK:-$(dirname "$(dirname "$(readlink -f "$(command -v flutter)")")")}"
mode=all
version="v$(sed -n 's/^version: \([^+]*\).*/\1/p' "${repo}/pubspec.yaml")"
prefix=navis
build=true
args=()
mounts=()
archive_source_list=""
for arg in "$@"; do
  case "${arg}" in
    --package=*) mode="${arg#*=}" ;;
    --version=*) version="${arg#*=}" ;;
    --asset-prefix=*) prefix="${arg#*=}" ;;
    --package-only) build=false ;;
    --source-list=*) archive_source_list="${arg#*=}" ;;
    --dart-define-from-file=*)
      file="$(realpath "${arg#*=}")"
      mounts+=(--mount "type=bind,src=${file},dst=${file},readonly")
      args+=("--dart-define-from-file=${file}") ;;
    --obfuscate|--split-debug-info=*|--dart-define=*) args+=("${arg}") ;;
    -h|--help)
      echo 'Usage: tool/linux/build_in_container.sh [--package=bundle|deb|rpm|all] [--package-only] [--version=vX.Y.Z] [--asset-prefix=navis|navis-dev] [--dart-define=KEY=VALUE]'
      echo 'Local only; defaults: all packages, pubspec version, stable, 6 GiB, 2 CPUs.'
      exit 0 ;;
    --*) echo "Unsupported release option: ${arg}" >&2; exit 1 ;;
    *) echo "Unexpected argument: ${arg}" >&2; exit 1 ;;
  esac
done
[[ "${mode}" =~ ^(bundle|deb|rpm|all)$ && "${version}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ && "${prefix}" =~ ^navis(-dev)?$ ]] || { echo 'Invalid package/version/prefix' >&2; exit 1; }
[[ "${cpus}" =~ ^[1-9][0-9]*$ ]] || { echo 'NAVIS_LINUX_CPUS must be a positive integer' >&2; exit 1; }
[[ "$(uname -m)" == x86_64 ]] || { echo 'Linux release builder requires x86_64' >&2; exit 1; }
# Serialize image construction and builds, including invocations in other worktrees.
exec 9>"${TMPDIR:-/tmp}/navis-linux-container-build-${UID}.lock"
flock 9
mkdir -p "${repo}/build/linux"
source_list="$(mktemp "${repo}/build/linux/container-sources.XXXXXX")"
trap 'rm -f "${source_list}"' EXIT
if [[ -n "${archive_source_list}" ]]; then
  # SSH builds receive a tracked-only tar archive rather than Git metadata.
  while IFS= read -r source_file; do
    [[ -n "${source_file}" && "${source_file}" != /* && "${source_file}" != *../* ]] || exit 1
    printf '%s\0' "${source_file}"
  done < "${archive_source_list}" > "${source_list}"
else
  git -C "${repo}" ls-files --cached --others --exclude-standard -z > "${source_list}"
fi
DOCKER_BUILDKIT=0 docker build --memory="${memory}" --memory-swap="${memory}" -t "${image}" "${repo}/tool/linux"
docker run --rm --memory="${memory}" --memory-swap="${memory}" --cpus="${cpus}" \
  --user "$(id -u):$(id -g)" \
  --mount "type=bind,src=${repo},dst=${repo}" \
  --mount "type=bind,src=${sdk},dst=/host-flutter,readonly" \
  --mount "type=bind,src=${PUB_CACHE:-${HOME}/.pub-cache},dst=/host-pub,readonly" \
  "${mounts[@]}" \
  -e NAVIS_DEB_MAINTAINER -e CMAKE_BUILD_PARALLEL_LEVEL="${cpus}" \
  "${image}" bash "${repo}/tool/linux/container_entry.sh" \
  "${repo}" "${build}" "${mode}" "${version}" "${prefix}" "${source_list}" "${args[@]}"
