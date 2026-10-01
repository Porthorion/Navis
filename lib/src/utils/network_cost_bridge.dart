import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Reads whether the active network is billed/metered from platform APIs.
///
/// Returns `null` when the platform cannot report metering (desktop fallbacks
/// and unsupported builds). Callers combine this with [NetworkType].
class NetworkCostBridge {
  new({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('com.navis.app/network_cost');

  final MethodChannel _channel;

  /// Returns `true` when the OS reports a metered/expensive path, `false`
  /// when unmetered, and `null` when unavailable.
  Future<bool?> isActiveNetworkMetered() async {
    if (kIsWeb) {
      return null;
    }
    try {
      final value = await _channel.invokeMethod<Object?>(
        'isActiveNetworkMetered',
      );
      if (value is bool) {
        return value;
      }
      return null;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}
