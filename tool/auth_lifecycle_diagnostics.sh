#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-clone}"
if [[ "$MODE" != "clone" ]]; then
  echo "Usage: $0 clone" >&2
  exit 64
fi

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DB="${NAVIS_DIAGNOSTICS_PRIMARY_DB:-$HOME/Documents/navis.sqlite.sqlite}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUTPUT_ROOT="$PROJECT_DIR/build/auth-lifecycle-diagnostics/$STAMP-clone"
HANDSHAKE="$OUTPUT_ROOT/handshake.json"
FIXTURE_HANDSHAKE="$OUTPUT_ROOT/fixture-handshake.json"
FIXTURE_LOG="$OUTPUT_ROOT/fixture.log"
CREDENTIAL_FILE="$OUTPUT_ROOT/fixture-password"
FIXTURE_FAILURE_FLAG="$OUTPUT_ROOT/fixture-sync-failure"
mkdir -p "$OUTPUT_ROOT"
chmod 700 "$OUTPUT_ROOT"

if [[ ! -f "$SOURCE_DB" ]]; then
  echo "Primary database not found: $SOURCE_DB" >&2
  exit 66
fi

FLUTTER_PID=0
FIXTURE_PID=0
FIXTURE_PORT=''
PORT=''
TOKEN=''
BASE_URL=''
APP_LOG=''

cleanup_app() {
  if (( FLUTTER_PID > 0 )) && kill -0 "$FLUTTER_PID" >/dev/null 2>&1; then
    kill "$FLUTTER_PID" >/dev/null 2>&1 || true
    wait "$FLUTTER_PID" >/dev/null 2>&1 || true
  fi
}

cleanup() {
  cleanup_app
  if (( FIXTURE_PID > 0 )) && kill -0 "$FIXTURE_PID" >/dev/null 2>&1; then
    kill "$FIXTURE_PID" >/dev/null 2>&1 || true
    wait "$FIXTURE_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

start_fixture() {
  printf '%s\n' 'navis-auth-lifecycle-fixture' > "$CREDENTIAL_FILE"
  chmod 600 "$CREDENTIAL_FILE"
  : > "$FIXTURE_LOG"
  python3 "$PROJECT_DIR/tool/auth_lifecycle_fixture_server.py" \
    --handshake "$FIXTURE_HANDSHAKE" \
    --failure-flag "$FIXTURE_FAILURE_FLAG" >>"$FIXTURE_LOG" 2>&1 &
  FIXTURE_PID=$!
  local deadline=$((SECONDS + 30))
  while [[ ! -s "$FIXTURE_HANDSHAKE" ]] && (( SECONDS < deadline )); do
    if ! kill -0 "$FIXTURE_PID" >/dev/null 2>&1; then
      echo "Fixture server exited before startup. See $FIXTURE_LOG" >&2
      exit 70
    fi
    sleep 1
  done
  if [[ ! -s "$FIXTURE_HANDSHAKE" ]]; then
    echo "Timed out waiting for fixture server. See $FIXTURE_LOG" >&2
    exit 70
  fi
  FIXTURE_PORT="$(python3 - "$FIXTURE_HANDSHAKE" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["port"])
PY
)"
}

clone_database() {
  local target_db="$1"
  local cache_root="$2"
  mkdir -p "$cache_root"
  python3 - "$SOURCE_DB" "$target_db" "$cache_root" "$FIXTURE_PORT" <<'PY'
import hashlib, os, sqlite3, sys
source = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
target = sqlite3.connect(sys.argv[2])
source.backup(target)
source.close()
cache_root = os.path.realpath(sys.argv[3])
fixture_url = f"http://127.0.0.1:{sys.argv[4]}"
for song_id, source_path in target.execute(
    "SELECT song_id, file_path FROM cached_tracks"
).fetchall():
    extension = os.path.splitext(source_path)[1] or ".isolated"
    name = hashlib.sha256(song_id.encode("utf-8")).hexdigest() + extension
    target.execute(
        "UPDATE cached_tracks SET file_path = ? WHERE song_id = ?",
        (os.path.join(cache_root, name), song_id),
    )
target.execute(
    """UPDATE server_config
       SET name = ?, url = ?, username = ?, api_version = ?, capabilities = NULL""",
    ("Navis lifecycle fixture", fixture_url, "diagnostics", "1.16.1"),
)
target.commit()
assert target.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
assert not target.execute("PRAGMA foreign_key_check").fetchall()
target.close()
PY
  chmod 600 "$target_db"
}

launch_app() {
  local database_path="$1"
  local label="$2"
  cleanup_app
  FLUTTER_PID=0
  APP_LOG="$OUTPUT_ROOT/$label-navis.log"
  rm -f "$HANDSHAKE"
  : > "$APP_LOG"
  flutter run -d linux --profile \
    --dart-define=NAVIS_UPDATE_CHANNEL=dev \
    --dart-define=NAVIS_APP_ID_SUFFIX=.dev \
    --dart-define=NAVIS_APP_NAME='Navis Auth Diagnostics' \
    --dart-define=NAVIS_SYNC_DIAGNOSTICS=true \
    --dart-define=NAVIS_SYNC_DIAGNOSTICS_MODE=clone \
    --dart-define="NAVIS_SYNC_DIAGNOSTICS_HANDSHAKE=$HANDSHAKE" \
    --dart-define="NAVIS_SYNC_DIAGNOSTICS_ROOT=$OUTPUT_ROOT" \
    --dart-define="NAVIS_SYNC_DIAGNOSTICS_DB_PATH=$database_path" \
    --dart-define="NAVIS_SYNC_DIAGNOSTICS_CREDENTIAL_PATH=$CREDENTIAL_FILE" \
    >>"$APP_LOG" 2>&1 &
  FLUTTER_PID=$!

  local deadline=$((SECONDS + 180))
  while [[ ! -s "$HANDSHAKE" ]] && (( SECONDS < deadline )); do
    if ! kill -0 "$FLUTTER_PID" >/dev/null 2>&1; then
      echo "Navis exited before diagnostics startup. See $APP_LOG" >&2
      exit 70
    fi
    sleep 1
  done
  if [[ ! -s "$HANDSHAKE" ]]; then
    echo "Timed out waiting for diagnostics API. See $APP_LOG" >&2
    exit 70
  fi
  read -r PORT TOKEN < <(python3 - "$HANDSHAKE" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
print(value["port"], value["token"])
PY
  )
  BASE_URL="http://127.0.0.1:$PORT"
}

stop_app() {
  if (( FLUTTER_PID > 0 )) && kill -0 "$FLUTTER_PID" >/dev/null 2>&1; then
    api POST /v1/shutdown >/dev/null 2>&1 || true
    local deadline=$((SECONDS + 30))
    while kill -0 "$FLUTTER_PID" >/dev/null 2>&1 && (( SECONDS < deadline )); do
      sleep 1
    done
    cleanup_app
  fi
  FLUTTER_PID=0
}

api() {
  local method="$1"
  local route="$2"
  local body="${3:-}"
  if [[ -n "$body" ]]; then
    curl --fail-with-body --silent --show-error \
      -X "$method" -H "Authorization: Bearer $TOKEN" \
      -H 'Content-Type: application/json' -d "$body" "$BASE_URL$route"
  else
    curl --fail-with-body --silent --show-error \
      -X "$method" -H "Authorization: Bearer $TOKEN" "$BASE_URL$route"
  fi
}

wait_for_session() {
  local expected_phase="$1"
  local expected_initial="$2"
  local output_file="$3"
  local timeout_seconds="${4:-300}"
  local deadline=$((SECONDS + timeout_seconds))
  while (( SECONDS < deadline )); do
    local status
    status="$(api GET /v1/session/status)"
    if python3 - "$expected_phase" "$expected_initial" "$status" <<'PY'
import json, sys
value = json.loads(sys.argv[3])
phase_ok = not sys.argv[1] or value.get("phase") == sys.argv[1]
initial_ok = not sys.argv[2] or value.get("initialSync") == sys.argv[2]
raise SystemExit(0 if phase_ok and initial_ok else 1)
PY
    then
      printf '%s\n' "$status" > "$output_file"
      return
    fi
    sleep 1
  done
  echo "Timed out waiting for session phase=$expected_phase initial=$expected_initial. See $APP_LOG" >&2
  exit 70
}

capture_screenshot() {
  local label="$1"
  local manifest="$2"
  api POST /v1/presentation/screenshot "{\"label\":\"$label\"}" > "$manifest"
  python3 - "$manifest" "$OUTPUT_ROOT" <<'PY'
import hashlib, json, os, stat, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
root = os.path.realpath(sys.argv[2])
artifact = value.get("artifact")
if not isinstance(artifact, str) or os.path.isabs(artifact):
    raise SystemExit("invalid screenshot artifact")
path = os.path.realpath(os.path.join(root, artifact))
if os.path.commonpath([root, path]) != root:
    raise SystemExit("screenshot escaped diagnostics root")
data = open(path, "rb").read()
assert data[:8] == b"\x89PNG\r\n\x1a\n"
assert len(data) == value.get("byteCount")
assert hashlib.sha256(data).hexdigest() == value.get("sha256")
assert stat.S_IMODE(os.stat(path).st_mode) == 0o600
print(path)
PY
}

assert_signed_out() {
  local status_file="$1"
  python3 - "$status_file" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
assert value["phase"] == "unauthenticated", value
assert value["transition"] == "idle", value
assert all(count == 0 for count in value["queues"].values()), value
assert not any(value["activity"].values()), value
PY
}

SETUP_DB="$OUTPUT_ROOT/setup-and-signout.sqlite"
CANCEL_DB="$OUTPUT_ROOT/cancel.sqlite"
start_fixture
clone_database "$SETUP_DB" "$OUTPUT_ROOT/setup-cache"
clone_database "$CANCEL_DB" "$OUTPUT_ROOT/cancel-cache"

cd "$PROJECT_DIR"
launch_app "$SETUP_DB" setup
api GET /v1/health > "$OUTPUT_ROOT/setup-health.json"
wait_for_session ready '' "$OUTPUT_ROOT/setup-ready-before-reset.json" 180
api POST /v1/diagnostics/overrides \
  '{"networkType":"offline","nativeMetered":false}' >/dev/null
api POST /v1/session/reset-initial-state > "$OUTPUT_ROOT/setup-reset.json"
wait_for_session initialSyncRequired waitingForNetwork \
  "$OUTPUT_ROOT/setup-waiting.json" 180
capture_screenshot setup-waiting \
  "$OUTPUT_ROOT/setup-waiting-screenshot.json" \
  > "$OUTPUT_ROOT/setup-waiting-screenshot-path.txt"

api POST /v1/diagnostics/overrides \
  '{"networkType":"cellular","nativeMetered":true}' >/dev/null
wait_for_session initialSyncRequired waitingForMobileConsent \
  "$OUTPUT_ROOT/setup-mobile-consent.json" 180
capture_screenshot setup-mobile-consent \
  "$OUTPUT_ROOT/setup-mobile-consent-screenshot.json" \
  > "$OUTPUT_ROOT/setup-mobile-consent-screenshot-path.txt"

: > "$FIXTURE_FAILURE_FLAG"
api POST /v1/diagnostics/overrides \
  '{"networkType":"wifi","nativeMetered":false}' >/dev/null
wait_for_session initialSyncRequired failed \
  "$OUTPUT_ROOT/setup-failed.json" 300
capture_screenshot setup-failed \
  "$OUTPUT_ROOT/setup-failed-screenshot.json" \
  > "$OUTPUT_ROOT/setup-failed-screenshot-path.txt"
rm -f "$FIXTURE_FAILURE_FLAG"
curl --fail-with-body --silent --show-error \
  -X POST -H "Authorization: Bearer $TOKEN" \
  "$BASE_URL/v1/session/initial-sync/retry" \
  > "$OUTPUT_ROOT/setup-retry-result.json" &
RETRY_REQUEST_PID=$!
wait_for_session initialSyncRequired running \
  "$OUTPUT_ROOT/setup-running.json" 300
capture_screenshot setup-running \
  "$OUTPUT_ROOT/setup-running-screenshot.json" \
  > "$OUTPUT_ROOT/setup-running-screenshot-path.txt"
wait "$RETRY_REQUEST_PID"
wait_for_session ready complete "$OUTPUT_ROOT/setup-complete.json" 14400
capture_screenshot setup-complete-home \
  "$OUTPUT_ROOT/setup-complete-screenshot.json" \
  > "$OUTPUT_ROOT/setup-complete-screenshot-path.txt"

stop_app
launch_app "$SETUP_DB" setup-restart
wait_for_session ready '' "$OUTPUT_ROOT/setup-clean-restart.json" 180

SONG_ID="$(python3 - "$SETUP_DB" <<'PY'
import sqlite3, sys
db = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
row = db.execute(
    "SELECT id FROM songs WHERE server_deleted_at IS NULL ORDER BY id LIMIT 1"
).fetchone()
db.close()
if row:
    print(row[0])
PY
)"
if [[ -z "$SONG_ID" ]]; then
  echo "Initial sync produced no playable songs." >&2
  exit 69
fi
PLAY_BODY="$(python3 - "$SONG_ID" <<'PY'
import json, sys
print(json.dumps({"songId": sys.argv[1]}))
PY
)"
api POST /v1/playback/start "$PLAY_BODY" >/dev/null
local_deadline=$((SECONDS + 90))
while (( SECONDS < local_deadline )); do
  status="$(api GET /v1/session/status)"
  if python3 - "$status" <<'PY'
import json, sys
value = json.loads(sys.argv[1])
raise SystemExit(0 if value["activity"]["playing"] else 1)
PY
  then
    printf '%s\n' "$status" > "$OUTPUT_ROOT/signout-playing.json"
    break
  fi
  sleep 1
done
if [[ ! -s "$OUTPUT_ROOT/signout-playing.json" ]]; then
  echo "Timed out waiting for real playback before sign-out. See $APP_LOG" >&2
  exit 70
fi
api POST /v1/session/sign-out '{"wipeLocalData":false}' \
  > "$OUTPUT_ROOT/signout-result.json"
assert_signed_out "$OUTPUT_ROOT/signout-result.json"
stop_app

launch_app "$CANCEL_DB" cancel
wait_for_session ready '' "$OUTPUT_ROOT/cancel-ready-before-reset.json" 180
api POST /v1/diagnostics/overrides \
  '{"networkType":"offline","nativeMetered":false}' >/dev/null
api POST /v1/session/reset-initial-state >/dev/null
wait_for_session initialSyncRequired waitingForNetwork \
  "$OUTPUT_ROOT/cancel-waiting.json" 180
api POST /v1/diagnostics/overrides \
  '{"networkType":"wifi","nativeMetered":false}' >/dev/null
wait_for_session initialSyncRequired running \
  "$OUTPUT_ROOT/cancel-running.json" 180
curl --fail-with-body --silent --show-error \
  -X POST -H "Authorization: Bearer $TOKEN" \
  "$BASE_URL/v1/session/initial-sync/cancel" \
  > "$OUTPUT_ROOT/cancel-result.json" &
CANCEL_REQUEST_PID=$!
cancel_deadline=$((SECONDS + 30))
while (( SECONDS < cancel_deadline )); do
  cancel_status="$(api GET /v1/session/status)"
  if python3 - "$cancel_status" <<'PY'
import json, sys
value = json.loads(sys.argv[1])
raise SystemExit(0 if value.get("initialSync") == "cancelling" else 1)
PY
  then
    printf '%s\n' "$cancel_status" > "$OUTPUT_ROOT/cancel-cancelling.json"
    capture_screenshot setup-cancelling \
      "$OUTPUT_ROOT/setup-cancelling-screenshot.json" \
      > "$OUTPUT_ROOT/setup-cancelling-screenshot-path.txt"
    break
  fi
  sleep 0.02
done
wait "$CANCEL_REQUEST_PID"
assert_signed_out "$OUTPUT_ROOT/cancel-result.json"
capture_screenshot setup-cancelled-login \
  "$OUTPUT_ROOT/setup-cancelled-login-screenshot.json" \
  > "$OUTPUT_ROOT/setup-cancelled-login-screenshot-path.txt"
api GET /v1/health > "$OUTPUT_ROOT/cancel-health.json"
python3 - "$OUTPUT_ROOT/cancel-health.json" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
assert all(count == 0 for count in value["catalog"].values()), value
PY
stop_app

launch_app "$CANCEL_DB" cancel-restart
wait_for_session unauthenticated '' "$OUTPUT_ROOT/cancel-clean-restart.json" 180
stop_app

if rg -n 'Unhandled Exception|Tried to modify a provider while|NavisDatabase multiple times' \
  "$OUTPUT_ROOT"/*-navis.log; then
  echo "Auth lifecycle diagnostics found a fatal log pattern." >&2
  exit 1
fi

echo "Auth lifecycle diagnostics passed: $OUTPUT_ROOT"
