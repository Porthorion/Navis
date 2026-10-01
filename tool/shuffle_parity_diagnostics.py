#!/usr/bin/env python3
"""Check that the song Navis reports is the song the desktop player plays.

Starts a loopback Subsonic fixture with a 40-song album, launches an isolated
muted Linux profile against an empty database, turns shuffle on, presses Next
five times and lets two tracks advance on their own. After each step it
compares the reported `songId` with the song media_kit/mpv is actually playing
(`native.mediaKitCurrent` in `GET /v1/playback/status`).

It then queues 2,000 songs (the album 50 times), jumps far ahead, near, far
back and to both ends, presses Previous across the released head and lets
songs play on, checking parity, that the reported index is the one asked for,
that head + materialised + tail add up to the queue, and that the native
playlist stays bounded (the released window). Results are written to
build/shuffle-parity-diagnostics/<timestamp>/report.json; the exit status is 1
when any sample disagrees.

Set NAVIS_PARITY_BUNDLE to a built profile bundle to skip `flutter run`.
"""

import io
import json
import math
import os
import pathlib
import struct
import subprocess
import threading
import time
import urllib.error
import urllib.request
import wave
from http.server import ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import auth_lifecycle_fixture_server as fixture

ROOT = pathlib.Path(__file__).resolve().parent.parent
SONG_COUNT = 40
SECONDS = 3
ARTIST = {'id': 'parity-artist', 'name': 'Parity Fixture', 'albumCount': 1}
ALBUM = {'id': 'parity-album', 'name': 'Parity Album', 'artist': 'Parity Fixture',
         'artistId': 'parity-artist', 'songCount': SONG_COUNT,
         'duration': SONG_COUNT * SECONDS, 'year': 2026,
         'created': '2026-01-01T00:00:00Z'}
SONGS = [{'id': f'parity-song-{i:02d}', 'title': f'Parity {i:02d}',
          'album': ALBUM['name'], 'albumId': ALBUM['id'], 'artist': ARTIST['name'],
          'artistId': ARTIST['id'], 'track': i + 1, 'discNumber': 1,
          'duration': SECONDS, 'bitRate': 352, 'suffix': 'wav',
          'contentType': 'audio/wav', 'type': 'music'}
         for i in range(SONG_COUNT)]
LAST_MODIFIED = 1790000000000


def tone():
    out = io.BytesIO()
    with wave.open(out, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(22050)
        w.writeframes(b''.join(
            struct.pack('<h', int(3000 * math.sin(2 * math.pi * 440 * i / 22050)))
            for i in range(22050 * SECONDS)))
    return out.getvalue()


AUDIO = tone()


class Handler(fixture.Handler):
    def do_GET(self):
        parsed = urlparse(self.path)
        endpoint = os.path.basename(parsed.path).removesuffix('.view')
        query = {k: v[0] for k, v in parse_qs(parsed.query).items()}
        index = [{'name': 'P', 'artist': [ARTIST]}]
        if endpoint in ('stream', 'download'):
            return self._bytes(AUDIO, 'audio/wav')
        if endpoint == 'getArtists':
            return self._json(fixture._root(artists={'lastModified': LAST_MODIFIED, 'index': index}))
        if endpoint == 'getIndexes':
            return self._json(fixture._root(indexes={'lastModified': LAST_MODIFIED, 'index': index}))
        if endpoint == 'getArtist':
            return self._json(fixture._root(artist={**ARTIST, 'album': [ALBUM]}))
        if endpoint == 'getAlbumList2':
            first = query.get('offset', '0') == '0'
            return self._json(fixture._root(albumList2={'album': [ALBUM] if first else []}))
        if endpoint == 'getAlbum':
            return self._json(fixture._root(album={**ALBUM, 'song': SONGS}))
        if endpoint == 'getSong':
            song = next((s for s in SONGS if s['id'] == query.get('id')), SONGS[0])
            return self._json(fixture._root(song=song))
        if endpoint == 'search3':
            offset = int(query.get('songOffset', 0))
            count = int(query.get('songCount', 20))
            return self._json(fixture._root(searchResult3={'song': SONGS[offset:offset + count]}))
        return super().do_GET()


LONG_QUEUE = [song['id'] for song in SONGS] * 50
# behind + trimSlack + current + ahead + a page released early.
NATIVE_BOUND = 32 + 16 + 1 + 32 + 32


def wait_until(check, timeout, description):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = check()
        if result:
            return result
        time.sleep(0.25)
    raise RuntimeError(f'Timed out waiting for {description}')


def main():
    output = ROOT / 'build/shuffle-parity-diagnostics' / time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())
    output.mkdir(parents=True, mode=0o700)
    handshake = output / 'handshake.json'
    credential = output / 'fixture-password'
    credential.write_text('shuffle-parity-local-fixture\n')
    os.chmod(credential, 0o600)
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()

    defines = dict(
        NAVIS_UPDATE_CHANNEL='dev', NAVIS_APP_ID_SUFFIX='.dev',
        NAVIS_APP_NAME='Navis Shuffle Parity Diagnostics',
        NAVIS_SYNC_DIAGNOSTICS='true', NAVIS_SYNC_DIAGNOSTICS_MUTED='true',
        NAVIS_SYNC_DIAGNOSTICS_MODE='clone',
        NAVIS_SYNC_DIAGNOSTICS_HANDSHAKE=str(handshake),
        NAVIS_SYNC_DIAGNOSTICS_ROOT=str(output),
        NAVIS_SYNC_DIAGNOSTICS_DB_PATH=str(output / 'navis.sqlite'),
        NAVIS_SYNC_DIAGNOSTICS_CREDENTIAL_PATH=str(credential))
    bundle = os.environ.get('NAVIS_PARITY_BUNDLE')
    command = [bundle] if bundle else [
        'flutter', 'run', '-d', 'linux', '--profile',
        *[f'--dart-define={k}={v}' for k, v in defines.items()]]
    log = open(output / 'app.log', 'w')
    process = subprocess.Popen(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
    client = {}

    def api(route, body=None, timeout=60):
        request = urllib.request.Request(
            f'http://127.0.0.1:{client["port"]}{route}',
            data=None if body is None else json.dumps(body).encode(),
            headers={'Authorization': f'Bearer {client["token"]}',
                     'Content-Type': 'application/json'})
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.load(response)

    samples = []
    errors = []

    def act(step, route, body):
        try:
            return api(route, body)
        except urllib.error.HTTPError as error:
            detail = error.read().decode(errors='replace')[:300]
            errors.append({'step': step, 'route': route, 'status': error.code, 'detail': detail})
            return None

    def sample(step):
        status = api('/v1/playback/status')
        playing = (status.get('native') or {}).get('mediaKitCurrent') or []
        reported = status.get('songId')
        actual = playing[0] if playing else None
        # Cached sources are named `<songId>_<digest>.<ext>`.
        agrees = actual is not None and reported is not None and (
            actual == reported or actual.startswith(f'{reported}_'))
        samples.append({'step': step, 'reported': reported, 'mediaKit': actual,
                        'agrees': agrees, 'shuffle': status.get('shuffleMode')})
        return agrees

    def window_sample(step, expected_index=None):
        status = api('/v1/playback/status')
        playing = (status.get('native') or {}).get('mediaKitCurrent') or []
        reported = status.get('songId')
        actual = playing[0] if playing else None
        parts = (status.get('deferredHeadLength', 0) + status.get('materializedLength', 0)
                 + status.get('deferredLength', 0))
        checks = {
            'parity': actual is not None and reported is not None and (
                actual == reported or actual.startswith(f'{reported}_')),
            'index': expected_index is None or status.get('currentIndex') == expected_index,
            'song': expected_index is None or reported == LONG_QUEUE[expected_index],
            'parts': parts == len(LONG_QUEUE) and status.get('queueLength') == len(LONG_QUEUE),
            'bounded': status.get('playerSequenceLength', 0) <= NATIVE_BOUND,
        }
        samples.append({'step': step, 'reported': reported, 'mediaKit': actual,
                        'agrees': all(checks.values()), 'checks': checks,
                        'currentIndex': status.get('currentIndex'),
                        'head': status.get('deferredHeadLength'),
                        'materialized': status.get('materializedLength'),
                        'tail': status.get('deferredLength'),
                        'playerSequenceLength': status.get('playerSequenceLength')})

    def settled(index):
        status = api('/v1/playback/status')
        return (status.get('currentIndex') == index and not status.get('isLoading')
                and status.get('playing'))

    failure = None
    try:
        wait_until(lambda: process.poll() is None and handshake.exists()
                   and handshake.stat().st_size > 0, 300, 'the diagnostics handshake')
        client.update(json.loads(handshake.read_text()))
        api('/v1/health')
        api('/v1/session/connect', {'url': f'http://127.0.0.1:{server.server_port}',
                                    'username': 'diagnostics',
                                    'password': 'shuffle-parity-local-fixture'}, timeout=120)
        wait_until(lambda: api('/v1/health')['catalog']['songs'] >= SONG_COUNT, 180,
                   'the fixture library to sync')
        api('/v1/presentation/onboarding/complete', {})
        api('/v1/playback/queue', {'songIds': [s['id'] for s in SONGS]})
        wait_until(lambda: api('/v1/playback/status').get('playing'), 60, 'playback')
        time.sleep(1)
        sample('before shuffle')
        act('shuffle on', '/v1/playback/shuffle', {'enabled': True})
        time.sleep(1)
        sample('after shuffle')
        for press in range(5):
            act(f'next {press + 1}', '/v1/playback/next', {})
            time.sleep(1.2)
            sample(f'next {press + 1}')
        for tick in range(int(SECONDS * 2.5 / 0.5)):
            time.sleep(0.5)
            sample(f'auto-advance {tick * 0.5 + 0.5:.1f}s')

        # The released window on a 2,000-song queue.
        act('shuffle off', '/v1/playback/shuffle', {'enabled': False})
        api('/v1/playback/queue', {'songIds': LONG_QUEUE})
        wait_until(lambda: settled(0), 120, 'the long queue')
        window_sample('long queue', 0)
        for target in (1500, 1540, 1510, 12, len(LONG_QUEUE) - 1, 0, 1000):
            act(f'jump {target}', '/v1/playback/queue-index', {'index': target})
            wait_until(lambda: settled(target), 60, f'jump {target}')
            time.sleep(0.5)
            window_sample(f'jump {target}', target)
        # Previous across the head released by the far jump to 1000.
        for press in range(40):
            act(f'previous {press + 1}', '/v1/playback/previous', {})
            time.sleep(0.15)
        wait_until(lambda: settled(960), 60, 'previous 40')
        window_sample('previous 40', 960)
        # Let songs play on so played ones are trimmed.
        time.sleep(SECONDS * 3)
        window_sample('played on')
    except Exception as error:  # noqa: BLE001 - reported below
        failure = f'{type(error).__name__}: {error}'
    finally:
        try:
            api('/v1/playback/shuffle', {'enabled': False})
            api('/v1/shutdown', {})
            process.wait(timeout=20)
        except Exception:
            process.terminate()
        log.close()
        server.shutdown()

    disagreements = [s for s in samples if not s['agrees']]
    status = 'failed' if failure else ('passed' if not disagreements and not errors else 'diverged')
    report = {'status': status, 'failure': failure, 'errors': errors,
              'samples': samples, 'disagreements': len(disagreements)}
    (output / 'report.json').write_text(json.dumps(report, indent=2))
    print(f"{status}: {len(disagreements)} of {len(samples)} samples disagree, "
          f"{len(errors)} call errors; see {output / 'report.json'}")
    return 0 if status == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
