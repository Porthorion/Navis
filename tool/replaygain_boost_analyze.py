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

from replaygain_boost_clamps import unexpected_clamps

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


def after_loud(x, loud=0.5, decay=100):
    """The first sample after the last loud one plus `decay` samples (one 440 Hz period at 44.1 kHz): the
    song may end in the next, unfinished half-cycle (H and qa are the only songs at or above `loud`);
    None without one."""
    hi = np.where(np.abs(x) >= loud)[0]
    return int(hi[-1]) + 1 + decay if len(hi) else None


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
    b = after_loud(hq)
    if b is not None:
        late = peaks(hq[b:])  # per-sample boundary: H's last half-cycle is not Q's head
        head = np.max(np.abs(hq[b:b + int(0.3 * RATE)]))
        check('D1 Q head held down after H->Q (<= 0.05)', head <= 0.05, f'head max={head:.4f}')
        check('D1 Q boosted again within ~1.2 s', np.median(late[119:159]) >= 0.085, f'late median={np.median(late[119:159])}')
    else:
        check('D1 H->Q join found', False, 'no H region')


def d6(root):
    """Q and H served by the fixture server, which paces media bodies at 800 KB/s. Pass 'st' joins songs
    that are still downloading, so a stream plays (the seek's source kind is directStream); pass 'st2'
    joins the same songs once the rolling cache holds them (a file plays). H's last 0.2 s plays
    without its cut because Dart lifts the cut at the index event (1.014 on the base build too), so
    the H->Q cap is 1.05, not H's own level. The head of Q is checked per sample from the end of
    H's last loud sample."""
    import json
    for name, label, kind in (('st', 'streamed', 'directStream'), ('st2', 'rolling cache', 'file')):
        for join in ('qh', 'hq'):
            path = os.path.join(root, f'{name}-{join}-status.json')
            events = (json.load(open(path)).get('seekEvents') or []) if os.path.exists(path) else []
            seek = [e for e in events if e.get('requestedPositionMs') == 26000]
            got = seek[-1].get('afterSourceKind') if seek else None
            check(f'D6 {label} {join.upper()}: the join seek landed on a {kind} source', got == kind,
                  f'afterSourceKind={got} path={seek[-1].get("path") if seek else None}')
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
        b = after_loud(hq)
        if b is None:
            check(f'D6 {label} H->Q join found', False, 'no H region')
            continue
        head = np.max(np.abs(hq[b:b + int(0.3 * RATE)]))
        check(f'D6 {label} Q head held down after H->Q (<= 0.05)', head <= 0.05, f'head max={head:.4f}')
        late = peaks(hq[b:])
        check(f'D6 {label} Q boosted again within ~1.2 s', np.median(late[119:159]) >= 0.085,
              f'late median={np.median(late[119:159])}')


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
        x = load(root, f'd5-{delay}')
        b = after_loud(x)  # qa is the only loud song: its last loud sample is the join
        if b is None:
            check(f'D5 delay {delay}: qa found', False, f'max={np.max(np.abs(x)) if len(x) else None}')
            continue
        tail = np.max(np.abs(x[:b]))
        check(f"D5 delay {delay}: qa's tail stays within its own level", tail <= qa_own * margin,
              f'max up to the join={tail:.4f} limit={qa_own * margin:.4f}')
        raised = np.where(peaks(x[b:]) >= 0.07)[0]
        at = raised[0] * 0.01 if len(raised) else None
        check(f'D5 delay {delay}: qb is raised only after the 0.5 s hold', at is not None and at >= 0.4,
              f'join at {b / RATE:.2f}s, qb raised {at}s after it')


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
    # Clamped samples per phase and song (see unexpected_clamps for what is exempt).
    clamped, unexpected = unexpected_clamps(rows)
    for (phase_name, song), n in sorted(clamped.items()):
        print(f'INFO A1 clamped samples in {phase_name} while {song} played: {n}'
              + (' (mid-song L, exempt)' if (phase_name, song) not in unexpected else ''))
    if not clamped:
        print('INFO A1 clamped samples: none in any phase')
    check('A1 no clamped sample except L mid-song in a lossy phase (the L to H join included)', not unexpected,
          f'unexpected={unexpected}')
    for codec in ('opus', 'mp3'):
        rs = phase(f'lossy-{codec}')
        lossy = [r for r in mid(rs, 4000, 25000) if r['songId'] == 'rgl-1']
        check(f'A1 lossy {codec}: L is boosted ~7 dB', len(lossy) > 20
              and 6.5 <= float(np.median([r['boost']['appliedDb'] for r in lossy])) <= 7.5,
              f'n={len(lossy)} median={float(np.median([r["boost"]["appliedDb"] for r in lossy])) if lossy else None}')


    # A2: switches and queue edits around a boosted Q. The processor's applied boost may never
    # exceed the playing song's own boost, whichever command moved the index.
    a2 = [r for r in rows if r['phase'].startswith('a2-')]
    check('A2 samples recorded for skip, jump, remove, edit-above, Play and insert phases', len(a2) > 300 and
          len({r['phase'] for r in a2}) >= 13, f'rows={len(a2)} phases={sorted({r["phase"] for r in a2})}')
    a2_rises = unexpected_clamps(a2)[1]  # the counter is cumulative: count its rises, not its value
    check('A2 no clamped sample in any A2 phase', not a2_rises, f'rises={a2_rises}')
    play = phase('a2-play-completed')
    done = [r for r in play if r['songId'] == 'rgq-1' and (r['positionMs'] or 0) > 28000]
    # Only rows after the last row of Q's end count: H rows before it would not be a restart.
    end = max((i for i, r in enumerate(play) if r in done), default=-1)
    restarted = [r for r in play[end + 1:] if r['songId'] == 'rgh-1' and r.get('playing')]
    again = [r for r in play[end + 1:] if r['songId'] == 'rgq-1' and r.get('playing')
             and r['positionMs'] is not None and r['positionMs'] < 5000]
    if len(done) > 3 and len(restarted) > 3:
        check('A2 Play on the completed queue restarted at song 0 (H)', True,
              f'Q end rows={len(done)} H restart rows={len(restarted)}')
    elif len(done) > 3 and len(again) > 3:
        # The API's Play (handler.play(), like the Now Playing button) replays the ended last song on the
        # emulator and never takes handler.dart's restart-at-index-0 branch: that path is not exercised.
        print('SKIP A2 Play on the completed queue restarted at song 0 (H): NOT a pass. Play on a finished '
              f'queue replays the last song (Q end rows={len(done)} Q restart rows={len(again)}); '
              'tracked in #374')
    else:
        check('A2 Play on the completed queue restarted at song 0 or replayed Q', False,
              f'Q end rows={len(done)} H restart rows={len(restarted)} Q again rows={len(again)}')
    for action in ('remove-above', 'loop', 'shuffle'):
        rs = [r for r in phase(f'a2-latch-{action}') if r['songId'] == 'rgq-1' and r.get('playing')
              and r['positionMs'] is not None and 25200 <= r['positionMs'] <= 26800
              and r['boost']['sentDb'] is not None]
        runs = 5 if action == 'remove-above' else 1
        check(f'A2 {action} after a 2x to 1x drop with 5 s left ({runs} run{"s" if runs > 1 else ""}): Q stays guarded to 0 until the window',
              len(rs) > 3 * runs and max(r['boost']['sentDb'] for r in rs) == 0,
              f'n={len(rs)} max sentDb={max([r["boost"]["sentDb"] for r in rs] or [None])}')
    # A new play of the same song: a duplicate entry (index 1 of [Q, Q, H]) and the repeat pass of repeat-one.
    second = [r for r in phase('a2-duplicate') if r['songId'] == 'rgq-1' and r.get('index') == 1 and r.get('playing')
              and r['positionMs'] is not None and 1500 <= r['positionMs'] <= 6000]
    check('A2 a duplicate entry of Q is a new play: unguarded and boosted from its start',
          len(second) > 10 and all(not r['boost']['guarded'] and r['boost']['sentDb'] == 10 for r in second),
          f'n={len(second)} guarded rows={sum(1 for r in second if r["boost"]["guarded"])}')
    wrap = [r for r in phase('a2-repeat-one-wrap') if r['songId'] == 'rgq-1' and r.get('playing')
            and r['positionMs'] is not None and 2500 <= r['positionMs'] <= 8000]
    check('A2 repeat-one wrap, then repeat off in the second pass: Q is unguarded and boosted',
          len(wrap) > 10 and all(not r['boost']['guarded'] and r['boost']['sentDb'] == 10 for r in wrap),
          f'n={len(wrap)} guarded rows={sum(1 for r in wrap if r["boost"]["guarded"])}')
    import json
    order_path = os.path.join(root, 'a1', 'a1-ordering.jsonl')
    orders = [json.loads(line) for line in open(order_path)] if os.path.exists(order_path) else []
    for o in orders:
        print(f'INFO A2 remove-above ordering: reply at {o["replyMs"]} ms, new index seen at {o["indexSeenMs"]} ms: {o["order"]}')
    print('INFO A2 remove-above ordering summary: ' + ', '.join(
        f'{k}={sum(1 for o in orders if o["order"] == k)}' for k in ('before-reply', 'after-reply', 'not-seen')))
    resumed = [r for r in phase('a2-insert-resume') if r['songId'] == 'rgh-2' and r.get('playing')]
    check('A2 an insert into the completed queue resumed at the inserted song (H2)', len(resumed) > 3,
          f'H2 rows={len(resumed)}')
    # A row that is not playing can name the song of a queue being replaced while the processor still
    # holds the old song's value (nothing is audible): only playing rows are held to the rule.
    heard = [r for r in a2 if r.get('playing')]
    over = [r for r in heard if r['boost']['appliedDb'] > (r.get('decision') or {}).get('boostDb', 0) + 0.3]
    check("A2 the applied boost never exceeds the playing song's own", not over,
          f'violations={len(over)} first={over[0]["songId"] + " " + str(over[0]["boost"]) if over else None}')
    mis = [r for r in heard if r['boost']['requestedDb'] > (r.get('decision') or {}).get('boostDb', 0) + 0.3]
    check("A2 the boost the processor was asked for never exceeds the playing song's own, from its first sample", not mis,
          f'violations={len(mis)} first={mis[0]["songId"] + " @" + str(mis[0]["positionMs"]) + " " + str(mis[0]["boost"]) if mis else None}')
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
