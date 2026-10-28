import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/sync_write_fence.dart';
import 'package:navis/src/features/auth/data/server_config_repository.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/library/data/adaptive_library_sync_coordinator.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/domain/sync_run_contract.dart';
import 'package:navis/src/utils/connectivity.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../helpers/library_sync_fakes.dart';
import '../../helpers/library_sync_plan.dart';
import '../../helpers/test_database.dart';

void main() {
  late Directory directory;
  late File file;
  late NavisDatabase database;
  late Database otherConnection;
  late DateTime now;
  late SyncWriteFence fence;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('navis-sync-fence-');
    file = File('${directory.path}/fixture.sqlite');
    database = createTestDatabase(file: file);
    await database.serverDao.saveServer(
      ServerConfigTableCompanion.insert(
        url: 'https://example.test',
        username: 'fixture',
        apiVersion: '1.16.1',
      ),
    );
    now = DateTime.utc(2026, 9, 19);
    await database.librarySyncDao.acquireExecutionLease(
      serverId: 1,
      ownerToken: 'first-owner',
      ownerKind: 'foreground',
      now: now,
      ttl: const Duration(minutes: 1),
    );
    otherConnection = sqlite3.open(file.path);
    fence = SyncWriteFence(
      serverId: 1,
      ownerToken: 'first-owner',
      now: () => now,
    );
  });

  tearDown(() async {
    otherConnection.close();
    await database.close();
    await directory.delete(recursive: true);
  });

  test('owned standalone and batched writes commit', () async {
    await fence.run(() async {
      await database
          .into(database.artistsTable)
          .insert(ArtistsTableCompanion.insert(id: 'a', name: 'Artist'));
      await database.libraryDao.upsertSongs([
        SongsTableCompanion.insert(id: 's', title: 'Song'),
      ]);
    });
    expect((await database.libraryDao.getSongById('s'))?.title, 'Song');
  });

  test(
    'a replaced owner cannot write catalog, candidate, or checkpoint data',
    () async {
      otherConnection.execute(
        "UPDATE library_sync_execution_lease SET owner_token = 'second-owner'",
      );
      await expectLater(
        fence.run(
          () => database.libraryDao.upsertSongs([
            SongsTableCompanion.insert(id: 'stale', title: 'Stale'),
          ]),
        ),
        throwsA(isA<SyncLeaseLostException>()),
      );
      await expectLater(
        fence.run(
          () => database.customStatement(
            "INSERT INTO library_sync_candidate_artists (server_id, generation, id, name) VALUES (1, 2, 'stale', 'Stale')",
          ),
        ),
        throwsA(isA<SyncLeaseLostException>()),
      );
      await expectLater(
        fence.run(
          () => database.librarySyncDao.writeState(
            const LibrarySyncStateTableCompanion(
              serverId: Value(1),
              currentGeneration: Value(99),
            ),
          ),
        ),
        throwsA(isA<SyncLeaseLostException>()),
      );
      expect(await database.libraryDao.getSongById('stale'), isNull);
      expect(
        (await database.librarySyncDao.getOrCreateState(1)).currentGeneration,
        0,
      );
      expect(
        (await database.librarySyncDao.getExecutionLease(1))?.ownerToken,
        'second-owner',
      );
    },
  );

  test('a transaction that outlives the lease TTL still commits for its live owner', () async {
    // The owner validated its lease when the transaction acquired the
    // writer lock; no takeover can happen while that lock is held, so
    // expiry alone must not roll the transaction back at commit.
    await expectLater(
      fence.run(
        () => database.transaction(() async {
          await database.libraryDao.upsertSongs([
            SongsTableCompanion.insert(id: 's', title: 'Song'),
          ]);
          await database.librarySyncDao.writeState(
            const LibrarySyncStateTableCompanion(
              serverId: Value(1),
              currentGeneration: Value(2),
            ),
          );
          now = now.add(const Duration(minutes: 2));
        }),
      ),
      completes,
    );
    expect((await database.libraryDao.getSongById('s'))?.title, 'Song');
    expect(
      (await database.librarySyncDao.getOrCreateState(1)).currentGeneration,
      2,
    );
  });

  test(
    'an expired lease nobody took over still lets its owner write',
    () async {
      now = now.add(const Duration(minutes: 5));
      await fence.run(
        () => database.libraryDao.upsertSongs([
          SongsTableCompanion.insert(id: 'late', title: 'Late'),
        ]),
      );
      expect((await database.libraryDao.getSongById('late'))?.title, 'Late');

      // A real takeover (after expiry) still fences the old owner out.
      expect(
        await database.librarySyncDao.acquireExecutionLease(
          serverId: 1,
          ownerToken: 'second-owner',
          ownerKind: 'foreground',
          now: now.add(const Duration(minutes: 5)),
          ttl: const Duration(minutes: 1),
        ),
        isTrue,
      );
      await expectLater(
        fence.run(
          () => database.libraryDao.upsertSongs([
            SongsTableCompanion.insert(id: 'stale', title: 'Stale'),
          ]),
        ),
        throwsA(isA<SyncLeaseLostException>()),
      );
      expect(await database.libraryDao.getSongById('stale'), isNull);
    },
  );

  test(
    'a renewal TTL extends the lease under the transaction write lock',
    () async {
      final renewingFence = SyncWriteFence(
        serverId: 1,
        ownerToken: 'first-owner',
        now: () => now,
        renewalTtl: const Duration(minutes: 10),
      );
      await renewingFence.run(
        () => database.libraryDao.upsertSongs([
          SongsTableCompanion.insert(id: 's', title: 'Song'),
        ]),
      );
      final lease = await database.librarySyncDao.getExecutionLease(1);
      // now (advanced 2 minutes) + 10 minutes must hold after the renewal.
      expect(
        lease!.expiresAt.isAfter(now.add(const Duration(minutes: 9))),
        isTrue,
      );
    },
  );

  test(
    'unrelated user edits remain available outside the sync scope',
    () async {
      otherConnection.execute(
        "UPDATE library_sync_execution_lease SET owner_token = 'second-owner'",
      );
      await database.libraryDao.upsertSongs([
        SongsTableCompanion.insert(id: 'local', title: 'Local edit'),
      ]);
      expect(
        (await database.libraryDao.getSongById('local'))?.title,
        'Local edit',
      );
    },
  );

  group('worker hand-off', () {
    late SyncWriteFence worker;

    Future<bool> takeOver() => database.librarySyncDao.acquireExecutionLease(
      serverId: 1,
      ownerToken: 'foreground-owner',
      ownerKind: 'foreground',
      now: now,
      ttl: const Duration(minutes: 1),
    );

    Future<void> writeSongs(List<String> ids) =>
        database.libraryDao.upsertSongs([
          for (final id in ids) SongsTableCompanion.insert(id: id, title: id),
        ]);

    setUp(() async {
      await database.librarySyncDao.releaseExecutionLease(
        serverId: 1,
        ownerToken: 'first-owner',
      );
      await database.librarySyncDao.acquireExecutionLease(
        serverId: 1,
        ownerToken: 'worker-owner',
        ownerKind: 'androidWorker',
        now: now,
        ttl: const Duration(minutes: 1),
      );
      worker = SyncWriteFence(
        serverId: 1,
        ownerToken: 'worker-owner',
        now: () => now,
      );
    });

    test('10 a preempted worker cannot commit a new write', () async {
      expect(await takeOver(), isTrue);

      await expectLater(
        worker.run(() => writeSongs(['standalone'])),
        throwsA(isA<SyncLeaseLostException>()),
      );
      await expectLater(
        worker.run(
          () => database.transaction(() async {
            await writeSongs(['first']);
            await writeSongs(['second']);
          }),
        ),
        throwsA(isA<SyncLeaseLostException>()),
      );
      for (final id in ['standalone', 'first', 'second']) {
        expect(await database.libraryDao.getSongById(id), isNull);
      }
    });

    test(
      '11 a takeover never interleaves an open worker transaction',
      () async {
        final wrote = Completer<void>();
        final finish = Completer<void>();
        final open = worker.run(
          () => database.transaction(() async {
            await writeSongs(['committed']);
            wrote.complete();
            await finish.future;
          }),
        );
        await wrote.future;
        // Drift opens transactions with BEGIN IMMEDIATE: another engine's
        // connection cannot take over while this one holds the writer lock,
        // so a commit can never race a takeover.
        expect(
          () => otherConnection.execute(
            "UPDATE library_sync_execution_lease SET owner_token = 'other'",
          ),
          throwsA(isA<SqliteException>()),
        );
        // In process, the acquire queues behind the transaction.
        final takeover = takeOver();
        finish.complete();
        await open;
        expect(await takeover, isTrue);

        expect(await database.libraryDao.getSongById('committed'), isNotNull);
        await expectLater(
          worker.run(
            () => database.transaction(() async {
              await writeSongs(['late-1']);
              await writeSongs(['late-2']);
            }),
          ),
          throwsA(isA<SyncLeaseLostException>()),
        );
        expect(await database.libraryDao.getSongById('late-1'), isNull);
        expect(await database.libraryDao.getSongById('late-2'), isNull);
        expect(
          (await database.librarySyncDao.getExecutionLease(1))?.ownerToken,
          'foreground-owner',
        );
      },
    );

    Future<Database> reopenWithBusyHandler() async {
      // The production connection: background isolate plus the Dart busy
      // handler that waits up to 5 s for another connection's writer lock.
      await database.close();
      database = NavisDatabase.atPath(file.path);
      await database.customSelect('SELECT 1').get();
      return otherConnection;
    }

    test(
      '12 a foreground acquire waits out a short worker lock, then preempts',
      () async {
        final raw = await reopenWithBusyHandler();
        raw.execute('BEGIN IMMEDIATE');
        raw.execute(
          'UPDATE library_sync_execution_lease SET heartbeat_at = '
          "heartbeat_at WHERE owner_token = 'worker-owner'",
        );
        unawaited(
          Future<void>.delayed(
            const Duration(seconds: 1),
            () => raw.execute('COMMIT'),
          ),
        );
        final stopwatch = Stopwatch()..start();
        expect(await takeOver(), isTrue);
        expect(
          stopwatch.elapsed,
          greaterThan(const Duration(milliseconds: 800)),
        );
        expect(
          (await database.librarySyncDao.getExecutionLease(1))?.ownerKind,
          'foreground',
        );
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test('12a a failed lease acquire leaves the previous owner running work as it was', () async {
      final dao = database.librarySyncDao;
      await dao.enqueueWork(serverId: 1, kind: 'catalogSnapshot', priority: 50);
      final work = (await dao.getWork(serverId: 1, kind: 'catalogSnapshot'))!;
      await dao.markRunning(work.id, now: now);
      final request = await dao.enqueueSyncRun(
        serverId: 1,
        plan: syncPlanForTest(LibrarySyncPlanKind.catalogSnapshot),
        now: now,
      );
      final attempt = (await dao.beginSyncRunAttempt(
        requestId: request.id,
        androidWorker: true,
        now: now,
      ))!;
      // Fail after the lease upsert, inside the acquire transaction.
      await database.customStatement(
        'CREATE TRIGGER fail_requeue BEFORE UPDATE ON library_sync_work '
        "BEGIN SELECT RAISE(ABORT, 'injected'); END",
      );

      await expectLater(takeOver(), throwsA(anything));

      expect((await dao.getExecutionLease(1))?.ownerToken, 'worker-owner');
      expect(
        (await dao.getWork(serverId: 1, kind: 'catalogSnapshot'))!.status,
        'running',
      );
      final attempts = await database
          .select(database.librarySyncRunAttemptTable)
          .get();
      expect(attempts.single.id, attempt.id);
      expect(attempts.single.status, 0);
      final requests = await database
          .select(database.librarySyncRunRequestTable)
          .get();
      expect(requests.single.status, 1);
      await database.customStatement('DROP TRIGGER fail_requeue');
      // The worker's run is still its own: the takeover can succeed later.
      expect(await takeOver(), isTrue);
      expect(
        (await dao.getWork(serverId: 1, kind: 'catalogSnapshot'))!.status,
        'queued',
      );
    });

    // A foreground coordinator on the production connection whose worker lease
    // is gone. [onPolicyRead] sees the 1-based count of network policy reads
    // (the second is the execution gate right before the lease acquire);
    // [hasActivePlayback] is read just before the request row is written.
    Future<({AdaptiveLibrarySyncCoordinator coordinator, int serverId})>
    lockedCoordinator({
      required void Function(int reads) onPolicyRead,
      bool Function()? hasActivePlayback,
    }) async {
      await database.librarySyncDao.releaseExecutionLease(
        serverId: 1,
        ownerToken: 'worker-owner',
      );
      final repository = ServerConfigRepository(
        database,
        credentials: FakeSyncCredentialStore(),
      );
      await repository.save(
        ServerConfigModel(
          url: 'https://example.test',
          username: 'fixture',
          password: 'fixture',
          apiVersion: '1.16.1',
          lastSynced: DateTime.now().subtract(const Duration(days: 1)),
        ),
      );
      final serverId = (await repository.getActiveServer())!.id!;
      await database.librarySyncDao.writeState(
        LibrarySyncStateTableCompanion(
          serverId: Value(serverId),
          currentGeneration: const Value(1),
        ),
      );
      var policyReads = 0;
      final coordinator = AdaptiveLibrarySyncCoordinator(
        executor: serialDriftEngine(
          api: FakeLibrarySyncApi(),
          database: database,
          repository: repository,
          networkType: NetworkType.wifi,
        ),
        database: database,
        serverConfigRepository: repository,
        readSyncNetworkPolicy: () {
          onPolicyRead(++policyReads);
          return resolveSyncNetworkPolicy(
            networkType: NetworkType.wifi,
            nativeMetered: false,
            backgroundSyncUnmeteredOnly: true,
          );
        },
        staleAfter: const Duration(hours: 1),
        readHasActivePlayback: hasActivePlayback ?? () => false,
      );
      return (coordinator: coordinator, serverId: serverId);
    }

    // Another engine's long transaction (a worker promotion): holds the writer
    // lock for [hold], longer than the 5 s busy wait.
    void holdWriterLock(Database raw, Duration hold) {
      raw.execute('BEGIN IMMEDIATE');
      unawaited(Future<void>.delayed(hold, () => raw.execute('ROLLBACK')));
    }

    Future<void> expectBusyNotFailure(
      LibrarySyncState result,
      int serverId,
    ) async {
      expect(result.status, LibrarySyncStatus.deferred);
      expect(result.planReason, 'leaseHeld');
      final state = await database.librarySyncDao.getOrCreateState(serverId);
      expect(state.failureStreak, 0);
      expect(state.nextEligibleAt, isNull);
      expect(
        await (database.select(
          database.librarySyncWorkTable,
        )..where((row) => row.status.equals('failed'))).get(),
        isEmpty,
      );
      expect(
        await database.select(database.librarySyncRunAttemptTable).get(),
        isEmpty,
      );
      expect(await database.librarySyncDao.getExecutionLease(serverId), isNull);
    }

    test('13 a lease acquire that times out on a lock is lease held, not a failure', () async {
      final raw = await reopenWithBusyHandler();
      final (:coordinator, :serverId) = await lockedCoordinator(
        // The execution gate right before the lease acquire.
        onPolicyRead: (reads) {
          if (reads == 2) holdWriterLock(raw, const Duration(seconds: 7));
        },
      );

      final result = await coordinator.requestSync(
        const LibrarySyncRequest.checkForUpdates(),
      );

      await expectBusyNotFailure(result, serverId);
      final outcome =
          (await database.select(database.librarySyncRunOutcomeTable).get())
              .single;
      expect(outcome.outcomeKind, SyncRunOutcomeKind.deferred.index);
      expect(outcome.safeReason, SyncSafeReason.leaseHeld.index);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('13a a request write that times out on a lock is lease held, not a failure', () async {
      final raw = await reopenWithBusyHandler();
      var locked = false;
      final (:coordinator, :serverId) = await lockedCoordinator(
        onPolicyRead: (_) {},
        // Read while planning, right before enqueueSyncRun writes the request.
        hasActivePlayback: () {
          if (!locked) {
            locked = true;
            holdWriterLock(raw, const Duration(seconds: 7));
          }
          return false;
        },
      );

      final result = await coordinator.requestSync(
        const LibrarySyncRequest.checkForUpdates(),
      );

      expect(locked, isTrue);
      await expectBusyNotFailure(result, serverId);
      expect(
        await database.select(database.librarySyncRunRequestTable).get(),
        isEmpty,
      );
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('13b a deferral write that also times out on the lock is lease held, not a failure', () async {
      final raw = await reopenWithBusyHandler();
      final (:coordinator, :serverId) = await lockedCoordinator(
        onPolicyRead: (reads) {
          // Outlasts the acquire wait and the outcome write's own 5 s wait.
          if (reads == 2) holdWriterLock(raw, const Duration(seconds: 12));
        },
      );

      final result = await coordinator.requestSync(
        const LibrarySyncRequest.checkForUpdates(),
      );

      await expectBusyNotFailure(result, serverId);
      // The request stays queued for the retry to share; nothing is running.
      expect(
        (await database.select(database.librarySyncRunRequestTable).get())
            .where((row) => row.status == 1),
        isEmpty,
      );
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
