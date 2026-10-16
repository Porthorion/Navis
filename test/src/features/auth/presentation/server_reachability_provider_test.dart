import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/domain/server_reachability.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/auth/presentation/server_reachability_provider.dart';
import 'package:navis/src/providers/app_providers.dart';

class _AuthStateController extends Notifier<AsyncValue<ServerConfigModel?>> {
  new(this._initialState);

  final AsyncValue<ServerConfigModel?> _initialState;

  @override
  AsyncValue<ServerConfigModel?> build() => _initialState;
}

class _Flag extends Notifier<bool> {
  @override
  bool build() => false;

  void set() => state = true;
}

void main() {
  const authenticatedConfig = ServerConfigModel(
    url: 'https://example.com',
    username: 'alice',
    password: 'secret',
    apiVersion: '1.16.1',
  );

  group('false offline regressions', () {
    ProviderContainer createContainer(PingServer Function() readPing) {
      final container = ProviderContainer(
        overrides: [
          serverConfigStateProvider.overrideWithValue(
            const AsyncData(authenticatedConfig),
          ),
          connectivityProvider.overrideWith((_) => const Stream.empty()),
          pingServerProvider.overrideWith((_) => readPing()),
        ],
      );
      addTearDown(container.dispose);
      container.listen(serverReachabilityControllerProvider, (_, _) {});
      return container;
    }

    test('replaced-client failure rechecks immediately and stays online', () {
      fakeAsync((async) {
        final retiredPing = Completer<String>();
        var calls = 0;
        var ping = () async => 'ready';
        final container = createContainer(() => ping);
        async.flushMicrotasks();
        final statuses = <ServerReachabilityStatus>[];
        container.listen(serverReachabilityControllerProvider, (_, next) {
          statuses.add(next.status);
        });
        ping = () => retiredPing.future;
        container.invalidate(pingServerProvider);
        final check = container
            .read(serverReachabilityControllerProvider.notifier)
            .retryNow();
        var finished = false;
        unawaited(check.then((_) => finished = true));
        final currentPing = Completer<String>();
        ping = () {
          calls++;
          return currentPing.future;
        };
        container.invalidate(pingServerProvider);
        retiredPing.completeError(const SubsonicConnectionException('closed'));
        async.flushMicrotasks();
        expect(calls, 1);
        expect(
          finished,
          isFalse,
          reason: 'retryNow joins the replacement probe',
        );
        expect(statuses, isNot(contains(ServerReachabilityStatus.offline)));
        currentPing.complete('ready');
        async.flushMicrotasks();
        expect(finished, isTrue);
        final state = container.read(serverReachabilityControllerProvider);
        expect(state.status, ServerReachabilityStatus.online);
        expect(state.consecutiveFailureCount, 0);
        async.elapse(Duration.zero);
        expect(async.pendingTimers, isEmpty);
      });
    });

    test(
      'repeated client replacement has one immediate follow-up, then waits',
      () {
        fakeAsync((async) {
          final first = Completer<String>();
          final second = Completer<String>();
          var ping = () => first.future;
          final container = createContainer(() => ping);
          async.flushMicrotasks();
          ping = () => second.future;
          container.invalidate(pingServerProvider);
          first.completeError(const SubsonicConnectionException('closed'));
          async.flushMicrotasks();
          var currentCalls = 0;
          ping = () async {
            currentCalls++;
            return 'ready';
          };
          container.invalidate(pingServerProvider);
          second.completeError(
            const SubsonicConnectionException('closed again'),
          );
          async.flushMicrotasks();
          expect(
            currentCalls,
            0,
            reason: 'no unbounded immediate replacement loop',
          );
          expect(
            container
                .read(serverReachabilityControllerProvider)
                .consecutiveFailureCount,
            0,
          );
          async.elapse(const Duration(seconds: 3));
          expect(currentCalls, 1);
          expect(
            container.read(serverReachabilityControllerProvider).status,
            ServerReachabilityStatus.online,
          );
        });
      },
    );

    test(
      'connectivity checks preserve a confirmed outage and its retry budget',
      () {
        fakeAsync((async) {
          final connectivity = StreamController<List<ConnectivityResult>>();
          final gate = Completer<String>();
          var gated = false;
          final container = ProviderContainer(
            overrides: [
              serverConfigStateProvider.overrideWithValue(
                const AsyncData(authenticatedConfig),
              ),
              connectivityProvider.overrideWith((_) => connectivity.stream),
              pingServerProvider.overrideWithValue(() async {
                if (gated) return await gate.future;
                throw const SubsonicConnectionException('down');
              }),
            ],
          );
          addTearDown(() {
            container.dispose();
            unawaited(connectivity.close());
          });
          container.listen(serverReachabilityControllerProvider, (_, _) {});
          async.flushMicrotasks();
          async.elapse(const Duration(seconds: 93));
          expect(
            container
                .read(serverReachabilityControllerProvider)
                .showRetryBanner,
            isFalse,
          );
          gated = true;
          connectivity.add([ConnectivityResult.wifi]);
          async.flushMicrotasks();
          var state = container.read(serverReachabilityControllerProvider);
          expect(state.status, ServerReachabilityStatus.offline);
          expect(state.showRetryBanner, isFalse);
          expect(state.consecutiveFailureCount, 4);
          gate.completeError(const SubsonicConnectionException('still down'));
          async.flushMicrotasks();
          state = container.read(serverReachabilityControllerProvider);
          expect(state.status, ServerReachabilityStatus.offline);
          expect(state.consecutiveFailureCount, 5);
          expect(state.showRetryBanner, isFalse);
        });
      },
    );

    for (final initiallyOnline in [false, true]) {
      test('one transient failure stays checking then recovers after 3 seconds '
          '(initially online: $initiallyOnline)', () {
        fakeAsync((async) {
          var calls = 0;
          var fail = !initiallyOnline;
          final container = createContainer(
            () => () async {
              calls++;
              if (fail) throw const SubsonicConnectionException('transient');
              return 'ready';
            },
          );
          async.flushMicrotasks();
          if (initiallyOnline) {
            fail = true;
            unawaited(
              container
                  .read(serverReachabilityControllerProvider.notifier)
                  .retryNow(),
            );
            async.flushMicrotasks();
          }
          final state = container.read(serverReachabilityControllerProvider);
          expect(state.status, ServerReachabilityStatus.checking);
          expect(state.consecutiveFailureCount, 0);
          final callsBeforeRetry = calls;
          fail = false;
          async.elapse(const Duration(milliseconds: 2999));
          expect(calls, callsBeforeRetry);
          async.elapse(const Duration(milliseconds: 1));
          expect(calls, callsBeforeRetry + 1);
          expect(
            container.read(serverReachabilityControllerProvider).status,
            ServerReachabilityStatus.online,
          );
          expect(async.pendingTimers, isEmpty);
        });
      });
    }

    test(
      'real outage is confirmed by second probe; visible retries start there',
      () {
        fakeAsync((async) {
          var calls = 0;
          final container = createContainer(
            () => () async {
              calls++;
              throw const SubsonicConnectionException('down');
            },
          );
          async.flushMicrotasks();
          expect(
            container.read(serverReachabilityControllerProvider).status,
            ServerReachabilityStatus.checking,
          );
          async.elapse(const Duration(seconds: 3));
          var state = container.read(serverReachabilityControllerProvider);
          expect(calls, 2);
          expect(state.status, ServerReachabilityStatus.offline);
          expect(state.consecutiveFailureCount, 1);
          expect(state.showRetryBanner, isTrue);
          async.elapse(const Duration(seconds: 60));
          state = container.read(serverReachabilityControllerProvider);
          expect(calls, 4);
          expect(state.consecutiveFailureCount, 3);
          expect(state.showRetryBanner, isTrue);
          async.elapse(const Duration(seconds: 30));
          state = container.read(serverReachabilityControllerProvider);
          expect(state.consecutiveFailureCount, 4);
          expect(state.showRetryBanner, isFalse);
          container.dispose();
        });
      },
    );

    test(
      'a manual retry consumes the quick retry without leaving another timer',
      () {
        fakeAsync((async) {
          var calls = 0;
          var fail = true;
          final container = createContainer(
            () => () async {
              calls++;
              if (fail) throw const SubsonicConnectionException('down');
              return 'ready';
            },
          );
          async.flushMicrotasks();
          fail = false;
          unawaited(
            container
                .read(serverReachabilityControllerProvider.notifier)
                .retryNow(),
          );
          async.flushMicrotasks();
          async.elapse(const Duration(seconds: 31));
          expect(calls, 2);
          expect(
            container.read(serverReachabilityControllerProvider).status,
            ServerReachabilityStatus.online,
          );
          expect(async.pendingTimers, isEmpty);
        });
      },
    );
  });

  test('checks reachability on startup and becomes online', () async {
    final authStateProvider =
        NotifierProvider<_AuthStateController, AsyncValue<ServerConfigModel?>>(
          () => _AuthStateController(const AsyncData(authenticatedConfig)),
        );
    final connectivityController = StreamController<List<ConnectivityResult>>();
    var pingCalls = 0;

    final container = ProviderContainer(
      overrides: [
        serverConfigStateProvider.overrideWith((ref) {
          return ref.watch(authStateProvider);
        }),
        connectivityProvider.overrideWith((ref) {
          return connectivityController.stream;
        }),
        pingServerProvider.overrideWithValue(() async {
          pingCalls++;
          return '1.16.1';
        }),
      ],
    );

    expect(
      container.read(serverReachabilityControllerProvider).status,
      ServerReachabilityStatus.checking,
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));

    final state = container.read(serverReachabilityControllerProvider);
    expect(state.status, ServerReachabilityStatus.online);
    expect(pingCalls, 1);
    expect(state.lastOnlineAt, isNotNull);

    container.dispose();
    await connectivityController.close();
  });

  test('checks as soon as the session client exists, without reporting '
      'the server unreachable meanwhile', () async {
    final authStateProvider =
        NotifierProvider<_AuthStateController, AsyncValue<ServerConfigModel?>>(
          () => _AuthStateController(const AsyncData(authenticatedConfig)),
        );
    final connectivityController = StreamController<List<ConnectivityResult>>();
    final clientReady = NotifierProvider<_Flag, bool>(_Flag.new);
    var pingCalls = 0;
    final container = ProviderContainer(
      overrides: [
        serverConfigStateProvider.overrideWith((ref) {
          return ref.watch(authStateProvider);
        }),
        connectivityProvider.overrideWith((ref) {
          return connectivityController.stream;
        }),
        reachabilityRetryIntervalProvider.overrideWithValue(
          const Duration(minutes: 5),
        ),
        pingServerProvider.overrideWith((ref) {
          if (!ref.watch(clientReady)) return null;
          return () async {
            pingCalls++;
            return '1.16.1';
          };
        }),
      ],
    );
    final subscription = container.listen(
      serverReachabilityControllerProvider,
      (_, _) {},
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(subscription.read().status, ServerReachabilityStatus.checking);
    expect(pingCalls, 0);

    container.read(clientReady.notifier).set();
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(subscription.read().status, ServerReachabilityStatus.online);
    expect(pingCalls, 1);
    subscription.close();
    container.dispose();
    await connectivityController.close();
  });

  test('retryNow recovers without waiting for the retry timer and joins a '
      'running check', () async {
    final authStateProvider =
        NotifierProvider<_AuthStateController, AsyncValue<ServerConfigModel?>>(
          () => _AuthStateController(const AsyncData(authenticatedConfig)),
        );
    final connectivityController = StreamController<List<ConnectivityResult>>();
    var serverUp = false;
    var pingCalls = 0;
    Completer<void>? pingGate;
    final container = ProviderContainer(
      overrides: [
        serverConfigStateProvider.overrideWith((ref) {
          return ref.watch(authStateProvider);
        }),
        connectivityProvider.overrideWith((ref) {
          return connectivityController.stream;
        }),
        reachabilityRetryIntervalProvider.overrideWithValue(
          const Duration(minutes: 5),
        ),
        pingServerProvider.overrideWithValue(() async {
          pingCalls++;
          await pingGate?.future;
          if (!serverUp) {
            throw const SubsonicConnectionException('down');
          }
          return '1.16.1';
        }),
      ],
    );
    final subscription = container.listen(
      serverReachabilityControllerProvider,
      (_, _) {},
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(subscription.read().status, ServerReachabilityStatus.checking);
    await container
        .read(serverReachabilityControllerProvider.notifier)
        .retryNow();
    expect(subscription.read().status, ServerReachabilityStatus.offline);
    expect(pingCalls, 2);

    serverUp = true;
    pingGate = Completer<void>();
    final controller = container.read(
      serverReachabilityControllerProvider.notifier,
    );
    final first = controller.retryNow();
    final second = controller.retryNow();
    await Future<void>.delayed(Duration.zero);
    // The banner stays up while the retry runs.
    expect(subscription.read().status, ServerReachabilityStatus.offline);

    pingGate.complete();
    await Future.wait(<Future<void>>[first, second]);

    expect(subscription.read().status, ServerReachabilityStatus.online);
    expect(pingCalls, 3);
    subscription.close();
    container.dispose();
    await connectivityController.close();
  });

  test('transitions offline and retries every configured interval', () async {
    final authStateProvider =
        NotifierProvider<_AuthStateController, AsyncValue<ServerConfigModel?>>(
          () => _AuthStateController(const AsyncData(authenticatedConfig)),
        );
    final connectivityController = StreamController<List<ConnectivityResult>>();
    var pingCalls = 0;

    final container = ProviderContainer(
      overrides: [
        serverConfigStateProvider.overrideWith((ref) {
          return ref.watch(authStateProvider);
        }),
        connectivityProvider.overrideWith((ref) {
          return connectivityController.stream;
        }),
        reachabilityRetryIntervalProvider.overrideWithValue(
          const Duration(milliseconds: 20),
        ),
        pingServerProvider.overrideWithValue(() async {
          pingCalls++;
          if (pingCalls <= 2) {
            throw const SubsonicConnectionException('offline');
          }
          return '1.16.1';
        }),
      ],
    );

    container.read(serverReachabilityControllerProvider);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await container
        .read(serverReachabilityControllerProvider.notifier)
        .retryNow();
    expect(
      container.read(serverReachabilityControllerProvider).status,
      ServerReachabilityStatus.offline,
    );

    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(
      container.read(serverReachabilityControllerProvider).status,
      ServerReachabilityStatus.online,
    );
    expect(pingCalls, greaterThanOrEqualTo(2));

    container.dispose();
    await connectivityController.close();
  });

  test('hides visible retry banner after repeated failures', () async {
    final authStateProvider =
        NotifierProvider<_AuthStateController, AsyncValue<ServerConfigModel?>>(
          () => _AuthStateController(const AsyncData(authenticatedConfig)),
        );
    final connectivityController = StreamController<List<ConnectivityResult>>();
    var pingCalls = 0;

    final container = ProviderContainer(
      overrides: [
        serverConfigStateProvider.overrideWith((ref) {
          return ref.watch(authStateProvider);
        }),
        connectivityProvider.overrideWith((ref) {
          return connectivityController.stream;
        }),
        reachabilityRetryIntervalProvider.overrideWithValue(
          const Duration(milliseconds: 10),
        ),
        pingServerProvider.overrideWithValue(() async {
          pingCalls++;
          throw const SubsonicConnectionException('offline');
        }),
      ],
    );

    container.read(serverReachabilityControllerProvider);
    await Future<void>.delayed(Duration.zero);
    await container
        .read(serverReachabilityControllerProvider.notifier)
        .retryNow();
    await Future<void>.delayed(const Duration(milliseconds: 45));

    final state = container.read(serverReachabilityControllerProvider);
    expect(state.status, ServerReachabilityStatus.offline);
    expect(pingCalls, greaterThan(3));
    expect(state.consecutiveFailureCount, greaterThan(3));
    expect(state.showRetryBanner, isFalse);

    container.dispose();
    await connectivityController.close();
  });

  test(
    'connectivity changes trigger re-check but do not set status directly',
    () async {
      final authStateProvider =
          NotifierProvider<
            _AuthStateController,
            AsyncValue<ServerConfigModel?>
          >(() => _AuthStateController(const AsyncData(authenticatedConfig)));
      final connectivityController =
          StreamController<List<ConnectivityResult>>();
      var pingCalls = 0;

      final container = ProviderContainer(
        overrides: [
          serverConfigStateProvider.overrideWith((ref) {
            return ref.watch(authStateProvider);
          }),
          connectivityProvider.overrideWith((ref) {
            return connectivityController.stream;
          }),
          pingServerProvider.overrideWithValue(() async {
            pingCalls++;
            return '1.16.1';
          }),
        ],
      );

      container.read(serverReachabilityControllerProvider);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(pingCalls, 1);

      connectivityController.add(const <ConnectivityResult>[
        ConnectivityResult.wifi,
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      connectivityController.add(const <ConnectivityResult>[
        ConnectivityResult.mobile,
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(pingCalls, greaterThanOrEqualTo(1));
      expect(
        container.read(serverReachabilityControllerProvider).status,
        ServerReachabilityStatus.online,
      );

      container.dispose();
      await connectivityController.close();
    },
  );

  test('stops retrying after session becomes unauthenticated', () async {
    final authStateProvider =
        NotifierProvider<_AuthStateController, AsyncValue<ServerConfigModel?>>(
          () => _AuthStateController(const AsyncData(authenticatedConfig)),
        );
    final connectivityController = StreamController<List<ConnectivityResult>>();
    var pingCalls = 0;

    final container = ProviderContainer(
      overrides: [
        serverConfigStateProvider.overrideWith((ref) {
          return ref.watch(authStateProvider);
        }),
        connectivityProvider.overrideWith((ref) {
          return connectivityController.stream;
        }),
        reachabilityRetryIntervalProvider.overrideWithValue(
          const Duration(milliseconds: 20),
        ),
        pingServerProvider.overrideWithValue(() async {
          pingCalls++;
          throw const SubsonicConnectionException('offline');
        }),
      ],
    );

    container.read(serverReachabilityControllerProvider);
    await Future<void>.delayed(Duration.zero);
    await container
        .read(serverReachabilityControllerProvider.notifier)
        .retryNow();
    await Future<void>.delayed(const Duration(milliseconds: 35));
    expect(
      container.read(serverReachabilityControllerProvider).status,
      ServerReachabilityStatus.offline,
    );
    expect(pingCalls, greaterThanOrEqualTo(1));

    container.read(authStateProvider.notifier).state =
        const AsyncData<ServerConfigModel?>(null);
    await Future<void>.delayed(const Duration(milliseconds: 5));

    final callsAfterSignOut = pingCalls;
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(
      container.read(serverReachabilityControllerProvider).status,
      isNot(ServerReachabilityStatus.online),
    );
    expect(pingCalls, callsAfterSignOut);

    container.dispose();
    await connectivityController.close();
  });
}
