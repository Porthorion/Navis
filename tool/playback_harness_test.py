#!/usr/bin/env python3
"""Self-check for tool/playback_harness.py (stdlib only, no builds or emulators): python3 tool/playback_harness_test.py"""

import contextlib
import io
import os
import sys
import tempfile
import unittest
from pathlib import Path

os.environ['NAVIS_HARNESS_CAPPED'] = '1'
sys.path.insert(0, str(Path(__file__).resolve().parent))
import playback_harness as h  # noqa: E402


def drag_metrics(p95=17.0, max_ms=40.0, over50=0, release=2.4, sockets=1, gets=16, flick=0):
    stall = {'max': max_ms, 'over50': over50}
    return {'previewSocketMax': sockets, 'closedBeforeSuccessor': True, 'previewGETsMax': gets, 'flickGETs': flick,
            'frameGapP95Ms': p95, 'eventLoopP95Ms': p95, 'frameGapStall': stall, 'eventLoopStall': stall, 'releaseMedianS': release}


def verdicts(name, base, fix):
    return {line.split()[2]: ok for ok, line in h.evaluate(name, base, fix)}


class Thresholds(unittest.TestCase):
    def test_stress_drag_pass_and_each_failure(self):
        base = drag_metrics()
        self.assertTrue(all(verdicts('stress-drag', base, drag_metrics(p95=21.9, release=2.8)).values()))
        for name, fix in {'frameGapP95Ms': drag_metrics(p95=22.1), 'previewSocketMax': drag_metrics(sockets=2),
                          'previewGETsMax': drag_metrics(gets=21), 'flickGETs': drag_metrics(flick=1),
                          'releaseMedianS': drag_metrics(release=3.0),
                          'frameGapStall': drag_metrics(max_ms=60.0, over50=1)}.items():
            self.assertFalse(verdicts('stress-drag', base, fix)[name + ':'], name)

    def test_stall_rule_allows_what_the_base_also_does(self):
        slow = drag_metrics(max_ms=80.0, over50=2)
        self.assertTrue(verdicts('stress-drag', slow, slow)['frameGapStall:'])

    def test_line_format(self):
        ok, line = h.evaluate('queue-edit', {'violations': 0}, {'violations': 2})[0]
        self.assertFalse(ok)
        self.assertEqual(line, 'FAIL queue-edit violations: fix=2 base=0 limit=<= 0')

    def test_nonew_kinds_and_missing_metric(self):
        self.assertFalse(verdicts('seek', {'kinds': ['stall']}, {'kinds': ['stall', 'seekLate'], 'violations': 0,
                                                              'latencyMedianS': 1}).get('kinds:'))
        self.assertFalse(verdicts('local-seek', {'violations': 0}, {'violations': 0})['landingErrorMaxMs:'])

    def test_soak_slope_limit(self):
        base = {'slopeMiBPerDrag': 6.0, 'postGcPssMiB': 500.0, 'postGcHeapMiB': 47.0}
        self.assertTrue(all(verdicts('memory-soak', base, {**base, 'slopeMiBPerDrag': 7.0}).values()))
        self.assertFalse(verdicts('memory-soak', base, {**base, 'slopeMiBPerDrag': 7.2})['slopeMiBPerDrag:'])
        self.assertFalse(verdicts('memory-soak', base, {**base, 'postGcHeapMiB': 55.5})['postGcHeapMiB:'])

    def test_metrics_from_rows(self):
        beat = {'frameGap': {'p95Micros': 18000, 'maxMicros': 36000, 'over50ms': 0},
                'eventLoopLag': {'p95Micros': 5000, 'maxMicros': 16000, 'over50ms': 1}}
        drag = {'previewGETs': 16, 'previewSocketMax': 1, 'closedBeforeSuccessor': True, 'heartbeat': beat, 'releaseToTargetPlus1S': 2.0}
        rows = [{'violations': [], 'latencyS': 1.9, 'metrics': {'drag': drag, 'maxFrozenS': 1.0}},
                {'violations': [{'oracle': 'stall'}], 'latencyS': None, 'metrics': {'flick': {'previewGETs': 0}}}]
        m = h.metrics('stress-drag', rows)
        self.assertEqual((m['violations'], m['kinds'], m['drags'], m['frameGapP95Ms']), (1, ['stall'], 1, 18.0))
        self.assertEqual(m['eventLoopStall'], {'max': 16.0, 'over50': 1})
        self.assertAlmostEqual(h._ols_slope([1.0, 3.0, 5.0, 7.0]), 2.0)


class CodeAreaMap(unittest.TestCase):
    def test_paths(self):
        names = lambda *paths: h.map_files(list(paths))[0]
        self.assertEqual(names('docs/x.md', 'tool/check.sh'), [])
        self.assertEqual(set(names('lib/src/features/downloads/data/download_store.dart')), {'local-seek'})
        self.assertIn('stress-drag', names('lib/src/features/player/presentation/now_playing_seek_bar.dart'))
        self.assertEqual(set(names('lib/src/features/player/data/navis_audio_handler_crossfade.dart')), {'seek', 'memory-soak', 'repeat',
                                                                                                    'cut-recovery', 'crossfade'})
        self.assertIn('repeat', names('third_party/just_audio/android/src/main/java/com/ryanheise/just_audio/ProgressiveRepeat.java'))
        self.assertEqual(set(names('lib/src/features/player/presentation/some_other_widget.dart')), set(h.SCENARIOS))
        self.assertEqual(names('lib/src/features/settings/foo.dart'), [])


class CacheKey(unittest.TestCase):
    def test_key_changes_with_inputs(self):
        sha = h.git('rev-parse', 'HEAD')
        key = h.cache_key(sha, 'linux', 'Flutter 3.1')
        self.assertEqual(key, h.cache_key(sha, 'linux', 'Flutter 3.1'))
        self.assertNotEqual(key, h.cache_key(sha, 'android', 'Flutter 3.1'))
        self.assertNotEqual(key, h.cache_key(sha, 'linux', 'Flutter 3.2'))
        self.assertTrue(key.startswith(sha[:12] + '-linux-'))


class InfraErrors(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.saved = (h.CACHE, h.SOURCE_AVD)
        h.CACHE = Path(self.tmp.name)

    def tearDown(self):
        h.CACHE, h.SOURCE_AVD = self.saved
        self.tmp.cleanup()

    def ab(self, *args):
        err = io.StringIO()
        with contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
            code = h.main(['ab', *args])
        return code, err.getvalue()

    def test_unknown_base_is_exit_2(self):
        code, err = self.ab('queue-edit', '--platform', 'linux', '--base', 'no-such-ref-anywhere')
        self.assertEqual(code, 2)
        self.assertIn('infrastructure', err)

    def test_missing_avd_is_exit_2_before_any_build(self):
        h.SOURCE_AVD = 'No_Such_Avd'
        code, err = self.ab('stress-drag', '--platform', 'android', '--base', 'HEAD')
        self.assertEqual(code, 2)
        self.assertIn('No_Such_Avd', err)

    def test_base_without_harness_is_exit_2(self):
        root = h.git('rev-list', '--max-parents=0', 'HEAD').splitlines()[0]
        code, err = self.ab('queue-edit', '--platform', 'linux', '--base', root)
        self.assertEqual(code, 2)
        self.assertIn('predates this harness', err)

    def test_unknown_scenario_is_exit_2(self):
        code, _ = self.ab('nonsense', '--platform', 'linux')
        self.assertEqual(code, 2)


if __name__ == '__main__':
    unittest.main()
