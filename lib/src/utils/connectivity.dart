import 'package:connectivity_plus/connectivity_plus.dart';

/// One coalesced network check: whether the device has any connection, and
/// whether the Navidrome server answered.
typedef NetworkReconciliation = ({bool connected, bool serverReachable});

/// Simplified network type used by streaming quality logic.
enum NetworkType { offline, wifi, cellular, other }

NetworkType resolveNetworkType(List<ConnectivityResult> results) {
  if (results.isEmpty || results.contains(ConnectivityResult.none)) {
    return NetworkType.offline;
  }

  if (results.contains(ConnectivityResult.wifi) ||
      results.contains(ConnectivityResult.ethernet)) {
    return NetworkType.wifi;
  }

  if (results.contains(ConnectivityResult.mobile)) {
    return NetworkType.cellular;
  }

  return NetworkType.other;
}

/// Cost-aware policy used by library sync scheduling and execution.
class SyncNetworkPolicy {
  const new({
    required this.networkType,
    required this.isMetered,
    required this.allowsBackgroundSync,
    required this.allowsHardProbe,
    required this.allowsInteractiveHydration,
  });

  final NetworkType networkType;
  final bool isMetered;
  final bool allowsBackgroundSync;
  final bool allowsHardProbe;
  final bool allowsInteractiveHydration;

  bool get isOffline => networkType == NetworkType.offline;
}

/// Resolves sync-safe network policy from interface type and optional native
/// metering.
///
/// Cellular is always metered. Wi-Fi/Ethernet trust a native metered signal
/// when available and otherwise default to unmetered on desktop-like
/// transports. Unknown transports are conservative.
SyncNetworkPolicy resolveSyncNetworkPolicy({
  required NetworkType networkType,
  required bool? nativeMetered,
  required bool backgroundSyncUnmeteredOnly,
}) {
  if (networkType == NetworkType.offline) {
    return const SyncNetworkPolicy(
      networkType: NetworkType.offline,
      isMetered: false,
      allowsBackgroundSync: false,
      allowsHardProbe: false,
      allowsInteractiveHydration: false,
    );
  }

  final isMetered = switch (networkType) {
    NetworkType.cellular => true,
    NetworkType.wifi => nativeMetered ?? false,
    NetworkType.other => nativeMetered ?? true,
    NetworkType.offline => false,
  };
  final allowsBackground = !backgroundSyncUnmeteredOnly || !isMetered;
  return SyncNetworkPolicy(
    networkType: networkType,
    isMetered: isMetered,
    allowsBackgroundSync: allowsBackground,
    allowsHardProbe: true,
    allowsInteractiveHydration: true,
  );
}
