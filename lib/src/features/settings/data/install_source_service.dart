import 'dart:io';

import 'package:flutter/services.dart';

/// Android install-source details reported by the platform.
class InstallSourceInfo {
  const new({this.installerPackage, this.initiatingPackage});

  final String? installerPackage;
  final String? initiatingPackage;
}

/// Reads the Android package installer that delivered the current app install.
class InstallSourceService {
  new({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('com.navis.app/distribution');

  final MethodChannel _channel;

  /// Returns install-source metadata on Android, or `null` on other platforms.
  Future<InstallSourceInfo?> getInstallSource() async {
    if (!Platform.isAndroid) {
      return null;
    }

    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'getInstallSource',
      );
      if (result == null) {
        return const InstallSourceInfo();
      }
      return InstallSourceInfo(
        installerPackage: result['installerPackage'] as String?,
        initiatingPackage: result['initiatingPackage'] as String?,
      );
    } on PlatformException {
      return const InstallSourceInfo();
    }
  }
}
