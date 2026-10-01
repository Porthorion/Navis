"""Offline verification of Windows SQLite asset selection and failure handling."""

import hashlib
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from sqlite3_windows_asset import ASSET_NAME, locked_asset, prepare_asset


class WindowsAssetTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.lock = self.root / "pubspec.lock"
        self.lock.write_text('packages:\n  sqlite3:\n    version: "3.6.0"\n  uuid:\n    version: "4.6.0"\n')
        self.metadata = self.root / "sqlite3-3.6.0/lib/src/hook/asset_hashes.dart"
        self.metadata.parent.mkdir(parents=True)
        self.content = b"verified SQLite DLL fixture"
        self.hash = hashlib.sha256(self.content).hexdigest()
        self.write_metadata()
        self.output = self.root / "sqlite3.dll"

    def write_metadata(self, tag="sqlite3-3.6.0"):
        self.metadata.write_text(
            f"const String? releaseTag = '{tag}';\n"
            f"const assetNameToSha256Hash = {{'{ASSET_NAME}': '{self.hash}'}};\n"
        )

    def test_download_uses_locked_release_and_verified_bytes(self):
        with patch("sqlite3_windows_asset.urlopen", return_value=io.BytesIO(self.content)) as download:
            self.assertEqual(prepare_asset(self.lock, self.root, self.output), self.hash)
        download.assert_called_once_with(
            "https://github.com/simolus3/sqlite3.dart/releases/download/sqlite3-3.6.0/sqlite3.x64.windows.dll",
            timeout=30,
        )
        self.assertEqual(self.output.read_bytes(), self.content)

    def test_checksum_failure_does_not_replace_an_existing_file(self):
        self.output.write_bytes(b"original")
        before = set(self.root.iterdir())
        with patch("sqlite3_windows_asset.urlopen", return_value=io.BytesIO(b"wrong")):
            with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                prepare_asset(self.lock, self.root, self.output)
        self.assertEqual(self.output.read_bytes(), b"original")
        self.assertEqual(set(self.root.iterdir()), before)

    def test_download_failure_leaves_no_partial_asset(self):
        before = set(self.root.iterdir())
        with patch("sqlite3_windows_asset.urlopen", side_effect=OSError("unavailable")):
            with self.assertRaises(OSError):
                prepare_asset(self.lock, self.root, self.output)
        self.assertFalse(self.output.exists())
        self.assertEqual(set(self.root.iterdir()), before)

    def test_wrong_release_metadata_is_rejected_before_download(self):
        self.write_metadata("sqlite3-3.5.2")
        with patch("sqlite3_windows_asset.urlopen") as download:
            with self.assertRaisesRegex(ValueError, "locked release"):
                prepare_asset(self.lock, self.root, self.output)
        download.assert_not_called()

    def test_missing_hash_is_rejected(self):
        self.metadata.write_text("const releaseTag = 'sqlite3-3.6.0';")
        with self.assertRaisesRegex(ValueError, "locked release"):
            locked_asset(self.lock, self.root)

    def test_missing_package_version_is_rejected(self):
        self.lock.write_text('packages:\n  uuid:\n    version: "4.6.0"\n')
        with self.assertRaisesRegex(ValueError, "No stable sqlite3 version"):
            locked_asset(self.lock, self.root)


if __name__ == "__main__":
    unittest.main()
