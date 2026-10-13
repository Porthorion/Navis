#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: ./tool/remote_build_linux.sh --ssh=<user@host> --version=<vX.Y.Z> [options]

Builds Linux release artifacts on a remote Linux builder over SSH, then copies
asset(s) back to the local repository root.

Options:
  --ssh=<target>           SSH target (required)
  --version=<tag>          Release tag (required), e.g. v1.2.3
  --asset-prefix=<name>    Asset prefix (default: navis)
  --package=<bundle|deb|rpm|all>   Linux package mode (default: bundle)
  --channel=<stable|dev>   Update channel (default: stable)
  --lastfm-defines-file=<path>
                           Optional local mode-600 JSON of the masked Last.fm
                           key defines (see tool/lib/lastfm_key_defines.sh).
                           Sent over ssh stdin into a mode-600 remote file that
                           is deleted when the build ends; not put on argv.
  --remote-dir=<path>      Remote working dir relative to remote HOME
                           (default: .navis/remote-linux-build)
  --repo-root=<path>       Local repo root (default: script/..)
USAGE
}

SSH_TARGET=""
VERSION=""
ASSET_PREFIX="navis"
PACKAGE_MODE="bundle"
UPDATE_CHANNEL="stable"
LASTFM_DEFINES_FILE=""
REMOTE_DIR=".navis/remote-linux-build"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

for arg in "$@"; do
  case "${arg}" in
    --ssh=*) SSH_TARGET="${arg#--ssh=}" ;;
    --version=*) VERSION="${arg#--version=}" ;;
    --asset-prefix=*) ASSET_PREFIX="${arg#--asset-prefix=}" ;;
    --package=*) PACKAGE_MODE="${arg#--package=}" ;;
    --channel=*) UPDATE_CHANNEL="${arg#--channel=}" ;;
    --lastfm-defines-file=*) LASTFM_DEFINES_FILE="${arg#--lastfm-defines-file=}" ;;
    --remote-dir=*) REMOTE_DIR="${arg#--remote-dir=}" ;;
    --repo-root=*) REPO_ROOT="${arg#--repo-root=}" ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[remote-linux] Unknown argument: ${arg}" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "${SSH_TARGET}" || -z "${VERSION}" ]]; then
  usage
  exit 1
fi

PACKAGE_MODE="$(echo "${PACKAGE_MODE}" | tr '[:upper:]' '[:lower:]')"
if [[ ! "${PACKAGE_MODE}" =~ ^(bundle|deb|rpm|all)$ ]]; then
  echo "[remote-linux] --package must be bundle, deb, rpm or all" >&2
  exit 1
fi

UPDATE_CHANNEL="$(echo "${UPDATE_CHANNEL}" | tr '[:upper:]' '[:lower:]')"
if [[ "${UPDATE_CHANNEL}" != "stable" && "${UPDATE_CHANNEL}" != "dev" ]]; then
  echo "[remote-linux] --channel must be stable or dev" >&2
  exit 1
fi

for tool in ssh scp tar; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    echo "[remote-linux] Missing required tool: ${tool}" >&2
    exit 1
  fi
done

SOURCE_ARCHIVE="$(mktemp -t navis_linux_remote_src.XXXXXX.tgz)"
REMOTE_SCRIPT="$(mktemp -t navis_linux_remote_script.XXXXXX.sh)"
REMOTE_DEFINES="${REMOTE_DIR}/lastfm-defines.json"
REMOTE_DEFINES_PUSHED=false
cleanup() {
  rm -f "${SOURCE_ARCHIVE}" "${REMOTE_SCRIPT}"
  ssh "${SSH_TARGET}" "rm -f '${REMOTE_DIR}/source.tgz'" >/dev/null 2>&1 || true
  if [[ "${REMOTE_DEFINES_PUSHED}" == "true" ]]; then
    # The remote script removes the file itself; this covers a dropped session.
    ssh "${SSH_TARGET}" "rm -f '${REMOTE_DEFINES}'" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if [[ -n "${LASTFM_DEFINES_FILE}" && ! -f "${LASTFM_DEFINES_FILE}" ]]; then
  echo "[remote-linux] --lastfm-defines-file not found: ${LASTFM_DEFINES_FILE}" >&2
  exit 1
fi

printf '[remote-linux] Packaging local source archive...\n'
# Package tracked files only. Ignored files such as android/key.properties,
# the release keystore and tool/release.env must never reach a build host.
git -C "${REPO_ROOT}" ls-files -z |
  tar -czf "${SOURCE_ARCHIVE}" -C "${REPO_ROOT}" --null -T -

cat > "${REMOTE_SCRIPT}" <<'REMOTE_EOF'
#!/usr/bin/env bash
set -euo pipefail

base_dir="$(cd "$1" && pwd)"
archive_name="$2"
package_mode="$3"
version="$4"
asset_prefix="$5"
update_channel="$6"
lastfm_defines_file="$7"

archive_path="${base_dir}/${archive_name}"
workspace_dir="${base_dir}/workspace"
asset_name_file="${base_dir}/asset_name.txt"

# The masked Last.fm key defines arrive in a private file; remove it when the
# build ends, however it ends.
if [[ -n "${lastfm_defines_file}" ]]; then
  lastfm_defines_file="$(readlink -f "${lastfm_defines_file}")"
  trap 'rm -f "${lastfm_defines_file}"' EXIT
fi

rm -rf "${workspace_dir}"
mkdir -p "${workspace_dir}"

# Preserve the tracked-file manifest for the container wrapper: this extracted
# archive deliberately has no .git directory or ignored files.
source_list="${base_dir}/source-files.txt"
tar -tzf "${archive_path}" > "${source_list}"
tar -xzf "${archive_path}" -C "${workspace_dir}"
rm -f "${archive_path}"
cd "${workspace_dir}"

build_args=("--dart-define=NAVIS_UPDATE_CHANNEL=${update_channel}")
if [[ -n "${lastfm_defines_file}" ]]; then
  build_args+=("--dart-define-from-file=${lastfm_defines_file}")
fi
# Same container build and package assembly as the coordinator. Obfuscation is
# mandatory here too; split symbols stay on the remote host, never in assets.
./tool/linux/build_in_container.sh --source-list="$(readlink -f "${source_list}")" --package="${package_mode}" \
  --version="${version}" --asset-prefix="${asset_prefix}" "${build_args[@]}"
: > "${asset_name_file}"
for asset in "${asset_prefix}-${version}-linux.tar.gz" \
    "${asset_prefix}-${version}-linux-amd64.deb" "${asset_prefix}-${version}-linux-x86_64.rpm"; do
  if [[ -f "${asset}" ]]; then
    cp "${asset}" "${base_dir}/${asset}"
    printf '%s\n' "${asset}" >> "${asset_name_file}"
  fi
done
REMOTE_EOF

printf '[remote-linux] Preparing remote workspace on %s...\n' "${SSH_TARGET}"
ssh "${SSH_TARGET}" "mkdir -p '${REMOTE_DIR}'"
scp "${SOURCE_ARCHIVE}" "${SSH_TARGET}:${REMOTE_DIR}/source.tgz" >/dev/null
scp "${REMOTE_SCRIPT}" "${SSH_TARGET}:${REMOTE_DIR}/navis_remote_linux_build.sh" >/dev/null

remote_defines_arg=""
if [[ -n "${LASTFM_DEFINES_FILE}" ]]; then
  printf '[remote-linux] Sending masked Last.fm key defines (mode 600)...\n'
  REMOTE_DEFINES_PUSHED=true
  ssh "${SSH_TARGET}" "umask 077 && cat > '${REMOTE_DEFINES}' && chmod 600 '${REMOTE_DEFINES}'" \
    <"${LASTFM_DEFINES_FILE}"
  remote_defines_arg="${REMOTE_DEFINES}"
fi

printf '[remote-linux] Running remote build...\n'
ssh "${SSH_TARGET}" \
  "bash '${REMOTE_DIR}/navis_remote_linux_build.sh' '${REMOTE_DIR}' 'source.tgz' '${PACKAGE_MODE}' '${VERSION}' '${ASSET_PREFIX}' '${UPDATE_CHANNEL}' '${remote_defines_arg}'"

asset_names="$(ssh "${SSH_TARGET}" "cat '${REMOTE_DIR}/asset_name.txt'")"
[[ -n "${asset_names}" ]] || { echo '[remote-linux] No artifacts returned' >&2; exit 1; }
while IFS= read -r asset_name; do
  asset_name="${asset_name//$'\r'/}"
  if [[ ! "${asset_name}" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "[remote-linux] Refusing unexpected remote asset name" >&2
    exit 1
  fi
  printf '[remote-linux] Fetching %s...\n' "${asset_name}"
  scp "${SSH_TARGET}:${REMOTE_DIR}/${asset_name}" "${REPO_ROOT}/${asset_name}" >/dev/null
  printf '[remote-linux] Artifact ready: %s\n' "${REPO_ROOT}/${asset_name}"
done <<< "${asset_names}"
