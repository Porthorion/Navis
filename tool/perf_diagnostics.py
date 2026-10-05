#!/usr/bin/env python3
"""Bounded performance diagnostics for Navis on Linux.

Runs an isolated profile build against a real Subsonic server and records
frame, memory, provider, playback, and local-search metrics through the
authenticated diagnostics API. Every wait is bounded, and the run ends with one
compact summary (``summary.json`` and ``summary.md``), so it can run in the
background without anyone polling it.

Credentials come from ``NAVIS_PERF_CREDENTIAL_FILE``: a mode-600 JSON file with
``url``, ``username``, and ``password``. The password is written only to a
mode-600 file read by the clone's in-memory credential store, and is sent only
to ``POST /v1/session/connect`` during ``--fresh``. It is never logged.

Profiles:
  default   Clone ``NAVIS_DIAGNOSTICS_PRIMARY_DB`` (the normal Navis database)
            once into build/perf-diagnostics/profile, then reuse that warm
            profile. Only the clone is modified.
  --fresh   Start from an empty database, connect, and measure the first sync.
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import random
import shlex
import shutil
import sqlite3
import stat
import struct
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

from diagnostics_profile import disable_external_integrations

ROOT = pathlib.Path(__file__).resolve().parent.parent
BASE = ROOT / 'build' / 'perf-diagnostics'
PROFILE = BASE / 'profile'
# NAVIS_PERF_BUNDLE runs a saved build (for example an unmodified baseline)
# instead of the current profile bundle.
BUNDLE = pathlib.Path(os.environ.get(
    'NAVIS_PERF_BUNDLE',
    str(ROOT / 'build' / 'linux' / 'x64' / 'profile' / 'bundle' / 'navis')))
APK = pathlib.Path(os.environ.get(
    'NAVIS_PERF_APK',
    str(ROOT / 'build' / 'app' / 'outputs' / 'flutter-apk' /
        'app-sideload-profile.apk')))
ANDROID_PACKAGE = 'com.navis.app.navis.perf'
ANDROID_DATA = f'/data/user/0/{ANDROID_PACKAGE}'
ANDROID_HANDSHAKE = (f'/sdcard/Android/data/{ANDROID_PACKAGE}/files/'
                     'navis-diagnostics/handshake.json')
ANDROID_PORT = 19485
# NAVIS_PERF_GOLDEN selects another snapshot, for example one at an older
# schema for a baseline build that cannot open a newer database.
GOLDEN = pathlib.Path(os.environ.get('NAVIS_PERF_GOLDEN',
                                     str(PROFILE / 'golden.sqlite')))
FOLDER_FIXTURE = PROFILE / 'folder-fixture'
REMOTE_ARTIST = os.environ.get('NAVIS_PERF_REMOTE_ARTIST', 'SQUARE ENIX MUSIC')
SEARCH_QUERIES = [
    'love', 'the', 'bohemian rhapsody', 'bhmn rhpsdy', 'beyonce', 'café',
    'عمرو', 'حب', '東京', 'zz',
]


class Failure(Exception):
    pass


def load_credentials() -> dict:
    path = os.environ.get('NAVIS_PERF_CREDENTIAL_FILE')
    if not path:
        raise Failure('NAVIS_PERF_CREDENTIAL_FILE is required')
    file = pathlib.Path(path)
    mode = stat.S_IMODE(file.lstat().st_mode)
    if file.is_symlink() or mode & 0o077:
        raise Failure('credential file must be a regular mode-600 file')
    data = json.loads(file.read_text())
    for key in ('url', 'username', 'password'):
        if not isinstance(data.get(key), str) or not data[key]:
            raise Failure(f'credential file is missing {key}')
    return data


def defines() -> dict:
    return dict(
        NAVIS_UPDATE_CHANNEL='dev',
        NAVIS_APP_ID_SUFFIX='.perf',
        NAVIS_APP_NAME='Navis Perf Diagnostics',
        NAVIS_SYNC_DIAGNOSTICS='true',
        NAVIS_SYNC_DIAGNOSTICS_MUTED='true',
        NAVIS_SYNC_DIAGNOSTICS_MODE='clone',
        NAVIS_SYNC_DIAGNOSTICS_HANDSHAKE=str(PROFILE / 'handshake.json'),
        NAVIS_SYNC_DIAGNOSTICS_ROOT=str(PROFILE),
        NAVIS_SYNC_DIAGNOSTICS_DB_PATH=str(PROFILE / 'navis.sqlite'),
        NAVIS_SYNC_DIAGNOSTICS_CREDENTIAL_PATH=str(PROFILE / 'password'),
    )


def android_defines() -> dict:
    # The clone database stays in the sidecar's private internal storage, as
    # in a real install; only the handshake is published to external storage.
    values = defines()
    values.update(
        NAVIS_SYNC_DIAGNOSTICS_HANDSHAKE='',
        NAVIS_SYNC_DIAGNOSTICS_ROOT=ANDROID_DATA,
        NAVIS_SYNC_DIAGNOSTICS_DB_PATH=f'{ANDROID_DATA}/app_flutter/perf.sqlite',
        NAVIS_SYNC_DIAGNOSTICS_CREDENTIAL_PATH=f'{ANDROID_DATA}/files/password',
    )
    return values


def build(log: pathlib.Path, android: bool = False) -> float:
    started = time.monotonic()
    # One ABI keeps the APK small enough for emulator data partitions;
    # NAVIS_PERF_ANDROID_PLATFORM=android-arm64 targets a physical phone.
    platform = os.environ.get('NAVIS_PERF_ANDROID_PLATFORM', 'android-x64')
    command = (['flutter', 'build', 'apk', '--profile', '--flavor', 'sideload',
                '--target-platform', platform]
               if android else ['flutter', 'build', 'linux', '--profile'])
    values = android_defines() if android else defines()
    env = dict(os.environ, NAVIS_APP_ID_SUFFIX='.perf',
               NAVIS_APP_NAME='Navis Perf Diagnostics')
    with open(log, 'w') as out:
        result = subprocess.run(
            [*command, *[f'--dart-define={k}={v}' for k, v in values.items()]],
            cwd=ROOT, stdout=out, stderr=subprocess.STDOUT, timeout=1800,
            env=env,
        )
    if result.returncode != 0:
        raise Failure(f'build failed; see {log}')
    return round(time.monotonic() - started, 1)


def prepare_profile(credentials: dict, fresh: bool) -> None:
    if fresh and PROFILE.exists():
        shutil.rmtree(PROFILE)
    PROFILE.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(PROFILE, 0o700)
    password = PROFILE / 'password'
    password.write_text(credentials['password'] + '\n')
    os.chmod(password, 0o600)
    database = PROFILE / 'navis.sqlite'
    if database.exists() and not fresh:
        if GOLDEN.exists():
            # Restore the post-first-sync snapshot, so remote hydration,
            # adopted downloads and queues from earlier runs never change the
            # workload of this one.
            for suffix in ('-wal', '-shm'):
                pathlib.Path(f'{database}{suffix}').unlink(missing_ok=True)
            with sqlite3.connect(f'file:{GOLDEN}?mode=ro', uri=True) as golden, \
                    sqlite3.connect(database) as clone:
                golden.backup(clone)
        # Each run starts without a saved queue so launches are comparable; the
        # cold-restart scenario saves its own queue during the run.
        with sqlite3.connect(database) as clone:
            clone.execute('DELETE FROM play_queue_items')
            clone.execute('DELETE FROM play_queue')
            clone.execute('DELETE FROM cached_tracks')
            clone.execute('DELETE FROM download_queue')
            clone.execute(
                'UPDATE app_settings SET custom_download_folder_enabled=0, '
                'custom_download_folder_path=NULL')
            clone.commit()
        return
    if fresh:
        return
    source = pathlib.Path(os.environ.get(
        'NAVIS_DIAGNOSTICS_PRIMARY_DB',
        str(pathlib.Path.home() / 'Documents' / 'navis.sqlite.sqlite')))
    with sqlite3.connect(f'file:{source}?mode=ro', uri=True) as original, \
            sqlite3.connect(database) as clone:
        original.backup(clone)
        clone.execute(
            'UPDATE server_config SET url=?, username=?',
            (credentials['url'], credentials['username']))
        clone.execute(
            'UPDATE app_settings SET scrobble_enabled=0, '
            'last_fm_scrobbling_enabled=0, listen_brainz_scrobbling_enabled=0, '
            'update_check_enabled=0, custom_download_folder_enabled=0, '
            'custom_download_folder_path=NULL')
        disable_external_integrations(clone)
        clone.execute('DELETE FROM play_queue_items')
        clone.execute('DELETE FROM play_queue')
        clone.execute('DELETE FROM cached_tracks')
        clone.execute('DELETE FROM download_queue')
        clone.commit()
    os.chmod(database, 0o600)


def unhydrate_artist(database: pathlib.Path, name: str, keep: int = 2) -> dict:
    """Forgets the songs of all but [keep] of an artist's albums in the clone,
    so playing the artist hydrates them from the server one by one, as for an
    artist the user has never opened."""
    with sqlite3.connect(database) as clone:
        clone.execute('PRAGMA foreign_keys=ON')
        row = clone.execute(
            'SELECT id FROM artists WHERE name = ? COLLATE NOCASE LIMIT 1',
            (name,)).fetchone()
        if row is None:
            return {'error': f'artist {name!r} not in catalog'}
        albums = [r[0] for r in clone.execute(
            'SELECT id FROM albums WHERE artist_id = ? ORDER BY id',
            (row[0],))][keep:]
        marks = ','.join('?' * len(albums))
        songs = [r[0] for r in clone.execute(
            f'SELECT id FROM songs WHERE album_id IN ({marks})', albums)]
        song_marks = ','.join('?' * len(songs))
        clone.execute(
            f'DELETE FROM song_search_text WHERE song_id IN ({song_marks})',
            songs)
        clone.execute(f'DELETE FROM songs WHERE id IN ({song_marks})', songs)
        clone.execute(
            f'UPDATE albums SET songs_hydrated = 0 WHERE id IN ({marks})',
            albums)
        clone.commit()
    return {'albums': len(albums), 'songs': len(songs)}


class App:
    def __init__(self, output: pathlib.Path):
        self.output = output
        self.process: subprocess.Popen | None = None
        self.client: dict | None = None

    def launch(self, label: str) -> dict:
        handshake = PROFILE / 'handshake.json'
        handshake.unlink(missing_ok=True)
        log = open(self.output / f'{label}.log', 'w')
        started = time.monotonic()
        self.process = subprocess.Popen(
            [str(BUNDLE)], cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
        log.close()

        def ready():
            if self.process.poll() is not None:
                raise Failure(f'app exited; see {label}.log')
            return handshake.exists() and handshake.stat().st_size > 0

        wait_until(ready, 120, 'handshake')
        handshake_s = time.monotonic() - started
        self.client = json.loads(handshake.read_text())
        self.api('/v1/health')
        self.api('/v1/diagnostics/overrides',
                 {'networkType': 'wifi', 'automaticSyncAllowed': False})
        wait_until(
            lambda: self.api('/v1/playback/bootstrap/status').get('handlerReady'),
            120, 'handlerReady')
        handler_s = time.monotonic() - started
        return {'handshakeS': round(handshake_s, 2),
                'handlerReadyS': round(handler_s, 2)}

    def api(self, route: str, body=None, timeout=60):
        request = urllib.request.Request(
            f'http://127.0.0.1:{self.client["port"]}{route}',
            data=None if body is None else json.dumps(body).encode(),
            headers={'Authorization': f'Bearer {self.client["token"]}',
                     'Content-Type': 'application/json'})
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.load(response)

    def cpu_seconds(self) -> float:
        fields = pathlib.Path(f'/proc/{self.process.pid}/stat').read_text()
        parts = fields.rsplit(')', 1)[1].split()
        return (int(parts[11]) + int(parts[12])) / os.sysconf('SC_CLK_TCK')

    def stop(self) -> None:
        if self.process is None:
            return
        try:
            self.api('/v1/shutdown', {}, timeout=20)
            self.process.wait(timeout=30)
        except Exception:
            self.process.terminate()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
        self.process = None


class AndroidApp(App):
    """Drives the profile sidecar on a device or emulator through adb."""

    def __init__(self, output: pathlib.Path, serial: str):
        super().__init__(output)
        self.adb = ['adb', '-s', serial]
        self.pid: str | None = None

    def shell(self, *args: str, check=True) -> str:
        return subprocess.run(self.adb + ['shell', *args], check=check,
                              capture_output=True, text=True).stdout

    def install_and_seed(self, credentials: dict, seed: pathlib.Path | None):
        installed = subprocess.run(self.adb + ['install', '-r', str(APK)],
                                   capture_output=True)
        if installed.returncode != 0:
            # Small emulator data partitions cannot hold two copies of the
            # APK; replace only this disposable sidecar.
            subprocess.run(self.adb + ['uninstall', ANDROID_PACKAGE],
                           capture_output=True)
            subprocess.run(self.adb + ['install', str(APK)], check=True,
                           capture_output=True)
        self.shell('am', 'force-stop', ANDROID_PACKAGE)
        # The notification prompt would otherwise hold the sidecar's UI
        # bootstrap until someone answers it.
        self.shell('pm', 'grant', ANDROID_PACKAGE,
                   'android.permission.POST_NOTIFICATIONS', check=False)
        staging = '/data/local/tmp/navis-perf'
        self.shell('mkdir', '-p', staging)
        password = self.output / 'password.tmp'
        password.write_text(credentials['password'] + '\n')
        os.chmod(password, 0o600)
        try:
            subprocess.run(self.adb + ['push', str(password),
                                       f'{staging}/password'],
                           check=True, capture_output=True)
        finally:
            password.unlink()
        self.shell('run-as', ANDROID_PACKAGE, 'mkdir', '-p', 'files',
                   'app_flutter')
        self.shell('run-as', ANDROID_PACKAGE, 'cp', f'{staging}/password',
                   'files/password')
        if seed is not None:
            # A small rolling-cache budget keeps streamed FLAC from filling an
            # emulator's data partition; playback behaviour is otherwise the
            # same.
            staged_seed = self.output / 'seed.sqlite'
            with sqlite3.connect(f'file:{seed}?mode=ro', uri=True) as source, \
                    sqlite3.connect(staged_seed) as copy:
                source.backup(copy)
                copy.execute('UPDATE app_settings SET rolling_cache_budget_mb=256')
                copy.execute('DELETE FROM play_queue_items')
                copy.execute('DELETE FROM play_queue')
                copy.commit()
            seed = staged_seed
            subprocess.run(self.adb + ['push', str(seed),
                                       f'{staging}/perf.sqlite'],
                           check=True, capture_output=True)
            self.shell('run-as', ANDROID_PACKAGE, 'rm', '-f',
                       'app_flutter/perf.sqlite-wal',
                       'app_flutter/perf.sqlite-shm')
            self.shell('run-as', ANDROID_PACKAGE, 'cp',
                       f'{staging}/perf.sqlite', 'app_flutter/perf.sqlite')
        self.shell('rm', '-rf', staging)
        if seed is not None:
            seed.unlink(missing_ok=True)

    def launch(self, label: str) -> dict:
        self.shell('rm', '-f', ANDROID_HANDSHAKE, check=False)
        started = time.monotonic()
        self.shell('am', 'start', '-W', '-n',
                   f'{ANDROID_PACKAGE}/com.navis.app.navis.MainActivity')

        relaunched = False

        def ready():
            nonlocal relaunched
            text = self.shell('cat', ANDROID_HANDSHAKE, check=False)
            if text.strip().startswith('{'):
                return text
            # The first launch after a fresh install can die before the UI
            # bootstrap; relaunch it once.
            if (not relaunched and time.monotonic() - started > 5 and
                    not self.shell('pidof', ANDROID_PACKAGE,
                                   check=False).strip()):
                relaunched = True
                self.shell('am', 'start', '-W', '-n',
                           f'{ANDROID_PACKAGE}/com.navis.app.navis.MainActivity')
            return None

        handshake = json.loads(wait_until(ready, 120, 'handshake'))
        handshake_s = time.monotonic() - started
        subprocess.run(self.adb + ['forward', f'tcp:{ANDROID_PORT}',
                                   f'tcp:{handshake["port"]}'],
                       check=True, capture_output=True)
        self.client = {'port': ANDROID_PORT, 'token': handshake['token']}
        self.pid = self.shell('pidof', ANDROID_PACKAGE).strip().split()[0]
        self.api('/v1/health')
        self.api('/v1/diagnostics/overrides',
                 {'networkType': 'wifi', 'automaticSyncAllowed': False})
        wait_until(
            lambda: self.api('/v1/playback/bootstrap/status').get('handlerReady'),
            120, 'handlerReady')
        return {'handshakeS': round(handshake_s, 2),
                'handlerReadyS': round(time.monotonic() - started, 2)}

    def stage_saf_fixture(self, fixture: pathlib.Path) -> None:
        staging = '/data/local/tmp/navis-folder'
        self.shell('rm', '-rf', staging)
        subprocess.run(self.adb + ['push', str(fixture), staging],
                       check=True, capture_output=True)
        latency = os.environ.get('NAVIS_PERF_SAF_LATENCY_MS', '2')
        # adb joins arguments into one remote command line, so the script
        # must be quoted to run entirely as the app user.
        script = ('rm -rf files/navis-saf-fixture && '
                  'mkdir -p files/navis-saf-fixture && '
                  f'cp -r {staging}/. files/navis-saf-fixture/ && '
                  f'echo {int(latency)} > files/navis-saf-fixture-latency-ms')
        self.shell('run-as', ANDROID_PACKAGE, 'sh', '-c', shlex.quote(script))
        self.shell('rm', '-rf', staging)

    def cpu_seconds(self) -> float:
        fields = self.shell('cat', f'/proc/{self.pid}/stat')
        parts = fields.rsplit(')', 1)[1].split()
        return (int(parts[11]) + int(parts[12])) / 100

    def stop(self) -> None:
        if self.pid is None:
            return
        try:
            self.api('/v1/shutdown', {}, timeout=20)
        except Exception:
            pass
        time.sleep(2)
        self.shell('am', 'force-stop', ANDROID_PACKAGE, check=False)
        self.pid = None


def wait_until(check, timeout: float, label: str, interval=0.5):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = check()
        if value:
            return value
        time.sleep(interval)
    raise Failure(f'timed out after {timeout}s waiting for {label}')


def frame_summary(report: dict) -> dict:
    def ms(key, field):
        value = report.get(key, {}).get(field)
        return None if value is None else round(value / 1000, 2)
    frames = report.get('frames', {})
    gap = report.get('frameGap', {})
    lag = report.get('eventLoopLag', {})
    return {
        'buildP99Ms': ms('frameBuild', 'p99Micros'),
        'rasterP99Ms': ms('frameRaster', 'p99Micros'),
        'frameGapMaxMs': ms('frameGap', 'maxMicros'),
        'frameGapP99Ms': ms('frameGap', 'p99Micros'),
        'frameGapsOver50ms': gap.get('over50ms'),
        'frameGapsOver250ms': gap.get('over250ms'),
        'eventLoopLagMaxMs': ms('eventLoopLag', 'maxMicros'),
        'eventLoopLagOver50ms': lag.get('over50ms'),
        'playbackCounters': report.get('playbackCounters'),
        'tableUpdates': report.get('tableUpdates'),
        'samples': frames.get('samples', 0),
        'p50Ms': ms('frames', 'p50Micros'),
        'p95Ms': ms('frames', 'p95Micros'),
        'p99Ms': ms('frames', 'p99Micros'),
        'maxMs': ms('frames', 'maxMicros'),
        'over16ms': frames.get('over16ms'),
        'over33ms': frames.get('over33ms'),
        'fps': report.get('frameWindow', {}).get('framesPerSecond'),
        'rssMb': round(report.get('rssBytes', 0) / 1048576, 1),
        'peakRssMb': round(report.get('peakRssBytes', 0) / 1048576, 1),
        'providersAlive': (report.get('providers') or {}).get('alive'),
        'familyInstances': (report.get('providers') or {}).get('familyInstances'),
        'largestFamilies': (report.get('providers') or {}).get('largestFamilies', [])[:3],
        'imageCacheMb': round(
            report.get('imageCache', {}).get('currentSizeBytes', 0) / 1048576, 1),
        'liveImages': report.get('imageCache', {}).get('liveImageCount'),
        'dbCanaryP95Ms': ms('databaseCanary', 'p95Micros'),
        'dbCanaryMaxMs': ms('databaseCanary', 'maxMicros'),
    }


class Runner:
    def __init__(self, app: App, database: pathlib.Path):
        self.app = app
        self.database = database
        self.results: dict = {}

    def measure(self, name: str, action, heartbeat: bool = False):
        if heartbeat:
            self.app.api('/v1/diagnostics/heartbeat', {'enabled': True})
        self.app.api('/v1/diagnostics/metrics/reset', {})
        cpu_before = self.app.cpu_seconds()
        started = time.monotonic()
        error = None
        extra = {}
        try:
            extra = action() or {}
        except Failure as failure:
            error = str(failure)
        except Exception as failure:  # an API timeout ends only this scenario
            error = f'{type(failure).__name__}: {failure}'
        elapsed = time.monotonic() - started
        try:
            report = self.app.api('/v1/diagnostics/report', timeout=120)
        except Exception as failure:
            report = {}
            error = error or f'report {type(failure).__name__}: {failure}'
        if heartbeat:
            self.app.api('/v1/diagnostics/heartbeat', {'enabled': False})
        result = frame_summary(report)
        result['elapsedS'] = round(elapsed, 2)
        result['cpuPercent'] = round(
            100 * (self.app.cpu_seconds() - cpu_before) / max(elapsed, 0.001), 1)
        result.update(extra)
        if error:
            result['error'] = error
        self.results[name] = result
        print(f'[perf] {name}: {json.dumps(result)}', flush=True)
        return result

    def song_ids(self, count: int, seed: int) -> list[str]:
        with sqlite3.connect(f'file:{self.database}?mode=ro', uri=True) as db:
            ids = [row[0] for row in db.execute(
                'SELECT id FROM songs WHERE server_deleted_at IS NULL '
                'AND is_provisional = 0 ORDER BY id')]
        random.Random(seed).shuffle(ids)
        return ids[:count]

    def largest_artist(self) -> str | None:
        with sqlite3.connect(f'file:{self.database}?mode=ro', uri=True) as db:
            row = db.execute(
                'SELECT artist_id FROM songs WHERE artist_id IS NOT NULL '
                'GROUP BY artist_id ORDER BY COUNT(*) DESC LIMIT 1').fetchone()
        return row[0] if row else None

    def remote_artist_id(self) -> str | None:
        with sqlite3.connect(f'file:{self.database}?mode=ro', uri=True) as db:
            row = db.execute(
                'SELECT id FROM artists WHERE name = ? COLLATE NOCASE LIMIT 1',
                (REMOTE_ARTIST,)).fetchone()
        return row[0] if row else None

    def artist_page(self, artist: str):
        # Opening the page requests the artist's remote releases; wait for
        # that metadata to land so the shuffle scenario starts from the same
        # state the user sees before pressing Shuffle.
        self.app.api('/v1/presentation/navigate',
                     {'location': f'/library/artists/{artist}'})
        time.sleep(10)
        return {'artistId': artist}

    def remote_artist_shuffle(self):
        started = time.monotonic()
        self.app.api('/v1/presentation/artist-action', {'action': 'shuffle'})
        first_audio = None
        queue_open_ms = []
        next_probe = time.monotonic() + 4
        final = None
        deadline = time.monotonic() + 360
        while time.monotonic() < deadline:
            status = self.app.api('/v1/artists/playback/status')
            if first_audio is None:
                playback = self.app.api('/v1/playback/status')
                if playback.get('playing') and playback.get('positionMs', 0) > 0:
                    first_audio = round(time.monotonic() - started, 2)
            if status.get('stage') in ('completed', 'failed', 'cancelled'):
                final = status
                break
            if time.monotonic() >= next_probe:
                # Opening the Queue while the artist is still loading is the
                # interaction that used to become unusable.
                opened = time.monotonic()
                try:
                    # Time to the first frame with the Queue, not to every
                    # animation settling (the loading indicator never does).
                    self.app.api('/v1/presentation/player-overlay',
                                 {'surface': 'queue', 'visible': True,
                                  'settle': False},
                                 timeout=30)
                    queue_open_ms.append(round((time.monotonic() - opened) * 1000))
                    time.sleep(1.5)
                    self.app.api('/v1/presentation/player-overlay',
                                 {'surface': 'queue', 'visible': False},
                                 timeout=30)
                except Exception as error:  # reported, never fatal
                    queue_open_ms.append(f'error:{type(error).__name__}')
                next_probe = time.monotonic() + 5
            time.sleep(0.5)
        playback = self.app.api('/v1/playback/status')
        return {
            'stage': (final or {}).get('stage', 'timeout'),
            'artistPrepareS': round(time.monotonic() - started, 1),
            'firstAudioS': first_audio,
            'albums': f"{(final or {}).get('completedAlbums')}/{(final or {}).get('totalAlbums')}",
            'availableTracks': (final or {}).get('availableTracks'),
            'queueLength': playback.get('queueLength'),
            'playerSequenceLength': playback.get('playerSequenceLength'),
            'deferredLength': playback.get('deferredLength'),
            'queueOpenMs': queue_open_ms,
        }

    def remote_artist_crossfade(self, fade_s: int, linger_s: float = 60):
        """Shuffles the remote artist and forces a cross-fade every few
        seconds (by seeking near the end of each song) while its releases
        hydrate, sampling whether the player still holds the Dart queue."""
        started = time.monotonic()
        self.app.api('/v1/presentation/artist-action', {'action': 'shuffle'})
        deadline = started + 420
        done_at = None
        next_seek = started + 8
        samples = 0
        streak = 0
        mismatches = 0
        deck_mismatches = 0
        first_mismatch = None
        loading_since = None
        longest_loading = 0.0
        stopped_since = None
        longest_stopped = 0.0
        max_queue = 0
        min_after_max = None
        seeks = 0
        stage = None
        playback = {}
        collapse = None
        timeline = open(self.app.output / 'artist-crossfade-timeline.jsonl', 'w')
        db_state = None
        next_db_probe = started
        db_blocked_s = 0.0
        while time.monotonic() < deadline:
            # The report reads the database; a blocked connection shows here
            # first (playback status never touches it).
            if time.monotonic() >= next_db_probe:
                probed = time.monotonic()
                try:
                    self.app.api('/v1/diagnostics/report', timeout=5)
                    db_state = round((time.monotonic() - probed) * 1000)
                except Exception:
                    db_state = 'timeout'
                    db_blocked_s += time.monotonic() - probed
                next_db_probe = time.monotonic() + 10
            now = time.monotonic()
            if done_at is None:
                stage = self.app.api('/v1/artists/playback/status').get('stage')
                if stage in ('completed', 'failed', 'cancelled'):
                    done_at = now
            elif now - done_at >= linger_s:
                break
            playback = self.app.api('/v1/playback/status')
            samples += 1
            length = playback.get('queueLength') or 0
            native = playback.get('native') or {}
            crossfade = playback.get('crossfade') or {}
            seek_events = playback.get('seekEvents') or []
            timeline.write(json.dumps({
                't': round(now - started, 1),
                'stage': stage,
                'queue': length,
                'materialized': playback.get('materializedLength'),
                'sequence': playback.get('playerSequenceLength'),
                'tail': playback.get('deferredLength'),
                'head': playback.get('deferredHeadLength'),
                'index': playback.get('currentIndex'),
                'nativeIndex': native.get('index'),
                'song': playback.get('songId'),
                'playing': playback.get('playing'),
                'state': playback.get('processingState'),
                'loading': playback.get('isLoading'),
                'settled': playback.get('queueSettled'),
                'matches': playback.get('playerMatchesQueue'),
                'fading': crossfade.get('active'),
                'deck': crossfade.get('inactiveDeckSequenceLength'),
                'phases': crossfade.get('phases'),
                'seeks': len(seek_events),
                'lastSeekPath': (seek_events[-1] if seek_events else {})
                                .get('path'),
                'timedOps': (playback.get('counters') or {})
                            .get('timedPlayerOperations'),
                'nav': playback.get('navigation'),
                'lane': playback.get('queueLane'),
                'recovery': playback.get('recovery'),
                'db': db_state,
            }) + '\n')
            timeline.flush()
            if collapse is None and max_queue > 50 and length < max_queue / 2:
                collapse = round(now - started, 1)
                (self.app.output / 'artist-crossfade-collapse.json').write_text(
                    json.dumps(playback, indent=1))
            if length >= max_queue:
                max_queue = length
                min_after_max = length
            else:
                min_after_max = min(min_after_max or length, length)
            settled = playback.get('queueSettled', True)
            crossfade = playback.get('crossfade') or {}
            # A native call and its Dart commit are a moment apart; only a
            # mismatch that survives two samples counts.
            if settled and not crossfade.get('active') and \
                    playback.get('playerMatchesQueue') is False:
                streak += 1
                if streak == 2:
                    mismatches += 1
                    if first_mismatch is None:
                        native = playback.get('native') or {}
                        first_mismatch = {
                            'atS': round(now - started, 1),
                            'songId': playback.get('songId'),
                            'currentIndex': playback.get('currentIndex'),
                            'nativeIndex': native.get('index'),
                            'materializedLength':
                                playback.get('materializedLength'),
                            'playerSequenceLength':
                                playback.get('playerSequenceLength'),
                        }
            else:
                streak = 0
            if crossfade.get('active') is False and \
                    crossfade.get('inactiveDeckMatchesQueue') is False:
                deck_mismatches += 1
            if playback.get('isLoading'):
                loading_since = loading_since or now
                longest_loading = max(longest_loading, now - loading_since)
            else:
                loading_since = None
            if not playback.get('playing'):
                stopped_since = stopped_since or now
                longest_stopped = max(longest_stopped, now - stopped_since)
            else:
                stopped_since = None
            duration = playback.get('durationMs') or 0
            position = playback.get('positionMs') or 0
            # A seek cancels a fade in progress; let each fade finish.
            if now >= next_seek and playback.get('playing') and \
                    not crossfade.get('active') and \
                    duration > (2 * fade_s + 10) * 1000 and \
                    duration - position > (fade_s + 6) * 1000:
                try:
                    self.app.api('/v1/playback/seek', {
                        'positionMs': duration - (fade_s + 4) * 1000})
                    seeks += 1
                except Exception:  # reported through the counters only
                    pass
                next_seek = now + fade_s + 8
            time.sleep(0.5)
        timeline.close()
        (self.app.output / 'artist-crossfade-final.json').write_text(
            json.dumps(playback, indent=1))
        crossfade = playback.get('crossfade') or {}
        return {
            'stage': stage or 'timeout',
            'collapseAtS': collapse,
            'dbProbeTimeoutS': round(db_blocked_s, 1),
            'finalLane': playback.get('queueLane'),
            'finalRecovery': playback.get('recovery'),
            'finalLoading': playback.get('isLoading'),
            'runS': round(time.monotonic() - started, 1),
            'samples': samples,
            'seeks': seeks,
            'crossfadePhases': crossfade.get('phases'),
            'playerQueueMismatches': mismatches,
            'firstMismatch': first_mismatch,
            'idleDeckMismatchSamples': deck_mismatches,
            'longestLoadingS': round(longest_loading, 1),
            'longestStoppedS': round(longest_stopped, 1),
            'maxQueueLength': max_queue,
            'minQueueLengthAfterMax': min_after_max,
            'finalQueueLength': playback.get('queueLength'),
            'finalPlaying': playback.get('playing'),
        }

    def build_folder_fixture(self, count: int, flac_kb: int, other_kb: int,
                             target: pathlib.Path) -> dict:
        with sqlite3.connect(f'file:{self.database}?mode=ro', uri=True) as db:
            rows = db.execute(
                "SELECT title, COALESCE(artist_name, ''), "
                "LOWER(COALESCE(suffix, 'mp3')) FROM songs "
                'WHERE server_deleted_at IS NULL AND is_provisional = 0 '
                'ORDER BY id').fetchall()
        random.Random(count).shuffle(rows)
        if target.exists():
            shutil.rmtree(target)
        target.mkdir(parents=True)
        payload = os.urandom(max(flac_kb, other_kb) * 1024)
        written = 0
        seen = set()

        def clean(value: str) -> str:
            value = value.replace('/', ' ').replace('\0', ' ').strip()
            return value[:120] or 'Unknown'

        for title, artist, suffix in rows:
            if written >= count:
                break
            folder = target / clean(artist)
            path = folder / f'{clean(title)}.{suffix or "mp3"}'
            if path in seen:
                continue
            seen.add(path)
            folder.mkdir(exist_ok=True)
            with open(path, 'wb') as out:
                if suffix == 'flac':
                    out.write(_minimal_flac_header())
                    out.write(payload[:flac_kb * 1024])
                else:
                    out.write(payload[:other_kb * 1024])
            written += 1
        return {'files': written}

    def folder_import(self, count: int):
        if isinstance(self.app, AndroidApp):
            fixture = self.app.output / 'folder-fixture'
            built = self.build_folder_fixture(count, 512, 128, fixture)
            self.app.stage_saf_fixture(fixture)
            shutil.rmtree(fixture)
            body = {'fixture': True}
        else:
            built = self.build_folder_fixture(count, 1024, 256, FOLDER_FIXTURE)
            body = {'path': str(FOLDER_FIXTURE)}
        started = time.monotonic()
        result = self.app.api('/v1/downloads/folder/adopt', body, timeout=1800)
        result['adoptS'] = round(time.monotonic() - started, 1)
        result.update(built)
        return result

    def idle(self, seconds: float):
        time.sleep(seconds)

    def play_queue(self, count: int, fill_timeout: float, skips: int = 0):
        ids = self.song_ids(count, seed=count)
        started = time.monotonic()
        call: dict = {}

        def submit():
            try:
                self.app.api('/v1/playback/queue', {'songIds': ids},
                             timeout=fill_timeout + 60)
            except Exception as error:  # reported, never fatal to the run
                call['error'] = type(error).__name__
            call['returnedS'] = round(time.monotonic() - started, 1)

        worker = threading.Thread(target=submit, daemon=True)
        worker.start()

        def playing():
            status = self.app.api('/v1/playback/status')
            return status if status.get('playing') and status.get('positionMs', 0) > 0 else None

        wait_until(playing, 90, 'first advancing position')
        for _ in range(skips):
            self.app.api('/v1/playback/next', {})
            time.sleep(1)
        filled = None
        status = {}
        deadline = time.monotonic() + fill_timeout
        while time.monotonic() < deadline:
            status = self.app.api('/v1/playback/status')
            # A released-window queue holds only part of it in the player;
            # the rest is deferred, and both count as filled.
            held = (status.get('playerSequenceLength', 0) +
                    status.get('deferredLength', 0))
            if status.get('queueLength') == count and held >= count - 5:
                filled = time.monotonic() - started
                break
            time.sleep(1)
        worker.join(timeout=5)
        attempts = status.get('startupAttempts') or []
        stages = {}
        for attempt in attempts:
            for event in attempt['events']:
                if ':' not in event['stage']:
                    stages.setdefault(event['stage'], event['elapsedMs'])
        return {
            'queueSize': count,
            'firstAudioS': None if 'firstAdvancingPosition' not in stages
            else round(stages['firstAdvancingPosition'] / 1000, 2),
            'fillCompleteS': None if filled is None else round(filled, 1),
            'fillTimedOut': filled is None,
            'apiCall': call,
            'playerSequenceLength': status.get('playerSequenceLength'),
            'deferredLength': status.get('deferredLength'),
            'queueLength': status.get('queueLength'),
            'navigation': status.get('navigation'),
            'startupStages': stages,
        }

    def scroll_library(self):
        self.app.api('/v1/presentation/navigate', {'location': '/library?section=albums'})
        time.sleep(2)
        reached = 0
        for step in range(1, 61):
            try:
                reached = self.app.api(
                    '/v1/presentation/library-scroll', {'pixels': step * 1600})['pixels']
            except urllib.error.HTTPError:
                break
            time.sleep(0.15)
        self.app.api('/v1/presentation/library-scroll', {'pixels': 0})
        return {'scrolledPx': reached}

    def local_search(self):
        timings = {}
        for query in SEARCH_QUERIES:
            samples = []
            counts = None
            for _ in range(3):
                result = self.app.api(
                    '/v1/diagnostics/local-search?query=' +
                    urllib.parse.quote(query))
                samples.append(result['songs']['elapsedMicros'] / 1000)
                counts = {k: result[k]['count'] for k in ('artists', 'albums', 'songs')}
            timings[query] = {'songsMedianMs': round(sorted(samples)[1], 1),
                              'counts': counts}
        all_ms = sorted(v['songsMedianMs'] for v in timings.values())
        return {'queries': timings,
                'songsP50Ms': all_ms[len(all_ms) // 2],
                'songsMaxMs': all_ms[-1]}

    def artist_shuffle(self):
        artist = self.largest_artist()
        if artist is None:
            raise Failure('no artist found')
        started = time.monotonic()
        self.app.api('/v1/artists/playback',
                     {'command': 'prepare', 'artistId': artist, 'action': 'shuffle'})

        def done():
            status = self.app.api('/v1/artists/playback/status')
            return status if status.get('stage') in ('completed', 'failed', 'cancelled') else None

        final = wait_until(done, 240, 'artist playback')
        status = self.app.api('/v1/playback/status')
        return {'stage': final.get('stage'),
                'artistPrepareS': round(time.monotonic() - started, 1),
                'queueLength': status.get('queueLength'),
                'playing': status.get('playing')}


def _minimal_flac_header() -> bytes:
    # fLaC, a 34-byte STREAMINFO, then a last VORBIS_COMMENT block holding
    # only a vendor string; the audio frames that follow are opaque bytes.
    streaminfo = bytes([0, 0]) + struct.pack('>H', 4096) + bytes(30)
    vendor = b'navis-perf'
    comment = struct.pack('<I', len(vendor)) + vendor + struct.pack('<I', 0)
    return (b'fLaC' + bytes([0]) + len(streaminfo).to_bytes(3, 'big') +
            streaminfo + bytes([0x84]) + len(comment).to_bytes(3, 'big') +
            comment)


def first_sync(app: App, runner: Runner, credentials: dict):
    def action():
        started = time.monotonic()
        # Launch disables automatic sync so scenarios are not disturbed; the
        # first catalog sync needs it, or the planner defers it.
        app.api('/v1/diagnostics/overrides',
                {'networkType': 'wifi', 'automaticSyncAllowed': True})
        app.api('/v1/diagnostics/sync-foreground', {'active': True})
        app.api('/v1/presentation/onboarding/complete', {})
        app.api('/v1/session/connect', {
            'url': credentials['url'], 'username': credentials['username'],
            'password': credentials['password']}, timeout=120)

        def ready():
            status = app.api('/v1/session/status')
            return status if status.get('phase') == 'ready' and \
                status.get('initialSync') in ('complete', None) else None

        final = wait_until(ready, 900, 'first sync', interval=5)
        app.api('/v1/diagnostics/overrides',
                {'networkType': 'wifi', 'automaticSyncAllowed': False})
        report = app.api('/v1/diagnostics/report')
        return {'firstSyncS': round(time.monotonic() - started, 1),
                'catalog': report.get('catalog'),
                'initialSync': final.get('initialSync')}
    runner.measure('S1_first_sync', action)


def write_summary(output: pathlib.Path, summary: dict):
    (output / 'summary.json').write_text(json.dumps(summary, indent=2))
    lines = [f"# Navis perf run {summary['label']}", '',
             '| Scenario | p50 | p95 | p99 | max | >16ms | fps | CPU% | RSS MB | providers | img MB | notes |',
             '|---|---|---|---|---|---|---|---|---|---|---|---|']
    for name, r in summary['scenarios'].items():
        notes = {k: v for k, v in r.items() if k in (
            'firstAudioS', 'fillCompleteS', 'fillTimedOut', 'songsP50Ms',
            'songsMaxMs', 'scrolledPx', 'artistPrepareS', 'firstSyncS',
            'handshakeS', 'handlerReadyS', 'error', 'dbCanaryP95Ms',
            'frameGapMaxMs', 'frameGapsOver250ms', 'eventLoopLagMaxMs',
            'queueOpenMs', 'albums', 'adoptS', 'importedCount', 'files')}
        lines.append(
            f"| {name} | {r.get('p50Ms')} | {r.get('p95Ms')} | {r.get('p99Ms')} | "
            f"{r.get('maxMs')} | {r.get('over16ms')} | {r.get('fps')} | "
            f"{r.get('cpuPercent')} | {r.get('rssMb')} | {r.get('providersAlive')} | "
            f"{r.get('imageCacheMb')} | {json.dumps(notes)} |")
    (output / 'summary.md').write_text('\n'.join(lines) + '\n')


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--fresh', action='store_true')
    parser.add_argument('--label', default='run')
    parser.add_argument('--skip-build', action='store_true')
    parser.add_argument('--build-only', action='store_true')
    parser.add_argument('--android', metavar='SERIAL',
                        help='run on an Android device/emulator sidecar')
    parser.add_argument('--android-seed', action='store_true',
                        help='copy the synced Linux profile database to the '
                             'Android sidecar before running')
    parser.add_argument('--scenarios', default='all',
                        help='comma list: idle,queue2k,library,search,queue10k,'
                             'artist,artist-remote,artist-crossfade,'
                             'folder-import,cold (artist-crossfade runs only '
                             'when named)')
    parser.add_argument('--unhydrate-artist', action='store_true',
                        help='forget the remote artist\'s album songs in the '
                             'clone (all but two albums), so playing it '
                             'hydrates them during playback')
    parser.add_argument('--crossfade', type=int, metavar='SECONDS',
                        help='set the cross-fade length in the clone; 0 turns '
                             'cross-fade off (default: keep the clone\'s)')
    parser.add_argument('--folder-files', type=int, default=400,
                        help='files in the folder-import fixture')
    parser.add_argument('--refresh-golden', action='store_true',
                        help='launch once, let startup maintenance bring the '
                             'derived indexes up to date, then save the '
                             'profile as the golden snapshot')
    args = parser.parse_args()
    wanted = set(args.scenarios.split(','))

    def enabled(name):
        return 'all' in wanted or name in wanted

    credentials = load_credentials()
    output = BASE / 'runs' / f"{time.strftime('%Y%m%dT%H%M%S')}-{args.label}"
    output.mkdir(parents=True, mode=0o700)
    summary = {'label': args.label, 'fresh': args.fresh, 'scenarios': {}}
    android = args.android is not None
    if not args.skip_build:
        summary['buildS'] = build(output / 'build.log', android=android)
    if args.build_only:
        print(f"[perf] built in {summary['buildS']}s", flush=True)
        return 0
    prepare_profile(credentials, args.fresh)
    if args.crossfade is not None:
        with sqlite3.connect(PROFILE / 'navis.sqlite') as clone:
            clone.execute(
                'UPDATE app_settings SET crossfade_enabled=?, '
                'crossfade_duration_seconds=?, gapless_enabled=1',
                (1 if args.crossfade > 0 else 0, max(args.crossfade, 1)))
            clone.commit()
        summary['crossfadeS'] = args.crossfade
    if args.unhydrate_artist:
        summary['unhydrated'] = unhydrate_artist(
            PROFILE / 'navis.sqlite', REMOTE_ARTIST)
    if android:
        app = AndroidApp(output, args.android)
        app.install_and_seed(
            credentials, PROFILE / 'navis.sqlite' if args.android_seed else None)
    else:
        app = App(output)
    # Song IDs for scenarios come from the synced Linux profile; the Android
    # sidecar is seeded from the same catalog.
    runner = Runner(app, PROFILE / 'navis.sqlite')
    runner.results = summary['scenarios']
    exit_code = 0
    try:
        launch = app.launch('launch')
        runner.results['S2_launch'] = launch
        if args.refresh_golden and not android:
            # Migrations and deferred maintenance (20 s after launch) rewrite
            # derived indexes; measure later runs against their steady state.
            time.sleep(90)
            app.stop()
            with sqlite3.connect(
                    f'file:{PROFILE / "navis.sqlite"}?mode=ro',
                    uri=True) as source, sqlite3.connect(GOLDEN) as golden:
                source.backup(golden)
            print('[perf] golden snapshot refreshed', flush=True)
            return 0
        if args.fresh:
            first_sync(app, runner, credentials)
            if not android:
                # Later runs restore this post-sync snapshot so they all start
                # from the same catalog, before any scenario mutates it.
                time.sleep(25)  # let deferred maintenance finish its pass
                with sqlite3.connect(
                        f'file:{PROFILE / "navis.sqlite"}?mode=ro',
                        uri=True) as source, sqlite3.connect(GOLDEN) as golden:
                    source.backup(golden)
                os.chmod(GOLDEN, 0o600)
        else:
            app.api('/v1/presentation/onboarding/complete', {})
        app.api('/v1/presentation/navigate', {'location': '/'})
        time.sleep(3)
        if enabled('idle'):
            runner.measure('S5a_idle_home_paused', lambda: runner.idle(8))
        if enabled('queue2k'):
            runner.measure('S4a_queue_2000', lambda: runner.play_queue(2000, 180))
            runner.measure('S5b_idle_home_playing', lambda: runner.idle(10))
            app.api('/v1/presentation/player-overlay',
                    {'surface': 'nowPlaying', 'visible': True})
            time.sleep(1)
            runner.measure('S5c_idle_now_playing', lambda: runner.idle(10))
            app.api('/v1/presentation/player-overlay',
                    {'surface': 'nowPlaying', 'visible': False})
        if enabled('library'):
            runner.measure('S3_library_scroll', runner.scroll_library)
            app.api('/v1/presentation/navigate', {'location': '/'})
            runner.measure('S3b_after_scroll_idle', lambda: runner.idle(5))
        if enabled('search'):
            runner.measure('S6_local_search', runner.local_search)
        if enabled('queue10k'):
            runner.measure('S4b_queue_10000_skip',
                           lambda: runner.play_queue(10000, 240, skips=5))
        if enabled('artist'):
            runner.measure('S4c_artist_shuffle', runner.artist_shuffle)
        if enabled('artist-remote'):
            artist = runner.remote_artist_id()
            if artist is None:
                runner.results['S7_remote_artist'] = {
                    'error': f'artist {REMOTE_ARTIST!r} not in catalog'}
            else:
                runner.measure('S7a_remote_artist_page',
                               lambda: runner.artist_page(artist), heartbeat=True)
                runner.measure('S7b_remote_artist_shuffle',
                               runner.remote_artist_shuffle, heartbeat=True)
        if 'artist-crossfade' in wanted:
            artist = runner.remote_artist_id()
            if artist is None:
                runner.results['S7c_remote_artist_crossfade'] = {
                    'error': f'artist {REMOTE_ARTIST!r} not in catalog'}
            else:
                if not enabled('artist-remote'):
                    runner.artist_page(artist)
                else:
                    app.api('/v1/playback/queue/clear', {})
                fade = args.crossfade if args.crossfade else 5
                runner.measure('S7c_remote_artist_crossfade',
                               lambda: runner.remote_artist_crossfade(fade))
        if enabled('folder-import'):
            app.api('/v1/presentation/navigate', {'location': '/'})
            time.sleep(2)
            runner.measure('S8_folder_import',
                           lambda: runner.folder_import(args.folder_files),
                           heartbeat=True)
        if enabled('cold'):
            app.stop()
            launch = app.launch('cold-restart')
            runner.results['S2b_cold_restart_saved_queue'] = launch
            runner.measure('S2c_after_restart_idle', lambda: runner.idle(5))
    except Failure as failure:
        summary['error'] = str(failure)
        exit_code = 1
    finally:
        app.stop()
        write_summary(output, summary)
        print(f'[perf] summary: {output / "summary.md"}', flush=True)
    return exit_code


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Failure as failure:
        print(f'[perf] failed: {failure}', file=sys.stderr)
        sys.exit(1)
