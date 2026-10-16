import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';

import '../../../helpers/test_database.dart';

void main() {
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
}
