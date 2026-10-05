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
import 'package:flutter_riverpod/misc.dart' show Override;

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
  new(this._state);

  final ServerReachabilityState _state;

  @override
  ServerReachabilityState build() => _state;
}

class _MutableReachabilityController extends ServerReachabilityController {
  new(this._initial);

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

class _ServerConfigSource extends Notifier<AsyncValue<ServerConfigModel?>> {
  @override
  AsyncValue<ServerConfigModel?> build() => const AsyncData(null);

  // A setter would hide that this simulates a sign-in or sign-out.
  // ignore: use_setters_to_change_properties
  void set(AsyncValue<ServerConfigModel?> value) {
    state = value;
  }
}

final _serverConfigSource =
    NotifierProvider<_ServerConfigSource, AsyncValue<ServerConfigModel?>>(
      _ServerConfigSource.new,
    );

class _FakeLibrarySyncEngine extends LibrarySyncEngine {
  new(this._handlerIfStale, this._handlerNow, {this.requestHandler});

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
        ({onProgress}) async {
          final state = LibrarySyncState(
            status: LibrarySyncStatus.succeeded,
            stage: LibrarySyncStage.completed,
            completedAt: DateTime.now(),
            lastSyncedAt: DateTime.now(),
          );
          onProgress?.call(state);
          return state;
        },
        ({forceFull = false, onProgress}) async {
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

    test('automatic checks honor a persisted deadline and manual checks leave it unchanged', () async {
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

      final controller = container.read(librarySyncControllerProvider.notifier);
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
    });

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
      'cancelAndWait drains an automatic check through persistence',
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
        final automaticResult = Completer<LibrarySyncState>();
        final enteredEngine = Completer<void>();
        final engine = _FakeLibrarySyncEngine(
          ({onProgress}) {
            enteredEngine.complete();
            return automaticResult.future;
          },
          ({forceFull = false, onProgress}) async =>
              const LibrarySyncState.idle(),
        );
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
        final notifier = container.read(librarySyncControllerProvider.notifier);
        final automatic = notifier.syncIfStale();
        await enteredEngine.future;
        var drained = false;
        final cancellation = notifier.cancelAndWait().then(
          (_) => drained = true,
        );
        await Future<void>.delayed(Duration.zero);
        final completedBeforeEngine = drained;

        automaticResult.complete(
          LibrarySyncState(
            status: LibrarySyncStatus.cancelled,
            stage: LibrarySyncStage.completed,
            completedAt: DateTime.now(),
          ),
        );
        await cancellation;
        expect(completedBeforeEngine, isFalse);
        expect(drained, isTrue);
        await automatic;
        final persisted = await database.librarySyncDao.getOrCreateState(
          config.id!,
        );
        expect(persisted.nextAutomaticCheckAt!.isAfter(DateTime.now()), isTrue);
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

    test('budget-limited partial delta keeps the persisted automatic deadline in status', () async {
      final database = createTestDatabase();
      addTearDown(database.close);
      final config = await _saveAuthenticatedServer(database);
      final deadline = DateTime.now().add(const Duration(hours: 1));
      await database.librarySyncDao.setNextAutomaticCheckAt(
        serverId: config.id!,
        nextAutomaticCheckAt: deadline,
      );
      // An interrupted Check for updates resumes before the deadline.
      await database.librarySyncDao.enqueueWork(
        serverId: config.id!,
        kind: LibrarySyncPlanKind.deltaReconcile.name,
        priority: 60,
      );
      final engine = _FakeLibrarySyncEngine(
        ({onProgress}) async {
          // Engine frames and results never carry the automatic deadline.
          onProgress?.call(
            const LibrarySyncState(
              status: LibrarySyncStatus.running,
              stage: LibrarySyncStage.fetchingSongs,
              planKind: LibrarySyncPlanKind.deltaReconcile,
            ),
          );
          return LibrarySyncState(
            status: LibrarySyncStatus.partial,
            stage: LibrarySyncStage.completed,
            planKind: LibrarySyncPlanKind.deltaReconcile,
            planReason: 'resumeDeltaReconcile',
            failureCategory: 'entityBudget',
            completedAt: DateTime.now(),
          );
        },
        ({forceFull = false, onProgress}) async =>
            const LibrarySyncState.idle(),
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
      final status = container.read(librarySyncControllerProvider);
      final persisted = await database.librarySyncDao.getOrCreateState(
        config.id!,
      );
      expect(status.status, LibrarySyncStatus.partial);
      expect(status.failureCategory, 'entityBudget');
      expect(
        persisted.nextAutomaticCheckAt!.difference(deadline).abs(),
        lessThan(const Duration(seconds: 1)),
      );
      expect(status.nextAutomaticCheckAt, persisted.nextAutomaticCheckAt);
      expect(status.nextRetryAt, persisted.nextEligibleAt);
    });

    test(
      'repair keeps the automatic deadline and persisted retry in status',
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
          ({onProgress}) async => const LibrarySyncState.idle(),
          ({forceFull = false, onProgress}) async {
            for (final stage in <LibrarySyncStage>[
              LibrarySyncStage.collectingCandidate,
              LibrarySyncStage.applyingCandidate,
            ]) {
              onProgress?.call(
                LibrarySyncState(
                  status: LibrarySyncStatus.running,
                  stage: stage,
                  planKind: LibrarySyncPlanKind.fullRepair,
                ),
              );
            }
            return LibrarySyncState(
              status: LibrarySyncStatus.succeeded,
              stage: LibrarySyncStage.completed,
              planKind: LibrarySyncPlanKind.fullRepair,
              completedAt: DateTime.now(),
            );
          },
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
        final controller = container.read(
          librarySyncControllerProvider.notifier,
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(engine.staleCalls, 0);
        expect(
          container.read(librarySyncControllerProvider).nextAutomaticCheckAt,
          isNotNull,
        );

        final published = <LibrarySyncState>[];
        container.listen<LibrarySyncState>(
          librarySyncControllerProvider,
          (_, next) => published.add(next),
        );
        await controller.repairLibrary();

        expect(engine.forceFullCalls, <bool>[true]);
        expect(
          published.where((value) => value.status == LibrarySyncStatus.running),
          isNotEmpty,
        );
        for (final value in published) {
          expect(value.nextAutomaticCheckAt, isNotNull, reason: '$value');
        }
        final status = container.read(librarySyncControllerProvider);
        final persisted = await database.librarySyncDao.getOrCreateState(
          config.id!,
        );
        expect(status.status, LibrarySyncStatus.succeeded);
        expect(
          persisted.nextAutomaticCheckAt!.difference(deadline).abs(),
          lessThan(const Duration(seconds: 1)),
        );
        expect(status.nextAutomaticCheckAt, persisted.nextAutomaticCheckAt);
        expect(status.nextRetryAt, persisted.nextEligibleAt);
        expect(status.nextRetryAt, isNotNull);
      },
    );

    test('automatic timer waits for the persisted deadline before one catalog pass', () async {
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
    });

    test('cancelAndWait drains an active automatic check and its durable completion', () async {
      final database = createTestDatabase();
      addTearDown(database.close);
      final config = await _saveAuthenticatedServer(database);
      await database.librarySyncDao.setNextAutomaticCheckAt(
        serverId: config.id!,
        nextAutomaticCheckAt: DateTime.now().subtract(
          const Duration(minutes: 1),
        ),
      );
      final entered = Completer<void>();
      final completion = Completer<LibrarySyncState>();
      final engine = _FakeLibrarySyncEngine(
        ({onProgress}) {
          entered.complete();
          return completion.future;
        },
        ({forceFull = false, onProgress}) async =>
            const LibrarySyncState.idle(),
      );
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
      final controller = container.read(librarySyncControllerProvider.notifier);
      final automatic = controller.syncIfStale();
      await entered.future;
      var drained = false;
      final cancellation = controller.cancelAndWait().then(
        (_) => drained = true,
      );
      await Future<void>.delayed(Duration.zero);
      expect(drained, isFalse);
      completion.complete(
        LibrarySyncState(
          status: LibrarySyncStatus.cancelled,
          stage: LibrarySyncStage.completed,
          completedAt: DateTime.now(),
        ),
      );
      await cancellation;
      await automatic;
      final persisted = await database.librarySyncDao.getOrCreateState(
        config.id!,
      );
      expect(persisted.nextAutomaticCheckAt!.isAfter(DateTime.now()), isTrue);
      expect(drained, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(engine.staleCalls, 1);
    });

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
        ({onProgress}) async {
          return const LibrarySyncState(
            status: LibrarySyncStatus.skipped,
            stage: LibrarySyncStage.completed,
          );
        },
        ({forceFull = false, onProgress}) async {
          onProgress?.call(
            LibrarySyncState(
              status: LibrarySyncStatus.running,
              stage: LibrarySyncStage.fetchingArtists,
              startedAt: DateTime.now(),
            ),
          );
          return await completer.future;
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

    test(
      'cancellation prevents a queued stronger repair from starting',
      () async {
        final active = Completer<LibrarySyncState>();
        final engine = _FakeLibrarySyncEngine(
          ({onProgress}) async => const LibrarySyncState.idle(),
          ({forceFull = false, onProgress}) => active.future,
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
        final controller = container.read(
          librarySyncControllerProvider.notifier,
        );
        final check = controller.syncNow();
        await Future<void>.delayed(Duration.zero);
        final repair = controller.repairLibrary();
        controller.cancelSync();
        active.complete(
          const LibrarySyncState(
            status: LibrarySyncStatus.cancelled,
            stage: LibrarySyncStage.completed,
          ),
        );
        await check;
        expect((await repair).status, LibrarySyncStatus.cancelled);
        expect(engine.forceFullCalls, [false]);
        // A subsequent explicit command is new intent and remains allowed.
        await controller.repairLibrary();
        expect(engine.forceFullCalls, [false, true]);
      },
    );

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
          return await completer.future;
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

        // The first open in a session hydrates every artist, including one
        // whose stored albums already match its count: Octo-Fiesta counts
        // local albums only, and getArtist adds the remote ones.
        expect(
          requestedArtistIds,
          unorderedEquals(<String>[
            'missing',
            'incomplete',
            'countless',
            'complete',
          ]),
        );

        controller.registerArtistInteraction('incomplete');
        controller.registerArtistInteraction('complete');
        await Future<void>.delayed(const Duration(milliseconds: 20));

        // Albums still missing keeps the existing rule; a complete artist
        // already hydrated this session does not ask again.
        expect(
          requestedArtistIds.where((id) => id == 'incomplete'),
          hasLength(2),
        );
        expect(
          requestedArtistIds.where((id) => id == 'complete'),
          hasLength(1),
        );

        await controller.refreshArtist('complete');

        expect(
          requestedArtistIds.where((id) => id == 'complete'),
          hasLength(2),
        );
      },
    );

    group('artist page hydration once per session', () {
      late NavisDatabase database;
      late List<String> requestedArtistIds;
      late Future<LibrarySyncState> Function() nextResult;

      setUp(() async {
        database = createTestDatabase();
        await database.libraryDao.upsertArtists(<ArtistsTableCompanion>[
          ArtistsTableCompanion.insert(
            id: 'oor',
            name: 'ONE OK ROCK',
            albumCount: const Value(1),
          ),
        ]);
        await database.libraryDao.upsertAlbums(<AlbumsTableCompanion>[
          AlbumsTableCompanion.insert(
            id: 'ambitions',
            name: 'Ambitions',
            artistId: const Value('oor'),
          ),
        ]);
        requestedArtistIds = <String>[];
        nextResult = () async => LibrarySyncState(
          status: LibrarySyncStatus.succeeded,
          stage: LibrarySyncStage.completed,
          completedAt: DateTime.now(),
        );
      });

      tearDown(() async {
        await database.close();
      });

      ProviderContainer buildContainer({
        ServerReachabilityStatus reachability = ServerReachabilityStatus.online,
        Override? serverConfig,
      }) {
        final engine = _FakeLibrarySyncEngine(
          ({onProgress}) async => const LibrarySyncState(
            status: LibrarySyncStatus.skipped,
            stage: LibrarySyncStage.completed,
          ),
          ({forceFull = false, onProgress}) async => const LibrarySyncState(
            status: LibrarySyncStatus.skipped,
            stage: LibrarySyncStage.completed,
          ),
          requestHandler: (request, {onProgress}) {
            requestedArtistIds.add(request.target.entityId!);
            return nextResult();
          },
        );
        final container = ProviderContainer(
          overrides: [
            _manualSyncInterval,
            navisDatabaseProvider.overrideWithValue(database),
            serverReachabilityControllerProvider.overrideWith(
              () => _MutableReachabilityController(
                ServerReachabilityState(status: reachability),
              ),
            ),
            librarySyncEngineProvider.overrideWithValue(engine),
            serverConfig ??
                serverConfigStateProvider.overrideWithValue(
                  const AsyncData(null),
                ),
          ],
        );
        addTearDown(container.dispose);
        return container;
      }

      Future<void> settle() =>
          Future<void>.delayed(const Duration(milliseconds: 20));

      test('a complete artist hydrates on the first open only', () async {
        final container = buildContainer();
        final controller = container.read(
          librarySyncControllerProvider.notifier,
        );

        controller.registerArtistInteraction('oor');
        await settle();
        expect(requestedArtistIds, <String>['oor']);

        controller.registerArtistInteraction('oor');
        await settle();
        expect(requestedArtistIds, <String>['oor']);
      });

      test('concurrent opens hydrate once', () async {
        final release = Completer<LibrarySyncState>();
        nextResult = () => release.future;
        final container = buildContainer();
        final controller = container.read(
          librarySyncControllerProvider.notifier,
        );

        controller.registerArtistInteraction('oor');
        controller.registerArtistInteraction(' oor ');
        await settle();
        controller.registerArtistInteraction('oor');
        await settle();

        expect(requestedArtistIds, <String>['oor']);
        release.complete(
          LibrarySyncState(
            status: LibrarySyncStatus.succeeded,
            stage: LibrarySyncStage.completed,
            completedAt: DateTime.now(),
          ),
        );
        await settle();
        controller.registerArtistInteraction('oor');
        await settle();
        expect(requestedArtistIds, <String>['oor']);
      });

      test(
        'the artist page gets the shared result, then none is needed',
        () async {
          final release = Completer<LibrarySyncState>();
          nextResult = () => release.future;
          final container = buildContainer();
          final controller = container.read(
            librarySyncControllerProvider.notifier,
          );

          final first = controller.hydrateOpenedArtist('oor');
          final second = controller.hydrateOpenedArtist(' oor ');
          final succeeded = LibrarySyncState(
            status: LibrarySyncStatus.succeeded,
            stage: LibrarySyncStage.completed,
            completedAt: DateTime.now(),
          );
          release.complete(succeeded);
          expect((await first)?.status, LibrarySyncStatus.succeeded);
          expect((await second)?.status, LibrarySyncStatus.succeeded);
          expect(requestedArtistIds, <String>['oor']);

          // Hydrated this session: the next open needs no request.
          expect(await controller.hydrateOpenedArtist('oor'), isNull);
          expect(requestedArtistIds, <String>['oor']);
        },
      );

      test('offline does not hydrate and does not use up the open', () async {
        final container = buildContainer(
          reachability: ServerReachabilityStatus.offline,
        );
        final controller = container.read(
          librarySyncControllerProvider.notifier,
        );

        controller.registerArtistInteraction('oor');
        await settle();
        expect(requestedArtistIds, isEmpty);

        (container.read(serverReachabilityControllerProvider.notifier)
                as _MutableReachabilityController)
            .setStatus(ServerReachabilityStatus.online);
        controller.registerArtistInteraction('oor');
        await settle();
        expect(requestedArtistIds, <String>['oor']);
      });

      test(
        'a hydration that did not succeed is retried on the next open',
        () async {
          nextResult = () async => const LibrarySyncState(
            status: LibrarySyncStatus.deferred,
            stage: LibrarySyncStage.completed,
          );
          final container = buildContainer();
          final controller = container.read(
            librarySyncControllerProvider.notifier,
          );

          controller.registerArtistInteraction('oor');
          await settle();
          nextResult = () async => LibrarySyncState(
            status: LibrarySyncStatus.succeeded,
            stage: LibrarySyncStage.completed,
            completedAt: DateTime.now(),
          );
          controller.registerArtistInteraction('oor');
          await settle();
          controller.registerArtistInteraction('oor');
          await settle();

          expect(requestedArtistIds, <String>['oor', 'oor']);
        },
      );

      test('opening without an engine does not use up the open', () async {
        final engine = _FakeLibrarySyncEngine(
          ({onProgress}) async => const LibrarySyncState(
            status: LibrarySyncStatus.skipped,
            stage: LibrarySyncStage.completed,
          ),
          ({forceFull = false, onProgress}) async => LibrarySyncState(
            status: LibrarySyncStatus.succeeded,
            stage: LibrarySyncStage.completed,
            completedAt: DateTime.now(),
          ),
          requestHandler: (request, {onProgress}) {
            requestedArtistIds.add(request.target.entityId!);
            return nextResult();
          },
        );
        final engineState =
            NotifierProvider<_MutableLibrarySyncEngine, LibrarySyncEngine?>(
              _MutableLibrarySyncEngine.new,
            );
        final container = ProviderContainer(
          overrides: [
            _manualSyncInterval,
            navisDatabaseProvider.overrideWithValue(database),
            serverConfigStateProvider.overrideWithValue(const AsyncData(null)),
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
        final controller = container.read(
          librarySyncControllerProvider.notifier,
        );
        // An earlier catalog check leaves the controller reading succeeded.
        container.read(engineState.notifier).replace(engine);
        await controller.syncNow();
        expect(
          container.read(librarySyncControllerProvider).status,
          LibrarySyncStatus.succeeded,
        );

        container.read(engineState.notifier).replace(null);
        controller.registerArtistInteraction('oor');
        await settle();
        container.read(engineState.notifier).replace(engine);
        controller.registerArtistInteraction('oor');
        await settle();

        expect(requestedArtistIds, <String>['oor']);
      });

      // An open whose library read straddles a sign-out and sign-in: the
      // read is held by a transaction until [release] completes.
      Future<
        ({
          ProviderContainer container,
          LibrarySyncController controller,
          Completer<void> release,
          Future<void> blocking,
        })
      >
      openAcrossSessionChange() async {
        final server = await _saveAuthenticatedServer(database);
        await database.libraryDao.upsertArtists([
          ArtistsTableCompanion.insert(
            id: 'oor',
            name: 'ONE OK ROCK',
            albumCount: const Value(2),
          ),
        ]);
        final container = buildContainer(
          serverConfig: serverConfigStateProvider.overrideWith(
            (ref) => ref.watch(_serverConfigSource),
          ),
        );
        container.read(_serverConfigSource.notifier).set(AsyncData(server));
        container.listen(librarySyncControllerProvider, (_, _) {});
        final controller = container.read(
          librarySyncControllerProvider.notifier,
        );
        await settle();
        final entered = Completer<void>();
        final release = Completer<void>();
        final blocking = database.transaction(() async {
          await database.libraryDao.getArtistById('oor');
          entered.complete();
          await release.future;
        });
        await entered.future;
        // Albums are missing (none of 2 stored), so this open would enqueue.
        controller.registerArtistInteraction('oor');
        await settle();
        container.read(_serverConfigSource.notifier).set(const AsyncData(null));
        await settle();
        container
            .read(_serverConfigSource.notifier)
            .set(AsyncData(server.copyWith(username: 'other-account')));
        await settle();
        return (
          container: container,
          controller: controller,
          release: release,
          blocking: blocking,
        );
      }

      test(
        'an open from a previous session does not enqueue into the next',
        () async {
          final run = await openAcrossSessionChange();
          run.release.complete();
          await run.blocking;
          await settle();
          expect(requestedArtistIds, isEmpty);
        },
      );

      test(
        "an open from a previous session does not suppress the next one's",
        () async {
          final run = await openAcrossSessionChange();
          run.controller.registerArtistInteraction('oor');
          run.release.complete();
          await run.blocking;
          await settle();
          expect(requestedArtistIds, <String>['oor']);
          // That hydration counted as this session's open: with the albums
          // now complete, opening again asks nothing.
          await database.libraryDao.upsertAlbums([
            for (final id in ['oor-1', 'oor-2'])
              AlbumsTableCompanion.insert(
                id: id,
                name: id,
                artistId: const Value('oor'),
              ),
          ]);
          run.controller.registerArtistInteraction('oor');
          await settle();
          expect(requestedArtistIds, <String>['oor']);
        },
      );

      test('signing out starts a new session for artist hydration', () async {
        final server = await _saveAuthenticatedServer(database);
        final container = buildContainer(
          serverConfig: serverConfigStateProvider.overrideWith(
            (ref) => ref.watch(_serverConfigSource),
          ),
        );
        container.read(_serverConfigSource.notifier).set(AsyncData(server));
        // Riverpod pauses an unlistened provider's own listeners.
        container.listen(librarySyncControllerProvider, (_, _) {});
        final controller = container.read(
          librarySyncControllerProvider.notifier,
        );

        controller.registerArtistInteraction('oor');
        await settle();
        container.read(_serverConfigSource.notifier).set(const AsyncData(null));
        await settle();
        container.read(_serverConfigSource.notifier).set(AsyncData(server));
        await settle();
        controller.registerArtistInteraction('oor');
        await settle();

        expect(requestedArtistIds, <String>['oor', 'oor']);
      });
    });

    test(
      'forceFullSync becomes visibly preparing before engine planning',
      () async {
        final completer = Completer<LibrarySyncState>();
        final engine = _FakeLibrarySyncEngine(
          ({onProgress}) async => const LibrarySyncState(
            status: LibrarySyncStatus.skipped,
            stage: LibrarySyncStage.completed,
          ),
          ({forceFull = false, onProgress}) async => await (forceFull
              ? completer.future
              : const LibrarySyncState(
                  status: LibrarySyncStatus.succeeded,
                  stage: LibrarySyncStage.completed,
                  runRequestId: 12,
                  runAttemptId: 34,
                  apiRequests: 9,
                  endpointRequests: {'getAlbum': 9},
                  lastRunBytes: 1024,
                )),
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
        expect(container.read(librarySyncControllerProvider).runAttemptId, 34);
        final future = container
            .read(librarySyncControllerProvider.notifier)
            .forceFullSync();
        await Future<void>.delayed(Duration.zero);

        final preparing = container.read(librarySyncControllerProvider);
        expect(preparing.status, LibrarySyncStatus.running);
        expect(preparing.stage, LibrarySyncStage.preparing);
        expect(preparing.mode, LibrarySyncMode.forceFull);
        expect(preparing.runRequestId, isNull);
        expect(preparing.runAttemptId, isNull);
        expect(preparing.apiRequests, 0);
        expect(preparing.endpointRequests, isEmpty);
        expect(preparing.lastRunBytes, 0);
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
        ({onProgress}) async {
          return const LibrarySyncState(
            status: LibrarySyncStatus.skipped,
            stage: LibrarySyncStage.completed,
          );
        },
        ({forceFull = false, onProgress}) async {
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
          ({onProgress}) async {
            return const LibrarySyncState(
              status: LibrarySyncStatus.succeeded,
              stage: LibrarySyncStage.completed,
            );
          },
          ({forceFull = false, onProgress}) async {
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
          ({onProgress}) async {
            return const LibrarySyncState(
              status: LibrarySyncStatus.skipped,
              stage: LibrarySyncStage.completed,
            );
          },
          ({forceFull = false, onProgress}) async {
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
            networkTypeProvider.overrideWith((ref) => networkType),
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

    test(
      'upgrading from the previous sync model forces a full catalog repair',
      () async {
        final database = createTestDatabase();
        addTearDown(database.close);
        await database.appSettingsDao.setLastFullSyncAppBuild('56');
        final engine = _FakeLibrarySyncEngine(
          ({onProgress}) async => const LibrarySyncState(
            status: LibrarySyncStatus.skipped,
            stage: LibrarySyncStage.completed,
          ),
          ({forceFull = false, onProgress}) async => LibrarySyncState(
            status: LibrarySyncStatus.succeeded,
            stage: LibrarySyncStage.completed,
            mode: LibrarySyncMode.forceFull,
            completedAt: DateTime.now(),
          ),
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

    test(
      'the post-upgrade reconciliation completes only after promotion',
      () async {
        final database = createTestDatabase();
        addTearDown(database.close);
        // The previous release's model version: this startup must schedule
        // exactly one recovery reconciliation.
        await database.appSettingsDao.setLastFullSyncAppBuild('57');
        var forceFullCalls = 0;
        var forcedStatus = LibrarySyncStatus.failed;
        LibrarySyncEngine buildEngine() => _FakeLibrarySyncEngine(
          ({onProgress}) async => const LibrarySyncState(
            status: LibrarySyncStatus.skipped,
            stage: LibrarySyncStage.completed,
          ),
          ({forceFull = false, onProgress}) async {
            forceFullCalls++;
            return LibrarySyncState(
              status: forcedStatus,
              stage: LibrarySyncStage.completed,
              mode: LibrarySyncMode.forceFull,
              completedAt: DateTime.now(),
            );
          },
        );
        ProviderContainer buildContainer(LibrarySyncEngine engine) {
          return ProviderContainer(
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
        }

        // First launch: the forced repair fails (no promotion). The model
        // version must stay unstamped so a later run reconciles again.
        final failedContainer = buildContainer(buildEngine());
        addTearDown(failedContainer.dispose);
        failedContainer.read(librarySyncControllerProvider);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(forceFullCalls, 1);
        expect(await database.appSettingsDao.getLastFullSyncAppBuild(), '57');
        failedContainer.dispose();

        // Second launch (app restart): the reconciliation is resumable and
        // the version is stamped only once the repair promoted successfully.
        final recoveredContainer = buildContainer(buildEngine());
        addTearDown(recoveredContainer.dispose);
        forcedStatus = LibrarySyncStatus.succeeded;
        recoveredContainer.read(librarySyncControllerProvider);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(forceFullCalls, 2);
        expect(
          await database.appSettingsDao.getLastFullSyncAppBuild(),
          currentLibrarySyncModelVersion,
        );
      },
      skip: !sqliteAvailable,
    );

    test('unauthenticated state does not trigger startup sync', () async {
      final engine = _FakeLibrarySyncEngine(
        ({onProgress}) async {
          return const LibrarySyncState(
            status: LibrarySyncStatus.succeeded,
            stage: LibrarySyncStage.completed,
          );
        },
        ({forceFull = false, onProgress}) async {
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
        ({onProgress}) async {
          return const LibrarySyncState(
            status: LibrarySyncStatus.skipped,
            stage: LibrarySyncStage.completed,
          );
        },
        ({forceFull = false, onProgress}) async {
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
        ({onProgress}) async {
          return LibrarySyncState(
            status: LibrarySyncStatus.succeeded,
            stage: LibrarySyncStage.completed,
            completedAt: DateTime.now(),
          );
        },
        ({forceFull = false, onProgress}) async {
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
          ({onProgress}) async {
            return const LibrarySyncState(
              status: LibrarySyncStatus.skipped,
              stage: LibrarySyncStage.completed,
            );
          },
          ({forceFull = false, onProgress}) async {
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
          ({onProgress}) async {
            return const LibrarySyncState(
              status: LibrarySyncStatus.skipped,
              stage: LibrarySyncStage.completed,
            );
          },
          ({forceFull = false, onProgress}) async {
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

        final notifier = container.read(librarySyncControllerProvider.notifier);
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
