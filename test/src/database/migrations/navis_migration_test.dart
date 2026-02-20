import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:sqlite3/sqlite3.dart';

bool get _sqliteAvailable {
  try {
    final db = sqlite3.openInMemory();
    db.dispose();
    return true;
  } on Object {
    return false;
  }
}

void main() {
  test(
    'latest schema opens with expected user_version',
    () async {
      final database = NavisDatabase(NativeDatabase.memory());
      addTearDown(database.close);

      final pragmaRow = await database
          .customSelect('PRAGMA user_version;')
          .getSingle();

      expect(database.schemaVersion, 3);
      expect(pragmaRow.read<int>('user_version'), 3);
    },
    skip: !_sqliteAvailable,
  );

  test(
    'backfillAlbumHydrationState marks albums with songs as hydrated',
    () async {
      final database = NavisDatabase(NativeDatabase.memory());
      addTearDown(database.close);

      await database
          .into(database.albumsTable)
          .insert(
            AlbumsTableCompanion.insert(
              id: 'album-with-song',
              name: 'Album With Song',
              songsHydrated: const Value(false),
            ),
          );
      await database
          .into(database.albumsTable)
          .insert(
            AlbumsTableCompanion.insert(
              id: 'album-without-song',
              name: 'Album Without Song',
              songsHydrated: const Value(false),
            ),
          );
      await database
          .into(database.songsTable)
          .insert(
            SongsTableCompanion.insert(
              id: 'song-1',
              title: 'Song 1',
              albumId: const Value('album-with-song'),
            ),
          );

      await database.backfillAlbumHydrationState();

      final rows = await database.select(database.albumsTable).get();
      final byId = {for (final row in rows) row.id: row};
      expect(byId['album-with-song']?.songsHydrated, isTrue);
      expect(byId['album-without-song']?.songsHydrated, isFalse);
    },
    skip: !_sqliteAvailable,
  );
}
