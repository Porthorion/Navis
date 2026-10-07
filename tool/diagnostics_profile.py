"""Profile preparation shared by isolated diagnostics launchers."""
import argparse
import os
from pathlib import Path
import sqlite3


def disable_external_integrations(clone: sqlite3.Connection) -> None:
    """Seed master-off before startup, including profiles before schema 91."""
    columns = {row[1] for row in clone.execute('PRAGMA table_info(app_settings)')}
    if 'external_integrations_enabled' not in columns:
        clone.execute('ALTER TABLE app_settings ADD COLUMN '
                      'external_integrations_enabled INTEGER NOT NULL DEFAULT 0')
    clone.execute('UPDATE app_settings SET external_integrations_enabled=0')


def default_primary_database() -> Path:
    """Prefer Linux application support, falling back only to an existing legacy DB."""
    home = Path.home()
    current = home / ".local" / "share" / "com.navis.app.navis" / "navis.sqlite.sqlite"
    legacy = home / "Documents" / "navis.sqlite.sqlite"
    return legacy if not current.is_file() and legacy.is_file() else current


def primary_database() -> Path:
    """Resolve the diagnostics override or the normal Linux database location."""
    override = os.environ.get("NAVIS_DIAGNOSTICS_PRIMARY_DB")
    return Path(override).expanduser() if override else default_primary_database()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Resolve diagnostics database paths.")
    parser.add_argument("path", choices=("primary-db", "default-primary-db"))
    args = parser.parse_args()
    print(primary_database() if args.path == "primary-db" else default_primary_database())
