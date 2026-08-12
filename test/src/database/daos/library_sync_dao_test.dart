import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';

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
}
