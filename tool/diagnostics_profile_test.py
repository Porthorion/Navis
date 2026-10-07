"""Synthetic profiles and temporary homes; no primary profile or credentials."""
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import unittest
from unittest.mock import patch

if __package__:
    from .diagnostics_profile import (
        default_primary_database, disable_external_integrations, primary_database,
    )
else:
    from diagnostics_profile import (
        default_primary_database, disable_external_integrations, primary_database,
    )


class ProfileTest(unittest.TestCase):
    def test_pre91_and_current_profiles_stay_off_after_migration(self):
        for current in (False, True):
            with self.subTest(current=current), sqlite3.connect(':memory:') as db:
                db.execute('CREATE TABLE app_settings(id INTEGER PRIMARY KEY)')
                db.execute('INSERT INTO app_settings VALUES(1)')
                if current:
                    db.execute('ALTER TABLE app_settings ADD COLUMN external_integrations_enabled INTEGER NOT NULL DEFAULT 1')
                disable_external_integrations(db)
                disable_external_integrations(db)
                columns = {r[1] for r in db.execute('PRAGMA table_info(app_settings)')}
                # The app migration skips a column already present.
                if 'external_integrations_enabled' not in columns:
                    db.execute('ALTER TABLE app_settings ADD COLUMN external_integrations_enabled INTEGER NOT NULL DEFAULT 1')
                self.assertEqual(db.execute('SELECT external_integrations_enabled FROM app_settings').fetchone()[0], 0)


class DatabasePathTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.current = self.home / ".local/share/com.navis.app.navis/navis.sqlite.sqlite"
        self.legacy = self.home / "Documents/navis.sqlite.sqlite"
        self.current.parent.mkdir(parents=True)
        self.legacy.parent.mkdir(parents=True)
        home = patch(f"{primary_database.__module__}.Path.home", return_value=self.home)
        home.start()
        self.addCleanup(home.stop)
        environment = patch.dict(os.environ, {"HOME": str(self.home)}, clear=True)
        environment.start()
        self.addCleanup(environment.stop)

    def test_current_path_even_when_no_database_exists(self):
        self.assertEqual(default_primary_database(), self.current)
        self.assertEqual(primary_database(), self.current)

    def test_existing_legacy_database_is_used_until_migration(self):
        self.legacy.touch()
        self.assertEqual(primary_database(), self.legacy)
        self.current.touch()
        self.assertEqual(primary_database(), self.current)

    def test_override_and_empty_override(self):
        self.legacy.touch()
        os.environ["NAVIS_DIAGNOSTICS_PRIMARY_DB"] = "~/custom.sqlite"
        self.assertEqual(primary_database(), self.home / "custom.sqlite")
        # Primary certification must retain its normal-path safety check.
        self.assertEqual(default_primary_database(), self.legacy)
        os.environ["NAVIS_DIAGNOSTICS_PRIMARY_DB"] = ""
        self.assertEqual(primary_database(), self.legacy)

    def test_shell_launchers_resolve_paths_without_running_diagnostics(self):
        root = Path(__file__).resolve().parent.parent
        launchers = []
        for script in (root / "tool").glob("*.sh"):
            assignments = [line for line in script.read_text().splitlines()
                           if line.startswith(("SOURCE_DB=", "NORMAL_PRIMARY_DB="))
                           and "diagnostics_profile.py" in line]
            if not assignments:
                continue
            launchers.append(script.name)
            for current, legacy, override in [(False, False, ""), (False, True, ""),
                                               (True, True, ""), (True, True, "~/custom.sqlite")]:
                with self.subTest(script=script.name, current=current,
                                  legacy=legacy, override=bool(override)):
                    self.current.unlink(missing_ok=True)
                    self.legacy.unlink(missing_ok=True)
                    if current:
                        self.current.touch()
                    if legacy:
                        self.legacy.touch()
                    expected = self.current if current or not legacy else self.legacy
                    command = '\n'.join(assignments) + '\nprintf "%s\n" "$SOURCE_DB"'
                    if len(assignments) > 1:
                        command += '\nprintf "%s\n" "$NORMAL_PRIMARY_DB"'
                    result = subprocess.run(["/bin/bash", "-c", command], check=True,
                                            capture_output=True, text=True,
                                            env={"PATH": os.defpath, "HOME": str(self.home),
                                                 "PROJECT_DIR": str(root),
                                                 "NAVIS_DIAGNOSTICS_PRIMARY_DB": override})
                    paths = result.stdout.splitlines()
                    self.assertEqual(paths[0], str(self.home / "custom.sqlite" if override else expected))
                    if len(assignments) > 1:
                        self.assertEqual(paths[1], str(expected))
        self.assertEqual(len(launchers), 11)


if __name__ == '__main__':
    unittest.main()
