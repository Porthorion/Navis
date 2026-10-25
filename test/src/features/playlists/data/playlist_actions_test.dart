import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/api/models/playlist.dart';
import 'package:navis/src/api/models/song.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/playlists/data/playlist_actions.dart';
import 'package:navis/src/features/playlists/presentation/playlist_providers.dart';
import 'package:navis/src/providers/app_providers.dart';

import '../../../../helpers/test_database.dart';

class _MockApi extends Mock implements SubsonicApiClient;

const _playlist = PlaylistsTableData(isLocal: false, id: 'p', name: 'Mix');
const _response = Playlist(id: 'p', name: 'Mix');

void main() {
  late _MockApi api;
  late ProviderContainer container;
  late PlaylistActions actions;
  late int headerSyncs;
  late int detailSyncs;

  setUp(() {
    api = _MockApi();
    headerSyncs = 0;
    detailSyncs = 0;
    container = ProviderContainer(
      overrides: [
        subsonicApiProvider.overrideWithValue(api),
        playlistSyncProvider.overrideWith((ref) async {
          headerSyncs++;
        }),
        playlistDetailSyncProvider.overrideWith((ref, id) async {
          detailSyncs++;
        }),
      ],
    );
    container.listen(playlistSyncProvider, (_, _) {});
    container.listen(playlistDetailSyncProvider('p'), (_, _) {});
    actions = container.read(playlistActionsProvider);
    addTearDown(container.dispose);
  });

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  test('create trims names, refreshes headers and returns server ID', () async {
    when(() => api.createPlaylist('New', songIds: ['a']))
        .thenAnswer((_) async => _response);
    await flush();
    expect(await actions.create('  New  ', ['a'], onServer: true), 'p');
    await flush();
    expect(headerSyncs, 2);
    verify(() => api.createPlaylist('New', songIds: ['a'])).called(1);
  });

  test('server creation fails visibly when offline', () async {
    final offline = ProviderContainer(
      overrides: [subsonicApiProvider.overrideWithValue(null)],
    );
    addTearDown(offline.dispose);
    await expectLater(
      offline.read(playlistActionsProvider).create('New', [], onServer: true),
      throwsStateError,
    );
  });

  test('create propagates server failure', () async {
    when(() => api.createPlaylist('New', songIds: []))
        .thenThrow(StateError('failed'));
    await expectLater(
      actions.create('New', [], onServer: true),
      throwsStateError,
    );
  });

  test('blank create and rename names fail before contacting server', () async {
    for (final onServer in [true, false]) {
      await expectLater(
        actions.create('  ', [], onServer: onServer),
        throwsArgumentError,
      );
    }
    await expectLater(actions.rename(_playlist, '  '), throwsArgumentError);
    verifyZeroInteractions(api);
  });

  test('rename trims the name', () async {
    when(() => api.updatePlaylist(id: 'p', name: 'New'))
        .thenAnswer((_) async => _response);
    await actions.rename(_playlist, ' New ');
    verify(() => api.updatePlaylist(id: 'p', name: 'New')).called(1);
  });

  test(
    'all device actions work offline and leave sync and API untouched',
    () async {
      final database = createTestDatabase();
      addTearDown(database.close);
      final local = ProviderContainer(
        overrides: withTestDatabase(
          database,
          overrides: [
            subsonicApiProvider.overrideWithValue(api),
            playlistSyncProvider.overrideWith(
              (ref) => throw StateError('unexpected sync'),
            ),
            playlistDetailSyncProvider.overrideWith(
              (ref, id) => throw StateError('unexpected detail'),
            ),
          ],
        ),
      );
      addTearDown(local.dispose);
      await database.libraryDao.upsertSongs([
        SongsTableCompanion.insert(
          id: 'a',
          title: 'A',
          duration: const Value(5),
        ),
        SongsTableCompanion.insert(
          id: 'b',
          title: 'B',
          duration: const Value(10),
        ),
      ]);
      final a = local.read(playlistActionsProvider);
      final id = await a.create(' Mix ', ['a', 'a'], onServer: false);
      final p = (await database.playlistDao.watchPlaylistById(id).first)!;
      expect(p.name, 'Mix');
      expect(await a.addSongs(p, ['b', 'missing']), 1);
      expect(
        (await database.playlistDao.watchPlaylistSongs(id).first).map(
          (s) => s.id,
        ),
        ['a', 'a', 'b'],
      );
      final ids = ['a', 'a', 'b'];
      await a.reorder(p, ids, 1, 2);
      expect(ids, ['a', 'a', 'b']);
      await a.removeAt(p, ['a', 'b', 'a'], 2);
      await a.rename(p, ' Renamed ');
      final updated = (await database.playlistDao.watchPlaylistById(id).first)!;
      expect(
        (updated.name, updated.songCount, updated.duration),
        ('Renamed', 2, 15),
      );
      expect(
        (await database.playlistDao.watchPlaylistSongs(id).first).map(
          (s) => s.id,
        ),
        ['a', 'b'],
      );
      final offline = ProviderContainer(
        overrides: withTestDatabase(
          database,
          overrides: [subsonicApiProvider.overrideWithValue(null)],
        ),
      );
      addTearDown(offline.dispose);
      await offline.read(playlistActionsProvider).rename(p, 'Offline');
      await offline.read(playlistActionsProvider).delete(p);
      expect(await database.playlistDao.watchPlaylistById(id).first, isNull);
      expect(await database.playlistDao.watchPlaylistSongs(id).first, isEmpty);
      verifyZeroInteractions(api);
    },
    skip: !sqliteAvailable,
  );

  test('rename and delete call the server and refresh headers', () async {
    when(() => api.updatePlaylist(id: 'p', name: 'New'))
        .thenAnswer((_) async => _response);
    when(() => api.deletePlaylist('p')).thenAnswer((_) async {});
    await flush();
    await actions.rename(_playlist, 'New');
    await flush();
    expect(headerSyncs, 2);
    expect(detailSyncs, 1);
    await actions.delete(_playlist);
    await flush();
    expect(headerSyncs, 3);
    verify(() => api.updatePlaylist(id: 'p', name: 'New')).called(1);
    verify(() => api.deletePlaylist('p')).called(1);
  });

  /// Stateful server: [maxAdd] caps how many `songIdsToAdd` one call honours
  /// (Navidrome 0.64 ignores 2+ ids).
  List<String> stubServer(List<String> songs, {required int maxAdd}) {
    when(
      () => api.updatePlaylist(
        id: 'p',
        songIdsToAdd: any(named: 'songIdsToAdd'),
      ),
    ).thenAnswer((i) async {
      final ids = i.namedArguments[#songIdsToAdd] as List<String>;
      if (ids.length <= maxAdd) songs.addAll(ids);
      return _response;
    });
    when(() => api.getPlaylist('p')).thenAnswer(
      (_) async => Playlist(
        id: 'p',
        name: 'Mix',
        entries: [for (final id in songs) Song(id: id, title: id)],
      ),
    );
    return songs;
  }

  test('album add falls back to one id per request', () async {
    final server = stubServer(['x'], maxAdd: 1);
    await flush();
    expect(await actions.addSongs(_playlist, ['a', 'b', 'a']), 0);
    await flush();
    expect(server, ['x', 'a', 'b', 'a']);
    expect(headerSyncs, 2);
    expect(detailSyncs, 2);
  });

  test('add stays one update when the server honours multi-id', () async {
    final server = stubServer(['x'], maxAdd: 99);
    await flush();
    expect(await actions.addSongs(_playlist, ['a', 'b']), 0);
    expect(server, ['x', 'a', 'b']);
    verify(
      () => api.updatePlaylist(id: 'p', songIdsToAdd: ['a', 'b']),
    ).called(1);
    verifyNever(() => api.updatePlaylist(id: 'p', songIdsToAdd: ['a']));
    // One read before (baseline) and one after.
    verify(() => api.getPlaylist('p')).called(2);
  });

  test('add never reports success when the server drops every add', () async {
    final server = stubServer(['x'], maxAdd: 0);
    await flush();
    expect(await actions.addSongs(_playlist, ['a', 'b']), 2);
    expect(server, ['x']);
  });

  test('add reports the songs the server still lacks', () async {
    var calls = 0;
    final server = ['x'];
    when(
      () => api.updatePlaylist(
        id: 'p',
        songIdsToAdd: any(named: 'songIdsToAdd'),
      ),
    ).thenAnswer((i) async {
      final ids = i.namedArguments[#songIdsToAdd] as List<String>;
      if (ids.length == 1 && ++calls == 1) server.addAll(ids);
      return _response;
    });
    when(() => api.getPlaylist('p')).thenAnswer(
      (_) async => Playlist(
        id: 'p',
        name: 'Mix',
        entries: [for (final id in server) Song(id: id, title: id)],
      ),
    );
    await flush();
    expect(await actions.addSongs(_playlist, ['a', 'b', 'c']), 2);
    expect(server, ['x', 'a']);
  });

  test('remove uses the occurrence index and refreshes detail', () async {
    when(() => api.updatePlaylist(id: 'p', songIndexesToRemove: [1]))
        .thenAnswer((_) async => _response);
    await flush();
    await actions.removeAt(_playlist, ['a', 'a', 'b'], 1);
    await flush();
    expect(headerSyncs, 1);
    expect(detailSyncs, 2);
    verify(() => api.updatePlaylist(id: 'p', songIndexesToRemove: [1]))
        .called(1);
  });

  test('reorder replaces atomically, preserves duplicates and input', () async {
    when(
      () => api.replacePlaylistSongs(playlistId: 'p', songIds: ['a', 'b', 'a']),
    ).thenAnswer((_) async {});
    await flush();
    final ids = ['a', 'a', 'b'];
    await actions.reorder(_playlist, ids, 1, 2);
    await flush();
    expect(ids, ['a', 'a', 'b']);
    expect(headerSyncs, 1);
    expect(detailSyncs, 2);
    verify(
      () => api.replacePlaylistSongs(playlistId: 'p', songIds: ['a', 'b', 'a']),
    ).called(1);
  });

  test('unchanged reorder does not call the server', () async {
    await actions.reorder(_playlist, ['a'], 0, 0);
    verifyZeroInteractions(api);
  });

  for (final (label, operation)
      in <(String, Future<void> Function(PlaylistActions, PlaylistsTableData))>[
        ('rename', (a, p) => a.rename(p, 'New')),
        ('delete', (a, p) => a.delete(p)),
        (
          'add',
          (a, p) async {
            await a.addSongs(p, ['a']);
          },
        ),
        ('remove', (a, p) => a.removeAt(p, ['a', 'b'], 0)),
        ('reorder', (a, p) => a.reorder(p, ['a', 'b'], 0, 1)),
      ]) {
    test('$label throws server failures to its caller', () async {
      final error = StateError('server failed');
      when(
        () => api.updatePlaylist(
          id: any(named: 'id'),
          name: any(named: 'name'),
          songIdsToAdd: any(named: 'songIdsToAdd'),
          songIndexesToRemove: any(named: 'songIndexesToRemove'),
        ),
      ).thenThrow(error);
      when(() => api.getPlaylist(any())).thenThrow(error);
      when(() => api.deletePlaylist(any())).thenThrow(error);
      when(
        () => api.replacePlaylistSongs(
          playlistId: any(named: 'playlistId'),
          songIds: any(named: 'songIds'),
        ),
      ).thenThrow(error);
      await flush();
      await expectLater(operation(actions, _playlist), throwsA(same(error)));
      await flush();
      // A failed add may have added some songs, so it refreshes too.
      expect(headerSyncs, label == 'add' ? 2 : 1);
      expect(detailSyncs, label == 'reorder' || label == 'add' ? 2 : 1);
    });

    test('$label fails visibly when offline', () async {
      final offline = ProviderContainer(
        overrides: [subsonicApiProvider.overrideWithValue(null)],
      );
      addTearDown(offline.dispose);
      await expectLater(
        operation(offline.read(playlistActionsProvider), _playlist),
        throwsStateError,
      );
    });
  }
}
