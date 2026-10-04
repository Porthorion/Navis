#!/usr/bin/env python3
"""Stress seeking on never-played songs from a live Subsonic server.

Builds (or reuses) a muted Linux profile build in clone diagnostics mode,
signs a fresh isolated profile into the server named by a mode-600 JSON
credential file ({"url", "username", "password"}), and plays songs the profile
has never cached: library songs found through the server's random songs and
remote (external) songs found through search. Each case plays one song, seeks
in a pattern and samples GET /v1/playback/status until the seek settles,
recording whether the native player landed, restarted from the beginning,
ended, or changed song.

The profile lives under build/live-seek/root, never the user's own profile or
download folder; each run writes build/live-seek/runs/<stamp>/report.json.
Remote cases make the server fetch those songs on first play.

  NAVIS_LIVE_SEEK_CREDENTIALS=/path/creds.json \
    python3 tool/live_seek_stress.py --quality wifi,cellular \
      --sources library,remote --cases far,mid,back,burst,paused
"""

from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import http.client
import json
import os
import random
import re
import secrets
import shutil
import signal
import sqlite3
import stat
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlencode, urlsplit
from urllib.request import Request, urlopen

PROJECT = Path(__file__).resolve().parents[1]
BASE = PROJECT / 'build' / 'live-seek'
ROOT = BASE / 'root'
USED = BASE / 'used-songs.json'
REMOTE_QUERIES = [
    'Daft Punk', 'Radiohead', 'Muse', 'Gorillaz', 'Massive Attack',
    'Air', 'Justice', 'Phoenix', 'Moderat', 'Bonobo', 'Caribou', 'Tame Impala',
]
CASES = {
    # name: (seek targets as fractions of the duration, early, paused)
    'far': ([0.75], True, False),
    'mid': ([0.55], False, False),
    'back': ([0.6, 0.15], False, False),
    'burst': ([0.3, 0.7, 0.45], False, False),
    'paused': ([0.65], False, True),
    # A 500-song queue, seeking while the rest of it is still being filled.
    'queue': ([0.7], True, False),
}
QUEUE_LENGTH = 500


class Failure(RuntimeError):
    pass


def load_credentials(path: str) -> dict:
    file = Path(path).expanduser()
    if not file.is_file():
        raise Failure('credential file not found')
    if stat.S_IMODE(file.stat().st_mode) & 0o077:
        raise Failure('credential file must be mode 600')
    data = json.loads(file.read_text())
    for key in ('url', 'username', 'password'):
        if not isinstance(data.get(key), str) or not data[key]:
            raise Failure(f'credential file lacks {key}')
    return data


class Server:
    """Direct Subsonic calls, used only to choose songs."""

    def __init__(self, credentials: dict):
        self.base = credentials['url'].rstrip('/') + '/rest/'
        self.username = credentials['username']
        self.password = credentials['password']

    def call(self, method: str, **params) -> dict:
        salt = secrets.token_hex(6)
        token = hashlib.md5((self.password + salt).encode()).hexdigest()
        query = urlencode({'u': self.username, 't': token, 's': salt,
                           'v': '1.16.1', 'c': 'navis-live-seek', 'f': 'json',
                           **params})
        # Some reverse proxies reject urllib's default user agent.
        request = Request(self.base + method + '.view?' + query,
                          headers={'User-Agent': 'Navis live seek stress'})
        with urlopen(request, timeout=30) as r:
            body = json.load(r)['subsonic-response']
        if body.get('status') != 'ok':
            raise Failure(f'{method} failed')
        return body


class ThrottledProxy:
    """A loopback reverse proxy to the server with a shared bandwidth limit
    and added first-byte latency, approximating a phone's connection.

    Range requests and their answers pass through unchanged, so the server's
    own seeking behaviour (206 or a linear 200) is preserved.
    """

    PORT = 47391

    def __init__(self, upstream: str, kbps: int, latency_ms: int):
        target = urlsplit(upstream)
        self.secure = target.scheme == 'https'
        self.host = target.hostname
        self.upstream_port = target.port or (443 if self.secure else 80)
        self.rate = kbps * 1000 / 8
        self.latency = latency_ms / 1000
        self.tokens = 0.0
        self.requests = 0
        self.stamp = time.monotonic()
        self.lock = threading.Lock()
        proxy = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_HEAD(self):
                proxy.forward(self, body=False)

            def do_GET(self):
                proxy.forward(self, body=True)

            def do_POST(self):
                proxy.forward(self, body=True)

        self.server = ThreadingHTTPServer(('127.0.0.1', self.PORT), Handler)
        self.server.daemon_threads = True
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    @property
    def url(self) -> str:
        return f'http://127.0.0.1:{self.PORT}'

    def take(self, size: int):
        while True:
            with self.lock:
                now = time.monotonic()
                self.tokens = min(self.rate, self.tokens + (now - self.stamp) * self.rate)
                self.stamp = now
                if self.tokens >= size:
                    self.tokens -= size
                    return
                missing = size - self.tokens
            time.sleep(missing / self.rate)

    def forward(self, handler, body: bool):
        self.requests += 1
        connection_type = (http.client.HTTPSConnection if self.secure
                           else http.client.HTTPConnection)
        upstream = connection_type(self.host, self.upstream_port, timeout=120)
        headers = {k: v for k, v in handler.headers.items()
                   if k.lower() in ('range', 'user-agent', 'accept',
                                    'content-type', 'icy-metadata')}
        length = int(handler.headers.get('Content-Length') or 0)
        payload = handler.rfile.read(length) if length else None
        try:
            time.sleep(self.latency)
            upstream.request(handler.command, handler.path, body=payload,
                             headers=headers)
            response = upstream.getresponse()
            handler.send_response(response.status)
            for key in ('Content-Type', 'Content-Length', 'Content-Range',
                        'Accept-Ranges', 'Content-Disposition'):
                value = response.getheader(key)
                if value:
                    handler.send_header(key, value)
            handler.send_header('Connection', 'close')
            handler.end_headers()
            if not body:
                return
            while True:
                chunk = response.read(16384)
                if not chunk:
                    break
                self.take(len(chunk))
                handler.wfile.write(chunk)
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception:
            try:
                handler.send_error(502)
            except Exception:
                pass
        finally:
            upstream.close()

    def close(self):
        self.server.shutdown()


def point_profile_at(url: str):
    """Points the isolated profile's server at [url] (the proxy or the real
    server). The profile signs in with the credential file either way."""
    database = ROOT / 'navis.sqlite'
    if not database.exists():
        return
    with sqlite3.connect(database) as connection:
        connection.execute('UPDATE server_config SET url = ?', (url,))


class App:
    def __init__(self, run: Path, platform: str):
        self.run = run
        self.platform = platform
        self.proc = None
        self.port = None
        self.token = None
        self.log = None

    def api(self, path: str, body=None, timeout=60):
        request = Request(
            f'http://127.0.0.1:{self.port}{path}',
            data=None if body is None else json.dumps(body).encode(),
            headers={'Authorization': f'Bearer {self.token}',
                     'Content-Type': 'application/json'})
        with urlopen(request, timeout=timeout) as response:
            raw = response.read()
            return json.loads(raw) if raw else {}

    def launch(self):
        handshake = ROOT / 'handshake.json'
        handshake.unlink(missing_ok=True)
        self.log = (self.run / 'app.log').open('a')
        self.proc = subprocess.Popen(
            [str(ROOT / 'bundle' / 'navis')], cwd=ROOT, stdout=self.log,
            stderr=subprocess.STDOUT, start_new_session=True)
        wait(lambda: handshake.exists() and handshake.stat().st_size > 0,
             120, 'handshake', self)
        values = json.loads(handshake.read_text())
        self.port, self.token = int(values['port']), str(values['token'])
        if self.api('/v1/health').get('mode') != 'clone':
            raise Failure('refusing to drive a non-clone instance')

    def stop(self):
        if self.proc is None:
            return
        try:
            self.api('/v1/shutdown', {}, timeout=10)
        except Exception:
            pass
        try:
            self.proc.wait(timeout=20)
        except subprocess.TimeoutExpired:
            os.killpg(self.proc.pid, signal.SIGTERM)
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(self.proc.pid, signal.SIGKILL)
        self.proc = None
        if self.log:
            self.log.close()


ANDROID_PACKAGE = 'com.navis.app.navis.liveseek'
ANDROID_ROOT = f'/data/user/0/{ANDROID_PACKAGE}/files/liveseek'
ANDROID_HANDSHAKE = (f'/sdcard/Android/data/{ANDROID_PACKAGE}/files/'
                     'navis-diagnostics/handshake.json')
ANDROID_APK = Path(os.environ.get('NAVIS_LIVE_SEEK_APK', str(BASE / 'android.apk')))


class AndroidApp(App):
    """The same scenario on an Android emulator: a profile sidecar seeded
    with the Linux profile's synced catalog, driven through adb forward."""

    def __init__(self, run: Path, serial: str):
        super().__init__(run, 'android')
        sdk = Path(os.environ.get('ANDROID_HOME', str(Path.home() / 'Android/Sdk')))
        self.adb = [str(sdk / 'platform-tools/adb'), '-s', serial]

    def shell(self, *parts, check=True) -> str:
        result = subprocess.run(self.adb + ['shell', *parts],
                                capture_output=True, text=True)
        if check and result.returncode != 0:
            raise Failure(f'adb shell {parts[0]} failed: {result.stderr.strip()}')
        return result.stdout

    def prepare(self, credentials: dict, server_url: str):
        # A clean install each run: an earlier sign-in can leave the server
        # identity in the sidecar's own storage, overriding the seed.
        subprocess.run(self.adb + ['uninstall', ANDROID_PACKAGE],
                       capture_output=True)
        subprocess.run(self.adb + ['install', str(ANDROID_APK)],
                       check=True, capture_output=True)
        self.shell('am', 'force-stop', ANDROID_PACKAGE)
        self.shell('pm', 'grant', ANDROID_PACKAGE,
                   'android.permission.POST_NOTIFICATIONS', check=False)
        staging = '/data/local/tmp/navis-liveseek'
        self.shell('mkdir', '-p', staging)
        seed = self.run / 'seed.sqlite'
        password = self.run / 'password.tmp'
        password.write_text(credentials['password'] + '\n')
        os.chmod(password, 0o600)
        source = sqlite3.connect(f'file:{ROOT / "navis.sqlite"}?mode=ro',
                                 uri=True)
        copy = sqlite3.connect(seed)
        try:
            source.backup(copy)
            # The backup inherits WAL mode; edits would then stay in a -wal
            # file that is never pushed.
            copy.execute('PRAGMA journal_mode=DELETE')
            copy.execute('UPDATE server_config SET url = ?', (server_url,))
            # Keep streamed FLAC from filling the emulator's data partition.
            copy.execute('UPDATE app_settings SET rolling_cache_budget_mb=512')
            copy.execute('DELETE FROM play_queue_items')
            copy.execute('DELETE FROM play_queue')
            copy.commit()
        finally:
            copy.close()
            source.close()
        try:
            for local in (password, seed):
                subprocess.run(self.adb + ['push', str(local),
                                           f'{staging}/{local.name}'],
                               check=True, capture_output=True)
        finally:
            password.unlink()
            seed.unlink()
        script = (f'mkdir -p {ANDROID_ROOT} && '
                  f'rm -f {ANDROID_ROOT}/navis.sqlite-wal '
                  f'{ANDROID_ROOT}/navis.sqlite-shm && '
                  f'cp {staging}/password.tmp {ANDROID_ROOT}/password && '
                  f'cp {staging}/seed.sqlite {ANDROID_ROOT}/navis.sqlite')
        self.shell('run-as', ANDROID_PACKAGE, 'sh', '-c', f"'{script}'")
        self.shell('rm', '-rf', staging)

    def launch(self):
        self.shell('rm', '-f', ANDROID_HANDSHAKE, check=False)
        self.shell('am', 'start', '-n',
                   f'{ANDROID_PACKAGE}/com.navis.app.navis.MainActivity')

        def handshake():
            text = self.shell('cat', ANDROID_HANDSHAKE, check=False)
            return text if text.strip().startswith('{') else None

        values = json.loads(wait(handshake, 120, 'android handshake',
                                 interval=1))
        forwarded = subprocess.run(
            self.adb + ['forward', 'tcp:0', f'tcp:{values["port"]}'],
            check=True, capture_output=True, text=True)
        self.port, self.token = int(forwarded.stdout.strip()), values['token']
        if self.api('/v1/health').get('mode') != 'clone':
            raise Failure('refusing to drive a non-clone instance')
        wait(lambda: self.api('/v1/playback/bootstrap/status').get('handlerReady'),
             120, 'android handler')

    def stop(self):
        try:
            with (self.run / 'app.log').open('w') as log:
                subprocess.run(self.adb + ['logcat', '-d', '-s', 'flutter:*',
                                           'ExoPlayerImplInternal:*',
                                           'AudioPlayer:*'],
                               stdout=log, stderr=subprocess.STDOUT)
        except Exception:
            pass
        self.shell('am', 'force-stop', ANDROID_PACKAGE, check=False)


def build_android():
    defines = {
        'NAVIS_UPDATE_CHANNEL': 'dev',
        'NAVIS_APP_ID_SUFFIX': '.liveseek',
        'NAVIS_APP_NAME': 'Navis Live Seek',
        'NAVIS_SYNC_DIAGNOSTICS': 'true',
        'NAVIS_SYNC_DIAGNOSTICS_MUTED': 'true',
        'NAVIS_SYNC_DIAGNOSTICS_MODE': 'clone',
        'NAVIS_SYNC_DIAGNOSTICS_ROOT': ANDROID_ROOT,
        'NAVIS_SYNC_DIAGNOSTICS_DB_PATH': f'{ANDROID_ROOT}/navis.sqlite',
        'NAVIS_SYNC_DIAGNOSTICS_HANDSHAKE': '',
        'NAVIS_SYNC_DIAGNOSTICS_CREDENTIAL_PATH': f'{ANDROID_ROOT}/password',
    }
    with (BASE / 'build-android.log').open('w') as log:
        subprocess.run(
            ['flutter', 'build', 'apk', '--profile', '--flavor', 'sideload',
             '--target-platform', 'android-x64',
             *[f'--dart-define={k}={v}' for k, v in defines.items()]],
            cwd=PROJECT, stdout=log, stderr=subprocess.STDOUT, check=True,
            env={**os.environ, 'NAVIS_APP_ID_SUFFIX': '.liveseek',
                 'NAVIS_APP_NAME': 'Navis Live Seek'})
    shutil.copyfile(
        PROJECT / 'build/app/outputs/flutter-apk/app-sideload-profile.apk',
        ANDROID_APK)


def wait(predicate, timeout, label, app: App | None = None, interval=0.1):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        if app and app.proc is not None and app.proc.poll() is not None:
            raise Failure(f'app exited while waiting for {label}')
        time.sleep(interval)
    raise Failure(f'timed out waiting for {label}')


def build(credentials: dict):
    password = ROOT / 'password'
    ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
    password.write_text(credentials['password'] + '\n')
    os.chmod(password, 0o600)
    defines = {
        'NAVIS_UPDATE_CHANNEL': 'dev',
        'NAVIS_APP_ID_SUFFIX': '.liveseek',
        'NAVIS_APP_NAME': 'Navis Live Seek',
        'NAVIS_SYNC_DIAGNOSTICS': 'true',
        'NAVIS_SYNC_DIAGNOSTICS_MUTED': 'true',
        'NAVIS_SYNC_DIAGNOSTICS_MODE': 'clone',
        'NAVIS_SYNC_DIAGNOSTICS_ROOT': str(ROOT),
        'NAVIS_SYNC_DIAGNOSTICS_DB_PATH': str(ROOT / 'navis.sqlite'),
        'NAVIS_SYNC_DIAGNOSTICS_HANDSHAKE': str(ROOT / 'handshake.json'),
        'NAVIS_SYNC_DIAGNOSTICS_CREDENTIAL_PATH': str(password),
    }
    with (BASE / 'build.log').open('w') as log:
        subprocess.run(
            ['flutter', 'build', 'linux', '--profile',
             *[f'--dart-define={k}={v}' for k, v in defines.items()]],
            cwd=PROJECT, stdout=log, stderr=subprocess.STDOUT, check=True,
            env={**os.environ, 'NAVIS_APP_ID_SUFFIX': '.liveseek',
                 'NAVIS_APP_NAME': 'Navis Live Seek'})
    shutil.rmtree(ROOT / 'bundle', ignore_errors=True)
    shutil.copytree(PROJECT / 'build/linux/x64/profile/bundle', ROOT / 'bundle')


def reset_profile():
    for entry in ROOT.iterdir():
        if entry.name in ('bundle', 'password'):
            continue
        if entry.is_dir():
            shutil.rmtree(entry)
        else:
            entry.unlink()


def sign_in(app: App, credentials: dict, network: str, server_url: str):
    app.api('/v1/presentation/onboarding/complete', {})
    wait(lambda: app.api('/v1/session/status').get('phase') != 'loading',
         60, 'session phase', app, interval=0.5)
    session = app.api('/v1/session/status')
    if session.get('phase') != 'ready':
        # The first catalog sync needs automatic sync allowed; later runs
        # keep the synced profile (--keep-profile) and skip this.
        app.api('/v1/diagnostics/overrides',
                {'networkType': 'wifi', 'automaticSyncAllowed': True})
        app.api('/v1/diagnostics/sync-foreground', {'active': True})
        if session.get('phase') == 'unauthenticated':
            app.api('/v1/session/connect', {
                'url': server_url, 'username': credentials['username'],
                'password': credentials['password']}, timeout=120)
        else:
            app.api('/v1/sync/check', {})
        wait(lambda: app.api('/v1/session/status').get('phase') == 'ready',
             1800, 'first catalog sync', app, interval=5)
    app.api('/v1/diagnostics/overrides',
            {'networkType': network, 'automaticSyncAllowed': False})
    volume = app.api('/v1/playback/volume', {'value': 0})
    if volume.get('effectivePlayerVolume') != 0:
        raise Failure('mute could not be confirmed')


def set_network(app: App, network: str):
    app.api('/v1/diagnostics/overrides',
            {'networkType': network, 'automaticSyncAllowed': False})


def used_songs() -> set:
    return set(json.loads(USED.read_text())) if USED.exists() else set()


def mark_used(song_id: str):
    used = used_songs()
    used.add(song_id)
    USED.write_text(json.dumps(sorted(used)))


def library_candidates(server: Server, count: int) -> list[dict]:
    """Never-played server songs of 200-600 s that the synced catalog holds."""
    used = used_songs()
    picked = []
    with sqlite3.connect(f'file:{ROOT / "navis.sqlite"}?mode=ro',
                         uri=True) as catalog:
        for _ in range(10):
            songs = server.call('getRandomSongs', size=50)['randomSongs'].get('song', [])
            for song in songs:
                if (song['id'] not in used
                        and 200 <= song.get('duration', 0) <= 600
                        and all(s['id'] != song['id'] for s in picked)
                        and catalog.execute('SELECT 1 FROM songs WHERE id = ?',
                                            (song['id'],)).fetchone()):
                    picked.append(song)
            if len(picked) >= count:
                break
    return picked[:count]


def remote_candidates(server: Server, count: int) -> list[dict]:
    used = used_songs()
    picked = []
    queries = REMOTE_QUERIES[:]
    random.shuffle(queries)
    for query in queries:
        result = server.call('search3', query=query, songCount=30,
                             albumCount=0, artistCount=0)
        for song in result.get('searchResult3', {}).get('song', []):
            if (song.get('isExternal') and song['id'] not in used
                    and 200 <= song.get('duration', 0) <= 600):
                picked.append({**song, 'query': query})
                break
        if len(picked) >= count:
            break
    return picked[:count]


def search_query(song: dict) -> str:
    if song.get('query'):
        return song['query']
    title = re.sub(r'[\(\[].*?[\)\]]', '', song['title']).strip() or song['title']
    return f"{title} {song.get('artist', '')}".strip()


def native_positions(state: dict) -> list:
    return [entry.get('positionMs') for entry in
            (state.get('native') or {}).get('mediaKitTransport') or []]


def compact(state: dict, started: float) -> dict:
    seek = state.get('seek') or {}
    return {
        't': round(time.monotonic() - started, 2),
        'songId': state.get('songId'),
        'positionMs': state.get('positionMs'),
        'playerPositionMs': state.get('playerPositionMs'),
        'native': (state.get('native') or {}).get('mediaKitTransport'),
        'nativeIndex': (state.get('native') or {}).get('index'),
        'processingState': state.get('processingState'),
        'playing': state.get('playing'),
        'isLoading': state.get('isLoading'),
        'sourceKind': state.get('sourceKind'),
        'seek': {k: seek.get(k) for k in ('generation', 'requestedPositionMs',
                                          'pending', 'stage', 'outcome',
                                          'recoveryAttempts')},
        'recovery': state.get('recovery'),
        'cacheActivity': state.get('cacheActivity'),
        'sidecarCacheActiveSongId': state.get('sidecarCacheActiveSongId'),
        'bufferedPositionMs': state.get('bufferedPositionMs'),
        'durationMs': state.get('durationMs'),
    }


def evaluate(trace: list, song_id: str, target: int, before: int, paused: bool,
             seek_t: float) -> dict:
    after = [s for s in trace if s['t'] >= seek_t]

    def native(s):
        entry = (s['native'] or [None])[0]
        if entry is None:
            return s['playerPositionMs'], s['playing']
        return entry.get('positionMs'), entry.get('playing')

    positions = [(s['t'], native(s)[0]) for s in after]
    changed = any(s['songId'] != song_id for s in after)
    landed_at = next((t for t, p in positions
                      if p is not None and abs(p - target) <= 2000), None)
    # Audio restarted: the native player played forward from near the start,
    # below both the old position and the target. A paused reload that sits
    # at zero until its start position applies is not audible.
    floor = min(before, target) - 3000
    restarted = []
    for previous, current in zip(after, after[1:]):
        (p0, playing0), (p1, playing1) = native(previous), native(current)
        if (None not in (p0, p1) and playing0 and playing1 and p1 > p0
                and p1 < 8000 and p1 < floor):
            restarted.append(current['t'])
    final = after[-1] if after else {}
    final_position = positions[-1][1] if positions else None
    outcome = (final.get('seek') or {}).get('outcome')
    tail = [p for t, p in positions if t >= positions[-1][0] - 2.0] if positions else []
    advancing = len(tail) >= 2 and tail[-1] is not None and tail[0] is not None \
        and tail[-1] - tail[0] >= 500
    stopped = final.get('processingState') in ('idle', 'completed')
    near_final = final_position is not None and \
        final_position >= target - 2000 and not changed
    motion_ok = (not advancing) if paused else advancing
    return {
        'landedAfterS': None if landed_at is None else round(landed_at - seek_t, 2),
        'restartedFromStart': bool(restarted),
        'restartSampleS': None if not restarted else round(restarted[0] - seek_t, 2),
        'songChanged': changed,
        'outcome': outcome,
        'stoppedOrEnded': stopped,
        'finalPositionMs': final_position,
        'motionOk': motion_ok,
        'passed': (landed_at is not None and not restarted and not changed
                   and outcome == 'completed' and not stopped and near_final
                   and motion_ok),
    }


def queue_filler(server: Server, count: int) -> list[dict]:
    """Random server songs the synced profile's catalog also holds."""
    with sqlite3.connect(f'file:{ROOT / "navis.sqlite"}?mode=ro',
                         uri=True) as catalog:
        songs = []
        while len(songs) < count:
            batch = server.call('getRandomSongs', size=500)
            ids = [song['id'] for song in batch['randomSongs'].get('song', [])]
            known = {row[0] for row in catalog.execute(
                f'SELECT id FROM songs WHERE id IN ({",".join("?" * len(ids))})',
                ids)}
            songs += [{'id': i} for i in ids if i in known]
    return songs[:count]


def run_case(app: App, song: dict, source: str, case: str, quality: str,
             results: list, run: Path, server: 'Server'):
    fractions, early, paused = CASES[case]
    duration_ms = int(song['duration']) * 1000
    targets = [int(duration_ms * f) for f in fractions]
    if source == 'remote':
        # Remote songs are not in the catalog: play them from search, as
        # the app does.
        found = app.api('/v1/presentation/search',
                        {'query': search_query(song), 'filter': 'songs'},
                        timeout=40)
        if not any(r['id'] == song['id'] for r in found.get('songs', [])):
            results.append({'case': case, 'source': source, 'quality': quality,
                            'songId': song['id'],
                            'skipped': 'not in search results'})
            return
    mark_used(song['id'])
    started = time.monotonic()
    trace = []
    if source == 'remote':
        app.api('/v1/presentation/search/play', {'songId': song['id']},
                timeout=60)
    elif case == 'queue':
        others = [s['id'] for s in queue_filler(server, QUEUE_LENGTH - 1)
                  if s['id'] != song['id']]
        app.api('/v1/playback/queue', {'songIds': [song['id'], *others]},
                timeout=120)
    else:
        app.api('/v1/playback/start', {'songId': song['id']}, timeout=60)

    def sample():
        state = app.api('/v1/playback/status')
        trace.append(compact(state, started))
        return state

    def playing_here():
        state = sample()
        positions = [p for p in (native_positions(state)
                                 or [state.get('playerPositionMs')]) if p]
        return (state.get('songId') == song['id'] and state.get('playing')
                and state.get('processingState') == 'ready'
                and (not early or any(p > 0 for p in positions)))

    try:
        wait(playing_here, 60, 'song start', app, interval=0.1)
    except Failure:
        (run / 'traces').mkdir(exist_ok=True)
        (run / 'traces' / f'{len(results) + 1:02d}-{quality}-{source}-{case}-nostart.json').write_text(
            json.dumps({'songId': song['id'], 'trace': trace,
                        'status': app.api('/v1/playback/status')}, indent=2))
        raise
    start_ready = round(time.monotonic() - started, 2)
    if not early:
        # Play a few seconds so the stream is established mid-song.
        end = time.monotonic() + 4
        while time.monotonic() < end:
            sample()
            time.sleep(0.1)
    if paused:
        app.api('/v1/playback/pause', {})
    before_state = sample()
    before = (native_positions(before_state) or [before_state.get('playerPositionMs')])[0] or 0
    seek_t = round(time.monotonic() - started, 2)
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        futures = []
        for target in targets:
            futures.append(pool.submit(app.api, '/v1/playback/seek',
                                       {'positionMs': target}, 90))
            if len(targets) > 1:
                time.sleep(0.25)
        quiet_since = None
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            state = sample()
            done = all(f.done() for f in futures) and not (state.get('seek') or {}).get('pending')
            if done:
                quiet_since = quiet_since or time.monotonic()
                if time.monotonic() - quiet_since >= 4:
                    break
            else:
                quiet_since = None
            time.sleep(0.1)
        responses = []
        for future in futures:
            try:
                responses.append(future.result(timeout=5).get('elapsedMs'))
            except Exception as error:
                responses.append(f'error: {type(error).__name__}')
    final_state = app.api('/v1/playback/status')
    verdict = evaluate(trace, song['id'], targets[-1], before, paused, seek_t)
    result = {
        'case': case, 'source': source, 'quality': quality,
        'songId': song['id'], 'suffix': song.get('suffix'),
        'durationMs': duration_ms, 'targetsMs': targets, 'beforeMs': before,
        'startReadyS': start_ready, 'seekAtS': seek_t,
        'seekResponsesMs': responses, **verdict,
        'seekEvents': final_state.get('seekEvents'),
        'startupAttempts': (final_state.get('startupAttempts') or [])[-1:],
    }
    results.append(result)
    (run / 'traces').mkdir(exist_ok=True)
    (run / 'traces' / f'{len(results):02d}-{quality}-{source}-{case}.json').write_text(
        json.dumps({'result': result, 'trace': trace}, indent=2))
    print(json.dumps({k: result[k] for k in (
        'case', 'source', 'quality', 'songId', 'suffix', 'passed',
        'landedAfterS', 'restartedFromStart', 'songChanged', 'outcome',
        'stoppedOrEnded', 'finalPositionMs', 'targetsMs')}), flush=True)
    app.api('/v1/playback/queue/clear', {})


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--credentials',
                        default=os.environ.get('NAVIS_LIVE_SEEK_CREDENTIALS', ''))
    parser.add_argument('--skip-build', action='store_true')
    parser.add_argument('--keep-profile', action='store_true')
    parser.add_argument('--quality', default='wifi,cellular')
    parser.add_argument('--sources', default='library,remote')
    parser.add_argument('--cases', default=','.join(CASES))
    parser.add_argument('--repeat', type=int, default=1)
    parser.add_argument('--label', default='run')
    parser.add_argument('--throttle-kbps', type=int, default=0,
                        help='route the app through a loopback proxy limited '
                             'to this bandwidth (shared by all requests)')
    parser.add_argument('--android', metavar='SERIAL',
                        help='run on this emulator instead of Linux, seeded '
                             'with the synced Linux profile')
    parser.add_argument('--latency-ms', type=int, default=150,
                        help='first-byte latency the proxy adds per request')
    args = parser.parse_args()
    credentials = load_credentials(args.credentials)
    server = Server(credentials)
    server.call('ping')
    BASE.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    run = BASE / 'runs' / f'{stamp}-{args.label}'
    run.mkdir(parents=True)
    if args.android:
        if not args.skip_build or not ANDROID_APK.exists():
            build_android()
        if not (ROOT / 'navis.sqlite').exists():
            raise Failure('sync the Linux profile first; Android seeds from it')
    else:
        if not args.skip_build or not (ROOT / 'bundle' / 'navis').exists():
            build(credentials)
        if not args.keep_profile:
            reset_profile()
    qualities = [q for q in args.quality.split(',') if q]
    sources = [s for s in args.sources.split(',') if s]
    cases = [c for c in args.cases.split(',') if c]
    results = []
    app = AndroidApp(run, args.android) if args.android else App(run, 'linux')
    proxy = None
    if args.throttle_kbps:
        proxy = ThrottledProxy(credentials['url'], args.throttle_kbps,
                               args.latency_ms)
    server_url = proxy.url if proxy else credentials['url']
    if args.android:
        if proxy:
            # The emulator reaches the host's loopback proxy through adb.
            subprocess.run(app.adb + ['reverse', f'tcp:{proxy.PORT}',
                                      f'tcp:{proxy.PORT}'],
                           check=True, capture_output=True)
        app.prepare(credentials, server_url)
    else:
        point_profile_at(server_url)
    try:
        app.launch()
        sign_in(app, credentials, qualities[0], server_url)
        print(json.dumps({'signedIn': app.api('/v1/session/status').get('phase'),
                          'throttled': bool(proxy)}), flush=True)
        if proxy:
            # Fail fast if the app is not routed through the proxy.
            served = proxy.requests
            app.api('/v1/presentation/search', {'query': 'a', 'filter': 'songs'},
                    timeout=40)
            if proxy.requests == served:
                raise Failure('the app is not using the throttling proxy')
        for quality in qualities:
            set_network(app, 'wifi' if quality == 'wifi' else 'cellular')
            for source in sources:
                count = len(cases) * args.repeat
                songs = (library_candidates(server, count) if source == 'library'
                         else remote_candidates(server, count))
                for index, case in enumerate(cases * args.repeat):
                    if index >= len(songs):
                        results.append({'case': case, 'source': source,
                                        'quality': quality, 'skipped': 'no song'})
                        continue
                    try:
                        run_case(app, songs[index], source, case, quality,
                                 results, run, server)
                    except Exception as error:
                        results.append({'case': case, 'source': source,
                                        'quality': quality,
                                        'songId': songs[index]['id'],
                                        'passed': False,
                                        'error': f'{type(error).__name__}: {error}'})
                        print(json.dumps(results[-1]), flush=True)
                        try:
                            app.api('/v1/playback/queue/clear', {})
                        except Exception:
                            pass
                    (run / 'report.json').write_text(json.dumps(
                        {'label': args.label, 'results': results}, indent=2))
    finally:
        app.stop()
        if proxy:
            proxy.close()
            if not args.android:
                point_profile_at(credentials['url'])
    passed = sum(1 for r in results if r.get('passed'))
    ran = sum(1 for r in results if 'passed' in r)
    print(f'PASSED {passed}/{ran}  REPORT={run / "report.json"}')
    (run / 'report.json').write_text(json.dumps(
        {'label': args.label, 'throttleKbps': args.throttle_kbps,
         'latencyMs': args.latency_ms if args.throttle_kbps else 0,
         'results': results}, indent=2))
    return 0 if ran and passed == ran else 1


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Failure as error:
        print(f'ERROR: {error}', file=sys.stderr)
        sys.exit(2)
