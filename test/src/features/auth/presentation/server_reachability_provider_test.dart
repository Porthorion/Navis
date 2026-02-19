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
  _AuthStateController(this._initialState);

  final AsyncValue<ServerConfigModel?> _initialState;

  @override
  AsyncValue<ServerConfigModel?> build() => _initialState;
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
