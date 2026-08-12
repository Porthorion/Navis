import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/data/secure_credential_store.dart';
import 'package:navis/src/features/auth/data/server_config_repository.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/library/data/adaptive_library_sync_coordinator.dart';
import 'package:navis/src/features/library/data/library_sync_engine.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/utils/connectivity.dart';

import '../../../../helpers/test_database.dart';

class _MemoryCredentialStore implements SecureCredentialStore {
  String? password;

  @override
  Future<void> clearPassword() async => password = null;

  @override
  Future<String?> readPassword() async => password;

  @override
  Future<void> savePassword(String value) async => password = value;
}

class _ProbeLibrarySyncEngine
    implements LibrarySyncEngine, TargetedLibrarySyncExecutor {
  int probeCalls = 0;
  int forceFullSyncCalls = 0;
  int syncIfStaleCalls = 0;
  int syncNowCalls = 0;
  bool probeIndexChanged = false;
  bool probeIndexesUnsupported = false;
  LibrarySyncState? forcedResult;

  LibrarySyncState _idle() =>
      forcedResult ??
      LibrarySyncState(
        status: LibrarySyncStatus.succeeded,
        stage: LibrarySyncStage.completed,
        metadataReady: true,
        completedAt: DateTime.utc(2026, 8, 4),
      );

  @override
  Future<LibrarySyncState> requestSync(
    LibrarySyncRequest request, {
    Iterable<String> priorityAlbumIds = const <String>[],
    LibrarySyncProgressCallback? onProgress,
  }) async => _idle();

  @override
  Future<LibrarySyncState> continueVerification({
    Iterable<String> priorityAlbumIds = const <String>[],
    LibrarySyncProgressCallback? onProgress,
  }) async => _idle();

  @override
  Future<LibrarySyncState> forceFullSync({
    Iterable<String> priorityAlbumIds = const <String>[],
    LibrarySyncProgressCallback? onProgress,
  }) async {
    forceFullSyncCalls++;
    return _idle();
  }

  @override
  Future<LibrarySyncState> syncIfStale({
    Iterable<String> priorityAlbumIds = const <String>[],
    LibrarySyncProgressCallback? onProgress,
  }) async {
    syncIfStaleCalls++;
    return _idle();
  }

  @override
  Future<LibrarySyncState> syncNow({
    Iterable<String> priorityAlbumIds = const <String>[],
    LibrarySyncProgressCallback? onProgress,
  }) async {
    syncNowCalls++;
    return _idle();
  }

  @override
  Future<LibrarySyncState> probeCatalog({
    LibrarySyncProgressCallback? onProgress,
  }) async {
    probeCalls++;
    return LibrarySyncState(
      status: LibrarySyncStatus.succeeded,
      stage: LibrarySyncStage.completed,
      metadataReady: true,
      completedAt: DateTime.utc(2026, 8, 4),
      probeIndexChanged: probeIndexChanged,
      probeIndexesUnsupported: probeIndexesUnsupported,
      updatesAvailable: probeIndexChanged || probeIndexesUnsupported,
      apiRequests: 1,
    );
  }

  @override
  Future<LibrarySyncState> hydrateAlbum(
    String albumId, {
    LibrarySyncProgressCallback? onProgress,
  }) async => _idle();

  @override
  Future<LibrarySyncState> hydrateArtist(
    String artistId, {
    LibrarySyncProgressCallback? onProgress,
  }) async => _idle();

  @override
  Future<LibrarySyncState> hydratePlaylist(
    String playlistId, {
    LibrarySyncProgressCallback? onProgress,
  }) async => _idle();

  @override
  Future<LibrarySyncState> syncGenres({
    LibrarySyncProgressCallback? onProgress,
  }) async => _idle();

  @override
  Future<LibrarySyncState> syncPlaylistHeaders({
    LibrarySyncProgressCallback? onProgress,
  }) async => _idle();

  @override
  Future<LibrarySyncState> syncStarredContent({
    LibrarySyncProgressCallback? onProgress,
  }) async => _idle();
}

class _CompletedCatalogWithPendingAlbumEngine
    implements LibrarySyncEngine, TargetedLibrarySyncExecutor {
  final List<String> targetedCalls = <String>[];

  LibrarySyncState _result() => LibrarySyncState(
    status: LibrarySyncStatus.succeeded,
    stage: LibrarySyncStage.completed,
    metadataReady: true,
    pendingHydrationCount: 1,
    completedAt: DateTime.utc(2026, 8, 4),
  );

  LibrarySyncState _targetResult() => LibrarySyncState(
    status: LibrarySyncStatus.succeeded,
    stage: LibrarySyncStage.completed,
    metadataReady: true,
    completedAt: DateTime.utc(2026, 8, 4),
  );

  @override
  Future<LibrarySyncState> requestSync(
    LibrarySyncRequest request, {
    Iterable<String> priorityAlbumIds = const <String>[],
    LibrarySyncProgressCallback? onProgress,
  }) async => _result();

  @override
  Future<LibrarySyncState> continueVerification({
    Iterable<String> priorityAlbumIds = const <String>[],
    LibrarySyncProgressCallback? onProgress,
  }) async => _result();

  @override
  Future<LibrarySyncState> forceFullSync({
    Iterable<String> priorityAlbumIds = const <String>[],
    LibrarySyncProgressCallback? onProgress,
  }) async => _result();

  @override
  Future<LibrarySyncState> syncIfStale({
    Iterable<String> priorityAlbumIds = const <String>[],
    LibrarySyncProgressCallback? onProgress,
  }) async => _result();

  @override
  Future<LibrarySyncState> syncNow({
    Iterable<String> priorityAlbumIds = const <String>[],
    LibrarySyncProgressCallback? onProgress,
  }) async => _result();

  @override
  Future<LibrarySyncState> hydrateAlbum(
    String albumId, {
    LibrarySyncProgressCallback? onProgress,
  }) async {
    targetedCalls.add('album:$albumId');
    return _targetResult();
  }

  @override
  Future<LibrarySyncState> hydrateArtist(
    String artistId, {
    LibrarySyncProgressCallback? onProgress,
  }) async {
    targetedCalls.add('artist:$artistId');
    return _targetResult();
  }

  @override
  Future<LibrarySyncState> hydratePlaylist(
    String playlistId, {
    LibrarySyncProgressCallback? onProgress,
  }) async {
    targetedCalls.add('playlist:$playlistId');
    return _targetResult();
  }

  @override
  Future<LibrarySyncState> syncGenres({
    LibrarySyncProgressCallback? onProgress,
  }) async => _result();

  @override
  Future<LibrarySyncState> syncPlaylistHeaders({
    LibrarySyncProgressCallback? onProgress,
  }) async => _result();

  @override
  Future<LibrarySyncState> syncStarredContent({
    LibrarySyncProgressCallback? onProgress,
  }) async => _result();

  @override
  Future<LibrarySyncState> probeCatalog({
    LibrarySyncProgressCallback? onProgress,
  }) async => _result();
}

void main() {
  late NavisDatabase database;
  late ServerConfigRepository repository;
  late AdaptiveLibrarySyncCoordinator coordinator;
  late _CompletedCatalogWithPendingAlbumEngine executor;

  setUp(() async {
    database = createTestDatabase();
    repository = ServerConfigRepository(
      database,
      credentials: _MemoryCredentialStore(),
    );
    await repository.save(
      const ServerConfigModel(
        url: 'https://music.example.test',
        username: 'listener',
        password: 'secret',
        apiVersion: '1.16.1',
      ),
    );
    executor = _CompletedCatalogWithPendingAlbumEngine();
    coordinator = AdaptiveLibrarySyncCoordinator(
      executor: executor,
      database: database,
      serverConfigRepository: repository,
      networkType: NetworkType.wifi,
      staleAfter: const Duration(hours: 1),
      readHasActivePlayback: () => false,
      now: () => DateTime.utc(2026, 8, 4),
    );
  });

  tearDown(() async => database.close());

  test(
    'a promoted catalog task completes before remaining album hydration',
    () async {
      final result = await coordinator.requestSync(
        const LibrarySyncRequest.repair(),
      );
      final work = await database.librarySyncDao.getWork(
        serverId: 1,
        kind: LibrarySyncPlanKind.fullRepair.name,
      );

      expect(result.status, LibrarySyncStatus.partial);
      expect(work?.status, 'completed');
      expect(await database.librarySyncDao.countPendingWork(1), 0);
    },
    skip: !sqliteAvailable,
  );

  test(
    'promotion completion closes only running broad catalog work',
    () async {
      await database.librarySyncDao.enqueueWork(
        serverId: 1,
        kind: LibrarySyncPlanKind.fullRepair.name,
        priority: 80,
      );
      await database.librarySyncDao.enqueueWork(
        serverId: 1,
        kind: LibrarySyncPlanKind.catalogSnapshot.name,
        priority: 50,
      );
      await database.librarySyncDao.enqueueWork(
        serverId: 1,
        kind: LibrarySyncPlanKind.targetedHydration.name,
        entityId: 'album:pending',
        priority: 30,
      );
      for (final kind in <LibrarySyncPlanKind>[
        LibrarySyncPlanKind.fullRepair,
        LibrarySyncPlanKind.catalogSnapshot,
        LibrarySyncPlanKind.targetedHydration,
      ]) {
        final work = await database.librarySyncDao.getWork(
          serverId: 1,
          kind: kind.name,
          entityId: kind == LibrarySyncPlanKind.targetedHydration
              ? 'album:pending'
              : '',
        );
        await database.librarySyncDao.markRunning(work!.id);
      }

      await database.librarySyncDao.completeRunningCatalogWork(1);

      expect(
        (await database.librarySyncDao.getWork(
          serverId: 1,
          kind: LibrarySyncPlanKind.fullRepair.name,
        ))?.status,
        'completed',
      );
      expect(
        (await database.librarySyncDao.getWork(
          serverId: 1,
          kind: LibrarySyncPlanKind.catalogSnapshot.name,
        ))?.status,
        'completed',
      );
      expect(
        (await database.librarySyncDao.getWork(
          serverId: 1,
          kind: LibrarySyncPlanKind.targetedHydration.name,
          entityId: 'album:pending',
        ))?.status,
        'running',
      );
    },
    skip: !sqliteAvailable,
  );

  test(
    'same-ID targeted work remains distinct by entity type',
    () async {
      const sharedId = 'shared-id';
      await coordinator.requestSync(
        const LibrarySyncRequest(
          trigger: LibrarySyncTrigger.interaction,
          intent: LibrarySyncIntent.checkForUpdates,
          target: LibrarySyncTarget.artist(sharedId),
        ),
      );
      await coordinator.requestSync(
        const LibrarySyncRequest(
          trigger: LibrarySyncTrigger.interaction,
          intent: LibrarySyncIntent.checkForUpdates,
          target: LibrarySyncTarget.album(sharedId),
        ),
      );
      await coordinator.requestSync(
        const LibrarySyncRequest(
          trigger: LibrarySyncTrigger.interaction,
          intent: LibrarySyncIntent.checkForUpdates,
          target: LibrarySyncTarget.playlist(sharedId),
        ),
      );

      final artistWork = await database.librarySyncDao.getWork(
        serverId: 1,
        kind: LibrarySyncPlanKind.targetedHydration.name,
        entityId: librarySyncTargetWorkKey(
          const LibrarySyncTarget.artist(sharedId),
        ),
      );
      final albumWork = await database.librarySyncDao.getWork(
        serverId: 1,
        kind: LibrarySyncPlanKind.targetedHydration.name,
        entityId: librarySyncTargetWorkKey(
          const LibrarySyncTarget.album(sharedId),
        ),
      );

      expect(artistWork, isNotNull);
      expect(albumWork, isNotNull);
      expect(artistWork?.id, isNot(albumWork?.id));
      expect(
        executor.targetedCalls,
        containsAll(<String>[
          'artist:$sharedId',
          'album:$sharedId',
          'playlist:$sharedId',
        ]),
      );
      expect(
        executor.targetedCalls,
        isNot(contains('playlist:playlist:$sharedId')),
      );
    },
    skip: !sqliteAvailable,
  );

  test(
    'metered automatic catalog runs a hard probe instead of syncIfStale',
    () async {
      await repository.save(
        ServerConfigModel(
          url: 'https://music.example.test',
          username: 'listener',
          password: 'secret',
          apiVersion: '1.16.1',
          lastSynced: DateTime.utc(2026, 8, 1),
        ),
      );
      final server = await repository.getActiveServer();
      final serverId = server!.id!;
      await database.librarySyncDao.getOrCreateState(serverId);
      await database.librarySyncDao.writeState(
        LibrarySyncStateTableCompanion(
          serverId: Value(serverId),
          currentGeneration: const Value(3),
          lastCheckedAt: Value(DateTime.utc(2026, 7, 1)),
        ),
      );
      final probeEngine = _ProbeLibrarySyncEngine()..probeIndexChanged = true;
      final meteredCoordinator = AdaptiveLibrarySyncCoordinator(
        executor: probeEngine,
        database: database,
        serverConfigRepository: repository,
        readSyncNetworkPolicy: () => const SyncNetworkPolicy(
          networkType: NetworkType.cellular,
          isMetered: true,
          allowsBackgroundSync: false,
          allowsHardProbe: true,
          allowsInteractiveHydration: true,
        ),
        staleAfter: const Duration(hours: 1),
        readHasActivePlayback: () => false,
        now: () => DateTime.utc(2026, 8, 4),
      );

      final result = await meteredCoordinator.requestSync(
        const LibrarySyncRequest.automatic(),
      );

      expect(result.planKind, LibrarySyncPlanKind.probe);
      expect(probeEngine.probeCalls, 1);
      expect(probeEngine.syncIfStaleCalls, 0);
      expect(probeEngine.syncNowCalls, 0);
      expect(result.updatesAvailable, isTrue);
      final followUp = await database.librarySyncDao.getWork(
        serverId: serverId,
        kind: LibrarySyncPlanKind.deltaReconcile.name,
      );
      expect(followUp, isNotNull);
      expect(followUp?.workClass, 'background');
    },
    skip: !sqliteAvailable,
  );

  test(
    'manual refresh runs catalog discovery even when automatic work is fresh',
    () async {
      await repository.save(
        ServerConfigModel(
          url: 'https://music.example.test',
          username: 'listener',
          password: 'secret',
          apiVersion: '1.16.1',
          lastSynced: DateTime.utc(2026, 8, 1),
        ),
      );
      await database.librarySyncDao.writeState(
        const LibrarySyncStateTableCompanion(
          serverId: Value(1),
          currentGeneration: Value(1),
        ),
      );
      final probeEngine = _ProbeLibrarySyncEngine();
      final manualCoordinator = AdaptiveLibrarySyncCoordinator(
        executor: probeEngine,
        database: database,
        serverConfigRepository: repository,
        networkType: NetworkType.wifi,
        staleAfter: const Duration(hours: 1),
        readHasActivePlayback: () => false,
        now: () => DateTime.utc(2026, 8, 4),
      );

      final result = await manualCoordinator.syncNow();

      expect(probeEngine.probeCalls, 0);
      expect(probeEngine.syncNowCalls, 1);
      expect(result.planKind, LibrarySyncPlanKind.deltaReconcile);
      expect(
        await database.librarySyncDao.getWork(
          serverId: 1,
          kind: LibrarySyncPlanKind.deltaReconcile.name,
        ),
        isNotNull,
      );
    },
    skip: !sqliteAvailable,
  );

  test(
    'manual refresh preserves offline catalog discovery for eligible resume',
    () async {
      await database.librarySyncDao.writeState(
        const LibrarySyncStateTableCompanion(
          serverId: Value(1),
          currentGeneration: Value(1),
        ),
      );
      final probeEngine = _ProbeLibrarySyncEngine();
      final offlineCoordinator = AdaptiveLibrarySyncCoordinator(
        executor: probeEngine,
        database: database,
        serverConfigRepository: repository,
        networkType: NetworkType.offline,
        staleAfter: const Duration(hours: 1),
        readHasActivePlayback: () => false,
        now: () => DateTime.utc(2026, 8, 4),
      );

      final result = await offlineCoordinator.syncNow();

      expect(result.status, LibrarySyncStatus.deferred);
      expect(result.planKind, LibrarySyncPlanKind.deltaReconcile);
      expect(result.planReason, 'manualCatalogDiscoveryOffline');
      expect(probeEngine.probeCalls, 0);
      expect(probeEngine.syncNowCalls, 0);
      expect(
        (await database.librarySyncDao.getWork(
          serverId: 1,
          kind: LibrarySyncPlanKind.deltaReconcile.name,
        ))?.status,
        'queued',
      );

      final onlineCoordinator = AdaptiveLibrarySyncCoordinator(
        executor: probeEngine,
        database: database,
        serverConfigRepository: repository,
        networkType: NetworkType.wifi,
        staleAfter: const Duration(hours: 1),
        readHasActivePlayback: () => false,
        now: () => DateTime.utc(2026, 8, 4),
      );
      final resumed = await onlineCoordinator.syncIfStale();

      expect(resumed.status, LibrarySyncStatus.succeeded);
      expect(resumed.planKind, LibrarySyncPlanKind.deltaReconcile);
      expect(probeEngine.syncNowCalls, 1);
    },
    skip: !sqliteAvailable,
  );

  test(
    'manual cellular refresh requires an explicit broad-data override',
    () async {
      await database.librarySyncDao.writeState(
        const LibrarySyncStateTableCompanion(
          serverId: Value(1),
          currentGeneration: Value(1),
        ),
      );
      final probeEngine = _ProbeLibrarySyncEngine();
      const policy = SyncNetworkPolicy(
        networkType: NetworkType.cellular,
        isMetered: true,
        allowsBackgroundSync: false,
        allowsHardProbe: true,
        allowsInteractiveHydration: true,
      );
      final meteredCoordinator = AdaptiveLibrarySyncCoordinator(
        executor: probeEngine,
        database: database,
        serverConfigRepository: repository,
        readSyncNetworkPolicy: () => policy,
        staleAfter: const Duration(hours: 1),
        readHasActivePlayback: () => false,
        now: () => DateTime.utc(2026, 8, 4),
      );

      final probeResult = await meteredCoordinator.syncNow();

      expect(probeResult.planKind, LibrarySyncPlanKind.probe);
      expect(probeResult.planReason, 'manualMeteredProbe');
      expect(probeEngine.probeCalls, 1);
      expect(probeEngine.syncNowCalls, 0);

      final discoveryResult = await meteredCoordinator.syncNow(
        allowMeteredBroadOverride: true,
      );

      expect(discoveryResult.planKind, LibrarySyncPlanKind.deltaReconcile);
      expect(probeEngine.syncNowCalls, 1);
    },
    skip: !sqliteAvailable,
  );

  test(
    'manual refresh resumes queued catalog work while playback is active',
    () async {
      final probeEngine = _ProbeLibrarySyncEngine();
      final activePlaybackCoordinator = AdaptiveLibrarySyncCoordinator(
        executor: probeEngine,
        database: database,
        serverConfigRepository: repository,
        networkType: NetworkType.wifi,
        staleAfter: const Duration(hours: 1),
        readHasActivePlayback: () => true,
        now: () => DateTime.utc(2026, 8, 4),
      );
      await database.librarySyncDao.enqueueWork(
        serverId: 1,
        kind: LibrarySyncPlanKind.deltaReconcile.name,
        priority: 50,
      );

      final result = await activePlaybackCoordinator.syncNow();

      expect(result.status, LibrarySyncStatus.succeeded);
      expect(probeEngine.syncNowCalls, 1);
    },
    skip: !sqliteAvailable,
  );

  test(
    'automatic work does not resume a queued explicit full repair',
    () async {
      final probeEngine = _ProbeLibrarySyncEngine();
      final automaticCoordinator = AdaptiveLibrarySyncCoordinator(
        executor: probeEngine,
        database: database,
        serverConfigRepository: repository,
        networkType: NetworkType.wifi,
        staleAfter: const Duration(hours: 1),
        readHasActivePlayback: () => false,
        now: () => DateTime.utc(2026, 8, 4),
      );
      await database.librarySyncDao.writeState(
        LibrarySyncStateTableCompanion(
          serverId: const Value(1),
          currentGeneration: const Value(1),
          lastCheckedAt: Value(DateTime.utc(2026, 8, 4)),
        ),
      );
      await database.librarySyncDao.enqueueWork(
        serverId: 1,
        kind: LibrarySyncPlanKind.fullRepair.name,
        priority: 80,
      );

      final result = await automaticCoordinator.syncIfStale();

      expect(result.status, isNot(LibrarySyncStatus.failed));
      expect(probeEngine.forceFullSyncCalls, 0);
      expect(
        (await database.librarySyncDao.getWork(
          serverId: 1,
          kind: LibrarySyncPlanKind.fullRepair.name,
        ))?.status,
        'queued',
      );
    },
    skip: !sqliteAvailable,
  );

  test(
    'interactive album hydration is allowed on metered networks',
    () async {
      final probeEngine = _ProbeLibrarySyncEngine();
      final meteredCoordinator = AdaptiveLibrarySyncCoordinator(
        executor: probeEngine,
        database: database,
        serverConfigRepository: repository,
        readSyncNetworkPolicy: () => const SyncNetworkPolicy(
          networkType: NetworkType.cellular,
          isMetered: true,
          allowsBackgroundSync: false,
          allowsHardProbe: true,
          allowsInteractiveHydration: true,
        ),
        staleAfter: const Duration(hours: 1),
        readHasActivePlayback: () => false,
        now: () => DateTime.utc(2026, 8, 4),
      );

      await meteredCoordinator.requestSync(
        const LibrarySyncRequest(
          trigger: LibrarySyncTrigger.interaction,
          intent: LibrarySyncIntent.checkForUpdates,
          target: LibrarySyncTarget.album('album-1'),
        ),
      );

      final work = await database.librarySyncDao.getWork(
        serverId: 1,
        kind: LibrarySyncPlanKind.targetedHydration.name,
        entityId: librarySyncTargetWorkKey(
          const LibrarySyncTarget.album('album-1'),
        ),
      );
      expect(work?.workClass, 'interactive');
      expect(work?.status, 'completed');
    },
    skip: !sqliteAvailable,
  );

  test(
    'failed sync keeps executor failure diagnostics',
    () async {
      final failingExecutor = _ProbeLibrarySyncEngine()
        ..forcedResult = LibrarySyncState(
          status: LibrarySyncStatus.failed,
          stage: LibrarySyncStage.completed,
          completedAt: DateTime.utc(2026, 8, 4),
        );
      final failingCoordinator = AdaptiveLibrarySyncCoordinator(
        executor: failingExecutor,
        database: database,
        serverConfigRepository: repository,
        networkType: NetworkType.wifi,
        staleAfter: const Duration(hours: 1),
        readHasActivePlayback: () => false,
        now: () => DateTime.utc(2026, 8, 4),
      );
      await database.librarySyncDao.writeState(
        const LibrarySyncStateTableCompanion(
          serverId: Value(1),
          endpointFailureJson: Value(
            '{"stage":"collectingCandidate","endpoint":"getAlbum",'
            '"entityId":"album-1","exceptionType":"TimeoutException"}',
          ),
        ),
      );

      await failingCoordinator.requestSync(const LibrarySyncRequest.repair());

      final persisted = await database.librarySyncDao.getOrCreateState(1);
      expect(persisted.endpointFailureJson, contains('collectingCandidate'));
      expect(persisted.endpointFailureJson, contains('TimeoutException'));
    },
    skip: !sqliteAvailable,
  );
}
