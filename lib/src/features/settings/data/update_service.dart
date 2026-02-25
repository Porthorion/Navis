import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:navis/src/features/settings/domain/update_info.dart';
import 'package:navis/src/utils/app_logger.dart';

/// Handles downloading an APK from the Forgejo release assets and launching
/// the Android package installer.
class UpdateService {
  UpdateService({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  static const _channel = MethodChannel('com.navis.app/updater');

  /// Downloads the APK from the URL in [info] into the app's cache
  /// directory and reports progress via `onProgress` (0.0 – 1.0).
  ///
  /// Returns the absolute path to the downloaded file.
  Future<String> downloadApk(
    UpdateInfo info, {
    void Function(double progress)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final url = info.apkDownloadUrl;
    if (url == null || url.isEmpty) {
      throw StateError('No APK download URL available for ${info.tagName}');
    }

    final cacheDir = await getTemporaryDirectory();
    final updatesDir = Directory(p.join(cacheDir.path, 'updates'));
    if (!updatesDir.existsSync()) {
      updatesDir.createSync(recursive: true);
    }

    // Name the file consistently so repeated downloads overwrite the old one.
    final fileName = 'navis-${info.tagName}.apk';
    final filePath = p.join(updatesDir.path, fileName);

    AppLogger.info('Downloading APK from $url → $filePath');

    await _dio.download(
      url,
      filePath,
      cancelToken: cancelToken,
      onReceiveProgress: (received, total) {
        if (total > 0) {
          onProgress?.call(received / total);
        }
      },
      options: Options(
        receiveTimeout: const Duration(minutes: 5),
        sendTimeout: const Duration(seconds: 15),
      ),
    );

    AppLogger.info('APK downloaded to $filePath');
    return filePath;
  }

  /// Requests the Android system to install the APK at [filePath] via the
  /// platform method channel.
  Future<void> installApk(String filePath) async {
    AppLogger.info('Requesting APK install for $filePath');
    await _channel.invokeMethod<bool>('installApk', {'filePath': filePath});
  }

  /// Convenience method: downloads then installs.
  Future<void> downloadAndInstall(
    UpdateInfo info, {
    void Function(double progress)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final path = await downloadApk(
      info,
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
    await installApk(path);
  }
}
