#!/usr/bin/env bash
# ReplayGain boost runtime checks on Linux: a profile build against a clone
# profile, audio captured from a disposable null sink with parec.
#
#   tool/replaygain_boost_diagnostics.sh [--scenarios d1,d2,d4,d5] [--output DIR]
#
# d1  Q (quiet, boosted) and H (hot, cut) join gaplessly, both ways, plus a
#     control where Q has no peak and so no boost
# (d1 also records d3-samples.log: the hook's gain write against the heard song)
# d2  skip, queue jump, seek, removing the playing song, repeat-one
# d4  the same joins with cross-fade on: no over-boost, no level step
# d5  a pre-amp change in the last second of a song must not raise its tail
#
# Synthetic songs only: Q is a -30 dBFS sine tagged +10 dB with its peak, H a
# -1 dBFS sine tagged -3 dB. With no display, a private headless kwin_wayland
# runs the app. Prints PASS/FAIL per assertion; exits 1 on any FAIL.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_DIR/tool/lib/diagnostics.sh"
SCENARIOS="d1,d2,d4,d5"
OUTPUT_ROOT=""
while (($#)); do
  case "$1" in
    --scenarios) SCENARIOS="$2"; shift 2 ;;
    --output) OUTPUT_ROOT="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 64 ;;
  esac
done
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUTPUT_ROOT="${OUTPUT_ROOT:-$PROJECT_DIR/build/replaygain-boost-diagnostics/$STAMP}"
SOURCE_DB="$(python3 "$PROJECT_DIR/tool/diagnostics_profile.py" primary-db)"
HANDSHAKE="$OUTPUT_ROOT/handshake.json"
APP_LOG="$OUTPUT_ROOT/navis.log"
DIAGNOSTICS_FAILURE_PREFIX="replaygain boost diagnostics"
DIAGNOSTICS_POLL_INTERVAL=1
mkdir -p "$OUTPUT_ROOT/cache"; chmod 700 "$OUTPUT_ROOT"
: > "$APP_LOG"
FLUTTER_PID=0; AUDIO_MODULE=""; KWIN_PID=0
AUDIO_SINK="navis_boost_$$"

cleanup() {
  cleanup_audio_app
  if (( KWIN_PID > 0 )); then kill "$KWIN_PID" >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT INT TERM

if [[ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
  kwin_wayland --virtual --no-lockscreen --socket "navis-boost-$$" --width 1280 --height 900 \
    >"$OUTPUT_ROOT/kwin.log" 2>&1 &
  KWIN_PID=$!
  export WAYLAND_DISPLAY="navis-boost-$$" GDK_BACKEND=wayland
  sleep 4
fi
# A virtual compositor cannot give Impeller's GLES backend a framebuffer.
export NAVIS_DIAGNOSTICS_RUN_ARGS="${NAVIS_DIAGNOSTICS_RUN_ARGS:---no-enable-impeller}"
AUDIO_MODULE="$(pactl load-module module-null-sink "sink_name=$AUDIO_SINK" sink_properties=device.description=NavisBoostDiagnostics)"

# Clone the profile once per cross-fade setting: songs, files, tags.
make_clone() { # make_clone <db> <crossfade 0|1>
  python3 - "$SOURCE_DB" "$1" "$OUTPUT_ROOT/cache" "$PROJECT_DIR/tool" "$2" <<'PY'
import math, os, shutil, sqlite3, struct, sys, time, wave
sys.path.insert(0, sys.argv[4])
from diagnostics_profile import disable_external_integrations
source = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
target = sqlite3.connect(sys.argv[2]); source.backup(target); source.close()
cache, crossfade = sys.argv[3], int(sys.argv[5])
for song_id, _ in target.execute("SELECT song_id, file_path FROM cached_tracks").fetchall():
    target.execute("UPDATE cached_tracks SET file_path=? WHERE song_id=?",
                   (os.path.join(cache, 'unused-' + song_id.replace('/', '_')), song_id))
RATE = 44100
def tone(path, peak, seconds=30):
    with wave.open(path, 'wb') as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE)
        chunk = b''.join(struct.pack('<h', int(32767 * peak * math.sin(2 * math.pi * 440 * i / RATE))) for i in range(RATE))
        for _ in range(seconds): w.writeframes(chunk)
# id: (sine peak, track gain dB, tagged peak or None). Q boosts 10 dB, H is cut 3 dB,
# qn is Q without a peak (never boosted), qa/qb are the d5 pair (+2 dB / +6 dB).
songs = {
    'rgboost-q1': (0.0316, 10.0, 0.0316), 'rgboost-h1': (0.891, -3.0, 0.891),
    'rgboost-q2': (0.0316, 10.0, 0.0316), 'rgboost-h2': (0.891, -3.0, 0.891),
    'rgboost-qn': (0.0316, 10.0, None),
    'rgboost-qa': (0.0316, 2.0, 0.0316), 'rgboost-qb': (0.0316, 6.0, 0.0316),
}
for sid, (peak, gain, tag_peak) in songs.items():
    path = os.path.join(cache, sid + '.wav'); tone(path, peak)
    target.execute("INSERT OR REPLACE INTO songs (id, title, duration, content_type, suffix, replay_gain_track_gain, replay_gain_track_peak) VALUES (?,?,30,'audio/wav','wav',?,?)", (sid, sid, gain, tag_peak))
    target.execute("INSERT OR REPLACE INTO cached_tracks (song_id,file_path,file_size,format,last_accessed_at,cache_type,download_status) VALUES (?,?,?,?,?,'permanent','complete')", (sid, path, os.path.getsize(path), 'wav', int(time.time())))
target.execute("UPDATE app_settings SET crossfade_enabled=?, crossfade_duration_seconds=3, gapless_enabled=1, scrobble_enabled=0, listen_brainz_scrobbling_enabled=0, replay_gain_mode='track', replay_gain_preamp=0", (crossfade,))
disable_external_integrations(target)
target.execute('DELETE FROM play_queue')
target.commit(); target.close()
PY
  chmod 600 "$1"
}

route() { # move this app's stream to the capture sink
  local deadline=$((SECONDS + 20)) idx=""
  while ((SECONDS < deadline)); do
    idx="$(pactl -f json list sink-inputs | python3 -c 'import json,sys; print(" ".join(str(x["index"]) for x in json.load(sys.stdin) if x.get("properties",{}).get("application.process.id") == sys.argv[1]))' "$APP_PID")"
    [[ -n "$idx" ]] && break; sleep 0.5
  done
  [[ -n "$idx" ]] || fail "no audio stream"
  for i in $idx; do pactl move-sink-input "$i" "$AUDIO_SINK" || true; done
}
rec_start() { parec --device="$AUDIO_SINK.monitor" --raw --rate=44100 --format=float32le --channels=1 > "$OUTPUT_ROOT/$1.pcm" & REC_PID=$!; }
rec_stop() { sleep "$1"; kill "$REC_PID" 2>/dev/null || true; wait "$REC_PID" 2>/dev/null || true; }
play_queue() { api POST /v1/playback/queue "{\"songIds\":$1}" > "$OUTPUT_ROOT/queue.json"; }
post() { api POST "$1" "${2:-}" > /dev/null; }
# One JSON line per status read: heard song, position and the adapter's gain.
sample_status() { # sample_status <file>
  while :; do
    api GET /v1/playback/status 2>/dev/null | python3 -c '
import json, sys, time
v = json.load(sys.stdin)
t = ((v.get("native") or {}).get("mediaKitTransport") or [{}])[0]
print(json.dumps({"t": round(time.time(), 3), "songId": v.get("songId"), "positionMs": v.get("playerPositionMs"),
                  "intendedDb": t.get("replayGainBoostIntendedDb"), "mpvDb": t.get("replayGainBoostDb"),
                  "heldDb": t.get("replayGainBoostHeldDb")}))' >> "$1" || true
    sleep 0.05
  done
}
# Pause at 26 s of a 30 s song and capture its natural end and the next song.
join() { # join <label> <queue> [capture seconds] [seek ms]
  play_queue "$2"; route; sleep 2; post /v1/playback/pause
  post /v1/playback/seek "{\"positionMs\":${4:-26000}}"
  rec_start "$1"; post /v1/playback/play; rec_stop "${3:-8}"
}

launch() { # launch <label> <crossfade>
  local clone="$OUTPUT_ROOT/navis-$1.sqlite"
  make_clone "$clone" "$2"
  CLONE_DB="$clone"; HANDSHAKE="$OUTPUT_ROOT/handshake-$1.json"
  cd "$PROJECT_DIR"
  launch_audio_app 'Navis Boost Diagnostics'
  api GET /v1/health > "$OUTPUT_ROOT/health-$1.json"
  api POST /v1/playback/volume '{"value":1}' > /dev/null || true
}

if [[ ",$SCENARIOS," == *,d1,* || ",$SCENARIOS," == *,d2,* || ",$SCENARIOS," == *,d5,* ]]; then
  launch gapless 0
  if [[ ",$SCENARIOS," == *,d1,* ]]; then
    sample_status "$OUTPUT_ROOT/d3-samples.log" & SAMPLER=$!
    join qh '["rgboost-q1","rgboost-h1"]'
    kill "$SAMPLER" 2>/dev/null || true; wait "$SAMPLER" 2>/dev/null || true
    join hq '["rgboost-h1","rgboost-q1"]'
    join hqn '["rgboost-h1","rgboost-qn"]'
  fi
  if [[ ",$SCENARIOS," == *,d2,* ]]; then
    play_queue '["rgboost-q1","rgboost-h1","rgboost-q2","rgboost-h2"]'; route; sleep 2
    rec_start d2-start; rec_stop 2
    post /v1/playback/next; rec_start d2-next-h; rec_stop 2.5
    post /v1/playback/next; rec_start d2-next-q; rec_stop 2.5
    post /v1/playback/seek '{"positionMs":10000}'; rec_start d2-seek-q; rec_stop 2.5
    post /v1/playback/queue-index '{"index":1}'; rec_start d2-jump-h; rec_stop 2.5
    post /v1/playback/queue-index '{"index":2}'; sleep 1
    post /v1/playback/queue-edit '{"op":"remove","index":2}'; rec_start d2-remove-current; rec_stop 3
    post /v1/playback/queue-edit '{"op":"add","songIds":["rgboost-q1"]}'
    post /v1/playback/queue-index '{"index":3}'; sleep 1
    post /v1/playback/repeat '{"mode":"one"}'
    post /v1/playback/seek '{"positionMs":27000}'; rec_start d2-repeat-one; rec_stop 7
    post /v1/playback/repeat '{"mode":"none"}'
  fi
  if [[ ",$SCENARIOS," == *,d5,* ]]; then
    # The pre-amp rises 3 dB while the last second of qa (+2 dB) plays and qb
    # (+6 dB) is about to start. qa's tail must never exceed qa's own level.
    for delay in 0.55 0.70 0.80 0.88 0.95; do
      post /v1/playback/replay-gain '{"mode":"track","preamp":0}'
      play_queue '["rgboost-qa","rgboost-qb"]'; route; sleep 2; post /v1/playback/pause
      post /v1/playback/seek '{"positionMs":29000}'
      rec_start "d5-$delay"; post /v1/playback/play; sleep "$delay"
      post /v1/playback/replay-gain '{"mode":"track","preamp":3}'; rec_stop 4
    done
    post /v1/playback/replay-gain '{"mode":"track","preamp":0}'
  fi
  stop_app
fi
if [[ ",$SCENARIOS," == *,d4,* ]]; then
  launch crossfade 1
  join cf-qh '["rgboost-q1","rgboost-h1"]' 12 24000
  join cf-hq '["rgboost-h1","rgboost-q1"]' 12 24000
  stop_app
fi
python3 "$PROJECT_DIR/tool/replaygain_boost_analyze.py" "$OUTPUT_ROOT" "$SCENARIOS" | tee "$OUTPUT_ROOT/analysis.txt"
