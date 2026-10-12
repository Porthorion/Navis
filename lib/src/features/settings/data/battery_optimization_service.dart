import 'dart:io';

import 'package:flutter/services.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class BatteryOptimizationService {
  const new({this._now, this._supportDirectory});

  static const _channel = MethodChannel('com.navis.app/power');
  static const _snoozeDuration = Duration(days: 14);
  final DateTime Function()? _now;
  final Future<Directory> Function()? _supportDirectory;

  Future<File> _snoozeFile() async {
    final directory =
        await (_supportDirectory?.call() ?? getApplicationSupportDirectory());
    return File(p.join(directory.path, 'battery_tip_snoozed_at.txt'));
  }

  /// Whether Later or dismissing the sheet still suppresses the battery tip.
  Future<bool> isPromptSnoozed() async {
    try {
      final file = await _snoozeFile();
      if (!file.existsSync()) return false;
      final dismissedAt = DateTime.tryParse((await file.readAsString()).trim());
      if (dismissedAt == null) return false;
      return (_now?.call() ?? DateTime.now()).toUtc().difference(dismissedAt) <
          _snoozeDuration;
    } on Exception catch (error) {
      AppLogger.debug('Battery tip snooze read failed: $error');
      return false;
    }
  }

  /// Remembers a dismissed battery tip across cold starts on this device.
  Future<void> snoozePrompt() async {
    try {
      final file = await _snoozeFile();
      await file.parent.create(recursive: true);
      await file.writeAsString(
        (_now?.call() ?? DateTime.now()).toUtc().toIso8601String(),
        flush: true,
      );
    } on Exception catch (error) {
      AppLogger.debug('Battery tip snooze write failed: $error');
    }
  }

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
      AppLogger.debug('Battery optimization check failed: $error\n$stackTrace');
      return false;
    }
  }

  Future<void> openDisableBatteryOptimizationSettings() async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('requestIgnoreBatteryOptimizations');
    } on PlatformException catch (error, stackTrace) {
      AppLogger.debug(
        'Battery optimization settings launch failed: $error\n$stackTrace',
      );
    }
  }
}
