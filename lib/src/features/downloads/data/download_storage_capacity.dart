import 'dart:io';

import 'package:flutter/services.dart';
import 'package:navis/src/utils/app_logger.dart';

/// Available bytes on the filesystem containing an existing directory.
/// SAF providers do not expose capacity; their staging directory is checked.
Future<int?> downloadStorageFreeBytes(String directory) async {
  try {
    return await const MethodChannel('com.navis.app/storage_capacity')
        .invokeMethod<int>('freeBytes', {'path': directory});
  } on MissingPluginException {
    return null;
  } on PlatformException {
    // Some filesystems cannot report capacity. Write errors still hold work.
    return null;
  }
}

/// Marks a directory, and so everything under it, as excluded from iCloud and
/// iTunes backups (iOS). A failure is logged and ignored: it must never fail a
/// download.
Future<bool> excludeFromBackup(String path) async {
  try {
    final excluded =
        await const MethodChannel('com.navis.app/storage_capacity')
            .invokeMethod<bool>('excludeFromBackup', {'path': path}) ??
        false;
    if (!excluded) AppLogger.warning('Backup exclusion was refused.');
    return excluded;
  } on MissingPluginException {
    AppLogger.warning('Backup exclusion is unavailable on this platform.');
  } on PlatformException catch (error) {
    AppLogger.warning('Backup exclusion failed: ${error.code}');
  }
  return false;
}

/// Keeps re-downloadable media out of backups on iOS (App Review rejects
/// backed-up re-downloadable media). The attribute is lost when a directory is
/// deleted and recreated (clear-all), so it is applied whenever the directory
/// was just created and once per process otherwise. Other platforms: no-op.
class BackupExclusion {
  new({bool? isIOS, Future<bool> Function(String path)? exclude})
    : _isIOS = isIOS ?? Platform.isIOS,
      _exclude = exclude ?? excludeFromBackup;

  final bool _isIOS;
  final Future<bool> Function(String path) _exclude;
  final Set<String> _applied = {};

  Future<void> apply(Directory directory, {required bool created}) async {
    if (!_isIOS) return;
    if (!created && _applied.contains(directory.path)) return;
    try {
      // Only a confirmed exclusion counts as done; a refusal is retried on
      // the next call.
      if (await _exclude(directory.path)) {
        _applied.add(directory.path);
      } else {
        _applied.remove(directory.path);
      }
    } on Object catch (error) {
      _applied.remove(directory.path);
      AppLogger.warning('Backup exclusion failed: ${error.runtimeType}');
    }
  }
}
