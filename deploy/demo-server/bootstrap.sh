#!/usr/bin/env bash
# Host-side setup of the demo Navidrome seed database.
#   ./bootstrap.sh                 first run: admin + reviewer + scan + export seeds
#   ./bootstrap.sh rotate-reviewer change the reviewer password in the master seed
# Two seeds: the MASTER (with the admin) stays in DEMO_MASTER_DIR, which is never
# mounted into the container; the PUBLIC seed (DEMO_SEED_DIR, mounted at /seed)
# is derived from it with the admin user deleted, so the public server has no admin.
# Reads .env next to this script. Secrets come from the env, are never echoed
# and never appear in process arguments. Talks to 127.0.0.1 only.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

for c in docker curl jq openssl; do
  command -v "$c" >/dev/null || { echo "[bootstrap] missing: $c" >&2; exit 1; }
done
[[ -f .env ]] || { echo "[bootstrap] .env missing (see .env.example)" >&2; exit 1; }
# Reviewer vars passed on the command line win over .env (rotation).
o_user="${DEMO_REVIEWER_USER:-}"; o_pass="${DEMO_REVIEWER_PASSWORD:-}"
set -a; . ./.env; set +a
DEMO_REVIEWER_USER="${o_user:-${DEMO_REVIEWER_USER:-}}"; DEMO_REVIEWER_PASSWORD="${o_pass:-${DEMO_REVIEWER_PASSWORD:-}}"
: "${DEMO_DATA_DIR:?}" "${DEMO_SEED_DIR:?}" "${DEMO_MASTER_DIR:?}" "${DEMO_REVIEWER_USER:?}" "${DEMO_REVIEWER_PASSWORD:?}"
PORT="${DEMO_PORT:-4535}"
BASE="http://127.0.0.1:${PORT}/demo"
SEED="${DEMO_SEED_DIR}/navidrome.db"
MASTER="${DEMO_MASTER_DIR}/navidrome.db"
SQLITE_IMAGE="keinos/sqlite3:3.47.2@sha256:4e75252fb72327cdcb67ced362d76299acd1fbe829629f22ae2ab9d25b35ec54"
cmd="${1:-bootstrap}"

tmp="$(mktemp -d)"; chmod 700 "$tmp"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT
log() { echo "[bootstrap] $*"; }
dc() { docker compose "$@"; }

start_bootstrap() {
  DEMO_BOOTSTRAP=1 dc up -d --force-recreate
  for _ in $(seq 1 60); do
    curl -fsS -o /dev/null "$BASE/ping" 2>/dev/null && return 0
    sleep 1
  done
  log "navidrome did not come up; see: docker compose logs" >&2; exit 1
}

# post_json URL JSON [TOKEN] -> response body on stdout. Secrets via files/stdin only.
post_json() {
  local url="$1" body="$2" token="${3:-}" method="${4:-POST}"
  printf '%s' "$body" > "$tmp/body"
  { printf 'header = "Content-Type: application/json"\n'
    [[ -n "$token" ]] && printf 'header = "x-nd-authorization: Bearer %s"\n' "$token"
    true; } | curl -fsS -K - -X "$method" --data-binary @"$tmp/body" "$url"
}
get_json() {
  printf 'header = "x-nd-authorization: Bearer %s"\n' "$2" | curl -fsS -K - "$1"
}
login() { # user pass -> token
  post_json "$BASE/auth/login" "$(jq -nc --arg u "$1" --arg p "$2" '{username:$u,password:$p}')" | jq -r .token
}
subsonic() { # user pass method [extra form fields...] -> body
  local u="$1" p="$2" m="$3"; shift 3
  { printf 'u=%s&p=%s&f=json&v=1.16.1&c=demo-bootstrap' "$u" "$p"
    for kv in "$@"; do printf '&%s' "$kv"; done; } > "$tmp/form"
  curl -fsS --data-binary @"$tmp/form" "$BASE/rest/$m"
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
  install -m 600 "$tmp/pub.db" "$SEED"
  log "public seed derived (admin removed, $(stat -c %s "$SEED") bytes)"
}

export_seed() {
  dc stop
  [[ -s "$DEMO_DATA_DIR/navidrome.db" ]] || { log "no database to export" >&2; exit 1; }
  if [[ -s "$DEMO_DATA_DIR/navidrome.db-wal" ]]; then
    log "WAL not checkpointed after stop; refusing to export a partial seed" >&2; exit 1
  fi
  install -m 600 "$DEMO_DATA_DIR/navidrome.db" "$MASTER"
  derive_public
}

case "$cmd" in
bootstrap)
  : "${DEMO_ADMIN_CREDS_FILE:?}"
  if [[ ( -f "$SEED" || -f "$MASTER" ) && "${DEMO_FORCE:-0}" != 1 ]]; then
    log "seed exists; use rotate-reviewer, or DEMO_FORCE=1 to rebuild from scratch" >&2; exit 1
  fi
  dc down 2>/dev/null || true
  rm -f "$SEED" "$MASTER" "$DEMO_DATA_DIR"/navidrome.db*
  start_bootstrap
  admin_user="adm-$(openssl rand -hex 6)"
  admin_pass="$(openssl rand -hex 24)"
  post_json "$BASE/auth/createAdmin" "$(jq -nc --arg u "$admin_user" --arg p "$admin_pass" '{username:$u,password:$p}')" >/dev/null
  token="$(login "$admin_user" "$admin_pass")"
  post_json "$BASE/api/user" "$(jq -nc --arg u "$DEMO_REVIEWER_USER" --arg p "$DEMO_REVIEWER_PASSWORD" \
    '{userName:$u,name:$u,email:"",password:$p,isAdmin:false}')" "$token" >/dev/null
  # Full scan, then wait until it reports idle with songs indexed.
  subsonic "$admin_user" "$admin_pass" startScan fullScan=true >/dev/null
  for _ in $(seq 1 600); do
    st="$(subsonic "$admin_user" "$admin_pass" getScanStatus)"
    [[ "$(jq -r '."subsonic-response".scanStatus.scanning' <<<"$st")" == false ]] && \
      [[ "$(jq -r '."subsonic-response".scanStatus.count // 0' <<<"$st")" -gt 0 ]] && break
    sleep 1
  done
  log "scan finished: $(jq -r '."subsonic-response".scanStatus.count // 0' <<<"$st") files"
  ( umask 077; printf 'user=%s\npassword=%s\n' "$admin_user" "$admin_pass" > "$DEMO_ADMIN_CREDS_FILE" )
  chmod 600 "$DEMO_ADMIN_CREDS_FILE"
  unset admin_pass token
  export_seed
  ;;
rotate-reviewer)
  : "${DEMO_ADMIN_CREDS_FILE:?}"
  [[ -f "$MASTER" ]] || { log "no master seed; run bootstrap first" >&2; exit 1; }
  dc down 2>/dev/null || true
  rm -f "$DEMO_DATA_DIR"/navidrome.db*
  install -m 600 "$MASTER" "$DEMO_DATA_DIR/navidrome.db"   # bootstrap mode starts from the master
  admin_user="$(sed -n 's/^user=//p' "$DEMO_ADMIN_CREDS_FILE")"
  admin_pass="$(sed -n 's/^password=//p' "$DEMO_ADMIN_CREDS_FILE")"
  start_bootstrap
  token="$(login "$admin_user" "$admin_pass")"
  rid="$(get_json "$BASE/api/user?_start=0&_end=100" "$token" | jq -r --arg u "$DEMO_REVIEWER_USER" '.[]|select(.userName==$u)|.id')"
  [[ -n "$rid" ]] || { log "reviewer not found" >&2; exit 1; }
  post_json "$BASE/api/user/$rid" "$(jq -nc --arg u "$DEMO_REVIEWER_USER" --arg p "$DEMO_REVIEWER_PASSWORD" \
    '{userName:$u,name:$u,password:$p,isAdmin:false}')" "$token" PUT >/dev/null
  unset admin_pass token
  export_seed
  ;;
*) echo "usage: $0 [bootstrap|rotate-reviewer]" >&2; exit 2 ;;
esac

dc up -d --force-recreate   # DEMO_BOOTSTRAP unset in .env => normal mode (seed copy)
log "done"
