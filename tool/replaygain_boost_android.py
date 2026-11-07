#!/usr/bin/env python3
"""A1: the Android ReplayGain boost on a running emulator, through the Navis diagnostics API.

Called by `tool/replaygain_boost_diagnostics.sh --scenarios a1 --android-serial SERIAL`, which
then asserts over the samples with `tool/replaygain_boost_analyze.py`. Builds a muted profile
sidecar under its own application id, serves the Q/H fixture songs (TranscodeLibrary, with a
Navidrome-like transcoding stream) over `adb reverse`, and samples `/v1/playback/status` while it
drives joins, an EQ, repeat-one switched off and shuffle toggled inside the last 3 s, a
cross-fade and a lossy stream. The processor reports what it applied (`replayGainBoost`): the
applied boost, the guard and the samples it had to clamp. Never touches another application id.
"""
from __future__ import annotations

import argparse
import json
import os
import sqlite3
import subprocess
import sys
import threading
import time
from pathlib import Path
from urllib.request import Request, urlopen

sys.path.insert(0, str(Path(__file__).resolve().parent))
import seek_reliability_diagnostics as seek  # noqa: E402

PROJECT = Path(__file__).resolve().parents[1]
PACKAGE = 'com.navis.app.navis.rgboost'
REMOTE = f'/data/user/0/{PACKAGE}/files/diag'
Q1, H1, Q2, H2, QL = 'rgq-1', 'rgh-1', 'rgq-2', 'rgh-2', 'rgl-1'


class Run:
    def __init__(self, args):
        self.args = args
        self.out = args.output
        self.adb = [os.path.join(os.environ.get('ANDROID_HOME', str(Path.home() / 'Android/Sdk')),
                                 'platform-tools/adb'), '-s', args.serial]
        self.client: dict = {}
        self.phase = 'setup'
        self.samples = (self.out / 'a1-samples.jsonl').open('w')
        self.ordering = (self.out / 'a1-ordering.jsonl').open('w')
        self.stop_sampling = threading.Event()
        self.sampler = None

    def shell(self, *parts, check=True):
        return subprocess.run(self.adb + list(parts), check=check, capture_output=True).stdout

    def api(self, method, route, body=None, timeout=60):
        data = None if body is None else json.dumps(body).encode()
        request = Request(f'http://127.0.0.1:{self.client["port"]}{route}', data=data, method=method,
                          headers={'Authorization': f'Bearer {self.client["token"]}',
                                   'Content-Type': 'application/json'})
        with urlopen(request, timeout=timeout) as response:
            return json.load(response)

    def status(self):
        return self.api('GET', '/v1/playback/status')

    def post(self, route, body=None):
        return self.api('POST', route, {} if body is None else body)

    def wait(self, predicate, timeout=30, interval=.1, label=''):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            value = predicate()
            if value:
                return value
            time.sleep(interval)
        raise TimeoutError(f'timed out waiting for {label or predicate}')

    # -- sampling

    def start_sampler(self):
        def loop():
            while not self.stop_sampling.is_set():
                try:
                    v = self.status()
                    row = {'t': round(time.time(), 3), 'phase': self.phase, 'songId': v.get('songId'),
                           'index': v.get('currentIndex'), 'positionMs': v.get('playerPositionMs'), 'durationMs': v.get('durationMs'),
                           'playing': v.get('playing'),
                           'boost': v.get('replayGainBoost'), 'decision': v.get('replayGain')}
                    self.samples.write(json.dumps(row) + '\n')
                    self.samples.flush()
                except Exception:  # noqa: BLE001 - a missed sample is not a failure
                    pass
                time.sleep(.1)
        self.stop_sampling.clear()
        self.sampler = threading.Thread(target=loop, daemon=True)
        self.sampler.start()

    def stop_sampler(self):
        self.stop_sampling.set()
        if self.sampler:
            self.sampler.join(5)

    # -- app lifecycle

    def build_and_install(self, library):
        defines = {'NAVIS_UPDATE_CHANNEL': 'dev', 'NAVIS_APP_NAME': 'Navis RG Boost', 'NAVIS_SYNC_DIAGNOSTICS': 'true',
                   'NAVIS_SYNC_DIAGNOSTICS_MUTED': 'true', 'NAVIS_SYNC_DIAGNOSTICS_MODE': 'clone',
                   'NAVIS_SYNC_DIAGNOSTICS_ROOT': REMOTE, 'NAVIS_SYNC_DIAGNOSTICS_DB_PATH': REMOTE + '/navis.sqlite'}
        apk = self.out / 'app.apk'
        if not self.args.reuse_apk or not apk.exists():
            env = {**os.environ, 'NAVIS_APP_ID_SUFFIX': PACKAGE.removeprefix('com.navis.app.navis'),
                   'NAVIS_APP_NAME': 'Navis RG Boost'}
            command = ['flutter', 'build', 'apk', '--profile', '--flavor', 'sideload', '--target-platform',
                       'android-x64', '--no-pub'] + [f'--dart-define={k}={v}' for k, v in defines.items()]
            with (self.out / 'build.log').open('w') as log:
                subprocess.run(command, cwd=PROJECT, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
            apk.write_bytes((PROJECT / 'build/app/outputs/flutter-apk/app-sideload-profile.apk').read_bytes())
        self.shell('install', '-r', str(apk))
        self.shell('shell', 'pm', 'grant', PACKAGE, 'android.permission.POST_NOTIFICATIONS')
        self.shell('shell', 'run-as', PACKAGE, 'mkdir', '-p', 'files/diag')
        self.shell('reverse', f'tcp:{self.library_port}', f'tcp:{self.library_port}')

    def launch(self):
        remote_handshake = f'/sdcard/Android/data/{PACKAGE}/files/navis-diagnostics/handshake.json'
        self.shell('shell', 'rm', '-f', remote_handshake, check=False)
        self.shell('shell', 'am', 'start', '-n', PACKAGE + '/com.navis.app.navis.MainActivity')

        def handshake():
            try:
                self.client.update(json.loads(self.shell('exec-out', 'cat', remote_handshake)))
                return True
            except (ValueError, subprocess.CalledProcessError):
                return False
        self.wait(handshake, 90, .5, 'the diagnostics handshake')
        port = int(self.shell('forward', 'tcp:0', f'tcp:{self.client["port"]}').decode().strip())
        self.client['port'] = port
        if self.api('GET', '/v1/health').get('mode') != 'clone':
            raise RuntimeError('refusing mutations outside clone mode')

    def connect(self):
        self.post('/v1/session/connect', {'url': f'http://127.0.0.1:{self.library_port}', 'username': 'diagnostics',
                                          'password': 'synthetic-rgboost-fixture'})
        self.wait(lambda: self.api('GET', '/v1/health')['catalog']['songs'] >= 5, 120, 1, 'the catalog sync')
        self.post('/v1/presentation/onboarding/complete')
        self.post('/v1/playback/volume', {'value': 0})
        self.post('/v1/playback/replay-gain', {'mode': 'track', 'preamp': 0})

    def restart(self, mutate_db=None):
        try:
            self.post('/v1/shutdown')
        except Exception:  # noqa: BLE001 - the app closes the connection while it exits
            pass
        time.sleep(2)
        self.shell('shell', 'am', 'force-stop', PACKAGE, check=False)
        if mutate_db:
            self.edit_db(mutate_db)
        self.launch()
        self.connect()

    def edit_db(self, mutate):
        work = self.out / 'db'
        work.mkdir(exist_ok=True)
        for name in ('navis.sqlite', 'navis.sqlite-wal', 'navis.sqlite-shm'):
            data = subprocess.run(self.adb + ['exec-out', 'run-as', PACKAGE, 'cat', f'files/diag/{name}'],
                                  capture_output=True).stdout
            (work / name).write_bytes(data)
        connection = sqlite3.connect(work / 'navis.sqlite')
        mutate(connection)
        connection.commit()
        connection.execute('PRAGMA wal_checkpoint(TRUNCATE)')
        connection.close()
        for name in ('navis.sqlite-wal', 'navis.sqlite-shm'):
            self.shell('shell', 'run-as', PACKAGE, 'rm', '-f', f'files/diag/{name}', check=False)
        self.shell('push', str(work / 'navis.sqlite'), '/data/local/tmp/rgboost.sqlite')
        self.shell('shell', 'run-as', PACKAGE, 'cp', '/data/local/tmp/rgboost.sqlite', 'files/diag/navis.sqlite')

    # -- drive

    def queue(self, ids, repeat='none'):
        self.post('/v1/playback/pause')
        self.post('/v1/playback/queue', {'songIds': ids})
        self.post('/v1/playback/repeat', {'mode': repeat})
        self.wait(lambda: self.status().get('processingState') == 'ready', 30, .2, 'ready')

    def play_from(self, ms):
        self.post('/v1/playback/pause')
        self.post('/v1/playback/seek', {'positionMs': ms})
        self.post('/v1/playback/play')

    def heard(self):
        return self.status().get('songId')

    def join(self, seconds_after=3.5, from_ms=26000):
        """Seek the playing song to its last seconds and let the next one start."""
        before = self.heard()
        self.play_from(from_ms)
        self.wait(lambda: self.heard() != before, 15, .1, 'a join')
        time.sleep(seconds_after)

    def clip(self):
        boost = self.status().get('replayGainBoost') or {}
        return boost.get('clipSamples')

    def steady(self, ids, seconds=7):
        """Play the first song from 5 s on, away from both ends, and let the levels settle."""
        self.queue(ids)
        self.play_from(5000)
        time.sleep(seconds)

    def run(self):
        library = seek.TranscodeLibrary(self.out / 'fixture-media', artists=1, albums=1, tracks=1,
                                        replay_gain_levels=True)
        server, _ = seek.start_transcoding_server(library)
        self.library_port = server.server_port
        try:
            self.build_and_install(library)
            self.launch()
            self.connect()
            self.start_sampler()
            self.scenarios()
        finally:
            self.stop_sampler()
            self.samples.close()
            self.ordering.close()
            subprocess.run(self.adb + ['shell', 'am', 'force-stop', PACKAGE], capture_output=True)
            server.shutdown()

    def scenarios(self):
        queue = [Q1, H1, Q2, H2]
        self.phase = 'plateau'
        self.steady([Q1, Q2])
        self.steady([H1, H2])

        self.phase = 'joins'
        self.queue(queue, repeat='all')
        self.post('/v1/playback/play')
        time.sleep(3)
        for _ in range(10):
            self.join()

        self.phase = 'eq-on'
        self.post('/v1/equalizer', {'action': 'configure', 'configuration': {
            'version': 1, 'mode': 'advanced', 'enabled': True, 'preampDb': 0, 'autoHeadroom': True,
            'filters': [{'type': 'peaking', 'frequencyHz': 1000, 'gainDb': 3, 'q': 1, 'enabled': True}]}})
        time.sleep(1)
        self.steady([Q1, Q2])
        self.steady([H1, H2])
        self.queue(queue, repeat='all')
        for _ in range(3):
            self.join()
        self.post('/v1/equalizer', {'action': 'configure', 'configuration': {
            'version': 1, 'mode': 'advanced', 'enabled': False, 'preampDb': 0, 'autoHeadroom': True, 'filters': []}})

        self.phase = 'repeat-one-off'
        self.queue([Q1, H1], repeat='one')
        self.play_from(26500)
        time.sleep(.6)
        self.post('/v1/playback/repeat', {'mode': 'none'})
        self.wait(lambda: self.heard() == H1, 15, .1, 'H after repeat-one was switched off')
        time.sleep(3)

        self.phase = 'shuffle-toggle'
        self.queue([Q1, H1, Q2, H2])
        self.play_from(26500)
        time.sleep(.6)
        self.post('/v1/playback/shuffle', {'enabled': True})
        time.sleep(6)
        self.post('/v1/playback/shuffle', {'enabled': False})
        time.sleep(1)

        self.phase = 'crossfade-setup'
        self.restart(lambda db: db.execute(
            'UPDATE app_settings SET crossfade_enabled=1, crossfade_duration_seconds=3, gapless_enabled=1'))
        self.phase = 'crossfade'
        self.queue([Q1, H1, Q2, H2])
        for _ in range(3):
            self.join(seconds_after=5, from_ms=24000)
        # A speed change in the middle of the fade to Q2: its deck was Q1's, and the hand-over refresh
        # wrote Q1's end guard for it while it sat paused.
        self.phase = 'crossfade-speed'
        self.queue([Q1, H1, Q2, H2])
        self.play_from(24000)
        self.wait(lambda: self.heard() == H1, 20, .1, 'the first cross-fade')
        time.sleep(1)
        self.play_from(24000)
        self.wait(lambda: self.heard() == H1 and (self.status().get('playerPositionMs') or 0) >= 27600,
                  20, .1, 'the middle of the fade to Q2')
        self.post('/v1/playback/adjustments', {'speed': 1.25})
        self.wait(lambda: self.heard() == Q2, 15, .1, 'the hand-over to Q2')
        time.sleep(8)
        self.post('/v1/playback/adjustments', {'speed': 1})
        self.phase = 'crossfade-teardown'
        self.restart(lambda db: db.execute('UPDATE app_settings SET crossfade_enabled=0'))

        for codec, quality in (('opus', {'maxBitRate': 96, 'format': 'opus'}),
                               ('mp3', {'maxBitRate': 128, 'format': 'mp3'})):
            self.phase = f'lossy-{codec}'
            self.post('/v1/playback/quality', {'wifi': quality, 'cellular': quality})
            self.queue([QL, H1])
            self.play_from(2000)
            time.sleep(12)
            self.join(seconds_after=4)
        self.a2()
        self.phase = 'done'
        (self.out / 'a1-final.json').write_text(json.dumps(self.status(), indent=2))

    def remove_above_with_ordering(self):
        """Removes the song above the playing one while a fast poller watches the status's index, and
        logs when the status's index changed relative to the edit's reply. That is the Dart status index
        seen over HTTP, not evidence of the native event order."""
        started, replied, seen = time.time(), [None], [None]
        stop = threading.Event()

        def poll():
            while not stop.is_set():
                try:
                    index = self.status().get('currentIndex')
                except Exception:  # noqa: BLE001
                    continue
                if index == 0 and seen[0] is None:
                    seen[0] = time.time()
        poller = threading.Thread(target=poll, daemon=True)
        poller.start()
        self.post('/v1/playback/queue-edit', {'op': 'remove', 'index': 0})
        replied[0] = time.time()
        time.sleep(.6)
        stop.set()
        poller.join(2)
        order = ('before-reply' if seen[0] is not None and seen[0] <= replied[0]
                 else 'after-reply' if seen[0] is not None else 'not-seen')
        self.ordering.write(json.dumps({'edit': 'remove-above', 'replyMs': round((replied[0] - started) * 1000),
                                        'indexSeenMs': None if seen[0] is None else round((seen[0] - started) * 1000),
                                        'order': order}) + '\n')
        self.ordering.flush()

    def a2(self):
        """A2: song switches and queue edits around a boosted Q: nothing may reach the processor
        above the playing song's own boost, whichever command moved the index."""
        long_queue = [H1, H2, H1, Q1, H2, Q2, H1]
        self.phase = 'a2-skip'
        self.queue([Q1, H1, Q2, H2], repeat='all')
        self.play_from(10000)
        time.sleep(2.5)
        self.post('/v1/playback/next')
        time.sleep(3)
        self.post('/v1/playback/next')
        time.sleep(3)

        self.phase = 'a2-skip-at-the-end'
        self.play_from(26500)
        time.sleep(.5)
        self.post('/v1/playback/next')
        time.sleep(3)

        self.phase = 'a2-jump'
        self.queue([Q1, H1, Q2, H2], repeat='all')
        self.play_from(26500)
        time.sleep(.5)
        self.post('/v1/playback/queue-index', {'index': 1})
        time.sleep(3)
        self.post('/v1/playback/queue-index', {'index': 2})
        time.sleep(3)

        self.phase = 'a2-remove-current'
        self.queue([Q1, H1, Q2, H2])
        self.play_from(26500)
        time.sleep(.5)
        self.post('/v1/playback/queue-edit', {'op': 'remove', 'index': 0})
        time.sleep(4)
        self.queue([Q1, H1, Q2, H2])
        self.play_from(10000)
        time.sleep(1)
        self.post('/v1/playback/queue-edit', {'op': 'remove', 'index': 0})
        time.sleep(3)

        self.phase = 'a2-edit-above'
        for position in (10000, 26500):
            self.queue(long_queue)
            self.post('/v1/playback/queue-index', {'index': 3})
            self.play_from(position)
            time.sleep(.6)
            for _ in range(3):
                self.post('/v1/playback/queue-edit', {'op': 'remove', 'index': 0})
                time.sleep(.3)
            time.sleep(4)
        self.queue(long_queue)
        self.post('/v1/playback/queue-index', {'index': 3})
        self.play_from(10000)
        self.post('/v1/playback/queue-edit', {'op': 'move', 'from': 0, 'to': 6})
        time.sleep(3)

        # Q (boost 10) is the last song and plays to the end; Play, or an insert that resumes,
        # then seeks to another song while Dart still holds Q's value.
        self.phase = 'a2-play-completed'
        self.queue([H1, Q1])
        self.post('/v1/playback/queue-index', {'index': 1})
        self.play_from(28500)
        self.wait(lambda: self.status().get('processingState') == 'completed', 20, .2, 'the queue to complete')
        time.sleep(1)
        self.post('/v1/playback/play')
        time.sleep(4)

        self.phase = 'a2-insert-resume'
        self.queue([H1, Q1])
        self.post('/v1/playback/queue-index', {'index': 1})
        self.play_from(28500)
        self.wait(lambda: self.status().get('processingState') == 'completed', 20, .2, 'the queue to complete')
        time.sleep(1)
        self.post('/v1/playback/queue-edit', {'op': 'add', 'songIds': [H2]})
        time.sleep(4)

        # Z1: a 2x to 1x drop with 5 s of Q left (inside the window at 2x, outside it at 1x), then an
        # action that changes the index, the loop mode or the play order. Q's next song is H, so any
        # value above 0 sent before the song changes is the old song's own boost on H's samples.
        # The remove-above case is repeated 5 times, each with an ordering probe: does the native
        # index event (the status's currentIndex) land before or after the edit's reply?
        actions = [f'remove-above-{n}' for n in range(1, 6)] + ['insert-above', 'loop', 'shuffle']
        for action in actions:
            self.phase = f'a2-latch-{action}'
            self.post('/v1/playback/adjustments', {'speed': 2})
            self.queue([H2, Q1, H1])
            self.post('/v1/playback/queue-index', {'index': 1})
            self.play_from(24000)
            time.sleep(.5)
            self.post('/v1/playback/adjustments', {'speed': 1})
            time.sleep(.3)
            if action.startswith('remove-above'):
                self.remove_above_with_ordering()
            elif action == 'insert-above':
                # Insert above the playing Q: an append, then a move of the new entry to the top.
                self.post('/v1/playback/queue-edit', {'op': 'add', 'songIds': [H2]})
                self.post('/v1/playback/queue-edit', {'op': 'move', 'from': 3, 'to': 0})
            elif action == 'loop':
                self.post('/v1/playback/repeat', {'mode': 'all'})
            else:
                self.post('/v1/playback/shuffle', {'enabled': True})
            time.sleep(3.5)
            self.post('/v1/playback/repeat', {'mode': 'none'})
            self.post('/v1/playback/shuffle', {'enabled': False})
        self.post('/v1/playback/adjustments', {'speed': 1})

        # A duplicate entry of Q: the second copy is a new play, not guarded from its start.
        self.phase = 'a2-duplicate'
        self.queue([Q1, Q1, H1])
        self.play_from(26000)
        time.sleep(9)

        # Repeat-one wraps Q onto itself; repeat off in the second pass must not leave Q guarded.
        self.phase = 'a2-repeat-one-wrap'
        self.queue([Q1, H1], repeat='one')
        self.play_from(26500)
        self.wait(lambda: (self.status().get('playerPositionMs') or 99999) < 4000, 15, .1, 'the repeat-one wrap')
        time.sleep(1.5)
        self.post('/v1/playback/repeat', {'mode': 'none'})
        time.sleep(3)

        self.phase = 'a2-speed'
        self.queue([Q1, H1])
        self.post('/v1/playback/adjustments', {'speed': 2})
        self.play_from(24000)  # 6 s of song left: 3 s of wall clock, inside the window
        time.sleep(.8)
        self.post('/v1/playback/adjustments', {'speed': 1})
        time.sleep(4)
        self.post('/v1/playback/adjustments', {'speed': 1})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serial', required=True)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--reuse-apk', action='store_true', help='install output/app.apk instead of building')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    Run(args).run()
    return 0


if __name__ == '__main__':
    sys.exit(main())
