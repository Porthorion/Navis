import 'dart:io';

import 'package:flutter/services.dart';
import 'package:navis/src/utils/app_logger.dart';

class BatteryOptimizationService {
  const BatteryOptimizationService();

  static const _channel = MethodChannel('com.navis.app/power');

  Future<bool> shouldPromptDisableBatteryOptimization() async {
    if (!Platform.isAndroid) {
      return false;
    }
    try {
      final ignoring =
          await _channel.invokeMethod<bool>('isIgnoringBatteryOptimizations') ??
          true;
      return !ignoring;
    } on PlatformException catch (error, stackTrace) {
      AppLogger.debug(
        'Battery optimization check failed: $error\n$stackTrace',
      );
      return false;
    }
  }

  Future<void> openDisableBatteryOptimizationSettings() async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      await _channel.invokeMethod<void>(
        'requestIgnoreBatteryOptimizations',
      );
    } on PlatformException catch (error, stackTrace) {
      AppLogger.debug(
        'Battery optimization settings launch failed: $error\n$stackTrace',
      );
    }
  }
}
