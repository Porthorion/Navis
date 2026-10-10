#!/usr/bin/env python3
"""Allocate Android dev versionCodes across worktrees on this build host."""
import fcntl
import os
from pathlib import Path
import time

EPOCH = 1767225600  # 2026-01-01 00:00:00 UTC
OFFSET = 10500000
LIMIT = 2100000000


def allocate_build(state_dir: Path, now: int | None = None) -> int:
    state_dir.mkdir(parents=True, exist_ok=True)
    with (state_dir / 'build-number.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        state = state_dir / 'build-number'
        previous = int(state.read_text()) if state.exists() else 10500
        seconds = int(time.time()) if now is None else now
        build = max(OFFSET + seconds - EPOCH, previous + 1)
        if not 10500 < build < LIMIT:
            raise ValueError('Dev build number exceeds the Android versionCode range')
        temporary = state_dir / 'build-number.tmp'
        temporary.write_text(f'{build}\n')
        os.replace(temporary, state)
        return build


if __name__ == '__main__':
    print(allocate_build(Path.home() / '.cache/navis/dev-releases'))
