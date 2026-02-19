import 'package:drift/drift.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/play_queue_items_table.dart';
import 'package:navis/src/database/tables/play_queue_table.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/database/tables/songs_table.dart';

part 'play_queue_dao.g.dart';

@DriftAccessor(tables: [PlayQueueTable, PlayQueueItemsTable, SongsTable])
class PlayQueueDao extends DatabaseAccessor<NavisDatabase>
    with _$PlayQueueDaoMixin {
  PlayQueueDao(super.db);

  static const int primaryQueueId = 1;

  Stream<PlayQueueTableData?> watchQueueState() {
    final query = select(playQueueTable)
      ..where((table) => table.id.equals(primaryQueueId))
      ..limit(1);
    return query.watchSingleOrNull();
  }

  Stream<List<SongsTableData>> watchQueueItems() {
    final query =
        select(songsTable).join([
            innerJoin(
              playQueueItemsTable,
              playQueueItemsTable.songId.equalsExp(songsTable.id),
            ),
          ])
          ..where(playQueueItemsTable.queueId.equals(primaryQueueId))
          ..orderBy([OrderingTerm.asc(playQueueItemsTable.sortOrder)]);

    return query.watch().map(
      (rows) => rows.map((row) => row.readTable(songsTable)).toList(),
    );
  }

  Future<void> saveQueue({
    int? currentIndex,
    required List<String> songIds,
    ShuffleMode shuffleMode = ShuffleMode.off,
    RepeatMode repeatMode = RepeatMode.off,
    int positionMs = 0,
  }) async {
    await transaction(() async {
      await into(playQueueTable).insertOnConflictUpdate(
        PlayQueueTableCompanion.insert(
          id: Value(primaryQueueId),
          currentIndex: Value(currentIndex),
          shuffleMode: Value(shuffleMode),
          repeatMode: Value(repeatMode),
          positionMs: Value(positionMs),
          updatedAt: DateTime.now(),
        ),
      );

      await (delete(
        playQueueItemsTable,
      )..where((table) => table.queueId.equals(primaryQueueId))).go();

      if (songIds.isNotEmpty) {
        await batch((batch) {
          for (var index = 0; index < songIds.length; index++) {
            batch.insert(
              playQueueItemsTable,
              PlayQueueItemsTableCompanion.insert(
                queueId: primaryQueueId,
                songId: songIds[index],
                sortOrder: index,
              ),
            );
          }
        });
      }
    });
  }

  Future<void> clearQueue() async {
    await transaction(() async {
      await (delete(
        playQueueItemsTable,
      )..where((table) => table.queueId.equals(primaryQueueId))).go();
      await (delete(
        playQueueTable,
      )..where((table) => table.id.equals(primaryQueueId))).go();
    });
  }
}
