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
# The harness (tool/playback_harness.py) moves the data root and app-id suffix out of the
# worktree so a cached bundle runs from any checkout.
BASE = Path(os.environ.get('NAVIS_LIVE_SEEK_BASE', PROJECT / 'build' / 'live-seek'))
SUFFIX = os.environ.get('NAVIS_LIVE_SEEK_SUFFIX', '.liveseek')
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
        self.pace = None  # diagnostics: (song id, bytes/s): that song's un-offset bodies are paced to real time
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

    def pace_song(self, song_id, kbps):
        self.pace = (song_id, kbps * 1000 / 8) if song_id else None

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

    def _open(self, handler, upstream, payload, headers):
        """Waits for the upstream answer but notices a client that hangs up meanwhile (so a preview
        request the app already closed ends now, not when the transcode finally answers)."""
        import select
        result = {}

        def ask():
            try:
                time.sleep(self.latency)
                upstream.request(handler.command, handler.path, body=payload, headers=headers)
                result['response'] = upstream.getresponse()
            except Exception as error:
                result['error'] = error

        asker = threading.Thread(target=ask, daemon=True)
        asker.start()
        while asker.is_alive():
            asker.join(0.01)
            conn = handler.connection
            try:
                if select.select([conn], [], [], 0)[0] and conn.recv(1, 2) == b'':  # 2 = MSG_PEEK
                    upstream.close()
                    raise BrokenPipeError('client closed before the answer')
            except (OSError, ValueError):
                raise BrokenPipeError('client closed before the answer')
        if 'error' in result:
            raise result['error']
        return result['response']

    def forward(self, handler, body: bool):
        self.requests += 1
        connection_type = (http.client.HTTPSConnection if self.secure
                           else http.client.HTTPConnection)
        upstream = connection_type(self.host, self.upstream_port, timeout=120)
        headers = {k: v for k, v in handler.headers.items()
                   if k.lower() in ('range', 'if-range', 'user-agent', 'accept',
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
                 'ifRange': handler.headers.get('If-Range'),
                 'ua': (handler.headers.get('User-Agent') or '')[:40], 'bytes': 0}
        is_media = entry['endpoint'] in ('stream', 'download')
        if is_media:
            self.log.append(entry)
        fault = self._take_fault(entry) if body else None
        sent_headers = False
        started = time.monotonic()
        try:
            response = self._open(handler, upstream, payload, headers)
            entry['ttfbS'] = round(time.monotonic() - started, 2)
            entry['status'] = response.status
            entry['contentLength'] = response.getheader('Content-Length')
            entry['upstreamEncoding'] = response.getheader('Transfer-Encoding')
            entry['acceptRanges'] = response.getheader('Accept-Ranges')
            entry['contentRange'] = response.getheader('Content-Range')
            entry['etag'] = response.getheader('ETag')
            frame = self.chunked and body and entry['contentLength'] is None
            handler.send_response(response.status)
            for key in ('Content-Type', 'Content-Length', 'Content-Range',
                        'Accept-Ranges', 'Content-Disposition', 'ETag', 'Last-Modified'):
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
                while is_media and time.monotonic() < self.stall_until:
                    time.sleep(0.1)
                if time.monotonic() < self.cut_until and is_media:
                    entry['end'] = f'injectedCut-{self.cut_mode}'
                    self._abort(handler, self.cut_mode)
                    return
                self.take(len(chunk))
                if self.pace and entry['id'] == self.pace[0]:
                    time.sleep(len(chunk) / self.pace[1])
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


ANDROID_PACKAGE = 'com.navis.app.navis' + SUFFIX
RELAY_PID = '/data/local/tmp/navis-relay.pid'
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
        subprocess.run(self.adb + ['logcat', '-G', '16M'], capture_output=True)
        subprocess.run(self.adb + ['logcat', '-c'], capture_output=True)
        self.shell('rm', '-f', ANDROID_HANDSHAKE, check=False)
        self.shell('am', 'start', '-n',
                   f'{ANDROID_PACKAGE}/com.navis.app.navis.MainActivity',
                   *(['--ez', 'enable-dart-profiling', 'true'] if os.environ.get('NAVIS_LIVE_SEEK_VM') == '1' else []))

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
        # exec keeps the shell's PID, recorded so stop() kills exactly this relay.
        self.relay = subprocess.Popen(
            self.adb + ['shell', f'echo $$ > {RELAY_PID}; exec nc -s 127.0.0.1 -p {port} -L nc 10.0.2.2 {port}'],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(1.0)

    def stop(self):
        relay = getattr(self, 'relay', None)
        if relay is not None:
            relay.terminate()
            self.shell(f'kill $(cat {RELAY_PID}); rm -f {RELAY_PID}', check=False)
        try:
            with (self.run / 'app.log').open('w') as log:
                subprocess.run(self.adb + ['logcat', '-d', '-s', 'flutter:*',
                                           'ExoPlayerImplInternal:*',
                                           'AudioPlayer:*', '*:E'],
                               stdout=log, stderr=subprocess.STDOUT, timeout=60)
        except Exception:
            pass
        self.shell('am', 'force-stop', ANDROID_PACKAGE, check=False)


def build_android():
    defines = {
        'NAVIS_UPDATE_CHANNEL': 'dev',
        'NAVIS_APP_ID_SUFFIX': SUFFIX,
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
            env={**os.environ, 'NAVIS_APP_ID_SUFFIX': SUFFIX,
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
        'NAVIS_APP_ID_SUFFIX': SUFFIX,
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
            env={**os.environ, 'NAVIS_APP_ID_SUFFIX': SUFFIX,
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
    'slow200': (200, 300),  # barely above the 128 kbit/s stream: little buffer ahead at 60 s
    'slow350': (350, 300),  # origin body still running 60 s into a song (stall/cut probes)
}
# Deadlines in seconds by throttle: seek landing, skip audible, stall limit.
DEADLINES = {
    'none': {'land': 15, 'advance': 12, 'stall': 6},
    'wan6000': {'land': 25, 'advance': 20, 'stall': 8},
    'slow1500': {'land': 45, 'advance': 35, 'stall': 12},
    'slow350': {'land': 45, 'advance': 35, 'stall': 30},
    'slow200': {'land': 45, 'advance': 35, 'stall': 40},
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
        player_position = state.get('playerPositionMs')
        if position is not None:
            position += offset
            # At a song switch the raw transport still holds the previous item's native position
            # (while the new item is not ready); the player's own song-time position is right then.
            if (player_position is not None and state.get('processingState') != 'ready'
                    and abs(position - player_position) > 10000):
                position = player_position
        else:
            position = player_position
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
            'pbuf': state.get('playerBufferedPositionMs'), 'cplay': state.get('cachedPlayablePositionMs'),
            'drawn': state.get('drawnBufferedPositionMs'),
            'aheadS': state.get('drawnAheadStartMs'), 'aheadE': state.get('drawnAheadEndMs'),
            'cpsrc': state.get('cachedPlayableSource'), 'probes': state.get('cachedExtentProbes'),
            'bar': bar.get('bufferedMs') if bar.get('songId') == state.get('songId') else None,
            'cacheB': cache.get('receivedBytes'), 'cacheTotal': cache.get('totalBytes'),
            'seekOutcome': seek.get('outcome'), 'seekPending': seek.get('pending'),
            'seekStage': seek.get('stage'), 'rec': (state.get('recovery') or {}).get('stage'),
            'navPending': (state.get('navigation') or {}).get('pending'),
            'src': state.get('sourceKind'), 'mat': state.get('materializedLength'),
            'deferred': state.get('deferredLength'), 'shuffle': state.get('shuffleEnabled'),
            'nseq': sequence[:3],
            'off': offset, 'pp': state.get('playerPositionMs'),
            'bridge': state.get('fastSeekBridge'), 'sidecar': state.get('sidecar'),
            'media': native.get('mediaKitCurrent'),
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


TRUTH = False  # --truth: i87 cases also compare the drawn cached time with the partial cache file (item 8)
TRUTH_PERIOD = 1.5
TRUTH_SETTLE_AT = (9.0, 30.0)  # seconds after the sampler starts: hold the origin bodies, then measure a static file


def part_files(app):
    """Partial cache files of the app, newest first: desktop sidecar `<name>.part.<pid>.<gen>`, Android `<name>.part`."""
    if isinstance(app, AndroidApp):
        out = app.shell('run-as', ANDROID_PACKAGE, 'sh', '-c', f"'ls -t {ANDROID_ROOT}/cache/audio/rolling 2>/dev/null'", check=False)
        return [n for n in out.split() if '.part' in n]
    folder = ROOT / 'cache' / 'audio' / 'rolling'
    if not folder.exists():
        return []
    files = [f for f in folder.iterdir() if '.part' in f.name]
    return [f.name for f in sorted(files, key=lambda f: f.stat().st_mtime, reverse=True)]


def packet_end_seconds(path: Path) -> float | None:
    """The last packet's pts + duration (not format=duration, which reads the FLAC STREAMINFO total)."""
    result = subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'packet=pts_time,duration_time', '-of', 'csv=p=0', str(path)],
                            capture_output=True, text=True)
    lines = [l for l in result.stdout.splitlines() if l.strip()]
    if not lines:
        return None
    try:
        pts, dur = (lines[-1].split(',') + ['0'])[:2]
        return float(pts) + (float(dur) if dur not in ('', 'N/A') else 0.0)
    except ValueError:
        return None


class TruthSampler(threading.Thread):
    """Every TRUTH_PERIOD s: copy the newest partial file, read the status, copy again; truth = last packet end of each copy.
    The file grows between the two copies, so truthBefore <= truthAt(status) <= truthAfter. Twice (TRUTH_SETTLE_AT) the proxy
    holds the media bodies first, so the file is static and the drawn time can be compared exactly."""

    def __init__(self, run: Run):
        super().__init__(daemon=True)
        self.run_ref, self.halt, self.rows = run, threading.Event(), []
        self.dir = run.app.run / f'truth-{run.case}-{run.quality}-{run.throttle}-{run.rep}'
        self.dir.mkdir(exist_ok=True)

    def measure(self, settled: bool):
        run, app = self.run_ref, self.run_ref.app
        names = part_files(app)
        if not names:
            self.rows.append({'t': run.now(), 'part': None, 'settled': settled})
            return
        name = names[0]
        c1, c2 = self.dir / 'c1.bin', self.dir / 'c2.bin'
        n1 = rolling_fetch(run, name, c1)
        t_status = run.now()
        status = app.api('/v1/playback/status', timeout=20)
        n2 = rolling_fetch(run, name, c2)
        row = {'t': t_status, 'part': name, 'settled': settled, 'bytes1': n1, 'bytes2': n2,
               'X': status.get('cachedPlayablePositionMs'), 'src': status.get('cachedPlayableSource'),
               'drawn': status.get('drawnBufferedPositionMs'), 'aheadS': status.get('drawnAheadStartMs'),
               'aheadE': status.get('drawnAheadEndMs'), 'pbuf': status.get('playerBufferedPositionMs'),
               'pos': status.get('positionMs'), 'off': status.get('positionOffsetMs'), 'dur': status.get('durationMs'),
               'songId': status.get('songId'), 'recv': (status.get('cacheProgress') or {}).get('receivedBytes')}
        if n1 and n2:
            row['truth1'] = packet_end_seconds(c1)
            row['truth2'] = packet_end_seconds(c2)
        self.rows.append(row)

    def run(self):
        run, start, settles = self.run_ref, time.monotonic(), list(TRUTH_SETTLE_AT)
        while not self.halt.is_set():
            try:
                if settles and time.monotonic() - start >= settles[0] and part_files(run.app):
                    settles.pop(0)
                    run.env.proxy.stall(4.5)
                    if self.halt.wait(3.0):
                        break
                    self.measure(True)
                    self.halt.wait(2.0)
                else:
                    self.measure(False)
                    self.halt.wait(TRUTH_PERIOD)
            except Exception as error:
                self.rows.append({'t': run.now(), 'error': f'{type(error).__name__}: {error}'})
                self.halt.wait(1.0)
        shutil.rmtree(self.dir, ignore_errors=True)


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


def oracle_progress_loss(run: Run, drop_ms=2000) -> list[dict]:
    """A drop of more than [drop_ms] in the position of the same song that nobody asked for (no
    seek/navigation in flight, within 1 s before it, or at the song's own end): lost progress,
    for example a stream that is reopened and restarts at its own start (T on an offset stream)."""
    out = []
    samples = run.samples
    for i in range(1, len(samples)):
        a, b = samples[i - 1], samples[i]
        if a['pos'] is None or b['pos'] is None or a['songId'] != b['songId'] or a['idx'] != b['idx']:
            continue
        if a['pos'] - b['pos'] <= drop_ms or a['proc'] != 'ready':  # a loading item still reports the previous song's position
            continue
        if is_position_blip(samples, i):
            continue
        asked = ('seek', 'prev', 'jump', 'next')  # a 'start' has no end time: its window would hide a rewind seconds in
        if _requested_at(run, b['t'], asked) or _requested_at(run, b['t'] - 1.0, asked) or song_end_near(samples, i):
            continue
        out.append(violation('progressLoss', b['t'], f"{b['songId']} position {a['pos']}->{b['pos']} (offset {a.get('off')}->"
                             f"{b.get('off')}, proc {a['proc']}->{b['proc']}) with no seek or navigation in flight", run))
    return out


def is_position_blip(samples, i) -> bool:
    """A native clock reset returning within 3 samples and 500 ms, or its return to the same timeline."""
    a, b = samples[i - 1], samples[i]
    if (a['pos'] is None or b['pos'] is None or a['songId'] != b['songId'] or a['idx'] != b['idx']
            or (a.get('off') or 0) != (b.get('off') or 0)):
        return False
    if a['pos'] - b['pos'] > 2000 and 0 <= b['pos'] - (b.get('off') or 0) < 3000:
        return any(n['pos'] is not None and abs(n['pos'] - a['pos']) < 500
                   and n['songId'] == b['songId'] and n['idx'] == b['idx']
                   and (n.get('off') or 0) == (b.get('off') or 0) and n['t'] - a['t'] <= 0.5
                   for n in samples[i + 1:i + 4])
    if b['pos'] - a['pos'] > 2000 and 0 <= a['pos'] - (a.get('off') or 0) < 3000:
        return any(n['pos'] is not None and abs(n['pos'] - b['pos']) < 500
                   and n['songId'] == b['songId'] and n['idx'] == b['idx']
                   and (n.get('off') or 0) == (b.get('off') or 0) and b['t'] - n['t'] <= 0.5
                   for n in samples[max(0, i - 4):i - 1])
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
        elif is_position_blip(samples, i):
            continue  # one status read caught the player between items: the position is back at the next sample
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


def oracle_i87(run: Run, song: dict, quality: str, media: list, full_expected=False) -> list[dict]:
    """#87 measurements (no hard verdicts). The drawn line is seekBar.bufferedMs (the handler's buffer state, on both builds).
    Two references for how much audio the cache holds, from the received bytes (cacheProgress.receivedBytes):
      A (nominal, what the app can know; the 2026-10-19 baseline method): original = bytes / total bytes * duration,
        transcode = bytes * 8 / bitrate;
      B (true): bytes / (the finished response's size / duration); a VBR transcode differs from A.
    lag = reference - drawn, counted only when it lasted 3 s; overshoot = drawn - max(reference, player's raw buffer).
    Keeps a 1 s series [t, drawn, A, B, player buffer, cachedPlayable, position, source]."""
    fmt, kbps = QUALITIES[quality]
    dur_s_song = float(song.get('duration') or 0)
    finished = [r['bytes'] for r in media if r['id'] == song['id'] and r.get('status') == 200 and r.get('end') == 'complete']
    true_bps = max(finished) / dur_s_song if finished and dur_s_song else None
    out, series, last_sec = [], [], -1
    first_audio = next((s['t'] for s in run.samples if s['playing'] and s['proc'] == 'ready' and (s['pos'] or 0) > 0), None)
    worst = {'lagA': 0.0, 'lagB': 0.0, 'lagCp': 0.0, 'overA': 0.0, 'overB': 0.0}
    wins = {k: [] for k in ('lagA', 'lagB', 'lagCp')}

    def sustained(key, t, lag):
        window = wins[key]
        window.append((t, lag))
        while window and t - window[0][0] > 3.0:
            window.pop(0)
        worst[key] = max(worst[key], min(x[1] for x in window) if t - window[0][0] >= 2.9 else 0.0)

    for s in run.samples:
        if s['bar'] is None or not s['dur'] or first_audio is None or s['t'] < first_audio + 1:
            continue
        dur_s, bar_s = s['dur'] / 1000, s['bar'] / 1000
        raw = s['cacheB']
        ref_a = ref_b = None
        if raw is not None:
            if fmt:
                ref_a = raw * 8 / (kbps * 1000)
            elif s['cacheTotal']:
                ref_a = raw / s['cacheTotal'] * dur_s
            elif song.get('size'):
                ref_a = raw / song['size'] * dur_s
            if true_bps:
                ref_b = raw / true_bps
            ref_a = None if ref_a is None else min(dur_s, ref_a)
            ref_b = None if ref_b is None else min(dur_s, ref_b)
        pbuf_s = None if s['pbuf'] is None else s['pbuf'] / 1000
        cplay_s = None if s['cplay'] is None else s['cplay'] / 1000
        if ref_a is not None:
            sustained('lagA', s['t'], ref_a - bar_s)
            worst['overA'] = max(worst['overA'], bar_s - max(ref_a, pbuf_s or 0.0))
        if ref_b is not None:
            sustained('lagB', s['t'], ref_b - bar_s)
            worst['overB'] = max(worst['overB'], bar_s - max(ref_b, pbuf_s or 0.0))
        if cplay_s is not None:
            sustained('lagCp', s['t'], cplay_s - bar_s)
        if int(s['t']) != last_sec:
            last_sec = int(s['t'])
            rnd = lambda v: None if v is None else round(v, 1)
            series.append([round(s['t'], 1), rnd(bar_s), rnd(ref_a), rnd(ref_b), rnd(pbuf_s), rnd(cplay_s),
                           None if s['pos'] is None else round(s['pos'] / 1000, 1), s['src']])
    final = next((s for s in reversed(run.samples) if s['bar'] is not None and s['dur']), None)
    run.metrics['i87'] = {**{k: round(v, 1) for k, v in worst.items()}, 'trueBps': true_bps and round(true_bps),
                          'finalBarS': final and round(final['bar'] / 1000, 1), 'durS': final and round(final['dur'] / 1000, 1),
                          'series': series}
    if full_expected and final and final['bar'] < final['dur'] - 1000:
        out.append(violation('bufferNotFull', final['t'], f"line {final['bar'] / 1000:.0f}s of {final['dur'] / 1000:.0f}s "
                             f"(src {final['src']}) on a song that is fully local", run, passive=True))
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
        self.server = type('Catalog', (), {'call': lambda _, method, **params: {'song': library.songs[params['id']]}})()  # getSong only

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
        # A normal album starts with a long song: the 3-8 s first tracks are too short for cases that seek 6-16 s from the end.
        albums = [a for a, d in self.library.albums.items() if self._is_short(d['artistId']) == short
                  and (short or self.library.songs[self.library.album_songs[a][0]]['duration'] >= 100)
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
                                                       'elapsedMs', 'outcome', 'afterSourceKind', 'recoveryAttempts', 'unsettled')} for e in events]
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


def wait_for_repeat_start(run: Run, song_id: str, after: float, timeout: float, max_position: float):
    """Confirms a repeat start without mistaking a brief native clock reset for a loop."""
    deadline = time.monotonic() + timeout
    while (remaining := deadline - time.monotonic()) > 0:
        sample = run.until(lambda s: s['t'] > after and s['songId'] == song_id and s['pos'] is not None
                           and s['pos'] < max_position and s['proc'] == 'ready', remaining)
        if sample is None:
            return None
        run.observe(0.5)
        index = run.samples.index(sample)
        if index == 0 or not is_position_blip(run.samples, index):
            return sample
        after = sample['t']
    return None


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
    fade_ms = CROSSFADE_S * 1000  # a cross-faded loop hands over when the new copy is already fade_ms in
    wrapped = wait_for_repeat_start(run, song['id'], t_seek,
                                    duration_ms * 0.2 / 1000 + 60 + run.deadlines['advance'], 4000 + fade_ms)
    run.metrics['loopWrappedAt'] = wrapped and wrapped['t']
    if wrapped is None:
        run.violations.append(violation('repeatOneNoLoop', run.now(), 'position never wrapped to the start', run))
        raise CaseAbort('no loop')
    run.observe(8.0)
    wrapped2 = wait_for_repeat_start(run, song['id'], wrapped['t'] + 30,
                                     duration_ms / 1000 + 2 * run.deadlines['advance'], 4000)
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
        # f1b2c1df: the native restart briefly re-opens the offset URL and the reload from 0 cancels it within
        # milliseconds (a tiny aborted body): record it, do not count it as the loop re-requesting T.
        run.metrics['transientOffsetReopenAtLoop'] = [r for r in after_loop if r.get('end') == 'clientAborted' and (r.get('bytes') or 0) <= 65536 and r['w'] <= loop_w + 1.5]
        after_loop = [r for r in after_loop if r not in run.metrics['transientOffsetReopenAtLoop']]
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
        run.observe(85.0)  # the fatal error only surfaces when playback reaches the end of what was buffered
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
                for e in run.trace if e['kind'] != 'bufferState' and device_ms - 8000 <= e['atMs'] <= device_ms + 86000][:80]
    return case


def case_base_repeat_one(run: Run, env):
    """Baseline A: repeat-one on a plain transcode, no seek at all; two loops. progressLoss must stay quiet."""
    run.metrics['repeatOne'] = True
    song = min(env.backend.fresh_songs(6), key=lambda x: x['duration'])
    duration_ms = int(song['duration']) * 1000
    run.app.api('/v1/playback/repeat', {'mode': 'one'})
    start_single(run, song)
    first = run.until(lambda s: s['songId'] == song['id'] and (s['pos'] or 0) > duration_ms - 6000, duration_ms / 1000 + 60)
    for n in (1, 2):
        wrapped = wait_for_repeat_start(run, song['id'], (run.metrics.get(f'wrap{n - 1}') or 0) + 20,
                                        duration_ms / 1000 + 60, 4000)
        run.metrics[f'wrap{n}'] = wrapped and wrapped['t']
        if wrapped is None:
            run.violations.append(violation('baselineNoLoop', run.now(), f'loop {n} never happened', run))
            break
    run.observe(6.0)


def hold_case(fraction: float, repeat: str, album: bool, hold_s=35.0):
    """Baselines B and C: an offset seek, then play on for [hold_s] with repeat off/all; progressLoss judges it."""
    def case(run: Run, env):
        offset_case_prologue(run)
        if album:
            ids = env.backend.fresh_album()
            run.songs = [{'id': i} for i in ids]
            duration_s, _ = song_info(run, ids[0])
            run.app.api('/v1/playback/repeat', {'mode': repeat})
            rec = start_queue(run, ids)
            await_audio(run, rec, ids[0])
        else:
            song = env.backend.fresh_songs(1)[0]
            duration_s = float(song['duration'])
            if repeat != 'none':
                run.app.api('/v1/playback/repeat', {'mode': repeat})
            start_single(run, song)
        run.observe(5.0)
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            seek = issue_seek(run, pool, int(duration_s * 1000 * fraction))
            landed(run, seek)
            finish_futures(run)
        run.observe(hold_s)
        run.checks.append(lambda: oracle_seek(run, seek) + oracle_offset(run, [seek], run.quality != 'original'))
        run.latency_from = [seek]
    return case


def paused_spans(run: Run, t0: float, t1: float, minimum=1.0) -> list:
    """Spans in [t0, t1] where the player was ready but not playing although playback was wanted."""
    spans, start = [], None
    for x in run.samples:
        if not (t0 <= x['t'] <= t1):
            continue
        idle = x['proc'] == 'ready' and not x['playing'] and wanted_at(run, x['t'])
        if idle and start is None:
            start = x['t']
        elif not idle and start is not None:
            if x['t'] - start >= minimum:
                spans.append((round(start, 1), round(x['t'], 1)))
            start = None
    if start is not None and t1 - start >= minimum:
        spans.append((round(start, 1), round(t1, 1)))
    return spans


def case_natural_play3(run: Run, env, songs=3):
    """Round 11 (G): plain album playback, no injection and no user command: [songs] songs play to their natural end and
    hand over in order. No recovery decision (quiet stop, failover, skip) may appear, and no song may end early."""
    ids = env.backend.fresh_album()
    run.songs = [{'id': i} for i in ids]
    rec = start_queue(run, ids)
    await_audio(run, rec, ids[0])
    hand = []
    for n in range(songs):
        cur = run.last()
        dur = (cur['dur'] or 240000) / 1000
        moved = run.until(lambda s, n=n: s['songId'] == ids[n + 1], dur + 90)
        prev = [x for x in run.samples if x['songId'] == ids[n] and x['pos'] is not None][-1:]
        if moved is None:
            run.violations.append(violation('naturalNoAdvance', run.now(), f'song {n + 1} never followed song {n}', run))
            raise CaseAbort('no advance')
        hand.append({'from': n, 'dur': cur['dur'], 'lastPos': prev[0]['pos'] if prev else None, 'handoverAtS': moved['t']})
        if prev and cur['dur'] and prev[0]['pos'] < cur['dur'] - 5000:
            run.violations.append(violation('endedEarly', moved['t'], f"song {n} ended at {prev[0]['pos']} of {cur['dur']}", run))
        ok = run.until(lambda s, n=n: s['songId'] == ids[n + 1] and s['playing'] and s['proc'] == 'ready' and (s['pos'] or 0) > 1000, 20)
        if ok is None:
            run.violations.append(violation('pausedAtSongEnd', moved['t'], f'song {n + 1} not playing 20 s after the handover', run))
    run.metrics['handovers'] = hand
    hits = [e for e in run.trace if e['kind'] == 'recovery']
    run.metrics['recoveryEntries'] = [{k: e.get(k) for k in ('decision', 'reason', 'rel')} for e in hits][:8]
    if hits:
        run.violations.append(violation('unexpectedRecovery', hits[0]['rel'], f'{len(hits)} recovery entries on a fault-free run: {run.metrics["recoveryEntries"]}', run))
    run.checks.append(lambda: oracle_sequence(run, ids, minimum=songs + 1))


def dart_gets(log: list, song_id: str) -> list:
    """The app's own full-song origin GETs: Dart's user agent (the desktop sidecar) or the player's `Navis/<ver>` one
    (Android: LockCachingAudioSource._fetch sends a plain GET, no Range). Android's independent range fetches carry a
    Range and are seeks, so only an absent Range or `bytes=0-` counts there. `Navis Desktop` is mpv and never counts."""
    return [r for r in log if r['id'] == song_id and r['endpoint'] in ('stream', 'download') and not r.get('timeOffset')
            and (r['ua'].startswith('Dart') or (r['ua'].startswith('Navis/') and r.get('range') in (None, '', 'bytes=0-')))]


def seek_was_local(log: list, song_id: str, seek_w: float, *, cache_complete: bool) -> bool:
    """Network-free seek with a complete cache file; this does not prove a disk read over an in-buffer seek."""
    done = any(r.get('end') == 'complete' and (r.get('endW') or 1e12) <= seek_w for r in dart_gets(log, song_id))
    return cache_complete and done and not any(r['id'] == song_id and r['endpoint'] in ('stream', 'download') and r['w'] >= seek_w for r in log)


def next_song_readiness(log: list, song_id: str, handover_w: float) -> tuple:
    """(lead, bytes) of the full-song GETs the app's own downloader (the desktop sidecar, the Android lock-cache
    origin fetch; see dart_gets) made for [song_id] before it took over at wall time [handover_w]. lead: seconds between the first
    GET and the handover (negative: it started after, None: it never did). bytes: received by the handover (a GET still
    running then is prorated over its duration)."""
    gets = dart_gets(log, song_id)
    if not gets:
        return None, 0
    got = 0
    for r in gets:
        # In-flight counters are observed now, possibly seconds after handover.
        end = r.get('endW') or time.time()
        if r['w'] >= handover_w:
            continue
        share = 1.0 if end <= handover_w else (handover_w - r['w']) / max(end - r['w'], 0.001)
        got += int((r.get('bytes') or 0) * share)
    return round(handover_w - min(r['w'] for r in gets), 2), got


def chain_warm_wait_s(sample: dict) -> float:
    # Leave 10 s for the near-end seek even on short tracks.
    return min(25, max(0, ((sample.get('dur') or 0) - (sample.get('pos') or 0)) / 1000 - 10))


def next_cache_complete(run: Run, song_id: str) -> bool:
    gets = [r for r in dart_gets(run.env.proxy.log[run.proxy_mark:], song_id) if r.get('end') == 'complete']
    if not gets:
        return False
    song = run.env.backend.server.call('getSong', id=song_id)['song']
    fmt, kbps = QUALITIES[run.quality]
    suffix = song.get('suffix') or 'flac'
    digest = hashlib.sha1(f'{song_id}::{kbps}::{fmt}::{suffix}'.encode()).hexdigest()
    name = f'{digest}.{fmt or suffix}'
    size = rolling_fetch(run, name, run.app.run / 'next-cache-probe.bin')
    return size is not None and size > 0 and any(size == r['bytes'] for r in gets)


def case_chain_end(run: Run, env):
    """Repeat off, long queue: four songs each seeked to 6 s before their end; every boundary must hand over
    to the next song without a pause (setPauseAtEndOfMediaItems must not leak into normal playback)."""
    ids = [song['id'] for song in env.backend.fresh_songs(5, min_s=100)]
    run.songs = [{'id': i} for i in ids]
    if getattr(run, 'chain_repeat', 'none') != 'none':
        run.app.api('/v1/playback/repeat', {'mode': run.chain_repeat})
    rec = start_queue(run, ids)
    await_audio(run, rec, ids[0])
    gaps, leads, fetched, local = [], [], [], []
    for n in range(4):
        cur = run.until(lambda s: s['songId'] == ids[n] and s['proc'] == 'ready' and s['playing'] and (s['pos'] or 0) > 500, 60) \
            or run.last()
        run.observe(3.0)
        # Wait for the complete next file, not merely its first GET.
        warm_deadline = time.monotonic() + chain_warm_wait_s(run.last())
        while time.monotonic() < warm_deadline and not next_cache_complete(run, ids[n + 1]):
            run.observe(0.5)
        dur = run.last()['dur'] or 0
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            seek = issue_seek(run, pool, max(0, dur - getattr(run, 'chain_lead', 6000)))
            landed(run, seek)
            finish_futures(run)
        landed_t = run.now()
        moved = run.until(lambda s, n=n: s['songId'] == ids[n + 1], getattr(run, 'chain_lead', 6000) / 1000 + run.deadlines['advance'] + 20)
        if moved is None:
            run.violations.append(violation('chainNoHandover', run.now(), f'song {n + 1} never handed over', run))
            raise CaseAbort('no handover')
        ok = run.until(lambda s, n=n, t=moved['t']: s['t'] >= t and s['songId'] == ids[n + 1] and s['playing']
                       and s['proc'] == 'ready' and (s['pos'] or 0) > 1000, 12)
        gaps.append(round(ok['t'] - moved['t'], 2) if ok else None)
        if ok is None:
            run.violations.append(violation('pausedAtSongEnd', moved['t'], f'song {n + 2} not playing 12 s after the handover', run))
            raise CaseAbort('paused')
        spans = paused_spans(run, landed_t, ok['t'] + 1)
        if spans:
            run.violations.append(violation('pausedAtSongEnd', spans[0][0], f'ready but not playing {spans}', run))
        handover_w = time.time() - (run.now() - moved['t'])
        lead, got = next_song_readiness(run.env.proxy.log[run.proxy_mark:], ids[n + 1], handover_w)
        leads.append(lead)
        fetched.append(got)
        # Classify after settlement: complete file before the seek, no media request after it.
        cache_complete = next_cache_complete(run, ids[n + 1])
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            seek = issue_seek(run, pool, 2000)
            landed(run, seek)
            finish_futures(run)
        run.observe(1.0)
        local.append(seek_was_local(run.env.proxy.log[run.proxy_mark:], ids[n + 1], seek['w'], cache_complete=cache_complete))
    run.metrics['handoverGapsS'] = gaps
    run.metrics.update(nextRequestLeadS=leads, nextBytesAtHandover=fetched, nextSeekLocal=local)
    run.checks.append(lambda: oracle_sequence(run, ids, minimum=4))

    def no_false_recovery():
        hits = [e for e in run.trace if e['kind'] == 'recovery' or (e['kind'] == 'playerState' and e.get('errorCode'))]
        run.metrics['recoveryEntries'] = [{k: e.get(k) for k in ('kind', 'decision', 'reason', 'errorCode')} for e in hits][:6]
        return [violation('falseRecovery', hits[0]['rel'], f"{len(hits)} recovery/error entries on a fault-free run", run)] if hits else []
    run.checks.append(no_false_recovery)


def case_chain_end_all(run: Run, env):
    run.chain_repeat = 'all'
    case_chain_end(run, env)


def case_repeat_switch_off(run: Run, env):
    """Repeat-one, then repeat off shortly before the song's end: it must advance to the next song, playing."""
    ids = env.backend.fresh_album()
    run.songs = [{'id': i} for i in ids]
    run.app.api('/v1/playback/repeat', {'mode': 'one'})
    rec = start_queue(run, ids)
    await_audio(run, rec, ids[0])
    run.observe(4.0)
    dur = run.last()['dur'] or 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        seek = issue_seek(run, pool, max(0, dur - 16000))
        landed(run, seek)
        finish_futures(run)
    run.until(lambda s: s['songId'] == ids[0] and (s['pos'] or 0) >= dur - 10000, 30)
    run.act('repeatOff')
    run.app.api('/v1/playback/repeat', {'mode': 'none'})
    t_off = run.now()
    moved = run.until(lambda s: s['songId'] == ids[1], 25)
    if moved is None:
        run.violations.append(violation('switchOffNoAdvance', run.now(), f'still on song 1: {run.last()["pos"]}/{dur}', run))
        raise CaseAbort('no advance')
    ok = run.until(lambda s: s['t'] >= moved['t'] and s['songId'] == ids[1] and s['playing'] and s['proc'] == 'ready'
                   and (s['pos'] or 0) > 1000, 12)
    run.metrics['switchOff'] = {'offAtS': t_off, 'handoverAtS': moved['t'], 'playingAfterS': ok and round(ok['t'] - moved['t'], 2)}
    if ok is None:
        run.violations.append(violation('pausedAtSongEnd', moved['t'], 'song 2 not playing 12 s after the handover', run))
    else:
        run.observe(5.0)
        spans = paused_spans(run, t_off, run.now())
        if spans:
            run.violations.append(violation('pausedAtSongEnd', spans[0][0], f'ready but not playing {spans}', run))
    run.checks.append(lambda: oracle_sequence(run, ids, minimum=2))


def case_repeat_one_fill(run: Run, env):
    """Repeat-one with the background queue fill still running at the song end: an artist shuffle
    (a large queue), song 1 seeked to its last 8 s straight away; it must restart exactly once, on the
    same index, and never advance."""
    run.metrics['repeatOne'] = True
    artist, ids = env.backend.fresh_artist()
    run.songs = [{'id': i} for i in ids]
    run.shuffled = True
    run.app.api('/v1/playback/repeat', {'mode': 'one'})
    rec = run.act('start', artist=artist, shuffle=True)
    run.app.api('/v1/artists/playback', {'command': 'prepare', 'artistId': artist, 'action': 'shuffle'}, timeout=60)
    first = await_audio(run, rec)
    dur = first['dur'] or run.last()['dur'] or 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        seek = issue_seek(run, pool, max(0, dur - 8000))
        landed(run, seek)
        finish_futures(run)
    run.observe(25.0)

    def check():
        out = []
        same = [x for x in run.samples if x['t'] >= seek['t'] and x['pos'] is not None]
        # A local-file reload briefly publishes a loading cursor at the old offset.
        ready = [x for x in same if x['proc'] == 'ready']
        wraps = [(a, b) for i, (a, b) in enumerate(zip(ready, ready[1:]), 1)
                 if a['songId'] == b['songId'] == first['songId'] and a['idx'] == b['idx']
                 and a['pos'] > dur - 4000 and b['pos'] < 3000 and not is_position_blip(ready, i)]
        run.metrics['wraps'] = [{'t': round(b['t'], 1), 'from': a['pos'], 'to': b['pos'], 'mat': b['mat'], 'deferred': b['deferred'],
                                 'qlen': b['qlen']} for a, b in wraps]
        if len(wraps) != 1:
            out.append(violation('repeatOneRestartCount', seek['t'], f"{len(wraps)} restarts of song 1 in 25 s (expected 1)", run))
        moved = next((x for x in same if x['songId'] != first['songId']), None)
        if moved:
            out.append(violation('repeatOneAdvanced', moved['t'], f"advanced to {moved['songId']} under repeat-one", run))
        return out
    run.checks.append(check)


def cut_at_case(fraction: float, cuts: int, gap_s=10.0, pace_kbps=176):
    """#86 item 2 (proxy abort on origin cut): album, repeat off; after song 1 starts the origin is paced
    near real time, and when song 1 reaches [fraction] of its length the in-flight origin body is cut
    ([cuts] times, [gap_s] apart). Records whether it resumes in place, restarts, or ends early, then
    lets the song play to its natural end. The progress-loss oracle judges the rest."""
    def case(run: Run, env):
        ids = env.backend.fresh_album()
        run.songs = [{'id': i} for i in ids]
        env.proxy.pace_song(ids[0], pace_kbps)  # song 1's body arrives at ~1.4x real time, so it is in flight at the cut
        rec = start_queue(run, ids)
        first = await_audio(run, rec, ids[0])
        dur = first['dur'] or run.last()['dur'] or 0
        restore = THROTTLES[run.throttle]
        run.metrics['cutPlan'] = {'fraction': fraction, 'cuts': cuts, 'durMs': dur, 'paceKbps': pace_kbps}
        at = run.until(lambda s: s['songId'] == ids[0] and (s['pos'] or 0) >= dur * fraction, dur / 1000 + 90)
        if at is None:
            env.proxy.pace_song(None, 0)
            raise CaseAbort('song 1 never reached the cut point')
        device_ms = int(run.app.shell('date', '+%s%3N').strip() or 0) if isinstance(run.app, AndroidApp) else None
        events = []
        for n in range(cuts):
            if n:  # the first cut only surfaces when the buffer runs out: cut again gap_s after the recovery resumed
                run.until(lambda s: s['off'] and s['proc'] == 'ready' and s['playing'] and s['songId'] == ids[0], 90)
                time.sleep(gap_s)
            cur = run.last()
            env.proxy.cut_active('fin', window=3.0)
            run.act('originCut', n=n + 1)
            events.append({'n': n + 1, 't': run.now(), 'pos': cur['pos'], 'buf': cur['buf']})
            time.sleep(3.2)
        run.metrics.update(cutEvents=events, cutDeviceMs=device_ms)
        t_first = events[0]['t']
        # recovery window: let it settle, then restore the link and play the song out
        run.observe(25.0)
        env.proxy.pace_song(None, 0)
        end_wait = max(30.0, (dur - (run.last()['pos'] or 0)) / 1000 + 60)
        moved = run.until(lambda s: s['songId'] != ids[0], end_wait)
        after = [s for s in run.samples if s['t'] >= t_first and s['songId'] == ids[0] and s['pos'] is not None]
        resumed = next((s for s in after if s['t'] > events[0]['t'] + 0.5 and s['proc'] == 'ready' and s['playing']
                        and s['pos'] >= events[0]['pos'] + 1500), None)
        top = max((s['pos'] for s in after), default=0)
        early = moved is not None and top < dur - 6000
        restarted = any(b['pos'] < a['pos'] - 5000 and b['pos'] < 6000 for a, b in zip(after, after[1:]))
        run.metrics['cutVerdict'] = {'resumedAfterS': resumed and round(resumed['t'] - t_first, 1), 'topPosMs': top, 'durMs': dur,
                                     'endedEarlyAndAdvanced': early, 'restartedNear0': restarted, 'advancedNaturally': moved is not None and not early}
        if device_ms:
            keys = ('processingState', 'playing', 'positionMs', 'stage', 'reason', 'decision', 'errorCode', 'index', 'timeOffset', 'initialPositionMs', 'outcome', 'path')
            run.metrics['cutTrace'] = [f"{(e['atMs'] - device_ms) / 1000:+.1f}s {e['kind']} " + ' '.join(f'{k}={e[k]}' for k in keys if e.get(k) is not None)
                                       for e in run.trace if e['kind'] in ('recovery', 'seekEvent', 'navigate', 'setAudioSources', 'sourceResolved', 'playerState')
                                       and (e['kind'] != 'playerState' or e.get('errorCode')) and device_ms - 2000 <= e['atMs'] <= device_ms + 60000
                                       and (e['kind'] != 'sourceResolved' or e.get('timeOffset'))][:40]
        if early:
            run.violations.append(violation('cutEndedEarly', t_first, f"song 1 advanced at pos {top}/{dur}", run))
        if resumed is None:
            run.violations.append(violation('cutNoResume', t_first, f"no playback past {events[0]['pos']}+1.5 s afterwards", run))
        run.checks.append(lambda: oracle_sequence(run, ids, minimum=2) if moved is not None else [])
    return case


def cold_seek_target(song_id: str, wanted_ms=60000) -> int:
    """The cold-seek target clamped to the song: at least 10 s before its end (a 51 s track made a 60 s seek run off the end)."""
    try:
        with sqlite3.connect(f'file:{ROOT / "navis.sqlite"}?mode=ro', uri=True) as db:
            row = db.execute('SELECT duration FROM songs WHERE id = ?', (song_id,)).fetchone()
    except Exception:
        row = None
    if not row or not row[0]:
        return wanted_ms
    return min(wanted_ms, max(5000, int(row[0]) * 1000 - 10000))


def cold_command_case(kind: str, kbps=1000):
    """Item 3 round 2: while a slow cold start is still loading, a user command (next or seek) issued ~5 s in
    must be acted on within a few seconds, not after the extended load finishes."""
    def case(run: Run, env):
        ids = env.backend.fresh_album()
        run.songs = [{'id': i} for i in ids]
        restore = THROTTLES[run.throttle]
        env.proxy.set_profile(kbps, 300)
        try:
            starter = concurrent.futures.ThreadPoolExecutor(max_workers=1)  # the start call blocks while the load runs
            run.queue_ids = list(ids)
            rec = run.act('start', songIds=len(ids), first=ids[0], shuffle=False)
            run.futures.append(starter.submit(lambda: run.app.api('/v1/playback/queue', {'songIds': ids}, timeout=180)))
            time.sleep(5.0)
            before = run.last()
            run.metrics['stateAt5s'] = {k: before[k] for k in ('songId', 'proc', 'playing', 'pos', 'loading', 'buf')} if before else None
            t_cmd = run.now()
            with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
                if kind == 'next':
                    cmd = run.act('next', idx0=0, pos0=before and before['pos'], song0=ids[0], expect=1)
                    pool.submit(lambda: run.app.api('/v1/playback/next', {}, timeout=120))
                    hit = run.until(lambda s: s['songId'] == ids[1], 60)
                else:
                    target = cold_seek_target(ids[0])
                    run.metrics['coldSeekTarget'] = target
                    seek = issue_seek(run, pool, target)
                    seek['song'] = ids[0]
                    hit = run.until(lambda s: s['songId'] == ids[0] and abs((s['pos'] or 0) - target) <= 1500 and s['proc'] == 'ready', 60)
                run.metrics['commandActedAfterS'] = None if hit is None else round(hit['t'] - t_cmd, 1)
                run.metrics['commandKind'] = kind
                finish_futures(run, 30)
        finally:
            env.proxy.set_profile(*restore)
        if run.metrics['commandActedAfterS'] is None or run.metrics['commandActedAfterS'] > 10:
            run.violations.append(violation('commandNotPrompt', t_cmd, f"{kind} acted on after {run.metrics['commandActedAfterS']} s "
                                            f"(state at 5 s: {run.metrics['stateAt5s']})", run))
        run.observe(4.0)
    return case
def case_cold_seek_stall(run: Run, env, kbps=1000, stall_s=60.0, at_start=False):
    """Round 8 injection: a same-song seek 5 s into a slow cold start; once the cold load is up, every media body is held
    (connection kept open, ProxyServer.stall) for [stall_s], so the seek cannot settle (~25 s deadline) and the reload
    (and its retry) times out at 12 s. Records the state 20 s after the seek and the final state, and flags an idle player."""
    ids = env.backend.fresh_album()
    run.songs = [{'id': i} for i in ids]
    tgt = cold_seek_target(ids[0])
    run.metrics['coldSeekTarget'] = tgt
    run.queue_ids = list(ids)
    restore = THROTTLES[run.throttle]
    env.proxy.set_profile(kbps, 300)
    keys = ('songId', 'proc', 'playing', 'pos', 'loading', 'buf', 'idx')
    pick = lambda s: {k: s[k] for k in keys} if s else None
    try:
        starter = concurrent.futures.ThreadPoolExecutor(max_workers=1)
        if at_start:  # hold the cold load itself: the media bodies of the first load stall for stall_s
            env.proxy.stall(stall_s)
            run.act('stall', seconds=stall_s, atStart=True)
        t_start = run.now()
        rec = run.act('start', songIds=len(ids), first=ids[0], shuffle=False)
        run.futures.append(starter.submit(lambda: run.app.api('/v1/playback/queue', {'songIds': ids}, timeout=180)))
        time.sleep(5.0)
        run.metrics['stateAt5s'] = pick(run.last())
        t_cmd = run.now()
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            seek = issue_seek(run, pool, tgt)
            seek['song'] = ids[0]
            loaded = run.until(lambda s: s['songId'] == ids[0] and s['proc'] in ('ready', 'buffering') and not s['loading'], 90)
            run.metrics['coldLoadedAfterS'] = None if loaded is None else round(loaded['t'] - t_cmd, 1)
            if not at_start:
                env.proxy.stall(stall_s)
                run.act('stall', seconds=stall_s)
            t_stall = t_start if at_start else run.now()
            time.sleep(max(0.0, t_cmd + 20 - run.now()))
            run.metrics['stateAt20sAfterSeek'] = pick(run.last())
            time.sleep(max(0.0, t_stall + stall_s + 40 - run.now(), t_cmd + 80 - run.now()))
            finish_futures(run, 30)
    finally:
        env.proxy.stall_until = 0.0
        env.proxy.set_profile(*restore)
    final = run.last()
    run.metrics['finalState'] = pick(final)
    run.metrics['seekOutcomeIssued'] = seek.get('outcome')
    last = None
    timeline = []
    for s in run.samples:
        if s['t'] >= t_cmd:
            cur = (s['songId'], s['proc'], bool(s['playing']))
            if cur != last:
                timeline.append((round(s['t'] - t_cmd, 1), s['songId'], s['proc'], bool(s['playing']), s['pos']))
                last = cur
    run.metrics['timeline'] = timeline[:60]
    near = next((x for x in run.samples if x['t'] >= t_cmd and x['playing'] and x['proc'] in ('ready', 'buffering')
                 and x['songId'] == ids[0] and (x['pos'] or 0) >= tgt - 5000), None)
    run.metrics['playingNearTargetAtS'] = None if near is None else round(near['t'] - t_cmd, 1)  # since the seek command
    run.metrics['holdEndsAtS'] = round(t_start + stall_s - t_cmd, 1) if at_start else None
    if final is None or final['proc'] in ('idle', None) or final['songId'] is None:
        run.violations.append(violation('leftIdle', run.now(), f'final state {pick(final)}', run))
    elif not final['playing']:
        run.violations.append(violation('notPlayingAtEnd', run.now(), f'final state {pick(final)}', run))


def case_dead_source_hold(run: Run, env, kbps=1000, window_s=90.0):
    """Round 9 (E): a one-song queue whose media is held for the whole observation window. The seek cannot ever load;
    expected: a quiet stop (no notice, no load-failure event). Then the hold is lifted and Play must restart it."""
    ids = env.backend.fresh_album()  # the start API needs 2+ songs; the queue stays at 1 while the first load is held
    run.songs = [{'id': i} for i in ids]
    run.queue_ids = list(ids)
    restore = THROTTLES[run.throttle]
    env.proxy.set_profile(kbps, 300)
    keys = ('songId', 'proc', 'playing', 'pos', 'loading', 'buf', 'idx')
    pick = lambda s: {k: s[k] for k in keys} if s else None

    def failures():
        try:
            return run.app.api('/v1/diagnostics/report', None, timeout=40).get('playback', {}).get('loadFailures')
        except Exception as error:
            return f'{type(error).__name__}'

    def shot(label):
        try:
            return run.app.api('/v1/presentation/screenshot', {'label': label}, timeout=30).get('artifact')
        except Exception as error:
            return f'{type(error).__name__}: {error}'
    try:
        try:
            run.app.api('/v1/diagnostics/metrics/reset', {})
        except Exception:
            pass
        env.proxy.stall(window_s + 600)  # held until the case lifts it
        run.act('stall', seconds=window_s + 600, atStart=True)
        starter = concurrent.futures.ThreadPoolExecutor(max_workers=1)
        run.act('start', songIds=len(ids), first=ids[0], shuffle=False)
        start_future = starter.submit(lambda: run.app.api('/v1/playback/queue', {'songIds': ids}, timeout=180))
        run.futures.append(start_future)
        time.sleep(5.0)
        t_cmd = run.now()
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            seek = issue_seek(run, pool, cold_seek_target(ids[0]))
            seek['song'] = ids[0]
            shots = {}
            for at in (15, 40):
                time.sleep(max(0.0, t_cmd + at - run.now()))
                shots[f'+{at}s'] = {'state': pick(run.last()), 'artifact': shot(f'dead-{at}')}
            time.sleep(max(0.0, t_cmd + window_s - run.now()))
            run.metrics['heldWindow'] = {'state': pick(run.last()), 'loadFailures': failures(), 'seekOutcome': seek.get('outcome'),
                                         'artifact': shot('dead-end'), 'earlier': shots}
            env.proxy.stall_until = 0.0
            t_play = run.now()
            run.act('play')
            run.app.api('/v1/playback/play', {}, timeout=60)
            hit = run.until(lambda s: s['songId'] == ids[0] and s['playing'] and s['proc'] == 'ready', 60)
            run.metrics['playAfterHoldS'] = None if hit is None else round(hit['t'] - t_play, 1)
            run.metrics['playAfterHoldPos'] = None if hit is None else hit['pos']
            time.sleep(max(0.0, t_play + 30 - run.now()))
            finish_futures(run, 20)
    finally:
        env.proxy.stall_until = 0.0
        env.proxy.set_profile(*restore)
    run.metrics['startCall'] = repr(start_future.exception(timeout=1)) if start_future.done() else 'pending'
    run.metrics['finalState'] = pick(run.last())
    run.metrics['loadFailuresEnd'] = failures()
    if run.metrics.get('playAfterHoldS') is None:
        run.violations.append(violation('playDidNotRestart', run.now(), f"final state {run.metrics['finalState']}", run))
    if run.metrics['heldWindow']['loadFailures'] not in (0, None):
        run.violations.append(violation('loadFailureEvent', run.now(), f"loadFailures={run.metrics['heldWindow']['loadFailures']} while held", run))


def case_dead_start(run: Run, env):
    """Item 3: the origin sends headers but no body bytes from the start; the load must still fail over at about
    the old 12 s deadline (not the 45 s progress cap). Records when the first recovery/navigation/failure shows."""
    ids = env.backend.fresh_album()
    run.songs = [{'id': i} for i in ids]
    env.proxy.stall(55.0)
    t0 = run.now()
    rec = start_queue(run, ids)
    first_event = None
    deadline = time.monotonic() + 50
    while time.monotonic() < deadline and first_event is None:
        for e in run.trace:
            if e['kind'] in ('recovery', 'navigate', 'loadFailure', 'loadError') or (e['kind'] == 'playerState' and e.get('errorCode')) \
                    or (e['kind'] == 'songCurrent' and e.get('songId') != ids[0]):
                first_event = e
                break
        s = run.last()
        if first_event is None and s and s['songId'] not in (None, ids[0]) and s['t'] > t0:
            first_event = {'kind': 'songChange', 'rel': s['t'] + run.w0 - run.w0, 'songId': s['songId']}
        time.sleep(0.2)
    env.proxy.stall_until = 0.0
    t_ev = None
    if first_event is not None:
        t_ev = first_event['rel'] if 'rel' in first_event else None
    # trace 'rel' is host-wall relative to run start; harness t0 is when the case began
    run.metrics['deadStart'] = {'startAtS': t0, 'firstEventKind': first_event and first_event['kind'],
                                'firstEventAtS': t_ev, 'afterS': None if t_ev is None else round(t_ev - t0, 1),
                                'decision': first_event and first_event.get('decision'), 'reason': first_event and first_event.get('reason')}
    run.metrics['deadStartTrace'] = [f"{e['rel']:+.1f}s {e['kind']} " + ' '.join(f'{k}={e[k]}' for k in ('decision', 'reason', 'processingState', 'stage', 'phase', 'songId', 'errorCode', 'operation') if e.get(k) is not None)
                                     for e in run.trace if e['kind'] != 'bufferState'][:30]
    run.observe(3.0)


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


def i87_start(run: Run, env):
    song = env.backend.fresh_songs(1)[0]
    run.i87_rate = bytes_per_second(song, run.quality)
    start_single(run, song)
    return song, int(song['duration']) * 1000


def i87_seek(run: Run, target: int, observe_s: float):
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        rec = issue_seek(run, pool, target)
        landed(run, rec)
        finish_futures(run)
    run.observe(observe_s)
    return rec


def case_i87_natural(run: Run, env):
    """#87: natural play, no seek, 60 s."""
    i87_start(run, env)
    run.observe(60.0)


def case_i87_seekpast(run: Run, env):
    """#87: seek past the downloaded part, then watch the line for 25 s."""
    _, dur = i87_start(run, env)
    run.observe(3.0)
    i87_seek(run, int(dur * 0.8), 25.0)


def case_i87_seekdl(run: Run, env):
    """#87: play until about 30 s are downloaded, seek to 80% of the downloaded part (ahead of the playhead), watch 20 s."""
    _, dur = i87_start(run, env)
    deadline = time.monotonic() + 40
    cache_s = 0.0
    while time.monotonic() < deadline:
        run.observe(1.0)
        cache_s = ((run.last()['cacheB'] or 0) / run.i87_rate) if run.i87_rate else 0.0
        if cache_s >= 30:
            break
    run.metrics['seekdlCacheS'] = round(cache_s, 1)
    target = int(0.8 * min(cache_s * 1000, 0.9 * dur))
    i87_seek(run, max(target, 5000), 20.0)


def case_i87_download(run: Run, env):
    """#87: a permanently downloaded song plays with the line at its full duration, also after a seek."""
    song = env.backend.fresh_songs(1)[0]
    fmt, kbps = QUALITIES[run.quality]
    body = {'songIds': [song['id']], **({'quality': kbps, 'format': fmt} if fmt else {})}
    run.app.api('/v1/downloads/enqueue', body, timeout=60)
    deadline = time.monotonic() + 240
    while time.monotonic() < deadline:
        status = run.app.api('/v1/downloads/status', timeout=30)
        if any(e.get('songId') == song['id'] for e in status.get('permanentDownloads') or []):
            break
        time.sleep(1.0)
    else:
        raise CaseAbort('download did not complete')
    run.i87_rate = bytes_per_second(song, run.quality)
    start_single(run, song)
    run.observe(8.0)
    i87_seek(run, int(song['duration']) * 500, 8.0)
    run.metrics['i87src'] = run.last()['src']
    run.i87_full = True


def case_i87_cached(run: Run, env):
    """#87: play until the rolling cache holds the whole song, then seek to the middle: the line stays full."""
    song, dur = i87_start(run, env)
    complete = lambda: [r for r in run.env.proxy.log[run.proxy_mark:]
                        if r['id'] == song['id'] and r.get('status') == 200 and r.get('end') == 'complete'
                        and r['endpoint'] in ('stream', 'download')]
    deadline = time.monotonic() + 150
    while time.monotonic() < deadline:
        run.observe(1.0)
        last = run.last()
        if complete() or (run.i87_rate and (last['cacheB'] or 0) / run.i87_rate >= dur / 1000):
            break
    run.observe(3.0)
    run.metrics['cachedAtS'] = run.now()
    i87_seek(run, dur // 2, 8.0)
    run.i87_full = True


def case_i8_shots(run: Run, env):
    """Item 8: app-owned screenshots of the seek bar with the thumb in the cached range, in a gap, and in the ahead range."""
    song = env.backend.fresh_songs(1)[0]
    dur = int(song['duration']) * 1000
    out = Path.home() / '.cache/claude-navis-logs/playback-151/i8/rt/shots'
    out.mkdir(parents=True, exist_ok=True)

    def shot(label):
        status = run.app.api('/v1/playback/status', timeout=20)
        seek = status.get('seek') or {}
        info = {k: status.get(k) for k in ('positionMs', 'cachedPlayablePositionMs', 'cachedPlayableSource', 'drawnBufferedPositionMs',
                                           'drawnAheadStartMs', 'drawnAheadEndMs', 'playerBufferedPositionMs', 'positionOffsetMs', 'durationMs')}
        info['pendingSeekMs'] = (status.get('uiPlayback') or {}).get('pendingSeekMs')
        info['seekPending'] = seek.get('pending')
        response = run.app.api('/v1/presentation/screenshot', {'label': label}, timeout=30)
        artifact = response.get('artifact')
        src = (Path(ROOT) / artifact) if artifact else None
        if src and src.exists():
            shutil.copyfile(src, out / f'{label}-{run.quality}-{run.throttle}.png')
        run.metrics.setdefault('shots', {})[label] = {**info, 'artifact': artifact}

    start_single(run, song)
    run.until(lambda s: (s['pos'] or 0) >= 5000 and (s['cplay'] or 0) >= 25000, 40)
    shot('thumb-in-cached')
    target = int(dur * 0.8)
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        rec = issue_seek(run, pool, target)
        landed(run, rec)
        finish_futures(run)
        run.observe(2.5)
        shot('thumb-in-ahead')
        cached = run.last()['cplay'] or 0
        env.proxy.stall(25)
        rec2 = issue_seek(run, pool, (cached + target) // 2)
        run.observe(4.0)
        shot('thumb-in-gap')
        env.proxy.stall_until = 0.0
        landed(run, rec2)
        finish_futures(run)
    run.observe(2.0)


def case_i8_merge(run: Run, env):
    """Item 8: seek past the download to 40%, then watch until the download passes the seek point (the two ranges must merge)."""
    _, dur = i87_start(run, env)
    run.observe(3.0)
    target = int(dur * 0.4)
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        rec = issue_seek(run, pool, target)
        landed(run, rec)
        finish_futures(run)
    run.until(lambda s: (s['cplay'] or 0) >= target + 8000, 50)
    run.observe(3.0)


# ---------------------------------------------------------------------------
# Shuffle belongs to the queue (1.5.1, fix/shuffle-per-queue): scenarios 1-7.
# Each step records {name, ok, detail} in metrics['steps'] with the observed
# values, so a base run shows what the old behaviour did.
# ---------------------------------------------------------------------------

SHUFFLE_SHOTS = Path.home() / '.cache/claude-navis-logs/playback-151/shuffle/rt/shots'


def sh_step(run: Run, name: str, ok: bool, **observed):
    run.metrics.setdefault('steps', []).append({'name': name, 'ok': bool(ok), **observed})
    if not ok:
        run.violations.append(violation('shuffle:' + name, run.now(), json.dumps(observed, default=str)[:600], run))


def sh_status(run: Run) -> dict:
    st = run.app.api('/v1/playback/status', timeout=30)
    ui = st.get('uiPlayback') or {}
    return {'mode': st.get('shuffleMode'), 'flag': st.get('shuffleEnabled'), 'uiMode': ui.get('shuffleMode'),
            'queue': ui.get('queueSongIds') or [], 'song': st.get('songId'), 'idx': st.get('currentIndex'),
            'pos': st.get('positionMs'), 'playing': st.get('playing'), 'settled': st.get('queueSettled'),
            'loading': st.get('isLoading'), 'repeat': st.get('repeatMode')}


def sh_settle(run: Run, length: int, timeout=40):
    """Wait for a queue of `length` songs that finished filling and loading."""
    deadline = time.monotonic() + timeout
    st = sh_status(run)
    while time.monotonic() < deadline:
        st = sh_status(run)
        if len(st['queue']) == length and st['settled'] and not st['loading'] and st['song']:
            time.sleep(1.0)
            return sh_status(run)
        time.sleep(0.3)
    return st


def persisted_queue(app) -> dict:
    """The saved queue read from the profile database: mode, song order, original ranks."""
    import tempfile
    tmp = Path(tempfile.mkdtemp(prefix='shuf-', dir=app.run))
    try:
        for name in ('navis.sqlite', 'navis.sqlite-wal', 'navis.sqlite-shm'):
            if isinstance(app, AndroidApp):
                data = subprocess.run(app.adb + ['exec-out', 'run-as', ANDROID_PACKAGE, 'cat', f'{ANDROID_ROOT}/{name}'],
                                      capture_output=True).stdout
                if data:
                    (tmp / name).write_bytes(data)
            elif (ROOT / name).exists():
                shutil.copy(ROOT / name, tmp / name)
        db = sqlite3.connect(f'file:{tmp / "navis.sqlite"}?mode=ro', uri=True)
        try:
            row = db.execute('SELECT shuffle_mode, current_index FROM play_queue ORDER BY id LIMIT 1').fetchone()
            items = db.execute('SELECT song_id, original_order FROM play_queue_items ORDER BY sort_order').fetchall()
        finally:
            db.close()
        return {'mode': row[0] if row else None, 'index': row[1] if row else None,
                'ids': [i[0] for i in items], 'ranks': [i[1] for i in items]}
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def sh_persisted(run: Run, ids: list[str] | None = None, timeout=12) -> dict:
    """Poll the saved queue until it holds `ids` (when given) or the timeout passes."""
    deadline = time.monotonic() + timeout
    saved = persisted_queue(run.app)
    while time.monotonic() < deadline and ids is not None and saved['ids'] != ids:
        time.sleep(0.5)
        saved = persisted_queue(run.app)
    return saved


def media_session_shuffle(app):
    """True/False as the media session (MPRIS Shuffle on Linux, dumpsys media_session on Android) reports it."""
    if isinstance(app, AndroidApp):
        # dumpsys media_session does not print the shuffle mode: read the value audio_service pushes to the session.
        got = app.api('/v1/playback/status', timeout=30).get('systemShuffleMode')
        return None if got is None else got == 'all'
    listing = subprocess.run(['busctl', '--user', 'list', '--no-legend'], capture_output=True, text=True).stdout
    names = [l.split()[0] for l in listing.splitlines()
             if l.startswith('org.mpris.MediaPlayer2.navis') and l.split()[1] == str(app.proc.pid)]
    if not names:
        return None
    got = subprocess.run(['busctl', '--user', 'get-property', names[0], '/org/mpris/MediaPlayer2',
                          'org.mpris.MediaPlayer2.Player', 'Shuffle'], capture_output=True, text=True).stdout.strip()
    return got.endswith('true') if got.startswith('b ') else None


def sh_view(run: Run, expect_queue: list[str] | None = None):
    """The four places shuffle shows: handler snapshot, UI snapshot, media session, saved queue."""
    st = sh_status(run)
    saved = sh_persisted(run, expect_queue) if expect_queue is not None else persisted_queue(run.app)
    return st, saved, media_session_shuffle(run.app)


def sh_expect_off(run: Run, label: str, ids: list[str], idx=0):
    st, saved, media = sh_view(run, ids)
    obs = dict(snapshot=st['mode'], flag=st['flag'], ui=st['uiMode'], media=media, saved=saved['mode'],
               queueInOrder=st['queue'] == ids, savedInOrder=saved['ids'] == ids, idx=st['idx'], song=st['song'])
    sh_step(run, label, st['mode'] == 'none' and st['flag'] is False and st['uiMode'] == 'none'
            and media in (False, None) and saved['mode'] == 'off' and st['queue'] == ids
            and saved['ids'] == ids and st['idx'] == idx, **obs)
    if media is None:
        run.metrics.setdefault('mediaSessionUnread', []).append(label)
    return st


def sh_expect_on(run: Run, label: str, pool: list[str], keep_song=None):
    st, saved, media = sh_view(run, None)
    obs = dict(snapshot=st['mode'], flag=st['flag'], ui=st['uiMode'], media=media, saved=saved['mode'],
               permutation=sorted(st['queue']) == sorted(pool), queueNotInOrder=st['queue'] != pool, idx=st['idx'])
    sh_step(run, label, st['mode'] == 'all' and st['flag'] is True and st['uiMode'] == 'all'
            and media in (True, None) and saved['mode'] == 'all' and sorted(st['queue']) == sorted(pool)
            and (keep_song is None or st['song'] == keep_song), **obs)
    if media is None:
        run.metrics.setdefault('mediaSessionUnread', []).append(label)
    return st


def sh_play(run: Run, ids: list[str], shuffle=False, start=0):
    run.queue_ids = list(ids)
    run.act('start', songIds=len(ids), first=ids[0], shuffle=shuffle, startIndex=start)
    body = {'songIds': ids, **({'shuffle': True} if shuffle else {}), **({'startIndex': start} if start else {})}
    run.app.api('/v1/playback/queue', body, timeout=120)
    return sh_settle(run, len(ids))


def sh_pools(run: Run, env, n=8):
    a = [s['id'] for s in env.backend.fresh_songs(n)]
    b = [s['id'] for s in env.backend.fresh_songs(n)]
    run.songs = [{'id': i} for i in a + b]
    return a, b


def sh_shot(run: Run, label: str):
    SHUFFLE_SHOTS.mkdir(parents=True, exist_ok=True)
    try:
        run.app.api('/v1/presentation/player-overlay', {'surface': 'queue', 'visible': True}, timeout=30)
        time.sleep(1.0)
        response = run.app.api('/v1/presentation/screenshot', {'label': label}, timeout=30)
        artifact = response.get('artifact')
        if isinstance(run.app, AndroidApp):
            data = subprocess.run(run.app.adb + ['exec-out', 'run-as', ANDROID_PACKAGE, 'cat', f'{ANDROID_ROOT}/{artifact}'],
                                  capture_output=True).stdout
            if data:
                (SHUFFLE_SHOTS / f'{label}.png').write_bytes(data)
        elif artifact and (ROOT / artifact).exists():
            shutil.copyfile(ROOT / artifact, SHUFFLE_SHOTS / f'{label}.png')
        run.metrics['shot'] = label
        run.app.api('/v1/presentation/player-overlay', {'surface': 'queue', 'visible': False}, timeout=30)
    except Exception as exc:
        run.metrics['shotError'] = f'{type(exc).__name__}: {exc}'


def case_shuffle_q1(run: Run, env):
    """1. Entity Shuffle on A, then plain Play on B: B in order, shuffle off everywhere."""
    a, b = sh_pools(run, env)
    label = os.environ.get('SHUFFLE_SHOT_LABEL', 'queue-after-shuffle-then-play')
    sh_play(run, a, shuffle=True)
    sh_expect_on(run, 'shuffleA', a)
    sh_shot(run, label.replace('after-shuffle-then-play', 'shuffle-on'))  # for contrast with the indicator after Play
    sh_play(run, b)
    sh_expect_off(run, 'playB', b)
    sh_shot(run, label)


def case_shuffle_q2(run: Run, env):
    """2. Entity Shuffle on A, then tap song k of B: B in order from k, shuffle off."""
    a, b = sh_pools(run, env)
    sh_play(run, a, shuffle=True)
    sh_expect_on(run, 'shuffleA', a)
    sh_play(run, b, start=3)
    st = sh_expect_off(run, 'tapB3', b, idx=3)
    sh_step(run, 'tapB3Song', st['song'] == b[3], song=st['song'], wanted=b[3])


def case_shuffle_q3(run: Run, env):
    """3. Entity Shuffle on A, then Instant Mix: shuffle off, recommendation order."""
    a, b = sh_pools(run, env)
    sh_play(run, a, shuffle=True)
    first = sh_expect_on(run, 'shuffleA', a)
    seed = first['song']
    ordered = [s['id'] for s in env.backend.library.sorted_songs()]
    pos = {sid: i for i, sid in enumerate(ordered)}
    run.act('start', mix=seed)
    res = run.app.api('/v1/mix/start', {'mode': 'server', 'seedId': seed}, timeout=120)
    deadline = time.monotonic() + 40
    st = sh_status(run)
    while time.monotonic() < deadline:
        st = sh_status(run)
        if len(st['queue']) >= 6 and st['settled'] and not st['loading']:
            break
        time.sleep(0.4)
    time.sleep(1.5)
    st, saved, media = sh_view(run)
    after = [i for i in st['queue'][(st['idx'] or 0) + 1:] if i in pos]
    ascending = after == sorted(after, key=lambda i: pos[i]) and len(after) >= 5
    sh_step(run, 'mixOff', st['mode'] == 'none' and st['flag'] is False and st['uiMode'] == 'none'
            and media in (False, None) and saved['mode'] == 'off' and ascending,
            snapshot=st['mode'], flag=st['flag'], ui=st['uiMode'], media=media, saved=saved['mode'],
            recommendationOrder=ascending, queue=st['queue'][:14], seed=seed, mix=res)


def case_shuffle_q4(run: Run, env):
    """4. Plain Play A, toggle shuffle on mid-song (no restart), then off (original order, same song)."""
    a, _ = sh_pools(run, env)
    sh_play(run, a)
    await_audio(run, run.act('noop'), a[0])
    run.observe(4.0)
    before = sh_status(run)
    run.act('shuffle', enabled=True)
    run.app.api('/v1/playback/shuffle', {'enabled': True})
    time.sleep(2.0)
    on = sh_expect_on(run, 'toggleOn', a, keep_song=before['song'])
    sh_step(run, 'toggleOnNoRestart', on['pos'] is not None and on['pos'] >= (before['pos'] or 0) - 500
            and on['playing'] is True, before=before['pos'], after=on['pos'], playing=on['playing'])
    run.act('shuffle', enabled=False)
    run.app.api('/v1/playback/shuffle', {'enabled': False})
    time.sleep(2.0)
    off = sh_status(run)
    st, saved, media = sh_view(run, a)
    sh_step(run, 'toggleOffRestoresOrder', st['queue'] == a and st['song'] == before['song'] and st['mode'] == 'none'
            and saved['mode'] == 'off' and media in (False, None) and st['idx'] == 0 and off['pos'] >= on['pos'] - 500,
            queueInOrder=st['queue'] == a, song=st['song'], wanted=before['song'], idx=st['idx'], mode=st['mode'],
            media=media, saved=saved['mode'], posBefore=on['pos'], posAfter=off['pos'])


def case_shuffle_q5(run: Run, env):
    """5. A shuffled queue, then Add to queue and Play next: the mode stays on."""
    a, b = sh_pools(run, env)
    sh_play(run, a, shuffle=True)
    first = sh_expect_on(run, 'shuffleA', a)
    queue0 = first['queue']
    x, y = b[0], b[1]
    run.act('queueEdit', op='add', song=x)
    run.app.api('/v1/playback/queue-edit', {'op': 'add', 'songIds': [x]}, timeout=60)
    run.act('queueEdit', op='playNext', song=y)
    run.app.api('/v1/playback/queue-edit', {'op': 'playNext', 'songIds': [y]}, timeout=60)
    time.sleep(2.0)
    st, saved, media = sh_view(run)
    cur = st['idx'] or 0
    kept = [i for i in st['queue'] if i not in (x, y)] == queue0
    sh_step(run, 'editsKeepShuffle', st['mode'] == 'all' and st['flag'] is True and st['uiMode'] == 'all'
            and media in (True, None) and saved['mode'] == 'all' and kept and st['queue'][cur + 1:cur + 2] == [y]
            and x in st['queue'],
            snapshot=st['mode'], flag=st['flag'], ui=st['uiMode'], media=media, saved=saved['mode'], orderKept=kept,
            playNextRight=st['queue'][cur + 1:cur + 2] == [y], addPresent=x in st['queue'])
    run.act('shuffle', enabled=False)
    run.app.api('/v1/playback/shuffle', {'enabled': False})
    time.sleep(2.0)
    off = sh_status(run)
    sh_step(run, 'offKeepsAddedSongs', x in off['queue'] and y in off['queue'] and off['mode'] == 'none',
            queue=off['queue'])


def sh_kill_and_relaunch(run: Run, env):
    app = run.app
    if isinstance(app, AndroidApp):
        app.shell('am', 'force-stop', ANDROID_PACKAGE, check=False)
        app.proc = None
    else:
        os.killpg(app.proc.pid, signal.SIGKILL)
        app.proc.wait(timeout=20)
        app.proc = None
    time.sleep(2.0)
    app.launch()
    sign_in(app, env.backend.credentials, 'wifi', env.proxy.url)


def case_shuffle_q6(run: Run, env):
    """6. A shuffled queue survives a kill and relaunch with order and mode; then Play on another list turns it off."""
    a, b = sh_pools(run, env)
    sh_play(run, a, shuffle=True)
    before = sh_expect_on(run, 'shuffleA', a)
    saved0 = sh_persisted(run, before['queue'])
    sh_step(run, 'savedOrderBeforeKill', saved0['ids'] == before['queue'] and saved0['mode'] == 'all',
            saved=saved0['ids'], queue=before['queue'], mode=saved0['mode'])
    run.act('kill')
    sh_kill_and_relaunch(run, env)
    deadline = time.monotonic() + 60
    st = sh_status(run)
    while time.monotonic() < deadline and len(st['queue']) != len(a):
        time.sleep(0.5)
        st = sh_status(run)
    time.sleep(2.0)
    st, saved, media = sh_view(run)
    sh_step(run, 'restoredOrderAndMode', st['queue'] == before['queue'] and st['mode'] == 'all' and st['flag'] is True
            and st['uiMode'] == 'all' and media in (True, None) and saved['mode'] == 'all',
            snapshot=st['mode'], flag=st['flag'], ui=st['uiMode'], media=media, saved=saved['mode'],
            sameOrder=st['queue'] == before['queue'], restored=st['queue'])
    sh_play(run, b)
    sh_expect_off(run, 'playBAfterRestore', b)


def sh_passes(run: Run, expected: int, timeout: float):
    """Poll queue order and index until the index wraps `expected` times; return the queue seen at each pass."""
    deadline = time.monotonic() + timeout
    seen, wraps, last_idx = [], 0, None
    while time.monotonic() < deadline and wraps < expected:
        st = sh_status(run)
        if st['queue'] and st['idx'] is not None:
            if not seen:
                seen.append(list(st['queue']))
            if last_idx is not None and last_idx == len(st['queue']) - 1 and st['idx'] == 0:
                wraps += 1
                time.sleep(0.5)
                seen.append(list(sh_status(run)['queue']))
            last_idx = st['idx']
        time.sleep(0.25)
    return seen, wraps


def sh_short_ids(env):
    ids = [i for i in env.backend.fresh_album(short=True) if i not in env.backend.library.duplicates]
    return ids[:5]


def case_shuffle_q7(run: Run, env):
    """7. Repeat-all reshuffles a shuffled queue on wrap and never reshuffles an in-order queue."""
    shuffled_ids = sh_short_ids(env)
    plain_ids = sh_short_ids(env)
    run.songs = [{'id': i} for i in shuffled_ids + plain_ids]
    run.app.api('/v1/playback/repeat', {'mode': 'all'})
    sh_play(run, shuffled_ids, shuffle=True)
    seen, wraps = sh_passes(run, 3, 120)
    differs = [seen[i] != seen[i + 1] for i in range(len(seen) - 1)]
    sh_step(run, 'shuffledReshufflesOnWrap', wraps >= 2 and any(differs) and all(sorted(q) == sorted(shuffled_ids) for q in seen),
            wraps=wraps, passes=seen, changed=differs)
    sh_play(run, plain_ids)
    seen, wraps = sh_passes(run, 3, 120)
    sh_step(run, 'inOrderNeverReshuffles', wraps >= 2 and all(q == plain_ids for q in seen),
            wraps=wraps, passes=seen, wanted=plain_ids)
    run.app.api('/v1/playback/repeat', {'mode': 'none'})


def case_i9_inject(run: Run, env):
    """Item 9: a raw player seek back of about 6 s (clone-only diagnostics action, bypasses NavisAudioHandler.seek),
    twice, on two queue entries. A recorder build must log exactly one backwardJump per injection."""
    ids, rec = skip_queue(run, env)
    await_audio(run, rec, ids[0])
    injections = []
    for n in range(2):
        run.until(lambda s: s['songId'] == ids[n] and (s['pos'] or 0) > 12000 and s['playing'], 60)
        run.observe(1.0)
        before = run.last()
        run.act('rawSeekBack', n=n + 1)
        run.app.api('/v1/playback/recovery-fixture', {'action': 'rawSeekBack'})
        injections.append({'n': n + 1, 't': run.now(), 'posBefore': before['pos'], 'songId': before['songId']})
        run.observe(6.0)
        if n == 0:
            with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
                a = nav(run, pool, 'next')
                wait_advanced(run, a)
            run.observe(2.0)
    run.metrics['injections'] = injections


def case_i9_cut(run: Run, env):
    """Item 9: cut40 on an album whose first song is long (fixture first tracks are often 3-8 s)."""
    backend = env.backend
    original = backend.fresh_album

    def long_first(short=False):
        for _ in range(60):
            ids = original(short)
            if backend.library.songs[ids[0]]['duration'] >= 100:
                return ids
        raise CaseAbort('no album with a long first song')
    backend.fresh_album = long_first
    try:
        cut_at_case(0.40, 1)(run, env)
    finally:
        backend.fresh_album = original



def i10_case(mode):
    def case(run: Run, env):
        if mode == 'off':
            run.app.api('/v1/presentation/navigate', {'location': '/settings/playback'})
            run.observe(2)
            run.app.api('/v1/presentation/playback-settings', {'toggle': 'fastSeeking'})
            run.observe(2)
            with sqlite3.connect(f'file:{ROOT / "navis.sqlite"}?mode=ro', uri=True) as db:
                run.metrics['fastSeekingSettingOff'] = db.execute('SELECT fast_seeking_enabled FROM app_settings').fetchone()[0]
            response = run.app.api('/v1/presentation/screenshot', {'label': f'i10-setting-off-{run.rep}'}, timeout=30)
            shutil.copyfile(ROOT / response['artifact'], run.app.run / f'i10-setting-off-{run.rep}.png')
        song, dur = i87_start(run, env)
        run.observe(3)
        target = int(dur * (0.96 if mode == 'repeat' else 0.70))
        before = dict(run.last())
        run.metrics['beforeSeek'] = before
        if mode == 'repeat':
            run.metrics['repeatOne'] = True
            run.app.api('/v1/playback/repeat', {'mode': 'one'})
        rec = i87_seek(run, target, 4)
        after = [s for s in run.samples if s['t'] >= rec['t']]
        advancing = next((s for s in after if s['playing'] and s['proc'] == 'ready'
                          and target + 1000 <= (s['pos'] or 0) <= target + 10000), None)
        run.metrics['seekToAdvancingS'] = None if advancing is None else round(advancing['t'] - rec['t'], 3)
        run.metrics['seekEvents'] = run.app.api('/v1/playback/status').get('seekEvents')
        run.metrics['bridgeSeen'] = any(s.get('bridge') for s in after)
        if mode == 'quality':
            run.app.api('/v1/presentation/window', {'mode': 'miniPlayer'})
            run.app.api('/v1/presentation/window', {'width': 800, 'height': 500})
            run.observe(1)
            response = run.app.api('/v1/presentation/screenshot', {'label': 'i10-quality-x11'}, timeout=30)
            shutil.copyfile(ROOT / response['artifact'], run.app.run / 'i10-quality-x11.png')
            run.app.api('/v1/presentation/window', {'mode': 'desktop'})
        if not isinstance(run.app, AndroidApp) and mode in ('seek', 'off'):
            run.app.api('/v1/presentation/window', {'width': 560, 'height': 850})
            run.app.api('/v1/presentation/player-overlay', {'surface': 'nowPlaying', 'visible': True})
            run.observe(1)
            response = run.app.api('/v1/presentation/screenshot', {'label': f'i10-{mode}-{run.throttle}-{run.rep}'}, timeout=30)
            source = ROOT / response['artifact']
            dest = run.app.run / f'i10-{mode}-{run.throttle}-{run.rep}.png'
            shutil.copyfile(source, dest)
            run.metrics['screenshot'] = str(dest)
            run.app.api('/v1/presentation/player-overlay', {'surface': 'nowPlaying', 'visible': False})
            run.app.api('/v1/presentation/window', {'width': 1440, 'height': 900})

        run.metrics['fixtureRequests'] = [dict(r) for r in env.backend.requests() if r['songId'] == song['id']]
        if mode == 'continuity':
            run.app.api('/v1/presentation/window', {'mode': 'miniPlayer'})
            run.app.api('/v1/presentation/window', {'width': 1000, 'height': 600})
            run.observe(1)
            response = run.app.api('/v1/presentation/screenshot', {'label': f'i10-quality-{run.throttle}'}, timeout=30)
            dest = run.app.run / f'i10-quality-{run.throttle}.png'
            shutil.copyfile(ROOT / response['artifact'], dest)
            run.metrics['qualityScreenshot'] = str(dest)
            run.app.api('/v1/presentation/window', {'mode': 'desktop'})
            complete = run.until(lambda s: s['cacheB'] == song['size'], 600)
            run.metrics['cacheCompleted'] = complete is not None
            run.observe(1)
            with sqlite3.connect(f'file:{ROOT / "navis.sqlite"}?mode=ro', uri=True) as db:
                db.row_factory = sqlite3.Row
                run.metrics['cacheRows'] = [dict(r) for r in db.execute('SELECT * FROM cached_tracks WHERE song_id = ?', (song['id'],))]
            run.metrics['rollingFiles'] = [{'name': p.name, 'size': p.stat().st_size} for p in (ROOT / 'cache/audio/rolling').glob('*') if p.is_file()]
            run.metrics['originalSize'] = song['size']
            rows = run.metrics['cacheRows']
            assert complete is not None, 'Original download did not complete'
            assert len(rows) == 1 and rows[0]['format'] == 'flac' and rows[0]['file_size'] == song['size'], 'Original cache row is wrong'
            cached = Path(rows[0]['file_path'])
            original = env.backend.library.media_path(int(song['duration']))
            run.metrics['cachedSha256'] = hashlib.file_digest(cached.open('rb'), 'sha256').hexdigest()
            run.metrics['originalSha256'] = hashlib.file_digest(original.open('rb'), 'sha256').hexdigest()
            assert run.metrics['cachedSha256'] == run.metrics['originalSha256'], 'Cached bytes differ from the original FLAC'

        elif mode == 'back':
            back = i87_seek(run, 5000, 4)
            run.metrics['upgradeState'] = run.app.api('/v1/playback/status')
            run.checks.append(lambda: oracle_seek(run, back))
        elif mode == 'replay':
            run.act('start', reason='restartQueueEntry')
            run.app.api('/v1/playback/queue-index', {'index': 0}, timeout=90)
            run.observe(5)
            run.metrics['upgradeState'] = run.app.api('/v1/playback/status')
        elif mode == 'repeat':
            wrap = run.until(lambda s: s['t'] > rec['t'] + 5 and s['playing'] and s['proc'] == 'ready' and (s['pos'] or 0) < 10000, 60)
            run.metrics['repeatWrap'] = wrap
            assert wrap is not None, 'Repeat One never wrapped'
            run.observe(6)
            run.metrics['upgradeState'] = run.app.api('/v1/playback/status')
        else:
            run.observe(12)
        if mode == 'off':
            run.app.api('/v1/presentation/playback-settings', {'toggle': 'fastSeeking'})
            run.observe(2)
        if mode == 'repeat':
            run.checks.append(lambda: [v for v in oracle_seek(run, rec)
                                      if not (v['oracle'] == 'seekRegressed' and v['t'] >= wrap['t'] - 1)])
            state = run.metrics['upgradeState']
            assert state.get('fastSeekBridge') is None and state.get('positionOffsetMs') == 0, 'Repeat One kept the bridge'
            assert state.get('playing') and (state.get('playerPositionMs') or 0) >= 1500, 'Repeat One did not advance after wrap'
        else:
            run.checks.append(lambda: oracle_seek(run, rec))
        run.metrics['fixtureRequestsEnd'] = [dict(r) for r in env.backend.requests() if r['songId'] == song['id']]
    return case


# ---------------------------------------------------------------------------
# Playback harness cases (tool/playback_harness.py): seek-drag stress, memory
# soak, cross-fade hand-off and local-file seeks. Their per-case numbers go to
# run.metrics; the harness compares them between a base and a fix build.

DRAG_RNG = random.Random(12012)
DRAG_STEPS = [{'fraction': [.1, .8, .2, .9][i % 4], 'moveMs': 200 if i else 0, 'holdMs': DRAG_RNG.randint(300, 700)}
              for i in range(20)]
VM_SERVICE = os.environ.get('NAVIS_LIVE_SEEK_VM') == '1'  # the soak reads the Dart heap through the VM service


def max_frozen_s(run: Run) -> float:
    """Longest time the position stood still (within 200 ms) while playback was wanted, from the first audio on."""
    first_audio = next((s['t'] for s in run.samples if s['pos'] and s['playing']), None)
    anchor, longest = None, 0.0
    for s in run.samples:
        finished = s['proc'] == 'completed' and s['idx'] is not None and s['qlen'] and s['idx'] >= s['qlen'] - 1 and not s['deferred']
        if first_audio is None or s['t'] < first_audio or s['pos'] is None or finished or not wanted_at(run, s['t']):
            anchor = None
            continue
        if anchor is None or abs(s['pos'] - anchor['pos']) > 200 or s['songId'] != anchor['songId']:
            anchor = s
            continue
        longest = max(longest, s['t'] - anchor['t'])
    return round(longest, 2)


def oracle_crossfade(run: Run) -> list[dict]:
    """Cross-fade hand-offs: the outgoing and incoming song never swap back and forth (two current songs), and
    the position never jumps by more than a second between samples without a seek or navigation."""
    out, samples = [], run.samples
    if samples and not any((s['cf'] or {}).get('enabled') for s in samples):
        out.append(violation('crossfadeOff', samples[0]['t'], 'cross-fade was not enabled in the profile', run))
    for i in range(2, len(samples)):
        a, b, c = samples[i - 2], samples[i - 1], samples[i]
        if a['songId'] and a['songId'] == c['songId'] and b['songId'] not in (None, a['songId']) \
                and not _requested_at(run, b['t']):
            out.append(violation('doubleCurrent', b['t'], f"current song {a['songId']} -> {b['songId']} -> {c['songId']}", run))
    for a, b in zip(samples, samples[1:]):
        if a['songId'] and a['songId'] == b['songId'] and a['idx'] == b['idx'] and a['pos'] is not None and b['pos'] is not None \
                and a['proc'] == b['proc'] == 'ready' and a['playing'] and b['playing'] and abs(b['pos'] - a['pos']) > 1000 and not _requested_at(run, b['t']):
            out.append(violation('crossfadeProgressJump', b['t'], f"position {a['pos']} -> {b['pos']} on {b['songId']}", run))
            break
    return out


def case_crossfade_end(run: Run, env):
    """Cross-fade on a short album (1-8 s songs): every song ends by itself and the next must take over and play."""
    ids = [i for i in env.backend.fresh_album(short=True) if i not in env.backend.library.duplicates][:5]
    run.songs = [{'id': i} for i in ids]
    rec = start_queue(run, ids)
    await_audio(run, rec, ids[0])
    for n in range(len(ids) - 1):
        moved = run.until(lambda s, n=n: s['songId'] == ids[n + 1], 40)
        if moved is None:
            run.violations.append(violation('chainNoHandover', run.now(), f'song {n + 1} never followed song {n}', run))
            raise CaseAbort('no handover')
    ok = run.until(lambda s: s['songId'] == ids[-1] and s['playing'] and s['proc'] == 'ready', 20)
    if ok is None:
        run.violations.append(violation('pausedAtSongEnd', run.now(), 'the last song is not playing', run))
    run.checks.append(lambda: oracle_sequence(run, ids, minimum=len(ids)))


def start_player_overlay(run: Run):
    run.app.api('/v1/presentation/player-overlay', {'surface': 'nowPlaying', 'visible': True, 'settle': False})
    run.app.api('/v1/presentation/dismiss-popup', {})
    time.sleep(0.6)


def preview_sockets(rows: list[dict], released_w: float) -> dict:
    """Preview (timeOffset) GETs the gesture opened before its release: how many, the most open at once, and
    whether each closed before the next opened."""
    opened = sorted((r for r in rows if r.get('timeOffset') and r['w'] < released_w), key=lambda r: r['w'])
    ends = [r.get('endW') or float('inf') for r in opened]
    peak = max([sum(1 for e, o in zip(ends, opened) if o['w'] <= r['w'] < e - 0.05) for r in opened] or [0])
    ordered = all(ends[i] <= opened[i + 1]['w'] + 0.05 for i in range(len(opened) - 1))
    return {'previewGETs': len(opened), 'previewSocketMax': peak, 'closedBeforeSuccessor': ordered}


def case_stress_drag(run: Run, env):
    """One held pointer: 20 slider rests (seed 12012), then a single release. Records the heartbeat summaries the
    release returns, the origin sockets the previews opened, and release -> target + 1 s."""
    song = env.backend.fresh_songs(1)[0]
    start_single(run, song)
    run.observe(2.0)
    start_player_overlay(run)
    run.app.api('/v1/diagnostics/heartbeat', {'enabled': True})
    run.app.api('/v1/diagnostics/metrics/reset', {})
    mark = len(env.proxy.log)
    result = run.app.api('/v1/presentation/seek-drag', {'steps': DRAG_STEPS, 'release': True}, timeout=180)
    released_w, released_t = time.time(), run.now()
    run.act('seek', target=None, kind2='drag')
    target = (run.app.api('/v1/playback/status').get('seek') or {}).get('requestedPositionMs')
    if target is None:
        raise Failure('the release left no production seek target')
    settled = run.until(lambda s: s['t'] >= released_t and (s['pos'] or 0) >= target + 1000 and s['proc'] == 'ready'
                        and not s['seekPending'], 60)
    run.observe(3.0)
    run.app.api('/v1/diagnostics/heartbeat', {'enabled': False})
    run.metrics['drag'] = {
        **preview_sockets(env.proxy.log[mark:], released_w),
        'heartbeat': result['heartbeat'],
        'releaseToTargetPlus1S': None if settled is None else round(settled['t'] - released_t, 3)}
    if settled is None:
        run.violations.append(violation('dragNoSettle', released_t, f'no playback at {target}+1 s within 60 s', run))


def case_stress_flick(run: Run, env):
    """A continuous five-second flick opens no preview request."""
    song = env.backend.fresh_songs(1)[0]
    start_single(run, song)
    run.observe(2.0)
    start_player_overlay(run)
    run.app.api('/v1/diagnostics/heartbeat', {'enabled': True})
    mark = len(env.proxy.log)
    result = run.app.api('/v1/presentation/seek-drag', {'fraction': .1, 'flickMs': 5000}, timeout=90)
    released_w = time.time()
    run.act('seek', target=None, kind2='flick')
    run.observe(3.0)
    run.app.api('/v1/diagnostics/heartbeat', {'enabled': False})
    run.metrics['flick'] = {**preview_sockets(env.proxy.log[mark:], released_w), 'heartbeat': result['heartbeat']}


def app_pid(app) -> int:
    if isinstance(app, AndroidApp):
        return int(app.shell('pidof', ANDROID_PACKAGE).strip().split()[0])
    return app.proc.pid


def memory_kib(app) -> dict:
    pid = app_pid(app)
    path = f'/proc/{pid}/smaps_rollup'
    text = app.shell('run-as', ANDROID_PACKAGE, 'cat', path) if isinstance(app, AndroidApp) else Path(path).read_text()
    fields = dict(re.findall(r'^(Pss|SwapPss):\s+(\d+) kB$', text, re.MULTILINE))
    if not {'Pss', 'SwapPss'} <= fields.keys():
        raise Failure('memory-soak needs Pss and SwapPss in smaps_rollup')
    return {'pssKiB': int(fields['Pss']), 'swapPssKiB': int(fields['SwapPss'])}


def vm_url(app) -> str:
    """The Dart VM service of a profile build started with NAVIS_LIVE_SEEK_VM=1."""
    text = (subprocess.run(app.adb + ['logcat', '-d', '-s', 'flutter:*'], capture_output=True, text=True).stdout
            if isinstance(app, AndroidApp) else (app.run / 'app.log').read_text(errors='replace'))
    found = re.findall(r'Dart VM [Ss]ervice[^\n]*?(http://127\.0\.0\.1:(\d+)/[^\s]+/)', text)
    if not found:
        raise Failure('no Dart VM service URL in the app log (NAVIS_LIVE_SEEK_VM=1?)')
    url, port = found[-1]
    if isinstance(app, AndroidApp):
        forwarded = subprocess.run(app.adb + ['forward', 'tcp:0', f'tcp:{port}'], check=True,
                                   capture_output=True, text=True).stdout.strip()
        url = url.replace(f':{port}/', f':{forwarded}/')
    return url


def vm_call(url: str, method: str, **params):
    with urlopen(url + method + '?' + urlencode(params), timeout=60) as response:
        body = json.load(response)
    if 'error' in body:
        raise Failure(f'VM {method}: {body["error"]}')
    return body['result']


def dart_heap(url: str, isolate: str, gc=False) -> int:
    if gc:
        vm_call(url, 'getAllocationProfile', isolateId=isolate, gc='true')
    return vm_call(url, 'getMemoryUsage', isolateId=isolate)['heapUsage']


def case_mem_soak(run: Run, env, drags=int(os.environ.get('NAVIS_LIVE_SEEK_SOAK_DRAGS', 20)),
                  idle_s=int(os.environ.get('NAVIS_LIVE_SEEK_SOAK_IDLE_S', 120))):
    """20 held drags on fresh songs, 10 s of playback after each, then 120 s of idle playback and a forced GC.
    Records resident PSS and SwapPss (KiB) after every drag and the Dart heap for the harness slope."""
    if not VM_SERVICE:
        raise Failure('memory-soak needs NAVIS_LIVE_SEEK_VM=1 (the harness sets it)')
    url = vm_url(run.app)
    isolate = next(i['id'] for i in vm_call(url, 'getVM')['isolates'] if i.get('name') == 'main')
    rows = []
    for drag in range(1, drags + 1):
        start_single(run, env.backend.fresh_songs(1)[0])
        run.observe(1.0)
        start_player_overlay(run)
        run.app.api('/v1/presentation/seek-drag', {'steps': DRAG_STEPS, 'release': True}, timeout=180)
        released_t = run.now()
        run.act('seek', target=None, kind2='drag')
        target = (run.app.api('/v1/playback/status').get('seek') or {}).get('requestedPositionMs') or 0
        run.until(lambda s: s['t'] >= released_t and (s['pos'] or 0) >= target + 1000 and s['proc'] == 'ready', 60)
        run.observe(10.0)
        rows.append({'drag': drag, **memory_kib(run.app), 'heapB': dart_heap(url, isolate)})
    start_single(run, env.backend.fresh_songs(1)[0])
    run.observe(idle_s)
    before = {**memory_kib(run.app), 'heapB': dart_heap(url, isolate)}
    after = {'heapB': dart_heap(url, isolate, gc=True)}
    after.update(memory_kib(run.app))
    run.metrics['soak'] = {'drags': rows, 'beforeGc': before, 'afterGc': after}


def case_local_seek(run: Run, env):
    """A permanently downloaded song: seeks to 5 s, the middle and 5 s again land within 500 ms of the target,
    and the player reads the local file."""
    song = env.backend.fresh_songs(1)[0]
    fmt, kbps = QUALITIES[run.quality]
    run.app.api('/v1/downloads/enqueue', {'songIds': [song['id']], **({'quality': kbps, 'format': fmt} if fmt else {})}, timeout=60)
    deadline = time.monotonic() + 240
    while time.monotonic() < deadline:
        status = run.app.api('/v1/downloads/status', timeout=30)
        if any(e.get('songId') == song['id'] for e in status.get('permanentDownloads') or []):
            break
        time.sleep(1.0)
    else:
        raise CaseAbort('download did not complete')
    start_single(run, song)
    run.observe(2.0)
    recs, errors = [], []
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        for target in (5000, int(song['duration']) * 500, 5000):
            rec = issue_seek(run, pool, target)
            hit = landed(run, rec)
            finish_futures(run)
            recs.append(rec)
            if hit is not None:
                errors.append(abs(hit['pos'] - target))
            run.observe(2.0)
    run.metrics['localSeek'] = {'errorsMs': errors, 'src': run.last()['src']}
    run.checks.append(lambda: [v for r in recs for v in oracle_seek(run, r)])
    run.latency_from = recs
    if not errors or max(errors) >= 500:
        run.violations.append(violation('localLandingError', run.now(), f'landing errors {errors} ms (limit 500)', run))


# Repeat All edge from the q7 investigation: an append 200 ms before / 5 ms after the end of the queue's last
# song must continue into the appended song, playing. (A seek 150 ms before the end races the sampler: not ported.)

def q7_last_song(run: Run, env):
    """Repeat All on a short album sorted so its longest song is last; returns (ids, the last song's sample) at 3 s in."""
    ids = sorted(sh_short_ids(env), key=lambda x: env.backend.library.songs[x]['duration'])
    run.songs = [{'id': i} for i in ids]
    run.app.api('/v1/playback/repeat', {'mode': 'all'})
    sh_play(run, ids, start=len(ids) - 1)
    tail = run.until(lambda s: s['idx'] == len(ids) - 1 and s['proc'] == 'ready' and (s['pos'] or 0) > 3000, 25)
    if tail is None:
        raise CaseAbort('the last song did not play')
    return ids, tail


def sleep_until_remaining(run: Run, tail: dict, remaining_ms: int):
    time.sleep(max(0.0, run.t0 + tail['t'] + (tail['dur'] - tail['pos'] - remaining_ms) / 1000 - time.monotonic()))


def q7_append_case(remaining_ms: int):
    def case(run: Run, env):
        added = sh_short_ids(env)[-1]
        sh_play(run, [added, added])  # the queue call stores a fixture song the library lacks; queue-edit only resolves stored ones
        settle_between_runs(run.app)
        ids, tail = q7_last_song(run, env)
        sleep_until_remaining(run, tail, remaining_ms)
        run.act('queueEdit', op='add', song=added)
        response = run.app.api('/v1/playback/queue-edit', {'op': 'add', 'songIds': [added]}, timeout=60)
        if response.get('queueLength') != len(ids) + 1:
            raise Failure('the appended fixture song was not admitted')
        got = run.until(lambda s: s['songId'] == added and s['playing'] and s['proc'] == 'ready' and (s['pos'] or 0) > 0, 35)
        sh_step(run, 'appendContinues', got is not None, remainingMs=remaining_ms, sample=got)
        run.observe(2.0)
    return case


CASE_FUNCS = {
    **{f"i10_{m}": i10_case(m) for m in ("seek", "continuity", "back", "replay", "repeat", "off", "quality")},
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
    'cold_next': cold_command_case('next'),
    'cold_seek': cold_command_case('seek'),
    'dead_start': case_dead_start,
    'cold_seek_stall': case_cold_seek_stall,
    'dead_source_hold': case_dead_source_hold,
    'cold_seek_hold20': lambda run, env: case_cold_seek_stall(run, env, stall_s=20.0, at_start=True),
    'cold_seek_hold40': lambda run, env: case_cold_seek_stall(run, env, stall_s=40.0, at_start=True),
    'cut40': cut_at_case(0.40, 1),
    'cut40x2': cut_at_case(0.40, 2),
    'repeat_one_fill': case_repeat_one_fill,
    'chain_end': case_chain_end,
    'natural_play3': case_natural_play3,
    'i87_natural': case_i87_natural, 'i87_seekpast': case_i87_seekpast, 'i87_seekdl': case_i87_seekdl,
    'i87_download': case_i87_download, 'i87_cached': case_i87_cached, 'i8_shots': case_i8_shots, 'i8_merge': case_i8_merge,
    'chain_end_all': case_chain_end_all, 'i9_inject': case_i9_inject, 'i9_cut': case_i9_cut,
    **{f'shuffle_q{n}': globals()[f'case_shuffle_q{n}'] for n in range(1, 8)},
    'repeat_switch_off': case_repeat_switch_off,
    'base_repeat_one': case_base_repeat_one,
    'hold_off': hold_case(0.5, 'none', False),
    'hold_all': hold_case(0.5, 'all', True),
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
    'crossfade_end': case_crossfade_end, 'stress_drag': case_stress_drag, 'stress_flick': case_stress_flick,
    'mem_soak': case_mem_soak, 'local_seek': case_local_seek,
    'q7_append_200': q7_append_case(200), 'q7_append_after5': q7_append_case(-5),
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


def anomaly_log_lines(app) -> list:
    """Every [PLAYBACK_ANOMALY] line in the app log so far (Android: logcat; Linux: the app's stdout file)."""
    try:
        if isinstance(app, AndroidApp):
            out = subprocess.run(app.adb + ['logcat', '-d', '-s', 'flutter:*'], capture_output=True, text=True, timeout=60).stdout
        else:
            app.log.flush()
            out = (app.run / 'app.log').read_text(errors='replace')
    except Exception:
        return []
    return [line for line in out.splitlines() if 'PLAYBACK_ANOMALY' in line]


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
    anomaly_mark = len(anomaly_log_lines(app))
    sampler.start()
    truth = None
    run.proxy_mark = proxy_mark
    if TRUTH and case in ('i87_natural', 'i87_seekpast', 'i87_seekdl', 'i8_merge'):
        truth = TruthSampler(run)
        truth.start()
    error = None
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
        if truth:
            truth.halt.set()
            truth.join(timeout=30)
            run.metrics['i8truth'] = truth.rows
    if app.proc is not None and app.proc.poll() is not None:
        run.violations.append(violation('appExited', run.now(), f'the app exited (code {app.proc.returncode}) during the case', run))
    for check in run.checks:
        try:
            run.violations += check()
        except Exception as exc:
            run.violations.append(violation('oracleError', run.now(), f'{type(exc).__name__}: {exc}', run))
    run.violations += oracle_unexpected_change(run) + oracle_stall(run) + oracle_replay(run)
    if VERIFY_OFFSET:
        run.violations += oracle_progress_loss(run)
    if CROSSFADE_S:
        run.violations += oracle_crossfade(run)
        run.metrics['crossfadePhases'] = run.samples[-1]['cf']['phases'] if run.samples else None
    run.metrics['maxFrozenS'] = max_frozen_s(run)
    logged = anomaly_log_lines(app)
    run.metrics['anomalyLines'] = logged[anomaly_mark if anomaly_mark <= len(logged) else 0:]
    try:
        run.metrics['anomaliesStatus'] = app.api('/v1/playback/status').get('anomalies')
    except Exception as exc:
        run.metrics['anomaliesStatus'] = f'unreadable: {exc}'
    song = run.songs[0] if run.songs else None
    if song and song.get('duration'):
        # Bytes per second of audio: what the server actually sent for a
        # complete response, else the nominal bitrate.
        done = [r['bytes'] for r in proxy.log[proxy_mark:]
                if r['id'] == song['id'] and r.get('status') == 200 and r.get('end') == 'complete']
        rate = max(done) / song['duration'] if done else bytes_per_second(song, quality)
        run.violations += oracle_buffer_lag(run, rate)
        if case.startswith(('i87', 'i10')):
            run.violations += oracle_i87(run, song, quality, proxy.log[proxy_mark:], getattr(run, 'i87_full', False))
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
    if hard or unique or VERIFY_OFFSET or case.startswith(('i87', 'i10')) or case == 'skip_next':
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
        if args.seed_only:
            return 0  # the synced catalog in ROOT/navis.sqlite is all the harness wants (it seeds Android with it)
        if CROSSFADE_S and not args.android:
            # A fresh profile has no database before the first launch, so point_profile_at wrote nothing:
            # set cross-fade and gapless now and relaunch on the kept profile.
            app.stop()
            point_profile_at(app_url)
            app.proc = None
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
    parser.add_argument('--truth', action='store_true',
                        help='item 8: i87_natural/seekpast/seekdl also compare the drawn cached time with the partial cache file (ffprobe)')
    parser.add_argument('--seed-only', action='store_true',
                        help='sign the fixture profile in and stop (leaves the synced catalog in the data root)')
    parser.add_argument('--no-transcode-offset', action='store_true',
                        help='fixture does not advertise/honour transcodeOffset')
    args = parser.parse_args()
    global TRUTH, CROSSFADE_S, NATURAL_SONGS, NATURAL_FULL, LIVE_MAX_SONG_S, REPEAT_MODE, LIVE_REUSE_GROUPS, PRIME_SERVER_CACHE, SLOW_NEXT_S, VERIFY_OFFSET
    TRUTH = args.truth
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
        build_android() if args.android else build(credentials)
        return 0
    BASE.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    run = Path(os.environ.get('NAVIS_LIVE_SEEK_RUNS', str(BASE / 'runs'))) / f'{stamp}-{args.label}'
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
