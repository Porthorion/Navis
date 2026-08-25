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
  --flutter-dir=<path>     Optional Flutter SDK directory on the Windows host
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
FLUTTER_DIR=""
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
    --flutter-dir=*) FLUTTER_DIR="${arg#--flutter-dir=}" ;;
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
  rm -f "${SOURCE_ARCHIVE}" "${PUB_CACHE_ARCHIVE}" "${REMOTE_SCRIPT}" "${_sqlite3_dll_tmp:-}"
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
# flutter pub get --offline even without internet access. Also include the
# vendored SMTC adapter's cargokit build-tool dependencies, which are pinned
# independently from the main app.
printf '[remote-windows] Bundling pub package cache...\n'
_pub_cache_host="${HOME}/.pub-cache/hosted/pub.dev"
_lock_file="${REPO_ROOT}/pubspec.lock"
# The first-party Windows adapter ships cargokit with its own lockfile.
_cargokit_lock="${REPO_ROOT}/third_party/navis_windows_smtc/cargokit/build_tool/pubspec.lock"
_pkg_dirs=()
_seen=()
_collect_lock_pkgs() {
  local _lf="$1"
  if [[ -f "${_lf}" ]]; then
    while IFS= read -r _pkg; do
      if [[ -d "${_pub_cache_host}/${_pkg}" ]]; then
        local _already=0
        for _s in "${_seen[@]}"; do [[ "$_s" == "$_pkg" ]] && _already=1 && break; done
        if [[ $_already -eq 0 ]]; then
          _pkg_dirs+=("${_pkg}")
          _seen+=("${_pkg}")
        fi
      fi
    done < <(python3 - "${_lf}" <<'PYEOF'
import sys, re
with open(sys.argv[1]) as f:
    content = f.read()
for m in re.finditer(r'^\s{2}(\S+):\n(?:.*\n)*?.*?version:\s*"([^"]+)"', content, re.MULTILINE):
    print(f"{m.group(1)}-{m.group(2)}")
PYEOF
)
  fi
}
if [[ -d "${_pub_cache_host}" ]]; then
  _collect_lock_pkgs "${_lock_file}"
  _collect_lock_pkgs "${_cargokit_lock}"
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
  [string]$PubCacheArchiveName = '',
  [string]$Sqlite3DllName = '',
  [string]$FlutterDir = ''
)

$ErrorActionPreference = 'Stop'

if ($FlutterDir -ne '') {
    $flutterBin = Join-Path $FlutterDir 'bin'
    $flutterCommand = Join-Path $flutterBin 'flutter.bat'
    if (-not (Test-Path $flutterCommand)) {
        throw "Flutter SDK not found at $FlutterDir"
    }
    $env:PATH = "$flutterBin;$env:PATH"
    Write-Host "[remote-windows] Using Flutter SDK at $FlutterDir"
}

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

# Set up offline pub cache. We always use the system-default PUB_CACHE
# (C:\Users\...\AppData\Local\Pub\Cache) so that:
#  - The hooks_runner shared cache (sqlite3.dll, etc.) is preserved across runs
#  - Content hashes match what Windows originally fetched
# If a bundled archive is provided, we supplement the system cache with any
# packages that might be missing (extracted with --skip-old-files so we never
# overwrite existing Windows-native copies with Linux-packed ones).
$_systemPubCache = if ($env:PUB_CACHE) { $env:PUB_CACHE } else { Join-Path $env:LOCALAPPDATA 'Pub\Cache' }
if ($PubCacheArchiveName -ne '') {
  $pubCacheArchivePath = Join-Path $baseDir $PubCacheArchiveName
  if (Test-Path $pubCacheArchivePath) {
    $localPubCacheHosted = Join-Path $_systemPubCache 'hosted\pub.dev'
    New-Item -ItemType Directory -Force -Path $localPubCacheHosted | Out-Null
    # Extract all bundled packages into the system pub cache. Content-hash
    # mismatch warnings may appear for packages already present (Linux vs
    # Windows line endings) but these are non-fatal. bsdtar (Windows tar.exe)
    # does not support GNU tar's --skip-old-files so we always overwrite.
    $ErrorActionPreference = 'Continue'
    tar -xzf $pubCacheArchivePath -C $localPubCacheHosted
    if ($LASTEXITCODE -ne 0) {
      Write-Host "[remote-windows] WARNING: tar extraction returned $LASTEXITCODE"
    } else {
      Write-Host "[remote-windows] Supplemented system pub cache with bundled packages"
    }
    $ErrorActionPreference = 'Stop'
  }
}
Write-Host "[remote-windows] Using system pub cache at $_systemPubCache"

# Always run offline to avoid a multi-minute TCP timeout on VMs with no internet.
$ErrorActionPreference = 'Continue'
flutter pub get --offline
if ($LASTEXITCODE -ne 0) { throw "flutter pub get --offline failed with exit code $LASTEXITCODE" }
$ErrorActionPreference = 'Stop'

# Pre-seed cmake download cache with pre-built native assets so the build works
# without internet access. media_kit_libs_windows_audio downloads libmpv from
# GitHub releases; if a valid copy is already on this machine, reuse it.
$_cmakeBuildDir = Join-Path $workspaceDir 'build\windows\x64'
New-Item -ItemType Directory -Force -Path $_cmakeBuildDir | Out-Null
$_libmpvName = 'mpv-dev-x86_64-20230924-git-652a1dd.7z'
$_libmpvMd5  = 'cd738e16e2a19626d7cfa48801524f8c'
$_libmpvDest = Join-Path $_cmakeBuildDir $_libmpvName
if (-not (Test-Path $_libmpvDest)) {
  # Search common locations where a prior local build may have cached the file.
  $_libmpvSourceDirs = @(
    (Join-Path $HOME 'Documents\forgejo_projects\Navis\build\windows\x64'),
    (Join-Path $HOME 'My Documents\forgejo_projects\Navis\build\windows\x64')
  )
  foreach ($_srcDir in $_libmpvSourceDirs) {
    $_src = Join-Path $_srcDir $_libmpvName
    if (Test-Path $_src) {
      $_srcMd5 = (Get-FileHash $_src -Algorithm MD5).Hash.ToLower()
      if ($_srcMd5 -eq $_libmpvMd5) {
        Copy-Item $_src $_libmpvDest
        Write-Host "[remote-windows] Pre-seeded libmpv from $_src"
        break
      }
    }
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
$_resolvePs1 = [System.IO.Path]::Combine($workspaceDir, 'windows', 'flutter', 'ephemeral', '.plugin_symlinks', 'navis_windows_smtc', 'cargokit', 'cmake', 'resolve_symlinks.ps1')
if ([System.IO.File]::Exists($_resolvePs1)) {
    $_c = [System.IO.File]::ReadAllText($_resolvePs1)
    if ($_c -match 'Get-Item \$realPath' -and $_c -notmatch 'Get-Item -Force \$realPath') {
        [System.IO.File]::WriteAllText($_resolvePs1, ($_c -replace 'Get-Item \$realPath', 'Get-Item -Force $realPath'))
    }
}

# Pre-seed sqlite3 native asset DLL so the hooks_runner doesn't try to
# download it from GitHub. sqlite3 uses native assets (hook/build.dart) to
# download sqlite3.dll at build time. On this VM github.com downloads fail.
# Priority: use the bundled DLL shipped with the source archive; fall back to
# any cached DLL from a prior local build on this machine.
$_sqlite3SharedDir = [System.IO.Path]::Combine($workspaceDir, '.dart_tool', 'hooks_runner', 'shared', 'sqlite3', 'build', 'download-bundled')
$_sqlite3OfflineDir = [System.IO.Path]::Combine($workspaceDir, '.dart_tool', 'offline_native_assets', 'sqlite3')
New-Item -ItemType Directory -Force -Path $_sqlite3SharedDir | Out-Null
New-Item -ItemType Directory -Force -Path $_sqlite3OfflineDir | Out-Null
$_sqlite3Seeded = $false
if ($Sqlite3DllName -ne '' -and (Test-Path (Join-Path $baseDir $Sqlite3DllName))) {
    Copy-Item (Join-Path $baseDir $Sqlite3DllName) (Join-Path $_sqlite3SharedDir 'sqlite3.dll') -Force
    Copy-Item (Join-Path $baseDir $Sqlite3DllName) (Join-Path $_sqlite3OfflineDir 'sqlite3.x64.windows.dll') -Force
    Write-Host "[remote-windows] Pre-seeded sqlite3 native asset from bundled DLL"
    $_sqlite3Seeded = $true
}
if (-not $_sqlite3Seeded) {
    $_sqlite3SrcBase = [System.IO.Path]::Combine($HOME, 'Documents', 'forgejo_projects', 'Navis', '.dart_tool', 'hooks_runner', 'shared', 'sqlite3', 'build')
    if (Test-Path $_sqlite3SrcBase) {
        $ErrorActionPreference = 'Continue'
        Get-ChildItem $_sqlite3SrcBase -Directory | ForEach-Object {
            $_srcFile = Join-Path $_.FullName 'sqlite3.dll'
            if ((Test-Path $_srcFile) -and -not $_sqlite3Seeded) {
                Copy-Item $_srcFile (Join-Path $_sqlite3SharedDir 'sqlite3.dll') -Force
                Copy-Item $_srcFile (Join-Path $_sqlite3OfflineDir 'sqlite3.x64.windows.dll') -Force
                Write-Host "[remote-windows] Pre-seeded sqlite3 native asset from $_srcFile"
                $_sqlite3Seeded = $true
            }
        }
        $ErrorActionPreference = 'Stop'
    }
}

if ($_sqlite3Seeded) {
    $_pubspecPath = Join-Path $workspaceDir 'pubspec.yaml'
    $_pubspecContent = [System.IO.File]::ReadAllText($_pubspecPath)
    if ($_pubspecContent -notmatch '(?m)^hooks:') {
        Add-Content -Path $_pubspecPath -Value @'

hooks:
  user_defines:
    sqlite3:
      source: test-sqlite3
      directory: .dart_tool/offline_native_assets/sqlite3/
'@
        Write-Host "[remote-windows] Configured sqlite3 native hook to use bundled DLL"
        $ErrorActionPreference = 'Continue'
        $_dillDir = [System.IO.Path]::Combine($workspaceDir, '.dart_tool', 'hooks_runner', 'sqlite3')
        if (Test-Path $_dillDir) { Remove-Item -Recurse -Force $_dillDir 2>$null }
        $ErrorActionPreference = 'Stop'
        flutter pub get --offline
        if ($LASTEXITCODE -ne 0) { throw "flutter pub get --offline after sqlite3 hook config failed with exit code $LASTEXITCODE" }
    }
}

# Patch all sqlite3-X.Y.Z versions found in the pub cache to add an offline
# fallback that scans sibling download-* directories in the shared output dir
# (where we already pre-seeded the DLL above) and copies the DLL to the
# expected location before any network download is attempted.
# The hook downloads sqlite3.dll from GitHub into a subdirectory whose name
# is derived from Object.hash(), which is non-deterministic across Dart VM
# runs — we cannot pre-seed the exact path, only sibling directories.
$_sqlite3PubBase = Join-Path $_systemPubCache 'hosted\pub.dev'
$_dlMarker = '    final tmp = File(''${downloadedFile.path}.tmp'');'
$_fallback = @'
    // Offline fallback: before attempting a network download, check if the
    // DLL already exists in any sibling download-* directory (pre-seeded).
    final sharedBuildDir = dir.parent;
    if (sharedBuildDir.existsSync()) {
      for (final entry in sharedBuildDir.listSync().whereType<Directory>()) {
        final candidate = File(p.join(entry.path, fileName));
        if (candidate.existsSync() && candidate.path != downloadedFile.path) {
          candidate.copySync(downloadedFile.path);
          return downloadedFile;
        }
      }
    }
    final tmp = File('${downloadedFile.path}.tmp');
'@
Get-ChildItem $_sqlite3PubBase -Directory | Where-Object { $_.Name -like 'sqlite3-*' } | ForEach-Object {
    $_sqlite3DescPath = Join-Path $_.FullName 'lib\src\hook\description.dart'
    if (Test-Path $_sqlite3DescPath) {
        $_descContent = [System.IO.File]::ReadAllText($_sqlite3DescPath)
        if ($_descContent.Contains($_dlMarker) -and -not $_descContent.Contains('Offline fallback')) {
            $_descContent = $_descContent.Replace($_dlMarker, $_fallback)
            [System.IO.File]::WriteAllText($_sqlite3DescPath, $_descContent)
            Write-Host "[remote-windows] Patched $($_.Name) description.dart with offline fallback"
            $ErrorActionPreference = 'Continue'
            $_dillDir = [System.IO.Path]::Combine($workspaceDir, '.dart_tool', 'hooks_runner', 'sqlite3')
            if (Test-Path $_dillDir) { Remove-Item -Recurse -Force $_dillDir 2>$null }
            $ErrorActionPreference = 'Stop'
        }
    }
}

# Patch cargokit's run_build_tool.cmd to use --offline for pub get.
# cargokit creates a temporary pubspec and runs "dart pub get --no-precompile"
# to resolve the build_tool path dependency. On a VM with no internet access
# this silently fails, leaving package_config.json absent and causing
# "Couldn't resolve the package 'build_tool'" at compile time.
# Adding --offline makes it resolve from $PUB_CACHE (our bundled cache).
$_cargokitRoot = [System.IO.Path]::Combine($workspaceDir, 'windows', 'flutter', 'ephemeral', '.plugin_symlinks', 'navis_windows_smtc', 'cargokit')
$_runBuildToolCmd = [System.IO.Path]::Combine($_cargokitRoot, 'run_build_tool.cmd')
if ([System.IO.File]::Exists($_runBuildToolCmd)) {
    $_c = [System.IO.File]::ReadAllText($_runBuildToolCmd)
    if ($_c -match 'pub get --no-precompile' -and $_c -notmatch 'pub get --no-precompile --offline') {
        [System.IO.File]::WriteAllText($_runBuildToolCmd, ($_c -replace 'pub get --no-precompile', 'pub get --no-precompile --offline'))
        Write-Host "[remote-windows] Patched cargokit run_build_tool.cmd to use --offline pub get"
    }
}

$buildArgs = @(
  '--release',
  '--no-pub',
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

# Download sqlite3 Windows DLL from GitHub on the local machine (which has
# internet access) and transfer it to the Windows VM so it can be pre-seeded
# into the hooks_runner shared directory, bypassing the network-dependent hook.
_sqlite3_version="$(grep -A8 '^  sqlite3:$' "${REPO_ROOT}/pubspec.lock" | grep 'version:' | head -1 | sed 's/.*version: *"\([^"]*\)".*/\1/')"
_sqlite3_dll_name=""
_sqlite3_dll_tmp=""
if [[ -n "${_sqlite3_version}" ]]; then
  _sqlite3_dll_url="https://github.com/simolus3/sqlite3.dart/releases/download/sqlite3-${_sqlite3_version}/sqlite3.x64.windows.dll"
  _sqlite3_dll_tmp="$(mktemp -t sqlite3_windows.XXXXXX.dll)"
  printf '[remote-windows] Downloading sqlite3 v%s Windows DLL from GitHub...\n' "${_sqlite3_version}"
  if curl -fsSL "${_sqlite3_dll_url}" -o "${_sqlite3_dll_tmp}" 2>/dev/null; then
    _sqlite3_dll_name="sqlite3-${_sqlite3_version}-x64.dll"
    scp "${_sqlite3_dll_tmp}" "${SSH_TARGET}:${REMOTE_DIR}/${_sqlite3_dll_name}" >/dev/null
    printf '[remote-windows] Transferred sqlite3 DLL to remote.\n'
  else
    printf '[remote-windows] Warning: could not download sqlite3 DLL from GitHub; will try local cache on Windows.\n'
  fi
fi

printf '[remote-windows] Running remote build...\n'
# Windows OpenSSH runs commands through cmd.exe, which doesn't treat single-quotes as
# string delimiters. Use backslash-separated path (no spaces) and omit quotes.
_win_script="${REMOTE_DIR//\//\\}\\navis_remote_windows_build.ps1"
_lastfm_arg=""
if [[ -n "${LASTFM_API_KEY}" ]]; then
  _lastfm_arg="-LastFmApiKey ${LASTFM_API_KEY}"
fi
_sqlite3_dll_arg=""
if [[ -n "${_sqlite3_dll_name}" ]]; then
  _sqlite3_dll_arg="-Sqlite3DllName ${_sqlite3_dll_name}"
fi
_flutter_arg=""
if [[ -n "${FLUTTER_DIR}" ]]; then
  _flutter_arg="-FlutterDir ${FLUTTER_DIR}"
fi
ssh "${SSH_TARGET}" \
  "powershell -NoProfile -ExecutionPolicy Bypass -File ${_win_script} -RemoteDir ${REMOTE_DIR} -ArchiveName source.tgz -PubCacheArchiveName pub_cache.tgz -PackageMode ${PACKAGE_MODE} -Version ${VERSION} -AssetPrefix ${ASSET_PREFIX} -UpdateChannel ${UPDATE_CHANNEL} ${_flutter_arg} ${_lastfm_arg} ${_sqlite3_dll_arg}"

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
