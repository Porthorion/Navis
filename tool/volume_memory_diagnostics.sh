#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DB="${NAVIS_DIAGNOSTICS_PRIMARY_DB:-$HOME/Documents/navis.sqlite.sqlite}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUTPUT_ROOT="$PROJECT_DIR/build/volume-memory-diagnostics/$STAMP"
CLONE_DB="$OUTPUT_ROOT/navis-volume-memory.sqlite"
HANDSHAKE="$OUTPUT_ROOT/handshake.json"
APP_LOG="$OUTPUT_ROOT/navis.log"

if [[ ! -f "$SOURCE_DB" ]]; then
  echo "Primary database not found: $SOURCE_DB" >&2
  exit 66
fi

mkdir -p "$OUTPUT_ROOT/cache"
chmod 700 "$OUTPUT_ROOT"
python3 - "$SOURCE_DB" "$CLONE_DB" "$OUTPUT_ROOT/cache" <<'PY'
import os, sqlite3, sys
source = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
target = sqlite3.connect(sys.argv[2])
source.backup(target)
source.close()
cache_root = sys.argv[3]
for song_id, source_path in target.execute(
    "SELECT song_id, file_path FROM cached_tracks"
).fetchall():
    extension = os.path.splitext(source_path)[1] or ".isolated"
    target.execute(
        "UPDATE cached_tracks SET file_path = ? WHERE song_id = ?",
        (os.path.join(cache_root, f"{song_id}{extension}"), song_id),
    )
target.commit()
target.close()
PY
chmod 600 "$CLONE_DB"

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
    --dart-define=NAVIS_APP_NAME='Navis Volume Diagnostics' \
    --dart-define=NAVIS_SYNC_DIAGNOSTICS=true \
    --dart-define=NAVIS_SYNC_DIAGNOSTICS_MODE=clone \
    --dart-define="NAVIS_SYNC_DIAGNOSTICS_HANDSHAKE=$HANDSHAKE" \
    --dart-define="NAVIS_SYNC_DIAGNOSTICS_ROOT=$OUTPUT_ROOT" \
    --dart-define="NAVIS_SYNC_DIAGNOSTICS_DB_PATH=$CLONE_DB" \
    >>"$APP_LOG" 2>&1 &
  FLUTTER_PID=$!

  for _ in $(seq 1 180); do
    [[ -s "$HANDSHAKE" ]] && break
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

  read -r PORT TOKEN < <(
    python3 - "$HANDSHAKE" <<'PY'
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

assert_volume() {
  local input_path="$1"
  local expected_volume="$2"
  local expected_last_audible="$3"
  python3 - "$input_path" "$expected_volume" "$expected_last_audible" <<'PY'
import json, math, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
expected = float(sys.argv[2])
last = float(sys.argv[3])
for key in ("volume", "persistedVolume", "handlerUserVolume"):
    assert math.isclose(value[key], expected, abs_tol=0.001), (key, value)
for key in ("lastAudibleVolume", "persistedLastAudibleVolume"):
    assert math.isclose(value[key], last, abs_tol=0.001), (key, value)
assert value["desktopPersistenceEnabled"] is True, value
assert value["hydrated"] is True, value
PY
}

shutdown_app() {
  api POST /v1/shutdown > "$OUTPUT_ROOT/shutdown-$1.json" || true
  wait "$FLUTTER_PID" || true
  FLUTTER_PID=0
}

launch_app
api GET /v1/health > "$OUTPUT_ROOT/health-initial.json"
api POST /v1/playback/volume '{"value":0.37}' \
  > "$OUTPUT_ROOT/volume-set.json"
assert_volume "$OUTPUT_ROOT/volume-set.json" 0.37 0.37
shutdown_app initial

launch_app
api GET /v1/health > "$OUTPUT_ROOT/health-volume-restart.json"
api GET /v1/playback/volume > "$OUTPUT_ROOT/volume-restored.json"
assert_volume "$OUTPUT_ROOT/volume-restored.json" 0.37 0.37
api POST /v1/playback/volume/toggle-mute \
  > "$OUTPUT_ROOT/volume-muted.json"
assert_volume "$OUTPUT_ROOT/volume-muted.json" 0 0.37
shutdown_app muted

launch_app
api GET /v1/health > "$OUTPUT_ROOT/health-muted-restart.json"
api GET /v1/playback/volume > "$OUTPUT_ROOT/mute-restored.json"
assert_volume "$OUTPUT_ROOT/mute-restored.json" 0 0.37
api POST /v1/playback/volume/toggle-mute \
  > "$OUTPUT_ROOT/volume-unmuted.json"
assert_volume "$OUTPUT_ROOT/volume-unmuted.json" 0.37 0.37
api GET /v1/diagnostics/report > "$OUTPUT_ROOT/report.json"
shutdown_app final

if grep -E \
  'Unhandled Exception|Desktop playback volume persistence failed|ERROR:flutter/runtime' \
  "$APP_LOG" >/dev/null; then
  echo "Runtime errors found in $APP_LOG" >&2
  exit 1
fi

trap - EXIT INT TERM
echo "Volume memory diagnostics completed: $OUTPUT_ROOT"
