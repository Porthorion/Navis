import 'dart:async';
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

  test('in-flight sync state write queued behind a wipe is a no-op', () async {
    await database.librarySyncDao.getOrCreateState(1);
    final wiping = Completer<void>();
    final release = Completer<void>();
    final wipe = database.transaction(() async {
      await database.serverDao.clearServer();
      wiping.complete();
      await release.future;
    });
    await wiping.future;
    final write = database.librarySyncDao.setNextAutomaticCheckAt(
      serverId: 1,
      nextAutomaticCheckAt: DateTime.utc(2026, 10, 10),
    );
    final completed = expectLater(write, completes);
    release.complete();
    await wipe;
    await completed;
    expect(
      await database.select(database.librarySyncStateTable).get(),
      isEmpty,
    );
  }, skip: !sqliteAvailable);

  for (final write in <String, Future<void> Function()>{
    'state upsert': () => database.librarySyncDao.writeState(
      const LibrarySyncStateTableCompanion(
        serverId: Value(1),
        currentGeneration: Value(2),
      ),
    ),
    'Android capability': () => database.librarySyncDao
        .setAndroidBackgroundSyncEnabled(serverId: 1, enabled: true),
    'Android worker outcome': () => database.librarySyncDao
        .writeAndroidBackgroundStatus(serverId: 1, workerResult: 'succeeded'),
    'automatic deadline': () => database.librarySyncDao.setNextAutomaticCheckAt(
      serverId: 1,
      nextAutomaticCheckAt: DateTime.utc(2026, 10, 10),
    ),
  }.entries) {
    test('late ${write.key} is a no-op for a deleted server', () async {
      await database.librarySyncDao.getOrCreateState(1);
      await database.serverDao.clearServer();
      await write.value();
      expect(
        await database.select(database.librarySyncStateTable).get(),
        isEmpty,
      );
    }, skip: !sqliteAvailable);
  }

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
    const request = LibrarySyncRequest(
      origin: SyncRunOrigin.libraryPullToRefresh,
      intent: SyncRunIntent.manualCatalogCheck,
      target: LibrarySyncTarget.catalog(),
      grant: SyncNetworkGrant.boundedMeteredDiscovery,
    );
    const plan = SyncExecutionPlan(
      request: request,
      kind: LibrarySyncPlanKind.deltaReconcile,
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

    final attempt = (await database.librarySyncDao.beginSyncRunAttempt(
      requestId: queued.id,
      androidWorker: false,
      now: now,
    ))!;
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

  test('a finished request is never reopened by a late attempt', () async {
    final now = DateTime.utc(2026, 8, 26, 10);
    const plan = SyncExecutionPlan(
      request: LibrarySyncRequest(
        origin: SyncRunOrigin.libraryPullToRefresh,
        intent: SyncRunIntent.manualCatalogCheck,
        target: LibrarySyncTarget.catalog(),
        grant: SyncNetworkGrant.none,
      ),
      kind: LibrarySyncPlanKind.deltaReconcile,
      reason: SyncSafeReason.none,
      budget: SyncExecutionBudget(
        allowedEndpoints: <SyncEndpoint>{SyncEndpoint.indexes},
        maxNewestPages: 1,
        maxAlbumHydrations: 0,
        maxResponseBytes: null,
        maxTotalBytes: null,
        maxConcurrency: 1,
      ),
    );
    final dao = database.librarySyncDao;
    final queued = await dao.enqueueSyncRun(serverId: 1, plan: plan, now: now);
    // Another engine finished the shared request before this one began.
    await dao.completeSyncRun(
      requestId: queued.id,
      outcome: const SyncRunOutcome(
        kind: SyncRunOutcomeKind.deferred,
        reason: SyncSafeReason.leaseHeld,
      ),
      now: now,
    );

    final late = await dao.beginSyncRunAttempt(
      requestId: queued.id,
      androidWorker: false,
      now: now.add(const Duration(seconds: 1)),
    );

    expect(late, isNull);
    final request = await (database.select(
      database.librarySyncRunRequestTable,
    )..where((table) => table.id.equals(queued.id))).getSingle();
    expect(request.status, 2);
    expect(
      await database.select(database.librarySyncRunAttemptTable).get(),
      isEmpty,
    );
    expect(
      await database.select(database.librarySyncRunOutcomeTable).get(),
      hasLength(1),
    );
  });

  test('keeps every historical plan index readable', () async {
    const budget = SyncExecutionBudget(
      allowedEndpoints: <SyncEndpoint>{},
      maxNewestPages: 0,
      maxAlbumHydrations: 0,
      maxResponseBytes: null,
      maxTotalBytes: null,
      maxConcurrency: 1,
    );
    const cases = [
      (LibrarySyncPlanKind.probe, SyncRunIntent.automaticCatalogCheck, 0),
      (LibrarySyncPlanKind.deltaReconcile, SyncRunIntent.manualCatalogCheck, 1),
      (LibrarySyncPlanKind.fullRepair, SyncRunIntent.repairLibrary, 2),
      (LibrarySyncPlanKind.targetedHydration, SyncRunIntent.targetHydration, 3),
      (
        LibrarySyncPlanKind.targetedHydration,
        SyncRunIntent.auxiliaryRefresh,
        4,
      ),
      (
        LibrarySyncPlanKind.catalogSnapshot,
        SyncRunIntent.automaticCatalogCheck,
        5,
      ),
      (
        LibrarySyncPlanKind.compatibilityAudit,
        SyncRunIntent.automaticCatalogCheck,
        6,
      ),
    ];
    for (final (kind, intent, storedIndex) in cases) {
      final queued = await database.librarySyncDao.enqueueSyncRun(
        serverId: 1,
        plan: SyncExecutionPlan(
          request: LibrarySyncRequest(
            origin: SyncRunOrigin.startup,
            intent: intent,
            target: intent == SyncRunIntent.auxiliaryRefresh
                ? const LibrarySyncTarget.starred()
                : intent == SyncRunIntent.targetHydration
                ? const LibrarySyncTarget.album('album')
                : const LibrarySyncTarget.catalog(),
            grant: SyncNetworkGrant.none,
          ),
          kind: kind,
          reason: SyncSafeReason.none,
          budget: budget,
        ),
      );
      final stored = await (database.select(
        database.librarySyncRunRequestTable,
      )..where((row) => row.id.equals(queued.id))).getSingle();
      expect(stored.planKind, storedIndex);
      await database.librarySyncDao.completeSyncRun(
        requestId: queued.id,
        outcome: const SyncRunOutcome(
          kind: SyncRunOutcomeKind.completed,
          reason: SyncSafeReason.none,
        ),
      );
      final history = await database.librarySyncDao.getRecentSyncRunHistory(1);
      expect(
        history.first.planKind,
        const [
          'automaticProbe',
          'manualCatalogDiscovery',
          'repairLibrary',
          'targetHydration',
          'auxiliaryRefresh',
          'catalogSnapshot',
          'compatibilityAudit',
        ][storedIndex],
      );
    }
  }, skip: !sqliteAvailable);

  test('preserves separate durable origins for repair and cache reset', () {
    const repair = LibrarySyncRequest(
      origin: SyncRunOrigin.settingsRepair,
      intent: SyncRunIntent.repairLibrary,
    );
    const reset = LibrarySyncRequest.cacheReset();

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
      const request = LibrarySyncRequest(
        origin: SyncRunOrigin.interaction,
        intent: SyncRunIntent.targetHydration,
        target: LibrarySyncTarget.album('album-1'),
        grant: SyncNetworkGrant.none,
      );
      const plan = SyncExecutionPlan(
        request: request,
        kind: LibrarySyncPlanKind.targetedHydration,
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
      final interrupted = (await database.librarySyncDao.beginSyncRunAttempt(
        requestId: queued.id,
        androidWorker: false,
        now: now,
      ))!;
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
    'terminal request completion is idempotent and omits dead request inputs',
    () async {
      const request = LibrarySyncRequest(
        origin: SyncRunOrigin.settingsRepair,
        intent: SyncRunIntent.repairLibrary,
        grant: SyncNetworkGrant.broadMeteredOnce,
      );
      final queued = await database.librarySyncDao.enqueueSyncRun(
        serverId: 1,
        plan: SyncExecutionPlan(
          request: request,
          kind: LibrarySyncPlanKind.fullRepair,
          reason: SyncSafeReason.none,
          budget: const SyncExecutionBudget(
            allowedEndpoints: {},
            maxNewestPages: 0,
            maxAlbumHydrations: 1,
            maxResponseBytes: null,
            maxTotalBytes: null,
            maxConcurrency: 1,
          ),
        ),
      );
      final stored = await (database.select(
        database.librarySyncRunRequestTable,
      )..where((row) => row.id.equals(queued.id))).getSingle();
      expect(stored.contractVersion, 1);
      expect(stored.priority, 0);
      expect(stored.networkGrant, SyncNetworkGrant.none.index);
      expect(stored.targetKey, isEmpty);
      expect(stored.resumedFromRequestId, isNull);
      final attempt = (await database.librarySyncDao.beginSyncRunAttempt(
        requestId: queued.id,
        androidWorker: false,
      ))!;
      await database.librarySyncDao.completeSyncRun(
        requestId: queued.id,
        attemptId: attempt.id,
        outcome: const SyncRunOutcome(
          kind: SyncRunOutcomeKind.completed,
          reason: SyncSafeReason.none,
        ),
      );
      await database.librarySyncDao.completeSyncRun(
        requestId: queued.id,
        outcome: const SyncRunOutcome(
          kind: SyncRunOutcomeKind.skipped,
          reason: SyncSafeReason.none,
        ),
      );
      final history = await database.librarySyncDao.getRecentSyncRunHistory(1);
      expect(history, hasLength(1));
      expect(history.single.outcome, SyncRunOutcomeKind.completed);
      expect(history.single.attemptId, attempt.id);
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

  test('heartbeat after a stall past the TTL renews an untaken lease', () async {
    final now = DateTime.utc(2026, 8, 12, 10);
    const ttl = Duration(seconds: 1);
    Future<bool> acquire(String token, DateTime at) =>
        database.librarySyncDao.acquireExecutionLease(
          serverId: 1,
          ownerToken: token,
          ownerKind: 'foreground',
          now: at,
          ttl: ttl,
        );
    Future<bool> beat(String token, DateTime at) =>
        database.librarySyncDao.heartbeatExecutionLease(
          serverId: 1,
          ownerToken: token,
          now: at,
          ttl: ttl,
        );
    expect(await acquire('owner-a', now), isTrue);

    final stalled = now.add(const Duration(seconds: 2));
    expect(await beat('owner-b', stalled), isFalse);
    expect(await beat('owner-a', stalled), isTrue);
    expect(
      (await database.librarySyncDao.getExecutionLease(1))!.expiresAt
          .toUtc(),
      stalled.add(ttl),
    );

    // Once the renewed lease expires and another run takes it over, the old
    // owner is fenced out.
    final later = stalled.add(const Duration(seconds: 2));
    expect(await acquire('owner-b', later), isTrue);
    expect(await beat('owner-a', later.add(const Duration(seconds: 1))), isFalse);
    expect(await beat('owner-b', later.add(const Duration(seconds: 1))), isTrue);
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
        await database.librarySyncDao.getWork(serverId: 1, kind: 'fullRepair'),
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

  test('provider profile persists independently for each server', () async {
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
  }, skip: !sqliteAvailable);

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

  group('worker hand-off', () {
    final t0 = DateTime.utc(2026, 10, 15, 10);
    const ttl = Duration(minutes: 10);
    const plan = SyncExecutionPlan(
      request: LibrarySyncRequest.automatic(),
      kind: LibrarySyncPlanKind.catalogSnapshot,
      reason: SyncSafeReason.none,
      budget: SyncExecutionBudget(
        allowedEndpoints: <SyncEndpoint>{SyncEndpoint.catalogAlbums},
        maxNewestPages: 0,
        maxAlbumHydrations: 0,
        maxResponseBytes: null,
        maxTotalBytes: null,
        maxConcurrency: 1,
      ),
    );

    Future<bool> acquire(
      String token,
      String kind,
      DateTime now, {
      int serverId = 1,
      Duration leaseTtl = ttl,
    }) => database.librarySyncDao.acquireExecutionLease(
      serverId: serverId,
      ownerToken: token,
      ownerKind: kind,
      now: now,
      ttl: leaseTtl,
    );

    Future<LibrarySyncWorkTableData> runningWork({int serverId = 1}) async {
      await database.librarySyncDao.enqueueWork(
        serverId: serverId,
        kind: 'catalogSnapshot',
        priority: 20,
        checkpointJson: '{"version":3,"generation":7}',
        now: t0,
      );
      final work = (await database.librarySyncDao.getWork(
        serverId: serverId,
        kind: 'catalogSnapshot',
      ))!;
      await database.librarySyncDao.markFailed(
        work.id,
        errorType: 'transport',
        notBefore: t0.subtract(const Duration(minutes: 1)),
        now: t0,
      );
      await database.librarySyncDao.markRunning(work.id, now: t0);
      return (await database.librarySyncDao.getWork(
        serverId: serverId,
        kind: 'catalogSnapshot',
      ))!;
    }

    Future<(int, int)> runningRequest({int serverId = 1}) async {
      final request = await database.librarySyncDao.enqueueSyncRun(
        serverId: serverId,
        plan: plan,
        now: t0,
      );
      final attempt = (await database.librarySyncDao.beginSyncRunAttempt(
        requestId: request.id,
        androidWorker: true,
        now: t0,
      ))!;
      return (request.id, attempt.id);
    }

    Future<int> requestStatus(int id) async => (await (database.select(
      database.librarySyncRunRequestTable,
    )..where((row) => row.id.equals(id))).getSingle()).status;

    Future<int> attemptStatus(int id) async => (await (database.select(
      database.librarySyncRunAttemptTable,
    )..where((row) => row.id.equals(id))).getSingle()).status;

    Future<List<LibrarySyncRunOutcomeTableData>> outcomes() =>
        database.select(database.librarySyncRunOutcomeTable).get();

    Future<String> workStatus({int serverId = 1}) async =>
        (await database.librarySyncDao.getWork(
          serverId: serverId,
          kind: 'catalogSnapshot',
        ))!.status;

    const outcome = SyncRunOutcome(
      kind: SyncRunOutcomeKind.completed,
      reason: SyncSafeReason.none,
    );

    test('1 a foreground acquirer preempts a live worker lease', () async {
      expect(await acquire('worker', 'androidWorker', t0), isTrue);
      final takeoverAt = t0.add(const Duration(minutes: 1));
      expect(await acquire('foreground', 'foreground', takeoverAt), isTrue);

      final lease = (await database.librarySyncDao.getExecutionLease(1))!;
      expect(lease.ownerToken, 'foreground');
      expect(lease.ownerKind, 'foreground');
      expect(lease.startedAt.toUtc(), takeoverAt);
      expect(
        await database.librarySyncDao.heartbeatExecutionLease(
          serverId: 1,
          ownerToken: 'worker',
          now: takeoverAt.add(const Duration(seconds: 1)),
          ttl: ttl,
        ),
        isFalse,
      );
    }, skip: !sqliteAvailable);

    test('2 a live foreground lease is never preempted and a worker preempts nobody', () async {
      expect(await acquire('foreground', 'foreground', t0), isTrue);
      final later = t0.add(const Duration(minutes: 1));
      expect(await acquire('second-foreground', 'foreground', later), isFalse);
      expect(await acquire('worker', 'androidWorker', later), isFalse);
      final held = (await database.librarySyncDao.getExecutionLease(1))!;
      expect(held.ownerToken, 'foreground');
      expect(held.startedAt.toUtc(), t0);

      await database.librarySyncDao.releaseExecutionLease(
        serverId: 1,
        ownerToken: 'foreground',
      );
      expect(await acquire('worker', 'androidWorker', later), isTrue);
      expect(await acquire('second-worker', 'androidWorker', later), isFalse);
      expect(
        (await database.librarySyncDao.getExecutionLease(1))!.ownerToken,
        'worker',
      );
    }, skip: !sqliteAvailable);

    for (final (previousKind, nextKind) in [
      ('androidWorker', 'foreground'),
      ('foreground', 'androidWorker'),
      ('foreground', 'foreground'),
    ]) {
      test('3 taking over an expired $previousKind lease as $nextKind requeues '
          'its running work unchanged', () async {
        expect(
          await acquire(
            'previous',
            previousKind,
            t0,
            leaseTtl: const Duration(minutes: 1),
          ),
          isTrue,
        );
        final before = await runningWork();
        expect(before.status, 'running');

        expect(
          await acquire('next', nextKind, t0.add(const Duration(minutes: 2))),
          isTrue,
        );

        final after = (await database.librarySyncDao.getWork(
          serverId: 1,
          kind: 'catalogSnapshot',
        ))!;
        expect(after.status, 'queued');
        expect(after.checkpointJson, before.checkpointJson);
        expect(after.attemptCount, 1);
        expect(after.notBefore, before.notBefore);
        expect(after.lastErrorType, 'transport');
      }, skip: !sqliteAvailable);
    }

    test(
      '4 a takeover recovers run requests and attempts without an outcome',
      () async {
        expect(await acquire('worker', 'androidWorker', t0), isTrue);
        final (requestId, attemptId) = await runningRequest();
        expect(await requestStatus(requestId), 1);

        expect(
          await acquire(
            'foreground',
            'foreground',
            t0.add(const Duration(minutes: 1)),
          ),
          isTrue,
        );

        expect(await requestStatus(requestId), 0, reason: 'queued');
        expect(await attemptStatus(attemptId), 1, reason: 'recovered');
        expect(await outcomes(), isEmpty);
      },
      skip: !sqliteAvailable,
    );

    test(
      '5 a clean release does not recover, and recovery stays per server',
      () async {
        // saveServer replaces the only server; recovery is keyed by id.
        await database
            .into(database.serverConfigTable)
            .insert(
              ServerConfigTableCompanion.insert(
                url: 'https://other.example.test',
                username: 'listener',
                apiVersion: '1.16.1',
              ),
            );
        expect(await acquire('first', 'foreground', t0), isTrue);
        await runningWork();
        final (requestId, attemptId) = await runningRequest();
        await database.librarySyncDao.releaseExecutionLease(
          serverId: 1,
          ownerToken: 'first',
        );
        expect(await acquire('second', 'foreground', t0), isTrue);
        expect(await workStatus(), 'running');
        expect(await requestStatus(requestId), 1);
        expect(await attemptStatus(attemptId), 0);

        // A live in-process section on server 2 keeps its running rows when
        // server 1 changes hands.
        expect(await acquire('other', 'foreground', t0, serverId: 2), isTrue);
        await runningWork(serverId: 2);
        final (otherRequest, otherAttempt) = await runningRequest(serverId: 2);
        await database.librarySyncDao.releaseExecutionLease(
          serverId: 1,
          ownerToken: 'second',
        );
        expect(await acquire('worker', 'androidWorker', t0), isTrue);
        expect(
          await acquire(
            'foreground',
            'foreground',
            t0.add(const Duration(minutes: 1)),
          ),
          isTrue,
        );
        expect(await workStatus(), 'queued');
        expect(await workStatus(serverId: 2), 'running');
        expect(await requestStatus(otherRequest), 1);
        expect(await attemptStatus(otherAttempt), 0);
      },
      skip: !sqliteAvailable,
    );

    test('6 a same-token re-acquire does not recover', () async {
      expect(await acquire('owner', 'androidWorker', t0), isTrue);
      await runningWork();
      final (requestId, attemptId) = await runningRequest();

      expect(
        await acquire(
          'owner',
          'androidWorker',
          t0.add(const Duration(minutes: 1)),
        ),
        isTrue,
      );

      expect(await workStatus(), 'running');
      expect(await requestStatus(requestId), 1);
      expect(await attemptStatus(attemptId), 0);
    }, skip: !sqliteAvailable);

    test('7 completing with a recovered attempt is a no-op', () async {
      final (requestId, recovered) = await runningRequest();
      await database.librarySyncDao.recoverInterruptedSyncRuns(1, now: t0);

      await database.librarySyncDao.completeSyncRun(
        requestId: requestId,
        attemptId: recovered,
        outcome: outcome,
        now: t0,
      );
      expect(await requestStatus(requestId), 0, reason: 'still queued');
      expect(await attemptStatus(recovered), 1);
      expect(await outcomes(), isEmpty);

      final current = (await database.librarySyncDao.beginSyncRunAttempt(
        requestId: requestId,
        androidWorker: false,
        now: t0,
      ))!;
      await database.librarySyncDao.completeSyncRun(
        requestId: requestId,
        attemptId: recovered,
        outcome: outcome,
        now: t0,
      );
      expect(await requestStatus(requestId), 1, reason: 'still running');
      expect(await outcomes(), isEmpty);

      await database.librarySyncDao.completeSyncRun(
        requestId: requestId,
        attemptId: current.id,
        outcome: outcome,
        now: t0,
      );
      expect(await requestStatus(requestId), 2);
      expect(await attemptStatus(current.id), 2);
      expect((await outcomes()).single.attemptId, current.id);
    }, skip: !sqliteAvailable);

    test(
      '8 completing without an attempt never terminates a running request',
      () async {
        final (running, attemptId) = await runningRequest();
        await database.librarySyncDao.completeSyncRun(
          requestId: running,
          outcome: outcome,
          now: t0,
        );
        expect(await requestStatus(running), 1);
        expect(await attemptStatus(attemptId), 0);
        expect(await outcomes(), isEmpty);

        // A queued request is still finished by a waiter that never ran it.
        final queued = await database.librarySyncDao.enqueueSyncRun(
          serverId: 1,
          plan: const SyncExecutionPlan(
            request: LibrarySyncRequest.checkForUpdates(),
            kind: LibrarySyncPlanKind.deltaReconcile,
            reason: SyncSafeReason.none,
            budget: SyncExecutionBudget(
              allowedEndpoints: <SyncEndpoint>{SyncEndpoint.indexes},
              maxNewestPages: 1,
              maxAlbumHydrations: 0,
              maxResponseBytes: null,
              maxTotalBytes: null,
              maxConcurrency: 1,
            ),
          ),
          now: t0,
        );
        await database.librarySyncDao.completeSyncRun(
          requestId: queued.id,
          outcome: outcome,
          now: t0,
        );
        expect(await requestStatus(queued.id), 2);
        expect((await outcomes()).single.requestId, queued.id);
      },
      skip: !sqliteAvailable,
    );

    test(
      '9 a worker heartbeat just before the takeover still loses the lease',
      () async {
        expect(await acquire('worker', 'androidWorker', t0), isTrue);
        final beat = t0.add(const Duration(minutes: 1));
        expect(
          await database.librarySyncDao.heartbeatExecutionLease(
            serverId: 1,
            ownerToken: 'worker',
            now: beat,
            ttl: ttl,
          ),
          isTrue,
        );
        final takeoverAt = beat.add(const Duration(seconds: 1));
        expect(await acquire('foreground', 'foreground', takeoverAt), isTrue);
        expect(
          await database.librarySyncDao.heartbeatExecutionLease(
            serverId: 1,
            ownerToken: 'worker',
            now: takeoverAt.add(const Duration(seconds: 1)),
            ttl: ttl,
          ),
          isFalse,
        );
        expect(await acquire('worker', 'androidWorker', takeoverAt), isFalse);
        expect(
          (await database.librarySyncDao.getExecutionLease(1))!.ownerToken,
          'foreground',
        );
      },
      skip: !sqliteAvailable,
    );
  });
}
