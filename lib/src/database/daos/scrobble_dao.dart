import 'package:drift/drift.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/scrobble_queue_table.dart';

part 'scrobble_dao.g.dart';

@DriftAccessor(tables: [ScrobbleQueueTable])
class ScrobbleDao extends DatabaseAccessor<NavisDatabase>
    with _$ScrobbleDaoMixin {
  ScrobbleDao(super.db);

  Future<void> enqueue({
    required String songId,
    required bool submission,
    required String sessionKey,
    required DateTime createdAt,
    required DateTime nextAttemptAt,
    required DateTime expiresAt,
  }) {
    return into(scrobbleQueueTable).insert(
      ScrobbleQueueTableCompanion.insert(
        songId: songId,
        submission: submission,
        sessionKey: sessionKey,
        createdAt: createdAt,
        nextAttemptAt: nextAttemptAt,
        expiresAt: expiresAt,
      ),
      mode: InsertMode.insertOrIgnore,
    );
  }

  Future<List<ScrobbleQueueTableData>> getDueEntries(
    DateTime now, {
    int limit = 50,
  }) {
    final query = select(scrobbleQueueTable)
      ..where(
        (table) =>
            table.nextAttemptAt.isSmallerOrEqualValue(now) &
            table.expiresAt.isBiggerThanValue(now),
      )
      ..orderBy([
        (table) => OrderingTerm.asc(table.nextAttemptAt),
      ])
      ..limit(limit);
    return query.get();
  }

  Future<void> markDelivered(int id) {
    return (delete(
      scrobbleQueueTable,
    )..where((table) => table.id.equals(id))).go();
  }

  Future<void> reschedule({
    required int id,
    required int attempts,
    required DateTime nextAttemptAt,
    String? lastError,
  }) {
    return (update(
      scrobbleQueueTable,
    )..where((table) => table.id.equals(id))).write(
      ScrobbleQueueTableCompanion(
        attempts: Value(attempts),
        nextAttemptAt: Value(nextAttemptAt),
        lastError: Value(lastError),
      ),
    );
  }

  Future<void> pruneExpired(DateTime now) {
    return (delete(
      scrobbleQueueTable,
    )..where((table) => table.expiresAt.isSmallerOrEqualValue(now))).go();
  }

  Future<void> clearAll() => delete(scrobbleQueueTable).go();

  Future<int> countEntries() async {
    final countExpression = scrobbleQueueTable.id.count();
    final query = selectOnly(scrobbleQueueTable)
      ..addColumns(<Expression<Object>>[countExpression]);
    final row = await query.getSingle();
    return row.read(countExpression) ?? 0;
  }
}
