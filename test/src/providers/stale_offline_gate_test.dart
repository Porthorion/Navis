import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/auth/presentation/server_reachability_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/connectivity.dart';

const _config = ServerConfigModel(
  id: 1,
  url: 'https://fixture.invalid',
  username: 'fixture',
  password: 'synthetic',
  apiVersion: '1.16.1',
);

void main() {
  late List<ConnectivityResult> platform;
  late int pings;
  late int reads;
  late ProviderContainer container;

  ProviderContainer build({required bool serverUp}) {
    container = ProviderContainer(
      overrides: [
        serverConfigStateProvider.overrideWithValue(const AsyncData(_config)),
        connectivityProvider.overrideWith((_) {
          reads++;
          return Stream.value(platform);
        }),
        pingServerProvider.overrideWithValue(() async {
          pings++;
          if (!serverUp) throw Exception('down');
          return 'ok';
        }),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  setUp(() {
    platform = const [ConnectivityResult.none];
    pings = 0;
    reads = 0;
  });

  Future<void> settle() => Future<void>.delayed(const Duration(seconds: 1));

  test('a stale offline read is re-read once, not in a ping loop', () async {
    final c = build(serverUp: true);
    c.listen(connectivityProvider, (_, _) {});
    c.read(serverReachabilityControllerProvider);
    final heal = Provider<void>(healStaleOfflineConnectivity);
    c.read(heal);
    await settle();
    expect(pings, lessThanOrEqualTo(3));
    expect(reads, lessThanOrEqualTo(3));
  });

  test('the re-read heals a stale offline read and stops', () async {
    final c = build(serverUp: true);
    c.listen(connectivityProvider, (_, _) {});
    c.read(serverReachabilityControllerProvider);
    c.read(Provider<void>(healStaleOfflineConnectivity));
    platform = const [ConnectivityResult.wifi];
    await settle();
    expect(c.read(networkTypeProvider), NetworkType.wifi);
    expect(pings, lessThanOrEqualTo(3));
  });

  group('canStreamProvider wiring', () {
    test('offline connectivity + reachable server streams', () async {
      final c = build(serverUp: true);
      c.listen(connectivityProvider, (_, _) {});
      c.listen(serverReachabilityControllerProvider, (_, _) {});
      await settle();
      expect(c.read(networkTypeProvider), NetworkType.offline);
      expect(c.read(canStreamProvider)(), isTrue);
    });

    test('offline connectivity + unreachable server refuses', () async {
      final c = build(serverUp: false);
      c.listen(connectivityProvider, (_, _) {});
      c.listen(serverReachabilityControllerProvider, (_, _) {});
      await settle();
      expect(c.read(canStreamProvider)(), isFalse);
    });
  });
}
