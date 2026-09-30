#!/usr/bin/env bash
set -euo pipefail

# Proves that a production-controller target hydration does not change the
# catalog status shown by Library/Settings, and that a persisted automatic
# deadline survives startup and restart. The run is isolated: it copies the
# database and rewrites cache paths below its own diagnostics root.

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DB="${NAVIS_DIAGNOSTICS_PRIMARY_DB:-$HOME/Documents/navis.sqlite.sqlite}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUTPUT_ROOT="$PROJECT_DIR/build/sync-target-lane-diagnostics/$STAMP-clone"
CLONE_DB="$OUTPUT_ROOT/navis-diagnostics.sqlite"
CACHE_ROOT="$OUTPUT_ROOT/cache"
HANDSHAKE="$OUTPUT_ROOT/handshake.json"
APP_LOG="$OUTPUT_ROOT/navis.log"
FLUTTER_PID=0

if [[ ! -f "$SOURCE_DB" ]]; then
  echo "Primary database not found: $SOURCE_DB" >&2
  exit 66
fi

mkdir -p "$CACHE_ROOT"
chmod 700 "$OUTPUT_ROOT"

python3 - "$SOURCE_DB" "$CLONE_DB" "$CACHE_ROOT" <<'PY'
import datetime, hashlib, os, sqlite3, sys
source = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
target = sqlite3.connect(sys.argv[2])
source.backup(target)
source.close()
cache_root = sys.argv[3]
for song_id, source_path in target.execute(
    "SELECT song_id, file_path FROM cached_tracks"
).fetchall():
    extension = os.path.splitext(source_path)[1] or ".isolated"
    destination = os.path.join(
        cache_root, f"{hashlib.sha256(song_id.encode()).hexdigest()}{extension}"
    )
    if os.path.isfile(source_path):
        with open(source_path, "rb") as input_file, open(destination, "wb") as output_file:
            while chunk := input_file.read(1024 * 1024):
                output_file.write(chunk)
target.execute("UPDATE cached_tracks SET file_path = ? WHERE song_id = ?", (destination, song_id))
# Start well inside an automatic interval and retry cooldown. This deterministic
# fixture setup lets the running app API prove that startup, navigation, and
# restart do not recreate or consume either durable deadline. It does not drive
# sync behavior directly; every assertion below observes the production
# controller.
columns = {
    row[1] for row in target.execute("PRAGMA table_info(library_sync_state)")
}
if "next_automatic_check_at" not in columns:
    # The source profile may still be on the pre-v63 schema. This fixture
    # column matches the guarded app migration and lets the scheduled-run
    # scenario start with a deterministic value.
    target.execute(
        "ALTER TABLE library_sync_state ADD COLUMN next_automatic_check_at INTEGER"
    )
deadline = int(
    (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(hours=1))
    .replace(microsecond=0)
    .timestamp()
)
retry_at = int(
    (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(minutes=15))
    .replace(microsecond=0)
    .timestamp()
)
server_ids = target.execute(
    "SELECT id FROM server_config WHERE is_authenticated = 1"
).fetchall()
if not server_ids:
    raise SystemExit("isolated clone has no authenticated server")
for (server_id,) in server_ids:
    existing = target.execute(
        "SELECT 1 FROM library_sync_state WHERE server_id = ?", (server_id,)
    ).fetchone()
    if existing is None:
        target.execute(
            "INSERT INTO library_sync_state (server_id, next_automatic_check_at) VALUES (?, ?)",
            (server_id, deadline),
        )
    else:
        target.execute(
            "UPDATE library_sync_state SET next_automatic_check_at = ? WHERE server_id = ?",
            (deadline, server_id),
        )
    target.execute(
        "UPDATE library_sync_state SET next_eligible_at = ? WHERE server_id = ?",
        (retry_at, server_id),
    )
target.commit()
integrity = target.execute("PRAGMA integrity_check").fetchone()[0]
foreign_keys = target.execute("PRAGMA foreign_key_check").fetchall()
target.close()
if integrity != "ok" or foreign_keys:
    raise SystemExit("isolated clone validation failed")
PY
chmod 600 "$CLONE_DB"

cleanup() {
  if (( FLUTTER_PID > 0 )) && kill -0 "$FLUTTER_PID" >/dev/null 2>&1; then
    kill "$FLUTTER_PID" >/dev/null 2>&1 || true
    wait "$FLUTTER_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

launch() {
  rm -f "$HANDSHAKE"
  local diagnostics_data_home="$OUTPUT_ROOT/app-data"
  local changelog_version
  changelog_version="$(awk '/^version:/ {split($2, parts, "+"); print parts[1]; exit}' "$PROJECT_DIR/pubspec.yaml")"
  mkdir -p "$diagnostics_data_home/com.navis.app.navis"
  # Keep clone-only app-support state isolated. A first-run changelog dialog
  # would cover the Liked surface that this gate has to inspect.
  printf '%s\n' "$changelog_version" \
    > "$diagnostics_data_home/com.navis.app.navis/changelog_seen_version.txt"
  (
    cd "$PROJECT_DIR"
    env "XDG_DATA_HOME=$diagnostics_data_home" flutter run -d linux --profile \
      --dart-define=NAVIS_UPDATE_CHANNEL=dev \
      --dart-define=NAVIS_APP_ID_SUFFIX=.dev \
      --dart-define=NAVIS_APP_NAME='Navis Target Lane Diagnostics' \
      --dart-define=NAVIS_SYNC_DIAGNOSTICS=true \
      --dart-define=NAVIS_SYNC_DIAGNOSTICS_MODE=clone \
      --dart-define="NAVIS_SYNC_DIAGNOSTICS_HANDSHAKE=$HANDSHAKE" \
      --dart-define="NAVIS_SYNC_DIAGNOSTICS_ROOT=$OUTPUT_ROOT" \
      --dart-define="NAVIS_SYNC_DIAGNOSTICS_DB_PATH=$CLONE_DB" \
      >>"$APP_LOG" 2>&1
  ) &
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

api() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  if [[ -n "$body" ]]; then
    curl --fail-with-body --silent --show-error -X "$method" \
      -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
      -d "$body" "$BASE_URL$path"
  else
    curl --fail-with-body --silent --show-error -X "$method" \
      -H "Authorization: Bearer $TOKEN" "$BASE_URL$path"
  fi
}

wait_for_stable_catalog_status() {
  local output="$1"
  local deadline=$((SECONDS + 90))
  while (( SECONDS < deadline )); do
    api GET /v1/sync/status > "$output"
    if python3 - "$output" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
settled = value.get("status") != "running" and not value.get("requestActive")
raise SystemExit(0 if settled else 1)
PY
    then
      return
    fi
    sleep 1
  done
  echo "Timed out waiting for catalog status to settle. See $APP_LOG" >&2
  exit 70
}

wait_for_presentation() {
  local output="$1"
  local deadline=$((SECONDS + 90))
  while (( SECONDS < deadline )); do
    api GET /v1/presentation/status > "$output"
    if python3 - "$output" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
ready = value.get("appReady") is True and value.get("screenshotReady") is True
route = value.get("route")
raise SystemExit(0 if ready and route not in (None, "", "/loading") else 1)
PY
    then
      return
    fi
    sleep 1
  done
  echo "Timed out waiting for the Flutter presentation surface. See $APP_LOG" >&2
  exit 70
}

capture_screenshot() {
  local metadata="$1"
  local label="$2"
  api POST /v1/presentation/screenshot "$(python3 - "$label" <<'PY'
import json, sys
print(json.dumps({"label": sys.argv[1]}))
PY
)" > "$metadata"
  python3 - "$metadata" "$OUTPUT_ROOT" <<'PY'
import hashlib, json, os, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
artifact = value.get("artifact")
if not isinstance(artifact, str) or os.path.isabs(artifact):
    raise SystemExit("invalid screenshot artifact")
path = os.path.realpath(os.path.join(sys.argv[2], artifact))
root = os.path.realpath(sys.argv[2])
if os.path.commonpath([root, path]) != root:
    raise SystemExit("screenshot escaped diagnostics root")
data = open(path, "rb").read()
if data[:8] != b"\x89PNG\r\n\x1a\n" or hashlib.sha256(data).hexdigest() != value.get("sha256"):
    raise SystemExit("invalid screenshot")
print(path)
PY
}

launch
api GET /v1/health > "$OUTPUT_ROOT/health.json"
wait_for_presentation "$OUTPUT_ROOT/presentation-before.json"
wait_for_stable_catalog_status "$OUTPUT_ROOT/catalog-before.json"

# The app reads both clone deadlines through its production controller. Asking
# the automatic endpoint before its normal interval is due must not start a
# catalog run or clear/recalculate either deadline.
api POST /v1/sync/automatic > "$OUTPUT_ROOT/automatic-before-deadline.json"
wait_for_stable_catalog_status "$OUTPUT_ROOT/catalog-after-automatic.json"
python3 - "$OUTPUT_ROOT/catalog-before.json" \
  "$OUTPUT_ROOT/catalog-after-automatic.json" <<'PY'
import datetime, json, sys
before = json.load(open(sys.argv[1], encoding="utf-8"))
actual = json.load(open(sys.argv[2], encoding="utf-8"))
deadline = actual.get("nextAutomaticCheckAt")
retry_at = actual.get("nextRetryAt")
if not isinstance(deadline, str):
    raise SystemExit("production status omitted nextAutomaticCheckAt")
if not isinstance(retry_at, str):
    raise SystemExit("production status omitted nextRetryAt")
parsed = datetime.datetime.fromisoformat(deadline.replace("Z", "+00:00"))
parsed_retry = datetime.datetime.fromisoformat(retry_at.replace("Z", "+00:00"))
if parsed <= datetime.datetime.now(datetime.timezone.utc):
    raise SystemExit(f"automatic deadline was not future: {deadline}")
if parsed_retry <= datetime.datetime.now(datetime.timezone.utc):
    raise SystemExit(f"retry deadline was not future: {retry_at}")
if actual != before:
    raise SystemExit(
        "automatic check before its deadline changed catalog status: "
        f"{actual}"
    )
PY

# Home, Library, and Liked are local-catalog read surfaces. The sequence uses
# the same virtual Library-section destination that desktop navigation history
# and the visible rail use. None of these transitions may start or relabel
# catalog work, change catalog counts, or add a controller ledger event.
api GET /v1/sync/ledger > "$OUTPUT_ROOT/ledger-before-navigation.json"
locations=(/ /library /library?section=liked / /library?section=liked)
for index in "${!locations[@]}"; do
  location="${locations[$index]}"
  api POST /v1/presentation/navigate "$(python3 - "$location" <<'PY'
import json, sys
print(json.dumps({"location": sys.argv[1]}))
PY
)" > "$OUTPUT_ROOT/navigation-$index.json"
  sleep 2
  api GET /v1/sync/status > "$OUTPUT_ROOT/catalog-after-navigation-$index.json"
done
api GET /v1/sync/ledger > "$OUTPUT_ROOT/ledger-after-navigation.json"

python3 - "$OUTPUT_ROOT/catalog-before.json" \
  "$OUTPUT_ROOT/catalog-after-navigation-0.json" \
  "$OUTPUT_ROOT/catalog-after-navigation-1.json" \
  "$OUTPUT_ROOT/catalog-after-navigation-2.json" \
  "$OUTPUT_ROOT/catalog-after-navigation-3.json" \
  "$OUTPUT_ROOT/catalog-after-navigation-4.json" \
  "$OUTPUT_ROOT/ledger-before-navigation.json" \
  "$OUTPUT_ROOT/ledger-after-navigation.json" <<'PY'
import json, sys
before = json.load(open(sys.argv[1], encoding="utf-8"))
for path in sys.argv[2:-2]:
    actual = json.load(open(path, encoding="utf-8"))
    if actual != before:
        raise SystemExit(
            f"local navigation changed catalog status or counts: {actual}"
        )
before_ledger = json.load(open(sys.argv[-2], encoding="utf-8"))
after_ledger = json.load(open(sys.argv[-1], encoding="utf-8"))
if after_ledger != before_ledger:
    raise SystemExit("local navigation added a controller sync ledger event")
PY

# Capture the production Library/Liked state that just completed the trace.
sleep 3
capture_screenshot "$OUTPUT_ROOT/liked-screenshot.json" "liked-navigation" \
  > "$OUTPUT_ROOT/liked-screenshot-path.txt"

# Offline browsing remains entirely local. Switching between Home and Liked
# must preserve the committed catalog and cannot turn the offline transition
# into a controller operation.
api POST /v1/diagnostics/overrides \
  '{"networkType":"offline","requestReporting":true}' \
  > "$OUTPUT_ROOT/offline-overrides.json"
api GET /v1/sync/status > "$OUTPUT_ROOT/offline-before-navigation.json"
api GET /v1/sync/ledger > "$OUTPUT_ROOT/offline-ledger-before.json"
for index in 0 1; do
  if (( index == 0 )); then
    location='/'
  else
    location='/library?section=liked'
  fi
  api POST /v1/presentation/navigate "$(python3 - "$location" <<'PY'
import json, sys
print(json.dumps({"location": sys.argv[1]}))
PY
)" > "$OUTPUT_ROOT/offline-navigation-$index.json"
  sleep 2
  api GET /v1/sync/status > "$OUTPUT_ROOT/offline-after-navigation-$index.json"
done
api GET /v1/sync/ledger > "$OUTPUT_ROOT/offline-ledger-after.json"

python3 - "$OUTPUT_ROOT/offline-before-navigation.json" \
  "$OUTPUT_ROOT/offline-after-navigation-0.json" \
  "$OUTPUT_ROOT/offline-after-navigation-1.json" \
  "$OUTPUT_ROOT/offline-ledger-before.json" \
  "$OUTPUT_ROOT/offline-ledger-after.json" <<'PY'
import json, sys
before = json.load(open(sys.argv[1], encoding="utf-8"))
for path in sys.argv[2:4]:
    actual = json.load(open(path, encoding="utf-8"))
    if actual != before:
        raise SystemExit(f"offline local navigation changed sync status or counts: {actual}")
before_ledger = json.load(open(sys.argv[4], encoding="utf-8"))
after_ledger = json.load(open(sys.argv[5], encoding="utf-8"))
if after_ledger != before_ledger:
    raise SystemExit("offline local navigation added a controller sync ledger event")
PY

api POST /v1/diagnostics/overrides \
  '{"networkType":"wifi","nativeMetered":false,"interactiveHydrationAllowed":true,"requestReporting":true}' \
  > "$OUTPUT_ROOT/online-overrides.json"
wait_for_stable_catalog_status "$OUTPUT_ROOT/catalog-before-target.json"

ALBUM_ID="$(python3 - "$CLONE_DB" <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
row = db.execute(
    "SELECT id FROM albums ORDER BY CASE WHEN songs_hydrated = 0 THEN 0 ELSE 1 END, id LIMIT 1"
).fetchone()
db.close()
if row is None:
    raise SystemExit("clone contains no album target")
print(row[0])
PY
)"

api POST /v1/sync/target \
  "$(python3 - "$ALBUM_ID" <<'PY'
import json, sys
print(json.dumps({"targetKind": "album", "entityId": sys.argv[1]}))
PY
)" > "$OUTPUT_ROOT/target-start.json"
api GET /v1/sync/status > "$OUTPUT_ROOT/catalog-during-target.json"

python3 - "$OUTPUT_ROOT/catalog-before-target.json" "$OUTPUT_ROOT/catalog-during-target.json" <<'PY'
import json, sys
before = json.load(open(sys.argv[1], encoding="utf-8"))
during = json.load(open(sys.argv[2], encoding="utf-8"))
before.pop("requestActive", None)
during.pop("requestActive", None)
if during != before:
    raise SystemExit("target hydration changed controller catalog status")
PY

wait_for_stable_catalog_status "$OUTPUT_ROOT/catalog-after-target.json"
api GET /v1/sync/ledger > "$OUTPUT_ROOT/sync-ledger.json"

python3 - "$OUTPUT_ROOT/sync-ledger.json" <<'PY'
import json, sys
events = json.load(open(sys.argv[1], encoding="utf-8")).get("events")
if not isinstance(events, list) or not events:
    raise SystemExit("sync diagnostics ledger returned no events")
for event in events:
    if not isinstance(event, dict):
        raise SystemExit("sync diagnostics ledger event is not an object")
    forbidden = {"url", "username", "password", "title", "path"} & set(event)
    if forbidden:
        raise SystemExit(f"sync diagnostics ledger exposed sensitive keys: {forbidden}")
target_events = [event for event in events if event.get("cause") == "targetHydration"]
if not target_events:
    raise SystemExit("sync diagnostics ledger omitted target hydration")
if not any(event.get("phase") == "terminal" for event in target_events):
    raise SystemExit("sync diagnostics ledger omitted target terminal event")
PY

api POST /v1/presentation/navigate '{"location":"/settings/sync"}' \
  > "$OUTPUT_ROOT/navigation.json"
# Navigation returns after GoRouter accepts the route, before the next rendered
# desktop frame. Let the app-owned presentation surface settle before capture.
sleep 5
capture_screenshot "$OUTPUT_ROOT/screenshot.json" "target-lane" \
  > "$OUTPUT_ROOT/screenshot-path.txt"
api POST /v1/shutdown > "$OUTPUT_ROOT/shutdown.json" || true
wait "$FLUTTER_PID" || true
FLUTTER_PID=0

launch
api GET /v1/health > "$OUTPUT_ROOT/restart-health.json"
wait_for_presentation "$OUTPUT_ROOT/restart-presentation-before.json"
wait_for_stable_catalog_status "$OUTPUT_ROOT/restart-catalog-status.json"
python3 - "$OUTPUT_ROOT/catalog-before.json" \
  "$OUTPUT_ROOT/restart-catalog-status.json" <<'PY'
import datetime, json, sys
before = json.load(open(sys.argv[1], encoding="utf-8"))
restart = json.load(open(sys.argv[2], encoding="utf-8"))
before_deadline = before.get("nextAutomaticCheckAt")
restart_deadline = restart.get("nextAutomaticCheckAt")
before_retry = before.get("nextRetryAt")
restart_retry = restart.get("nextRetryAt")
if (not isinstance(before_deadline, str) or not isinstance(restart_deadline, str)
        or not isinstance(before_retry, str) or not isinstance(restart_retry, str)):
    raise SystemExit("restart status omitted an automatic or retry deadline")
start = datetime.datetime.fromisoformat(before_deadline.replace("Z", "+00:00"))
end = datetime.datetime.fromisoformat(restart_deadline.replace("Z", "+00:00"))
if abs((end - start).total_seconds()) >= 1:
    raise SystemExit(
        f"restart changed automatic deadline: {before_deadline} -> {restart_deadline}"
    )
if before_retry != restart_retry:
    raise SystemExit(f"restart changed retry deadline: {before_retry} -> {restart_retry}")
PY
api POST /v1/presentation/navigate '{"location":"/settings/sync"}' \
  > "$OUTPUT_ROOT/restart-navigation.json"
sleep 5
capture_screenshot "$OUTPUT_ROOT/restart-screenshot.json" "target-lane-restart" \
  > "$OUTPUT_ROOT/restart-screenshot-path.txt"
api POST /v1/shutdown > "$OUTPUT_ROOT/restart-shutdown.json" || true
wait "$FLUTTER_PID" || true
FLUTTER_PID=0

if rg -n \
  'Unhandled Exception|Tried to modify a provider while the widget tree was building|created the database class NavisDatabase multiple times' \
  "$APP_LOG" > "$OUTPUT_ROOT/log-errors.txt"; then
  echo "Runtime log contains a hard-fail pattern. See $OUTPUT_ROOT/log-errors.txt" >&2
  exit 1
fi

python3 - \
  "$OUTPUT_ROOT/runtime-validation.json" \
  "$OUTPUT_ROOT/liked-screenshot-path.txt" \
  "$OUTPUT_ROOT/screenshot-path.txt" \
  "$OUTPUT_ROOT/restart-screenshot-path.txt" <<'PY'
import json, sys
liked = open(sys.argv[2], encoding="utf-8").read().strip()
initial = open(sys.argv[3], encoding="utf-8").read().strip()
restart = open(sys.argv[4], encoding="utf-8").read().strip()
json.dump({
    "status": "passed",
    "target": "linux",
    "profile": "isolated-clone",
    "scenario": "Future automatic deadline, online/offline Home-Library-Liked navigation, and target hydration preserve catalog status and counts",
    "endpoints": [
        "GET /v1/health", "GET /v1/sync/status", "GET /v1/sync/ledger", "POST /v1/sync/automatic", "POST /v1/sync/target",
        "POST /v1/presentation/navigate", "POST /v1/presentation/screenshot",
        "POST /v1/diagnostics/overrides",
        "POST /v1/shutdown"
    ],
    "screenshots": [liked, initial, restart],
    "visualInspection": "required-by-agent",
    "logReview": "no-hard-fail-patterns",
    "cleanRestart": "passed",
}, open(sys.argv[1], "w", encoding="utf-8"))
PY

echo "Target-lane diagnostics completed: $OUTPUT_ROOT"
echo "Open and inspect: $(<"$OUTPUT_ROOT/screenshot-path.txt")"
echo "Open and inspect: $(<"$OUTPUT_ROOT/restart-screenshot-path.txt")"
