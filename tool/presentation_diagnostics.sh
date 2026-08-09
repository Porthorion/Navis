#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-clone}"
ROUTE="${2:-/}"
LABEL="${3:-home}"
if [[ "$MODE" != "clone" ]] ||
   [[ ! "$ROUTE" =~ ^/ ]] ||
   [[ "$ROUTE" =~ ^// ]] ||
   [[ ! "$LABEL" =~ ^[a-z0-9][a-z0-9_-]{0,35}$ ]]; then
  echo "Usage: $0 clone [/local-route] [safe-label]" >&2
  exit 64
fi

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DB="${NAVIS_DIAGNOSTICS_PRIMARY_DB:-$HOME/Documents/navis.sqlite.sqlite}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUTPUT_ROOT="$PROJECT_DIR/build/presentation-diagnostics/$STAMP-clone"
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
    --dart-define=NAVIS_APP_NAME='Navis Presentation Diagnostics' \
    --dart-define=NAVIS_SYNC_DIAGNOSTICS=true \
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

navigation_body() {
  python3 - "$ROUTE" <<'PY'
import json, sys
print(json.dumps({"location": sys.argv[1]}))
PY
}

screenshot_body() {
  python3 - "$1" <<'PY'
import json, sys
print(json.dumps({"label": sys.argv[1]}))
PY
}

validate_navigation() {
  python3 - "$1" "$ROUTE" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
if value.get("actualLocation") != sys.argv[2]:
    raise SystemExit(f"navigation did not reach requested route: {value}")
PY
}

wait_for_presentation() {
  local output_file="$1"
  local deadline=$((SECONDS + 60))
  while (( SECONDS < deadline )); do
    api GET /v1/presentation/status > "$output_file"
    if python3 - "$output_file" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
ready = value.get("screenshotReady") is True and value.get("appReady") is True
size = value.get("logicalWidth", 0) > 0 and value.get("logicalHeight", 0) > 0
route_ready = value.get("route") not in (None, "", "/loading")
raise SystemExit(0 if ready and size and route_ready else 1)
PY
    then
      return
    fi
    sleep 1
  done
  echo "Timed out waiting for the Flutter presentation surface." >&2
  exit 70
}

validate_screenshot() {
  python3 - "$1" "$OUTPUT_ROOT" "$2" <<'PY'
import hashlib, json, os, stat, sys
metadata_path, root, path_output = sys.argv[1:]
value = json.load(open(metadata_path, encoding="utf-8"))
artifact = value.get("artifact")
if not isinstance(artifact, str) or os.path.isabs(artifact):
    raise SystemExit("screenshot artifact must be relative")
root = os.path.realpath(root)
path = os.path.realpath(os.path.join(root, artifact))
if os.path.commonpath([root, path]) != root:
    raise SystemExit("screenshot escaped diagnostics root")
with open(path, "rb") as screenshot:
    data = screenshot.read()
if data[:8] != b"\x89PNG\r\n\x1a\n":
    raise SystemExit("screenshot is not a PNG")
if len(data) != value.get("byteCount"):
    raise SystemExit("screenshot byte count mismatch")
if hashlib.sha256(data).hexdigest() != value.get("sha256"):
    raise SystemExit("screenshot digest mismatch")
if value.get("pixelRatio") != 1.0:
    raise SystemExit("screenshot pixel ratio is not deterministic")
if value.get("pixelWidth", 0) <= 0 or value.get("pixelHeight", 0) <= 0:
    raise SystemExit("screenshot dimensions are invalid")
if stat.S_IMODE(os.stat(path).st_mode) != 0o600:
    raise SystemExit("screenshot file is not mode 0600")
if stat.S_IMODE(os.stat(os.path.dirname(path)).st_mode) != 0o700:
    raise SystemExit("screenshot directory is not mode 0700")
with open(path_output, "w", encoding="utf-8") as output:
    output.write(path + "\n")
PY
}

validate_window_response() {
  python3 - "$1" "$2" "$3" "$4" "$5" <<'PY'
import json, math, sys
path, expected_mode, expected_transition, expected_width, expected_height = sys.argv[1:]
value = json.load(open(path, encoding="utf-8"))
if value.get("mode") != expected_mode:
    raise SystemExit(f"unexpected window mode: {value}")
pending = value.get("pendingTransition")
if expected_transition == "none":
    if pending is not None:
        raise SystemExit(f"unexpected pending transition: {value}")
elif not isinstance(pending, dict) or pending.get("direction") != expected_transition:
    raise SystemExit(f"missing {expected_transition} transition: {value}")
bounds = value.get("bounds")
if not isinstance(bounds, dict):
    raise SystemExit(f"window bounds unavailable: {value}")
if not math.isclose(bounds.get("width", -1), float(expected_width), abs_tol=1.0):
    raise SystemExit(f"unexpected window width: {value}")
if not math.isclose(bounds.get("height", -1), float(expected_height), abs_tol=1.0):
    raise SystemExit(f"unexpected window height: {value}")
if value.get("desktopViewAvailable") is not True:
    raise SystemExit(f"desktop work area unexpectedly unavailable: {value}")
PY
}

capture_window_screenshot() {
  local prefix="$1"
  local label="$2"
  api POST /v1/presentation/screenshot "$(screenshot_body "$label")" \
    > "$OUTPUT_ROOT/$prefix.json"
  validate_screenshot \
    "$OUTPUT_ROOT/$prefix.json" \
    "$OUTPUT_ROOT/$prefix-path.txt"
}

run_capture() {
  local prefix="$1"
  local capture_label="$prefix-$LABEL"
  api GET /v1/health > "$OUTPUT_ROOT/$prefix-health.json"
  wait_for_presentation "$OUTPUT_ROOT/$prefix-presentation-before.json"
  api POST /v1/presentation/navigate "$(navigation_body)" \
    > "$OUTPUT_ROOT/$prefix-navigation.json"
  validate_navigation "$OUTPUT_ROOT/$prefix-navigation.json"
  if [[ "${NAVIS_DESKTOP_LAYOUT_DIAGNOSTICS:-0}" == "1" ]]; then
    api GET /v1/presentation/window \
      > "$OUTPUT_ROOT/$prefix-window-before.json"
    api POST /v1/presentation/window \
      '{"mode":"desktop"}' \
      > "$OUTPUT_ROOT/$prefix-window-desktop-mode.json"
    api POST /v1/presentation/window \
      '{"width":1306,"height":853}' \
      > "$OUTPUT_ROOT/$prefix-window-desktop-standard.json"
    validate_window_response \
      "$OUTPUT_ROOT/$prefix-window-desktop-standard.json" desktop none 1306 853
    capture_window_screenshot \
      "$prefix-desktop-standard-screenshot" "$prefix-desktop-standard"
    api POST /v1/presentation/window \
      '{"width":1159,"height":678}' \
      > "$OUTPUT_ROOT/$prefix-window-desktop-short.json"
    validate_window_response \
      "$OUTPUT_ROOT/$prefix-window-desktop-short.json" desktop none 1159 678
    capture_window_screenshot \
      "$prefix-desktop-short-screenshot" "$prefix-desktop-short"
    api POST /v1/presentation/window \
      '{"width":887,"height":900}' \
      > "$OUTPUT_ROOT/$prefix-window-desktop-compact.json"
    validate_window_response \
      "$OUTPUT_ROOT/$prefix-window-desktop-compact.json" desktop none 887 900
    capture_window_screenshot \
      "$prefix-desktop-compact-screenshot" "$prefix-desktop-compact"
    api POST /v1/presentation/window \
      '{"width":800,"height":600}' \
      > "$OUTPUT_ROOT/$prefix-window-desktop.json"
    validate_window_response \
      "$OUTPUT_ROOT/$prefix-window-desktop.json" desktop none 800 600
    capture_window_screenshot \
      "$prefix-desktop-screenshot" "$prefix-desktop-view"

    api POST /v1/presentation/window \
      '{"width":799,"height":599}' \
      > "$OUTPUT_ROOT/$prefix-window-enter-mini-gate.json"
    validate_window_response \
      "$OUTPUT_ROOT/$prefix-window-enter-mini-gate.json" \
      desktop enterMiniPlayer 799 599
    capture_window_screenshot \
      "$prefix-enter-mini-gate-screenshot" "$prefix-enter-mini-gate"
    api POST /v1/presentation/window \
      '{"width":799,"height":444}' \
      > "$OUTPUT_ROOT/$prefix-window-enter-mini-gate-short.json"
    validate_window_response \
      "$OUTPUT_ROOT/$prefix-window-enter-mini-gate-short.json" \
      desktop enterMiniPlayer 799 444
    capture_window_screenshot \
      "$prefix-enter-mini-gate-short-screenshot" \
      "$prefix-enter-mini-gate-short"
    api POST /v1/presentation/window \
      '{"transitionResolution":"restoreBounds"}' \
      > "$OUTPUT_ROOT/$prefix-window-desktop-restored.json"
    validate_window_response \
      "$OUTPUT_ROOT/$prefix-window-desktop-restored.json" desktop none 800 600

    api POST /v1/presentation/window \
      '{"mode":"miniPlayer"}' \
      > "$OUTPUT_ROOT/$prefix-window-mini-mode.json"
    validate_window_response \
      "$OUTPUT_ROOT/$prefix-window-mini-mode.json" miniPlayer none 720 405
    capture_window_screenshot \
      "$prefix-mini-default-screenshot" "$prefix-mini-default"
    api POST /v1/presentation/window \
      '{"width":560,"height":360}' \
      > "$OUTPUT_ROOT/$prefix-window-mini.json"
    validate_window_response \
      "$OUTPUT_ROOT/$prefix-window-mini.json" miniPlayer none 560 360
    capture_window_screenshot \
      "$prefix-mini-minimum-screenshot" "$prefix-mini-minimum"

    api POST /v1/presentation/window \
      '{"width":800,"height":600}' \
      > "$OUTPUT_ROOT/$prefix-window-exit-mini-gate.json"
    validate_window_response \
      "$OUTPUT_ROOT/$prefix-window-exit-mini-gate.json" \
      miniPlayer exitMiniPlayer 800 600
    capture_window_screenshot \
      "$prefix-exit-mini-gate-screenshot" "$prefix-exit-mini-gate"
    api POST /v1/presentation/window \
      '{"transitionResolution":"restoreBounds"}' \
      > "$OUTPUT_ROOT/$prefix-window-mini-restored.json"
    validate_window_response \
      "$OUTPUT_ROOT/$prefix-window-mini-restored.json" miniPlayer none 720 405
    capture_window_screenshot \
      "$prefix-mini-screenshot" "$prefix-mini-player"
  fi
  api GET /v1/presentation/status \
    > "$OUTPUT_ROOT/$prefix-presentation-after.json"
  api POST /v1/presentation/screenshot "$(screenshot_body "$capture_label")" \
    > "$OUTPUT_ROOT/$prefix-screenshot.json"
  validate_screenshot \
    "$OUTPUT_ROOT/$prefix-screenshot.json" \
    "$OUTPUT_ROOT/$prefix-screenshot-path.txt"
}

shutdown_app() {
  api POST /v1/shutdown > "$OUTPUT_ROOT/$1-shutdown.json" || true
  wait "$FLUTTER_PID" || true
  FLUTTER_PID=0
}

launch_app
run_capture initial
shutdown_app initial

launch_app
run_capture restart
shutdown_app restart

if rg -n \
  'Unhandled Exception|Tried to modify a provider while the widget tree was building|created the database class NavisDatabase multiple times' \
  "$APP_LOG" > "$OUTPUT_ROOT/log-errors.txt"; then
  echo "Runtime log contains a hard-fail pattern. See $OUTPUT_ROOT/log-errors.txt" >&2
  exit 1
fi

python3 - \
  "$OUTPUT_ROOT/runtime-validation.json" \
  "$ROUTE" \
  "${NAVIS_QUALITY_GATE_RESULT:-not-run}" \
  "$OUTPUT_ROOT/initial-screenshot.json" \
  "$OUTPUT_ROOT/restart-screenshot.json" <<'PY'
import json, sys
screenshots = []
for path in sys.argv[4:]:
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
        "route": sys.argv[2],
        "endpoints": [
            "GET /v1/health",
            "GET /v1/presentation/status",
            "GET /v1/presentation/window",
            "POST /v1/presentation/window",
            "POST /v1/presentation/navigate",
            "POST /v1/presentation/screenshot",
            "POST /v1/shutdown",
        ],
        "screenshots": screenshots,
        "visualInspection": "required-by-agent",
        "logReview": "no-hard-fail-patterns",
        "qualityGate": sys.argv[3],
        "cleanRestart": "passed",
    }, output)
PY

echo "Presentation diagnostics completed: $OUTPUT_ROOT"
echo "Open and inspect both PNG paths listed in:"
echo "  $OUTPUT_ROOT/initial-screenshot-path.txt"
echo "  $OUTPUT_ROOT/restart-screenshot-path.txt"
