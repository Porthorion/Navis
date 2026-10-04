#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DB="${NAVIS_DIAGNOSTICS_PRIMARY_DB:-$HOME/Documents/navis.sqlite.sqlite}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUTPUT_ROOT="$PROJECT_DIR/build/equalizer-diagnostics/$STAMP"
CLONE_DB="$OUTPUT_ROOT/navis-equalizer.sqlite"
HANDSHAKE="$OUTPUT_ROOT/handshake.json"
APP_LOG="$OUTPUT_ROOT/navis.log"

if [[ ! -f "$SOURCE_DB" ]]; then
  echo "Primary database not found: $SOURCE_DB" >&2
  exit 66
fi

mkdir -p "$OUTPUT_ROOT/cache"
chmod 700 "$OUTPUT_ROOT"
python3 - "$SOURCE_DB" "$CLONE_DB" "$OUTPUT_ROOT/cache" <<'PY'
import os, shutil, sqlite3, sys, wave, math, struct, time, hashlib
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
    for _ in range(120): tone.writeframes(chunk)
for index, identity in enumerate(('diagnostics-adjustment-tone-1', 'diagnostics-adjustment-tone-2'), start=1):
    # Each song owns its file: the app moves a permanent download into its own
    # layout, which would leave a shared path missing for the other song.
    identity_path = os.path.join(cache_root, f'tone-{index}.wav')
    shutil.copyfile(tone_path, identity_path)
    target.execute("INSERT OR REPLACE INTO songs (id, title, duration, content_type, suffix) VALUES (?, 'Equalizer test tone', 120, 'audio/wav', 'wav')", (identity,))
    target.execute("INSERT OR REPLACE INTO cached_tracks (song_id,file_path,file_size,format,last_accessed_at,cache_type,download_status) VALUES (?,?,?,?,?,'permanent','complete')", (identity,identity_path,os.path.getsize(identity_path),'wav',int(time.time())))
target.execute("UPDATE app_settings SET crossfade_enabled = 1, gapless_enabled = 1, crossfade_duration_seconds = 3, scrobble_enabled = 0, listen_brainz_scrobbling_enabled = 0")
columns = {row[1] for row in target.execute('PRAGMA table_info(app_settings)')}
# No external-service traffic in the measurement; the column is absent from a
# profile that predates the integration policy.
if 'external_integrations_enabled' in columns:
    target.execute('UPDATE app_settings SET external_integrations_enabled = 0')
if 'playback_presets' in columns:
    target.execute("UPDATE app_settings SET playback_presets = '[]', selected_playback_preset_id = NULL, playback_speed = 1, playback_pitch_semitones = 0")
if 'lock_pitch_to_speed' in columns:
    target.execute('UPDATE app_settings SET lock_pitch_to_speed = 0')
if target.execute("SELECT 1 FROM sqlite_master WHERE name = 'eq_state'").fetchone():
    target.execute('DELETE FROM eq_state')
    target.execute('DELETE FROM eq_presets')
target.execute('DELETE FROM play_queue')
target.commit()
target.close()
PY
chmod 600 "$CLONE_DB"

cd "$PROJECT_DIR"
: > "$APP_LOG"
FLUTTER_PID=0
AUDIO_MODULE=""
AUDIO_SINK="navis_equalizer_$$"
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
    --dart-define=NAVIS_APP_NAME='Navis Equalizer Diagnostics' \
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
raw = raw[len(raw)*2//3:]
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
api GET /v1/health > "$OUTPUT_ROOT/health.json"
api GET /v1/equalizer > "$OUTPUT_ROOT/initial.json"
api POST /v1/playback/queue '{"songIds":["diagnostics-adjustment-tone-1","diagnostics-adjustment-tone-2"]}' > "$OUTPUT_ROOT/play.json"
capture_audio baseline 0
configure() {
  local hz="$1" gain="$2" enabled="$3" headroom="$4"
  api POST /v1/equalizer "{\"action\":\"configure\",\"configuration\":{\"version\":1,\"mode\":\"advanced\",\"enabled\":$enabled,\"autoHeadroom\":$headroom,\"preampDb\":0,\"filters\":[{\"type\":\"peaking\",\"frequencyHz\":$hz,\"gainDb\":$gain,\"q\":4,\"enabled\":true}]}}"
}
configure 440 -12 true false > "$OUTPUT_ROOT/cut.json"
capture_audio cut 0
configure 440 12 true true > "$OUTPUT_ROOT/headroom.json"
capture_audio headroom 0
api POST /v1/equalizer '{"action":"enable","enabled":false}' > "$OUTPUT_ROOT/bypass.json"
capture_audio bypass 0
api POST /v1/playback/adjustments '{"speed":1.25,"pitchSemitones":12,"lockPitchToSpeed":false}' > "$OUTPUT_ROOT/pitch.json"
capture_audio pitch-baseline 12
configure 880 -12 true false > "$OUTPUT_ROOT/pitch-cut.json"
capture_audio pitch-cut 12
python3 - "$OUTPUT_ROOT" <<'PYCODE'
import json, math, pathlib, sys
root = pathlib.Path(sys.argv[1])
def rms(name): return json.load(open(root / (name + '-audio.json')))['rms']
def delta(a,b): return 20*math.log10(rms(a)/rms(b))
measurements = {'cutDb': delta('cut','baseline'), 'headroomDb': delta('headroom','baseline'),
    'bypassDb': delta('bypass','baseline'), 'pitchCutDb': delta('pitch-cut','pitch-baseline')}
assert abs(measurements['cutDb'] + 12) < .8, measurements
assert abs(measurements['headroomDb'] + .5) < .8, measurements
assert abs(measurements['bypassDb']) < .5, measurements
assert abs(measurements['pitchCutDb'] + 12) < .8, measurements
json.dump(measurements, open(root / 'signal-results.json','w'), indent=2)
PYCODE
api POST /v1/playback/seek '{"positionMs":117000}' > "$OUTPUT_ROOT/transition-seek.json"
for _ in $(seq 1 15); do
  api GET /v1/playback/status > "$OUTPUT_ROOT/transition-status.json"
  if python3 - "$OUTPUT_ROOT/transition-status.json" <<'PYCODE'
import json,sys
value=json.load(open(sys.argv[1]))
sys.exit(0 if value['songId']=='diagnostics-adjustment-tone-2' and value['playing'] and value['playerPositionMs']>=5000 else 1)
PYCODE
  then break; fi
  sleep 1
done
python3 - "$OUTPUT_ROOT/transition-status.json" <<'PYCODE'
import json,sys
value=json.load(open(sys.argv[1]))
assert value['songId']=='diagnostics-adjustment-tone-2' and value['playing'] and value['playerPositionMs']>=5000, value
PYCODE
capture_audio transition-pitch-cut 12
api GET /v1/equalizer > "$OUTPUT_ROOT/transition-equalizer.json"
python3 - "$OUTPUT_ROOT/pitch-cut.json" "$OUTPUT_ROOT/transition-equalizer.json" "$OUTPUT_ROOT/pitch-baseline-audio.json" "$OUTPUT_ROOT/transition-pitch-cut-audio.json" <<'PYCODE'
import json,sys,math
before,after,baseline,transition=[json.load(open(path)) for path in sys.argv[1:]]
assert before['configuration']==after['configuration'], (before,after)
assert after['application']['enabled'] and not after['application']['pending'], after
assert abs(20*math.log10(transition['rms']/baseline['rms'])+12)<.8, transition
PYCODE
api POST /v1/equalizer '{"action":"save","name":"Measured headphones"}' > "$OUTPUT_ROOT/saved.json"
api POST /v1/presentation/window '{"mode":"desktop","width":1280,"height":1000}' > "$OUTPUT_ROOT/window-wide.json"
api POST /v1/presentation/navigate '{"location":"/settings/equalizer"}' > "$OUTPUT_ROOT/navigation.json"
api POST /v1/presentation/screenshot '{"label":"eq-desktop-wide"}' > "$OUTPUT_ROOT/screenshot-wide.json"
api POST /v1/presentation/window '{"mode":"desktop","width":800,"height":600}' > "$OUTPUT_ROOT/window-compact.json"
api POST /v1/presentation/screenshot '{"label":"eq-desktop-compact"}' > "$OUTPUT_ROOT/screenshot-compact.json"
# Exercise independent built-in drafts and retained modes through production state.
api POST /v1/equalizer '{"action":"select","id":"builtin:bass"}' > "$OUTPUT_ROOT/draft-bass.json"
api POST /v1/equalizer '{"action":"mode","mode":"advanced"}' > "$OUTPUT_ROOT/draft-advanced.json"
api POST /v1/equalizer '{"action":"mode","mode":"tenBand"}' > "$OUTPUT_ROOT/draft-ten-band.json"
api POST /v1/equalizer '{"action":"select","id":"builtin:vocal"}' > "$OUTPUT_ROOT/draft-vocal.json"
api POST /v1/equalizer '{"action":"select","id":"builtin:bass"}' > "$OUTPUT_ROOT/draft-restored.json"
python3 - "$OUTPUT_ROOT" <<'PYCODE'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
restored = json.load(open(root / 'draft-restored.json'))
assert restored['configuration']['mode'] == 'tenBand', restored
assert set(restored['workspaces']['builtin:bass']['curves']) == {'simple','advanced','tenBand'}, restored
assert restored['draftPersisted'] and restored['dirty'], restored
saved = json.load(open(root / 'saved.json'))
json.dump({'action':'select','id':saved['selectedPresetId']}, open(root / 'restore-measured-body.json','w'))
PYCODE
api POST /v1/equalizer "$(cat "$OUTPUT_ROOT/restore-measured-body.json")" > "$OUTPUT_ROOT/restored-measured.json"
api POST /v1/presentation/equalizer '{"action":"selectBand"}' > "$OUTPUT_ROOT/graph-visible.json"
api POST /v1/presentation/screenshot '{"label":"eq-graph"}' > "$OUTPUT_ROOT/screenshot-pinned.json"
api POST /v1/presentation/equalizer '{"action":"edit","index":0}' > "$OUTPUT_ROOT/band-editor.json"
api POST /v1/presentation/equalizer '{"action":"gain","value":"-6"}' > "$OUTPUT_ROOT/band-preview.json"
api POST /v1/presentation/screenshot '{"label":"eq-band-editor"}' > "$OUTPUT_ROOT/screenshot-band.json"
api GET /v1/equalizer > "$OUTPUT_ROOT/preview-status.json"
capture_audio draft-preview 12
api POST /v1/presentation/equalizer '{"action":"cancel"}' > "$OUTPUT_ROOT/band-cancel.json"
api GET /v1/equalizer > "$OUTPUT_ROOT/cancel-status.json"
capture_audio draft-cancel 12
python3 - "$OUTPUT_ROOT" <<'PYCODE'
import json, math, pathlib, sys
root = pathlib.Path(sys.argv[1])
preview = json.load(open(root / 'preview-status.json'))
cancel = json.load(open(root / 'cancel-status.json'))
assert preview['configuration'] == cancel['configuration'], (preview,cancel)
assert preview['persistedConfiguration'] == cancel['persistedConfiguration'], (preview,cancel)
assert preview['application']['configuration']['filters'][0]['gainDb'] == -6, preview
assert cancel['application']['configuration']['filters'][0]['gainDb'] == -12, cancel
baseline = json.load(open(root / 'pitch-baseline-audio.json'))['rms']
for name, expected in [('draft-preview',-6),('draft-cancel',-12)]:
    rms = json.load(open(root / (name+'-audio.json')))['rms']
    assert abs(20*math.log10(rms/baseline)-expected)<.8, (name,rms)
PYCODE
python3 - "$OUTPUT_ROOT" <<'PYGRAPH'
import json, math, pathlib, sys, urllib.request
root = pathlib.Path(sys.argv[1])
handshake = json.load(open(root / 'handshake.json'))
def api(route, body=None):
    request = urllib.request.Request('http://127.0.0.1:'+str(handshake['port'])+route,
      data=None if body is None else json.dumps(body).encode(),
      headers={'Authorization':'Bearer '+handshake['token'],'Content-Type':'application/json'})
    with urllib.request.urlopen(request,timeout=30) as response: return json.load(response)
before = api('/v1/equalizer')
api('/v1/presentation/equalizer', {'action':'dragBand','index':0,'dx':40,'dy':-12})
dragged = api('/v1/equalizer')
assert dragged['configuration'] != before['configuration'], dragged
assert dragged['configuration'] == dragged['persistedConfiguration'], dragged
api('/v1/equalizer', {'action':'undo'})
assert api('/v1/equalizer')['configuration'] == before['configuration']
api('/v1/presentation/equalizer', {'action':'cancelDrag','index':0,'dx':20,'dy':-6})
assert api('/v1/equalizer')['configuration'] == before['configuration']
json.dump(dragged, open(root/'graph-drag.json','w'),indent=2)
dense = json.loads(json.dumps(before['configuration']))
dense['filters'] = [{'type':'peaking','frequencyHz':20*1000**(i/31),'gainDb':-.2,'q':1,'enabled':True} for i in range(32)]
api('/v1/equalizer', {'action':'configure','configuration':dense})
queues_before = api('/v1/equalizer')['interaction']
profile = api('/v1/presentation/equalizer', {'action':'profileGraph','index':15})
queues_after = api('/v1/equalizer')['interaction']
assert profile['profile']['bands']==32 and profile['profile']['frames']>=100, profile
assert queues_after['workspaceWrites']-queues_before['workspaceWrites']<40, queues_after
assert queues_after['previewCommands']-queues_before['previewCommands']<180, queues_after
assert not queues_after['checkpointPending'], queues_after
profile['queuesBefore']=queues_before; profile['queuesAfter']=queues_after
json.dump(profile, open(root/'graph-profile.json','w'),indent=2)
api('/v1/presentation/screenshot', {'label':'eq-desktop-32-bands'})
api('/v1/equalizer', {'action':'configure','configuration':before['configuration']})
PYGRAPH
api POST /v1/playback/queue/clear '{}' > "$OUTPUT_ROOT/clear.json"
shutdown_app initial
launch_app
api GET /v1/health > "$OUTPUT_ROOT/health-restart.json"
api GET /v1/equalizer > "$OUTPUT_ROOT/restart.json"
python3 - "$OUTPUT_ROOT/saved.json" "$OUTPUT_ROOT/restart.json" <<'PYCODE'
import json,sys
before=json.load(open(sys.argv[1])); after=json.load(open(sys.argv[2]))
assert before['configuration'] == after['configuration'], (before,after)
assert before['selectedPresetId'] == after['selectedPresetId'], (before,after)
assert len(after['presets']) == 1, after
assert set(after['workspaces']['builtin:bass']['curves']) == {'simple','advanced','tenBand'}, after
PYCODE
api POST /v1/playback/queue '{"songIds":["diagnostics-adjustment-tone-1","diagnostics-adjustment-tone-2"]}' > "$OUTPUT_ROOT/restart-play.json"
capture_audio restart-pitch-cut 12
shutdown_app final
if rg -n 'Unhandled Exception|RenderFlex overflowed|provider.*during.*build' "$APP_LOG"; then
  echo "Runtime errors in $APP_LOG" >&2; exit 70
fi
printf 'Equalizer diagnostics passed: %s\n' "$OUTPUT_ROOT"
