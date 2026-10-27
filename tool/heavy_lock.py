#!/usr/bin/env python3
"""Fail-fast shared heavy-job ownership, including verified inherited flock FDs."""
import fcntl
import json
import os
from pathlib import Path
import sys
from contextlib import contextmanager


HEAVY_LOCK = Path('/tmp/navis-heavy.lock')
LEGACY_LOCK = Path.home() / '.cache/navis-harness/lock'


@contextmanager
def heavy_lock(owner, cache=None, require_inherited=False):
    configured = Path(cache or os.environ.get('NAVIS_HARNESS_CACHE', LEGACY_LOCK.parent)) / 'lock'
    paths = list(dict.fromkeys([HEAVY_LOCK, LEGACY_LOCK, configured]))
    held = []
    try:
        for path in paths:
            path.parent.mkdir(parents=True, exist_ok=True)
            probe = path.open('a+')
            inherited = None
            # Also recognize an outer `flock ... command` without an environment bypass.
            fd_directory = Path('/proc/self/fd') if Path('/proc/self/fd').exists() else Path('/dev/fd')
            for entry in fd_directory.iterdir():
                try:
                    fd = int(entry.name)
                    if os.fstat(fd).st_ino != path.stat().st_ino or os.fstat(fd).st_dev != path.stat().st_dev:
                        continue
                    if fd == probe.fileno():
                        continue
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    try:
                        fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    except BlockingIOError:
                        inherited = fd
                        break
                    else:
                        fcntl.flock(probe, fcntl.LOCK_UN)
                except (OSError, ValueError):
                    continue
            if inherited is not None:
                probe.close()
                held.append((inherited, None))
                continue
            if require_inherited:
                probe.close()
                raise RuntimeError(f'no verified inherited ownership of {path}')
            try:
                fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                probe.seek(0)
                detail = probe.read().strip() or 'external flock owner'
                probe.close()
                raise RuntimeError(f'heavy job busy: {path}: {detail}; the recorded pid may be gone while a child (KWin, emulator, '
                                   'cleanup owner) still holds the lock: find the holder with `lslocks | grep navis`; '
                                   'cancel owner and confirm terminal state before retry')
            probe.seek(0)
            probe.truncate()
            probe.write(json.dumps({'pid': os.getpid(), 'owner': str(owner)}))
            probe.flush()
            held.append((probe.fileno(), probe))
        yield tuple(fd for fd, _ in held)
    finally:
        for _, stream in reversed(held):
            if stream is not None:
                stream.close()


def main(arguments):
    try:
        owner = ' '.join(arguments)
        if arguments[:1] == ['--owner']:
            owner, arguments = arguments[1], arguments[2:]
        verify = arguments[:1] == ['--verify']
        if not arguments:
            print('usage: heavy_lock.py [--owner NAME] (--verify | COMMAND [ARGS...])', file=sys.stderr)
            return 2
        with heavy_lock(owner, require_inherited=verify) as descriptors:
            if verify:
                return 0
            for fd in descriptors:
                os.set_inheritable(fd, True)
            os.execvp(arguments[0], arguments)
    except (RuntimeError, OSError) as error:  # busy lock, or e.g. PermissionError on a lock file owned by another user
        return f'heavy lock unavailable: {error}' if isinstance(error, OSError) else str(error)


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
