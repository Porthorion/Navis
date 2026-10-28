#!/usr/bin/env python3
"""Self-check for tool/playback_harness.py (no builds or emulators; NumPy for the PCM gate): python3 tool/playback_harness_test.py"""

import contextlib
import io
import os
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch
from pathlib import Path

os.environ['NAVIS_HARNESS_CAPPED'] = '1'
# Hermetic: never touch the real heavy-job locks or harness cache, whatever HOME is.
_ISOLATED = tempfile.TemporaryDirectory(prefix='navis-selfcheck-')
os.environ['NAVIS_HARNESS_CACHE'] = str(Path(_ISOLATED.name) / 'cache')
sys.path.insert(0, str(Path(__file__).resolve().parent))
import heavy_lock as _locks  # noqa: E402
_locks.HEAVY_LOCK = Path(_ISOLATED.name) / 'heavy.lock'
_locks.LEGACY_LOCK = Path(_ISOLATED.name) / 'legacy' / 'lock'
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
                          'frameGapStall': drag_metrics(max_ms=60.0, over50=4)}.items():
            self.assertFalse(verdicts('stress-drag', base, fix)[name + ':'], name)

    def test_linux_stall_rule_ignores_single_outlier_max(self):
        # same-code A/A pairs: 204 ms x1 vs 20.6 ms x0, and 353.8 ms x2 vs 93.9 ms x2
        for base, fix in ((drag_metrics(max_ms=20.6, over50=0), drag_metrics(max_ms=204.0, over50=1)),
                          (drag_metrics(max_ms=93.9, over50=2), drag_metrics(max_ms=353.8, over50=2))):
            self.assertTrue(verdicts('stress-drag', base, fix)['frameGapStall:'])

    def test_linux_stall_rule_fails_long_freezes_with_unchanged_p95(self):
        base = drag_metrics(max_ms=20.0, over50=0)
        self.assertFalse(verdicts('stress-drag', base, drag_metrics(max_ms=5000.0, over50=3))['frameGapStall:'])
        self.assertFalse(verdicts('stress-drag', base, drag_metrics(max_ms=5000.0, over50=1))['frameGapStall:'])
        # recorded same-code numbers and the final run still pass
        for b, f in ((20.6, 204.0), (93.9, 353.8), (33.7, 50.2), (19.994, 20.103)):
            self.assertTrue(verdicts('stress-drag', drag_metrics(max_ms=b), drag_metrics(max_ms=f, over50=1))['frameGapStall:'])

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

    def test_cut_recovery_splice_checks_are_android_only(self):
        base = {'caseErrors': 0, 'violations': 0, 'kinds': [], 'progressLoss': 0, 'recoveryMedianS': 5.0, 'frozenMedianS': 6.0,
                'reloadsAfterCut': 0, 'cutsObserved': 3}  # the current base splices instead of reloading
        fix = {**base, 'frozenMedianS': 0.0, 'spliceFrozenMedianS': 0.0, 'recoveryMedianS': 0.0, 'reloadsAfterCut': 0, 'playerErrorsAfterCut': 0,
               'spliceRequestsOk': True, 'spliceFileOk': True, 'joinRmsMax': 0.001}
        self.assertTrue(all(ok for ok, _ in h.evaluate('cut-recovery', base, fix, 'android')))
        for broken in ({'reloadsAfterCut': 1}, {'spliceRequestsOk': False}, {'spliceFileOk': False}, {'joinRmsMax': 0.02},
                       {'playerErrorsAfterCut': 1}, {'spliceFrozenMedianS': 5.0}):
            self.assertFalse(all(ok for ok, _ in h.evaluate('cut-recovery', base, {**fix, **broken}, 'android')), broken)
        # Linux has no splice: those metrics are neither required nor checked.
        self.assertEqual(len(h.evaluate('cut-recovery', base, fix)), len(h.evaluate('cut-recovery', base, fix, 'android')) - 7)

    def test_cut_base_without_an_observed_cut_is_a_failed_comparison(self):
        for observed in (None, 0):
            lines = h.evaluate('cut-recovery', {'reloadsAfterCut': 0, 'cutsObserved': observed}, {}, 'android')
            self.assertTrue(any(not ok and 'baseCutObserved' in line for ok, line in lines), observed)
        # A base that splices has no reloads, but its continuation requests/events prove the cut bit.
        lines = h.evaluate('cut-recovery', {'reloadsAfterCut': 0, 'cutsObserved': 2}, {}, 'android')
        self.assertTrue(all(ok for ok, line in lines if 'baseCutObserved' in line))

    def test_cuts_observed_must_hold_for_every_cut_row_not_the_pool(self):
        def row(requests):
            return {'violations': [], 'latencyS': None, 'metrics': {'maxFrozenS': 0, 'spliceCheck': {
                'reloads': [], 'playerErrors': [], 'requestsOk': True, 'timeOffsetRequests': requests, 'spliceEvents': [],
                'file': {'ok': True, 'maxWindowRms': 0.001}}}}
        self.assertEqual(h.metrics('cut-recovery', [row([1]), row([])])['cutsObserved'], 0)  # one row missed its cut
        self.assertEqual(h.metrics('cut-recovery', [row([1]), row([5, 6])])['cutsObserved'], 1)

    def test_splice_events_outside_the_cut_window_are_not_evidence(self):
        trace = [{'atMs': 500, 'kind': 'oggSplice', 'timeOffset': 1, 'attempt': 0},       # before the cut
                 {'atMs': 1500, 'kind': 'oggSplice', 'timeOffset': 2, 'attempt': 0}]       # inside the window
        run = Mock(trace=trace, proxy_mark=0, quality='opus128')
        run.app.run = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: __import__('shutil').rmtree(run.app.run, ignore_errors=True))
        env = Mock()
        env.proxy.log = []
        with patch.object(engine, 'oracle_cache_integrity', return_value=[]):
            info = engine.splice_check(run, env, 's', 5.0, 1000, 1, set())
        self.assertEqual([e['timeOffset'] for e in info['spliceEvents']], [2])

    def test_real_android_cut_row_yields_every_gated_splice_metric(self):
        # Trimmed from the fix run build/harness/20261028T004939.200516Z (cut40 opus128 slow1500 rep 0): that run reported
        # playerErrorsAfterCut=None because a comment swallowed it inside metrics().
        row = {'case': 'cut40', 'quality': 'opus128', 'throttle': 'slow1500', 'rep': 0, 'passed': True, 'violations': [], 'latencyS': None,
               'metrics': {'maxFrozenS': 0.28, 'spliceCheck': {
                   'reloads': [], 'playerErrors': [], 'timeOffsetRequests': ['94'],
                   'spliceEvents': [{'timeOffset': 94, 'dropped': 100, 'attempt': 1, 'result': 'ok'}], 'requestsOk': True,
                   'cacheViolations': [], 'file': {'decodeExit': 0, 'decodeStderr': '', 'lenDiffS': 0.0, 'maxWindowRms': 0.0, 'ok': True}}}}
        metrics = h.metrics('cut-recovery', [row])
        for check in h.ANDROID_CHECKS['cut-recovery']:
            self.assertIsNotNone(metrics.get(check[0]), check[0])
        self.assertEqual((metrics['playerErrorsAfterCut'], metrics['cutsObserved']), (0, 2))
        self.assertTrue(all(ok for ok, _ in h.evaluate('cut-recovery', metrics, metrics, 'android')))

    def test_cuts_observed_counts_continuation_requests_events_and_reloads(self):
        def row(**check):
            return {'violations': [], 'latencyS': None, 'metrics': {'maxFrozenS': 0, 'spliceCheck': {
                'reloads': [], 'playerErrors': [], 'requestsOk': True, 'timeOffsetRequests': [], 'spliceEvents': [],
                'file': {'ok': True, 'maxWindowRms': 0.001}, **check}}}
        self.assertEqual(h.metrics('cut-recovery', [row(timeOffsetRequests=[120], spliceEvents=[{}])])['cutsObserved'], 2)
        self.assertEqual(h.metrics('cut-recovery', [row(reloads=['setAudioSources'])])['cutsObserved'], 1)
        self.assertEqual(h.metrics('cut-recovery', [row(), row()])['cutsObserved'], 0)

    def test_splice_frozen_median_uses_only_cut_rows(self):
        rows = [{'violations': [], 'latencyS': None, 'metrics': {'maxFrozenS': 0}} for _ in range(7)]
        rows.append({'violations': [], 'latencyS': None, 'metrics': {
            'maxFrozenS': 5, 'spliceCheck': {'reloads': [], 'playerErrors': [], 'requestsOk': True,
                                          'file': {'ok': True, 'maxWindowRms': 0.001, 'lenDiffS': 0}}}})
        metrics = h.metrics('cut-recovery', rows)
        self.assertEqual(metrics['spliceFrozenMedianS'], 5)
        lines = h.evaluate('cut-recovery', {'reloadsAfterCut': 0, 'cutsObserved': 1}, metrics, 'android')
        self.assertTrue(any(not ok and 'spliceFrozenMedianS' in line for ok, line in lines))

    def test_cut5_is_android_full_only(self):
        self.assertNotIn('cut5', h.plan('cut-recovery', True, None)[0].split(','))
        self.assertIn('cut5', h.plan('cut-recovery', True, None, platform='android')[0].split(','))

    def test_join_rms_rejects_a_missing_tail(self):
        import numpy
        run = Mock(quality='opus128')
        run.env.backend.library.media_seconds = {'song': 5}
        for missing, ok in [(0, True), (480, True), (48000, False)]:
            with self.subTest(missing=missing), tempfile.TemporaryDirectory() as folder, \
                    patch.object(engine.subprocess, 'run'), \
                    patch.object(engine, 'decode_f32', side_effect=[
                        (0, '', numpy.zeros(96000 - missing)), (0, '', numpy.zeros(96000))]):
                self.assertEqual(engine.join_rms(Path(folder) / 'cache.ogg', run, 'song')['ok'], ok)

    def test_line_format(self):
        ok, line = h.evaluate('queue-edit', {'caseErrors': 0, 'violations': 0}, {'caseErrors': 0, 'violations': 2})[1]
        self.assertFalse(ok)
        self.assertEqual(line, 'FAIL queue-edit violations: fix=2 base=0 limit=<= 0')

    def test_nonew_kinds_and_missing_metric(self):
        self.assertFalse(verdicts('seek', {'kinds': ['stall']}, {'kinds': ['stall', 'seekLate'], 'violations': 0,
                                                              'latencyMedianS': 1}).get('kinds:'))
        self.assertFalse(verdicts('local-seek', {'violations': 0}, {'violations': 0})['landingErrorMaxMs:'])

    def test_soak_identical_runs_pass_including_negative_slope(self):
        for slope in (6.0, 0.0, -16.597):
            base = {'caseErrors': 0, 'slopeMiBPerDrag': slope, 'postGcPssMiB': 500.0, 'postGcPssSwapMiB': 500.0, 'postGcHeapMiB': 47.0}
            with self.subTest(slope=slope):
                self.assertTrue(all(verdicts('memory-soak', base, base).values()))

    def test_soak_real_growth_fails(self):
        base = {'caseErrors': 0, 'slopeMiBPerDrag': -2.0, 'postGcPssSwapMiB': 500.0, 'postGcHeapMiB': 47.0}
        self.assertFalse(verdicts('memory-soak', base, {**base, 'slopeMiBPerDrag': 25.0})['slopeMiBPerDrag:'])
        self.assertFalse(verdicts('memory-soak', base, {**base, 'postGcPssSwapMiB': 700.0})['postGcPssSwapMiB:'])
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


class SoakMemory(unittest.TestCase):
    @staticmethod
    def rows():
        return [{'violations': [], 'latencyS': None, 'metrics': {'soak': {
            'drags': [{'pssKiB': 400 * 1024, 'swapPssKiB': 100 * 1024},
                      {'pssKiB': 300 * 1024, 'swapPssKiB': 200 * 1024},
                      {'pssKiB': 200 * 1024, 'swapPssKiB': 300 * 1024}],
            'afterGc': {'pssKiB': 200 * 1024, 'swapPssKiB': 300 * 1024, 'heapB': 47 * 1024 ** 2}}}}]

    def test_swap_out_does_not_change_slope_or_post_gc_total(self):
        m = h.metrics('memory-soak', self.rows())
        self.assertEqual(m['slopeMiBPerDrag'], 0.0)
        self.assertEqual(m['postGcPssSwapMiB'], 500.0)
        self.assertEqual(m['postGcPssMiB'], 200.0)
        self.assertEqual(m['postGcHeapMiB'], 47.0)
        self.assertTrue(all(verdicts('memory-soak', m, m).values()))

    def test_real_total_growth_fails_despite_resident_reclaim(self):
        rows = self.rows()
        for i, sample in enumerate(rows[0]['metrics']['soak']['drags']):
            sample['swapPssKiB'] += i * 25 * 1024
        base = h.metrics('memory-soak', self.rows())
        fix = h.metrics('memory-soak', rows)
        self.assertEqual(fix['slopeMiBPerDrag'], 25.0)
        self.assertFalse(verdicts('memory-soak', base, fix)['slopeMiBPerDrag:'])

    def test_missing_swap_pss_never_passes_even_in_one_repetition(self):
        good = h.metrics('memory-soak', self.rows())
        for section, metric in (('drags', 'slopeMiBPerDrag:'), ('afterGc', 'postGcPssSwapMiB:')):
            for missing in (None, 'absent'):
                rows = self.rows()
                sample = rows[0]['metrics']['soak'][section]
                sample = sample[1] if isinstance(sample, list) else sample
                if missing == 'absent':
                    del sample['swapPssKiB']
                else:
                    sample['swapPssKiB'] = missing
                broken = h.metrics('memory-soak', rows + self.rows())
                with self.subTest(section=section, missing=missing):
                    self.assertFalse(verdicts('memory-soak', good, broken)[metric])
                    self.assertFalse(verdicts('memory-soak', broken, good)[metric])

    def test_sampler_requires_both_kernel_fields(self):
        app = Mock()
        app.proc.pid = 123
        with patch.object(engine.Path, 'read_text', return_value='Pss: 2048 kB\nSwapPss: 1024 kB\n') as read:
            self.assertEqual(engine.memory_kib(app), {'pssKiB': 2048, 'swapPssKiB': 1024})
            read.assert_called_once()
        for text in ('Pss: 2048 kB\n', 'SwapPss: 1024 kB\n'):
            with patch.object(engine.Path, 'read_text', return_value=text):
                with self.assertRaises(engine.Failure):
                    engine.memory_kib(app)

    def test_android_uses_the_same_rollup_fields(self):
        app = Mock(spec=engine.AndroidApp)
        app.shell.side_effect = ['123', 'Pss: 2048 kB\nSwapPss: 1024 kB\n']
        self.assertEqual(engine.memory_kib(app), {'pssKiB': 2048, 'swapPssKiB': 1024})
        app.shell.assert_called_with('run-as', engine.ANDROID_PACKAGE, 'cat', '/proc/123/smaps_rollup')


class NextSongReadiness(unittest.TestCase):
    @staticmethod
    def get(song, w, end_w, ua='Dart/3.5', **extra):
        return {'id': song, 'endpoint': 'stream', 'ua': ua, 'w': w, 'endW': end_w, 'bytes': 1000, **extra}

    def test_lead_bytes_and_cold_boundary(self):
        log = [self.get('b', 90.0, 95.0), self.get('b', 99.0, 120.0, ua='Navis Desktop')]
        self.assertEqual(engine.next_song_readiness(log, 'b', 100.0), (10.0, 1000))
        self.assertEqual(engine.next_song_readiness(log, 'c', 100.0), (None, 0))
        self.assertEqual(engine.next_song_readiness([self.get('b', 101.0, 105.0)], 'b', 100.0), (-1.0, 0))
        self.assertEqual(engine.next_song_readiness([self.get('b', 90.0, 110.0)], 'b', 100.0), (10.0, 500))
        # The sidecar GET that starts at the hand-over is the song's own, not a warm: the lead stays below the gate.
        self.assertLess(engine.next_song_readiness([self.get('b', 99.9, 106.0)], 'b', 100.0)[0], 3.0)

    def test_android_lock_cache_origin_gets_count_but_seeks_and_mpv_do_not(self):
        ua = 'Navis/1.5.0 (Android)'
        for extra in ({}, {'range': 'bytes=0-'}):
            self.assertEqual(engine.next_song_readiness([self.get('b', 90.0, 95.0, ua=ua, **extra)], 'b', 100.0), (10.0, 1000))
        for ignored in (self.get('b', 90.0, 95.0, ua=ua, range='bytes=1234-'), self.get('b', 90.0, 95.0, ua=ua, range='bytes=0-99'),
                        self.get('b', 90.0, 95.0, ua=ua, timeOffset='30'), self.get('b', 90.0, 95.0, ua='Navis Desktop')):
            self.assertEqual(engine.next_song_readiness([ignored], 'b', 100.0), (None, 0))
        done = self.get('b', 90.0, 95.0, ua=ua, end='complete')
        self.assertTrue(engine.seek_was_local([done], 'b', 100.0, cache_complete=True))

    def test_inflight_bytes_are_prorated_to_handover_not_the_later_observation(self):
        # 1000 bytes observed at t=110 cannot all have arrived at the t=100 boundary.
        with patch.object(engine.time, 'time', return_value=110.0):
            self.assertEqual(engine.next_song_readiness([self.get('b', 90.0, None)], 'b', 100.0), (10.0, 500))

    def test_seek_is_local_only_after_a_finished_download_and_no_new_request(self):
        done = self.get('b', 90.0, 95.0, end='complete')
        self.assertTrue(engine.seek_was_local([done], 'b', 100.0, cache_complete=True))
        self.assertFalse(engine.seek_was_local([self.get('b', 90.0, 95.0, end='cut')], 'b', 100.0, cache_complete=True))
        self.assertFalse(engine.seek_was_local([self.get('b', 99.0, 130.0, end='complete')], 'b', 100.0, cache_complete=True))
        self.assertFalse(engine.seek_was_local([done, self.get('b', 100.5, 101.0, ua='Navis Desktop')], 'b', 100.0, cache_complete=True))
        self.assertFalse(engine.seek_was_local([], 'b', 100.0, cache_complete=True))

    def test_seek_requires_the_complete_cache_file(self):
        done = self.get('b', 90.0, 95.0, end='complete')
        self.assertFalse(engine.seek_was_local([done], 'b', 100.0, cache_complete=False))

    def test_chain_wait_leaves_time_for_the_end_seek(self):
        self.assertEqual(engine.chain_warm_wait_s({'dur': 300000, 'pos': 30000}), 25)
        self.assertEqual(engine.chain_warm_wait_s({'dur': 20000, 'pos': 8000}), 2)
        self.assertEqual(engine.chain_warm_wait_s({'dur': 8000, 'pos': 5000}), 0)

    def test_chain_selects_five_long_tracks(self):
        backend = Mock()
        backend.fresh_songs.return_value = [{'id': str(i)} for i in range(5)]
        run, env = Mock(chain_repeat='none'), Mock(backend=backend)
        with patch.object(engine, 'start_queue', side_effect=RuntimeError('selected')):
            with self.assertRaisesRegex(RuntimeError, 'selected'):
                engine.case_chain_end(run, env)
        backend.fresh_songs.assert_called_once_with(5, min_s=100)

    def test_cache_completion_requires_the_final_file_and_matching_bytes(self):
        run = Mock()
        run.proxy_mark, run.quality = 0, 'opus128'
        run.env.proxy.log = [self.get('b', 90.0, 95.0, end='complete')]
        run.env.backend.server.call.return_value = {'song': {'suffix': 'flac'}}
        run.app.run = Path('/unused')
        for size, expected in ((None, False), (0, False), (999, False), (1000, True)):
            with patch.object(engine, 'rolling_fetch', return_value=size):
                self.assertEqual(engine.next_cache_complete(run, 'b'), expected)

    def test_repeat_fixture_can_finish_both_downloads_before_the_wait_expires(self):
        # The old 3x fixture took ~75 s per 300 s song: 25 s could never warm its successor.
        args = h.SCENARIOS['repeat']['args']
        self.assertGreaterEqual(float(args[args.index('--transcode-speed') + 1]), 30)

    def test_repeat_metrics_and_thresholds(self):
        cell = {'nextRequestLeadS': [8.0, None, 6.0], 'nextBytesAtHandover': [900000, 0, 800000], 'nextSeekLocal': [True, False, True]}
        m = h.metrics('repeat', [{'violations': [], 'latencyS': None, 'metrics': cell}])
        self.assertEqual((m['nextRequestLeadMinS'], m['nextBytesAtHandoverMin'], m['nextSeekLocalRate']), (-1.0, 0, 0.67))
        empty = h.metrics('repeat', [{'violations': [], 'latencyS': None, 'metrics': {}}])
        self.assertEqual((empty['nextRequestLeadMinS'], empty['nextSeekLocalRate']), (None, None))
        base = {'caseErrors': 0, 'violations': 0, 'kinds': [], 'frozenMedianS': 0.1}
        good = {**base, 'nextRequestLeadMinS': 6.0, 'nextBytesAtHandoverMin': 2000000, 'nextSeekLocalRate': 1.0}
        self.assertTrue(all(verdicts('repeat', base, good).values()))
        for name, bad in (('nextRequestLeadMinS', 0.2), ('nextRequestLeadMinS', 5.9),
                          ('nextBytesAtHandoverMin', 0), ('nextBytesAtHandoverMin', 1048575), ('nextSeekLocalRate', 0.5),
                          ('nextRequestLeadMinS', None), ('nextSeekLocalRate', None)):
            self.assertFalse(verdicts('repeat', base, {**good, name: bad})[name + ':'], (name, bad))
        android = h.evaluate('repeat', base, {**good, 'nextRequestLeadMinS': -1.0}, 'android')
        self.assertFalse(all(ok for ok, _ in android))
        self.assertTrue(all(ok for ok, _ in h.evaluate('repeat', base, good, 'android')))


class PositionBlip(unittest.TestCase):
    @staticmethod
    def samples(positions, offset=0):
        return [{'t': i * 0.1, 'songId': 's', 'idx': 0, 'pos': p, 'off': offset,
                 'proc': 'ready', 'playing': True, 'dur': 300000}
                for i, p in enumerate(positions)]

    def test_one_sample_reset_is_not_a_violation(self):
        run = type('R', (), {'samples': self.samples([100000, 100100, 0, 100300, 100400]), 'actions': [], 'trace': []})()
        self.assertEqual(engine.oracle_unexpected_change(run), [])
        self.assertEqual(engine.oracle_progress_loss(run), [])

    def test_recorded_short_native_clock_resets_with_and_without_offset(self):
        for positions, offset in [([2530, 0, 2575, 2609], 0),
                                  ([73023, 45000, 45000, 45000, 73174, 73376], 45000)]:
            with self.subTest(offset=offset):
                run = type('R', (), {'samples': self.samples(positions, offset), 'actions': [], 'trace': []})()
                self.assertEqual(engine.oracle_unexpected_change(run), [])
                self.assertEqual(engine.oracle_progress_loss(run), [])

    def test_real_reset_still_is(self):
        run = type('R', (), {'samples': self.samples([100000, 100100, 0, 100, 200, 300, 400]), 'actions': [], 'metrics': {},
                             'trace': []})()
        self.assertEqual([v['oracle'] for v in engine.oracle_unexpected_change(run)], ['unrequestedReset'])
        self.assertEqual([v['oracle'] for v in engine.oracle_progress_loss(run)], ['progressLoss'])

    def test_persistent_resets_near_start_and_in_offset_stream_still_lose_progress(self):
        for positions, offset in [([2530, 0, 100, 200, 300, 400], 0),
                                  ([73023, 45000, 45100, 45200, 45300, 45400], 45000)]:
            with self.subTest(offset=offset):
                run = type('R', (), {'samples': self.samples(positions, offset), 'actions': [], 'trace': []})()
                self.assertEqual([v['oracle'] for v in engine.oracle_progress_loss(run)], ['progressLoss'])

    def test_slow_samples_cannot_hide_a_long_reset(self):
        samples = self.samples([100000, 100100, 0, 100300, 100400])
        for i, sample in enumerate(samples):
            sample['t'] = i * 0.6
        run = type('R', (), {'samples': samples, 'actions': [], 'trace': []})()
        self.assertEqual([v['oracle'] for v in engine.oracle_progress_loss(run)], ['progressLoss'])

    def test_return_on_another_occurrence_or_offset_does_not_restore_progress(self):
        for field, value in [('idx', 1), ('off', 45000)]:
            with self.subTest(field=field):
                samples = self.samples([100000, 0, 100200])
                samples[-1][field] = value
                run = type('R', (), {'samples': samples, 'actions': [], 'trace': []})()
                self.assertEqual([v['oracle'] for v in engine.oracle_progress_loss(run)], ['progressLoss'])


class CrossfadeLongOracle(unittest.TestCase):
    """P5 oracles (synthetic samples): a clean swap passes, each defect is reported by name."""
    IDS = ['a', 'b']
    FADE = 4000

    @staticmethod
    def swap(mutate=None):
        rows = []
        for i in range(160):  # 16 s at 10 Hz: the last 10 s of song a (0..99), then song b from 0 (100..)
            song, pos = ('a', 290000 + i * 100) if i < 100 else ('b', (i - 100) * 100 + 4000)
            rows.append({'t': 10 + i * 0.1, 'songId': song, 'idx': 0 if song == 'a' else 1, 'pos': pos, 'uiPos': pos,
                         'playing': True, 'proc': 'ready', 'dur': 300000, 'off': 0, 'cf': {}})
        if mutate:
            mutate(rows)
        return rows

    def names(self, rows, saved=None):
        run = type('R', (), {'samples': rows, 'actions': [], 'trace': [], 'metrics': {}})()
        return [v['oracle'] for v in engine.oracle_crossfade_long(run, self.IDS, self.FADE, saved, rows[-1])]

    def test_clean_swap_passes(self):
        self.assertEqual(self.names(self.swap(), {'index': 1, 'positionMs': 9800}), [])

    def test_jump_and_backstep(self):
        def jump(rows):
            for r in rows[50:]:
                r['uiPos'] += 3000
        def back(rows):
            for r in rows[50:]:
                r['pos'] -= 1000
        self.assertEqual(self.names(self.swap(jump)), ['xfadeJump'])
        self.assertEqual(self.names(self.swap(back)), ['xfadeJump'])

    def test_a_sampling_gap_is_not_a_jump(self):
        """The API poll can stall (adb, UI isolate): a 2 s gap with a matching 2 s position step is real-time playback."""
        def gap(rows):
            for r in rows[120:]:
                r['t'] += 1.9
                r['pos'] += 1900
                r['uiPos'] += 1900
        self.assertEqual(self.names(self.swap(gap)), [])
        def gap_jump(rows):
            gap(rows)
            for r in rows[140:]:
                r['pos'] += 2000
        self.assertIn('xfadeJump', self.names(self.swap(gap_jump)))

    def test_freeze(self):
        def freeze(rows):
            for r in rows[60:90]:
                r['pos'] = rows[60]['pos']
        self.assertEqual(self.names(self.swap(freeze)), ['xfadeFrozen', 'xfadeJump'])  # the unfreeze is a 3 s step
        def short_freeze(rows):
            for r in rows[60:70]:
                r['pos'] = rows[60]['pos']
        self.assertNotIn('xfadeFrozen', self.names(self.swap(short_freeze)))

    @staticmethod
    def real_freeze(rows):
        """Real rows, fix r0 @13.22-14.62: the song flips to B, the display holds 0 for 1.5 s with proc=buffering, playing=True, cf active."""
        for r in rows[100:156]:
            r.update(proc='buffering', pos=0, uiPos=0, cf={'active': True})
        for r in rows[156:]:
            r.update(cf={'active': True})
        for i, r in enumerate(rows[100:], 0):
            r['t'] = 13.222 + i * 0.03  # dense enough: > 1.5 s of buffering

    def test_buffering_during_the_fade_counts_as_frozen(self):
        run = type('R', (), {'samples': self.swap(self.real_freeze), 'actions': [], 'trace': [], 'metrics': {}})()
        found = [v for v in engine.oracle_crossfade_long(run, self.IDS, self.FADE) if v['oracle'] == 'xfadeFrozen']
        self.assertTrue(found)

    def test_start_action_does_not_mask_the_freeze(self):
        """A 'start' never gets a 'ret' (start_queue sets one only for issue_seek), so its 15 s window hid the whole
        swap window; only seeks and navigations may mask."""
        run = type('R', (), {'samples': self.swap(self.real_freeze), 'actions': [{'kind': 'start', 't': 0.5}],
                             'trace': [], 'metrics': {}})()
        found = [v for v in engine.oracle_crossfade_long(run, self.IDS, self.FADE) if v['oracle'] == 'xfadeFrozen']
        self.assertTrue(found)

    def test_buffering_outside_a_fade_is_not_a_freeze(self):
        def stall(rows):
            for r in rows[100:156]:
                r.update(proc='buffering', pos=0, uiPos=0)
            for i, r in enumerate(rows[100:], 0):
                r['t'] = 13.222 + i * 0.03
        run = type('R', (), {'samples': self.swap(stall), 'actions': [], 'trace': [], 'metrics': {}})()
        self.assertNotIn('xfadeFrozen', [v['oracle'] for v in engine.oracle_crossfade_long(run, self.IDS, self.FADE)])

    def test_late_incoming_start(self):
        def late(rows):
            for r in rows[100:]:
                r['pos'] += 20000
                r['uiPos'] += 20000
        self.assertIn('xfadeLateStart', self.names(self.swap(late)))

    def test_persisted_position_follows_the_save_design(self):
        """Saves are events (the handoff 250 ms after the swap) plus a 15 s timer. Real P5 rows: saved 4366-4370 ms read 5.5 s
        after the swap while 9546 ms was shown is correct; a wrong index or another song's position is not."""
        end = self.swap()[-1]['pos']
        for saved in ({'index': 1, 'positionMs': 4368}, {'index': 1, 'positionMs': end - 2500}, {'index': 1, 'positionMs': end}):
            self.assertEqual(self.names(self.swap(), saved), [], saved)
        for saved in ({'index': 0, 'positionMs': 4975},               # base r1: saved the outgoing song's index
                      {'index': 1, 'positionMs': 299000},             # outgoing song's position under the incoming index
                      {'index': 1, 'positionMs': 2000},               # older than the swap
                      {'index': 1, 'positionMs': end + 5000}):        # ahead of the display
            self.assertEqual(self.names(self.swap(), saved), ['xfadePersistMismatch'], saved)

    def test_a_save_older_than_the_timer_period_must_have_been_refreshed(self):
        rows = self.swap()  # the swap is at t=20 s; the read at t=40 s, so a save from the swap (4100 ms) is 20 s old
        run = type('R', (), {'samples': rows, 'actions': [], 'trace': [], 'metrics': {}})()
        after = dict(rows[-1], t=40.0)
        stale = engine.oracle_crossfade_long(run, self.IDS, self.FADE, {'index': 1, 'positionMs': 4100}, after)
        self.assertEqual([v['oracle'] for v in stale], ['xfadePersistMismatch'])

    def test_seek_in_flight_is_not_a_jump(self):
        rows = self.swap(lambda r: [x.update(uiPos=x['uiPos'] + 5000) for x in r[30:]])
        run = type('R', (), {'samples': rows, 'actions': [{'kind': 'seek', 't': 12.9, 'ret': 13.1}], 'trace': [], 'metrics': {}})()
        self.assertEqual(engine.oracle_crossfade_long(run, self.IDS, self.FADE), [])


class AndroidCrossfadeSeed(unittest.TestCase):
    """An Android crossfade run seeds crossfade_enabled and the duration into the emulator profile (not crossfadeOff)."""
    def seeded(self, fade_s):
        import sqlite3
        db = sqlite3.connect(':memory:')
        db.executescript("CREATE TABLE server_config(url TEXT); INSERT INTO server_config VALUES('x');"
                         "CREATE TABLE app_settings(rolling_cache_budget_mb INT, crossfade_enabled INT DEFAULT 0, "
                         "crossfade_duration_seconds INT DEFAULT 5, gapless_enabled INT DEFAULT 0); INSERT INTO app_settings(rolling_cache_budget_mb) VALUES(1);"
                         "CREATE TABLE play_queue(id INT); CREATE TABLE play_queue_items(id INT);")
        with patch.object(engine, 'CROSSFADE_S', fade_s):
            engine.android_seed_edits(db, 'http://127.0.0.1:1')
        return db.execute('SELECT crossfade_enabled, crossfade_duration_seconds, gapless_enabled, rolling_cache_budget_mb FROM app_settings').fetchone()

    def test_crossfade_run_seeds_enabled_and_duration(self):
        self.assertEqual(self.seeded(4), (1, 4, 1, 160))

    def test_other_runs_keep_the_seed_settings(self):
        self.assertEqual(self.seeded(0), (0, 5, 0, 160))

    def test_crossfade_is_an_android_scenario(self):
        self.assertIn('crossfade', h.ANDROID_SCENARIOS)


class ActivePlayerPosition(unittest.TestCase):
    """Artefact 1: mediaKitTransport lists every native player in no fixed order; `pos` must follow the active one.
    Numbers are real rows of the 2026-10-28 repro (fix rep 0 and rep 2); the transport list order is reconstructed."""
    @staticmethod
    def ingest(transport, pp, offset=0):
        import time
        run = object.__new__(engine.Run)
        run.t0, run.w0, run.samples, run.trace, run._trace_seq = time.monotonic(), time.time(), [], [], 0
        run.ingest({'songId': 's', 'currentIndex': 1, 'playerPositionMs': pp, 'positionOffsetMs': offset, 'processingState': 'ready',
                    'native': {'mediaKitTransport': [{'positionMs': t} for t in transport]}})
        return run.samples[0]['pos']

    def test_retired_outgoing_player_listed_first(self):  # fix r0 @15.12: pos stuck 416 while the active player is at 4085
        self.assertEqual(self.ingest([416, 4085], 4085), 4085)

    def test_fresh_incoming_deck_listed_first_with_offset(self):  # fix r2 @7.82: pos 290000 (= 0 + offset) while the song is at 294315
        self.assertEqual(self.ingest([0, 4315], 294315, 290000), 294315)

    def test_single_player_and_missing_player_position_unchanged(self):
        self.assertEqual(self.ingest([1200], 1190), 1200)
        self.assertEqual(self.ingest([416, 4085], None), 416)


class RepeatFillOracle(unittest.TestCase):
    def test_loading_cursor_between_end_and_restart_does_not_hide_wrap(self):
        first = {'songId': 'a', 'dur': 300000}
        samples = [{'t': t, 'pos': pos, 'proc': proc, 'songId': 'a', 'idx': 0,
                    'mat': 1, 'deferred': 0, 'qlen': 15}
                   for t, pos, proc in [(10.9, 299541, 'ready'), (11.0, 292001, 'loading'),
                                        (11.1, 0, 'ready'), (11.2, 100, 'ready')]]
        run = Mock(metrics={}, samples=samples, checks=[])
        run.now.return_value = 0.0
        env = Mock()
        env.backend.fresh_artist.return_value = ('artist', ['a', 'b'])
        with contextlib.ExitStack() as stack:
            stack.enter_context(patch.object(engine, 'await_audio', return_value=first))
            stack.enter_context(patch.object(engine, 'issue_seek', return_value={'t': 0}))
            stack.enter_context(patch.object(engine, 'landed', return_value={'t': 0.0}))
            stack.enter_context(patch.object(engine, 'finish_futures'))
            stack.enter_context(patch.object(engine, 'violation', side_effect=lambda kind, *args: {'oracle': kind}))
            engine.case_repeat_one_fill(run, env)
            self.assertEqual(run.checks[0](), [])
            self.assertEqual(len(run.metrics['wraps']), 1)
            run.samples = [{**samples[0], 't': t, 'pos': position}
                           for t, position in [(10.5, 299000), (10.6, 0), (10.7, 299200)]] + samples
            self.assertEqual(run.checks[0](), [])
            self.assertEqual(len(run.metrics['wraps']), 1)
            # Missing and duplicate restarts must still fail.
            for variant, count in ((samples[2:], 0),
                                   (samples + [{**s, 't': s['t'] + 20} for s in samples], 2)):
                run.samples = variant
                self.assertEqual(run.checks[0](), [{'oracle': 'repeatOneRestartCount'}])
                self.assertEqual(len(run.metrics['wraps']), count)


class FixtureRepetitionSeed(unittest.TestCase):
    """M1: a repetition run as its own engine invocation (--rep-start) must not replay the previous repetition's songs."""

    @staticmethod
    def draw(rep_start):
        songs = [{'id': f's{i}', 'duration': 200, 'track': 2} for i in range(60)]
        library = Mock(duplicates={})
        library.sorted_songs.return_value = songs
        backend = engine.FixtureBackend('http://x', library, Mock(), rep_start=rep_start)
        return [s['id'] for s in backend.fresh_songs(5)]

    def test_reps_draw_different_songs_and_the_same_rep_draws_the_same_for_both_variants(self):
        draws = [self.draw(rep) for rep in range(3)]
        self.assertEqual(len({tuple(d) for d in draws}), 3)
        self.assertEqual(self.draw(1), self.draw(1))  # base and fix each start their own backend at the same rep
        self.assertEqual(self.draw(0), [s for s in self.draw(0)])
        library = Mock(duplicates={})
        library.sorted_songs.return_value = [{'id': f's{i}', 'duration': 200, 'track': 2} for i in range(60)]
        legacy = engine.FixtureBackend('http://x', library, Mock())  # one invocation (Android) keeps its seed
        self.assertEqual([s['id'] for s in legacy.fresh_songs(5)], self.draw(0))


class RepeatFillDuration(unittest.TestCase):
    """Row 26: repeat_one_fill needs a known duration, disjoint wrap windows and exactly one intended loop."""

    @staticmethod
    def sample(t, pos, dur):
        return {'t': t, 'pos': pos, 'proc': 'ready', 'songId': 'a', 'idx': 0, 'mat': 1, 'deferred': 0, 'qlen': 15, 'dur': dur}

    def play(self, first_dur, samples, known=None, land_t=0.0, now=0.0):
        """Runs case_repeat_one_fill; returns (run, issue_seek mock, violations of the check)."""
        first = {'songId': 'a', 'dur': first_dur}
        run = self.run = Mock(metrics={}, samples=samples, checks=[], violations=[])
        run.last.return_value = {'dur': first_dur}
        run.until.return_value = known
        run.now.return_value = now
        env = Mock()
        env.backend.fresh_artist.return_value = ('artist', ['a', 'b'])
        with contextlib.ExitStack() as stack:
            stack.enter_context(patch.object(engine, 'await_audio', return_value=first))
            seek = stack.enter_context(patch.object(engine, 'issue_seek', return_value={'t': 0}))
            stack.enter_context(patch.object(engine, 'landed', return_value=None if land_t is None else {'t': land_t}))
            stack.enter_context(patch.object(engine, 'finish_futures'))
            stack.enter_context(patch.object(engine, 'violation', side_effect=lambda kind, *args: {'oracle': kind}))
            engine.case_repeat_one_fill(run, env)
            return run, seek, run.checks[0]()

    def test_zero_duration_at_start_waits_for_the_known_duration(self):
        run, seek, out = self.play(0, [self.sample(10.9, 299541, 300000), self.sample(11.1, 0, 300000), self.sample(11.2, 100, 300000)],
                                   known={'dur': 300000})
        self.assertEqual(seek.call_args[0][2], 292000)  # never a seek to 0 because the duration was not known yet
        self.assertEqual(run.observe.call_args[0][0], 25.0)
        self.assertEqual(out, [])
        with self.assertRaises(engine.CaseAbort):
            self.play(0, [], known=None)  # the duration never became known: no verdict from a made-up 0
        self.assertEqual(self.run.violations, [{'oracle': 'caseError'}])  # and the aborted cell is a recorded failure, not a pass

    def test_true_five_second_loop_counts_exactly_one_restart(self):
        positions = lambda end: [self.sample(round(i * 0.1, 1), (i * 100) % 5000, 5000) for i in range(int(end * 10))]
        run, seek, out = self.play(5000, positions(7.5))
        self.assertEqual(seek.call_args[0][2], 0)
        self.assertEqual(run.observe.call_args[0][0], 7.5)  # a second loop would start at 10 s
        self.assertEqual(out, [])
        self.assertEqual(len(run.metrics['wraps']), 1)
        run, _, out = self.play(5000, positions(12.0))  # a window that holds two loops must not pass as one
        self.assertEqual(out, [{'oracle': 'repeatOneRestartCount'}])
        self.assertEqual(len(run.metrics['wraps']), 2)
        run, _, out = self.play(5000, positions(4.9))  # and a real missing restart still fails
        self.assertEqual(out, [{'oracle': 'repeatOneRestartCount'}])

    def test_observation_is_measured_from_the_observed_landing(self):
        # the second loop of a 5 s song starts 10 s after the landing: a slow landing/API return must not push the window past it
        run, _, _ = self.play(5000, [], land_t=1.0, now=3.0)
        self.assertEqual(run.observe.call_args[0][0], 5.5)  # lands at 1.0 s, window ends 7.5 s later, 3.0 s are already spent
        run, _, _ = self.play(5000, [], land_t=None, now=3.0)  # never observed landing: the full window from now
        self.assertEqual(run.observe.call_args[0][0], 7.5)

    def test_wrap_windows_are_disjoint_per_duration_and_clips_too_short_to_loop_abort(self):
        self.assertEqual(engine.repeat_wrap_bounds(300000), (296000, 3000))
        self.assertEqual(engine.repeat_wrap_bounds(5000), (2500, 2500))
        for dur in (3000, 5000, 8000, 300000):
            end_from, start_to = engine.repeat_wrap_bounds(dur)
            self.assertLessEqual(start_to, end_from)
        with self.assertRaises(engine.CaseAbort):
            self.play(2000, [])
        self.assertEqual(self.run.violations, [{'oracle': 'caseError'}])

    def test_a_three_second_fixture_song_reported_as_2_99_s_is_still_observable(self):
        self.assertEqual(engine.REPEAT_FILL_MIN_MS, 2500)
        for dur in (2990, 2500):
            run, _, _ = self.play(dur, [])  # no abort, no caseError
            self.assertEqual(run.violations, [], dur)
            self.assertLess(run.observe.call_args[0][0], 2 * dur / 1000)  # still before a second loop
        with self.assertRaises(engine.CaseAbort):
            self.play(2400, [])


class RepeatClockBlip(unittest.TestCase):
    def fixture(self):
        samples = [{'t': t, 'pos': position, 'proc': 'ready', 'songId': 'a', 'idx': 0, 'off': 0}
                   for t, position in [(39.9, 294430), (40.0, 0), (40.1, 294454),
                                       (45.9, 299600), (46.0, 0), (46.1, 100),
                                       (50.0, 4000), (54.0, 8000), (345.9, 299600),
                                       (346.0, 0), (350.0, 4000)]]
        env = Mock()
        env.backend.fresh_songs.return_value = [{'id': 'a', 'duration': 300}]
        env.proxy.log = []
        run = Mock(metrics={}, samples=samples, checks=[], violations=[], env=env,
                   proxy_mark=0, w0=0, quality='opus128', deadlines={'advance': 30})
        run.until.side_effect = lambda predicate, timeout: next((s for s in run.samples if predicate(s)), None)
        return run, env

    def test_offset_repeat_waits_for_a_real_wrap(self):
        run, env = self.fixture()
        with contextlib.ExitStack() as stack:
            for name in ['offset_case_prologue', 'start_single', 'landed', 'finish_futures']:
                stack.enter_context(patch.object(engine, name))
            stack.enter_context(patch.object(engine, 'issue_seek', return_value={'t': 0}))
            stack.enter_context(patch.object(engine, 'oracle_seek', return_value=[]))
            stack.enter_context(patch.object(engine, 'oracle_offset', return_value=[]))
            stack.enter_context(patch.object(engine, 'violation', side_effect=lambda kind, *args: {'oracle': kind}))
            engine.case_offset_repeat_one(run, env)
            self.assertEqual(run.checks[0](), [])
            self.assertEqual(run.metrics['loopWrappedAt'], 46)
            self.assertEqual(run.metrics['loop2WrappedAt'], 346)

    def test_plain_repeat_waits_for_a_real_wrap(self):
        run, env = self.fixture()
        with patch.object(engine, 'start_single'):
            engine.case_base_repeat_one(run, env)
        self.assertEqual(run.metrics['wrap1'], 46)
        self.assertEqual(run.metrics['wrap2'], 346)

    def test_a_blip_without_a_real_loop_still_fails(self):
        run, env = self.fixture()
        run.samples = run.samples[:3]
        with patch.object(engine, 'start_single'), \
                patch.object(engine, 'violation', side_effect=lambda kind, *args: {'oracle': kind}):
            engine.case_base_repeat_one(run, env)
        self.assertEqual(run.violations, [{'oracle': 'baselineNoLoop'}])


class PairedRepetitions(unittest.TestCase):
    """Rows 24/29: base and fix alternate rep by rep (first variant swapping on every other pair), one merged
    evidence record per variant and scenario, thresholds and cell counts unchanged."""

    def test_schedule_alternates_pairs_and_swaps_the_first_variant(self):
        steps = h.schedule(['seek', 'crossfade'], lambda name: 3)
        self.assertEqual(steps[:6], [('base', 'seek', 0), ('fix', 'seek', 0), ('fix', 'seek', 1),
                                     ('base', 'seek', 1), ('base', 'seek', 2), ('fix', 'seek', 2)])
        self.assertEqual(steps[6:8], [('fix', 'crossfade', 0), ('base', 'crossfade', 0)])  # the second scenario starts with the other variant
        quick = h.schedule(['a', 'b', 'c'], lambda name: 1)  # reps=1 (the default quick run) still alternates across scenarios
        self.assertEqual([v for v, _, _ in quick], ['base', 'fix', 'fix', 'base', 'base', 'fix'])
        self.assertEqual(len(steps), len(set(steps)), 'every (variant, scenario, rep) exactly once')
        self.assertEqual(h.schedule(['seek'], lambda name: 1), [('base', 'seek', 0), ('fix', 'seek', 0)])

    def test_engine_runs_one_rep_at_its_own_index(self):
        import json
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            seen = []
            def fake_engine(args, env, folder, extra, timeout, label):
                seen.append(args)
                (folder / f'{label}.log').write_text('log')
                run = folder / 'runs' / f'stamp-{label}'
                run.mkdir(parents=True)
                rows = [dict(zip(('case', 'quality', 'throttle', 'rep'), c), metrics={}, violations=[], latencyS=None, passed=True)
                        for c in h.expected_cells('queue-edit', False, 3, 'linux') if c[3] == 2]
                (run / 'report.json').write_text(json.dumps({'results': rows}))
                return Mock(returncode=0)
            with patch.object(h, 'engine', side_effect=fake_engine):
                rows, _ = h.run_scenario('queue-edit', 'linux', out, {}, None, None, False, 3, False, rep=2)
            self.assertEqual({r['rep'] for r in rows}, {2})
            args = seen[0]
            self.assertEqual(args[args.index('--reps') + 1], '1')
            self.assertEqual(args[args.index('--rep-start') + 1], '2')
            self.assertEqual({tuple(c) for c in json.loads((out / 'evidence.json').read_text())['expected']},
                             {tuple(c) for c in h.expected_cells('queue-edit', False, 3, 'linux') if c[3] == 2})

    def test_engine_rep_numbers_start_at_the_requested_index(self):
        self.assertEqual(list(engine.matrix_reps('seek_far', 3, 0, 0)), [0, 1, 2])
        self.assertEqual(list(engine.matrix_reps('seek_far', 1, 0, 2)), [2])
        self.assertEqual(list(engine.matrix_reps('shuffle_album', 3, 2, 1)), [1, 2])

    def ab(self, fail_at=None, reps=3, platform='linux', scenarios=('queue-edit',), full=False, guests=None):
        """Runs cmd_ab for queue-edit on Linux against a fake engine; returns (exit/exception, evidence dir, calls)."""
        import argparse
        import json
        calls = []
        root_ctx = tempfile.TemporaryDirectory()
        self.addCleanup(root_ctx.cleanup)
        root = Path(root_ctx.name)
        artifact = root / 'bundle'
        artifact.write_text('bundle')
        def scenario(name, platform, variant_dir, display_env, serial, apk, full, nreps, real, rep=None):
            parts = variant_dir.parts
            calls.append((parts[-4], parts[-3], int(parts[-2].split('-')[1])) if parts[-2].startswith('rep-')
                         else (parts[-3], parts[-2], None))
            if fail_at is not None and len(calls) == fail_at:
                raise h.InfraError('engine died')
            variant_dir.mkdir(parents=True, exist_ok=True)
            cells = [c for c in h.expected_cells(name, full, nreps, platform) if rep is None or c[3] == rep]
            rows = [dict(zip(('case', 'quality', 'throttle', 'rep'), c), id=i, metrics={}, violations=[], latencyS=None, passed=True)
                    for i, c in enumerate(cells, 1)]  # the engine numbers rows from 1 in every invocation
            (variant_dir / f'{name}.log').write_text(f'engine log {parts[-4]} rep {rep}')
            report = variant_dir / 'report.json'
            report.write_text(json.dumps({'results': rows}))
            h.write_evidence(variant_dir, {'status': 'complete', 'exitCode': 0, 'expected': cells, 'observed': cells, 'seconds': 1.0,
                                           'log': str(variant_dir / f'{name}.log'), 'report': str(report)})
            return rows, 1.0
        identity = {'head': 'headsha', 'sha256': 'a'}
        def git(*a, **k):
            return 'headsha' if a[:2] == ('rev-parse', 'HEAD') else ('basesha' if a[0] == 'rev-parse' else '')
        args = argparse.Namespace(fn=h.cmd_ab, command='ab', scenarios=list(scenarios), map=False, all=False, platform=platform,
                                  base='ref', base_range='r...HEAD', full=full, reps=reps, real=False, output=str(root / 'out'))
        class Guest:  # a fake Emulator that only counts boots
            def __init__(self, out):
                guests.append(out) if guests is not None else None
                self.proc = Mock(poll=Mock(return_value=None))
            def check(self): pass
            def __enter__(self): return 'emulator-5620'
            def __exit__(self, *_): pass
        with patch.object(h, 'PROJECT', root), patch.object(h, 'candidate_identity', return_value=identity), \
                patch.object(h, 'Emulator', Guest), patch.object(h, 'seed_android', return_value=root), \
                patch.object(h, 'environment_identity', return_value={}), patch.object(h, 'heavy_lock', return_value=contextlib.nullcontext(())), \
                patch.object(h, 'git', side_effect=git), patch.object(h, 'run', return_value=Mock(returncode=0)), \
                patch.object(h, 'flutter_version', return_value='Flutter test'), patch.object(h, 'downloads_snapshot', return_value={}), \
                patch.object(h, 'base_build', return_value=(root, 'cached')), patch.object(h, 'fix_build', return_value=root), \
                patch.object(h, 'artifact_of', return_value=artifact), patch.object(h, 'activate'), \
                patch.object(h, 'Display', return_value=contextlib.nullcontext({})), patch.object(h, 'run_scenario', side_effect=scenario), \
                contextlib.redirect_stdout(io.StringIO()):
            try:
                code = h.cmd_ab(args)
            except h.InfraError as error:
                code = error
        return code, root / 'out', calls

    def test_ab_interleaves_and_keeps_one_verified_evidence_record_per_variant(self):
        import json
        code, out, calls = self.ab()
        self.assertEqual(code, 0)
        self.assertEqual(calls, h.schedule(['queue-edit'], lambda name: 3))
        record = json.loads((out / 'evidence.json').read_text())
        self.assertEqual(record['status'], 'passed')  # cmd_ab verifies the merged records before it promotes a pass
        cells = h.expected_cells('queue-edit', False, 3, 'linux')
        for variant in ('base', 'fix'):
            merged = record['variants'][f'{variant}/queue-edit']
            self.assertEqual((merged['status'], merged['exitCode'], merged['expected'], merged['observed']), ('complete', 0, cells, cells))
            merged_rows = json.loads(Path(merged['report']).read_text())['results']
            self.assertEqual(len(merged_rows), len(cells))
            ids = [r['id'] for r in merged_rows]
            self.assertEqual(len(set(ids)), len(ids), 'row ids stay unique across repetitions (trace files are named by id)')
            self.assertTrue(all(r['repDir'].endswith(f"rep-{r['rep']}/attempt-1") for r in merged_rows))
            self.assertEqual(Path(merged['log']).read_text().count('engine log'), 3)

    def test_android_runs_one_guest_per_variant_and_scenario_with_alternating_first_variant(self):
        import json
        guests = []
        names = ('queue-edit', 'stress-drag', 'repeat')
        with patch.object(h, 'evaluate', return_value=[(True, 'ok')]):  # these rows carry no metrics; thresholds are not under test
            code, out, calls = self.ab(platform='android', scenarios=names, full=True, reps=None, guests=guests)
        self.assertEqual(code, 0)
        self.assertEqual(calls, [('base', 'queue-edit', None), ('fix', 'queue-edit', None), ('fix', 'stress-drag', None),
                                 ('base', 'stress-drag', None), ('base', 'repeat', None), ('fix', 'repeat', None)])
        guests = [g for g in guests if g != Path('.')]  # _cmd_ab builds one Emulator only to check the tools exist
        self.assertEqual(len(guests), 2 * len(names), 'a full Android A/B starts exactly 2 guests per scenario')
        self.assertEqual(h.android_schedule(['a', 'b']), [('base', 'a', None), ('fix', 'a', None), ('fix', 'b', None), ('base', 'b', None)])
        record = json.loads((out / 'evidence.json').read_text())
        self.assertEqual(record['status'], 'passed')  # the unmerged per-scenario evidence verifies like the Linux merged one
        for name in names:
            cells = h.expected_cells(name, True, None, 'android')
            for variant in ('base', 'fix'):
                merged = record['variants'][f'{variant}/{name}']
                self.assertEqual((merged['status'], merged['observed']), ('complete', cells))

    def test_ab_failure_midway_leaves_incomplete_evidence_for_started_variants(self):
        import json
        code, out, calls = self.ab(fail_at=3)
        self.assertIsInstance(code, h.InfraError)
        record = json.loads((out / 'evidence.json').read_text())
        self.assertNotEqual(record['status'], 'passed')
        base = record['variants']['base/queue-edit']
        self.assertEqual((base['status'], len(base['observed'])), ('incomplete', 3))
        self.assertEqual(record['variants']['fix/queue-edit']['status'], 'incomplete')


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
        output = Path(self.tmp.name) / f'run-{len(list(Path(self.tmp.name).glob("run-*")))}'  # never the real worktree
        with contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
            code = h.main(['ab', *args, '--output', str(output)])
        return code, err.getvalue()

    def test_bad_arguments_fail_before_the_lock_and_leave_no_evidence(self):
        for arguments in (['--platform', 'linux'], ['nonsense', '--platform', 'linux'], ['seek', '--platform', 'android', '--base', 'HEAD']):
            with self.subTest(arguments=arguments), patch.object(h, 'heavy_lock', side_effect=AssertionError('lock taken')):
                code, err = self.ab(*arguments)
                self.assertEqual(code, 2)
                self.assertNotIn('busy', err)
                self.assertFalse(list(Path(self.tmp.name).glob('run-*/evidence.json')))

    def test_uncaught_exception_is_exit_2_with_traceback(self):
        from contextlib import nullcontext
        with patch.object(h, 'heavy_lock', return_value=nullcontext(())), patch.object(h, 'candidate_identity', return_value={'head': 'h'}), \
                patch.object(h, '_cmd_ab', side_effect=KeyError('boom')):
            code, err = self.ab('--all', '--platform', 'linux')
        self.assertEqual(code, 2)
        self.assertIn('Traceback', err)
        self.assertIn("KeyError: 'boom'", err)

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


class DurableEvidence(unittest.TestCase):
    def test_full_counts(self):
        self.assertEqual(sum(len(h.expected_cells(n, True, None, 'linux')) for n in h.SCENARIOS), 124)
        self.assertEqual(sum(len(h.expected_cells(n, True, None, 'android')) for n in h.ANDROID_SCENARIOS), 88)

    def test_exact_cells(self):
        expected = h.expected_cells('queue-edit', False, None, 'linux')
        h.validate_cells(expected, expected)
        for wrong in (expected[:-1], expected[:-1] + expected[:1], expected + expected[:1],
                      [cell[:2] + ['wrong', cell[3]] for cell in expected]):
            with self.assertRaises(h.InfraError):
                h.validate_cells(expected, wrong)

    def test_source_identity_tracks_bytes_modes_untracked_and_ignores(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def git(*args):
                return h.git(*args, cwd=root)
            git('init', '-q')
            git('config', 'user.email', 'test@example.invalid')
            git('config', 'user.name', 'Test')
            (root / '.gitignore').write_text('ignored\n')
            (root / 'source').write_text('a')
            git('add', '.')
            git('commit', '-qm', 'fixture')
            first = h.candidate_identity(root)
            (root / 'ignored').write_text('secret')
            self.assertEqual(first, h.candidate_identity(root))
            (root / 'source').write_text('b')
            self.assertNotEqual(first, h.candidate_identity(root))
            (root / 'source').write_text('a')
            (root / 'source').chmod(0o755)
            self.assertNotEqual(first, h.candidate_identity(root))
            (root / 'source').chmod(0o644)
            (root / 'source').unlink()
            self.assertNotEqual(first, h.candidate_identity(root))
            (root / 'source').write_text('a')
            (root / 'new').write_text('new')
            self.assertNotEqual(first, h.candidate_identity(root))
            self.assertNotIn('secret', str(h.candidate_identity(root)))

    def test_source_identity_excludes_only_the_progress_log(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def git(*args):
                return h.git(*args, cwd=root)
            git('init', '-q')
            git('config', 'user.email', 'test@example.invalid')
            git('config', 'user.name', 'Test')
            (root / 'docs/project').mkdir(parents=True)
            (root / 'docs/project/progress.md').write_text('log')
            (root / 'docs/project/other.md').write_text('log')
            git('add', '.')
            git('commit', '-qm', 'fixture')
            first = h.candidate_identity(root)
            (root / 'docs/project/progress.md').write_text('log\nrecorded evidence')
            self.assertEqual(first, h.candidate_identity(root))
            git('add', 'docs/project/progress.md')
            self.assertEqual(first, h.candidate_identity(root))
            (root / 'docs/project/other.md').write_text('changed')
            self.assertNotEqual(first, h.candidate_identity(root))

    def test_engine_failure_timeout_partial_and_malformed_are_durable(self):
        import json
        import subprocess
        for fault in ('exit', 'timeout', 'timeout-partial', 'interrupt', 'missing', 'malformed', 'partial', 'duplicate', 'wrong', 'missing-log', 'multiple'):
            with self.subTest(fault=fault), tempfile.TemporaryDirectory() as directory:
                out = Path(directory)
                def engine(*args, **kwargs):
                    if fault != 'missing-log':
                        (out / 'queue-edit.log').write_text('log')
                    if fault == 'timeout':
                        raise subprocess.TimeoutExpired('engine', 1)
                    if fault == 'interrupt':
                        raise KeyboardInterrupt()
                    if fault != 'missing':
                        folder = out / 'runs' / 'stamp-queue-edit'
                        folder.mkdir(parents=True)
                        cells = h.expected_cells('queue-edit', False, None, 'linux')
                        if fault in ('partial', 'timeout-partial'):
                            cells = cells[:-1]
                        if fault == 'duplicate':
                            cells[-1] = cells[0]
                        if fault == 'wrong':
                            cells[0][0] = 'wrong'
                        rows = [dict(zip(('case', 'quality', 'throttle', 'rep'), c),
                                     metrics={}, violations=[], latencyS=None, passed=True) for c in cells]
                        (folder / 'report.json').write_text('{' if fault == 'malformed' else json.dumps({'results': rows}))
                    if fault == 'timeout-partial':
                        raise subprocess.TimeoutExpired('engine', 1)
                    if fault == 'multiple':
                        second = out / 'runs' / 'second-queue-edit'
                        second.mkdir()
                        (second / 'report.json').write_text('{}')
                    return Mock(returncode=2 if fault == 'exit' else 0)
                with patch.object(h, 'engine', side_effect=engine):
                    with self.assertRaises((h.InfraError, KeyboardInterrupt)):
                        h.run_scenario('queue-edit', 'linux', out, {}, None, None, False, None, False)
                record = json.loads((out / 'evidence.json').read_text())
                self.assertNotEqual(record['status'], 'complete')
                self.assertIn('seconds', record)
                if fault == 'timeout-partial':
                    self.assertEqual(record['status'], 'timeout')
                    self.assertEqual(len(record['observed']), 2)

    def test_complete_report_and_contradictory_exit(self):
        import json
        for code, passed, allowed in ((0, True, True), (1, False, True), (1, True, False), (0, False, False)):
            with self.subTest(code=code, passed=passed), tempfile.TemporaryDirectory() as directory:
                out = Path(directory)
                def engine(*args, **kwargs):
                    (out / 'queue-edit.log').write_text('log')
                    folder = out / 'runs' / 'stamp-queue-edit'
                    folder.mkdir(parents=True)
                    rows = [dict(zip(('case', 'quality', 'throttle', 'rep'), c), metrics={},
                                 violations=[] if passed else [{'oracle': 'stall'}], latencyS=None, passed=passed)
                            for c in h.expected_cells('queue-edit', False, None, 'linux')]
                    (folder / 'report.json').write_text(json.dumps({'results': rows}))
                    return Mock(returncode=code)
                with patch.object(h, 'engine', side_effect=engine):
                    if allowed:
                        rows, seconds = h.run_scenario('queue-edit', 'linux', out, {}, None, None, False, None, False)
                        self.assertEqual(len(rows), 3)
                    else:
                        with self.assertRaises(h.InfraError):
                            h.run_scenario('queue-edit', 'linux', out, {}, None, None, False, None, False)

    def test_cell_verdict_must_agree_with_violations(self):
        row = dict(case='queue_reorder', quality='opus128', throttle='wan6000', rep=0,
                   metrics={}, latencyS=None)
        for passed, violations in ((False, []), (True, [{'oracle': 'stall'}]), (False, [{}])):
            with self.subTest(passed=passed, violations=violations), self.assertRaises(h.InfraError):
                h.observed_cells([{**row, 'passed': passed, 'violations': violations}])

    def test_build_exit_and_interruption_records_without_building(self):
        import json
        for fault in ('exit', 'interrupt'):
            with self.subTest(fault=fault), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                with patch.object(h, 'DATA', root / 'data'), \
                        patch.object(h, 'bounded_command', return_value=Mock(returncode=7),
                                     side_effect=KeyboardInterrupt() if fault == 'interrupt' else None):
                    with self.assertRaises((h.InfraError, KeyboardInterrupt)):
                        h.build(root, 'android', root / 'artifact', root / 'build.log')
                record = json.loads((root / 'build.result.json').read_text())
                self.assertEqual(record['exitCode'], 7 if fault == 'exit' else None)
                self.assertNotEqual(record['status'], 'complete')

    def test_ab_finalizes_and_verifies_complete_evidence(self):
        import argparse
        import json
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            identity = {'head': 'head', 'sha256': 'a'}
            args = argparse.Namespace(fn=h.cmd_ab, full=False, reps=None, platform='linux')
            def complete(args, out, evidence):
                evidence.update(base='base', flutter='Flutter test')
                evidence['config'].update(names=['queue-edit'], baseSha='base', flutter='Flutter test')
                for variant in ('base', 'fix'):
                    folder = out / variant / 'queue-edit' / 'attempt-1'
                    folder.mkdir(parents=True)
                    log, report = folder / 'queue-edit.log', folder / 'report.json'
                    log.write_text('engine log')
                    cells = h.expected_cells('queue-edit', False, None, 'linux')
                    report.write_text(json.dumps({'results': [dict(zip(('case', 'quality', 'throttle', 'rep'), c),
                                      metrics={}, violations=[], latencyS=None, passed=True) for c in cells]}))
                    h.write_evidence(folder, {'status': 'complete', 'exitCode': 0, 'expected': cells, 'observed': cells,
                                              'log': str(log), 'report': str(report)})
                    evidence['variants'][variant + '/queue-edit'] = {'status': 'not-run'}
                evidence['baseArtifact'] = {'path': str(log), 'sha256': h.sha256(log)}
                (out / 'comparison.json').write_text(json.dumps({'base': 'base', 'fix': 'head', 'platform': 'linux',
                                                               'scenarios': {'queue-edit': {}}}))
                (out / 'summary.md').write_text('# detail\n\nRESULT UNVERIFIED\n')
                return 0
            with patch.object(h, 'PROJECT', root), patch.object(h, 'candidate_identity', return_value=identity), \
                    patch.object(h, '_cmd_ab', side_effect=complete), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(h.cmd_ab(args), 0)
            record = json.loads(next(root.glob('build/harness/*/evidence.json')).read_text())
            self.assertEqual(record['status'], 'passed')
            self.assertEqual(len(record['variants']), 2)
            summary = next(root.glob('build/harness/*/summary.md'))
            self.assertIn('RESULT PASS', summary.read_text())
            self.assertNotIn('UNVERIFIED', summary.read_text())
            self.assertEqual(record['artifacts'][str(summary)], h.sha256(summary))
            self.assertFalse(list(summary.parent.glob('*.tmp')))

    def test_ab_persists_interruption_and_changed_source(self):
        import argparse
        import json
        for fault in ('interrupt', 'source'):
            with self.subTest(fault=fault), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                args = argparse.Namespace(fn=h.cmd_ab)
                identity = {'head': 'head', 'sha256': 'a'}
                identities = [identity, {**identity, 'sha256': 'b'}] if fault == 'source' else [identity, identity]
                with patch.object(h, 'PROJECT', root), patch.object(h, 'candidate_identity', side_effect=identities), \
                        patch.object(h, '_cmd_ab', side_effect=KeyboardInterrupt() if fault == 'interrupt' else None, return_value=0):
                    with contextlib.redirect_stdout(io.StringIO()), self.assertRaises((KeyboardInterrupt, h.InfraError)):
                        h.cmd_ab(args)
                record = json.loads(next(root.glob('build/harness/*/evidence.json')).read_text())
                self.assertNotEqual(record['status'], 'passed')
                self.assertEqual(record['exitCode'], 2)

    def test_verify_rejects_stale_incomplete_and_missing_artifacts(self):
        import json
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            config = {'names': ['queue-edit'], 'full': False, 'reps': None, 'platform': 'linux',
                      'baseSha': 'base', 'flutter': 'Flutter test'}
            cells = h.expected_cells('queue-edit', False, None, 'linux')
            log, report = out / 'run.log', out / 'report.json'
            for p in (log, report, out / 'comparison.json', out / 'summary.md'):
                p.write_text('{}')
            report.write_text(json.dumps({'results': [dict(zip(('case', 'quality', 'throttle', 'rep'), c),
                              metrics={}, violations=[], latencyS=None, passed=True) for c in cells]}))
            (out / 'comparison.json').write_text(json.dumps({'base': 'base', 'fix': 'head', 'platform': 'linux',
                                                           'scenarios': {'queue-edit': {}}}))
            record = {'base': 'base', 'flutter': 'Flutter test',
                      'baseArtifact': {'path': str(log), 'sha256': h.sha256(log)},
                      'schema': 1, 'status': 'passed', 'exitCode': 0, 'candidate': {'sha256': 'a', 'head': 'head'},
                      'candidateAfter': {'sha256': 'a', 'head': 'head'}, 'environment': {}, 'config': config,
                      'variants': {v + '/queue-edit': {'status': 'complete', 'exitCode': 0, 'expected': cells,
                                   'observed': cells, 'log': str(log), 'report': str(report)} for v in ('base', 'fix')},
                      'artifacts': {str(p): h.sha256(p) for p in out.iterdir()}}
            h.write_evidence(out, record)
            h.verify_evidence(out, record['candidate'], {}, config)
            with self.assertRaises(h.InfraError):
                h.verify_evidence(out, {'sha256': 'changed'}, {}, config)
            for field, value in (('status', 'incomplete'), ('variants', {}), ('variants', []), ('artifacts', {}), ('artifacts', [])):
                changed = {**record, field: value}
                h.write_evidence(out, changed)
                with self.assertRaises(h.InfraError):
                    h.verify_evidence(out, record['candidate'], {}, config)
            h.write_evidence(out, record)
            with self.assertRaises(h.InfraError):
                h.verify_evidence(out, record['candidate'], {'changed': True}, config)
            with self.assertRaises(h.InfraError):
                h.verify_evidence(out, record['candidate'], {}, {**config, 'full': True})
            report.write_text('corrupt')
            with self.assertRaises(h.InfraError):
                h.verify_evidence(out, record['candidate'], {}, config)
            report.unlink()
            with self.assertRaises(h.InfraError):
                h.verify_evidence(out, record['candidate'], {}, config)
            (out / 'evidence.json').write_text('{')
            with self.assertRaises(h.InfraError):
                h.verify_evidence(out, {}, {}, config)


if __name__ == '__main__':
    unittest.main()
