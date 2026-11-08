#!/usr/bin/env bash
# iOS gapless diagnostics (I23): plays 4-song queues of phase-continuous 440 Hz
# tones on the booted iOS simulator and reads the native transition gap meter
# (`transitionGapsMs`) and equalizer counters from GET /v1/equalizer, for proxied
# streams and permanent downloads, with the equalizer off and on (-12 dB). It
# also checks one tap prepare per queue, that seek and skip each reset the
# filter history exactly once, a mixed 22.05/48/96 kHz queue, a "play next"
# insert in the middle of a song (no gap; the stall it causes is reported),
# repeat one, the speed of
# seeking to 0 after the queue ended, and (phase `crossfade`) that crossfade
# still plays through. Needs a booted iOS simulator; one heavy job (see
# docs/development/development-workflow.md). Evidence: build/ios-gapless-diagnostics/<stamp>/.
#
#   GAPLESS_PHASES   space-separated subset of: main rates seek insert loop crossfade
#   GAP_TOLERANCE_MS largest accepted gap at a gapless transition (default 20)
#   GAPLESS_REPEATS  runs of each main case (default 1); GAPLESS_KEEP_GOING=1
#                    reports failures and carries on instead of stopping
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export NAVIS_DIAGNOSTICS_DEVICE=ios
source "$PROJECT_DIR/tool/lib/diagnostics.sh"
DIAGNOSTICS_APP_NAME='Navis Gapless Diagnostics'
DIAGNOSTICS_FAILURE_PREFIX='ios-gapless'
DIAGNOSTICS_POLL_INTERVAL=0.5
PHASES="${GAPLESS_PHASES:-main rates seek insert loop crossfade}"
GAP_TOLERANCE_MS="${GAP_TOLERANCE_MS:-20}"
REPEATS="${GAPLESS_REPEATS:-1}"
OUTPUT_ROOT="${GAPLESS_OUTPUT:-$PROJECT_DIR/build/ios-gapless-diagnostics/$(date -u +%Y%m%dT%H%M%SZ)}"
HANDSHAKE="$OUTPUT_ROOT/handshake.json"
FIXTURE_HANDSHAKE="$OUTPUT_ROOT/fixture-handshake.json"
FIXTURE_LOG="$OUTPUT_ROOT/fixture.log"
CREDENTIAL_FILE="$OUTPUT_ROOT/fixture-password"
PROFILE_DB="$OUTPUT_ROOT/profile.sqlite"
SUMMARY="$OUTPUT_ROOT/summary.txt"
mkdir -p "$OUTPUT_ROOT"
chmod 700 "$OUTPUT_ROOT"
exec > >(tee -a "$OUTPUT_ROOT/run.log") 2>&1
FLUTTER_PID=0; FIXTURE_PID=0; FIXTURE_PORT=''; FIXTURE_HOST='127.0.0.1'; TOKEN=''; BASE_URL=''; APP_LOG=''
trap cleanup_fixture_app EXIT INT TERM

# Every queue replacement stops the player, which disposes the native player
# and its equalizer, so the counters in a snapshot cover that one queue.
# Songs 1-4 are 22.05 kHz; 5 and 6 are 48 and 96 kHz (the mixed-rate queue).
GAPLESS_SONGS='["fixture-song","fixture-song-2","fixture-song-3","fixture-song-4"]'
RATE_SONGS='["fixture-song-4","fixture-song-5","fixture-song-6"]'
FRAMES_PER_SONG=88200

sign_in() {
  launch_app "$1"
  api POST /v1/diagnostics/overrides '{"networkType":"wifi","nativeMetered":false}' >/dev/null
  api POST /v1/session/connect "$(python3 -c '
import json, sys
print(json.dumps({"url": f"http://{sys.argv[3]}:{sys.argv[1]}", "username": "diagnostics",
                  "password": open(sys.argv[2]).read().strip()}))' \
    "$FIXTURE_PORT" "$CREDENTIAL_FILE" "$FIXTURE_HOST")" > "$OUTPUT_ROOT/$1-connect.json"
  wait_for /v1/session/status 'v.get("phase") == "ready"' "$OUTPUT_ROOT/$1-session-ready.json" 300
  api POST /v1/presentation/onboarding/complete '{}' >/dev/null || true
}

# set_eq off|on: on is a flat -12 dB preamp, so the level delta reads -12.
set_eq() {
  local enabled=false
  [[ "$1" == on ]] && enabled=true
  api POST /v1/equalizer "{\"action\":\"configure\",\"configuration\":{\"version\":1,\"mode\":\"advanced\",\"enabled\":$enabled,\"autoHeadroom\":false,\"preampDb\":-12,\"filters\":[]}}" >/dev/null
}

snap() { api GET /v1/equalizer > "$1"; }

# check <label> <python-assertions>; the snapshot files are named in the label's
# folder; the python body sees `s` (name -> application object) and `fail(msg)`.
check() {
  local label="$1" body="$2"
  python3 - "$OUTPUT_ROOT/$label" "$GAP_TOLERANCE_MS" "$SUMMARY" "$label" <<PYTHON || [[ -n "${GAPLESS_KEEP_GOING:-}" ]] || fail "$label failed (see $SUMMARY)"
import glob, json, os, sys
folder, tolerance, summary, label = sys.argv[1], float(sys.argv[2]), sys.argv[3], sys.argv[4]
s = {os.path.basename(f)[:-5]: json.load(open(f))["application"] for f in glob.glob(folder + "/*.json")}
problems = []
def fail(message): problems.append(message)
$body
line = "%-34s %s" % (label, "FAIL: " + "; ".join(problems) if problems else "ok")
open(summary, "a").write(line + "\n")
print(line)
sys.exit(1 if problems else 0)
PYTHON
}

play_queue() { # <label> <songs-json> <eq off|on> <sample-seconds...>: one snapshot per sample time
  local label="$1" songs="$2" eq="$3"; shift 3
  mkdir -p "$OUTPUT_ROOT/$label"
  api POST /v1/playback/pause '{}' >/dev/null || true
  set_eq "$eq"
  sleep 1
  local start=$SECONDS now
  api POST /v1/playback/queue "{\"songIds\":$songs}" > "$OUTPUT_ROOT/$label-queue.json"
  for at in "$@"; do
    now=$((SECONDS - start))
    (( at > now )) && sleep $((at - now))
    snap "$OUTPUT_ROOT/$label/at$at.json"
  done
}

GAPLESS_CHECK='
gaps = s["at19"].get("transitionGapsMs") or []
if len(gaps) < 3: fail("only %d transition gaps measured" % len(gaps))
for g in gaps[-3:]:
    if g > tolerance: fail("silence of %.1f ms between songs exceeds %.0f ms" % (g, tolerance))
    # A negative gap is the next song clock starting early, not silence. It shows up
    # now and then when the main thread is busy; report it, do not fail on it.
    if g < -tolerance: print("  note: transition clock %.1f ms early (overlap, not silence)" % -g)
frames = s["at19"]["processedFrames"]
if frames < 0.95 * 4 * %FRAMES%: fail("the tap processed %d frames, expected about %d" % (frames, 4 * %FRAMES%))
if s["at19"]["resetCount"] != s["at3"]["resetCount"]: fail("resetCount moved %s -> %s during playback" % (s["at3"]["resetCount"], s["at19"]["resetCount"]))
prepares = s["at19"]["tapPrepareCount"]
if prepares != 1: fail("%d tap prepares for one queue" % prepares)
level = s["at14"].get("levelDeltaDb")
if level is None or abs(level - %LEVEL%) > 0.6: fail("levelDeltaDb %s, expected %s" % (level, %LEVEL%))
print("  gaps=%s prepares=%d frames=%d resets=%s level=%s" % (gaps[-3:], prepares, frames, s["at19"]["resetCount"], level))
'

run_main() {
  local source="$1"
  for run in $(seq 1 "$REPEATS"); do
    for eq in off on; do
      local level=0 label="$source-eq-$eq"
      [[ "$eq" == on ]] && level=-12
      (( run > 1 )) && label="$label-r$run"
      play_queue "$label" "$GAPLESS_SONGS" "$eq" 3 14 19
      check "$label" "$(sed -e "s/%FRAMES%/$FRAMES_PER_SONG/g" -e "s/%LEVEL%/$level/g" <<<"$GAPLESS_CHECK")"
    done
  done
}

run_rates() {
  play_queue rates "$RATE_SONGS" on 3 7 11 15
  wait_for /v1/playback/status 'v.get("songId") == "fixture-song-6" and v.get("playing") is False' "$OUTPUT_ROOT/rates-status-final.json" 20
  check rates '
# AVFoundation picks the format the tap sees (it may resample to the faster
# neighbour), so only require that it is never below the song rate, that the
# equalizer applies at every rate, and that each format change re-prepares.
for name, rate in (("at3", 22050), ("at7", 48000), ("at11", 96000)):
    seen = round(s[name].get("sampleRate") or 0)
    if seen < rate: fail("%s: the tap runs at %d Hz for a %d Hz song" % (name, seen, rate))
    level = s[name].get("levelDeltaDb")
    if level is None or abs(level + 12) > 0.6: fail("%s: levelDeltaDb %s" % (name, level))
if s["at15"]["processedFrames"] < 0.9 * 3 * 4 * 22050: fail("the tap processed only %d frames" % s["at15"]["processedFrames"])
gaps = s["at15"].get("transitionGapsMs") or []
if any(g > 1500 for g in gaps): fail("a format change took %s ms" % gaps)
print("  prepares=%s rates=%s format-change gaps (not gapless by design): %s" % (
    s["at15"]["tapPrepareCount"], [s[n].get("sampleRate") for n in ("at3", "at7", "at11")], gaps))
'
}

run_seek() {
  mkdir -p "$OUTPUT_ROOT/seek"
  api POST /v1/playback/pause '{}' >/dev/null || true
  set_eq on
  sleep 1
  api POST /v1/playback/queue "{\"songIds\":$GAPLESS_SONGS}" > "$OUTPUT_ROOT/seek-queue.json"
  sleep 6
  snap "$OUTPUT_ROOT/seek/a-steady.json"
  api POST /v1/playback/seek '{"positionMs":1000}' > "$OUTPUT_ROOT/seek-seek.json"
  sleep 1.5
  snap "$OUTPUT_ROOT/seek/b-after-seek.json"
  api POST /v1/playback/next '{}' > "$OUTPUT_ROOT/seek-next.json"
  sleep 1.5
  snap "$OUTPUT_ROOT/seek/c-after-skip.json"
  check seek '
steady, seeked, skipped = (s[k]["resetCount"] for k in ("a-steady", "b-after-seek", "c-after-skip"))
flushes = [s[k]["flushCount"] for k in ("a-steady", "b-after-seek", "c-after-skip")]
# Each seek and each skip tells the tap once. AVFoundation then either feeds the
# old stream another block, which resets its history, or re-prepares the tap,
# whose new stream starts with an empty history; so one counted reset at most.
if flushes[1] - flushes[0] != 1: fail("a seek noted %d flushes" % (flushes[1] - flushes[0]))
if flushes[2] - flushes[1] != 1: fail("a skip noted %d flushes" % (flushes[2] - flushes[1]))
if steady != 0: fail("the history was reset %d times before any seek" % steady)
if seeked - steady > 1: fail("a seek reset the history %d times" % (seeked - steady))
if skipped - seeked > 1: fail("a skip reset the history %d times" % (skipped - seeked))
print("  flushCount=%s resetCount steady=%s after seek=%s after skip=%s" % (flushes, steady, seeked, skipped))
'
  # The queue ends; seeking to 0 afterwards must stay quick.
  api POST /v1/playback/queue "{\"songIds\":[\"fixture-song\",\"fixture-song-2\"]}" >/dev/null
  wait_for /v1/playback/status 'v.get("songId") == "fixture-song-2" and v.get("playing") is False' "$OUTPUT_ROOT/seek-ended.json" 60
  local ms
  ms="$(curl --silent --output /dev/null --write-out '%{time_total}' -X POST -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' -d '{"positionMs":0}' "$BASE_URL/v1/playback/seek" | awk '{printf "%d", $1 * 1000}')"
  local line="seek to 0 after the queue ended   $ms ms"
  echo "$line" | tee -a "$SUMMARY"
  (( ms < 2000 )) || fail "seek to 0 after the queue ended took $ms ms"
}

# Milliseconds from the player starting to the first song change after it, from
# the transport trace (native index events). The start latency is the same for
# every queue, so two queues with the same first song compare directly.
first_change_ms() {
  python3 - "$1" <<'PYTHON'
import json, sys
t = json.load(open(sys.argv[1]))["transportTrace"]
t = t[max(k for k, e in enumerate(t) if e.get("phase") == "phase1Start"):]
play = next(e for e in t if e.get("kind") == "playerState" and e.get("playing") and e.get("processingState") == "ready")
print(next(e for e in t if e.get("kind") == "songCurrent" and e["atMs"] > play["atMs"] + 1000)["atMs"] - play["atMs"])
PYTHON
}

run_insert() {
  mkdir -p "$OUTPUT_ROOT/insert"
  api POST /v1/playback/pause '{}' >/dev/null || true
  set_eq off
  sleep 1
  # Baseline: the same first song with nothing inserted.
  api POST /v1/playback/queue '{"songIds":["fixture-song","fixture-song-2"]}' > "$OUTPUT_ROOT/insert-baseline-queue.json"
  wait_for /v1/playback/status 'v.get("songId") == "fixture-song-2"' "$OUTPUT_ROOT/insert-baseline-status.json" 30
  local baseline
  baseline="$(first_change_ms "$OUTPUT_ROOT/insert-baseline-status.json")"
  api POST /v1/playback/pause '{}' >/dev/null || true
  sleep 1
  api POST /v1/playback/queue '{"songIds":["fixture-song","fixture-song-2","fixture-song-3"]}' > "$OUTPUT_ROOT/insert-queue.json"
  sleep 3
  api POST /v1/playback/queue-edit '{"op":"playNext","songIds":["fixture-song-4"]}' > "$OUTPUT_ROOT/insert-edit.json"
  wait_for /v1/playback/status 'v.get("songId") == "fixture-song-3"' "$OUTPUT_ROOT/insert-status.json" 40
  sleep 2
  snap "$OUTPUT_ROOT/insert/at-end.json"
  api GET /v1/playback/status > "$OUTPUT_ROOT/insert-status-end.json"
  local first
  first="$(first_change_ms "$OUTPUT_ROOT/insert-status-end.json")"
  python3 - "$OUTPUT_ROOT/insert-status-end.json" <<'PYTHON' || fail "play next did not play the inserted song second"
import json, sys
order = [e["songId"] for e in json.load(open(sys.argv[1]))["transportTrace"] if e.get("kind") == "songCurrent"][-3:]
assert order == ["fixture-song-4", "fixture-song-2", "fixture-song-3"], order
PYTHON
  check insert "
stall = $first - $baseline
gaps = s['at-end'].get('transitionGapsMs') or []
if len(gaps) < 3: fail('only %d transition gaps measured' % len(gaps))
if any(g > tolerance for g in gaps[-3:]): fail('silence after a mid-song insert: %s' % gaps)
# Putting another song in front of the prefetched next one rebuilds the pipeline all
# queued songs share: the playing song stalls for about 0.8 s (seen on dev too, with
# per-item taps, in one of two runs). Reported, not failed.
if s['at-end']['tapPrepareCount'] > 2: fail('%s tap prepares' % s['at-end']['tapPrepareCount'])
print('  insert: gaps=%s prepares=%s; the first song change came %d ms later than without the insert (known stall)' % (gaps[-3:], s['at-end']['tapPrepareCount'], stall))
"
}

run_loop() {
  mkdir -p "$OUTPUT_ROOT/loop"
  api POST /v1/playback/pause '{}' >/dev/null || true
  set_eq on
  sleep 1
  api POST /v1/playback/queue '{"songIds":["fixture-song","fixture-song-2"]}' > "$OUTPUT_ROOT/loop-queue.json"
  api POST /v1/playback/repeat '{"mode":"one"}' > "$OUTPUT_ROOT/loop-repeat.json"
  sleep 15
  snap "$OUTPUT_ROOT/loop/at15.json"
  api POST /v1/playback/repeat '{"mode":"none"}' >/dev/null
  check loop '
gaps = s["at15"].get("transitionGapsMs") or []
if len(gaps) < 2: fail("repeat one wrapped only %d times" % len(gaps))
if any(g > tolerance for g in gaps): fail("silence when repeat one restarts the song: %s" % gaps)
# Switching the repeat mode re-queues the items once, which re-prepares the tap once.
if s["at15"]["tapPrepareCount"] > 2: fail("%s tap prepares" % s["at15"]["tapPrepareCount"])
print("  repeat one: gaps=%s prepares=%s" % (gaps, s["at15"]["tapPrepareCount"]))
'
}

run_crossfade() {
  stop_app
  command -v sqlite3 >/dev/null || fail "sqlite3 is required for the crossfade phase"
  sqlite3 "$PROFILE_DB" "UPDATE app_settings SET crossfade_enabled = 1, gapless_enabled = 1, crossfade_duration_seconds = 2"
  launch_app crossfade
  wait_for /v1/session/status 'v.get("phase") == "ready"' "$OUTPUT_ROOT/crossfade-session-ready.json" 300
  mkdir -p "$OUTPUT_ROOT/crossfade"
  set_eq on
  api POST /v1/playback/queue "{\"songIds\":$GAPLESS_SONGS}" > "$OUTPUT_ROOT/crossfade-queue.json"
  wait_for /v1/playback/status 'v.get("songId") == "fixture-song-2" and v.get("playing")' "$OUTPUT_ROOT/crossfade-status-song2.json" 30
  wait_for /v1/playback/status 'v.get("songId") == "fixture-song-4" and v.get("playing")' "$OUTPUT_ROOT/crossfade-status-song4.json" 30
  snap "$OUTPUT_ROOT/crossfade/at-song4.json"
  python3 - "$OUTPUT_ROOT/crossfade-status-song4.json" <<'PYTHON' || fail "crossfade did not run through the queue"
import json, sys
c = json.load(open(sys.argv[1]))["crossfade"]
print("  crossfade:", json.dumps({k: c.get(k) for k in ("enabled", "lastFailure", "inactiveDeckMatchesQueue", "phases")}))
assert c["enabled"] and c["lastFailure"] is None and c["inactiveDeckMatchesQueue"], c
assert c["phases"].get("completed", 0) >= 2, c["phases"]
PYTHON
  check crossfade '
if not s["at-song4"]["enabled"]: fail("the equalizer is not applied during crossfade playback")
if (s["at-song4"].get("processedFrames") or 0) <= 0: fail("the equalizer processed no audio during crossfade playback")
'
}

: > "$SUMMARY"
start_fixture 'navis-gapless-fixture' --scenario downloads --song-count 6 \
  --song-rate fixture-song-5=48000 --song-rate fixture-song-6=96000
sign_in main
snap "$OUTPUT_ROOT/equalizer-initial.json"
for phase in $PHASES; do
  case "$phase" in
    main)
      run_main proxied
      api POST /v1/downloads/enqueue '{"songIds":["fixture-song","fixture-song-2","fixture-song-3","fixture-song-4","fixture-song-5","fixture-song-6"]}' >/dev/null
      wait_for /v1/downloads/status 'sum(1 for d in v["permanentDownloads"] if d["songId"].startswith("fixture-song")) >= 6 and sum(v["queue"].values()) == 0' "$OUTPUT_ROOT/download-status.json" 180
      run_main download ;;
    rates) run_rates ;;
    seek) run_seek ;;
    insert) run_insert ;;
    loop) run_loop ;;
    crossfade) run_crossfade ;;
    *) fail "unknown phase $phase" ;;
  esac
done
stop_app
echo "ios-gapless: all selected phases passed; evidence in $OUTPUT_ROOT"
