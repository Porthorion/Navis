import 'dart:io';

/// Extracts an archive file using platform-native CLI tools.
///
/// No additional Dart packages are needed — every supported desktop OS ships
/// the required tools out of the box.
class ArchiveUtils {
  /// Extracts a `.tar.gz` file to [destDir] (Linux).
  ///
  /// Uses `tar -xzf`. Throws a [ProcessException] on failure.
  static Future<void> extractTarGz(String tarPath, String destDir) async {
    await Directory(destDir).create(recursive: true);
    final result = await Process.run('tar', ['-xzf', tarPath, '-C', destDir]);
    if (result.exitCode != 0) {
      throw ProcessException(
        'tar',
        ['-xzf', tarPath, '-C', destDir],
        'tar exited with code ${result.exitCode}\n${result.stderr}',
        result.exitCode,
      );
    }
  }

  /// Extracts a `.zip` file to [destDir] (macOS).
  ///
  /// Uses `ditto -xk` which preserves macOS resource forks and extended
  /// attributes. Throws a [ProcessException] on failure.
  static Future<void> extractZipMacos(String zipPath, String destDir) async {
    await Directory(destDir).create(recursive: true);
    final result = await Process.run('ditto', ['-xk', zipPath, destDir]);
    if (result.exitCode != 0) {
      throw ProcessException(
        'ditto',
        ['-xk', zipPath, destDir],
        'ditto exited with code ${result.exitCode}\n${result.stderr}',
        result.exitCode,
      );
    }
  }

  /// Extracts a `.zip` file to [destDir] (Windows).
  ///
  /// Uses `powershell.exe Expand-Archive`. Throws a [ProcessException] on
  /// failure.
  static Future<void> extractZipWindows(String zipPath, String destDir) async {
    await Directory(destDir).create(recursive: true);
    final result = await Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      // This is one PowerShell command argument, split for readability.
      // ignore: no_adjacent_strings_in_list
      'Expand-Archive -LiteralPath "${zipPath.replaceAll('"', '`"')}" '
          '-DestinationPath "${destDir.replaceAll('"', '`"')}" -Force',
    ]);
    if (result.exitCode != 0) {
      throw ProcessException(
        'powershell.exe',
        ['Expand-Archive', zipPath, destDir],
        'Expand-Archive exited with code ${result.exitCode}\n${result.stderr}',
        result.exitCode,
      );
    }
  }

  /// Returns true if [dirPath] is writable by the current user.
  ///
  /// Creates a temporary probe file and immediately deletes it.
  static bool isDirectoryWritable(String dirPath) {
    try {
      final probe = File('$dirPath${Platform.pathSeparator}.navis_write_test');
      probe.writeAsStringSync('');
      probe.deleteSync();
      return true;
    } on Object catch (_) {
      return false;
    }
  }
}
