#!/usr/bin/env bash
set -euo pipefail

# Proves that a production-controller target hydration does not change the
# catalog status shown by Library/Settings. The run is isolated: it copies the
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
import hashlib, os, sqlite3, sys
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
  (
    cd "$PROJECT_DIR"
    flutter run -d linux --profile \
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
raise SystemExit(0 if value.get("status") != "running" else 1)
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
  api POST /v1/presentation/screenshot '{"label":"target-lane"}' > "$metadata"
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

# Home and Library are local-catalog read surfaces. Repeatedly switching
# between them must not start or relabel a catalog operation. This reproduces
# the navigation pattern that previously looked like a sync because Liked and
# target work shared the global controller state.
for index in 1 2; do
  api POST /v1/presentation/navigate '{"location":"/"}' \
    > "$OUTPUT_ROOT/home-$index-navigation.json"
  sleep 2
  api POST /v1/presentation/navigate '{"location":"/library"}' \
    > "$OUTPUT_ROOT/library-$index-navigation.json"
  sleep 2
  api GET /v1/sync/status > "$OUTPUT_ROOT/catalog-after-library-$index.json"
done

python3 - "$OUTPUT_ROOT/catalog-before.json" \
  "$OUTPUT_ROOT/catalog-after-library-1.json" \
  "$OUTPUT_ROOT/catalog-after-library-2.json" <<'PY'
import json, sys
before = json.load(open(sys.argv[1], encoding="utf-8"))
for path in sys.argv[2:]:
    actual = json.load(open(path, encoding="utf-8"))
    if actual != before:
        raise SystemExit(
            f"Home-to-Library navigation changed catalog status: {actual}"
        )
PY

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

python3 - "$OUTPUT_ROOT/catalog-before.json" "$OUTPUT_ROOT/catalog-during-target.json" <<'PY'
import json, sys
before = json.load(open(sys.argv[1], encoding="utf-8"))
during = json.load(open(sys.argv[2], encoding="utf-8"))
before.pop("requestActive", None)
during.pop("requestActive", None)
if during != before:
    raise SystemExit("target hydration changed controller catalog status")
PY

api POST /v1/presentation/navigate '{"location":"/settings/sync"}' \
  > "$OUTPUT_ROOT/navigation.json"
# Navigation returns after GoRouter accepts the route, before the next rendered
# desktop frame. Let the app-owned presentation surface settle before capture.
sleep 5
capture_screenshot "$OUTPUT_ROOT/screenshot.json" > "$OUTPUT_ROOT/screenshot-path.txt"
api POST /v1/shutdown > "$OUTPUT_ROOT/shutdown.json" || true
wait "$FLUTTER_PID" || true
FLUTTER_PID=0

launch
api GET /v1/health > "$OUTPUT_ROOT/restart-health.json"
wait_for_presentation "$OUTPUT_ROOT/restart-presentation-before.json"
wait_for_stable_catalog_status "$OUTPUT_ROOT/restart-catalog-status.json"
api POST /v1/presentation/navigate '{"location":"/settings/sync"}' \
  > "$OUTPUT_ROOT/restart-navigation.json"
sleep 5
capture_screenshot "$OUTPUT_ROOT/restart-screenshot.json" \
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
  "$OUTPUT_ROOT/screenshot-path.txt" \
  "$OUTPUT_ROOT/restart-screenshot-path.txt" <<'PY'
import json, sys
initial = open(sys.argv[2], encoding="utf-8").read().strip()
restart = open(sys.argv[3], encoding="utf-8").read().strip()
json.dump({
    "status": "passed",
    "target": "linux",
    "profile": "isolated-clone",
    "scenario": "Home-to-Library navigation and target hydration preserve catalog status",
    "endpoints": [
        "GET /v1/health", "GET /v1/sync/status", "POST /v1/sync/target",
        "POST /v1/presentation/navigate", "POST /v1/presentation/screenshot",
        "POST /v1/shutdown"
    ],
    "screenshots": [initial, restart],
    "visualInspection": "required-by-agent",
    "logReview": "no-hard-fail-patterns",
    "cleanRestart": "passed",
}, open(sys.argv[1], "w", encoding="utf-8"))
PY

echo "Target-lane diagnostics completed: $OUTPUT_ROOT"
echo "Open and inspect: $(<"$OUTPUT_ROOT/screenshot-path.txt")"
echo "Open and inspect: $(<"$OUTPUT_ROOT/restart-screenshot-path.txt")"
