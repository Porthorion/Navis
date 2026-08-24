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
OUTPUT_ROOT="$PROJECT_DIR/build/playback-indicator-diagnostics/$STAMP-clone"
CLONE_DB="$OUTPUT_ROOT/navis-diagnostics.sqlite"
CACHE_ROOT="$OUTPUT_ROOT/cache"
HANDSHAKE="$OUTPUT_ROOT/handshake.json"
APP_LOG="$OUTPUT_ROOT/navis.log"
mkdir -p "$CACHE_ROOT"
chmod 700 "$OUTPUT_ROOT"

if [[ ! -f "$SOURCE_DB" ]]; then
  echo "Primary database not found: $SOURCE_DB" >&2
  exit 66
fi

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
    digest = hashlib.sha256(song_id.encode("utf-8")).hexdigest()
    destination = os.path.join(cache_root, f"{digest}{extension}")
    if os.path.isfile(source_path):
        with open(source_path, "rb") as source_file, open(destination, "wb") as output:
            while chunk := source_file.read(1024 * 1024):
                output.write(chunk)
    target.execute(
        "UPDATE cached_tracks SET file_path = ? WHERE song_id = ?",
        (destination, song_id),
    )
target.commit()
integrity = target.execute("PRAGMA integrity_check").fetchone()[0]
foreign_keys = target.execute("PRAGMA foreign_key_check").fetchall()
target.close()
if integrity != "ok" or foreign_keys:
    raise SystemExit("isolated clone validation failed")
PY
chmod 600 "$CLONE_DB"

mapfile -t SONG_IDS < <(python3 - "$CLONE_DB" <<'PY'
import sqlite3, sys
db = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
rows = db.execute(
    "SELECT id FROM songs "
    "WHERE is_provisional = 0 AND server_deleted_at IS NULL "
    "ORDER BY starred IS NOT NULL DESC, COALESCE(duration, 0) DESC LIMIT 2"
).fetchall()
db.close()
for row in rows:
    print(row[0])
PY
)
if (( ${#SONG_IDS[@]} < 2 )); then
  echo "At least two playable catalog songs are required." >&2
  exit 69
fi
SONG_ONE="${SONG_IDS[0]}"
SONG_TWO="${SONG_IDS[1]}"

cd "$PROJECT_DIR"
: > "$APP_LOG"
FLUTTER_PID=0

cleanup() {
  if (( FLUTTER_PID > 0 )) && kill -0 "$FLUTTER_PID" >/dev/null 2>&1; then
    kill "$FLUTTER_PID" >/dev/null 2>&1 || true
    wait "$FLUTTER_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

launch_app() {
  rm -f "$HANDSHAKE"
  flutter run -d linux --profile \
    --dart-define=NAVIS_UPDATE_CHANNEL=dev \
    --dart-define=NAVIS_APP_ID_SUFFIX=.dev \
    --dart-define=NAVIS_APP_NAME='Navis Indicator Diagnostics' \
    --dart-define=NAVIS_SYNC_DIAGNOSTICS=true \
    --dart-define=NAVIS_SYNC_DIAGNOSTICS_MUTED=true \
    --dart-define=NAVIS_SYNC_DIAGNOSTICS_MODE=clone \
    --dart-define="NAVIS_SYNC_DIAGNOSTICS_HANDSHAKE=$HANDSHAKE" \
    --dart-define="NAVIS_SYNC_DIAGNOSTICS_ROOT=$OUTPUT_ROOT" \
    --dart-define="NAVIS_SYNC_DIAGNOSTICS_DB_PATH=$CLONE_DB" \
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

song_body() {
  python3 - "$1" <<'PY'
import json, sys
print(json.dumps({"songId": sys.argv[1]}))
PY
}

indicator_route() {
  python3 - "$1" <<'PY'
import sys, urllib.parse
print("/v1/presentation/song-indicator?songId=" + urllib.parse.quote(sys.argv[1]))
PY
}

wait_for_song() {
  local expected_song="$1"
  local expected_playing="$2"
  local output_file="$3"
  local deadline=$((SECONDS + 90))
  while (( SECONDS < deadline )); do
    local status
    status="$(api GET /v1/playback/status)"
    if python3 - "$expected_song" "$expected_playing" "$status" <<'PY'
import json, sys
value = json.loads(sys.argv[3])
expected_playing = sys.argv[2] == "true"
raise SystemExit(0 if value.get("songId") == sys.argv[1]
                 and value.get("playing") is expected_playing
                 and not value.get("isLoading") else 1)
PY
    then
      python3 - "$expected_playing" "$status" "$output_file" <<'PY'
import json, sys
value = json.loads(sys.argv[2])
with open(sys.argv[3], "w", encoding="utf-8") as output:
    json.dump({
        "matchedExpectedSong": True,
        "playing": sys.argv[1] == "true",
        "isLoading": value.get("isLoading"),
        "processingState": value.get("processingState"),
        "loadFailures": value.get("loadFailures", 0),
    }, output)
PY
      return
    fi
    sleep 1
  done
  echo "Timed out waiting for playback state. See $APP_LOG" >&2
  exit 70
}

assert_indicator() {
  local song_id="$1"
  local expected_state="$2"
  local output_file="$3"
  local response
  response="$(api GET "$(indicator_route "$song_id")")"
  printf '%s\n' "$response" > "$output_file"
  python3 - "$expected_state" "$response" <<'PY'
import json, sys
value = json.loads(sys.argv[2])
expected = sys.argv[1]
assert value.get("state") == expected, value
assert value.get("selected") is (expected != "inactive"), value
assert "songId" not in value, value
PY
}

capture_screenshot() {
  local label="$1"
  local output_file="$2"
  api POST /v1/presentation/screenshot "{\"label\":\"$label\"}" \
    > "$output_file"
  python3 - "$output_file" "$OUTPUT_ROOT" <<'PY'
import hashlib, json, os, stat, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
root = os.path.realpath(sys.argv[2])
artifact = value.get("artifact")
if not isinstance(artifact, str) or os.path.isabs(artifact):
    raise SystemExit("screenshot artifact must be relative")
path = os.path.realpath(os.path.join(root, artifact))
if os.path.commonpath([root, path]) != root:
    raise SystemExit("screenshot escaped diagnostics root")
with open(path, "rb") as screenshot:
    data = screenshot.read()
assert data[:8] == b"\x89PNG\r\n\x1a\n", "invalid PNG signature"
assert len(data) == value.get("byteCount"), "byte count mismatch"
assert hashlib.sha256(data).hexdigest() == value.get("sha256"), "digest mismatch"
assert stat.S_IMODE(os.stat(path).st_mode) == 0o600, "unsafe screenshot mode"
PY
}

show_queue() {
  local output_file="$1"
  api POST /v1/presentation/player-overlay \
    '{"surface":"queue","visible":true}' > "$output_file"
}

mute_and_verify() {
  local response
  response="$(api POST /v1/playback/volume '{"value":0}')"
  python3 - "$response" <<'PY'
import json, sys
value = json.loads(sys.argv[1])
assert value.get("volume") == 0, value
assert value.get("effectivePlayerVolume") == 0, value
PY
}

run_acceptance() {
  local prefix="$1"
  api GET /v1/health > "$OUTPUT_ROOT/$prefix-health.json"

  api POST /v1/playback/start "$(song_body "$SONG_ONE")" > /dev/null
  wait_for_song "$SONG_ONE" true "$OUTPUT_ROOT/$prefix-playing-one.json"
  assert_indicator "$SONG_ONE" current "$OUTPUT_ROOT/$prefix-current-one.json"
  assert_indicator "$SONG_TWO" inactive "$OUTPUT_ROOT/$prefix-inactive-two.json"
  show_queue "$OUTPUT_ROOT/$prefix-current-queue-overlay.json"
  capture_screenshot \
    "$prefix-current-queue" \
    "$OUTPUT_ROOT/$prefix-current-screenshot.json"

  api POST /v1/playback/pause > /dev/null
  wait_for_song "$SONG_ONE" false "$OUTPUT_ROOT/$prefix-paused-one.json"
  assert_indicator "$SONG_ONE" current \
    "$OUTPUT_ROOT/$prefix-paused-indicator-one.json"
  show_queue "$OUTPUT_ROOT/$prefix-paused-queue-overlay.json"
  capture_screenshot \
    "$prefix-paused-queue" \
    "$OUTPUT_ROOT/$prefix-paused-screenshot.json"

  api POST /v1/playback/start "$(song_body "$SONG_TWO")" > /dev/null
  wait_for_song "$SONG_TWO" true "$OUTPUT_ROOT/$prefix-playing-two.json"
  assert_indicator "$SONG_ONE" inactive "$OUTPUT_ROOT/$prefix-inactive-one.json"
  assert_indicator "$SONG_TWO" current "$OUTPUT_ROOT/$prefix-current-two.json"
  show_queue "$OUTPUT_ROOT/$prefix-switched-queue-overlay.json"
  capture_screenshot \
    "$prefix-switched-queue" \
    "$OUTPUT_ROOT/$prefix-switched-screenshot.json"
  local report
  report="$(api GET /v1/diagnostics/report)"
  python3 - "$report" "$OUTPUT_ROOT/$prefix-report.json" <<'PY'
import json, sys
value = json.loads(sys.argv[1])
playback = value.get("playback") or {}
if playback.get("loadFailures") not in (None, 0):
    raise SystemExit("playback diagnostics reported load failures")
with open(sys.argv[2], "w", encoding="utf-8") as output:
    json.dump({
        "syncErrorType": value.get("syncErrorType"),
        "playback": {
            "active": playback.get("active"),
            "playing": playback.get("playing"),
            "loadFailures": playback.get("loadFailures"),
        },
        "frameSamples": (value.get("frames") or {}).get("samples"),
        "databaseCanarySamples": (
            value.get("databaseCanary") or {}
        ).get("samples"),
    }, output)
PY
}

launch_app
mute_and_verify
run_acceptance initial
api POST /v1/shutdown > "$OUTPUT_ROOT/initial-shutdown.json" || true
wait "$FLUTTER_PID" || true
FLUTTER_PID=0

launch_app
mute_and_verify
run_acceptance restart
api POST /v1/shutdown > "$OUTPUT_ROOT/restart-shutdown.json" || true
wait "$FLUTTER_PID" || true
FLUTTER_PID=0

if rg -n \
  'Unhandled Exception|Tried to modify a provider while the widget tree was building|created the database class NavisDatabase multiple times' \
  "$APP_LOG" > "$OUTPUT_ROOT/log-errors.txt"; then
  echo "Runtime log contains a hard-fail pattern. See $OUTPUT_ROOT/log-errors.txt" >&2
  exit 1
fi

KNOWN_PLATFORM_WARNING_COUNT="$({
  rg -c 'MPV: \[error\] lavf: Failed to create file cache\.' "$APP_LOG" || true
} | tail -1)"
KNOWN_PLATFORM_WARNING_COUNT="${KNOWN_PLATFORM_WARNING_COUNT:-0}"

python3 - \
  "$OUTPUT_ROOT/runtime-validation.json" \
  "${NAVIS_QUALITY_GATE_RESULT:-not-run}" \
  "$KNOWN_PLATFORM_WARNING_COUNT" \
  "$OUTPUT_ROOT" <<'PY'
import glob, json, os, sys
screenshots = []
for path in sorted(glob.glob(os.path.join(sys.argv[4], "*-screenshot.json"))):
    value = json.load(open(path, encoding="utf-8"))
    screenshots.append({
        "artifact": value["artifact"],
        "pixelWidth": value["pixelWidth"],
        "pixelHeight": value["pixelHeight"],
        "sha256": value["sha256"],
    })
with open(sys.argv[1], "w", encoding="utf-8") as output:
    json.dump({
        "status": "passed",
        "target": "linux",
        "profile": "isolated-clone",
        "endpoints": [
            "GET /v1/health",
            "POST /v1/playback/start",
            "GET /v1/playback/status",
            "POST /v1/playback/pause",
            "GET /v1/presentation/song-indicator",
            "POST /v1/presentation/player-overlay",
            "POST /v1/presentation/screenshot",
            "GET /v1/diagnostics/report",
            "POST /v1/shutdown",
        ],
        "scenarios": [
            "current-and-inactive-indicators",
            "paused-indicator-persistence",
            "indicator-moves-on-song-change",
            "clean-restart-repeat",
        ],
        "logReview": "no-hard-fail-patterns",
        "knownPlatformWarning": "media-kit-lavf-file-cache",
        "knownPlatformWarningCount": int(sys.argv[3]),
        "visualEvidence": "app-owned-screenshots-and-widget-semantics",
        "screenshots": screenshots,
        "retestIterations": 2,
        "qualityGate": sys.argv[2],
        "cleanRestart": "passed",
    }, output)
PY

echo "Playback indicator diagnostics completed: $OUTPUT_ROOT"
echo "Open and inspect every PNG under: $OUTPUT_ROOT/screenshots"
