"""Only synthetic in-memory profiles; no primary profile or credentials."""
import sqlite3
import unittest
from diagnostics_profile import disable_external_integrations


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


if __name__ == '__main__':
    unittest.main()
