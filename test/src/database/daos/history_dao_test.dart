import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import '../../../helpers/test_database.dart';

void main() {
  group('HistoryDao', () {
    late NavisDatabase database;

    setUp(() async {
      database = NavisDatabase(NativeDatabase.memory());
      await database.libraryDao.upsertSongs(
        <SongsTableCompanion>[
          SongsTableCompanion.insert(id: 'song-1', title: 'Song 1'),
        ],
      );
    });

    tearDown(() async {
      await database.close();
    });

    test(
      'duplicate play-history inserts can be ignored safely',
      () async {
        final now = DateTime.now();
        await database
            .into(database.playHistoryTable)
            .insert(
              PlayHistoryTableCompanion.insert(songId: 'song-1', playedAt: now),
            );
        await database
            .into(database.playHistoryTable)
            .insert(
              PlayHistoryTableCompanion.insert(songId: 'song-1', playedAt: now),
              mode: InsertMode.insertOrIgnore,
            );

        final rows = await database.select(database.playHistoryTable).get();
        expect(rows, hasLength(1));
      },
      skip: !sqliteAvailable,
    );
  });
}
