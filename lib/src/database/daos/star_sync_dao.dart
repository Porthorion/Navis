import 'package:drift/drift.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/star_sync_queue_table.dart';

part 'star_sync_dao.g.dart';

@DriftAccessor(tables: [StarSyncQueueTable])
class StarSyncDao extends DatabaseAccessor<NavisDatabase>
    with _$StarSyncDaoMixin {
  StarSyncDao(super.db);

  /// Queue a star/unstar operation that failed due to connectivity.
  Future<void> queueStarAction({
    required String itemId,
    required String itemType,
    required String action,
  }) {
    return transaction(() async {
      await (delete(starSyncQueueTable)..where(
            (t) => t.itemId.equals(itemId) & t.itemType.equals(itemType),
          ))
          .go();
      await into(starSyncQueueTable).insert(
        StarSyncQueueTableCompanion.insert(
          itemId: itemId,
          itemType: itemType,
          action: action,
          queuedAt: DateTime.now(),
        ),
      );
    });
  }

  /// Get all pending star/unstar operations in queue order.
  Future<List<StarSyncQueueTableData>> getPendingActions() {
    return (select(
      starSyncQueueTable,
    )..orderBy([(t) => OrderingTerm.asc(t.queuedAt)])).get();
  }

  /// Remove a single completed action from the queue.
  Future<int> removeAction(int id) {
    return (delete(starSyncQueueTable)..where((t) => t.id.equals(id))).go();
  }

  /// Clear all pending actions (e.g., after sign-out).
  Future<int> clearAll() {
    return delete(starSyncQueueTable).go();
  }

  /// Watch the queue count for UI indicators.
  Stream<int> watchPendingCount() {
    final countExpr = starSyncQueueTable.id.count();
    return (selectOnly(starSyncQueueTable)..addColumns([countExpr]))
        .map((row) => row.read(countExpr)!)
        .watchSingle();
  }
}
