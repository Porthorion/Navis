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
import statistics
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
        self.set_profile(kbps, latency_ms)
        self.tokens = 0.0
        self.requests = 0
        # One compact record per proxied request (no credentials), for the
        # matrix reports.
        self.log: list[dict] = []
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

        class QuietServer(ThreadingHTTPServer):
            daemon_threads = True

            def handle_error(self, request, client_address):
                pass

        self.server = QuietServer(('127.0.0.1', self.PORT), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def set_profile(self, kbps: int, latency_ms: int):
        """Changes the shared bandwidth (0 = unlimited) and added latency."""
        self.rate = kbps * 1000 / 8
        self.latency = latency_ms / 1000

    @property
    def url(self) -> str:
        return f'http://127.0.0.1:{self.PORT}'

    def take(self, size: int):
        if not self.rate:
            return
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
        parts = urlsplit(handler.path)
        params = dict(pair.split('=', 1) for pair in parts.query.split('&') if '=' in pair)
        entry = {'w': round(time.time(), 3),
                 'endpoint': parts.path.rsplit('/', 1)[-1].removesuffix('.view'),
                 'id': params.get('id'), 'format': params.get('format'),
                 'maxBitRate': params.get('maxBitRate'),
                 'timeOffset': params.get('timeOffset'),
                 'range': handler.headers.get('Range'), 'bytes': 0}
        if entry['endpoint'] in ('stream', 'download'):
            self.log.append(entry)
        try:
            time.sleep(self.latency)
            upstream.request(handler.command, handler.path, body=payload,
                             headers=headers)
            response = upstream.getresponse()
            entry['status'] = response.status
            entry['contentLength'] = response.getheader('Content-Length')
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
                entry['bytes'] += len(chunk)
        except (BrokenPipeError, ConnectionResetError):
            entry['aborted'] = True
        except Exception:
            try:
                handler.send_error(502)
            except Exception:
                pass
        finally:
            entry['endW'] = round(time.time(), 3)
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
            # Keep streamed FLAC from filling the emulator's data partition
            # (the phone AVD has only ~500 MB free; a full disk cascades
            # into player and API failures).
            copy.execute('UPDATE app_settings SET rolling_cache_budget_mb=160')
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
        subprocess.run(self.adb + ['logcat', '-c'], capture_output=True)
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

    def trim_cache(self, limit_mb=100):
        """The phone AVD has ~500 MB free and the rolling cache can outgrow
        its budget (a full disk cascades into API 500s): empty it between
        cases, which only use never-played songs anyway."""
        out = self.shell('run-as', ANDROID_PACKAGE, 'sh', '-c',
                         f"'du -sm {ANDROID_ROOT}/cache/audio 2>/dev/null | cut -f1'", check=False)
        if out.strip().isdigit() and int(out.strip()) > limit_mb:
            self.shell('run-as', ANDROID_PACKAGE, 'sh', '-c',
                       f"'rm -rf {ANDROID_ROOT}/cache/audio/rolling/*'", check=False)

    def start_relay(self, port: int):
        self.relay = subprocess.Popen(
            self.adb + ['shell', f'nc -s 127.0.0.1 -p {port} -L nc 10.0.2.2 {port}'],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(1.0)

    def stop(self):
        relay = getattr(self, 'relay', None)
        if relay is not None:
            relay.terminate()
            self.shell('pkill', 'nc', check=False)
        try:
            with (self.run / 'app.log').open('w') as log:
                subprocess.run(self.adb + ['logcat', '-d', '-s', 'flutter:*',
                                           'ExoPlayerImplInternal:*',
                                           'AudioPlayer:*', 'NavisExoDiag:*', '*:E'],
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
        if entry.name in ('bundle', 'password', 'profile-server'):
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


# --- Playback matrix: seek, skip, shuffle and queue cases with oracles -------
#
# `--profile smoke|full` runs the same cases against the live server or the
# Navidrome-like transcoding fixture (`--server fixture`) through the
# throttling proxy, over streaming-quality and bandwidth profiles. Every case
# is judged from 100 ms samples of GET /v1/playback/status and the native
# transport trace; each violation keeps timestamps and a trace excerpt.

QUALITIES = {
    # name: (format, maxBitRate); None means the server's original file.
    'original': (None, None),
    'opus64': ('opus', 64), 'opus96': ('opus', 96),
    'opus128': ('opus', 128), 'opus192': ('opus', 192),
    'mp3_128': ('mp3', 128), 'mp3_320': ('mp3', 320),
    'aac_128': ('aac', 128), 'aac_256': ('aac', 256),
}
THROTTLES = {  # name: (kbps, added first-byte latency ms); 0 = unlimited
    'none': (0, 0), 'wan6000': (6000, 150), 'slow1500': (1500, 300),
}
# Deadlines in seconds by throttle: seek landing, skip audible, stall limit.
DEADLINES = {
    'none': {'land': 15, 'advance': 12, 'stall': 6},
    'wan6000': {'land': 25, 'advance': 20, 'stall': 8},
    'slow1500': {'land': 45, 'advance': 35, 'stall': 12},
}
START_DEADLINE = 45
LAND_TOLERANCE_MS = 1500
SAMPLE_PERIOD = 0.1
RESTART_THRESHOLD_MS = 3000  # navisPreviousTrackRestartThreshold


class CaseAbort(Exception):
    """The case cannot continue (for example the song never started)."""


class Run:
    """One case execution: samples, trace, harness actions and verdicts."""

    def __init__(self, app, backend, case, quality, throttle, rep):
        self.app, self.backend = app, backend
        self.case, self.quality, self.throttle, self.rep = case, quality, throttle, rep
        self.deadlines = DEADLINES[throttle]
        self.t0 = time.monotonic()
        self.w0 = time.time()
        self.samples: list[dict] = []
        self.trace: list[dict] = []
        self.actions: list[dict] = []
        self.futures: list = []
        self.songs: list[dict] = []
        self.queue_ids: list[str] = []
        self.errors: list[str] = []
        self.shuffled = False
        self.checks: list = []
        self.latency_from: list = []
        self.violations: list[dict] = []
        self.latency = None
        self.start_ready = None
        self.metrics: dict = {}
        self._trace_seq = 0

    def now(self) -> float:
        return round(time.monotonic() - self.t0, 3)

    def act(self, kind: str, **fields) -> dict:
        record = {'t': self.now(), 'w': round(time.time(), 3), 'kind': kind, **fields}
        self.actions.append(record)
        return record

    def last(self):
        return self.samples[-1] if self.samples else None

    def ingest(self, state: dict):
        native = state.get('native') or {}
        transport = native.get('mediaKitTransport') or []
        position = (transport[0].get('positionMs') if transport else None)
        if position is None:
            position = state.get('playerPositionMs')
        sequence = native.get('sequenceIds') or []
        native_index = native.get('index')
        ui = state.get('uiPlayback') or {}
        bar = state.get('seekBar') or {}
        cache = state.get('cacheProgress') or {}
        seek = state.get('seek') or {}
        sample = {
            't': self.now(), 'songId': state.get('songId'),
            'idx': state.get('currentIndex'), 'nidx': native_index,
            'nsong': (sequence[native_index] if native_index is not None
                      and 0 <= native_index < len(sequence) else None),
            'pos': position, 'uiPos': ui.get('positionStreamMs'),
            'uiPending': ui.get('pendingSeekMs'),
            'playing': state.get('playing'), 'proc': state.get('processingState'),
            'loading': state.get('isLoading'), 'qlen': state.get('queueLength'),
            'settled': state.get('queueSettled'), 'dur': state.get('durationMs'),
            'buf': state.get('bufferedPositionMs'),
            'bar': bar.get('bufferedMs') if bar.get('songId') == state.get('songId') else None,
            'cacheB': cache.get('receivedBytes'), 'cacheTotal': cache.get('totalBytes'),
            'seekOutcome': seek.get('outcome'), 'seekPending': seek.get('pending'),
            'seekStage': seek.get('stage'), 'rec': (state.get('recovery') or {}).get('stage'),
            'navPending': (state.get('navigation') or {}).get('pending'),
            'src': state.get('sourceKind'), 'mat': state.get('materializedLength'),
            'deferred': state.get('deferredLength'), 'shuffle': state.get('shuffleEnabled'),
            'nseq': sequence[:3],
        }
        self.samples.append(sample)
        for entry in state.get('transportTrace') or []:
            if entry['seq'] > self._trace_seq:
                self._trace_seq = entry['seq']
                self.trace.append({**entry, 'rel': round(entry['atMs'] / 1000 - self.w0, 3)})

    def until(self, predicate, timeout, interval=0.05):
        deadline = time.monotonic() + timeout
        seen = len(self.samples)  # state-based predicates; only newer samples
        while time.monotonic() < deadline:
            fresh = self.samples[seen:]
            seen = len(self.samples)
            for sample in fresh:
                if predicate(sample):
                    return sample
            time.sleep(interval)
        return None

    def observe(self, seconds: float):
        time.sleep(seconds)


class Sampler(threading.Thread):
    def __init__(self, run: Run):
        super().__init__(daemon=True)
        self.run_ref, self.halt = run, threading.Event()

    def run(self):
        while not self.halt.is_set():
            started = time.monotonic()
            try:
                self.run_ref.ingest(self.run_ref.app.api('/v1/playback/status', timeout=20))
            except Exception as error:  # the app may be mid-restart
                self.run_ref.errors.append(f'{self.run_ref.now()}: {type(error).__name__}')
                time.sleep(0.3)
            self.halt.wait(max(0.0, SAMPLE_PERIOD - (time.monotonic() - started)))


def violation(oracle: str, t: float, detail: str, run: Run, passive=False, span=(2.0, 4.0)) -> dict:
    return {'oracle': oracle, 't': round(t, 2), 'detail': detail, 'passive': passive,
            'excerpt': excerpt(run, t, *span)}


def excerpt(run: Run, t: float, before: float, after: float, limit=16) -> list[str]:
    keys = ('processingState', 'playing', 'index', 'songId', 'decision', 'stage', 'phase',
            'action', 'sourceKind', 'format', 'maxBitRate', 'positionMs', 'requestedPositionMs',
            'outcome', 'path', 'reason', 'context', 'requestedIndex', 'fromIndex', 'count',
            'errorCode', 'timeOffset', 'operation', 'timeoutMs')
    lines = []
    for entry in run.trace:
        if t - before <= entry['rel'] <= t + after:
            detail = ' '.join(f'{k}={entry[k]}' for k in keys if entry.get(k) is not None)
            lines.append(f"{entry['rel']:+.2f}s {entry['kind']} {detail}")
    return lines[:limit]


def song_end_near(samples, i) -> bool:
    """Whether the sample before [i] was at (or past) the end of its song."""
    for previous in reversed(samples[max(0, i - 40):i]):
        dur, pos = previous.get('dur'), previous.get('pos')
        if previous.get('proc') == 'completed':
            return True
        if dur and pos is not None and pos >= dur - 5000:
            return True
    return False


def advance_after(run: Run, t: float, index, song_id=None):
    """(reached, advanced): the first sample at [index] after [t] and the first
    later one playing at least 1 s past the lowest position seen there (the
    first samples after a switch can still carry the previous song's)."""
    reached, floor = None, None
    for s in run.samples:
        if s['t'] < t or s['pos'] is None:
            continue
        if reached is None:
            if s['idx'] == index and (song_id is None or s['songId'] == song_id):
                reached, floor = s, s['pos']
            continue
        if s['idx'] != index:
            continue
        floor = min(floor, s['pos'])
        if s['playing'] and s['proc'] == 'ready' and s['pos'] - floor >= 1000:
            return reached, s
    return reached, None


# Oracles -----------------------------------------------------------------

def oracle_seek(run: Run, rec: dict) -> list[dict]:
    out, d = [], run.deadlines
    target, t0 = rec['target'], rec['t']
    after = [s for s in run.samples if s['t'] >= t0 and s['pos'] is not None]
    # The player reports the target as its position while still buffering, so
    # a landing also needs the player to be ready.
    landed = next((s for s in after if abs(s['pos'] - target) <= LAND_TOLERANCE_MS
                   and s['songId'] == rec['song'] and s['proc'] == 'ready'), None)
    if rec.get('error') or rec.get('outcome') not in (None, 'completed'):
        out.append(violation('seekOutcome', t0, f"error={rec.get('error')} outcome={rec.get('outcome')} "
                             f"respMs={rec.get('respMs')}", run))
    if landed is None:
        last = after[-1] if after else None
        out.append(violation('seekNoLanding', t0, f"target={target} lastPos={last and last['pos']} "
                             f"pos0={rec.get('pos0')} outcome={rec.get('outcome')}", run, span=(1, d['land'])))
    elif landed['t'] - t0 > d['land']:
        out.append(violation('seekLate', t0, f"landed after {landed['t'] - t0:.1f}s (limit {d['land']}s)", run))
    if landed is not None:
        rec['latency'] = round(landed['t'] - t0, 2)
    # Snap-back: after the call returned (or the landing deadline), the player
    # is back near where it was before the seek.
    pos0 = rec.get('pos0')
    if pos0 is not None and abs(target - pos0) > 8000:
        check_from = rec.get('ret', t0 + d['land'])
        run_hits = 0
        for s in after:
            if s['t'] < check_from + 0.2 or s['t'] < t0 or s['t'] > check_from + 12:
                continue
            expected_old = pos0 + (s['t'] - t0) * 1000 if rec.get('playing0') else pos0
            if abs(s['pos'] - expected_old) <= 3000:
                run_hits += 1
                if run_hits >= 3:
                    out.append(violation('seekSnapBack', s['t'], f"pos={s['pos']} back near old position "
                               f"{pos0} (target {target}); ui={s['uiPos']} pending={s['uiPending']}", run))
                    break
            else:
                run_hits = 0
    if landed is not None:
        later_seek = next((a['t'] for a in run.actions if a['kind'] in ('seek', 'next', 'prev', 'jump', 'start')
                           and a['t'] > t0 + 0.01), None)
        for s in after:
            if s['t'] > landed['t'] and (later_seek is None or s['t'] < later_seek) \
                    and s['songId'] == rec['song'] and s['proc'] == 'ready' and s['pos'] < target - 3000:
                out.append(violation('seekRegressed', s['t'], f"pos={s['pos']} fell below target {target} "
                                     f"after landing", run))
                break
        want_paused = not wanted_at(run, t0)
        window_end = min(landed['t'] + 6, later_seek if later_seek is not None else 1e9)
        window = [s for s in after if landed['t'] + 2 <= s['t'] <= window_end]
        if window:
            moved = window[-1]['pos'] - landed['pos']
            if want_paused and (abs(moved) > 600 or window[-1]['playing']):
                out.append(violation('seekPausedMoved', landed['t'], f"moved {moved} ms playing={window[-1]['playing']}", run))
            if not want_paused and moved < 1500:
                out.append(violation('seekNotAdvancing', landed['t'], f"advanced only {moved} ms in "
                                     f"{window[-1]['t'] - landed['t']:.1f}s", run))
    return out


def oracle_skip(run: Run, rec: dict) -> list[dict]:
    out, t0, d = [], rec['t'], run.deadlines
    expect, idx0 = rec['expect'], rec['idx0']
    queue = run.queue_ids
    song = queue[expect] if expect != 'restart' and not run.shuffled and expect < len(queue) else None
    after = [s for s in run.samples if s['t'] >= t0 and s['pos'] is not None]
    if expect == 'restart':
        hit = next((s for s in after if s['idx'] == idx0 and s['pos'] < 2500 and s['t'] > t0), None)
        if hit is None:
            out.append(violation('skipNoRestart', t0, f"previous after {rec['pos0']} ms did not restart", run))
        return out
    low, high = sorted((idx0, expect))
    for n, s in enumerate(after):
        if s['idx'] is not None and not low <= s['idx'] <= high \
                and not song_end_near(after, n):
            out.append(violation('skipOvershoot', s['t'], f"idx={s['idx']} outside {low}..{high} "
                                 f"(expected {expect})", run))
            break
    reached, advanced = advance_after(run, t0, expect, song)
    if reached is None:
        seen = sorted({s['idx'] for s in after if s['idx'] is not None})
        out.append(violation('skipIndexNotReached', t0, f"expected index {expect} (from {idx0}); saw {seen}; "
                             f"song at idx {expect} should be {song}", run, span=(1, d['advance'])))
    elif advanced is None:
        out.append(violation('skipNoAdvance', reached['t'], f"index {expect} reached at +{reached['t'] - t0:.1f}s "
                             f"but position stuck at {reached['pos']}", run, span=(1, d['advance'])))
    elif advanced['t'] - t0 > d['advance']:
        out.append(violation('skipLate', t0, f"audible after {advanced['t'] - t0:.1f}s (limit {d['advance']}s)", run))
    if advanced is not None:
        rec['latency'] = round(advanced['t'] - t0, 2)
    return out


def license_pool(run: Run):
    return [a for a in run.actions if a['kind'] in ('start', 'next', 'prev', 'jump', 'shuffle', 'queueEdit')]


def _requested_at(run: Run, t: float, kinds=('seek', 'prev', 'jump', 'start', 'next')) -> bool:
    """A seek or navigation is in flight (or returned a moment ago)."""
    for a in run.actions:
        if a['kind'] in kinds:
            end = a['ret'] + 1.5 if 'ret' in a else a['t'] + (90 if a['kind'] == 'seek' else 15)
            if a['t'] - 0.2 <= t <= end:
                return True
    return False


def oracle_unexpected_change(run: Run) -> list[dict]:
    """Song or index changes nobody asked for (and that are not a song ending)."""
    out, licenses = [], license_pool(run)
    used = 0
    def requested(t):
        return _requested_at(run, t)
    samples = run.samples
    for i in range(1, len(samples)):
        a, b = samples[i - 1], samples[i]
        if a['songId'] is None or b['songId'] is None:
            continue
        if a['idx'] != b['idx'] or a['songId'] != b['songId']:
            if a['idx'] is None or b['idx'] is None:
                if a['idx'] is None and b['idx'] is not None:
                    used += 1  # the start that selected the first song
                continue
            step = max(1, abs(b['idx'] - a['idx']))
            available = sum(1 for x in licenses if x['t'] <= b['t'] + 0.2)
            if available - used >= 1:
                used = min(available, used + step)
                continue
            if song_end_near(samples, i):
                continue
            kind = 'sameSongTwice' if a['songId'] == b['songId'] and a['idx'] != b['idx'] else 'unexpectedChange'
            out.append(violation(kind, b['t'], f"idx {a['idx']}->{b['idx']} song {a['songId']}->{b['songId']} "
                                 f"pos {a['pos']}->{b['pos']} with no user action", run))
        elif (a['pos'] is not None and b['pos'] is not None and a['pos'] - b['pos'] > 5000 and b['pos'] < 3000
              and not requested(b['t']) and not song_end_near(samples, i)):
            out.append(violation('unrequestedReset', b['t'], f"position {a['pos']}->{b['pos']} on {b['songId']} "
                                 f"with no seek or navigation", run))
        elif (a['pos'] is not None and b['pos'] is not None and b['pos'] - a['pos'] > 8000 and b['t'] - a['t'] < 2
              and not requested(b['t'])):
            out.append(violation('unrequestedJump', b['t'], f"position jumped {a['pos']}->{b['pos']} on {b['songId']} "
                                 f"with no seek or navigation", run))
    return out


def oracle_replay(run: Run) -> list[dict]:
    """A song that reaches its end and starts over on the same queue index,
    with no seek, navigation or repeat mode: the same song heard twice."""
    out = []
    samples = run.samples
    began = 0  # first sample of the current (index, song) run
    for i in range(1, len(samples)):
        a, b = samples[i - 1], samples[i]
        if (a['idx'], a['songId']) != (b['idx'], b['songId']):
            began = i
            continue
        # The first samples after a switch can still carry the previous
        # song's position: only a run that has played for a while counts, and
        # its position must be at the song's own end.
        carried = began > 0 and samples[began - 1]['pos'] is not None and a['pos'] is not None \
            and abs(samples[began - 1]['pos'] - a['pos']) <= 200  # still the previous song's position
        if (a['songId'] and a['dur'] and not carried and i - began >= 3 and a['pos'] is not None and b['pos'] is not None
                and a['dur'] - 2500 <= a['pos'] <= a['dur'] + 2000 and b['pos'] < 3000
                and a['pos'] - b['pos'] > a['dur'] / 2
                and not _requested_at(run, b['t'], ('seek', 'prev', 'jump', 'next'))):
            out.append(violation('songReplayedAtEnd', b['t'], f"{b['songId']} reached {a['pos']}/{a['dur']} ms and "
                                 f"started again at {b['pos']} ms on idx {b['idx']} (proc {a['proc']}->{b['proc']})", run))
    return out


def wanted_at(run: Run, t: float) -> bool:
    wanted = True
    for a in run.actions:
        if a['t'] <= t and a['kind'] in ('pause', 'play'):
            wanted = a['kind'] == 'play'
    return wanted


def oracle_stall(run: Run) -> list[dict]:
    out, limit = [], run.deadlines['stall']
    first_audio = next((s['t'] for s in run.samples if s['pos'] and s['playing']), None)
    anchor = None
    for s in run.samples:
        # The last song of a queue that has played out is finished, not stalled.
        finished = (s['proc'] == 'completed' and s['idx'] is not None and s['qlen']
                    and s['idx'] >= s['qlen'] - 1 and not s['deferred'])
        if first_audio is None or s['t'] < first_audio or s['pos'] is None \
                or finished or not wanted_at(run, s['t']):
            anchor = None
            continue
        if anchor is None or abs(s['pos'] - anchor['pos']) > 200 or s['songId'] != anchor['songId']:
            anchor = s
            continue
        if s['t'] - anchor['t'] >= limit:
            out.append(violation('stall', anchor['t'], f"position frozen at {anchor['pos']} for "
                                 f"{s['t'] - anchor['t']:.1f}s (proc={s['proc']} loading={s['loading']} "
                                 f"buffered={s['buf']})", run, span=(1, limit + 2)))
            anchor = None
            first_audio = None  # one stall report per case
    return out


def oracle_buffer_lag(run: Run, bytes_per_second: float | None) -> list[dict]:
    """Passive (#87): the seek bar's buffered line lags the real cache."""
    out = []
    if not bytes_per_second:
        return out
    stalled_since, bar_ref = None, None
    lag_since = None
    max_lag = 0.0
    final = {}
    for s in run.samples:
        if s['cacheB'] is None or s['pos'] is None:
            continue
        cache_s = s['cacheB'] / bytes_per_second
        bar_s = (s['bar'] or 0) / 1000
        final = {'cacheS': round(cache_s, 1), 'barS': round(bar_s, 1), 't': s['t']}
        lag = cache_s - bar_s
        max_lag = max(max_lag, lag)
        if s['t'] > 5 and lag > 10:
            lag_since = lag_since or s['t']
            if s['t'] - lag_since >= 3:
                out.append(violation('bufferLag', s['t'], f"seek bar line {bar_s:.0f}s, cache holds ~{cache_s:.0f}s "
                                     f"(lag {lag:.0f}s)", run, passive=True))
                lag_since = None
                break
        else:
            lag_since = None
    # Stops while cache bytes keep growing.
    window = []
    for s in run.samples:
        if s['cacheB'] is None or s['bar'] is None or s['pos'] is None:
            continue
        window.append(s)
        window = [x for x in window if s['t'] - x['t'] <= 5]
        if (s['t'] - window[0]['t'] >= 4.5 and len({x['bar'] for x in window}) == 1
                and (s['cacheB'] - window[0]['cacheB']) / bytes_per_second >= 4
                and s['bar'] < (s['dur'] or 0) - 3000):
            out.append(violation('bufferStalled', s['t'], f"seek bar line frozen at {s['bar'] / 1000:.0f}s while "
                                 f"cache grew {(s['cacheB'] - window[0]['cacheB']) / bytes_per_second:.0f}s of audio", run, passive=True))
            break
    run.metrics['bufferMaxLagS'] = round(max_lag, 1)
    run.metrics['bufferFinal'] = final
    return out


def oracle_sequence(run: Run, expected_pass: list[str] | None, minimum=3) -> list[dict]:
    """Shuffle oracle: the songs that became current, in order, never repeat
    (by id, or as the same recording twice in a row) within one pass."""
    out, order = [], []
    for s in run.samples:
        if s['songId'] and (not order or order[-1][1] != s['songId'] or order[-1][0] != s['idx']):
            order.append((s['idx'], s['songId'], s['t']))
    ids = [song for _, song, _ in order]
    run.metrics['songSequence'] = ids[:12]
    seen = set()
    for n, (idx, song, t) in enumerate(order):
        if n and ids[n - 1] == song:
            out.append(violation('sameSongTwice', t, f"{song} became current again at idx {idx} right after "
                                 f"itself (sequence {ids[:n + 1]})", run))
        elif song in seen:
            out.append(violation('songRepeatedInPass', t, f"{song} played again before the pass ended "
                                 f"(sequence {ids[:n + 1]})", run))
        elif n and run.backend.canonical(ids[n - 1]) == run.backend.canonical(song):
            out.append(violation('sameRecordingAdjacent', t, f"{ids[n - 1]} then {song}: same recording", run))
        if song.startswith('ext-'):
            run.metrics['remoteSongInQueue'] = song  # the artist queue adds remote songs; not judged
        elif expected_pass is not None and song not in expected_pass:
            out.append(violation('songNotInSelection', t, f"{song} is not part of the album/artist", run))
        seen.add(song)
    if len(order) < minimum:
        out.append(violation('shuffleNoProgress', run.now(), f"only {len(order)} songs became current: {ids}", run))
    return out


def oracle_queue_edit(run: Run, expect: dict) -> list[dict]:
    """After the fill settles: queue length, neighbours of the current song,
    and that the current song was not interrupted."""
    out = []
    settled = [s for s in run.samples if s['settled'] and s['qlen'] == expect['qlen']]
    final = run.samples[-1]
    if not settled:
        out.append(violation('queueLengthWrong', final['t'], f"queue length {final['qlen']} (expected {expect['qlen']}), "
                             f"settled={final['settled']}", run))
        return out
    s = settled[-1]
    head = s['nseq']
    if expect.get('neighbours') and head[:len(expect['neighbours'])] != expect['neighbours']:
        out.append(violation('queueOrderWrong', s['t'], f"native head {head} expected {expect['neighbours']}", run))
    first = expect['first']
    changed = [x for x in run.samples if x['songId'] and x['songId'] != first and x['t'] < run.samples[-1]['t'] - 3]
    if changed:
        out.append(violation('queueEditInterrupted', changed[0]['t'], f"current song became {changed[0]['songId']} "
                             f"(was {first}) during the queue edit", run))
    return out


# Backends -------------------------------------------------------------------

class FixtureBackend:
    name = 'fixture'
    short_groups = True  # has albums/artists whose songs all end within seconds
    credentials = {'username': 'diagnostics', 'password': 'synthetic-seek-fixture'}

    def __init__(self, upstream_url, library, handler):
        self.upstream, self.library, self.handler = upstream_url, library, handler
        self.credentials = {**self.credentials, 'url': upstream_url}
        self.used: set[str] = set()
        self.rng = random.Random(86)

    def _take(self, songs):
        self.used.update(s['id'] for s in songs)
        return songs

    def _is_short(self, artist_id):
        return artist_id in self.library.short

    def fresh_songs(self, n, min_s=100):
        pool = [s for s in self.library.sorted_songs() if s['id'] not in self.used
                and s['duration'] >= min_s and s['track'] > 1 and s['id'] not in self.library.duplicates]
        return self._take(self.rng.sample(pool, n))

    def fresh_album(self, short=False):
        albums = [a for a, d in self.library.albums.items() if self._is_short(d['artistId']) == short
                  and not any(i in self.used for i in self.library.album_songs[a])]
        ids = list(self.library.album_songs[self.rng.choice(albums)])
        self.used.update(ids)
        return ids

    def fresh_artist(self, short=False):
        artists = [a for a in self.library.artists if self._is_short(a) == short and not any(
            i in self.used for al, d in self.library.albums.items() if d['artistId'] == a
            for i in self.library.album_songs[al])]
        artist = self.rng.choice(artists)
        ids = [i for al, d in self.library.albums.items() if d['artistId'] == artist
               for i in self.library.album_songs[al]]
        self.used.update(ids)
        return artist, ids

    def filler(self, n, exclude=()):
        pool = [s['id'] for s in self.library.sorted_songs()
                if s['id'] not in exclude and s['duration'] >= 30]
        self.rng.shuffle(pool)
        return pool[:n]

    def canonical(self, song_id):
        return self.library.duplicates.get(song_id, song_id)

    def requests(self):
        return self.handler.requests


class LiveBackend:
    name = 'live'
    short_groups = False  # real songs are long: natural-end cases wait out a whole song

    def __init__(self, credentials, server: Server):
        self.credentials, self.server = credentials, server
        self.upstream = credentials['url']
        self.pool: list[dict] = []
        self.used = used_songs()

    def _catalog_has(self, ids):
        with sqlite3.connect(f'file:{ROOT / "navis.sqlite"}?mode=ro', uri=True) as db:
            return {r[0] for r in db.execute(
                f'SELECT id FROM songs WHERE id IN ({",".join("?" * len(ids))})', ids)}

    def _refill(self):
        for _ in range(12):
            songs = self.server.call('getRandomSongs', size=500)['randomSongs'].get('song', [])
            known = self._catalog_has([s['id'] for s in songs])
            self.pool += [s for s in songs if s['id'] in known and s['id'] not in self.used
                          and 120 <= s.get('duration', 0) <= 600 and s.get('bitRate', 0) >= 700
                          and all(p['id'] != s['id'] for p in self.pool)]
            if len(self.pool) >= 150:
                return

    def fresh_songs(self, n, min_s=100):
        if len(self.pool) < n:
            self._refill()
        picked, self.pool = self.pool[:n], self.pool[n:]
        for song in picked:
            self.used.add(song['id'])
            mark_used(song['id'])
        return picked

    def _groups(self, key, low, high, extra=''):
        """Unused lossless groups (album or artist) from the synced catalog.
        Artists are grouped by their albums' artist: many songs carry no
        artist id of their own."""
        column = 'a.artist_id' if key == 'artist_id' else 's.album_id'
        with sqlite3.connect(f'file:{ROOT / "navis.sqlite"}?mode=ro', uri=True) as db:
            groups = db.execute(
                f'SELECT {column} FROM songs s JOIN albums a ON a.id = s.album_id '
                f'WHERE s.server_deleted_at IS NULL AND {column} IS NOT NULL '
                f'GROUP BY {column} HAVING COUNT(*) BETWEEN ? AND ? AND MIN(COALESCE(s.bit_rate, 0)) >= 700 '
                f'{extra} ORDER BY RANDOM() LIMIT 40', (low, high)).fetchall()
            for (group,) in groups:
                rows = db.execute(
                    f'SELECT s.id FROM songs s JOIN albums a ON a.id = s.album_id WHERE {column} = ? '
                    f'ORDER BY s.disc_number, s.track, s.id', (group,)).fetchall()
                ids = [r[0] for r in rows]
                if not self.used.intersection(ids):
                    return group, ids
        raise Failure(f'no suitable live {key}')

    def _take_ids(self, ids):
        self.used.update(ids)
        for i in ids:
            mark_used(i)
        return ids

    def fresh_album(self, short=False):
        return self._take_ids(self._groups('album_id', 6, 14)[1])

    def fresh_artist(self, short=False):
        artist, ids = self._groups('artist_id', 15, 45, 'AND COUNT(DISTINCT s.album_id) BETWEEN 2 AND 4')
        return artist, self._take_ids(ids)

    def filler(self, n, exclude=()):
        return [s['id'] for s in queue_filler(self.server, n + len(exclude)) if s['id'] not in exclude][:n]

    def canonical(self, song_id):
        return song_id

    def requests(self):
        return []


def bytes_per_second(song: dict, quality: str):
    fmt, kbps = QUALITIES[quality]
    if fmt is None:
        return song['size'] / song['duration'] if song.get('size') and song.get('duration') else None
    return kbps * 125  # nominal; Opus and AAC are variable


# Case actions -----------------------------------------------------------------

def start_single(run: Run, song: dict):
    run.songs = [song]
    run.queue_ids = [song['id']]
    rec = run.act('start', songIds=[song['id']])
    run.app.api('/v1/playback/start', {'songId': song['id']}, timeout=60)
    return await_audio(run, rec, song['id'])


def start_queue(run: Run, ids: list[str], shuffle=False):
    run.queue_ids = list(ids)
    run.shuffled = shuffle
    rec = run.act('start', songIds=len(ids), first=ids[0], shuffle=shuffle)
    body = {'songIds': ids, **({'shuffle': True} if shuffle else {})}
    response = run.app.api('/v1/playback/queue', body, timeout=120)
    rec['startedSongId'] = response.get('startedSongId')
    return rec


def await_audio(run: Run, rec: dict, song_id=None):
    sample = run.until(lambda s: s['playing'] and s['proc'] == 'ready' and (s['pos'] or 0) > 0
                       and (song_id is None or s['songId'] == song_id), START_DEADLINE)
    if sample is None:
        run.violations.append(violation('noStart', rec['t'], f"no audio within {START_DEADLINE}s; last="
                                        f"{run.last() and {k: run.last()[k] for k in ('songId', 'proc', 'pos', 'playing', 'loading')}}",
                                        run, span=(1, START_DEADLINE)))
        raise CaseAbort('no start')
    run.start_ready = round(sample['t'] - rec['t'], 2)
    return sample


def issue_seek(run: Run, pool, target: int) -> dict:
    s = run.last()
    rec = run.act('seek', target=target, pos0=s['pos'], idx0=s['idx'], song=s['songId'], playing0=s['playing'])

    def call():
        try:
            response = run.app.api('/v1/playback/seek', {'positionMs': target}, timeout=90)
            rec['respMs'] = response.get('elapsedMs')
            rec['outcome'] = ((response.get('after') or {}).get('seek') or {}).get('outcome')
        except Exception as error:
            rec['error'] = f'{type(error).__name__}: {error}'
        rec['ret'] = run.now()

    run.futures.append(pool.submit(call))
    return rec


def landed(run: Run, rec: dict):
    return run.until(lambda s: s['songId'] == rec['song'] and s['pos'] is not None and s['proc'] == 'ready'
                     and abs(s['pos'] - rec['target']) <= LAND_TOLERANCE_MS and s['t'] >= rec['t'],
                     run.deadlines['land'])


def finish_futures(run: Run, timeout=60):
    deadline = time.monotonic() + timeout
    for future in run.futures:
        try:
            future.result(timeout=max(0.1, deadline - time.monotonic()))
        except Exception:
            pass


def seek_case(fractions, play_s=5.0, paused=False, sequential=False, gap=0.25):
    def case(run: Run, env):
        song = env.backend.fresh_songs(1)[0]
        duration_ms = int(song['duration']) * 1000
        start_single(run, song)
        if play_s:
            run.observe(play_s)
        if paused:
            run.act('pause')
            run.app.api('/v1/playback/pause', {})
            run.observe(1.0)
        recs = []
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            for n, fraction in enumerate(fractions):
                rec = issue_seek(run, pool, int(duration_ms * fraction))
                recs.append(rec)
                if sequential:
                    landed(run, rec)
                    run.observe(3.0)
                elif len(fractions) > 1 and n < len(fractions) - 1:
                    time.sleep(gap)
            landed(run, recs[-1])
            finish_futures(run)
            run.observe(6.0)
        finals = recs if sequential else recs[-1:]
        run.checks.append(lambda: [v for rec in finals for v in oracle_seek(run, rec)])
        run.latency_from = finals
    return case


def nav(run: Run, pool, kind: str, expect=None) -> dict:
    s = run.last()
    if expect is None:
        expect = s['idx'] + (1 if kind == 'next' else -1)
        if kind == 'prev' and (s['pos'] or 0) > RESTART_THRESHOLD_MS:
            expect = 'restart'
    rec = run.act(kind, idx0=s['idx'], pos0=s['pos'], song0=s['songId'], expect=expect)
    path = '/v1/playback/next' if kind == 'next' else '/v1/playback/previous'

    def call():
        try:
            run.app.api(path, {}, timeout=90)
        except Exception as error:
            rec['error'] = f'{type(error).__name__}: {error}'

    run.futures.append(pool.submit(call))
    return rec


def wait_advanced(run: Run, rec: dict):
    expect = rec['expect']
    if expect == 'restart':
        run.until(lambda s: s['t'] > rec['t'] and s['pos'] is not None and s['pos'] < 2500, run.deadlines['advance'])
        return
    song = None if run.shuffled or expect >= len(run.queue_ids) else run.queue_ids[expect]
    deadline = time.monotonic() + run.deadlines['advance'] + 2
    while time.monotonic() < deadline:
        if advance_after(run, rec['t'], expect, song)[1] is not None:
            return
        time.sleep(0.1)


def skip_queue(run: Run, env, count=12):
    songs = env.backend.fresh_songs(count)
    run.songs = songs
    ids = [s['id'] for s in songs]
    rec = start_queue(run, ids)
    return ids, rec


def case_skip_next(run: Run, env):
    ids, rec = skip_queue(run, env)
    await_audio(run, rec, ids[0])
    run.observe(4.0)
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        a = nav(run, pool, 'next')
        wait_advanced(run, a)
        run.observe(3.0)
    run.checks.append(lambda: oracle_skip(run, a))
    run.latency_from = [a]


def case_skip_prev(run: Run, env):
    ids, rec = skip_queue(run, env)
    await_audio(run, rec, ids[0])
    run.observe(3.0)
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        a = nav(run, pool, 'next')
        wait_advanced(run, a)
        # Press Previous as soon as the new song is audible, within the 3 s
        # restart threshold, so it must go back one song.
        b = nav(run, pool, 'prev')
        wait_advanced(run, b)
        run.observe(3.0)
    run.checks.append(lambda: oracle_skip(run, a) + oracle_skip(run, b))
    run.latency_from = [a, b]


def case_skip_rapid(run: Run, env):
    ids, rec = skip_queue(run, env, 14)
    await_audio(run, rec, ids[0])
    run.observe(3.0)
    with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
        base = run.last()['idx']
        recs = []
        for _ in range(10):
            recs.append(nav(run, pool, 'next', expect=base + 10))
            time.sleep(0.08)
        wait_advanced(run, recs[-1])
        run.observe(4.0)
    run.checks.append(lambda: oracle_skip(run, recs[-1]))
    run.latency_from = [recs[-1]]


def case_skip_during_load(run: Run, env):
    ids, rec = skip_queue(run, env)
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        run.until(lambda s: s['songId'] == ids[0], 15)  # selected, not yet audible
        a = nav(run, pool, 'next', expect=1)
        wait_advanced(run, a)
        run.observe(4.0)
    run.checks.append(lambda: oracle_skip(run, a))
    run.latency_from = [a]


def case_skip_seek_next(run: Run, env):
    ids, rec = skip_queue(run, env)
    song = run.songs[0]
    await_audio(run, rec, ids[0])
    run.observe(4.0)
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        issue_seek(run, pool, int(song['duration'] * 500))
        time.sleep(0.15)
        a = nav(run, pool, 'next')
        wait_advanced(run, a)
        finish_futures(run, 30)
        run.observe(4.0)
    run.checks.append(lambda: oracle_skip(run, a))
    run.latency_from = [a]


def case_skip_last_batch(run: Run, env):
    # Longer than the 256-song window threshold, so the tail is deferred.
    songs = env.backend.fresh_songs(1) + [{'id': i} for i in env.backend.filler(299)]
    ids = [s['id'] for s in songs]
    run.songs = songs[:1]
    rec = start_queue(run, ids)
    await_audio(run, rec, ids[0])
    run.until(lambda s: s['settled'], 60)
    last = (run.last()['mat'] or 1) - 1
    run.act('jump', index=last, expect=last, idx0=run.last()['idx'])
    run.app.api('/v1/playback/queue-index', {'index': last}, timeout=60)
    run.until(lambda s: s['idx'] == last and (s['pos'] or 0) > 0 and s['playing'], run.deadlines['advance'] + 20)
    run.observe(3.0)
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        a = nav(run, pool, 'next', expect=last + 1)
        wait_advanced(run, a)
        run.observe(4.0)
    run.checks.append(lambda: oracle_skip(run, a))
    run.latency_from = [a]


def shuffle_steps(run: Run, pool, first):
    """Let the first song end (when short) or skip it, then skip twice more."""
    if first['dur'] and first['dur'] <= 9000:
        run.until(lambda s: s['idx'] != first['idx'], first['dur'] / 1000 + 12)
    else:
        run.observe(4.0)
        wait_advanced(run, nav(run, pool, 'next', expect=run.last()['idx'] + 1))
    for _ in range(2):
        run.observe(4.0)
        wait_advanced(run, nav(run, pool, 'next', expect=run.last()['idx'] + 1))
    run.observe(5.0)


def case_shuffle_album(run: Run, env):
    ids = env.backend.fresh_album()
    run.songs = [{'id': i} for i in ids]
    rec = start_queue(run, ids, shuffle=True)
    first = await_audio(run, rec)
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        shuffle_steps(run, pool, first)
    run.checks.append(lambda: oracle_sequence(run, ids))


def case_shuffle_artist(run: Run, env):
    artist, ids = env.backend.fresh_artist()
    run.songs = [{'id': i} for i in ids]
    run.shuffled = True
    rec = run.act('start', artist=artist, shuffle=True)
    run.app.api('/v1/artists/playback', {'command': 'prepare', 'artistId': artist, 'action': 'shuffle'}, timeout=60)
    first = await_audio(run, rec)
    run.metrics['artistStatus'] = run.app.api('/v1/artists/playback/status')
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        shuffle_steps(run, pool, first)
    run.checks.append(lambda: oracle_sequence(run, ids))


NATURAL_SONGS = 1  # --natural-songs: songs that end by themselves (a long one after the first is seeked to its end)


def natural_shuffle(kind: str):
    """Shuffle an album or artist and let song 1 play to its natural end with
    no skip, while the rest of the queue is still being filled; then follow
    up to four more transitions (letting short songs end, skipping long ones).
    Fixture songs of the short artists end within seconds; a live song is
    played for its full length (minutes). The sequence oracle must see no repeat."""
    def case(run: Run, env):
        backend = env.backend
        if kind == 'album':
            ids = backend.fresh_album(short=True)
            run.songs = [{'id': i} for i in ids]
            rec = start_queue(run, ids, shuffle=True)
        else:
            artist, ids = backend.fresh_artist(short=True)
            run.songs = [{'id': i} for i in ids]
            run.shuffled = True
            rec = run.act('start', artist=artist, shuffle=True)
            run.app.api('/v1/artists/playback', {'command': 'prepare', 'artistId': artist, 'action': 'shuffle'}, timeout=60)
        first = await_audio(run, rec)
        run.metrics.update(firstSong=first['songId'], firstDurMs=first['dur'], shortGroups=backend.short_groups)
        wait_s = 2 * (first['dur'] or 400000) / 1000 + run.deadlines['advance']  # room for one replay
        moved = run.until(lambda s: s['idx'] != first['idx'] or s['songId'] != first['songId'], wait_s)
        run.metrics['firstEndedNaturally'] = moved is not None
        if moved is None:
            run.violations.append(violation('naturalEndNoContinuation', run.now(),
                                            f"song 1 {first['songId']} did not hand over within {wait_s:.0f}s; last="
                                            f"{ {k: run.last()[k] for k in ('idx', 'songId', 'pos', 'proc', 'playing', 'loading', 'qlen', 'mat')} }",
                                            run, span=(wait_s, 2)))
            raise CaseAbort('no natural end')
        run.metrics['firstTransitionAt'] = moved['t']
        appends = [e['rel'] for e in run.trace if e['kind'] == 'queueFill' and e.get('phase') == 'append']
        starts = [e['rel'] for e in run.trace if e['kind'] == 'queueFill' and e.get('phase') == 'phase1Start']
        # Positive: the rest of the queue was appended this long before song 1 ended.
        # The device clock may differ from the host's: measure from phase 1's start.
        skew = (starts[0] - rec['t']) if starts else 0
        run.metrics['appendMarginS'] = round(moved['t'] - (appends[0] - skew), 2) if appends else None
        run.metrics['firstTransitionSample'] = {k: moved[k] for k in ('idx', 'songId', 'pos', 'proc', 'qlen', 'mat', 'deferred')}
        run.observe(3.0)
        run.metrics['firstTransition'] = excerpt(run, moved['t'], 4.0, 3.0, limit=60)
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            for n in range(min(4, len(ids) - 2)):
                cur = run.last()
                if cur['dur'] and cur['dur'] <= 12000:
                    run.until(lambda s, c=cur: s['idx'] != c['idx'], 2 * cur['dur'] / 1000 + run.deadlines['advance'])
                elif cur['dur'] and n + 1 < NATURAL_SONGS:
                    # A long song: seek to its last seconds (the download has long finished)
                    # and let it end by itself.
                    run.observe(6.0)
                    target = cur['dur'] - 4000
                    run.act('seek', target=target, pos0=run.last()['pos'], idx0=cur['idx'], song=cur['songId'], playing0=True)
                    run.app.api('/v1/playback/seek', {'positionMs': target}, timeout=90)
                    run.until(lambda s, c=cur: s['idx'] != c['idx'], 12 + run.deadlines['advance'])
                else:
                    run.observe(3.0)
                    wait_advanced(run, nav(run, pool, 'next', expect=cur['idx'] + 1))
            run.observe(3.0)
        run.checks.append(lambda: oracle_sequence(run, ids))
    return case


def case_shuffle_toggle(run: Run, env):
    ids, rec = skip_queue(run, env)
    first = await_audio(run, rec, ids[0])
    run.observe(4.0)
    before = run.last()
    run.act('shuffle', enabled=True)
    run.app.api('/v1/playback/shuffle', {'enabled': True})
    run.observe(4.0)
    mid = run.last()
    run.act('shuffle', enabled=False)
    run.app.api('/v1/playback/shuffle', {'enabled': False})
    run.observe(4.0)
    end = run.last()

    def check():
        out = []
        for label, a, b in (('on', before, mid), ('off', mid, end)):
            if b['songId'] != a['songId']:
                out.append(violation('shuffleToggleChangedSong', b['t'], f"toggle {label}: {a['songId']} -> {b['songId']}", run))
            elif (b['pos'] or 0) < (a['pos'] or 0):
                out.append(violation('shuffleToggleResetPosition', b['t'], f"toggle {label}: position {a['pos']} -> {b['pos']}", run))
        return out + oracle_sequence(run, None, minimum=1)
    run.checks.append(check)


def queue_case(edit):
    def case(run: Run, env):
        song = env.backend.fresh_songs(1)[0]
        extra = env.backend.filler(204, exclude=(song['id'],))
        ids = [song['id']] + extra[:199]
        run.songs = [song]
        run.queue_ids = ids
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            rec = run.act('start', songIds=len(ids), first=song['id'])
            started = pool.submit(run.app.api, '/v1/playback/queue', {'songIds': ids}, 120)
            time.sleep(0.25)
            expect = edit(run, ids, extra)
            started.result(timeout=120)
            await_audio(run, rec, song['id'])
            run.until(lambda s: s['settled'] and s['qlen'] == expect['qlen'], 60)
            run.observe(4.0)
        run.checks.append(lambda: oracle_queue_edit(run, {**expect, 'first': song['id']}))
    return case


def edit_play_next_add(run, ids, extra):
    x, y = extra[199], extra[200]
    run.act('queueEdit', op='playNext', song=x)
    run.app.api('/v1/playback/queue-edit', {'op': 'playNext', 'songIds': [x]}, timeout=60)
    run.act('queueEdit', op='add', song=y)
    run.app.api('/v1/playback/queue-edit', {'op': 'add', 'songIds': [y]}, timeout=60)
    return {'qlen': len(ids) + 2, 'neighbours': [ids[0], x]}


def edit_reorder(run, ids, extra):
    run.act('queueEdit', op='move', source=3, to=1)
    run.app.api('/v1/playback/queue-edit', {'op': 'move', 'from': 3, 'to': 1}, timeout=60)
    return {'qlen': len(ids), 'neighbours': [ids[0], ids[3], ids[1]]}


CASE_FUNCS = {
    'seek_early': seek_case([0.3], play_s=0),
    'seek_pastdl': seek_case([0.92], play_s=0),
    'seek_far': seek_case([0.75]),
    'seek_mid': seek_case([0.4]),
    'seek_back': seek_case([0.6, 0.15], sequential=True),
    'seek_burst': seek_case([0.3, 0.7, 0.45]),
    'seek_paused': seek_case([0.65], play_s=3.0, paused=True),
    'skip_next': case_skip_next,
    'skip_prev': case_skip_prev,
    'skip_rapid10': case_skip_rapid,
    'skip_during_load': case_skip_during_load,
    'skip_seek_next': case_skip_seek_next,
    'skip_last_batch': case_skip_last_batch,
    'shuffle_album': case_shuffle_album,
    'shuffle_artist': case_shuffle_artist,
    'shuffle_album_natural': natural_shuffle('album'),
    'shuffle_artist_natural': natural_shuffle('artist'),
    'shuffle_toggle': case_shuffle_toggle,
    'queue_playnext_add': queue_case(edit_play_next_add),
    'queue_reorder': queue_case(edit_reorder),
}
PROFILES = {
    'smoke': {'cases': ['seek_far', 'seek_back', 'skip_next', 'skip_rapid10', 'shuffle_album', 'shuffle_artist',
                        'shuffle_album_natural', 'shuffle_artist_natural'],
              'qualities': ['original', 'opus128'], 'throttles': ['none', 'slow1500'], 'reps': 1},
    'full': {'cases': list(CASE_FUNCS), 'qualities': list(QUALITIES), 'throttles': list(THROTTLES), 'reps': 1},
}
REPEATED_CASES = {'shuffle_album', 'shuffle_artist', 'shuffle_album_natural', 'shuffle_artist_natural'}  # --shuffle-reps times each


def set_quality(app, quality: str):
    fmt, kbps = QUALITIES[quality]
    setting = {'format': fmt, 'maxBitRate': kbps}
    app.api('/v1/playback/quality', {'wifi': setting, 'cellular': setting})
    time.sleep(0.5)


def reset_modes(app):
    # Shuffle and repeat are sticky across queues: every case starts plain.
    app.api('/v1/playback/shuffle', {'enabled': False})
    app.api('/v1/playback/repeat', {'mode': 'none'})


def settle_between_runs(app):
    try:
        app.api('/v1/playback/queue/clear', {})
        reset_modes(app)
        if isinstance(app, AndroidApp):
            app.trim_cache()
    except Exception:
        pass
    time.sleep(1.5)


def revive_app(app, backend, proxy, quality: str, events: list, when: str) -> bool:
    """If the app has exited, records how (exit code, log tail) and starts it
    again on the kept profile. Returns whether it had exited."""
    if app.proc is None or app.proc.poll() is None:
        return False
    log = (app.run / 'app.log')
    tail = log.read_text(errors='replace').splitlines()[-12:] if log.exists() else []
    events.append({'event': 'appExited', 'when': when, 'returncode': app.proc.returncode,
                   'logTail': tail, 'w': round(time.time(), 1)})
    print(json.dumps({'event': 'appExited', 'when': when, 'returncode': app.proc.returncode}), flush=True)
    app.proc = None
    app.launch()
    sign_in(app, backend.credentials, 'wifi', proxy.url)
    set_quality(app, quality)
    return True


def run_one(app, backend, proxy, env, case: str, quality: str, throttle: str, rep: int, out_dir: Path, serial: int,
            events: list | None = None) -> dict:
    events = events if events is not None else []
    revived = revive_app(app, backend, proxy, quality, events, f'before #{serial} {case}')
    run = Run(app, backend, case, quality, throttle, rep)
    if revived:
        run.metrics['appRestartedBeforeRun'] = True
    run.checks, run.latency_from = [], []
    run.env = env
    proxy_mark = len(proxy.log)
    sampler = Sampler(run)
    reset_modes(app)
    # Baseline the trace so earlier runs' events are not re-read.
    baseline = app.api('/v1/playback/status')
    run._trace_seq = max([e['seq'] for e in baseline.get('transportTrace') or []] or [0])
    sampler.start()
    error = None
    try:
        CASE_FUNCS[case](run, env)
    except CaseAbort:
        pass
    except Exception as exc:  # harness or app failure: a failed case, kept visible
        error = f'{type(exc).__name__}: {exc}'
        run.violations.append(violation('caseError', run.now(), error, run))
    finally:
        try:
            finish_futures(run, 20)
        except Exception:
            pass
        sampler.halt.set()
        sampler.join(timeout=10)
    if app.proc is not None and app.proc.poll() is not None:
        run.violations.append(violation('appExited', run.now(), f'the app exited (code {app.proc.returncode}) during the case', run))
    for check in run.checks:
        try:
            run.violations += check()
        except Exception as exc:
            run.violations.append(violation('oracleError', run.now(), f'{type(exc).__name__}: {exc}', run))
    run.violations += oracle_unexpected_change(run) + oracle_stall(run) + oracle_replay(run)
    song = run.songs[0] if run.songs else None
    if song and song.get('duration'):
        # Bytes per second of audio: what the server actually sent for a
        # complete response, else the nominal bitrate.
        done = [r['bytes'] for r in proxy.log[proxy_mark:]
                if r['id'] == song['id'] and r.get('status') == 200 and not r.get('aborted')]
        rate = max(done) / song['duration'] if done else bytes_per_second(song, quality)
        run.violations += oracle_buffer_lag(run, rate)
    # Collapse repeats of one oracle to its first occurrence.
    seen, unique = set(), []
    for v in run.violations:
        key = (v['oracle'], v['passive'])
        if key not in seen:
            seen.add(key)
            unique.append(v)
    hard = [v for v in unique if not v['passive']]
    latencies = [r['latency'] for r in run.latency_from if r.get('latency') is not None]
    latency = statistics.median(latencies) if latencies else run.start_ready
    row = {
        'id': serial, 'case': case, 'quality': quality, 'throttle': throttle, 'rep': rep,
        'passed': not hard and error is None, 'latencyS': latency, 'startReadyS': run.start_ready,
        'violations': hard, 'passive': [v for v in unique if v['passive']],
        'songs': [s['id'] for s in run.songs][:20], 'metrics': run.metrics,
        'actions': [{k: v for k, v in a.items() if k != 'future'} for a in run.actions],
        'proxyRequests': proxy.log[proxy_mark:], 'sampleErrors': run.errors[:5],
    }
    if hard or unique:
        (out_dir / 'traces').mkdir(exist_ok=True)
        (out_dir / 'traces' / f'{serial:04d}-{case}-{quality}-{throttle}.json').write_text(json.dumps(
            {'row': row, 'samples': run.samples, 'trace': run.trace}, indent=1))
    return row


def summarize(results: list[dict]) -> str:
    groups: dict[tuple, list[dict]] = {}
    for row in results:
        groups.setdefault((row['case'], row['quality'], row['throttle']), []).append(row)
    lines = [f"{'case':18} {'quality':9} {'throttle':9} {'pass':>4} {'fail':>4} {'med s':>6} {'p95 s':>6}  failing oracles"]
    for (case, quality, throttle), rows in sorted(groups.items()):
        latencies = sorted(r['latencyS'] for r in rows if r['latencyS'] is not None)
        median = f'{statistics.median(latencies):.1f}' if latencies else '-'
        p95 = f'{latencies[min(len(latencies) - 1, int(len(latencies) * 0.95))]:.1f}' if latencies else '-'
        oracles = sorted({v['oracle'] for r in rows for v in r['violations']})
        lines.append(f"{case:18} {quality:9} {throttle:9} {sum(r['passed'] for r in rows):4d} "
                     f"{sum(not r['passed'] for r in rows):4d} {median:>6} {p95:>6}  {','.join(oracles)}")
    passive = {}
    for row in results:
        for v in row['passive']:
            passive.setdefault((row['quality'], row['throttle']), set()).add(row['id'])
    totals = {}
    for row in results:
        totals.setdefault((row['quality'], row['throttle']), 0)
        totals[(row['quality'], row['throttle'])] += 1
    lines += ['', 'Passive #87 oracle (seek-bar buffered line lags or freezes vs real cache): runs flagged / runs']
    for key in sorted(totals):
        lines.append(f"  {key[0]:9} {key[1]:9} {len(passive.get(key, ())):3d} / {totals[key]}")
    return '\n'.join(lines)


def run_matrix(args, credentials, app, run_dir: Path) -> int:
    profile = dict(PROFILES[args.profile])
    if args.cases:
        profile['cases'] = [c for c in args.cases.split(',') if c]
    if args.qualities:
        profile['qualities'] = [q for q in args.qualities.split(',') if q]
    if args.throttles:
        profile['throttles'] = [t for t in args.throttles.split(',') if t]
    reps = args.reps or profile['reps']
    unknown = [c for c in profile['cases'] if c not in CASE_FUNCS] + \
              [q for q in profile['qualities'] if q not in QUALITIES] + \
              [t for t in profile['throttles'] if t not in THROTTLES]
    if unknown:
        raise Failure(f'unknown matrix entries: {unknown}')
    fixture_server = None
    if args.server == 'fixture':
        import seek_reliability_diagnostics as fixture_tool
        library = fixture_tool.TranscodeLibrary(BASE / 'fixture-media', artists=args.fixture_artists,
                                                short_artists=args.fixture_short_artists)
        fixture_server, handler = fixture_tool.start_transcoding_server(
            library, speed=args.transcode_speed, advertise_offset=not args.no_transcode_offset,
            static=args.fixture_static_transcode)
        backend = FixtureBackend(f'http://127.0.0.1:{fixture_server.server_port}', library, handler)
    else:
        backend = LiveBackend(credentials, Server(credentials))
    proxy = ThrottledProxy(backend.upstream, 0, 0)
    try:
        (ROOT / 'password').write_text(backend.credentials['password'] + '\n')
        os.chmod(ROOT / 'password', 0o600)
        marker = ROOT / 'profile-server'
        android = isinstance(app, AndroidApp)
        app_url = proxy.url
        if android:
            # The emulator is seeded with the Linux profile's synced catalog,
            # so that profile must come from this server (run Linux first).
            if not marker.exists() or marker.read_text() != args.server or not (ROOT / 'navis.sqlite').exists():
                raise Failure(f'sync the Linux profile against the {args.server} server first; Android seeds from it')
            # The app must see the proxy at 127.0.0.1: ExoPlayer refuses cleartext to any
            # other host (error 2007), which breaks every direct-stream fallback. adb reverse
            # gives that address but caps near 100 KB/s, so a toybox nc relay on the
            # emulator forwards its loopback to the host alias 10.0.2.2 (about 10 MB/s).
            if args.android_reverse:
                subprocess.run(app.adb + ['reverse', f'tcp:{proxy.PORT}', f'tcp:{proxy.PORT}'],
                               check=True, capture_output=True)
            else:
                app.start_relay(proxy.PORT)
            app.prepare(backend.credentials, app_url)
        else:
            # A kept profile is only valid for the server it was synced from.
            if (args.server == 'fixture' or not args.keep_profile
                    or not marker.exists() or marker.read_text() != args.server):
                reset_profile()
            marker.write_text(args.server)
            point_profile_at(proxy.url)
        app.launch()
        sign_in(app, backend.credentials, 'wifi', app_url)
        env = type('Env', (), {'backend': backend, 'profile': args.profile})()
        # Fail fast if the app is not using the proxy.
        before = proxy.requests
        app.api('/v1/presentation/search', {'query': 'a', 'filter': 'songs'}, timeout=40)
        if proxy.requests == before:
            raise Failure('the app is not using the throttling proxy')
        info = {'server': args.server, 'profile': args.profile, 'cases': profile['cases'],
                'qualities': profile['qualities'], 'throttles': profile['throttles'], 'reps': reps}
        print(json.dumps(info), flush=True)
        results, serial, events = [], 0, []
        if args.resume_from:
            previous = json.loads(args.resume_from.read_text())
            # Harness errors (for example a fixture that ran out of fresh
            # songs) are rerun; real verdicts are kept.
            results = [r for r in previous['results']
                       if not any(v['oracle'] == 'caseError' for v in r['violations'])]
            events = previous.get('events', [])
            serial = max([r['id'] for r in results] or [0])
            for row in results:  # keep the earlier traces beside the new ones
                source = args.resume_from.parent / 'traces'
                for trace in source.glob(f"{row['id']:04d}-*.json") if source.exists() else []:
                    (run_dir / 'traces').mkdir(exist_ok=True)
                    shutil.copy(trace, run_dir / 'traces' / trace.name)
        finished = {(r['case'], r['quality'], r['throttle'], r['rep']) for r in results}
        info['events'] = events
        for throttle in profile['throttles']:
            proxy.set_profile(*THROTTLES[throttle])
            for quality in profile['qualities']:
                set_quality(app, quality)
                for case in profile['cases']:
                    for rep in range(args.shuffle_reps if case in REPEATED_CASES and args.shuffle_reps else reps):
                        if (case, quality, throttle, rep) in finished:
                            continue
                        serial += 1
                        row = run_one(app, backend, proxy, env, case, quality, throttle, rep, run_dir, serial, events)
                        results.append(row)
                        print(json.dumps({k: row[k] for k in ('id', 'case', 'quality', 'throttle', 'passed', 'latencyS')}
                                         | {'violations': [v['oracle'] for v in row['violations']]}), flush=True)
                        (run_dir / 'report.json').write_text(json.dumps({**info, 'results': results}, indent=1))
                        settle_between_runs(app)
        summary = summarize(results)
        (run_dir / 'summary.txt').write_text(summary + '\n')
        print(summary)
        passed = sum(r['passed'] for r in results)
        print(f'PASSED {passed}/{len(results)}  REPORT={run_dir / "report.json"}')
        return 0 if passed == len(results) else 1
    finally:
        app.stop()
        proxy.close()
        if fixture_server:
            fixture_server.shutdown()
        if args.server == 'live':
            point_profile_at(credentials['url'])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--credentials',
                        default=os.environ.get('NAVIS_LIVE_SEEK_CREDENTIALS', ''))
    parser.add_argument('--skip-build', action='store_true')
    parser.add_argument('--build-only', action='store_true',
                        help='build the profile bundle and exit')
    parser.add_argument('--keep-profile', action='store_true')
    parser.add_argument('--quality', default='wifi,cellular')
    parser.add_argument('--sources', default='library,remote')
    parser.add_argument('--cases', default=None,
                        help='legacy cases, or matrix cases with --profile')
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
    parser.add_argument('--profile', choices=sorted(PROFILES),
                        help='run the playback matrix (seek, skip, shuffle, queue '
                             'cases with oracles) instead of the legacy seek cases')
    parser.add_argument('--server', choices=['live', 'fixture'], default='live',
                        help='matrix server: the live one or the local '
                             'Navidrome-like transcoding fixture')
    parser.add_argument('--qualities', help='matrix qualities, e.g. original,opus128')
    parser.add_argument('--throttles', help='matrix throttles: none,wan6000,slow1500')
    parser.add_argument('--reps', type=int, help='repetitions per matrix cell')
    parser.add_argument('--shuffle-reps', type=int, default=0,
                        help='repetitions for the shuffle cases (default: --reps)')
    parser.add_argument('--resume-from', type=Path,
                        help='a matrix report.json whose finished cells are kept '
                             'and skipped (after an interrupted run)')
    parser.add_argument('--android-reverse', action='store_true',
                        help='matrix on Android: reach the proxy through adb reverse '
                             '(about 100 KB/s) instead of the emulator-side nc relay')
    parser.add_argument('--fixture-artists', type=int, default=240)
    parser.add_argument('--fixture-short-artists', type=int, default=60,
                        help='of those, artists whose songs are all 1-8 s (natural-end shuffle cases)')
    parser.add_argument('--transcode-speed', type=float, default=30.0,
                        help='fixture transcode speed in multiples of the bitrate')
    parser.add_argument('--natural-songs', type=int, default=1,
                        help='natural-end shuffle cases: songs let play to their end (default 1)')
    parser.add_argument('--fixture-static-transcode', action='store_true',
                        help='fixture answers transcodes like a cached Navidrome: whole body, '
                             'Content-Length and byte ranges')
    parser.add_argument('--no-transcode-offset', action='store_true',
                        help='fixture does not advertise/honour transcodeOffset')
    args = parser.parse_args()
    global NATURAL_SONGS
    NATURAL_SONGS = args.natural_songs
    if args.profile and args.server == 'fixture':
        credentials = {'url': 'http://127.0.0.1', 'username': 'diagnostics',
                       'password': 'synthetic-seek-fixture'}
    else:
        credentials = load_credentials(args.credentials)
    if args.build_only:
        BASE.mkdir(parents=True, exist_ok=True)
        build(credentials)
        return 0
    BASE.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    run = BASE / 'runs' / f'{stamp}-{args.label}'
    run.mkdir(parents=True)
    if args.profile:
        if args.android:
            if not args.skip_build or not ANDROID_APK.exists():
                build_android()
        elif not args.skip_build:
            build(load_credentials(args.credentials) if args.server == 'live' else credentials)
        elif not (ROOT / 'bundle' / 'navis').exists():
            raise Failure('no bundle: run without --skip-build once')
        ROOT.mkdir(parents=True, exist_ok=True)
        return run_matrix(args, credentials, AndroidApp(run, args.android) if args.android else App(run, 'linux'), run)
    server = Server(credentials)
    server.call('ping')
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
    cases = [c for c in (args.cases or ','.join(CASES)).split(',') if c]
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
