import 'package:drift/drift.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/play_queue_items_table.dart';
import 'package:navis/src/database/tables/play_queue_table.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/database/tables/songs_table.dart';

part 'play_queue_dao.g.dart';

@DriftAccessor(tables: [PlayQueueTable, PlayQueueItemsTable, SongsTable])
class PlayQueueDao extends DatabaseAccessor<NavisDatabase>
    with NavisDaoTransactions, _$PlayQueueDaoMixin {
  new(super.attachedDatabase);

  static const int primaryQueueId = 1;

  Future<PlayQueueTableData?> getQueueState() {
    final query = select(playQueueTable)
      ..where((table) => table.id.equals(primaryQueueId))
      ..limit(1);
    return query.getSingleOrNull();
  }

  JoinedSelectStatement<HasResultSet, dynamic> _queueRowsQuery() =>
      select(songsTable).join([
          innerJoin(
            playQueueItemsTable,
            playQueueItemsTable.songId.equalsExp(songsTable.id),
          ),
        ])
        ..where(playQueueItemsTable.queueId.equals(primaryQueueId))
        ..orderBy([OrderingTerm.asc(playQueueItemsTable.sortOrder)]);

  List<SongsTableData> _queueSongs(List<TypedResult> rows) =>
      rows.map((row) => row.readTable(songsTable)).toList();

  Stream<List<SongsTableData>> watchQueueItems() =>
      _queueRowsQuery().watch().map(_queueSongs);

  Future<List<SongsTableData>> getQueueItems() =>
      _queueRowsQuery().get().then(_queueSongs);

  /// Saved queue rows in play order, each with its unshuffled position
  /// (null when shuffle was off or the queue predates schema v88).
  Future<List<({SongsTableData song, int? originalOrder})>> getQueueEntries() {
    return _queueRowsQuery().get().then(
      (rows) => rows
          .map(
            (row) => (
              song: row.readTable(songsTable),
              originalOrder: row.readTable(playQueueItemsTable).originalOrder,
            ),
          )
          .toList(),
    );
  }

  /// Replaces the saved queue. [songIds] is the play order; [originalOrder],
  /// when shuffle is on, gives each row's unshuffled position.
  Future<void> saveQueue({
    int? currentIndex,
    required List<String> songIds,
    ShuffleMode shuffleMode = ShuffleMode.off,
    RepeatMode repeatMode = RepeatMode.off,
    int positionMs = 0,
    List<int>? originalOrder,
  }) async {
    assert(
      originalOrder == null || originalOrder.length == songIds.length,
      'originalOrder must have one entry per song',
    );
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
                originalOrder: Value(originalOrder?[index]),
              ),
            );
          }
        });
      }
    });
  }

  Future<void> savePlaybackState({
    int? currentIndex,
    ShuffleMode shuffleMode = ShuffleMode.off,
    RepeatMode repeatMode = RepeatMode.off,
    int positionMs = 0,
  }) {
    return into(playQueueTable).insertOnConflictUpdate(
      PlayQueueTableCompanion.insert(
        id: Value(primaryQueueId),
        currentIndex: Value(currentIndex),
        shuffleMode: Value(shuffleMode),
        repeatMode: Value(repeatMode),
        positionMs: Value(positionMs),
        updatedAt: DateTime.now(),
      ),
    );
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
