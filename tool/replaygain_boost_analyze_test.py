#!/usr/bin/env python3
"""Self-test of the clamp rules of tool/replaygain_boost_clamps.py (pure Python, no numpy): an L-labelled
clamp at the L to H join must fail, and only a clamp mid-song for L, unguarded around it, is exempt."""
import sys

import replaygain_boost_clamps as clamps


def row(song, pos, count, guarded, phase, duration):
    return {'phase': phase, 'songId': song, 'positionMs': pos, 'durationMs': duration,
            'boost': {'clipSamples': count, 'guarded': guarded, 'sentDb': 0, 'appliedDb': 0, 'requestedDb': 0}}


def rows(clamp_at, song='rgl-1', guarded_from=27000, phase='lossy-opus', duration=30000, start=1000):
    """A 100 ms status stream of L from `start` to its end; the counter rises at clamp_at."""
    result, count = [], 0
    for pos in range(start, duration + 100, 100):
        if pos == clamp_at:
            count = 10
        result.append(row(song, pos, count, pos >= guarded_from, phase, duration))
    return result


def unexpected(stream):
    return clamps.unexpected_clamps(stream)[1]


def main():
    # A clamp on H's head, which the status still labels L: L's last seconds are guarded.
    assert unexpected(rows(29900)), "a clamp in L's guard window must fail"
    assert unexpected(rows(30000)), 'a clamp at the very end, labelled L, must fail'
    assert unexpected(rows(27100)), 'a clamp just after the guard opens must fail'
    # Unguarded by flag but past the mid-song band by position (L's own duration minus 3.75 s).
    assert unexpected(rows(26900, guarded_from=99999)), 'a clamp after 26.25 s must fail'
    assert not unexpected(rows(26200, guarded_from=99999)), 'a clamp just inside the band is exempt'
    # One row of margin on each side, inside the band: a guarded neighbour fails it.
    assert unexpected(rows(25500, guarded_from=25600)), 'a clamp one row before a guarded row must fail'
    stream = rows(25500, guarded_from=99999)
    stream[[r['positionMs'] for r in stream].index(25400)]['boost']['guarded'] = True
    assert unexpected(stream), 'a clamp one row after a guarded row must fail'
    # The lower bound: the first 1.5 s of L are not mid-song.
    assert unexpected(rows(1200, guarded_from=99999)), 'a clamp before 1.5 s must fail'
    assert unexpected(rows(1400, guarded_from=99999)), 'a clamp before 1.5 s must fail'
    assert not unexpected(rows(1500, guarded_from=99999)), 'a clamp at 1.5 s is exempt'
    # A shorter L: the upper bound is its own duration minus 3.75 s, not 26.25 s.
    assert unexpected(rows(17000, guarded_from=99999, duration=20000)), 'a clamp past 16.25 s of a 20 s L must fail'
    assert not unexpected(rows(15000, guarded_from=99999, duration=20000)), 'a mid-song clamp of a 20 s L is exempt'
    # No duration, no exemption.
    stream = rows(15000, guarded_from=99999)
    for r in stream:
        r['durationMs'] = None
    assert unexpected(stream), 'without a duration nothing is exempt'
    # L mid-song and unguarded around it: reported, not failed.
    assert not unexpected(rows(25500, guarded_from=99999)), 'a mid-song L clamp is exempt'
    # Not in a lossy phase, or not L: always a failure.
    assert unexpected(rows(25500, guarded_from=99999, phase='joins')), 'a lossless clamp must fail'
    assert unexpected(rows(25500, song='rgh-1', guarded_from=99999)), 'a clamp on H must fail'
    assert clamps.unexpected_clamps(rows(25500, guarded_from=99999))[0], 'the clamp is still listed'
    print('ReplayGain analyzer self-test: 17 clamp rules passed.')


if __name__ == '__main__':
    main()
