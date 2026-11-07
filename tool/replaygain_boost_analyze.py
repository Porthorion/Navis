#!/usr/bin/env python3
"""Assertions over the PCM captures of tool/replaygain_boost_diagnostics.sh.

Captures are mono float32 at 44.1 kHz. A window's peak tells the level: Q plays
at 0.1 (-20 dBFS), H at 0.63 (-4 dBFS). The Android scenario (a1) reads the status samples of
tool/replaygain_boost_android.py instead: the processor's own applied boost, guard and
clamped-sample counter. Exits 1 on any FAIL.
"""
import os
import sys

import numpy as np

RATE = 44100
WIN = RATE // 100  # 10 ms
ok = True


def load(root, name):
    path = os.path.join(root, name + '.pcm')
    return np.fromfile(path, dtype='<f4') if os.path.exists(path) else np.zeros(0, dtype='<f4')


def peaks(x, win=WIN):
    n = len(x) // win
    return np.array([np.max(np.abs(x[i * win:(i + 1) * win])) for i in range(n)])


def rms(x, win=RATE // 20):  # 50 ms
    n = len(x) // win
    return np.array([np.sqrt(np.mean(x[i * win:(i + 1) * win] ** 2)) for i in range(n)])


def check(label, cond, detail):
    global ok
    print(('PASS ' if cond else 'FAIL ') + label + ' ' + detail)
    ok &= bool(cond)


def d1(root):
    qh, hq, hqn = (load(root, n) for n in ('qh', 'hq', 'hqn'))
    check('D1 Q->H: no sample above 0.7', len(qh) and np.max(np.abs(qh)) <= 0.7, f'max={np.max(np.abs(qh)) if len(qh) else None}')
    t = peaks(qh)
    q, h = t[(t > 0.05) & (t < 0.2)], t[t >= 0.5]
    check('D1 Q plays boosted (~0.1)', len(q) > 20 and 0.085 <= np.median(q) <= 0.115, f'median={np.median(q) if len(q) else None}')
    check('D1 H plays at ~0.63', len(h) > 20 and 0.58 <= np.median(h) <= 0.68, f'median={np.median(h) if len(h) else None}')
    # H's last 0.2 s plays without its cut because Dart lifts the cut at the index event
    # (present without any boost); the boost must add nothing to it.
    check('D1 H->Q: the boost adds nothing over the no-boost control', len(hq) and np.max(np.abs(hq)) <= np.max(np.abs(hqn)) + 0.01,
          f'hq max={np.max(np.abs(hq)) if len(hq) else None} control max={np.max(np.abs(hqn)) if len(hqn) else None}')
    t = peaks(hq)
    hi = np.where(t >= 0.5)[0]
    if len(hi):
        after = t[hi[-1] + 1:hi[-1] + 201]  # 10 ms windows
        check('D1 Q head held down after H->Q (<= 0.05)', np.max(after[:30]) <= 0.05, f'head max={np.max(after[:30])}')
        check('D1 Q boosted again within ~1.2 s', np.median(after[120:160]) >= 0.085, f'late median={np.median(after[120:160])}')
    else:
        check('D1 H->Q join found', False, 'no H region')


def d6(root):
    """Q and H streamed from the fixture server. Pass 'st' plays them from the stream, 'st2' once the
    rolling cache holds them. H's last 0.2 s plays without its cut because Dart lifts the cut at the
    index event (1.014 on the base build too), so the H->Q cap is 1.05, not H's own level."""
    import json
    for name, label in (('st', 'streamed'), ('st2', 'rolling cache')):
        qh, hq = load(root, f'{name}-qh'), load(root, f'{name}-hq')
        check(f'D6 {label} Q->H: no sample above 0.7', len(qh) and np.max(np.abs(qh)) <= 0.7,
              f'max={np.max(np.abs(qh)) if len(qh) else None}')
        t = peaks(qh)
        q, h = t[(t > 0.05) & (t < 0.2)], t[t >= 0.5]
        check(f'D6 {label} Q is boosted (~0.1)', len(q) > 20 and 0.085 <= np.median(q) <= 0.115,
              f'median={np.median(q) if len(q) else None}')
        check(f'D6 {label} H plays at ~0.63', len(h) > 20 and 0.58 <= np.median(h) <= 0.68,
              f'median={np.median(h) if len(h) else None}')
        check(f'D6 {label} H->Q: no sample above 1.05', len(hq) and np.max(np.abs(hq)) <= 1.05,
              f'max={np.max(np.abs(hq)) if len(hq) else None}')
        t = peaks(hq)
        hi = np.where(t >= 0.5)[0]
        if len(hi):
            # One 10 ms window straddles the join and shows H's last samples.
            after = t[hi[-1] + 2:hi[-1] + 202]
            check(f'D6 {label} Q head held down after H->Q (<= 0.05)', np.max(after[:30]) <= 0.05,
                  f'head max={np.max(after[:30])}')
            check(f'D6 {label} Q boosted again within ~1.2 s', np.median(after[119:159]) >= 0.085,
                  f'late median={np.median(after[119:159])}')
        else:
            check(f'D6 {label} H->Q join found', False, 'no H region')
        path = os.path.join(root, f'{name}-qh-status.json')
        if os.path.exists(path):
            current = (json.load(open(path)).get('native') or {}).get('mediaKitCurrent')
            print(f'INFO D6 {label}: mpv is playing {current}')


def d3(root):
    """The on_load hook runs when the next file starts, not when it is prefetched: during Q->H the
    adapter's gain write (10 -> 0 dB) lands within 0.6 s of the heard song changing and in Q's
    last second, with prefetch-playlist off."""
    import json
    path = os.path.join(root, 'd3-samples.log')
    rows = [json.loads(line) for line in open(path)] if os.path.exists(path) else []
    rows = [r for r in rows if r.get('songId')]
    heard = next((r for i, r in enumerate(rows[1:], 1) if r['songId'] != rows[i - 1]['songId'] and r['songId'] == 'rgboost-h1'), None)
    hook = next((r for i, r in enumerate(rows[1:], 1) if rows[i - 1]['intendedDb'] == 10 and r['intendedDb'] == 0), None)
    check('D3 samples show the heard song change and the hook write', heard and hook, f'rows={len(rows)}')
    if heard and hook:
        last = max((r for r in rows if r['songId'] == 'rgboost-q1' and r['t'] <= hook['t']), key=lambda r: r['t'])
        check('D3 hook write is within 0.6 s of the heard change', abs(hook['t'] - heard['t']) <= 0.6, f'dt={hook["t"] - heard["t"]:.2f}s')
        check('D3 hook ran in the last second of Q (not at prefetch)', last['positionMs'] is not None and last['positionMs'] >= 29000,
              f'Q position at the write={last["positionMs"]} ms of 30000')


def d2(root):
    def steady(name, lo, hi, label):
        t = peaks(load(root, name))[30:]
        check(f'D2 {label}', len(t) > 10 and lo <= np.min(t) and np.max(t) <= hi,
              f'min={np.min(t) if len(t) else None} max={np.max(t) if len(t) else None}')
    steady('d2-next-h', 0.58, 0.68, 'skip Q->H plays H at its own level')
    steady('d2-next-q', 0.09, 0.115, 'skip H->Q plays Q boosted at once')
    steady('d2-seek-q', 0.09, 0.115, 'seek inside Q keeps the boost')
    steady('d2-jump-h', 0.58, 0.68, 'queue jump to H')
    steady('d2-remove-current', 0.0, 0.7, 'removing the playing song: nothing over-boosted')
    steady('d2-repeat-one', 0.085, 0.115, 'repeat-one Q loops with no dip')


def d4(root):
    for name, label in (('cf-qh', 'Q->H'), ('cf-hq', 'H->Q')):
        x = load(root, name)
        check(f'D4 {label}: no sample above 0.7', len(x) and np.max(np.abs(x)) <= 0.7, f'max={np.max(np.abs(x)) if len(x) else None}')
        e = rms(x)
        live = np.where(e > 0.005)[0]
        e = e[live[0] + 8:] if len(live) else e  # skip the start of playback
        ratio = e[1:] / np.maximum(e[:-1], 1e-9)
        # A 3 s fade moves the envelope ~2 % per 50 ms window; a missing boost that appears at the
        # hand-over is a step of 3x.
        check(f'D4 {label}: no level step (50 ms RMS ratios in 0.75..1.33)',
              len(ratio) and np.min(ratio) >= 0.75 and np.max(ratio) <= 1.33,
              f'min={np.min(ratio) if len(ratio) else None:.3f} max={np.max(ratio) if len(ratio) else None:.3f}')


def d5(root):
    """The pre-amp rises 6 dB in the last second of qa while qb is next. qa is a 0.5 sine tagged +10
    dB: its boost stops 1 dB under its peak at 5 dB (0.889) and the pre-amp cannot lift it. qb is
    tagged +2 dB, so its hook value is at or under qa's, and 6 dB of pre-amp lifts it to 8 dB. A raise
    that lands on qa's queued tail puts 0.5 * 10^(8/20) = 1.256 on it (the F1 regression). The join
    itself shows one 10 ms window ~8 % off (also in the no-boost control), hence 15 %. qb has to stay
    held for 0.5 s of its own playback, then rise to 0.0794. The join is 1.0 s after the first audible
    sample: the runner seeks to 29 s of a 30 s song."""
    qa_own, margin = 0.5 * 10 ** (5 / 20), 1.15
    for delay in ('0.55', '0.80', '0.86', '0.91', '0.96', '1.01'):
        t = peaks(load(root, f'd5-{delay}'))
        loud = np.where(t >= 0.5)[0]  # qa is the only loud song; its last window is the join
        if not len(loud):
            check(f'D5 delay {delay}: qa found', False, f'max={np.max(t) if len(t) else None}')
            continue
        join = int(loud[-1]) + 1
        check(f"D5 delay {delay}: qa's tail stays within its own level", np.max(t[:join]) <= qa_own * margin,
              f'max before the join={np.max(t[:join]):.4f} limit={qa_own * margin:.4f}')
        # One window straddles the join; qb itself is 0.056 while held and 0.079 once raised.
        raised = np.where(t[join + 2:] >= 0.07)[0]
        at = (raised[0] + 2) * 0.01 if len(raised) else None
        check(f'D5 delay {delay}: qb is raised only after the 0.5 s hold', at is not None and at >= 0.4,
              f'join at {join * 0.01:.2f}s, qb raised {at}s after it')


def a1(root):
    import json
    path = os.path.join(root, 'a1', 'a1-samples.jsonl')
    rows = [json.loads(line) for line in open(path)] if os.path.exists(path) else []
    rows = [r for r in rows if r.get('boost') and r.get('songId')]
    check('A1 samples recorded', len(rows) > 500, f'rows={len(rows)}')
    if not rows:
        return
    is_q = lambda r: r['songId'] in ('rgq-1', 'rgq-2')
    is_h = lambda r: r['songId'] in ('rgh-1', 'rgh-2')

    def phase(*names):
        return [r for r in rows if r['phase'] in names]

    def mid(rs, lo=3000, hi=20000):
        # A paused row can describe the song being replaced (status updates before the load ends).
        return [r for r in rs if r.get('playing') and r['positionMs'] is not None and lo <= r['positionMs'] <= hi]

    for name in ('joins', 'crossfade'):
        values = [r['boost']['clipSamples'] for r in phase(name)]
        check(f'A1 {name}: processor reported and clipped nothing', len(values) > 100 and max(values) == 0,
              f'samples={len(values)} max={max(values) if values else None}')
    songs = [r['songId'] for r in phase('joins')]
    changes = sum(1 for i in range(1, len(songs)) if songs[i] != songs[i - 1])
    check('A1 at least 10 gapless joins', changes >= 10, f'joins={changes}')
    for name, label in (('plateau', 'EQ off'), ('eq-on', 'EQ on'), ('crossfade', 'cross-fade')):
        q = [r['boost']['appliedDb'] for r in mid(phase(name)) if is_q(r)]
        check(f'A1 {name}: Q is boosted ~10 dB ({label})', len(q) > 10 and 9.5 <= float(np.median(q)) <= 10.5,
              f'median={float(np.median(q)) if q else None} n={len(q)}')
        h = [r['boost']['appliedDb'] for r in mid(phase(name)) if is_h(r)]
        check(f'A1 {name}: H gets no boost', len(h) > 10 and max(h) <= 0.3, f'max={max(h) if h else None} n={len(h)}')
    # The guard: in Q's last 3 s with H next, the processor is told 0 (the lower of the two).
    tail = [r for r in phase('joins') if is_q(r) and r['positionMs'] is not None and r['positionMs'] >= 27500]
    check('A1 guard: Q is guarded to 0 in its last 3 s before H',
          len(tail) > 5 and sum(1 for r in tail if r['boost']['guarded'] and r['boost']['sentDb'] == 0) >= len(tail) * 0.8,
          f'guarded={sum(1 for r in tail if r["boost"]["guarded"] and r["boost"]["sentDb"] == 0)}/{len(tail)}')
    # After H -> Q the head is held down, then the boost comes back: the processor read-back is at
    # most 1 s old, plus the 20 ms ramp.
    delays = []
    seq = phase('joins')
    for i in range(1, len(seq)):
        if is_h(seq[i - 1]) and is_q(seq[i]):
            back = next((r for r in seq[i:] if r['songId'] == seq[i]['songId'] and r['boost']['appliedDb'] >= 9.5), None)
            if back:
                delays.append(back['t'] - seq[i]['t'])
    check('A1 Q is boosted again within 3 s of every H->Q join', len(delays) >= 4 and max(delays) <= 3.0,
          f'delays={[round(d, 2) for d in delays]}')
    lowered = [r for r in phase('repeat-one-off') if r['songId'] == 'rgq-1' and r['boost']['guarded']
               and r['boost']['sentDb'] == 0]
    check('A1 repeat-one switched off in the last 3 s: guarded to H\'s 0', len(lowered) >= 2, f'samples={len(lowered)}')
    shuffled = phase('shuffle-toggle')
    check('A1 shuffle toggled in the last 3 s: nothing clipped', len(shuffled) > 50
          and max(r['boost']['clipSamples'] for r in shuffled) == 0, f'samples={len(shuffled)}')
    lossless_clips = [r['boost']['clipSamples'] for r in rows if not r['phase'].startswith('lossy')
                      and not r['phase'].startswith('a2-')]
    check('A1 lossless: clipSamples stays 0 (joins, EQ, repeat-one, shuffle, cross-fade)',
          max(lossless_clips) == 0, f'max={max(lossless_clips)} over {len(lossless_clips)} samples')
    # L is a -8 dBFS sine boosted to 1 dB under full scale: a lossy decode that overshoots the
    # tagged peak by more than the margin clips. The margin is the owner's decision, so a count
    # is reported, not asserted.
    for codec in ('opus', 'mp3'):
        rs = phase(f'lossy-{codec}')
        lossy = [r for r in mid(rs, 4000, 25000) if r['songId'] == 'rgl-1']
        check(f'A1 lossy {codec}: L is boosted ~7 dB', len(lossy) > 20
              and 6.5 <= float(np.median([r['boost']['appliedDb'] for r in lossy])) <= 7.5,
              f'n={len(lossy)} median={float(np.median([r["boost"]["appliedDb"] for r in lossy])) if lossy else None}')
        counts = [r['boost']['clipSamples'] for r in rs]
        added = sum(max(0, b - a) for a, b in zip(counts, counts[1:]))
        print(f'INFO A1 lossy {codec}: clamped samples while playing L (boost 7 dB, 1 dB under its peak): {added}')


    # A2: switches and queue edits around a boosted Q. The processor's applied boost may never
    # exceed the playing song's own boost, whichever command moved the index.
    a2 = [r for r in rows if r['phase'].startswith('a2-')]
    check('A2 samples recorded for skip, jump, remove and edit-above phases', len(a2) > 300 and
          len({r['phase'] for r in a2}) >= 6, f'rows={len(a2)} phases={sorted({r["phase"] for r in a2})}')
    check('A2 clipSamples stays 0', a2 and max(r['boost']['clipSamples'] for r in a2) == 0,
          f'max={max([r["boost"]["clipSamples"] for r in a2] or [None])}')
    over = [r for r in a2 if r['boost']['appliedDb'] > (r.get('decision') or {}).get('boostDb', 0) + 0.3]
    check("A2 the applied boost never exceeds the playing song's own", not over,
          f'violations={len(over)} first={over[0]["songId"] + " " + str(over[0]["boost"]) if over else None}')
    mis = [r for r in a2 if r['boost']['requestedDb'] > (r.get('decision') or {}).get('boostDb', 0) + 0.3
           and r['positionMs'] is not None and r['positionMs'] > 1500]
    check("A2 the boost the processor was asked for never exceeds the playing song's own after its first 1.5 s", not mis,
          f'violations={len(mis)} first={mis[0]["songId"] + " " + str(mis[0]["boost"]) if mis else None}')
    late = [r for r in phase('a2-speed') if r['songId'] == 'rgq-1' and r['positionMs'] is not None
            and r['positionMs'] >= 25800 and r['boost']['sentDb'] is not None]
    check('A2 a 2x to 1x change inside the window keeps Q guarded to 0', len(late) > 3
          and max(r['boost']['sentDb'] for r in late) == 0, f'n={len(late)} max={max([r["boost"]["sentDb"] for r in late] or [None])}')


if __name__ == '__main__':
    root, scenarios = sys.argv[1], sys.argv[2].split(',')
    for name, fn in (('d1', d1), ('d3', d3), ('d2', d2), ('d4', d4), ('d5', d5), ('d6', d6), ('a1', a1)):
        if name in scenarios or (name == 'd3' and 'd1' in scenarios):
            fn(root)
    sys.exit(0 if ok else 1)
