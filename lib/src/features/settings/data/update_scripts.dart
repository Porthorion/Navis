import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:navis/src/utils/app_logger.dart';

/// Generates lightweight platform-specific updater scripts that are written
/// to a temp file, launched detached, and self-delete after finishing.
///
/// All path arguments are shell-escaped to prevent command injection.
class UpdateScripts {
  /// Creates a Windows batch script that:
  /// 1. Waits 2 s for the app to exit
  /// 2. Renames the old install dir to `.backup`
  /// 3. Moves the staging dir into place
  /// 4. Relaunches the app
  /// 5. Removes `.backup`, staging dir, and the script itself
  ///
  /// Returns the absolute path to the written `.bat` file.
  static Future<String> writeWindowsPortableScript({
    required String targetDir,
    required String stagingDir,
    required String appExeName,
  }) async {
    final scriptPath = p.join(
      Directory.systemTemp.path,
      'navis_update_${DateTime.now().millisecondsSinceEpoch}.bat',
    );

    final backupDir = '$targetDir.backup';
    final tdEsc = _winEsc(targetDir);
    final sdEsc = _winEsc(stagingDir);
    final bdEsc = _winEsc(backupDir);
    final relaunchEsc = _winEsc(p.join(targetDir, appExeName));

    // robocopy exit codes 0–7 indicate various degrees of success; 8+ are
    // errors. We do not gate the rest of the script on the exit code because
    // robocopy itself signals partial success with non-zero codes. If it truly
    // fails the relaunch will simply not find the binary (visible to the user).
    final script =
        '''
@echo off
timeout /t 2 /nobreak >nul
if exist $bdEsc rd /s /q $bdEsc
ren $tdEsc "${p.basename(backupDir)}"
robocopy $sdEsc $tdEsc /E /NFL /NDL /NJH /NJS >nul
rd /s /q $sdEsc 2>nul
start "" $relaunchEsc
rd /s /q $bdEsc 2>nul
del "%~f0"
''';

    await File(scriptPath).writeAsString(script);
    return scriptPath;
  }

  /// Creates a macOS/Linux shell script that:
  /// 1. Waits 2 s for the app to exit
  /// 2. Renames the old bundle/dir to `.backup`
  /// 3. Moves new content into place
  /// 4. Relaunches the app (macOS: `open`, Linux: direct exec)
  /// 5. Removes `.backup`, staging dir, and the script itself
  ///
  /// Returns the absolute path to the written `.sh` file.
  static Future<String> writeUnixScript({
    required String targetPath,
    required String stagingPath,
    required bool isMacos,
    required String relaunchCommand,
  }) async {
    final scriptPath = p.join(
      Directory.systemTemp.path,
      'navis_update_${DateTime.now().millisecondsSinceEpoch}.sh',
    );

    final backupPath = '$targetPath.backup';
    final tEsc = _shEsc(targetPath);
    final sEsc = _shEsc(stagingPath);
    final bEsc = _shEsc(backupPath);
    final rEsc = _shEsc(relaunchCommand);

    final relaunchLine = isMacos
        ? 'open $rEsc'
        // cd to the bundle directory first so the app runs with the correct
        // working directory, then detach it fully from this script's session.
        : '(cd -- "\$(dirname $rEsc)" && nohup $rEsc </dev/null >/dev/null 2>&1 &)';

    // The script backs up the current installation before touching anything.
    // If moving the new version into place fails, it rolls back automatically
    // so the app remains functional.
    final script =
        '''
#!/usr/bin/env bash
sleep 2
# Remove stale backup from a previous aborted update.
rm -rf $bEsc 2>/dev/null || true
# Rename (back up) the current installation.
if ! mv $tEsc $bEsc; then
  echo "navis-updater: backup failed, aborting" >&2
  exit 1
fi
# Move new version into place; restore backup on failure.
if ! mv $sEsc $tEsc; then
  echo "navis-updater: install failed, restoring backup" >&2
  mv $bEsc $tEsc || true
  rm -rf $sEsc || true
  exit 1
fi
# Launch the updated app.
$relaunchLine
# Cleanup.
rm -rf $bEsc 2>/dev/null || true
rm -- "\$0" 2>/dev/null || true
''';

    final file = File(scriptPath);
    await file.writeAsString(script);
    // Make executable. We still invoke the script as `bash scriptPath` so
    // this is defensive; log a warning if it somehow fails.
    final chmodResult = await Process.run('chmod', ['700', scriptPath]);
    if (chmodResult.exitCode != 0) {
      AppLogger.warning(
        'chmod 700 on updater script failed (exit ${chmodResult.exitCode}); '
        'continuing since script is invoked via bash.',
      );
    }
    return scriptPath;
  }

  // ---------------------------------------------------------------------------
  // Escaping helpers
  // ---------------------------------------------------------------------------

  /// Wraps a Windows path in double-quotes; internal double-quotes are escaped
  /// with a caret (^) which is the cmd.exe escape character.
  static String _winEsc(String path) {
    return '"${path.replaceAll('"', '^"')}"';
  }

  /// Wraps a Unix path in single quotes; internal single quotes are closed,
  /// escaped with a backslash, and reopened.
  static String _shEsc(String path) {
    return "'${path.replaceAll("'", r"'\''")}'";
  }
}
