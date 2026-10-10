import 'dart:convert';

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
