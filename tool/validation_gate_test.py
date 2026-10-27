#!/usr/bin/env python3
"""Small tooling checks only: no Flutter, builds, devices or runtime matrices."""
import argparse
from contextlib import nullcontext, redirect_stdout
import fcntl
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

# Hermetic: never touch the real heavy-job locks or harness cache, whatever HOME is.
_ISOLATED = tempfile.TemporaryDirectory(prefix='navis-selfcheck-')
os.environ['NAVIS_HARNESS_CACHE'] = str(Path(_ISOLATED.name) / 'cache')
import heavy_lock as locks
locks.HEAVY_LOCK = Path(_ISOLATED.name) / 'heavy.lock'
locks.LEGACY_LOCK = Path(_ISOLATED.name) / 'legacy' / 'lock'
import playback_harness as h


class Ownership(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.patch = patch.object(locks, 'HEAVY_LOCK', self.root / 'heavy.lock')
        self.patch.start()
        self.addCleanup(self.patch.stop)
        self.cache = self.root / 'cache'
        self.legacy_patch = patch.object(locks, 'LEGACY_LOCK', self.cache / 'lock')
        self.legacy_patch.start()
        self.addCleanup(self.legacy_patch.stop)

    def child(self, descriptors=()):
        code = (f'import sys; sys.path.insert(0, {str(Path(__file__).parent)!r}); '
                f'import heavy_lock as h; from pathlib import Path; '
                f'h.HEAVY_LOCK=Path({str(locks.HEAVY_LOCK)!r}); '
                f'h.LEGACY_LOCK=Path({str(locks.LEGACY_LOCK)!r}); '
                f'c=h.heavy_lock("child", Path({str(self.cache)!r})); c.__enter__()')
        return subprocess.run([sys.executable, '-c', code], pass_fds=descriptors,
                              capture_output=True, text=True, timeout=5)

    def test_contention_and_verified_nesting(self):
        with locks.heavy_lock('evidence/run-1', self.cache) as descriptors:
            busy = self.child()
            self.assertNotEqual(busy.returncode, 0)
            self.assertIn('evidence/run-1', busy.stderr)
            self.assertIn('lslocks', busy.stderr)  # the recorded pid may be dead while a child holds the lock
            self.assertEqual(self.child(descriptors).returncode, 0)
            with locks.heavy_lock('nested', self.cache) as nested:
                self.assertEqual(nested, descriptors)
            self.assertNotEqual(self.child().returncode, 0)
        self.assertEqual(self.child().returncode, 0)

    def test_legacy_cache_and_outer_flock(self):
        self.cache.mkdir()
        with (self.cache / 'lock').open('w') as old:
            fcntl.flock(old, fcntl.LOCK_EX)
            self.assertNotEqual(self.child().returncode, 0)
            with locks.heavy_lock('outer compatibility', self.cache) as descriptors:
                self.assertIn(old.fileno(), descriptors)
        with locks.HEAVY_LOCK.open('w') as outer:
            fcntl.flock(outer, fcntl.LOCK_EX)
            with locks.heavy_lock('outer', self.cache) as descriptors:
                self.assertIn(outer.fileno(), descriptors)

    def test_custom_cache_still_conflicts_with_default_legacy_owner(self):
        custom = self.root / 'custom'
        with locks.heavy_lock('default owner', self.cache):
            code = (f'import sys; sys.path.insert(0, {str(Path(__file__).parent)!r}); '
                    f'import heavy_lock as h; from pathlib import Path; '
                    f'h.HEAVY_LOCK=Path({str(self.root / "different-global")!r}); '
                    f'h.LEGACY_LOCK=Path({str(locks.LEGACY_LOCK)!r}); '
                    f'c=h.heavy_lock("custom", Path({str(custom)!r})); c.__enter__()')
            done = subprocess.run([sys.executable, '-c', code], capture_output=True, text=True, timeout=5)
            self.assertNotEqual(done.returncode, 0)
            self.assertIn(str(locks.LEGACY_LOCK), done.stderr)

    def test_cli_without_a_command_prints_usage_and_exits_2(self):
        done = subprocess.run([sys.executable, str(Path(locks.__file__))], capture_output=True, text=True, timeout=10)
        self.assertEqual(done.returncode, 2)
        self.assertIn('usage', done.stderr)
        self.assertNotIn('Traceback', done.stderr)

    def test_cli_reports_unusable_lock_file_without_traceback(self):
        locked = self.root / 'locked'
        locked.mkdir()
        locked.chmod(0o500)
        self.addCleanup(locked.chmod, 0o700)
        if os.access(locked, os.W_OK):
            self.skipTest('permissions are not enforced (root)')
        with patch.object(locks, 'HEAVY_LOCK', locked / 'sub' / 'heavy.lock'):
            message = locks.main(['true'])
        self.assertIn('heavy lock unavailable', message)
        self.assertIn('Permission denied', message)

    def test_environment_marker_does_not_bypass_ownership(self):
        with patch.dict(os.environ, {'NAVIS_HEAVY_LOCKED': '1'}):
            with self.assertRaisesRegex(RuntimeError, 'no verified inherited'):
                with locks.heavy_lock('fake', self.cache, require_inherited=True):
                    self.fail('unlocked')


    def test_killed_holder_keeps_the_lock_while_its_bounded_command_runs(self):
        import time
        ready = self.root / 'ready'
        code = (f'import sys; sys.path.insert(0, {str(Path(__file__).parent)!r}); '
                f'import heavy_lock as l, playback_harness as h; from pathlib import Path; '
                f'l.HEAVY_LOCK=Path({str(locks.HEAVY_LOCK)!r}); l.LEGACY_LOCK=Path({str(locks.LEGACY_LOCK)!r}); '
                f'h.CACHE=Path({str(self.cache)!r}); '
                f'h.heavy_lock=l.heavy_lock; h.candidate_identity=lambda *a: {{}}; h.PROJECT=Path({str(self.root)!r}); '
                f'h._cmd_ab=lambda a,o,e: h.bounded_command(["sh","-c","touch {ready}; sleep 30"], timeout=60); '
                f'import argparse; h.cmd_ab(argparse.Namespace(fn=None))')
        holder = subprocess.Popen([sys.executable, '-c', code], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            for _ in range(100):
                if ready.exists():
                    break
                time.sleep(0.1)
            self.assertTrue(ready.exists())
            holder.kill()
            holder.wait()
            time.sleep(0.3)
            with self.assertRaises(RuntimeError):
                with locks.heavy_lock('second job', self.cache):
                    pass
        finally:
            subprocess.run(['pkill', '-KILL', '-f', f'touch {ready}; sleep 30'])

    def test_display_and_emulator_children_inherit_the_lock_descriptors(self):
        class Stop(Exception):
            pass
        captured = []
        def popen(*args, **kwargs):
            captured.append(kwargs.get('pass_fds'))
            raise Stop
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / (h.SOURCE_AVD + '.avd')).mkdir()
            (root / (h.SOURCE_AVD + '.avd/config.ini')).write_text('hw.ramSize=3072')
            emulator = h.Emulator(root)
            emulator.home = root
            display = h.Display(root)
            with patch.object(h, 'LOCK_FDS', (7,)), patch.object(h.subprocess, 'Popen', side_effect=popen), \
                    patch.object(emulator, 'check'), patch.object(emulator, '_free', return_value=True), \
                    patch.dict(os.environ, {'XDG_RUNTIME_DIR': folder}):
                for acquire in (display._acquire, emulator._acquire):
                    with self.assertRaises(Stop):
                        acquire()
        self.assertEqual(captured, [(7,), (7,)])
        with patch.object(h, 'LOCK_FDS', (7, 8)):
            self.assertEqual(h.held_fds((8, 9)), (7, 8, 9))

    def test_cmd_ab_publishes_and_clears_its_lock_descriptors(self):
        seen = []
        with tempfile.TemporaryDirectory() as folder, patch.object(h, 'PROJECT', Path(folder)), \
                patch.object(h, 'candidate_identity', return_value={}), patch.object(h, 'heavy_lock', return_value=nullcontext((7,))), \
                patch.object(h, '_cmd_ab', side_effect=lambda *a: seen.append(h.LOCK_FDS) or 1), redirect_stdout(io.StringIO()):
            h.cmd_ab(argparse.Namespace(fn=None))
        self.assertEqual((seen, h.LOCK_FDS), ([(7,)], ()))


class Gate(unittest.TestCase):
    def exercise(self, runner=None, verifier=None, reuse=False, lock_error=None, changed=False):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            args = argparse.Namespace(base='ref', reuse_linux='prior-linux' if reuse else None,
                                      reuse_android='prior-android' if reuse else None)
            with patch.object(h, 'PROJECT', root), patch.object(h, 'candidate_identity', return_value={'head': 'h', 'sha256': 'x'},
                        side_effect=([{'head': 'h', 'sha256': 'x'}, {'head': 'h', 'sha256': 'changed'}] if changed else None)), \
                    patch.object(h, 'environment_identity', return_value={'env': 'stable'}), \
                    patch.object(h, 'heavy_lock', return_value=nullcontext(()), side_effect=lock_error), \
                    patch.object(h, 'git', return_value='resolved-base'), \
                    patch.object(h, 'flutter_version', return_value='Flutter pinned'), \
                    patch.object(h, 'bounded_command', side_effect=runner or (lambda *a, **kw: subprocess.CompletedProcess(a[0], 0))) as dispatch, \
                    patch.object(h, 'verify_evidence', side_effect=verifier) as verify, redirect_stdout(io.StringIO()):
                code = h.cmd_gate(args)
            out = next(root.glob('build/harness/gate-*'))
            return code, json.loads((out / 'gate.json').read_text()), (out / 'gate-summary.md').read_text(), dispatch.call_args_list, verify.call_args_list

    def test_busy_owner_and_changed_source_retain_not_run_steps(self):
        for kwargs in ({'lock_error': RuntimeError('owner pid=42 evidence=previous/run')}, {'changed': True}):
            code, record, summary, calls, _ = self.exercise(**kwargs)
            self.assertEqual(code, 2)
            self.assertFalse(calls)
            self.assertEqual([s['status'] for s in record['steps'].values()], ['not-run'] * 3)
            self.assertIn('not-run', summary)
            self.assertIn('previous/run' if 'lock_error' in kwargs else 'candidate/environment changed', summary)

    def test_full_dispatch_and_required_configuration(self):
        code, record, summary, calls, verifies = self.exercise()
        self.assertEqual(code, 0)
        self.assertEqual(list(record['steps']), ['check', 'linux', 'android'])
        self.assertEqual(len(calls), 3)
        self.assertEqual(len(verifies), 2)
        for platform, call in zip(('linux', 'android'), calls[1:]):
            command = call.args[0]
            self.assertIn('--all', command)
            self.assertIn('--full', command)
            self.assertEqual(command[command.index('--platform') + 1], platform)
            self.assertGreater(call.kwargs['timeout'], 3600)
        for platform, verify in zip(('linux', 'android'), verifies):
            config = verify.args[3]
            self.assertEqual(config, h.full_config(platform, 'resolved-base', 'Flutter pinned'))
            self.assertEqual(config['names'], [n for n in h.SCENARIOS if platform == 'linux' or n in h.ANDROID_SCENARIOS])
            cells = sum(len(h.expected_cells(n, True, None, platform)) for n in config['names'])
            self.assertEqual(cells, 121 if platform == 'linux' else 85)
        self.assertIn('Whole playback acceptance: outstanding', summary)
        self.assertTrue(all(v['status'] == 'outstanding' for v in record['external'].values()))

    def test_failures_and_timeout_never_pass_and_keep_exact_exit(self):
        for failed_command in range(3):
            for fault in ('exit', 'timeout'):
                count = 0
                def runner(command, **kw):
                    nonlocal count
                    current, count = count, count + 1
                    if current == failed_command:
                        if fault == 'timeout':
                            raise subprocess.TimeoutExpired(command, kw['timeout'])
                        return subprocess.CompletedProcess(command, 7)
                    return subprocess.CompletedProcess(command, 0)
                with self.subTest(command=failed_command, fault=fault):
                    code, record, summary, calls, _ = self.exercise(runner)
                    self.assertNotEqual(code, 0)
                    step = list(record['steps'].values())[failed_command]
                    self.assertEqual(step['commandExit'], 7 if fault == 'exit' else None)
                    self.assertIn(step['status'], ('failed', 'blocked'))
                    skipped = failed_command == 0  # a check.sh that did not pass (failed or timed out) stops the matrices
                    self.assertEqual(len(calls), 1 if skipped else 3)
                    if skipped:
                        self.assertEqual([s['status'] for s in list(record['steps'].values())[1:]], ['not-run'] * 2)
                        self.assertEqual((code, record['status']), (1, 'failed') if fault == 'exit' else (2, 'blocked'))
                        self.assertIn(f"skipped: check {record['steps']['check']['status']}", summary)
                    self.assertIn('exact command exit=', summary)

    def test_killed_or_infrastructure_exit_of_a_matrix_is_blocked_not_failed(self):
        for platform in ('linux', 'android'):
            for command_exit, expected in ((-9, 'blocked'), (137, 'blocked'), (143, 'blocked'), (2, 'blocked'), (7, 'blocked'), (1, 'failed')):
                def runner(command, **kw):
                    return subprocess.CompletedProcess(command, command_exit if ('--platform' in command and platform in command) else 0)
                with self.subTest(platform=platform, exit=command_exit):
                    code, record, _, _, _ = self.exercise(runner)
                    self.assertEqual(record['steps'][platform]['status'], expected)
                    self.assertEqual(record['steps'][platform]['commandExit'], command_exit)
                    self.assertEqual((code, record['status']), (1, 'failed') if expected == 'failed' else (2, 'blocked'))
        for command_exit in (137, 143):
            code, record, _, _, _ = self.exercise(lambda command, **kw: subprocess.CompletedProcess(command, command_exit if 'check.sh' in command[0] else 0))
            self.assertEqual((code, record['steps']['check']['status']), (2, 'blocked'))

    def test_interruption_during_verification_never_leaves_a_step_passed(self):
        for fault in (KeyboardInterrupt(), SystemExit(143)):
            code, record, _, _, _ = self.exercise(verifier=fault)
            self.assertEqual(code, 2)
            self.assertEqual(record['steps']['linux']['status'], 'blocked')
            self.assertEqual(record['steps']['android']['status'], 'not-run')
            self.assertNotIn('passed', [s['status'] for s in list(record['steps'].values())[1:]])

    def test_missing_malformed_or_stale_evidence_is_blocked(self):
        for message in ('missing artifact', 'malformed evidence', 'stale source', 'wrong base', 'wrong Flutter', 'wrong config'):
            with self.subTest(message=message):
                code, record, summary, _, _ = self.exercise(verifier=h.InfraError(message))
                self.assertEqual(code, 2)
                self.assertEqual(record['steps']['linux']['commandExit'], 0)
                self.assertEqual(record['steps']['linux']['status'], 'blocked')
                self.assertIn(message, summary)

    def test_missing_captured_log_cannot_pass(self):
        for missing in range(3):
            calls = []
            def runner(command, **kwargs):
                if len(calls) == missing:
                    Path(kwargs['stdout'].name).unlink()
                calls.append(command)
                return subprocess.CompletedProcess(command, 0)
            with self.subTest(missing=missing):
                code, record, _, _, _ = self.exercise(runner=runner)
                steps = list(record['steps'].values())
                self.assertEqual(code, 2)
                self.assertEqual(steps[missing]['status'], 'blocked')
                self.assertEqual(steps[missing]['commandExit'], 0)
                self.assertTrue(all(s['status'] == 'passed' for s in steps[:missing]))
                if missing == 0:  # a check.sh that did not pass stops the matrices
                    self.assertEqual([s['status'] for s in steps[1:]], ['not-run'] * 2)

    def test_explicit_verified_reuse_runs_only_check(self):
        code, record, _, calls, verifies = self.exercise(reuse=True)
        self.assertEqual(code, 0)
        self.assertEqual(len(calls), 1)
        self.assertEqual(len(verifies), 2)
        self.assertIsNone(record['steps']['linux']['commandExit'])
        code, record, _, calls, _ = self.exercise(reuse=True, verifier=h.InfraError('stale'))
        self.assertEqual(code, 2)
        self.assertEqual(len(calls), 1)  # rejection does not launch a surprise replacement

    def test_real_missing_and_malformed_evidence(self):
        with tempfile.TemporaryDirectory() as folder:
            out = Path(folder)
            for content in (None, '{', '[]', '{}'):
                if content is not None:
                    (out / 'evidence.json').write_text(content)
                with self.assertRaises(h.InfraError):
                    h.verify_evidence(out, {}, {}, h.full_config('linux', 'sha', 'flutter'))

    def test_flutter_identity_requires_resolved_framework_engine_and_dart(self):
        version = dict(frameworkRevision='framework', engineRevision='engine', dartSdkVersion='dart')
        with patch.object(h, 'run', return_value=subprocess.CompletedProcess([], 0, json.dumps(version), '')) as run:
            self.assertEqual(json.loads(h.flutter_version()), version)
            self.assertIn('--machine', run.call_args.args[0])
        for malformed in ('{', '[]', '{}', '{"frameworkRevision":"only"}'):
            with patch.object(h, 'run', return_value=subprocess.CompletedProcess([], 0, malformed, '')):
                with self.assertRaises(h.InfraError):
                    h.flutter_version()

    def test_environment_is_stable_but_real_configuration_invalidates(self):
        with patch.dict(os.environ, {'NAVIS_TEST_TOKEN': 'private'}, clear=True):
            first = h.environment_identity()
            with patch.dict(os.environ, {'SHLVL': '9', '_': '/bin/other', 'INVOCATION_ID': 'new', 'T3_THREAD_ID': 'other'}):
                self.assertEqual(first, h.environment_identity())
            for key in ('NAVIS_TEST_TOKEN', 'JAVA_HOME', 'PATH', 'ANDROID_HOME', 'GRADLE_OPTS', 'JDK_JAVA_OPTIONS', 'PKG_CONFIG_PATH'):
                with patch.dict(os.environ, {key: 'changed'}):
                    self.assertNotEqual(first, h.environment_identity(), key)
            self.assertNotIn('private', str(first))

    def test_malformed_finalization_retains_original_error_and_failure_summary(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            def fail(args, out, evidence):
                attempt = out / 'base/queue-edit/attempt-1'
                attempt.mkdir(parents=True)
                (attempt / 'evidence.json').write_text('{')
                raise h.InfraError('original engine failure')
            with patch.object(h, 'PROJECT', root), patch.object(h, 'candidate_identity', return_value={}), \
                    patch.object(h, 'heavy_lock', return_value=nullcontext(())), \
                    patch.object(h, '_cmd_ab', side_effect=fail), redirect_stdout(io.StringIO()):
                with self.assertRaisesRegex(h.InfraError, 'original engine failure'):
                    h.cmd_ab(argparse.Namespace(fn=h.cmd_ab))
            out = next(root.glob('build/harness/*'))
            record = json.loads((out / 'evidence.json').read_text())
            self.assertEqual(record['exitCode'], 2)
            self.assertIn('finalizationError', record)
            self.assertIn('original engine failure', (out / 'summary.md').read_text())

    def test_failed_comparison_keeps_detailed_summary_and_result_follows_finalization(self):
        def exercise(code, finalize_error=False):
            with tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                def fake(args, out, evidence):
                    (out / 'comparison.json').write_text('{}')
                    (out / 'summary.md').write_text('# detail\n    seek: FAIL p95 stall 9s > 2s\nRESULT FAIL\n')
                    return code
                stdout = io.StringIO()
                with patch.object(h, 'PROJECT', root), patch.object(h, 'candidate_identity', return_value={}), \
                        patch.object(h, 'heavy_lock', return_value=nullcontext(())), patch.object(h, '_cmd_ab', side_effect=fake), \
                        patch.object(h, 'verify_evidence', side_effect=h.InfraError('stale') if finalize_error else None), \
                        redirect_stdout(stdout):
                    try:
                        returned = h.cmd_ab(argparse.Namespace(fn=h.cmd_ab))
                    except h.InfraError:
                        returned = 'raised'
                out = next(root.glob('build/harness/*'))
                return returned, stdout.getvalue(), (out / 'summary.md').read_text()
        returned, stdout, summary = exercise(1)
        self.assertEqual(returned, 1)
        self.assertIn('RESULT FAIL', stdout)
        self.assertIn('seek: FAIL p95 stall', summary)
        returned, stdout, summary = exercise(0, finalize_error=True)
        self.assertEqual(returned, 'raised')
        self.assertNotIn('RESULT PASS', stdout)
        self.assertNotIn('RESULT PASS', summary)
        self.assertIn('incomplete', summary)
        returned, stdout, _ = exercise(0)
        self.assertEqual((returned, 'RESULT PASS' in stdout), (0, True))

    def test_stale_pass_summary_never_survives_an_incomplete_run(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            def fake(args, out, evidence):
                (out / 'comparison.json').write_text('{}')
                (out / 'summary.md').write_text('# detail\nRESULT PASS\n')
                (out / 'summary.md').chmod(0o444)
                return 0
            identities = iter([{'a': 1}] + [{'a': 2}] * 5)
            stdout = io.StringIO()
            with patch.object(h, 'PROJECT', root), patch.object(h, 'candidate_identity', side_effect=lambda *a: next(identities)), \
                    patch.object(h, 'heavy_lock', return_value=nullcontext(())), patch.object(h, '_cmd_ab', side_effect=fake), \
                    patch.object(h, 'verify_evidence'), redirect_stdout(stdout):
                with self.assertRaises(h.InfraError):
                    h.cmd_ab(argparse.Namespace(fn=h.cmd_ab))
            out = next(root.glob('build/harness/*'))
            self.assertEqual(json.loads((out / 'evidence.json').read_text())['status'], 'incomplete')
            self.assertNotIn('RESULT PASS', (out / 'summary.md').read_text())
            self.assertNotIn('RESULT PASS', stdout.getvalue())

    def ab_args(self, out, **overrides):
        values = dict(fn=None, output=str(out), command='ab', scenarios=[], map=False, all=True, platform='linux',
                      base='ref', base_range='r', full=True, reps=None, real=False)
        return argparse.Namespace(**{**values, **overrides})

    def test_a_kill_during_final_verification_never_leaves_a_pass(self):
        script = (f'import sys, os, signal; sys.path.insert(0, {str(Path(h.__file__).parent)!r}); import playback_harness as h\n'
                  'from contextlib import nullcontext\nfrom pathlib import Path\nfrom unittest.mock import patch\n'
                  'import argparse\nout = Path(sys.argv[1])\n'
                  'def fake(args, out, evidence):\n'
                  '    (out / "comparison.json").write_text("{}"); (out / "summary.md").write_text("...\\nRESULT UNVERIFIED\\n"); return 0\n'
                  'args = argparse.Namespace(fn=None, output=str(out), command="ab", scenarios=[], map=False, all=True, platform="linux",\n'
                  '                         base="b", base_range="r", full=True, reps=None, real=False)\n'
                  'with patch.object(h, "candidate_identity", return_value={"head": "h"}), patch.object(h, "environment_identity", return_value={}), \\\n'
                  '        patch.object(h, "heavy_lock", return_value=nullcontext(())), patch.object(h, "_cmd_ab", fake), \\\n'
                  '        patch.object(h, "git", return_value="sha"), \\\n'
                  '        patch.object(h, "verify_evidence", lambda *a, **k: os.kill(os.getpid(), signal.SIGKILL)):\n'
                  '    h.cmd_ab(args)\n')
        with tempfile.TemporaryDirectory() as folder:
            out = Path(folder) / 'run'
            done = subprocess.run([sys.executable, '-c', script, str(out)], capture_output=True, text=True, timeout=30)
            record = json.loads((out / 'evidence.json').read_text())
            self.assertEqual(done.returncode, -9)
            self.assertEqual((record['status'], record['exitCode']), ('incomplete', 2))
            self.assertNotIn('RESULT PASS', (out / 'summary.md').read_text())
            self.assertNotIn('PASS', done.stdout)

    def test_map_without_playback_changes_is_status_none_not_failed(self):
        with tempfile.TemporaryDirectory() as folder:
            out = Path(folder) / 'run'
            with patch.object(h, 'candidate_identity', return_value={'head': 'h'}), patch.object(h, 'environment_identity', return_value={}), \
                    patch.object(h, 'heavy_lock', return_value=nullcontext(())), patch.object(h, 'pick_scenarios', return_value=[]), \
                    patch.object(h, 'git', return_value='sha'), redirect_stdout(io.StringIO()):
                code = h.cmd_ab(self.ab_args(out, scenarios=[], all=False, map=True))
            record = json.loads((out / 'evidence.json').read_text())
            self.assertEqual((code, record['status'], record['exitCode']), (0, 'none', 0))
            self.assertNotIn('failed', (out / 'summary.md').read_text())

    def test_standalone_evidence_stores_the_resolved_base_sha(self):
        with tempfile.TemporaryDirectory() as folder:
            out = Path(folder) / 'run'
            with patch.object(h, 'candidate_identity', return_value={'head': 'h'}), patch.object(h, 'environment_identity', return_value={}), \
                    patch.object(h, 'heavy_lock', return_value=nullcontext(())), patch.object(h, '_cmd_ab', return_value=1), \
                    patch.object(h, 'git', return_value='0123abc'), redirect_stdout(io.StringIO()):
                h.cmd_ab(self.ab_args(out, base='github/release/1.5'))
            self.assertEqual(json.loads((out / 'evidence.json').read_text())['config']['base'], '0123abc')

    def test_timeout_kills_owned_process_group(self):
        with self.assertRaises(subprocess.TimeoutExpired) as caught:
            h.bounded_command([sys.executable, '-c', 'import time; time.sleep(60)'], timeout=0.05)
        self.assertLess(caught.exception.command_exit, 0)

    def test_signal_death_is_reported_faithfully_without_traceback(self):
        import signal
        for sig in (signal.SIGKILL, signal.SIGSEGV):
            with self.subTest(sig=sig), tempfile.TemporaryDirectory() as folder:
                log = Path(folder) / 'log'
                with log.open('w') as stream:
                    done = h.bounded_command(['sh', '-c', f'kill -{int(sig)} $$'], timeout=10, stderr=stream)
                self.assertEqual(done.returncode, -int(sig))
                self.assertNotIn('Traceback', log.read_text())

    def test_gate_records_the_signal_of_a_killed_command(self):
        def runner(command, **kw):
            return subprocess.CompletedProcess(command, -9 if 'check.sh' in command[0] else 0)
        code, record, summary, _, _ = self.exercise(runner)
        self.assertEqual((code, record['status'], record['steps']['check']['status']), (2, 'blocked', 'blocked'))
        self.assertEqual(record['steps']['check']['commandExit'], -9)
        self.assertIn('signal 9', summary)

    def test_refused_termination_signal_is_logged_not_fatal(self):
        code = (f'import sys, signal; sys.path.insert(0, {str(Path(h.__file__).parent)!r}); import playback_harness as h\n'
                'real = signal.pidfd_send_signal\n'
                'def refuse(fd, sig, *a):\n'
                '    if sig == signal.SIGTERM: raise PermissionError(1, "Operation not permitted")\n'
                '    return real(fd, sig, *a)\n'
                'signal.pidfd_send_signal = refuse\n'
                'sys.exit(h._command_owner(["sh", "-c", "sleep 30 & exit 0"], (), 0.3))')
        done = subprocess.run([sys.executable, '-c', code], capture_output=True, text=True, timeout=20)
        self.assertEqual(done.returncode, 0)  # the leftover descendant was escalated to SIGKILL after the grace period
        self.assertNotIn('Traceback', done.stderr)
        self.assertEqual(done.stderr.count('cannot signal'), 1)

    def test_engine_timeout_unwinds_cleanup_and_retains_sibling_imports(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'tool').mkdir()
            (root / 'tool/sibling.py').write_text('ready = True')
            cleaned = root / 'cleaned'
            (root / 'tool/live_seek_stress.py').write_text(
                'from sibling import ready\nimport time\nfrom pathlib import Path\n'
                f'try:\n    time.sleep(60)\nfinally:\n    Path({str(cleaned)!r}).write_text(str(ready))\n')
            with patch.object(h, 'PROJECT', root):
                with self.assertRaises(subprocess.TimeoutExpired):
                    h.engine([], {}, root / 'out', {}, timeout=0.5, label='fake')
            self.assertEqual(cleaned.read_text(), 'True')

    def test_display_partial_acquisition_stops_its_owned_process(self):
        display = h.Display(Path('unused'))
        display.proc = object()
        with patch.object(display, '_acquire', side_effect=h.InfraError('partial display')), \
                patch.object(h, 'stop_group') as stopped:
            with self.assertRaisesRegex(h.InfraError, 'partial display'):
                display.__enter__()
        stopped.assert_called_once_with(display.proc)

    def test_emulator_partial_acquisition_cleans_only_owned_files(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            emulator = h.Emulator(root)
            emulator.home = root
            emulator.adb = ['unused-adb']
            emulator.proc = object()
            owned = root / (emulator.name + '.avd')
            other = root / 'existing.avd'
            other.mkdir()
            def partial():
                owned.mkdir()
                emulator.created = True
                (root / (emulator.name + '.ini')).write_text('owned')
                raise h.InfraError('partial boot')
            with patch.object(emulator, '_acquire', side_effect=partial), patch.object(h, 'run'), \
                    patch.object(h, 'stop_group') as stopped:
                with self.assertRaisesRegex(h.InfraError, 'partial boot'):
                    emulator.__enter__()
            self.assertFalse(owned.exists())
            self.assertFalse((root / (emulator.name + '.ini')).exists())
            self.assertTrue(other.is_dir())
            stopped.assert_called_once_with(emulator.proc)

    def test_slow_adb_call_is_an_infra_error_not_a_timeout(self):
        emulator = h.Emulator(Path('unused'))
        emulator.adb = ['unused-adb']
        with patch.object(h, 'run', side_effect=subprocess.TimeoutExpired('adb', 15)):
            with self.assertRaisesRegex(h.InfraError, 'getprop timed out'):
                emulator._adb('getprop', 'sys.boot_completed', timeout=15)

    def boot(self, states, reconnect_fixes=True, reconnect_works=True, booted=True):
        """Boots Emulator._acquire against a fake adb and clock. [states] gives get-state per call (last repeats);
        returns (error or None, adb calls, fake seconds)."""
        clock, calls, state = [0.0], [], ['unauthorized']
        def fake_run(cmd, **kwargs):
            calls.append(cmd[1:] if cmd[1:2] != ['-s'] else cmd[3:])
            done = subprocess.CompletedProcess(cmd, 0, '', '')
            if 'get-state' in cmd:
                state[0] = states[min(len([c for c in calls if 'get-state' in c]) - 1, len(states) - 1)]
                if state[0] == 'unauthorized':  # real adb: error text on stderr, exit 1
                    return subprocess.CompletedProcess(cmd, 1, '', 'error: device unauthorized.\n')
                done.stdout = state[0] + '\n'
            elif 'reconnect' in cmd:
                if not reconnect_works and cmd[-2:] != ['reconnect', 'offline']:
                    return subprocess.CompletedProcess(cmd, 1, '', 'error')
                if reconnect_fixes:
                    states[:] = ['device']
            elif 'getprop' in cmd:
                done.stdout = '1\n' if state[0] == 'device' and booted else ''
            return done
        fake_time = type('T', (), {'monotonic': staticmethod(lambda: clock[0]),
                                   'sleep': staticmethod(lambda s: clock.__setitem__(0, clock[0] + s))})
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            source = root / (h.SOURCE_AVD + '.avd')
            source.mkdir()
            (source / 'config.ini').write_text('hw.ramSize=3072')
            emulator = h.Emulator(root)
            emulator.home = root
            proc = type('P', (), {'poll': lambda self: None})()
            error = None
            with patch.object(emulator, 'check'), patch.object(emulator, '_free', return_value=True), \
                    patch.object(h, 'run', side_effect=fake_run), patch.object(h, 'time', fake_time), \
                    patch.object(h.subprocess, 'Popen', return_value=proc):
                try:
                    emulator._acquire()
                except h.InfraError as caught:
                    error = caught
        return error, calls, clock[0]

    def test_boot_wait_gives_up_on_a_guest_adb_never_authorizes(self):
        error, calls, seconds = self.boot(['unauthorized'], reconnect_fixes=False)
        self.assertIsNotNone(error)
        self.assertRegex(str(error), 'unauthorized')
        self.assertLess(seconds, 120)  # not the 240 s boot timeout
        self.assertEqual(len([c for c in calls if 'reconnect' in c]), 1)

    def test_boot_wait_reconnects_a_stuck_adb_and_continues(self):
        for state in ('unauthorized', 'offline'):
            error, calls, seconds = self.boot([state])
            self.assertIsNone(error, state)
            reconnects = [c for c in calls if 'reconnect' in c]
            self.assertEqual(reconnects, [['reconnect']], state)
            self.assertGreater(seconds, 40)

    def test_boot_wait_ignores_a_short_blip(self):
        error, calls, _ = self.boot(['offline', 'offline', 'device'])
        self.assertIsNone(error)
        self.assertFalse([c for c in calls if 'reconnect' in c])

    def test_failed_reconnect_is_an_infra_error_and_never_touches_other_devices(self):
        error, calls, _ = self.boot(['offline'], reconnect_works=False)
        self.assertRegex(str(error), 'reconnect')
        self.assertEqual([c for c in calls if 'reconnect' in c], [['reconnect']])  # `adb reconnect offline` hits every offline device

    def test_flapping_adb_still_names_its_state_at_about_90_s(self):
        # reconnect makes the device vanish for a few polls ('unknown'); a device state that never finishes booting resets nothing
        for states in (['unauthorized'] * 22 + ['unknown'] * 3 + ['unauthorized'],
                       (['unauthorized'] * 14 + ['device']) * 20):
            error, _, seconds = self.boot(states, reconnect_fixes=False, booted=False)
            self.assertRegex(str(error), 'unauthorized')
            self.assertLess(seconds, 100)

    def guest_run(self, platform='android', boot=('ok',), run_errors=(), dies=False):
        """h.run_guest_scenario against fake guests. [boot] lists what each Emulator.__enter__ does ('ok' or 'fail');
        returns (result or exception, emulators built)."""
        built = []
        class Fake:
            def __init__(self, out):
                self.out, self.entered, self.exited = out, False, False
                self.proc = type('P', (), {'poll': lambda me: 1 if dies else None})()
                built.append(self)
            def __enter__(self):
                if boot[min(len(built), len(boot)) - 1] == 'fail':
                    self.exited = True  # the real __enter__ cleans its own failed acquisition
                    raise h.InfraError('emulator adb stayed unauthorized')
                self.entered = True
                return 'emulator-5620'
            def __exit__(self, *_):
                self.exited = True
        errors = list(run_errors)
        def scenario(*args, **kwargs):
            if errors:
                raise errors.pop(0)
            return ['row'], 1.0
        with tempfile.TemporaryDirectory() as folder, patch.object(h, 'Emulator', Fake), \
                patch.object(h, 'run_scenario', side_effect=scenario), patch.object(h, 'activate'), \
                patch.object(h, 'artifact_of', return_value=Path('app.apk')), patch.object(h, 'candidate_identity', return_value={}), \
                redirect_stdout(io.StringIO()):
            try:
                result = h.run_guest_scenario('base/queue-edit', 'queue-edit', platform, Path('base'), Path(folder), {}, None,
                                              {}, False, None, False)
            except h.InfraError as error:
                result = error
        return result, built

    def test_boot_failure_is_retried_once_on_a_fresh_guest(self):
        result, built = self.guest_run(boot=('fail', 'ok'))
        self.assertEqual(result, (['row'], 1.0))
        self.assertEqual(len(built), 2)
        self.assertTrue(built[0].exited)
        self.assertNotEqual(built[0].out, built[1].out)  # the failed boot keeps its emulator.log
        result, built = self.guest_run(boot=('fail', 'fail'))
        self.assertRegex(str(result), 'unauthorized')
        self.assertEqual(len(built), 2)

    def test_guest_run_retries_only_a_dead_guest_and_never_on_linux(self):
        result, built = self.guest_run(run_errors=[h.InfraError('engine died')], dies=True)
        self.assertEqual((result, len(built)), ((['row'], 1.0), 2))
        result, built = self.guest_run(run_errors=[h.InfraError('engine failed')])
        self.assertRegex(str(result), 'engine failed')
        self.assertEqual(len(built), 1)
        result, built = self.guest_run(platform='linux', run_errors=[h.InfraError('engine failed')])
        self.assertRegex(str(result), 'engine failed')
        self.assertEqual(built, [])

    def test_failed_emulator_acquisition_preserves_existing_avd(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            emulator = h.Emulator(root)
            emulator.home = root
            source = root / (h.SOURCE_AVD + '.avd')
            source.mkdir()
            (source / 'config.ini').write_text('hw.ramSize=3072')
            existing = root / (emulator.name + '.avd')
            existing.mkdir()
            (existing / 'sentinel').write_text('not ours')
            with patch.object(emulator, 'check'):
                with self.assertRaises(FileExistsError):
                    emulator.__enter__()
            self.assertEqual((existing / 'sentinel').read_text(), 'not ours')

    def test_capture_preserves_command_and_tee_failure(self):
        helper = Path(__file__).parent / 'lib/check_capture.sh'
        with tempfile.TemporaryDirectory() as folder:
            for command_exit, capture_failure in ((0, False), (9, False), (0, True), (9, True)):
                script = f'set -euo pipefail\nsource "{helper}"\n'
                if capture_failure:
                    script += 'tee() { cat >/dev/null; return 6; }\n'
                script += f'run_step_capture test "{folder}/retained.log" bash -c "echo evidence; exit {command_exit}"\n'
                result = subprocess.run(['bash', '-c', script], capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, command_exit or (6 if capture_failure else 0))
                self.assertIn(f'command exit={command_exit}', result.stdout)
                if not capture_failure:
                    self.assertIn('evidence', (Path(folder) / 'retained.log').read_text())


class ProcessCleanup(unittest.TestCase):
    def test_nested_sessions_timeout_cancellation_and_exited_parent(self):
        import signal
        import time
        for mode in ('timeout', 'cancel', 'exited'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                leaf = root / 'leaf.py'
                leaf.write_text(
                    'import os,signal,time\nfrom pathlib import Path\n'
                    'signal.signal(signal.SIGTERM,signal.SIG_IGN)\n'
                    f'Path({str(root / "leaf.pid")!r}).write_text(str(os.getpid()))\n'
                    'time.sleep(30)\n')
                parent = root / 'parent.py'
                parent.write_text(
                    'import os,signal,subprocess,sys,time\nfrom pathlib import Path\n'
                    f'Path({str(root / "parent.pid")!r}).write_text(str(os.getpid()))\n'
                    f'subprocess.Popen([sys.executable,{str(leaf)!r}],start_new_session=True)\n'
                    'signal.signal(signal.SIGTERM,signal.SIG_IGN)\n'
                    + ('time.sleep(.15)\n' if mode == 'exited' else 'time.sleep(30)\n'))
                nested = root / 'nested.py'
                nested.write_text(
                    'import sys,signal,time\n'
                    f'sys.path.insert(0,{str(Path(h.__file__).parent)!r})\n'
                    'import playback_harness as h\n'
                    'signal.signal(signal.SIGTERM,lambda *_:sys.exit(143))\n'
                    f'h.bounded_command([sys.executable,{str(parent)!r}],timeout=30,cleanup_grace=.2)\ntime.sleep(30)\n')
                runner = root / 'runner.py'
                runner.write_text(
                    'import sys,signal,subprocess,fcntl\nfrom pathlib import Path\n'
                    f'sys.path.insert(0,{str(Path(h.__file__).parent)!r})\n'
                    'import playback_harness as h\n'
                    'signal.signal(signal.SIGTERM,lambda *_:sys.exit(143))\n'
                    f'lock=open({str(root / "owned.lock")!r},"w"); fcntl.flock(lock,fcntl.LOCK_EX)\n'
                    f'try:\n h.bounded_command([sys.executable,{str(nested)!r}],timeout=.6,cleanup_grace=.1,pass_fds=(lock.fileno(),))\n'
                    'except BaseException as error:\n'
                    f' Path({str(root / "error")!r}).write_text(type(error).__name__+":"+str(error))\n'
                    ' raise\n')
                control = subprocess.Popen([sys.executable, '-c', 'import time;time.sleep(30)'], start_new_session=True)
                proc = subprocess.Popen([sys.executable, str(runner)], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
                handles = []
                try:
                    deadline = time.monotonic() + 5
                    while not (root / 'leaf.pid').exists():
                        self.assertIsNone(proc.poll())
                        self.assertLess(time.monotonic(), deadline)
                        time.sleep(.01)
                    for name in ('parent', 'leaf'):
                        try:
                            handles.append(os.pidfd_open(int((root / f'{name}.pid').read_text())))
                        except ProcessLookupError:
                            pass
                    with (root / 'owned.lock').open() as lock_probe:
                        with self.assertRaises(BlockingIOError):
                            fcntl.flock(lock_probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    if mode == 'cancel':
                        proc.send_signal(signal.SIGTERM)
                        time.sleep(.03)
                        with (root / 'owned.lock').open() as lock_probe:
                            with self.assertRaises(BlockingIOError):
                                fcntl.flock(lock_probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    _, stderr = proc.communicate(timeout=5)
                    self.assertNotEqual(proc.returncode, 0, stderr)
                    error = (root / 'error').read_text()
                    self.assertTrue(error.startswith('SystemExit:143' if mode == 'cancel' else 'TimeoutExpired:'), error)
                    for name in ('parent', 'leaf'):
                        pid = int((root / f'{name}.pid').read_text())
                        self.assertFalse(Path(f'/proc/{pid}').exists(), (mode, name, pid))
                    self.assertIsNone(control.poll())
                    with (root / 'owned.lock').open() as lock_probe:
                        fcntl.flock(lock_probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
                finally:
                    control.kill()
                    control.wait()
                    if proc.poll() is None:
                        proc.kill()
                    proc.communicate()
                    # Stable handles keep failure cleanup safe from PID reuse.
                    for fd in handles:
                        try:
                            signal.pidfd_send_signal(fd, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                        finally:
                            os.close(fd)


if __name__ == '__main__':
    unittest.main()
