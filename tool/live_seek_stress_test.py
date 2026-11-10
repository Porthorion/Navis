#!/usr/bin/env python3
"""Proves live_seek_stress refuses an empty or whitespace app-id suffix before
any adb call. Uses a fake adb that records invocation, never a device.

Usage: python3 tool/live_seek_stress_test.py
"""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import live_seek_stress as engine  # noqa: E402

SCRIPT = Path(__file__).resolve().with_name('live_seek_stress.py')


class SuffixValidation(unittest.TestCase):
    def test_rejects_blank_suffixes(self):
        for suffix in ('', ' ', '\t\n'):
            with self.assertRaisesRegex(engine.Failure, 'NAVIS_LIVE_SEEK_SUFFIX'):
                engine.validate_android_identity(suffix)

    def test_accepts_a_distinct_suffix(self):
        engine.validate_android_identity('.liveseek')


class CommandLineGuard(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.base = self.root / 'base'
        self.marker = self.root / 'adb-called'
        self.sdk = self.root / 'sdk'
        adb = self.sdk / 'platform-tools' / 'adb'
        adb.parent.mkdir(parents=True)
        adb.write_text(
            '#!/bin/sh\n'
            f'echo "$@" >> "{self.marker}"\n'
            'exit 0\n'
        )
        adb.chmod(0o755)
        self.credentials = self.root / 'credentials.json'
        self.credentials.write_text(json.dumps(
            {'url': 'http://127.0.0.1', 'username': 'guard',
             'password': 'guard'}))
        self.credentials.chmod(0o600)

    def run_script(self, suffix):
        env = {
            **os.environ,
            'NAVIS_LIVE_SEEK_SUFFIX': suffix,
            'NAVIS_LIVE_SEEK_BASE': str(self.base),
            'NAVIS_LIVE_SEEK_APK': str(self.root / 'android.apk'),
            'NAVIS_LIVE_SEEK_CREDENTIALS': str(self.credentials),
            'ANDROID_HOME': str(self.sdk),
        }
        return subprocess.run(
            [sys.executable, str(SCRIPT), '--android', 'emulator-guard-test',
             '--skip-build'],
            capture_output=True, text=True, timeout=60, env=env)

    def test_blank_suffix_exits_before_adb(self):
        for suffix in ('', ' '):
            with self.subTest(suffix=suffix):
                result = self.run_script(suffix)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('NAVIS_LIVE_SEEK_SUFFIX', result.stderr)
                self.assertFalse(
                    self.marker.exists(),
                    f'adb was called with suffix {suffix!r}: '
                    f'{self.marker.read_text() if self.marker.exists() else ""}')


if __name__ == '__main__':
    unittest.main()
