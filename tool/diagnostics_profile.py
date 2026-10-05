"""Profile preparation shared by isolated diagnostics launchers."""
import sqlite3


def disable_external_integrations(clone: sqlite3.Connection) -> None:
    """Seed master-off before startup, including profiles before schema 91."""
    columns = {row[1] for row in clone.execute('PRAGMA table_info(app_settings)')}
    if 'external_integrations_enabled' not in columns:
        clone.execute('ALTER TABLE app_settings ADD COLUMN '
                      'external_integrations_enabled INTEGER NOT NULL DEFAULT 0')
    clone.execute('UPDATE app_settings SET external_integrations_enabled=0')
