import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
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
  _StaticReachabilityController(this.initial);

  final ServerReachabilityState initial;

  @override
  ServerReachabilityState build() => initial;
}

class _RecordingLibrarySyncController extends LibrarySyncController {
  _RecordingLibrarySyncController(this.result, {this.gate});

  final LibrarySyncState result;
  final Completer<void>? gate;
  int calls = 0;
  bool? lastAllowMeteredOverride;

  @override
  LibrarySyncState build() => const LibrarySyncState.idle();

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
  _SingleFlightRecordingLibrarySyncController(super.result, {super.gate});

  Future<LibrarySyncState>? _active;

  @override
  Future<LibrarySyncState> syncNow({
    bool allowMeteredBroadOverride = false,
  }) {
    return _active ??= super.syncNow(
      allowMeteredBroadOverride: allowMeteredBroadOverride,
    );
  }
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
}
