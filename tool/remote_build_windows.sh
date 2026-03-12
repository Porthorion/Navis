#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: ./tool/remote_build_windows.sh --ssh=<user@host> --version=<vX.Y.Z> [options]

Builds Windows release artifacts on a remote Windows builder over SSH, then
copies asset(s) back to the local repository root.

Options:
  --ssh=<target>           SSH target (required)
  --version=<tag>          Release tag (required), e.g. v1.2.3
  --asset-prefix=<name>    Asset prefix (default: navis)
  --package=<zip|exe>      Windows package mode (default: zip)
  --channel=<stable|dev>   Update channel (default: stable)
  --remote-dir=<path>      Remote working dir relative to remote HOME
                           (default: .navis/remote-windows-build)
  --repo-root=<path>       Local repo root (default: script/..)
USAGE
}

SSH_TARGET=""
VERSION=""
ASSET_PREFIX="navis"
PACKAGE_MODE="zip"
UPDATE_CHANNEL="stable"
REMOTE_DIR=".navis/remote-windows-build"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

for arg in "$@"; do
  case "${arg}" in
    --ssh=*) SSH_TARGET="${arg#--ssh=}" ;;
    --version=*) VERSION="${arg#--version=}" ;;
    --asset-prefix=*) ASSET_PREFIX="${arg#--asset-prefix=}" ;;
    --package=*) PACKAGE_MODE="${arg#--package=}" ;;
    --channel=*) UPDATE_CHANNEL="${arg#--channel=}" ;;
    --remote-dir=*) REMOTE_DIR="${arg#--remote-dir=}" ;;
    --repo-root=*) REPO_ROOT="${arg#--repo-root=}" ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[remote-windows] Unknown argument: ${arg}" >&2
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
if [[ "${PACKAGE_MODE}" != "zip" && "${PACKAGE_MODE}" != "exe" ]]; then
  echo "[remote-windows] --package must be zip or exe" >&2
  exit 1
fi

UPDATE_CHANNEL="$(echo "${UPDATE_CHANNEL}" | tr '[:upper:]' '[:lower:]')"
if [[ "${UPDATE_CHANNEL}" != "stable" && "${UPDATE_CHANNEL}" != "dev" ]]; then
  echo "[remote-windows] --channel must be stable or dev" >&2
  exit 1
fi

for tool in ssh scp tar; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    echo "[remote-windows] Missing required tool: ${tool}" >&2
    exit 1
  fi
done

SOURCE_ARCHIVE="$(mktemp -t navis_windows_remote_src.XXXXXX.tgz)"
REMOTE_SCRIPT="$(mktemp -t navis_windows_remote_script.XXXXXX.ps1)"
cleanup() {
  rm -f "${SOURCE_ARCHIVE}" "${REMOTE_SCRIPT}"
}
trap cleanup EXIT

printf '[remote-windows] Packaging local source archive...\n'
tar \
  --exclude='.git' \
  --exclude='.dart_tool' \
  --exclude='build' \
  --exclude='ios/Pods' \
  --exclude='android/.gradle' \
  -czf "${SOURCE_ARCHIVE}" \
  -C "${REPO_ROOT}" .

cat > "${REMOTE_SCRIPT}" <<'REMOTE_POWERSHELL'
param(
  [Parameter(Mandatory = $true)][string]$RemoteDir,
  [Parameter(Mandatory = $true)][string]$ArchiveName,
  [Parameter(Mandatory = $true)][ValidateSet('zip', 'exe')][string]$PackageMode,
  [Parameter(Mandatory = $true)][string]$Version,
  [Parameter(Mandatory = $true)][string]$AssetPrefix,
  [Parameter(Mandatory = $true)][ValidateSet('stable', 'dev')][string]$UpdateChannel
)

$ErrorActionPreference = 'Stop'

$baseDir = Join-Path $HOME $RemoteDir
$archivePath = Join-Path $baseDir $ArchiveName
$workspaceDir = Join-Path $baseDir 'workspace'
$assetNameFile = Join-Path $baseDir 'asset_name.txt'

if (Test-Path $workspaceDir) {
  Remove-Item -Recurse -Force $workspaceDir
}
New-Item -ItemType Directory -Force -Path $workspaceDir | Out-Null

tar -xzf $archivePath -C $workspaceDir
Set-Location $workspaceDir

flutter pub get
flutter build windows --release --dart-define=NAVIS_UPDATE_CHANNEL=$UpdateChannel

$releaseDir = Join-Path $workspaceDir 'build/windows/x64/runner/Release'
if (-not (Test-Path $releaseDir)) {
  throw "Windows release dir not found at $releaseDir"
}

if ($PackageMode -eq 'exe') {
  $assetName = "$AssetPrefix-$Version-windows-installer.exe"
  $assetPath = Join-Path $baseDir $assetName
  $installerScript = Join-Path $workspaceDir 'tool/windows/build_inno_installer.ps1'
  if (-not (Test-Path $installerScript)) {
    throw "Installer script not found at $installerScript"
  }
  if (Test-Path $assetPath) {
    Remove-Item -Force $assetPath
  }
  powershell -NoProfile -ExecutionPolicy Bypass -File $installerScript `
    -ReleaseDir $releaseDir `
    -Version $Version `
    -AssetPrefix $AssetPrefix `
    -OutputPath $assetPath
} else {
  $assetName = "$AssetPrefix-$Version-windows.zip"
  $assetPath = Join-Path $baseDir $assetName
  if (Test-Path $assetPath) {
    Remove-Item -Force $assetPath
  }
  Compress-Archive -Path (Join-Path $releaseDir '*') -DestinationPath $assetPath -Force
}

Set-Content -Path $assetNameFile -Value $assetName -NoNewline
REMOTE_POWERSHELL

printf '[remote-windows] Preparing remote workspace on %s...\n' "${SSH_TARGET}"
ssh "${SSH_TARGET}" \
  "powershell -NoProfile -Command \"New-Item -ItemType Directory -Force -Path (Join-Path \$HOME '${REMOTE_DIR}') | Out-Null\""
scp "${SOURCE_ARCHIVE}" "${SSH_TARGET}:${REMOTE_DIR}/source.tgz" >/dev/null
scp "${REMOTE_SCRIPT}" "${SSH_TARGET}:${REMOTE_DIR}/navis_remote_windows_build.ps1" >/dev/null

printf '[remote-windows] Running remote build...\n'
ssh "${SSH_TARGET}" \
  "powershell -NoProfile -ExecutionPolicy Bypass -File '${REMOTE_DIR}/navis_remote_windows_build.ps1' -RemoteDir '${REMOTE_DIR}' -ArchiveName 'source.tgz' -PackageMode '${PACKAGE_MODE}' -Version '${VERSION}' -AssetPrefix '${ASSET_PREFIX}' -UpdateChannel '${UPDATE_CHANNEL}'"

asset_name="$(ssh "${SSH_TARGET}" "powershell -NoProfile -Command \"Get-Content -Raw -Path (Join-Path (Join-Path \$HOME '${REMOTE_DIR}') 'asset_name.txt')\"")"
asset_name="${asset_name//$'\r'/}"
asset_name="${asset_name//$'\n'/}"
if [[ -z "${asset_name}" ]]; then
  echo "[remote-windows] Failed to resolve remote asset name" >&2
  exit 1
fi

printf '[remote-windows] Fetching %s...\n' "${asset_name}"
scp "${SSH_TARGET}:${REMOTE_DIR}/${asset_name}" "${REPO_ROOT}/${asset_name}" >/dev/null

printf '[remote-windows] Artifact ready: %s\n' "${REPO_ROOT}/${asset_name}"
