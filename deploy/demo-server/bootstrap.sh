#!/usr/bin/env bash
# Host-side setup of the demo Navidrome seed database.
#   ./bootstrap.sh                 first run: admin + reviewer + scan + export seed
#   ./bootstrap.sh rotate-reviewer change the reviewer password in the current seed
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
: "${DEMO_DATA_DIR:?}" "${DEMO_SEED_DIR:?}" "${DEMO_REVIEWER_USER:?}" "${DEMO_REVIEWER_PASSWORD:?}"
PORT="${DEMO_PORT:-4535}"
BASE="http://127.0.0.1:${PORT}/demo"
SEED="${DEMO_SEED_DIR}/navidrome.db"
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

export_seed() {
  dc stop
  [[ -s "$DEMO_DATA_DIR/navidrome.db" ]] || { log "no database to export" >&2; exit 1; }
  if [[ -s "$DEMO_DATA_DIR/navidrome.db-wal" ]]; then
    log "WAL not checkpointed after stop; refusing to export a partial seed" >&2; exit 1
  fi
  install -m 600 "$DEMO_DATA_DIR/navidrome.db" "$SEED"
  log "seed exported ($(stat -c %s "$SEED") bytes)"
}

case "$cmd" in
bootstrap)
  : "${DEMO_ADMIN_CREDS_FILE:?}"
  if [[ -f "$SEED" && "${DEMO_FORCE:-0}" != 1 ]]; then
    log "seed exists; use rotate-reviewer, or DEMO_FORCE=1 to rebuild from scratch" >&2; exit 1
  fi
  dc down 2>/dev/null || true
  rm -f "$SEED" "$DEMO_DATA_DIR"/navidrome.db*
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
  [[ -f "$SEED" ]] || { log "no seed; run bootstrap first" >&2; exit 1; }
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
