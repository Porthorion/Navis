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
