"""Pure-Python rules of the ReplayGain boost runtime checks (clamps, edit landing, the A2 latch phases): the
self-test runs without numpy."""


def unexpected_clamps(rows):
    """Clamp-counter rises per (phase, song) and the ones that are not allowed.

    A rise is seen about 100 ms after it happened, and the processor runs up to ~0.75 s ahead of the
    speaker, so the status can still name L while H's first samples clamp (the L to H join). Only a
    rise mid-song for L in a lossy phase is exempt (reported, not asserted: L sits 1 dB under full
    scale and the margin is the owner's decision): the row, the one before and the one after name L,
    and L is between 1.5 s and its own duration - 3 s - 0.75 s (the row's `durationMs`; no
    duration, no exemption). Any rise in L's last 3.75 s or after it fails, as does any rise while
    another song plays."""
    clamped, unexpected = {}, {}
    for i in range(1, len(rows)):
        r, before = rows[i], rows[i - 1]
        if r['boost']['clipSamples'] <= before['boost']['clipSamples']:
            continue
        n = r['boost']['clipSamples'] - before['boost']['clipSamples']
        key = (r['phase'], r['songId'])
        clamped[key] = clamped.get(key, 0) + n
        neighbours = rows[max(0, i - 1):i + 2]
        exempt = (r['phase'].startswith('lossy-') and r['songId'] == 'rgl-1'
                  and all(x['songId'] == 'rgl-1' for x in neighbours)
                  and r['positionMs'] is not None and r.get('durationMs')
                  and 1500 <= r['positionMs'] <= r['durationMs'] - 3750)
        if not exempt:
            unexpected[key] = unexpected.get(key, 0) + n
    return clamped, unexpected


def edit_landed(rows, phase, song, before, after):
    """Whether `song`'s rows of `phase` show the queue index `before` and, later, `after`: the proof that
    the phase's queue edit happened (a remove above moves Q from 1 to 0, an insert above from 1 to 2)."""
    seen = [r['index'] for r in rows if r['phase'] == phase and r['songId'] == song and r.get('index') is not None]
    return before in seen and after in seen[seen.index(before):]


def field_changed(rows, phase, key):
    """Whether `key` took two different values in `phase`: the proof that a loop, shuffle or speed change landed."""
    return len({r.get(key) for r in rows if r['phase'] == phase and r.get(key) is not None}) >= 2


def speed_changed_mid_fade(rows):
    """The crossfade-speed phase: a row of H1 in its fade (from 27 s) at another speed, then Q2 heard."""
    seq = [r for r in rows if r['phase'] == 'crossfade-speed']
    for i, r in enumerate(seq):
        if (r['songId'] == 'rgh-1' and (r.get('positionMs') or 0) >= 27000 and (r.get('speed') or 1) >= 1.2
                and any(x['songId'] == 'rgq-2' for x in seq[i:])):
            return True
    return False


def over_own_gain(r, slack=0.3, edge_ms=1000):
    """Whether the processor's applied gain exceeds the named song's own total (`decision.db`) while the song
    is more than `edge_ms` from either end: nearer a join the row and the processor can name different songs."""
    pos, dur = r.get('positionMs'), r.get('durationMs')
    if pos is None or not dur or not edge_ms <= pos <= dur - edge_ms:
        return False
    return r['boost']['appliedDb'] > ((r.get('decision') or {}).get('db') or 0) + slack


LATCH_ACTIONS = [f'remove-above-{n}' for n in range(1, 6)] + ['insert-above', 'loop', 'shuffle']
MOVED = {'insert-above': (1, 2), **{f'remove-above-{n}': (1, 0) for n in range(1, 6)}}
CHANGED = {'loop': 'repeat', 'shuffle': 'shuffle'}


def latch_phase_results(rows):
    """(label, ok, detail) per A2 latch phase: the edit landed (an index change, or a loop or shuffle value
    change), and Q keeps its full boost in 25.2-26.8 s (there is no guard any more: the processor changes
    gain only at Q's own boundary). Each run asserts on its own: a pooled minimum would hide one bad run
    among five good ones, and a no-op edit must fail."""
    results = []
    for action in LATCH_ACTIONS:
        phase = f'a2-latch-{action}'
        if action in MOVED:
            before, after = MOVED[action]
            results.append((f'A2 {action}: the edit landed (Q moved from queue index {before} to {after})',
                            edit_landed(rows, phase, 'rgq-1', before, after), f'moved={MOVED[action]}'))
        else:
            results.append((f'A2 {action}: the change landed (the status {CHANGED[action]} value changed)',
                            field_changed(rows, phase, CHANGED[action]), f'key={CHANGED[action]}'))
        rs = [r for r in rows if r['phase'] == phase and r['songId'] == 'rgq-1' and r.get('playing')
              and r['positionMs'] is not None and 25200 <= r['positionMs'] <= 26800
              and r['boost']['appliedDb'] is not None]
        results.append((f'A2 {action} after a 2x to 1x drop with 5 s left: Q keeps its full boost to its end',
                        len(rs) > 3 and min(r['boost']['appliedDb'] for r in rs) >= 9.5,
                        f'n={len(rs)} min appliedDb={min([r["boost"]["appliedDb"] for r in rs] or [None])}'))
    return results
