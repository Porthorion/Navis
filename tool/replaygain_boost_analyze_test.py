#!/usr/bin/env python3
"""Self-test of the clamp rules of tool/replaygain_boost_clamps.py (pure Python, no numpy): an L-labelled
clamp at the L to H join must fail, and only a clamp mid-song for L, unguarded around it, is exempt."""
import sys

import replaygain_boost_clamps as clamps


def row(song, pos, count, phase, duration, applied=7.0):
    """One status row as the Android sidecar emits it: `replayGainBoost` is currentKey, appliedDb, clipSamples."""
    return {'phase': phase, 'songId': song, 'positionMs': pos, 'durationMs': duration,
            'boost': {'currentKey': song, 'appliedDb': applied, 'clipSamples': count}}


def rows(clamp_at, song='rgl-1', phase='lossy-opus', duration=30000, start=1000):
    """A 100 ms status stream of L from `start` to its end; the counter rises at clamp_at."""
    result, count = [], 0
    for pos in range(start, duration + 100, 100):
        if pos == clamp_at:
            count = 10
        result.append(row(song, pos, count, phase, duration))
    return result


def unexpected(stream):
    return clamps.unexpected_clamps(stream)[1]


def main():
    # A clamp on H's head, which the status still labels L: L's last 3.75 s are never exempt.
    assert unexpected(rows(29900)), "a clamp in L's last seconds must fail"
    assert unexpected(rows(30000)), 'a clamp at the very end, labelled L, must fail'
    assert unexpected(rows(27100)), 'a clamp past the mid-song band must fail'
    # Past the mid-song band by position (L's own duration minus 3.75 s).
    assert unexpected(rows(26900)), 'a clamp after 26.25 s must fail'
    assert not unexpected(rows(26200)), 'a clamp just inside the band is exempt'
    # One row of margin on each side, inside the band: a neighbour naming another song fails it.
    for neighbour in (25400, 25600):
        stream = rows(25500)
        stream[[r['positionMs'] for r in stream].index(neighbour)]['songId'] = 'rgh-1'
        assert unexpected(stream), f'a clamp next to a row of another song ({neighbour}) must fail'
    # The lower bound: the first 1.5 s of L are not mid-song.
    assert unexpected(rows(1200)), 'a clamp before 1.5 s must fail'
    assert unexpected(rows(1400)), 'a clamp before 1.5 s must fail'
    assert not unexpected(rows(1500)), 'a clamp at 1.5 s is exempt'
    # A shorter L: the upper bound is its own duration minus 3.75 s, not 26.25 s.
    assert unexpected(rows(17000, duration=20000)), 'a clamp past 16.25 s of a 20 s L must fail'
    assert not unexpected(rows(15000, duration=20000)), 'a mid-song clamp of a 20 s L is exempt'
    # No duration, no exemption.
    stream = rows(15000)
    for r in stream:
        r['durationMs'] = None
    assert unexpected(stream), 'without a duration nothing is exempt'
    # L mid-song with L around it: reported, not failed.
    assert not unexpected(rows(25500)), 'a mid-song L clamp is exempt'
    # Not in a lossy phase, or not L: always a failure.
    assert unexpected(rows(25500, phase='joins')), 'a lossless clamp must fail'
    assert unexpected(rows(25500, song='rgh-1')), 'a clamp on H must fail'
    assert clamps.unexpected_clamps(rows(25500))[0], 'the clamp is still listed'
    # The count is reported as it was: one rise of 10 samples on L in its phase, nothing else.
    assert unexpected(rows(29900)) == {('lossy-opus', 'rgl-1'): 10}, 'the failing count is the rise, per phase and song'
    assert clamps.unexpected_clamps(rows(25500))[0] == {('lossy-opus', 'rgl-1'): 10}, 'the listed count'
    # A clamp row with no position is not exempt and must not crash the analyzer.
    stream = rows(25500)
    stream[[r['positionMs'] for r in stream].index(25500)]['positionMs'] = None
    assert unexpected(stream) == {('lossy-opus', 'rgl-1'): 10}, 'a clamp without a position fails cleanly'
    # A phase passes only when its queue edit landed: the index change must be in its rows.
    def edit_rows(indices, phase='a2-edit-remove-above-1'):
        return [{'phase': phase, 'songId': 'rgq-1', 'index': i} for i in indices]
    assert clamps.edit_landed(edit_rows([1, 1, 1, 0, 0]), 'a2-edit-remove-above-1', 'rgq-1', 1, 0), 'a landed edit'
    assert not clamps.edit_landed(edit_rows([1, 1, 1, 1, 1]), 'a2-edit-remove-above-1', 'rgq-1', 1, 0), \
        'an edit that never landed (a doctored capture pinned to index 1) must not count'
    assert not clamps.edit_landed(edit_rows([0, 0, 1, 1]), 'a2-edit-remove-above-1', 'rgq-1', 1, 0), \
        'the index change must come after the start'
    assert clamps.edit_landed(edit_rows([1, 1, 2, 2], 'a2-edit-insert-above'), 'a2-edit-insert-above', 'rgq-1', 1, 2)
    assert not clamps.edit_landed(edit_rows([1, 1, 1], 'a2-edit-insert-above'), 'a2-edit-insert-above', 'rgq-1', 1, 2)
    assert not clamps.edit_landed(edit_rows([1, 0]), 'a2-edit-insert-above', 'rgq-1', 1, 0), 'another phase does not count'
    # The A2 edit phases as the analyzer runs them: a capture whose edits never landed must fail every landing
    # check, a healthy one none, so the wiring of `edit_landed` cannot be bypassed without this test noticing.
    def capture(landed, hold=True):
        # `hold` False models the old guard, which the processor no longer has: Q's gain falls to 0 before its end
        out = []
        for action in clamps.EDIT_ACTIONS:
            moved = clamps.MOVED.get(action)
            for n, pos in enumerate(range(25200, 26900, 100)):
                after = landed and n >= 8
                out.append({'phase': f'a2-edit-{action}', 'songId': 'rgq-1', 'playing': True, 'positionMs': pos,
                            'index': (moved[1] if after else moved[0]) if moved else 1,
                            'repeat': 'all' if action == 'loop' and after else 'none',
                            'shuffle': action == 'shuffle' and after,
                            'boost': {'currentKey': 'rgq-1', 'appliedDb': 10.0 if hold else 0.0, 'clipSamples': 0}})
        return out
    healthy = clamps.edit_phase_results(capture(True))
    doctored = clamps.edit_phase_results(capture(False))
    assert len(healthy) == len(doctored) == 16 and all(ok for _, ok, _ in healthy), 'a landed run passes all 16 checks'
    guarded = clamps.edit_phase_results(capture(True, hold=False))
    assert not any(ok for label, ok, _ in guarded if 'full boost' in label), 'a Q whose gain drops before its end fails all 8'
    assert all(ok for label, ok, _ in guarded if 'landed' in label), 'the landing checks do not look at the gain'
    landing = [ok for label, ok, _ in doctored if 'landed' in label]
    assert len(landing) == 8 and not any(landing), 'a capture whose edits never landed fails all 8 landing checks'
    assert all(ok for label, ok, _ in doctored if 'full boost' in label), 'the gain rows alone still pass: only the landing checks catch it'
    # The crossfade-speed phase: the speed change must land while H1 fades to Q2.
    def fade(speed, pos=27800, then='rgq-2'):
        return [{'phase': 'crossfade-speed', 'songId': 'rgh-1', 'positionMs': pos, 'speed': speed},
                {'phase': 'crossfade-speed', 'songId': then, 'positionMs': 500, 'speed': speed}]
    assert clamps.speed_changed_mid_fade(fade(1.25)), 'a speed change in the fade'
    assert not clamps.speed_changed_mid_fade(fade(1.0)), 'no speed change'
    assert not clamps.speed_changed_mid_fade(fade(1.25, pos=20000)), 'a change before the fade'
    assert not clamps.speed_changed_mid_fade(fade(1.25, then='rgh-2')), 'Q2 never heard'
    # The A2 ceiling: the applied gain may not exceed the named song's own mid-song (rows near a join are skipped).
    def own(pos, applied, db=-3.0, dur=30000):
        return {'positionMs': pos, 'durationMs': dur, 'boost': {'appliedDb': applied}, 'decision': {'db': db}}
    assert clamps.over_own_gain(own(15000, 10.0)), "Q's gain on H mid-song must fail"
    assert not clamps.over_own_gain(own(15000, -3.0)), "H at its own gain passes"
    assert not clamps.over_own_gain(own(500, 10.0)), 'the first second of a song is skipped'
    assert not clamps.over_own_gain(own(29500, 10.0)), 'the last second of a song is skipped'
    assert not clamps.over_own_gain(own(None, 10.0)) and not clamps.over_own_gain(own(15000, 10.0, dur=None)), 'no position or duration, no verdict'
    assert clamps.over_own_gain({'positionMs': 15000, 'durationMs': 30000, 'boost': {'appliedDb': 2.0}, 'decision': None}), 'no decision counts as 0 dB'
    print('ReplayGain analyzer self-test: clamp rules passed.')


if __name__ == '__main__':
    main()
