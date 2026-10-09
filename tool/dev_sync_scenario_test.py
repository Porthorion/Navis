#!/usr/bin/env python3
"""Focused checks for disposable sync scenario preparation."""

import sqlite3
import tempfile
import unittest
from pathlib import Path

from tool.dev_sync_scenario import (
    PROJECT_ROOT,
    _clone_diagnostic_defines,
    _scenario_args,
    prepare_database,
    prepare_support_directory,
)


class DevSyncScenarioTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "source.sqlite"
        with sqlite3.connect(self.source) as db:
            db.executescript(
                """
                CREATE TABLE server_config (
                  id INTEGER PRIMARY KEY, name TEXT, url TEXT,
                  username TEXT, api_version TEXT, capabilities TEXT,
                  last_synced INTEGER, last_full_synced INTEGER,
                  is_authenticated INTEGER
                );
                CREATE TABLE app_settings (
                  id INTEGER PRIMARY KEY, onboarding_version INTEGER,
                  custom_download_folder_enabled INTEGER,
                  custom_download_folder_path TEXT,
                  auto_download_starred_on_wifi INTEGER
                );
                CREATE TABLE cache_system_state (
                  id INTEGER PRIMARY KEY, cache_system_version INTEGER
                );
                CREATE TABLE library_sync_state (
                  server_id INTEGER PRIMARY KEY, current_generation INTEGER,
                  last_catalog_synced_at INTEGER, initial_catalog_usable_at INTEGER
                );
                CREATE TABLE songs (id TEXT PRIMARY KEY);
                CREATE TABLE cached_tracks (song_id TEXT PRIMARY KEY, file_path TEXT);
                CREATE TABLE star_sync_queue (id INTEGER PRIMARY KEY);
                """
            )
            db.execute(
                "INSERT INTO server_config VALUES "
                "(1, 'Source', 'https://example.test', 'reader', '1.16.1', "
                "'{}', 123, 123, 1)"
            )
            db.execute("INSERT INTO app_settings VALUES (1, 1, 1, '/user/downloads', 1)")
            db.execute("INSERT INTO cache_system_state VALUES (1, 3)")
            db.execute("INSERT INTO library_sync_state VALUES (1, 2, 123, NULL)")
            db.execute("INSERT INTO songs VALUES ('song')")
            db.execute("INSERT INTO cached_tracks VALUES ('song', '/user/file')")
            db.execute("INSERT INTO star_sync_queue VALUES (1)")

    def test_first_setup_resets_only_clone(self):
        target = self.root / "first.sqlite"
        prepare_database(self.source, target, "first-setup")
        with sqlite3.connect(target) as db:
            self.assertEqual(db.execute("SELECT count(*) FROM songs").fetchone()[0], 0)
            self.assertEqual(db.execute("SELECT count(*) FROM cached_tracks").fetchone()[0], 0)
            self.assertIsNone(db.execute("SELECT last_synced FROM server_config").fetchone()[0])
            self.assertEqual(db.execute("SELECT onboarding_version FROM app_settings").fetchone()[0], 0)
            self.assertEqual(db.execute("SELECT cache_system_version FROM cache_system_state").fetchone()[0], 3)
            self.assertEqual(
                db.execute(
                    "SELECT custom_download_folder_enabled, "
                    "custom_download_folder_path, auto_download_starred_on_wifi "
                    "FROM app_settings"
                ).fetchone(),
                (0, None, 0),
            )
        with sqlite3.connect(self.source) as db:
            self.assertEqual(db.execute("SELECT count(*) FROM songs").fetchone()[0], 1)
            self.assertEqual(db.execute("SELECT file_path FROM cached_tracks").fetchone()[0], "/user/file")
            self.assertEqual(db.execute("SELECT last_synced FROM server_config").fetchone()[0], 123)
            self.assertEqual(
                db.execute(
                    "SELECT custom_download_folder_enabled, "
                    "custom_download_folder_path, auto_download_starred_on_wifi "
                    "FROM app_settings"
                ).fetchone(),
                (1, '/user/downloads', 1),
            )

    def test_bad_cache_keeps_catalog_and_removes_only_cloned_marker(self):
        target = self.root / "bad.sqlite"
        prepare_database(self.source, target, "bad-cache")
        with sqlite3.connect(target) as db:
            self.assertEqual(db.execute("SELECT count(*) FROM songs").fetchone()[0], 1)
            self.assertEqual(db.execute("SELECT count(*) FROM cache_system_state").fetchone()[0], 0)
            self.assertEqual(db.execute("SELECT count(*) FROM star_sync_queue").fetchone()[0], 0)
        with sqlite3.connect(self.source) as db:
            self.assertEqual(db.execute("SELECT count(*) FROM cache_system_state").fetchone()[0], 1)

    def test_onboarding_and_fixture_are_distinct_states(self):
        onboarding = self.root / "onboarding.sqlite"
        prepare_database(self.source, onboarding, "force-setup")
        with sqlite3.connect(onboarding) as db:
            self.assertEqual(db.execute("SELECT onboarding_version FROM app_settings").fetchone()[0], 0)
            self.assertEqual(db.execute("SELECT count(*) FROM songs").fetchone()[0], 1)
        fixture = self.root / "fixture.sqlite"
        prepare_database(
            self.source, fixture, "partial-album", fixture_url="http://127.0.0.1:9000"
        )
        with sqlite3.connect(fixture) as db:
            self.assertEqual(db.execute("SELECT url FROM server_config").fetchone()[0], "http://127.0.0.1:9000")
            self.assertEqual(db.execute("SELECT count(*) FROM songs").fetchone()[0], 0)

    def test_ready_only_scenarios_reject_unsigned_or_unready_source(self):
        with sqlite3.connect(self.source) as db:
            db.execute("UPDATE server_config SET last_synced = NULL")
            db.execute("DELETE FROM library_sync_state")
        with self.assertRaisesRegex(ValueError, "usable library"):
            prepare_database(self.source, self.root / "unready.sqlite", "force-setup")
        with sqlite3.connect(self.source) as db:
            db.execute("UPDATE server_config SET is_authenticated = 0")
        with self.assertRaisesRegex(ValueError, "Sign in"):
            prepare_database(self.source, self.root / "signedout.sqlite", "first-setup")

    def test_launch_flags_require_linux_and_reject_overriding_clone_defines(self):
        options, remaining = _scenario_args(["-d", "linux", "--first-setup", "--offline"])
        self.assertEqual(options.scenario, "first-setup")
        self.assertTrue(options.offline)
        self.assertEqual(remaining, [])
        with self.assertRaises(SystemExit):
            _scenario_args(["-d", "android", "--first-setup"])
        with self.assertRaises(SystemExit):
            _scenario_args(["-d", "linux", "--first-setup", "--dart-define=BAD=1"])

    def test_interactive_clone_uses_the_production_lease_duration(self):
        options, _ = _scenario_args(["-d", "linux", "--first-setup"])
        defines = _clone_diagnostic_defines(
            options,
            root=self.root / "run",
            database=self.root / "run" / "navis.sqlite",
            handshake_path=self.root / "run" / "handshake.json",
        )
        self.assertEqual(defines["NAVIS_SYNC_DIAGNOSTICS_LEASE_SECONDS"], "600")

    def test_existing_profiles_seed_their_own_support_directory(self):
        version = next(
            line.split(":", 1)[1].strip().split("+", 1)[0]
            for line in (PROJECT_ROOT / "pubspec.yaml").read_text().splitlines()
            if line.startswith("version:")
        )
        for scenario in ("first-setup", "partial-album", "manual-cache-reset"):
            run = self.root / scenario
            run.mkdir()
            prepare_support_directory(run, scenario)
            marker = run / "support" / "changelog_seen_version.txt"
            self.assertEqual(marker.read_text(), version + "\n")
            self.assertEqual(marker.stat().st_mode & 0o777, 0o600)
        fresh = self.root / "fresh-login"
        fresh.mkdir()
        prepare_support_directory(fresh, "fresh-login")
        self.assertEqual(list((fresh / "support").iterdir()), [])


if __name__ == "__main__":
    unittest.main()
