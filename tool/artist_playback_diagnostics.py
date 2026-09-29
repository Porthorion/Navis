#!/usr/bin/env python3
"""Certify artist selection in a disposable Linux profile and loopback server."""

import io
import json
import os
import pathlib
import sqlite3
import subprocess
import threading
import time
import urllib.request
import wave
from http.server import ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import auth_lifecycle_fixture_server as fixture

ROOT = pathlib.Path(__file__).resolve().parent.parent
ARTIST_ID = 'artist-playback-fixture'
ALBUM_IDS = [f'artist-playback-album-{i}' for i in range(1, 4)]
SONG_IDS = [f'artist-playback-song-{i}' for i in range(1, 4)]
ALBUM_IDS[2] = 'ext-' + ALBUM_IDS[2]
SONG_IDS[2] = 'ext-' + SONG_IDS[2]
ALBUMS = [dict(id=album_id, name=f'Release {i}', artistId=ARTIST_ID,
               artist='Playback Fixture', year=2020+i, songCount=1,
               duration=30, coverArt='fixture-cover', isExternal=i == 3)
          for i, album_id in enumerate(ALBUM_IDS, 1)]
SONGS = [dict(id=song_id, title=f'Track {i}', albumId=album_id,
              album=f'Release {i}', artistId=ARTIST_ID if i == 1 else None,
              artist='Playback Fixture', track=1, discNumber=1,
              duration=30, suffix='wav', contentType='audio/wav', bitRate=352, isExternal=i == 3)
         for i, (song_id, album_id) in enumerate(zip(SONG_IDS, ALBUM_IDS), 1)]

EXTRA_SONG = {**SONGS[0], 'id': 'artist-playback-expanded-song',
              'title': 'Track 1 second disc', 'artistId': None, 'discNumber': 2}


def audio_bytes():
    with wave.open(io.BytesIO(fixture.AUDIO), 'rb') as original:
        frames = original.readframes(original.getnframes())
        parameters = original.getparams()
    output = io.BytesIO()
    with wave.open(output, 'wb') as destination:
        destination.setparams(parameters)
        destination.writeframes(frames * 8)
    return output.getvalue()


fixture.AUDIO = audio_bytes()


class Handler(fixture.Handler):
    incomplete = False
    artist_delay = 12
    album_delay = 3
    expanded = False

    def do_GET(self):
        parsed = urlparse(self.path)
        endpoint = parsed.path.rsplit('/', 1)[-1].removesuffix('.view')
        query = parse_qs(parsed.query)
        if endpoint == 'getArtist':
            time.sleep(self.artist_delay)
            self._json(fixture._root(artist=dict(id=ARTIST_ID, name='Playback Fixture', albumCount=3, album=ALBUMS)))
        elif endpoint == 'getAlbum':
            time.sleep(self.album_delay)
            album_id = query.get('id', [''])[0]
            if album_id not in ALBUM_IDS:
                self._json(fixture._root(status='failed', error={'code': 70, 'message': 'Fixture album unavailable'}))
                return
            index = ALBUM_IDS.index(album_id)
            album = {**ALBUMS[index], 'song': [SONGS[index]]}
            if self.expanded and index == 0:
                album['song'].append(EXTRA_SONG)
            if self.incomplete and index == 2:
                album['songCount'] = 2
            self._json(fixture._root(album=album))
        elif endpoint == 'getSong' and query.get('id', [''])[0] in SONG_IDS:
            self._json(fixture._root(song=SONGS[SONG_IDS.index(query['id'][0])]))
        elif endpoint == 'getArtists':
            self._json(fixture._root(artists={'index': [{'name': 'P', 'artist': [{'id': ARTIST_ID, 'name': 'Playback Fixture', 'albumCount': 3}]}]}))
        elif endpoint == 'getAlbumList2':
            self._json(fixture._root(albumList2={'album': ALBUMS if query.get('offset', ['0'])[0] == '0' else []}))
        else:
            super().do_GET()


def wait_until(check, timeout=90):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = check()
        if result:
            return result
        time.sleep(0.2)
    raise RuntimeError('Timed out waiting for artist diagnostics state')


def main():
    source = pathlib.Path(os.environ.get('NAVIS_DIAGNOSTICS_PRIMARY_DB', str(pathlib.Path.home() / 'Documents/navis.sqlite.sqlite')))
    output = ROOT / 'build/artist-playback-diagnostics' / time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())
    output.mkdir(parents=True, mode=0o700)
    os.chmod(output, 0o700)
    database = output / 'navis.sqlite'
    handshake = output / 'handshake.json'
    credential = output / 'fixture-password'
    credential.write_text('artist-playback-local-fixture\n')
    os.chmod(credential, 0o600)
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    with sqlite3.connect(f'file:{source}?mode=ro', uri=True) as original, sqlite3.connect(database) as clone:
        original.backup(clone)
        clone.execute("UPDATE server_config SET name='Artist Playback Fixture', url=?, username='diagnostics', capabilities=NULL, last_synced=?, is_authenticated=1", (f'http://127.0.0.1:{server.server_port}', int(time.time())))
        clone.execute("UPDATE app_settings SET sync_interval_minutes=0, last_full_sync_app_build='58', scrobble_enabled=0, last_fm_scrobbling_enabled=0, listen_brainz_scrobbling_enabled=0, update_check_enabled=0, use_lrclib=0, custom_download_folder_enabled=0, custom_download_folder_path=NULL")
        clone.execute('DELETE FROM play_queue_items')
        clone.execute('DELETE FROM play_queue')
        clone.execute("UPDATE cached_tracks SET file_path=? || song_id", (str(output / 'missing-cache-'),))
        clone.execute('INSERT INTO artists(id,name,album_count) VALUES(?,?,3)', (ARTIST_ID, 'Playback Fixture'))
        for i, album_id in enumerate(ALBUM_IDS, 1):
            clone.execute('INSERT INTO albums(id,name,artist_id,artist_name,year,song_count,songs_hydrated,is_external,is_provisional) VALUES(?,?,?,?,?,1,?,?,?)', (album_id, f'Release {i}', ARTIST_ID, 'Playback Fixture', 2020+i, i == 1, i == 3, i == 3))
        clone.execute('INSERT INTO songs(id,title,album_id,album_name,artist_id,track,disc_number,duration,suffix,content_type) VALUES(?,?,?,?,?,1,1,30,?,?)', (SONG_IDS[0], 'Track 1', ALBUM_IDS[0], 'Release 1', ARTIST_ID, 'wav', 'audio/wav'))
        clone.commit()
    os.chmod(database, 0o600)
    process = None
    client = None

    def launch(label):
        nonlocal process, client
        handshake.unlink(missing_ok=True)
        log = open(output / f'{label}.log', 'w')
        defines = dict(NAVIS_UPDATE_CHANNEL='dev', NAVIS_APP_ID_SUFFIX='.dev', NAVIS_APP_NAME='Navis Artist Diagnostics', NAVIS_SYNC_DIAGNOSTICS='true', NAVIS_SYNC_DIAGNOSTICS_MUTED='true', NAVIS_SYNC_DIAGNOSTICS_MODE='clone', NAVIS_SYNC_DIAGNOSTICS_HANDSHAKE=str(handshake), NAVIS_SYNC_DIAGNOSTICS_ROOT=str(output), NAVIS_SYNC_DIAGNOSTICS_DB_PATH=str(database), NAVIS_SYNC_DIAGNOSTICS_CREDENTIAL_PATH=str(credential))
        process = subprocess.Popen(['flutter', 'run', '-d', 'linux', '--profile', *[f'--dart-define={key}={value}' for key, value in defines.items()]], cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
        log.close()
        def ready():
            if process.poll() is not None:
                raise RuntimeError(f'App exited; inspect {label}.log')
            return handshake.exists() and handshake.stat().st_size > 0
        wait_until(ready, timeout=240)
        client = json.loads(handshake.read_text())
        api('/v1/health')
        api('/v1/diagnostics/overrides', {'networkType': 'wifi', 'automaticSyncAllowed': False})
        api('/v1/presentation/onboarding/complete', {})
        api('/v1/presentation/navigate', {'location': f'/library/artists/{ARTIST_ID}'})
        wait_until(lambda: api('/v1/playback/bootstrap/status').get('handlerReady'), timeout=60)
        api('/v1/playback/volume', {'value': 0})

    def api(route, body=None):
        request = urllib.request.Request(f'http://127.0.0.1:{client["port"]}{route}', data=None if body is None else json.dumps(body).encode(), headers={'Authorization': f'Bearer {client["token"]}', 'Content-Type': 'application/json'})
        with urllib.request.urlopen(request, timeout=40) as response:
            return json.load(response)

    def terminal():
        result = api('/v1/artists/playback/status')
        return result if result['stage'] in ('completed', 'failed', 'cancelled') else None

    def saved_queue():
        with sqlite3.connect(f'file:{database}?mode=ro', uri=True) as clone:
            return [row[0] for row in clone.execute('SELECT song_id FROM play_queue_items ORDER BY sort_order')]

    def screenshot(label):
        result = api('/v1/presentation/screenshot', {'label': label})
        (output / f'{label}-capture.json').write_text(json.dumps(result, indent=2))

    def stop():
        nonlocal process
        if process is None:
            return
        try:
            api('/v1/shutdown', {})
            process.wait(timeout=15)
        except Exception:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        process = None

    results = {}
    try:
        launch('complete')
        api('/v1/presentation/artist-action', {'action': 'play'})
        initial = wait_until(lambda: state
                             if (state := api('/v1/playback/status')).get('songId') == SONG_IDS[0]
                             and state.get('playing') and state.get('playerPositionMs', 0) > 200
                             else None, timeout=10)
        loading = api('/v1/artists/playback/status')
        assert loading['stage'] in ('loading', 'committing'), loading
        assert saved_queue() == SONG_IDS[:1], saved_queue()
        screenshot('artist-background-loading')
        wait_until(lambda: len(saved_queue()) > 1)
        grown = api('/v1/playback/status')
        assert grown['songId'] == SONG_IDS[0] and grown['playing'], grown
        assert grown.get('playerPositionMs', 0) > initial['playerPositionMs'], grown
        results['backgroundStart'] = {
            'startedBeforeHydrationFinished': True,
            'firstQueueTracks': 1,
            'queueGrewWithoutRestart': True,
        }
        result = wait_until(terminal)
        assert result['stage'] == 'completed' and result['availableTracks'] == 3, result
        wait_until(lambda: saved_queue() == SONG_IDS)
        wait_until(lambda: api('/v1/playback/status').get('playing') and api('/v1/playback/status').get('playerPositionMs', 0) > 200)
        results['complete'] = result
        Handler.artist_delay = 0.3
        Handler.album_delay = 0.5
        api('/v1/playback/queue-index', {'index': 2})
        remote = wait_until(lambda: state
                            if (state := api('/v1/playback/status')).get('songId') == SONG_IDS[2] and state.get('playing')
                            and state.get('playerPositionMs', 0) > 200 else None)
        assert remote.get('sourceKind') in ('directStream', 'lockCachedStream'), remote
        results['remote'] = {'sourceKind': remote['sourceKind'], 'positionAdvanced': True}
        api('/v1/artists/playback', {'command': 'prepare', 'artistId': ARTIST_ID, 'action': 'add'})
        result = wait_until(terminal)
        assert result['stage'] == 'completed', result
        wait_until(lambda: saved_queue() == SONG_IDS + SONG_IDS)
        results['append'] = {'preservedOccurrences': 6}
        api('/v1/presentation/artist-action', {'action': 'shuffle'})
        result = wait_until(terminal)
        assert result['stage'] == 'completed', result
        wait_until(lambda: sorted(saved_queue()) == sorted(SONG_IDS))
        results['shuffle'] = result
        stop()
        with sqlite3.connect(database) as clone:
            assert clone.execute('SELECT COUNT(*) FROM songs WHERE album_id IN (?,?,?)', ALBUM_IDS).fetchone()[0] == 3
            clone.execute('DELETE FROM songs WHERE id=?', (SONG_IDS[2],))
            clone.execute('UPDATE albums SET songs_hydrated=0 WHERE id=?', (ALBUM_IDS[2],))
            clone.commit()
        Handler.incomplete = True
        launch('partial-restart')
        api('/v1/presentation/artist-action', {'action': 'play'})
        result = wait_until(terminal)
        assert result['stage'] == 'completed' and result['availableTracks'] == 2, result
        wait_until(lambda: saved_queue() == SONG_IDS[:2])
        screenshot('artist-partial-automatic')
        results['partialAutomatic'] = result
        Handler.incomplete = False
        api('/v1/presentation/artist-action', {'action': 'play'})
        result = wait_until(terminal)
        assert result['stage'] == 'completed' and result['availableTracks'] == 3, result
        wait_until(lambda: saved_queue() == SONG_IDS)
        results['recovered'] = result
        screenshot('artist-complete')
        stop()
        launch('clean-restart')
        wait_until(lambda: saved_queue() == SONG_IDS)
        results['restart'] = {'persistedTracks': len(saved_queue())}
        Handler.expanded = True
        ALBUMS[0]['songCount'] = 2
        api('/v1/presentation/artist-action', {'action': 'play'})
        expanded = wait_until(terminal)
        assert expanded['stage'] == 'completed' and expanded['availableTracks'] == 4, expanded
        wait_until(lambda: saved_queue() == [SONG_IDS[0], EXTRA_SONG['id'], *SONG_IDS[1:]])
        results['expandedRelease'] = expanded
        api('/v1/diagnostics/overrides', {'networkType': 'offline', 'automaticSyncAllowed': False})
        with sqlite3.connect(database) as clone:
            clone.execute('DELETE FROM cached_tracks WHERE song_id=?', (SONG_IDS[2],))
            clone.commit()
        api('/v1/presentation/artist-action', {'action': 'play'})
        offline = wait_until(terminal)
        assert offline['stage'] == 'completed' and offline['unavailableTracks'] > 0, offline
        results['offline'] = offline
        api('/v1/presentation/artist-action', {'action': 'queue'})
        screenshot('artist-offline-queue')
        (output / 'results.json').write_text(json.dumps(results, indent=2))
        print(f'Artist playback diagnostics passed. Evidence: {output}')
    finally:
        stop()
        server.shutdown()


if __name__ == '__main__':
    main()
