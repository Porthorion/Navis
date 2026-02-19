import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
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
  late NavisDatabase database;

  setUp(() {
    database = NavisDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await database.close();
  });

  test(
    'creates all core tables',
    () async {
      final rows = await database
          .customSelect(
            "SELECT name FROM sqlite_master WHERE type = 'table'",
          )
          .get();

      final names = rows.map((row) => row.read<String>('name')).toSet();

      expect(names, contains('server_config'));
      expect(names, contains('artists'));
      expect(names, contains('albums'));
      expect(names, contains('songs'));
      expect(names, contains('play_queue'));
    },
    skip: !_sqliteAvailable,
  );

  test(
    'enforces foreign keys',
    () async {
      await expectLater(
        database
            .into(database.playlistSongsTable)
            .insert(
              PlaylistSongsTableCompanion.insert(
                playlistId: 'missing-playlist',
                songId: 'missing-song',
                sortOrder: 0,
              ),
            ),
        throwsA(isA<Exception>()),
      );
    },
    skip: !_sqliteAvailable,
  );

  test(
    'reactive artist stream emits after replace',
    () async {
      final emitted = database.libraryDao.watchArtists().firstWhere(
        (artists) => artists.isNotEmpty,
      );

      await database.libraryDao.replaceArtists(
        <ArtistsTableCompanion>[
          ArtistsTableCompanion.insert(
            id: 'a1',
            name: 'Artist One',
          ),
        ],
      );

      final artists = await emitted;
      expect(artists.single.id, 'a1');
      expect(artists.single.name, 'Artist One');
    },
    skip: !_sqliteAvailable,
  );

  test(
    'play queue dao persists and restores queue',
    () async {
      await database
          .into(database.songsTable)
          .insert(
            SongsTableCompanion.insert(
              id: 's1',
              title: 'Song 1',
            ),
          );

      await database.playQueueDao.saveQueue(
        currentIndex: 0,
        songIds: const <String>['s1'],
        shuffleMode: ShuffleMode.off,
        repeatMode: RepeatMode.off,
        positionMs: 4200,
      );

      final state = await database.playQueueDao.watchQueueState().firstWhere(
        (value) => value != null,
      );
      final items = await database.playQueueDao.watchQueueItems().firstWhere(
        (value) => value.isNotEmpty,
      );

      expect(state?.currentIndex, 0);
      expect(state?.positionMs, 4200);
      expect(items.single.id, 's1');
    },
    skip: !_sqliteAvailable,
  );
}
