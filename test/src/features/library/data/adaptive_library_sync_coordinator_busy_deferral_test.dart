import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
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

/// Fails chosen writes with SQLITE_BUSY, the error a writer lock held past the
/// busy handler produces. Lease acquires and releases are counted (1-based).
class _LockFaults extends QueryInterceptor {
  final failAcquires = <int>{};
  final failReleases = <int>{};
  bool failFirstRunRequestInsert = false;
  int acquires = 0;
  int releases = 0;

  Never _fail() => throw SqliteException(
    extendedResultCode: 5,
    message: 'database is locked',
  );

  @override
  Future<void> runCustom(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    if (statement.contains('INSERT INTO library_sync_execution_lease') &&
        failAcquires.contains(++acquires)) {
      _fail();
    }
    return executor.runCustom(statement, args);
  }

  @override
  Future<int> runDelete(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    if (statement.contains('DELETE FROM "library_sync_execution_lease"') &&
        failReleases.contains(++releases)) {
      _fail();
    }
    return executor.runDelete(statement, args);
  }

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    if (failFirstRunRequestInsert &&
        statement.contains('library_sync_run_request')) {
      failFirstRunRequestInsert = false;
      _fail();
    }
    return executor.runInsert(statement, args);
  }
}

void main() {
  final now = DateTime.utc(2026, 8, 4);
  const repair = LibrarySyncRequest(
    origin: SyncRunOrigin.settingsRepair,
    intent: SyncRunIntent.repairLibrary,
  );
  late _LockFaults faults;
  late NavisDatabase database;
  late AdaptiveLibrarySyncCoordinator coordinator;

  setUp(() async {
    faults = _LockFaults();
    database = NavisDatabase(NativeDatabase.memory().interceptWith(faults));
    final repository = ServerConfigRepository(
      database,
      credentials: FakeSyncCredentialStore(),
    );
    await repository.save(
      const ServerConfigModel(
        url: 'https://music.example.test',
        username: 'listener',
        password: 'secret',
        apiVersion: '1.16.1',
      ),
    );
    coordinator = AdaptiveLibrarySyncCoordinator(
      executor: StubSyncPlanExecutor(
        (plan, {onProgress}) async => LibrarySyncState(
          status: LibrarySyncStatus.succeeded,
          stage: LibrarySyncStage.completed,
          metadataReady: true,
          completedAt: now,
        ),
      ),
      database: database,
      serverConfigRepository: repository,
      networkType: NetworkType.wifi,
      staleAfter: const Duration(hours: 1),
      readHasActivePlayback: () => false,
      now: () => now,
      leaseReleaseRetryDelays: const [
        Duration(milliseconds: 10),
        Duration(milliseconds: 20),
      ],
    );
  });

  tearDown(() => database.close());

  void expectBusyDeferral(LibrarySyncState state) {
    expect(state.status, LibrarySyncStatus.deferred);
    expect(state.planReason, 'leaseHeld');
    expect(state.failureCategory, 'databaseBusy');
    expect(state.nextRetryAt?.toUtc(), now.add(databaseBusyRetryDelay));
  }

  test(
    'a lock timeout on the first write of a request is a busy deferral',
    () async {
      faults.failFirstRunRequestInsert = true;

      expectBusyDeferral(await coordinator.requestSync(repair));
    },
    skip: !sqliteAvailable,
  );

  // Acquire 1 is the one-time recovery lease, acquire 2 the run's own.
  for (final (name, ordinal) in [('recovery', 1), ('run', 2)]) {
    test(
      'a lock timeout acquiring the $name lease is a busy deferral',
      () async {
        faults.failAcquires.add(ordinal);

        expectBusyDeferral(await coordinator.requestSync(repair));
        if (ordinal == 2) {
          // The ledger keeps its plain leaseHeld deferral.
          final history = await database.librarySyncDao.getRecentSyncRunHistory(
            1,
          );
          expect(
            history.where(
              (run) =>
                  run.outcome == SyncRunOutcomeKind.deferred &&
                  run.reason == SyncSafeReason.leaseHeld,
            ),
            isNotEmpty,
          );
        }
      },
      skip: !sqliteAvailable,
    );
  }

  test('a real lease conflict is not marked busy', () async {
    expect(
      await database.librarySyncDao.acquireExecutionLease(
        serverId: 1,
        ownerToken: 'someone-else',
        ownerKind: 'foreground',
        now: now,
        ttl: const Duration(minutes: 10),
      ),
      isTrue,
    );

    final state = await coordinator.requestSync(repair);

    expect(state.status, LibrarySyncStatus.deferred);
    expect(state.planReason, 'leaseHeld');
    expect(state.failureCategory, isNull);
    expect(state.nextRetryAt, isNull);
  }, skip: !sqliteAvailable);

  test('a lease release that times out is retried in the background', () async {
    // Release 1 is the recovery lease, release 2 the run's own.
    faults.failReleases.add(2);

    final first = await coordinator.requestSync(repair);
    expect(first.status, LibrarySyncStatus.succeeded);

    for (var i = 0; i < 100; i++) {
      if (await database.librarySyncDao.getExecutionLease(1) == null) break;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(await database.librarySyncDao.getExecutionLease(1), isNull);
    final next = await coordinator.requestSync(repair);
    expect(next.status, isNot(LibrarySyncStatus.deferred));
  }, skip: !sqliteAvailable);

  test('the release retry never deletes another owner lease', () async {
    faults.failReleases.add(2);
    await coordinator.requestSync(repair);
    // The stuck lease was taken over (e.g. after its TTL) before the retry ran.
    await database.customStatement(
      'UPDATE library_sync_execution_lease SET owner_token = ?',
      ['someone-else'],
    );

    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(
      (await database.librarySyncDao.getExecutionLease(1))?.ownerToken,
      'someone-else',
    );
  }, skip: !sqliteAvailable);
}
