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


    def prime_stream(self, song_id: str, fmt: str | None, kbps: int | None) -> tuple:
        """Diagnostics: downloads a song's stream once, as the app asks for it, so
        Navidrome's transcode cache holds it and the next request is answered as a
        cached file (206, Content-Length) instead of a live chunked transcode.
        Returns (status, transfer-encoding, bytes)."""
        salt = secrets.token_hex(6)
        token = hashlib.md5((self.password + salt).encode()).hexdigest()
        params = {'u': self.username, 't': token, 's': salt, 'v': '1.16.1', 'c': 'Navis [Linux]',
                  'f': 'json', 'id': song_id}
        if fmt:
            params.update({'maxBitRate': kbps, 'format': fmt})
        request = Request(self.base + 'stream.view?' + urlencode(params),
                          headers={'User-Agent': 'Navis Desktop', 'Range': 'bytes=0-'})
        with urlopen(request, timeout=120) as r:
            size = len(r.read())
            return r.status, r.headers.get('Transfer-Encoding'), size


class ThrottledProxy:
    """A loopback reverse proxy to the server with a shared bandwidth limit
    and added first-byte latency, approximating a phone's connection.

    Range requests and their answers pass through unchanged, so the server's
    own seeking behaviour (206 or a linear 200) is preserved.
    """

    PORT = 47391

    def __init__(self, upstream: str, kbps: int, latency_ms: int, chunked=False, jsonl: Path | None = None):
        # chunked: answer a body of unknown length with real chunked framing
        # (as Navidrome does) instead of an HTTP/1.0 close-delimited body, so a
        # premature cut is an error for the client, not a clean EOF.
        # jsonl: every proxied request is also appended there as it ends.
        self.chunked = chunked
        self.jsonl = jsonl
        # Fault injection: the next `count` stream/download requests that
        # match `only` are cut after `after_bytes` of body (diagnostics).
        self.fault = None
        target = urlsplit(upstream)
        self.secure = target.scheme == 'https'
        self.host = target.hostname
        self.upstream_port = target.port or (443 if self.secure else 80)
        self.set_profile(kbps, latency_ms)
        self.stall_until = 0.0  # diagnostics: media bodies pause (connection kept open) until this monotonic time
        self.cut_until, self.cut_mode = 0.0, 'fin'  # diagnostics: in-flight media bodies are cut until this time
        self.tokens = 0.0
        self.requests = 0
        # One compact record per proxied request (no credentials), for the
        # matrix reports.
        self.log: list[dict] = []
        self.stamp = time.monotonic()
        self.lock = threading.Lock()
        self.lock_log = threading.Lock()
        proxy = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1' if chunked else 'HTTP/1.0'

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

    def stall(self, seconds: float):
        """Pauses every in-flight media body for [seconds] without closing the connection."""
        self.stall_until = time.monotonic() + seconds

    def cut_active(self, mode='fin', window=3.0):
        """Closes the in-flight media bodies (the next [window] s of chunks)."""
        self.cut_until, self.cut_mode = time.monotonic() + window, mode

    def arm_fault(self, after_bytes: int, count=1, only='any', mode='fin'):
        """Cuts the next [count] stream/download request(s) after [after_bytes]
        of body. [only]: 'any', 'transcode' (has a format) or 'download'."""
        self.fault = {'after': after_bytes, 'left': count, 'only': only, 'mode': mode}

    def _take_fault(self, entry):
        fault = self.fault
        if not fault or fault['left'] <= 0 or entry['endpoint'] not in ('stream', 'download'):
            return None
        if fault['only'] == 'transcode' and not entry.get('format'):
            return None
        if fault['only'] == 'download' and entry['endpoint'] != 'download':
            return None
        # The player's request is libmpv's ('Navis Desktop', with a Range); the sidecar download is Dart's.
        if fault['only'] == 'player' and not entry['ua'].startswith('Navis'):
            return None
        if fault['only'] == 'sidecar' and not entry['ua'].startswith('Dart'):
            return None
        fault['left'] -= 1
        return fault

    def _abort(self, handler, mode):
        import socket
        import struct
        handler.close_connection = True
        try:
            if mode == 'rst':
                handler.connection.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack('ii', 1, 0))
            else:
                handler.connection.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            handler.connection.close()
        except OSError:
            pass

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
                 'method': handler.command,
                 'endpoint': parts.path.rsplit('/', 1)[-1].removesuffix('.view'),
                 'id': params.get('id'), 'format': params.get('format'),
                 'maxBitRate': params.get('maxBitRate'),
                 'timeOffset': params.get('timeOffset'),
                 'range': handler.headers.get('Range'),
                 'ua': (handler.headers.get('User-Agent') or '')[:40], 'bytes': 0}
        is_media = entry['endpoint'] in ('stream', 'download')
        if is_media:
            self.log.append(entry)
        fault = self._take_fault(entry) if body else None
        sent_headers = False
        started = time.monotonic()
        try:
            time.sleep(self.latency)
            upstream.request(handler.command, handler.path, body=payload,
                             headers=headers)
            response = upstream.getresponse()
            entry['ttfbS'] = round(time.monotonic() - started, 2)
            entry['status'] = response.status
            entry['contentLength'] = response.getheader('Content-Length')
            entry['upstreamEncoding'] = response.getheader('Transfer-Encoding')
            entry['acceptRanges'] = response.getheader('Accept-Ranges')
            entry['contentRange'] = response.getheader('Content-Range')
            frame = self.chunked and body and entry['contentLength'] is None
            handler.send_response(response.status)
            for key in ('Content-Type', 'Content-Length', 'Content-Range',
                        'Accept-Ranges', 'Content-Disposition'):
                value = response.getheader(key)
                if value:
                    handler.send_header(key, value)
            if frame:
                handler.send_header('Transfer-Encoding', 'chunked')
            handler.send_header('Connection', 'close')
            handler.end_headers()
            sent_headers = True
            if not body:
                entry['end'] = 'head'
                return
            while True:
                chunk = response.read(16384)
                if not chunk:
                    break
                while time.monotonic() < self.stall_until:
                    time.sleep(0.1)
                if time.monotonic() < self.cut_until and is_media:
                    entry['end'] = f'injectedCut-{self.cut_mode}'
                    self._abort(handler, self.cut_mode)
                    return
                self.take(len(chunk))
                if fault and entry['bytes'] + len(chunk) >= fault['after']:
                    keep = max(0, fault['after'] - entry['bytes'])
                    if frame and keep:
                        handler.wfile.write(b'%x\r\n%s\r\n' % (keep, chunk[:keep]))
                    elif keep:
                        handler.wfile.write(chunk[:keep])
                    entry['bytes'] += keep
                    entry['end'] = f"injectedCut-{fault['mode']}"
                    self._abort(handler, fault['mode'])
                    return
                if frame:
                    handler.wfile.write(b'%x\r\n%s\r\n' % (len(chunk), chunk))
                else:
                    handler.wfile.write(chunk)
                entry['bytes'] += len(chunk)
            if frame:
                handler.wfile.write(b'0\r\n\r\n')
            entry['end'] = 'complete'
        except (BrokenPipeError, ConnectionResetError):
            entry['aborted'] = True
            entry['end'] = 'clientAborted'
        except Exception as error:
            entry['end'] = f'upstreamError:{type(error).__name__}'
            if sent_headers:
                # No terminal chunk and no error page in the body: the client
                # sees a premature end, as with a dropped upstream.
                self._abort(handler, 'fin')
            else:
                try:
                    handler.send_error(502)
                except Exception:
                    pass
        finally:
            entry['endW'] = round(time.time(), 3)
            upstream.close()
            if is_media and self.jsonl:
                with self.lock_log:
                    with self.jsonl.open('a') as out:
                        out.write(json.dumps(entry) + '\n')

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
        # The profile is sticky: every run states its cross-fade explicitly.
        connection.execute(
            'UPDATE app_settings SET crossfade_enabled = ?, crossfade_duration_seconds = ?, gapless_enabled = 1',
            (1 if CROSSFADE_S else 0, CROSSFADE_S or 5))


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
    'slow350': (350, 300),  # origin body still running 60 s into a song (stall/cut probes)
}
# Deadlines in seconds by throttle: seek landing, skip audible, stall limit.
DEADLINES = {
    'none': {'land': 15, 'advance': 12, 'stall': 6},
    'wan6000': {'land': 25, 'advance': 20, 'stall': 8},
    'slow1500': {'land': 45, 'advance': 35, 'stall': 12},
    'slow350': {'land': 45, 'advance': 35, 'stall': 30},
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
        # An offset transcode (1.5.1) plays from native 0: the transport reports
        # time inside the stream, so add the source's positionOffset to get song time.
        offset = state.get('positionOffsetMs') or 0
        if position is not None:
            position += offset
        else:
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
            'off': offset, 'pp': state.get('playerPositionMs'),
            'cf': {k: (state.get('crossfade') or {}).get(k) for k in ('enabled', 'active', 'disabledReason', 'lastFailure', 'phases')},
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
    if run.metrics.get('repeatOne'):
        return out  # repeat-one loops the song by design
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
                f'{extra} {f"AND MAX(s.duration) <= {int(LIVE_MAX_SONG_S)}" if LIVE_MAX_SONG_S else ""} ORDER BY RANDOM() LIMIT 40', (low, high)).fetchall()
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

    def _reused(self, kind, pick):
        # diagnostics (--live-reuse-groups): the same album/artist again, so its
        # songs now play from the rolling cache the first pass filled.
        saved = BASE / 'reuse-groups.json'
        groups = json.loads(saved.read_text()) if saved.exists() else {}
        if kind not in groups:
            groups[kind] = pick()
            saved.write_text(json.dumps(groups))
        return groups[kind]

    def fresh_album(self, short=False):
        if LIVE_REUSE_GROUPS:
            return self._reused('album', lambda: self._take_ids(self._groups('album_id', 6, 14)[1]))
        return self._take_ids(self._groups('album_id', 6, 14)[1])

    def fresh_artist(self, short=False):
        if LIVE_REUSE_GROUPS:
            artist, ids = self._reused('artist', lambda: list(self.fresh_artist_raw()))
            return artist, ids
        artist, ids = self._groups('artist_id', 15, 45, 'AND COUNT(DISTINCT s.album_id) BETWEEN 2 AND 4')
        return artist, self._take_ids(ids)

    def fresh_artist_raw(self):
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


SLOW_NEXT_S = 0  # --slow-next-s
PRIME_SERVER_CACHE = False  # --prime-server-cache
LIVE_REUSE_GROUPS = False  # --live-reuse-groups
CROSSFADE_S = 0  # --crossfade-s: cross-fade seconds written into the profile (0 = off)
VERIFY_OFFSET = False  # --verify-offset: judge seeks by the transcodeOffset oracle
REPEAT_MODE = 'none'  # --repeat-mode: set after every case's mode reset
LIVE_MAX_SONG_S = 0  # --live-max-song-s: live groups whose songs are all at most this long (0 = any)
NATURAL_FULL = False  # --natural-full: later songs play to their real end instead of being seeked near it
NATURAL_SONGS = 1  # --natural-songs: songs that end by themselves (a long one after the first is seeked to its end)


def slow_next_song(run: Run, env, first):
    """--slow-next-s: shortly before song 1 ends, every proxied request waits this long
    before it is forwarded (the next song's first byte arrives late), then the proxy is
    restored. Diagnostics for the stall watchdog and recovery at a song change."""
    proxy, delay = env.proxy, SLOW_NEXT_S
    restore = THROTTLES[run.throttle]
    start_after = max(0.0, first['dur'] / 1000 - 6.0 - (time.monotonic() - run.t0 - first['t']))
    run.metrics['slowNext'] = {'delayS': delay, 'armedAfterS': round(start_after, 1)}

    def worker():
        time.sleep(start_after)
        proxy.set_profile(restore[0], delay * 1000)
        run.metrics['slowNextArmedAt'] = round(run.now(), 1)
        time.sleep(6.0 + delay + 15.0)
        proxy.set_profile(*restore)
        run.metrics['slowNextEndedAt'] = round(run.now(), 1)

    threading.Thread(target=worker, daemon=True).start()


def prime_server_cache(run: Run, ids):
    """--prime-server-cache: fetch every song of the selection once straight from the
    live server, so the app's own requests are answered from Navidrome's transcode cache."""
    if not PRIME_SERVER_CACHE or run.backend.name != 'live':
        return
    fmt, kbps = QUALITIES[run.quality]
    primed = [run.backend.server.prime_stream(i, fmt, kbps) for i in ids]
    run.metrics['primed'] = [list(p) for p in primed]


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
            prime_server_cache(run, ids)
            rec = start_queue(run, ids, shuffle=True)
        else:
            artist, ids = backend.fresh_artist(short=True)
            run.songs = [{'id': i} for i in ids]
            prime_server_cache(run, ids)
            run.shuffled = True
            rec = run.act('start', artist=artist, shuffle=True)
            run.app.api('/v1/artists/playback', {'command': 'prepare', 'artistId': artist, 'action': 'shuffle'}, timeout=60)
        first = await_audio(run, rec)
        run.metrics.update(firstSong=first['songId'], firstDurMs=first['dur'], shortGroups=backend.short_groups)
        if SLOW_NEXT_S and first['dur']:
            slow_next_song(run, env, first)
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
        run.observe(3.0 + (SLOW_NEXT_S + 14 if SLOW_NEXT_S else 0))  # a slow next song gets time to stall and recover on its own
        run.metrics['firstTransition'] = excerpt(run, moved['t'], 4.0, 3.0 + (SLOW_NEXT_S + 14 if SLOW_NEXT_S else 0), limit=80)
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            for n in range(min(4, len(ids) - 2)):
                cur = run.last()
                if cur['dur'] and cur['dur'] <= 12000:
                    run.until(lambda s, c=cur: s['idx'] != c['idx'], 2 * cur['dur'] / 1000 + run.deadlines['advance'])
                elif cur['dur'] and n + 1 < NATURAL_SONGS and NATURAL_FULL:
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


# ---------------------------------------------------------------------------
# 1.5.1 transcode offset seek verification (--verify-offset, cases offset_*).

def seek_events_since(run: Run, baseline: int) -> list[dict]:
    status = run.app.api('/v1/playback/status', timeout=30)
    return [e for e in status.get('seekEvents') or [] if (e.get('generation') or 0) > baseline]


def oracle_offset(run: Run, recs: list[dict], expect_offset: bool, strict_land=3.0) -> list[dict]:
    """Per seek: on a transcode with an incomplete local cache it takes the transcodeOffset
    path, sends timeOffset=<floor seconds> and lands within 3 s / 1.5 s of the target. When
    the whole file was already downloaded before the seek, the completed file wins by design
    (noted, not a failure). On original it never uses either."""
    out = []
    events = seek_events_since(run, run.metrics.get('seekGenerationBaseline', 0))
    run.metrics['seekPaths'] = [{k: e.get(k) for k in ('generation', 'path', 'requestedPositionMs', 'afterPositionMs',
                                                       'elapsedMs', 'outcome', 'afterSourceKind')} for e in events]
    media = [r for r in run.env.proxy.log[run.proxy_mark:] if r['endpoint'] in ('stream', 'download')]
    offsets = [r for r in media if r.get('timeOffset')]
    run.metrics['timeOffsetRequests'] = [{'id': r['id'], 'timeOffset': r['timeOffset'], 'status': r.get('status'),
                                          'bytes': r.get('bytes'), 'end': r.get('end')} for r in offsets]
    for rec in recs:
        event = next((e for e in reversed(events) if abs((e.get('requestedPositionMs') or -10**9) - rec['target']) <= 1), None)
        path = event.get('path') if event else None
        rec['path'] = path
        want_s = rec['target'] // 1000
        sent = [r for r in offsets if r['id'] == rec['song'] and abs(int(r['timeOffset']) - want_s) <= 1]
        rec['timeOffsetSent'] = [r['timeOffset'] for r in sent]
        full_before = [r for r in media if r['id'] == rec['song'] and not r.get('timeOffset') and r.get('end') == 'complete'
                       and (r.get('endW') or 1e12) <= rec['w']]
        if not expect_offset:
            if path == 'transcodeOffset' or any(r['id'] == rec['song'] for r in offsets):
                out.append(violation('offsetOnOriginal', rec['t'], f"path={path} timeOffset requests={rec['timeOffsetSent']}", run))
            continue
        if path == 'transcodeOffset':
            if not sent:
                out.append(violation('offsetNoRequest', rec['t'], f"path transcodeOffset for target {rec['target']} but no "
                                     f"timeOffset~{want_s} stream request (offset requests: {[r['timeOffset'] for r in offsets]})", run))
            if rec.get('latency') is not None and rec['latency'] > strict_land:
                out.append(violation('offsetLate', rec['t'], f"landed {rec['latency']:.1f}s after the seek (limit {strict_land}s)", run))
        elif full_before:
            rec['note'] = 'cacheCompleteBeforeSeek'
        elif sent and any(r['id'] == rec['song'] and not r.get('timeOffset') and r.get('end') == 'complete'
                          and rec['w'] <= (r.get('endW') or 0) <= rec['w'] + 8 for r in media):
            # The offset reload started, then the full download finished while it settled: the
            # handler reloads from the completed file by design (recovery path).
            rec['note'] = 'offsetThenCacheComplete'
        else:
            out.append(violation('offsetPathNotTaken', rec['t'], f"path={path} for target {rec['target']} while the full "
                                 f"download was not complete (events {[e.get('path') for e in events]}, "
                                 f"offset requests {len(offsets)})", run))
    for rec in recs:  # landing error, signed (negative = early)
        after = [s for s in run.samples if s['t'] >= rec['t'] and s['songId'] == rec['song'] and s['proc'] == 'ready'
                 and s['pos'] is not None]
        landed_sample = next((s for s in after if abs(s['pos'] - rec['target']) <= LAND_TOLERANCE_MS), None)
        if landed_sample is not None:
            rec['err'] = landed_sample['pos'] - rec['target']
            rec['landedOff'] = landed_sample['off']
            rec['durAfter'] = landed_sample['dur']
        run.metrics.setdefault('landings', []).append({k: rec.get(k) for k in (
            'target', 'path', 'note', 'latency', 'err', 'landedOff', 'durAfter', 'timeOffsetSent')})
        # The player's own song-time position must agree with the transport + offset.
        if landed_sample is not None and landed_sample['pp'] is not None:
            later = next((s for s in run.samples if s['t'] >= landed_sample['t'] + 1 and s['pos'] is not None
                          and s['pp'] is not None and s['proc'] == 'ready'), None)
            if later and abs(later['pos'] - later['pp']) > 2500:
                out.append(violation('offsetPositionDisagree', later['t'], f"transport+offset={later['pos']} but "
                                     f"player.position={later['pp']} (offset {later['off']})", run))
    return out


def rolling_names(run: Run) -> set:
    if isinstance(run.app, AndroidApp):
        out = run.app.shell('run-as', ANDROID_PACKAGE, 'sh', '-c',
                            f"'ls {ANDROID_ROOT}/cache/audio/rolling 2>/dev/null'", check=False)
        return set(out.split())
    folder = ROOT / 'cache' / 'audio' / 'rolling'
    return {f.name for f in folder.iterdir()} if folder.exists() else set()


def rolling_fetch(run: Run, name: str, dest: Path) -> int | None:
    """Copy one rolling-cache file out of the profile; returns its size or None."""
    if isinstance(run.app, AndroidApp):
        with dest.open('wb') as out:
            result = subprocess.run(run.app.adb + ['exec-out', 'run-as', ANDROID_PACKAGE, 'cat',
                                                   f'{ANDROID_ROOT}/cache/audio/rolling/{name}'], stdout=out)
        return dest.stat().st_size if result.returncode == 0 else None
    source = ROOT / 'cache' / 'audio' / 'rolling' / name
    if not source.exists():
        return None
    shutil.copyfile(source, dest)
    return dest.stat().st_size


def probe_seconds(path: Path) -> float | None:
    result = subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', str(path)],
                            capture_output=True, text=True)
    try:
        return float(result.stdout.strip())
    except ValueError:
        return None


def oracle_cache_integrity(run: Run, song_id: str, duration_s: float, before: set, quality: str) -> list[dict]:
    """The rolling-cache file of a song that was offset-sought must be the whole
    song (ffprobe duration within 1 s of the metadata duration), never one that starts at T."""
    fmt, kbps = QUALITIES[quality]
    suffix = run.metrics.get('songSuffix') or 'flac'
    digest = hashlib.sha1(f'{song_id}::{kbps}::{fmt}::{suffix}'.encode()).hexdigest()
    name = f'{digest}.{fmt}' if fmt else None
    deadline = time.monotonic() + 150
    sizes, size = [], None
    while time.monotonic() < deadline:  # wait for the full download: file present and its size stable for 4 s
        names = rolling_names(run)
        if name in names:
            size = rolling_fetch(run, name, run.app.run / 'cache-probe.bin')
            sizes.append(size)
            if len(sizes) >= 4 and len(set(sizes[-4:])) == 1:
                break
        time.sleep(1.0)
    new = sorted(rolling_names(run) - before)
    info = {'songId': song_id, 'file': name, 'newFiles': new, 'metadataDurationS': duration_s, 'sizeBytes': size,
            'sizeHistory': sizes[-6:]}
    out = []
    if name not in rolling_names(run):
        info['verdict'] = 'file missing'
        out.append(violation('cacheMissing', run.now(), f"rolling file {name} never appeared; new files {new}", run))
    else:
        kept = run.app.run / f'cache-{song_id}.{fmt}'
        rolling_fetch(run, name, kept)
        seconds = probe_seconds(kept)
        info['ffprobeDurationS'] = seconds
        info['copy'] = str(kept)
        if seconds is None or abs(seconds - duration_s) > 1.5:
            out.append(violation('cacheCorrupt', run.now(), f"rolling file {name}: ffprobe duration {seconds} s vs "
                                 f"metadata {duration_s} s ({size} bytes)", run))
            info['verdict'] = 'FAIL'
        else:
            info['verdict'] = 'ok'
    for r in run.env.proxy.log[run.proxy_mark:]:
        if r['id'] == song_id and r['endpoint'] in ('stream', 'download'):
            info.setdefault('requests', []).append({k: r.get(k) for k in ('endpoint', 'timeOffset', 'status', 'bytes', 'end', 'range')})
    run.metrics['cacheIntegrity'] = info
    return out


def song_info(run: Run, song_id: str) -> tuple[float, str]:
    song = run.backend.server.call('getSong', id=song_id)['song']
    run.metrics['songSuffix'] = song.get('suffix')
    return float(song['duration']), song.get('suffix') or 'flac'


def offset_case_prologue(run: Run):
    run.metrics['seekGenerationBaseline'] = max([e.get('generation') or 0 for e in
                                                run.app.api('/v1/playback/status', timeout=30).get('seekEvents') or []] or [0])


def case_offset_natural(run: Run, env):
    """Seek to 65%, play to the natural end: the next song follows, no replay; then the
    sought song's rolling-cache file is whole."""
    offset_case_prologue(run)
    before = rolling_names(run)
    ids = env.backend.fresh_album()
    run.songs = [{'id': i} for i in ids]
    duration_s, _ = song_info(run, ids[0])
    rec = start_queue(run, ids)
    first = await_audio(run, rec, ids[0])
    run.observe(5.0)
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        seek = issue_seek(run, pool, int(duration_s * 1000 * 0.65))
        landed(run, seek)
        finish_futures(run)
    run.observe(2.0)
    remaining = duration_s * 0.35
    moved = run.until(lambda s: s['idx'] != first['idx'] or s['songId'] != first['songId'],
                      remaining + 2 * run.deadlines['advance'] + 30)
    run.metrics['naturalHandoverAt'] = moved and moved['t']
    if moved is None:
        run.violations.append(violation('naturalEndNoContinuation', run.now(), f"no next song after the sought song; "
                                        f"last={ {k: run.last()[k] for k in ('idx', 'songId', 'pos', 'proc', 'playing')} }", run))
        raise CaseAbort('no natural end')
    run.observe(8.0)
    run.checks.append(lambda: oracle_seek(run, seek))
    run.checks.append(lambda: oracle_sequence(run, ids, minimum=2))
    run.checks.append(lambda: oracle_offset(run, [seek], run.quality != 'original'))
    run.checks.append(lambda: oracle_cache_integrity(run, ids[0], duration_s, before, run.quality))
    run.latency_from = [seek]


def case_offset_repeat_one(run: Run, env):
    """Repeat-one with an offset seek: the loop restarts at 0:00, never at the sought position."""
    offset_case_prologue(run)
    run.metrics['repeatOne'] = True
    song = min(env.backend.fresh_songs(6), key=lambda x: x['duration'])  # shortest: the second loop costs one song length
    duration_ms = int(song['duration']) * 1000
    run.app.api('/v1/playback/repeat', {'mode': 'one'})
    start_single(run, song)
    run.observe(5.0)
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        seek = issue_seek(run, pool, int(duration_ms * 0.88))
        landed(run, seek)
        finish_futures(run)
    t_seek = seek['t']
    wrapped = run.until(lambda s: s['t'] > t_seek and s['songId'] == song['id'] and s['pos'] is not None
                        and s['pos'] < 4000 and s['proc'] == 'ready', duration_ms * 0.2 / 1000 + 60 + run.deadlines['advance'])
    run.metrics['loopWrappedAt'] = wrapped and wrapped['t']
    if wrapped is None:
        run.violations.append(violation('repeatOneNoLoop', run.now(), 'position never wrapped to the start', run))
        raise CaseAbort('no loop')
    run.observe(8.0)
    wrapped2 = run.until(lambda s: s['t'] > wrapped['t'] + 30 and s['songId'] == song['id'] and s['pos'] is not None
                         and s['pos'] < 4000 and s['proc'] == 'ready', duration_ms / 1000 + 2 * run.deadlines['advance'])
    run.metrics['loop2WrappedAt'] = wrapped2 and wrapped2['t']
    if wrapped2 is None:
        run.violations.append(violation('repeatOneNoSecondLoop', run.now(), 'position never wrapped a second time', run))
    run.observe(6.0)
    after = [s for s in run.samples if s['t'] >= wrapped['t'] and s['pos'] is not None and s['songId'] == song['id']]

    def check():
        # The loop is expected to return the position below the target: only count regressions before it.
        out = [v for v in oracle_seek(run, seek) if not (v['oracle'] == 'seekRegressed' and v['t'] >= wrapped['t'] - 1)]
        out += oracle_offset(run, [seek], run.quality != 'original')
        repeats = [r for r in run.env.proxy.log[run.proxy_mark:] if r['id'] == song['id'] and r.get('timeOffset')]
        # Requests while the offset stream plays (before the first loop) are ExoPlayer's own re-opens,
        # counted as a metric; a request that starts after the loop is the loop re-requesting T.
        loop_w = run.w0 + wrapped['t']
        after_loop = [r for r in repeats if r['w'] >= loop_w - 1]
        run.metrics['timeOffsetRequestCount'] = len(repeats)
        run.metrics['timeOffsetRequestsAfterLoop'] = len(after_loop)
        if after_loop:
            out.append(violation('timeOffsetRequestAfterLoop', wrapped['t'], f"{len(after_loop)} timeOffset requests after "
                                 f"the loop: {[r['timeOffset'] for r in after_loop]}", run))
        jumped = next((s for s in after if s['pos'] > 12000 + (s['t'] - wrapped['t']) * 1000
                       and not (wrapped2 and s['t'] >= wrapped2['t'] - 1)), None)
        if jumped:
            out.append(violation('repeatOneJumpedToSeek', jumped['t'], f"after the loop pos={jumped['pos']} (offset "
                                 f"{jumped['off']}), wrap sample pos={wrapped['pos']}", run))
        late = [s for s in after if s['t'] >= wrapped['t'] + 4 and s['t'] <= wrapped['t'] + 8]
        if late and late[-1]['pos'] - late[0]['pos'] < 1500:
            out.append(violation('repeatOneNotAdvancing', wrapped['t'], f"{late[0]['pos']}->{late[-1]['pos']}", run))
        run.metrics['loopSamples'] = [(round(s['t'], 1), s['pos'], s['off'], s['proc']) for s in after[::10][:12]]
        return out
    run.checks.append(check)
    run.latency_from = [seek]


def case_offset_repeat_all(run: Run, env):
    """Repeat-all with an album: offset-seek song 1 to 65%, let it end; song 2 must start at 0
    and play untouched (no seek, offset, reload or position jump back), and song 1 must not replay."""
    offset_case_prologue(run)
    run.metrics['repeatAll'] = True
    ids = env.backend.fresh_album()
    run.songs = [{'id': i} for i in ids]
    duration_s, _ = song_info(run, ids[0])
    run.app.api('/v1/playback/repeat', {'mode': 'all'})
    rec = start_queue(run, ids)
    first = await_audio(run, rec, ids[0])
    run.observe(5.0)
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        seek = issue_seek(run, pool, int(duration_s * 1000 * 0.65))
        landed(run, seek)
        finish_futures(run)
    moved = run.until(lambda s: s['songId'] != first['songId'] and s['proc'] == 'ready' and s['playing'],
                      duration_s * 0.35 + 2 * run.deadlines['advance'] + 30)
    if moved is None:
        run.violations.append(violation('naturalEndNoContinuation', run.now(), 'song 2 never started', run))
        raise CaseAbort('no natural end')
    run.metrics['song2StartedAt'] = moved['t']
    run.observe(24.0)

    def check():
        out = oracle_seek(run, seek) + oracle_offset(run, [seek], run.quality != 'original')
        s2 = [x for x in run.samples if x['t'] >= moved['t'] and x['songId'] == moved['songId'] and x['pos'] is not None]
        run.metrics['song2'] = {'id': moved['songId'], 'firstPos': s2[0]['pos'] if s2 else None,
                                'lastPos': s2[-1]['pos'] if s2 else None, 'spanS': round(s2[-1]['t'] - s2[0]['t'], 1) if s2 else 0,
                                'offsets': sorted({x['off'] for x in s2})}
        if not s2 or s2[-1]['t'] - s2[0]['t'] < 20:
            out.append(violation('song2TooShort', moved['t'], f"song 2 observed {run.metrics['song2']['spanS']} s", run))
        if s2 and s2[0]['pos'] > 3000:
            out.append(violation('song2NotAtZero', s2[0]['t'], f"first position {s2[0]['pos']} (offset {s2[0]['off']})", run))
        back = next((b for a, b in zip(s2, s2[1:]) if b['pos'] < a['pos'] - 1000), None)
        if back:
            out.append(violation('song2PositionJumpedBack', back['t'], f"pos fell to {back['pos']}", run))
        if any(x['off'] for x in s2):
            out.append(violation('song2HasOffset', moved['t'], f"offsets {run.metrics['song2']['offsets']}", run))
        touched = [e for e in run.trace if e['rel'] >= moved['t'] + 0.5
                   and (e['kind'] in ('seekRequest', 'seekStage', 'setAudioSources')
                        or (e['kind'] == 'sourceResolved' and e.get('timeOffset'))
                        or e.get('path') == 'transcodeOffset' or e.get('stage') == 'recovering')]
        run.metrics['song2TraceTouches'] = [{k: e.get(k) for k in ('rel', 'kind', 'stage', 'songId', 'timeOffset', 'initialPositionMs')} for e in touched][:10]
        if touched:
            out.append(violation('song2Reloaded', touched[0]['rel'], f"{len(touched)} seek/reload trace entries on song 2", run))
        out += oracle_sequence(run, ids, minimum=2)
        return out
    run.checks.append(check)
    run.latency_from = [seek]


def origin_event_probe(mode: str):
    """Hypothesis probe (media3 read timeout vs the app proxy's body timeout): ~60 s into song 1 of a
    shuffled album, stall the origin body for 12 s (connection kept open) or cut it; record whether
    song 1 restarts at 0, ends early and advances, or recovers in place."""
    def case(run: Run, env):
        ids = env.backend.fresh_album()
        run.songs = [{'id': i} for i in ids]
        run.shuffled = True
        rec = start_queue(run, ids, shuffle=True)
        first = await_audio(run, rec)
        at = run.until(lambda s: s['songId'] == first['songId'] and (s['pos'] or 0) >= 60000, 150)
        if at is None:
            raise CaseAbort('song 1 never reached 60 s')
        device_ms = None
        if isinstance(run.app, AndroidApp):
            device_ms = int(run.app.shell('date', '+%s%3N').strip() or 0)
        run.metrics.update(eventMode=mode, eventAt=run.now(), eventWall=round(time.time(), 2), eventDeviceMs=device_ms,
                           eventPos=at['pos'], eventBufMs=at['buf'], eventSong=first['songId'])
        run.act('originEvent', mode=mode)
        env.proxy.stall(12.0) if mode == 'stall' else env.proxy.cut_active('fin')
        run.observe(45.0)
        t_event = run.metrics['eventAt']
        after = [s for s in run.samples if s['t'] >= t_event and s['pos'] is not None]
        restarted = next((s for s in after if s['songId'] == first['songId'] and s['idx'] == first['idx'] and s['pos'] < 5000
                          and (at['pos'] or 0) > 50000), None)
        advanced = next((s for s in after if s['songId'] != first['songId']), None)
        frozen = [s for s in after if s['songId'] == first['songId']]
        run.metrics['eventVerdict'] = ('restartedAt0' if restarted else 'endedEarlyAdvanced' if advanced else 'recoveredInPlace')
        run.metrics['eventDetail'] = {'restartedAtT': restarted and round(restarted['t'] - t_event, 1),
                                      'advancedAtT': advanced and round(advanced['t'] - t_event, 1),
                                      'posAfter45s': frozen[-1]['pos'] if frozen else None,
                                      'minPosAfter': min((s['pos'] for s in frozen), default=None)}
        if device_ms:
            keys = ('processingState', 'playing', 'positionMs', 'bufferedMs', 'stage', 'reason', 'phase', 'errorCode', 'index', 'songId', 'operation')
            run.metrics['traceAround'] = [
                f"{(e['atMs'] - device_ms) / 1000:+.1f}s {e['kind']} " + ' '.join(f'{k}={e[k]}' for k in keys if e.get(k) is not None)
                for e in run.trace if e['kind'] != 'bufferState' and device_ms - 8000 <= e['atMs'] <= device_ms + 46000][:60]
    return case


def case_offset_prev(run: Run, env):
    """Previous after an offset seek restarts the song at 0."""
    offset_case_prologue(run)
    song = env.backend.fresh_songs(1)[0]
    duration_ms = int(song['duration']) * 1000
    start_single(run, song)
    run.observe(5.0)
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        seek = issue_seek(run, pool, int(duration_ms * 0.5))
        landed(run, seek)
        finish_futures(run)
        run.observe(5.0)
        prev = nav(run, pool, 'prev')
        wait_advanced(run, prev)
        run.observe(8.0)
    after = [s for s in run.samples if s['t'] >= prev['t'] and s['pos'] is not None]

    def check():
        out = oracle_seek(run, seek) + oracle_offset(run, [seek], run.quality != 'original')
        restarted = next((s for s in after if s['pos'] < 2500 and s['proc'] == 'ready' and s['songId'] == song['id']), None)
        if restarted is None:
            out.append(violation('prevNoRestart', prev['t'], f"never back near 0; last pos={after[-1]['pos'] if after else None}", run))
        else:
            wrong = next((s for s in after if s['t'] >= restarted['t'] + 0.5 and s['t'] <= restarted['t'] + 7
                          and s['pos'] > 2500 + (s['t'] - restarted['t']) * 1000 + 3000), None)
            if wrong:
                out.append(violation('prevJumpedBack', wrong['t'], f"pos={wrong['pos']} after the restart at {restarted['pos']}", run))
            run.metrics['prevRestartedAfterS'] = round(restarted['t'] - prev['t'], 2)
        return out
    run.checks.append(check)


CASE_FUNCS = {
    'seek_early': seek_case([0.3], play_s=0),
    'seek_pastdl': seek_case([0.92], play_s=0),
    'seek_far': seek_case([0.75]),
    'seek_mid': seek_case([0.4]),
    'seek_back': seek_case([0.6, 0.15], sequential=True),
    'seek_burst': seek_case([0.3, 0.7, 0.45]),
    'seek_paused': seek_case([0.65], play_s=3.0, paused=True),
    'offset_quick': seek_case([0.4, 0.2, 0.6]),
    'offset_far': seek_case([0.75], play_s=0.3),  # seeks before an unthrottled download can finish
    'offset_back': seek_case([0.6, 0.15], play_s=0.3, sequential=True),
    'offset_natural': case_offset_natural,
    'offset_repeat_one': case_offset_repeat_one,
    'offset_prev': case_offset_prev,
    'probe_stall': origin_event_probe('stall'),
    'probe_cut': origin_event_probe('cut'),
    'offset_repeat_all': case_offset_repeat_all,
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
    if getattr(proxy, 'fault_template', None):
        proxy.arm_fault(**proxy.fault_template)  # diagnostics: re-armed for every case
        run.metrics['faultInjected'] = proxy.fault_template
    sampler = Sampler(run)
    reset_modes(app)
    if REPEAT_MODE != 'none':
        app.api('/v1/playback/repeat', {'mode': REPEAT_MODE})  # diagnostics: the owner's profile may keep Repeat on
        run.metrics['repeatMode'] = REPEAT_MODE
    # Baseline the trace so earlier runs' events are not re-read.
    baseline = app.api('/v1/playback/status')
    run._trace_seq = max([e['seq'] for e in baseline.get('transportTrace') or []] or [0])
    sampler.start()
    error = None
    run.proxy_mark = proxy_mark
    try:
        offset_case_prologue(run)
        CASE_FUNCS[case](run, env)
        if VERIFY_OFFSET and case in ('seek_far', 'seek_back', 'seek_mid', 'seek_early', 'offset_quick', 'offset_far', 'offset_back'):
            seeks = [a for a in run.actions if a['kind'] == 'seek']
            judged = seeks[-1:] if case == 'offset_quick' else seeks
            run.checks.append(lambda: oracle_offset(run, judged, quality != 'original'))
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
    proxy = ThrottledProxy(backend.upstream, 0, 0, chunked=args.proxy_chunked, jsonl=run_dir / 'proxy.jsonl')
    if args.cut_after_kb:
        proxy.fault_template = {'after_bytes': args.cut_after_kb * 1000, 'count': args.cut_count,
                                'only': args.cut_only, 'mode': args.cut_mode}
    try:
        (ROOT / 'password').write_text(backend.credentials['password'] + '\n')
        os.chmod(ROOT / 'password', 0o600)
        marker = ROOT / 'profile-server'
        android = isinstance(app, AndroidApp)
        app_url = backend.upstream if args.direct else proxy.url  # --direct: the app talks to the live server itself (no proxy log, no throttle)
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
            point_profile_at(app_url)
        app.launch()
        sign_in(app, backend.credentials, 'wifi', app_url)
        env = type('Env', (), {'backend': backend, 'profile': args.profile, 'proxy': proxy})()
        # Fail fast if the app is not using the proxy.
        before = proxy.requests
        app.api('/v1/presentation/search', {'query': 'a', 'filter': 'songs'}, timeout=40)
        if proxy.requests == before and not args.direct:
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
    parser.add_argument('--direct', action='store_true',
                        help='diagnostics: the app talks to the live server directly over HTTPS (no proxy, no throttle); use with NAVIS_MPV_LOG_LEVEL')
    parser.add_argument('--proxy-chunked', action='store_true',
                        help='diagnostics: the proxy frames unknown-length bodies as chunked (like Navidrome)')
    parser.add_argument('--cut-after-kb', type=int, default=0,
                        help='diagnostics: cut the next stream/download request(s) of every case after this many KB')
    parser.add_argument('--cut-count', type=int, default=1)
    parser.add_argument('--cut-only', choices=['any', 'transcode', 'download', 'player', 'sidecar'], default='any')
    parser.add_argument('--cut-mode', choices=['fin', 'rst'], default='fin')
    parser.add_argument('--live-max-song-s', type=int, default=0,
                        help='live natural-end cases: only albums/artists whose songs are all at most this long')
    parser.add_argument('--slow-next-s', type=int, default=0,
                        help="diagnostics: delay every request by this many seconds from 6 s before song 1 ends (natural-end cases)")
    parser.add_argument('--prime-server-cache', action='store_true',
                        help="diagnostics: download the selected songs once first so Navidrome answers the app from its transcode cache")
    parser.add_argument('--live-reuse-groups', action='store_true',
                        help='diagnostics: every natural-end case shuffles the same live album/artist (its songs play from the rolling cache after the first pass)')
    parser.add_argument('--crossfade-s', type=int, default=0,
                        help='enable cross-fade (and gapless) with this many seconds in the profile; 0 = off')
    parser.add_argument('--repeat-mode', choices=['none', 'all', 'one'], default='none',
                        help='diagnostics: repeat mode set at the start of every case')
    parser.add_argument('--natural-full', action='store_true',
                        help='natural-end cases: later songs (up to --natural-songs) play to their real end')
    parser.add_argument('--natural-songs', type=int, default=1,
                        help='natural-end shuffle cases: songs let play to their end (default 1)')
    parser.add_argument('--fixture-static-transcode', action='store_true',
                        help='fixture answers transcodes like a cached Navidrome: whole body, '
                             'Content-Length and byte ranges')
    parser.add_argument('--verify-offset', action='store_true',
                        help='1.5.1 offset-seek verification: seeks must take the transcodeOffset path on a '
                             'transcode (and never on original), land within 3 s, and send timeOffset')
    parser.add_argument('--no-transcode-offset', action='store_true',
                        help='fixture does not advertise/honour transcodeOffset')
    args = parser.parse_args()
    global CROSSFADE_S, NATURAL_SONGS, NATURAL_FULL, LIVE_MAX_SONG_S, REPEAT_MODE, LIVE_REUSE_GROUPS, PRIME_SERVER_CACHE, SLOW_NEXT_S, VERIFY_OFFSET
    CROSSFADE_S = args.crossfade_s
    LIVE_REUSE_GROUPS, PRIME_SERVER_CACHE, SLOW_NEXT_S = args.live_reuse_groups, args.prime_server_cache, args.slow_next_s
    VERIFY_OFFSET = args.verify_offset
    NATURAL_SONGS, NATURAL_FULL, LIVE_MAX_SONG_S, REPEAT_MODE = args.natural_songs, args.natural_full, args.live_max_song_s, args.repeat_mode
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
