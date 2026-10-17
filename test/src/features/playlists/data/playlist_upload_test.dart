import 'dart:async';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/api/models/playlist.dart';
import 'package:navis/src/api/models/song.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/playlists/data/playlist_actions.dart';
import 'package:navis/src/features/playlists/domain/playlist_ownership.dart';
import 'package:navis/src/features/playlists/presentation/playlist_providers.dart';
import 'package:navis/src/providers/app_providers.dart';

import '../../../../helpers/test_database.dart';

class _MockApi extends Mock implements SubsonicApiClient;

void main() {
  late _MockApi api;
  late NavisDatabase database;
  late ProviderContainer container;
  late PlaylistActions actions;
  late String localId;

  setUp(() async {
    api = _MockApi();
    when(() => api.getPlaylists()).thenAnswer((_) async => []);
    when(() => api.getPlaylist(any())).thenAnswer(
      (call) async => Playlist(
        id: call.positionalArguments.single as String,
        name: call.positionalArguments.single == 'srv2' ? 'Empty' : 'Mix',
        owner: 'me',
        entries: call.positionalArguments.single == 'srv2'
            ? []
            : const [
                Song(id: 'b', title: 'B'),
                Song(id: 'a', title: 'A'),
                Song(id: 'b', title: 'B'),
              ],
      ),
    );
    database = createTestDatabase();
    container = ProviderContainer(
      overrides: withTestDatabase(
        database,
        overrides: [
          subsonicApiProvider.overrideWithValue(api),
          playlistSyncProvider.overrideWith((ref) async {}),
        ],
      ),
    );
    await database.libraryDao.upsertSongs([
      SongsTableCompanion.insert(id: 'a', title: 'A', duration: const Value(5)),
      SongsTableCompanion.insert(
        id: 'b',
        title: 'B',
        duration: const Value(10),
      ),
    ]);
    actions = container.read(playlistActionsProvider);
    localId = await actions.create('Mix', ['b', 'a', 'b'], onServer: false);
  });
  tearDown(() async {
    container.dispose();
    await database.close();
  });

  Future<List<String>> songIds(String id) async =>
      (await database.playlistDao.watchPlaylistSongs(id).first)
          .map((s) => s.id)
          .toList();

  Future<PlaylistsTableData?> row(String id) =>
      database.playlistDao.watchPlaylistById(id).first;

  for (final edit in ['rename', 'add', 'reorder']) {
    test('delayed create preserves device $edit during upload', () async {
      final started = Completer<void>();
      final gate = Completer<Playlist>();
      when(() => api.createPlaylist(any(), songIds: any(named: 'songIds')))
          .thenAnswer((_) {
            started.complete();
            return gate.future;
          });
      final pending = actions.uploadToServer(localId);
      await started.future;
      if (edit == 'rename') {
        await database.playlistDao.renamePlaylist(localId, 'Edited');
      } else {
        await database.playlistDao.setLocalPlaylistSongs(
          localId,
          edit == 'add' ? ['b', 'a', 'b', 'a'] : ['a', 'b', 'b'],
        );
      }
      gate.complete(const Playlist(id: 'srv1', name: 'Mix'));
      final result = await pending;
      expect(result.deviceCopyKept, isTrue);
      expect((await row(localId))?.name, edit == 'rename' ? 'Edited' : 'Mix');
      expect(await songIds(localId), switch (edit) {
        'add' => ['b', 'a', 'b', 'a'],
        'reorder' => ['a', 'b', 'b'],
        _ => ['b', 'a', 'b'],
      });
      expect(await songIds('srv1'), ['b', 'a', 'b']);
      expect(container.read(playlistMovedToServerProvider), isEmpty);
    });
  }

  test('saving a kept device copy updates the same server playlist', () async {
    var server = const Playlist(
      id: 'srv1',
      name: 'Mix',
      entries: [
        Song(id: 'b', title: 'B'),
        Song(id: 'a', title: 'A'),
        Song(id: 'b', title: 'B'),
      ],
    );
    when(() => api.createPlaylist(any(), songIds: any(named: 'songIds')))
        .thenAnswer((_) async {
          await database.playlistDao.renamePlaylist(localId, 'Edited');
          await database.playlistDao.setLocalPlaylistSongs(localId, [
            'a',
            'b',
            'a',
          ]);
          return server;
        });
    when(() => api.getPlaylist('srv1')).thenAnswer((_) async => server);
    when(
      () => api.updatePlaylist(
        id: 'srv1',
        name: 'Edited',
        songIdsToAdd: ['a', 'b', 'a'],
        songIndexesToRemove: [0, 1, 2],
      ),
    ).thenAnswer((_) async {
      return server = const Playlist(
        id: 'srv1',
        name: 'Edited',
        entries: [
          Song(id: 'a', title: 'A'),
          Song(id: 'b', title: 'B'),
          Song(id: 'a', title: 'A'),
        ],
      );
    });
    expect((await actions.uploadToServer(localId)).deviceCopyKept, isTrue);
    final result = await actions.uploadToServer(localId);
    verify(() => api.createPlaylist(any(), songIds: any(named: 'songIds')))
        .called(1);
    expect(result.deviceCopyKept, isFalse);
    expect(server.name, 'Edited');
    expect(server.entries.map((song) => song.id), ['a', 'b', 'a']);
    expect(await row(localId), isNull);
    expect((await row('srv1'))?.name, 'Edited');
    expect(await songIds('srv1'), ['a', 'b', 'a']);
  });

  test('bodyless success resolves only a new matching id', () async {
    var reads = 0;
    when(() => api.getPlaylists()).thenAnswer(
      (_) async => [
        const Playlist(id: 'existing', name: 'Mix'),
        if (reads++ > 0) const Playlist(id: 'srv1', name: 'Mix'),
      ],
    );
    when(() => api.createPlaylist(any(), songIds: any(named: 'songIds')))
        .thenAnswer((_) async => const Playlist(id: 'created', name: 'Mix'));
    await actions.uploadToServer(localId);
    expect(await row('srv1'), isNotNull);
    expect(await row(localId), isNull);
    expect(container.read(playlistMovedToServerProvider)[localId], 'srv1');
  });

  test(
    'commit then timeout resolves on retry without another create',
    () async {
      var committed = false;
      var failRead = true;
      when(() => api.getPlaylists()).thenAnswer((_) async {
        if (committed && failRead) {
          failRead = false;
          throw const SubsonicConnectionException('offline');
        }
        return [if (committed) const Playlist(id: 'srv1', name: 'Mix')];
      });
      when(() => api.createPlaylist(any(), songIds: any(named: 'songIds')))
          .thenAnswer((_) async {
            committed = true;
            throw const SubsonicConnectionException('timeout');
          });
      await expectLater(
        actions.uploadToServer(localId),
        throwsA(isA<SubsonicConnectionException>()),
      );
      expect(await row(localId), isNotNull);
      await actions.uploadToServer(localId);
      expect(await row(localId), isNull);
      verify(() => api.createPlaylist(any(), songIds: any(named: 'songIds')))
          .called(1);
    },
  );

  test('ambiguous bodyless result keeps device copy on retry', () async {
    var reads = 0;
    when(() => api.getPlaylists()).thenAnswer(
      (_) async => [
        if (reads++ > 0) ...const [
          Playlist(id: 'x', name: 'Mix'),
          Playlist(id: 'y', name: 'Mix'),
        ],
      ],
    );
    when(() => api.createPlaylist(any(), songIds: any(named: 'songIds')))
        .thenAnswer((_) async => const Playlist(id: 'created', name: 'Mix'));
    await expectLater(actions.uploadToServer(localId), throwsStateError);
    await expectLater(actions.uploadToServer(localId), throwsStateError);
    expect(await row(localId), isNotNull);
    verify(() => api.createPlaylist(any(), songIds: any(named: 'songIds')))
        .called(1);
  });

  test(
    'a definite Subsonic rejection does not infer success by name',
    () async {
      when(() => api.getPlaylists())
          .thenAnswer((_) async => const [Playlist(id: 'old', name: 'Mix')]);
      when(() => api.createPlaylist(any(), songIds: any(named: 'songIds')))
          .thenThrow(const SubsonicForbiddenException(message: 'Denied'));
      await expectLater(
        actions.uploadToServer(localId),
        throwsA(isA<SubsonicForbiddenException>()),
      );
      expect(await row(localId), isNotNull);
      verify(() => api.getPlaylists()).called(1);
    },
  );

  test(
    'readback failure retries the resolved id without another create',
    () async {
      var reads = 0;
      when(() => api.createPlaylist(any(), songIds: any(named: 'songIds')))
          .thenAnswer((_) async => const Playlist(id: 'srv1', name: 'Mix'));
      when(() => api.getPlaylist('srv1')).thenAnswer((_) async {
        if (reads++ == 0) throw const SubsonicConnectionException('offline');
        return const Playlist(
          id: 'srv1',
          name: 'Mix',
          entries: [Song(id: 'a', title: 'A')],
        );
      });
      await expectLater(
        actions.uploadToServer(localId),
        throwsA(isA<SubsonicConnectionException>()),
      );
      expect(await row(localId), isNotNull);
      await actions.uploadToServer(localId);
      expect(await row(localId), isNull);
      verify(() => api.createPlaylist(any(), songIds: any(named: 'songIds')))
          .called(1);
    },
  );

  test(
    'an upload replacement survives reconciliation of an older fetch',
    () async {
      final version = await database.playlistDao.getMutationVersion();
      when(() => api.createPlaylist(any(), songIds: any(named: 'songIds')))
          .thenAnswer((_) async => const Playlist(id: 'srv1', name: 'Mix'));
      await actions.uploadToServer(localId);
      await database.playlistDao.reconcileServerPlaylists(
        [],
        [],
        mutationVersion: version,
      );
      expect(await row('srv1'), isNotNull);
      expect(await songIds('srv1'), ['b', 'a', 'b']);
    },
  );

  test('partial acceptance caches actual server entries', () async {
    when(() => api.createPlaylist(any(), songIds: any(named: 'songIds')))
        .thenAnswer((_) async => const Playlist(id: 'srv1', name: 'Mix'));
    when(() => api.getPlaylist('srv1')).thenAnswer(
      (_) async => const Playlist(
        id: 'srv1',
        name: 'Mix',
        entries: [Song(id: 'a', title: 'A')],
      ),
    );
    final result = await actions.uploadToServer(localId);
    expect((result.kept, result.total), (1, 3));
    expect(await songIds('srv1'), ['a']);
    expect((await row('srv1'))?.songCount, 1);
    expect(await row(localId), isNull);
  });

  test(
    'upload creates the server playlist and replaces the device row',
    () async {
      when(() => api.createPlaylist('Mix', songIds: ['b', 'a', 'b']))
          .thenAnswer(
            (_) async => const Playlist(id: 'srv1', name: 'Mix', owner: 'me'),
          );

      final newId = await actions.uploadToServer(localId);

      expect(newId.serverId, 'srv1');
      expect(newId.deviceCopyKept, isFalse);
      expect((newId.kept, newId.total), (3, 3));
      verify(() => api.createPlaylist('Mix', songIds: ['b', 'a', 'b']))
          .called(1);
      expect(await row(localId), isNull);
      expect(await songIds(localId), isEmpty);
      final server = (await row('srv1'))!;
      expect(
        (server.name, server.isLocal, server.songCount),
        ('Mix', false, 3),
      );
      expect(await songIds('srv1'), ['b', 'a', 'b']);
      expect((await database.libraryDao.getSongById('a'))?.duration, 5);
      expect(isOwnPlaylist(server, 'me'), isTrue);
      expect(container.read(playlistMovedToServerProvider)[localId], 'srv1');
    },
  );

  test(
    'upload keeps the device playlist when the server create fails',
    () async {
      when(() => api.createPlaylist(any(), songIds: any(named: 'songIds')))
          .thenThrow(StateError('boom'));

      await expectLater(actions.uploadToServer(localId), throwsStateError);

      expect((await row(localId))?.isLocal, isTrue);
      expect(await songIds(localId), ['b', 'a', 'b']);
      expect(container.read(playlistMovedToServerProvider), isEmpty);
    },
  );

  test('a double submit makes one create call', () async {
    final gate = Completer<Playlist>();
    when(() => api.createPlaylist(any(), songIds: any(named: 'songIds')))
        .thenAnswer((_) => gate.future);

    final first = actions.uploadToServer(localId);
    final second = actions.uploadToServer(localId);
    gate.complete(const Playlist(id: 'srv1', name: 'Mix'));

    expect((await first).serverId, 'srv1');
    expect((await second).serverId, 'srv1');
    verify(() => api.createPlaylist(any(), songIds: any(named: 'songIds')))
        .called(1);
  });

  test(
    'an empty device playlist uploads as an empty server playlist',
    () async {
      final empty = await actions.create('Empty', [], onServer: false);
      when(() => api.createPlaylist('Empty', songIds: []))
          .thenAnswer((_) async => const Playlist(id: 'srv2', name: 'Empty'));

      expect((await actions.uploadToServer(empty)).serverId, 'srv2');
      expect(await row(empty), isNull);
      expect((await row('srv2'))?.songCount, 0);
    },
  );

  test('upload refuses server playlists and an unavailable server', () async {
    when(() => api.createPlaylist(any(), songIds: any(named: 'songIds')))
        .thenAnswer((_) async => const Playlist(id: 'srv1', name: 'Mix'));
    final newId = await actions.uploadToServer(localId);
    await expectLater(actions.uploadToServer(newId.serverId), throwsStateError);

    final offline = ProviderContainer(
      overrides: withTestDatabase(
        database,
        overrides: [subsonicApiProvider.overrideWithValue(null)],
      ),
    );
    addTearDown(offline.dispose);
    final other = await actions.create('Other', [], onServer: false);
    await expectLater(
      offline.read(playlistActionsProvider).uploadToServer(other),
      throwsStateError,
    );
    expect((await row(other))?.isLocal, isTrue);
  });
}
