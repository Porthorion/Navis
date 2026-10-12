#!/usr/bin/env bash
# Download preferences, concurrency, pause/cancel and durable download covers.
#
# An empty isolated Linux clone signs in to the loopback fixture server, whose
# album holds several songs that each take a few seconds to transfer. It
# downloads a song through the album row's download control: the quality
# picker opens, 320 kbps is picked, and the one-time "always download in this
# quality?" dialog is answered "Always use". It then downloads the rest of the
# album with three concurrent downloads, pauses and resumes a transfer, cancels
# one, and finally restarts with the fixture server stopped and the cover art
# caches deleted, so the album can show its cover only from the download
# artwork store. Screenshots are captured at each visible step.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_DIR/tool/lib/diagnostics.sh"
DIAGNOSTICS_APP_NAME='Navis Download Preferences Diagnostics'
DIAGNOSTICS_FAILURE_PREFIX='download-preferences'
DIAGNOSTICS_POLL_INTERVAL=0.5
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUTPUT_ROOT="$PROJECT_DIR/build/download-preferences-diagnostics/$STAMP"
HANDSHAKE="$OUTPUT_ROOT/handshake.json"
FIXTURE_HANDSHAKE="$OUTPUT_ROOT/fixture-handshake.json"
FIXTURE_LOG="$OUTPUT_ROOT/fixture.log"
CREDENTIAL_FILE="$OUTPUT_ROOT/fixture-password"
PROFILE_DB="$OUTPUT_ROOT/profile.sqlite"
ARTWORK_DIR="$OUTPUT_ROOT/support/artwork/permanent"
mkdir -p "$OUTPUT_ROOT"
chmod 700 "$OUTPUT_ROOT"

FLUTTER_PID=0
FIXTURE_PID=0
FIXTURE_PORT=''
TOKEN=''
BASE_URL=''
APP_LOG=''
SCREENSHOTS=()

stop_fixture() {
  if (( FIXTURE_PID > 0 )) && kill -0 "$FIXTURE_PID" >/dev/null 2>&1; then
    kill "$FIXTURE_PID" >/dev/null 2>&1 || true
    wait "$FIXTURE_PID" >/dev/null 2>&1 || true
  fi
  FIXTURE_PID=0
}

cleanup() {
  cleanup_app
  stop_fixture
}
trap cleanup EXIT INT TERM

api() {
  local method="$1" route="$2" body="${3:-}"
  local args=(--fail-with-body --silent --show-error --max-time 900
    -X "$method" -H "Authorization: Bearer $TOKEN")
  if [[ -n "$body" ]]; then
    args+=(-H 'Content-Type: application/json' -d "$body")
  fi
  local output
  if ! output="$(curl "${args[@]}" "$BASE_URL$route")"; then
    echo "download-preferences: $method $route failed: $output" >&2
    return 22
  fi
  printf '%s\n' "$output"
}

# Asserts the Python expression $2 over the JSON file $1.
check() {
  local file="$1" predicate="$2" message="$3"
  python3 -c "import json,sys; v=json.load(open(sys.argv[1])); raise SystemExit(0 if ($predicate) else 1)" \
    "$file" || fail "$message ($(cat "$file"))"
}

screenshot() {
  local label="$1"
  sleep 1 # let route, sheet and dialog transitions finish before a capture
  api POST /v1/presentation/screenshot "{\"label\":\"$label\"}" \
    > "$OUTPUT_ROOT/$label-screenshot.json"
  SCREENSHOTS+=("$(python3 - "$OUTPUT_ROOT/$label-screenshot.json" "$OUTPUT_ROOT" <<'PY'
import hashlib, json, os, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
root = os.path.realpath(sys.argv[2])
path = os.path.realpath(os.path.join(root, value["artifact"]))
assert os.path.commonpath([root, path]) == root, "screenshot escaped the run root"
data = open(path, "rb").read()
assert data[:8] == b"\x89PNG\r\n\x1a\n"
assert hashlib.sha256(data).hexdigest() == value["sha256"]
print(path)
PY
)")
}

# Counts pixels of the fixture cover's orange and teal in a screenshot (an
# RGBA PNG), so a placeholder where the cover belongs fails the run.
cover_pixels() {
  python3 - "$1" <<'PY'
import struct, sys, zlib
data = open(sys.argv[1], "rb").read()
pos, idat = 8, b""
while pos < len(data):
    length, kind = struct.unpack(">I4s", data[pos:pos + 8])
    body = data[pos + 8:pos + 8 + length]
    if kind == b"IHDR":
        width, height, depth, color = struct.unpack(">IIBB", body[:10])
    elif kind == b"IDAT":
        idat += body
    pos += 12 + length
assert depth == 8 and color in (2, 6), (depth, color)
bpp = 4 if color == 6 else 3
raw, stride, rows, prev = zlib.decompress(idat), width * bpp, [], bytearray(width * bpp)
for y in range(height):
    kind, line = raw[y * (stride + 1)], bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
    for i in range(stride):
        a = line[i - bpp] if i >= bpp else 0
        b, c = prev[i], prev[i - bpp] if i >= bpp else 0
        if kind == 1: line[i] = (line[i] + a) & 255
        elif kind == 2: line[i] = (line[i] + b) & 255
        elif kind == 3: line[i] = (line[i] + (a + b) // 2) & 255
        elif kind == 4:
            p = a + b - c
            pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
            line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
    rows.append(line); prev = line
def near(px, ref): return all(abs(px[k] - ref[k]) <= 24 for k in range(3))
orange = teal = 0
for line in rows:
    for x in range(0, stride, bpp):
        px = line[x:x + 3]
        orange += near(px, (240, 120, 30)); teal += near(px, (20, 150, 150))
print(min(orange, teal))
PY
}

# Retries a presentation action until its control is mounted (bounded).
act() {
  local action="$1" deadline=$((SECONDS + ${2:-30}))
  while (( SECONDS < deadline )); do
    if api POST /v1/presentation/track-action "{\"action\":\"$action\"}" \
      >/dev/null 2>"$OUTPUT_ROOT/last-action-error.txt"; then
      return
    fi
    sleep 1
  done
  fail "track action $action never found its control ($(cat "$OUTPUT_ROOT/last-action-error.txt"))"
}

start_fixture 'navis-download-preferences-fixture' \
  --scenario downloads --song-count 8 --media-seconds 5
launch_app first
api POST /v1/diagnostics/overrides \
  '{"networkType":"wifi","nativeMetered":false}' >/dev/null
api POST /v1/session/connect "$(python3 -c '
import json, sys
print(json.dumps({"url": f"http://127.0.0.1:{sys.argv[1]}",
                  "username": "diagnostics",
                  "password": open(sys.argv[2]).read().strip()}))' \
  "$FIXTURE_PORT" "$CREDENTIAL_FILE")" > "$OUTPUT_ROOT/connect.json"
wait_for /v1/session/status 'v.get("phase") == "ready"' \
  "$OUTPUT_ROOT/session-ready.json" 300
api POST /v1/presentation/onboarding/complete '{}' >/dev/null || true

# 1. A fresh install asks for the quality and has not been prompted yet.
api GET /v1/downloads/status > "$OUTPUT_ROOT/initial.json"
check "$OUTPUT_ROOT/initial.json" \
  'v["qualityPreference"] == {"mode": "ask", "bitRate": 320, "format": "mp3", "prompted": False} and v["maxConcurrent"] == 2 and not v["paused"]' \
  "unexpected initial download preferences"

# 2. The first download opens the picker, then asks once whether to always
#    use the picked quality; "Always use" saves it.
# Wide rows show the song's direct download control.
api POST /v1/presentation/window '{"width":1440,"height":900}' >/dev/null
# The album opens once its songs are in the library; startup work may still
# move the route, so navigate until the album stays current.
deadline=$((SECONDS + 90))
until api POST /v1/presentation/navigate \
    '{"location":"/library/albums/fixture-album"}' >/dev/null &&
  sleep 2 &&
  api GET /v1/presentation/status > "$OUTPUT_ROOT/presentation.json" &&
  python3 -c 'import json,sys; raise SystemExit(0 if "/library/albums/fixture-album" in (json.load(open(sys.argv[1])).get("route") or "") else 1)' \
    "$OUTPUT_ROOT/presentation.json" &&
  api POST /v1/presentation/track-action '{"action":"revealFirst"}' \
    >/dev/null 2>&1; do
  (( SECONDS < deadline )) || fail "the album page never showed its songs"
  sleep 2
done
screenshot album-page
act download 30
screenshot quality-picker
act downloadQuality320
screenshot always-prompt
act downloadQualityAlwaysUse
wait_for /v1/downloads/status \
  'v["qualityPreference"] == {"mode": "transcode", "bitRate": 320, "format": "mp3", "prompted": True}' \
  "$OUTPUT_ROOT/preference-saved.json" 30
# The fixture ignores the requested format and sends WAV: the download is
# stored under the format it actually received, at the song's bitrate.
wait_for /v1/downloads/status \
  'any(d["songId"] == "fixture-song" for d in v["permanentDownloads"]) and sum(v["queue"].values()) == 0' \
  "$OUTPUT_ROOT/first-download.json" 120
check "$OUTPUT_ROOT/first-download.json" \
  '[(d["format"], d["bitRate"], d["fileName"]) for d in v["permanentDownloads"]] == [("wav", 352, "Lifecycle Tone.wav")]' \
  "the first download was not stored as the format the server sent"
screenshot first-download-notice

# 3. Downloads settings show the saved quality.
api POST /v1/presentation/navigate '{"location":"/settings/downloads"}' >/dev/null
api POST /v1/presentation/track-action '{"action":"downloadsSettingsTab"}' >/dev/null
screenshot settings-quality

# 4. Three concurrent downloads: never more than three at once.
api POST /v1/downloads/settings '{"maxConcurrent":3,"resetPeak":true}' \
  > "$OUTPUT_ROOT/concurrency-set.json"
check "$OUTPUT_ROOT/concurrency-set.json" \
  'v["maxConcurrent"] == 3 and v["effectiveConcurrency"] == 3' \
  "concurrency setting not applied"
api POST /v1/downloads/enqueue \
  '{"songIds":["fixture-song-2","fixture-song-3","fixture-song-4"]}' >/dev/null
api POST /v1/downloads/enqueue \
  '{"songIds":["fixture-song-5","fixture-song-6","fixture-song-7"],"usePreference":true}' \
  >/dev/null
wait_for /v1/downloads/status 'len(v["activeQueueIds"]) == 3' \
  "$OUTPUT_ROOT/three-active.json" 60
api POST /v1/presentation/navigate '{"location":"/settings/downloads"}' >/dev/null
act downloadsQueueTab
screenshot queue-three-active
wait_for /v1/downloads/status \
  'len(v["permanentDownloads"]) == 7 and sum(v["queue"].values()) == 0' \
  "$OUTPUT_ROOT/album-downloaded.json" 240
check "$OUTPUT_ROOT/album-downloaded.json" 'v["peakActive"] == 3' \
  "more or fewer than three downloads ran at once"
check "$OUTPUT_ROOT/album-downloaded.json" \
  'len({d["fileName"] for d in v["permanentDownloads"]}) == 7' \
  "two downloads share a file"

# 5. Songs already downloaded in original quality are not downloaded again.
api POST /v1/downloads/enqueue \
  '{"songIds":["fixture-song-2","fixture-song-3","fixture-song-4"]}' >/dev/null
api GET /v1/downloads/status > "$OUTPUT_ROOT/original-again.json"
check "$OUTPUT_ROOT/original-again.json" \
  'sum(v["queue"].values()) == 0 and len(v["permanentDownloads"]) == 7' \
  "original downloads were queued again"

# 6. Pausing returns a transfer to the queue; resuming finishes it.
api POST /v1/downloads/enqueue '{"songIds":["fixture-song-8"]}' >/dev/null
wait_for /v1/downloads/status 'len(v["activeQueueIds"]) == 1' \
  "$OUTPUT_ROOT/song-8-active.json" 30
api POST /v1/downloads/settings '{"paused":true}' > "$OUTPUT_ROOT/paused.json"
wait_for /v1/downloads/status \
  'v["paused"] and not v["activeQueueIds"] and v["queue"]["queued"] == 1 and v["effectiveConcurrency"] == 0' \
  "$OUTPUT_ROOT/paused-queue.json" 30
screenshot queue-paused
sleep 6 # longer than one transfer: nothing may finish while paused
api GET /v1/downloads/status > "$OUTPUT_ROOT/still-paused.json"
check "$OUTPUT_ROOT/still-paused.json" \
  'len(v["permanentDownloads"]) == 7 and v["queue"]["queued"] == 1' \
  "a download finished while paused"
api POST /v1/downloads/settings '{"paused":false}' >/dev/null
wait_for /v1/downloads/status 'len(v["activeQueueIds"]) == 1' \
  "$OUTPUT_ROOT/resumed.json" 30

# 7. Cancelling the transfer in progress removes it and registers nothing.
QUEUE_ID="$(python3 -c \
  'import json,sys; print(json.load(open(sys.argv[1]))["activeQueueIds"][0])' \
  "$OUTPUT_ROOT/resumed.json")"
api POST /v1/downloads/cancel "{\"queueId\":$QUEUE_ID}" >/dev/null
wait_for /v1/downloads/status \
  'not v["activeQueueIds"] and sum(v["queue"].values()) == 0' \
  "$OUTPUT_ROOT/cancelled.json" 30
sleep 6
api GET /v1/downloads/status > "$OUTPUT_ROOT/after-cancel.json"
check "$OUTPUT_ROOT/after-cancel.json" \
  'len(v["permanentDownloads"]) == 7 and not any(d["songId"] == "fixture-song-8" for d in v["permanentDownloads"])' \
  "the cancelled download was registered"
if find "$OUTPUT_ROOT/support" -name '*.navis-part' | grep -q .; then
  fail "a cancelled or paused transfer left a part file"
fi

# 8. The album's cover is kept with the downloads.
check "$OUTPUT_ROOT/after-cancel.json" 'v["permanentArtworkCount"] == 1' \
  "the download cover was not stored"
[[ -f "$ARTWORK_DIR/fixture-cover.png" ]] || fail "the cover file is missing"

# 9. Restart with the server gone and every disposable cover cache deleted:
#    the album shows its cover from the download artwork store alone, and the
#    preferences survived.
stop_app
stop_fixture
find "$OUTPUT_ROOT/cache" "$OUTPUT_ROOT/support" -maxdepth 1 \
  \( -name 'navis_cover_art_cache*' -o -name 'navis_art_*' \) \
  -exec rm -rf {} + 2>/dev/null || true
if find "$OUTPUT_ROOT/cache" -maxdepth 1 -name 'navis_cover_art_cache*' | grep -q .; then
  fail "the cover art cache was not cleared"
fi
launch_app offline
api GET /v1/downloads/status > "$OUTPUT_ROOT/offline-status.json"
check "$OUTPUT_ROOT/offline-status.json" \
  'v["qualityPreference"]["mode"] == "transcode" and v["qualityPreference"]["prompted"] and v["maxConcurrent"] == 3 and not v["paused"] and len(v["permanentDownloads"]) == 7' \
  "download preferences did not survive the restart"
api POST /v1/presentation/navigate \
  '{"location":"/library/albums/fixture-album"}' >/dev/null
sleep 3
screenshot offline-album
OFFLINE_COVER="$(cover_pixels "${SCREENSHOTS[-1]}")"
(( OFFLINE_COVER > 5000 )) ||
  fail "the offline album shows no download cover ($OFFLINE_COVER cover pixels)"
stop_app

if grep -l 'EXCEPTION CAUGHT BY' "$OUTPUT_ROOT"/*-navis.log >/dev/null 2>&1; then
  fail "the app logged a Flutter exception"
fi
python3 - "$OUTPUT_ROOT" "${SCREENSHOTS[@]}" <<'PY'
import json, os, sys
root = sys.argv[1]
status = json.load(open(os.path.join(root, "album-downloaded.json")))
report = {
    "result": "passed",
    "peakActive": status["peakActive"],
    "downloads": status["permanentDownloads"],
    "screenshots": sys.argv[2:],
}
json.dump(report, open(os.path.join(root, "report.json"), "w"), indent=2)
print(json.dumps(report, indent=2))
PY
echo "download-preferences: passed ($OUTPUT_ROOT)"
