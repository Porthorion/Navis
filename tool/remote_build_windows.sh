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
  --lastfm-key=<key>       Optional Last.fm API key dart-define
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
LASTFM_API_KEY=""
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
    --lastfm-key=*) LASTFM_API_KEY="${arg#--lastfm-key=}" ;;
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
PUB_CACHE_ARCHIVE="$(mktemp -t navis_windows_pub_cache.XXXXXX.tgz)"
REMOTE_SCRIPT="$(mktemp -t navis_windows_remote_script.XXXXXX.ps1)"
cleanup() {
  rm -f "${SOURCE_ARCHIVE}" "${PUB_CACHE_ARCHIVE}" "${REMOTE_SCRIPT}"
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

# Bundle the pub packages required by pubspec.lock so the Windows VM can run
# flutter pub get --offline even without internet access.
printf '[remote-windows] Bundling pub package cache...\n'
_pub_cache_host="${HOME}/.pub-cache/hosted/pub.dev"
_lock_file="${REPO_ROOT}/pubspec.lock"
_pkg_dirs=()
if [[ -f "${_lock_file}" ]] && [[ -d "${_pub_cache_host}" ]]; then
  while IFS= read -r _pkg; do
    _dir="${_pub_cache_host}/${_pkg}"
    if [[ -d "${_dir}" ]]; then
      _pkg_dirs+=("${_pkg}")
    fi
  done < <(python3 - "${_lock_file}" <<'PYEOF'
import sys, re
with open(sys.argv[1]) as f:
    content = f.read()
for m in re.finditer(r'^\s{2}(\S+):\n(?:.*\n)*?.*?version:\s*"([^"]+)"', content, re.MULTILINE):
    print(f"{m.group(1)}-{m.group(2)}")
PYEOF
)
fi

if [[ ${#_pkg_dirs[@]} -gt 0 ]]; then
  tar -czf "${PUB_CACHE_ARCHIVE}" -C "${_pub_cache_host}" "${_pkg_dirs[@]}"
  printf '[remote-windows] Bundled %d pub packages.\n' "${#_pkg_dirs[@]}"
else
  # Empty archive fallback
  tar -czf "${PUB_CACHE_ARCHIVE}" -T /dev/null 2>/dev/null || touch "${PUB_CACHE_ARCHIVE}"
  printf '[remote-windows] Warning: no pub packages bundled.\n'
fi

cat > "${REMOTE_SCRIPT}" <<'REMOTE_POWERSHELL'
param(
  [Parameter(Mandatory = $true)][string]$RemoteDir,
  [Parameter(Mandatory = $true)][string]$ArchiveName,
  [Parameter(Mandatory = $true)][ValidateSet('zip', 'exe')][string]$PackageMode,
  [Parameter(Mandatory = $true)][string]$Version,
  [Parameter(Mandatory = $true)][string]$AssetPrefix,
  [Parameter(Mandatory = $true)][ValidateSet('stable', 'dev')][string]$UpdateChannel,
  [string]$LastFmApiKey = '',
  [string]$PubCacheArchiveName = ''
)

$ErrorActionPreference = 'Stop'

# Add Rust toolchain binaries to PATH for non-interactive SSH sessions.
# rustup installs zero-byte symlinks in .cargo/bin which don't work in SSH;
# we resolve the actual toolchain bin directory directly.
$rustupHome = if ($env:RUSTUP_HOME) { $env:RUSTUP_HOME } else { Join-Path $HOME '.rustup' }
$toolchainBin = Get-ChildItem (Join-Path $rustupHome 'toolchains') -Directory |
    Where-Object { $_.Name -match 'stable' } |
    Select-Object -First 1 |
    ForEach-Object { Join-Path $_.FullName 'bin' }
if ($toolchainBin -and (Test-Path $toolchainBin)) {
    $env:PATH = "$toolchainBin;$env:PATH"
}
# NOTE: do NOT add .cargo/bin — it contains 0-byte rustup proxy stubs that
# fail silently in non-interactive SSH sessions. The toolchain bin above has
# the real cargo.exe and rustc.exe binaries.

$baseDir = Join-Path $HOME $RemoteDir
$archivePath = Join-Path $baseDir $ArchiveName
$workspaceDir = Join-Path $baseDir 'workspace'
$assetNameFile = Join-Path $baseDir 'asset_name.txt'

if (Test-Path $workspaceDir) {
  # Kill any leftover build processes from a prior interrupted run that may
  # be holding file locks in the workspace directory.
  $ErrorActionPreference = 'Continue'
  @('dart','flutter','cmake','ninja','cargo','rustc','cl','link','MSBuild') | ForEach-Object {
    Stop-Process -Name $_ -Force -ErrorAction SilentlyContinue
  }
  Start-Sleep -Milliseconds 500
  Remove-Item -Recurse -Force $workspaceDir 2>$null
  if (Test-Path $workspaceDir) {
    # Fall back to cmd rd which can clear handles held by Defender/Search indexer
    cmd /c "rd /s /q `"$workspaceDir`"" 2>$null | Out-Null
  }
  $ErrorActionPreference = 'Stop'
  if (Test-Path $workspaceDir) {
    throw "Could not remove old workspace at $workspaceDir - a process is holding a lock"
  }
}
New-Item -ItemType Directory -Force -Path $workspaceDir | Out-Null

tar -xzf $archivePath -C $workspaceDir
Set-Location $workspaceDir

# Set up offline pub cache if a bundled archive was provided.
if ($PubCacheArchiveName -ne '') {
  $pubCacheArchivePath = Join-Path $baseDir $PubCacheArchiveName
  if (Test-Path $pubCacheArchivePath) {
    $localPubCache = Join-Path $baseDir 'pub_cache'
    $localPubCacheHosted = Join-Path $localPubCache 'hosted\pub.dev'
    New-Item -ItemType Directory -Force -Path $localPubCacheHosted | Out-Null
    tar -xzf $pubCacheArchivePath -C $localPubCacheHosted
    $env:PUB_CACHE = $localPubCache
    Write-Host "[remote-windows] Using bundled pub cache at $localPubCache"
  }
}

# Try online first; fall back to offline if network is unavailable (e.g. VM with no internet).
# If a bundled pub cache was provided, skip the online attempt and go straight to offline
# to avoid a multi-minute TCP timeout on VMs with no internet.
if ($env:PUB_CACHE -ne $null -and $env:PUB_CACHE -ne '') {
  flutter pub get --offline
} else {
  $ErrorActionPreference = 'Continue'
  flutter pub get 2>&1
  $_pubExit = $LASTEXITCODE
  $ErrorActionPreference = 'Stop'
  if ($_pubExit -ne 0) {
    Write-Warning "flutter pub get failed (network?); retrying with --offline"
    flutter pub get --offline
  }
}

# Locate VsDevCmd.bat — used later to run flutter build in a VS developer shell
# so that all subprocesses (cmake, MSBuild, cargokit, cargo) inherit link.exe.
$_devCmd = $null
$_vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path $_vswhere)) {
    $_vswhere = Join-Path $env:ProgramFiles 'Microsoft Visual Studio\Installer\vswhere.exe'
}
if (Test-Path $_vswhere) {
    $_vsInstall = ((& $_vswhere -latest -prerelease -property installationPath 2>$null) -join '').Trim()
    if ($_vsInstall -and (Test-Path $_vsInstall)) {
        $_candidate = Join-Path $_vsInstall 'Common7\Tools\VsDevCmd.bat'
        if (Test-Path $_candidate) { $_devCmd = $_candidate }
    }
}

# Patch cargokit's resolve_symlinks.ps1 if present.
# cargokit uses Get-Item on path components that may include hidden Windows
# system junctions (e.g. AppData), which fails without -Force in SSH sessions.
# Use .NET file APIs to bypass the PowerShell hidden-item restriction.
$_resolvePs1 = [System.IO.Path]::Combine($workspaceDir, 'windows', 'flutter', 'ephemeral', '.plugin_symlinks', 'smtc_windows', 'cargokit', 'cmake', 'resolve_symlinks.ps1')
if ([System.IO.File]::Exists($_resolvePs1)) {
    $_c = [System.IO.File]::ReadAllText($_resolvePs1)
    if ($_c -match 'Get-Item \$realPath' -and $_c -notmatch 'Get-Item -Force \$realPath') {
        [System.IO.File]::WriteAllText($_resolvePs1, ($_c -replace 'Get-Item \$realPath', 'Get-Item -Force $realPath'))
    }
}

$buildArgs = @(
  '--release',
  "--dart-define=NAVIS_UPDATE_CHANNEL=$UpdateChannel"
)
if ($LastFmApiKey -ne '') {
  $buildArgs += "--dart-define=NAVIS_LASTFM_API_KEY=$LastFmApiKey"
}

# Run flutter build inside a VS Developer Command Prompt so that every child
# process (cmake → MSBuild → cargokit → cargo) inherits link.exe/cl.exe from
# MSVC. Writing the command to a .cmd file avoids PowerShell quoting issues.
if ($_devCmd) {
    $_buildCmd = Join-Path $env:TEMP 'navis_flutter_build.cmd'
    $flutterArgs = 'build windows ' + ($buildArgs -join ' ')
    $cmdContent  = '@echo off' + [Environment]::NewLine
    $cmdContent += 'call "' + $_devCmd + '" -arch=x64 -host_arch=x64 -no_logo' + [Environment]::NewLine
    $cmdContent += 'if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%' + [Environment]::NewLine
    $cmdContent += 'cd /D "' + $workspaceDir + '"' + [Environment]::NewLine
    $cmdContent += 'flutter ' + $flutterArgs + [Environment]::NewLine
    [System.IO.File]::WriteAllText($_buildCmd, $cmdContent)
    cmd.exe /c $_buildCmd
    if ($LASTEXITCODE -ne 0) {
        throw "flutter build windows failed with exit code $LASTEXITCODE"
    }
} else {
    Write-Warning 'VsDevCmd.bat not found — building without VS developer environment'
    flutter build windows @buildArgs
}

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
scp "${PUB_CACHE_ARCHIVE}" "${SSH_TARGET}:${REMOTE_DIR}/pub_cache.tgz" >/dev/null
scp "${REMOTE_SCRIPT}" "${SSH_TARGET}:${REMOTE_DIR}/navis_remote_windows_build.ps1" >/dev/null

printf '[remote-windows] Running remote build...\n'
# Windows OpenSSH runs commands through cmd.exe, which doesn't treat single-quotes as
# string delimiters. Use backslash-separated path (no spaces) and omit quotes.
_win_script="${REMOTE_DIR//\//\\}\\navis_remote_windows_build.ps1"
_lastfm_arg=""
if [[ -n "${LASTFM_API_KEY}" ]]; then
  _lastfm_arg="-LastFmApiKey ${LASTFM_API_KEY}"
fi
ssh "${SSH_TARGET}" \
  "powershell -NoProfile -ExecutionPolicy Bypass -File ${_win_script} -RemoteDir ${REMOTE_DIR} -ArchiveName source.tgz -PubCacheArchiveName pub_cache.tgz -PackageMode ${PACKAGE_MODE} -Version ${VERSION} -AssetPrefix ${ASSET_PREFIX} -UpdateChannel ${UPDATE_CHANNEL} ${_lastfm_arg}"

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
