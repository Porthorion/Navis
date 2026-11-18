import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/auth/domain/server_reachability.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/connectivity.dart';

void main() {
  const online = ServerReachabilityStatus.online;
  const down = ServerReachabilityStatus.offline;

  test('connectivity offline but server reachable still streams', () {
    expect(
      resolveCanStream(
        networkType: NetworkType.offline,
        reachability: online,
        diagnosticsOverride: null,
      ),
      isTrue,
    );
  });

  test('connectivity offline and server unreachable refuses streams', () {
    for (final status in [down, ServerReachabilityStatus.checking]) {
      expect(
        resolveCanStream(
          networkType: NetworkType.offline,
          reachability: status,
          diagnosticsOverride: null,
        ),
        isFalse,
      );
    }
  });

  test('connected devices stream whatever the reachability says', () {
    expect(
      resolveCanStream(
        networkType: NetworkType.wifi,
        reachability: down,
        diagnosticsOverride: null,
      ),
      isTrue,
    );
  });

  test('the diagnostics offline override beats a reachable server', () {
    expect(
      resolveCanStream(
        networkType: NetworkType.offline,
        reachability: online,
        diagnosticsOverride: NetworkType.offline,
      ),
      isFalse,
    );
  });
}
