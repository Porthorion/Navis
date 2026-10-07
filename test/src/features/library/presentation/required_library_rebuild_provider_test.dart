import 'dart:async';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/data/sign_out_service.dart';
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
import 'package:flutter_riverpod/misc.dart' show Override;

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
  final List<String> methods = <String>[];
  int get calls => methods.length;

  @override
  LibrarySyncState build() => const LibrarySyncState.idle();

  @override
  Future<LibrarySyncState> syncNow({bool allowMeteredBroadOverride = false}) =>
      _run('syncNow');

  @override
  Future<LibrarySyncState> forceFullSync({
    bool allowMeteredBroadOverride = false,
  }) => _run('forceFullSync');

  @override
  Future<LibrarySyncState> resetCachesAndRebuildLibrary({
    bool allowMeteredBroadOverride = false,
  }) => _run('resetCachesAndRebuildLibrary');

  @override
  Future<LibrarySyncState> repairLibrary({
    bool allowMeteredBroadOverride = false,
  }) => _run('repairLibrary');

  Future<LibrarySyncState> _run(String method) async {
    methods.add(method);
    await beforeResult?.call();
    return resultFor(method);
  }

  LibrarySyncState resultFor(String method) => result;
}

/// Models the engine difference behind first setup with a committed catalog:
/// incremental discovery never publishes a catalog in its own run, while the
/// explicit full scan does.
class _PublishingFullScanSync extends _ControlledSync {
  new() : super(_publishedIncompleteAlbum);

  @override
  LibrarySyncState resultFor(String method) => method == 'forceFullSync'
      ? _publishedIncompleteAlbum
      : _publishedIncompleteAlbum.copyWith(catalogPublishedThisRun: false);
}

const _publishedIncompleteAlbum = LibrarySyncState(
  status: LibrarySyncStatus.partial,
  stage: LibrarySyncStage.completed,
  metadataReady: true,
  pendingHydrationCount: 1,
  onlyIncompleteAlbumDetails: true,
  catalogPublishedThisRun: true,
);

class _CountingCacheReset extends LibraryCacheResetService {
  new(NavisDatabase database)
    : super(database: database, clearCoverArt: () async {});

  int resets = 0;

  @override
  Future<void> reset() {
    resets++;
    return super.reset();
  }
}

class _GatedSignOut implements SignOutService {
  final Completer<void> gate = Completer<void>();
  int calls = 0;

  @override
  Future<void> signOut({required bool wipeLocalData}) {
    calls++;
    return gate.future;
  }
}

class _SignedOutServerConfig extends ServerConfigNotifier {
  @override
  Future<ServerConfigModel?> build() async => null;

  @override
  Future<void> refresh() async {}
}

Future<(NavisDatabase, ServerConfigModel)> _committedCatalog() async {
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
  return (
    database,
    ServerConfigModel(
      id: server.id,
      url: server.url,
      username: server.username,
      password: 'fixture',
      apiVersion: server.apiVersion,
    ),
  );
}

Future<void> _insertIncompleteAlbum(NavisDatabase database) {
  return database.libraryDao.upsertAlbums([
    AlbumsTableCompanion.insert(
      id: 'incomplete',
      name: 'Incomplete',
      songsHydrated: const Value(false),
    ),
  ]);
}

class _Session extends Notifier<AsyncValue<ServerConfigModel?>> {
  new(this.initial);

  final ServerConfigModel initial;

  @override
  AsyncValue<ServerConfigModel?> build() => AsyncData(initial);

  void set(ServerConfigModel? server) => state = AsyncData(server);
}

final _sessionProvider =
    NotifierProvider<_Session, AsyncValue<ServerConfigModel?>>(
      () => throw UnimplementedError('Override with the test session.'),
    );

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
  List<Override> extra = const <Override>[],
  LibraryCacheResetService? cacheReset,
  Override? session,
}) => ProviderContainer(
  overrides: [
    ...extra,
    navisDatabaseProvider.overrideWithValue(database),
    session ?? serverConfigStateProvider.overrideWithValue(AsyncData(server)),
    serverReachabilityControllerProvider.overrideWith(_OnlineReachability.new),
    syncNetworkPolicyProvider.overrideWithValue(_wifi),
    librarySyncControllerProvider.overrideWith(() => sync),
    libraryCacheResetServiceProvider.overrideWithValue(
      cacheReset ??
          LibraryCacheResetService(
            database: database,
            clearCoverArt: () async {},
          ),
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

/// Holds the route-scoped controller as the mounted screen does.
ProviderSubscription<RequiredLibraryRebuildState> _mount(
  ProviderContainer container,
  RequiredLibraryRebuildReason reason,
) => container.listen(
  requiredLibraryRebuildControllerProvider(reason),
  (_, _) {},
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
      _mount(container, RequiredLibraryRebuildReason.initialLogin);
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
        _mount(container, reason);
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
      _mount(container, reason);
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
      _mount(container, RequiredLibraryRebuildReason.initialLogin);
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
      _mount(restarted, RequiredLibraryRebuildReason.initialLogin);
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

  test(
    'first setup over a committed catalog runs the full scan that publishes it',
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
      // An interrupted setup promoted a catalog without readiness evidence.
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
      final sync = _PublishingFullScanSync();
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
      container.listen(initialSyncRequiredProvider, (_, _) {});
      expect(await container.read(initialSyncRequiredProvider.future), isTrue);
      const reason = RequiredLibraryRebuildReason.initialLogin;
      _mount(container, reason);
      await _drainMicrotasks();

      expect(sync.methods, <String>['forceFullSync']);
      expect(
        container.read(requiredLibraryRebuildControllerProvider(reason)).status,
        RequiredLibraryRebuildStatus.complete,
      );
      expect(
        await container.refresh(initialSyncRequiredProvider.future),
        isFalse,
      );
      final persisted = await database.librarySyncDao.getOrCreateState(
        server.id,
      );
      expect(persisted.initialCatalogUsableAt, isNotNull);
      expect(
        await database.appSettingsDao.getLastFullSyncAppBuild(),
        currentLibrarySyncModelVersion,
      );
    },
    skip: !sqliteAvailable,
  );

  test(
    'first setup without a catalog keeps the planner first-catalog request',
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
      final sync = _ControlledSync(
        const LibrarySyncState(
          status: LibrarySyncStatus.failed,
          stage: LibrarySyncStage.collectingCandidate,
        ),
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
      const reason = RequiredLibraryRebuildReason.initialLogin;
      _mount(container, reason);
      await _drainMicrotasks();

      expect(sync.methods, <String>['syncNow']);
      expect(
        container.read(requiredLibraryRebuildControllerProvider(reason)).status,
        RequiredLibraryRebuildStatus.failed,
      );
    },
    skip: !sqliteAvailable,
  );

  for (final reason in RequiredLibraryRebuildReason.values) {
    test('$reason starts a new rebuild on every visit to its route', () async {
      final (database, server) = await _committedCatalog();
      final cacheReset = _CountingCacheReset(database);
      final sync = _ControlledSync(
        _publishedIncompleteAlbum,
        beforeResult: () => _insertIncompleteAlbum(database),
      );
      final container = _setupContainer(
        database: database,
        server: server,
        sync: sync,
        cacheReset: cacheReset,
      );
      addTearDown(container.dispose);
      final provider = requiredLibraryRebuildControllerProvider(reason);

      final firstVisit = _mount(container, reason);
      await _drainMicrotasks();
      expect(
        container.read(provider).status,
        RequiredLibraryRebuildStatus.complete,
      );
      firstVisit.close();
      await _drainMicrotasks();
      expect(container.exists(provider), isFalse);

      _mount(container, reason);
      await _drainMicrotasks();
      expect(sync.calls, 2);
      expect(
        container.read(provider).status,
        RequiredLibraryRebuildStatus.complete,
      );
      final clearsCache =
          reason == RequiredLibraryRebuildReason.manualCacheReset ||
          reason == RequiredLibraryRebuildReason.playbackRecovery;
      expect(cacheReset.resets, clearsCache ? 2 : 0);
    }, skip: !sqliteAvailable);
  }

  test('retry within one visit does not clear the cache again', () async {
    final (database, server) = await _committedCatalog();
    final cacheReset = _CountingCacheReset(database);
    final sync = _ControlledSync(
      const LibrarySyncState(
        status: LibrarySyncStatus.failed,
        stage: LibrarySyncStage.collectingCandidate,
      ),
    );
    final container = _setupContainer(
      database: database,
      server: server,
      sync: sync,
      cacheReset: cacheReset,
    );
    addTearDown(container.dispose);
    const reason = RequiredLibraryRebuildReason.manualCacheReset;
    _mount(container, reason);
    await _drainMicrotasks();
    await container
        .read(requiredLibraryRebuildControllerProvider(reason).notifier)
        .retry();

    expect(sync.calls, 2);
    expect(cacheReset.resets, 1);
  }, skip: !sqliteAvailable);

  test('cancelling setup survives its route closing and never reaches the next session', () async {
    final (database, server) = await _committedCatalog();
    final signOut = _GatedSignOut();
    final sync = _ControlledSync(
      const LibrarySyncState(
        status: LibrarySyncStatus.failed,
        stage: LibrarySyncStage.collectingCandidate,
      ),
    );
    final container = _setupContainer(
      database: database,
      server: server,
      sync: sync,
      extra: [
        signOutServiceProvider.overrideWithValue(signOut),
        serverConfigProvider.overrideWith(_SignedOutServerConfig.new),
      ],
    );
    addTearDown(container.dispose);
    const reason = RequiredLibraryRebuildReason.initialLogin;
    final provider = requiredLibraryRebuildControllerProvider(reason);
    final visit = _mount(container, reason);
    await _drainMicrotasks();
    expect(
      container.read(provider).status,
      RequiredLibraryRebuildStatus.failed,
    );

    final cancelling = container.read(provider.notifier).cancelAndSignOut();
    expect(
      container.read(provider).status,
      RequiredLibraryRebuildStatus.cancelling,
    );
    // Signing out replaces the route while the sign-out is still running.
    visit.close();
    await _drainMicrotasks();
    expect(container.exists(provider), isTrue);
    signOut.gate.complete();
    await cancelling;
    await _drainMicrotasks();
    expect(signOut.calls, 1);
    expect(container.exists(provider), isFalse);

    _mount(container, reason);
    await _drainMicrotasks();
    expect(sync.calls, 2);
    expect(
      container.read(provider).status,
      RequiredLibraryRebuildStatus.failed,
    );
  }, skip: !sqliteAvailable);

  test(
    'a run finishes its readiness bookkeeping after its route closes',
    () async {
      final (database, server) = await _committedCatalog();
      await _insertIncompleteAlbum(database);
      final gate = Completer<void>();
      final sync = _ControlledSync(
        _publishedIncompleteAlbum,
        beforeResult: () => gate.future,
      );
      final container = _setupContainer(
        database: database,
        server: server,
        sync: sync,
      );
      addTearDown(container.dispose);
      const reason = RequiredLibraryRebuildReason.initialLogin;
      final provider = requiredLibraryRebuildControllerProvider(reason);
      final visit = _mount(container, reason);
      await _drainMicrotasks();
      expect(
        container.read(provider).status,
        RequiredLibraryRebuildStatus.syncing,
      );

      visit.close();
      await _drainMicrotasks();
      expect(container.exists(provider), isTrue);
      gate.complete();
      await _drainMicrotasks();

      final persisted = await database.librarySyncDao.getOrCreateState(
        server.id!,
      );
      expect(persisted.initialCatalogUsableAt, isNotNull);
      await _drainMicrotasks();
      expect(container.exists(provider), isFalse);
    },
    skip: !sqliteAvailable,
  );

  test(
    'a route kept mounted across sign-out and sign-in starts a new visit',
    () async {
      final (database, server) = await _committedCatalog();
      final signOut = _GatedSignOut();
      final sync = _ControlledSync(
        const LibrarySyncState(
          status: LibrarySyncStatus.failed,
          stage: LibrarySyncStage.collectingCandidate,
        ),
      );
      final container = _setupContainer(
        database: database,
        server: server,
        sync: sync,
        session: serverConfigStateProvider.overrideWith(
          (ref) => ref.watch(_sessionProvider),
        ),
        extra: [
          _sessionProvider.overrideWith(() => _Session(server)),
          signOutServiceProvider.overrideWithValue(signOut),
          serverConfigProvider.overrideWith(_SignedOutServerConfig.new),
        ],
      );
      addTearDown(container.dispose);
      const reason = RequiredLibraryRebuildReason.initialLogin;
      final provider = requiredLibraryRebuildControllerProvider(reason);
      // The route's exit transition is reused, so the screen never unmounts.
      _mount(container, reason);
      await _drainMicrotasks();
      expect(sync.calls, 1);

      final cancelling = container.read(provider.notifier).cancelAndSignOut();
      container.read(_sessionProvider.notifier).set(null);
      signOut.gate.complete();
      await cancelling;
      await _drainMicrotasks();
      expect(
        container.read(provider).status,
        RequiredLibraryRebuildStatus.idle,
      );
      expect(sync.calls, 1);

      container.read(_sessionProvider.notifier).set(server);
      await _drainMicrotasks();
      expect(sync.calls, 2);
      expect(
        container.read(provider).status,
        RequiredLibraryRebuildStatus.failed,
      );
    },
    skip: !sqliteAvailable,
  );

  test(
    'a cancel whose sign-out keeps the session offers retry again',
    () async {
      final (database, server) = await _committedCatalog();
      final signOut = _GatedSignOut()..gate.complete();
      final sync = _ControlledSync(
        const LibrarySyncState(
          status: LibrarySyncStatus.failed,
          stage: LibrarySyncStage.collectingCandidate,
        ),
      );
      final container = _setupContainer(
        database: database,
        server: server,
        sync: sync,
        extra: [
          signOutServiceProvider.overrideWithValue(signOut),
          serverConfigProvider.overrideWith(_SignedOutServerConfig.new),
        ],
      );
      addTearDown(container.dispose);
      const reason = RequiredLibraryRebuildReason.initialLogin;
      final provider = requiredLibraryRebuildControllerProvider(reason);
      _mount(container, reason);
      await _drainMicrotasks();

      // Teardown steps fail softly, so credentials may survive sign-out.
      await container.read(provider.notifier).cancelAndSignOut();

      expect(signOut.calls, 1);
      expect(
        container.read(provider).status,
        RequiredLibraryRebuildStatus.failed,
      );
    },
    skip: !sqliteAvailable,
  );
}
