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
  --package=<bundle|deb>   Linux package mode (default: bundle)
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
if [[ "${PACKAGE_MODE}" != "bundle" && "${PACKAGE_MODE}" != "deb" ]]; then
  echo "[remote-linux] --package must be bundle or deb" >&2
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
tar \
  --exclude='.git' \
  --exclude='.dart_tool' \
  --exclude='build' \
  --exclude='ios/Pods' \
  --exclude='android/.gradle' \
  --exclude='tool/release.env' \
  -czf "${SOURCE_ARCHIVE}" \
  -C "${REPO_ROOT}" .

cat > "${REMOTE_SCRIPT}" <<'REMOTE_EOF'
#!/usr/bin/env bash
set -euo pipefail

base_dir="$1"
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

tar -xzf "${archive_path}" -C "${workspace_dir}"
cd "${workspace_dir}"

flutter pub get
build_args=("--dart-define=NAVIS_UPDATE_CHANNEL=${update_channel}")
if [[ -n "${lastfm_defines_file}" ]]; then
  build_args+=("--dart-define-from-file=${lastfm_defines_file}")
fi
flutter build linux --release "${build_args[@]}"

bundle_dir="$(find build/linux -type d -path '*/release/bundle' | head -1)"
if [[ -z "${bundle_dir}" ]]; then
  echo "Linux bundle not found under build/linux" >&2
  exit 1
fi

if [[ "${package_mode}" == "deb" ]]; then
  if ! command -v dpkg-deb >/dev/null 2>&1; then
    echo "dpkg-deb is required for --package=deb" >&2
    exit 1
  fi

  deb_arch="$(dpkg --print-architecture 2>/dev/null || true)"
  if [[ -z "${deb_arch}" ]]; then
    case "$(uname -m)" in
      x86_64) deb_arch="amd64" ;;
      aarch64|arm64) deb_arch="arm64" ;;
      *) deb_arch="$(uname -m)" ;;
    esac
  fi

  deb_package_name="${asset_prefix}"
  deb_app_name="Navis"
  if [[ "${update_channel}" == "dev" ]]; then
    deb_app_name="Navis Dev"
  fi
  deb_maintainer="${NAVIS_DEB_MAINTAINER:-Navis Team <noreply@example.com>}"
  deb_stage_dir="${workspace_dir}/build/linux/deb_stage"

  rm -rf "${deb_stage_dir}"
  mkdir -p "${deb_stage_dir}/DEBIAN"
  mkdir -p "${deb_stage_dir}/opt/${deb_package_name}"
  mkdir -p "${deb_stage_dir}/usr/bin"
  mkdir -p "${deb_stage_dir}/usr/share/applications"
  mkdir -p "${deb_stage_dir}/usr/share/icons/hicolor"

  cp -R "${bundle_dir}/." "${deb_stage_dir}/opt/${deb_package_name}/"

  cat > "${deb_stage_dir}/usr/bin/${deb_package_name}" <<LAUNCHER
#!/usr/bin/env bash
exec "/opt/${deb_package_name}/navis" "\$@"
LAUNCHER
  chmod 0755 "${deb_stage_dir}/usr/bin/${deb_package_name}"

  cat > "${deb_stage_dir}/usr/share/applications/${deb_package_name}.desktop" <<DESKTOP
[Desktop Entry]
Name=${deb_app_name}
GenericName=Music Player
Comment=Subsonic/OpenSubsonic music player
Exec=${deb_package_name}
Icon=${deb_package_name}
Terminal=false
Type=Application
Categories=AudioVideo;Audio;Player;
StartupNotify=true
StartupWMClass=navis
MimeType=audio/mpeg;audio/ogg;audio/flac;audio/x-flac;audio/wav;audio/aac;audio/x-m4a;
DESKTOP

  icon_source_dir="${workspace_dir}/linux/packaging/icons/hicolor"
  if [[ -d "${icon_source_dir}" ]]; then
    while IFS= read -r icon_path; do
      icon_size="$(basename "$(dirname "$(dirname "${icon_path}")")")"
      install -d "${deb_stage_dir}/usr/share/icons/hicolor/${icon_size}/apps"
      install -m 0644 "${icon_path}" \
        "${deb_stage_dir}/usr/share/icons/hicolor/${icon_size}/apps/${deb_package_name}.png"
    done < <(find "${icon_source_dir}" -path "*/apps/navis.png" -type f | sort)
  fi

  semver="${version#v}"
  cat > "${deb_stage_dir}/DEBIAN/control" <<CONTROL
Package: ${deb_package_name}
Version: ${semver}
Section: sound
Priority: optional
Architecture: ${deb_arch}
Maintainer: ${deb_maintainer}
Depends: libgtk-3-0, libpulse0, libasound2
Homepage: https://git.porthorion.com/khalifa/Navis
Description: Navis music player
 Subsonic/OpenSubsonic music player built with Flutter.
CONTROL

  asset_name="${asset_prefix}-${version}-linux-${deb_arch}.deb"
  asset_path="${base_dir}/${asset_name}"
  rm -f "${asset_path}"
  dpkg-deb --root-owner-group --build "${deb_stage_dir}" "${asset_path}" >/dev/null
  rm -rf "${deb_stage_dir}"
else
  asset_name="${asset_prefix}-${version}-linux.tar.gz"
  asset_path="${base_dir}/${asset_name}"
  rm -f "${asset_path}"
  tar -czf "${asset_path}" -C "${bundle_dir}" .
fi

printf '%s' "${asset_name}" > "${asset_name_file}"
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

asset_name="$(ssh "${SSH_TARGET}" "cat '${REMOTE_DIR}/asset_name.txt'")"
asset_name="${asset_name//$'\r'/}"
asset_name="${asset_name//$'\n'/}"
if [[ -z "${asset_name}" ]]; then
  echo "[remote-linux] Failed to resolve remote asset name" >&2
  exit 1
fi

printf '[remote-linux] Fetching %s...\n' "${asset_name}"
scp "${SSH_TARGET}:${REMOTE_DIR}/${asset_name}" "${REPO_ROOT}/${asset_name}" >/dev/null

printf '[remote-linux] Artifact ready: %s\n' "${REPO_ROOT}/${asset_name}"
