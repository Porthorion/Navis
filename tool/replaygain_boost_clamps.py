"""Clamp rules of the ReplayGain boost runtime checks. Pure Python: the self-test runs without numpy."""


def unexpected_clamps(rows):
    """Clamp-counter rises per (phase, song) and the ones that are not allowed.

    A rise is seen about 100 ms after it happened, and the processor runs up to ~0.75 s ahead of the
    speaker, so the status can still name L while H's first samples clamp (the L to H join). Only a
    rise mid-song for L in a lossy phase is exempt (reported, not asserted: L sits 1 dB under full
    scale and the margin is the owner's decision): the row, the one before and the one after are
    unguarded, and L is between 1.5 s and its own duration - 3 s - 0.75 s (the row's `durationMs`;
    no duration, no exemption). Any rise in L's guard window or after it fails, as does any rise
    while another song plays."""
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
                  and all(not x['boost']['guarded'] and x['songId'] == 'rgl-1' for x in neighbours)
                  and r['positionMs'] is not None and r.get('durationMs')
                  and 1500 <= r['positionMs'] <= r['durationMs'] - 3750)
        if not exempt:
            unexpected[key] = unexpected.get(key, 0) + n
    return clamped, unexpected
