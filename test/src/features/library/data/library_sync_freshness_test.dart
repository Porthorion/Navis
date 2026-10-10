import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/data/server_config_repository.dart';
import 'package:navis/src/features/auth/presentation/session_route_provider.dart';
import 'package:navis/src/features/library/data/adaptive_library_sync_coordinator.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/utils/connectivity.dart';

import '../../../../helpers/library_sync_fakes.dart';
import '../../../../helpers/library_sync_plan.dart';
import '../../../../helpers/test_database.dart';

void main() {
  late NavisDatabase database;
  late ServerConfigRepository repository;
  late FakeLibrarySyncApi api;
  late AdaptiveLibrarySyncCoordinator coordinator;

  setUp(() async {
    database = createTestDatabase();
    repository = await seedSyncSession(database);
    api = FakeLibrarySyncApi();
    for (var i = 0; i < 80; i++) {
      final artist = Artist(
        id: 'artist-$i',
        name: 'Artist $i',
        albumCount: i == 0 ? 1 : 0,
        albums: i == 0
            ? const [
                Album(
                  id: 'incomplete',
                  name: 'Incomplete',
                  artistId: 'artist-0',
                  songCount: 2,
                ),
              ]
            : const [],
      );
      api.artists.add(artist);
      api.artistDetails[artist.id] = artist;
    }
    api.indexes = Indexes(
      lastModified: FakeLibrarySyncApi.defaultIndexesCursor,
      shortcut: api.artists,
    );
    api.fastPathPages[0] = api.artists.first.albums;
    api.albumDetails['incomplete'] = const Album(
      id: 'incomplete',
      name: 'Incomplete',
      artistId: 'artist-0',
      songCount: 2,
      songs: [Song(id: 'one', title: 'One', albumId: 'incomplete')],
    );
    coordinator = AdaptiveLibrarySyncCoordinator(
      executor: serialDriftEngine(
        api: api,
        database: database,
        repository: repository,
      ),
      database: database,
      serverConfigRepository: repository,
      networkType: NetworkType.wifi,
      staleAfter: const Duration(hours: 1),
      readHasActivePlayback: () => false,
    );
  });

  tearDown(() => database.close());

  Future<Map<String, dynamic>> capabilities() async {
    final config = (await repository.getActiveServer())!;
    final root = jsonDecode(config.capabilitiesJson!) as Map<String, dynamic>;
    return root['navis'] as Map<String, dynamic>;
  }

  Future<LibrarySyncState> classifyFourAlbums() async {
    final albums = [
      for (var i = 0; i < 4; i++)
        Album(
          id: 'incomplete-$i',
          name: 'Incomplete $i',
          artistId: 'artist-0',
          songCount: 2,
        ),
    ];
    api.fastPathPages[0] = albums;
    api.artistDetails['artist-0'] = api.artists.first.copyWith(albums: albums);
    for (final album in albums) {
      api.albumDetails[album.id] = album.copyWith(
        songs: [Song(id: '${album.id}-one', title: 'One', albumId: album.id)],
      );
    }
    final first = await coordinator.requestSync(
      const LibrarySyncRequest(
        origin: SyncRunOrigin.settingsRepair,
        intent: SyncRunIntent.repairLibrary,
      ),
    );
    expect(first.status, LibrarySyncStatus.succeeded);
    expect(first.pendingHydrationCount, 4);
    expect(first.onlyIncompleteAlbumDetails, isTrue);
    return first;
  }

  Future<LibrarySyncState> boundedCheck() async {
    api.calls.clear();
    api.newestPages[0] = const [
      Album(id: 'healthy', name: 'Healthy', songCount: 1),
    ];
    api.albumDetails['healthy'] = const Album(
      id: 'healthy',
      name: 'Healthy',
      songCount: 1,
      songs: [Song(id: 'healthy-one', title: 'One', albumId: 'healthy')],
    );
    // A new executor has no classification left in run metrics.
    final engine = meteredDriftEngine(
      api: api,
      database: database,
      repository: repository,
    );
    final meteredCoordinator = AdaptiveLibrarySyncCoordinator(
      executor: engine,
      database: database,
      serverConfigRepository: repository,
      networkType: NetworkType.cellular,
      staleAfter: const Duration(hours: 1),
      readHasActivePlayback: () => false,
    );
    return await meteredCoordinator.requestSync(
      const LibrarySyncRequest.checkForUpdates(),
    );
  }

  test(
    'unattempted incomplete albums stay current across bounded checks',
    () async {
      final first = await classifyFourAlbums();
      final next = await boundedCheck();
      expect(next.status, LibrarySyncStatus.succeeded);
      expect(next.pendingHydrationCount, 4);
      expect(next.onlyIncompleteAlbumDetails, isTrue);
      expect(next.freshness, LibrarySyncFreshness.current);
      expect(next.lastSyncedAt!.isAfter(first.lastSyncedAt!), isTrue);
      expect(
        next.lastCatalogUpdatedAt!.isAfter(first.lastCatalogUpdatedAt!),
        isTrue,
      );
      expect(
        api.calls.where((call) => call.startsWith('getAlbum:incomplete')),
        isEmpty,
      );
      final classified = jsonDecode(
        (await capabilities())['libraryIncompleteAlbumEvidence'] as String,
      ) as Map<String, dynamic>;
      expect(
        classified.keys,
        unorderedEquals([for (var i = 0; i < 4; i++) 'incomplete-$i']),
      );
    },
    skip: !sqliteAvailable,
  );

  test(
    'changed metadata revokes an unattempted incomplete exemption',
    () async {
      await classifyFourAlbums();
      await database.libraryDao.upsertAlbums([
        const AlbumsTableCompanion(
          id: Value('incomplete-0'),
          name: Value('Changed'),
        ),
      ]);
      final next = await boundedCheck();
      expect(next.onlyIncompleteAlbumDetails, isFalse);
      expect(next.hasBlockingPendingAlbums, isTrue);
      expect(next.freshness, LibrarySyncFreshness.verificationPending);
      final classified = jsonDecode(
        (await capabilities())['libraryIncompleteAlbumEvidence'] as String,
      ) as Map<String, dynamic>;
      expect(classified, isNot(contains('incomplete-0')));
    },
    skip: !sqliteAvailable,
  );

  test('an unclassified unattempted pending album still blocks', () async {
    await classifyFourAlbums();
    await database.libraryDao.upsertAlbums([
      AlbumsTableCompanion.insert(id: 'unknown', name: 'Unknown'),
    ]);
    final next = await boundedCheck();
    expect(next.pendingHydrationCount, 5);
    expect(next.onlyIncompleteAlbumDetails, isFalse);
    expect(next.hasBlockingPendingAlbums, isTrue);
    expect(next.freshness, LibrarySyncFreshness.verificationPending);
  }, skip: !sqliteAvailable);

  test('removed albums lose their persisted classification', () async {
    await classifyFourAlbums();
    await database.libraryDao.deleteAlbumsByIds(['incomplete-0']);
    final next = await boundedCheck();
    expect(next.pendingHydrationCount, 3);
    expect(next.onlyIncompleteAlbumDetails, isTrue);
    final classified = jsonDecode(
      (await capabilities())['libraryIncompleteAlbumEvidence'] as String,
    ) as Map<String, dynamic>;
    expect(classified, isNot(contains('incomplete-0')));
  }, skip: !sqliteAvailable);

  test(
    'targeted detail retries revoke classifications before other failures',
    () async {
      await classifyFourAlbums();
      final engine = serialDriftEngine(
        api: api,
        database: database,
        repository: repository,
      );
      final incomplete = await engine.hydrateAlbum('incomplete-0');
      expect(incomplete.status, LibrarySyncStatus.partial);
      api.albumErrors['incomplete-0'] = const SubsonicNotFoundException(
        message: 'Missing',
      );
      await engine.hydrateAlbum('incomplete-0');
      final next = await boundedCheck();
      expect(next.onlyIncompleteAlbumDetails, isFalse);
      expect(next.hasBlockingPendingAlbums, isTrue);
    },
    skip: !sqliteAvailable,
  );

  for (final outcome in ['404', 'transient', 'conflict', 'hydrated']) {
    test('a later $outcome revokes the persisted exemption', () async {
      await classifyFourAlbums();
      if (outcome == '404') {
        api.albumErrors['incomplete-0'] = const SubsonicNotFoundException(
          message: 'Missing',
        );
      } else if (outcome == 'transient') {
        api.albumErrors['incomplete-0'] = const SubsonicGenericException(
          code: 503,
          message: 'Unavailable',
        );
      } else {
        api.albumDetails['incomplete-0'] = api.albumDetails['incomplete-0']!
            .copyWith(
              songCount: outcome == 'hydrated' ? 1 : 2,
              songs: [
                Song(
                  id: 'one',
                  title: 'One',
                  albumId: outcome == 'conflict' ? 'wrong' : 'incomplete-0',
                ),
              ],
            );
      }
      final next = await serialDriftEngine(
        api: api,
        database: database,
        repository: repository,
      ).executeSyncPlan(syncPlanForTest(LibrarySyncPlanKind.targetedHydration));
      expect(next.onlyIncompleteAlbumDetails, outcome == 'hydrated');
      expect(next.hasBlockingPendingAlbums, outcome != 'hydrated');
      expect(
        next.freshness,
        outcome == 'hydrated'
            ? LibrarySyncFreshness.current
            : LibrarySyncFreshness.verificationPending,
      );
      final classified = jsonDecode(
        (await capabilities())['libraryIncompleteAlbumEvidence'] as String,
      ) as Map<String, dynamic>;
      expect(classified, isNot(contains('incomplete-0')));
    }, skip: !sqliteAvailable);
  }

  test(
    'a retryable album still blocks alongside server-incomplete details',
    () async {
      api.fastPathPages[0] = [
        ...api.fastPathPages[0]!,
        const Album(id: 'retryable', name: 'Retryable', songCount: 1),
      ];
      api.albumErrors['retryable'] = const SubsonicGenericException(
        code: 503,
        message: 'Unavailable',
      );
      final result = await coordinator.requestSync(
        const LibrarySyncRequest(
          origin: SyncRunOrigin.settingsRepair,
          intent: SyncRunIntent.repairLibrary,
        ),
      );
      expect(result.status, LibrarySyncStatus.partial);
      expect(result.pendingHydrationCount, 2);
      expect(result.onlyIncompleteAlbumDetails, isFalse);
      expect(result.freshness, LibrarySyncFreshness.verificationPending);
      expect(result.lastSyncedAt, isNull);
      expect(result.lastCatalogUpdatedAt, isNull);
      expect((await capabilities())['libraryIndexesCursor'], isNull);
    },
    skip: !sqliteAvailable,
  );

  test(
    'a short detail list with conflicting tracks still blocks freshness',
    () async {
      api.albumDetails['incomplete'] = const Album(
        id: 'incomplete',
        name: 'Incomplete',
        songCount: 2,
        songs: [Song(id: 'one', title: 'One', albumId: 'wrong-album')],
      );
      final result = await coordinator.requestSync(
        const LibrarySyncRequest(
          origin: SyncRunOrigin.settingsRepair,
          intent: SyncRunIntent.repairLibrary,
        ),
      );
      expect(result.status, LibrarySyncStatus.partial);
      expect(result.pendingHydrationCount, 1);
      expect(result.onlyIncompleteAlbumDetails, isFalse);
      expect(result.freshness, LibrarySyncFreshness.verificationPending);
      expect(result.lastCatalogUpdatedAt, isNull);
      expect((await capabilities())['libraryIndexesCursor'], isNull);
    },
    skip: !sqliteAvailable,
  );

  test(
    'server-incomplete promotion is current and the next check is bounded',
    () async {
      final first = await coordinator.requestSync(
        const LibrarySyncRequest(
          origin: SyncRunOrigin.settingsRepair,
          intent: SyncRunIntent.repairLibrary,
        ),
      );
      expect(first.status, LibrarySyncStatus.succeeded);
      expect(first.catalogPublishedThisRun, isTrue);
      expect(first.pendingHydrationCount, 1);
      expect(first.onlyIncompleteAlbumDetails, isTrue);
      expect(first.freshness, LibrarySyncFreshness.current);
      expect(first.lastSyncedAt, isNotNull);
      expect(first.lastCatalogUpdatedAt, isNotNull);
      final config = (await repository.getActiveServer())!;
      expect(config.lastSynced, isNotNull);
      expect(
        first.lastSyncedAt!.difference(config.lastSynced!).abs(),
        lessThan(const Duration(seconds: 1)),
      );
      final persisted = await database.librarySyncDao.getOrCreateState(
        config.id!,
      );
      expect(persisted.lastCatalogSyncedAt, isNotNull);
      expect(
        first.lastCatalogUpdatedAt!
            .difference(persisted.lastCatalogSyncedAt!)
            .abs(),
        lessThan(const Duration(seconds: 1)),
      );
      expect(
        (await capabilities())['libraryIndexesCursor'],
        FakeLibrarySyncApi.defaultIndexesCursor.toIso8601String(),
      );
      expect(
        await recordInitialCatalogReadiness(
          database: database,
          serverId: config.id!,
          result: first,
        ),
        isTrue,
      );

      api.calls.clear();
      api.requestedIndexesCursors.clear();
      final next = await coordinator.requestSync(
        const LibrarySyncRequest.checkForUpdates(),
      );
      expect(next.planKind, LibrarySyncPlanKind.deltaReconcile);
      expect(next.status, LibrarySyncStatus.succeeded);
      expect(next.freshness, LibrarySyncFreshness.current);
      expect(next.remainingVerificationCount, 0);
      expect(next.pendingHydrationCount, 1);
      expect(next.onlyIncompleteAlbumDetails, isTrue);
      expect(
        api.requestedIndexesCursors.first!.toUtc(),
        FakeLibrarySyncApi.defaultIndexesCursor,
      );
      expect(
        api.calls.where((call) => call.startsWith('getArtist:')).length,
        lessThan(10),
      );
      expect(api.calls, contains('getAlbum:incomplete'));
    },
    skip: !sqliteAvailable,
  );

  test(
    'hydration-only retry of incomplete details keeps freshness current',
    () async {
      final engine = serialDriftEngine(
        api: api,
        database: database,
        repository: repository,
      );
      await engine.executeSyncPlan(
        syncPlanForTest(LibrarySyncPlanKind.fullRepair),
      );
      api.calls.clear();
      final retry = await engine.executeSyncPlan(
        syncPlanForTest(LibrarySyncPlanKind.targetedHydration),
      );
      expect(retry.status, LibrarySyncStatus.succeeded);
      expect(retry.pendingHydrationCount, 1);
      expect(retry.onlyIncompleteAlbumDetails, isTrue);
      expect(retry.freshness, LibrarySyncFreshness.current);
      expect(retry.lastSyncedAt, isNotNull);
      expect((await capabilities())['libraryIndexesCursor'], isNotNull);
      expect(api.calls, contains('getAlbum:incomplete'));
      expect(api.calls.where((call) => call.startsWith('getArtist:')), isEmpty);
    },
    skip: !sqliteAvailable,
  );

  for (final failure in <String, Exception>{
    '5xx': const SubsonicGenericException(code: 503, message: 'Unavailable'),
    '404': const SubsonicNotFoundException(message: 'Missing'),
  }.entries) {
    test(
      '${failure.key} details still block freshness after promotion',
      () async {
        api.albumErrors['incomplete'] = failure.value;
        final result = await coordinator.requestSync(
          const LibrarySyncRequest(
            origin: SyncRunOrigin.settingsRepair,
            intent: SyncRunIntent.repairLibrary,
          ),
        );
        expect(result.status, LibrarySyncStatus.partial);
        expect(result.catalogPublishedThisRun, isTrue);
        expect(result.pendingHydrationCount, 1);
        expect(result.onlyIncompleteAlbumDetails, isFalse);
        expect(result.freshness, LibrarySyncFreshness.verificationPending);
        expect(result.lastSyncedAt, isNull);
        expect(result.lastCatalogUpdatedAt, isNull);
        expect((await repository.getActiveServer())!.lastSynced, isNull);
        expect((await capabilities())['libraryIndexesCursor'], isNull);
      },
      skip: !sqliteAvailable,
    );
  }
}
