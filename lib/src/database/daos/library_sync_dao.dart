import 'package:drift/drift.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/library_sync_state_table.dart';
import 'package:navis/src/database/tables/library_sync_work_table.dart';
import 'package:navis/src/database/tables/library_sync_local_mutations_table.dart';

part 'library_sync_dao.g.dart';

@DriftAccessor(
  tables: [
    LibrarySyncStateTable,
    LibrarySyncWorkTable,
    LibrarySyncLocalMutationsTable,
  ],
)
class LibrarySyncDao extends DatabaseAccessor<NavisDatabase>
    with _$LibrarySyncDaoMixin {
  LibrarySyncDao(super.attachedDatabase);

  Future<void> clearLocalMutations() {
    return delete(librarySyncLocalMutationsTable).go();
  }

  Future<void> clearWorkForServer(int serverId) {
    return (delete(
      librarySyncWorkTable,
    )..where((table) => table.serverId.equals(serverId))).go();
  }

  Future<void> clearCatalogPageWork({
    required int serverId,
    required int generation,
  }) {
    return (delete(librarySyncWorkTable)..where(
          (table) =>
              table.serverId.equals(serverId) &
              table.kind.equals('catalogAlbumPage') &
              table.entityId.like('$generation:%'),
        ))
        .go();
  }

  Future<Map<String, Set<String>>> getLocalStarMutationsSince(
    DateTime since,
  ) => getLocalMutationsSince(since, operation: 'star');

  Future<Map<String, Set<String>>> getLocalMutationsSince(
    DateTime since, {
    required String operation,
  }) async {
    final rows =
        await (select(librarySyncLocalMutationsTable)..where(
              (table) =>
                  table.operation.equals(operation) &
                  table.createdAt.isBiggerOrEqualValue(since),
            ))
            .get();
    final result = <String, Set<String>>{
      'artist': <String>{},
      'album': <String>{},
      'song': <String>{},
    };
    for (final row in rows) {
      result[row.entityType]?.add(row.entityId);
    }
    return result;
  }

  Future<void> pruneLocalStarMutationsBefore(
    DateTime cutoff, {
    Map<String, Set<String>> exclude = const <String, Set<String>>{},
  }) => pruneLocalMutationsBefore(
    cutoff,
    operation: 'star',
    exclude: exclude,
  );

  Future<void> pruneLocalMutationsBefore(
    DateTime cutoff, {
    required String operation,
    Map<String, Set<String>> exclude = const <String, Set<String>>{},
  }) async {
    for (final entityType in const <String>['artist', 'album', 'song']) {
      final protectedIds = exclude[entityType] ?? const <String>{};
      await (delete(librarySyncLocalMutationsTable)..where(
            (table) =>
                table.operation.equals(operation) &
                table.entityType.equals(entityType) &
                table.createdAt.isSmallerThanValue(cutoff) &
                (protectedIds.isEmpty
                    ? const Constant(true)
                    : table.entityId.isNotIn(protectedIds)),
          ))
          .go();
    }
  }

  Future<LibrarySyncStateTableData> getOrCreateState(int serverId) async {
    await into(librarySyncStateTable).insert(
      LibrarySyncStateTableCompanion.insert(serverId: Value(serverId)),
      mode: InsertMode.insertOrIgnore,
    );
    return (select(
      librarySyncStateTable,
    )..where((table) => table.serverId.equals(serverId))).getSingle();
  }

  Future<void> writeState(LibrarySyncStateTableCompanion state) {
    return into(librarySyncStateTable).insertOnConflictUpdate(state);
  }

  Future<void> enqueueWork({
    required int serverId,
    required String kind,
    String entityId = '',
    required int priority,
    String workClass = 'background',
    String? checkpointJson,
    bool releaseCooldown = false,
    DateTime? now,
  }) async {
    final timestamp = now ?? DateTime.now();
    final normalizedClass = workClass == 'interactive'
        ? 'interactive'
        : 'background';
    await customStatement(
      '''
      INSERT INTO library_sync_work (
        server_id, kind, entity_id, priority, work_class, status,
        checkpoint_json, attempt_count, not_before, last_error_type,
        created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, 'queued', ?, 0, NULL, NULL, ?, ?)
      ON CONFLICT(server_id, kind, entity_id) DO UPDATE SET
        priority = MAX(priority, excluded.priority),
        work_class = CASE
          WHEN excluded.work_class = 'interactive'
            OR library_sync_work.work_class = 'interactive'
          THEN 'interactive'
          ELSE 'background'
        END,
        status = CASE
          WHEN library_sync_work.status = 'running' THEN 'running'
          ELSE 'queued'
        END,
        checkpoint_json = COALESCE(
          excluded.checkpoint_json,
          library_sync_work.checkpoint_json
        ),
        attempt_count = CASE
          WHEN library_sync_work.status = 'completed' THEN 0
          ELSE library_sync_work.attempt_count
        END,
        not_before = CASE
          WHEN ? = 1 THEN NULL
          ELSE library_sync_work.not_before
        END,
        last_error_type = NULL,
        updated_at = excluded.updated_at;
      ''',
      <Object?>[
        serverId,
        kind,
        entityId,
        priority,
        normalizedClass,
        checkpointJson,
        timestamp.millisecondsSinceEpoch ~/ 1000,
        timestamp.millisecondsSinceEpoch ~/ 1000,
        releaseCooldown ? 1 : 0,
      ],
    );
  }

  Future<List<LibrarySyncWorkTableData>> getRunnableWork({
    required int serverId,
    required DateTime now,
    int limit = 64,
  }) {
    final query = select(librarySyncWorkTable)
      ..where(
        (table) =>
            table.serverId.equals(serverId) &
            table.status.isIn(const <String>['queued', 'failed']) &
            (table.notBefore.isNull() |
                table.notBefore.isSmallerOrEqualValue(now)),
      )
      ..orderBy([
        (table) => OrderingTerm.desc(table.priority),
        (table) => OrderingTerm.asc(table.createdAt),
      ])
      ..limit(limit);
    return query.get();
  }

  Future<LibrarySyncWorkTableData?> getWork({
    required int serverId,
    required String kind,
    String entityId = '',
  }) {
    return (select(librarySyncWorkTable)
          ..where(
            (table) =>
                table.serverId.equals(serverId) &
                table.kind.equals(kind) &
                table.entityId.equals(entityId),
          )
          ..limit(1))
        .getSingleOrNull();
  }

  Future<void> updateCheckpoint(
    int id, {
    required String checkpointJson,
    DateTime? now,
  }) {
    return (update(
      librarySyncWorkTable,
    )..where((table) => table.id.equals(id))).write(
      LibrarySyncWorkTableCompanion(
        checkpointJson: Value(checkpointJson),
        updatedAt: Value(now ?? DateTime.now()),
      ),
    );
  }

  Future<int> countPendingWork(int serverId) async {
    final countExpression = librarySyncWorkTable.id.count();
    final query = selectOnly(librarySyncWorkTable)
      ..addColumns([countExpression])
      ..where(
        librarySyncWorkTable.serverId.equals(serverId) &
            librarySyncWorkTable.status.isIn(
              const <String>['queued', 'running', 'failed'],
            ),
      );
    final row = await query.getSingle();
    return row.read(countExpression) ?? 0;
  }

  Future<void> markRunning(int id, {DateTime? now}) {
    return (update(
      librarySyncWorkTable,
    )..where((table) => table.id.equals(id))).write(
      LibrarySyncWorkTableCompanion(
        status: const Value('running'),
        updatedAt: Value(now ?? DateTime.now()),
      ),
    );
  }

  Future<void> requeue(int id, {DateTime? now}) {
    return (update(
      librarySyncWorkTable,
    )..where((table) => table.id.equals(id))).write(
      LibrarySyncWorkTableCompanion(
        status: const Value('queued'),
        notBefore: const Value(null),
        lastErrorType: const Value(null),
        updatedAt: Value(now ?? DateTime.now()),
      ),
    );
  }

  Future<void> markCompleted(
    int id, {
    DateTime? now,
    bool preserveCheckpoint = false,
  }) {
    return (update(
      librarySyncWorkTable,
    )..where((table) => table.id.equals(id))).write(
      LibrarySyncWorkTableCompanion(
        status: const Value('completed'),
        checkpointJson: preserveCheckpoint
            ? const Value.absent()
            : const Value(null),
        notBefore: const Value(null),
        lastErrorType: const Value(null),
        updatedAt: Value(now ?? DateTime.now()),
      ),
    );
  }

  Future<void> completeRunningCatalogWork(
    int serverId, {
    DateTime? now,
  }) {
    return (update(librarySyncWorkTable)..where(
          (table) =>
              table.serverId.equals(serverId) &
              table.kind.isIn(const <String>['fullRepair', 'catalogSnapshot']) &
              table.status.equals('running'),
        ))
        .write(
          LibrarySyncWorkTableCompanion(
            status: const Value('completed'),
            checkpointJson: const Value(null),
            notBefore: const Value(null),
            lastErrorType: const Value(null),
            updatedAt: Value(now ?? DateTime.now()),
          ),
        );
  }

  Future<void> markCancelled(int id, {DateTime? now}) {
    return (update(
      librarySyncWorkTable,
    )..where((table) => table.id.equals(id))).write(
      LibrarySyncWorkTableCompanion(
        status: const Value('queued'),
        updatedAt: Value(now ?? DateTime.now()),
      ),
    );
  }

  Future<void> markFailed(
    int id, {
    required String errorType,
    required DateTime notBefore,
    DateTime? now,
  }) async {
    final row = await (select(
      librarySyncWorkTable,
    )..where((table) => table.id.equals(id))).getSingle();
    await (update(
      librarySyncWorkTable,
    )..where((table) => table.id.equals(id))).write(
      LibrarySyncWorkTableCompanion(
        status: const Value('failed'),
        attemptCount: Value(row.attemptCount + 1),
        notBefore: Value(notBefore),
        lastErrorType: Value(errorType),
        updatedAt: Value(now ?? DateTime.now()),
      ),
    );
  }

  Future<void> resetInterruptedWork(int serverId, {DateTime? now}) {
    return (update(librarySyncWorkTable)..where(
          (table) =>
              table.serverId.equals(serverId) & table.status.equals('running'),
        ))
        .write(
          LibrarySyncWorkTableCompanion(
            status: const Value('queued'),
            updatedAt: Value(now ?? DateTime.now()),
          ),
        );
  }

  Future<void> deleteEntityWork({
    required int serverId,
    required String kind,
    required Iterable<String> entityIds,
  }) async {
    final ids = entityIds.toSet();
    if (ids.isEmpty) {
      return;
    }
    await (delete(librarySyncWorkTable)..where(
          (table) =>
              table.serverId.equals(serverId) &
              table.kind.equals(kind) &
              table.entityId.isIn(ids),
        ))
        .go();
  }

  Future<void> pruneCompletedBefore(DateTime cutoff) {
    return (delete(librarySyncWorkTable)..where(
          (table) =>
              table.status.equals('completed') &
              table.updatedAt.isSmallerThanValue(cutoff),
        ))
        .go();
  }
}
