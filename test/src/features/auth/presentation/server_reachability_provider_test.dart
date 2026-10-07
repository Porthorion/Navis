import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
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
    expect(subscription.read().status, ServerReachabilityStatus.offline);
    expect(pingCalls, 1);

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
    expect(pingCalls, 2);
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
          if (pingCalls == 1) {
            throw const SubsonicConnectionException('offline');
          }
          return '1.16.1';
        }),
      ],
    );

    container.read(serverReachabilityControllerProvider);
    await Future<void>.delayed(const Duration(milliseconds: 10));
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
