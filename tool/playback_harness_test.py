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
import live_seek_stress as engine  # noqa: E402


def drag_metrics(p95=17.0, max_ms=40.0, over50=0, release=2.4, sockets=1, gets=16, flick=0):
    stall = {'max': max_ms, 'over50': over50}
    return {'caseErrors': 0, 'drags': 5, 'flickCells': 1, 'previewSocketMax': sockets, 'closedBeforeSuccessor': True, 'previewGETsMax': gets, 'flickGETs': flick,
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

    def test_case_error_row_fails_even_with_no_other_metric(self):
        # a stress-drag row that died with caseError carries neither 'drag' nor 'flick'
        rows = [{'violations': [{'oracle': 'caseError'}], 'latencyS': None, 'metrics': {}}]
        broken = h.metrics('stress-drag', rows)
        clean = drag_metrics()
        results = verdicts('stress-drag', clean, {**broken})
        self.assertFalse(results['caseErrors:'])
        self.assertFalse(results['drags:'])
        self.assertFalse(results['flickCells:'])
        self.assertFalse(all(ok for ok, _ in h.evaluate('stress-drag', clean, broken)))

    def test_base_error_cell_invalidates_the_comparison(self):
        rows = [{'case': 'stress_drag', 'rep': 0, 'violations': []},
                {'case': 'stress_flick', 'rep': 2, 'violations': [{'oracle': 'stall'}, {'oracle': 'appExited'}]}]
        self.assertEqual(h.invalid_cells(rows), ['stress_flick rep 2: appExited'])
        self.assertEqual(h.invalid_cells(rows[:1]), [])

    def test_android_stall_rule_is_wider(self):
        base, fix = drag_metrics(max_ms=149.0, over50=1), drag_metrics(max_ms=188.0, over50=46)
        self.assertFalse(verdicts('stress-drag', base, fix)['frameGapStall:'])
        android = {line.split()[2]: ok for ok, line in h.evaluate('stress-drag', base, fix, 'android')}
        self.assertTrue(android['frameGapStall:'])

    def test_line_format(self):
        ok, line = h.evaluate('queue-edit', {'caseErrors': 0, 'violations': 0}, {'caseErrors': 0, 'violations': 2})[1]
        self.assertFalse(ok)
        self.assertEqual(line, 'FAIL queue-edit violations: fix=2 base=0 limit=<= 0')

    def test_nonew_kinds_and_missing_metric(self):
        self.assertFalse(verdicts('seek', {'kinds': ['stall']}, {'kinds': ['stall', 'seekLate'], 'violations': 0,
                                                              'latencyMedianS': 1}).get('kinds:'))
        self.assertFalse(verdicts('local-seek', {'violations': 0}, {'violations': 0})['landingErrorMaxMs:'])

    def test_soak_slope_limit(self):
        base = {'caseErrors': 0, 'slopeMiBPerDrag': 6.0, 'postGcPssMiB': 500.0, 'postGcHeapMiB': 47.0}
        self.assertTrue(all(verdicts('memory-soak', base, {**base, 'slopeMiBPerDrag': 8.9}).values()))
        self.assertFalse(verdicts('memory-soak', base, {**base, 'slopeMiBPerDrag': 9.1})['slopeMiBPerDrag:'])
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


class NextSongReadiness(unittest.TestCase):
    def test_lead_bytes_and_cold_boundary(self):
        log = [{'id': 'b', 'endpoint': 'stream', 'ua': 'Dart/3.5', 'w': 90.0, 'endW': 95.0, 'bytes': 1000},
               {'id': 'b', 'endpoint': 'stream', 'ua': 'Navis Desktop', 'w': 99.0, 'endW': 120.0, 'bytes': 500}]
        self.assertEqual(engine.next_song_readiness(log, 'b', 100.0), (10.0, 1000))
        self.assertEqual(engine.next_song_readiness(log, 'c', 100.0), (None, 0))
        late = [{'id': 'b', 'endpoint': 'stream', 'ua': 'Dart/3.5', 'w': 101.0, 'endW': 105.0, 'bytes': 1000}]
        self.assertEqual(engine.next_song_readiness(late, 'b', 100.0), (-1.0, 0))
        running = [{'id': 'b', 'endpoint': 'stream', 'ua': 'Dart/3.5', 'w': 90.0, 'endW': 110.0, 'bytes': 1000}]
        self.assertEqual(engine.next_song_readiness(running, 'b', 100.0), (10.0, 500))

    def test_repeat_metrics_and_thresholds(self):
        cell = {'nextRequestLeadS': [8.0, None, 6.0], 'nextBytesAtHandover': [900, 0, 800], 'nextSeekLocal': [True, False, True]}
        m = h.metrics('repeat', [{'violations': [], 'latencyS': None, 'metrics': cell}])
        self.assertEqual((m['nextRequestLeadMedianS'], m['nextBytesAtHandoverMedian'], m['nextSeekLocalRate']), (6.0, 800, 0.67))
        base = {'caseErrors': 0, 'violations': 0, 'kinds': [], 'frozenMedianS': 0.1}
        good = {**base, 'nextRequestLeadMedianS': 5.0, 'nextSeekLocalRate': 1.0}
        self.assertTrue(all(verdicts('repeat', base, good).values()))
        cold = {**good, 'nextRequestLeadMedianS': -1.0, 'nextSeekLocalRate': 0.0}
        self.assertEqual({k: v for k, v in verdicts('repeat', base, cold).items() if not v},
                         {'nextRequestLeadMedianS:': False, 'nextSeekLocalRate:': False})
        android = h.evaluate('repeat', base, cold, 'android')
        self.assertTrue(all(ok for ok, _ in android))
        self.assertTrue(any(line.startswith('INFO') for _, line in android))


class PositionBlip(unittest.TestCase):
    @staticmethod
    def samples(positions):
        return [{'t': i * 0.1, 'songId': 's', 'idx': 0, 'pos': p, 'proc': 'ready', 'playing': True, 'dur': 300000}
                for i, p in enumerate(positions)]

    def test_one_sample_reset_is_not_a_violation(self):
        run = type('R', (), {'samples': self.samples([100000, 100100, 0, 100300, 100400]), 'actions': []})()
        self.assertEqual(engine.oracle_unexpected_change(run), [])

    def test_real_reset_still_is(self):
        run = type('R', (), {'samples': self.samples([100000, 100100, 0, 100, 200, 300, 400]), 'actions': [], 'metrics': {},
                             'trace': []})()
        self.assertEqual([v['oracle'] for v in engine.oracle_unexpected_change(run)], ['unrequestedReset'])


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
        self.assertIn('repeat', names('lib/src/features/cache/data/rolling_cache_manager.dart'))
        for path in ('lib/src/features/player/data/navis_playback_lanes.dart',):
            self.assertTrue({'crossfade', 'repeat'} <= set(names(path)), path)
        for path in ('lib/src/features/player/data/navis_shuffle_order.dart', 'lib/src/features/player/data/foo_persistence.dart'):
            self.assertTrue({'queue-edit', 'repeat'} <= set(names(path)), path)


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

    def test_no_selection_is_exit_2(self):
        code, err = self.ab('--platform', 'linux')
        self.assertEqual(code, 2)
        self.assertIn('usage', err)

    def test_android_with_only_linux_scenarios_is_exit_2(self):
        code, err = self.ab('seek', '--platform', 'android', '--base', 'HEAD')
        self.assertEqual(code, 2)
        self.assertIn('not available on Android', err)

    def test_android_map_of_linux_only_scenarios_skips_and_exits_2(self):
        out = io.StringIO()
        saved = h.map_files
        h.map_files = lambda paths: (['local-seek'], 'stub')
        try:
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()) as err:
                code = h.main(['ab', '--map', '--platform', 'android', '--base-range', 'HEAD'])
        finally:
            h.map_files = saved
        self.assertEqual(code, 2)
        self.assertIn('SKIP local-seek: linux-only', out.getvalue())
        self.assertIn('--platform linux', err.getvalue())

    def test_unknown_scenario_is_exit_2(self):
        code, _ = self.ab('nonsense', '--platform', 'linux')
        self.assertEqual(code, 2)


if __name__ == '__main__':
    unittest.main()
