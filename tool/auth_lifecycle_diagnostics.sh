#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-clone}"
if [[ "$MODE" != "clone" && "$MODE" != "partial" &&
      "$MODE" != "existing-catalog" ]]; then
  echo "Usage: $0 [clone|partial|existing-catalog]" >&2
  exit 64
fi

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_DIR/tool/lib/diagnostics.sh"
SOURCE_DB="$(python3 "$PROJECT_DIR/tool/diagnostics_profile.py" primary-db)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUTPUT_ROOT="$PROJECT_DIR/build/auth-lifecycle-diagnostics/$STAMP-$MODE"
HANDSHAKE="$OUTPUT_ROOT/handshake.json"
FIXTURE_HANDSHAKE="$OUTPUT_ROOT/fixture-handshake.json"
FIXTURE_LOG="$OUTPUT_ROOT/fixture.log"
CREDENTIAL_FILE="$OUTPUT_ROOT/fixture-password"
FIXTURE_FAILURE_FLAG="$OUTPUT_ROOT/fixture-sync-failure"
PARTIAL_ALBUM_FLAG="$OUTPUT_ROOT/fixture-partial-album"
ALBUM_ERROR_FLAG="$OUTPUT_ROOT/fixture-album-error"
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

cleanup() {
  cleanup_fixture_app
}
trap cleanup EXIT INT TERM

start_fixture() {
  printf '%s\n' 'navis-auth-lifecycle-fixture' > "$CREDENTIAL_FILE"
  chmod 600 "$CREDENTIAL_FILE"
  : > "$FIXTURE_LOG"
  local fixture_args=(
    --handshake "$FIXTURE_HANDSHAKE"
    --failure-flag "$FIXTURE_FAILURE_FLAG"
  )
  if [[ "$MODE" == "partial" || "$MODE" == "existing-catalog" ]]; then
    fixture_args+=(
      --scenario partial-album
      --partial-album-flag "$PARTIAL_ALBUM_FLAG"
      --album-error-flag "$ALBUM_ERROR_FLAG"
    )
  fi
  python3 "$PROJECT_DIR/tool/auth_lifecycle_fixture_server.py" \
    "${fixture_args[@]}" >>"$FIXTURE_LOG" 2>&1 &
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
    --dart-define=NAVIS_SYNC_DIAGNOSTICS_MUTED=true \
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

# Polls the route phase without starting a setup controller.
wait_for_phase() {
  local expected_phase="$1"
  local output_file="$2"
  local timeout_seconds="${3:-180}"
  local deadline=$((SECONDS + timeout_seconds))
  while (( SECONDS < deadline )); do
    local status
    status="$(api GET '/v1/session/status')"
    if python3 - "$expected_phase" "$status" <<'PY'
import json, sys
raise SystemExit(0 if json.loads(sys.argv[2]).get("phase") == sys.argv[1] else 1)
PY
    then
      printf '%s\n' "$status" > "$output_file"
      return
    fi
    sleep 1
  done
  echo "Timed out waiting for session phase=$expected_phase. See $APP_LOG" >&2
  exit 70
}

# Waits for the setup screen's own initial-login rebuild controller to reach
# one of the space-separated statuses in $1.
wait_for_rebuild_status() {
  local expected="$1"
  local output_file="$2"
  local timeout_seconds="${3:-300}"
  local deadline=$((SECONDS + timeout_seconds))
  while (( SECONDS < deadline )); do
    api GET '/v1/presentation/library-rebuild?reason=initial-login' \
      > "$output_file"
    if python3 - "$output_file" "$expected" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
raise SystemExit(0 if value.get("status") in sys.argv[2].split() else 1)
PY
    then
      return
    fi
    sleep 0.5
  done
  echo "Timed out waiting for the setup screen status $expected. See $APP_LOG" >&2
  exit 70
}

# Waits for the initial-login rebuild controller to leave its active states.
wait_for_rebuild_settled() {
  local output_file="$1"
  local timeout_seconds="${2:-300}"
  local deadline=$((SECONDS + timeout_seconds))
  while (( SECONDS < deadline )); do
    api GET '/v1/presentation/library-rebuild?reason=initial-login' \
      > "$output_file"
    if python3 - "$output_file" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
raise SystemExit(0 if value.get("status") in ("failed", "complete") else 1)
PY
    then
      return
    fi
    sleep 1
  done
  echo "Timed out waiting for the initial-login rebuild to settle. See $APP_LOG" >&2
  exit 70
}

# Waits for the initial-login rebuild to settle after a new session. On
# timeout it records the route, controller state, ledger and a screenshot
# before failing, so a stuck setup screen leaves evidence.
wait_for_resumed_setup() {
  local label="$1"
  local baseline="$2"
  local timeout_seconds="${3:-300}"
  local deadline=$((SECONDS + timeout_seconds))
  local output_file="$OUTPUT_ROOT/$label-rebuild.json"
  local ledger_file="$OUTPUT_ROOT/$label-ledger.json"
  while (( SECONDS < deadline )); do
    api GET '/v1/presentation/library-rebuild?reason=initial-login' \
      > "$output_file"
    api GET /v1/sync/ledger > "$ledger_file"
    # A settled status alone could be left over from an earlier visit; the
    # new session must also have recorded its own catalog run.
    if python3 - "$output_file" "$ledger_file" "$baseline" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
ledger = json.load(open(sys.argv[2], encoding="utf-8"))
# Only the setup controller issues these intents; an automatic timer pass
# must not stand in for the setup screen's own run.
ran = any(
    run.get("requestId", 0) > int(sys.argv[3])
    and run.get("targetKind") == "catalog"
    and run.get("intent") in ("manualCatalogCheck", "repairLibrary")
    for run in ledger["durableRuns"]
)
# A finished visit leaves the route and its controller is disposed, so
# `inactive` after the visit's own run also means it settled.
raise SystemExit(
    0 if ran and value.get("status") in ("failed", "complete", "inactive") else 1
)
PY
    then
      return
    fi
    sleep 1
  done
  api GET /v1/presentation/status > "$OUTPUT_ROOT/$label-stuck-presentation.json"
  capture_screenshot "$label-stuck" "$OUTPUT_ROOT/$label-stuck-screenshot.json" \
    > "$OUTPUT_ROOT/$label-stuck-screenshot-path.txt"
  echo "Setup did not resume after $label; rebuild state: $(cat "$output_file"); ledger: $ledger_file" >&2
  exit 1
}

latest_request_id() {
  api GET /v1/sync/ledger | python3 -c \
    'import json,sys; print(max((run["requestId"] for run in json.load(sys.stdin)["durableRuns"]), default=0))'
}

connect_fixture() {
  local body
  body="$(python3 - "$FIXTURE_PORT" "$CREDENTIAL_FILE" <<'PY'
import json, sys
print(json.dumps({
    "url": f"http://127.0.0.1:{sys.argv[1]}",
    "username": "diagnostics",
    "password": open(sys.argv[2], encoding="utf-8").read().strip(),
}))
PY
)"
  api POST /v1/session/connect "$body"
}

if [[ "$MODE" == "existing-catalog" ]]; then
  EXISTING_DB="$OUTPUT_ROOT/existing.sqlite"
  start_fixture
  clone_database "$EXISTING_DB" "$OUTPUT_ROOT/existing-cache"
  cd "$PROJECT_DIR"

  # A completed profile keeps its first-sync evidence across a keep-data
  # sign-out, so signing back in must open Home without the setup route.
  launch_app "$EXISTING_DB" existing-completed
  api GET /v1/health > "$OUTPUT_ROOT/existing-health.json"
  wait_for_phase ready "$OUTPUT_ROOT/existing-ready-before-reset.json"
  api POST /v1/diagnostics/overrides \
    '{"networkType":"offline","nativeMetered":false}' >/dev/null
  api POST '/v1/session/reset-initial-state' > "$OUTPUT_ROOT/existing-reset.json"
  api POST /v1/diagnostics/overrides \
    '{"networkType":"wifi","nativeMetered":false}' >/dev/null
  wait_for_phase ready "$OUTPUT_ROOT/existing-first-setup-ready.json" 600
  api POST '/v1/session/sign-out' '{"wipeLocalData":false}' \
    > "$OUTPUT_ROOT/existing-keep-data-signout.json"
  assert_signed_out "$OUTPUT_ROOT/existing-keep-data-signout.json"
  connect_fixture > "$OUTPUT_ROOT/existing-keep-data-connect.json"
  wait_for_phase ready "$OUTPUT_ROOT/existing-keep-data-ready.json" 60
  api GET /v1/presentation/status \
    > "$OUTPUT_ROOT/existing-keep-data-presentation.json"
  python3 - "$EXISTING_DB" \
    "$OUTPUT_ROOT/existing-keep-data-presentation.json" <<'PY'
import json, sqlite3, sys
presentation = json.load(open(sys.argv[2], encoding="utf-8"))
assert presentation.get("route") != "/initial-sync", presentation
db = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
server = db.execute("SELECT last_synced FROM server_config LIMIT 1").fetchone()
albums = db.execute("SELECT count(*) FROM albums").fetchone()[0]
assert server is not None and server[0] is not None, server
assert albums > 0, albums
PY
  # Removing data and signing in again in the same process must run a new
  # setup; the finished setup's controller must not carry over. An incomplete
  # album keeps the automatic timer pass from completing setup on its own.
  : > "$PARTIAL_ALBUM_FLAG"
  # The ledger is scoped to the signed-in server, so record the baseline
  # before signing out.
  baseline_request_id="$(latest_request_id)"
  api POST '/v1/session/sign-out' '{"wipeLocalData":true}' \
    > "$OUTPUT_ROOT/existing-wipe-signout.json"
  assert_signed_out "$OUTPUT_ROOT/existing-wipe-signout.json"
  connect_fixture > "$OUTPUT_ROOT/existing-wipe-connect.json"
  wait_for_resumed_setup existing-wipe-resign "$baseline_request_id" 180
  wait_for_phase ready "$OUTPUT_ROOT/existing-wipe-ready.json" 60
  api GET /v1/sync/ledger > "$OUTPUT_ROOT/existing-wipe-ledger.json"
  python3 - "$OUTPUT_ROOT/existing-wipe-ledger.json" "$baseline_request_id" <<'PY'
import json, sys
ledger = json.load(open(sys.argv[1], encoding="utf-8"))
assert any(
    run.get("requestId", 0) > int(sys.argv[2])
    and run.get("targetKind") == "catalog"
    and run.get("intent") in ("manualCatalogCheck", "repairLibrary")
    for run in ledger["durableRuns"]
), ledger
PY
  rm -f "$PARTIAL_ALBUM_FLAG"
  stop_app

  # An interrupted first setup can promote a catalog without readiness
  # evidence. Signing out with kept data and back in resumes that setup; its
  # retry must publish a full catalog so the partial-readiness predicate can
  # release the route.
  launch_app "$EXISTING_DB" existing-interrupted
  wait_for_phase ready "$OUTPUT_ROOT/existing-interrupted-start.json"
  api POST /v1/diagnostics/overrides \
    '{"networkType":"offline","nativeMetered":false}' >/dev/null
  : > "$PARTIAL_ALBUM_FLAG"
  : > "$ALBUM_ERROR_FLAG"
  api POST '/v1/session/reset-initial-state' > /dev/null
  wait_for_phase initialSyncRequired \
    "$OUTPUT_ROOT/existing-interrupted-required.json"
  api POST /v1/diagnostics/overrides \
    '{"networkType":"wifi","nativeMetered":false}' >/dev/null
  wait_for_rebuild_settled "$OUTPUT_ROOT/existing-interrupted-first.json" 600
  python3 - "$EXISTING_DB" "$OUTPUT_ROOT/existing-interrupted-first.json" <<'PY'
import json, sqlite3, sys
rebuild = json.load(open(sys.argv[2], encoding="utf-8"))
assert rebuild["status"] == "failed", rebuild
db = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
server = db.execute("SELECT last_synced FROM server_config LIMIT 1").fetchone()
state = db.execute("SELECT current_generation, last_catalog_synced_at, initial_catalog_usable_at FROM library_sync_state LIMIT 1").fetchone()
assert server[0] is None, server
assert state[0] > 0 and state[1] is None and state[2] is None, state
PY
  capture_screenshot existing-interrupted-failed \
    "$OUTPUT_ROOT/existing-interrupted-failed-screenshot.json" \
    > "$OUTPUT_ROOT/existing-interrupted-failed-screenshot-path.txt"
  rm -f "$ALBUM_ERROR_FLAG"
  # The screen's own "Cancel and Sign Out" keeps local data. Signing back in
  # must start a new setup run automatically rather than showing the
  # cancelled controller.
  baseline_request_id="$(latest_request_id)"
  api POST /v1/presentation/library-rebuild \
    '{"reason":"initial-login","action":"cancelAndSignOut"}' \
    > "$OUTPUT_ROOT/existing-interrupted-cancel.json"
  api GET '/v1/session/status' \
    > "$OUTPUT_ROOT/existing-interrupted-signout.json"
  assert_signed_out "$OUTPUT_ROOT/existing-interrupted-signout.json"
  connect_fixture > "$OUTPUT_ROOT/existing-interrupted-connect.json"
  wait_for_resumed_setup existing-interrupted-resign "$baseline_request_id" 600
  cp "$OUTPUT_ROOT/existing-interrupted-resign-rebuild.json" \
    "$OUTPUT_ROOT/existing-interrupted-retried.json"
  api GET /v1/sync/ledger > "$OUTPUT_ROOT/existing-interrupted-ledger.json"
  python3 - "$EXISTING_DB" "$OUTPUT_ROOT/existing-interrupted-retried.json" \
    "$OUTPUT_ROOT/existing-interrupted-ledger.json" "$baseline_request_id" <<'PY'
import json, sqlite3, sys
rebuild = json.load(open(sys.argv[2], encoding="utf-8"))
ledger = json.load(open(sys.argv[3], encoding="utf-8"))
runs = [
    run for run in ledger["durableRuns"]
    if run.get("requestId", 0) > int(sys.argv[4])
    and run.get("targetKind") == "catalog"
]
assert rebuild["status"] in ("complete", "inactive"), (rebuild, runs)
assert any(
    run.get("planKind") == "repairLibrary" and run.get("outcome") == "partial"
    for run in runs
), runs
assert not any(run.get("planKind") == "manualCatalogDiscovery" for run in runs), runs
db = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
state = db.execute("SELECT current_generation, initial_catalog_usable_at FROM library_sync_state LIMIT 1").fetchone()
pending = db.execute("SELECT count(*) FROM albums WHERE songs_hydrated = 0 AND is_external = 0 AND is_provisional = 0").fetchone()[0]
assert state[0] > 0 and state[1] is not None, state
assert pending == 1, pending
PY
  wait_for_phase ready "$OUTPUT_ROOT/existing-interrupted-ready.json" 60
  capture_screenshot existing-interrupted-home \
    "$OUTPUT_ROOT/existing-interrupted-home-screenshot.json" \
    > "$OUTPUT_ROOT/existing-interrupted-home-screenshot-path.txt"
  stop_app
  launch_app "$EXISTING_DB" existing-restart
  wait_for_phase ready "$OUTPUT_ROOT/existing-clean-restart.json"
  stop_app
  if rg -n 'Unhandled Exception|Tried to modify a provider while|NavisDatabase multiple times' \
    "$OUTPUT_ROOT"/*-navis.log; then
    echo "Existing-catalog auth diagnostics found a fatal log pattern." >&2
    exit 1
  fi
  echo "Existing-catalog auth diagnostics passed: $OUTPUT_ROOT"
  exit 0
fi

if [[ "$MODE" == "partial" ]]; then
  PARTIAL_DB="$OUTPUT_ROOT/partial.sqlite"
  start_fixture
  clone_database "$PARTIAL_DB" "$OUTPUT_ROOT/partial-cache"
  cd "$PROJECT_DIR"
  launch_app "$PARTIAL_DB" partial-setup
  api GET /v1/health > "$OUTPUT_ROOT/partial-health.json"
  wait_for_session ready '' "$OUTPUT_ROOT/partial-ready-before-reset.json" 180
  : > "$PARTIAL_ALBUM_FLAG"
  api POST /v1/diagnostics/overrides \
    '{"networkType":"offline","nativeMetered":false}' >/dev/null
  api POST /v1/session/reset-initial-state > "$OUTPUT_ROOT/partial-reset.json"
  wait_for_session initialSyncRequired waitingForNetwork \
    "$OUTPUT_ROOT/partial-fullscreen.json" 180
  api POST /v1/diagnostics/overrides \
    '{"networkType":"wifi","nativeMetered":false}' >/dev/null
  wait_for_session ready complete "$OUTPUT_ROOT/partial-ready.json" 600
  capture_screenshot partial-ready-home \
    "$OUTPUT_ROOT/partial-ready-screenshot.json" \
    > "$OUTPUT_ROOT/partial-ready-screenshot-path.txt"
  python3 - "$PARTIAL_DB" <<'PY'
import sqlite3, sys
db = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
server = db.execute("SELECT last_synced FROM server_config LIMIT 1").fetchone()
state = db.execute("SELECT current_generation, last_catalog_synced_at, initial_catalog_usable_at FROM library_sync_state LIMIT 1").fetchone()
pending = db.execute("SELECT count(*) FROM albums WHERE songs_hydrated = 0 AND is_external = 0 AND is_provisional = 0").fetchone()[0]
songs = db.execute("SELECT count(*) FROM songs WHERE server_deleted_at IS NULL").fetchone()[0]
assert server is not None and server[0] is None, server
assert state is not None and state[0] > 0 and state[1] is None and state[2] is not None, state
assert pending == 1 and songs >= 1, (pending, songs)
db.close()
PY
  stop_app
  launch_app "$PARTIAL_DB" partial-restart
  wait_for_session ready '' "$OUTPUT_ROOT/partial-clean-restart.json" 180
  api GET '/v1/library/album?id=fixture-incomplete-album&verifySongs=true' \
    > "$OUTPUT_ROOT/partial-album-before-recovery.json"
  python3 - "$OUTPUT_ROOT/partial-album-before-recovery.json" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
assert value.get("exists") and value.get("songsHydrated") is False, value
PY
  stop_app
  rm -f "$PARTIAL_ALBUM_FLAG"
  launch_app "$PARTIAL_DB" partial-recovery
  wait_for_session ready '' "$OUTPUT_ROOT/partial-recovery-ready.json" 180
  api POST /v1/diagnostics/overrides \
    '{"networkType":"wifi","nativeMetered":false}' >/dev/null
  api POST /v1/diagnostics/sync-foreground '{"active":true}' \
    > "$OUTPUT_ROOT/partial-foreground.json"
  api POST /v1/diagnostics/automatic-sync-due \
    > "$OUTPUT_ROOT/partial-due.json"
  api POST /v1/sync/automatic > "$OUTPUT_ROOT/partial-automatic-result.json"
  recovery_deadline=$((SECONDS + 180))
  next_recovery_dispatch=$((SECONDS + 20))
  recovery_redispatches=0
  while (( SECONDS < recovery_deadline )); do
    api GET '/v1/library/album?id=fixture-incomplete-album&verifySongs=true' \
      > "$OUTPUT_ROOT/partial-album-after-recovery.json"
    if python3 - "$OUTPUT_ROOT/partial-album-after-recovery.json" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
raise SystemExit(0 if value.get("songsHydrated") is True and value.get("persistedSongCount") == 2 else 1)
PY
    then
      break
    fi
    if (( recovery_redispatches < 6 && SECONDS >= next_recovery_dispatch )); then
      # Startup's deferred automatic request can coalesce with an early
      # dispatch. Recheck admission at a bounded interval until it settles.
      api GET /v1/sync/status \
        > "$OUTPUT_ROOT/partial-recovery-admission-status.json"
      if python3 - "$OUTPUT_ROOT/partial-recovery-admission-status.json" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
raise SystemExit(0 if value.get("requestActive") is False else 1)
PY
      then
        recovery_redispatches=$((recovery_redispatches + 1))
        api POST /v1/diagnostics/sync-foreground '{"active":true}' \
          > "$OUTPUT_ROOT/partial-foreground-retry-$recovery_redispatches.json"
        api POST /v1/diagnostics/automatic-sync-due \
          > "$OUTPUT_ROOT/partial-due-retry-$recovery_redispatches.json"
        api POST /v1/sync/automatic \
          > "$OUTPUT_ROOT/partial-automatic-retry-$recovery_redispatches.json"
        next_recovery_dispatch=$((SECONDS + 20))
      else
        next_recovery_dispatch=$((SECONDS + 5))
      fi
    fi
    sleep 1
  done
  python3 - "$OUTPUT_ROOT/partial-album-after-recovery.json" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
assert value.get("songsHydrated") is True and value.get("persistedSongCount") == 2, value
PY
  recovery_settle_deadline=$((SECONDS + 30))
  while (( SECONDS < recovery_settle_deadline )); do
    api GET /v1/sync/status > "$OUTPUT_ROOT/partial-recovered-status.json"
    if python3 - "$OUTPUT_ROOT/partial-recovered-status.json" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
raise SystemExit(0 if not value.get("requestActive") else 1)
PY
    then
      break
    fi
    sleep 1
  done
  python3 - "$OUTPUT_ROOT/partial-recovered-status.json" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
assert value["requestActive"] is False, value
assert value["pendingHydration"] == 0, value
assert any(
    run.get("intent") == "automaticCatalogCheck"
    and run.get("outcome") == "completed"
    and run.get("planKind") == "targetHydration"
    for run in value["durableRuns"]
), value
PY
  : > "$PARTIAL_ALBUM_FLAG"
  # The second manual-cache-reset and playback-recovery visits in the same
  # process must run again rather than reuse the earlier visit's controller.
  for rebuild_visit in manual-cache-reset playback-recovery \
    cache-upgrade manual-cache-reset/2 playback-recovery/2; do
    rebuild_reason="${rebuild_visit%%/*}"
    rebuild_label="${rebuild_visit//\//-}"
    baseline_request_id="$(api GET /v1/sync/ledger | python3 -c \
      'import json,sys; print(max((run["requestId"] for run in json.load(sys.stdin)["durableRuns"]), default=0))')"
    api POST /v1/presentation/navigate \
      "{\"location\":\"/library-rebuild?reason=$rebuild_reason\"}" \
      > "$OUTPUT_ROOT/partial-$rebuild_label-navigation.json"
    rebuild_deadline=$((SECONDS + 180))
    while (( SECONDS < rebuild_deadline )); do
      api GET /v1/presentation/status \
        > "$OUTPUT_ROOT/partial-$rebuild_label-presentation.json"
      api GET /v1/sync/ledger \
        > "$OUTPUT_ROOT/partial-$rebuild_label-ledger.json"
      api GET '/v1/library/album?id=fixture-incomplete-album&verifySongs=true' \
        > "$OUTPUT_ROOT/partial-$rebuild_label-album.json"
      if python3 - \
        "$OUTPUT_ROOT/partial-$rebuild_label-presentation.json" \
        "$OUTPUT_ROOT/partial-$rebuild_label-ledger.json" \
        "$OUTPUT_ROOT/partial-$rebuild_label-album.json" \
        "$baseline_request_id" <<'PY'
import json, sys
presentation = json.load(open(sys.argv[1], encoding="utf-8"))
ledger = json.load(open(sys.argv[2], encoding="utf-8"))
album = json.load(open(sys.argv[3], encoding="utf-8"))
ready = (
    presentation.get("route") == "/"
    and album.get("exists") is True
    and album.get("songsHydrated") is False
    and any(
        run.get("requestId", 0) > int(sys.argv[4])
        and run.get("targetKind") == "catalog"
        and run.get("outcome") == "partial"
        for run in ledger["durableRuns"]
    )
)
raise SystemExit(0 if ready else 1)
PY
      then
        break
      fi
      sleep 1
    done
    python3 - "$OUTPUT_ROOT/partial-$rebuild_label-presentation.json" \
      "$OUTPUT_ROOT/partial-$rebuild_label-ledger.json" \
      "$OUTPUT_ROOT/partial-$rebuild_label-album.json" \
      "$baseline_request_id" <<'PY'
import json, sys
presentation = json.load(open(sys.argv[1], encoding="utf-8"))
ledger = json.load(open(sys.argv[2], encoding="utf-8"))
album = json.load(open(sys.argv[3], encoding="utf-8"))
assert presentation.get("route") == "/", presentation
assert album.get("exists") is True and album.get("songsHydrated") is False, album
assert any(
    run.get("requestId", 0) > int(sys.argv[4])
    and run.get("targetKind") == "catalog"
    and run.get("outcome") == "partial"
    for run in ledger["durableRuns"]
), ledger
PY
  done
  capture_screenshot partial-repair-ready-home \
    "$OUTPUT_ROOT/partial-repair-ready-screenshot.json" \
    > "$OUTPUT_ROOT/partial-repair-ready-screenshot-path.txt"
  stop_app
  if rg -n 'Unhandled Exception|Tried to modify a provider while|NavisDatabase multiple times' \
    "$OUTPUT_ROOT"/*-navis.log; then
    echo "Partial auth diagnostics found a fatal log pattern." >&2
    exit 1
  fi
  echo "Partial auth diagnostics passed: $OUTPUT_ROOT"
  exit 0
fi

SETUP_DB="$OUTPUT_ROOT/setup-and-signout.sqlite"
CANCEL_DB="$OUTPUT_ROOT/cancel.sqlite"
start_fixture
clone_database "$SETUP_DB" "$OUTPUT_ROOT/setup-cache"
clone_database "$CANCEL_DB" "$OUTPUT_ROOT/cancel-cache"
RESIGN_DB="$OUTPUT_ROOT/resign.sqlite"
clone_database "$RESIGN_DB" "$OUTPUT_ROOT/resign-cache"

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
# The screenshot shows the setup screen, which runs its own controller.
wait_for_rebuild_status failed "$OUTPUT_ROOT/setup-failed-screen.json" 300
capture_screenshot setup-failed \
  "$OUTPUT_ROOT/setup-failed-screenshot.json" \
  > "$OUTPUT_ROOT/setup-failed-screenshot-path.txt"
rm -f "$FIXTURE_FAILURE_FLAG"
# Press the setup screen's own Retry, as a user would. (The legacy
# /v1/session/initial-sync/retry drives a separate diagnostics controller, so
# the screen would still show the failure.)
api POST /v1/presentation/library-rebuild \
  '{"reason":"initial-login","action":"retry"}' \
  > "$OUTPUT_ROOT/setup-retry-result.json"
wait_for_rebuild_status 'clearingCache syncing' \
  "$OUTPUT_ROOT/setup-running.json" 300
capture_screenshot setup-running \
  "$OUTPUT_ROOT/setup-running-screenshot.json" \
  > "$OUTPUT_ROOT/setup-running-screenshot-path.txt"
# The controller is disposed once setup ends and the app leaves the screen.
wait_for_rebuild_status 'complete inactive' \
  "$OUTPUT_ROOT/setup-complete-screen.json" 14400
wait_for_session ready '' "$OUTPUT_ROOT/setup-complete.json" 600
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
mute_and_verify
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
wait_for_session initialSyncRequired syncing \
  "$OUTPUT_ROOT/cancel-running.json" 180
curl --fail-with-body --silent --show-error \
  -X POST -H "Authorization: Bearer $TOKEN" \
  "$BASE_URL/v1/session/initial-sync/cancel" \
  > "$OUTPUT_ROOT/cancel-result.json" &
CANCEL_REQUEST_PID=$!
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

# Cancelling setup and signing in again in the same process
# must set the new session up instead of keeping the cancelled setup state.
launch_app "$RESIGN_DB" resign
wait_for_session ready '' "$OUTPUT_ROOT/resign-ready-before-reset.json" 180
api POST /v1/diagnostics/overrides \
  '{"networkType":"offline","nativeMetered":false}' >/dev/null
api POST /v1/session/reset-initial-state >/dev/null
wait_for_session initialSyncRequired waitingForNetwork \
  "$OUTPUT_ROOT/resign-waiting.json" 180
api POST /v1/session/initial-sync/cancel > "$OUTPUT_ROOT/resign-cancel.json"
assert_signed_out "$OUTPUT_ROOT/resign-cancel.json"
api POST /v1/diagnostics/overrides \
  '{"networkType":"wifi","nativeMetered":false}' >/dev/null
connect_fixture > "$OUTPUT_ROOT/resign-connect.json"
resign_deadline=$((SECONDS + 180))
while (( SECONDS < resign_deadline )); do
  api GET /v1/session/status > "$OUTPUT_ROOT/resign-status.json"
  if python3 - "$OUTPUT_ROOT/resign-status.json" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
raise SystemExit(
    0 if value.get("phase") == "ready" and value.get("initialSync") == "complete"
    else 1
)
PY
  then
    break
  fi
  sleep 1
done
if ! python3 - "$OUTPUT_ROOT/resign-status.json" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
raise SystemExit(
    0 if value.get("phase") == "ready" and value.get("initialSync") == "complete"
    else 1
)
PY
then
  capture_screenshot resign-stuck "$OUTPUT_ROOT/resign-stuck-screenshot.json" \
    > "$OUTPUT_ROOT/resign-stuck-screenshot-path.txt"
  echo "Setup did not resume after cancel and sign-in: $(cat "$OUTPUT_ROOT/resign-status.json")" >&2
  exit 1
fi
stop_app

if rg -n 'Unhandled Exception|Tried to modify a provider while|NavisDatabase multiple times' \
  "$OUTPUT_ROOT"/*-navis.log; then
  echo "Auth lifecycle diagnostics found a fatal log pattern." >&2
  exit 1
fi

echo "Auth lifecycle diagnostics passed: $OUTPUT_ROOT"
