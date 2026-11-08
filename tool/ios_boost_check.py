#!/usr/bin/env python3
"""Assertions for the `boost` phase of ios_gapless_diagnostics.sh (I24).

usage: ios_boost_check.py KIND SAMPLES.jsonl GAP_TOLERANCE_MS

SAMPLES.jsonl holds one row per 250 ms: the playing song, its position and the
equalizer's boost fields (see boost_sample in the script). The fixture songs
are 12 s long: 16, 18 (Q, 44.1 kHz) and 19 (Q48, 48 kHz) are -30 dBFS tagged
+10 dB with their peak, so they are boosted 10 dB; 17 and 20 (H, 0.98 of full
scale, tagged -3 dB) are cut and never boosted. Any of Q's boost leaking onto
H's samples makes them cross full scale and counts in boostClipSamples.
Exit 1 with the problems on stdout.
"""
import json
import statistics
import sys

kind, path, tolerance = sys.argv[1], sys.argv[2], float(sys.argv[3])
rows = [json.loads(line) for line in open(path)]
Q = {"fixture-song-16", "fixture-song-18", "fixture-song-19"}
H = {"fixture-song-17", "fixture-song-20"}
problems = []


def fail(message):
    problems.append(message)


def of(song):
    return [r for r in rows if r["songId"] == song and r.get("playing") is not False]


def mid(song, low=1000, high=8500):
    return [r for r in of(song) if low <= r["positionMs"] <= high and r["boostAppliedDb"] is not None]


def expect_level(song, wanted, label=None):
    samples = mid(song)
    if len(samples) < 8:
        fail("%s: only %d mid-song samples" % (song, len(samples)))
        return None
    worst = max(abs(r["boostAppliedDb"] - wanted) for r in samples)
    if worst > 0.1:
        fail("%s: boostAppliedDb off by %.2f dB from %g mid-song" % (song, worst, wanted))
    return statistics.median(r["boostAppliedDb"] for r in samples)


def max_clip():
    return max((r["boostClipSamples"] or 0) for r in rows) if rows else 0


def table():
    lines = []
    for song in sorted({r["songId"] for r in rows if r["songId"]}):
        samples = mid(song)
        if not samples:
            continue
        applied = statistics.median(r["boostAppliedDb"] for r in samples)
        eq = [r["levelDeltaDb"] for r in samples if r["levelDeltaDb"] is not None]
        level = statistics.median(eq) if eq else float("nan")
        lines.append("  %-16s requested %5.2f applied %6.2f eq %6.2f dB -> level delta %6.2f dB, rate %s Hz" % (
            song, statistics.median(r["boostRequestedDb"] for r in samples), applied, level, level + applied,
            samples[0].get("sampleRate")))
    return lines


if kind == "on":
    for song in sorted(Q | H):
        expect_level(song, 10 if song in Q else 0)
    songs = [s for s in ("fixture-song-16", "fixture-song-17", "fixture-song-18", "fixture-song-19", "fixture-song-20") if of(s)]
    if len(songs) != 5:
        fail("only %d of 5 songs played" % len(songs))
    for song in songs[:-1]:
        # The guard is on for the last 3 s of a song (and a tick), never earlier.
        early = [r for r in of(song) if 500 <= r["positionMs"] < 8500 and r["boostGuarded"]]
        if early:
            fail("%s: guarded at %d ms" % (song, early[0]["positionMs"]))
        tail = [r for r in of(song) if r["positionMs"] >= 9500]
        if tail and not any(r["boostGuarded"] for r in tail):
            fail("%s: never guarded in its last 2.5 s" % song)
        # The tail of a song that is followed by a quieter one drops to that song's boost.
    gaps = rows[-1].get("transitionGapsMs") or []
    if len(gaps) < 4:
        fail("only %d transition gaps measured" % len(gaps))
    else:
        for index, gap in enumerate(gaps[-4:]):
            limit = tolerance if index < 2 else 1500  # Q -> Q48 and Q48 -> H switch the source format
            if gap > limit:
                fail("gap %d is %.1f ms (limit %g)" % (index + 1, gap, limit))
    # Q's tail before H: at or under H's boost (0) from the guard on.
    for q, h in (("fixture-song-16", "fixture-song-17"), ("fixture-song-18", "fixture-song-19")):
        tail = [r for r in of(q) if r["positionMs"] >= 9500 and r["boostGuarded"]]
        if q == "fixture-song-16" and tail and max(r["boostAppliedDb"] for r in tail) > 0.1:
            fail("%s: its tail still plays at %.2f dB before %s" % (q, max(r["boostAppliedDb"] for r in tail), h))
    if max_clip() != 0:
        fail("boostClipSamples reached %d" % max_clip())
    print("  gaps %s, clip samples %d" % (gaps[-4:], max_clip()))
elif kind == "off":
    worst = max((abs(r["boostAppliedDb"] or 0) for r in rows), default=0)
    requested = max((abs(r["boostRequestedDb"] or 0) for r in rows), default=0)
    if worst > 0.01 or requested > 0:
        fail("boost applied %.3f dB, requested %.3f dB with ReplayGain off" % (worst, requested))
    if max_clip() != 0:
        fail("boostClipSamples reached %d with ReplayGain off" % max_clip())
elif kind == "skip":
    expect_level("fixture-song-16", 10)
    h = of("fixture-song-17")
    if len(h) < 4:
        fail("fixture-song-17 never played")
    elif max(r["boostAppliedDb"] for r in h) > 0.1:
        fail("H boosted by up to %.2f dB after the skip" % max(r["boostAppliedDb"] for r in h))
    if max_clip() != 0:
        fail("boostClipSamples reached %d" % max_clip())
elif kind == "seek":
    q = of("fixture-song-16")
    after = [r for r in q if r["positionMs"] >= 7000]
    before = [r for r in q if 1000 <= r["positionMs"] <= 3500]
    if not before or abs(statistics.median(r["boostAppliedDb"] for r in before) - 10) > 0.1:
        fail("Q is not at 10 dB before the seek")
    # The seek went to 7000 ms; a sample at least 1.5 s later is back at 10 (until the guard at 9000 ms).
    settled = [r for r in q if 8500 <= r["positionMs"] <= 8900]
    if settled and abs(statistics.median(r["boostAppliedDb"] for r in settled) - 10) > 0.1:
        fail("Q is at %.2f dB 1.5 s after the seek" % statistics.median(r["boostAppliedDb"] for r in settled))
    if max_clip() != 0:
        fail("boostClipSamples reached %d" % max_clip())
elif kind == "insert":
    h = of("fixture-song-17")
    if len(h) < 4:
        fail("the inserted H never played")
    elif max(r["boostAppliedDb"] for r in h) > 0.1:
        fail("the inserted H was boosted by up to %.2f dB" % max(r["boostAppliedDb"] for r in h))
    expect_level("fixture-song-18", 10)
    if max_clip() != 0:
        fail("boostClipSamples reached %d" % max_clip())
elif kind == "preamp":
    # Pre-amp +6 raises Q's boost from 10 to 12 (the cap) without a song change.
    q = [r for r in of("fixture-song-16") if r["positionMs"] >= 6000 and r["positionMs"] <= 8500]
    if not q or abs(statistics.median(r["boostAppliedDb"] for r in q) - 12) > 0.1:
        fail("Q did not rise to 12 dB after the pre-amp change")
    h = of("fixture-song-17")
    if h and max(r["boostAppliedDb"] for r in h) > 0.1:
        fail("H boosted by up to %.2f dB" % max(r["boostAppliedDb"] for r in h))
    if max_clip() != 0:
        fail("boostClipSamples reached %d" % max_clip())
elif kind == "level":
    pass
else:
    fail("unknown kind %s" % kind)

for line in table():
    print(line)
if problems:
    print("FAIL: " + "; ".join(problems))
    sys.exit(1)
print("ok")
