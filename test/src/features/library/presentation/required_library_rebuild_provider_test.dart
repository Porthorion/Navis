import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/domain/server_reachability.dart';
import 'package:navis/src/features/auth/presentation/initial_server_sync_provider.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/auth/presentation/server_reachability_provider.dart';
import 'package:navis/src/features/auth/presentation/session_route_provider.dart';
import 'package:navis/src/features/cache/data/cache_system_upgrade_service.dart';
import 'package:navis/src/features/cache/data/library_cache_reset_service.dart';
import 'package:navis/src/features/cache/presentation/library_cache_reset_provider.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/library/presentation/required_library_rebuild.dart';
import 'package:navis/src/features/library/presentation/required_library_rebuild_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/connectivity.dart';

import '../../../../helpers/test_database.dart';

class _OnlineReachability extends ServerReachabilityController {
  @override
  ServerReachabilityState build() =>
      const ServerReachabilityState(status: ServerReachabilityStatus.online);
}

class _ControlledSync extends LibrarySyncController {
  new(this.result, {this.beforeResult});

  LibrarySyncState result;
  final Future<void> Function()? beforeResult;
  int calls = 0;

  @override
  LibrarySyncState build() => const LibrarySyncState.idle();

  @override
  Future<LibrarySyncState> syncNow({bool allowMeteredBroadOverride = false}) =>
      _run();

  @override
  Future<LibrarySyncState> forceFullSync({
    bool allowMeteredBroadOverride = false,
  }) => _run();

  @override
  Future<LibrarySyncState> resetCachesAndRebuildLibrary({
    bool allowMeteredBroadOverride = false,
  }) => _run();

  @override
  Future<LibrarySyncState> repairLibrary({
    bool allowMeteredBroadOverride = false,
  }) => _run();

  Future<LibrarySyncState> _run() async {
    calls++;
    await beforeResult?.call();
    return result;
  }
}

const _wifi = SyncNetworkPolicy(
  networkType: NetworkType.wifi,
  isMetered: false,
  allowsBackgroundSync: true,
  allowsHardProbe: true,
  allowsInteractiveHydration: true,
);

ProviderContainer _setupContainer({
  required NavisDatabase database,
  required ServerConfigModel server,
  required _ControlledSync sync,
}) => ProviderContainer(
  overrides: [
    navisDatabaseProvider.overrideWithValue(database),
    serverConfigStateProvider.overrideWithValue(AsyncData(server)),
    serverReachabilityControllerProvider.overrideWith(_OnlineReachability.new),
    syncNetworkPolicyProvider.overrideWithValue(_wifi),
    librarySyncControllerProvider.overrideWith(() => sync),
    libraryCacheResetServiceProvider.overrideWithValue(
      LibraryCacheResetService(database: database, clearCoverArt: () async {}),
    ),
    cacheSystemUpgradeServiceProvider.overrideWithValue(
      CacheSystemUpgradeService(
        database: database,
        cacheResetService: LibraryCacheResetService(
          database: database,
          clearCoverArt: () async {},
        ),
        triggerFullLibraryScan: () async => false,
      ),
    ),
  ],
);

Future<void> _drainMicrotasks() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('only isolated album response gaps qualify for automatic exit', () {
    const usable = LibrarySyncState(
      status: LibrarySyncStatus.partial,
      stage: LibrarySyncStage.completed,
      metadataReady: true,
      pendingHydrationCount: 1,
      onlyIncompleteAlbumDetails: true,
      catalogPublishedThisRun: true,
    );
    expect(isUsableIncompleteAlbumSyncRun(usable), isTrue);
    for (final unsafe in <LibrarySyncState>[
      usable.copyWith(onlyIncompleteAlbumDetails: false),
      usable.copyWith(catalogPublishedThisRun: false),
      usable.copyWith(status: LibrarySyncStatus.failed),
      usable.copyWith(status: LibrarySyncStatus.deferred),
      usable.copyWith(metadataReady: false),
      usable.copyWith(isHydrating: true),
      usable.copyWith(pendingHydrationCount: 0),
      usable.copyWith(remainingVerificationCount: 1),
      usable.copyWith(candidateGeneration: 3),
      usable.copyWith(candidateStatus: 'awaitingDeletionConfirmation'),
    ]) {
      expect(isUsableIncompleteAlbumSyncRun(unsafe), isFalse);
    }
  });

  test(
    'first setup admits only verified incomplete album details across restart',
    () async {
      final database = createTestDatabase();
      addTearDown(database.close);
      await database.serverDao.saveServer(
        ServerConfigTableCompanion.insert(
          url: 'https://example.test',
          username: 'fixture',
          apiVersion: '1.16.1',
        ),
      );
      final server = (await database.serverDao.getActiveServer())!;
      await database.librarySyncDao.writeState(
        LibrarySyncStateTableCompanion(
          serverId: Value(server.id),
          currentGeneration: const Value(2),
        ),
      );
      await database.libraryDao.upsertAlbums([
        AlbumsTableCompanion.insert(
          id: 'incomplete',
          name: 'Incomplete',
          songsHydrated: const Value(false),
        ),
      ]);
      final config = ServerConfigModel(
        id: server.id,
        url: server.url,
        username: server.username,
        password: 'fixture',
        apiVersion: server.apiVersion,
      );
      final sync = _ControlledSync(
        const LibrarySyncState(
          status: LibrarySyncStatus.partial,
          stage: LibrarySyncStage.completed,
          metadataReady: true,
          pendingHydrationCount: 1,
          onlyIncompleteAlbumDetails: true,
          catalogPublishedThisRun: true,
        ),
      );
      final container = _setupContainer(
        database: database,
        server: config,
        sync: sync,
      );
      expect(await container.read(initialSyncRequiredProvider.future), isTrue);
      container.read(
        requiredLibraryRebuildControllerProvider(
          RequiredLibraryRebuildReason.initialLogin,
        ),
      );
      await _drainMicrotasks();
      expect(
        container
            .read(
              requiredLibraryRebuildControllerProvider(
                RequiredLibraryRebuildReason.initialLogin,
              ),
            )
            .status,
        RequiredLibraryRebuildStatus.complete,
      );
      expect(container.read(initialSyncCompletionWarningProvider), isTrue);
      expect(
        await container.refresh(initialSyncRequiredProvider.future),
        isFalse,
      );
      final persisted = await database.librarySyncDao.getOrCreateState(
        server.id,
      );
      expect(persisted.initialCatalogUsableAt, isNotNull);
      expect(persisted.lastCatalogSyncedAt, isNull);
      container.dispose();

      final restarted = _setupContainer(
        database: database,
        server: config,
        sync: _ControlledSync(const LibrarySyncState.idle()),
      );
      addTearDown(restarted.dispose);
      expect(await restarted.read(initialSyncRequiredProvider.future), isFalse);
    },
    skip: !sqliteAvailable,
  );

  for (final reason in <RequiredLibraryRebuildReason>[
    RequiredLibraryRebuildReason.manualCacheReset,
    RequiredLibraryRebuildReason.playbackRecovery,
    RequiredLibraryRebuildReason.cacheUpgrade,
    RequiredLibraryRebuildReason.repairLibrary,
  ]) {
    test(
      '$reason leaves full-screen after safe incomplete album response',
      () async {
        final database = createTestDatabase();
        addTearDown(database.close);
        await database.serverDao.saveServer(
          ServerConfigTableCompanion.insert(
            url: 'https://example.test',
            username: 'fixture',
            apiVersion: '1.16.1',
          ),
        );
        final server = (await database.serverDao.getActiveServer())!;
        await database.librarySyncDao.writeState(
          LibrarySyncStateTableCompanion(
            serverId: Value(server.id),
            currentGeneration: const Value(2),
          ),
        );
        final sync = _ControlledSync(
          const LibrarySyncState(
            status: LibrarySyncStatus.partial,
            stage: LibrarySyncStage.completed,
            metadataReady: true,
            pendingHydrationCount: 1,
            onlyIncompleteAlbumDetails: true,
            catalogPublishedThisRun: true,
          ),
          beforeResult: () async {
            await database.libraryDao.upsertAlbums([
              AlbumsTableCompanion.insert(
                id: 'incomplete',
                name: 'Incomplete',
                songsHydrated: const Value(false),
              ),
            ]);
          },
        );
        final container = _setupContainer(
          database: database,
          server: ServerConfigModel(
            id: server.id,
            url: server.url,
            username: server.username,
            password: 'fixture',
            apiVersion: server.apiVersion,
          ),
          sync: sync,
        );
        addTearDown(container.dispose);
        container.read(requiredLibraryRebuildControllerProvider(reason));
        await _drainMicrotasks();
        expect(sync.calls, 1);
        expect(
          container
              .read(requiredLibraryRebuildControllerProvider(reason))
              .status,
          RequiredLibraryRebuildStatus.complete,
        );
        expect(container.read(initialSyncCompletionWarningProvider), isTrue);
      },
      skip: !sqliteAvailable,
    );
  }

  test(
    'repair cannot use an older committed generation for partial exit',
    () async {
      final database = createTestDatabase();
      addTearDown(database.close);
      await database.serverDao.saveServer(
        ServerConfigTableCompanion.insert(
          url: 'https://example.test',
          username: 'fixture',
          apiVersion: '1.16.1',
        ),
      );
      final server = (await database.serverDao.getActiveServer())!;
      await database.librarySyncDao.writeState(
        LibrarySyncStateTableCompanion(
          serverId: Value(server.id),
          currentGeneration: const Value(2),
        ),
      );
      await database.libraryDao.upsertAlbums([
        AlbumsTableCompanion.insert(
          id: 'incomplete',
          name: 'Incomplete',
          songsHydrated: const Value(false),
        ),
      ]);
      final container = _setupContainer(
        database: database,
        server: ServerConfigModel(
          id: server.id,
          url: server.url,
          username: server.username,
          password: 'fixture',
          apiVersion: server.apiVersion,
        ),
        sync: _ControlledSync(
          const LibrarySyncState(
            status: LibrarySyncStatus.partial,
            stage: LibrarySyncStage.completed,
            metadataReady: true,
            pendingHydrationCount: 1,
            onlyIncompleteAlbumDetails: true,
          ),
        ),
      );
      addTearDown(container.dispose);
      const reason = RequiredLibraryRebuildReason.repairLibrary;
      container.read(requiredLibraryRebuildControllerProvider(reason));
      await _drainMicrotasks();
      expect(
        container.read(requiredLibraryRebuildControllerProvider(reason)).status,
        RequiredLibraryRebuildStatus.failed,
      );
      expect(container.read(initialSyncCompletionWarningProvider), isFalse);
    },
    skip: !sqliteAvailable,
  );

  test(
    'first setup stays required after promotion without a complete sync',
    () async {
      final database = createTestDatabase();
      addTearDown(database.close);
      await database.serverDao.saveServer(
        ServerConfigTableCompanion.insert(
          url: 'https://example.test',
          username: 'fixture',
          apiVersion: '1.16.1',
        ),
      );
      final server = (await database.serverDao.getActiveServer())!;
      await database.librarySyncDao.writeState(
        LibrarySyncStateTableCompanion(
          serverId: Value(server.id),
          currentGeneration: const Value(2),
        ),
      );
      final config = ServerConfigModel(
        id: server.id,
        url: server.url,
        username: server.username,
        password: 'fixture',
        apiVersion: server.apiVersion,
      );
      final sync = _ControlledSync(
        const LibrarySyncState(
          status: LibrarySyncStatus.succeeded,
          stage: LibrarySyncStage.completed,
          metadataReady: true,
        ),
      );
      final container = _setupContainer(
        database: database,
        server: config,
        sync: sync,
      );
      expect(await container.read(initialSyncRequiredProvider.future), isTrue);
      container.read(
        requiredLibraryRebuildControllerProvider(
          RequiredLibraryRebuildReason.initialLogin,
        ),
      );
      await _drainMicrotasks();
      expect(sync.calls, 1);
      expect(
        container
            .read(
              requiredLibraryRebuildControllerProvider(
                RequiredLibraryRebuildReason.initialLogin,
              ),
            )
            .status,
        RequiredLibraryRebuildStatus.failed,
      );
      container.dispose();

      final resumed = _ControlledSync(
        const LibrarySyncState(
          status: LibrarySyncStatus.succeeded,
          stage: LibrarySyncStage.completed,
          pendingHydrationCount: 3,
        ),
      );
      final restarted = _setupContainer(
        database: database,
        server: config,
        sync: resumed,
      );
      addTearDown(restarted.dispose);
      expect(await restarted.read(initialSyncRequiredProvider.future), isTrue);

      await database.librarySyncDao.writeState(
        LibrarySyncStateTableCompanion(
          serverId: Value(server.id),
          lastCatalogSyncedAt: Value(DateTime.utc(2026, 9, 20)),
        ),
      );
      restarted.read(
        requiredLibraryRebuildControllerProvider(
          RequiredLibraryRebuildReason.initialLogin,
        ),
      );
      await _drainMicrotasks();
      expect(
        restarted
            .read(
              requiredLibraryRebuildControllerProvider(
                RequiredLibraryRebuildReason.initialLogin,
              ),
            )
            .status,
        RequiredLibraryRebuildStatus.failed,
      );

      resumed.result = const LibrarySyncState(
        status: LibrarySyncStatus.succeeded,
        stage: LibrarySyncStage.completed,
        pendingHydrationCount: 0,
      );
      await restarted
          .read(
            requiredLibraryRebuildControllerProvider(
              RequiredLibraryRebuildReason.initialLogin,
            ).notifier,
          )
          .retry();
      expect(
        restarted
            .read(
              requiredLibraryRebuildControllerProvider(
                RequiredLibraryRebuildReason.initialLogin,
              ),
            )
            .status,
        RequiredLibraryRebuildStatus.complete,
      );
      expect(
        await restarted.refresh(initialSyncRequiredProvider.future),
        isFalse,
      );
    },
    skip: !sqliteAvailable,
  );
}
