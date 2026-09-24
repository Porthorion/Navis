#!/usr/bin/env bash
set -euo pipefail

# Controller-backed clone certification that an uncommitted large-deletion
# repair candidate cannot alter the committed offline catalog.

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DB="${NAVIS_DIAGNOSTICS_PRIMARY_DB:-$HOME/Documents/navis.sqlite.sqlite}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUTPUT_ROOT="$PROJECT_DIR/build/repair-confirmation-diagnostics/$STAMP-clone"
CLONE_DB="$OUTPUT_ROOT/navis-diagnostics.sqlite"
HANDSHAKE="$OUTPUT_ROOT/handshake.json"
FIXTURE_HANDSHAKE="$OUTPUT_ROOT/fixture-handshake.json"
CREDENTIAL_FILE="$OUTPUT_ROOT/fixture-password"
APP_LOG="$OUTPUT_ROOT/navis.log"
FLUTTER_PID=0
FIXTURE_PID=0

[[ -f "$SOURCE_DB" ]] || { echo "Primary database not found: $SOURCE_DB" >&2; exit 66; }
mkdir -p "$OUTPUT_ROOT"
chmod 700 "$OUTPUT_ROOT"

cleanup() {
  for process_id in "$FLUTTER_PID" "$FIXTURE_PID"; do
    if (( process_id > 0 )) && kill -0 "$process_id" >/dev/null 2>&1; then
      kill "$process_id" >/dev/null 2>&1 || true
      wait "$process_id" >/dev/null 2>&1 || true
    fi
  done
}
trap cleanup EXIT INT TERM

printf '%s\n' 'navis-repair-confirmation-fixture' > "$CREDENTIAL_FILE"
chmod 600 "$CREDENTIAL_FILE"
python3 "$PROJECT_DIR/tool/auth_lifecycle_fixture_server.py" \
  --handshake "$FIXTURE_HANDSHAKE" \
  --failure-flag "$OUTPUT_ROOT/unused-failure-flag" \
  --scenario auth-lifecycle >"$OUTPUT_ROOT/fixture.log" 2>&1 &
FIXTURE_PID=$!
for _ in $(seq 1 30); do [[ -s "$FIXTURE_HANDSHAKE" ]] && break; sleep 1; done
[[ -s "$FIXTURE_HANDSHAKE" ]] || { echo "Fixture startup failed" >&2; exit 70; }

python3 - "$SOURCE_DB" "$CLONE_DB" "$FIXTURE_HANDSHAKE" \
  "$PROJECT_DIR/lib/src/features/library/presentation/library_sync_provider.dart" <<'PY'
import datetime, json, re, sqlite3, sys, time
from pathlib import Path
source = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
target = sqlite3.connect(sys.argv[2])
source.backup(target)
source.close()
fixture = json.load(open(sys.argv[3], encoding="utf-8"))
model_source = Path(sys.argv[4]).read_text(encoding="utf-8")
model_version = re.search(
    r"const currentLibrarySyncModelVersion = '([^']+)';", model_source
)
if model_version is None:
    raise SystemExit("could not read the current library sync model version")
server = target.execute("SELECT id, capabilities FROM server_config WHERE is_authenticated = 1 ORDER BY id LIMIT 1").fetchone()
if server is None:
    raise SystemExit("clone has no authenticated server")
server_id, raw_capabilities = server
try:
    capabilities = json.loads(raw_capabilities) if raw_capabilities else {}
except (TypeError, json.JSONDecodeError):
    capabilities = {}
navis = capabilities.setdefault("navis", {})
if not isinstance(navis, dict):
    navis = {}
    capabilities["navis"] = navis
for key in ("libraryPendingIndexesFingerprint", "libraryPendingIndexesCursor", "libraryPendingIndexesOffset", "libraryPendingIndexesArtistIds", "bulkSongSearchWildcardQuery"):
    navis.pop(key, None)
now = int(time.time())
columns = {row[1] for row in target.execute("PRAGMA table_info(library_sync_state)")}
if "next_automatic_check_at" not in columns:
    target.execute("ALTER TABLE library_sync_state ADD COLUMN next_automatic_check_at INTEGER")
target.execute("DELETE FROM library_sync_work")
for table in ("library_sync_candidate_artists", "library_sync_candidate_albums", "library_sync_candidate_songs"):
    target.execute(f"DELETE FROM {table}")
target.execute("UPDATE albums SET songs_hydrated=1")
# This gate tests an explicit confirmation across restart. A source export
# from an older app model would independently schedule startup full repair and
# race that confirmation, so make only the disposable fixture model-current.
target.execute(
    "UPDATE app_settings SET last_full_sync_app_build = ?",
    (model_version.group(1),),
)
target.execute("UPDATE server_config SET name=?, url=?, username=?, api_version=?, capabilities=?, last_synced=?, last_full_synced=?, is_authenticated=1 WHERE id=?", ("Navis repair confirmation fixture", f"http://127.0.0.1:{fixture['port']}", "diagnostics", "1.16.1", json.dumps(capabilities, separators=(",", ":")), now, now, server_id))
target.execute("INSERT OR IGNORE INTO library_sync_state (server_id) VALUES (?)", (server_id,))
target.execute("UPDATE library_sync_state SET last_checked_at=?, last_catalog_synced_at=?, last_auxiliary_synced_at=?, last_genres_synced_at=?, candidate_generation=NULL, candidate_status=NULL, candidate_started_at=NULL, candidate_carried_forward_count=0, deletion_candidate_fingerprint=NULL, deletion_candidate_count=0, next_automatic_check_at=? WHERE server_id=?", (now, now, now, now, now + 3600, server_id))
target.commit()
assert target.execute("SELECT count(*) FROM albums").fetchone()[0] > 10
assert target.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
assert not target.execute("PRAGMA foreign_key_check").fetchall()
target.close()
PY
chmod 600 "$CLONE_DB"

launch() {
  rm -f "$HANDSHAKE"
  local data_home="$OUTPUT_ROOT/app-data"
  local version
  version="$(awk '/^version:/ {split($2, p, "+"); print p[1]; exit}' "$PROJECT_DIR/pubspec.yaml")"
  mkdir -p "$data_home/com.navis.app.navis"
  printf '%s\n' "$version" > "$data_home/com.navis.app.navis/changelog_seen_version.txt"
  (
    cd "$PROJECT_DIR"
    env "XDG_DATA_HOME=$data_home" flutter run -d linux --profile \
      --dart-define=NAVIS_UPDATE_CHANNEL=dev \
      --dart-define=NAVIS_APP_ID_SUFFIX=.dev \
      --dart-define=NAVIS_APP_NAME='Navis Repair Confirmation Diagnostics' \
      --dart-define=NAVIS_SYNC_DIAGNOSTICS=true \
      --dart-define=NAVIS_SYNC_DIAGNOSTICS_MODE=clone \
      --dart-define=NAVIS_SYNC_DIAGNOSTICS_LEASE_SECONDS=600 \
      --dart-define="NAVIS_SYNC_DIAGNOSTICS_HANDSHAKE=$HANDSHAKE" \
      --dart-define="NAVIS_SYNC_DIAGNOSTICS_ROOT=$OUTPUT_ROOT" \
      --dart-define="NAVIS_SYNC_DIAGNOSTICS_DB_PATH=$CLONE_DB" \
      --dart-define="NAVIS_SYNC_DIAGNOSTICS_CREDENTIAL_PATH=$CREDENTIAL_FILE" \
      >>"$APP_LOG" 2>&1
  ) &
  FLUTTER_PID=$!
  for _ in $(seq 1 180); do [[ -s "$HANDSHAKE" ]] && break; sleep 1; done
  [[ -s "$HANDSHAKE" ]] || { echo "App startup failed. See $APP_LOG" >&2; exit 70; }
  read -r PORT TOKEN < <(python3 - "$HANDSHAKE" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
print(value["port"], value["token"])
PY
)
  BASE_URL="http://127.0.0.1:$PORT"
}

api() {
  local method="$1" path="$2" body="${3:-}"
  if [[ -n "$body" ]]; then
    curl --fail-with-body --silent --show-error -X "$method" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d "$body" "$BASE_URL$path"
  else
    curl --fail-with-body --silent --show-error -X "$method" -H "Authorization: Bearer $TOKEN" "$BASE_URL$path"
  fi
}

wait_for_idle() {
  local output="$1"
  for _ in $(seq 1 180); do
    api GET /v1/sync/status > "$output"
    if python3 - "$output" <<'PY'
import json, sys
raise SystemExit(0 if not json.load(open(sys.argv[1])).get("requestActive") else 1)
PY
    then return; fi
    sleep 1
  done
  echo "Sync did not settle. See $APP_LOG" >&2
  exit 70
}

wait_for_presentation() {
  for _ in $(seq 1 90); do
    if api GET /v1/presentation/status | python3 -c 'import json,sys; value=json.load(sys.stdin); raise SystemExit(0 if value.get("appReady") and value.get("screenshotReady") else 1)'; then return; fi
    sleep 1
  done
  echo "Presentation did not become ready. See $APP_LOG" >&2
  exit 70
}

capture() {
  local label="$1" manifest="$2"
  api POST /v1/presentation/screenshot "$(python3 - "$label" <<'PY'
import json, sys
print(json.dumps({"label": sys.argv[1]}))
PY
)" > "$manifest"
  python3 - "$manifest" "$OUTPUT_ROOT" <<'PY'
import hashlib, json, os, sys
value = json.load(open(sys.argv[1]))
path = os.path.realpath(os.path.join(sys.argv[2], value["artifact"]))
assert os.path.commonpath([os.path.realpath(sys.argv[2]), path]) == os.path.realpath(sys.argv[2])
data = open(path, "rb").read()
assert data[:8] == b"\x89PNG\r\n\x1a\n" and hashlib.sha256(data).hexdigest() == value["sha256"]
print(path)
PY
}

launch
api GET /v1/health > "$OUTPUT_ROOT/health.json"
wait_for_presentation
wait_for_idle "$OUTPUT_ROOT/status-before.json"
api POST /v1/sync/repair '{}' > "$OUTPUT_ROOT/repair-first-start.json"
wait_for_idle "$OUTPUT_ROOT/repair-first-result.json"
python3 - "$OUTPUT_ROOT/status-before.json" "$OUTPUT_ROOT/repair-first-result.json" <<'PY'
import json, sys
before, after = (json.load(open(path)) for path in sys.argv[1:])
assert after["candidateStatus"] == "awaitingDeletionConfirmation", after
assert after["deletionCandidateCount"] > 0, after
assert before["catalog"] == after["catalog"], (before, after)
PY
api POST /v1/presentation/navigate '{"location":"/settings/sync"}' > "$OUTPUT_ROOT/confirmation-navigation.json"
sleep 3
capture repair-awaiting-confirmation "$OUTPUT_ROOT/confirmation-screenshot.json" > "$OUTPUT_ROOT/confirmation-screenshot-path.txt"
api POST /v1/shutdown > "$OUTPUT_ROOT/shutdown.json" || true
wait "$FLUTTER_PID" || true
FLUTTER_PID=0

launch
wait_for_presentation
wait_for_idle "$OUTPUT_ROOT/restart-status.json"
python3 - "$OUTPUT_ROOT/repair-first-result.json" "$OUTPUT_ROOT/restart-status.json" <<'PY'
import json, sys
first, restart = (json.load(open(path)) for path in sys.argv[1:])
assert restart["candidateStatus"] == "awaitingDeletionConfirmation", restart
assert restart["catalog"] == first["catalog"], (first, restart)
PY
api POST /v1/sync/repair '{}' > "$OUTPUT_ROOT/repair-confirm-start.json"
wait_for_idle "$OUTPUT_ROOT/repair-confirm-result.json"
api GET /v1/sync/ledger > "$OUTPUT_ROOT/sync-ledger.json"
python3 - "$OUTPUT_ROOT/status-before.json" "$OUTPUT_ROOT/repair-confirm-result.json" "$OUTPUT_ROOT/sync-ledger.json" <<'PY'
import json, sys
before, status = (json.load(open(path)) for path in sys.argv[1:3])
assert status["candidateStatus"] is None, status
for key in ("artists", "albums", "songs"):
    assert 0 < status["catalog"][key] < before["catalog"][key], (before, status)
ledger_payload = json.load(open(sys.argv[3]))
events = ledger_payload["events"]
terminal = [event for event in events if event.get("cause") == "repair" and event.get("phase") == "terminal"]
# The bounded in-memory diagnostic ledger is intentionally reset by the clean
# restart. The first repair's durable awaiting state is asserted above; this
# post-restart ledger proves the explicit confirmation reached its terminal
# production-controller result.
assert terminal and terminal[-1]["result"] == "succeeded", terminal
operations = ledger_payload["durableOperations"]
promotion = next(
    operation for operation in operations
    if operation.get("operation") == "catalogPromotion"
)
assert promotion["reason"] == "validatedFullCandidate", promotion
details = promotion["details"]
assert details["before"] == before["catalog"], (details, before)
assert details["after"] == status["catalog"], (details, status)
assert details["removed"]["songs"] > 0, details
PY
api POST /v1/presentation/navigate '{"location":"/settings/sync"}' > "$OUTPUT_ROOT/promoted-navigation.json"
sleep 3
capture repair-promoted "$OUTPUT_ROOT/promoted-screenshot.json" > "$OUTPUT_ROOT/promoted-screenshot-path.txt"
api POST /v1/shutdown > "$OUTPUT_ROOT/final-shutdown.json" || true
wait "$FLUTTER_PID" || true
FLUTTER_PID=0

if rg -n 'Unhandled Exception|Tried to modify a provider while the widget tree was building|created the database class NavisDatabase multiple times' "$APP_LOG" > "$OUTPUT_ROOT/log-errors.txt"; then
  echo "Runtime log contains a hard-fail pattern. See $APP_LOG" >&2
  exit 1
fi

echo "Repair-confirmation diagnostics completed: $OUTPUT_ROOT"
echo "Open and inspect: $(<"$OUTPUT_ROOT/confirmation-screenshot-path.txt")"
echo "Open and inspect: $(<"$OUTPUT_ROOT/promoted-screenshot-path.txt")"
