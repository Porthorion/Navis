import 'package:connectivity_plus/connectivity_plus.dart';

/// Simplified network type used by streaming quality logic.
enum NetworkType {
  offline,
  wifi,
  cellular,
  other,
}

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
