#!/usr/bin/env bash
# Host-side setup of the demo Navidrome seed databases. Run as DEMO_UID.
#   ./bootstrap.sh                  first run: admin + reviewer + scan + export seeds
#   ./bootstrap.sh rotate-reviewer  change the reviewer password (master seed)
#   ./bootstrap.sh rescan           re-scan the library into the master seed (keeps passwords)
# Two seeds: the MASTER (with the admin) stays in DEMO_MASTER_DIR, which is never
# mounted into the container; the PUBLIC seed (DEMO_SEED_DIR, mounted at /seed)
# is derived from it with the admin user deleted, so the public server has no admin.
# Bootstrap mode never runs on the public port: the public service is stopped,
# a separate container (restart "no") runs on 127.0.0.1:DEMO_BOOT_PORT, and an
# EXIT trap removes it and restarts the public service in normal mode on the
# previous (or new) public seed, also when something fails.
# Reads .env next to this script (shell-sourced). Secrets come from the env, are
# never echoed and never appear in process arguments. Talks to 127.0.0.1 only.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

for c in docker curl jq openssl; do
  command -v "$c" >/dev/null || { echo "[bootstrap] missing: $c" >&2; exit 1; }
done
[[ -f .env ]] || { echo "[bootstrap] .env missing (see .env.example)" >&2; exit 1; }
cmd="${1:-bootstrap}"
# Reviewer vars passed on the command line win over .env (rotation).
o_user="${DEMO_REVIEWER_USER:-}"; o_pass="${DEMO_REVIEWER_PASSWORD:-}"
set -a; . ./.env; set +a
DEMO_REVIEWER_USER="${o_user:-${DEMO_REVIEWER_USER:-}}"; DEMO_REVIEWER_PASSWORD="${o_pass:-${DEMO_REVIEWER_PASSWORD:-}}"
: "${DEMO_DATA_DIR:?}" "${DEMO_SEED_DIR:?}" "${DEMO_MASTER_DIR:?}" "${DEMO_ADMIN_CREDS_FILE:?}" "${DEMO_UID:?}"
[[ "$(id -u)" == "$DEMO_UID" ]] || { echo "[bootstrap] run as uid $DEMO_UID (owner of the data and seed dirs)" >&2; exit 1; }
BOOT_PORT="${DEMO_BOOT_PORT:-4536}"
BASE="http://127.0.0.1:${BOOT_PORT}/demo"
SEED="${DEMO_SEED_DIR}/navidrome.db"
MASTER="${DEMO_MASTER_DIR}/navidrome.db"
SQLITE_IMAGE="keinos/sqlite3:3.47.2@sha256:4e75252fb72327cdcb67ced362d76299acd1fbe829629f22ae2ab9d25b35ec54"
PROJ="${COMPOSE_PROJECT_NAME:-$(basename "$PWD")}"

tmp="$(mktemp -d)"; chmod 700 "$tmp"
log() { echo "[bootstrap] $*"; }
dc() { docker compose "$@"; }                                   # public service
dcb() { DEMO_BOOTSTRAP=1 DEMO_RESTART=no DEMO_PORT="$BOOT_PORT" docker compose -p "${PROJ}-boot" "$@"; }

stopped_public=0
cleanup() {
  local rc=$?
  trap - EXIT
  dcb down >/dev/null 2>&1 || true
  rm -rf "$tmp"
  if ((stopped_public)); then
    if [[ -s "$SEED" ]]; then
      dc up -d --force-recreate >/dev/null 2>&1 && log "public service restored" || { log "FAILED to restore the public service" >&2; rc=1; }
    else
      log "no public seed yet; public service left stopped" >&2
    fi
  fi
  exit "$rc"
}
trap cleanup EXIT

# atomic_install SRC DEST: temp file in the same dir, then rename (mode 600).
atomic_install() {
  local t; t="$(mktemp "$(dirname "$2")/.tmp.XXXXXX")"
  cat "$1" > "$t" && chmod 600 "$t" && mv -f "$t" "$2" || { rm -f "$t"; return 1; }
}

start_bootstrap() {   # stop the public service, run bootstrap mode on the boot port
  if [[ -n "$(dc ps -q 2>/dev/null)" ]]; then dc stop >/dev/null; fi
  stopped_public=1
  dcb up -d --force-recreate >/dev/null
  for _ in $(seq 1 60); do
    curl -fsS -o /dev/null "$BASE/ping" 2>/dev/null && return 0
    sleep 1
  done
  log "navidrome did not come up; see: docker compose -p ${PROJ}-boot logs" >&2; exit 1
}

# post_json URL JSON [TOKEN] [METHOD] -> response body. Secrets via files/stdin only.
post_json() {
  local url="$1" body="$2" token="${3:-}" method="${4:-POST}"
  printf '%s' "$body" > "$tmp/body"
  { printf 'header = "Content-Type: application/json"\n'
    [[ -n "$token" ]] && printf 'header = "x-nd-authorization: Bearer %s"\n' "$token"
    true; } | curl -fsS -K - -X "$method" --data-binary @"$tmp/body" "$url"
}
get_json() { printf 'header = "x-nd-authorization: Bearer %s"\n' "$2" | curl -fsS -K - "$1"; }
login() { # user pass -> token
  post_json "$BASE/auth/login" "$(NU="$1" NP="$2" jq -nc '{username:env.NU,password:env.NP}')" | jq -r .token
}
subsonic() { # user pass method [extra form fields...] -> body
  local u="$1" p="$2" m="$3"; shift 3
  { printf 'u=%s&p=%s&f=json&v=1.16.1&c=demo-bootstrap' "$u" "$p"
    for kv in "$@"; do printf '&%s' "$kv"; done; } > "$tmp/form"
  curl -fsS --data-binary @"$tmp/form" "$BASE/rest/$m"
}

# Full scan as admin; fails (non-zero) on timeout or an empty library.
scan_library() { # user pass
  local before st n
  before="$(subsonic "$1" "$2" getScanStatus | jq -r '."subsonic-response".scanStatus.lastScan // ""')"
  subsonic "$1" "$2" startScan fullScan=true >/dev/null
  for _ in $(seq 1 600); do
    st="$(subsonic "$1" "$2" getScanStatus)"
    if [[ "$(jq -r '."subsonic-response".scanStatus.scanning' <<<"$st")" == false &&
          "$(jq -r '."subsonic-response".scanStatus.lastScan // ""' <<<"$st")" != "$before" ]]; then
      n="$(jq -r '."subsonic-response".scanStatus.count // 0' <<<"$st")"
      [[ "$n" -gt 0 ]] || { log "scan found 0 songs; refusing to export" >&2; exit 1; }
      log "scan finished: $n files"; return 0
    fi
    sleep 1
  done
  log "scan did not finish within 10 minutes" >&2; exit 1
}

sql() { docker run --rm -i --network none --user "$(id -u):$(id -g)" -v "$tmp:/w" "$SQLITE_IMAGE" sqlite3 "$@"; }

# Public seed = master minus every admin user (and rows that reference them).
# Deleted explicitly per table (all FKs also cascade) and VACUUMed so no admin
# data stays in free pages. Aborts unless a non-admin user remains (an empty user
# table would let the first visitor create an admin).
derive_public() {
  install -m 600 "$MASTER" "$tmp/pub.db"
  sql /w/pub.db <<'SQL' >/dev/null
PRAGMA journal_mode=DELETE;
PRAGMA foreign_keys=ON;
CREATE TEMP TABLE admins AS SELECT id FROM user WHERE is_admin=1;
DELETE FROM bookmark WHERE user_id IN admins;
DELETE FROM user_props WHERE user_id IN admins;
DELETE FROM player WHERE user_id IN admins;
DELETE FROM share WHERE user_id IN admins;
DELETE FROM playqueue WHERE user_id IN admins;
DELETE FROM annotation WHERE user_id IN admins;
DELETE FROM user_library WHERE user_id IN admins;
DELETE FROM playlist WHERE owner_id IN admins;
DELETE FROM scrobble_buffer WHERE user_id IN admins;
DELETE FROM scrobbles WHERE user_id IN admins;
DELETE FROM user WHERE id IN admins;
VACUUM;
SQL
  [[ "$(sql /w/pub.db 'SELECT count(*) FROM user WHERE is_admin=1')" == 0 ]] || { log "admin still present" >&2; exit 1; }
  [[ "$(sql /w/pub.db 'SELECT count(*) FROM user')" -ge 1 ]] || { log "no user left in public seed" >&2; exit 1; }
  [[ -z "$(sql /w/pub.db 'PRAGMA foreign_key_check')" ]] || { log "foreign key violations" >&2; exit 1; }
  [[ "$(sql /w/pub.db 'PRAGMA integrity_check')" == ok ]] || { log "integrity check failed" >&2; exit 1; }
  atomic_install "$tmp/pub.db" "$SEED"
  log "public seed derived (admin removed, $(stat -c %s "$SEED") bytes)"
}

export_seed() {
  dcb stop >/dev/null
  [[ -s "$DEMO_DATA_DIR/navidrome.db" ]] || { log "no database to export" >&2; exit 1; }
  if [[ -s "$DEMO_DATA_DIR/navidrome.db-wal" ]]; then
    log "WAL not checkpointed after stop; refusing to export a partial seed" >&2; exit 1
  fi
  atomic_install "$DEMO_DATA_DIR/navidrome.db" "$MASTER"
  derive_public
}

# Start bootstrap mode on a copy of the master seed.
start_from_master() {
  [[ -f "$MASTER" ]] || { log "no master seed; run bootstrap first" >&2; exit 1; }
  if [[ -n "$(dc ps -q 2>/dev/null)" ]]; then dc stop >/dev/null; fi
  stopped_public=1
  rm -f "$DEMO_DATA_DIR"/navidrome.db*
  install -m 600 "$MASTER" "$DEMO_DATA_DIR/navidrome.db"
  start_bootstrap
}
admin_login() { # sets admin_user admin_pass token
  admin_user="$(sed -n 's/^user=//p' "$DEMO_ADMIN_CREDS_FILE")"
  admin_pass="$(sed -n 's/^password=//p' "$DEMO_ADMIN_CREDS_FILE")"
  token="$(login "$admin_user" "$admin_pass")"
  [[ -n "$token" && "$token" != null ]] || { log "admin login failed" >&2; exit 1; }
}

case "$cmd" in
bootstrap)
  : "${DEMO_REVIEWER_USER:?}" "${DEMO_REVIEWER_PASSWORD:?}"
  if [[ ( -f "$SEED" || -f "$MASTER" ) && "${DEMO_FORCE:-0}" != 1 ]]; then
    log "seed exists; use rotate-reviewer or rescan, or DEMO_FORCE=1 to rebuild from scratch" >&2; exit 1
  fi
  # Existing seeds stay in place until the new ones are built (atomic replace at the end).
  if [[ -n "$(dc ps -q 2>/dev/null)" ]]; then dc stop >/dev/null; fi
  stopped_public=1
  rm -f "$DEMO_DATA_DIR"/navidrome.db*
  start_bootstrap
  admin_user="adm-$(openssl rand -hex 6)"
  admin_pass="$(openssl rand -hex 24)"
  post_json "$BASE/auth/createAdmin" "$(NU="$admin_user" NP="$admin_pass" jq -nc '{username:env.NU,password:env.NP}')" >/dev/null
  token="$(login "$admin_user" "$admin_pass")"
  post_json "$BASE/api/user" "$(NU="$DEMO_REVIEWER_USER" NP="$DEMO_REVIEWER_PASSWORD" jq -nc \
    '{userName:env.NU,name:env.NU,email:"",password:env.NP,isAdmin:false}')" "$token" >/dev/null
  scan_library "$admin_user" "$admin_pass"
  ( umask 077; printf 'user=%s\npassword=%s\n' "$admin_user" "$admin_pass" > "$tmp/creds" )
  atomic_install "$tmp/creds" "$DEMO_ADMIN_CREDS_FILE"
  unset admin_pass token
  export_seed
  ;;
rotate-reviewer)
  : "${DEMO_REVIEWER_USER:?}" "${DEMO_REVIEWER_PASSWORD:?}"
  start_from_master
  admin_login
  rid="$(get_json "$BASE/api/user?_start=0&_end=100" "$token" | NU="$DEMO_REVIEWER_USER" jq -r '.[]|select(.userName==env.NU)|.id')"
  [[ -n "$rid" ]] || { log "reviewer not found" >&2; exit 1; }
  post_json "$BASE/api/user/$rid" "$(NU="$DEMO_REVIEWER_USER" NP="$DEMO_REVIEWER_PASSWORD" jq -nc \
    '{userName:env.NU,name:env.NU,password:env.NP,isAdmin:false}')" "$token" PUT >/dev/null
  unset admin_pass token
  export_seed
  ;;
rescan)
  start_from_master
  admin_login
  scan_library "$admin_user" "$admin_pass"
  unset admin_pass token
  export_seed
  ;;
*) echo "usage: $0 [bootstrap|rotate-reviewer|rescan]" >&2; exit 2 ;;
esac
log "done"
