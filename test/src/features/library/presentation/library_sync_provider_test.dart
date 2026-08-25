import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/domain/server_reachability.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/auth/presentation/server_reachability_provider.dart';
import 'package:navis/src/features/library/data/library_sync_engine.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/connectivity.dart';

import '../../../../helpers/test_database.dart';

// Test overrides for @visibleForTesting providers.
final _manualSyncInterval = syncIntervalMinutesProvider.overrideWithValue(0);
final _shortSyncInterval = syncIntervalDurationProvider.overrideWithValue(
  const Duration(milliseconds: 10),
);

Future<ServerConfigModel> _saveAuthenticatedServer(
  NavisDatabase database, {
  DateTime? lastSynced,
}) async {
  await database.serverDao.saveServer(
    ServerConfigTableCompanion.insert(
      url: 'https://example.com',
      username: 'alice',
      apiVersion: '1.16.1',
      isAuthenticated: const Value(true),
      lastSynced: Value(lastSynced),
    ),
  );
  final server = await database.serverDao.getActiveServer();
  return ServerConfigModel(
    id: server!.id,
    url: server.url,
    username: server.username,
    password: 'secret',
    apiVersion: server.apiVersion,
    lastSynced: server.lastSynced,
  );
}

class _StaticReachabilityController extends ServerReachabilityController {
  _StaticReachabilityController(this._state);

  final ServerReachabilityState _state;

  @override
  ServerReachabilityState build() => _state;
}

class _MutableReachabilityController extends ServerReachabilityController {
  _MutableReachabilityController(this._initial);

  final ServerReachabilityState _initial;

  @override
  ServerReachabilityState build() => _initial;

  void setStatus(ServerReachabilityStatus status) {
    state = state.copyWith(status: status);
  }
}

class _MutableLibrarySyncEngine extends Notifier<LibrarySyncEngine?> {
  @override
  LibrarySyncEngine? build() => null;

  // This simulates an asynchronous provider update in the startup race.
  // ignore: use_setters_to_change_properties
  void replace(LibrarySyncEngine? engine) {
    state = engine;
  }
}

class _FakeLibrarySyncEngine extends LibrarySyncEngine {
  _FakeLibrarySyncEngine(
    this._handlerIfStale,
    this._handlerNow, {
    this.requestHandler,
  });

  final Future<LibrarySyncState> Function({
    LibrarySyncProgressCallback? onProgress,
  })
  _handlerIfStale;
  final Future<LibrarySyncState> Function({
    bool forceFull,
    LibrarySyncProgressCallback? onProgress,
  })
  _handlerNow;
  final Future<LibrarySyncState> Function(
    LibrarySyncRequest request, {
    LibrarySyncProgressCallback? onProgress,
  })?
  requestHandler;

  int staleCalls = 0;
  int nowCalls = 0;
  int continuationCalls = 0;
  final List<bool> forceFullCalls = <bool>[];

  @override
  Future<LibrarySyncState> requestSync(
    LibrarySyncRequest request, {
    Iterable<String> priorityAlbumIds = const <String>[],
    LibrarySyncProgressCallback? onProgress,
  }) {
    final handler = requestHandler;
    if (handler != null) {
      return handler(request, onProgress: onProgress);
    }
    return super.requestSync(
      request,
      priorityAlbumIds: priorityAlbumIds,
      onProgress: onProgress,
    );
  }

  @override
  Future<LibrarySyncState> syncIfStale({
    Iterable<String> priorityAlbumIds = const <String>[],
    LibrarySyncProgressCallback? onProgress,
  }) {
    staleCalls++;
    return _handlerIfStale(onProgress: onProgress);
  }

  @override
  Future<LibrarySyncState> syncNow({
    Iterable<String> priorityAlbumIds = const <String>[],
    LibrarySyncProgressCallback? onProgress,
  }) {
    nowCalls++;
    forceFullCalls.add(false);
    return _handlerNow(forceFull: false, onProgress: onProgress);
  }

  @override
  Future<LibrarySyncState> continueVerification({
    Iterable<String> priorityAlbumIds = const <String>[],
    LibrarySyncProgressCallback? onProgress,
  }) {
    continuationCalls++;
    return _handlerNow(forceFull: false, onProgress: onProgress);
  }

  @override
  Future<LibrarySyncState> forceFullSync({
    Iterable<String> priorityAlbumIds = const <String>[],
    LibrarySyncProgressCallback? onProgress,
  }) {
    nowCalls++;
    forceFullCalls.add(true);
    return _handlerNow(forceFull: true, onProgress: onProgress);
  }

  @override
  Future<LibrarySyncState> probeCatalog({
    LibrarySyncProgressCallback? onProgress,
  }) {
    nowCalls++;
    return _handlerNow(forceFull: false, onProgress: onProgress);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('librarySyncControllerProvider', () {
    test(
      'startup waits for its API-backed engine without publishing failure',
      () async {
        final database = createTestDatabase();
        addTearDown(database.close);
        final engine = _FakeLibrarySyncEngine(
          ({onProgress}) async => LibrarySyncState(
            status: LibrarySyncStatus.succeeded,
            stage: LibrarySyncStage.completed,
            completedAt: DateTime.now(),
          ),
          ({forceFull = false, onProgress}) async => LibrarySyncState(
            status: LibrarySyncStatus.succeeded,
            stage: LibrarySyncStage.completed,
            completedAt: DateTime.now(),
          ),
        );
        final engineState =
            NotifierProvider<_MutableLibrarySyncEngine, LibrarySyncEngine?>(
              _MutableLibrarySyncEngine.new,
            );
        final container = ProviderContainer(
          overrides: [
            _manualSyncInterval,
            navisDatabaseProvider.overrideWithValue(database),
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
            serverReachabilityControllerProvider.overrideWith(
              () => _StaticReachabilityController(
                const ServerReachabilityState(
                  status: ServerReachabilityStatus.online,
                ),
              ),
            ),
            librarySyncEngineProvider.overrideWith(
              (ref) => ref.watch(engineState),
            ),
          ],
        );
        addTearDown(container.dispose);

        container.read(librarySyncControllerProvider);
        await Future<void>.delayed(const Duration(milliseconds: 5));
        expect(
          container.read(librarySyncControllerProvider).status,
          LibrarySyncStatus.idle,
        );
        expect(container.read(librarySyncEngineProvider), isNull);

        container.read(engineState.notifier).replace(engine);
        expect(container.read(librarySyncEngineProvider), same(engine));
        await Future<void>.delayed(const Duration(milliseconds: 100));

        expect(engine.nowCalls, 1);
        expect(
          container.read(librarySyncControllerProvider).status,
          LibrarySyncStatus.succeeded,
        );
      },
    );

    test('startup trigger runs once when authenticated', () async {
      final database = createTestDatabase();
      addTearDown(database.close);
      await database.appSettingsDao.setLastFullSyncAppBuild(
        currentLibrarySyncModelVersion,
      );
      final engine = _FakeLibrarySyncEngine(
        ({
          onProgress,
        }) async {
          final state = LibrarySyncState(
            status: LibrarySyncStatus.succeeded,
            stage: LibrarySyncStage.completed,
            completedAt: DateTime.now(),
            lastSyncedAt: DateTime.now(),
          );
          onProgress?.call(state);
          return state;
        },
        ({
          forceFull = false,
          onProgress,
        }) async {
          final state = LibrarySyncState(
            status: LibrarySyncStatus.succeeded,
            stage: LibrarySyncStage.completed,
            completedAt: DateTime.now(),
            lastSyncedAt: DateTime.now(),
          );
          onProgress?.call(state);
          return state;
        },
      );
      final container = ProviderContainer(
        overrides: [
          _manualSyncInterval,
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
          serverReachabilityControllerProvider.overrideWith(
            () => _StaticReachabilityController(
              const ServerReachabilityState(
                status: ServerReachabilityStatus.online,
              ),
            ),
          ),
          navisDatabaseProvider.overrideWithValue(database),
          librarySyncEngineProvider.overrideWithValue(engine),
        ],
      );
      addTearDown(container.dispose);

      container.read(librarySyncControllerProvider);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      container.read(librarySyncControllerProvider);

      expect(engine.staleCalls, 1);
      expect(engine.nowCalls, 0);
    });

    test(
      'automatic checks honor a persisted deadline and manual checks leave it unchanged',
      () async {
        final database = createTestDatabase();
        addTearDown(database.close);
        final config = await _saveAuthenticatedServer(database);
        final deadline = DateTime.now().add(const Duration(hours: 1));
        await database.librarySyncDao.setNextAutomaticCheckAt(
          serverId: config.id!,
          nextAutomaticCheckAt: deadline,
        );
        final retryAt = DateTime.now().add(const Duration(minutes: 15));
        await database.librarySyncDao.writeState(
          LibrarySyncStateTableCompanion(
            serverId: Value(config.id!),
            nextEligibleAt: Value(retryAt),
          ),
        );
        final engine = _FakeLibrarySyncEngine(
          ({onProgress}) async => const LibrarySyncState(
            status: LibrarySyncStatus.succeeded,
            stage: LibrarySyncStage.completed,
          ),
          ({forceFull = false, onProgress}) async => LibrarySyncState(
            status: LibrarySyncStatus.succeeded,
            stage: LibrarySyncStage.completed,
            completedAt: DateTime.now(),
          ),
        );
        final container = ProviderContainer(
          overrides: [
            _manualSyncInterval,
            requiredLibrarySyncModelVersionProvider.overrideWithValue(null),
            serverConfigStateProvider.overrideWithValue(AsyncData(config)),
            serverReachabilityControllerProvider.overrideWith(
              () => _StaticReachabilityController(
                const ServerReachabilityState(
                  status: ServerReachabilityStatus.online,
                ),
              ),
            ),
            navisDatabaseProvider.overrideWithValue(database),
            librarySyncEngineProvider.overrideWithValue(engine),
          ],
        );
        addTearDown(container.dispose);

        final controller = container.read(
          librarySyncControllerProvider.notifier,
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await controller.syncIfStale();
        expect(engine.staleCalls, 0);
        expect(
          container
              .read(librarySyncControllerProvider)
              .nextRetryAt!
              .difference(retryAt)
              .abs(),
          lessThan(const Duration(seconds: 1)),
        );

        await controller.syncNow();
        final persisted = await database.librarySyncDao.getOrCreateState(
          config.id!,
        );
        expect(engine.nowCalls, 1);
        expect(
          persisted.nextAutomaticCheckAt!.difference(deadline).abs(),
          lessThan(const Duration(seconds: 1)),
        );
        expect(
          container
              .read(librarySyncControllerProvider)
              .nextAutomaticCheckAt!
              .difference(deadline)
              .abs(),
          lessThan(const Duration(seconds: 1)),
        );
      },
    );

    test(
      'expired automatic deadline runs once and persists the next deadline',
      () async {
        final database = createTestDatabase();
        addTearDown(database.close);
        final config = await _saveAuthenticatedServer(database);
        await database.librarySyncDao.setNextAutomaticCheckAt(
          serverId: config.id!,
          nextAutomaticCheckAt: DateTime.now().subtract(
            const Duration(minutes: 1),
          ),
        );
        final engine = _FakeLibrarySyncEngine(
          ({onProgress}) async => LibrarySyncState(
            status: LibrarySyncStatus.succeeded,
            stage: LibrarySyncStage.completed,
            completedAt: DateTime.now(),
          ),
          ({forceFull = false, onProgress}) async => const LibrarySyncState(
            status: LibrarySyncStatus.succeeded,
            stage: LibrarySyncStage.completed,
          ),
        );
        final startedAt = DateTime.now();
        final container = ProviderContainer(
          overrides: [
            syncIntervalMinutesProvider.overrideWithValue(60),
            syncIntervalDurationProvider.overrideWithValue(
              const Duration(hours: 1),
            ),
            serverConfigStateProvider.overrideWithValue(AsyncData(config)),
            serverReachabilityControllerProvider.overrideWith(
              () => _StaticReachabilityController(
                const ServerReachabilityState(
                  status: ServerReachabilityStatus.offline,
                ),
              ),
            ),
            navisDatabaseProvider.overrideWithValue(database),
            librarySyncEngineProvider.overrideWithValue(engine),
          ],
        );
        addTearDown(container.dispose);

        final result = await container
            .read(librarySyncControllerProvider.notifier)
            .syncIfStale();
        final persisted = await database.librarySyncDao.getOrCreateState(
          config.id!,
        );

        expect(result.status, LibrarySyncStatus.succeeded);
        expect(engine.staleCalls, 1);
        expect(persisted.nextAutomaticCheckAt, isNotNull);
        expect(persisted.nextAutomaticCheckAt!.isAfter(startedAt), isTrue);
        expect(
          persisted.nextAutomaticCheckAt!.difference(startedAt),
          greaterThan(const Duration(minutes: 59)),
        );
      },
    );

    test(
      'eligible user catalog work bypasses a fresh automatic deadline',
      () async {
        final database = createTestDatabase();
        addTearDown(database.close);
        final config = await _saveAuthenticatedServer(database);
        final deadline = DateTime.now().add(const Duration(hours: 1));
        await database.librarySyncDao.setNextAutomaticCheckAt(
          serverId: config.id!,
          nextAutomaticCheckAt: deadline,
        );
        await database.librarySyncDao.enqueueWork(
          serverId: config.id!,
          kind: LibrarySyncPlanKind.deltaReconcile.name,
          priority: 60,
        );
        final engine = _FakeLibrarySyncEngine(
          ({onProgress}) async => LibrarySyncState(
            status: LibrarySyncStatus.succeeded,
            stage: LibrarySyncStage.completed,
            completedAt: DateTime.now(),
          ),
          ({forceFull = false, onProgress}) async => const LibrarySyncState(
            status: LibrarySyncStatus.succeeded,
            stage: LibrarySyncStage.completed,
          ),
        );
        final container = ProviderContainer(
          overrides: [
            syncIntervalMinutesProvider.overrideWithValue(60),
            syncIntervalDurationProvider.overrideWithValue(
              const Duration(hours: 1),
            ),
            requiredLibrarySyncModelVersionProvider.overrideWithValue(null),
            serverConfigStateProvider.overrideWithValue(AsyncData(config)),
            serverReachabilityControllerProvider.overrideWith(
              () => _StaticReachabilityController(
                const ServerReachabilityState(
                  status: ServerReachabilityStatus.online,
                ),
              ),
            ),
            navisDatabaseProvider.overrideWithValue(database),
            librarySyncEngineProvider.overrideWithValue(engine),
          ],
        );
        addTearDown(container.dispose);

        container.read(librarySyncControllerProvider);
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(engine.staleCalls, 1);
        final persisted = await database.librarySyncDao.getOrCreateState(
          config.id!,
        );
        expect(
          persisted.nextAutomaticCheckAt!.difference(deadline).abs(),
          lessThan(const Duration(seconds: 1)),
        );
      },
    );

    test(
      'automatic timer waits for the persisted deadline before one catalog pass',
      () async {
        final database = createTestDatabase();
        addTearDown(database.close);
        final config = await _saveAuthenticatedServer(database);
        await database.librarySyncDao.setNextAutomaticCheckAt(
          serverId: config.id!,
          nextAutomaticCheckAt: DateTime.now().add(
            const Duration(milliseconds: 1500),
          ),
        );
        final engine = _FakeLibrarySyncEngine(
          ({onProgress}) async => LibrarySyncState(
            status: LibrarySyncStatus.succeeded,
            stage: LibrarySyncStage.completed,
            completedAt: DateTime.now(),
          ),
          ({forceFull = false, onProgress}) async => const LibrarySyncState(
            status: LibrarySyncStatus.succeeded,
            stage: LibrarySyncStage.completed,
          ),
        );
        final container = ProviderContainer(
          overrides: [
            syncIntervalMinutesProvider.overrideWithValue(60),
            syncIntervalDurationProvider.overrideWithValue(
              const Duration(hours: 1),
            ),
            requiredLibrarySyncModelVersionProvider.overrideWithValue(null),
            serverConfigStateProvider.overrideWithValue(AsyncData(config)),
            serverReachabilityControllerProvider.overrideWith(
              () => _StaticReachabilityController(
                const ServerReachabilityState(
                  status: ServerReachabilityStatus.offline,
                ),
              ),
            ),
            navisDatabaseProvider.overrideWithValue(database),
            librarySyncEngineProvider.overrideWithValue(engine),
          ],
        );
        addTearDown(container.dispose);

        container.read(librarySyncControllerProvider);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(engine.staleCalls, 0);

        await Future<void>.delayed(const Duration(milliseconds: 1500));
        expect(engine.staleCalls, 1);
        final persisted = await database.librarySyncDao.getOrCreateState(
          config.id!,
        );
        expect(persisted.nextAutomaticCheckAt, isNotNull);
        expect(
          persisted.nextAutomaticCheckAt!.isAfter(
            DateTime.now().subtract(const Duration(minutes: 59)),
          ),
          isTrue,
        );
      },
    );

    test(
      'cancelAndWait drains and suppresses scheduled startup sync',
      () async {
        final database = createTestDatabase();
        addTearDown(database.close);
        await database.appSettingsDao.setLastFullSyncAppBuild(
          currentLibrarySyncModelVersion,
        );
        final startupResult = Completer<LibrarySyncState>();
        final engine = _FakeLibrarySyncEngine(
          ({onProgress}) => startupResult.future,
          ({forceFull = false, onProgress}) async => const LibrarySyncState(
            status: LibrarySyncStatus.succeeded,
            stage: LibrarySyncStage.completed,
          ),
        );
        final container = ProviderContainer(
          overrides: [
            _manualSyncInterval,
            serverConfigStateProvider.overrideWithValue(
              AsyncData(
                ServerConfigModel(
                  url: 'https://example.com',
                  username: 'alice',
                  password: 'secret',
                  apiVersion: '1.16.1',
                  lastSynced: DateTime.now(),
                ),
              ),
            ),
            serverReachabilityControllerProvider.overrideWith(
              () => _MutableReachabilityController(
                const ServerReachabilityState(
                  status: ServerReachabilityStatus.online,
                ),
              ),
            ),
            navisDatabaseProvider.overrideWithValue(database),
            librarySyncEngineProvider.overrideWithValue(engine),
          ],
        );
        addTearDown(container.dispose);

        container.read(librarySyncControllerProvider);
        await Future<void>.delayed(Duration.zero);
        expect(engine.staleCalls, 1);
        var cancellationCompleted = false;
        final cancellation = container
            .read(librarySyncControllerProvider.notifier)
            .cancelAndWait()
            .then((_) => cancellationCompleted = true);
        await Future<void>.delayed(Duration.zero);
        expect(cancellationCompleted, isFalse);

        startupResult.complete(
          const LibrarySyncState(
            status: LibrarySyncStatus.cancelled,
            stage: LibrarySyncStage.completed,
          ),
        );
        await cancellation;
        final reachability = container.read(
          serverReachabilityControllerProvider.notifier,
        ) as _MutableReachabilityController;
        reachability.setStatus(ServerReachabilityStatus.offline);
        reachability.setStatus(ServerReachabilityStatus.online);
        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(cancellationCompleted, isTrue);
        expect(engine.staleCalls, 1);
      },
    );

    test('syncNow transitions through running to succeeded state', () async {
      final completer = Completer<LibrarySyncState>();
      final engine = _FakeLibrarySyncEngine(
        ({
          onProgress,
        }) async {
          return const LibrarySyncState(
            status: LibrarySyncStatus.skipped,
            stage: LibrarySyncStage.completed,
          );
        },
        ({
          forceFull = false,
          onProgress,
        }) async {
          onProgress?.call(
            LibrarySyncState(
              status: LibrarySyncStatus.running,
              stage: LibrarySyncStage.fetchingArtists,
              startedAt: DateTime.now(),
            ),
          );
          return completer.future;
        },
      );

      final container = ProviderContainer(
        overrides: [
          _manualSyncInterval,
          serverConfigStateProvider.overrideWithValue(const AsyncData(null)),
          serverReachabilityControllerProvider.overrideWith(
            () => _StaticReachabilityController(
              const ServerReachabilityState(
                status: ServerReachabilityStatus.checking,
              ),
            ),
          ),
          librarySyncEngineProvider.overrideWithValue(engine),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(librarySyncControllerProvider.notifier);
      final future = notifier.syncNow();
      await Future<void>.delayed(const Duration(milliseconds: 1));

      expect(
        container.read(librarySyncControllerProvider).status,
        LibrarySyncStatus.running,
      );

      completer.complete(
        LibrarySyncState(
          status: LibrarySyncStatus.succeeded,
          stage: LibrarySyncStage.completed,
          completedAt: DateTime.now(),
          lastSyncedAt: DateTime.now(),
        ),
      );
      await future;

      final finalState = container.read(librarySyncControllerProvider);
      expect(finalState.status, LibrarySyncStatus.succeeded);
      expect(finalState.stage, LibrarySyncStage.completed);
      expect(engine.forceFullCalls.last, isFalse);
    });

    test('overlapping sync callers await one terminal result', () async {
      final completer = Completer<LibrarySyncState>();
      final engine = _FakeLibrarySyncEngine(
        ({onProgress}) async => const LibrarySyncState(
          status: LibrarySyncStatus.skipped,
          stage: LibrarySyncStage.completed,
        ),
        ({forceFull = false, onProgress}) async {
          onProgress?.call(
            const LibrarySyncState(
              status: LibrarySyncStatus.running,
              stage: LibrarySyncStage.collectingCandidate,
            ),
          );
          return completer.future;
        },
      );
      final container = ProviderContainer(
        overrides: [
          _manualSyncInterval,
          serverConfigStateProvider.overrideWithValue(const AsyncData(null)),
          serverReachabilityControllerProvider.overrideWith(
            () => _StaticReachabilityController(
              const ServerReachabilityState(
                status: ServerReachabilityStatus.checking,
              ),
            ),
          ),
          librarySyncEngineProvider.overrideWithValue(engine),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(librarySyncControllerProvider.notifier);
      final first = notifier.syncNow();
      final second = notifier.syncIfStale();
      await Future<void>.delayed(Duration.zero);

      expect(engine.nowCalls, 1);
      expect(engine.staleCalls, 0);
      expect(container.read(librarySyncControllerProvider).isRunning, isTrue);

      const completed = LibrarySyncState(
        status: LibrarySyncStatus.succeeded,
        stage: LibrarySyncStage.completed,
      );
      completer.complete(completed);

      expect(await first, completed);
      expect(await second, completed);
      expect(
        container.read(librarySyncControllerProvider).status,
        LibrarySyncStatus.succeeded,
      );
    });

    test(
      'manual refresh runs after an already-active automatic check',
      () async {
        final automaticCompletion = Completer<LibrarySyncState>();
        final manualResult = LibrarySyncState(
          status: LibrarySyncStatus.succeeded,
          stage: LibrarySyncStage.completed,
          completedAt: DateTime.now(),
          planKind: LibrarySyncPlanKind.deltaReconcile,
        );
        final engine = _FakeLibrarySyncEngine(
          ({onProgress}) => automaticCompletion.future,
          ({forceFull = false, onProgress}) async => manualResult,
        );
        final container = ProviderContainer(
          overrides: [
            _manualSyncInterval,
            serverConfigStateProvider.overrideWithValue(const AsyncData(null)),
            serverReachabilityControllerProvider.overrideWith(
              () => _StaticReachabilityController(
                const ServerReachabilityState(
                  status: ServerReachabilityStatus.checking,
                ),
              ),
            ),
            librarySyncEngineProvider.overrideWithValue(engine),
          ],
        );
        addTearDown(container.dispose);

        final notifier = container.read(librarySyncControllerProvider.notifier);
        final automatic = notifier.syncIfStale();
        final manual = notifier.syncNow();
        await Future<void>.delayed(Duration.zero);

        expect(engine.staleCalls, 1);
        expect(engine.nowCalls, 0);

        automaticCompletion.complete(
          const LibrarySyncState(
            status: LibrarySyncStatus.skipped,
            stage: LibrarySyncStage.completed,
          ),
        );
        await automatic;

        expect(await manual, same(manualResult));
        expect(engine.nowCalls, 1);
        expect(
          container.read(librarySyncControllerProvider).planKind,
          LibrarySyncPlanKind.deltaReconcile,
        );
      },
    );

    test(
      'target hydration neither replaces catalog status nor swallows a refresh',
      () async {
        final targetCompletion = Completer<LibrarySyncState>();
        var targetRequests = 0;
        final catalogResult = LibrarySyncState(
          status: LibrarySyncStatus.succeeded,
          stage: LibrarySyncStage.completed,
          completedAt: DateTime.now(),
          planKind: LibrarySyncPlanKind.deltaReconcile,
        );
        final engine = _FakeLibrarySyncEngine(
          ({onProgress}) async => const LibrarySyncState(
            status: LibrarySyncStatus.skipped,
            stage: LibrarySyncStage.completed,
          ),
          ({forceFull = false, onProgress}) async {
            onProgress?.call(catalogResult);
            return catalogResult;
          },
          requestHandler: (request, {onProgress}) {
            expect(request.target.kind, LibrarySyncTargetKind.album);
            targetRequests++;
            onProgress?.call(
              LibrarySyncState(
                status: LibrarySyncStatus.running,
                stage: LibrarySyncStage.fetchingSongs,
                planKind: LibrarySyncPlanKind.targetedHydration,
              ),
            );
            return targetCompletion.future;
          },
        );
        final container = ProviderContainer(
          overrides: [
            _manualSyncInterval,
            serverConfigStateProvider.overrideWithValue(const AsyncData(null)),
            serverReachabilityControllerProvider.overrideWith(
              () => _StaticReachabilityController(
                const ServerReachabilityState(
                  status: ServerReachabilityStatus.checking,
                ),
              ),
            ),
            librarySyncEngineProvider.overrideWithValue(engine),
          ],
        );
        addTearDown(container.dispose);

        final notifier = container.read(librarySyncControllerProvider.notifier);
        final firstTarget = notifier.requestTarget(
          const LibrarySyncTarget.album('album-1'),
        );
        final duplicateTarget = notifier.requestTarget(
          const LibrarySyncTarget.album('album-1'),
        );
        await Future<void>.delayed(Duration.zero);

        expect(targetRequests, 1);
        expect(
          container.read(librarySyncControllerProvider).status,
          LibrarySyncStatus.idle,
        );

        final refreshed = await notifier.syncNow();
        expect(refreshed, same(catalogResult));
        expect(engine.nowCalls, 1);
        expect(
          container.read(librarySyncControllerProvider).planKind,
          LibrarySyncPlanKind.deltaReconcile,
        );

        targetCompletion.complete(
          LibrarySyncState(
            status: LibrarySyncStatus.succeeded,
            stage: LibrarySyncStage.completed,
            completedAt: DateTime.now(),
            planKind: LibrarySyncPlanKind.targetedHydration,
          ),
        );
        await Future.wait(<Future<LibrarySyncState>>[
          firstTarget,
          duplicateTarget,
        ]);

        expect(
          container.read(librarySyncControllerProvider).planKind,
          LibrarySyncPlanKind.deltaReconcile,
        );
      },
    );

    test(
      'artist interaction hydrates missing, incomplete, and countless artists',
      () async {
        final database = createTestDatabase();
        addTearDown(database.close);
        await database.libraryDao.upsertArtists(<ArtistsTableCompanion>[
          ArtistsTableCompanion.insert(
            id: 'complete',
            name: 'Complete Artist',
            albumCount: const Value(1),
          ),
          ArtistsTableCompanion.insert(
            id: 'incomplete',
            name: 'Incomplete Artist',
            albumCount: const Value(2),
          ),
          ArtistsTableCompanion.insert(id: 'countless', name: 'Countless'),
        ]);
        await database.libraryDao.upsertAlbums(<AlbumsTableCompanion>[
          AlbumsTableCompanion.insert(
            id: 'complete-album',
            name: 'Complete Album',
            artistId: const Value('complete'),
          ),
          AlbumsTableCompanion.insert(
            id: 'incomplete-album',
            name: 'Incomplete Album',
            artistId: const Value('incomplete'),
          ),
          AlbumsTableCompanion.insert(
            id: 'countless-album',
            name: 'Countless Album',
            artistId: const Value('countless'),
          ),
        ]);
        final requestedArtistIds = <String>[];
        final engine = _FakeLibrarySyncEngine(
          ({onProgress}) async => const LibrarySyncState(
            status: LibrarySyncStatus.skipped,
            stage: LibrarySyncStage.completed,
          ),
          ({forceFull = false, onProgress}) async => const LibrarySyncState(
            status: LibrarySyncStatus.skipped,
            stage: LibrarySyncStage.completed,
          ),
          requestHandler: (request, {onProgress}) async {
            expect(request.target.kind, LibrarySyncTargetKind.artist);
            requestedArtistIds.add(request.target.entityId!);
            return LibrarySyncState(
              status: LibrarySyncStatus.succeeded,
              stage: LibrarySyncStage.completed,
              completedAt: DateTime.now(),
            );
          },
        );
        final container = ProviderContainer(
          overrides: [
            _manualSyncInterval,
            navisDatabaseProvider.overrideWithValue(database),
            serverConfigStateProvider.overrideWithValue(const AsyncData(null)),
            serverReachabilityControllerProvider.overrideWith(
              () => _StaticReachabilityController(
                const ServerReachabilityState(
                  status: ServerReachabilityStatus.checking,
                ),
              ),
            ),
            librarySyncEngineProvider.overrideWithValue(engine),
          ],
        );
        addTearDown(container.dispose);

        final controller = container.read(
          librarySyncControllerProvider.notifier,
        );
        controller.registerArtistInteraction('missing');
        controller.registerArtistInteraction('incomplete');
        controller.registerArtistInteraction('countless');
        controller.registerArtistInteraction('complete');
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(
          requestedArtistIds,
          unorderedEquals(<String>[
            'missing',
            'incomplete',
            'countless',
          ]),
        );

        await controller.refreshArtist('complete');

        expect(
          requestedArtistIds,
          unorderedEquals(<String>[
            'missing',
            'incomplete',
            'countless',
            'complete',
          ]),
        );
      },
    );

    test(
      'forceFullSync becomes visibly preparing before engine planning',
      () async {
        final completer = Completer<LibrarySyncState>();
        final engine = _FakeLibrarySyncEngine(
          ({onProgress}) async => const LibrarySyncState(
            status: LibrarySyncStatus.skipped,
            stage: LibrarySyncStage.completed,
          ),
          ({forceFull = false, onProgress}) async => completer.future,
        );
        final container = ProviderContainer(
          overrides: [
            _manualSyncInterval,
            serverConfigStateProvider.overrideWithValue(const AsyncData(null)),
            serverReachabilityControllerProvider.overrideWith(
              () => _StaticReachabilityController(
                const ServerReachabilityState(
                  status: ServerReachabilityStatus.checking,
                ),
              ),
            ),
            librarySyncEngineProvider.overrideWithValue(engine),
          ],
        );
        addTearDown(container.dispose);

        final future = container
            .read(librarySyncControllerProvider.notifier)
            .forceFullSync();
        await Future<void>.delayed(Duration.zero);

        final preparing = container.read(librarySyncControllerProvider);
        expect(preparing.status, LibrarySyncStatus.running);
        expect(preparing.stage, LibrarySyncStage.preparing);
        expect(preparing.mode, LibrarySyncMode.forceFull);
        expect(preparing.planKind, LibrarySyncPlanKind.fullRepair);

        completer.complete(
          LibrarySyncState(
            status: LibrarySyncStatus.succeeded,
            stage: LibrarySyncStage.completed,
            completedAt: DateTime.now(),
          ),
        );
        await future;
      },
    );

    test('syncNow transitions through running to failed state', () async {
      final engine = _FakeLibrarySyncEngine(
        ({
          onProgress,
        }) async {
          return const LibrarySyncState(
            status: LibrarySyncStatus.skipped,
            stage: LibrarySyncStage.completed,
          );
        },
        ({
          forceFull = false,
          onProgress,
        }) async {
          onProgress?.call(
            LibrarySyncState(
              status: LibrarySyncStatus.running,
              stage: LibrarySyncStage.fetchingAlbums,
              startedAt: DateTime.now(),
            ),
          );
          return LibrarySyncState(
            status: LibrarySyncStatus.failed,
            stage: LibrarySyncStage.completed,
            completedAt: DateTime.now(),
            errorMessage: 'Sync failed.',
          );
        },
      );

      final container = ProviderContainer(
        overrides: [
          _manualSyncInterval,
          serverConfigStateProvider.overrideWithValue(const AsyncData(null)),
          serverReachabilityControllerProvider.overrideWith(
            () => _StaticReachabilityController(
              const ServerReachabilityState(
                status: ServerReachabilityStatus.checking,
              ),
            ),
          ),
          librarySyncEngineProvider.overrideWithValue(engine),
        ],
      );
      addTearDown(container.dispose);

      await container.read(librarySyncControllerProvider.notifier).syncNow();

      final finalState = container.read(librarySyncControllerProvider);
      expect(finalState.status, LibrarySyncStatus.failed);
      expect(finalState.errorMessage, 'Sync failed.');
      expect(engine.forceFullCalls.last, isFalse);
    });

    test(
      'startup sync retries when reachability moves offline to online',
      () async {
        final database = createTestDatabase();
        addTearDown(database.close);
        await database.appSettingsDao.setLastFullSyncAppBuild(
          currentLibrarySyncModelVersion,
        );
        final engine = _FakeLibrarySyncEngine(
          ({
            onProgress,
          }) async {
            return const LibrarySyncState(
              status: LibrarySyncStatus.succeeded,
              stage: LibrarySyncStage.completed,
            );
          },
          ({
            forceFull = false,
            onProgress,
          }) async {
            return const LibrarySyncState(
              status: LibrarySyncStatus.succeeded,
              stage: LibrarySyncStage.completed,
            );
          },
        );
        late _MutableReachabilityController reachability;

        final container = ProviderContainer(
          overrides: [
            _manualSyncInterval,
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
            serverReachabilityControllerProvider.overrideWith(
              () => reachability = _MutableReachabilityController(
                const ServerReachabilityState(
                  status: ServerReachabilityStatus.offline,
                ),
              ),
            ),
            navisDatabaseProvider.overrideWithValue(database),
            librarySyncEngineProvider.overrideWithValue(engine),
          ],
        );
        addTearDown(container.dispose);

        container.read(librarySyncControllerProvider);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(engine.staleCalls, 0);

        reachability.setStatus(ServerReachabilityStatus.online);
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(engine.staleCalls, 1);
      },
    );

    test(
      'sync model repair deferred on cellular runs when Wi-Fi returns',
      () async {
        final database = createTestDatabase();
        addTearDown(database.close);
        var networkType = NetworkType.cellular;
        final engine = _FakeLibrarySyncEngine(
          ({
            onProgress,
          }) async {
            return const LibrarySyncState(
              status: LibrarySyncStatus.skipped,
              stage: LibrarySyncStage.completed,
            );
          },
          ({
            forceFull = false,
            onProgress,
          }) async {
            return LibrarySyncState(
              status: LibrarySyncStatus.succeeded,
              stage: LibrarySyncStage.completed,
              completedAt: DateTime.now(),
            );
          },
        );

        final container = ProviderContainer(
          overrides: [
            _manualSyncInterval,
            networkTypeProvider.overrideWith(
              (ref) => networkType,
            ),
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
            serverReachabilityControllerProvider.overrideWith(
              () => _StaticReachabilityController(
                const ServerReachabilityState(
                  status: ServerReachabilityStatus.online,
                ),
              ),
            ),
            navisDatabaseProvider.overrideWithValue(database),
            requiredLibrarySyncModelVersionProvider.overrideWithValue(
              'model-v2',
            ),
            librarySyncEngineProvider.overrideWithValue(engine),
          ],
        );
        addTearDown(container.dispose);

        container.read(librarySyncControllerProvider);
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(engine.staleCalls, 1);
        expect(engine.nowCalls, 0);
        expect(await database.appSettingsDao.getLastFullSyncAppBuild(), isNull);

        networkType = NetworkType.wifi;
        container.invalidate(networkTypeProvider);
        expect(container.read(networkTypeProvider), NetworkType.wifi);
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(engine.nowCalls, 1);
        expect(engine.forceFullCalls.single, isTrue);
        expect(
          await database.appSettingsDao.getLastFullSyncAppBuild(),
          'model-v2',
        );
      },
    );

    test(
      'promoted partial catalog satisfies the sync model repair gate',
      () async {
        final database = createTestDatabase();
        addTearDown(database.close);
        final engine = _FakeLibrarySyncEngine(
          ({onProgress}) async => const LibrarySyncState(
            status: LibrarySyncStatus.skipped,
            stage: LibrarySyncStage.completed,
          ),
          ({forceFull = false, onProgress}) async {
            expect(forceFull, isTrue);
            return LibrarySyncState(
              status: LibrarySyncStatus.partial,
              stage: LibrarySyncStage.completed,
              mode: LibrarySyncMode.forceFull,
              metadataReady: true,
              pendingHydrationCount: 1,
              completedAt: DateTime.now(),
            );
          },
        );
        final container = ProviderContainer(
          overrides: [
            _manualSyncInterval,
            networkTypeProvider.overrideWithValue(NetworkType.wifi),
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
            serverReachabilityControllerProvider.overrideWith(
              () => _StaticReachabilityController(
                const ServerReachabilityState(
                  status: ServerReachabilityStatus.online,
                ),
              ),
            ),
            navisDatabaseProvider.overrideWithValue(database),
            librarySyncEngineProvider.overrideWithValue(engine),
          ],
        );
        addTearDown(container.dispose);

        container.read(librarySyncControllerProvider);
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(engine.forceFullCalls, <bool>[true]);
        expect(
          await database.appSettingsDao.getLastFullSyncAppBuild(),
          currentLibrarySyncModelVersion,
        );
      },
    );

    test('unauthenticated state does not trigger startup sync', () async {
      final engine = _FakeLibrarySyncEngine(
        ({
          onProgress,
        }) async {
          return const LibrarySyncState(
            status: LibrarySyncStatus.succeeded,
            stage: LibrarySyncStage.completed,
          );
        },
        ({
          forceFull = false,
          onProgress,
        }) async {
          return const LibrarySyncState(
            status: LibrarySyncStatus.succeeded,
            stage: LibrarySyncStage.completed,
          );
        },
      );
      final container = ProviderContainer(
        overrides: [
          _manualSyncInterval,
          serverConfigStateProvider.overrideWithValue(const AsyncData(null)),
          serverReachabilityControllerProvider.overrideWith(
            () => _StaticReachabilityController(
              const ServerReachabilityState(
                status: ServerReachabilityStatus.checking,
              ),
            ),
          ),
          librarySyncEngineProvider.overrideWithValue(engine),
        ],
      );
      addTearDown(container.dispose);

      container.read(librarySyncControllerProvider);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(engine.staleCalls, 0);
      expect(engine.nowCalls, 0);
    });

    test('sync does not auto-retry on resume after failure', () async {
      final binding = TestWidgetsFlutterBinding.ensureInitialized();
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);

      var attempt = 0;
      final engine = _FakeLibrarySyncEngine(
        ({
          onProgress,
        }) async {
          return const LibrarySyncState(
            status: LibrarySyncStatus.skipped,
            stage: LibrarySyncStage.completed,
          );
        },
        ({
          forceFull = false,
          onProgress,
        }) async {
          attempt++;
          if (attempt == 1) {
            return LibrarySyncState(
              status: LibrarySyncStatus.failed,
              stage: LibrarySyncStage.fetchingAlbums,
              errorMessage: 'Transient background failure',
              completedAt: DateTime.now(),
            );
          }
          return LibrarySyncState(
            status: LibrarySyncStatus.succeeded,
            stage: LibrarySyncStage.completed,
            completedAt: DateTime.now(),
          );
        },
      );

      final container = ProviderContainer(
        overrides: [
          _manualSyncInterval,
          serverConfigStateProvider.overrideWithValue(const AsyncData(null)),
          serverReachabilityControllerProvider.overrideWith(
            () => _StaticReachabilityController(
              const ServerReachabilityState(
                status: ServerReachabilityStatus.checking,
              ),
            ),
          ),
          librarySyncEngineProvider.overrideWithValue(engine),
        ],
      );
      addTearDown(() async {
        container.dispose();
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      });

      final future = container
          .read(librarySyncControllerProvider.notifier)
          .syncNow();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(engine.nowCalls, 1);

      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await future;

      final finalState = container.read(librarySyncControllerProvider);
      expect(engine.nowCalls, 1);
      expect(finalState.status, LibrarySyncStatus.failed);
    });

    test('periodic sync pauses while backgrounded', () async {
      final binding = TestWidgetsFlutterBinding.ensureInitialized();
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);

      final engine = _FakeLibrarySyncEngine(
        ({
          onProgress,
        }) async {
          return LibrarySyncState(
            status: LibrarySyncStatus.succeeded,
            stage: LibrarySyncStage.completed,
            completedAt: DateTime.now(),
          );
        },
        ({
          forceFull = false,
          onProgress,
        }) async {
          return const LibrarySyncState(
            status: LibrarySyncStatus.succeeded,
            stage: LibrarySyncStage.completed,
          );
        },
      );

      final container = ProviderContainer(
        overrides: [
          _shortSyncInterval,
          syncIntervalMinutesProvider.overrideWithValue(1),
          serverConfigStateProvider.overrideWithValue(const AsyncData(null)),
          serverReachabilityControllerProvider.overrideWith(
            () => _StaticReachabilityController(
              const ServerReachabilityState(
                status: ServerReachabilityStatus.checking,
              ),
            ),
          ),
          librarySyncEngineProvider.overrideWithValue(engine),
        ],
      );
      addTearDown(() async {
        container.dispose();
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      });

      container.read(librarySyncControllerProvider);
      await Future<void>.delayed(const Duration(milliseconds: 35));

      expect(engine.staleCalls, 0);
    });

    test(
      'syncIfStale keeps a failed sync visible after a no-op pass',
      () async {
        var syncNowAttempts = 0;
        final engine = _FakeLibrarySyncEngine(
          ({
            onProgress,
          }) async {
            return const LibrarySyncState(
              status: LibrarySyncStatus.skipped,
              stage: LibrarySyncStage.completed,
            );
          },
          ({
            forceFull = false,
            onProgress,
          }) async {
            syncNowAttempts++;
            if (syncNowAttempts == 1) {
              return LibrarySyncState(
                status: LibrarySyncStatus.failed,
                stage: LibrarySyncStage.completed,
                completedAt: DateTime.now(),
                errorMessage: 'Sync failed.',
              );
            }
            return LibrarySyncState(
              status: LibrarySyncStatus.succeeded,
              stage: LibrarySyncStage.completed,
              completedAt: DateTime.now(),
            );
          },
        );
        final database = createTestDatabase();
        addTearDown(database.close);

        final container = ProviderContainer(
          overrides: [
            _manualSyncInterval,
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
            serverReachabilityControllerProvider.overrideWith(
              () => _StaticReachabilityController(
                const ServerReachabilityState(
                  status: ServerReachabilityStatus.online,
                ),
              ),
            ),
            requiredLibrarySyncModelVersionProvider.overrideWithValue(null),
            navisDatabaseProvider.overrideWithValue(database),
            librarySyncEngineProvider.overrideWithValue(engine),
          ],
        );
        addTearDown(container.dispose);

        final notifier = container.read(librarySyncControllerProvider.notifier);
        await notifier.syncNow();
        expect(
          container.read(librarySyncControllerProvider).status,
          LibrarySyncStatus.failed,
        );

        await notifier.syncIfStale();

        expect(syncNowAttempts, 1);
        expect(engine.staleCalls, 1);
        expect(
          container.read(librarySyncControllerProvider).status,
          LibrarySyncStatus.failed,
        );
      },
    );

    test(
      'manual-only mode leaves pending hydration for the next explicit action',
      () async {
        var boundedPass = 0;
        final engine = _FakeLibrarySyncEngine(
          ({
            onProgress,
          }) async {
            return const LibrarySyncState(
              status: LibrarySyncStatus.skipped,
              stage: LibrarySyncStage.completed,
            );
          },
          ({
            forceFull = false,
            onProgress,
          }) async {
            boundedPass++;
            return LibrarySyncState(
              status: LibrarySyncStatus.succeeded,
              stage: LibrarySyncStage.completed,
              completedAt: DateTime.now(),
              pendingHydrationCount: boundedPass == 1 ? 2 : 0,
              freshness: boundedPass == 1
                  ? LibrarySyncFreshness.verificationPending
                  : LibrarySyncFreshness.current,
            );
          },
        );
        final database = createTestDatabase();
        addTearDown(database.close);
        final container = ProviderContainer(
          overrides: [
            _manualSyncInterval,
            requiredLibrarySyncModelVersionProvider.overrideWithValue(null),
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
            serverReachabilityControllerProvider.overrideWith(
              () => _StaticReachabilityController(
                const ServerReachabilityState(
                  status: ServerReachabilityStatus.online,
                ),
              ),
            ),
            networkTypeProvider.overrideWithValue(NetworkType.wifi),
            navisDatabaseProvider.overrideWithValue(database),
            librarySyncEngineProvider.overrideWithValue(engine),
          ],
        );
        addTearDown(container.dispose);

        final notifier = container.read(
          librarySyncControllerProvider.notifier,
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await notifier.syncNow();
        await Future<void>.delayed(const Duration(milliseconds: 30));

        expect(engine.nowCalls, 1);
        expect(engine.continuationCalls, 0);
        expect(
          container.read(librarySyncControllerProvider).freshness,
          LibrarySyncFreshness.verificationPending,
        );
      },
    );
  });
}
