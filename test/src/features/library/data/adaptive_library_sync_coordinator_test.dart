import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/api/sync_request_scope.dart';
import 'package:navis/src/features/auth/data/secure_credential_store.dart';
import 'package:navis/src/features/auth/data/server_config_repository.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/library/data/adaptive_library_sync_coordinator.dart';
import 'package:navis/src/features/library/data/library_sync_engine.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/domain/sync_run_contract.dart';
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
  int hydrateAlbumCalls = 0;
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
  }) async {
    hydrateAlbumCalls++;
    return _idle();
  }

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
  Future<LibrarySyncState> syncPlaylistHeaders({
    LibrarySyncProgressCallback? onProgress,
  }) async => _idle();

  @override
  Future<LibrarySyncState> syncStarredContent({
    LibrarySyncProgressCallback? onProgress,
  }) async => _idle();
}

class _BlockingCatalogEngine extends _ProbeLibrarySyncEngine {
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<LibrarySyncState> forceFullSync({
    Iterable<String> priorityAlbumIds = const <String>[],
    LibrarySyncProgressCallback? onProgress,
  }) async {
    if (!entered.isCompleted) {
      entered.complete();
      await release.future;
    }
    return await super.forceFullSync(
      priorityAlbumIds: priorityAlbumIds,
      onProgress: onProgress,
    );
  }
}

class _ThrowingTransportEngine extends _ProbeLibrarySyncEngine {
  @override
  Future<LibrarySyncState> forceFullSync({
    Iterable<String> priorityAlbumIds = const <String>[],
    LibrarySyncProgressCallback? onProgress,
  }) async {
    onProgress?.call(
      const LibrarySyncState(
        status: LibrarySyncStatus.running,
        stage: LibrarySyncStage.fetchingArtists,
      ),
    );
    final attempt = SyncRequestScope.current!.beginTransport('getArtists');
    attempt.observe(9);
    attempt.finish(succeeded: false);
    throw StateError('private server failure');
  }
}

class _CompletedCatalogWithPendingAlbumEngine
    implements LibrarySyncEngine, TargetedLibrarySyncExecutor {
  final List<String> targetedCalls = <String>[];
  int syncIfStaleCalls = 0;

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
  }) async {
    syncIfStaleCalls++;
    return _result();
  }

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
  Future<LibrarySyncState> syncPlaylistHeaders({
    LibrarySyncProgressCallback? onProgress,
  }) async => _targetResult();

  @override
  Future<LibrarySyncState> syncStarredContent({
    LibrarySyncProgressCallback? onProgress,
  }) async => _targetResult();

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

  tearDown(() => database.close());

  test('replanning after an active run completes reuses the queued durable request', () async {
    final blocking = _BlockingCatalogEngine();
    final serial = AdaptiveLibrarySyncCoordinator(
      executor: blocking,
      database: database,
      serverConfigRepository: repository,
      networkType: NetworkType.wifi,
      staleAfter: const Duration(hours: 1),
      readHasActivePlayback: () => false,
      now: () => DateTime.utc(2026, 8, 4),
    );
    final active = serial.requestSync(const LibrarySyncRequest.repair());
    await blocking.entered.future;
    final queued = serial.requestSync(
      const LibrarySyncRequest.checkForUpdates(),
    );
    // Wait until the second request has a durable queued row behind the executor.
    LibrarySyncRunRequestTableData? queuedRow;
    for (var i = 0; i < 100; i++) {
      final rows = await database
          .select(database.librarySyncRunRequestTable)
          .get();
      final waiting = rows.where((row) => row.status == 0);
      if (waiting.isNotEmpty) {
        queuedRow = waiting.first;
        break;
      }
      await Future<void>.delayed(Duration.zero);
    }
    expect(queuedRow, isNotNull);
    blocking.release.complete();
    await active;
    final result = await queued;
    expect(result.runRequestId, queuedRow!.id);
    final rows = await database
        .select(database.librarySyncRunRequestTable)
        .get();
    expect(rows.where((row) => row.status == 0 || row.status == 1), isEmpty);
    final history = await database.librarySyncDao.getRecentSyncRunHistory(1);
    expect(
      history.where((run) => run.requestId == queuedRow!.id),
      hasLength(1),
    );
  }, skip: !sqliteAvailable);

  test(
    'replanning to another target retires the original queued request',
    () async {
      final blocking = _BlockingCatalogEngine();
      final serial = AdaptiveLibrarySyncCoordinator(
        executor: blocking,
        database: database,
        serverConfigRepository: repository,
        networkType: NetworkType.wifi,
        staleAfter: const Duration(hours: 1),
        readHasActivePlayback: () => false,
        now: () => DateTime.utc(2026, 8, 4),
      );
      final active = serial.requestSync(const LibrarySyncRequest.repair());
      await blocking.entered.future;
      final waiting = serial.requestSync(const LibrarySyncRequest.automatic());
      LibrarySyncRunRequestTableData? original;
      for (var i = 0; i < 100; i++) {
        final rows = await database
            .select(database.librarySyncRunRequestTable)
            .get();
        final queued = rows.where((row) => row.status == 0);
        if (queued.isNotEmpty) {
          original = queued.first;
          break;
        }
        await Future<void>.delayed(Duration.zero);
      }
      expect(original, isNotNull);
      await database.librarySyncDao.enqueueWork(
        serverId: 1,
        kind: LibrarySyncPlanKind.targetedHydration.name,
        entityId: 'album:a',
        priority: 100,
        workClass: 'interactive',
        checkpointJson: '{"targetKind":"album"}',
      );
      blocking.release.complete();
      await active;
      final result = await waiting;
      expect(result.runRequestId, isNot(original!.id));
      final rows = await database
          .select(database.librarySyncRunRequestTable)
          .get();
      expect(rows.where((row) => row.status != 2), isEmpty);
      final history = await database.librarySyncDao.getRecentSyncRunHistory(1);
      final retired = history.where((entry) => entry.requestId == original!.id);
      expect(retired, hasLength(1));
      expect(retired.single.outcome, SyncRunOutcomeKind.skipped);
    },
    skip: !sqliteAvailable,
  );

  for (final (capabilities, mirrored, expected) in [
    (
      jsonEncode({
        'navis': {'libraryIndexesUnsupportedAt': '2026-08-01'},
      }),
      'reliable',
      LibrarySyncPlanKind.compatibilityAudit,
    ),
    (
      jsonEncode({
        'navis': {'libraryIndexesCursor': '2026-08-01T00:00:00Z'},
      }),
      'unsupported',
      LibrarySyncPlanKind.probe,
    ),
    ('malformed', 'unsupported', LibrarySyncPlanKind.probe),
    (
      jsonEncode({
        'navis': {'libraryIndexesCursor': 'invalid'},
      }),
      'unsupported',
      LibrarySyncPlanKind.probe,
    ),
  ]) {
    test(
      'planning reads capabilities instead of mirrored $mirrored: $capabilities',
      () async {
        await repository.updateCapabilitiesJson(capabilities);
        await database.librarySyncDao.writeState(
          LibrarySyncStateTableCompanion(
            serverId: const Value(1),
            currentGeneration: const Value(1),
            providerFingerprint: const Value(
              'https://music.example.test|1.16.1',
            ),
            conditionalIndexesMode: Value(mirrored),
            lastCheckedAt: Value(DateTime.utc(2026, 8, 4)),
            lastAuditAt: Value(DateTime.utc(2026, 8, 2)),
          ),
        );
        final result = await coordinator.syncIfStale();
        expect(result.planKind, expected);
        expect(
          (await database.librarySyncDao.getOrCreateState(1))
              .conditionalIndexesMode,
          mirrored,
        );
      },
      skip: !sqliteAvailable,
    );
  }

  test(
    'backend changes clear sync capabilities and preserve provider metadata',
    () async {
      await repository.updateCapabilitiesJson(
        jsonEncode({
          'provider': {'supportsScanStatus': true},
          'navis': {
            'libraryIndexesUnsupportedAt': '2026-08-01',
            'libraryIndexesCursor': '2026-08-01T00:00:00Z',
            'bulkSongSearchWildcardQuery': '',
            'libraryPendingIndexesArtistIds': '["stale"]',
          },
        }),
      );
      await database.librarySyncDao.writeState(
        LibrarySyncStateTableCompanion(
          serverId: const Value(1),
          providerFingerprint: const Value('previous-backend'),
          currentGeneration: const Value(1),
          candidateGeneration: const Value(2),
          candidateStatus: const Value('collecting'),
          lastCheckedAt: Value(DateTime.utc(2026, 8, 4)),
          lastAuditAt: Value(DateTime.utc(2026, 8, 2)),
        ),
      );
      await database.librarySyncDao.enqueueWork(
        serverId: 1,
        kind: LibrarySyncPlanKind.catalogSnapshot.name,
        priority: 1,
      );
      const otherCapabilities =
          '{"navis":{"libraryIndexesCursor":"other-server"}}';
      final otherServer = await database
          .into(database.serverConfigTable)
          .insert(
            ServerConfigTableCompanion.insert(
              url: 'https://other.example.test',
              username: 'listener',
              apiVersion: '1.16.1',
              isAuthenticated: const Value(false),
              capabilities: const Value(otherCapabilities),
            ),
          );
      final result = await coordinator.syncIfStale();
      expect(result.planKind, LibrarySyncPlanKind.probe);
      final root = jsonDecode(
        (await repository.getActiveServer())!.capabilitiesJson!,
      ) as Map;
      expect(root.containsKey('navis'), isFalse);
      expect(root['provider'], {'supportsScanStatus': true});
      final other = await (database.select(
        database.serverConfigTable,
      )..where((row) => row.id.equals(otherServer))).getSingle();
      expect(other.capabilities, otherCapabilities);
      final state = await database.librarySyncDao.getOrCreateState(1);
      expect(state.candidateGeneration, isNull);
      expect(state.candidateStatus, isNull);
      expect(
        await database.librarySyncDao.getWork(
          serverId: 1,
          kind: LibrarySyncPlanKind.catalogSnapshot.name,
        ),
        isNull,
      );
    },
    skip: !sqliteAvailable,
  );

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
      final history = (await database.librarySyncDao.getRecentSyncRunHistory(1))
          .singleWhere((entry) => entry.requestId == result.runRequestId);
      expect(result.runRequestId, history.requestId);
      expect(result.runAttemptId, history.attemptId);
      final attempt = (await database.librarySyncDao.getRecentSyncAttempts(
        1,
        attemptId: result.runAttemptId,
      )).first;
      final telemetry =
          jsonDecode(attempt.telemetryJson!) as Map<String, dynamic>;
      expect(telemetry['captureComplete'], isTrue);
      expect(telemetry['status'], 'partial');
      expect(telemetry['pending']['albumHydration'], 1);
      expect(telemetry['transport']['observed'], isFalse);
    },
    skip: !sqliteAvailable,
  );

  test(
    'unexpected executor failure retains consumed bytes and attempt evidence',
    () async {
      final failing = AdaptiveLibrarySyncCoordinator(
        executor: _ThrowingTransportEngine(),
        database: database,
        serverConfigRepository: repository,
        networkType: NetworkType.wifi,
        staleAfter: const Duration(hours: 1),
        readHasActivePlayback: () => false,
      );
      await expectLater(
        failing.requestSync(const LibrarySyncRequest.repair()),
        throwsStateError,
      );
      final history = (await database.librarySyncDao.getRecentSyncRunHistory(1))
          .first;
      expect(history.requestCount, 1);
      expect(history.byteCount, 9);
      expect(history.outcome, SyncRunOutcomeKind.failed);
      final attempt = (await database.librarySyncDao.getRecentSyncAttempts(1))
          .first;
      expect(attempt.status, 2);
      final telemetry =
          jsonDecode(attempt.telemetryJson!) as Map<String, dynamic>;
      expect(telemetry['status'], 'failed');
      expect(telemetry['transport']['requests'], 1);
      expect(attempt.telemetryJson, isNot(contains('private server failure')));
    },
  );

  test(
    'cooldown deferral records a typed durable outcome without dispatching',
    () async {
      await database.librarySyncDao.writeState(
        LibrarySyncStateTableCompanion(
          serverId: const Value(1),
          failureStreak: const Value(3),
          nextEligibleAt: Value(DateTime.utc(2026, 8, 5)),
        ),
      );

      final result = await coordinator.requestSync(
        const LibrarySyncRequest.automatic(),
      );

      expect(result.status, LibrarySyncStatus.deferred);
      expect(result.planReason, 'endpointCircuitOpen');
      expect(executor.syncIfStaleCalls, 0);
      final history = await database.librarySyncDao.getRecentSyncRunHistory(1);
      final deferred = history.where(
        (run) => run.reason == SyncSafeReason.cooldown,
      );
      expect(deferred, hasLength(1));
      expect(deferred.single.outcome, SyncRunOutcomeKind.deferred);
      // The catalog circuit does not suppress independent auxiliary domains.
      expect(history, hasLength(3));
    },
    skip: !sqliteAvailable,
  );

  test('promotion completion closes only running broad catalog work', () async {
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
  }, skip: !sqliteAvailable);

  test('same-ID targeted work remains distinct by entity type', () async {
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
  }, skip: !sqliteAvailable);

  test(
    'target hydration preserves a persisted catalog retry cooldown',
    () async {
      final retryAt = DateTime.utc(2026, 8, 4, 0, 15);
      await database.librarySyncDao.writeState(
        LibrarySyncStateTableCompanion(
          serverId: const Value(1),
          nextEligibleAt: Value(retryAt),
        ),
      );

      final result = await coordinator.requestSync(
        const LibrarySyncRequest(
          trigger: LibrarySyncTrigger.interaction,
          intent: LibrarySyncIntent.checkForUpdates,
          target: LibrarySyncTarget.album('album-with-cooldown'),
        ),
      );

      final persisted = await database.librarySyncDao.getOrCreateState(1);
      expect(persisted.nextEligibleAt?.isAtSameMomentAs(retryAt), isTrue);
      expect(result.nextRetryAt?.isAtSameMomentAs(retryAt), isTrue);
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

  test('manual refresh does not let queued album hydration replace catalog discovery', () async {
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
    const target = LibrarySyncTarget.album('album-pending');
    await database.librarySyncDao.enqueueWork(
      serverId: 1,
      kind: LibrarySyncPlanKind.targetedHydration.name,
      entityId: librarySyncTargetWorkKey(target),
      priority: 100,
      workClass: 'interactive',
    );

    final result = await manualCoordinator.syncNow();

    expect(result.planKind, LibrarySyncPlanKind.deltaReconcile);
    expect(probeEngine.syncNowCalls, 1);
    expect(probeEngine.hydrateAlbumCalls, 0);
    expect(
      (await database.librarySyncDao.getWork(
        serverId: 1,
        kind: LibrarySyncPlanKind.targetedHydration.name,
        entityId: librarySyncTargetWorkKey(target),
      ))?.status,
      'queued',
    );
  }, skip: !sqliteAvailable);

  test(
    'escalated delta reconciliation is claimed by the next due automatic sync',
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
      // The discovery-debt escalation enqueues exactly this follow-up row.
      await database.librarySyncDao.enqueueWork(
        serverId: 1,
        kind: LibrarySyncPlanKind.deltaReconcile.name,
        entityId: '',
        priority: 50,
        workClass: 'background',
        releaseCooldown: true,
      );
      final probeEngine = _ProbeLibrarySyncEngine();
      final coordinator = AdaptiveLibrarySyncCoordinator(
        executor: probeEngine,
        database: database,
        serverConfigRepository: repository,
        networkType: NetworkType.wifi,
        staleAfter: const Duration(hours: 1),
        readHasActivePlayback: () => false,
        now: () => DateTime.utc(2026, 8, 4),
      );

      // Foreground, idle, unmetered: the due automatic catalog sync admits
      // the broad reconciliation instead of leaving it queued forever.
      final result = await coordinator.requestSync(
        const LibrarySyncRequest.automatic(),
      );

      expect(result.planKind, LibrarySyncPlanKind.deltaReconcile);
      expect(probeEngine.syncNowCalls, 1);
      expect(
        (await database.librarySyncDao.getWork(
          serverId: 1,
          kind: LibrarySyncPlanKind.deltaReconcile.name,
        ))?.status,
        'completed',
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
        readHasActivePlayback: () => true,
        readIsForeground: () => true,
        now: () => DateTime.utc(2026, 8, 4),
      );
      final resumed = await onlineCoordinator.syncIfStale();

      expect(resumed.status, LibrarySyncStatus.succeeded);
      expect(resumed.planKind, LibrarySyncPlanKind.deltaReconcile);
      expect(probeEngine.syncNowCalls, 1);
    },
    skip: !sqliteAvailable,
  );

  for (final (name, network, foreground, playing, worker, resumes) in [
    ('foreground playback', NetworkType.wifi, true, true, false, true),
    ('offline', NetworkType.offline, true, false, false, false),
    ('metered', NetworkType.cellular, true, false, false, false),
    ('hidden', NetworkType.wifi, false, false, false, false),
    ('hidden playback', NetworkType.wifi, false, true, false, false),
    ('idle worker', NetworkType.wifi, false, false, true, true),
    ('playing worker', NetworkType.wifi, false, true, true, false),
  ]) {
    test(
      'queued explicit discovery resumes only when eligible: $name',
      () async {
        await database.librarySyncDao.writeState(
          const LibrarySyncStateTableCompanion(
            serverId: Value(1),
            currentGeneration: Value(1),
          ),
        );
        await database.librarySyncDao.enqueueWork(
          serverId: 1,
          kind: LibrarySyncPlanKind.deltaReconcile.name,
          priority: 60,
          checkpointJson: jsonEncode({'intent': 'checkForUpdates'}),
        );
        final probeEngine = _ProbeLibrarySyncEngine();
        final guarded = AdaptiveLibrarySyncCoordinator(
          executor: probeEngine,
          database: database,
          serverConfigRepository: repository,
          networkType: network,
          staleAfter: const Duration(hours: 1),
          readIsForeground: () => foreground,
          readHasActivePlayback: () => playing,
          isBackgroundExecution: worker,
          now: () => DateTime.utc(2026, 8, 4),
        );

        await guarded.syncIfStale();

        expect(probeEngine.syncNowCalls, resumes ? 1 : 0);
        expect(
          (await database.librarySyncDao.getWork(
            serverId: 1,
            kind: LibrarySyncPlanKind.deltaReconcile.name,
          ))?.status,
          resumes ? 'completed' : 'queued',
        );
      },
      skip: !sqliteAvailable,
    );
  }

  test('manual cellular refresh runs bounded discovery before a broad-data override', () async {
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

    final discoveryResult = await meteredCoordinator.syncNow();

    expect(discoveryResult.planKind, LibrarySyncPlanKind.deltaReconcile);
    expect(discoveryResult.planReason, 'manualMeteredLimitedDiscovery');
    expect(probeEngine.probeCalls, 0);
    expect(probeEngine.syncNowCalls, 1);

    final broadResult = await meteredCoordinator.syncNow(
      allowMeteredBroadOverride: true,
    );

    expect(broadResult.planKind, LibrarySyncPlanKind.deltaReconcile);
    expect(probeEngine.syncNowCalls, 2);
  }, skip: !sqliteAvailable);

  test(
    'manual cellular refresh does not resume a queued automatic probe',
    () async {
      await database.librarySyncDao.writeState(
        const LibrarySyncStateTableCompanion(
          serverId: Value(1),
          currentGeneration: Value(1),
        ),
      );
      await database.librarySyncDao.enqueueWork(
        serverId: 1,
        kind: LibrarySyncPlanKind.probe.name,
        priority: 20,
      );
      final probeEngine = _ProbeLibrarySyncEngine();
      const policy = SyncNetworkPolicy(
        networkType: NetworkType.cellular,
        isMetered: true,
        allowsBackgroundSync: false,
        allowsHardProbe: true,
        allowsInteractiveHydration: true,
      );
      final coordinator = AdaptiveLibrarySyncCoordinator(
        executor: probeEngine,
        database: database,
        serverConfigRepository: repository,
        readSyncNetworkPolicy: () => policy,
        staleAfter: const Duration(hours: 1),
        readHasActivePlayback: () => false,
        now: () => DateTime.utc(2026, 8, 4),
      );

      final result = await coordinator.syncNow();

      expect(result.planKind, LibrarySyncPlanKind.deltaReconcile);
      expect(result.planReason, 'manualMeteredLimitedDiscovery');
      expect(probeEngine.syncNowCalls, 1);
      expect(probeEngine.probeCalls, 0);
      expect(
        (await database.librarySyncDao.getWork(
          serverId: 1,
          kind: LibrarySyncPlanKind.probe.name,
        ))?.status,
        'queued',
      );
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
      expect(result.planReason, 'resumeDeltaReconcile');
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

  test('manual discovery leaves a queued full repair dormant', () async {
    await database.librarySyncDao.writeState(
      const LibrarySyncStateTableCompanion(
        serverId: Value(1),
        currentGeneration: Value(1),
      ),
    );
    await database.librarySyncDao.enqueueWork(
      serverId: 1,
      kind: LibrarySyncPlanKind.fullRepair.name,
      priority: 80,
    );
    final probeEngine = _ProbeLibrarySyncEngine();
    final guarded = AdaptiveLibrarySyncCoordinator(
      executor: probeEngine,
      database: database,
      serverConfigRepository: repository,
      networkType: NetworkType.wifi,
      staleAfter: const Duration(hours: 1),
      readHasActivePlayback: () => false,
      now: () => DateTime.utc(2026, 8, 4),
    );
    final result = await guarded.syncNow();
    expect(result.planKind, LibrarySyncPlanKind.deltaReconcile);
    expect(probeEngine.forceFullSyncCalls, 0);
    expect(
      (await database.librarySyncDao.getWork(
        serverId: 1,
        kind: LibrarySyncPlanKind.fullRepair.name,
      ))?.status,
      'queued',
    );
  }, skip: !sqliteAvailable);

  for (final (name, foreground, playing, worker, allowed) in [
    ('foreground playback', true, true, false, true),
    ('hidden', false, false, false, false),
    ('hidden playback', false, true, false, false),
    ('idle worker', false, false, true, true),
    ('playing worker', false, true, true, false),
  ]) {
    test('interactive hydration retains visibility limits: $name', () async {
      final probeEngine = _ProbeLibrarySyncEngine();
      final guarded = AdaptiveLibrarySyncCoordinator(
        executor: probeEngine,
        database: database,
        serverConfigRepository: repository,
        networkType: NetworkType.wifi,
        staleAfter: const Duration(hours: 1),
        readIsForeground: () => foreground,
        readHasActivePlayback: () => playing,
        isBackgroundExecution: worker,
        now: () => DateTime.utc(2026, 8, 4),
      );
      final result = await guarded.requestSync(
        const LibrarySyncRequest(
          trigger: LibrarySyncTrigger.interaction,
          intent: LibrarySyncIntent.automatic,
          target: LibrarySyncTarget.album('album-1'),
        ),
      );

      expect(
        result.status,
        allowed ? LibrarySyncStatus.succeeded : LibrarySyncStatus.deferred,
      );
      expect(probeEngine.hydrateAlbumCalls, allowed ? 1 : 0);
    }, skip: !sqliteAvailable);
  }

  test('interactive album hydration is allowed on metered networks', () async {
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
  }, skip: !sqliteAvailable);

  test('failed sync keeps executor failure diagnostics', () async {
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
  }, skip: !sqliteAvailable);

  test(
    'metered repair without consent defers before joining or starting work',
    () async {
      final meteredCoordinator = AdaptiveLibrarySyncCoordinator(
        executor: executor,
        database: database,
        serverConfigRepository: repository,
        networkType: NetworkType.cellular,
        staleAfter: const Duration(hours: 1),
        readHasActivePlayback: () => false,
        now: () => DateTime.utc(2026, 8, 4),
      );

      final result = await meteredCoordinator.requestSync(
        const LibrarySyncRequest.repair(),
      );

      expect(result.status, LibrarySyncStatus.deferred);
      expect(result.planReason, 'waitingForMobileConsent');
      // No durable repair work was enqueued while consent was absent.
      final work = await database.librarySyncDao.getWork(
        serverId: 1,
        kind: LibrarySyncPlanKind.fullRepair.name,
        entityId: 'catalog',
      );
      expect(work, isNull);
    },
    skip: !sqliteAvailable,
  );

  test(
    'session grant survives retries within the session and clears on cancel',
    () async {
      final meteredCoordinator = AdaptiveLibrarySyncCoordinator(
        executor: executor,
        database: database,
        serverConfigRepository: repository,
        networkType: NetworkType.cellular,
        staleAfter: const Duration(hours: 1),
        readHasActivePlayback: () => false,
        now: () => DateTime.utc(2026, 8, 4),
      );
      meteredCoordinator.beginRepairSession(serverId: 1, allowMetered: true);

      // A retry-style re-entry without the request-level flag keeps the grant.
      final first = await meteredCoordinator.requestSync(
        const LibrarySyncRequest.repair(),
      );
      expect(first.planReason, isNot('waitingForMobileConsent'));

      meteredCoordinator.endRepairSession();
      final afterClear = await meteredCoordinator.requestSync(
        const LibrarySyncRequest.repair(),
      );
      expect(afterClear.planReason, 'waitingForMobileConsent');
    },
    skip: !sqliteAvailable,
  );
}
