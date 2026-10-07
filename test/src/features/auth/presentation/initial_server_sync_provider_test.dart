import 'dart:async';

import 'package:drift/drift.dart' show Value;
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
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/connectivity.dart';

import '../../../../helpers/test_database.dart';

class _StaticReachabilityController extends ServerReachabilityController {
  new(this.initial);

  final ServerReachabilityState initial;

  @override
  ServerReachabilityState build() => initial;
}

class _RecordingLibrarySyncController extends LibrarySyncController {
  new(this.result, {this.gate, this.activeCatalog});

  final LibrarySyncState result;
  final Completer<void>? gate;
  final Future<void>? activeCatalog;

  @override
  Future<void> waitForActiveCatalogSync() async => await activeCatalog;
  int calls = 0;
  int fullScanCalls = 0;
  bool? lastAllowMeteredOverride;

  @override
  LibrarySyncState build() => const LibrarySyncState.idle();

  @override
  Future<LibrarySyncState> forceFullSync({
    bool allowMeteredBroadOverride = false,
  }) {
    fullScanCalls += 1;
    return syncNow(allowMeteredBroadOverride: allowMeteredBroadOverride);
  }

  @override
  Future<LibrarySyncState> syncNow({
    bool allowMeteredBroadOverride = false,
  }) async {
    calls += 1;
    lastAllowMeteredOverride = allowMeteredBroadOverride;
    state = const LibrarySyncState(
      status: LibrarySyncStatus.running,
      stage: LibrarySyncStage.collectingCandidate,
    );
    await gate?.future;
    state = result;
    return result;
  }
}

class _SingleFlightRecordingLibrarySyncController
    extends _RecordingLibrarySyncController {
  new(super.result, {super.gate});

  Future<LibrarySyncState>? _active;

  @override
  Future<LibrarySyncState> syncNow({bool allowMeteredBroadOverride = false}) {
    return _active ??= super.syncNow(
      allowMeteredBroadOverride: allowMeteredBroadOverride,
    );
  }
}

class _Value<T> extends Notifier<T> {
  new(this.initial);

  final T initial;

  @override
  T build() => initial;

  // Simulates a session transition rather than a production property setter.
  // ignore: use_setters_to_change_properties
  void set(T value) => state = value;
}

final _phaseProvider =
    NotifierProvider<_Value<SessionRoutePhase>, SessionRoutePhase>(
      () => throw UnimplementedError('Override with the test phase.'),
    );

final _sessionProvider =
    NotifierProvider<
      _Value<AsyncValue<ServerConfigModel?>>,
      AsyncValue<ServerConfigModel?>
    >(() => throw UnimplementedError('Override with the test session.'));

class _CallbackSignOut implements SignOutService {
  new(this.onSignOut);

  final void Function() onSignOut;
  int calls = 0;

  @override
  Future<void> signOut({required bool wipeLocalData}) async {
    calls += 1;
    onSignOut();
  }
}

class _NoopServerConfig extends ServerConfigNotifier {
  @override
  Future<ServerConfigModel?> build() async => null;

  @override
  Future<void> refresh() async {}
}

const _sessionServer = ServerConfigModel(
  url: 'https://example.com',
  username: 'alice',
  password: 'secret',
  apiVersion: '1.16.1',
);

/// A container whose session and route phase the test drives, as sign-out
/// and sign-in do in the app.
ProviderContainer _sessionContainer({
  required NavisDatabase database,
  required _RecordingLibrarySyncController sync,
  required SessionRoutePhase phase,
  SignOutService? signOut,
}) {
  return ProviderContainer(
    overrides: [
      navisDatabaseProvider.overrideWithValue(database),
      _phaseProvider.overrideWith(() => _Value(phase)),
      _sessionProvider.overrideWith(
        () => _Value<AsyncValue<ServerConfigModel?>>(
          const AsyncData(_sessionServer),
        ),
      ),
      sessionRoutePhaseProvider.overrideWith(
        (ref) => ref.watch(_phaseProvider),
      ),
      serverConfigStateProvider.overrideWith(
        (ref) => ref.watch(_sessionProvider),
      ),
      syncNetworkPolicyProvider.overrideWithValue(_unmetered),
      serverReachabilityControllerProvider.overrideWith(
        () => _StaticReachabilityController(
          const ServerReachabilityState(
            status: ServerReachabilityStatus.online,
          ),
        ),
      ),
      librarySyncControllerProvider.overrideWith(() => sync),
      serverConfigProvider.overrideWith(_NoopServerConfig.new),
      if (signOut != null) signOutServiceProvider.overrideWithValue(signOut),
    ],
  );
}

const _unmetered = SyncNetworkPolicy(
  networkType: NetworkType.wifi,
  isMetered: false,
  allowsBackgroundSync: true,
  allowsHardProbe: true,
  allowsInteractiveHydration: true,
);

const _metered = SyncNetworkPolicy(
  networkType: NetworkType.cellular,
  isMetered: true,
  allowsBackgroundSync: false,
  allowsHardProbe: true,
  allowsInteractiveHydration: true,
);

Future<void> _drainMicrotasks() async {
  for (var i = 0; i < 6; i += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test(
    'readiness stamps only validated success and skips a null model version',
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
      await database.appSettingsDao.setLastFullSyncAppBuild('old-model');
      const completed = LibrarySyncState(
        status: LibrarySyncStatus.succeeded,
        stage: LibrarySyncStage.completed,
      );
      expect(
        await recordInitialCatalogReadiness(
          database: database,
          serverId: server.id,
          result: completed,
          syncModelVersion: currentLibrarySyncModelVersion,
        ),
        isFalse,
      );
      expect(
        await database.appSettingsDao.getLastFullSyncAppBuild(),
        'old-model',
      );
      await database.librarySyncDao.writeState(
        LibrarySyncStateTableCompanion(
          serverId: Value(server.id),
          currentGeneration: const Value(1),
          lastCatalogSyncedAt: Value(DateTime.now()),
        ),
      );
      expect(
        await recordInitialCatalogReadiness(
          database: database,
          serverId: server.id,
          result: completed,
        ),
        isTrue,
      );
      expect(
        await database.appSettingsDao.getLastFullSyncAppBuild(),
        'old-model',
      );
      expect(
        await recordInitialCatalogReadiness(
          database: database,
          serverId: server.id,
          result: completed,
          syncModelVersion: currentLibrarySyncModelVersion,
        ),
        isTrue,
      );
      expect(
        await database.appSettingsDao.getLastFullSyncAppBuild(),
        currentLibrarySyncModelVersion,
      );
    },
    skip: !sqliteAvailable,
  );

  test('offline setup waits without starting catalog sync', () async {
    final database = createTestDatabase();
    addTearDown(database.close);
    final sync = _RecordingLibrarySyncController(
      const LibrarySyncState(
        status: LibrarySyncStatus.succeeded,
        stage: LibrarySyncStage.completed,
      ),
    );
    final container = ProviderContainer(
      overrides: [
        navisDatabaseProvider.overrideWithValue(database),
        sessionRoutePhaseProvider.overrideWithValue(
          SessionRoutePhase.initialSyncRequired,
        ),
        syncNetworkPolicyProvider.overrideWithValue(_unmetered),
        serverReachabilityControllerProvider.overrideWith(
          () => _StaticReachabilityController(
            const ServerReachabilityState(
              status: ServerReachabilityStatus.offline,
            ),
          ),
        ),
        librarySyncControllerProvider.overrideWith(() => sync),
      ],
    );
    addTearDown(container.dispose);

    container.read(initialServerSyncControllerProvider);
    await _drainMicrotasks();

    expect(sync.calls, 0);
    expect(
      container.read(initialServerSyncControllerProvider).status,
      InitialServerSyncStatus.waitingForNetwork,
    );
  });

  test(
    'metered setup requires consent and forwards ephemeral override',
    () async {
      final database = createTestDatabase();
      addTearDown(database.close);
      final sync = _RecordingLibrarySyncController(
        const LibrarySyncState(
          status: LibrarySyncStatus.failed,
          stage: LibrarySyncStage.collectingCandidate,
          errorMessage: 'Safe failure',
        ),
      );
      final container = ProviderContainer(
        overrides: [
          navisDatabaseProvider.overrideWithValue(database),
          sessionRoutePhaseProvider.overrideWithValue(
            SessionRoutePhase.initialSyncRequired,
          ),
          syncNetworkPolicyProvider.overrideWithValue(_metered),
          serverReachabilityControllerProvider.overrideWith(
            () => _StaticReachabilityController(
              const ServerReachabilityState(
                status: ServerReachabilityStatus.online,
              ),
            ),
          ),
          librarySyncControllerProvider.overrideWith(() => sync),
          serverConfigStateProvider.overrideWithValue(
            const AsyncData(
              ServerConfigModel(
                url: 'https://example.com',
                username: 'alice',
                password: 'secret',
                apiVersion: '1.16.1',
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      container.read(initialServerSyncControllerProvider);
      await _drainMicrotasks();
      expect(sync.calls, 0);
      expect(
        container.read(initialServerSyncControllerProvider).status,
        InitialServerSyncStatus.waitingForMobileConsent,
      );

      await container
          .read(initialServerSyncControllerProvider.notifier)
          .startUsingMobileData();
      expect(sync.calls, 1);
      expect(sync.lastAllowMeteredOverride, isTrue);
    },
  );

  test(
    'partial promotion remains blocked until a complete catalog sync',
    () async {
      final database = createTestDatabase();
      addTearDown(database.close);
      await database.serverDao.saveServer(
        ServerConfigTableCompanion.insert(
          url: 'https://example.com',
          username: 'alice',
          apiVersion: '1.16.1',
        ),
      );
      final server = await database.serverDao.getActiveServer();
      await database.librarySyncDao.writeState(
        LibrarySyncStateTableCompanion(
          serverId: Value(server!.id),
          currentGeneration: const Value(2),
        ),
      );
      final gate = Completer<void>();
      final sync = _RecordingLibrarySyncController(
        const LibrarySyncState(
          status: LibrarySyncStatus.partial,
          stage: LibrarySyncStage.completed,
          metadataReady: true,
          pendingHydrationCount: 3,
        ),
        gate: gate,
      );
      final container = ProviderContainer(
        overrides: [
          navisDatabaseProvider.overrideWithValue(database),
          sessionRoutePhaseProvider.overrideWithValue(
            SessionRoutePhase.initialSyncRequired,
          ),
          syncNetworkPolicyProvider.overrideWithValue(_unmetered),
          serverReachabilityControllerProvider.overrideWith(
            () => _StaticReachabilityController(
              const ServerReachabilityState(
                status: ServerReachabilityStatus.online,
              ),
            ),
          ),
          librarySyncControllerProvider.overrideWith(() => sync),
          serverConfigStateProvider.overrideWithValue(
            AsyncData(
              ServerConfigModel(
                id: server.id,
                url: server.url,
                username: server.username,
                password: 'secret',
                apiVersion: server.apiVersion,
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      container.read(initialServerSyncControllerProvider);
      await _drainMicrotasks();
      expect(sync.calls, 1);
      expect(
        container.read(initialServerSyncControllerProvider).status,
        InitialServerSyncStatus.running,
      );
      gate.complete();
      await _drainMicrotasks();

      expect(sync.calls, 1);
      expect(
        container.read(initialServerSyncControllerProvider).status,
        InitialServerSyncStatus.failed,
      );
      expect(container.read(initialSyncCompletionWarningProvider), isFalse);
      expect(await database.appSettingsDao.getLastFullSyncAppBuild(), isNull);
    },
    skip: !sqliteAvailable,
  );

  test(
    'setup waits for an already-running sync instead of reporting failure',
    () async {
      final database = createTestDatabase();
      addTearDown(database.close);
      await database.serverDao.saveServer(
        ServerConfigTableCompanion.insert(
          url: 'https://example.com',
          username: 'alice',
          apiVersion: '1.16.1',
        ),
      );
      final server = await database.serverDao.getActiveServer();
      await database.librarySyncDao.writeState(
        LibrarySyncStateTableCompanion(
          serverId: Value(server!.id),
          currentGeneration: const Value(1),
          lastCatalogSyncedAt: Value(DateTime.now()),
        ),
      );
      final gate = Completer<void>();
      final sync = _SingleFlightRecordingLibrarySyncController(
        const LibrarySyncState(
          status: LibrarySyncStatus.succeeded,
          stage: LibrarySyncStage.completed,
        ),
        gate: gate,
      );
      final container = ProviderContainer(
        overrides: [
          navisDatabaseProvider.overrideWithValue(database),
          sessionRoutePhaseProvider.overrideWithValue(
            SessionRoutePhase.initialSyncRequired,
          ),
          syncNetworkPolicyProvider.overrideWithValue(_unmetered),
          serverReachabilityControllerProvider.overrideWith(
            () => _StaticReachabilityController(
              const ServerReachabilityState(
                status: ServerReachabilityStatus.online,
              ),
            ),
          ),
          librarySyncControllerProvider.overrideWith(() => sync),
          serverConfigStateProvider.overrideWithValue(
            AsyncData(
              ServerConfigModel(
                id: server.id,
                url: server.url,
                username: server.username,
                password: 'secret',
                apiVersion: server.apiVersion,
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      container.read(librarySyncControllerProvider);
      final existing = sync.syncNow();
      container.read(initialServerSyncControllerProvider);
      await _drainMicrotasks();

      expect(sync.calls, 1);
      expect(
        container.read(initialServerSyncControllerProvider).status,
        InitialServerSyncStatus.running,
      );

      gate.complete();
      await existing;
      await _drainMicrotasks();

      expect(
        container.read(initialServerSyncControllerProvider).status,
        InitialServerSyncStatus.complete,
      );
    },
  );
  test('router readiness requires complete catalog evidence, not partial generation', () async {
    final database = createTestDatabase();
    addTearDown(database.close);
    await database.serverDao.saveServer(
      ServerConfigTableCompanion.insert(
        url: 'https://example.com',
        username: 'fixture',
        apiVersion: '1.16.1',
      ),
    );
    final server = (await database.serverDao.getActiveServer())!;
    await database.librarySyncDao.writeState(
      LibrarySyncStateTableCompanion(
        serverId: Value(server.id),
        currentGeneration: const Value(1),
      ),
    );
    final container = ProviderContainer(
      overrides: [
        navisDatabaseProvider.overrideWithValue(database),
        serverConfigStateProvider.overrideWithValue(
          AsyncData(
            ServerConfigModel(
              id: server.id,
              url: server.url,
              username: server.username,
              password: 'fixture',
              apiVersion: server.apiVersion,
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.listen(initialSyncRequiredProvider, (_, _) {});
    expect(await container.read(initialSyncRequiredProvider.future), isTrue);
    await database.librarySyncDao.writeState(
      LibrarySyncStateTableCompanion(
        serverId: Value(server.id),
        lastCatalogSyncedAt: Value(DateTime.now()),
      ),
    );
    container.invalidate(initialSyncRequiredProvider);
    expect(await container.read(initialSyncRequiredProvider.future), isFalse);
  });

  test(
    'setup waits for catalog publication before choosing a full scan',
    () async {
      final database = createTestDatabase();
      addTearDown(database.close);
      await database.serverDao.saveServer(
        ServerConfigTableCompanion.insert(
          url: 'https://example.com',
          username: 'alice',
          apiVersion: '1.16.1',
        ),
      );
      final server = (await database.serverDao.getActiveServer())!;
      final activeCatalog = Completer<void>();
      await database.libraryDao.upsertAlbums([
        AlbumsTableCompanion.insert(
          id: 'incomplete',
          name: 'Incomplete',
          songsHydrated: const Value(false),
        ),
      ]);
      final sync = _RecordingLibrarySyncController(
        const LibrarySyncState(
          status: LibrarySyncStatus.partial,
          stage: LibrarySyncStage.completed,
          metadataReady: true,
          pendingHydrationCount: 1,
          onlyIncompleteAlbumDetails: true,
          catalogPublishedThisRun: true,
        ),
        activeCatalog: activeCatalog.future,
      );
      final container = ProviderContainer(
        overrides: [
          navisDatabaseProvider.overrideWithValue(database),
          sessionRoutePhaseProvider.overrideWithValue(
            SessionRoutePhase.initialSyncRequired,
          ),
          syncNetworkPolicyProvider.overrideWithValue(_unmetered),
          serverReachabilityControllerProvider.overrideWith(
            () => _StaticReachabilityController(
              const ServerReachabilityState(
                status: ServerReachabilityStatus.online,
              ),
            ),
          ),
          librarySyncControllerProvider.overrideWith(() => sync),
          serverConfigStateProvider.overrideWithValue(
            AsyncData(
              ServerConfigModel(
                id: server.id,
                url: server.url,
                username: server.username,
                password: 'secret',
                apiVersion: server.apiVersion,
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      container.listen(initialServerSyncControllerProvider, (_, _) {});
      await _drainMicrotasks();
      expect(sync.calls, 0);
      await database.librarySyncDao.writeState(
        LibrarySyncStateTableCompanion(
          serverId: Value(server.id),
          currentGeneration: const Value(2),
        ),
      );
      activeCatalog.complete();
      await _drainMicrotasks();

      expect(sync.fullScanCalls, 1);
      expect(
        container.read(initialServerSyncControllerProvider).status,
        InitialServerSyncStatus.complete,
      );
      expect(container.read(initialSyncCompletionWarningProvider), isTrue);
      expect(
        await database.appSettingsDao.getLastFullSyncAppBuild(),
        currentLibrarySyncModelVersion,
      );
    },
    skip: !sqliteAvailable,
  );

  test(
    'setup waits for the session phase instead of syncing while it loads',
    () async {
      final database = createTestDatabase();
      addTearDown(database.close);
      final sync = _RecordingLibrarySyncController(
        const LibrarySyncState(
          status: LibrarySyncStatus.failed,
          stage: LibrarySyncStage.collectingCandidate,
        ),
      );
      final container = _sessionContainer(
        database: database,
        sync: sync,
        phase: SessionRoutePhase.loading,
      );
      addTearDown(container.dispose);

      // The diagnostics server keeps an active subscription once activated.
      container.listen(initialServerSyncControllerProvider, (_, _) {});
      await _drainMicrotasks();
      expect(sync.calls, 0);

      container.read(_phaseProvider.notifier).set(SessionRoutePhase.ready);
      await _drainMicrotasks();
      expect(sync.calls, 0);
      expect(
        container.read(initialServerSyncControllerProvider).status,
        InitialServerSyncStatus.complete,
      );
    },
  );

  test('a cancelled setup does not carry into the next session', () async {
    final database = createTestDatabase();
    addTearDown(database.close);
    final sync = _RecordingLibrarySyncController(
      const LibrarySyncState(
        status: LibrarySyncStatus.failed,
        stage: LibrarySyncStage.collectingCandidate,
      ),
    );
    late final ProviderContainer container;
    final signOut = _CallbackSignOut(() {
      container.read(_sessionProvider.notifier).set(const AsyncData(null));
      container
          .read(_phaseProvider.notifier)
          .set(SessionRoutePhase.unauthenticated);
    });
    container = _sessionContainer(
      database: database,
      sync: sync,
      phase: SessionRoutePhase.initialSyncRequired,
      signOut: signOut,
    );
    addTearDown(container.dispose);
    // The diagnostics server keeps an active subscription once activated.
    container.listen(initialServerSyncControllerProvider, (_, _) {});
    await _drainMicrotasks();
    expect(sync.calls, 1);

    await container
        .read(initialServerSyncControllerProvider.notifier)
        .cancelAndLogOut();
    await _drainMicrotasks();
    expect(signOut.calls, 1);
    expect(
      container.read(initialServerSyncControllerProvider).status,
      isNot(InitialServerSyncStatus.cancelling),
    );

    container
        .read(_sessionProvider.notifier)
        .set(const AsyncData(_sessionServer));
    container
        .read(_phaseProvider.notifier)
        .set(SessionRoutePhase.initialSyncRequired);
    await _drainMicrotasks();
    expect(sync.calls, 2);
    expect(
      container.read(initialServerSyncControllerProvider).status,
      InitialServerSyncStatus.failed,
    );
  });

  test('a failed setup does not carry into the next session', () async {
    final database = createTestDatabase();
    addTearDown(database.close);
    final sync = _RecordingLibrarySyncController(
      const LibrarySyncState(
        status: LibrarySyncStatus.failed,
        stage: LibrarySyncStage.collectingCandidate,
      ),
    );
    final container = _sessionContainer(
      database: database,
      sync: sync,
      phase: SessionRoutePhase.initialSyncRequired,
    );
    addTearDown(container.dispose);
    // The diagnostics server keeps an active subscription once activated.
    container.listen(initialServerSyncControllerProvider, (_, _) {});
    await _drainMicrotasks();
    expect(
      container.read(initialServerSyncControllerProvider).status,
      InitialServerSyncStatus.failed,
    );

    // Signed out elsewhere, then signed in again in the same process.
    container.read(_sessionProvider.notifier).set(const AsyncData(null));
    container
        .read(_phaseProvider.notifier)
        .set(SessionRoutePhase.unauthenticated);
    await _drainMicrotasks();
    container
        .read(_sessionProvider.notifier)
        .set(const AsyncData(_sessionServer));
    container
        .read(_phaseProvider.notifier)
        .set(SessionRoutePhase.initialSyncRequired);
    await _drainMicrotasks();

    expect(sync.calls, 2);
  });

  test('a cancel whose sign-out keeps the session offers retry', () async {
    final database = createTestDatabase();
    addTearDown(database.close);
    final sync = _RecordingLibrarySyncController(
      const LibrarySyncState(
        status: LibrarySyncStatus.failed,
        stage: LibrarySyncStage.collectingCandidate,
      ),
    );
    final container = _sessionContainer(
      database: database,
      sync: sync,
      phase: SessionRoutePhase.initialSyncRequired,
      // Teardown steps fail softly, so credentials may survive sign-out.
      signOut: _CallbackSignOut(() {}),
    );
    addTearDown(container.dispose);
    // The diagnostics server keeps an active subscription once activated.
    container.listen(initialServerSyncControllerProvider, (_, _) {});
    await _drainMicrotasks();

    await container
        .read(initialServerSyncControllerProvider.notifier)
        .cancelAndLogOut();

    expect(
      container.read(initialServerSyncControllerProvider).status,
      InitialServerSyncStatus.failed,
    );
  });
}
