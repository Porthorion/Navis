#!/usr/bin/env python3
"""Exercise seeks against synthetic streams in a muted disposable profile.

Requires Flutter and ffmpeg. Android requires an already running emulator; a
unique application ID is installed, without clearing another application's data.
All requests go through the authenticated Navis diagnostics API.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
from pathlib import Path
import signal
import shutil
import subprocess
import threading
import time
from http.server import ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse
from urllib.request import Request, urlopen

import auth_lifecycle_fixture_server as fixture

PROJECT = Path(__file__).resolve().parents[1]


# --- Navidrome-like transcoding fixture ------------------------------------
#
# Shared with tool/live_seek_stress.py (--server fixture). stream.view behaves
# like Navidrome 0.64 as probed against the live server: original quality is a
# plain file with Range support; any format/maxBitRate request is an ffmpeg
# transcode answered HTTP 200, chunked (no Content-Length), `Accept-Ranges:
# none`, Range ignored. `timeOffset` is honoured while the OpenSubsonic
# `transcodeOffset` extension is advertised.
TRANSCODES = {
    'opus': ('libopus', 'ogg', 'audio/ogg'),
    'mp3': ('libmp3lame', 'mp3', 'audio/mpeg'),
    'aac': ('aac', 'adts', 'audio/aac'),
}


class TranscodeLibrary:
    """Artists x albums x tracks with mixed lengths: every album's first track
    is 3-8 s on half of the albums, and every fourth artist has one recording
    under two song ids (same title and MusicBrainz id, different albums). The
    last `short_artists` artists have only 1-8 s tracks (`self.short`), so a
    shuffle of one reaches natural song ends within seconds."""

    def __init__(self, cache_dir: Path, artists: int = 40, albums: int = 3, tracks: int = 5,
                 short_artists: int = 0):
        self.cache_dir = cache_dir
        cache_dir.mkdir(parents=True, exist_ok=True)
        self.artists: dict[str, dict] = {}
        self.albums: dict[str, dict] = {}
        self.songs: dict[str, dict] = {}
        self.media_seconds: dict[str, int] = {}
        self.album_songs: dict[str, list[str]] = {}
        self.duplicates: dict[str, str] = {}
        self.short = {f'ar{a}' for a in range(artists - short_artists, artists)}
        for a in range(artists):
            artist_id = f'ar{a}'
            self.artists[artist_id] = {'id': artist_id, 'name': f'Stress Artist {a:02d}', 'coverArt': 'fixture-cover'}
            for b in range(albums):
                album_id = f'al{a}-{b}'
                ids = []
                for t in range(1, tracks + 1):
                    if artist_id in self.short:
                        seconds = (1, 2, 3, 5, 8)[(t + a + b) % 5]
                    elif t == 1:
                        seconds = (3, 4, 5, 6, 7, 8)[((a + b) // 2) % 6] if (a + b) % 2 == 0 else 120
                    else:
                        seconds = 300  # Item 10: seek beyond a partial download in a >=4-minute FLAC.
                    song_id = f's{a}-{b}-{t}'
                    ids.append(song_id)
                    self._add_song(song_id, f'Stress {a:02d}-{b}-{t}', artist_id, album_id, t, seconds, f'mbid-{song_id}')
                if b == 2 and a % 4 == 0:
                    original = self.songs[f's{a}-0-2']
                    dup_id = f'd{a}'
                    ids.append(dup_id)
                    self._add_song(dup_id, original['title'], artist_id, album_id, tracks + 1, original['duration'], original['musicBrainzId'])
                    self.duplicates[dup_id] = original['id']
                self.album_songs[album_id] = ids
                self.albums[album_id] = {
                    'id': album_id, 'name': f'Stress Album {a:02d}-{b}', 'artist': self.artists[artist_id]['name'],
                    'artistId': artist_id, 'songCount': len(ids), 'year': 2000 + b,
                    'duration': sum(self.songs[i]['duration'] for i in ids), 'coverArt': 'fixture-cover',
                    'created': f'2026-0{1 + b}-{1 + a % 27:02d}T00:00:00Z',
                }
            self.artists[artist_id]['albumCount'] = albums
        for artist in self.artists.values():
            artist['songCount'] = sum(len(self.album_songs[i]) for i, album in self.albums.items() if album['artistId'] == artist['id'])

    def _add_song(self, song_id, title, artist_id, album_id, track, seconds, mbid):
        path = self.media_path(seconds)
        size = path.stat().st_size
        self.media_seconds[song_id] = seconds
        self.songs[song_id] = {
            'id': song_id, 'title': title, 'album': 'Stress Album ' + '-'.join(f'{int(n):02d}' if i == 0 else n for i, n in enumerate(album_id[2:].split('-'))),
            'albumId': album_id, 'artist': self.artists[artist_id]['name'], 'artistId': artist_id,
            'track': track, 'duration': seconds, 'bitRate': round(size * 8 / seconds / 1000),
            'contentType': 'audio/flac', 'suffix': 'flac', 'size': size, 'coverArt': 'fixture-cover',
            'created': '2026-01-01T00:00:00Z', 'musicBrainzId': mbid, 'isDir': False, 'type': 'music',
        }

    def media_path(self, seconds: int) -> Path:
        path = self.cache_dir / f'src-{seconds}.flac'
        if not path.exists():
            # Noise keeps FLAC near a realistic 600-900 kbps.
            temporary = path.with_suffix('.tmp.flac')
            subprocess.run([
                'ffmpeg', '-y', '-hide_banner', '-loglevel', 'error',
                '-f', 'lavfi', '-i', f'anoisesrc=d={seconds}:c=pink:r=44100:a=0.2',
                '-f', 'lavfi', '-i', f'sine=f=440:d={seconds}',
                '-filter_complex', '[0][1]amix=inputs=2:duration=first,aformat=channel_layouts=stereo',
                '-c:a', 'flac', str(temporary)], check=True)
            temporary.rename(path)
        return path

    def sorted_songs(self) -> list[dict]:
        return sorted(self.songs.values(), key=lambda s: s['id'])


def make_transcoding_handler(library: TranscodeLibrary, speed: float = 30.0, advertise_offset: bool = True,
                             first_byte_delay: float = 1.5, static: bool = False):
    """A request handler class; the log of stream requests is on `.requests`.
    `static` answers a transcode like a server that has it cached: complete
    in memory, Content-Length and byte ranges (Navidrome does this for a
    transcode it has already produced)."""
    requests: list[dict] = []

    class TranscodingHandler(fixture.Handler):
        protocol_version = 'HTTP/1.1'
        server_version = 'NavisTranscodeFixture/1.0'

        def _ok(self, **content):
            self._json({'subsonic-response': {
                'status': 'ok', 'version': '1.16.1', 'type': 'navis-fixture', 'serverVersion': '1.0.0',
                'openSubsonic': True, **content}})

        def _album_json(self, album_id, with_songs=False):
            album = dict(library.albums[album_id])
            if with_songs:
                album['song'] = [library.songs[i] for i in library.album_songs[album_id]]
            return album

        def do_GET(self):
            parsed = urlparse(self.path)
            endpoint = os.path.basename(parsed.path).removesuffix('.view')
            query = {k: v[0] for k, v in parse_qs(parsed.query).items()}
            if endpoint == 'getOpenSubsonicExtensions':
                extensions = [{'name': 'transcodeOffset', 'versions': [1]}] if advertise_offset else []
                return self._ok(openSubsonicExtensions=extensions)
            if endpoint == 'ping':
                return self._ok()
            if endpoint in ('getArtists', 'getIndexes'):
                index = [{'name': 'S', 'artist': list(library.artists.values())}]
                if endpoint == 'getIndexes':
                    return self._ok(indexes={'lastModified': fixture.INDEX_LAST_MODIFIED, 'index': index})
                return self._ok(artists={'index': index})
            if endpoint == 'getArtist':
                artist = library.artists.get(query.get('id', ''))
                if artist is None:
                    return self._ok(status='failed', error={'code': 70, 'message': 'Artist not found'})
                albums = [self._album_json(i) for i, a in library.albums.items() if a['artistId'] == artist['id']]
                return self._ok(artist={**artist, 'album': albums})
            if endpoint == 'getAlbumList2':
                albums = sorted(library.albums, key=lambda i: library.albums[i]['created'], reverse=True)
                offset, size = int(query.get('offset', 0)), int(query.get('size', 500))
                return self._ok(albumList2={'album': [self._album_json(i) for i in albums[offset:offset + size]]})
            if endpoint == 'getAlbum':
                if query.get('id') not in library.albums:
                    return self._ok(status='failed', error={'code': 70, 'message': 'Album not found'})
                return self._ok(album=self._album_json(query['id'], True))
            if endpoint == 'getSong':
                song = library.songs.get(query.get('id', ''))
                if song is None:
                    return self._ok(status='failed', error={'code': 70, 'message': 'Song not found'})
                return self._ok(song=song)
            if endpoint == 'getRandomSongs':
                import random
                songs = random.sample(library.sorted_songs(), min(int(query.get('size', 10)), len(library.songs)))
                return self._ok(randomSongs={'song': songs})
            if endpoint == 'getSimilarSongs2':
                # Fixed order so a mix's queue can be checked: the 12 songs after the seed.
                ordered = library.sorted_songs()
                at = next((i for i, s in enumerate(ordered) if s['id'] == query.get('id')), 0)
                similar = [s for s in ordered[at + 1:at + 40] if s['duration'] >= 30][:12]
                return self._ok(similarSongs2={'song': similar})
            if endpoint == 'search3':
                songs = library.sorted_songs()
                text = query.get('query', '').strip('"').lower()
                if text:
                    songs = [s for s in songs if text in s['title'].lower()]
                start, count = int(query.get('songOffset', 0)), int(query.get('songCount', 20))
                return self._ok(searchResult3={'song': songs[start:start + count]})
            if endpoint == 'stream':
                return self._stream(query)
            if endpoint == 'download':
                return self._stream({'id': query.get('id', '')})
            return super().do_GET()

        def _stream(self, query):
            song_id = query.get('id', '')
            song = library.songs.get(song_id)
            if song is None:
                return self._ok(status='failed', error={'code': 70, 'message': 'Song not found'})
            data_path = library.media_path(library.media_seconds[song_id])
            entry = {'at': round(time.time(), 3), 'songId': song_id, 'format': query.get('format'),
                     'maxBitRate': query.get('maxBitRate'), 'timeOffset': query.get('timeOffset'),
                     'range': self.headers.get('Range'), 'bytes': 0, 'aborted': False}
            requests.append(entry)
            fmt = query.get('format') or ('mp3' if query.get('maxBitRate') else None)
            if fmt in (None, 'flac', 'raw'):
                entry['mode'] = 'original'
                data = data_path.read_bytes()
                try:
                    self._bytes(data, 'audio/flac')
                    entry['bytes'] = len(data)
                except (BrokenPipeError, ConnectionResetError):
                    entry['aborted'] = True
                return
            if fmt not in TRANSCODES:
                return self._ok(status='failed', error={'code': 0, 'message': 'Unsupported format'})
            codec, container, content_type = TRANSCODES[fmt]
            kbps = int(query.get('maxBitRate') or 128) or 128
            offset = float(query['timeOffset']) if advertise_offset and query.get('timeOffset') else 0.0
            entry.update(mode='transcode', kbps=kbps, offsetS=offset)
            command = ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-nostdin']
            if offset > 0:
                command += ['-ss', f'{offset}']
            command += ['-i', str(data_path), '-vn', '-c:a', codec, '-b:a', f'{kbps}k', '-f', container, '-']
            if static:
                entry['mode'] = 'transcodeStatic'
                data = subprocess.run(command, capture_output=True).stdout
                time.sleep(first_byte_delay)
                try:
                    self._bytes(data, content_type)
                    entry['bytes'] = len(data)
                except (BrokenPipeError, ConnectionResetError):
                    entry['aborted'] = True
                return
            proc = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            # Navidrome 0.64 answers a transcode after 1-3.5 s (measured).
            time.sleep(first_byte_delay)
            self.send_response(200)
            self.send_header('Content-Type', content_type)
            self.send_header('Transfer-Encoding', 'chunked')
            self.send_header('Accept-Ranges', 'none')
            self.end_headers()
            rate = kbps * 125 * speed
            started = time.monotonic()
            try:
                while True:
                    chunk = proc.stdout.read1(16384)
                    if not chunk:
                        break
                    self.wfile.write(f'{len(chunk):x}\r\n'.encode() + chunk + b'\r\n')
                    self.wfile.flush()
                    entry['bytes'] += len(chunk)
                    ahead = entry['bytes'] / rate - (time.monotonic() - started)
                    if ahead > 0:
                        time.sleep(ahead)
                self.wfile.write(b'0\r\n\r\n')
            except (BrokenPipeError, ConnectionResetError):
                entry['aborted'] = True
            finally:
                proc.kill()
                proc.wait()
                entry['durationS'] = round(time.monotonic() - started, 3)
                self.close_connection = True

    TranscodingHandler.requests = requests
    return TranscodingHandler


class QuietServer(ThreadingHTTPServer):
    """A player that cancels a transfer resets the connection; not an error."""

    daemon_threads = True

    def handle_error(self, request, client_address):
        pass


def start_transcoding_server(library: TranscodeLibrary, **options):
    handler = make_transcoding_handler(library, **options)
    server = QuietServer(('127.0.0.1', 0), handler)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, handler


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', choices=['linux', 'android'], default='linux')
    parser.add_argument('--android-serial')
    parser.add_argument('--codecs', nargs='+', choices=['wav', 'mp3', 'flac', 'opus'], default=['wav', 'mp3', 'flac', 'opus'])
    parser.add_argument('--restarts', type=int, default=2)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if args.platform == 'android' and not args.android_serial:
        parser.error('--android-serial is required')
    if not 1 <= args.restarts <= 5:
        parser.error('--restarts must be between one and five')
    stamp = time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())
    root = (args.output or PROJECT / 'build' / 'seek-reliability' / f'{args.platform}-{stamp}').resolve()
    if root.exists() and any(root.iterdir()):
        parser.error('--output must be a fresh directory')
    root.mkdir(parents=True, mode=0o700, exist_ok=True)
    root.chmod(0o700)
    print(f'Evidence: {root}', flush=True)
    requests = []
    media = {}
    songs = []
    cases = []
    for codec in args.codecs:
        audio_file = root / f'fixture.{codec}'
        subprocess.run(['ffmpeg', '-y', '-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i', 'sine=frequency=440:duration=180', '-ar', '44100' if codec != 'opus' else '48000', '-ac', '2', str(audio_file)], check=True)
        audio = audio_file.read_bytes()
        content_type = {'wav': 'audio/wav', 'mp3': 'audio/mpeg', 'flac': 'audio/flac', 'opus': 'audio/ogg'}[codec]
        for restart in range(args.restarts):
            scenarios = [
                ('early90', [90000], True, False, 'supported'),
                ('early5', [5000], True, False, 'supported'),
                ('ready90', [90000], False, False, 'supported'),
                ('backwardBurst', [90000, 120000, 5000], False, False, 'supported'),
                ('earlyBurst', [90000, 120000, 30000], True, False, 'supported'),
                ('paused90', [90000], False, True, 'supported'),
                ('delayedRange', [90000], True, False, 'delayed'),
                ('unsupportedRange', [90000], False, False, 'unsupported'),
                ('failingRange', [90000], False, False, 'failing'),
                ('completedCache', [90000], False, False, 'fast'),
            ]
            for name, targets, early, paused, mode in scenarios:
                # Each invocation must exercise fresh, uncached songs.
                song_id = f'seek-{stamp.lower()}-{codec}-{restart}-{name}'
                songs.append({**fixture.SONG, 'id': song_id, 'title': f'Seek fixture {codec} {name}', 'track': len(songs) + 1, 'duration': 180, 'size': len(audio), 'suffix': codec, 'contentType': content_type, 'bitRate': round(len(audio) * 8 / 180000)})
                media[song_id] = (audio, content_type, mode)
                cases.append((restart, name, song_id, targets, early, paused, mode))
    fixture.SONG = songs[0]
    fixture.EXTRA_SONGS = {song['id']: song for song in songs[1:]}
    fixture.ALBUM.update(songCount=len(songs), duration=180 * len(songs))

    class Handler(fixture.Handler):
        def do_GET(self):
            parsed = urlparse(self.path)
            query = parse_qs(parsed.query)
            if parsed.path.endswith('search3.view'):
                start = int(query.get('songOffset', ['0'])[0])
                count = int(query.get('songCount', ['100'])[0])
                return self._json(fixture._root(searchResult3={'song': songs[start:start + count]}))
            if parsed.path.endswith('getLyricsBySongId.view'):
                return self._json(fixture._root(lyricsList={'structuredLyrics': [{'synced': True, 'lang': 'en', 'line': [{'start': i * 1000, 'value': f'Fixture line {i}'} for i in range(180)]}]}))
            return super().do_GET()

        def _bytes(self, data, content_type):
            if not content_type.startswith('audio/'):
                return super()._bytes(data, content_type)
            song_id = parse_qs(urlparse(self.path).query).get('id', [''])[0]
            data, content_type, mode = media[song_id]
            range_header = self.headers.get('Range')
            requests.append({'at': round(time.monotonic(), 3), 'songId': song_id, 'range': range_header, 'mode': mode})
            if range_header and mode == 'failing' and not range_header.startswith('bytes=0-'):
                self.send_response(416)
                self.send_header('Content-Range', f'bytes */{len(data)}')
                self.send_header('Content-Length', '0')
                self.end_headers()
                return
            start, end = 0, len(data) - 1
            ranged = bool(range_header) and mode != 'unsupported'
            if ranged:
                left, _, right = range_header[6:].split(',', 1)[0].partition('-')
                start = int(left) if left else 0
                end = min(int(right), end) if right else end
            if range_header and mode == 'delayed':
                time.sleep(1.5)
            body = data[start:end + 1]
            self.send_response(206 if ranged else 200)
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', str(len(body)))
            if mode != 'unsupported':
                self.send_header('Accept-Ranges', 'bytes')
            if ranged:
                self.send_header('Content-Range', f'bytes {start}-{end}/{len(data)}')
            self.end_headers()
            try:
                chunks = 40
                size = max(1, len(body) // chunks)
                for offset in range(0, len(body), size):
                    self.wfile.write(body[offset:offset + size])
                    self.wfile.flush()
                    if mode != 'fast':
                        time.sleep(20 * len(body) / len(data) / chunks)
            except (BrokenPipeError, ConnectionResetError):
                return

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    handshake = root / 'handshake.json'
    defines = {'NAVIS_UPDATE_CHANNEL': 'dev', 'NAVIS_APP_NAME': 'Navis Seek Diagnostics', 'NAVIS_SYNC_DIAGNOSTICS': 'true', 'NAVIS_SYNC_DIAGNOSTICS_MUTED': 'true', 'NAVIS_SYNC_DIAGNOSTICS_MODE': 'clone'}
    log = (root / 'app.log').open('w')
    client = {}
    results = []
    proc = None
    adb = [str(Path(os.environ.get('ANDROID_HOME', str(Path.home() / 'Android/Sdk'))) / 'platform-tools/adb'), '-s', args.android_serial or '']
    package = f'com.navis.app.navis.seekdiag{stamp.lower()}'
    metadata = root / 'build.json'
    remote = f'/data/user/0/{package}/files/seek-diagnostics'
    if args.platform == 'linux':
        defines.update(NAVIS_APP_ID_SUFFIX='.seekdiag', NAVIS_SYNC_DIAGNOSTICS_ROOT=str(root), NAVIS_SYNC_DIAGNOSTICS_DB_PATH=str(root / 'navis.sqlite'), NAVIS_SYNC_DIAGNOSTICS_HANDSHAKE=str(handshake))
        command = ['flutter', 'build', 'linux', '--profile', '--no-pub']
    else:
        defines.update(NAVIS_SYNC_DIAGNOSTICS_ROOT=remote, NAVIS_SYNC_DIAGNOSTICS_DB_PATH=remote + '/navis.sqlite')
        command = ['flutter', 'build', 'apk', '--profile', '--flavor', 'sideload', '--target-platform', 'android-x64', '--no-pub']
    env = {**os.environ, 'NAVIS_APP_ID_SUFFIX': package.removeprefix('com.navis.app.navis'), 'NAVIS_APP_NAME': 'Navis Seek Diagnostics'}

    def shell(*parts):
        return subprocess.run(adb + list(parts), check=True, capture_output=True).stdout

    def api(path, body=None, timeout=50):
        req = Request(f'http://127.0.0.1:{client["port"]}{path}', data=None if body is None else json.dumps(body).encode(), headers={'Authorization': f'Bearer {client["token"]}', 'Content-Type': 'application/json'})
        with urlopen(req, timeout=timeout) as response:
            return json.load(response)

    def wait(predicate, timeout=60):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            value = predicate()
            if value:
                return value
            if proc is not None and proc.poll() is not None:
                raise RuntimeError('app exited before completing the scenario')
            time.sleep(.1)
        raise TimeoutError('scenario deadline expired')

    def status():
        return api('/v1/playback/status')

    def native_position(state):
        native = state.get('native', {}).get('mediaKitTransport')
        if args.platform == 'linux' and native:
            return native[0]['positionMs']
        return state['playerPositionMs']

    def capture(label, metadata_name):
        screenshot = api('/v1/presentation/screenshot', {'label': label})
        (root / metadata_name).write_text(json.dumps(screenshot))
        if args.platform == 'android':
            artifact = Path(screenshot['artifact'])
            if artifact.is_absolute() or '..' in artifact.parts:
                raise RuntimeError('invalid screenshot artifact path')
            destination = root / artifact
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(shell(
                'exec-out', 'run-as', package, 'cat', remote + '/' + str(artifact)))

    def write_report():
        (root / 'report.json').write_text(json.dumps({'platform': args.platform, 'results': results, 'requests': requests, 'qualityGate': os.environ.get('NAVIS_QUALITY_GATE_RESULT', 'not-recorded')}, indent=2))

    def run_case(name, song_id, targets, early, paused, mode):
        mark = len(requests)
        started = time.monotonic()
        trace = []
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            loading = pool.submit(api, '/v1/playback/start', {'songId': song_id})
            if early:
                wait(lambda: any(r['songId'] == song_id for r in requests[mark:]) or loading.done(), 35)
                if loading.done():
                    loading.result(timeout=1)
            else:
                loading.result(timeout=50)
                wait(lambda: status()['processingState'] == 'ready', 35)
            if paused:
                api('/v1/playback/pause', {})
            seeks = []
            for target in targets:
                seeks.append(pool.submit(api, '/v1/playback/seek', {'positionMs': target}))
                if len(targets) > 1:
                    time.sleep(.07)
            # Await the current request's settlement, not a fixed sleep.
            seeks[-1].result(timeout=50)
            loading.result(timeout=50)
            settled = status()
            initial = native_position(settled)
            completed = (settled.get('seek') or {}).get('outcome') == 'completed'
            near = abs(initial - targets[-1]) <= 2000
            for _ in range(12):
                trace.append({'elapsed': round(time.monotonic() - started, 3), **status()})
                time.sleep(.25)
            final = status()
            stable = final['songId'] == song_id and final['queueLength'] == 1 and final['playing'] == (not paused)
            motion = abs(native_position(final) - initial) < 300 if paused else native_position(final) - initial >= 500
            passed = completed and near and stable and motion
            result = {'name': name, 'songId': song_id, 'mode': mode, 'passed': passed, 'targetMs': targets[-1], 'targetReached': near, 'completed': completed, 'transportPreserved': stable, 'motionCorrect': motion, 'settled': settled, 'final': final, 'trace': trace}
            results.append(result)
            write_report()
            print(json.dumps({k: result[k] for k in ['name', 'songId', 'mode', 'passed', 'targetReached', 'completed', 'transportPreserved', 'motionCorrect']}), flush=True)
        if name == 'cachedFileSeek':
            api('/v1/presentation/dismiss-popup', {})
            if args.platform == 'linux':
                api('/v1/presentation/window', {'mode': 'miniPlayer'})
                api('/v1/presentation/window', {'width': 560, 'height': 360})
            capture(song_id.lower(), song_id + '-screenshot.json')
            if args.platform == 'linux':
                api('/v1/presentation/window', {'mode': 'desktop', 'width': 1280, 'height': 800})
            before_lyrics = status()
            api('/v1/presentation/player-overlay', {'surface': 'nowPlaying', 'visible': True})
            capture((song_id.lower() + '-lyrics')[:48], song_id + '-lyrics-screenshot.json')
            after_lyrics = status()
            if (after_lyrics['seek']['generation'] != before_lyrics['seek']['generation']
                    or after_lyrics['songId'] != song_id
                    or abs(native_position(after_lyrics) - native_position(before_lyrics)) > 300):
                raise RuntimeError('opening lyrics changed paused playback')
            api('/v1/presentation/player-overlay', {'surface': 'nowPlaying', 'visible': False})
        api('/v1/playback/queue/clear', {})

    try:
        subprocess.run(command + [f'--dart-define={key}={value}' for key, value in defines.items()], cwd=PROJECT, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
        if args.platform == 'linux':
            shutil.copytree(PROJECT / 'build/linux/x64/profile/bundle', root / 'bundle', dirs_exist_ok=True)
        else:
            shutil.copyfile(PROJECT / 'build/app/outputs/flutter-apk/app-sideload-profile.apk', root / 'app.apk')
        metadata.write_text(json.dumps({'platform': args.platform, 'package': package}))
        if args.platform == 'android':
            shell('install', '-r', str(root / 'app.apk'))
            shell('shell', 'pm', 'grant', package, 'android.permission.POST_NOTIFICATIONS')
            shell('shell', 'run-as', package, 'mkdir', '-p', 'files/seek-diagnostics')
            shell('reverse', f'tcp:{server.server_port}', f'tcp:{server.server_port}')
        for restart in range(args.restarts):
            handshake.unlink(missing_ok=True)
            if args.platform == 'linux':
                proc = subprocess.Popen([str(root / 'bundle/navis')], cwd=PROJECT, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
                wait(lambda: handshake.exists() and handshake.stat().st_size, 90)
                client.update(json.loads(handshake.read_text()))
            else:
                shell('shell', 'am', 'start', '-n', package + '/com.navis.app.navis.MainActivity')
                remote_handshake = f'/sdcard/Android/data/{package}/files/navis-diagnostics/handshake.json'
                def read_android_handshake():
                    try:
                        client.update(json.loads(shell('exec-out', 'cat', remote_handshake)))
                        return True
                    except (ValueError, subprocess.CalledProcessError):
                        return False
                wait(read_android_handshake, 90)
                client['port'] = int(shell('forward', 'tcp:0', f'tcp:{client["port"]}').decode().strip())
            health = api('/v1/health')
            if health.get('mode') != 'clone':
                raise RuntimeError('refusing mutations outside clone mode')
            api('/v1/session/connect', {'url': f'http://127.0.0.1:{server.server_port}', 'username': 'diagnostics', 'password': 'synthetic-seek-fixture'}, 120)
            wait(lambda: api('/v1/health')['catalog']['songs'] >= len(songs), 120)
            api('/v1/presentation/onboarding/complete', {})
            volume = api('/v1/playback/volume', {'value': 0})
            if volume['effectivePlayerVolume'] != 0:
                raise RuntimeError('mute verification failed')
            for case_restart, name, song_id, targets, early, paused, mode in cases:
                if case_restart != restart:
                    continue
                try:
                    run_case(name, song_id, targets, early, paused, mode)
                except Exception as error:
                    if mode not in ['unsupported', 'failing']:
                        raise
                    results.append({'name': name, 'songId': song_id, 'mode': mode,
                                    'passed': False, 'errorType': type(error).__name__,
                                    'final': status()})
                    write_report()
                    print(json.dumps({'name': name, 'mode': mode, 'passed': False,
                                      'errorType': type(error).__name__}), flush=True)
                    api('/v1/playback/queue/clear', {})
                if mode == 'fast':
                    run_case('cachedFileSeek', song_id, [30000], False, True, mode)
            capture(f'seek-reliability-{restart}', f'screenshot-{restart}.json')
            api('/v1/shutdown', {}, 5)
            if proc is not None:
                proc.wait(timeout=15)
                proc = None
            else:
                shell('shell', 'am', 'force-stop', package)
                shell('shell', 'rm', '-f', remote_handshake)
            time.sleep(.3)
    except Exception as error:
        (root / 'failure.json').write_text(json.dumps({'type': type(error).__name__, 'message': str(error)}))
        raise
    finally:
        if proc is not None and proc.poll() is None:
            os.killpg(proc.pid, signal.SIGTERM)
            proc.wait(timeout=15)
        if args.platform == 'android':
            subprocess.run(adb + ['shell', 'am', 'force-stop', package], capture_output=True)
        server.shutdown()
        log.close()
    # Unsupported/failing ranges remain visible; they cannot certify a working
    # server. Supported and delayed ranges must always meet seek acceptance.
    required = [r for r in results if r['mode'] not in ['unsupported', 'failing']]
    return 0 if all(r['passed'] for r in required) else 1


if __name__ == '__main__':
    raise SystemExit(main())
