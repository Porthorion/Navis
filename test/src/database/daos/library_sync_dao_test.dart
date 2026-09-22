import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';
import 'package:navis/src/features/library/domain/sync_run_contract.dart';

import '../../../helpers/test_database.dart';

void main() {
  late NavisDatabase database;

  setUp(() async {
    database = createTestDatabase();
    await database.serverDao.saveServer(
      ServerConfigTableCompanion.insert(
        url: 'https://music.example.test',
        username: 'listener',
        apiVersion: '1.16.1',
      ),
    );
  });

  tearDown(() async {
    await database.close();
  });

  test('cancelled work reopens only for changed evidence', () async {
    Future<void> observe(String evidence) =>
        database.librarySyncDao.enqueueWork(
          serverId: 1,
          kind: 'targetedHydration',
          entityId: 'playlist:p',
          priority: 30,
          evidenceVersion: evidence,
          checkpointJson: '{"targetKind":"playlist"}',
        );
    await observe('v1');
    var row = (await database.librarySyncDao.getWork(
      serverId: 1,
      kind: 'targetedHydration',
      entityId: 'playlist:p',
    ))!;
    await database.librarySyncDao.markCancelled(row.id);
    await observe('v1');
    row = (await database.librarySyncDao.getWork(
      serverId: 1,
      kind: 'targetedHydration',
      entityId: 'playlist:p',
    ))!;
    expect(row.status, 'cancelled');
    await observe('v2');
    row = (await database.librarySyncDao.getWork(
      serverId: 1,
      kind: 'targetedHydration',
      entityId: 'playlist:p',
    ))!;
    expect(row.status, 'queued');
    expect(row.checkpointJson, contains('v2'));
    expect(row.notBefore, isNull);
  });

  test(
    'work summary separates cooldown and confirmation without target IDs',
    () async {
      final now = DateTime.utc(2026, 9, 19);
      await database.librarySyncDao.enqueueWork(
        serverId: 1,
        kind: 'targetedHydration',
        entityId: 'album:private-id',
        priority: 1,
        now: now,
      );
      final album = (await database.librarySyncDao.getWork(
        serverId: 1,
        kind: 'targetedHydration',
        entityId: 'album:private-id',
      ))!;
      await (database.update(
        database.librarySyncWorkTable,
      )..where((row) => row.id.equals(album.id))).write(
        LibrarySyncWorkTableCompanion(
          status: const Value('failed'),
          notBefore: Value(now.add(const Duration(minutes: 5))),
        ),
      );
      await database.librarySyncDao.enqueueWork(
        serverId: 1,
        kind: 'targetedHydration',
        entityId: '@starred',
        priority: 1,
        now: now,
      );
      await database.librarySyncDao.enqueueWork(
        serverId: 1,
        kind: 'fullRepair',
        priority: 1,
        now: now,
      );
      final repair = (await database.librarySyncDao.getWork(
        serverId: 1,
        kind: 'fullRepair',
      ))!;
      await database.librarySyncDao.markAwaitingConfirmation(
        repair.id,
        now: now,
      );
      final summary = await database.librarySyncDao.getWorkSummary(1, now);
      expect(
        summary,
        contains(
          equals({
            'target': 'album',
            'status': 'failed',
            'coolingDown': true,
            'nextRetryAt': now
                .add(const Duration(minutes: 5))
                .toIso8601String(),
            'count': 1,
          }),
        ),
      );
      expect(
        summary,
        contains(
          equals({
            'target': 'catalog',
            'status': 'awaitingConfirmation',
            'coolingDown': false,
            'nextRetryAt': null,
            'count': 1,
          }),
        ),
      );
      expect(
        summary,
        contains(
          equals({
            'target': 'starred',
            'status': 'queued',
            'coolingDown': false,
            'nextRetryAt': null,
            'count': 1,
          }),
        ),
      );
      expect(jsonEncode(summary), isNot(contains('private-id')));
      expect(await database.librarySyncDao.getWorkSummary(999, now), isEmpty);
    },
  );

  test('persists one typed request, attempt, and redacted outcome', () async {
    final now = DateTime.utc(2026, 8, 26, 10);
    const request = SyncRunRequest(
      contractVersion: SyncRunRequest.currentContractVersion,
      origin: SyncRunOrigin.libraryPullToRefresh,
      intent: SyncRunIntent.manualCatalogCheck,
      target: LibrarySyncTarget.catalog(),
      networkGrant: SyncNetworkGrant.boundedMeteredDiscovery,
      priority: 60,
    );
    const plan = SyncExecutionPlan(
      request: request,
      kind: SyncExecutionPlanKind.manualCatalogDiscovery,
      reason: SyncSafeReason.none,
      budget: SyncExecutionBudget(
        allowedEndpoints: <SyncEndpoint>{
          SyncEndpoint.indexes,
          SyncEndpoint.newestAlbums,
        },
        maxNewestPages: 5,
        maxAlbumHydrations: 0,
        maxResponseBytes: null,
        maxTotalBytes: null,
        maxConcurrency: 8,
      ),
    );

    final queued = await database.librarySyncDao.enqueueSyncRun(
      serverId: 1,
      plan: plan,
      now: now,
    );
    final duplicate = await database.librarySyncDao.enqueueSyncRun(
      serverId: 1,
      plan: plan,
      now: now.add(const Duration(seconds: 1)),
    );
    expect(duplicate.id, queued.id);

    final attempt = await database.librarySyncDao.beginSyncRunAttempt(
      requestId: queued.id,
      androidWorker: false,
      now: now,
    );
    await database.librarySyncDao.writeAttemptTelemetry(attempt.id, {
      'version': 1,
      'requestId': queued.id,
      'attemptId': attempt.id,
    });
    await database.librarySyncDao.completeSyncRun(
      requestId: queued.id,
      attemptId: attempt.id,
      outcome: const SyncRunOutcome(
        kind: SyncRunOutcomeKind.completed,
        reason: SyncSafeReason.none,
        requestCount: 6,
        byteCount: 2048,
      ),
      now: now.add(const Duration(seconds: 10)),
    );

    final history = await database.librarySyncDao.getRecentSyncRunHistory(1);
    expect(history, hasLength(1));
    expect(history.single.origin, SyncRunOrigin.libraryPullToRefresh);
    expect(history.single.intent, SyncRunIntent.manualCatalogCheck);
    expect(history.single.targetKind, LibrarySyncTargetKind.catalog);
    expect(history.single.outcome, SyncRunOutcomeKind.completed);
    expect(history.single.requestCount, 6);
    expect(history.single.byteCount, 2048);
    expect(history.single.requestId, queued.id);
    expect(history.single.attemptId, attempt.id);
    expect(history.single.startedAt?.toUtc(), now);
    final recorded = (await database.librarySyncDao.getRecentSyncAttempts(1))
        .single;
    expect(recorded.telemetryJson, contains('"version":1'));
    expect(
      await database.librarySyncDao.getRecentSyncAttempts(
        1,
        attemptId: attempt.id,
      ),
      hasLength(1),
    );
    expect(
      await database.librarySyncDao.getRecentSyncAttempts(
        1,
        attemptId: attempt.id + 1,
      ),
      isEmpty,
    );
    expect(
      await database.librarySyncDao.getRecentSyncAttempts(
        999,
        attemptId: attempt.id,
      ),
      isEmpty,
    );
    await database.librarySyncDao.writeAttemptTelemetry(attempt.id, {
      'version': 999,
    });
    expect(
      (await database.librarySyncDao.getRecentSyncAttempts(1))
          .single
          .telemetryJson,
      recorded.telemetryJson,
      reason: 'terminal telemetry cannot be overwritten',
    );
    await database.librarySyncDao.pruneAttemptTelemetryBefore(
      now.add(const Duration(days: 8)),
    );
    expect(
      (await database.librarySyncDao.getRecentSyncAttempts(1))
          .single
          .telemetryJson,
      isNull,
    );
    expect(
      (await database.librarySyncDao.getRecentSyncRunHistory(1))
          .single
          .byteCount,
      2048,
    );
    final storedRequest = await (database.select(
      database.librarySyncRunRequestTable,
    )..where((table) => table.id.equals(queued.id))).getSingle();
    expect(storedRequest.targetKey, isEmpty);
  }, skip: !sqliteAvailable);

  test('preserves separate durable origins for repair and cache reset', () {
    final repair = syncRunRequestFromLegacy(
      const LibrarySyncRequest.repair(),
    );
    final reset = syncRunRequestFromLegacy(
      const LibrarySyncRequest.cacheReset(),
    );

    expect(repair.intent, SyncRunIntent.repairLibrary);
    expect(repair.origin, SyncRunOrigin.settingsRepair);
    expect(reset.intent, SyncRunIntent.repairLibrary);
    expect(reset.origin, SyncRunOrigin.cacheReset);
    expect(repair.coalescingKey, isNot(reset.coalescingKey));
  });

  test(
    'restart recovery returns only typed running requests to the queue',
    () async {
      final now = DateTime.utc(2026, 8, 26, 10);
      const request = SyncRunRequest(
        contractVersion: SyncRunRequest.currentContractVersion,
        origin: SyncRunOrigin.interaction,
        intent: SyncRunIntent.targetHydration,
        target: LibrarySyncTarget.album('album-1'),
        networkGrant: SyncNetworkGrant.none,
        priority: 100,
      );
      const plan = SyncExecutionPlan(
        request: request,
        kind: SyncExecutionPlanKind.targetHydration,
        reason: SyncSafeReason.none,
        budget: SyncExecutionBudget(
          allowedEndpoints: <SyncEndpoint>{SyncEndpoint.album},
          maxNewestPages: 0,
          maxAlbumHydrations: 1,
          maxResponseBytes: 16 * 1024 * 1024,
          maxTotalBytes: 32 * 1024 * 1024,
          maxConcurrency: 1,
        ),
      );
      final queued = await database.librarySyncDao.enqueueSyncRun(
        serverId: 1,
        plan: plan,
        now: now,
      );
      final interrupted = await database.librarySyncDao.beginSyncRunAttempt(
        requestId: queued.id,
        androidWorker: false,
        now: now,
      );
      await database.librarySyncDao.writeAttemptTelemetry(interrupted.id, {
        'version': 1,
        'captureComplete': false,
      });

      await database.librarySyncDao.recoverInterruptedSyncRuns(1, now: now);

      final row = await (database.select(
        database.librarySyncRunRequestTable,
      )..where((table) => table.id.equals(queued.id))).getSingle();
      expect(row.status, 0);
      final attempts = await (database.select(
        database.librarySyncRunAttemptTable,
      )..where((table) => table.requestId.equals(queued.id))).get();
      expect(attempts.single.status, 1);
      expect(
        attempts.single.telemetryJson,
        contains('"captureComplete":false'),
      );
    },
    skip: !sqliteAvailable,
  );

  test(
    'imports legacy running repair work as a recoverable typed request',
    () async {
      final now = DateTime.utc(2026, 8, 26, 10);
      await database.librarySyncDao.enqueueWork(
        serverId: 1,
        kind: 'fullRepair',
        priority: 80,
        now: now,
      );
      final legacy = (await database.librarySyncDao.getRunnableWork(
        serverId: 1,
        now: now,
      )).single;
      await database.librarySyncDao.markRunning(legacy.id, now: now);

      await database.librarySyncDao.migrateLegacySyncWork(1, now: now);

      final rows = await database
          .select(database.librarySyncRunRequestTable)
          .get();
      expect(rows, hasLength(1));
      expect(rows.single.origin, SyncRunOrigin.legacyRecovery.index);
      expect(rows.single.intent, SyncRunIntent.repairLibrary.index);
      expect(rows.single.status, 0);
      final attempts = await database
          .select(database.librarySyncRunAttemptTable)
          .get();
      expect(attempts, hasLength(1));
      expect(attempts.single.status, 1);
      expect(
        (await database.librarySyncDao.getOrCreateState(1)).plannerVersion,
        3,
      );
    },
    skip: !sqliteAvailable,
  );

  test('deduplicates work and upgrades interactive priority', () async {
    final now = DateTime.utc(2026, 8, 4);
    await database.librarySyncDao.enqueueWork(
      serverId: 1,
      kind: 'targetedHydration',
      entityId: 'album-1',
      priority: 20,
      workClass: 'background',
      checkpointJson: '{"page":2}',
      now: now,
    );
    await database.librarySyncDao.enqueueWork(
      serverId: 1,
      kind: 'targetedHydration',
      entityId: 'album-1',
      priority: 100,
      workClass: 'interactive',
      now: now.add(const Duration(seconds: 1)),
    );

    final rows = await database.librarySyncDao.getRunnableWork(
      serverId: 1,
      now: now.add(const Duration(minutes: 1)),
    );
    expect(rows, hasLength(1));
    expect(rows.single.priority, 100);
    expect(rows.single.workClass, 'interactive');
    expect(rows.single.checkpointJson, '{"page":2}');
  }, skip: !sqliteAvailable);

  test(
    'cooldown survives ordinary enqueue and manual action releases it',
    () async {
      final now = DateTime.utc(2026, 8, 4);
      await database.librarySyncDao.enqueueWork(
        serverId: 1,
        kind: 'probe',
        priority: 20,
        now: now,
      );
      final work = (await database.librarySyncDao.getRunnableWork(
        serverId: 1,
        now: now,
      )).single;
      await database.librarySyncDao.markFailed(
        work.id,
        errorType: 'TimeoutException',
        notBefore: now.add(const Duration(hours: 1)),
        now: now,
      );

      await database.librarySyncDao.enqueueWork(
        serverId: 1,
        kind: 'probe',
        priority: 20,
        now: now.add(const Duration(minutes: 1)),
      );
      expect(
        await database.librarySyncDao.getRunnableWork(
          serverId: 1,
          now: now.add(const Duration(minutes: 2)),
        ),
        isEmpty,
      );

      await database.librarySyncDao.enqueueWork(
        serverId: 1,
        kind: 'probe',
        priority: 60,
        releaseCooldown: true,
        now: now.add(const Duration(minutes: 3)),
      );
      expect(
        await database.librarySyncDao.getRunnableWork(
          serverId: 1,
          now: now.add(const Duration(minutes: 3)),
        ),
        hasLength(1),
      );
    },
    skip: !sqliteAvailable,
  );

  test(
    'ordinary enqueue preserves a completed task until explicit reactivation',
    () async {
      final now = DateTime.utc(2026, 8, 4);
      await database.librarySyncDao.enqueueWork(
        serverId: 1,
        kind: 'targetedHydration',
        entityId: 'album:album-1',
        priority: 20,
        now: now,
      );
      var work = (await database.librarySyncDao.getRunnableWork(
        serverId: 1,
        now: now,
      )).single;
      await database.librarySyncDao.markFailed(
        work.id,
        errorType: 'TimeoutException',
        notBefore: now,
        now: now,
      );
      await database.librarySyncDao.markCompleted(work.id, now: now);

      await database.librarySyncDao.enqueueWork(
        serverId: 1,
        kind: 'targetedHydration',
        entityId: 'album:album-1',
        priority: 20,
        now: now.add(const Duration(minutes: 1)),
      );
      expect(
        await database.librarySyncDao.getRunnableWork(
          serverId: 1,
          now: now.add(const Duration(minutes: 1)),
        ),
        isEmpty,
      );

      await database.librarySyncDao.enqueueWork(
        serverId: 1,
        kind: 'targetedHydration',
        entityId: 'album:album-1',
        priority: 20,
        reactivateTerminal: true,
        now: now.add(const Duration(minutes: 2)),
      );
      work = (await database.librarySyncDao.getRunnableWork(
        serverId: 1,
        now: now.add(const Duration(minutes: 2)),
      )).single;
      expect(work.attemptCount, 0);
    },
    skip: !sqliteAvailable,
  );

  test(
    'confirmation-blocked work stays terminal until explicit reactivation',
    () async {
      final now = DateTime.utc(2026, 8, 4);
      await database.librarySyncDao.enqueueWork(
        serverId: 1,
        kind: 'fullRepair',
        priority: 80,
        now: now,
      );
      final work = (await database.librarySyncDao.getRunnableWork(
        serverId: 1,
        now: now,
      )).single;
      await database.librarySyncDao.markAwaitingConfirmation(work.id, now: now);

      await database.librarySyncDao.enqueueWork(
        serverId: 1,
        kind: 'fullRepair',
        priority: 80,
        now: now.add(const Duration(minutes: 1)),
      );
      expect(
        await database.librarySyncDao.getRunnableWork(
          serverId: 1,
          now: now.add(const Duration(minutes: 1)),
        ),
        isEmpty,
      );

      await database.librarySyncDao.enqueueWork(
        serverId: 1,
        kind: 'fullRepair',
        priority: 80,
        reactivateTerminal: true,
        now: now.add(const Duration(minutes: 2)),
      );
      expect(
        await database.librarySyncDao.getRunnableWork(
          serverId: 1,
          now: now.add(const Duration(minutes: 2)),
        ),
        hasLength(1),
      );
    },
    skip: !sqliteAvailable,
  );

  test('interrupted running work is restored to the queue', () async {
    final now = DateTime.utc(2026, 8, 4);
    await database.librarySyncDao.enqueueWork(
      serverId: 1,
      kind: 'catalogSnapshot',
      priority: 20,
      now: now,
    );
    final work = (await database.librarySyncDao.getRunnableWork(
      serverId: 1,
      now: now,
    )).single;
    await database.librarySyncDao.markRunning(work.id, now: now);
    expect(await database.librarySyncDao.countPendingWork(1), 1);

    await database.librarySyncDao.resetInterruptedWork(1, now: now);
    final resumed = await database.librarySyncDao.getRunnableWork(
      serverId: 1,
      now: now,
    );
    expect(resumed.single.status, 'queued');
  }, skip: !sqliteAvailable);

  test(
    'execution lease rejects a fresh competing owner and recovers expiry',
    () async {
      final now = DateTime.utc(2026, 8, 12, 10);
      expect(
        await database.librarySyncDao.acquireExecutionLease(
          serverId: 1,
          ownerToken: 'foreground-token',
          ownerKind: 'foreground',
          now: now,
          ttl: const Duration(minutes: 10),
        ),
        isTrue,
      );
      expect(
        await database.librarySyncDao.acquireExecutionLease(
          serverId: 1,
          ownerToken: 'worker-token',
          ownerKind: 'androidWorker',
          now: now.add(const Duration(minutes: 9)),
          ttl: const Duration(minutes: 10),
        ),
        isFalse,
      );
      expect(
        await database.librarySyncDao.acquireExecutionLease(
          serverId: 1,
          ownerToken: 'worker-token',
          ownerKind: 'androidWorker',
          now: now.add(const Duration(minutes: 10)),
          ttl: const Duration(minutes: 10),
        ),
        isTrue,
      );
      final lease = await database.librarySyncDao.getExecutionLease(1);
      expect(lease?.ownerToken, 'worker-token');
      expect(lease?.ownerKind, 'androidWorker');
    },
    skip: !sqliteAvailable,
  );

  test('lease heartbeat and release are ownership guarded', () async {
    final now = DateTime.utc(2026, 8, 12, 10);
    await database.librarySyncDao.acquireExecutionLease(
      serverId: 1,
      ownerToken: 'owner-a',
      ownerKind: 'foreground',
      now: now,
      ttl: const Duration(minutes: 10),
    );

    expect(
      await database.librarySyncDao.heartbeatExecutionLease(
        serverId: 1,
        ownerToken: 'owner-b',
        now: now.add(const Duration(minutes: 1)),
        ttl: const Duration(minutes: 10),
      ),
      isFalse,
    );
    expect(
      await database.librarySyncDao.heartbeatExecutionLease(
        serverId: 1,
        ownerToken: 'owner-a',
        now: now.add(const Duration(minutes: 1)),
        ttl: const Duration(minutes: 10),
      ),
      isTrue,
    );
    await database.librarySyncDao.releaseExecutionLease(
      serverId: 1,
      ownerToken: 'owner-b',
    );
    expect(await database.librarySyncDao.getExecutionLease(1), isNotNull);
    await database.librarySyncDao.releaseExecutionLease(
      serverId: 1,
      ownerToken: 'owner-a',
    );
    expect(await database.librarySyncDao.getExecutionLease(1), isNull);
  }, skip: !sqliteAvailable);

  test(
    'discarding an awaiting repair candidate keeps the committed catalog',
    () async {
      await database.libraryDao.upsertAlbums(<AlbumsTableCompanion>[
        AlbumsTableCompanion.insert(id: 'album-1', name: 'Committed'),
      ]);
      await database.librarySyncCandidateDao.upsertAlbums(
        serverId: 1,
        generation: 8,
        albums: <AlbumsTableCompanion>[
          AlbumsTableCompanion.insert(
            id: 'album-1',
            name: 'Uncommitted candidate',
            songsHydrated: const Value(false),
          ),
        ],
      );
      await database.librarySyncDao.writeState(
        const LibrarySyncStateTableCompanion(
          serverId: Value(1),
          candidateGeneration: Value(8),
          candidateStatus: Value('awaitingDeletionConfirmation'),
          deletionCandidateFingerprint: Value('fingerprint'),
          deletionCandidateCount: Value(1),
        ),
      );
      await database.librarySyncDao.enqueueWork(
        serverId: 1,
        kind: 'fullRepair',
        priority: 80,
      );
      final repair = (await database.librarySyncDao.getRunnableWork(
        serverId: 1,
        now: DateTime.now(),
      )).single;
      await database.librarySyncDao.markAwaitingConfirmation(repair.id);

      expect(
        await database.librarySyncDao.discardAwaitingRepairCandidate(
          serverId: 1,
          generation: 8,
        ),
        isTrue,
      );
      expect(
        (await database.libraryDao.getAlbumById('album-1'))?.name,
        'Committed',
      );
      expect(
        await database.librarySyncCandidateDao.getAlbums(
          serverId: 1,
          generation: 8,
        ),
        isEmpty,
      );
      final state = await database.librarySyncDao.getOrCreateState(1);
      expect(state.candidateGeneration, isNull);
      expect(state.deletionCandidateCount, 0);
      expect(
        await database.librarySyncDao.getWork(
          serverId: 1,
          kind: 'fullRepair',
        ),
        isNull,
      );
    },
    skip: !sqliteAvailable,
  );

  test(
    'cancelled work stays terminal until an explicit action reactivates it',
    () async {
      final now = DateTime.utc(2026, 8, 4);
      await database.librarySyncDao.enqueueWork(
        serverId: 1,
        kind: 'catalogSnapshot',
        priority: 20,
        now: now,
      );
      final work = (await database.librarySyncDao.getRunnableWork(
        serverId: 1,
        now: now,
      )).single;

      await database.librarySyncDao.markCancelled(work.id, now: now);
      expect(
        await database.librarySyncDao.getRunnableWork(serverId: 1, now: now),
        isEmpty,
      );
      expect(await database.librarySyncDao.countPendingWork(1), 0);

      await database.librarySyncDao.enqueueWork(
        serverId: 1,
        kind: 'catalogSnapshot',
        priority: 60,
        reactivateTerminal: true,
        now: now.add(const Duration(minutes: 1)),
      );
      final reactivated = await database.librarySyncDao.getRunnableWork(
        serverId: 1,
        now: now.add(const Duration(minutes: 1)),
      );
      expect(reactivated, hasLength(1));
      expect(reactivated.single.status, 'queued');
      expect(reactivated.single.lastErrorType, isNull);
    },
    skip: !sqliteAvailable,
  );

  test(
    'provider profile persists independently for each server',
    () async {
      await database.librarySyncDao.writeState(
        const LibrarySyncStateTableCompanion(
          serverId: Value(1),
          providerFingerprint: Value('server|1.16.1'),
          conditionalIndexesMode: Value('reliable'),
          bulkSearchMode: Value('supported'),
          bulkSearchQuery: Value('*'),
        ),
      );
      final state = await database.librarySyncDao.getOrCreateState(1);
      expect(state.providerFingerprint, 'server|1.16.1');
      expect(state.conditionalIndexesMode, 'reliable');
      expect(state.bulkSearchQuery, '*');
    },
    skip: !sqliteAvailable,
  );

  test('candidate rows remain isolated from the live catalog', () async {
    await database.libraryDao.upsertAlbums(<AlbumsTableCompanion>[
      AlbumsTableCompanion.insert(id: 'album-1', name: 'Committed'),
    ]);
    await database.librarySyncCandidateDao.upsertAlbums(
      serverId: 1,
      generation: 2,
      albums: <AlbumsTableCompanion>[
        AlbumsTableCompanion.insert(
          id: 'album-1',
          name: 'Candidate',
          songsHydrated: const Value(false),
        ),
      ],
    );

    expect(
      (await database.libraryDao.getAlbumById('album-1'))?.name,
      'Committed',
    );
    expect(
      (await database.librarySyncCandidateDao.getAlbums(
        serverId: 1,
        generation: 2,
      )).single.name,
      'Candidate',
    );
    expect(
      await database.librarySyncCandidateDao.countPendingAlbums(
        serverId: 1,
        generation: 2,
      ),
      1,
    );

    await database.librarySyncCandidateDao.clearGeneration(
      serverId: 1,
      generation: 2,
    );
    expect(
      await database.librarySyncCandidateDao.getAlbums(
        serverId: 1,
        generation: 2,
      ),
      isEmpty,
    );
    expect(
      (await database.libraryDao.getAlbumById('album-1'))?.name,
      'Committed',
    );
  }, skip: !sqliteAvailable);

  test('watchPendingWork streams live queued work counts', () async {
    // Drift propagates table updates on later event-loop turns, so settle
    // on the expected value with a bounded wait instead of fixed pumps.
    Future<void> waitForCount(List<int> counts, int expected) async {
      for (
        var attempt = 0;
        attempt < 100 && (counts.isEmpty || counts.last != expected);
        attempt++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(counts, isNotEmpty);
      expect(counts.last, expected);
    }

    final counts = <int>[];
    final sub = database.librarySyncDao.watchPendingWork(1).listen(counts.add);
    addTearDown(sub.cancel);
    await waitForCount(counts, 0);

    await database.librarySyncDao.enqueueWork(
      serverId: 1,
      kind: 'targetedHydration',
      entityId: 'album:watch-a',
      priority: 30,
    );
    await waitForCount(counts, 1);

    await database.librarySyncDao.enqueueWork(
      serverId: 1,
      kind: 'targetedHydration',
      entityId: 'album:watch-b',
      priority: 30,
    );
    await waitForCount(counts, 2);

    final row = (await database.librarySyncDao.getWork(
      serverId: 1,
      kind: 'targetedHydration',
      entityId: 'album:watch-a',
    ))!;
    await database.librarySyncDao.markCompleted(row.id);
    await waitForCount(counts, 1);
  }, skip: !sqliteAvailable);
}
