import 'package:drift/drift.dart';
import 'package:navis/src/database/tables/play_queue_table.dart';
import 'package:navis/src/database/tables/songs_table.dart';

class PlayQueueItemsTable extends Table {
  @override
  String get tableName => 'play_queue_items';

  IntColumn get queueId =>
      integer().references(PlayQueueTable, #id, onDelete: KeyAction.cascade)();

  TextColumn get songId =>
      text().references(SongsTable, #id, onDelete: KeyAction.cascade)();

  IntColumn get sortOrder => integer()();

  /// While shuffle is on, the row's position in the unshuffled queue;
  /// [sortOrder] is the play order. Null when shuffle is off, and in queues
  /// saved before schema v88.
  IntColumn get originalOrder => integer().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {queueId, sortOrder};
}
