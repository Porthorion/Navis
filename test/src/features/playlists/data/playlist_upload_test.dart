import 'dart:async';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/api/models/playlist.dart';
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

  test(
    'upload creates the server playlist and replaces the device row',
    () async {
      when(() => api.createPlaylist('Mix', songIds: ['b', 'a', 'b']))
          .thenAnswer(
            (_) async => const Playlist(id: 'srv1', name: 'Mix', owner: 'me'),
          );

      final newId = await actions.uploadToServer(localId);

      expect(newId, 'srv1');
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

    expect(await first, 'srv1');
    expect(await second, 'srv1');
    verify(() => api.createPlaylist(any(), songIds: any(named: 'songIds')))
        .called(1);
  });

  test(
    'an empty device playlist uploads as an empty server playlist',
    () async {
      final empty = await actions.create('Empty', [], onServer: false);
      when(() => api.createPlaylist('Empty', songIds: []))
          .thenAnswer((_) async => const Playlist(id: 'srv2', name: 'Empty'));

      expect(await actions.uploadToServer(empty), 'srv2');
      expect(await row(empty), isNull);
      expect((await row('srv2'))?.songCount, 0);
    },
  );

  test('upload refuses server playlists and an unavailable server', () async {
    when(() => api.createPlaylist(any(), songIds: any(named: 'songIds')))
        .thenAnswer((_) async => const Playlist(id: 'srv1', name: 'Mix'));
    final newId = await actions.uploadToServer(localId);
    await expectLater(actions.uploadToServer(newId!), throwsStateError);

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
