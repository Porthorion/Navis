import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/data/server_config_repository.dart';
import 'package:navis/src/features/library/data/adaptive_library_sync_coordinator.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/domain/server_reachability.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/auth/presentation/session_route_provider.dart';
import 'package:navis/src/features/auth/presentation/server_reachability_provider.dart';
import 'package:navis/src/features/library/data/library_sync_engine.dart';
import 'package:navis/src/features/library/data/android_background_sync.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart'
    show debugDesktopRuntimeOverride;
import 'package:navis/src/features/playlists/presentation/playlist_providers.dart';
import 'package:navis/src/utils/connectivity.dart';
import 'package:navis/src/utils/notifications/library_sync_notifier.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

import '../../../../helpers/library_sync_fakes.dart';
import '../../../../helpers/test_database.dart';
import '../../../../helpers/reachability_fakes.dart';
import '../../../../helpers/stub_library_sync_engine.dart';

// Deterministic manual-only and short automatic schedules.
final _manualSyncInterval = syncIntervalMinutesProvider.overrideWithValue(0);
final _shortSyncInterval = syncIntervalDurationProvider.overrideWithValue(
  const Duration(milliseconds: 10),
);

Future<ServerConfigModel> _saveAuthenticatedServer(
  NavisDatabase database, {
  DateTime? lastSynced,
  bool setupPending = false,
}) async {
  await database.serverDao.saveServer(
    ServerConfigTableCompanion.insert(
      url: 'https://example.com',
      username: 'alice',
      apiVersion: '1.16.1',
      isAuthenticated: const Value(true),
      lastSynced: Value(
        lastSynced ??
            (setupPending
                ? null
                : DateTime.now().subtract(const Duration(days: 1))),
      ),
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

const _exampleServer = ServerConfigModel(
  url: 'https://example.com',
  username: 'alice',
  password: 'secret',
  apiVersion: '1.16.1',
);

/// A completed, successful sync with no other detail.
// Real results carry completedAt; without it a re-armed timer can spin.
final _succeeded = LibrarySyncState(
  status: LibrarySyncStatus.succeeded,
  stage: LibrarySyncStage.completed,
  completedAt: DateTime.utc(2026, 8, 4),
);

/// Polls [condition] every 20 ms for up to [timeout] (loaded runners are slow).
Future<void> _until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

final _hourlyInterval = <Override>[
  syncIntervalMinutesProvider.overrideWithValue(60),
  syncIntervalDurationProvider.overrideWithValue(const Duration(hours: 1)),
];

/// A container wired to [engine] with a static reachability state. Without
/// [database] none is overridden, without [server] nobody is signed in, and
/// [interval] defaults to manual-only syncing.
ProviderContainer _container(
  LibrarySyncEngine engine, {
  NavisDatabase? database,
  ServerConfigModel? server,
  ServerReachabilityStatus reachability = ServerReachabilityStatus.online,
  List<Override> interval = const <Override>[],
  List<Override> serverConfig = const <Override>[],
  List<Override> extra = const <Override>[],
}) {
  return ProviderContainer(
    overrides: [
      if (interval.isEmpty) _manualSyncInterval else ...interval,
      if (database != null) navisDatabaseProvider.overrideWithValue(database),
      if (serverConfig.isEmpty)
        serverConfigStateProvider.overrideWithValue(AsyncData(server))
      else
        ...serverConfig,
      serverReachabilityControllerProvider.overrideWith(
        () => StaticReachabilityController(
          ServerReachabilityState(status: reachability),
        ),
      ),
      librarySyncEngineProvider.overrideWithValue(engine),
      ...extra,
    ],
  );
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

class _RecordingSyncNotifier extends SystemLibrarySyncNotifier {
  new();

  int shown = 0;
  int failedShown = 0;
  int completeShown = 0;

  @override
  Future<void> showProgress(LibrarySyncState state) async => shown++;

  @override
  Future<void> showFailed(LibrarySyncState state) async => failedShown++;

  @override
  Future<void> showComplete(LibrarySyncState state) async => completeShown++;

  @override
  Future<void> dismissProgress() async {}
}

/// An automatic check parked inside the engine. The run reports `running`
/// progress once when it starts and once more after [release].
class _ParkedCheck {
  new(this.container, this.notifier, this.automatic);

  final ProviderContainer container;
  final _RecordingSyncNotifier notifier;
  final Future<LibrarySyncState> automatic;
  late final Completer<LibrarySyncState> release;

  LibrarySyncController get controller =>
      container.read(librarySyncControllerProvider.notifier);
  LibrarySyncStatus get status =>
      container.read(librarySyncControllerProvider).status;

  /// Lets the new session's background tasks finish before the database
  /// closes.
  Future<void> drain() => controller.cancelAndWait();

  /// Sign out, then sign in as [next].
  Future<void> changeSession(ServerConfigModel next) async {
    final source = container.read(_serverConfigSource.notifier);
    source.set(const AsyncData(null));
    await container.pump();
    source.set(AsyncData(next));
    await container.pump();
  }
}

Future<_ParkedCheck> _parkedCheck(
  NavisDatabase database,
  ServerConfigModel config,
) async {
  await database.librarySyncDao.setNextAutomaticCheckAt(
    serverId: config.id!,
    nextAutomaticCheckAt: DateTime.now().subtract(const Duration(minutes: 1)),
  );
  final entered = Completer<void>();
  final release = Completer<LibrarySyncState>();
  const running = LibrarySyncState(
    status: LibrarySyncStatus.running,
    stage: LibrarySyncStage.fetchingArtists,
  );
  final engine = StubLibrarySyncEngine((request, {onProgress}) async {
    if (!request.isAutomatic) return const LibrarySyncState.idle();
    onProgress?.call(running);
    // A count-only update is held for the throttle's trailing timer.
    onProgress?.call(running.copyWith(processed: 1, total: 10));
    entered.complete();
    final result = await release.future;
    onProgress?.call(running);
    return result;
  });
  final notifier = _RecordingSyncNotifier();
  final container = _container(
    engine,
    database: database,
    reachability: ServerReachabilityStatus.offline,
    interval: _hourlyInterval,
    serverConfig: [
      serverConfigStateProvider.overrideWith(
        (ref) => ref.watch(_serverConfigSource),
      ),
    ],
    extra: [librarySyncNotifierProvider.overrideWithValue(notifier)],
  );
  addTearDown(container.dispose);
  container.read(_serverConfigSource.notifier).set(AsyncData(config));
  final automatic = container
      .read(librarySyncControllerProvider.notifier)
      .syncIfStale();
  await entered.future;
  return _ParkedCheck(container, notifier, automatic)..release = release;
}

Future<ServerConfigModel> _saveServer(
  NavisDatabase database,
  String username,
) async {
  await database.serverDao.saveServer(
    ServerConfigTableCompanion.insert(
      url: 'https://example.com',
      username: username,
      apiVersion: '1.16.1',
      isAuthenticated: const Value(true),
    ),
  );
  final row = (await database.serverDao.getActiveServer())!;
  return ServerConfigModel(
    id: row.id,
    url: row.url,
    username: row.username,
    password: 'secret',
    apiVersion: row.apiVersion,
  );
}

Matcher _catalogRequest(SyncRunOrigin origin, SyncRunIntent intent) =>
    isA<LibrarySyncRequest>()
        .having((request) => request.origin, 'origin', origin)
        .having((request) => request.intent, 'intent', intent)
        .having(
          (request) => request.target.kind,
          'target',
          LibrarySyncTargetKind.catalog,
        );

final _automaticRequest = _catalogRequest(
  SyncRunOrigin.timer,
  SyncRunIntent.automaticCatalogCheck,
);
final _manualRequest = _catalogRequest(
  SyncRunOrigin.libraryPullToRefresh,
  SyncRunIntent.manualCatalogCheck,
);
final _repairRequest = _catalogRequest(
  SyncRunOrigin.settingsRepair,
  SyncRunIntent.repairLibrary,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final kind in [
    LibrarySyncTargetKind.album,
    LibrarySyncTargetKind.artist,
  ]) {
    test('missing $kind cover requests one controller target', () async {
      final database = createTestDatabase();
      addTearDown(database.close);
      if (kind == LibrarySyncTargetKind.album) {
        await database
            .into(database.albumsTable)
            .insert(
              AlbumsTableCompanion.insert(
                id: 'entity',
                name: 'Album',
                coverArt: const Value('missing-cover'),
              ),
            );
      } else {
        await database
            .into(database.artistsTable)
            .insert(
              ArtistsTableCompanion.insert(
                id: 'entity',
                name: 'Artist',
                coverArt: const Value('missing-cover'),
              ),
            );
      }
      final requests = <LibrarySyncRequest>[];
      final engine = StubLibrarySyncEngine((request, {onProgress}) async {
        if (request.target.kind != LibrarySyncTargetKind.catalog) {
          requests.add(request);
          return const LibrarySyncState(
            status: LibrarySyncStatus.succeeded,
            stage: LibrarySyncStage.completed,
          );
        }
        return const LibrarySyncState.idle();
      });
      final container = ProviderContainer(
        overrides: [
          navisDatabaseProvider.overrideWithValue(database),
          serverConfigStateProvider.overrideWithValue(const AsyncData(null)),
          librarySyncEngineProvider.overrideWithValue(engine),
          _manualSyncInterval,
        ],
      );
      addTearDown(container.dispose);
      final recovery = container.read(coverArtRecoveryProvider);
      await Future.wait([
        recovery.handleMissingCover('missing-cover'),
        recovery.handleMissingCover('missing-cover'),
      ]);
      await recovery.handleMissingCover('missing-cover');
      expect(requests, hasLength(1));
      expect(requests.single.target.kind, kind);
      expect(requests.single.target.entityId, 'entity');
      expect(requests.single.origin, SyncRunOrigin.interaction);
    });
  }

  group('librarySyncControllerProvider', () {
    test(
      'repair and cache reset submit distinct origins with the same grant',
      () async {
        final database = createTestDatabase();
        addTearDown(database.close);
        final engine = StubLibrarySyncEngine.returning(_succeeded);
        final container = _container(
          engine,
          database: database,
          reachability: ServerReachabilityStatus.checking,
        );
        addTearDown(container.dispose);
        final controller = container.read(
          librarySyncControllerProvider.notifier,
        );

        await controller.repairLibrary(allowMeteredBroadOverride: true);
        await controller.resetCachesAndRebuildLibrary(
          allowMeteredBroadOverride: true,
        );

        expect(engine.requests, [
          _repairRequest,
          _catalogRequest(
            SyncRunOrigin.cacheReset,
            SyncRunIntent.repairLibrary,
          ),
        ]);
        expect(engine.requests.map((request) => request.grant), [
          SyncNetworkGrant.broadMeteredOnce,
          SyncNetworkGrant.broadMeteredOnce,
        ]);
      },
    );

    test('Z1: only repairLibrary(confirmation) carries a held-deletion '
        'confirmation', () async {
      final database = createTestDatabase();
      addTearDown(database.close);
      final engine = StubLibrarySyncEngine.returning(_succeeded);
      final container = _container(
        engine,
        database: database,
        reachability: ServerReachabilityStatus.checking,
      );
      addTearDown(container.dispose);
      final controller = container.read(librarySyncControllerProvider.notifier);

      await controller.repairLibrary();
      await controller.repairLibrary(
        confirmation: const HeldDeletionConfirmation(generation: 4, count: 17),
      );
      await controller.resetCachesAndRebuildLibrary();

      expect(engine.requests.map((r) => r.confirmsHeldDeletion?.generation), [
        null,
        4,
        null,
      ]);
      expect(engine.requests[1].confirmsHeldDeletion!.count, 17);
    });

    test('Z3: Discard is refused while a sync is running', () async {
      final database = createTestDatabase();
      addTearDown(database.close);
      final config = await _saveAuthenticatedServer(database);
      await database.librarySyncDao.writeState(
        LibrarySyncStateTableCompanion(
          serverId: Value(config.id!),
          candidateGeneration: const Value(5),
          candidateStatus: const Value('awaitingDeletionConfirmation'),
        ),
      );
      final engine = StubLibrarySyncEngine.returning(_succeeded);
      final container = _container(engine, database: database, server: config);
      addTearDown(container.dispose);
      container.listen(librarySyncControllerProvider, (_, _) {});
      final controller = container.read(librarySyncControllerProvider.notifier);
      controller.state = const LibrarySyncState(
        status: LibrarySyncStatus.running,
        stage: LibrarySyncStage.collectingCandidate,
        candidateGeneration: 5,
        candidateStatus: 'awaitingDeletionConfirmation',
      );

      expect(await controller.discardAwaitingRepairCandidate(), isFalse);
      expect(
        (await database.librarySyncDao.getOrCreateState(config.id!))
            .candidateStatus,
        'awaitingDeletionConfirmation',
      );

      controller.state = const LibrarySyncState(
        status: LibrarySyncStatus.partial,
        stage: LibrarySyncStage.validatingCandidate,
        candidateGeneration: 5,
        candidateStatus: 'awaitingDeletionConfirmation',
      );
      expect(await controller.discardAwaitingRepairCandidate(), isTrue);
      await pumpEventQueue();
    });

    test(
      'setup defers startup and automatic schedules until readiness',
      () async {
        final database = createTestDatabase();
        addTearDown(database.close);
        final config = await _saveAuthenticatedServer(
          database,
          setupPending: true,
        );
        final engine = StubLibrarySyncEngine.returning(
          const LibrarySyncState.idle(),
        );
        final container = _container(
          engine,
          database: database,
          server: config,
          interval: _hourlyInterval,
        );
        addTearDown(container.dispose);
        container.listen(librarySyncControllerProvider, (_, _) {});
        container.listen(initialSyncRequiredProvider, (_, _) {});
        expect(
          await container.read(initialSyncRequiredProvider.future),
          isTrue,
        );
        final controller = container.read(
          librarySyncControllerProvider.notifier,
        );
        await controller.syncIfStale();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(engine.explicitCatalogRequests, isEmpty);
        expect(engine.automaticRequests, isEmpty);
        expect(
          (await database.librarySyncDao.getOrCreateState(config.id!))
              .nextAutomaticCheckAt,
          isNull,
        );

        await database.librarySyncDao.writeState(
          LibrarySyncStateTableCompanion(
            serverId: Value(config.id!),
            currentGeneration: const Value(1),
            lastCatalogSyncedAt: Value(DateTime.now()),
          ),
        );
        expect(
          await recordInitialCatalogReadiness(
            database: database,
            serverId: config.id!,
            result: _succeeded,
            syncModelVersion: currentLibrarySyncModelVersion,
          ),
          isTrue,
        );
        final resumedAt = DateTime.now();
        container.invalidate(initialSyncRequiredProvider);
        expect(
          await container.read(initialSyncRequiredProvider.future),
          isFalse,
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));
        final deadline = (await database.librarySyncDao.getOrCreateState(
          config.id!,
        )).nextAutomaticCheckAt!;
        expect(
          deadline.difference(resumedAt.add(const Duration(hours: 1))).abs(),
          lessThan(const Duration(seconds: 2)),
        );
        expect(engine.explicitCatalogRequests, isEmpty);
        expect(engine.automaticRequests, isEmpty);
      },
    );

    test(
      'waitForActiveCatalogSync drains automatic work and queued successors',
      () async {
        final database = createTestDatabase();
        addTearDown(database.close);
        final config = await _saveAuthenticatedServer(database);
        final automaticResult = Completer<LibrarySyncState>();
        final manualResult = Completer<LibrarySyncState>();
        final enteredAutomatic = Completer<void>();
        final enteredManual = Completer<void>();
        final engine = StubLibrarySyncEngine((request, {onProgress}) async {
          if (request.isAutomatic) {
            enteredAutomatic.complete();
            return await automaticResult.future;
          }
          enteredManual.complete();
          return await manualResult.future;
        });
        final container = _container(
          engine,
          database: database,
          server: config,
          reachability: ServerReachabilityStatus.offline,
          interval: _hourlyInterval,
          extra: [
            requiredLibrarySyncModelVersionProvider.overrideWithValue(null),
          ],
        );
        addTearDown(container.dispose);
        container.listen(librarySyncControllerProvider, (_, _) {});
        final controller = container.read(
          librarySyncControllerProvider.notifier,
        );
        // Idle waits complete without starting a request.
        await controller.waitForActiveCatalogSync();
        final automatic = controller.syncIfStale();
        await enteredAutomatic.future;
        var finished = false;
        final waiting = controller.waitForActiveCatalogSync().then(
          (_) => finished = true,
        );
        final manual = controller.syncNow();
        automaticResult.complete(_succeeded);
        await enteredManual.future;
        await Future<void>.delayed(Duration.zero);
        expect(finished, isFalse);
        manualResult.complete(_succeeded);
        await Future.wait([automatic, manual]);
        await waiting;
        expect(finished, isTrue);
        await controller.waitForActiveCatalogSync();
      },
    );

    test(
      'waitForActiveCatalogSync tolerates errors from the active catalog',
      () async {
        final database = createTestDatabase();
        addTearDown(database.close);
        final failure = Completer<LibrarySyncState>();
        final entered = Completer<void>();
        final engine = StubLibrarySyncEngine((request, {onProgress}) async {
          if (request.isAutomatic) {
            return const LibrarySyncState.idle();
          }
          entered.complete();
          return await failure.future;
        });
        final container = _container(engine, database: database);
        addTearDown(container.dispose);
        container.listen(librarySyncControllerProvider, (_, _) {});
        final controller = container.read(
          librarySyncControllerProvider.notifier,
        );
        final active = controller.syncNow();
        final expectedError = expectLater(active, throwsStateError);
        await entered.future;
        final waiting = controller.waitForActiveCatalogSync();
        failure.completeError(StateError('Catalog failed'));
        await expectedError;
        await waiting;
        await controller.waitForActiveCatalogSync();
      },
    );

    test(
      'startup waits for its API-backed engine without publishing failure',
      () async {
        final database = createTestDatabase();
        addTearDown(database.close);
        final engine = StubLibrarySyncEngine.returning(
          LibrarySyncState(
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
              () => StaticReachabilityController(
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

        expect(engine.explicitCatalogRequests, [_repairRequest]);
        expect(
          container.read(librarySyncControllerProvider).status,
          LibrarySyncStatus.succeeded,
        );
      },
    );

    test(
      'session reset waits for startup before retrying a ready engine',
      () async {
        final database = createTestDatabase();
        addTearDown(database.close);
        final enteredFirst = Completer<void>();
        final firstResult = Completer<LibrarySyncState>();
        final enteredSecond = Completer<void>();
        final firstEngine = StubLibrarySyncEngine((
          request, {
          onProgress,
        }) async {
          enteredFirst.complete();
          return await firstResult.future;
        });
        final secondEngine = StubLibrarySyncEngine((
          request, {
          onProgress,
        }) async {
          enteredSecond.complete();
          return _succeeded;
        });
        final engineState =
            NotifierProvider<_MutableLibrarySyncEngine, LibrarySyncEngine?>(
              _MutableLibrarySyncEngine.new,
            );
        final container = ProviderContainer(
          overrides: [
            _manualSyncInterval,
            navisDatabaseProvider.overrideWithValue(database),
            serverReachabilityControllerProvider.overrideWith(
              () => StaticReachabilityController(
                const ServerReachabilityState(
                  status: ServerReachabilityStatus.online,
                ),
              ),
            ),
            requiredLibrarySyncModelVersionProvider.overrideWithValue(null),
            serverConfigStateProvider.overrideWith(
              (ref) => ref.watch(_serverConfigSource),
            ),
            librarySyncEngineProvider.overrideWith(
              (ref) => ref.watch(engineState),
            ),
          ],
        );
        addTearDown(container.dispose);
        container.read(engineState.notifier).replace(firstEngine);
        final source = container.read(_serverConfigSource.notifier);
        source.set(const AsyncData(_exampleServer));
        container.listen(librarySyncControllerProvider, (_, _) {});
        await enteredFirst.future.timeout(const Duration(seconds: 5));

        source.set(const AsyncData(null));
        expect(container.read(serverConfigStateProvider).value, isNull);
        final nextServer = _exampleServer.copyWith(username: 'bob');
        source.set(AsyncData(nextServer));
        expect(container.read(serverConfigStateProvider).value, nextServer);
        container.read(engineState.notifier).replace(secondEngine);
        expect(container.read(librarySyncEngineProvider), same(secondEngine));
        await Future<void>.delayed(Duration.zero);
        expect(firstEngine.requests, [_automaticRequest]);
        expect(secondEngine.requests, isEmpty);

        firstResult.complete(_succeeded);
        await enteredSecond.future.timeout(const Duration(seconds: 5));
        await container
            .read(librarySyncControllerProvider.notifier)
            .waitForActiveCatalogSync();
        await Future<void>.delayed(Duration.zero);
        source.set(AsyncData(nextServer.copyWith(lastSynced: DateTime.now())));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(firstEngine.requests, [_automaticRequest]);
        expect(secondEngine.requests, [_automaticRequest]);
      },
    );

    test('startup trigger runs once when authenticated', () async {
      final database = createTestDatabase();
      addTearDown(database.close);
      await database.appSettingsDao.setLastFullSyncAppBuild(
        currentLibrarySyncModelVersion,
      );
      final engine = StubLibrarySyncEngine((request, {onProgress}) async {
        final state = LibrarySyncState(
          status: LibrarySyncStatus.succeeded,
          stage: LibrarySyncStage.completed,
          completedAt: DateTime.now(),
          lastSyncedAt: DateTime.now(),
        );
        onProgress?.call(state);
        return state;
      });
      final container = _container(
        engine,
        database: database,
        server: ServerConfigModel(
          url: 'https://example.com',
          username: 'alice',
          password: 'secret',
          apiVersion: '1.16.1',
          lastSynced: DateTime.now().subtract(const Duration(days: 1)),
        ),
      );
      addTearDown(container.dispose);

      container.read(librarySyncControllerProvider);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      container.read(librarySyncControllerProvider);

      expect(engine.automaticRequests, [_automaticRequest]);
      expect(engine.explicitCatalogRequests, isEmpty);
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
      final engine = StubLibrarySyncEngine((request, {onProgress}) async {
        if (request.isAutomatic) {
          return _succeeded;
        }
        return LibrarySyncState(
          status: LibrarySyncStatus.succeeded,
          stage: LibrarySyncStage.completed,
          completedAt: DateTime.now(),
        );
      });
      final container = _container(
        engine,
        database: database,
        server: config,
        extra: [
          requiredLibrarySyncModelVersionProvider.overrideWithValue(null),
        ],
      );
      addTearDown(container.dispose);

      final controller = container.read(librarySyncControllerProvider.notifier);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await controller.syncIfStale();
      expect(engine.automaticRequests, isEmpty);
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
      expect(engine.explicitCatalogRequests, [_manualRequest]);
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
        final engine = StubLibrarySyncEngine((request, {onProgress}) async {
          if (request.isAutomatic) {
            return LibrarySyncState(
              status: LibrarySyncStatus.succeeded,
              stage: LibrarySyncStage.completed,
              completedAt: DateTime.now(),
            );
          }
          return _succeeded;
        });
        final startedAt = DateTime.now();
        final container = _container(
          engine,
          database: database,
          server: config,
          reachability: ServerReachabilityStatus.offline,
          interval: _hourlyInterval,
        );
        addTearDown(container.dispose);
        addTearDown(
          () => container
              .read(librarySyncControllerProvider.notifier)
              .cancelAndWait(),
        );

        final result = await container
            .read(librarySyncControllerProvider.notifier)
            .syncIfStale();
        final persisted = await database.librarySyncDao.getOrCreateState(
          config.id!,
        );

        expect(result.status, LibrarySyncStatus.succeeded);
        expect(engine.automaticRequests, [_automaticRequest]);
        expect(persisted.nextAutomaticCheckAt, isNotNull);
        expect(persisted.nextAutomaticCheckAt!.isAfter(startedAt), isTrue);
        expect(
          persisted.nextAutomaticCheckAt!.difference(startedAt),
          greaterThan(const Duration(minutes: 59)),
        );
      },
    );

    test('a lease-held automatic check retries at a foreground lease expiry, '
        'not a full interval later', () async {
      final database = createTestDatabase();
      addTearDown(database.close);
      final config = await _saveAuthenticatedServer(database);
      await database.librarySyncDao.setNextAutomaticCheckAt(
        serverId: config.id!,
        nextAutomaticCheckAt: DateTime.now().subtract(
          const Duration(minutes: 1),
        ),
      );
      await database.librarySyncDao.acquireExecutionLease(
        serverId: config.id!,
        ownerToken: 'foreground',
        ownerKind: 'foreground',
        now: DateTime.now(),
        ttl: const Duration(minutes: 3),
      );
      final engine = StubLibrarySyncEngine((request, {onProgress}) async {
        if (request.isAutomatic) {
          return LibrarySyncState(
            status: LibrarySyncStatus.deferred,
            stage: LibrarySyncStage.completed,
            completedAt: DateTime.now(),
            planReason: 'leaseHeld',
          );
        }
        return _succeeded;
      });
      final startedAt = DateTime.now();
      final container = _container(
        engine,
        database: database,
        server: config,
        reachability: ServerReachabilityStatus.offline,
        interval: _hourlyInterval,
      );
      addTearDown(container.dispose);
      addTearDown(
        () => container
            .read(librarySyncControllerProvider.notifier)
            .cancelAndWait(),
      );

      await container
          .read(librarySyncControllerProvider.notifier)
          .syncIfStale();
      final persisted = await database.librarySyncDao.getOrCreateState(
        config.id!,
      );

      expect(engine.automaticRequests, [_automaticRequest]);
      final wait = persisted.nextAutomaticCheckAt!.difference(startedAt);
      expect(wait, greaterThan(const Duration(minutes: 2)));
      expect(wait, lessThan(const Duration(minutes: 4)));
    });

    for (final (name, retryIn, expected) in [
      (
        'a silent busy failure retries at the coordinator retry time',
        const Duration(minutes: 1),
        const Duration(minutes: 1),
      ),
      (
        'a silent busy retry is floored at 30 s',
        const Duration(seconds: 1),
        const Duration(seconds: 30),
      ),
    ]) {
      test(name, () async {
        final database = createTestDatabase();
        addTearDown(database.close);
        final config = await _saveAuthenticatedServer(database);
        await database.librarySyncDao.setNextAutomaticCheckAt(
          serverId: config.id!,
          nextAutomaticCheckAt: DateTime.now().subtract(
            const Duration(minutes: 1),
          ),
        );
        final engine = StubLibrarySyncEngine((request, {onProgress}) async {
          if (request.isAutomatic) {
            return LibrarySyncState(
              status: LibrarySyncStatus.failed,
              stage: LibrarySyncStage.completed,
              completedAt: DateTime.now(),
              failureCategory: 'databaseBusy',
              nextRetryAt: DateTime.now().add(retryIn),
            );
          }
          return _succeeded;
        });
        final startedAt = DateTime.now();
        final container = _container(
          engine,
          database: database,
          server: config,
          reachability: ServerReachabilityStatus.offline,
          interval: _hourlyInterval,
        );
        addTearDown(container.dispose);
        addTearDown(
          () => container
              .read(librarySyncControllerProvider.notifier)
              .cancelAndWait(),
        );

        await container
            .read(librarySyncControllerProvider.notifier)
            .syncIfStale();
        final persisted = await database.librarySyncDao.getOrCreateState(
          config.id!,
        );

        final wait = persisted.nextAutomaticCheckAt!.difference(startedAt);
        expect(wait, greaterThan(expected - const Duration(seconds: 5)));
        expect(wait, lessThan(expected + const Duration(seconds: 5)));
      });
    }

    test(
      'a stale silent failure does not keep rescheduling 30 s checks',
      () async {
        final database = createTestDatabase();
        addTearDown(database.close);
        final config = await _saveAuthenticatedServer(database);
        var calls = 0;
        final engine = StubLibrarySyncEngine((request, {onProgress}) async {
          if (!request.isAutomatic) return _succeeded;
          calls++;
          return calls == 1
              ? LibrarySyncState(
                  status: LibrarySyncStatus.failed,
                  stage: LibrarySyncStage.completed,
                  completedAt: DateTime.now(),
                  failureCategory: 'databaseBusy',
                  nextRetryAt: DateTime.now().add(const Duration(minutes: 1)),
                )
              : LibrarySyncState(
                  status: LibrarySyncStatus.deferred,
                  stage: LibrarySyncStage.completed,
                  completedAt: DateTime.now(),
                );
        });
        final container = _container(
          engine,
          database: database,
          server: config,
          reachability: ServerReachabilityStatus.offline,
          interval: _hourlyInterval,
        );
        addTearDown(container.dispose);
        final controller = container.read(
          librarySyncControllerProvider.notifier,
        );
        addTearDown(controller.cancelAndWait);

        for (var i = 0; i < 4; i++) {
          await database.librarySyncDao.setNextAutomaticCheckAt(
            serverId: config.id!,
            nextAutomaticCheckAt: DateTime.now().subtract(
              const Duration(minutes: 1),
            ),
          );
          final startedAt = DateTime.now();
          final result = await controller.syncIfStale();
          final wait = (await database.librarySyncDao.getOrCreateState(
            config.id!,
          )).nextAutomaticCheckAt!.difference(startedAt);
          if (i == 0) {
            expect(result.isSilentFailure, isTrue);
            expect(wait, lessThan(const Duration(minutes: 2)));
          } else {
            // Only the pass that failed schedules the quick retry.
            expect(result.isSilentFailure, isFalse);
            expect(wait, greaterThan(const Duration(minutes: 59)));
          }
        }
      },
    );

    LibrarySyncState busyDeferral() => LibrarySyncState(
      status: LibrarySyncStatus.deferred,
      stage: LibrarySyncStage.completed,
      completedAt: DateTime.now(),
      planReason: 'leaseHeld',
      failureCategory: 'databaseBusy',
      nextRetryAt: DateTime.now().add(const Duration(minutes: 1)),
    );

    Future<(LibrarySyncController, NavisDatabase, int, _RecordingSyncNotifier)>
    busyDeferralRun(
      LibrarySyncState Function(int automaticCall) automatic, {
      List<Override> interval = const <Override>[],
      Future<void>? manualGate,
    }) async {
      final database = createTestDatabase();
      addTearDown(database.close);
      final config = await _saveAuthenticatedServer(database);
      var calls = 0;
      final engine = StubLibrarySyncEngine((request, {onProgress}) async {
        if (request.isAutomatic) return automatic(++calls);
        await manualGate;
        return busyDeferral();
      });
      final notifier = _RecordingSyncNotifier();
      final container = _container(
        engine,
        database: database,
        server: config,
        reachability: ServerReachabilityStatus.offline,
        interval: interval.isEmpty ? _hourlyInterval : interval,
        extra: [librarySyncNotifierProvider.overrideWithValue(notifier)],
      );
      addTearDown(container.dispose);
      final controller = container.read(librarySyncControllerProvider.notifier);
      addTearDown(controller.cancelAndWait);
      return (controller, database, config.id!, notifier);
    }

    Future<Duration> dueCheckWait(
      LibrarySyncController controller,
      NavisDatabase database,
      int serverId,
    ) async {
      await database.librarySyncDao.setNextAutomaticCheckAt(
        serverId: serverId,
        nextAutomaticCheckAt: DateTime.now().subtract(
          const Duration(minutes: 1),
        ),
      );
      final startedAt = DateTime.now();
      await controller.syncIfStale();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      return (await database.librarySyncDao.getOrCreateState(serverId))
          .nextAutomaticCheckAt!
          .difference(startedAt);
    }

    test(
      'a busy deferral retries in about a minute without a notice',
      () async {
        final (controller, database, serverId, notifier) =
            await busyDeferralRun((_) => busyDeferral());

        final wait = await dueCheckWait(controller, database, serverId);

        expect(wait, greaterThan(const Duration(seconds: 55)));
        expect(wait, lessThan(const Duration(minutes: 2)));
        expect(controller.state.status, LibrarySyncStatus.deferred);
        expect(notifier.failedShown, 0);
        expect(notifier.completeShown, 0);
      },
    );

    test('a plain lease deferral keeps the lease-expiry schedule', () async {
      final (controller, database, serverId, _) = await busyDeferralRun(
        (_) => busyDeferral().copyWith(
          clearFailureCategory: true,
          clearNextRetryAt: true,
        ),
      );

      final wait = await dueCheckWait(controller, database, serverId);

      // No lease row: the 30 s retry floor, not the 1 min busy retry.
      expect(wait, lessThan(const Duration(seconds: 45)));
    });

    test('a busy deferral retries after a preserved visible failure', () async {
      final (controller, database, serverId, _) = await busyDeferralRun(
        (call) => call == 1
            ? LibrarySyncState(
                status: LibrarySyncStatus.failed,
                stage: LibrarySyncStage.completed,
                completedAt: DateTime.now(),
                failureCategory: 'sync',
                errorMessage: 'Metadata sync failed.',
              )
            : busyDeferral(),
      );
      await dueCheckWait(controller, database, serverId);
      expect(controller.state.status, LibrarySyncStatus.failed);

      final wait = await dueCheckWait(controller, database, serverId);

      expect(controller.state.status, LibrarySyncStatus.failed);
      // About a minute, not the 30 s lease-expiry floor or the full interval.
      expect(wait, greaterThan(const Duration(seconds: 55)));
      expect(wait, lessThan(const Duration(minutes: 2)));
    });

    test(
      'a due automatic check joining a manual busy deferral keeps its retry',
      () async {
        final gate = Completer<void>();
        final (controller, database, serverId, _) = await busyDeferralRun(
          (_) => _succeeded,
          manualGate: gate.future,
        );
        await database.librarySyncDao.setNextAutomaticCheckAt(
          serverId: serverId,
          nextAutomaticCheckAt: DateTime.now().subtract(
            const Duration(minutes: 1),
          ),
        );

        // The automatic pass joins the manual one (higher priority), which ends
        // in a busy deferral and arms its quick retry. The join must not
        // overwrite it with a full-interval completion.
        final manual = controller.syncNow();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final startedAt = DateTime.now();
        final automatic = controller.syncIfStale();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        gate.complete();
        await manual;
        await automatic;
        await Future<void>.delayed(const Duration(milliseconds: 50));

        final wait = (await database.librarySyncDao.getOrCreateState(serverId))
            .nextAutomaticCheckAt!
            .difference(startedAt);
        expect(wait, greaterThan(const Duration(seconds: 55)));
        expect(wait, lessThan(const Duration(minutes: 2)));
      },
    );

    test('manual-only mode does not retry a busy deferral', () async {
      final (controller, database, serverId, _) = await busyDeferralRun(
        (_) => busyDeferral(),
        interval: [
          syncIntervalMinutesProvider.overrideWithValue(0),
          syncIntervalDurationProvider.overrideWithValue(null),
        ],
      );

      final result = await controller.syncNow();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(result.status, LibrarySyncStatus.deferred);
      expect(result.errorMessage, isNull);
      expect(controller.state.status, LibrarySyncStatus.deferred);
      expect(
        (await database.librarySyncDao.getOrCreateState(serverId))
            .nextAutomaticCheckAt,
        isNull,
      );
    });

    const failNextCheck =
        'CREATE TRIGGER fail_next_check BEFORE UPDATE OF '
        'next_automatic_check_at ON library_sync_state '
        // Only the near-term retry write fails, not a full-interval deadline.
        "WHEN NEW.next_automatic_check_at < CAST(strftime('%s', 'now') AS INT) "
        '+ 600 BEGIN '
        "SELECT RAISE(ABORT, 'database is locked'); END";

    LibrarySyncState busyFailure() => LibrarySyncState(
      status: LibrarySyncStatus.failed,
      stage: LibrarySyncStage.completed,
      completedAt: DateTime.now(),
      failureCategory: 'databaseBusy',
      errorMessage: '',
      nextRetryAt: DateTime.now(),
    );

    /// A container whose next check is 5 h away and whose non-automatic
    /// requests fail busy. The retry floor is shortened for the test.
    Future<
      (
        StubLibrarySyncEngine,
        LibrarySyncController,
        NavisDatabase,
        ProviderContainer,
      )
    >
    busyForcedRun({
      List<Override> interval = const <Override>[],
      Duration deadlineIn = const Duration(hours: 5),
      List<DateTime>? automaticCalls,
      bool mutableServerConfig = false,
    }) async {
      final floor = LibrarySyncController.automaticRetryFloor;
      LibrarySyncController.automaticRetryFloor = const Duration(
        milliseconds: 150,
      );
      addTearDown(() => LibrarySyncController.automaticRetryFloor = floor);
      final database = createTestDatabase();
      addTearDown(database.close);
      final config = await _saveAuthenticatedServer(database);
      await database.librarySyncDao.setNextAutomaticCheckAt(
        serverId: config.id!,
        nextAutomaticCheckAt: DateTime.now().add(deadlineIn),
      );
      final engine = StubLibrarySyncEngine((request, {onProgress}) async {
        if (!request.isAutomatic) return busyFailure();
        if (automaticCalls == null) return _succeeded;
        automaticCalls.add(DateTime.now());
        return busyFailure();
      });
      final container = _container(
        engine,
        database: database,
        server: config,
        reachability: ServerReachabilityStatus.offline,
        interval: interval.isEmpty ? _hourlyInterval : interval,
        serverConfig: mutableServerConfig
            ? [
                serverConfigStateProvider.overrideWith(
                  (ref) => ref.watch(_serverConfigSource),
                ),
              ]
            : const <Override>[],
      );
      addTearDown(container.dispose);
      if (mutableServerConfig) {
        container.read(_serverConfigSource.notifier).set(AsyncData(config));
      }
      final controller = container.read(librarySyncControllerProvider.notifier);
      addTearDown(controller.cancelAndWait);
      return (engine, controller, database, container);
    }

    test('a forced run that fails busy retries in about a minute', () async {
      final (engine, controller, _, _) = await busyForcedRun();
      final before = engine.automaticRequests.length;

      await controller.syncNow();
      await _until(() => engine.automaticRequests.length > before);

      // The periodic timer was re-armed for the retry, so an automatic check
      // actually runs soon, not at the old 5 h deadline.
      expect(engine.automaticRequests.length, greaterThan(before));
    });

    test('desktop focus regain re-arms the periodic timer from the stored '
        'deadline (#349)', () async {
      final binding = TestWidgetsFlutterBinding.ensureInitialized();
      debugDesktopRuntimeOverride = true;
      addTearDown(() {
        debugDesktopRuntimeOverride = null;
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      });
      final (engine, _, database, _) = await busyForcedRun();
      // The timer is armed for the 5 h deadline; a lock or sleep left it
      // stale, so the stored deadline is now close.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await database.librarySyncDao.setNextAutomaticCheckAt(
        serverId: 1,
        nextAutomaticCheckAt: DateTime.now().add(
          const Duration(milliseconds: 300),
        ),
      );
      expect(engine.automaticRequests, isEmpty);

      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _until(
        () => engine.automaticRequests.isNotEmpty,
        timeout: const Duration(seconds: 5),
      );

      expect(engine.automaticRequests, isNotEmpty);
    });

    test('a failing retry write still publishes the final state', () async {
      final (engine, controller, database, _) = await busyForcedRun();
      await database.customStatement(failNextCheck);

      final result = await controller.syncNow();

      expect(result.isSilentFailure, isTrue);
      expect(controller.state.status, LibrarySyncStatus.failed);
      expect(controller.state.nextAutomaticCheckAt, isNotNull);
      expect(
        controller.state.nextAutomaticCheckAt!.difference(DateTime.now()),
        lessThan(const Duration(seconds: 2)),
      );
      expect(engine.explicitCatalogRequests, isNotEmpty);
    });

    test('a forced run still retries when the retry write fails', () async {
      final (engine, controller, database, _) = await busyForcedRun();
      await database.customStatement(failNextCheck);
      final before = engine.automaticRequests.length;

      await controller.syncNow();
      await _until(() => engine.automaticRequests.length > before);

      expect(engine.automaticRequests.length, greaterThan(before));
    });

    test('a server change drops the in-memory busy retry', () async {
      final (engine, controller, database, container) = await busyForcedRun(
        mutableServerConfig: true,
      );
      final config = container.read(serverConfigStateProvider).value!;
      // Let the initial schedule load before the trigger takes over.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      // Below the trigger's 10 min window, so the retry write still fails.
      LibrarySyncController.automaticRetryFloor = const Duration(minutes: 5);
      await database.customStatement(failNextCheck);

      // The busy retry stays only in memory because its write fails. Let that
      // failed write settle, then make the new server's deadline due.
      await controller.syncNow();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await database.customStatement('DROP TRIGGER fail_next_check');
      await database.librarySyncDao.setNextAutomaticCheckAt(
        serverId: config.id!,
        nextAutomaticCheckAt: DateTime.now().subtract(
          const Duration(minutes: 1),
        ),
      );

      container
          .read(_serverConfigSource.notifier)
          .set(AsyncData(config.copyWith(username: 'bob')));
      await _until(
        () => controller.state.status == LibrarySyncStatus.idle,
        timeout: const Duration(seconds: 2),
      );

      await controller.syncIfStale();

      // The old server's retry is 5 min away, but the new server's persisted
      // deadline is due, so the check must run now.
      expect(engine.automaticRequests, isNotEmpty);
    });

    test(
      'an automatic busy pass with a failing write is not re-run at once',
      () async {
        final calls = <DateTime>[];
        final (_, controller, database, _) = await busyForcedRun(
          deadlineIn: const Duration(minutes: -1),
          automaticCalls: calls,
        );
        await database.customStatement(failNextCheck);

        await controller.syncIfStale();
        await _until(() => calls.length >= 2);

        // The retry waits for the floor instead of spinning on the stale
        // persisted deadline.
        expect(calls.length, greaterThanOrEqualTo(2));
        expect(
          calls[1].difference(calls[0]),
          greaterThan(const Duration(milliseconds: 100)),
        );
      },
    );

    test('manual-only mode shows a busy failure as an ordinary one', () async {
      final (_, controller, _, _) = await busyForcedRun(
        interval: [
          syncIntervalMinutesProvider.overrideWithValue(0),
          syncIntervalDurationProvider.overrideWithValue(null),
        ],
      );

      final result = await controller.syncNow();

      expect(result.isSilentFailure, isFalse);
      expect(result.failureCategory, 'sync');
      expect(result.errorMessage, 'Metadata sync failed.');
      expect(controller.state.isSilentFailure, isFalse);
    });

    test(
      'a startup repair that fails busy is retried by the next trigger',
      () async {
        final database = createTestDatabase();
        addTearDown(database.close);
        var networkType = NetworkType.other;
        final engine = StubLibrarySyncEngine((request, {onProgress}) async {
          if (request.isAutomatic) {
            return const LibrarySyncState(
              status: LibrarySyncStatus.skipped,
              stage: LibrarySyncStage.completed,
            );
          }
          return LibrarySyncState(
            status: LibrarySyncStatus.failed,
            stage: LibrarySyncStage.completed,
            completedAt: DateTime.now(),
            failureCategory: 'databaseBusy',
            nextRetryAt: DateTime.now().add(const Duration(minutes: 1)),
          );
        });
        final container = _container(
          engine,
          database: database,
          server: _exampleServer,
          // Silent only with an automatic interval; manual-only shows it.
          interval: _hourlyInterval,
          extra: [
            networkTypeProvider.overrideWith((ref) => networkType),
            requiredLibrarySyncModelVersionProvider.overrideWithValue(
              'model-v2',
            ),
          ],
        );
        addTearDown(container.dispose);

        container.read(librarySyncControllerProvider);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(engine.explicitCatalogRequests, [_repairRequest]);

        // Offline and back (not Wi-Fi, which would reset the fingerprint).
        for (final next in [NetworkType.offline, NetworkType.other]) {
          networkType = next;
          container.invalidate(networkTypeProvider);
          expect(container.read(networkTypeProvider), next);
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }

        // A silent failure leaves the startup pass unfinished.
        expect(engine.explicitCatalogRequests, [
          _repairRequest,
          _repairRequest,
        ]);
        expect(await database.appSettingsDao.getLastFullSyncAppBuild(), isNull);
      },
    );

    test(
      'an app-open automatic check runs while a worker lease is live',
      () async {
        final database = createTestDatabase();
        addTearDown(database.close);
        final config = await _saveAuthenticatedServer(database);
        final credentials = FakeSyncCredentialStore();
        await credentials.savePassword(config.password);
        final repository = ServerConfigRepository(
          database,
          credentials: credentials,
        );
        final api = FakeLibrarySyncApi()
          ..indexes = Indexes(
            lastModified: FakeLibrarySyncApi.defaultIndexesCursor,
          );
        final coordinator = AdaptiveLibrarySyncCoordinator(
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
        await database.librarySyncDao.writeState(
          LibrarySyncStateTableCompanion(
            serverId: Value(config.id!),
            currentGeneration: const Value(1),
            initialCatalogUsableAt: Value(DateTime.now()),
          ),
        );
        await database.librarySyncDao.setNextAutomaticCheckAt(
          serverId: config.id!,
          nextAutomaticCheckAt: DateTime.now().subtract(
            const Duration(minutes: 1),
          ),
        );
        expect(
          await database.librarySyncDao.acquireExecutionLease(
            serverId: config.id!,
            ownerToken: 'worker',
            ownerKind: 'androidWorker',
            now: DateTime.now(),
            ttl: const Duration(minutes: 3),
          ),
          isTrue,
        );
        final container = _container(
          coordinator,
          database: database,
          server: config,
          reachability: ServerReachabilityStatus.offline,
          interval: _hourlyInterval,
        );
        addTearDown(container.dispose);
        addTearDown(
          () => container
              .read(librarySyncControllerProvider.notifier)
              .cancelAndWait(),
        );

        final startedAt = DateTime.now();
        final result = await container
            .read(librarySyncControllerProvider.notifier)
            .syncIfStale();
        final persisted = await database.librarySyncDao.getOrCreateState(
          config.id!,
        );
        final lease = await database.librarySyncDao.getExecutionLease(
          config.id!,
        );

        expect(result.planReason, isNot('leaseHeld'));
        expect(api.calls, isNotEmpty);
        expect(
          persisted.nextAutomaticCheckAt!.difference(startedAt),
          greaterThan(const Duration(minutes: 59)),
        );
        expect(lease?.ownerToken, isNot('worker'));
      },
    );

    test('a lease-held check against a live worker lease retries at the 30 '
        'second floor, not at its heartbeat-extended expiry', () async {
      final database = createTestDatabase();
      addTearDown(database.close);
      final config = await _saveAuthenticatedServer(database);
      await database.librarySyncDao.setNextAutomaticCheckAt(
        serverId: config.id!,
        nextAutomaticCheckAt: DateTime.now().subtract(
          const Duration(minutes: 1),
        ),
      );
      await database.librarySyncDao.acquireExecutionLease(
        serverId: config.id!,
        ownerToken: 'worker',
        ownerKind: 'androidWorker',
        now: DateTime.now(),
        ttl: const Duration(minutes: 3),
      );
      final engine = StubLibrarySyncEngine((request, {onProgress}) async {
        if (request.isAutomatic) {
          return LibrarySyncState(
            status: LibrarySyncStatus.deferred,
            stage: LibrarySyncStage.completed,
            completedAt: DateTime.now(),
            planReason: 'leaseHeld',
          );
        }
        return _succeeded;
      });
      final startedAt = DateTime.now();
      final container = _container(
        engine,
        database: database,
        server: config,
        reachability: ServerReachabilityStatus.offline,
        interval: _hourlyInterval,
      );
      addTearDown(container.dispose);
      addTearDown(
        () => container
            .read(librarySyncControllerProvider.notifier)
            .cancelAndWait(),
      );

      await container
          .read(librarySyncControllerProvider.notifier)
          .syncIfStale();
      final persisted = await database.librarySyncDao.getOrCreateState(
        config.id!,
      );

      final wait = persisted.nextAutomaticCheckAt!.difference(startedAt);
      expect(wait, greaterThanOrEqualTo(const Duration(seconds: 29)));
      expect(wait, lessThanOrEqualTo(const Duration(seconds: 31)));
    });

    test(
      'an expired or released lease retries at the 30 second floor',
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
        // Acquired five minutes ago with a one minute ttl: already expired, so
        // expiry + 5s lies in the past and the floor applies.
        await database.librarySyncDao.acquireExecutionLease(
          serverId: config.id!,
          ownerToken: 'worker',
          ownerKind: 'worker',
          now: DateTime.now().subtract(const Duration(minutes: 5)),
          ttl: const Duration(minutes: 1),
        );
        final engine = StubLibrarySyncEngine((request, {onProgress}) async {
          if (request.isAutomatic) {
            return LibrarySyncState(
              status: LibrarySyncStatus.deferred,
              stage: LibrarySyncStage.completed,
              completedAt: DateTime.now(),
              planReason: 'leaseHeld',
            );
          }
          return _succeeded;
        });
        final startedAt = DateTime.now();
        final container = _container(
          engine,
          database: database,
          server: config,
          reachability: ServerReachabilityStatus.offline,
          interval: _hourlyInterval,
        );
        addTearDown(container.dispose);
        addTearDown(
          () => container
              .read(librarySyncControllerProvider.notifier)
              .cancelAndWait(),
        );

        await container
            .read(librarySyncControllerProvider.notifier)
            .syncIfStale();
        final persisted = await database.librarySyncDao.getOrCreateState(
          config.id!,
        );

        final wait = persisted.nextAutomaticCheckAt!.difference(startedAt);
        expect(wait, greaterThanOrEqualTo(const Duration(seconds: 29)));
        expect(wait, lessThanOrEqualTo(const Duration(seconds: 31)));
      },
    );

    test(
      'a lease outliving the interval caps the retry at the full interval',
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
        await database.librarySyncDao.acquireExecutionLease(
          serverId: config.id!,
          ownerToken: 'worker',
          ownerKind: 'worker',
          now: DateTime.now(),
          ttl: const Duration(hours: 2),
        );
        final engine = StubLibrarySyncEngine((request, {onProgress}) async {
          if (request.isAutomatic) {
            return LibrarySyncState(
              status: LibrarySyncStatus.deferred,
              stage: LibrarySyncStage.completed,
              completedAt: DateTime.now(),
              planReason: 'leaseHeld',
            );
          }
          return _succeeded;
        });
        final startedAt = DateTime.now();
        final container = _container(
          engine,
          database: database,
          server: config,
          reachability: ServerReachabilityStatus.offline,
          interval: _hourlyInterval,
        );
        addTearDown(container.dispose);
        addTearDown(
          () => container
              .read(librarySyncControllerProvider.notifier)
              .cancelAndWait(),
        );

        await container
            .read(librarySyncControllerProvider.notifier)
            .syncIfStale();
        final persisted = await database.librarySyncDao.getOrCreateState(
          config.id!,
        );

        final wait = persisted.nextAutomaticCheckAt!.difference(startedAt);
        expect(
          wait,
          greaterThanOrEqualTo(const Duration(minutes: 59, seconds: 59)),
        );
        expect(wait, lessThanOrEqualTo(const Duration(hours: 1, seconds: 1)));
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
        final engine = StubLibrarySyncEngine((request, {onProgress}) async {
          if (request.isAutomatic) {
            enteredEngine.complete();
            return await automaticResult.future;
          }
          return const LibrarySyncState.idle();
        });
        final container = _container(
          engine,
          database: database,
          server: config,
          reachability: ServerReachabilityStatus.offline,
          interval: _hourlyInterval,
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
        final engine = StubLibrarySyncEngine((request, {onProgress}) async {
          if (request.isAutomatic) {
            return LibrarySyncState(
              status: LibrarySyncStatus.succeeded,
              stage: LibrarySyncStage.completed,
              completedAt: DateTime.now(),
            );
          }
          return _succeeded;
        });
        final container = _container(
          engine,
          database: database,
          server: config,
          interval: _hourlyInterval,
          extra: [
            requiredLibrarySyncModelVersionProvider.overrideWithValue(null),
          ],
        );
        addTearDown(container.dispose);

        container.read(librarySyncControllerProvider);
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(engine.automaticRequests, [_automaticRequest]);
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
      final engine = StubLibrarySyncEngine((request, {onProgress}) async {
        if (request.isAutomatic) {
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
        }
        return const LibrarySyncState.idle();
      });
      final container = _container(
        engine,
        database: database,
        server: config,
        interval: _hourlyInterval,
        extra: [
          requiredLibrarySyncModelVersionProvider.overrideWithValue(null),
        ],
      );
      addTearDown(container.dispose);

      container.read(librarySyncControllerProvider);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(engine.automaticRequests, [_automaticRequest]);
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
        final engine = StubLibrarySyncEngine((request, {onProgress}) async {
          if (request.isAutomatic) {
            return const LibrarySyncState.idle();
          }
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
        });
        final container = _container(
          engine,
          database: database,
          server: config,
          interval: _hourlyInterval,
          extra: [
            requiredLibrarySyncModelVersionProvider.overrideWithValue(null),
          ],
        );
        addTearDown(container.dispose);
        final controller = container.read(
          librarySyncControllerProvider.notifier,
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(engine.automaticRequests, isEmpty);
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

        expect(engine.explicitCatalogRequests, [_repairRequest]);
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
      final engine = StubLibrarySyncEngine((request, {onProgress}) async {
        if (request.isAutomatic) {
          return LibrarySyncState(
            status: LibrarySyncStatus.succeeded,
            stage: LibrarySyncStage.completed,
            completedAt: DateTime.now(),
          );
        }
        return _succeeded;
      });
      final container = _container(
        engine,
        database: database,
        server: config,
        reachability: ServerReachabilityStatus.offline,
        interval: _hourlyInterval,
        extra: [
          requiredLibrarySyncModelVersionProvider.overrideWithValue(null),
        ],
      );
      addTearDown(container.dispose);

      container.read(librarySyncControllerProvider);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(engine.automaticRequests, isEmpty);

      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(engine.automaticRequests, [_automaticRequest]);
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

    test('cancelAndWait drains Android reconciliation before a wipe', () async {
      final database = createTestDatabase();
      addTearDown(database.close);
      final config = await _saveAuthenticatedServer(database);
      const channel = MethodChannel('com.navis.app/background_sync');
      final entered = Completer<void>();
      final release = Completer<void>();
      final methods = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            methods.add(call.method);
            if (call.method == 'configurePeriodic') {
              entered.complete();
              await release.future;
            }
            return <String, Object>{
              'available': true,
              'state': call.method == 'cancel' ? 'cancelled' : 'scheduled',
            };
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });
      final reconciler = AndroidBackgroundSyncReconciler(
        database: database,
        scheduler: AndroidBackgroundSyncScheduler(
          channel: channel,
          supported: true,
        ),
      );
      final engine = StubLibrarySyncEngine(
        (request, {onProgress}) async => _succeeded,
      );
      final container = ProviderContainer(
        overrides: [
          navisDatabaseProvider.overrideWithValue(database),
          librarySyncEngineProvider.overrideWithValue(engine),
          serverReachabilityControllerProvider.overrideWith(
            () => StaticReachabilityController(
              const ServerReachabilityState(
                status: ServerReachabilityStatus.offline,
              ),
            ),
          ),
          ..._hourlyInterval,
          serverConfigStateProvider.overrideWith(
            (ref) => ref.watch(_serverConfigSource),
          ),
          androidBackgroundSyncAvailableProvider.overrideWithValue(true),
          androidBackgroundSyncReconcilerProvider.overrideWithValue(reconciler),
          backgroundSyncUnmeteredOnlyProvider.overrideWithValue(true),
        ],
      );
      addTearDown(container.dispose);
      container.read(_serverConfigSource.notifier).set(AsyncData(config));
      final controller = container.read(librarySyncControllerProvider.notifier);
      await entered.future;
      var drained = false;
      final cancellation = controller.cancelAndWait().then(
        (_) => drained = true,
      );
      await Future<void>.delayed(Duration.zero);
      final drainedBeforeRelease = drained;
      release.complete();
      await cancellation;
      expect(drainedBeforeRelease, isFalse);
      await reconciler.cancelFor(config);
      await database.serverDao.clearServer();
      container.read(_serverConfigSource.notifier).set(const AsyncData(null));
      await container.pump();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(methods.where((method) => method == 'cancel'), hasLength(1));
      expect(
        await database.select(database.librarySyncStateTable).get(),
        isEmpty,
      );
    }, skip: !sqliteAvailable);

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
      final engine = StubLibrarySyncEngine((request, {onProgress}) async {
        if (request.isAutomatic) {
          entered.complete();
          return await completion.future;
        }
        return const LibrarySyncState.idle();
      });
      final container = _container(
        engine,
        database: database,
        server: config,
        reachability: ServerReachabilityStatus.offline,
        interval: _hourlyInterval,
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
      expect(engine.automaticRequests, [_automaticRequest]);
    });

    test('an old run cannot overwrite a same-user re-sign-in', () async {
      final database = createTestDatabase();
      addTearDown(database.close);
      final config = await _saveAuthenticatedServer(database);
      final parked = await _parkedCheck(database, config);

      await parked.changeSession(config);
      final before = parked.status;
      parked.release.complete(
        LibrarySyncState(
          status: LibrarySyncStatus.cancelled,
          stage: LibrarySyncStage.completed,
          completedAt: DateTime.now(),
        ),
      );
      await parked.automatic;

      expect(before, isNot(LibrarySyncStatus.cancelled));
      expect(parked.status, before);
      await parked.drain();
    }, skip: !sqliteAvailable);

    test(
      'a run started before the config listener ran still lands its result',
      () async {
        final database = createTestDatabase();
        addTearDown(database.close);
        final config = await _saveAuthenticatedServer(database);
        final engine = StubLibrarySyncEngine.returning(_succeeded);
        final container = _container(
          engine,
          database: database,
          serverConfig: [
            serverConfigStateProvider.overrideWith(
              (ref) => ref.watch(_serverConfigSource),
            ),
          ],
        );
        addTearDown(container.dispose);
        final controller = container.read(
          librarySyncControllerProvider.notifier,
        );

        container.read(_serverConfigSource.notifier).set(AsyncData(config));
        final result = await controller.syncNow();
        await container.pump();

        expect(result.status, LibrarySyncStatus.succeeded);
        expect(
          container.read(librarySyncControllerProvider).status,
          LibrarySyncStatus.succeeded,
        );
      },
      skip: !sqliteAvailable,
    );

    test(
      'an abandoned run posts no progress after the session changed',
      () async {
        final database = createTestDatabase();
        addTearDown(database.close);
        final config = await _saveAuthenticatedServer(database);
        final parked = await _parkedCheck(database, config);
        final postedWhileCurrent = parked.notifier.shown;

        await parked.changeSession(await _saveServer(database, 'bob'));
        final afterSignOut = parked.status;
        // The held progress update's trailing timer fires after the reset.
        await Future<void>.delayed(librarySyncProgressPublishInterval * 2);
        expect(afterSignOut, isNot(LibrarySyncStatus.running));
        expect(parked.status, afterSignOut);
        parked.release.complete(_succeeded);
        await parked.automatic;

        expect(postedWhileCurrent, greaterThan(0));
        expect(parked.notifier.shown, postedWhileCurrent);
        await parked.drain();
      },
      skip: !sqliteAvailable,
    );

    test(
      'an abandoned automatic check cannot reschedule the next session',
      () async {
        final database = createTestDatabase();
        addTearDown(database.close);
        final config = await _saveAuthenticatedServer(database);
        final parked = await _parkedCheck(database, config);

        final other = await _saveServer(database, 'bob');
        await parked.changeSession(other);
        final before = (await database.librarySyncDao.getOrCreateState(
          other.id!,
        )).nextAutomaticCheckAt;
        parked.release.complete(_succeeded);
        await parked.automatic;

        expect(
          (await database.librarySyncDao.getOrCreateState(other.id!))
              .nextAutomaticCheckAt,
          before,
        );
        await parked.drain();
      },
      skip: !sqliteAvailable,
    );

    test('a late cancelAndWait tail leaves the next session alone', () async {
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
      final release = Completer<LibrarySyncState>();
      final engine = StubLibrarySyncEngine((request, {onProgress}) async {
        if (request.isAutomatic) {
          entered.complete();
          return await release.future;
        }
        return const LibrarySyncState.idle();
      });
      final container = _container(
        engine,
        database: database,
        reachability: ServerReachabilityStatus.offline,
        interval: _hourlyInterval,
        serverConfig: [
          serverConfigStateProvider.overrideWith(
            (ref) => ref.watch(_serverConfigSource),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(_serverConfigSource.notifier).set(AsyncData(config));
      final controller = container.read(librarySyncControllerProvider.notifier);
      final automatic = controller.syncIfStale();
      await entered.future;

      // Sign-out abandons the pending cancel after its timeout, clears the
      // session, and another user signs in.
      final cancellation = controller.cancelAndWait();
      await Future<void>.delayed(Duration.zero);
      container.read(_serverConfigSource.notifier).set(const AsyncData(null));
      await container.pump();
      await database.serverDao.saveServer(
        ServerConfigTableCompanion.insert(
          url: 'https://other.example.com',
          username: 'bob',
          apiVersion: '1.16.1',
          isAuthenticated: const Value(true),
        ),
      );
      final other = (await database.serverDao.getActiveServer())!;
      container
          .read(_serverConfigSource.notifier)
          .set(
            AsyncData(
              ServerConfigModel(
                id: other.id,
                url: other.url,
                username: other.username,
                password: 'secret',
                apiVersion: other.apiVersion,
              ),
            ),
          );
      await container.pump();
      final before = container.read(librarySyncControllerProvider).status;

      release.complete(
        LibrarySyncState(
          status: LibrarySyncStatus.cancelled,
          stage: LibrarySyncStage.completed,
          completedAt: DateTime.now(),
        ),
      );
      await cancellation;
      await automatic;

      expect(before, isNot(LibrarySyncStatus.cancelled));
      expect(container.read(librarySyncControllerProvider).status, before);
    }, skip: !sqliteAvailable);

    test(
      'cancelAndWait drains and suppresses scheduled startup sync',
      () async {
        final database = createTestDatabase();
        addTearDown(database.close);
        await database.appSettingsDao.setLastFullSyncAppBuild(
          currentLibrarySyncModelVersion,
        );
        final startupResult = Completer<LibrarySyncState>();
        final engine = StubLibrarySyncEngine((request, {onProgress}) async {
          if (request.isAutomatic) {
            return await startupResult.future;
          }
          return _succeeded;
        });
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
        expect(engine.automaticRequests, [_automaticRequest]);
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
        expect(engine.automaticRequests, [_automaticRequest]);
      },
    );

    test('syncNow transitions through running to succeeded state', () async {
      final completer = Completer<LibrarySyncState>();
      final engine = StubLibrarySyncEngine((request, {onProgress}) async {
        if (request.isAutomatic) {
          return const LibrarySyncState(
            status: LibrarySyncStatus.skipped,
            stage: LibrarySyncStage.completed,
          );
        }
        onProgress?.call(
          LibrarySyncState(
            status: LibrarySyncStatus.running,
            stage: LibrarySyncStage.fetchingArtists,
            startedAt: DateTime.now(),
          ),
        );
        return await completer.future;
      });

      final container = _container(
        engine,
        reachability: ServerReachabilityStatus.checking,
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
      expect(engine.explicitCatalogRequests.last, _manualRequest);
    });

    test(
      'cancellation prevents a queued stronger repair from starting',
      () async {
        final active = Completer<LibrarySyncState>();
        final engine = StubLibrarySyncEngine((request, {onProgress}) async {
          if (request.isAutomatic) {
            return const LibrarySyncState.idle();
          }
          return await active.future;
        });
        final container = _container(
          engine,
          reachability: ServerReachabilityStatus.checking,
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
        expect(engine.explicitCatalogRequests, [_manualRequest]);
        // A subsequent explicit command is new intent and remains allowed.
        await controller.repairLibrary();
        expect(engine.explicitCatalogRequests, [
          _manualRequest,
          _repairRequest,
        ]);
      },
    );

    test('overlapping sync callers await one terminal result', () async {
      final completer = Completer<LibrarySyncState>();
      final engine = StubLibrarySyncEngine((request, {onProgress}) async {
        if (request.isAutomatic) {
          return const LibrarySyncState(
            status: LibrarySyncStatus.skipped,
            stage: LibrarySyncStage.completed,
          );
        }
        onProgress?.call(
          const LibrarySyncState(
            status: LibrarySyncStatus.running,
            stage: LibrarySyncStage.collectingCandidate,
          ),
        );
        return await completer.future;
      });
      final container = _container(
        engine,
        reachability: ServerReachabilityStatus.checking,
      );
      addTearDown(container.dispose);

      final notifier = container.read(librarySyncControllerProvider.notifier);
      final first = notifier.syncNow();
      final second = notifier.syncIfStale();
      await Future<void>.delayed(Duration.zero);

      expect(engine.explicitCatalogRequests, [_manualRequest]);
      expect(engine.automaticRequests, isEmpty);
      expect(container.read(librarySyncControllerProvider).isRunning, isTrue);

      final completed = _succeeded;
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
        final engine = StubLibrarySyncEngine((request, {onProgress}) async {
          if (request.isAutomatic) {
            return await automaticCompletion.future;
          }
          return manualResult;
        });
        final container = _container(
          engine,
          reachability: ServerReachabilityStatus.checking,
        );
        addTearDown(container.dispose);

        final notifier = container.read(librarySyncControllerProvider.notifier);
        final automatic = notifier.syncIfStale();
        final manual = notifier.syncNow();
        await Future<void>.delayed(Duration.zero);

        expect(engine.automaticRequests, [_automaticRequest]);
        expect(engine.explicitCatalogRequests, isEmpty);

        automaticCompletion.complete(
          const LibrarySyncState(
            status: LibrarySyncStatus.skipped,
            stage: LibrarySyncStage.completed,
          ),
        );
        await automatic;

        expect(await manual, same(manualResult));
        expect(engine.explicitCatalogRequests, [_manualRequest]);
        expect(
          container.read(librarySyncControllerProvider).planKind,
          LibrarySyncPlanKind.deltaReconcile,
        );
      },
    );

    test(
      'playlist refresh queues a fresh fetch after an in-flight request',
      () async {
        final gate = Completer<LibrarySyncState>();
        var reads = 0;
        final engine = StubLibrarySyncEngine((request, {onProgress}) async {
          if (request.target.kind == LibrarySyncTargetKind.playlistHeaders) {
            reads++;
            if (reads == 1) return await gate.future;
          }
          return const LibrarySyncState(
            status: LibrarySyncStatus.succeeded,
            stage: LibrarySyncStage.completed,
          );
        });
        final container = _container(
          engine,
          reachability: ServerReachabilityStatus.checking,
        );
        addTearDown(container.dispose);
        final subscription = container.listen(playlistSyncProvider, (_, _) {});
        addTearDown(subscription.close);
        final first = container.read(playlistSyncProvider.future);
        await Future<void>.delayed(Duration.zero);
        container.invalidate(playlistSyncProvider);
        final refreshed = container.read(playlistSyncProvider.future);
        expect(reads, 1);
        gate.complete(
          const LibrarySyncState(
            status: LibrarySyncStatus.succeeded,
            stage: LibrarySyncStage.completed,
          ),
        );
        await Future.wait([first, refreshed]);
        expect(reads, 2);
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
        final engine = StubLibrarySyncEngine((request, {onProgress}) async {
          if (request.target.kind != LibrarySyncTargetKind.catalog) {
            expect(request.target.kind, LibrarySyncTargetKind.album);
            targetRequests++;
            onProgress?.call(
              LibrarySyncState(
                status: LibrarySyncStatus.running,
                stage: LibrarySyncStage.fetchingSongs,
                planKind: LibrarySyncPlanKind.targetedHydration,
              ),
            );
            return await targetCompletion.future;
          }
          if (request.isAutomatic) {
            return const LibrarySyncState(
              status: LibrarySyncStatus.skipped,
              stage: LibrarySyncStage.completed,
            );
          }
          onProgress?.call(catalogResult);
          return catalogResult;
        });
        final container = _container(
          engine,
          reachability: ServerReachabilityStatus.checking,
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
        expect(engine.explicitCatalogRequests, [_manualRequest]);
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
        final engine = StubLibrarySyncEngine((request, {onProgress}) async {
          if (request.target.kind != LibrarySyncTargetKind.catalog) {
            expect(request.target.kind, LibrarySyncTargetKind.artist);
            requestedArtistIds.add(request.target.entityId!);
            return LibrarySyncState(
              status: LibrarySyncStatus.succeeded,
              stage: LibrarySyncStage.completed,
              completedAt: DateTime.now(),
            );
          }
          return const LibrarySyncState(
            status: LibrarySyncStatus.skipped,
            stage: LibrarySyncStage.completed,
          );
        });
        final container = _container(
          engine,
          database: database,
          reachability: ServerReachabilityStatus.checking,
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
        final engine = StubLibrarySyncEngine((request, {onProgress}) async {
          if (request.target.kind != LibrarySyncTargetKind.catalog) {
            requestedArtistIds.add(request.target.entityId!);
            return await nextResult();
          }
          return const LibrarySyncState(
            status: LibrarySyncStatus.skipped,
            stage: LibrarySyncStage.completed,
          );
        });
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
        final engine = StubLibrarySyncEngine((request, {onProgress}) async {
          if (request.target.kind != LibrarySyncTargetKind.catalog) {
            requestedArtistIds.add(request.target.entityId!);
            return await nextResult();
          }
          if (request.isAutomatic) {
            return const LibrarySyncState(
              status: LibrarySyncStatus.skipped,
              stage: LibrarySyncStage.completed,
            );
          }
          return LibrarySyncState(
            status: LibrarySyncStatus.succeeded,
            stage: LibrarySyncStage.completed,
            completedAt: DateTime.now(),
          );
        });
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
              () => StaticReachabilityController(
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

      group('a remote artist confirmed without albums', () {
        setUp(() async {
          await database.libraryDao.upsertProvisionalArtists([
            ArtistsTableCompanion.insert(
              id: 'ext-deezer-artist-1',
              name: 'Coldrain',
              albumCount: const Value(0),
              isExternal: const Value(true),
            ),
          ]);
        });

        test('is remembered, so a reopen needs no request', () async {
          final container = buildContainer();
          final controller = container.read(
            librarySyncControllerProvider.notifier,
          );
          expect(
            controller.artistConfirmedWithoutAlbums('ext-deezer-artist-1'),
            isFalse,
          );

          final first = await controller.hydrateOpenedArtist(
            'ext-deezer-artist-1',
          );
          expect(first?.status, LibrarySyncStatus.succeeded);
          expect(
            controller.artistConfirmedWithoutAlbums('ext-deezer-artist-1'),
            isTrue,
          );

          // Leaving and reopening: no second getArtist, and the page can
          // still show the artist as empty.
          expect(
            await controller.hydrateOpenedArtist('ext-deezer-artist-1'),
            isNull,
          );
          expect(requestedArtistIds, <String>['ext-deezer-artist-1']);
          expect(
            controller.artistConfirmedWithoutAlbums('ext-deezer-artist-1'),
            isTrue,
          );
        });

        test('is not remembered from a failed or partial hydration', () async {
          for (final status in <LibrarySyncStatus>[
            LibrarySyncStatus.failed,
            LibrarySyncStatus.partial,
          ]) {
            nextResult = () async => LibrarySyncState(
              status: status,
              stage: LibrarySyncStage.completed,
            );
            final container = buildContainer();
            final controller = container.read(
              librarySyncControllerProvider.notifier,
            );
            await controller.refreshArtist('ext-deezer-artist-1');
            expect(
              controller.artistConfirmedWithoutAlbums('ext-deezer-artist-1'),
              isFalse,
              reason: '$status',
            );
          }
        });

        test('a refresh that finds albums forgets it', () async {
          final container = buildContainer();
          final controller = container.read(
            librarySyncControllerProvider.notifier,
          );
          await controller.refreshArtist('ext-deezer-artist-1');
          expect(
            controller.artistConfirmedWithoutAlbums('ext-deezer-artist-1'),
            isTrue,
          );
          await database.libraryDao.upsertProvisionalAlbums([
            AlbumsTableCompanion.insert(
              id: 'ext-deezer-album-2',
              name: 'The Side Effects',
              artistId: const Value('ext-deezer-artist-1'),
              isExternal: const Value(true),
            ),
          ]);
          await controller.refreshArtist('ext-deezer-artist-1');
          expect(
            controller.artistConfirmedWithoutAlbums('ext-deezer-artist-1'),
            isFalse,
          );
        });

        test('a new server session forgets it', () async {
          final server = await _saveAuthenticatedServer(database);
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

          await controller.hydrateOpenedArtist('ext-deezer-artist-1');
          expect(
            controller.artistConfirmedWithoutAlbums('ext-deezer-artist-1'),
            isTrue,
          );
          container
              .read(_serverConfigSource.notifier)
              .set(const AsyncData(null));
          await settle();
          expect(
            controller.artistConfirmedWithoutAlbums('ext-deezer-artist-1'),
            isFalse,
          );
        });
      });
    });

    test(
      'forceFullSync becomes visibly preparing before engine planning',
      () async {
        final completer = Completer<LibrarySyncState>();
        final engine = StubLibrarySyncEngine((request, {onProgress}) async {
          if (request.isAutomatic) {
            return const LibrarySyncState(
              status: LibrarySyncStatus.skipped,
              stage: LibrarySyncStage.completed,
            );
          }
          return await ((request.intent == SyncRunIntent.repairLibrary)
              ? completer.future
              : const LibrarySyncState(
                  status: LibrarySyncStatus.succeeded,
                  stage: LibrarySyncStage.completed,
                  runRequestId: 12,
                  runAttemptId: 34,
                  apiRequests: 9,
                  endpointRequests: {'getAlbum': 9},
                  lastRunBytes: 1024,
                ));
        });
        final container = _container(
          engine,
          reachability: ServerReachabilityStatus.checking,
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
      final engine = StubLibrarySyncEngine((request, {onProgress}) async {
        if (request.isAutomatic) {
          return const LibrarySyncState(
            status: LibrarySyncStatus.skipped,
            stage: LibrarySyncStage.completed,
          );
        }
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
      });

      final container = _container(
        engine,
        reachability: ServerReachabilityStatus.checking,
      );
      addTearDown(container.dispose);

      await container.read(librarySyncControllerProvider.notifier).syncNow();

      final finalState = container.read(librarySyncControllerProvider);
      expect(finalState.status, LibrarySyncStatus.failed);
      expect(finalState.errorMessage, 'Sync failed.');
      expect(engine.explicitCatalogRequests.last, _manualRequest);
    });

    test(
      'startup sync retries when reachability moves offline to online',
      () async {
        final database = createTestDatabase();
        addTearDown(database.close);
        await database.appSettingsDao.setLastFullSyncAppBuild(
          currentLibrarySyncModelVersion,
        );
        final engine = StubLibrarySyncEngine.returning(_succeeded);
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
        expect(engine.automaticRequests, isEmpty);

        reachability.setStatus(ServerReachabilityStatus.online);
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(engine.automaticRequests, [_automaticRequest]);
      },
    );

    test(
      'sync model repair deferred on cellular runs when Wi-Fi returns',
      () async {
        final database = createTestDatabase();
        addTearDown(database.close);
        var networkType = NetworkType.cellular;
        final engine = StubLibrarySyncEngine((request, {onProgress}) async {
          if (request.isAutomatic) {
            return const LibrarySyncState(
              status: LibrarySyncStatus.skipped,
              stage: LibrarySyncStage.completed,
            );
          }
          return LibrarySyncState(
            status: LibrarySyncStatus.succeeded,
            stage: LibrarySyncStage.completed,
            completedAt: DateTime.now(),
          );
        });

        final container = _container(
          engine,
          database: database,
          server: _exampleServer,
          extra: [
            networkTypeProvider.overrideWith((ref) => networkType),
            requiredLibrarySyncModelVersionProvider.overrideWithValue(
              'model-v2',
            ),
          ],
        );
        addTearDown(container.dispose);

        container.read(librarySyncControllerProvider);
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(engine.automaticRequests, [_automaticRequest]);
        expect(engine.explicitCatalogRequests, isEmpty);
        expect(await database.appSettingsDao.getLastFullSyncAppBuild(), isNull);

        networkType = NetworkType.wifi;
        container.invalidate(networkTypeProvider);
        expect(container.read(networkTypeProvider), NetworkType.wifi);
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(engine.explicitCatalogRequests, [_repairRequest]);
        expect(engine.explicitCatalogRequests.single, _repairRequest);
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
        final engine = StubLibrarySyncEngine((request, {onProgress}) async {
          if (request.isAutomatic) {
            return const LibrarySyncState(
              status: LibrarySyncStatus.skipped,
              stage: LibrarySyncStage.completed,
            );
          }
          expect(request.intent, SyncRunIntent.repairLibrary);
          return LibrarySyncState(
            status: LibrarySyncStatus.partial,
            stage: LibrarySyncStage.completed,
            mode: LibrarySyncMode.forceFull,
            metadataReady: true,
            pendingHydrationCount: 1,
            completedAt: DateTime.now(),
          );
        });
        final container = _container(
          engine,
          database: database,
          server: _exampleServer,
          extra: [networkTypeProvider.overrideWithValue(NetworkType.wifi)],
        );
        addTearDown(container.dispose);

        container.read(librarySyncControllerProvider);
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(engine.explicitCatalogRequests, [_repairRequest]);
        expect(
          await database.appSettingsDao.getLastFullSyncAppBuild(),
          currentLibrarySyncModelVersion,
        );
      },
    );

    test('upgrading from the pre-genre sync model queues one full repair and '
        'keeps the cached library', () async {
      final database = createTestDatabase();
      addTearDown(database.close);
      // The model the previous release stamped: genres were not synced.
      await database.appSettingsDao.setLastFullSyncAppBuild('58');
      await database.libraryDao.upsertSongs([
        SongsTableCompanion.insert(id: 'kept', title: 'Kept'),
      ]);
      final engine = StubLibrarySyncEngine((request, {onProgress}) async {
        if (request.isAutomatic) {
          return const LibrarySyncState(
            status: LibrarySyncStatus.skipped,
            stage: LibrarySyncStage.completed,
          );
        }
        return LibrarySyncState(
          status: LibrarySyncStatus.succeeded,
          stage: LibrarySyncStage.completed,
          mode: LibrarySyncMode.forceFull,
          completedAt: DateTime.now(),
        );
      });
      final container = _container(
        engine,
        database: database,
        server: _exampleServer,
        extra: [networkTypeProvider.overrideWithValue(NetworkType.wifi)],
      );
      addTearDown(container.dispose);

      container.read(librarySyncControllerProvider);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(engine.explicitCatalogRequests, [_repairRequest]);
      expect(
        await database.appSettingsDao.getLastFullSyncAppBuild(),
        currentLibrarySyncModelVersion,
      );
      expect(await database.libraryDao.getSongById('kept'), isNotNull);
    });

    test(
      'upgrading from the previous sync model forces a full catalog repair',
      () async {
        final database = createTestDatabase();
        addTearDown(database.close);
        await database.appSettingsDao.setLastFullSyncAppBuild('56');
        final engine = StubLibrarySyncEngine((request, {onProgress}) async {
          if (request.isAutomatic) {
            return const LibrarySyncState(
              status: LibrarySyncStatus.skipped,
              stage: LibrarySyncStage.completed,
            );
          }
          return LibrarySyncState(
            status: LibrarySyncStatus.succeeded,
            stage: LibrarySyncStage.completed,
            mode: LibrarySyncMode.forceFull,
            completedAt: DateTime.now(),
          );
        });
        final container = _container(
          engine,
          database: database,
          server: _exampleServer,
          extra: [networkTypeProvider.overrideWithValue(NetworkType.wifi)],
        );
        addTearDown(container.dispose);

        container.read(librarySyncControllerProvider);
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(engine.explicitCatalogRequests, [_repairRequest]);
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
        final repairRequests = <LibrarySyncRequest>[];
        var forcedStatus = LibrarySyncStatus.failed;
        LibrarySyncEngine buildEngine() =>
            StubLibrarySyncEngine((request, {onProgress}) async {
              if (request.isAutomatic) {
                return const LibrarySyncState(
                  status: LibrarySyncStatus.skipped,
                  stage: LibrarySyncStage.completed,
                );
              }
              repairRequests.add(request);
              return LibrarySyncState(
                status: forcedStatus,
                stage: LibrarySyncStage.completed,
                mode: LibrarySyncMode.forceFull,
                completedAt: DateTime.now(),
              );
            });
        ProviderContainer buildContainer(LibrarySyncEngine engine) {
          return _container(
            engine,
            database: database,
            server: _exampleServer,
            extra: [networkTypeProvider.overrideWithValue(NetworkType.wifi)],
          );
        }

        // First launch: the forced repair fails (no promotion). The model
        // version must stay unstamped so a later run reconciles again.
        final failedContainer = buildContainer(buildEngine());
        addTearDown(failedContainer.dispose);
        failedContainer.read(librarySyncControllerProvider);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(repairRequests, [_repairRequest]);
        expect(await database.appSettingsDao.getLastFullSyncAppBuild(), '57');
        failedContainer.dispose();

        // Second launch (app restart): the reconciliation is resumable and
        // the version is stamped only once the repair promoted successfully.
        final recoveredContainer = buildContainer(buildEngine());
        addTearDown(recoveredContainer.dispose);
        forcedStatus = LibrarySyncStatus.succeeded;
        recoveredContainer.read(librarySyncControllerProvider);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(repairRequests, [_repairRequest, _repairRequest]);
        expect(
          await database.appSettingsDao.getLastFullSyncAppBuild(),
          currentLibrarySyncModelVersion,
        );
      },
      skip: !sqliteAvailable,
    );

    test('unauthenticated state does not trigger startup sync', () async {
      final engine = StubLibrarySyncEngine.returning(_succeeded);
      final container = _container(
        engine,
        reachability: ServerReachabilityStatus.checking,
      );
      addTearDown(container.dispose);

      container.read(librarySyncControllerProvider);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(engine.automaticRequests, isEmpty);
      expect(engine.explicitCatalogRequests, isEmpty);
    });

    test('sync does not auto-retry on resume after failure', () async {
      final binding = TestWidgetsFlutterBinding.ensureInitialized();
      // Mobile: `inactive` (app switcher, shade) backgrounds the app.
      debugDesktopRuntimeOverride = false;
      addTearDown(() => debugDesktopRuntimeOverride = null);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);

      var attempt = 0;
      final engine = StubLibrarySyncEngine((request, {onProgress}) async {
        if (request.isAutomatic) {
          return const LibrarySyncState(
            status: LibrarySyncStatus.skipped,
            stage: LibrarySyncStage.completed,
          );
        }
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
      });

      final container = _container(
        engine,
        reachability: ServerReachabilityStatus.checking,
      );
      addTearDown(() async {
        container.dispose();
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      });

      final future = container
          .read(librarySyncControllerProvider.notifier)
          .syncNow();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(engine.explicitCatalogRequests, [_manualRequest]);

      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await future;

      final finalState = container.read(librarySyncControllerProvider);
      expect(engine.explicitCatalogRequests, [_manualRequest]);
      expect(finalState.status, LibrarySyncStatus.failed);
    });

    group('foreground follows window visibility on desktop (#349)', () {
      final binding = TestWidgetsFlutterBinding.ensureInitialized();

      setUp(
        () => addTearDown(() {
          debugDesktopRuntimeOverride = null;
          binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        }),
      );

      test('foreground truth table', () {
        for (final state in <AppLifecycleState?>[
          null,
          ...AppLifecycleState.values,
        ]) {
          expect(
            librarySyncForegroundFor(state, desktop: false),
            state == null || state == AppLifecycleState.resumed,
            reason: 'mobile $state',
          );
          expect(
            librarySyncForegroundFor(state, desktop: true),
            state == null ||
                state == AppLifecycleState.resumed ||
                state == AppLifecycleState.inactive,
            reason: 'desktop $state',
          );
        }
      });

      Future<List<bool>> trace(
        List<AppLifecycleState> steps, {
        required bool desktop,
      }) async {
        debugDesktopRuntimeOverride = desktop;
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        final container = _container(
          StubLibrarySyncEngine.returning(_succeeded),
          reachability: ServerReachabilityStatus.checking,
        );
        addTearDown(container.dispose);
        container.read(librarySyncControllerProvider);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        final seen = <bool>[container.read(librarySyncForegroundProvider)];
        container.listen(
          librarySyncForegroundProvider,
          (_, next) => seen.add(next),
        );
        for (final step in steps) {
          binding.handleAppLifecycleStateChanged(step);
          await Future<void>.delayed(Duration.zero);
        }
        return seen;
      }

      test(
        'desktop: losing focus stays foreground, hiding backgrounds',
        () async {
          expect(
            await trace(desktop: true, [
              AppLifecycleState.inactive,
              AppLifecycleState.hidden,
              AppLifecycleState.inactive,
            ]),
            // Initial, hidden, shown again unfocused: one change each way.
            [true, false, true],
          );
        },
      );

      for (final (desktop, expected) in [(true, true), (false, false)]) {
        test('starting unfocused (inactive) with desktop=$desktop gives '
            'foreground=$expected', () async {
          debugDesktopRuntimeOverride = desktop;
          binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
          final container = _container(
            StubLibrarySyncEngine.returning(_succeeded),
            reachability: ServerReachabilityStatus.checking,
          );
          addTearDown(container.dispose);
          container.read(librarySyncControllerProvider);
          await Future<void>.delayed(const Duration(milliseconds: 10));

          expect(container.read(librarySyncForegroundProvider), expected);
        });
      }

      test('mobile: inactive still backgrounds', () async {
        expect(
          await trace(desktop: false, [
            AppLifecycleState.inactive,
            AppLifecycleState.resumed,
          ]),
          [true, false, true],
        );
      });
    });

    test('periodic sync pauses while backgrounded', () async {
      final binding = TestWidgetsFlutterBinding.ensureInitialized();
      // Mobile: `inactive` (app switcher, shade) backgrounds the app.
      debugDesktopRuntimeOverride = false;
      addTearDown(() => debugDesktopRuntimeOverride = null);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);

      final engine = StubLibrarySyncEngine((request, {onProgress}) async {
        if (request.isAutomatic) {
          return LibrarySyncState(
            status: LibrarySyncStatus.succeeded,
            stage: LibrarySyncStage.completed,
            completedAt: DateTime.now(),
          );
        }
        return _succeeded;
      });

      final container = ProviderContainer(
        overrides: [
          _shortSyncInterval,
          syncIntervalMinutesProvider.overrideWithValue(1),
          serverConfigStateProvider.overrideWithValue(const AsyncData(null)),
          serverReachabilityControllerProvider.overrideWith(
            () => StaticReachabilityController(
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

      expect(engine.automaticRequests, isEmpty);
    });

    test(
      'syncIfStale keeps a failed sync visible after a no-op pass',
      () async {
        var syncNowAttempts = 0;
        final engine = StubLibrarySyncEngine((request, {onProgress}) async {
          if (request.isAutomatic) {
            return const LibrarySyncState(
              status: LibrarySyncStatus.skipped,
              stage: LibrarySyncStage.completed,
            );
          }
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
        });
        final database = createTestDatabase();
        addTearDown(database.close);

        final container = _container(
          engine,
          database: database,
          server: _exampleServer,
          extra: [
            requiredLibrarySyncModelVersionProvider.overrideWithValue(null),
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
        expect(engine.automaticRequests, [_automaticRequest]);
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
        final engine = StubLibrarySyncEngine((request, {onProgress}) async {
          if (request.isAutomatic) {
            return const LibrarySyncState(
              status: LibrarySyncStatus.skipped,
              stage: LibrarySyncStage.completed,
            );
          }
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
        });
        final database = createTestDatabase();
        addTearDown(database.close);
        final container = _container(
          engine,
          database: database,
          server: _exampleServer,
          extra: [
            requiredLibrarySyncModelVersionProvider.overrideWithValue(null),
            networkTypeProvider.overrideWithValue(NetworkType.wifi),
          ],
        );
        addTearDown(container.dispose);

        final notifier = container.read(librarySyncControllerProvider.notifier);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await notifier.syncNow();
        await Future<void>.delayed(const Duration(milliseconds: 30));

        expect(engine.explicitCatalogRequests, [_manualRequest]);
        expect(
          container.read(librarySyncControllerProvider).freshness,
          LibrarySyncFreshness.verificationPending,
        );
      },
    );
  });
}
