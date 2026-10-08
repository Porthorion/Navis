import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/database_utils.dart';
import 'package:navis/src/database/tables/library_sync_state_table.dart';
import 'package:navis/src/database/tables/library_sync_work_table.dart';
import 'package:navis/src/database/tables/library_sync_local_mutations_table.dart';
import 'package:navis/src/database/tables/library_sync_operation_ledger_table.dart';
import 'package:navis/src/database/tables/library_sync_execution_lease_table.dart';
import 'package:navis/src/database/tables/library_sync_run_attempt_table.dart';
import 'package:navis/src/database/tables/library_sync_run_outcome_table.dart';
import 'package:navis/src/database/tables/library_sync_run_request_table.dart';
import 'package:navis/src/database/tables/library_scan_observation_table.dart';
import 'package:navis/src/database/tables/library_recovery_review_table.dart';
import 'package:navis/src/database/tables/starred_absence_candidates_table.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';
import 'package:navis/src/features/library/domain/sync_run_contract.dart';

part 'library_sync_dao.g.dart';

/// The redacted record exposed by settings and the diagnostics API.
class LibrarySyncRunHistoryEntry {
  const new({
    required this.requestId,
    required this.attemptId,
    required this.startedAt,
    required this.origin,
    required this.intent,
    required this.targetKind,
    required this.planKind,
    required this.outcome,
    required this.reason,
    required this.requestCount,
    required this.byteCount,
    required this.completedAt,
  });

  final SyncRunOrigin origin;
  final int requestId;
  final int? attemptId;
  final DateTime? startedAt;
  final SyncRunIntent intent;
  final LibrarySyncTargetKind targetKind;
  final String planKind;
  final SyncRunOutcomeKind outcome;
  final SyncSafeReason reason;
  final int requestCount;
  final int byteCount;
  final DateTime completedAt;
}

@DriftAccessor(
  tables: [
    LibrarySyncStateTable,
    LibrarySyncWorkTable,
    LibrarySyncLocalMutationsTable,
    StarredAbsenceCandidatesTable,
    LibrarySyncOperationLedgerTable,
    LibrarySyncExecutionLeaseTable,
    LibrarySyncRunRequestTable,
    LibrarySyncRunAttemptTable,
    LibrarySyncRunOutcomeTable,
    LibraryScanObservationTable,
    LibraryRecoveryReviewTable,
  ],
)
class LibrarySyncDao extends DatabaseAccessor<NavisDatabase>
    with NavisDaoTransactions, _$LibrarySyncDaoMixin {
  new(super.attachedDatabase);

  static const int _runQueued = 0;
  static const int _runRunning = 1;
  static const int _runTerminal = 2;
  static const int _attemptRunning = 0;
  static const int _attemptRecovered = 1;
  static const int _attemptTerminal = 2;

  /// Records a request before durable work is enqueued. Equivalent
  /// active requests share this durable identity, but terminal requests are
  /// retained as independent history entries.
  Future<({int id})> enqueueSyncRun({
    required int serverId,
    required SyncExecutionPlan plan,
    DateTime? now,
  }) async {
    final timestamp = (now ?? DateTime.now()).toUtc();
    final request = plan.request;
    final active =
        await (select(librarySyncRunRequestTable)
              ..where(
                (table) =>
                    table.serverId.equals(serverId) &
                    table.coalescingKey.equals(request.coalescingKey) &
                    table.status.isIn(const <int>[_runQueued, _runRunning]),
              )
              ..orderBy([(table) => OrderingTerm.desc(table.updatedAt)])
              ..limit(1))
            .getSingleOrNull();
    if (active != null) {
      return (id: active.id);
    }
    final id = await into(librarySyncRunRequestTable).insert(
      LibrarySyncRunRequestTableCompanion.insert(
        serverId: serverId,
        contractVersion: LibrarySyncRequest.currentContractVersion,
        origin: request.origin.index,
        intent: request.runHistoryIntent.index,
        targetKind: request.target.kind.index,
        targetKey: const Value(''),
        networkGrant: SyncNetworkGrant.none.index,
        // Historical plan indices predate the durable work-kind names.
        planKind: switch (plan.kind) {
          LibrarySyncPlanKind.probe => 0,
          LibrarySyncPlanKind.deltaReconcile => 1,
          LibrarySyncPlanKind.fullRepair => 2,
          LibrarySyncPlanKind.targetedHydration =>
            request.runHistoryIntent == SyncRunIntent.auxiliaryRefresh ? 4 : 3,
          LibrarySyncPlanKind.catalogSnapshot => 5,
          LibrarySyncPlanKind.compatibilityAudit => 6,
        },
        priority: 0,
        coalescingKey: request.coalescingKey,
        status: const Value(_runQueued),
        createdAt: timestamp,
        updatedAt: timestamp,
      ),
    );
    return (id: id);
  }

  Future<LibrarySyncRunAttemptTableData> beginSyncRunAttempt({
    required int requestId,
    required bool androidWorker,
    DateTime? now,
  }) async {
    final timestamp = (now ?? DateTime.now()).toUtc();
    return await transaction(() async {
      await (update(
        librarySyncRunRequestTable,
      )..where((table) => table.id.equals(requestId))).write(
        LibrarySyncRunRequestTableCompanion(
          status: const Value(_runRunning),
          updatedAt: Value(timestamp),
        ),
      );
      final id = await into(librarySyncRunAttemptTable).insert(
        LibrarySyncRunAttemptTableCompanion.insert(
          requestId: requestId,
          ownerKind: Value(androidWorker ? 1 : 0),
          startedAt: timestamp,
        ),
      );
      return await (select(
        librarySyncRunAttemptTable,
      )..where((table) => table.id.equals(id))).getSingle();
    });
  }

  /// Completes a request once with a redacted, typed result.
  ///
  /// Shared waiters cannot duplicate outcomes or overwrite an executed result.
  /// Legacy target identifiers are cleared at this boundary.
  Future<void> completeSyncRun({
    required int requestId,
    required SyncRunOutcome outcome,
    int? attemptId,
    DateTime? now,
  }) async {
    final timestamp = (now ?? DateTime.now()).toUtc();
    await transaction(() async {
      final changed =
          await (update(librarySyncRunRequestTable)..where(
                (table) =>
                    table.id.equals(requestId) &
                    table.status.isNotValue(_runTerminal),
              ))
              .write(
                LibrarySyncRunRequestTableCompanion(
                  status: const Value(_runTerminal),
                  targetKey: const Value(''),
                  updatedAt: Value(timestamp),
                ),
              );
      if (changed == 0) return;
      if (attemptId != null) {
        await (update(
          librarySyncRunAttemptTable,
        )..where((table) => table.id.equals(attemptId))).write(
          LibrarySyncRunAttemptTableCompanion(
            status: const Value(_attemptTerminal),
            completedAt: Value(timestamp),
          ),
        );
      }
      await into(librarySyncRunOutcomeTable).insert(
        LibrarySyncRunOutcomeTableCompanion.insert(
          requestId: requestId,
          attemptId: Value(attemptId),
          outcomeKind: outcome.kind.index,
          safeReason: outcome.reason.index,
          requestCount: Value(outcome.requestCount),
          byteCount: Value(outcome.byteCount),
          completedAt: timestamp,
        ),
      );
    });
  }

  Future<void> writeAttemptTelemetry(
    int attemptId,
    Map<String, Object?> telemetry,
  ) async {
    await (update(librarySyncRunAttemptTable)..where(
          (row) =>
              row.id.equals(attemptId) & row.status.equals(_attemptRunning),
        ))
        .write(
          LibrarySyncRunAttemptTableCompanion(
            telemetryJson: Value(jsonEncode(telemetry)),
          ),
        );
  }

  /// Includes active and recovered attempts, which have no terminal outcome yet.
  Future<List<LibrarySyncRunAttemptTableData>> getRecentSyncAttempts(
    int serverId, {
    int limit = 20,
    int? attemptId,
  }) async {
    final query =
        select(librarySyncRunAttemptTable).join([
            innerJoin(
              librarySyncRunRequestTable,
              librarySyncRunRequestTable.id.equalsExp(
                librarySyncRunAttemptTable.requestId,
              ),
            ),
          ])
          ..where(librarySyncRunRequestTable.serverId.equals(serverId))
          ..orderBy([OrderingTerm.desc(librarySyncRunAttemptTable.id)])
          ..limit(limit.clamp(1, 20));
    if (attemptId != null) {
      query.where(librarySyncRunAttemptTable.id.equals(attemptId));
    }
    return (await query.get())
        .map((row) => row.readTable(librarySyncRunAttemptTable))
        .toList();
  }

  /// Converts abandoned in-process attempts back to their request queue. The
  /// attempt remains durable evidence that a restart recovery occurred.
  Future<void> recoverInterruptedSyncRuns(int serverId, {DateTime? now}) {
    final timestamp = (now ?? DateTime.now()).toUtc();
    return transaction(() async {
      final runningRequests =
          await (select(librarySyncRunRequestTable)..where(
                (table) =>
                    table.serverId.equals(serverId) &
                    table.status.equals(_runRunning),
              ))
              .get();
      if (runningRequests.isEmpty) {
        return;
      }
      final ids = runningRequests.map((row) => row.id).toList(growable: false);
      await (update(librarySyncRunAttemptTable)..where(
            (table) =>
                table.requestId.isIn(ids) &
                table.status.equals(_attemptRunning),
          ))
          .write(
            const LibrarySyncRunAttemptTableCompanion(
              status: Value(_attemptRecovered),
            ),
          );
      await (update(
        librarySyncRunRequestTable,
      )..where((table) => table.id.isIn(ids))).write(
        LibrarySyncRunRequestTableCompanion(
          status: const Value(_runQueued),
          updatedAt: Value(timestamp),
        ),
      );
    });
  }

  Future<List<LibrarySyncRunHistoryEntry>> getRecentSyncRunHistory(
    int serverId, {
    int limit = 50,
  }) async {
    final safeLimit = limit.clamp(1, 50);
    final rows =
        await (select(librarySyncRunOutcomeTable).join([
                innerJoin(
                  librarySyncRunRequestTable,
                  librarySyncRunRequestTable.id.equalsExp(
                    librarySyncRunOutcomeTable.requestId,
                  ),
                ),
                leftOuterJoin(
                  librarySyncRunAttemptTable,
                  librarySyncRunAttemptTable.id.equalsExp(
                    librarySyncRunOutcomeTable.attemptId,
                  ),
                  useColumns: false,
                ),
              ])
              ..addColumns([librarySyncRunAttemptTable.startedAt])
              ..where(librarySyncRunRequestTable.serverId.equals(serverId))
              ..orderBy([
                OrderingTerm.desc(librarySyncRunOutcomeTable.completedAt),
                OrderingTerm.desc(librarySyncRunOutcomeTable.id),
              ])
              ..limit(safeLimit))
            .get();
    return rows
        .map(
          (row) => LibrarySyncRunHistoryEntry(
            requestId: row.readTable(librarySyncRunRequestTable).id,
            attemptId: row.readTable(librarySyncRunOutcomeTable).attemptId,
            startedAt: row.read(librarySyncRunAttemptTable.startedAt),
            origin: SyncRunOrigin
                .values[row.readTable(librarySyncRunRequestTable).origin],
            intent: SyncRunIntent
                .values[row.readTable(librarySyncRunRequestTable).intent],
            targetKind: LibrarySyncTargetKind
                .values[row.readTable(librarySyncRunRequestTable).targetKind],
            // Diagnostics consumers retain the names of historical plan indices.
            planKind: switch (row
                .readTable(librarySyncRunRequestTable)
                .planKind) {
              0 => 'automaticProbe',
              1 => 'manualCatalogDiscovery',
              2 => 'repairLibrary',
              3 => 'targetHydration',
              4 => 'auxiliaryRefresh',
              5 => 'catalogSnapshot',
              6 => 'compatibilityAudit',
              _ => throw StateError('Unknown sync history plan kind'),
            },
            outcome: SyncRunOutcomeKind
                .values[row.readTable(librarySyncRunOutcomeTable).outcomeKind],
            reason: SyncSafeReason
                .values[row.readTable(librarySyncRunOutcomeTable).safeReason],
            requestCount: row
                .readTable(librarySyncRunOutcomeTable)
                .requestCount,
            byteCount: row.readTable(librarySyncRunOutcomeTable).byteCount,
            completedAt: row.readTable(librarySyncRunOutcomeTable).completedAt,
          ),
        )
        .toList(growable: false);
  }

  Future<void> pruneSyncRunHistoryBefore(DateTime cutoff) async {
    final normalized = cutoff.toUtc();
    await transaction(() async {
      await (delete(
            librarySyncRunOutcomeTable,
          )..where((table) => table.completedAt.isSmallerThanValue(normalized)))
          .go();
      await (delete(librarySyncRunRequestTable)..where(
            (table) =>
                table.status.equals(_runTerminal) &
                table.updatedAt.isSmallerThanValue(normalized),
          ))
          .go();
    });
  }

  Future<void> pruneAttemptTelemetryBefore(DateTime cutoff) async {
    await (update(librarySyncRunAttemptTable)..where(
          (row) =>
              row.status.equals(_attemptRunning).not() &
              row.startedAt.isSmallerThanValue(cutoff) &
              row.telemetryJson.isNotNull(),
        ))
        .write(
          const LibrarySyncRunAttemptTableCompanion(telemetryJson: Value(null)),
        );
  }

  /// Work rows are one backlog axis, not a count of albums or artists.
  Future<List<Map<String, Object?>>> getWorkSummary(
    int serverId,
    DateTime now,
  ) async {
    final rows = await customSelect(
      '''
      SELECT CASE
        WHEN entity_id = '@starred' THEN 'starred'
        WHEN entity_id = '@playlistHeaders' THEN 'playlistHeaders'
        WHEN entity_id LIKE 'album:%' THEN 'album'
        WHEN entity_id LIKE 'artist:%' THEN 'artist'
        WHEN entity_id LIKE 'playlist:%' THEN 'playlist'
        WHEN entity_id = '' THEN 'catalog'
        ELSE 'legacyTarget' END AS target,
        CASE WHEN status IN ('queued','running','failed','cancelled','completed','awaitingConfirmation')
          THEN status ELSE 'unknown' END AS safe_status,
        CASE WHEN status IN ('queued','failed') AND not_before > ?1 THEN 1 ELSE 0 END AS cooling_down,
        MIN(CASE WHEN status IN ('queued','failed') AND not_before > ?1 THEN not_before END) AS next_retry_at,
        COUNT(*) AS count
      FROM library_sync_work WHERE server_id = ?2
      GROUP BY target, safe_status, cooling_down
      ORDER BY target, safe_status, cooling_down
    ''',
      variables: [Variable.withDateTime(now), Variable.withInt(serverId)],
      readsFrom: {librarySyncWorkTable},
    ).get();
    return [
      for (final row in rows)
        {
          'target': row.read<String>('target'),
          'status': row.read<String>('safe_status'),
          'coolingDown': row.read<int>('cooling_down') == 1,
          'nextRetryAt': row.readNullable<int>('next_retry_at') == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(
                  row.read<int>('next_retry_at') * 1000,
                  isUtc: true,
                ).toIso8601String(),
          'count': row.read<int>('count'),
        },
    ];
  }

  /// Attempts to acquire the server's broad-sync lease.
  ///
  /// The UPSERT is the ownership decision: a fresh lease belonging to another
  /// engine is never overwritten, while an expired lease can be recovered by
  /// exactly one writer. Reusing the same token is an idempotent heartbeat,
  /// which makes retries around a busy database safe.
  Future<bool> acquireExecutionLease({
    required int serverId,
    required String ownerToken,
    required String ownerKind,
    required DateTime now,
    required Duration ttl,
  }) async {
    final timestamp = now.toUtc();
    final expiry = timestamp.add(ttl);
    return await transaction(() async {
      await customStatement(
        '''
        INSERT INTO library_sync_execution_lease (
          server_id, owner_token, owner_kind, started_at, heartbeat_at,
          expires_at
        ) VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(server_id) DO UPDATE SET
          owner_token = excluded.owner_token,
          owner_kind = excluded.owner_kind,
          started_at = CASE
            WHEN library_sync_execution_lease.owner_token = excluded.owner_token
            THEN library_sync_execution_lease.started_at
            ELSE excluded.started_at
          END,
          heartbeat_at = excluded.heartbeat_at,
          expires_at = excluded.expires_at
        WHERE library_sync_execution_lease.expires_at <= ?
           OR library_sync_execution_lease.owner_token = excluded.owner_token;
        ''',
        <Object?>[
          serverId,
          ownerToken,
          ownerKind,
          timestamp.millisecondsSinceEpoch ~/ 1000,
          timestamp.millisecondsSinceEpoch ~/ 1000,
          expiry.millisecondsSinceEpoch ~/ 1000,
          timestamp.millisecondsSinceEpoch ~/ 1000,
        ],
      );
      final lease = await getExecutionLease(serverId);
      return lease?.ownerToken == ownerToken;
    });
  }

  Future<bool> heartbeatExecutionLease({
    required int serverId,
    required String ownerToken,
    required DateTime now,
    required Duration ttl,
  }) async {
    final timestamp = now.toUtc();
    final changed = await customUpdate(
      '''
      UPDATE library_sync_execution_lease
      SET heartbeat_at = ?, expires_at = ?
      WHERE server_id = ? AND owner_token = ? AND expires_at > ?;
      ''',
      variables: <Variable<Object>>[
        Variable.withDateTime(timestamp),
        Variable.withDateTime(timestamp.add(ttl)),
        Variable.withInt(serverId),
        Variable.withString(ownerToken),
        Variable.withDateTime(timestamp),
      ],
      updates: {librarySyncExecutionLeaseTable},
    );
    return changed == 1;
  }

  Future<void> releaseExecutionLease({
    required int serverId,
    required String ownerToken,
  }) {
    return (delete(librarySyncExecutionLeaseTable)..where(
          (table) =>
              table.serverId.equals(serverId) &
              table.ownerToken.equals(ownerToken),
        ))
        .go();
  }

  Future<LibrarySyncExecutionLeaseTableData?> getExecutionLease(int serverId) {
    return (select(
      librarySyncExecutionLeaseTable,
    )..where((table) => table.serverId.equals(serverId))).getSingleOrNull();
  }

  Stream<LibrarySyncStateTableData?> watchState(int serverId) {
    return (select(
      librarySyncStateTable,
    )..where((table) => table.serverId.equals(serverId))).watchSingleOrNull();
  }

  Future<void> setAndroidBackgroundSyncEnabled({
    required int serverId,
    required bool enabled,
    DateTime? now,
  }) async {
    await getOrCreateState(serverId);
    await (update(
      librarySyncStateTable,
    )..where((table) => table.serverId.equals(serverId))).write(
      LibrarySyncStateTableCompanion(
        androidBackgroundSyncEnabled: Value(enabled),
        androidScheduleReconciledAt: Value((now ?? DateTime.now()).toUtc()),
      ),
    );
  }

  /// Persists only redacted Android scheduler observations. Values are
  /// validated at the API boundary so raw platform exceptions cannot leak into
  /// the durable diagnostic surface.
  Future<void> writeAndroidBackgroundStatus({
    required int serverId,
    DateTime? scheduleReconciledAt,
    int? requestedIntervalMinutes,
    bool clearRequestedIntervalMinutes = false,
    String? workId,
    bool clearWorkId = false,
    String? workState,
    int? attemptCount,
    DateTime? workerStartedAt,
    DateTime? workerCompletedAt,
    int? workerDurationMs,
    String? workerResult,
    String? workerStopReason,
  }) async {
    await getOrCreateState(serverId);
    await (update(
      librarySyncStateTable,
    )..where((table) => table.serverId.equals(serverId))).write(
      LibrarySyncStateTableCompanion(
        androidScheduleReconciledAt: Value.absentIfNull(
          scheduleReconciledAt?.toUtc(),
        ),
        androidRequestedIntervalMinutes: clearRequestedIntervalMinutes
            ? const Value(null)
            : Value.absentIfNull(requestedIntervalMinutes),
        androidWorkId: clearWorkId
            ? const Value(null)
            : Value.absentIfNull(workId),
        androidWorkState: Value.absentIfNull(workState),
        androidWorkAttemptCount: Value.absentIfNull(attemptCount),
        androidWorkerStartedAt: Value.absentIfNull(workerStartedAt?.toUtc()),
        androidWorkerCompletedAt: Value.absentIfNull(
          workerCompletedAt?.toUtc(),
        ),
        androidWorkerDurationMs: Value.absentIfNull(workerDurationMs),
        androidWorkerResult: Value.absentIfNull(workerResult),
        androidWorkerStopReason: Value.absentIfNull(workerStopReason),
      ),
    );
  }

  Future<void> clearLocalMutations() {
    return delete(librarySyncLocalMutationsTable).go();
  }

  /// Records a safe aggregate mutation summary and retains only the most
  /// recent entries per server. Callers must invoke this inside the same
  /// transaction as the described mutation.
  Future<void> recordOperationLedgerEntry({
    required int serverId,
    required String operation,
    required String reason,
    required Map<String, Object?> details,
    DateTime? occurredAt,
  }) async {
    final timestamp = (occurredAt ?? DateTime.now()).toUtc();
    await into(librarySyncOperationLedgerTable).insert(
      LibrarySyncOperationLedgerTableCompanion.insert(
        serverId: serverId,
        operation: operation,
        reason: reason,
        detailsJson: jsonEncode(details),
        occurredAt: timestamp,
      ),
    );
    await customStatement(
      '''
      DELETE FROM library_sync_operation_ledger
      WHERE server_id = ?
        AND id NOT IN (
          SELECT id
          FROM library_sync_operation_ledger
          WHERE server_id = ?
          ORDER BY occurred_at DESC, id DESC
          LIMIT 50
        );
      ''',
      <Object?>[serverId, serverId],
    );
  }

  Future<List<LibrarySyncOperationLedgerTableData>>
  getRecentOperationLedgerEntries(int serverId, {int limit = 50}) =>
      _recentOperationLedgerQuery(serverId, limit).get();

  /// Emits the newest safe operation summaries for one retained server.
  Stream<List<LibrarySyncOperationLedgerTableData>>
  watchRecentOperationLedgerEntries(int serverId, {int limit = 50}) =>
      _recentOperationLedgerQuery(serverId, limit).watch();

  SimpleSelectStatement<
    LibrarySyncOperationLedgerTable,
    LibrarySyncOperationLedgerTableData
  >
  _recentOperationLedgerQuery(int serverId, int limit) =>
      select(librarySyncOperationLedgerTable)
        ..where((table) => table.serverId.equals(serverId))
        ..orderBy([
          (table) => OrderingTerm.desc(table.occurredAt),
          (table) => OrderingTerm.desc(table.id),
        ])
        ..limit(limit.clamp(1, 50));

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
    for (final chunk in chunked(ids.toList(growable: false), 500)) {
      await (delete(starredAbsenceCandidatesTable)..where(
            (table) =>
                table.serverId.equals(serverId) &
                table.entityType.equals(entityType) &
                table.entityId.isIn(chunk),
          ))
          .go();
    }
  }

  Future<void> clearWorkForServer(int serverId) {
    return (delete(
      librarySyncWorkTable,
    )..where((table) => table.serverId.equals(serverId))).go();
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

  /// Discards only an uncommitted repair candidate after the user declines a
  /// large-deletion confirmation. The committed catalog is never touched.
  Future<bool> discardAwaitingRepairCandidate({
    required int serverId,
    required int generation,
  }) {
    return transaction(() async {
      final state = await getOrCreateState(serverId);
      if (state.candidateGeneration != generation ||
          state.candidateStatus != 'awaitingDeletionConfirmation') {
        return false;
      }
      await attachedDatabase.librarySyncCandidateDao.clearGeneration(
        serverId: serverId,
        generation: generation,
      );
      await (delete(librarySyncWorkTable)..where(
            (table) =>
                table.serverId.equals(serverId) &
                table.kind.equals('fullRepair') &
                table.status.equals('awaitingConfirmation'),
          ))
          .go();
      await (update(
        librarySyncStateTable,
      )..where((table) => table.serverId.equals(serverId))).write(
        const LibrarySyncStateTableCompanion(
          candidateGeneration: Value(null),
          candidateStatus: Value(null),
          candidateStartedAt: Value(null),
          candidateCarriedForwardCount: Value(0),
          deletionCandidateFingerprint: Value(null),
          deletionCandidateCount: Value(0),
        ),
      );
      return true;
    });
  }

  Future<List<LibrarySyncWorkTableData>> getCatalogPageBoundaries({
    required int serverId,
    required int generation,
  }) async {
    final rows =
        await (select(librarySyncWorkTable)..where(
              (table) =>
                  table.serverId.equals(serverId) &
                  table.kind.equals('catalogAlbumPage') &
                  table.entityId.like('$generation:%') &
                  table.status.equals('completed'),
            ))
            .get();
    rows.sort(
      (a, b) => (int.tryParse(a.entityId.split(':').last) ?? 0).compareTo(
        int.tryParse(b.entityId.split(':').last) ?? 0,
      ),
    );
    return rows.length <= 1 ? rows : [rows.first, rows.last];
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

  Future<Map<String, Set<String>>> getLocalStarMutationsSince(DateTime since) =>
      getLocalMutationsSince(since, operation: 'star');

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

  Future<LibrarySyncStateTableData> getOrCreateState(int serverId) async {
    await into(librarySyncStateTable).insert(
      LibrarySyncStateTableCompanion.insert(serverId: Value(serverId)),
      mode: InsertMode.insertOrIgnore,
    );
    return await (select(
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
    String? evidenceVersion,
    DateTime? now,
  }) {
    var resolvedCheckpointJson = checkpointJson;
    var shouldReactivateTerminal = reactivateTerminal;
    var shouldReleaseCooldown = releaseCooldown;

    // The upsert below runs through customStatement, which bypasses drift's
    // automatic stream notifications. Report the table explicitly once the
    // transaction commits so watch queries see fresh enqueues.
    return transaction(() async {
      if (evidenceVersion != null) {
        final previous = await getWork(
          serverId: serverId,
          kind: kind,
          entityId: entityId,
        );
        Map<String, dynamic> decode(String? raw) {
          try {
            final value = jsonDecode(raw ?? '{}');
            if (value is Map<String, dynamic>) return value;
          } on FormatException {
            /* Legacy work has no evidence version. */
          }
          return {};
        }

        final previousCheckpoint = decode(previous?.checkpointJson);
        if (previous != null &&
            previousCheckpoint['evidenceVersion'] != evidenceVersion) {
          shouldReactivateTerminal = true;
          shouldReleaseCooldown = true;
        }
        resolvedCheckpointJson = jsonEncode({
          ...previousCheckpoint,
          ...decode(resolvedCheckpointJson),
          'evidenceVersion': evidenceVersion,
        });
      }
      final timestamp = now ?? DateTime.now();
      final normalizedClass = workClass == 'interactive'
          ? 'interactive'
          : 'background';
      final reactivateTerminalValue = shouldReactivateTerminal ? 1 : 0;
      final releaseCooldownValue = shouldReleaseCooldown ? 1 : 0;
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
          resolvedCheckpointJson,
          timestamp.millisecondsSinceEpoch ~/ 1000,
          timestamp.millisecondsSinceEpoch ~/ 1000,
          reactivateTerminalValue,
          reactivateTerminalValue,
          releaseCooldownValue,
        ],
      );
    }).then<void>((_) {
      notifyUpdates(<TableUpdate>{TableUpdate.onTable(librarySyncWorkTable)});
    });
  }

  /// Cancel only work still waiting for admission; never mutate another owner.
  Future<void> cancelQueuedWork({
    required int serverId,
    required String kind,
    required String entityId,
    required DateTime now,
  }) async {
    await (update(librarySyncWorkTable)..where(
          (row) =>
              row.serverId.equals(serverId) &
              row.kind.equals(kind) &
              row.entityId.equals(entityId) &
              row.status.equals('queued'),
        ))
        .write(
          LibrarySyncWorkTableCompanion(
            status: const Value('cancelled'),
            updatedAt: Value(now),
          ),
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

  Future<int> countPendingWork(int serverId) =>
      _pendingWorkQuery(serverId).getSingle();

  /// Emits backlog changes without waiting for the next sync run.
  Stream<int> watchPendingWork(int serverId) =>
      _pendingWorkQuery(serverId).watchSingle();

  Selectable<int> _pendingWorkQuery(int serverId) {
    final count = librarySyncWorkTable.id.count();
    return (selectOnly(librarySyncWorkTable)
          ..addColumns([count])
          ..where(
            librarySyncWorkTable.serverId.equals(serverId) &
                librarySyncWorkTable.status.isIn(const <String>[
                  'queued',
                  'running',
                  'failed',
                ]),
          ))
        .map((row) => row.read(count) ?? 0);
  }

  Future<void> _writeWork(
    Expression<bool> Function(LibrarySyncWorkTable) where, {
    required String status,
    DateTime? now,
    Value<String?> checkpointJson = const Value.absent(),
    Value<DateTime?> notBefore = const Value.absent(),
    Value<String?> lastErrorType = const Value.absent(),
    Value<int> attemptCount = const Value.absent(),
  }) => (update(librarySyncWorkTable)..where(where)).write(
    LibrarySyncWorkTableCompanion(
      status: Value(status),
      updatedAt: Value(now ?? DateTime.now()),
      checkpointJson: checkpointJson,
      notBefore: notBefore,
      lastErrorType: lastErrorType,
      attemptCount: attemptCount,
    ),
  );

  Future<void> markRunning(int id, {DateTime? now}) =>
      _writeWork((table) => table.id.equals(id), status: 'running', now: now);

  Future<void> requeue(int id, {DateTime? now}) => _writeWork(
    (table) => table.id.equals(id),
    status: 'queued',
    now: now,
    notBefore: const Value(null),
    lastErrorType: const Value(null),
  );

  Future<void> markCompleted(
    int id, {
    DateTime? now,
    bool preserveCheckpoint = false,
  }) => _writeWork(
    (table) => table.id.equals(id),
    status: 'completed',
    now: now,
    checkpointJson: preserveCheckpoint
        ? const Value.absent()
        : const Value(null),
    notBefore: const Value(null),
    lastErrorType: const Value(null),
  );

  Future<void> completeRunningCatalogWork(int serverId, {DateTime? now}) =>
      _writeWork(
        (table) =>
            table.serverId.equals(serverId) &
            table.kind.isIn(const <String>['fullRepair', 'catalogSnapshot']) &
            table.status.equals('running'),
        status: 'completed',
        now: now,
        checkpointJson: const Value(null),
        notBefore: const Value(null),
        lastErrorType: const Value(null),
      );

  /// Cancellation remains terminal until an explicit action reactivates the row.
  Future<void> markCancelled(int id, {DateTime? now}) => _writeWork(
    (table) => table.id.equals(id),
    status: 'cancelled',
    now: now,
    notBefore: const Value(null),
    lastErrorType: const Value('cancelled'),
  );

  /// Retains the candidate checkpoint and stops retries until explicit confirmation.
  Future<void> markAwaitingConfirmation(int id, {DateTime? now}) => _writeWork(
    (table) => table.id.equals(id),
    status: 'awaitingConfirmation',
    now: now,
    notBefore: const Value(null),
    lastErrorType: const Value(null),
  );

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
    await _writeWork(
      (table) => table.id.equals(id),
      status: 'failed',
      attemptCount: Value(row.attemptCount + 1),
      notBefore: Value(notBefore),
      lastErrorType: Value(errorType),
      now: now,
    );
  }

  Future<void> resetInterruptedWork(int serverId, {DateTime? now}) =>
      _writeWork(
        (table) =>
            table.serverId.equals(serverId) & table.status.equals('running'),
        status: 'queued',
        now: now,
      );

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

  // ---------------------------------------------------------------------------
  // Scan observation
  // ---------------------------------------------------------------------------

  Future<LibraryScanObservationTableData?> getScanObservation(int serverId) {
    return (select(
      libraryScanObservationTable,
    )..where((table) => table.serverId.equals(serverId))).getSingleOrNull();
  }

  /// Records a `getScanStatus` observation.
  ///
  /// A scan still in progress never produces a token: only a completed scan
  /// with a changed provider token marks the candidate evidence stale and
  /// opens a pending reconciliation. Unsupported servers are recorded once so
  /// sync admission stops probing them on every run.
  Future<void> recordScanObservation({
    required int serverId,
    required bool scanInProgress,
    required bool supported,
    String? providerScanToken,
    DateTime? observedAt,
  }) async {
    final now = observedAt ?? DateTime.now();
    final existing = await getScanObservation(serverId);
    if (!supported) {
      if (existing == null) {
        await into(libraryScanObservationTable).insert(
          LibraryScanObservationTableCompanion.insert(
            serverId: Value(serverId),
            scanSupported: const Value(false),
          ),
        );
      }
      return;
    }
    if (scanInProgress) {
      return;
    }
    final token = providerScanToken?.trim();
    if (token == null || token.isEmpty) {
      return;
    }
    final tokenChanged = existing?.observedToken != token;
    if (existing == null) {
      await into(libraryScanObservationTable).insert(
        LibraryScanObservationTableCompanion.insert(
          serverId: Value(serverId),
          observedToken: Value(token),
          observedAt: Value(now),
          pendingReconciliation: const Value(true),
        ),
      );
      return;
    }
    if (!tokenChanged) {
      return;
    }
    await (update(
      libraryScanObservationTable,
    )..where((table) => table.serverId.equals(serverId))).write(
      LibraryScanObservationTableCompanion(
        scanSupported: const Value(true),
        observedToken: Value(token),
        observedAt: Value(now),
        pendingReconciliation: const Value(true),
      ),
    );
  }

  /// Closes the reconciliation window for [token] after a catalog snapshot
  /// collected under it was promoted.
  Future<void> markScanReconciled({
    required int serverId,
    required String token,
    DateTime? reconciledAt,
  }) async {
    final now = reconciledAt ?? DateTime.now();
    await (update(libraryScanObservationTable)..where(
          (table) =>
              table.serverId.equals(serverId) &
              table.observedToken.equals(token),
        ))
        .write(
          LibraryScanObservationTableCompanion(
            reconciledToken: Value(token),
            reconciledAt: Value(now),
            pendingReconciliation: const Value(false),
          ),
        );
  }

  // ---------------------------------------------------------------------------
  // Recovery review
  // ---------------------------------------------------------------------------

  /// Creates or refreshes a review entry for an item recovery could not relink
  /// automatically. Existing pending entries are refreshed in place; a user
  /// disposition is never overwritten by later sync evidence.
  Future<void> recordRecoveryReview({
    required int serverId,
    required String entityType,
    required String oldId,
    String? savedTitle,
    String? savedSubtitle,
    required String reason,
    int? evidenceGeneration,
    String? candidateJson,
    DateTime? createdAt,
  }) async {
    final now = DateTime.now();
    final existing =
        await (select(libraryRecoveryReviewTable)..where(
              (table) =>
                  table.serverId.equals(serverId) &
                  table.entityType.equals(entityType) &
                  table.oldId.equals(oldId),
            ))
            .getSingleOrNull();
    if (existing != null && existing.disposition != 'pending') {
      return;
    }
    final companion = LibraryRecoveryReviewTableCompanion.insert(
      serverId: serverId,
      entityType: entityType,
      oldId: oldId,
      savedTitle: Value(savedTitle),
      savedSubtitle: Value(savedSubtitle),
      reason: reason,
      evidenceGeneration: Value(evidenceGeneration),
      candidateJson: Value(candidateJson),
      createdAt: existing?.createdAt ?? createdAt ?? now,
      updatedAt: now,
    );
    if (existing == null) {
      await into(libraryRecoveryReviewTable).insert(companion);
      return;
    }
    await (update(
      libraryRecoveryReviewTable,
    )..where((table) => table.id.equals(existing.id))).write(
      companion.copyWith(
        serverId: const Value.absent(),
        entityType: const Value.absent(),
        oldId: const Value.absent(),
        createdAt: const Value.absent(),
      ),
    );
  }

  /// Bulk-creates review entries for retained unavailable rows.
  ///
  /// `INSERT OR IGNORE` on the (server, type, old-id) key keeps existing
  /// entries — and their user dispositions — untouched; promotion replays are
  /// therefore idempotent and cheap even for large libraries.
  Future<void> recordRecoveryReviewBatch({
    required int serverId,
    required List<SongsTableData> retainedSongs,
    required int? evidenceGeneration,
  }) async {
    if (retainedSongs.isEmpty) {
      return;
    }
    final now = DateTime.now();
    await batch((batch) {
      for (final song in retainedSongs) {
        batch.insert(
          libraryRecoveryReviewTable,
          LibraryRecoveryReviewTableCompanion.insert(
            serverId: serverId,
            entityType: 'song',
            oldId: song.id,
            savedTitle: Value(song.title),
            savedSubtitle: Value(song.artistName),
            reason: 'missingFromCatalog',
            evidenceGeneration: Value(evidenceGeneration),
            createdAt: now,
            updatedAt: now,
          ),
          onConflict:
              DoNothing<
                LibraryRecoveryReviewTable,
                LibraryRecoveryReviewTableData
              >(
                target: [
                  libraryRecoveryReviewTable.serverId,
                  libraryRecoveryReviewTable.entityType,
                  libraryRecoveryReviewTable.oldId,
                ],
              ),
        );
      }
    });
  }

  /// Review entries awaiting a decision, oldest first.
  Stream<List<LibraryRecoveryReviewTableData>> watchPendingRecoveryReview(
    int serverId,
  ) {
    return (select(libraryRecoveryReviewTable)..where(
          (table) =>
              table.serverId.equals(serverId) &
              table.disposition.equals('pending'),
        ))
        .watch();
  }

  Stream<int> watchPendingRecoveryReviewCount(int serverId) {
    final countExpr = libraryRecoveryReviewTable.id.count();
    final query = selectOnly(libraryRecoveryReviewTable)
      ..addColumns([countExpr])
      ..where(
        libraryRecoveryReviewTable.serverId.equals(serverId) &
            libraryRecoveryReviewTable.disposition.equals('pending'),
      );
    return query.map((row) => row.read(countExpr) ?? 0).watchSingle();
  }

  Future<void> setRecoveryReviewDisposition({
    required int id,
    required String disposition,
  }) async {
    await (update(
      libraryRecoveryReviewTable,
    )..where((table) => table.id.equals(id))).write(
      LibraryRecoveryReviewTableCompanion(
        disposition: Value(disposition),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }
}
