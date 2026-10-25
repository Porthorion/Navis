#!/usr/bin/env python3
"""Self-check for tool/playback_harness.py (stdlib only, no builds or emulators): python3 tool/playback_harness_test.py"""

import contextlib
import io
import os
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch
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


class RepeatFillOracle(unittest.TestCase):
    def test_loading_cursor_between_end_and_restart_does_not_hide_wrap(self):
        first = {'songId': 'a', 'dur': 300000}
        samples = [{'t': t, 'pos': pos, 'proc': proc, 'songId': 'a', 'idx': 0,
                    'mat': 1, 'deferred': 0, 'qlen': 15}
                   for t, pos, proc in [(10.9, 299541, 'ready'), (11.0, 292001, 'loading'),
                                        (11.1, 0, 'ready'), (11.2, 100, 'ready')]]
        run = Mock(metrics={}, samples=samples, checks=[])
        env = Mock()
        env.backend.fresh_artist.return_value = ('artist', ['a', 'b'])
        with contextlib.ExitStack() as stack:
            stack.enter_context(patch.object(engine, 'await_audio', return_value=first))
            stack.enter_context(patch.object(engine, 'issue_seek', return_value={'t': 0}))
            stack.enter_context(patch.object(engine, 'landed'))
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
