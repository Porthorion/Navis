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
    """The pre-amp rises 3 dB in the last second of qa (+2 dB) with qb (+6 dB) next. qa may then
    reach 0.0316 * 10^(5/20) = 0.0562 at most; qb would be 0.0891, which qa's tail must never see
    (the join itself shows one 10 ms window ~8 % off, also in the no-boost control, hence 15 %).
    qb has to stay held for 0.5 s of its own playback, then rise. The join is 1.0 s after the first
    audible sample: the runner seeks to 29 s of a 30 s song."""
    qa_own, margin = 0.0316 * 10 ** (5 / 20), 1.15
    for delay in ('0.55', '0.70', '0.80', '0.88', '0.95'):
        t = peaks(load(root, f'd5-{delay}'))
        audible = np.where(t > 0.01)[0]
        full = np.where(t >= 0.075)[0]
        if not len(audible) or not len(full):
            check(f'D5 delay {delay}: pre-amp reached qb', False, f'max={np.max(t) if len(t) else None}')
            continue
        join_s = audible[0] * 0.01 + 1.0
        before = t[:int(round(join_s * 100))]
        check(f"D5 delay {delay}: qa's tail stays within its own level", np.max(before) <= qa_own * margin,
              f'max before the join={np.max(before):.4f} limit={qa_own * margin:.4f}')
        check(f'D5 delay {delay}: qb is raised only after the 0.5 s hold', full[0] * 0.01 >= join_s + 0.4,
              f'join at {join_s:.2f}s, qb full at {full[0] * 0.01:.2f}s')


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
        return [r for r in rs if r['positionMs'] is not None and lo <= r['positionMs'] <= hi]

    clips = [r['boost']['clipSamples'] for r in rows]
    check('A1 clipSamples stays 0 for the whole run (joins, EQ, repeat-one, shuffle, cross-fade)', max(clips) == 0,
          f'max={max(clips)} over {len(rows)} samples')
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
    lossy = [r for r in mid(phase('lossy'), 4000, 25000) if r['songId'] == 'rgl-1']
    check('A1 lossy streams: L is boosted ~7 dB and nothing clips', len(lossy) > 20
          and 6.5 <= float(np.median([r['boost']['appliedDb'] for r in lossy])) <= 7.5
          and max(r['boost']['clipSamples'] for r in phase('lossy')) == 0,
          f'n={len(lossy)} median={float(np.median([r["boost"]["appliedDb"] for r in lossy])) if lossy else None} '
          f'clip={max([r["boost"]["clipSamples"] for r in phase("lossy")] or [None])}')


if __name__ == '__main__':
    root, scenarios = sys.argv[1], sys.argv[2].split(',')
    for name, fn in (('d1', d1), ('d3', d3), ('d2', d2), ('d4', d4), ('d5', d5), ('a1', a1)):
        if name in scenarios or (name == 'd3' and 'd1' in scenarios):
            fn(root)
    sys.exit(0 if ok else 1)
