#!/usr/bin/env python3
"""Self-test of the clamp rules of tool/replaygain_boost_analyze.py: an L-labelled clamp at the L to H
join must fail, and only a clamp mid-song for L, unguarded around it, is exempt."""
import sys

try:
    import replaygain_boost_analyze as analyze
except ImportError as error:  # numpy is the analyzer's only dependency
    print(f'ReplayGain analyzer self-test skipped: {error}')
    sys.exit(0)


def row(song, pos, clips, guarded, phase='lossy-opus'):
    return {'phase': phase, 'songId': song, 'positionMs': pos,
            'boost': {'clipSamples': clips, 'guarded': guarded, 'sentDb': 0, 'appliedDb': 0, 'requestedDb': 0}}


def rows(clamp_at, song='rgl-1', guarded_from=27000, phase='lossy-opus'):
    """A 100 ms status stream of L from 25 s to its end; the counter rises at clamp_at."""
    result, clips = [], 0
    for pos in range(25000, 30100, 100):
        if pos == clamp_at:
            clips = 10
        result.append(row(song, pos, clips, pos >= guarded_from, phase))
    return result


def unexpected(stream):
    return analyze.unexpected_clamps(stream)[1]


def main():
    # A clamp on H's head, which the status still labels L: L's last seconds are guarded.
    assert unexpected(rows(29900)), 'a clamp in L\'s guard window must fail'
    assert unexpected(rows(30000)), 'a clamp at the very end, labelled L, must fail'
    assert unexpected(rows(27100)), 'a clamp just after the guard opens must fail'
    # Still unguarded by flag but past the mid-song band by position.
    assert unexpected(rows(26900, guarded_from=99999)), 'a clamp after 26.25 s must fail'
    # One row of margin: the flag flips on the row after the clamp.
    assert unexpected(rows(26900, guarded_from=27000)), 'a clamp one row before the guard must fail'
    # One row of margin on each side, inside the mid-song band: a guarded neighbour fails it.
    assert unexpected(rows(25500, guarded_from=25600)), 'a clamp one row before a guarded row must fail'
    stream = rows(25500, guarded_from=99999)
    stream[4]['boost']['guarded'] = True  # the row before the one that sees the rise (25400)
    assert unexpected(stream), 'a clamp one row after a guarded row must fail'
    # L mid-song and unguarded around it: reported, not failed.
    assert not unexpected(rows(25500, guarded_from=99999)), 'a mid-song L clamp is exempt'
    # Not in a lossy phase, or not L: always a failure.
    assert unexpected(rows(25500, guarded_from=99999, phase='joins')), 'a lossless clamp must fail'
    assert unexpected(rows(25500, song='rgh-1', guarded_from=99999)), 'a clamp on H must fail'
    assert analyze.unexpected_clamps(rows(25500, guarded_from=99999))[0], 'the clamp is still listed'
    print('ReplayGain analyzer self-test: 11 clamp rules passed.')


if __name__ == '__main__':
    main()
