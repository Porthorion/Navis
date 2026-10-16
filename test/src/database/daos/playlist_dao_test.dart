import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';

import '../../../helpers/test_database.dart';

void main() {
  test('watchPlaylists mixes local and server names ignoring case', () async {
    final database = createTestDatabase();
    addTearDown(database.close);
    await database.playlistDao.upsertPlaylists([
      PlaylistsTableCompanion.insert(id: 'server:z', name: 'Zulu'),
      PlaylistsTableCompanion.insert(
        id: 'local:a',
        name: 'alpha',
        isLocal: const Value(true),
      ),
      PlaylistsTableCompanion.insert(id: 'server:b', name: 'Bravo'),
    ]);
    expect(
      (await database.playlistDao.watchPlaylists().first).map((p) => p.id),
      ['local:a', 'server:b', 'server:z'],
    );
  }, skip: !sqliteAvailable);

  for (final serverIds in <List<String>>[
    [],
    ['server:kept'],
  ]) {
    test(
      'server reconciliation preserves device entries, serverIds=$serverIds',
      () async {
        final database = createTestDatabase();
        addTearDown(database.close);
        await database
            .into(database.songsTable)
            .insert(SongsTableCompanion.insert(id: 'song', title: 'Song'));
        await database.customStatement(
          "INSERT INTO playlists (id, name, is_local) VALUES ('local:list', 'Device list', 1), ('local:empty', 'Empty device list', 1), ('server:stale', 'Stale', 0), ('server:kept', 'Old name', 0)",
        );
        await database.customStatement(
          "INSERT INTO playlist_songs VALUES ('local:list', 'song', 0), ('local:list', 'song', 1), ('server:stale', 'song', 0), ('server:kept', 'song', 0)",
        );
        await database.playlistDao.reconcileServerPlaylists([
          for (final id in serverIds)
            PlaylistsTableCompanion.insert(id: id, name: 'Server list'),
        ], serverIds);
        expect(
          (await database.select(database.playlistsTable).get()).map(
            (p) => p.id,
          ),
          unorderedEquals(['local:list', 'local:empty', ...serverIds]),
        );
        expect(
          (await database.playlistDao.watchPlaylistSongs('local:list').first)
              .map((s) => s.id),
          ['song', 'song'],
        );
        expect(
          await database.playlistDao.watchPlaylistSongs('server:stale').first,
          isEmpty,
        );
        expect(
          await database.playlistDao.watchPlaylistSongs('server:kept').first,
          hasLength(serverIds.isEmpty ? 0 : 1),
        );
        expect(await database.select(database.songsTable).get(), hasLength(1));
        expect(
          (await database.playlistDao.getServerPlaylists()).map((p) => p.id),
          unorderedEquals(serverIds),
        );
      },
      skip: !sqliteAvailable,
    );
  }

  test(
    'playback cleanup keeps songs that device playlists still hold',
    () async {
      final database = createTestDatabase();
      addTearDown(database.close);
      // Both songs are confirmed missing on the server.
      await database.customStatement(
        "INSERT INTO songs (id, title, server_deleted_at) VALUES "
        "('in-device', 'Device song', 1), ('server-only', 'Server song', 1)",
      );
      await database.customStatement(
        "INSERT INTO playlists (id, name, is_local) VALUES "
        "('local:list', 'Device list', 1), ('server:list', 'Server list', 0)",
      );
      await database.customStatement(
        "INSERT INTO playlist_songs VALUES ('local:list', 'in-device', 0), "
        "('server:list', 'server-only', 0)",
      );

      await database.libraryDao.deleteLocalOnlySong('in-device');
      await database.libraryDao.deleteLocalOnlySong('server-only');

      expect(
        (await database.playlistDao.watchPlaylistSongs('local:list').first).map(
          (s) => s.id,
        ),
        ['in-device'],
      );
      expect(
        (await database.select(database.songsTable).get()).map((s) => s.id),
        ['in-device'],
      );
    },
    skip: !sqliteAvailable,
  );
}
