import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/data/server_config_repository.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/library/data/adaptive_library_sync_coordinator.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
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

  setUp(() async {
    playing = false;
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
    now: () => _clock,
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
          priority: 50,
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
}
