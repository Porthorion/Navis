import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:navis/src/features/group_listening/data/group_listening_configuration.dart';

class GroupListeningDeviceNameService {
  const GroupListeningDeviceNameService({
    MethodChannel channel = _defaultChannel,
  }) : _channel = channel;

  static const MethodChannel _defaultChannel = MethodChannel(
    'com.navis.app/device',
  );

  final MethodChannel _channel;

  Future<String> resolveDeviceLabel() async {
    String? nativeDeviceName;
    if (Platform.isAndroid) {
      nativeDeviceName = await _resolveAndroidDeviceName();
    }
    return defaultGroupListeningDeviceLabel(
      resolvedDeviceName: nativeDeviceName,
    );
  }

  Future<String?> _resolveAndroidDeviceName() async {
    try {
      return await _channel.invokeMethod<String>('getDeviceName');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}
