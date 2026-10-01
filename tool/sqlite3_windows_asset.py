#!/usr/bin/env python3
"""Download the exact locked SQLite Windows asset and verify its package hash."""

import argparse
import hashlib
import os
from pathlib import Path
import re
import tempfile
from urllib.request import urlopen


ASSET_NAME = "sqlite3.x64.windows.dll"


def locked_asset(lockfile, package_cache):
    """Read trusted asset metadata from the resolved Pub package, failing closed."""
    block = re.search(
        r"^  sqlite3:\n(.*?)(?=^  \S|\Z)",
        Path(lockfile).read_text(),
        re.MULTILINE | re.DOTALL,
    )
    version = re.search(r'^    version: "(\d+\.\d+\.\d+)"$', block[1], re.MULTILINE) if block else None
    if version is None:
        raise ValueError("No stable sqlite3 version found in the lockfile")
    tag = "sqlite3-" + version[1]
    metadata = (Path(package_cache) / tag / "lib/src/hook/asset_hashes.dart").read_text()
    release = re.search(r"releaseTag\s*=\s*'([^']+)'", metadata)
    checksum = re.search(r"'" + re.escape(ASSET_NAME) + r"':\s*'([a-f0-9]{64})'", metadata)
    if release is None or release[1] != tag or checksum is None:
        raise ValueError("SQLite asset metadata does not match the locked release")
    return tag, checksum[1]


def prepare_asset(lockfile, package_cache, destination):
    tag, expected = locked_asset(lockfile, package_cache)
    url = f"https://github.com/simolus3/sqlite3.dart/releases/download/{tag}/{ASSET_NAME}"
    destination = Path(destination)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as output:
            temporary = Path(output.name)
            digest = hashlib.sha256()
            with urlopen(url, timeout=30) as response:
                while chunk := response.read(1024 * 1024):
                    digest.update(chunk)
                    output.write(chunk)
        if digest.hexdigest() != expected:
            raise ValueError("SQLite Windows asset checksum mismatch")
        os.replace(temporary, destination)
        return expected
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lockfile", required=True, type=Path)
    parser.add_argument("--package-cache", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        checksum = prepare_asset(args.lockfile, args.package_cache, args.output)
    except (OSError, ValueError) as error:
        parser.exit(1, f"SQLite Windows asset preparation failed: {error}\n")
    print(checksum)


if __name__ == "__main__":
    main()
