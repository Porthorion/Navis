import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/data/server_config_repository.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/library/data/adaptive_library_sync_coordinator.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/domain/sync_run_contract.dart';
import 'package:navis/src/utils/connectivity.dart';

import '../../../../helpers/library_sync_fakes.dart';
import '../../../../helpers/stub_library_sync_engine.dart';
import '../../../../helpers/test_database.dart';

const _serverId = 1;
final _clock = DateTime.utc(2026, 8, 4, 12);
const _snapshot = 'catalogSnapshot';
const _delta = 'deltaReconcile';

const _unmeteredLimitOff = SyncNetworkPolicy(
  networkType: NetworkType.cellular,
  isMetered: true,
  allowsBackgroundSync: true,
  allowsHardProbe: true,
  allowsInteractiveHydration: true,
);
const _restrictedMetered = SyncNetworkPolicy(
  networkType: NetworkType.cellular,
  isMetered: true,
  allowsBackgroundSync: false,
  allowsHardProbe: true,
  allowsInteractiveHydration: true,
);

/// Catalog plans only: a finished run also drains starred/playlist work.
List<LibrarySyncPlanKind> _catalogKinds(StubSyncPlanExecutor executor) => [
  for (final plan in executor.plans)
    if (plan.request.target.kind == LibrarySyncTargetKind.catalog) plan.kind,
];

void main() {
  late NavisDatabase database;
  late ServerConfigRepository repository;
  var playing = false;
  var clock = _clock;

  setUp(() async {
    playing = false;
    clock = _clock;
    database = createTestDatabase();
    repository = ServerConfigRepository(
      database,
      credentials: FakeSyncCredentialStore(),
    );
    await repository.save(
      ServerConfigModel(
        url: 'https://music.example.test',
        username: 'listener',
        password: 'secret',
        apiVersion: '1.16.1',
        lastSynced: _clock.subtract(const Duration(days: 3)),
      ),
    );
    await database.librarySyncDao.writeState(
      const LibrarySyncStateTableCompanion(
        serverId: Value(_serverId),
        currentGeneration: Value(1),
      ),
    );
    // Baseline reconciled at T1; the executor's observation reports T2.
    await database.librarySyncDao.recordScanObservation(
      serverId: _serverId,
      scanInProgress: false,
      supported: true,
      providerScanToken: 'T1',
    );
    await database.librarySyncDao.markScanReconciled(
      serverId: _serverId,
      token: 'T1',
    );
  });

  tearDown(() => database.close());

  StubSyncPlanExecutor executorObserving({
    String? token = 'T2',
    bool scanning = false,
  }) => StubSyncPlanExecutor(
    (plan, {onProgress}) async {
      return LibrarySyncState(
        status: LibrarySyncStatus.succeeded,
        stage: LibrarySyncStage.completed,
        metadataReady: true,
        completedAt: _clock,
      );
    },
    onObserveScan: () => database.librarySyncDao.recordScanObservation(
      serverId: _serverId,
      scanInProgress: scanning,
      supported: true,
      providerScanToken: token,
    ),
  );

  AdaptiveLibrarySyncCoordinator coordinatorFor(
    StubSyncPlanExecutor executor, {
    NetworkType networkType = NetworkType.wifi,
    SyncNetworkPolicy? policy,
  }) => AdaptiveLibrarySyncCoordinator(
    executor: executor,
    database: database,
    serverConfigRepository: repository,
    networkType: policy == null ? networkType : null,
    readSyncNetworkPolicy: policy == null ? null : () => policy,
    staleAfter: const Duration(hours: 1),
    readHasActivePlayback: () => playing,
    now: () => clock,
  );

  Future<void> seedWork(
    String kind, {
    required String status,
    required Duration age,
    int priority = 60,
    DateTime? notBefore,
    String? checkpointJson,
  }) => database
      .into(database.librarySyncWorkTable)
      .insert(
        LibrarySyncWorkTableCompanion.insert(
          serverId: _serverId,
          kind: kind,
          priority: Value(priority),
          status: Value(status),
          notBefore: Value(notBefore),
          checkpointJson: Value(checkpointJson),
          createdAt: _clock.subtract(const Duration(days: 30)),
          updatedAt: _clock.subtract(age),
        ),
      );

  Future<LibrarySyncWorkTableData?> work(String kind) =>
      database.librarySyncDao.getWork(serverId: _serverId, kind: kind);

  Future<String> scanRank() async {
    final row = await database.librarySyncDao.getScanObservation(_serverId);
    return '${row!.observedToken}/${row.reconciledToken}/'
        '${row.pendingReconciliation}';
  }

  const manual = LibrarySyncRequest.checkForUpdates();
  const automatic = LibrarySyncRequest.automatic();

  group('a new unreconciled scan', () {
    test(
      'manual check outranks a queued partial delta with a catalog snapshot',
      () async {
        await seedWork(
          _delta,
          status: 'queued',
          age: const Duration(hours: 5),
          priority: 60, // a manual check queues its delta at 60
        );
        final executor = executorObserving();

        final result = await coordinatorFor(executor).requestSync(manual);

        expect(executor.observeScanCalls, 1);
        expect(_catalogKinds(executor), [LibrarySyncPlanKind.catalogSnapshot]);
        expect(result.planKind, LibrarySyncPlanKind.catalogSnapshot);
        // The snapshot keeps the manual request and names its scan token.
        expect(
          executor.plans.first.request.intent,
          SyncRunIntent.manualCatalogCheck,
        );
        final row = await work(_snapshot);
        expect(row!.status, 'completed');
        final checkpoint = jsonDecode(row.checkpointJson!) as Map;
        expect(checkpoint['evidenceVersion'], 'T2');
        expect(checkpoint['intent'], 'checkForUpdates');
        // The partial delta is untouched and still queued.
        expect((await work(_delta))!.status, 'queued');
      },
      skip: !sqliteAvailable,
    );

    test('automatic due pass runs it when the last attempt is over 24 h old, '
        'otherwise keeps the delta and the pending scan', () async {
      await seedWork(
        _snapshot,
        status: 'completed',
        age: const Duration(hours: 25),
      );
      final stale = executorObserving();
      await coordinatorFor(stale).requestSync(automatic);
      expect(_catalogKinds(stale), [LibrarySyncPlanKind.catalogSnapshot]);
      expect((await work(_snapshot))!.status, 'completed');
      expect(
        (await work(_snapshot))!.updatedAt
            .isAfter(_clock.subtract(const Duration(hours: 1))),
        isTrue,
      );
    }, skip: !sqliteAvailable);

    test(
      'automatic due pass within 24 h of the last attempt stays on delta',
      () async {
        await seedWork(
          _snapshot,
          status: 'completed',
          age: const Duration(hours: 2),
        );
        final fresh = executorObserving();
        await coordinatorFor(fresh).requestSync(automatic);
        expect(_catalogKinds(fresh), [LibrarySyncPlanKind.deltaReconcile]);
        // No scan request is spent while the throttle forbids a snapshot.
        expect(fresh.observeScanCalls, 0);
        expect(await scanRank(), 'T1/T1/false');
      },
      skip: !sqliteAvailable,
    );

    test('a snapshot attempt over 24 h ago whose scan is already reconciled '
        'only observes', () async {
      await seedWork(
        _snapshot,
        status: 'completed',
        age: const Duration(hours: 30),
      );
      final executor = executorObserving(token: 'T1');
      await coordinatorFor(executor).requestSync(automatic);
      expect(executor.observeScanCalls, 1);
      expect(_catalogKinds(executor), [LibrarySyncPlanKind.deltaReconcile]);
    }, skip: !sqliteAvailable);
  });

  test(
    'an automatic snapshot after a manual one does not inherit manual intent',
    () async {
      var clock = _clock;
      final executor = executorObserving();
      AdaptiveLibrarySyncCoordinator at(DateTime Function() now) =>
          AdaptiveLibrarySyncCoordinator(
            executor: executor,
            database: database,
            serverConfigRepository: repository,
            networkType: NetworkType.wifi,
            staleAfter: const Duration(hours: 1),
            readHasActivePlayback: () => playing,
            now: now,
          );
      final sync = at(() => clock);
      await sync.requestSync(manual);
      expect(_catalogKinds(executor), [LibrarySyncPlanKind.catalogSnapshot]);

      // 25 h later the server has scanned again; the automatic pass queues a
      // fresh snapshot that must stay automatic (and so defer in playback).
      clock = clock.add(const Duration(hours: 25));
      await database.librarySyncDao.recordScanObservation(
        serverId: _serverId,
        scanInProgress: false,
        supported: true,
        providerScanToken: 'T3',
      );
      final later = executorObserving(token: 'T3');
      await AdaptiveLibrarySyncCoordinator(
        executor: later,
        database: database,
        serverConfigRepository: repository,
        networkType: NetworkType.wifi,
        staleAfter: const Duration(hours: 1),
        readHasActivePlayback: () => playing,
        now: () => clock,
      ).requestSync(automatic);
      final plan = later.plans.firstWhere(
        (plan) => plan.kind == LibrarySyncPlanKind.catalogSnapshot,
      );
      expect(plan.request.intent, SyncRunIntent.automaticCatalogCheck);
    },
    skip: !sqliteAvailable,
  );

  group('network gates', () {
    for (final (name, policy, request) in [
      ('restricted metered, automatic', _restrictedMetered, automatic),
      ('restricted metered, manual', _restrictedMetered, manual),
      (
        'metered with unmetered-only off, automatic',
        _unmeteredLimitOff,
        automatic,
      ),
      ('metered with unmetered-only off, manual', _unmeteredLimitOff, manual),
    ]) {
      test('$name never observes or enqueues a snapshot', () async {
        final executor = executorObserving();
        await coordinatorFor(executor, policy: policy).requestSync(request);
        expect(executor.observeScanCalls, 0);
        expect(await work(_snapshot), isNull);
        expect(
          _catalogKinds(executor),
          isNot(contains(LibrarySyncPlanKind.catalogSnapshot)),
        );
        expect(await scanRank(), 'T1/T1/false');
      }, skip: !sqliteAvailable);
    }

    test('restricted metered keeps the probe plan', () async {
      final executor = executorObserving();
      final result = await coordinatorFor(
        executor,
        policy: _restrictedMetered,
      ).requestSync(automatic);
      expect(result.planKind, LibrarySyncPlanKind.probe);
    }, skip: !sqliteAvailable);

    test('metered with the one-time broad grant runs the snapshot', () async {
      final executor = executorObserving();
      await coordinatorFor(executor, policy: _unmeteredLimitOff).requestSync(
        const LibrarySyncRequest.checkForUpdates(
          grant: SyncNetworkGrant.broadMeteredOnce,
        ),
      );
      expect(_catalogKinds(executor), [LibrarySyncPlanKind.catalogSnapshot]);
    }, skip: !sqliteAvailable);

    test('offline does not observe', () async {
      final executor = executorObserving();
      await coordinatorFor(
        executor,
        networkType: NetworkType.offline,
      ).requestSync(manual);
      expect(executor.observeScanCalls, 0);
      expect(await work(_snapshot), isNull);
    }, skip: !sqliteAvailable);

    test(
      'active playback stops the automatic pass but not the manual one',
      () async {
        playing = true;
        final auto = executorObserving();
        await coordinatorFor(auto).requestSync(automatic);
        expect(auto.observeScanCalls, 0);
        expect(await work(_snapshot), isNull);

        final explicit = executorObserving();
        await coordinatorFor(explicit).requestSync(manual);
        expect(_catalogKinds(explicit), [LibrarySyncPlanKind.catalogSnapshot]);
      },
      skip: !sqliteAvailable,
    );

    test('an automatic pass that is not due does not observe', () async {
      await database.librarySyncDao.writeState(
        LibrarySyncStateTableCompanion(
          serverId: const Value(_serverId),
          lastCheckedAt: Value(_clock.subtract(const Duration(minutes: 5))),
        ),
      );
      final executor = executorObserving();
      await coordinatorFor(executor).requestSync(automatic);
      expect(executor.observeScanCalls, 0);
      expect(await work(_snapshot), isNull);
    }, skip: !sqliteAvailable);
  });

  group('state of the snapshot work', () {
    test('a running scan (no token) enqueues nothing', () async {
      final executor = executorObserving(token: null, scanning: true);
      await coordinatorFor(executor).requestSync(manual);
      expect(executor.observeScanCalls, 1);
      expect(await work(_snapshot), isNull);
      expect(_catalogKinds(executor), [LibrarySyncPlanKind.deltaReconcile]);
    }, skip: !sqliteAvailable);

    test('a snapshot cancelled within 24 h is not re-enqueued automatically, '
        'but a manual check reactivates it', () async {
      await seedWork(
        _snapshot,
        status: 'cancelled',
        age: const Duration(minutes: 10),
      );
      final auto = executorObserving();
      await coordinatorFor(auto).requestSync(automatic);
      expect((await work(_snapshot))!.status, 'cancelled');
      expect(
        _catalogKinds(auto),
        isNot(contains(LibrarySyncPlanKind.catalogSnapshot)),
      );

      final explicit = executorObserving();
      await coordinatorFor(explicit).requestSync(manual);
      expect(_catalogKinds(explicit), [LibrarySyncPlanKind.catalogSnapshot]);
      expect((await work(_snapshot))!.status, 'completed');
    }, skip: !sqliteAvailable);

    test('a snapshot awaiting deletion confirmation is neither observed nor '
        're-collected', () async {
      await database.librarySyncDao.writeState(
        const LibrarySyncStateTableCompanion(
          serverId: Value(_serverId),
          candidateGeneration: Value(2),
          candidateStatus: Value('awaitingDeletionConfirmation'),
        ),
      );
      await seedWork(
        _snapshot,
        status: 'awaitingConfirmation',
        age: const Duration(days: 2),
      );
      for (final request in [automatic, manual]) {
        final executor = executorObserving();
        await coordinatorFor(executor).requestSync(request);
        expect(executor.observeScanCalls, 0, reason: '${request.intent}');
        expect(
          _catalogKinds(executor),
          isNot(contains(LibrarySyncPlanKind.catalogSnapshot)),
        );
      }
      expect((await work(_snapshot))!.status, 'awaitingConfirmation');
    }, skip: !sqliteAvailable);

    test('a failed snapshot keeps its backoff for automatic passes and is '
        'released by a manual check', () async {
      final retryAt = _clock.add(const Duration(hours: 2));
      await seedWork(
        _snapshot,
        status: 'failed',
        age: const Duration(days: 2),
        notBefore: retryAt,
      );
      final auto = executorObserving();
      await coordinatorFor(auto).requestSync(automatic);
      expect(_catalogKinds(auto), [LibrarySyncPlanKind.deltaReconcile]);
      final held = await work(_snapshot);
      expect(held!.status, 'failed');
      expect(held.notBefore!.isAtSameMomentAs(retryAt), isTrue);

      final explicit = executorObserving();
      await coordinatorFor(explicit).requestSync(manual);
      expect(_catalogKinds(explicit), [LibrarySyncPlanKind.catalogSnapshot]);
      expect((await work(_snapshot))!.status, 'completed');
    }, skip: !sqliteAvailable);

    test('Repair Library skips the trigger', () async {
      final executor = executorObserving();
      await coordinatorFor(executor).requestSync(
        const LibrarySyncRequest(
          origin: SyncRunOrigin.settingsRepair,
          intent: SyncRunIntent.repairLibrary,
        ),
      );
      expect(executor.observeScanCalls, 0);
      expect(await work(_snapshot), isNull);
    }, skip: !sqliteAvailable);

    test('a first sync without a baseline does not take the trigger', () async {
      await database.librarySyncDao.writeState(
        const LibrarySyncStateTableCompanion(
          serverId: Value(_serverId),
          currentGeneration: Value(0),
        ),
      );
      await (database.update(database.serverConfigTable))
          .write(const ServerConfigTableCompanion(lastSynced: Value(null)));
      final executor = executorObserving();
      await coordinatorFor(executor).requestSync(manual);
      expect(executor.observeScanCalls, 0);
    }, skip: !sqliteAvailable);
  });

  StubSyncPlanExecutor executorReturning(
    LibrarySyncState Function(SyncExecutionPlan plan) result,
  ) => StubSyncPlanExecutor(
    (plan, {onProgress}) async => result(plan),
    onObserveScan: () => database.librarySyncDao.recordScanObservation(
      serverId: _serverId,
      scanInProgress: false,
      supported: true,
      providerScanToken: 'T2',
    ),
  );

  const evidence = '{"intent":null,"evidenceVersion":"T2"}';

  group('a queued scan snapshot on metered data (W2)', () {
    test('needs the one-time broad grant, for manual and automatic', () async {
      await seedWork(
        _snapshot,
        status: 'queued',
        age: const Duration(minutes: 30),
        checkpointJson: evidence,
      );
      for (final request in [manual, automatic]) {
        final executor = executorObserving();
        await coordinatorFor(
          executor,
          policy: _unmeteredLimitOff,
        ).requestSync(request);
        expect(
          _catalogKinds(executor),
          isNot(contains(LibrarySyncPlanKind.catalogSnapshot)),
          reason: '${request.intent}',
        );
        // The queued snapshot must not block the ordinary pass behind it.
        expect(
          _catalogKinds(executor),
          isNotEmpty,
          reason: '${request.intent}',
        );
      }
      final granted = executorObserving();
      await coordinatorFor(granted, policy: _unmeteredLimitOff).requestSync(
        const LibrarySyncRequest.checkForUpdates(
          grant: SyncNetworkGrant.broadMeteredOnce,
        ),
      );
      expect(_catalogKinds(granted), [LibrarySyncPlanKind.catalogSnapshot]);
    }, skip: !sqliteAvailable);

    test('a first-setup snapshot row is not affected', () async {
      await seedWork(
        _snapshot,
        status: 'queued',
        age: const Duration(minutes: 30),
      );
      final executor = executorObserving();
      await coordinatorFor(
        executor,
        policy: _unmeteredLimitOff,
      ).requestSync(manual);
      expect(_catalogKinds(executor), [LibrarySyncPlanKind.catalogSnapshot]);
    }, skip: !sqliteAvailable);

    test('a Wi-Fi to cellular flip mid-run defers it', () async {
      var policy = const SyncNetworkPolicy(
        networkType: NetworkType.wifi,
        isMetered: false,
        allowsBackgroundSync: true,
        allowsHardProbe: true,
        allowsInteractiveHydration: true,
      );
      final executor = executorObserving();
      final coordinator = AdaptiveLibrarySyncCoordinator(
        executor: StubSyncPlanExecutor(
          (plan, {onProgress}) async {
            expect(plan.scanTriggered, isTrue);
            return LibrarySyncState(
              status: LibrarySyncStatus.succeeded,
              stage: LibrarySyncStage.completed,
              metadataReady: true,
              completedAt: clock,
            );
          },
          onObserveScan: () async {
            await executor.observeServerScan(_serverId);
            policy = _unmeteredLimitOff;
          },
        ),
        database: database,
        serverConfigRepository: repository,
        readSyncNetworkPolicy: () => policy,
        staleAfter: const Duration(hours: 1),
        readHasActivePlayback: () => false,
        now: () => clock,
      );
      // Admitted at enqueue on Wi-Fi, then the network turns metered before
      // the run starts: it must not run.
      await coordinator.requestSync(manual);
      expect(
        (await work(_snapshot))?.status,
        isNot('completed'),
        reason: 'the metered flip stops the run',
      );
    }, skip: !sqliteAvailable);
  });

  group('failed snapshots (W3)', () {
    LibrarySyncState failingSnapshot(SyncExecutionPlan plan) =>
        plan.kind == LibrarySyncPlanKind.catalogSnapshot
        ? LibrarySyncState(
            status: LibrarySyncStatus.failed,
            stage: LibrarySyncStage.completed,
            failureCategory: 'sync',
            completedAt: clock,
          )
        : LibrarySyncState(
            status: LibrarySyncStatus.succeeded,
            stage: LibrarySyncStage.completed,
            metadataReady: true,
            completedAt: clock,
          );

    test(
      'an automatic retry waits 24 h from the attempt, manual does not',
      () async {
        final executor = executorReturning(failingSnapshot);
        int snapshots() =>
            _catalogKinds(executor)
                .where((k) => k == LibrarySyncPlanKind.catalogSnapshot)
                .length;
        final sync = coordinatorFor(executor);

        await sync.requestSync(automatic);
        expect(snapshots(), 1);
        expect((await work(_snapshot))!.status, 'failed');

        clock = clock.add(const Duration(hours: 1));
        await sync.requestSync(automatic);
        expect(snapshots(), 1, reason: 'backoff over, but within 24 h');

        clock = clock.add(const Duration(hours: 2));
        await sync.requestSync(manual);
        expect(snapshots(), 2, reason: 'a manual check may retry');

        clock = clock.add(const Duration(hours: 5));
        await sync.requestSync(automatic);
        expect(snapshots(), 2);

        clock = clock.add(const Duration(hours: 25));
        await sync.requestSync(automatic);
        expect(snapshots(), 3);
      },
      skip: !sqliteAvailable,
    );

    test('an incomplete snapshot is neither a successful check nor a circuit reset', () async {
      await database.librarySyncDao.writeState(
        const LibrarySyncStateTableCompanion(
          serverId: Value(_serverId),
          failureStreak: Value(2),
        ),
      );
      final executor = executorReturning(
        (plan) => plan.kind == LibrarySyncPlanKind.catalogSnapshot
            ? LibrarySyncState(
                status: LibrarySyncStatus.partial,
                stage: LibrarySyncStage.completed,
                metadataReady: true,
                candidateGeneration: 2,
                candidateStatus: 'collecting',
                completedAt: clock,
              )
            : LibrarySyncState(
                status: LibrarySyncStatus.succeeded,
                stage: LibrarySyncStage.completed,
                metadataReady: true,
                completedAt: clock,
              ),
      );

      await coordinatorFor(executor).requestSync(manual);

      final state = await database.librarySyncDao.getOrCreateState(_serverId);
      expect(state.failureStreak, 2);
      expect(state.lastCheckedAt, isNull);
      expect((await work(_snapshot))!.status, 'failed');
    }, skip: !sqliteAvailable);
  });

  group('a promotion that waits for a quiet server (W4)', () {
    LibrarySyncState waiting(SyncExecutionPlan plan) =>
        plan.kind == LibrarySyncPlanKind.catalogSnapshot
        ? LibrarySyncState(
            status: LibrarySyncStatus.deferred,
            stage: LibrarySyncStage.collectingCandidate,
            metadataReady: true,
            candidateGeneration: 2,
            candidateStatus: 'collecting',
            failureCategory: 'scanChanged',
            completedAt: clock,
          )
        : LibrarySyncState(
            status: LibrarySyncStatus.succeeded,
            stage: LibrarySyncStage.completed,
            metadataReady: true,
            completedAt: clock,
          );

    test(
      'stays queued with a short backoff and is reported as deferred',
      () async {
        final checked = _clock.subtract(const Duration(hours: 5));
        await database.librarySyncDao.writeState(
          LibrarySyncStateTableCompanion(
            serverId: const Value(_serverId),
            lastCheckedAt: Value(checked),
            lastCatalogSyncedAt: Value(checked),
          ),
        );
        final executor = executorReturning(waiting);
        int snapshots() =>
            _catalogKinds(executor)
                .where((k) => k == LibrarySyncPlanKind.catalogSnapshot)
                .length;
        final sync = coordinatorFor(executor);

        final result = await sync.requestSync(manual);

        expect(result.status, LibrarySyncStatus.deferred);
        expect(result.updatesAvailable, isFalse);
        final row = (await work(_snapshot))!;
        expect(row.status, 'queued');
        expect(
          row.notBefore!.difference(clock),
          const Duration(minutes: 15),
          reason: 'the first backoff step',
        );
        final state = await database.librarySyncDao.getOrCreateState(_serverId);
        expect(state.lastCheckedAt!.isAtSameMomentAs(checked), isTrue);
        expect(state.lastCatalogSyncedAt!.isAtSameMomentAs(checked), isTrue);
        final history = await database.librarySyncDao.getRecentSyncRunHistory(
          _serverId,
        );
        final catalogRun = history.firstWhere(
          (run) => run.targetKind == LibrarySyncTargetKind.catalog,
        );
        expect(catalogRun.outcome, SyncRunOutcomeKind.deferred);
        expect(catalogRun.reason, SyncSafeReason.scanChanged);

        // Inside the backoff nothing re-collects; after it the next eligible
        // pass does, without waiting 24 h.
        clock = clock.add(const Duration(minutes: 5));
        await sync.requestSync(automatic);
        expect(snapshots(), 1);
        clock = clock.add(const Duration(minutes: 11));
        await sync.requestSync(automatic);
        expect(snapshots(), 2);
      },
      skip: !sqliteAvailable,
    );

    test('a manual check retries inside the backoff', () async {
      final executor = executorReturning(waiting);
      final sync = coordinatorFor(executor);
      await sync.requestSync(manual);
      clock = clock.add(const Duration(minutes: 1));
      await sync.requestSync(manual);
      expect(
        _catalogKinds(executor)
            .where((k) => k == LibrarySyncPlanKind.catalogSnapshot),
        hasLength(2),
      );
    }, skip: !sqliteAvailable);
  });

  group('the attempt clock', () {
    test(
      'a snapshot stamped in the future (clock moved back) is due',
      () async {
        await seedWork(
          _snapshot,
          status: 'completed',
          age: const Duration(hours: -2),
        );
        final executor = executorObserving();
        await coordinatorFor(executor).requestSync(automatic);
        expect(_catalogKinds(executor), [LibrarySyncPlanKind.catalogSnapshot]);
      },
      skip: !sqliteAvailable,
    );

    test(
      'a failed row with the same scan evidence is released by a manual check',
      () async {
        await seedWork(
          _snapshot,
          status: 'failed',
          age: const Duration(hours: 1),
          notBefore: _clock.add(const Duration(hours: 3)),
          checkpointJson: evidence,
        );
        final executor = executorObserving();
        await coordinatorFor(executor).requestSync(manual);
        expect(_catalogKinds(executor), [LibrarySyncPlanKind.catalogSnapshot]);
      },
      skip: !sqliteAvailable,
    );

    test('a completed snapshot for the same scan is reactivated, automatic after 30 h and manual after a minute', () async {
      await seedWork(
        _snapshot,
        status: 'completed',
        age: const Duration(hours: 30),
        checkpointJson: evidence,
      );
      final auto = executorObserving();
      await coordinatorFor(auto).requestSync(automatic);
      expect(_catalogKinds(auto), [LibrarySyncPlanKind.catalogSnapshot]);

      await database.librarySyncDao.recordScanObservation(
        serverId: _serverId,
        scanInProgress: false,
        supported: true,
        providerScanToken: 'T2',
      );
      await (database.update(database.librarySyncWorkTable)).write(
        LibrarySyncWorkTableCompanion(
          status: const Value('completed'),
          updatedAt: Value(clock.subtract(const Duration(minutes: 1))),
        ),
      );
      final explicit = executorObserving();
      await coordinatorFor(explicit).requestSync(manual);
      expect(_catalogKinds(explicit), [LibrarySyncPlanKind.catalogSnapshot]);
    }, skip: !sqliteAvailable);
  });

  group('a server that keeps rescanning (X2)', () {
    test(
      'costs at most four automatic passes in a day, then one a day',
      () async {
        var streak = 0;
        final attempts = <DateTime>[];
        final executor = executorReturning((plan) {
          if (plan.kind != LibrarySyncPlanKind.catalogSnapshot) {
            return LibrarySyncState(
              status: LibrarySyncStatus.succeeded,
              stage: LibrarySyncStage.completed,
              metadataReady: true,
              completedAt: clock,
            );
          }
          attempts.add(clock);
          streak++;
          // The engine records the streak next to its other capabilities.
          unawaited(
            database
                .update(database.serverConfigTable)
                .write(
                  ServerConfigTableCompanion(
                    capabilities: Value(
                      jsonEncode({
                        'navis': {'libraryScanDeferralStreak': '$streak'},
                      }),
                    ),
                  ),
                ),
          );
          return LibrarySyncState(
            status: LibrarySyncStatus.deferred,
            stage: LibrarySyncStage.collectingCandidate,
            metadataReady: true,
            candidateGeneration: 2,
            candidateStatus: 'collecting',
            failureCategory: 'scanChanged',
            completedAt: clock,
          );
        });
        final sync = coordinatorFor(executor);

        for (var step = 0; step < 192; step++) {
          await sync.requestSync(automatic);
          await Future<void>.delayed(Duration.zero);
          clock = clock.add(const Duration(minutes: 15));
        }

        final first = attempts.first;
        expect(
          attempts.where(
            (t) => t.difference(first) < const Duration(hours: 24),
          ),
          hasLength(3),
          reason: 'attempts at 0, 15 and 45 minutes, then the daily wait',
        );
        for (var i = 4; i < attempts.length; i++) {
          expect(
            attempts[i].difference(attempts[i - 1]),
            greaterThanOrEqualTo(const Duration(hours: 24)),
            reason: 'attempt $i of ${attempts.length}',
          );
        }
        expect(attempts.length, lessThanOrEqualTo(5));
      },
      skip: !sqliteAvailable,
    );
  });

  group('deferral and confirmation details (X3)', () {
    test(
      'a scan deferral carries no failure category and is flagged',
      () async {
        final executor = executorReturning(
          (plan) => plan.kind == LibrarySyncPlanKind.catalogSnapshot
              ? LibrarySyncState(
                  status: LibrarySyncStatus.deferred,
                  stage: LibrarySyncStage.collectingCandidate,
                  candidateStatus: 'collecting',
                  failureCategory: 'scanChanged',
                  completedAt: clock,
                )
              : LibrarySyncState(
                  status: LibrarySyncStatus.succeeded,
                  stage: LibrarySyncStage.completed,
                  metadataReady: true,
                  completedAt: clock,
                ),
        );
        final result = await coordinatorFor(executor).requestSync(manual);
        expect(result.failureCategory, isNull);
        expect(result.scanDeferred, isTrue);
      },
      skip: !sqliteAvailable,
    );

    test(
      'a snapshot awaiting confirmation still counts as a completed check',
      () async {
        await database.librarySyncDao.writeState(
          const LibrarySyncStateTableCompanion(
            serverId: Value(_serverId),
            failureStreak: Value(2),
          ),
        );
        final executor = executorReturning(
          (plan) => plan.kind == LibrarySyncPlanKind.catalogSnapshot
              ? LibrarySyncState(
                  status: LibrarySyncStatus.partial,
                  stage: LibrarySyncStage.completed,
                  metadataReady: true,
                  candidateGeneration: 2,
                  candidateStatus: 'awaitingDeletionConfirmation',
                  completedAt: clock,
                )
              : LibrarySyncState(
                  status: LibrarySyncStatus.succeeded,
                  stage: LibrarySyncStage.completed,
                  metadataReady: true,
                  completedAt: clock,
                ),
        );
        await coordinatorFor(executor).requestSync(manual);
        final state = await database.librarySyncDao.getOrCreateState(_serverId);
        expect(state.failureStreak, 0);
        expect(state.lastCheckedAt, isNotNull);
        expect((await work(_snapshot))!.status, 'awaitingConfirmation');
      },
      skip: !sqliteAvailable,
    );
  });
}
