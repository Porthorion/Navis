import 'package:drift/drift.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/library_sync_state_table.dart';
import 'package:navis/src/database/tables/library_sync_work_table.dart';
import 'package:navis/src/database/tables/library_sync_local_mutations_table.dart';
import 'package:navis/src/database/tables/starred_absence_candidates_table.dart';

part 'library_sync_dao.g.dart';

@DriftAccessor(
  tables: [
    LibrarySyncStateTable,
    LibrarySyncWorkTable,
    LibrarySyncLocalMutationsTable,
    StarredAbsenceCandidatesTable,
  ],
)
class LibrarySyncDao extends DatabaseAccessor<NavisDatabase>
    with _$LibrarySyncDaoMixin {
  LibrarySyncDao(super.attachedDatabase);

  Future<void> clearLocalMutations() {
    return delete(librarySyncLocalMutationsTable).go();
  }

  /// Records absent locally-starred IDs and returns only those observed absent
  /// by two independent successful server snapshots.
  Future<Set<String>> observeStarredAbsences({
    required int serverId,
    required String entityType,
    required Set<String> ids,
    required DateTime observedAt,
  }) async {
    if (ids.isEmpty) {
      return const <String>{};
    }
    final confirmed = <String>{};
    for (final id in ids) {
      final existing =
          await (select(starredAbsenceCandidatesTable)..where(
                (table) =>
                    table.serverId.equals(serverId) &
                    table.entityType.equals(entityType) &
                    table.entityId.equals(id),
              ))
              .getSingleOrNull();
      if (existing == null) {
        await into(starredAbsenceCandidatesTable).insert(
          StarredAbsenceCandidatesTableCompanion.insert(
            serverId: serverId,
            entityType: entityType,
            entityId: id,
            firstObservedAt: observedAt,
            lastObservedAt: observedAt,
          ),
        );
        continue;
      }
      await (update(starredAbsenceCandidatesTable)..where(
            (table) =>
                table.serverId.equals(serverId) &
                table.entityType.equals(entityType) &
                table.entityId.equals(id),
          ))
          .write(
            StarredAbsenceCandidatesTableCompanion(
              lastObservedAt: Value(observedAt),
              observationCount: Value(existing.observationCount + 1),
            ),
          );
      if (existing.observationCount >= 1) {
        confirmed.add(id);
      }
    }
    return confirmed;
  }

  Future<void> clearStarredAbsenceCandidates({
    required int serverId,
    required String entityType,
    required Set<String> ids,
  }) async {
    for (final chunk in _idChunks(ids)) {
      await (delete(starredAbsenceCandidatesTable)..where(
            (table) =>
                table.serverId.equals(serverId) &
                table.entityType.equals(entityType) &
                table.entityId.isIn(chunk),
          ))
          .go();
    }
  }

  Iterable<List<String>> _idChunks(Set<String> ids) sync* {
    final values = ids.toList(growable: false);
    for (var offset = 0; offset < values.length; offset += 500) {
      final end = (offset + 500).clamp(0, values.length);
      yield values.sublist(offset, end);
    }
  }

  Future<void> clearWorkForServer(int serverId) {
    return (delete(
      librarySyncWorkTable,
    )..where((table) => table.serverId.equals(serverId))).go();
  }

  Future<void> discardPendingSessionWork(int serverId) async {
    await transaction(() async {
      await clearWorkForServer(serverId);
      await (update(
        librarySyncStateTable,
      )..where((table) => table.serverId.equals(serverId))).write(
        const LibrarySyncStateTableCompanion(
          candidateGeneration: Value(null),
          candidateStatus: Value(null),
          candidateStartedAt: Value(null),
          candidateCarriedForwardCount: Value(0),
        ),
      );
    });
  }

  Future<void> discardAllPendingSessionWork() async {
    await transaction(() async {
      await delete(librarySyncWorkTable).go();
      await update(librarySyncStateTable).write(
        const LibrarySyncStateTableCompanion(
          candidateGeneration: Value(null),
          candidateStatus: Value(null),
          candidateStartedAt: Value(null),
          candidateCarriedForwardCount: Value(0),
        ),
      );
    });
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

  Future<void> setNextAutomaticCheckAt({
    required int serverId,
    required DateTime? nextAutomaticCheckAt,
  }) async {
    // A newly authenticated server may not have run a sync yet. Persist the
    // per-server row first so configuring its schedule is never a silent
    // zero-row update.
    await getOrCreateState(serverId);
    await (update(
      librarySyncStateTable,
    )..where((table) => table.serverId.equals(serverId))).write(
      LibrarySyncStateTableCompanion(
        nextAutomaticCheckAt: Value(nextAutomaticCheckAt),
      ),
    );
  }

  Future<void> enqueueWork({
    required int serverId,
    required String kind,
    String entityId = '',
    required int priority,
    String workClass = 'background',
    String? checkpointJson,
    bool releaseCooldown = false,
    bool reactivateTerminal = false,
    DateTime? now,
  }) async {
    final timestamp = now ?? DateTime.now();
    final normalizedClass = workClass == 'interactive'
        ? 'interactive'
        : 'background';
    final reactivateTerminalValue = reactivateTerminal ? 1 : 0;
    final releaseCooldownValue = releaseCooldown ? 1 : 0;
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
          WHEN library_sync_work.status IN ('queued', 'running', 'failed')
          THEN library_sync_work.status
          WHEN ? = 1 THEN 'queued'
          ELSE library_sync_work.status
        END,
        checkpoint_json = COALESCE(
          excluded.checkpoint_json,
          library_sync_work.checkpoint_json
        ),
        attempt_count = CASE
          WHEN ? = 1 AND library_sync_work.status NOT IN
            ('queued', 'running', 'failed') THEN 0
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
        reactivateTerminalValue,
        reactivateTerminalValue,
        releaseCooldownValue,
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

  /// Stops automatic retries until an explicit user action reactivates it.
  ///
  /// The candidate checkpoint is deliberately retained so Repair Library can
  /// present a concrete confirmation instead of rebuilding the same snapshot.
  Future<void> markAwaitingConfirmation(int id, {DateTime? now}) {
    return (update(
      librarySyncWorkTable,
    )..where((table) => table.id.equals(id))).write(
      LibrarySyncWorkTableCompanion(
        status: const Value('awaitingConfirmation'),
        notBefore: const Value(null),
        lastErrorType: const Value(null),
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
    )..where((table) => table.id.equals(id))).getSingleOrNull();
    if (row == null) {
      return;
    }
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
