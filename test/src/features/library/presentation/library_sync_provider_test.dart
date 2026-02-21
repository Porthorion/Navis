import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/domain/server_reachability.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/auth/presentation/server_reachability_provider.dart';
import 'package:navis/src/features/library/data/library_sync_engine.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';

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

class _FakeLibrarySyncEngine extends LibrarySyncEngine {
  _FakeLibrarySyncEngine(this._handlerIfStale, this._handlerNow);

  final Future<LibrarySyncState> Function({
    LibrarySyncProgressCallback? onProgress,
  })
  _handlerIfStale;
  final Future<LibrarySyncState> Function({
    bool forceFull,
    LibrarySyncProgressCallback? onProgress,
  })
  _handlerNow;

  int staleCalls = 0;
  int nowCalls = 0;
  final List<bool> forceFullCalls = <bool>[];

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
    bool forceFull = false,
    Iterable<String> priorityAlbumIds = const <String>[],
    LibrarySyncProgressCallback? onProgress,
  }) {
    nowCalls++;
    forceFullCalls.add(forceFull);
    return _handlerNow(forceFull: forceFull, onProgress: onProgress);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('librarySyncControllerProvider', () {
    test('startup trigger runs once when authenticated', () async {
      final engine = _FakeLibrarySyncEngine(
        ({
          LibrarySyncProgressCallback? onProgress,
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
          bool forceFull = false,
          LibrarySyncProgressCallback? onProgress,
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

    test('syncNow transitions through running to succeeded state', () async {
      final completer = Completer<LibrarySyncState>();
      final engine = _FakeLibrarySyncEngine(
        ({
          LibrarySyncProgressCallback? onProgress,
        }) async {
          return const LibrarySyncState(
            status: LibrarySyncStatus.skipped,
            stage: LibrarySyncStage.completed,
          );
        },
        ({
          bool forceFull = false,
          LibrarySyncProgressCallback? onProgress,
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

    test('syncNow transitions through running to failed state', () async {
      final engine = _FakeLibrarySyncEngine(
        ({
          LibrarySyncProgressCallback? onProgress,
        }) async {
          return const LibrarySyncState(
            status: LibrarySyncStatus.skipped,
            stage: LibrarySyncStage.completed,
          );
        },
        ({
          bool forceFull = false,
          LibrarySyncProgressCallback? onProgress,
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
        final engine = _FakeLibrarySyncEngine(
          ({
            LibrarySyncProgressCallback? onProgress,
          }) async {
            return const LibrarySyncState(
              status: LibrarySyncStatus.succeeded,
              stage: LibrarySyncStage.completed,
            );
          },
          ({
            bool forceFull = false,
            LibrarySyncProgressCallback? onProgress,
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

    test('unauthenticated state does not trigger startup sync', () async {
      final engine = _FakeLibrarySyncEngine(
        ({
          LibrarySyncProgressCallback? onProgress,
        }) async {
          return const LibrarySyncState(
            status: LibrarySyncStatus.succeeded,
            stage: LibrarySyncStage.completed,
          );
        },
        ({
          bool forceFull = false,
          LibrarySyncProgressCallback? onProgress,
        }) async {
          return const LibrarySyncState(
            status: LibrarySyncStatus.succeeded,
            stage: LibrarySyncStage.completed,
          );
        },
      );
      final container = ProviderContainer(
        overrides: [
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
          LibrarySyncProgressCallback? onProgress,
        }) async {
          return const LibrarySyncState(
            status: LibrarySyncStatus.skipped,
            stage: LibrarySyncStage.completed,
          );
        },
        ({
          bool forceFull = false,
          LibrarySyncProgressCallback? onProgress,
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
  });
}
