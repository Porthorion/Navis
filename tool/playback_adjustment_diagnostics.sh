#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DB="$(python3 "$PROJECT_DIR/tool/diagnostics_profile.py" primary-db)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUTPUT_ROOT="$PROJECT_DIR/build/playback-adjustment-diagnostics/$STAMP"
CLONE_DB="$OUTPUT_ROOT/navis-adjustments.sqlite"
HANDSHAKE="$OUTPUT_ROOT/handshake.json"
APP_LOG="$OUTPUT_ROOT/navis.log"

if [[ ! -f "$SOURCE_DB" ]]; then
  echo "Primary database not found: $SOURCE_DB" >&2
  exit 66
fi

mkdir -p "$OUTPUT_ROOT/cache"
chmod 700 "$OUTPUT_ROOT"
python3 - "$SOURCE_DB" "$CLONE_DB" "$OUTPUT_ROOT/cache" "$PROJECT_DIR/tool" <<'PY'
import os, shutil, sqlite3, sys, wave, math, struct, time, hashlib
sys.path.insert(0, sys.argv[4])
from diagnostics_profile import disable_external_integrations
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
        (os.path.join(cache_root, f"{hashlib.sha256(song_id.encode()).hexdigest()}{extension}"), song_id),
    )
tone_path = os.path.join(cache_root, 'tone.wav')
with wave.open(tone_path, 'wb') as tone:
    tone.setnchannels(1); tone.setsampwidth(2); tone.setframerate(44100)
    chunk = b''.join(struct.pack('<h', int(2200 * math.sin(2 * math.pi * 440 * i / 44100))) for i in range(44100))
    for _ in range(30): tone.writeframes(chunk)
for index, identity in enumerate(('diagnostics-adjustment-tone-1', 'diagnostics-adjustment-tone-2'), start=1):
    # Each song owns its file: the app moves a permanent download into its own
    # layout, which would leave a shared path missing for the other song.
    identity_path = os.path.join(cache_root, f'tone-{index}.wav')
    shutil.copyfile(tone_path, identity_path)
    target.execute("INSERT OR REPLACE INTO songs (id, title, duration, content_type, suffix) VALUES (?, 'Playback adjustment tone', 30, 'audio/wav', 'wav')", (identity,))
    target.execute("INSERT OR REPLACE INTO cached_tracks (song_id,file_path,file_size,format,last_accessed_at,cache_type,download_status) VALUES (?,?,?,?,?,'permanent','complete')", (identity,identity_path,os.path.getsize(identity_path),'wav',int(time.time())))
target.execute("UPDATE app_settings SET crossfade_enabled = 1, gapless_enabled = 1, crossfade_duration_seconds = 3, scrobble_enabled = 0, listen_brainz_scrobbling_enabled = 0")
columns = {row[1] for row in target.execute('PRAGMA table_info(app_settings)')}
# No external-service traffic in the measurement, including from a profile
# that predates the integration policy (schema 91).
disable_external_integrations(target)
if 'playback_presets' in columns:
    target.execute("UPDATE app_settings SET playback_presets = '[]', selected_playback_preset_id = NULL, playback_speed = 1, playback_pitch_semitones = 0")
if 'lock_pitch_to_speed' in columns:
    target.execute('UPDATE app_settings SET lock_pitch_to_speed = 0')
target.execute('DELETE FROM play_queue')
target.commit()
target.close()
PY
chmod 600 "$CLONE_DB"

cd "$PROJECT_DIR"
: > "$APP_LOG"
FLUTTER_PID=0
AUDIO_MODULE=""
AUDIO_SINK="navis_adjustments_$$"
if command -v pactl >/dev/null && command -v parec >/dev/null; then
  AUDIO_MODULE="$(pactl load-module module-null-sink "sink_name=$AUDIO_SINK" sink_properties=device.description=NavisAdjustmentDiagnostics)"
fi

cleanup() {
  if (( FLUTTER_PID > 0 )) && kill -0 "$FLUTTER_PID" >/dev/null 2>&1; then
    kill "$FLUTTER_PID" >/dev/null 2>&1 || true
    wait "$FLUTTER_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$AUDIO_MODULE" ]]; then pactl unload-module "$AUDIO_MODULE" || true; fi
}
trap cleanup EXIT INT TERM

launch_app() {
  rm -f "$HANDSHAKE"
  # Like presentation_diagnostics.sh: an optional mode-600 password file
  # signs the clone in where the system keyring holds no Navis password.
  local -a credential_define=()
  if [[ -n "${NAVIS_DIAGNOSTICS_CREDENTIAL_PATH:-}" ]]; then
    if [[ ! -f "$NAVIS_DIAGNOSTICS_CREDENTIAL_PATH" ]]; then
      echo "Diagnostics credential file was not found." >&2
      exit 66
    fi
    credential_define+=(
      "--dart-define=NAVIS_SYNC_DIAGNOSTICS_CREDENTIAL_PATH=$NAVIS_DIAGNOSTICS_CREDENTIAL_PATH"
    )
  fi
  PULSE_SINK="$AUDIO_SINK" flutter run -d linux --profile \
    --dart-define=NAVIS_UPDATE_CHANNEL=dev \
    --dart-define=NAVIS_APP_ID_SUFFIX=.dev \
    --dart-define=NAVIS_APP_NAME='Navis Adjustment Diagnostics' \
    --dart-define=NAVIS_SYNC_DIAGNOSTICS=true \
    --dart-define="NAVIS_DIAGNOSTICS_AUDIO_DEVICE=pulse/$AUDIO_SINK" \
    --dart-define=NAVIS_SYNC_DIAGNOSTICS_MODE=clone \
    --dart-define="NAVIS_SYNC_DIAGNOSTICS_HANDSHAKE=$HANDSHAKE" \
    --dart-define="NAVIS_SYNC_DIAGNOSTICS_ROOT=$OUTPUT_ROOT" \
    --dart-define="NAVIS_SYNC_DIAGNOSTICS_DB_PATH=$CLONE_DB" \
    "${credential_define[@]}" \
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

  read -r PORT TOKEN APP_PID < <(
    python3 - "$HANDSHAKE" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
print(value["port"], value["token"], value["pid"])
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

assert_adjustments() {
  python3 - "$1" "$2" "$3" <<'PYCODE'
import json, math, sys
value = json.load(open(sys.argv[1]))
speed = float(sys.argv[2]); pitch = float(sys.argv[3]); factor = 2 ** (pitch / 12)
assert value['failure'] is None, value
assert value['pitchSupported'] is True, value
assert math.isclose(value['speedPercent'], speed, abs_tol=1e-6), value
assert math.isclose(value['pitchSemitones'], pitch, abs_tol=1e-6), value
assert math.isclose(value['persistedSpeed'], 1 + speed/100, abs_tol=1e-6), value
assert math.isclose(value['persistedPitchSemitones'], pitch, abs_tol=1e-6), value
for key in ('playerSpeed', 'crossfadeSpeed'):
    assert math.isclose(value['engine'][key], 1 + speed/100, abs_tol=1e-6), value
for key in ('playerPitchFactor', 'crossfadePitchFactor'):
    assert math.isclose(value['engine'][key], factor, abs_tol=1e-6), value
PYCODE
}

capture_audio() {
  local label="$1"
  local pitch="$2"
  if [[ -z "$AUDIO_MODULE" ]]; then
    echo "Audio capture requires pactl and parec" >&2
    exit 69
  fi
  # PipeWire can restore a stream's old route despite PULSE_SINK. Move only
  # streams owned by this diagnostics process to its disposable capture sink.
  local deadline=$((SECONDS + 20))
  local indexes=""
  while (( SECONDS < deadline )); do
    indexes="$(pactl -f json list sink-inputs | python3 -c 'import json,sys; print(" ".join(str(x["index"]) for x in json.load(sys.stdin) if x.get("properties",{}).get("application.process.id") == sys.argv[1]))' "$APP_PID")"
    [[ -n "$indexes" ]] && break
    sleep 1
  done
  if [[ -z "$indexes" ]]; then echo "No audio stream owned by the diagnostics process" >&2; exit 70; fi
  for index in $indexes; do pactl move-sink-input "$index" "$AUDIO_SINK"; done
  timeout 3 parec --device="$AUDIO_SINK.monitor" --raw --rate=44100 --format=float32le --channels=1 > "$OUTPUT_ROOT/$label.pcm" || [[ $? -eq 124 ]]
  python3 - "$OUTPUT_ROOT/$label.pcm" "$OUTPUT_ROOT/$label-audio.json" "$pitch" <<'PYCODE'
import numpy as np, json, sys
raw = np.fromfile(sys.argv[1], dtype='<f4')
raw = raw[len(raw)//4:]
rms = float(np.sqrt(np.mean(raw**2)))
assert rms > 0.001, ('No audible native PCM', rms)
spectrum = abs(np.fft.rfft(raw * np.hanning(len(raw))))
frequency = float(np.argmax(spectrum) * 44100 / len(raw))
expected = 440 * 2 ** (float(sys.argv[3])/12)
assert abs(frequency - expected) < 3, (frequency, expected)
json.dump({'rms':rms, 'measuredHz':frequency, 'expectedHz':expected}, open(sys.argv[2], 'w'))
PYCODE
}

shutdown_app() {
  api POST /v1/shutdown > "$OUTPUT_ROOT/shutdown-$1.json" || true
  wait "$FLUTTER_PID" || true
  FLUTTER_PID=0
}

launch_app
api GET /v1/health > "$OUTPUT_ROOT/health-initial.json"
api POST /v1/playback/adjustments '{"speed":1.25,"lockPitchToSpeed":true}' > "$OUTPUT_ROOT/locked.json"
assert_adjustments "$OUTPUT_ROOT/locked.json" 25 3.863137138648348
api POST /v1/playback/queue '{"songIds":["diagnostics-adjustment-tone-1","diagnostics-adjustment-tone-2"]}' > "$OUTPUT_ROOT/locked-play.json"
capture_audio locked-natural 3.863137138648348
api POST /v1/playback/adjustments '{"lockPitchToSpeed":false}' > "$OUTPUT_ROOT/unlocked.json"
api POST /v1/playback/adjustments '{"speed":1.5}' > "$OUTPUT_ROOT/unlocked-faster.json"
assert_adjustments "$OUTPUT_ROOT/unlocked-faster.json" 50 3.863137138648348
capture_audio unlocked-fixed 3.863137138648348
api POST /v1/playback/queue/clear '{}' > "$OUTPUT_ROOT/locked-clear.json"

api POST /v1/playback/adjustments '{"lockPitchToSpeed":false,"speedPercent":27.35,"pitchSemitones":-2.37}' > "$OUTPUT_ROOT/adjusted.json"
assert_adjustments "$OUTPUT_ROOT/adjusted.json" 27.35 -2.37
api POST /v1/playback/adjustments '{"action":"save","name":"Nightcore"}' > "$OUTPUT_ROOT/preset.json"
PRESET_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["selectedPresetId"])' "$OUTPUT_ROOT/preset.json")"
api POST /v1/playback/adjustments '{"action":"select","id":"none"}' > "$OUTPUT_ROOT/none.json"
assert_adjustments "$OUTPUT_ROOT/none.json" 0 0
api POST /v1/playback/adjustments "{\"action\":\"select\",\"id\":\"$PRESET_ID\"}" > "$OUTPUT_ROOT/preset-applied.json"
assert_adjustments "$OUTPUT_ROOT/preset-applied.json" 27.35 -2.37
api POST /v1/playback/queue '{"songIds":["diagnostics-adjustment-tone-1","diagnostics-adjustment-tone-2"]}' > "$OUTPUT_ROOT/play.json"
api GET /v1/playback/status > "$OUTPUT_ROOT/position-before.json"
capture_audio pitch-shifted -2.37
api GET /v1/playback/status > "$OUTPUT_ROOT/position-after.json"
python3 - "$OUTPUT_ROOT/position-before.json" "$OUTPUT_ROOT/position-after.json" <<'PYCODE'
import json, sys
before, after = [json.load(open(path)) for path in sys.argv[1:]]
assert after['playing'], after
assert after['playerPositionMs'] > before['playerPositionMs'] + 2000, (before['playerPositionMs'], after['playerPositionMs'])
PYCODE
api POST /v1/playback/adjustments '{"speedPercent":45.12}' > "$OUTPUT_ROOT/speed-independent.json"
capture_audio speed-independent -2.37
assert_adjustments "$OUTPUT_ROOT/speed-independent.json" 45.12 -2.37
api POST /v1/playback/adjustments "{\"action\":\"select\",\"id\":\"$PRESET_ID\"}" > "$OUTPUT_ROOT/preset-reselected.json"
api POST /v1/playback/queue/clear '{}' > "$OUTPUT_ROOT/queue-cleared.json"
assert_adjustments "$OUTPUT_ROOT/queue-cleared.json" 27.35 -2.37
api POST /v1/playback/queue '{"songIds":["diagnostics-adjustment-tone-1","diagnostics-adjustment-tone-2"]}' > "$OUTPUT_ROOT/replay.json"
api POST /v1/playback/seek '{"positionMs":27000}' > "$OUTPUT_ROOT/crossfade-seek.json"
for _ in $(seq 1 15); do
  api GET /v1/playback/status > "$OUTPUT_ROOT/crossfade-status.json"
  if python3 - "$OUTPUT_ROOT/crossfade-status.json" <<'PYCODE'
import json, sys
value = json.load(open(sys.argv[1]))
sys.exit(0 if value['songId'] == 'diagnostics-adjustment-tone-2' and value['playing'] else 1)
PYCODE
  then break; fi
  sleep 1
done
python3 - "$OUTPUT_ROOT/crossfade-status.json" <<'PYCODE'
import json, sys
value = json.load(open(sys.argv[1]))
assert value['songId'] == 'diagnostics-adjustment-tone-2' and value['playing'], value
PYCODE
api GET /v1/playback/adjustments > "$OUTPUT_ROOT/crossfade-adjustments.json"
assert_adjustments "$OUTPUT_ROOT/crossfade-adjustments.json" 27.35 -2.37
api POST /v1/playback/adjustments '{"speed":1.25,"lockPitchToSpeed":true}' > "$OUTPUT_ROOT/linked-final.json"
api POST /v1/playback/adjustments "{\"action\":\"update\",\"id\":\"$PRESET_ID\",\"name\":\"Nightcore\"}" > "$OUTPUT_ROOT/linked-preset.json"
api POST /v1/presentation/window '{"mode":"desktop","width":1280,"height":1000}' > "$OUTPUT_ROOT/window.json"
api POST /v1/presentation/navigate '{"location":"/settings/playback"}' > "$OUTPUT_ROOT/navigate.json"
api POST /v1/presentation/adjustments '{}' > "$OUTPUT_ROOT/panel.json"
api POST /v1/presentation/screenshot '{"label":"adjustments-settings"}' > "$OUTPUT_ROOT/screenshot.json"
api GET /v1/playback/status > "$OUTPUT_ROOT/playback.json"
api POST /v1/presentation/window '{"mode":"miniPlayer"}' > "$OUTPUT_ROOT/window-player.json"
api POST /v1/presentation/adjustments '{"open":true}' > "$OUTPUT_ROOT/panel-player.json"
api POST /v1/presentation/screenshot '{"label":"adjustments-now-playing"}' > "$OUTPUT_ROOT/screenshot-player.json"
api POST /v1/presentation/dismiss-popup '{}' > "$OUTPUT_ROOT/dismiss-player.json"
api POST /v1/presentation/window '{"mode":"desktop","width":1280,"height":800}' > "$OUTPUT_ROOT/window-quick.json"
api POST /v1/presentation/navigate '{"location":"/"}' > "$OUTPUT_ROOT/navigate-quick.json"
# The desktop bar Speed button shows the multiplier and opens an anchored popover.
api POST /v1/presentation/adjustments '{"quick":true}' > "$OUTPUT_ROOT/quick-desktop.json"
python3 - "$OUTPUT_ROOT/quick-desktop.json" <<'PYCODE'
import json, sys
value = json.load(open(sys.argv[1]))
assert value['surface'] == 'popover', value
speed = [c for c in value['quickControls'] if c['key'] == 'desktopPlayerSpeedButton']
assert speed and speed[0]['enabled'] and speed[0]['label'] == '1.25×', value
PYCODE
api POST /v1/presentation/screenshot '{"label":"adjustments-quick-popover"}' > "$OUTPUT_ROOT/screenshot-quick.json"
api POST /v1/presentation/dismiss-popup '{}' > "$OUTPUT_ROOT/dismiss-quick.json"
# Keyboard shortcuts step speed through the production global key handler and
# keep the linked pitch mode; stepping back restores the restart baseline.
wait_for_speed() {
  local expected="$1" label="$2"
  for _ in $(seq 1 20); do
    api GET /v1/playback/adjustments > "$OUTPUT_ROOT/$label.json"
    if python3 - "$OUTPUT_ROOT/$label.json" "$expected" <<'PYCODE'
import json, sys
value = json.load(open(sys.argv[1]))
sys.exit(0 if abs(value['speed'] - float(sys.argv[2])) < 1e-9 and abs(value['persistedSpeed'] - float(sys.argv[2])) < 1e-9 and value['lockPitchToSpeed'] else 1)
PYCODE
    then return 0; fi
    sleep 0.25
  done
  echo "Speed did not reach $expected: $OUTPUT_ROOT/$label.json" >&2
  exit 1
}
api POST /v1/presentation/shortcut '{"action":"speedUp"}' > "$OUTPUT_ROOT/shortcut-up.json"
wait_for_speed 1.35 shortcut-up-state
api POST /v1/presentation/screenshot '{"label":"adjustments-shortcut-notice"}' > "$OUTPUT_ROOT/screenshot-shortcut.json"
api POST /v1/presentation/shortcut '{"action":"speedDown"}' > "$OUTPUT_ROOT/shortcut-down.json"
wait_for_speed 1.25 shortcut-down-state
# Mini Equalizer: the EQ button opens a compact popover; choosing a preset
# turns the EQ on, and the full page returns to where it was opened.
wait_for_quick_state() {
  local label="$1" expression="$2"
  for _ in $(seq 1 20); do
    api GET /v1/presentation/quick-panel > "$OUTPUT_ROOT/$label.json"
    if python3 - "$OUTPUT_ROOT/$label.json" "$expression" <<'PYCODE'
import json, sys
value = json.load(open(sys.argv[1]))
sys.exit(0 if eval(sys.argv[2], {}, {'v': value}) else 1)
PYCODE
    then return 0; fi
    sleep 0.25
  done
  echo "Quick panel state did not satisfy $expression: $OUTPUT_ROOT/$label.json" >&2
  exit 1
}
api POST /v1/equalizer '{"action":"enable","enabled":false}' > "$OUTPUT_ROOT/eq-disabled.json"
# Leaving Mini Player restores saved bounds, so request the wide desktop size
# again: below 980 px the bar intentionally drops its EQ button. The player
# controls also need an active track; the short tone queue may have finished.
api POST /v1/presentation/window '{"mode":"desktop","width":1280,"height":800}' > "$OUTPUT_ROOT/window-eq.json"
api POST /v1/playback/queue '{"songIds":["diagnostics-adjustment-tone-1","diagnostics-adjustment-tone-2"]}' > "$OUTPUT_ROOT/eq-play.json"
wait_for_quick_state eq-ready-state "any(c['key'] == 'desktopPlayerEqualizerButton' and c['enabled'] for c in v['quickControls'])"
api POST /v1/presentation/quick-panel '{"action":"open","target":"equalizer"}' > "$OUTPUT_ROOT/eq-quick-open.json"
python3 - "$OUTPUT_ROOT/eq-quick-open.json" <<'PYCODE'
import json, sys
value = json.load(open(sys.argv[1]))
assert value['surface'] == 'popover', value
assert any(c['key'] == 'desktopPlayerEqualizerButton' and c['enabled'] for c in value['quickControls']), value
PYCODE
api POST /v1/presentation/screenshot '{"label":"eq-quick-popover-off"}' > "$OUTPUT_ROOT/screenshot-eq-off.json"
api POST /v1/presentation/quick-panel '{"action":"preset","preset":"builtin:bass"}' > "$OUTPUT_ROOT/eq-quick-preset.json"
for _ in $(seq 1 20); do
  api GET /v1/equalizer > "$OUTPUT_ROOT/eq-after-preset.json"
  if python3 - "$OUTPUT_ROOT/eq-after-preset.json" <<'PYCODE'
import json, sys
v = json.load(open(sys.argv[1]))
sys.exit(0 if v['selectedPresetId'] == 'builtin:bass' and v['persistedPresetId'] == 'builtin:bass' and v['configuration']['enabled'] and not v['pending'] else 1)
PYCODE
  then break; fi
  sleep 0.25
done
python3 - "$OUTPUT_ROOT/eq-after-preset.json" <<'PYCODE'
import json, sys
v = json.load(open(sys.argv[1]))
assert v['selectedPresetId'] == 'builtin:bass' and v['configuration']['enabled'], v
assert v['persistedConfiguration']['enabled'], v
PYCODE
api POST /v1/presentation/screenshot '{"label":"eq-quick-popover-bass"}' > "$OUTPUT_ROOT/screenshot-eq-bass.json"
api POST /v1/presentation/quick-panel '{"action":"openPage"}' > "$OUTPUT_ROOT/eq-open-page.json"
wait_for_quick_state eq-page-state "v['location'] == '/settings/equalizer'"
api POST /v1/presentation/screenshot '{"label":"eq-page-from-quick"}' > "$OUTPUT_ROOT/screenshot-eq-page.json"
# The EQ button is now a Close toggle that returns to the origin page.
api POST /v1/presentation/quick-panel '{"action":"press","target":"equalizer"}' > "$OUTPUT_ROOT/eq-close-page.json"
wait_for_quick_state eq-closed-state "v['location'] == '/'"
# From Mini Player, opening the page leaves Mini Player and closing it returns.
api POST /v1/presentation/window '{"mode":"miniPlayer"}' > "$OUTPUT_ROOT/window-eq-mini.json"
api POST /v1/presentation/quick-panel '{"action":"open","target":"equalizer"}' > "$OUTPUT_ROOT/eq-mini-open.json"
api POST /v1/presentation/screenshot '{"label":"eq-quick-mini-player"}' > "$OUTPUT_ROOT/screenshot-eq-mini.json"
api POST /v1/presentation/quick-panel '{"action":"openPage"}' > "$OUTPUT_ROOT/eq-mini-page.json"
wait_for_quick_state eq-mini-page-state "v['location'] == '/settings/equalizer' and not v['miniPlayer']"
api POST /v1/presentation/quick-panel '{"action":"press","target":"equalizer"}' > "$OUTPUT_ROOT/eq-mini-close.json"
wait_for_quick_state eq-mini-restored-state "v['miniPlayer']"
api POST /v1/presentation/window '{"mode":"desktop","width":1280,"height":800}' > "$OUTPUT_ROOT/window-after-eq.json"
shutdown_app initial

launch_app
api GET /v1/health > "$OUTPUT_ROOT/health-restart.json"
api GET /v1/playback/adjustments > "$OUTPUT_ROOT/restored.json"
assert_adjustments "$OUTPUT_ROOT/restored.json" 25 3.863137138648348
python3 - "$OUTPUT_ROOT/restored.json" <<'PYCODE'
import json,sys
v=json.load(open(sys.argv[1]))
assert v["lockPitchToSpeed"] and v["persistedLockPitchToSpeed"] and v["presets"][0]["lockPitchToSpeed"],v
PYCODE
api POST /v1/presentation/window '{"mode":"desktop","width":1280,"height":1000}' > "$OUTPUT_ROOT/window-restart.json"
api POST /v1/presentation/navigate '{"location":"/settings/playback"}' > "$OUTPUT_ROOT/navigate-restart.json"
api POST /v1/presentation/adjustments '{}' > "$OUTPUT_ROOT/panel-restart.json"
api POST /v1/presentation/screenshot '{"label":"adjustments-restart"}' > "$OUTPUT_ROOT/screenshot-restart.json"
api POST /v1/playback/adjustments "{\"action\":\"delete\",\"id\":\"$PRESET_ID\"}" > "$OUTPUT_ROOT/deleted.json"
assert_adjustments "$OUTPUT_ROOT/deleted.json" 25 3.863137138648348
api POST /v1/playback/adjustments '{"action":"select","id":"none"}' > "$OUTPUT_ROOT/reset.json"
assert_adjustments "$OUTPUT_ROOT/reset.json" 0 0
api GET /v1/diagnostics/report > "$OUTPUT_ROOT/report.json"
shutdown_app final

if rg -q 'Unhandled Exception|Playback adjustment rollback failed|ERROR:flutter/runtime' "$APP_LOG"; then
  echo "Runtime errors found in $APP_LOG" >&2
  exit 1
fi
cleanup
trap - EXIT INT TERM
echo "Playback adjustment diagnostics completed: $OUTPUT_ROOT"
