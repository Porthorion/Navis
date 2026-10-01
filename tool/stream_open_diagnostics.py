#!/usr/bin/env python3
"""Check how the desktop player opens remote streams that fail, and radio.

Starts a loopback Subsonic fixture whose `stream.view` returns 404 for one
song, puts a recording `yt-dlp` stand-in first on the app's PATH, and launches
an isolated muted Linux profile. Through the authenticated diagnostics API it
then:

1. plays the 404 song and waits for the load to settle. libmpv's built-in
   ytdl hook would hand the failed, credential-bearing URL to yt-dlp; the
   stand-in records every invocation (credential values redacted) so the run
   can require that none happened;
2. plays an ordinary uncached song and requires advancing playback;
3. opens Library > Radio, starts the fixture's Azuracast-style ICY station
   through the station card, requires advancing playback and a now-playing
   poll, captures an app-owned screenshot, and stops the station.

Results are written to build/stream-open-diagnostics/<timestamp>/report.json;
the exit status is 1 when any check fails. Requires ffmpeg (with an MP3
encoder) to make the radio stream.
"""

import json
import os
import pathlib
import re
import shutil
import stat
import subprocess
import threading
import time
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import auth_lifecycle_fixture_server as fixture

ROOT = pathlib.Path(__file__).resolve().parent.parent
PASSWORD = 'stream-open-local-fixture'
ARTIST = {'id': 'stream-artist', 'name': 'Stream Fixture', 'albumCount': 1}
ALBUM = {'id': 'stream-album', 'name': 'Stream Album', 'artist': ARTIST['name'],
         'artistId': ARTIST['id'], 'songCount': 2, 'duration': 6, 'year': 2026,
         'created': '2026-01-01T00:00:00Z'}


def song(song_id, title, track):
    return {'id': song_id, 'title': title, 'album': ALBUM['name'],
            'albumId': ALBUM['id'], 'artist': ARTIST['name'],
            'artistId': ARTIST['id'], 'track': track, 'discNumber': 1,
            'duration': 3, 'bitRate': 352, 'suffix': 'wav',
            'contentType': 'audio/wav', 'type': 'music'}


MISSING = song('stream-missing', 'Missing Stream', 1)
PLAYABLE = song('stream-playable', 'Playable Stream', 2)
SONGS = [MISSING, PLAYABLE]
STATION = 'fixture'
NOW_PLAYING = {'title': 'Fixture Broadcast', 'artist': 'Fixture Radio'}
ICY_METAINT = 8192
LAST_MODIFIED = 1790000000000

requests = []
radio_streams = []
stopping = threading.Event()


def radio_audio():
    if shutil.which('ffmpeg') is None:
        raise RuntimeError('ffmpeg is required to make the radio stream')
    return subprocess.run(
        ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-f', 'lavfi',
         '-i', 'sine=frequency=440:duration=8', '-ac', '1', '-ar', '44100',
         '-c:a', 'libmp3lame', '-b:a', '64k', '-f', 'mp3', '-'],
        check=True, capture_output=True).stdout


def icy_block(title):
    text = f"StreamTitle='{title}';".encode()
    blocks = -(-len(text) // 16)
    return bytes([blocks]) + text.ljust(blocks * 16, b'\0')


class Handler(fixture.Handler):
    audio = b''
    base = ''

    def do_GET(self):
        parsed = urlparse(self.path)
        requests.append(parsed.path)
        if parsed.path == f'/listen/{STATION}/radio.mp3':
            return self._radio()
        if parsed.path == f'/api/nowplaying/{STATION}':
            return self._json({'station': {'shortcode': STATION},
                               'now_playing': {'song': NOW_PLAYING}})
        endpoint = os.path.basename(parsed.path).removesuffix('.view')
        query = {k: v[0] for k, v in parse_qs(parsed.query).items()}
        index = [{'name': 'S', 'artist': [ARTIST]}]
        if endpoint in ('stream', 'download') and query.get('id') == MISSING['id']:
            self.send_response(404)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return None
        if endpoint == 'getInternetRadioStations':
            return self._json(fixture._root(internetRadioStations={
                'internetRadioStation': [{
                    'id': 'stream-radio', 'name': 'Fixture Radio',
                    'streamUrl': f'{self.base}/listen/{STATION}/radio.mp3',
                    'homePageUrl': f'{self.base}/public/{STATION}'}]}))
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
            match = next((s for s in SONGS if s['id'] == query.get('id')), PLAYABLE)
            return self._json(fixture._root(song=match))
        if endpoint == 'search3':
            offset = int(query.get('songOffset', 0))
            count = int(query.get('songCount', 20))
            return self._json(fixture._root(searchResult3={'song': SONGS[offset:offset + count]}))
        return super().do_GET()

    def _radio(self):
        """An endless Icecast-style MP3 stream, paced near real time."""
        metadata = self.headers.get('Icy-MetaData') == '1'
        radio_streams.append({'icyMetadataRequested': metadata})
        self.send_response(200)
        self.send_header('Content-Type', 'audio/mpeg')
        self.send_header('icy-name', 'Fixture Radio')
        if metadata:
            self.send_header('icy-metaint', str(ICY_METAINT))
        self.end_headers()
        audio, offset, sent = self.audio, 0, 0
        looped = audio + audio
        started = time.monotonic()
        title = icy_block(f"{NOW_PLAYING['artist']} - {NOW_PLAYING['title']}")
        try:
            while not stopping.is_set():
                take = ICY_METAINT if metadata else 4096
                chunk = looped[offset:offset + take]
                offset = (offset + take) % len(audio)
                self.wfile.write(chunk + (title if metadata else b''))
                sent += len(chunk)
                # 64 kbit/s, with two seconds sent ahead to fill the buffer.
                ahead = sent / 8000 - (time.monotonic() - started) - 2
                if ahead > 0:
                    time.sleep(ahead)
        except (BrokenPipeError, ConnectionResetError):
            return


def make_ytdl_stand_in(output):
    """Records how a yt-dlp found on PATH would be invoked, then fails."""
    bindir = output / 'bin'
    bindir.mkdir(mode=0o700)
    log = output / 'ytdl-invocations.jsonl'
    stand_in = bindir / 'yt-dlp'
    stand_in.write_text(f'''#!/usr/bin/env python3
import json, re, sys
def redact(arg):
    return re.sub(r'([?&](?:u|p|s|t)=)[^&]*', r'\\1<redacted>', arg)
url = sys.argv[-1] if len(sys.argv) > 1 else ''
record = {{'argv': [redact(a) for a in sys.argv[1:]],
          'credentialQuery': bool(re.search(r'[?&]t=[^&]', url)
                                  and re.search(r'[?&]s=[^&]', url))}}
with open({str(log)!r}, 'a') as f:
    f.write(json.dumps(record) + '\\n')
sys.exit(1)
''')
    stand_in.chmod(stat.S_IRWXU)
    return bindir, log


class ApiError(Exception):
    def __init__(self, route, status, detail):
        super().__init__(f'{route} returned {status}: {detail}')
        self.status = status
        self.detail = detail


def wait_until(check, timeout, description):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = check()
        if result:
            return result
        time.sleep(0.25)
    raise RuntimeError(f'Timed out waiting for {description}')


def main():
    output = ROOT / 'build/stream-open-diagnostics' / time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())
    output.mkdir(parents=True, mode=0o700)
    handshake = output / 'handshake.json'
    credential = output / 'fixture-password'
    credential.write_text(PASSWORD + '\n')
    os.chmod(credential, 0o600)
    bindir, invocation_log = make_ytdl_stand_in(output)
    Handler.audio = radio_audio()
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    server.daemon_threads = True
    Handler.base = f'http://127.0.0.1:{server.server_port}'
    threading.Thread(target=server.serve_forever, daemon=True).start()

    defines = dict(
        NAVIS_UPDATE_CHANNEL='dev', NAVIS_APP_ID_SUFFIX='.dev',
        NAVIS_APP_NAME='Navis Stream Open Diagnostics',
        NAVIS_SYNC_DIAGNOSTICS='true', NAVIS_SYNC_DIAGNOSTICS_MUTED='true',
        NAVIS_SYNC_DIAGNOSTICS_MODE='clone',
        NAVIS_SYNC_DIAGNOSTICS_HANDSHAKE=str(handshake),
        NAVIS_SYNC_DIAGNOSTICS_ROOT=str(output),
        NAVIS_SYNC_DIAGNOSTICS_DB_PATH=str(output / 'navis.sqlite'),
        NAVIS_SYNC_DIAGNOSTICS_CREDENTIAL_PATH=str(credential))
    command = ['flutter', 'run', '-d', 'linux', '--profile',
               *[f'--dart-define={k}={v}' for k, v in defines.items()]]
    environment = {**os.environ, 'PATH': f'{bindir}{os.pathsep}{os.environ["PATH"]}'}
    log_path = output / 'app.log'
    log = open(log_path, 'w')
    process = subprocess.Popen(command, cwd=ROOT, env=environment,
                               stdout=log, stderr=subprocess.STDOUT)
    client = {}

    def api(route, body=None, timeout=60):
        request = urllib.request.Request(
            f'http://127.0.0.1:{client["port"]}{route}',
            data=None if body is None else json.dumps(body).encode(),
            headers={'Authorization': f'Bearer {client["token"]}',
                     'Content-Type': 'application/json'})
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            detail = error.read().decode(errors='replace')[:200]
            raise ApiError(route, error.code, detail) from None

    def advancing(timeout, description):
        first = wait_until(lambda: (lambda s: s if s.get('playing') else None)(
            api('/v1/playback/status')), timeout, description)
        time.sleep(1.5)
        second = api('/v1/playback/status')
        return second.get('playerPositionMs', 0) > first.get('playerPositionMs', 0)

    def invocations():
        if not invocation_log.exists():
            return []
        return [json.loads(line) for line in invocation_log.read_text().splitlines()]

    checks = {}
    details = {}
    failure = None
    try:
        wait_until(lambda: process.poll() is None and handshake.exists()
                   and handshake.stat().st_size > 0, 600, 'the diagnostics handshake')
        client.update(json.loads(handshake.read_text()))
        api('/v1/health')
        api('/v1/session/connect', {'url': Handler.base, 'username': 'diagnostics',
                                    'password': PASSWORD}, timeout=120)
        wait_until(lambda: api('/v1/health')['catalog']['songs'] >= len(SONGS), 180,
                   'the fixture library to sync')
        api('/v1/presentation/onboarding/complete', {})

        # 1. A remote stream that fails to open. The start request may itself
        # report the failed load.
        try:
            started = {'status': 202, 'body': api('/v1/playback/start',
                                                  {'songId': MISSING['id']})}
        except ApiError as error:
            started = {'status': error.status, 'body': error.detail}
        wait_until(lambda: any(p.endswith('/stream.view') for p in requests), 60,
                   'the failing stream request')
        settled = wait_until(lambda: (lambda s: s if not s.get('isLoading') else None)(
            api('/v1/playback/status')), 60, 'the failed load to settle')
        # A hook subprocess runs inside the load, before mpv reports failure.
        time.sleep(3)
        app_log = log_path.read_text(errors='replace')
        details['failedStream'] = {
            'startResponse': started,
            'processingState': settled.get('processingState'),
            'playing': settled.get('playing'),
            'streamRequests': sum(p.endswith('/stream.view') for p in requests),
            'openFailuresLogged': app_log.count('Failed to open'),
            'ytdlHookLogLines': app_log.count('ytdl_hook'),
            'ytdlInvocations': invocations(),
        }
        checks['failedStreamOpened'] = details['failedStream']['streamRequests'] > 0
        checks['noYtdlInvocation'] = not details['failedStream']['ytdlInvocations']
        checks['noYtdlHookLog'] = details['failedStream']['ytdlHookLogLines'] == 0
        checks['failedStreamNotPlaying'] = not settled.get('playing')

        # 2. An ordinary uncached stream still plays.
        api('/v1/playback/start', {'songId': PLAYABLE['id']})
        checks['playableStreamAdvances'] = advancing(60, 'the playable song')

        # 3. Azuracast-style ICY internet radio.
        api('/v1/presentation/navigate', {'location': '/library?section=radio'})

        def start_station():
            try:
                return api('/v1/presentation/library-action',
                           {'action': 'toggleFirstRadioStation'})
            except ApiError as error:
                if error.status == 503:
                    return None
                raise
        wait_until(start_station, 60, 'the radio station card')
        wait_until(lambda: api('/v1/session/status')['activity']['radio'], 60,
                   'radio mode')
        checks['radioAdvances'] = advancing(60, 'radio playback')
        wait_until(lambda: f'/api/nowplaying/{STATION}' in requests, 30,
                   'the now-playing poll')
        time.sleep(1)
        screenshot = api('/v1/presentation/screenshot', {'label': 'radio-playing'})
        details['radio'] = {
            'streams': radio_streams,
            'nowPlayingPolls': requests.count(f'/api/nowplaying/{STATION}'),
            'screenshot': screenshot.get('artifact'),
        }
        checks['radioIcyRequested'] = any(s['icyMetadataRequested'] for s in radio_streams)
        api('/v1/presentation/library-action', {'action': 'toggleFirstRadioStation'})
        checks['radioStops'] = bool(wait_until(
            lambda: not api('/v1/session/status')['activity']['radio'], 30,
            'radio to stop'))
        checks['noYtdlInvocationAtEnd'] = not invocations()
    except Exception as error:  # noqa: BLE001 - reported below
        failure = f'{type(error).__name__}: {error}'
    finally:
        try:
            api('/v1/shutdown', {})
            process.wait(timeout=20)
        except Exception:
            process.terminate()
        stopping.set()
        log.close()
        server.shutdown()

    passed = failure is None and checks and all(checks.values())
    report = {'status': 'passed' if passed else 'failed', 'failure': failure,
              'checks': checks, 'details': details}
    (output / 'report.json').write_text(json.dumps(report, indent=2))
    failed = [name for name, ok in checks.items() if not ok]
    print(f"{report['status']}: {len(checks) - len(failed)} of {len(checks)} checks passed"
          f"{' (failed: ' + ', '.join(failed) + ')' if failed else ''}"
          f"{'; ' + failure if failure else ''}; see {output / 'report.json'}")
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
