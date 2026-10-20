import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:navis/src/features/integrations/domain/update_source.dart';
import 'package:navis/src/features/settings/data/update_transport.dart';
import 'package:navis/src/features/integrations/data/integration_guard_interceptor.dart';
import 'package:navis/src/features/settings/data/archive_utils.dart';
import 'package:navis/src/features/settings/data/update_install_mode.dart';
import 'package:navis/src/features/settings/data/update_scripts.dart';
import 'package:navis/src/features/settings/domain/update_info.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/utils/constants.dart';
import 'package:navis/src/utils/external_url.dart';
import 'package:navis/src/utils/network_usage_meter.dart';

/// A downloaded artifact differs from the signed manifest's size or digest.
class UpdateIntegrityException implements Exception {
  const new();

  @override
  String toString() => 'Update download failed integrity verification';
}

/// Handles downloading a verified release artifact and applying it.
class UpdateService {
  new({
    Dio? dio,
    this._networkUsageReporter,
    this.source = UpdateSource.porthorion,
  }) : _dio = dio ?? Dio();

  final Dio _dio;
  final UpdateSource source;
  final NetworkUsageReporter? _networkUsageReporter;

  static const _channel = MethodChannel('com.navis.app/updater');

  // ---------------------------------------------------------------------------
  // Download
  // ---------------------------------------------------------------------------

  /// Downloads the artifact from [UpdateInfo.downloadUrl] to a private work
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

    if (!isUpdateAssetUrl(
      url,
      source.effectiveFor(AppConstants.updateChannel),
    )) {
      throw StateError('Update download URL is outside the update host');
    }
    if (info.sha256 == null || info.size == null) {
      throw StateError('Update download has no manifest integrity metadata');
    }

    final cacheDir = await getTemporaryDirectory();
    // Android's FileProvider exposes this app-private cache subdirectory.
    // Desktop temp bases can be shared, so create a fresh private directory.
    final updatesDir = Platform.isAndroid
        ? await Directory(p.join(cacheDir.path, 'navis_updates'))
              .create(recursive: true)
        : await Directory(p.join(cacheDir.path)).createTemp('navis_update_');
    if (!Platform.isAndroid && !Platform.isWindows) {
      // createTemp's POSIX mode depends on the SDK/umask. Make the directory
      // private before writing any artifact or script, and fail closed.
      final result = await Process.run('chmod', ['700', updatesDir.path]);
      if (result.exitCode != 0) {
        throw ProcessException(
          'chmod',
          ['700', updatesDir.path],
          'Could not secure update work directory',
          result.exitCode,
        );
      }
      // Reject anything inserted before the directory became private when
      // the process umask allowed other users to write to the empty directory.
      if (updatesDir.listSync(followLinks: false).isNotEmpty) {
        throw StateError('Update work directory was not empty');
      }
    }

    final fileName = p.basename(info.assetFileName ?? 'navis-${info.tagName}');
    if (fileName.isEmpty || fileName == '.' || fileName == '..') {
      throw StateError('Invalid update artifact filename');
    }
    final filePath = p.join(updatesDir.path, fileName);

    AppLogger.info('Downloading update artifact from $url → $filePath');

    var downloadedBytes = 0;
    await followUpdateRedirects<dynamic>(
      url,
      source: source.effectiveFor(AppConstants.updateChannel),
      request: (url) => _dio.download(
        url,
        filePath,
        cancelToken: cancelToken,
        onReceiveProgress: (received, total) {
          downloadedBytes = received;
          if (total > 0) onProgress?.call(received / total);
        },
        // The user chose to install this update.
        options: userInitiatedOptions(
          Options(
            followRedirects: false,
            validateStatus: updateResponseStatus,
            receiveTimeout: const Duration(minutes: 10),
            sendTimeout: const Duration(seconds: 15),
          ),
        ),
      ),
    );

    _networkUsageReporter?.call(
      category: NetworkUsageCategory.updates,
      bytes: downloadedBytes,
    );

    await verifyArtifact(filePath, info);
    AppLogger.info('Verified artifact downloaded to $filePath');
    return filePath;
  }

  /// Verifies the file against the signed manifest before any install or apply.
  ///
  /// Deletes mismatched downloads so retries cannot reuse a damaged artifact.
  Future<void> verifyArtifact(String filePath, UpdateInfo info) async {
    final file = File(filePath);
    final sizeMatches = info.size != null && await file.length() == info.size;
    final hashMatches =
        sizeMatches &&
        info.sha256 != null &&
        (await crypto.sha256.bind(file.openRead()).first)
                .toString()
                .toLowerCase() ==
            info.sha256!.toLowerCase();
    if (!hashMatches) {
      await file.delete();
      throw const UpdateIntegrityException();
    }
  }

  // ---------------------------------------------------------------------------
  // Android install
  // ---------------------------------------------------------------------------

  /// Requests the Android system to install the APK at [filePath] via the
  /// platform MethodChannel.
  Future<void> installApk(String filePath) async {
    if (!AppConstants.selfUpdateEnabled) {
      throw StateError('APK self-update is disabled in this build');
    }
    AppLogger.info('Requesting APK install for $filePath');
    await _channel.invokeMethod<bool>('installApk', {'filePath': filePath});
  }

  /// Opens the Google Play listing for Navis, falling back to [fallbackUrl]
  /// when the Play app cannot handle the market URI.
  Future<bool> openPlayStoreListing({String? fallbackUrl}) async {
    final marketUri = Uri.parse(
      'market://details?id=${AppConstants.playStorePackageName}',
    );
    if (await canLaunchUrl(marketUri)) {
      final launched = await launchUrl(
        marketUri,
        mode: LaunchMode.externalApplication,
      );
      if (launched) {
        return true;
      }
    }

    final webUri = Uri.parse(AppConstants.playStoreListingUrl);
    if (await canLaunchUrl(webUri)) {
      return await launchUrl(webUri, mode: LaunchMode.externalApplication);
    }

    final fallback = fallbackUrl?.trim();
    if (fallback == null || fallback.isEmpty) return false;
    return launchExternalHttpUrl(fallback);
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
    } on Object catch (_) {
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
  /// [downloadedPath] must come from [downloadArtifact], which verifies the
  /// artifact against the manifest before returning it.
  Future<void> applyDesktopUpdate(
    String downloadedPath,
    UpdateInstallMode mode,
  ) async {
    AppLogger.info('Applying desktop update: mode=$mode path=$downloadedPath');

    switch (mode) {
      case UpdateInstallMode.windowsInstaller:
        await _applyWindowsInstaller(downloadedPath);

      case UpdateInstallMode.windowsPortable:
        await _applyWindowsPortable(downloadedPath);

      case UpdateInstallMode.macosBundle:
        await _applyMacosBundle(downloadedPath);

      case UpdateInstallMode.linuxDeb:
        await _applyLinuxDeb(downloadedPath);

      case UpdateInstallMode.linuxRpm:
      case UpdateInstallMode.linuxPackageManaged:
        throw UnsupportedError('Use the system package manager');

      case UpdateInstallMode.linuxPortable:
        await _applyLinuxPortable(downloadedPath);

      case UpdateInstallMode.androidApk:
        throw StateError('applyDesktopUpdate called in Android context');
    }
  }

  // ---- Windows installer ----------------------------------------------------

  Future<void> _applyWindowsInstaller(String exePath) async {
    await Process.start(exePath, [
      '/SILENT',
      '/CLOSEAPPLICATIONS',
    ], mode: ProcessStartMode.detached);
    exit(0);
  }

  // ---- Windows portable (zip) -----------------------------------------------

  Future<void> _applyWindowsPortable(String zipPath) async {
    final targetDir = _resolveTargetDir(UpdateInstallMode.windowsPortable);
    final workDir = p.dirname(zipPath);
    final stagingDir = p.join(workDir, 'staging');

    AppLogger.info('Extracting Windows zip to $stagingDir');
    await ArchiveUtils.extractZipWindows(zipPath, stagingDir);

    final script = await UpdateScripts.writeWindowsPortableScript(
      workDir: workDir,
      targetDir: targetDir,
      stagingDir: stagingDir,
      appExeName: 'navis.exe',
    );

    AppLogger.info('Launching Windows updater script: $script');
    await Process.start('cmd', ['/c', script], mode: ProcessStartMode.detached);
    exit(0);
  }

  // ---- macOS bundle (zip) ---------------------------------------------------

  Future<void> _applyMacosBundle(String zipPath) async {
    // Resolve the .app bundle path: walk up from the executable to the
    // first ancestor that ends with ".app".
    final exe = Platform.resolvedExecutable;
    var appBundlePath = exe;
    while (appBundlePath.isNotEmpty && !appBundlePath.endsWith('.app')) {
      appBundlePath = p.dirname(appBundlePath);
    }
    if (!appBundlePath.endsWith('.app')) {
      throw StateError('Could not locate .app bundle for executable: $exe');
    }

    final workDir = p.dirname(zipPath);
    final stagingDir = p.join(workDir, 'staging');

    AppLogger.info('Extracting macOS zip to $stagingDir');
    await ArchiveUtils.extractZipMacos(zipPath, stagingDir);

    final script = await UpdateScripts.writeUnixScript(
      workDir: workDir,
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
    final workDir = p.dirname(tarPath);
    final stagingDir = p.join(workDir, 'staging');

    AppLogger.info('Extracting Linux tar.gz to $stagingDir');
    await ArchiveUtils.extractTarGz(tarPath, stagingDir);

    final executableName = p.basename(Platform.resolvedExecutable);

    final script = await UpdateScripts.writeUnixScript(
      workDir: workDir,
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

  /// Deletes leftover `.backup` directories and this user's private update
  /// work directories. Safe to call on every desktop app launch.
  static Future<void> cleanupStaledUpdates() async {
    await _cleanupNextToBundle();
    await _cleanupWorkDirs();
  }

  static Future<void> _cleanupNextToBundle() async {
    try {
      final exeDir = File(Platform.resolvedExecutable).parent;
      await for (final entity in exeDir.list(followLinks: false)) {
        if (entity is Directory &&
            p.basename(entity.path).endsWith('.backup')) {
          AppLogger.info('Removing leftover backup dir: ${entity.path}');
          await entity.delete(recursive: true);
        }
      }
    } on Object catch (_) {}
  }

  static Future<void> _cleanupWorkDirs() async {
    try {
      final tmpDir = await getTemporaryDirectory();
      // FileStat does not expose ownership. On POSIX, compare numeric UIDs
      // before deleting anything in a potentially shared temp base.
      String? uid;
      if (!Platform.isWindows) {
        final result = await Process.run('id', ['-u']);
        if (result.exitCode != 0) return;
        uid = (result.stdout as String).trim();
        if (int.tryParse(uid) == null) return;
      }
      await for (final entity in tmpDir.list(followLinks: false)) {
        if (entity is! Directory ||
            !p.basename(entity.path).startsWith('navis_update_')) {
          continue;
        }
        try {
          if (uid != null) {
            final owner = await Process.run(
              'stat',
              Platform.isMacOS
                  ? ['-f', '%u', entity.path]
                  : ['-c', '%u', '--', entity.path],
            );
            if (owner.exitCode != 0 || (owner.stdout as String).trim() != uid) {
              continue;
            }
          }
          if (FileSystemEntity.isLinkSync(entity.path)) continue;
          AppLogger.info('Removing leftover update dir: ${entity.path}');
          await entity.delete(recursive: true);
        } on Object catch (_) {
          // A directory may disappear or belong to another user; continue.
        }
      }
    } on Object catch (_) {}
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
        return p.dirname(
          path,
        ); // e.g. /Applications, not /Applications/Navis.app

      case UpdateInstallMode.linuxDeb:
      case UpdateInstallMode.linuxRpm:
      case UpdateInstallMode.linuxPackageManaged:
        return p.dirname(Platform.resolvedExecutable);

      case UpdateInstallMode.androidApk:
      case UpdateInstallMode.windowsInstaller:
        return p.dirname(Platform.resolvedExecutable);
    }
  }
}
