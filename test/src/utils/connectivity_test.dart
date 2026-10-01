import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/utils/connectivity.dart';

void main() {
  group('resolveNetworkType', () {
    test('maps empty and none to offline', () {
      expect(
        resolveNetworkType(const <ConnectivityResult>[]),
        NetworkType.offline,
      );
      expect(
        resolveNetworkType(const <ConnectivityResult>[ConnectivityResult.none]),
        NetworkType.offline,
      );
    });

    test('maps wifi and ethernet to wifi', () {
      expect(
        resolveNetworkType(const <ConnectivityResult>[ConnectivityResult.wifi]),
        NetworkType.wifi,
      );
      expect(
        resolveNetworkType(const <ConnectivityResult>[
          ConnectivityResult.ethernet,
        ]),
        NetworkType.wifi,
      );
    });

    test('maps mobile to cellular', () {
      expect(
        resolveNetworkType(const <ConnectivityResult>[
          ConnectivityResult.mobile,
        ]),
        NetworkType.cellular,
      );
    });

    test('maps remaining transports to other', () {
      expect(
        resolveNetworkType(const <ConnectivityResult>[ConnectivityResult.vpn]),
        NetworkType.other,
      );
    });
  });

  group('resolveSyncNetworkPolicy', () {
    test('cellular is always metered and restricts background sync', () {
      final policy = resolveSyncNetworkPolicy(
        networkType: NetworkType.cellular,
        nativeMetered: false,
        backgroundSyncUnmeteredOnly: true,
      );
      expect(policy.networkType, NetworkType.cellular);
      expect(policy.isMetered, isTrue);
      expect(policy.allowsBackgroundSync, isFalse);
      expect(policy.allowsHardProbe, isTrue);
      expect(policy.allowsInteractiveHydration, isTrue);
    });

    test('wifi without native metering is unmetered', () {
      final policy = resolveSyncNetworkPolicy(
        networkType: NetworkType.wifi,
        nativeMetered: null,
        backgroundSyncUnmeteredOnly: true,
      );
      expect(policy.isMetered, isFalse);
      expect(policy.allowsBackgroundSync, isTrue);
    });

    test('wifi reported metered by native APIs restricts background sync', () {
      final policy = resolveSyncNetworkPolicy(
        networkType: NetworkType.wifi,
        nativeMetered: true,
        backgroundSyncUnmeteredOnly: true,
      );
      expect(policy.isMetered, isTrue);
      expect(policy.allowsBackgroundSync, isFalse);
      expect(policy.allowsHardProbe, isTrue);
    });

    test('other transports are treated conservatively as metered', () {
      final policy = resolveSyncNetworkPolicy(
        networkType: NetworkType.other,
        nativeMetered: null,
        backgroundSyncUnmeteredOnly: true,
      );
      expect(policy.isMetered, isTrue);
      expect(policy.allowsBackgroundSync, isFalse);
    });

    test('unmetered-only setting can be disabled', () {
      final policy = resolveSyncNetworkPolicy(
        networkType: NetworkType.cellular,
        nativeMetered: true,
        backgroundSyncUnmeteredOnly: false,
      );
      expect(policy.isMetered, isTrue);
      expect(policy.allowsBackgroundSync, isTrue);
    });

    test('offline never allows sync work', () {
      final policy = resolveSyncNetworkPolicy(
        networkType: NetworkType.offline,
        nativeMetered: null,
        backgroundSyncUnmeteredOnly: true,
      );
      expect(policy.allowsBackgroundSync, isFalse);
      expect(policy.allowsHardProbe, isFalse);
      expect(policy.allowsInteractiveHydration, isFalse);
    });
  });
}
