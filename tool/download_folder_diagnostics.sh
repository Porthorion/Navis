#!/usr/bin/env bash
# Leaving a custom download folder must leave every file in it where it is.
#
# An empty isolated Linux clone signs in to the loopback lifecycle fixture,
# downloads the fixture song into app storage, then chooses a fixture folder
# inside the run root that already holds a user's copy of the song. It turns
# the folder off through the Downloads settings switch and its confirmation,
# restarts, chooses the folder again and finally switches to a second folder
# holding its own copy of the song, which must be adopted in place. Every
# folder snapshot (paths, sizes, sha256) must stay unchanged.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_DIR/tool/lib/diagnostics.sh"
DIAGNOSTICS_APP_NAME='Navis Download Folder Diagnostics'
DIAGNOSTICS_FAILURE_PREFIX='download-folder'
DIAGNOSTICS_POLL_INTERVAL=1
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUTPUT_ROOT="$PROJECT_DIR/build/download-folder-diagnostics/$STAMP"
HANDSHAKE="$OUTPUT_ROOT/handshake.json"
FIXTURE_HANDSHAKE="$OUTPUT_ROOT/fixture-handshake.json"
FIXTURE_LOG="$OUTPUT_ROOT/fixture.log"
CREDENTIAL_FILE="$OUTPUT_ROOT/fixture-password"
PROFILE_DB="$OUTPUT_ROOT/profile.sqlite"
USER_FOLDER="$OUTPUT_ROOT/user-folder"
OTHER_FOLDER="$OUTPUT_ROOT/other-folder"
APP_STORE="$OUTPUT_ROOT/support/audio/permanent"
mkdir -p "$OUTPUT_ROOT"
chmod 700 "$OUTPUT_ROOT"

FLUTTER_PID=0
FIXTURE_PID=0
FIXTURE_PORT=''
TOKEN=''
BASE_URL=''
APP_LOG=''

cleanup() {
  cleanup_fixture_app
}
trap cleanup EXIT INT TERM

api() {
  local method="$1" route="$2" body="${3:-}"
  local args=(--fail-with-body --silent --show-error --max-time 900
    -X "$method" -H "Authorization: Bearer $TOKEN")
  if [[ -n "$body" ]]; then
    args+=(-H 'Content-Type: application/json' -d "$body")
  fi
  curl "${args[@]}" "$BASE_URL$route"
}

# Polls the clone database until the custom folder setting is $1 (0 or 1).
wait_for_folder_setting() {
  local expected="$1" deadline=$((SECONDS + 120))
  while (( SECONDS < deadline )); do
    if python3 - "$PROFILE_DB" "$expected" <<'PY'
import sqlite3, sys
db = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
row = db.execute("SELECT custom_download_folder_enabled FROM app_settings").fetchone()
raise SystemExit(0 if row is not None and int(row[0]) == int(sys.argv[2]) else 1)
PY
    then
      return
    fi
    sleep 1
  done
  fail "custom folder setting never became $expected"
}

screenshot() {
  local label="$1"
  api POST /v1/presentation/screenshot "{\"label\":\"$label\"}" \
    > "$OUTPUT_ROOT/$label-screenshot.json"
  python3 - "$OUTPUT_ROOT/$label-screenshot.json" "$OUTPUT_ROOT" <<'PY'
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
}

# Paths, sizes and sha256 of every file in a folder except Navis's sidecar.
snapshot() {
  python3 - "$1" <<'PY'
import hashlib, json, os, sys
root = sys.argv[1]
files = {}
for directory, _, names in os.walk(root):
    for name in names:
        if name.startswith(".navis-downloads.sqlite"):
            continue
        path = os.path.join(directory, name)
        data = open(path, "rb").read()
        files[os.path.relpath(path, root)] = [len(data), hashlib.sha256(data).hexdigest()]
print(json.dumps(files, sort_keys=True))
PY
}

expect_snapshot() {
  local folder="$1" expected="$2" step="$3"
  local actual
  actual="$(snapshot "$folder")"
  [[ "$actual" == "$expected" ]] ||
    fail "$step changed $folder: expected $expected, found $actual"
}

audio_in() {
  find "$1" -type f -name '*.wav' 2>/dev/null | wc -l
}

# A minimal WAV file; the tone differs from the fixture's own stream.
write_user_wav() {
  python3 - "$1" <<'PY'
import os, struct, sys
samples = bytes([128, 160, 192, 160, 128, 96, 64, 96]) * 64
header = (b"RIFF" + struct.pack("<I", 36 + len(samples)) + b"WAVEfmt " +
          struct.pack("<IHHIIHH", 16, 1, 1, 8000, 8000, 1, 8) +
          b"data" + struct.pack("<I", len(samples)))
os.makedirs(os.path.dirname(sys.argv[1]), exist_ok=True)
open(sys.argv[1], "wb").write(header + samples)
PY
}

start_fixture 'navis-download-folder-fixture'
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

# 1. A Navis download in app storage, and a user folder that already holds
#    the user's own copy of the song plus an unrelated file.
api POST /v1/downloads/enqueue '{"songIds":["fixture-song"]}' >/dev/null
wait_for /v1/cache/status \
  'v["permanentEntries"] == 1 and v["missingFiles"] == 0' \
  "$OUTPUT_ROOT/downloaded.json"
(( $(audio_in "$APP_STORE") == 1 )) || fail "download is not in app storage"
write_user_wav "$USER_FOLDER/Rips/Fixture Artist/Lifecycle Tone.wav"
write_user_wav "$USER_FOLDER/Rips/Unknown/Untitled Take.wav"
USER_FILES="$(snapshot "$USER_FOLDER")"

# 2. Choosing the folder moves only the app-stored download into it.
api POST /v1/downloads/folder/adopt "{\"path\":\"$USER_FOLDER\"}" \
  > "$OUTPUT_ROOT/choose-folder.json"
wait_for_folder_setting 1
wait_for /v1/cache/status \
  'v["permanentEntries"] == 1 and v["missingFiles"] == 0' \
  "$OUTPUT_ROOT/folder-chosen.json"
(( $(audio_in "$APP_STORE") == 0 )) || fail "download stayed in app storage"
[[ -f "$USER_FOLDER/Fixture Artist/Lifecycle Tone.wav" ]] ||
  fail "download was not moved into the chosen folder"
python3 - "$USER_FILES" "$(snapshot "$USER_FOLDER")" <<'PY' ||
import json, sys
before, after = json.loads(sys.argv[1]), json.loads(sys.argv[2])
assert all(after.get(path) == value for path, value in before.items()), (before, after)
PY
  fail "choosing the folder changed the user's files"
FOLDER_FILES="$(snapshot "$USER_FOLDER")"

# 3. Turn the folder off through the settings switch and its confirmation.
api POST /v1/presentation/navigate '{"location":"/settings/downloads"}' >/dev/null
api POST /v1/presentation/track-action '{"action":"downloadsSettingsTab"}' >/dev/null
sleep 1 # let the tab and dialog transitions finish before each capture
screenshot folder-on > "$OUTPUT_ROOT/folder-on-path.txt"
api POST /v1/presentation/track-action '{"action":"customFolderOff"}' >/dev/null
sleep 1
screenshot turn-off-dialog > "$OUTPUT_ROOT/turn-off-dialog-path.txt"
api POST /v1/presentation/track-action '{"action":"confirmCustomFolderOff"}' >/dev/null
wait_for_folder_setting 0
wait_for /v1/cache/status 'v["permanentEntries"] == 0' \
  "$OUTPUT_ROOT/folder-off.json"
sleep 1
screenshot folder-off > "$OUTPUT_ROOT/folder-off-path.txt"
expect_snapshot "$USER_FOLDER" "$FOLDER_FILES" "turning the folder off"
[[ -f "$USER_FOLDER/.navis-downloads.sqlite" ]] || fail "the folder index was removed"
(( $(audio_in "$APP_STORE") == 0 )) || fail "files were moved into app storage"

# 4. A clean restart must not move anything either.
stop_app
launch_app restart
wait_for /v1/session/status 'v.get("phase") == "ready"' \
  "$OUTPUT_ROOT/restart-ready.json" 300
wait_for /v1/cache/status 'v["permanentEntries"] == 0' \
  "$OUTPUT_ROOT/restart-cache.json"
api POST /v1/presentation/navigate '{"location":"/settings/downloads"}' >/dev/null
api POST /v1/presentation/track-action '{"action":"downloadsSettingsTab"}' >/dev/null
sleep 1
screenshot restart-folder-off > "$OUTPUT_ROOT/restart-folder-off-path.txt"
expect_snapshot "$USER_FOLDER" "$FOLDER_FILES" "the restart"
(( $(audio_in "$APP_STORE") == 0 )) || fail "the restart moved files into app storage"

# 5. Choosing the folder again adopts its files back in place.
api POST /v1/downloads/folder/adopt "{\"path\":\"$USER_FOLDER\"}" \
  > "$OUTPUT_ROOT/choose-again.json"
wait_for_folder_setting 1
wait_for /v1/cache/status \
  'v["permanentEntries"] == 1 and v["missingFiles"] == 0' \
  "$OUTPUT_ROOT/chosen-again.json"
expect_snapshot "$USER_FOLDER" "$FOLDER_FILES" "choosing the folder again"

# 6. Switching to another folder that holds its own copy of the song leaves
#    the first folder alone and adopts the copy in place.
write_user_wav "$OTHER_FOLDER/Fixture Artist/Lifecycle Tone.wav"
OTHER_FILES="$(snapshot "$OTHER_FOLDER")"
api POST /v1/downloads/folder/adopt "{\"path\":\"$OTHER_FOLDER\"}" \
  > "$OUTPUT_ROOT/switch-folder.json"
wait_for /v1/cache/status \
  'v["permanentEntries"] == 1 and v["missingFiles"] == 0' \
  "$OUTPUT_ROOT/switched.json"
expect_snapshot "$USER_FOLDER" "$FOLDER_FILES" "switching folders"
expect_snapshot "$OTHER_FOLDER" "$OTHER_FILES" "switching folders"
python3 - "$PROFILE_DB" "$OTHER_FOLDER" <<'PY' ||
import os, sqlite3, sys
db = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
paths = [row[0] for row in db.execute("SELECT file_path FROM cached_tracks")]
root = os.path.realpath(sys.argv[2])
assert len(paths) == 1 and os.path.commonpath([root, os.path.realpath(paths[0])]) == root, paths
PY
  fail "the new folder's copy was not adopted"
stop_app

if grep -l 'EXCEPTION CAUGHT BY' "$OUTPUT_ROOT"/*-navis.log >/dev/null 2>&1; then
  fail "the app logged a Flutter exception"
fi
python3 - "$OUTPUT_ROOT" "$FOLDER_FILES" <<'PY'
import json, os, sys
root = sys.argv[1]
report = {"result": "passed", "userFolder": json.loads(sys.argv[2]),
          "screenshots": [open(os.path.join(root, f"{label}-path.txt")).read().strip()
                          for label in ("folder-on", "turn-off-dialog", "folder-off",
                                        "restart-folder-off")]}
json.dump(report, open(os.path.join(root, "report.json"), "w"), indent=2)
print(json.dumps(report, indent=2))
PY
echo "download-folder: passed ($OUTPUT_ROOT)"
