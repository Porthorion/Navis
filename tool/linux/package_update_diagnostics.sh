#!/usr/bin/env bash
# Linux package updater R1–R9 harness. Only staging is touched; never stable/dev.
# Usage (each command is foreground; cleanup is explicit and restartable):
#   tool/linux/package_update_diagnostics.sh build
#   tool/linux/package_update_diagnostics.sh publish
#   tool/linux/package_update_diagnostics.sh run --host=user@debian-host
#   tool/linux/package_update_diagnostics.sh run --host=user@debian-host --repeat=3
#   tool/linux/package_update_diagnostics.sh run --host=user@debian-host --corrupt
#   tool/linux/package_update_diagnostics.sh run --host=user@debian-host --manual
#   tool/linux/package_update_diagnostics.sh run --host=user@fedora-host --family=rpm
#   tool/linux/package_update_diagnostics.sh run --containers
#   tool/linux/package_update_diagnostics.sh cleanup [--host=user@host]
# All commands accept --run-dir=PATH (default build/linux-package-update-diagnostics).
# build creates per-run 1.4.N packages; publish builds/publishes N+1 and N+2,
# corrupts N+2 at origin before its public URL is fetched, then restores N+1's
# signed envelope. Needs tool/release.env, the pinned signing key, Docker/Flutter.
# Remote run needs SSH, sudo, Python 3, curl and an existing graphical session.
# R1: owner authenticates at the real polkit prompt. R2: owner installs/removes
# a temporary polkit rule; --repeat=3 reinstalls N before each cycle.
# R3/R4/R5-swap/R6: --manual pauses after download; use the app's update dialog
# to cancel, test a session without an agent, swap the artifact at confirm, or
# contend the dpkg lock. It captures an app-owned screenshot and requires the
# package/pid to remain unchanged. Inspect UI and journal before accepting.
# R5-download: --corrupt asserts integrity_mismatch with no install/relaunch.
# R7: --family=rpm on a Fedora graphical host (VM or Xvfb with a single executable
# test elevator wrapper, if separately built). R8: manual AUR/unknown-owner UI
# check plus update_dialog_test.dart; do not call the download API in that mode.
# R9: --containers checks ownership in the three verify_packages.sh images, then
# installs N+1 over N using the actual root script, without GUI or polkit.
# Publishing requires an empty/older staging channel; ordering guards stay intact.
# Never run concurrently against the shared staging channel. This replaces a
# real installed package; cleanup removes it ONLY if absent before this run.
# Existing installations remain at the test version; restore them manually.
set +x
set -euo pipefail
umask 077
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo"
# Source only helpers: no app launch, publication, traps or profile preparation.
# shellcheck source=../r2_update_diagnostics.sh
source "$repo/tool/r2_update_diagnostics.sh"
# shellcheck source=../lib/r2_storage.sh
source "$repo/tool/lib/r2_storage.sh"
mode="${1:?build|publish|run|cleanup}"; shift
run_dir="$repo/build/linux-package-update-diagnostics"
host=''; family=deb; repeat=1; corrupt=false; manual=false; containers=false
for arg in "$@"; do
  case "$arg" in
    --run-dir=*) run_dir="${arg#*=}" ;;
    --host=*) host="${arg#*=}" ;;
    --family=*) family="${arg#*=}" ;;
    --repeat=*) repeat="${arg#*=}" ;;
    --corrupt) corrupt=true ;;
    --manual) manual=true ;;
    --containers) containers=true ;;
    *) echo 'Unknown option' >&2; exit 64 ;;
  esac
done
[[ "$mode" =~ ^(build|publish|run|cleanup)$ && "$family" =~ ^(deb|rpm)$ && "$repeat" =~ ^[1-9][0-9]?$ ]] || exit 64
[[ "$corrupt" != true || "$manual" != true ]] || exit 64
[[ -z "$host" || "$host" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.@:-]*$ ]] || exit 64
mkdir -p "$run_dir"
run_dir="$(cd "$run_dir" && pwd)"
chmod 700 "$run_dir"
exec 8>"$run_dir/lock"
flock -n 8 || { echo 'This run is already in use' >&2; exit 75; }
if [[ "$mode" == build ]]; then
  [[ ! -e "$run_dir/patch" ]] || { echo 'Use a fresh --run-dir for a new build' >&2; exit 64; }
  date +%s > "$run_dir/patch"
fi
N="$(cat "$run_dir/patch")"
[[ "$N" =~ ^[1-9][0-9]{8,}$ ]] || exit 64
remote_root="/tmp/navis-package-update-$N"
unit="navis-package-update-$N"
HANDSHAKE="$run_dir/handshake.json"
LOG="$run_dir/navis.log"
tunnel_dir="$(mktemp -d "${TMPDIR:-/tmp}/navis-pkg-tunnel.XXXXXX")"
socket="$tunnel_dir/control"
# Close/reap our SSH tunnel on every path; package/channel cleanup stays explicit.
close_tunnel() {
  if [[ -S "$socket" && -n "$host" ]]; then
    ssh -S "$socket" -O exit "$host" >/dev/null 2>&1 || true
  fi
}
trap 'close_tunnel; rm -rf -- "$tunnel_dir"' EXIT
load_r2() {
  # shellcheck source=/dev/null
  source "$repo/tool/release.env"
  : "${R2_ACCOUNT_ID:?}" "${R2_BUCKET:?}" "${R2_ACCESS_KEY_ID:?}" "${R2_SECRET_ACCESS_KEY:?}"
  R2_PREFIX="${R2_PREFIX:-navis}"
}
activate() {
  s3_curl --fail -o /dev/null -T "$run_dir/$1.json" -H 'Cache-Control: no-cache' \
    "$(s3_url channels/staging/manifest.json)"
}
package_name() {
  if [[ "$family" == deb ]]; then echo "navis-v1.4.$1-linux-amd64.deb"
  else echo "navis-v1.4.$1-linux-x86_64.rpm"; fi
}
build_packages() {
  local patch="$1" file
  bash tool/linux/build_in_container.sh --package=all --version="v1.4.$patch" \
    --build-mode=profile --build-name="1.4.$patch" --build-number=1 \
    --dart-define=NAVIS_UPDATE_CHANNEL=staging \
    --dart-define=NAVIS_APP_ID_SUFFIX=.dev \
    --dart-define='NAVIS_APP_NAME=Navis Package Update Diagnostics' \
    --dart-define=NAVIS_SYNC_DIAGNOSTICS=true \
    --dart-define=NAVIS_SYNC_DIAGNOSTICS_MODE=clone \
    --dart-define="NAVIS_SYNC_DIAGNOSTICS_HANDSHAKE=$remote_root/handshake.json" \
    --dart-define="NAVIS_SYNC_DIAGNOSTICS_ROOT=$remote_root" \
    --dart-define="NAVIS_SYNC_DIAGNOSTICS_DB_PATH=$remote_root/clone.sqlite"
  for file in "navis-v1.4.$patch-linux-amd64.deb" "navis-v1.4.$patch-linux-x86_64.rpm" "navis-v1.4.$patch-linux.tar.gz"; do
    mv "$repo/$file" "$run_dir/"
  done
}
remote() {
  local command
  printf -v command '%q ' bash -s -- "$@"
  ssh "$host" "$command"
}
package_version() {
  remote "$family" <<'REMOTE'
set -euo pipefail
if [[ "$1" == deb ]]; then dpkg-query -W -f='${Version}' navis
else rpm -q --qf '%{VERSION}' navis; fi
REMOTE
}
connect_api() {
  close_tunnel
  rm -f "$HANDSHAKE"
  local deadline=$((SECONDS + 180))
  while (( SECONDS < deadline )); do
    if ssh "$host" "cat '$remote_root/handshake.json'" > "$HANDSHAKE.tmp" 2>/dev/null && [[ -s "$HANDSHAKE.tmp" ]]; then
      mv "$HANDSHAKE.tmp" "$HANDSHAKE"; break
    fi
    sleep 1
  done
  [[ -s "$HANDSHAKE" ]] || { echo 'No remote handshake; inspect the user journal' >&2; exit 70; }
  read_handshake
  ssh -M -S "$socket" -fNT -o ExitOnForwardFailure=yes \
    -L "127.0.0.1:$PORT:127.0.0.1:$PORT" "$host"
  wait_handshake
}
assert_remote() {
  remote "$APP_PID" "${1:-0}" <<'REMOTE'
set -euo pipefail
kill -0 "$1"
[[ "$(readlink -f "/proc/$1/exe")" == /opt/navis/navis ]]
if [[ "$2" != 0 ]]; then [[ ! -e "/proc/$2" ]]; fi
[[ -z "$(find /var/tmp -maxdepth 1 -name 'navis-update.*' -print -quit)" ]]
if command -v dpkg >/dev/null; then [[ -z "$(dpkg --audit)" ]]; fi
REMOTE
}
run_remote() {
  [[ -n "$host" ]] || { echo 'run needs --host or --containers' >&2; exit 64; }
  if [[ -f "$run_dir/host" ]]; then
    [[ "$(cat "$run_dir/host")" == "$host" && "$(cat "$run_dir/family")" == "$family" ]] || { echo 'Use a separate run directory per host/family' >&2; exit 64; }
  else
    remote "$family" > "$run_dir/original-package" <<'REMOTE'
set -euo pipefail
if [[ "$1" == deb ]]; then
  dpkg-query -W -f='${db:Status-Status} ${Version}\n' navis 2>/dev/null || true
else rpm -q --qf 'installed %{VERSION}\n' navis 2>/dev/null || true; fi
REMOTE
    printf '%s\n' "$family" > "$run_dir/family"
    printf '%s\n' "$host" > "$run_dir/host"
  fi
  scp -q "$run_dir/$(package_name "$N")" "$host:$remote_root.pkg.$family"
  local iteration old_pid result screenshot
  for ((iteration=1; iteration<=repeat; iteration++)); do
    remote "$remote_root" "$unit" <<'REMOTE'
set -euo pipefail
export XDG_RUNTIME_DIR="/run/user/$(id -u)" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
systemctl --user stop "$2" 2>/dev/null || true
mkdir -p "$1"; chmod 700 "$1"
rm -f "$1/handshake.json"
REMOTE
    if [[ "$family" == deb ]]; then
      ssh -t "$host" "sudo apt-get -o DPkg::Lock::Timeout=120 install -y --allow-downgrades '$remote_root.pkg.deb'"
    else
      ssh -t "$host" "sudo dnf downgrade -y '$remote_root.pkg.rpm' || sudo dnf install -y '$remote_root.pkg.rpm'"
    fi
    [[ "$(package_version)" == "1.4.$N" ]] || { echo 'Base package version mismatch' >&2; exit 70; }
    remote "$remote_root" "$unit" <<'REMOTE'
set -euo pipefail
export XDG_RUNTIME_DIR="/run/user/$(id -u)" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
environment=(); graphical=false
while IFS= read -r entry; do
  case "$entry" in
    DISPLAY=*|WAYLAND_DISPLAY=*) environment+=(--setenv="$entry"); graphical=true ;;
    XAUTHORITY=*|DBUS_SESSION_BUS_ADDRESS=*|XDG_RUNTIME_DIR=*|XDG_SESSION_TYPE=*|XDG_CURRENT_DESKTOP=*) environment+=(--setenv="$entry") ;;
  esac
done < <(systemctl --user show-environment)
[[ "$graphical" == true ]] || { echo 'No graphical session environment in user manager' >&2; exit 70; }
systemd-run --user --unit="$2" --collect --property=ExitType=cgroup \
  --setenv="XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR" --setenv="DBUS_SESSION_BUS_ADDRESS=$DBUS_SESSION_BUS_ADDRESS" \
  "${environment[@]}" /opt/navis/navis
REMOTE
    connect_api
    old_pid="$APP_PID"
    api POST /v1/diagnostics/update/check > "$run_dir/check-$iteration.json"
    result="$(cat "$run_dir/check-$iteration.json")"
    [[ "$(field tag <<< "$result")" == "v1.4.$((N+1))" && "$(field signatureValid <<< "$result")" == True ]] || { echo 'Expected signed offer missing' >&2; exit 70; }
    local expected_key=linuxDeb-amd64
    [[ "$family" == deb ]] || expected_key=linuxRpm-x86_64
    [[ "$(field assetKey <<< "$result")" == "$expected_key" ]] || exit 70
    if [[ "$corrupt" == true ]]; then
      activate corrupt
      api POST /v1/diagnostics/update/download > "$run_dir/corrupt-result.json"
      result="$(cat "$run_dir/corrupt-result.json")"
      activate good
      [[ "$(field downloadError <<< "$result")" == integrity_mismatch && "$(field downloaded <<< "$result")" == False ]] || exit 70
    elif [[ "$manual" == true ]]; then
      api POST /v1/diagnostics/update/download > "$run_dir/manual-download.json"
      echo 'Use the app update dialog for R3/R4/R5-swap/R6; leave the package unchanged.'
      read -r -p 'Press Enter after the error/cancellation is visible: ' _
      api POST /v1/presentation/screenshot '{"label":"package-update-manual"}' > "$run_dir/manual-screenshot.json"
      [[ "$(field status < "$run_dir/manual-screenshot.json")" == captured ]] || exit 70
      screenshot="$(field artifact < "$run_dir/manual-screenshot.json")"
      [[ "$screenshot" =~ ^screenshots/[a-zA-Z0-9_-]+\.png$ ]] || exit 70
      scp -q "$host:$remote_root/$screenshot" "$run_dir/manual-screenshot.png"
      ssh "$host" "journalctl --user -u '$unit' --no-pager" > "$LOG"
    else
      api POST /v1/diagnostics/update/download > "$run_dir/download-$iteration.json"
      [[ "$(field downloaded < "$run_dir/download-$iteration.json")" == True ]] || exit 70
      ssh "$host" "rm -f '$remote_root/handshake.json'"
      api POST /v1/diagnostics/update/download '{"apply":true}' > "$run_dir/apply-$iteration.json"
      [[ "$(field applying < "$run_dir/apply-$iteration.json")" == True ]] || exit 70
      connect_api
      [[ "$APP_PID" != "$old_pid" && "$(package_version)" == "1.4.$((N+1))" ]] || exit 70
      assert_remote "$old_pid"
      echo "PASS: package upgraded, new pid, old pid gone, root temp directories removed (cycle $iteration)"
      continue
    fi
    [[ "$APP_PID" == "$old_pid" && "$(package_version)" == "1.4.$N" ]] || exit 70
    assert_remote
    echo 'PASS: package unchanged, original process alive, no root temp directories'
  done
  api POST /v1/shutdown >/dev/null
}
run_containers() {
  NAVIS_LINUX_PACKAGE_DIR="$run_dir" bash tool/linux/verify_packages.sh "v1.4.$N"
  # Extract the literal production script; do not maintain a second installer.
  python3 - "$run_dir/root-install.sh" <<'PY'
import pathlib, re, sys
source = pathlib.Path('lib/src/features/settings/data/update_scripts.dart').read_text()
script = re.search(r"const String linuxPackageInstallScript = r'''(.*?)''';", source, re.S)
assert script, 'Production package install script not found'
pathlib.Path(sys.argv[1]).write_text(script[1])
PY
  local image
  for image in ubuntu:22.04 debian:12 fedora:latest; do
    docker run --rm -i --memory=2g --memory-swap=2g --cpus=2 \
      --mount "type=bind,src=$run_dir,dst=/packages,readonly" -e N="$N" "$image" bash -s <<'CONTAINER'
set -euo pipefail
if command -v dpkg-query >/dev/null; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y "/packages/navis-v1.4.$N-linux-amd64.deb"
  [[ "$(dpkg-query -S /opt/navis/navis)" == 'navis: /opt/navis/navis' ]]
  artifact="/packages/navis-v1.4.$((N+1))-linux-amd64.deb"; family=deb
else
  dnf --setopt=zchunk=False install -y "/packages/navis-v1.4.$N-linux-x86_64.rpm"
  [[ "$(rpm -qf /opt/navis/navis)" == "$(rpm -q navis)" ]]
  artifact="/packages/navis-v1.4.$((N+1))-linux-x86_64.rpm"; family=rpm
fi
sha="$(sha256sum < "$artifact")"
/bin/sh /packages/root-install.sh "$artifact" "${sha%% *}" "$family"
if [[ "$family" == deb ]]; then [[ "$(dpkg-query -W -f='${Version}' navis)" == "1.4.$((N+1))" ]]
else [[ "$(rpm -q --qf '%{VERSION}' navis)" == "1.4.$((N+1))" ]]; fi
[[ -z "$(find /var/tmp -maxdepth 1 -name 'navis-update.*' -print -quit)" ]]
echo 'PASS: package owner and real root-script upgrade'
CONTAINER
  done
}
case "$mode" in
  build) build_packages "$N" ;;
  publish)
    load_r2
    bash tool/r2_publish.sh check --channel=staging --tag="v1.4.$((N+1))" \
      > "$run_dir/preflight.log" 2>&1
    for patch in "$((N+1))" "$((N+2))"; do
      build_packages "$patch"
      label=good; [[ "$patch" != "$((N+2))" ]] || label=corrupt
      # Do not duplicate signing, manifest generation or publication preconditions.
      bash tool/r2_publish.sh publish --channel=staging --tag="v1.4.$patch" \
        --manifest-out="$run_dir/$label.json" \
        "$run_dir/navis-v1.4.$patch-linux-amd64.deb" "$run_dir/navis-v1.4.$patch-linux-x86_64.rpm" \
        "$run_dir/navis-v1.4.$patch-linux.tar.gz" \
        > "$run_dir/publish-$patch.log" 2>&1
    done
    for family in deb rpm; do
      file="$(package_name "$((N+2))")"
      # Keep signed size, change bytes; query-string verification by the publisher
      # did not populate the app's never-requested bare public asset URL.
      size="$(stat -c %s "$run_dir/$file")"
      head -c "$size" /dev/zero > "$run_dir/corrupt-package"
      s3_curl --fail -o /dev/null -T "$run_dir/corrupt-package" \
        "$(s3_url "releases/v1.4.$((N+2))/$file")"
    done
    activate good
    echo 'Published signed good/corrupt staging fixtures' ;;
  run)
    if [[ "$containers" == true ]]; then run_containers
    else load_r2; activate good; run_remote; fi ;;
  cleanup)
    load_r2
    # Remove the manifest only if it still belongs to this run.
    status="$(s3_curl -o "$run_dir/current.json" -w '%{http_code}' "$(s3_url channels/staging/manifest.json)")"
    if [[ "$status" == 200 ]]; then
      tag="$(jq -r .payload "$run_dir/current.json" | base64 -d | jq -r .tag)"
      if [[ "$tag" == "v1.4.$((N+1))" || "$tag" == "v1.4.$((N+2))" ]]; then
        s3_curl --fail -o /dev/null -X DELETE "$(s3_url channels/staging/manifest.json)"
      fi
    elif [[ "$status" != 404 ]]; then exit 70; fi
    for patch in "$((N+1))" "$((N+2))"; do
      for file in "navis-v1.4.$patch-linux-amd64.deb" "navis-v1.4.$patch-linux-x86_64.rpm" "navis-v1.4.$patch-linux.tar.gz" SHA256SUMS.staging; do
        s3_curl --fail -o /dev/null -X DELETE "$(s3_url "releases/v1.4.$patch/$file")"
      done
    done
    if [[ -f "$run_dir/host" ]]; then
      [[ -f "$run_dir/original-package" ]] || exit 70
      recorded_host="$(cat "$run_dir/host")"
      [[ -z "$host" || "$host" == "$recorded_host" ]] || exit 64
      host="$recorded_host"; family="$(cat "$run_dir/family")"
      remote "$unit" "$remote_root" <<'REMOTE'
set -euo pipefail
export XDG_RUNTIME_DIR="/run/user/$(id -u)" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
systemctl --user stop "$1" 2>/dev/null || true
rm -rf -- "$2" "$2.pkg.deb" "$2.pkg.rpm"
REMOTE
      if ! grep -q '^installed ' "$run_dir/original-package"; then
        version="$(package_version 2>/dev/null || true)"
        if [[ "$version" == "1.4.$N" || "$version" == "1.4.$((N+1))" || "$version" == "1.4.$((N+2))" ]]; then
          if [[ "$family" == deb ]]; then ssh -t "$host" 'sudo apt-get remove -y navis'
          else ssh -t "$host" 'sudo dnf remove -y navis'; fi
        fi
      else echo 'Pre-existing package retained; restore its original version manually'; fi
    fi
    rm -f "$HANDSHAKE" "$HANDSHAKE.tmp"
    echo 'Staging objects and task-owned remote state cleaned' ;;
esac
