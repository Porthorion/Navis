import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:navis/src/features/settings/data/archive_utils.dart';
import 'package:navis/src/features/settings/data/update_install_mode.dart';
import 'package:navis/src/features/settings/data/update_scripts.dart';
import 'package:navis/src/features/settings/domain/update_info.dart';
import 'package:navis/src/utils/app_logger.dart';

/// Handles downloading a release artifact from Forgejo and applying the update.
///
/// On Android the system APK installer is used via a platform MethodChannel.
/// On desktop platforms a lightweight generated shell/batch script is spawned
/// detached so it can replace the running binary after the app exits.
class UpdateService {
  UpdateService({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  static const _channel = MethodChannel('com.navis.app/updater');

  // ---------------------------------------------------------------------------
  // Download
  // ---------------------------------------------------------------------------

  /// Downloads the artifact from [info.downloadUrl] to the app's cache
  /// directory and reports progress via [onProgress] (0.0 – 1.0).
  ///
  /// Returns the absolute path to the downloaded file.
  Future<String> downloadArtifact(
    UpdateInfo info, {
    void Function(double progress)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final url = info.downloadUrl;
    if (url == null || url.isEmpty) {
      throw StateError('No download URL available for ${info.tagName}');
    }

    final cacheDir = await getTemporaryDirectory();
    final updatesDir = Directory(p.join(cacheDir.path, 'navis_updates'));
    if (!updatesDir.existsSync()) {
      updatesDir.createSync(recursive: true);
    }

    final fileName = info.assetFileName ?? 'navis-${info.tagName}';
    final filePath = p.join(updatesDir.path, fileName);

    AppLogger.info('Downloading update artifact from $url → $filePath');

    await _dio.download(
      url,
      filePath,
      cancelToken: cancelToken,
      onReceiveProgress: (received, total) {
        if (total > 0) onProgress?.call(received / total);
      },
      options: Options(
        receiveTimeout: const Duration(minutes: 10),
        sendTimeout: const Duration(seconds: 15),
      ),
    );

    AppLogger.info('Artifact downloaded to $filePath');
    return filePath;
  }

  /// Backward-compatible alias used by Android callers.
  Future<String> downloadApk(
    UpdateInfo info, {
    void Function(double progress)? onProgress,
    CancelToken? cancelToken,
  }) => downloadArtifact(info, onProgress: onProgress, cancelToken: cancelToken);

  // ---------------------------------------------------------------------------
  // Android install
  // ---------------------------------------------------------------------------

  /// Requests the Android system to install the APK at [filePath] via the
  /// platform MethodChannel.
  Future<void> installApk(String filePath) async {
    AppLogger.info('Requesting APK install for $filePath');
    await _channel.invokeMethod<bool>('installApk', {'filePath': filePath});
  }

  /// Convenience: download then install (Android only).
  Future<void> downloadAndInstall(
    UpdateInfo info, {
    void Function(double progress)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final path = await downloadArtifact(
      info,
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
    await installApk(path);
  }

  // ---------------------------------------------------------------------------
  // Desktop apply
  // ---------------------------------------------------------------------------

  /// Returns `true` if the target directory for [mode] is writable.
  ///
  /// Should be called before initiating a download so we can fail fast and
  /// direct the user to download manually instead.
  bool canApplyUpdate(UpdateInstallMode mode) {
    // The Inno Setup installer runs with its own UAC elevation and replaces
    // itself in the install directory — we don't need write access to
    // C:\Program Files\... beforehand.
    if (mode == UpdateInstallMode.windowsInstaller) return true;

    try {
      final targetDir = _resolveTargetDir(mode);
      return ArchiveUtils.isDirectoryWritable(targetDir);
    } catch (_) {
      return false;
    }
  }

  /// Extracts [downloadedPath] to a staging directory, writes the appropriate
  /// updater script, launches it detached, then exits the app.
  ///
  /// For [UpdateInstallMode.windowsInstaller] and
  /// [UpdateInstallMode.linuxDeb], no extraction is needed — the artifact is
  /// launched/applied directly.
  ///
  /// Throws a [StateError] if the downloaded artifact is missing or appears
  /// truncated (< 10 KB), allowing the caller to surface an error to the user
  /// before any filesystem changes are made.
  Future<void> applyDesktopUpdate(
    String downloadedPath,
    UpdateInstallMode mode,
  ) async {
    AppLogger.info('Applying desktop update: mode=$mode path=$downloadedPath');

    // Guard: confirm the downloaded file exists and is a plausible size.
    final artifact = File(downloadedPath);
    if (!artifact.existsSync()) {
      throw StateError('Downloaded artifact not found: $downloadedPath');
    }
    final fileSize = artifact.lengthSync();
    if (fileSize < 10 * 1024) {
      throw StateError(
        'Downloaded artifact appears truncated: '
        '${(fileSize / 1024).toStringAsFixed(1)} KB',
      );
    }

    switch (mode) {
      case UpdateInstallMode.windowsInstaller:
        await _applyWindowsInstaller(downloadedPath);

      case UpdateInstallMode.windowsPortable:
        await _applyWindowsPortable(downloadedPath);

      case UpdateInstallMode.macosBundle:
        await _applyMacosBundle(downloadedPath);

      case UpdateInstallMode.linuxDeb:
        await _applyLinuxDeb(downloadedPath);

      case UpdateInstallMode.linuxPortable:
        await _applyLinuxPortable(downloadedPath);

      case UpdateInstallMode.androidApk:
        // Should not reach here — Android uses installApk().
        throw StateError('applyDesktopUpdate called in Android context');
    }
  }

  // ---- Windows installer ----------------------------------------------------

  Future<void> _applyWindowsInstaller(String exePath) async {
    await Process.start(
      exePath,
      ['/SILENT', '/CLOSEAPPLICATIONS'],
      mode: ProcessStartMode.detached,
    );
    exit(0);
  }

  // ---- Windows portable (zip) -----------------------------------------------

  Future<void> _applyWindowsPortable(String zipPath) async {
    final targetDir = _resolveTargetDir(UpdateInstallMode.windowsPortable);
    final stagingDir = p.join(
      Directory.systemTemp.path,
      'navis_update_staging_${DateTime.now().millisecondsSinceEpoch}',
    );

    AppLogger.info('Extracting Windows zip to $stagingDir');
    await ArchiveUtils.extractZipWindows(zipPath, stagingDir);

    final script = await UpdateScripts.writeWindowsPortableScript(
      targetDir: targetDir,
      stagingDir: stagingDir,
      appExeName: 'navis.exe',
    );

    AppLogger.info('Launching Windows updater script: $script');
    await Process.start(
      'cmd',
      ['/c', script],
      mode: ProcessStartMode.detached,
    );
    exit(0);
  }

  // ---- macOS bundle (zip) ---------------------------------------------------

  Future<void> _applyMacosBundle(String zipPath) async {
    // Resolve the .app bundle path: walk up from the executable to the
    // first ancestor that ends with ".app".
    final exe = Platform.resolvedExecutable;
    String appBundlePath = exe;
    while (appBundlePath.isNotEmpty && !appBundlePath.endsWith('.app')) {
      appBundlePath = p.dirname(appBundlePath);
    }
    if (!appBundlePath.endsWith('.app')) {
      throw StateError('Could not locate .app bundle for executable: $exe');
    }

    final stagingDir = p.join(
      Directory.systemTemp.path,
      'navis_update_staging_${DateTime.now().millisecondsSinceEpoch}',
    );

    AppLogger.info('Extracting macOS zip to $stagingDir');
    await ArchiveUtils.extractZipMacos(zipPath, stagingDir);

    final script = await UpdateScripts.writeUnixScript(
      targetPath: appBundlePath,
      stagingPath: p.join(stagingDir, p.basename(appBundlePath)),
      isMacos: true,
      relaunchCommand: appBundlePath,
    );

    AppLogger.info('Launching macOS updater script: $script');
    await Process.start('bash', [script], mode: ProcessStartMode.detached);
    exit(0);
  }

  // ---- Linux deb ------------------------------------------------------------

  Future<void> _applyLinuxDeb(String debPath) async {
    AppLogger.info('Installing deb via pkexec dpkg -i $debPath');
    final result = await Process.run('pkexec', ['dpkg', '-i', debPath]);
    if (result.exitCode != 0) {
      throw ProcessException(
        'pkexec',
        ['dpkg', '-i', debPath],
        'dpkg exited with code ${result.exitCode}\n${result.stderr}',
        result.exitCode,
      );
    }
    // Re-launch the freshly installed binary from the system launcher path,
    // then exit the old process.
    await Process.start(
      Platform.resolvedExecutable,
      [],
      mode: ProcessStartMode.detached,
    );
    exit(0);
  }

  // ---- Linux portable (tar.gz) ---------------------------------------------

  Future<void> _applyLinuxPortable(String tarPath) async {
    final targetDir = _resolveTargetDir(UpdateInstallMode.linuxPortable);
    final stagingDir = p.join(
      Directory.systemTemp.path,
      'navis_update_staging_${DateTime.now().millisecondsSinceEpoch}',
    );

    AppLogger.info('Extracting Linux tar.gz to $stagingDir');
    await ArchiveUtils.extractTarGz(tarPath, stagingDir);

    final executableName = p.basename(Platform.resolvedExecutable);

    final script = await UpdateScripts.writeUnixScript(
      targetPath: targetDir,
      stagingPath: stagingDir,
      isMacos: false,
      relaunchCommand: p.join(targetDir, executableName),
    );

    AppLogger.info('Launching Linux updater script: $script');
    await Process.start('bash', [script], mode: ProcessStartMode.detached);
    exit(0);
  }

  // ---------------------------------------------------------------------------
  // Startup cleanup
  // ---------------------------------------------------------------------------

  /// Deletes leftover `.backup` directories and orphaned staging dirs created
  /// by a previous updater script. Safe to call on every app launch.
  static Future<void> cleanupStaledUpdates() async {
    await _cleanupNextToBundle();
    await _cleanupStagingDirs();
  }

  static Future<void> _cleanupNextToBundle() async {
    try {
      final exeDir = File(Platform.resolvedExecutable).parent;
      await for (final entity in exeDir.list()) {
        if (entity is Directory &&
            p.basename(entity.path).endsWith('.backup')) {
          AppLogger.info(
            'Removing leftover backup dir: ${entity.path}',
          );
          await entity.delete(recursive: true);
        }
      }
    } catch (_) {}
  }

  static Future<void> _cleanupStagingDirs() async {
    try {
      final tmpDir = Directory.systemTemp;
      await for (final entity in tmpDir.list()) {
        if (entity is Directory &&
            p.basename(entity.path).startsWith('navis_update_staging_')) {
          AppLogger.info(
            'Removing leftover staging dir: ${entity.path}',
          );
          await entity.delete(recursive: true);
        }
      }
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Returns the directory that contains the running executable (i.e. the
  /// bundle root for portable installs) on desktop platforms.
  String _resolveTargetDir(UpdateInstallMode mode) {
    switch (mode) {
      case UpdateInstallMode.windowsPortable:
      case UpdateInstallMode.linuxPortable:
        return File(Platform.resolvedExecutable).parent.path;

      case UpdateInstallMode.macosBundle:
        // canApplyUpdate needs to confirm we can write to the *directory that
        // contains* the .app bundle (we rename it in place). Walk up to .app
        // then return its parent.
        final exe = Platform.resolvedExecutable;
        var path = exe;
        while (path.isNotEmpty && !path.endsWith('.app')) {
          path = p.dirname(path);
        }
        return p.dirname(path); // e.g. /Applications, not /Applications/Navis.app

      case UpdateInstallMode.linuxDeb:
        return p.dirname(Platform.resolvedExecutable);

      case UpdateInstallMode.androidApk:
      case UpdateInstallMode.windowsInstaller:
        return p.dirname(Platform.resolvedExecutable);
    }
  }
}
