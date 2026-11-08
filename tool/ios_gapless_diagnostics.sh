#!/usr/bin/env bash
# iOS gapless diagnostics (I23): plays 4-song queues of phase-continuous 440 Hz
# tones on the booted iOS simulator and reads the native transition gap meter
# (`transitionGapsMs`) and equalizer counters from GET /v1/equalizer, for proxied
# streams and permanent downloads, with the equalizer off and on (-12 dB). It
# also checks one tap prepare per queue, that seek and skip each reset the
# filter history once, a mixed 22.05/48/96 kHz queue (phase `rates`: every song's
# EQ runs at its own rate) and a same-rate queue of four source formats (phase
# `formats`: mono/stereo, 16-bit/float; I25), a "play next"
# insert in the middle of a song (no gap; the stall it causes is reported),
# repeat one, the speed of
# seeking to 0 after the queue ended, and (phase `crossfade`) that crossfade
# still plays through. Phase `pitch` (I21, independent pitch) plays 44.1/48/96 kHz
# sines at 0/+12/-12/+7 semitones and checks the tap's measured frequency ratio,
# a 440 -> 660 Hz two-song pair (gapless, no pitch reset at the song change, proxied
# and downloaded), the pitch resets of pause/resume/seek/skip, speed 1.5 x pitch
# +5, lock-to-speed 1.25, speed and EQ changes with pitch set, and the time from a
# seek to the first audio at pitch 0 and +5. Phase `boost` (I24, ReplayGain boost) plays
# -30 dBFS songs tagged +10 dB and 0.98 FS songs tagged -3 dB (queue Q H Q Q48 H) and
# samples the tap's boost every 250 ms. Needs a booted iOS simulator; one heavy job (see
# docs/development/development-workflow.md). Evidence: build/ios-gapless-diagnostics/<stamp>/.
#
#   GAPLESS_PHASES   space-separated subset of: main rates formats seek insert loop pitch boost crossfade (crossfade
#                    relaunches the app with crossfade on, so it stays last)
#   GAP_TOLERANCE_MS largest accepted gap at a gapless transition (default 20)
#   BOOST_ON_RUNS    runs of the boost-on queue in phase `boost` (default 1)
#   GAPLESS_REPEATS  runs of each main case (default 1); GAPLESS_KEEP_GOING=1
#                    reports failures and carries on instead of stopping
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export NAVIS_DIAGNOSTICS_DEVICE=ios
source "$PROJECT_DIR/tool/lib/diagnostics.sh"
DIAGNOSTICS_APP_NAME='Navis Gapless Diagnostics'
DIAGNOSTICS_FAILURE_PREFIX='ios-gapless'
DIAGNOSTICS_POLL_INTERVAL=0.5
PHASES="${GAPLESS_PHASES:-main rates formats seek insert loop pitch boost crossfade}"
BOOST_ON_RUNS="${BOOST_ON_RUNS:-1}"
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
# Songs 4, 14, 15, 3 are all 22.05 kHz but four different source formats: mono
# 16-bit, stereo 16-bit, mono float, mono 16-bit again (see start_fixture).
FORMAT_SONGS='["fixture-song-4","fixture-song-14","fixture-song-15","fixture-song-3"]'
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
# Every phase: the tap's prepares and unprepares balance (starting over at the format cap
# relies on it), so no unprepare ever found nothing to match.
for name, a in sorted(s.items()):
    if a.get("clampedUnprepares") != 0: fail("%s: clampedUnprepares %s" % (name, a.get("clampedUnprepares")))
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
for name in ("at3", "at14", "at19"):
    if round(s[name].get("sampleRate") or 0) != 22050: fail("%s: the EQ runs at %s Hz for a 22050 Hz song" % (name, s[name].get("sampleRate")))
if s["at19"]["unmatchedFrames"] != 0: fail("%s frames matched no format" % s["at19"]["unmatchedFrames"])
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

# play_each <label> <songs-json> <song-number...>: plays the queue with the EQ at -12 dB
# and snapshots each song 1.5 s after it became the playing one (the start latency
# and the format changes move the songs around, so no fixed times), then once more
# when the queue has ended (`<label>/zend.json`).
play_each() {
  local label="$1" songs="$2"; shift 2
  mkdir -p "$OUTPUT_ROOT/$label"
  api POST /v1/playback/pause '{}' >/dev/null || true
  set_eq on
  sleep 1
  api POST /v1/playback/queue "{\"songIds\":$songs}" > "$OUTPUT_ROOT/$label-queue.json"
  local n=0 song last
  for song in "$@"; do
    n=$((n + 1)); last=$song
    wait_for /v1/playback/status "v.get(\"songId\") == \"fixture-song-$song\" and v.get(\"playing\")" "$OUTPUT_ROOT/$label-status-$n.json" 40
    sleep 1.5
    snap "$OUTPUT_ROOT/$label/song$n-$song.json"
  done
  wait_for /v1/playback/status "v.get(\"songId\") == \"fixture-song-$last\" and v.get(\"playing\") is False" "$OUTPUT_ROOT/$label-status-final.json" 20
  snap "$OUTPUT_ROOT/$label/zend.json"
}

run_rates() {
  play_each rates "$RATE_SONGS" 4 5 6
  check rates '
# AVQueuePlayer runs one audio pipeline per source format and prepares the shared
# tap for each, so the tap keeps one EQ stream per format: every song runs at its
# own rate, is processed at -12 dB, and nothing is left unmatched.
for name, rate in (("song1-4", 22050), ("song2-5", 48000), ("song3-6", 96000)):
    seen = round(s[name].get("sampleRate") or 0)
    if seen != rate: fail("%s: the EQ runs at %d Hz for a %d Hz song" % (name, seen, rate))
    level = s[name].get("levelDeltaDb")
    if level is None or abs(level + 12) > 0.6: fail("%s: levelDeltaDb %s" % (name, level))
end = s["zend"]
streams = {round(f["sampleRate"]): f for f in end.get("formatStreams") or []}
if sorted(streams) != [22050, 48000, 96000]: fail("formatStreams hold rates %s" % sorted(streams))
for rate, f in streams.items():
    if f["processedFrames"] < 0.9 * 4 * rate: fail("%d Hz: %d frames processed, expected about %d" % (rate, f["processedFrames"], 4 * rate))
    if f["levelDeltaDb"] is None or abs(f["levelDeltaDb"] + 12) > 0.6: fail("%d Hz: levelDeltaDb %s" % (rate, f["levelDeltaDb"]))
if end["unmatchedFrames"] != 0: fail("%s frames matched no format" % end["unmatchedFrames"])
if end["overlapBlocks"] != 0: fail("%s blocks overlapped on one format" % end["overlapBlocks"])
if end["tapPrepareCount"] != 3: fail("%s tap prepares for three formats" % end["tapPrepareCount"])
gaps = end.get("transitionGapsMs") or []
if any(g > 1500 for g in gaps): fail("a format change took %s ms" % gaps)
print("  prepares=%s rates=%s frames=%s unmatched=%s overlap=%s format-change gaps (not gapless by design): %s" % (
    end["tapPrepareCount"], [s[n].get("sampleRate") for n in ("song1-4", "song2-5", "song3-6")],
    {r: f["processedFrames"] for r, f in sorted(streams.items())}, end["unmatchedFrames"], end["overlapBlocks"], gaps))
'
}

# Four source formats at one rate (I25): mono 16-bit, stereo 16-bit, mono float,
# mono 16-bit. The last step is a same-key transition across two pipelines.
run_formats() {
  play_each formats "$FORMAT_SONGS" 4 14 15 3
  check formats '
for name in ("song1-4", "song2-14", "song3-15", "song4-3"):
    a = s[name]
    if round(a.get("sampleRate") or 0) != 22050: fail("%s: the EQ runs at %s Hz" % (name, a.get("sampleRate")))
    level = a.get("levelDeltaDb")
    if level is None or abs(level + 12) > 0.6: fail("%s: levelDeltaDb %s" % (name, level))
# Each song is sampled 1.5 s into it. The slot of its channel count (mono 16-bit, stereo 16-bit,
# mono float, mono 16-bit) must have grown by about that much since the previous sample; the
# previous song had the other channel count, or ended in the part of its slot that is counted before.
def frames_by_format(a): return {(round(f["sampleRate"]), f["channels"]): f["processedFrames"] for f in a.get("formatStreams") or []}
previous = {}
for name, channels in (("song1-4", 1), ("song2-14", 2), ("song3-15", 1), ("song4-3", 1)):
    now = frames_by_format(s[name])
    key = (22050, channels)
    grown = now.get(key, 0) - previous.get(key, 0)
    if grown < 0.9 * 1.5 * 22050: fail("%s: the %s slot processed %d frames since the last sample, expected about %d" % (name, key, grown, 1.5 * 22050))
    previous = now
end = s["zend"]
streams = {(round(f["sampleRate"]), f["channels"]): f for f in end.get("formatStreams") or []}
if sorted(streams) != [(22050, 1), (22050, 2)]: fail("formatStreams hold %s, expected mono and stereo at 22050" % sorted(streams))
for key, f in streams.items():
    if f["processedFrames"] <= 0: fail("%s processed no frames" % (key,))
    if f["levelDeltaDb"] is None or abs(f["levelDeltaDb"] + 12) > 0.6: fail("%s: levelDeltaDb %s" % (key, f["levelDeltaDb"]))
if end["processedFrames"] < 0.9 * 4 * 88200: fail("the tap processed %d frames, expected about %d" % (end["processedFrames"], 4 * 88200))
if end["unmatchedFrames"] != 0: fail("%s frames matched no format" % end["unmatchedFrames"])
if end["overlapBlocks"] != 0: fail("%s blocks overlapped on one format" % end["overlapBlocks"])
gaps = end.get("transitionGapsMs") or []
if any(g > 1500 for g in gaps): fail("a format change took %s ms" % gaps)
print("  prepares=%s streams=%s frames=%s unmatched=%s overlap=%s gaps=%s" % (
    end["tapPrepareCount"], sorted(streams), end["processedFrames"], end["unmatchedFrames"], end["overlapBlocks"], gaps))
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
# Each seek and each skip tells the tap once. The history is dropped either by a
# counted reset (a stream that has audio sees the flush) or by AVFoundation
# re-preparing the tap, whose new stream starts empty and counts nothing: so 0 or
# 1 counted resets, and a re-prepare when 0.
prepares = [s[k]["tapPrepareCount"] for k in ("a-steady", "b-after-seek", "c-after-skip")]
for name, i in (("seek", 1), ("skip", 2)):
    flush_delta = flushes[i] - flushes[i - 1]
    reset_delta = [steady, seeked, skipped][i] - [steady, seeked, skipped][i - 1]
    prepare_delta = prepares[i] - prepares[i - 1]
    if flush_delta != 1: fail("a %s noted %d flushes, expected 1" % (name, flush_delta))
    if reset_delta > 1: fail("a %s reset the history %d times" % (name, reset_delta))
    if reset_delta == 0 and prepare_delta == 0: fail("a %s dropped the history neither by a reset nor a re-prepare" % name)
if steady != 0: fail("the history was reset %d times before any seek" % steady)
print("  flushCount=%s resetCount steady=%s after seek=%s after skip=%s tapPrepareCount=%s" % (flushes, steady, seeked, skipped, prepares))
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

# MARK: pitch (I21)

# Fixture songs of this phase (see start_fixture below): 12 s sines at 44.1, 48 and
# 96 kHz (songs 7 to 9), a 6 s filler of the same rate after each (11, 10, 13: the
# queue API needs two songs) and a 440 -> 660 Hz pair of 6 s songs at 44.1 kHz
# (11, 12).
PITCH_ADJUST_RESET='{"speed":1,"lockPitchToSpeed":false,"pitchSemitones":0}'

# adjust <json>: speed/pitch through the same API the settings panel uses.
adjust() { api POST /v1/playback/adjustments "$1" >/dev/null; }

# position_rate <seconds>: playback seconds per wall second over the interval.
position_rate() {
  python3 - "$BASE_URL" "$TOKEN" "$1" <<'PYTHON'
import http.client, json, sys, time, urllib.parse
u = urllib.parse.urlparse(sys.argv[1])
c = http.client.HTTPConnection(u.hostname, u.port, timeout=10)
def position():
    t = time.monotonic()
    c.request("GET", "/v1/playback/status", headers={"Authorization": "Bearer " + sys.argv[2]})
    v = json.loads(c.getresponse().read())
    return (t + time.monotonic()) / 2, v["uiPlayback"]["positionStreamMs"] / 1000.0
t0, p0 = position()
time.sleep(float(sys.argv[3]))
t1, p1 = position()
print("%.4f" % ((p1 - p0) / (t1 - t0)))
PYTHON
}

# seek_to_audio_ms <target-ms...>: ms from each seek request until audio reaches the
# tap again, polled every 5 ms: the pitch stage resets (the old stream saw the flush) or
# the tap was prepared again and then processes frames.
seek_to_audio_ms() {
  python3 - "$BASE_URL" "$TOKEN" "$@" <<'PYTHON'
import http.client, json, sys, time, urllib.parse
u = urllib.parse.urlparse(sys.argv[1])
c = http.client.HTTPConnection(u.hostname, u.port, timeout=10)
def call(method, path, body=None):
    c.request(method, path, body=json.dumps(body) if body is not None else None,
              headers={"Authorization": "Bearer " + sys.argv[2], "Content-Type": "application/json"})
    return json.loads(c.getresponse().read() or b"{}")
state = lambda: call("GET", "/v1/equalizer")["application"]
times = []
for target in sys.argv[3:]:
    before = state()
    t0 = time.monotonic()
    call("POST", "/v1/playback/seek", {"positionMs": int(target)})
    frames_at_prepare = None
    while time.monotonic() - t0 < 5:
        now = state()
        if now["pitchResetCount"] > before["pitchResetCount"]: break
        if now["tapPrepareCount"] > before["tapPrepareCount"]:
            if frames_at_prepare is None: frames_at_prepare = now["processedFrames"]
            elif now["processedFrames"] > frames_at_prepare: break
        time.sleep(0.005)
    times.append(round((time.monotonic() - t0) * 1000, 1))
    time.sleep(1.2)
print(json.dumps(times))
PYTHON
}

# audio_start_ms <songs-json>: ms from the queue request until the tap has processed
# audio on the new native player (every queue starts one, so its frames start at 0),
# polled every 5 ms.
audio_start_ms() {
  python3 - "$BASE_URL" "$TOKEN" "$1" <<'PYTHON'
import http.client, json, sys, time, urllib.parse
u = urllib.parse.urlparse(sys.argv[1])
c = http.client.HTTPConnection(u.hostname, u.port, timeout=10)
def call(method, path, body=None):
    c.request(method, path, body=body, headers={"Authorization": "Bearer " + sys.argv[2], "Content-Type": "application/json"})
    return json.loads(c.getresponse().read() or b"{}")
t0 = time.monotonic()
call("POST", "/v1/playback/queue", sys.argv[3])
while time.monotonic() - t0 < 10:
    try:
        if call("GET", "/v1/equalizer")["application"]["processedFrames"] > 0: break
    except KeyError:
        pass
    time.sleep(0.005)
print(round((time.monotonic() - t0) * 1000, 1))
PYTHON
}

# The frequency of the tap's output over its input, in tolerance of 1%.
PITCH_RATIO_CHECK='
def ratio(name, expected, song_hz):
    a = s[name]
    inn, out = a.get("pitchInputHz") or 0, a.get("pitchOutputHz") or 0
    if abs(inn - song_hz) > 0.01 * song_hz: fail("%s: input %.1f Hz, expected %g" % (name, inn, song_hz))
    if abs(out / max(inn, 1) - expected) > 0.01 * expected: fail("%s: output/input = %.4f, expected %.4f (in %.1f out %.1f)" % (name, out / max(inn, 1), expected, inn, out))
'

run_pitch() {
  mkdir -p "$OUTPUT_ROOT/pitch"
  api POST /v1/playback/pause '{}' >/dev/null || true
  set_eq off
  adjust "$PITCH_ADJUST_RESET"
  # 0. Queue request to first audio, the first one in this app process (a cold
  # AudioToolbox) and then warm ones, at pitch 0 and +5.
  local starts="" st_start
  for st_start in 0 0 0 5 5; do
    adjust "{\"pitchSemitones\":$st_start}"
    starts="$starts +${st_start}st:$(audio_start_ms '{"songIds":["fixture-song-7","fixture-song-11"]}')"
    sleep 1.5
  done
  echo "queue request to first audio (ms), in order:$starts" | tee -a "$SUMMARY"
  # 1. The measured frequency ratio per rate and pitch.
  for entry in fixture-song-7:44100:4096:fixture-song-11 fixture-song-8:48000:4096:fixture-song-10 fixture-song-9:96000:8192:fixture-song-13; do
    IFS=: read -r song rate latency filler <<<"$entry"
    for st in 0 12 -12 7; do
      local label="pitch-$song-st$st"
      mkdir -p "$OUTPUT_ROOT/$label"
      adjust "{\"pitchSemitones\":$st}"
      api POST /v1/playback/queue "{\"songIds\":[\"$song\",\"$filler\"]}" > "$OUTPUT_ROOT/$label-queue.json"
      sleep 5
      snap "$OUTPUT_ROOT/$label/at5.json"
      check "$label" "
$PITCH_RATIO_CHECK
a = s['at5']
ratio('at5', 2 ** ($st / 12.0), 440)
if a['pitchCents'] != round(100 * $st): fail('pitchCents %s for $st semitones' % a['pitchCents'])
if a['pitchActive'] != ($st != 0): fail('pitchActive %s at $st semitones' % a['pitchActive'])
if a['pitchLatencyFrames'] != $latency: fail('latency %s frames, expected $latency' % a['pitchLatencyFrames'])
if round(a.get('sampleRate') or 0) != $rate: fail('the tap runs at %s Hz, expected $rate' % a.get('sampleRate'))
if a['unmatchedFrames'] != 0: fail('%s frames matched no format' % a['unmatchedFrames'])
if $st == 0 and abs(a['levelDeltaDb'] or 0) > 0.6: fail('levelDeltaDb %s at pitch 0' % a['levelDeltaDb'])
print('  %s st: out/in %.4f cents %d latency %d resets %d' % ($st, a['pitchOutputHz'] / a['pitchInputHz'], a['pitchCents'], a['pitchLatencyFrames'], a['pitchResetCount']))
"
    done
  done
  # 2. Gapless 440 -> 660 Hz pair at pitch 0 and +5, from the proxy and from disk.
  for source in proxied downloaded; do
    if [[ "$source" == downloaded ]]; then
      api POST /v1/downloads/enqueue '{"songIds":["fixture-song-11","fixture-song-12"]}' >/dev/null
      wait_for /v1/downloads/status '{"fixture-song-11","fixture-song-12"} <= {d["songId"] for d in v["permanentDownloads"]} and sum(v["queue"].values()) == 0' "$OUTPUT_ROOT/pitch-pair-download.json" 120
    fi
    for st in 0 5; do
      local label="pitch-pair-$source-st$st"
      mkdir -p "$OUTPUT_ROOT/$label"
      adjust "{\"pitchSemitones\":$st}"
      api POST /v1/playback/queue '{"songIds":["fixture-song-11","fixture-song-12"]}' > "$OUTPUT_ROOT/$label-queue.json"
      sleep 4.5
      snap "$OUTPUT_ROOT/$label/first.json"
      sleep 6
      snap "$OUTPUT_ROOT/$label/second.json"
      check "$label" "
$PITCH_RATIO_CHECK
r = 2 ** ($st / 12.0)
ratio('first', r, 440)
ratio('second', r, 660)
for k in ('first', 'second'):
    if round(s[k].get('sampleRate') or 0) != 44100: fail('%s: the tap runs at %s Hz, expected 44100' % (k, s[k].get('sampleRate')))
    if s[k]['unmatchedFrames'] != 0: fail('%s: %s frames matched no format' % (k, s[k]['unmatchedFrames']))
gaps = s['second'].get('transitionGapsMs') or []
if not gaps: fail('no transition gap measured')
if gaps[-1] > tolerance: fail('silence of %.1f ms at the song change' % gaps[-1])
if s['second']['tapPrepareCount'] != s['first']['tapPrepareCount']: fail('the tap was prepared again at the song change')
if s['second']['pitchResetCount'] != s['first']['pitchResetCount']: fail('pitch reset at the song change: %s -> %s' % (s['first']['pitchResetCount'], s['second']['pitchResetCount']))
print('  gaps=%s prepares=%s resets=%s out %.1f -> %.1f Hz' % (gaps[-2:], s['second']['tapPrepareCount'], s['second']['pitchResetCount'], s['first']['pitchOutputHz'], s['second']['pitchOutputHz']))
"
    done
  done
  # 3. Pitch resets: pause/resume none, seek and skip one each, at +5 semitones.
  local label=pitch-transport
  mkdir -p "$OUTPUT_ROOT/$label"
  adjust '{"pitchSemitones":5}'
  api POST /v1/playback/queue '{"songIds":["fixture-song-7","fixture-song-11"]}' > "$OUTPUT_ROOT/$label-queue.json"
  sleep 5
  snap "$OUTPUT_ROOT/$label/a-playing.json"
  api POST /v1/playback/pause '{}' >/dev/null
  sleep 1.5
  snap "$OUTPUT_ROOT/$label/b-paused.json"
  api POST /v1/playback/play '{}' >/dev/null
  sleep 3
  snap "$OUTPUT_ROOT/$label/c-resumed.json"
  api POST /v1/playback/seek '{"positionMs":1000}' >/dev/null
  sleep 3
  snap "$OUTPUT_ROOT/$label/d-seeked.json"
  api POST /v1/playback/next '{}' >/dev/null
  sleep 3
  snap "$OUTPUT_ROOT/$label/e-skipped.json"
  check "$label" "
$PITCH_RATIO_CHECK
n = [s[k]['pitchResetCount'] for k in ('a-playing', 'b-paused', 'c-resumed', 'd-seeked', 'e-skipped')]
got = [n[i + 1] - n[i] for i in range(4)]
p = [s[k]['tapPrepareCount'] for k in ('a-playing', 'b-paused', 'c-resumed', 'd-seeked', 'e-skipped')]
prep = [p[i + 1] - p[i] for i in range(4)]
# AVFoundation re-prepares the tap for a pause (+1 on dev too), a seek and a skip. Format slots
# live until the tap does (I25), so the pipeline that starts afterwards reuses its slot and its
# StartOfStream resets that stage once when its first audio arrives (a new stage had nothing to
# reset and counted nothing): a pause moves pitchResetCount by 0, the resume after it by at most
# the number of pipelines the pause re-prepared (and prepares nothing), and a seek or skip by at
# most 2 (its flush, then the StartOfStream of the re-prepared pipeline), with a re-prepare or a
# reset at least.
if got[0] != 0 or got[1] > prep[0] or prep[1] != 0: fail('pause or resume moved pitchResetCount %s or resume moved tapPrepareCount %s (counts %s, prepares %s)' % (got[:2], prep[1], n, p))
for name, i in (('seek', 2), ('skip', 3)):
    if got[i] > 2 or got[i] + prep[i] < 1: fail('a %s moved pitchResetCount by %d and tapPrepareCount by %d' % (name, got[i], prep[i]))
ratio('e-skipped', 2 ** (5 / 12.0), 440)
if round(s['e-skipped'].get('sampleRate') or 0) != 44100 or s['e-skipped']['unmatchedFrames'] != 0: fail('e-skipped: rate %s Hz, %s frames matched no format' % (s['e-skipped'].get('sampleRate'), s['e-skipped']['unmatchedFrames']))
print('  pitchResetCount %s tapPrepareCount %s (steps: pause, resume, seek, skip)' % (n, p))
"
  # 4. Speed 1.5 x pitch +5: the tap pitches the source, AVPlayer plays it 1.5x faster.
  label=pitch-speed
  mkdir -p "$OUTPUT_ROOT/$label"
  adjust '{"speed":1.5,"pitchSemitones":5}'
  api POST /v1/playback/queue '{"songIds":["fixture-song-7","fixture-song-11"]}' > "$OUTPUT_ROOT/$label-queue.json"
  sleep 3
  local rate
  rate="$(position_rate 3)"
  snap "$OUTPUT_ROOT/$label/at6.json"
  echo "speed 1.5 x +5 st: position rate $rate" | tee -a "$SUMMARY"
  check "$label" "
$PITCH_RATIO_CHECK
ratio('at6', 2 ** (5 / 12.0), 440)
if abs($rate - 1.5) > 0.08: fail('currentTime advanced %s x, expected 1.5' % $rate)
"
  # 5. Lock to speed 1.25 while playing: AU cents, no tap prepare, 1.25x position rate.
  label=pitch-lock
  mkdir -p "$OUTPUT_ROOT/$label"
  adjust "$PITCH_ADJUST_RESET"
  api POST /v1/playback/queue '{"songIds":["fixture-song-8","fixture-song-10"]}' > "$OUTPUT_ROOT/$label-queue.json"
  sleep 3
  snap "$OUTPUT_ROOT/$label/before.json"
  adjust '{"speed":1.25,"lockPitchToSpeed":true}'
  sleep 3.5
  rate="$(position_rate 3)"
  snap "$OUTPUT_ROOT/$label/locked.json"
  echo "lock to speed 1.25: position rate $rate" | tee -a "$SUMMARY"
  check "$label" "
$PITCH_RATIO_CHECK
a = s['locked']
if abs(a['pitchCents'] - 386) > 1: fail('pitchCents %s, expected 386' % a['pitchCents'])
if not a['pitchActive']: fail('pitch not active')
ratio('locked', 1.25, 440)
if abs($rate - 1.25) > 0.08: fail('currentTime advanced %s x, expected 1.25' % $rate)
if a['tapPrepareCount'] != s['before']['tapPrepareCount']: fail('the lock prepared the tap again')
"
  # 6. A speed change with an independent pitch set leaves the pitch and counts no reset.
  label=pitch-speed-change
  mkdir -p "$OUTPUT_ROOT/$label"
  adjust "$PITCH_ADJUST_RESET"
  adjust '{"pitchSemitones":5}'
  api POST /v1/playback/queue '{"songIds":["fixture-song-7","fixture-song-11"]}' > "$OUTPUT_ROOT/$label-queue.json"
  sleep 3
  snap "$OUTPUT_ROOT/$label/a-before.json"
  adjust '{"speed":1.5}'
  sleep 3
  snap "$OUTPUT_ROOT/$label/b-fast.json"
  adjust '{"speed":1}'
  sleep 3
  snap "$OUTPUT_ROOT/$label/c-normal.json"
  check "$label" "
$PITCH_RATIO_CHECK
for k in ('a-before', 'b-fast', 'c-normal'):
    if s[k]['pitchCents'] != 500: fail('%s: pitchCents %s' % (k, s[k]['pitchCents']))
if len({s[k]['pitchResetCount'] for k in s}) != 1: fail('a speed change reset the pitch: %s' % {k: s[k]['pitchResetCount'] for k in s})
ratio('c-normal', 2 ** (5 / 12.0), 440)
"
  # 7. The EQ toggled with a pitch set: the pitch stays, the EQ level follows.
  label=pitch-eq
  mkdir -p "$OUTPUT_ROOT/$label"
  set_eq on
  sleep 3
  snap "$OUTPUT_ROOT/$label/on.json"
  set_eq off
  sleep 3
  snap "$OUTPUT_ROOT/$label/off.json"
  check "$label" "
if abs((s['on'].get('levelDeltaDb') or 0) + 12) > 0.6: fail('EQ on: levelDeltaDb %s' % s['on'].get('levelDeltaDb'))
if abs(s['off'].get('levelDeltaDb') or 0) > 0.6: fail('EQ off: levelDeltaDb %s' % s['off'].get('levelDeltaDb'))
for k in ('on', 'off'):
    if s[k]['pitchCents'] != 500 or not s[k]['pitchActive']: fail('%s: the pitch changed with the EQ toggle' % k)
if s['on']['pitchResetCount'] != s['off']['pitchResetCount']: fail('the EQ toggle reset the pitch')
"
  # 8. Seek to first audio, pitch 0 against +5 (the AU is created in prepare either way).
  for st in 0 5; do
    adjust "{\"pitchSemitones\":$st}"
    api POST /v1/playback/queue '{"songIds":["fixture-song-7","fixture-song-11"]}' >/dev/null
    sleep 4
    local times
    times="$(seek_to_audio_ms 1000 5000 2000 6000 3000 7000 4000 8000)"
    echo "seek to first audio at pitch +$st st (ms): $times" | tee -a "$SUMMARY"
  done
  adjust "$PITCH_ADJUST_RESET"
  api POST /v1/playback/pause '{}' >/dev/null || true
}

# Pitch with crossfade on (I21): both decks get the pitch factor, each deck that plays
# reports it in the tap, and the deck that played pitched is not left active after the
# pitch is cleared. Runs inside run_crossfade, whose app has crossfade on.
run_crossfade_pitch() {
  mkdir -p "$OUTPUT_ROOT/crossfade-pitch" "$OUTPUT_ROOT/crossfade-pitch-status"
  adjust '{"pitchSemitones":5}'
  api POST /v1/playback/queue "{\"songIds\":$GAPLESS_SONGS}" > "$OUTPUT_ROOT/crossfade-pitch-queue.json"
  for n in 2 3; do
    wait_for /v1/playback/status "v.get(\"songId\") == \"fixture-song-$n\" and v.get(\"playing\")" "$OUTPUT_ROOT/crossfade-pitch-status/song$n.json" 30
    sleep 1.5
    snap "$OUTPUT_ROOT/crossfade-pitch/song$n.json"
    api GET /v1/playback/status > "$OUTPUT_ROOT/crossfade-pitch-status/song$n-settled.json"
  done
  adjust "$PITCH_ADJUST_RESET"
  wait_for /v1/playback/status 'v.get("songId") == "fixture-song-4" and v.get("playing")' "$OUTPUT_ROOT/crossfade-pitch-status/song4.json" 30
  sleep 2.5
  snap "$OUTPUT_ROOT/crossfade-pitch/song4-cleared.json"
  api GET /v1/playback/status > "$OUTPUT_ROOT/crossfade-pitch-status/song4-settled.json"
  python3 - "$OUTPUT_ROOT/crossfade-pitch-status" <<'PYTHON' || fail "crossfade pitch: the decks did not both take the pitch"
import json, math, sys
d = sys.argv[1]
want = 2 ** (5 / 12)
for name, pitched in (("song2-settled", True), ("song3-settled", True), ("song4-settled", False)):
    v = json.load(open("%s/%s.json" % (d, name)))
    expected = want if pitched else 1.0
    for key in ("playerPitchFactor", "crossfadePitchFactor"):
        if abs(v[key] - expected) > 1e-6: raise SystemExit("%s: %s = %s, expected %s" % (name, key, v[key], expected))
print("  crossfade: both decks' pitch factors follow the setting")
PYTHON
  check crossfade-pitch '
for k in ("song2", "song3"):
    a = s[k]
    if a["pitchCents"] != 500 or not a["pitchActive"]: fail("%s: the playing deck reports cents %s active %s" % (k, a["pitchCents"], a["pitchActive"]))
a = s["song4-cleared"]
if a["pitchCents"] != 0 or a["pitchActive"]: fail("after clearing the pitch the deck reports cents %s active %s" % (a["pitchCents"], a["pitchActive"]))
print("  crossfade pitch: song 2 %s/%s, song 3 %s/%s, cleared %s/%s (cents/active)" % (s["song2"]["pitchCents"], s["song2"]["pitchActive"], s["song3"]["pitchCents"], s["song3"]["pitchActive"], a["pitchCents"], a["pitchActive"]))
'
}

# MARK: boost (I24)

# Fixture songs of this phase (see start_fixture below), 12 s each: 16 and 18 (Q) a 440 Hz
# sine at -30 dBFS tagged +10 dB with its peak (boost 10 dB), 19 (Q48) the same at 48 kHz,
# 17 and 20 (H) a 660 Hz sine at 0.98 of full scale tagged -3 dB (cut, never boosted).
BOOST_SONGS='["fixture-song-16","fixture-song-17","fixture-song-18","fixture-song-19","fixture-song-20"]'

# boost_sample <label> <seconds> [WHEN:METHOD:PATH:JSON...]: samples the playing song and the
# tap's boost fields every 250 ms into boost/<label>.jsonl. WHEN is a time in seconds from the
# start, or SONG@MS: the first sample at or after that position of the song.
boost_sample() {
  mkdir -p "$OUTPUT_ROOT/boost"
  python3 - "$BASE_URL" "$TOKEN" "$OUTPUT_ROOT/boost/$1.jsonl" "$2" "${@:3}" <<'PYTHON'
import http.client, json, sys, time, urllib.parse
u = urllib.parse.urlparse(sys.argv[1])
c = http.client.HTTPConnection(u.hostname, u.port, timeout=10)
def call(method, path, body=None):
    c.request(method, path, body=json.dumps(body) if body is not None else None,
              headers={"Authorization": "Bearer " + sys.argv[2], "Content-Type": "application/json"})
    return json.loads(c.getresponse().read() or b"{}")
actions = []
for spec in sys.argv[5:]:
    when, method, path, body = spec.split(":", 3)
    actions.append((when, method, path, json.loads(body) if body else None))
keys = ("boostRequestedDb", "boostAppliedDb", "boostGuarded", "boostClipSamples", "levelDeltaDb", "sampleRate",
        "transitionGapsMs", "tapPrepareCount", "flushCount")
out = open(sys.argv[3], "w")
t0 = time.monotonic()
duration = float(sys.argv[4])
while time.monotonic() - t0 < duration:
    now = time.monotonic() - t0
    status = call("GET", "/v1/playback/status")
    song, position = status.get("songId"), status["uiPlayback"]["positionStreamMs"]
    for action in list(actions):
        when = action[0]
        due = (now >= float(when)) if "@" not in when else (
            song == when.split("@")[0] and position >= int(when.split("@")[1]))
        if due:
            actions.remove(action)
            call(action[1], action[2], action[3])
    app = call("GET", "/v1/equalizer")["application"]
    out.write(json.dumps({"t": round(now, 3), "songId": song, "positionMs": position, "playing": status.get("playing"),
                          **{k: app.get(k) for k in keys}}) + "\n")
    time.sleep(max(0.0, 0.25 - (time.monotonic() - t0 - now)))
out.close()
PYTHON
}

# boost_run <label> <kind> <eq off|on> <songs-json> <seconds> [actions...]
boost_run() {
  local label="$1" kind="$2" eq="$3" songs="$4" seconds="$5"; shift 5
  api POST /v1/playback/pause '{}' >/dev/null || true
  set_eq "$eq"
  sleep 1
  api POST /v1/playback/queue "{\"songIds\":$songs}" > "$OUTPUT_ROOT/boost-$label-queue.json"
  boost_sample "$label" "$seconds" "$@"
  local line
  line="$(python3 "$PROJECT_DIR/tool/ios_boost_check.py" "$kind" "$OUTPUT_ROOT/boost/$label.jsonl" "$GAP_TOLERANCE_MS")" || true
  printf 'boost %-20s %s\n' "$label" "$(tail -1 <<<"$line")" | tee -a "$SUMMARY"
  sed '$d' <<<"$line" | tee -a "$SUMMARY"
  [[ "$(tail -1 <<<"$line")" == ok ]] || [[ -n "${GAPLESS_KEEP_GOING:-}" ]] || fail "boost $label failed"
}

run_boost() {
  rg_mode() { api POST /v1/playback/replay-gain "{\"mode\":\"$1\",\"preamp\":${2:-0}}" > "$OUTPUT_ROOT/boost-replay-gain-$1.json"; }
  local run
  # 1. Boost on, queue Q H Q Q48 H, the EQ off so that any leak onto H crosses full scale.
  rg_mode track
  for run in $(seq 1 "$BOOST_ON_RUNS"); do
    boost_run "on-r$run" on off "$BOOST_SONGS" 64
  done
  # 2. Boost off (ReplayGain off), then a pre-amp change while it plays.
  rg_mode off
  boost_run off off off "$BOOST_SONGS" 40 "10:POST:/v1/playback/replay-gain:{\"mode\":\"off\",\"preamp\":6}"
  # 3. Per-song level with the EQ at -12 dB, boost on and off.
  rg_mode track
  boost_run level-on level on '["fixture-song-16","fixture-song-17"]' 26
  rg_mode off
  boost_run level-off level on '["fixture-song-16","fixture-song-17"]' 26
  # 4. Skip, seek, insert and a pre-amp change on the playing song.
  rg_mode track
  boost_run skip skip off '["fixture-song-16","fixture-song-17"]' 12 "fixture-song-16@4000:POST:/v1/playback/next:{}"
  boost_run seek seek off '["fixture-song-16","fixture-song-17"]' 13 "fixture-song-16@4000:POST:/v1/playback/seek:{\"positionMs\":7000}"
  boost_run insert insert off '["fixture-song-16","fixture-song-18"]' 38 \
    'fixture-song-16@10000:POST:/v1/playback/queue-edit:{"op":"playNext","songIds":["fixture-song-17"]}'
  boost_run preamp preamp off '["fixture-song-16","fixture-song-17"]' 14 "fixture-song-16@3000:POST:/v1/playback/replay-gain:{\"mode\":\"track\",\"preamp\":6}"
  rg_mode track 0
  api POST /v1/playback/pause '{}' >/dev/null || true
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
  run_crossfade_pitch
}

: > "$SUMMARY"
start_fixture 'navis-gapless-fixture' --scenario downloads --song-count 20 \
  --song-rate fixture-song-5=48000 --song-rate fixture-song-6=96000 \
  --song-wav fixture-song-14=2:16 --song-wav fixture-song-15=1:32 \
  --song-tone fixture-song-7=440:44100:12 --song-tone fixture-song-8=440:48000:12 \
  --song-tone fixture-song-9=440:96000:12 --song-tone fixture-song-10=440:48000:6 \
  --song-tone fixture-song-11=440:44100:6 --song-tone fixture-song-12=660:44100:6 \
  --song-tone fixture-song-13=440:96000:6 \
  --song-tone fixture-song-16=440:44100:12:0.0316 --song-tone fixture-song-17=660:44100:12:0.98 \
  --song-tone fixture-song-18=440:44100:12:0.0316 --song-tone fixture-song-19=440:48000:12:0.0316 \
  --song-tone fixture-song-20=660:44100:12:0.98 \
  --song-gain fixture-song-16=10:0.0316 --song-gain fixture-song-17=-3:0.98 --song-gain fixture-song-18=10:0.0316 \
  --song-gain fixture-song-19=10:0.0316 --song-gain fixture-song-20=-3:0.98
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
    formats) run_formats ;;
    seek) run_seek ;;
    insert) run_insert ;;
    loop) run_loop ;;
    crossfade) run_crossfade ;;
    pitch) run_pitch ;;
    boost) run_boost ;;
    *) fail "unknown phase $phase" ;;
  esac
done
stop_app
echo "ios-gapless: all selected phases passed; evidence in $OUTPUT_ROOT"
