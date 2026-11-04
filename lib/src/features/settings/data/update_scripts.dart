import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:navis/src/utils/app_logger.dart';

/// Generates lightweight platform-specific updater scripts that are written
/// inside a private update work directory, launched detached, and self-delete
/// after finishing.
///
/// All path arguments are shell-escaped to prevent command injection.
class UpdateScripts {
  /// Creates a Windows batch script that:
  /// 1. Waits 2 s for the app to exit
  /// 2. Renames the old install dir to `.backup`
  /// 3. Copies staging into place, restoring `.backup` if copying fails
  /// 4. Relaunches the app
  /// 5. Removes `.backup`, staging dir, and the script itself
  ///
  /// Returns the absolute path to the written `.bat` file.
  static Future<String> writeWindowsPortableScript({
    required String workDir,
    required String targetDir,
    required String stagingDir,
    required String appExeName,
  }) async {
    final scriptPath = p.join(workDir, 'navis_update.bat');

    final backupDir = '$targetDir.backup';
    final tdEsc = _winEsc(targetDir);
    final sdEsc = _winEsc(stagingDir);
    final bdEsc = _winEsc(backupDir);
    final relaunchEsc = _winEsc(p.join(targetDir, appExeName));
    final backupNameEsc = _winEsc(p.basename(backupDir));
    final targetNameEsc = _winEsc(p.basename(targetDir));

    // robocopy exit codes 0–7 indicate various degrees of success; 8+ are
    // errors. Keep the backup until copying succeeds, and never relaunch a
    // partially copied installation.
    final script =
        '''
@echo off
timeout /t 2 /nobreak >nul
if exist $bdEsc rd /s /q $bdEsc
ren $tdEsc $backupNameEsc
if errorlevel 1 (
  rd /s /q $sdEsc 2>nul
  del "%~f0"
  exit /b 1
)
robocopy $sdEsc $tdEsc /E /NFL /NDL /NJH /NJS >nul
if errorlevel 8 (
  rd /s /q $tdEsc 2>nul
  ren $bdEsc $targetNameEsc
  rd /s /q $sdEsc 2>nul
  del "%~f0"
  exit /b 1
)
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
    required String workDir,
    required String targetPath,
    required String stagingPath,
    required bool isMacos,
    required String relaunchCommand,
  }) async {
    final scriptPath = p.join(workDir, 'navis_update.sh');

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
    // The enclosing work directory is already private (0700 on POSIX),
    // protecting the script while it is written and before chmod.
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

  /// Creates the macOS updater script. Unlike [writeUnixScript] it never leaves
  /// the user without a working app:
  /// 1. Waits (up to [exitWaitSeconds]) for process [pid] to exit; on timeout
  ///    it reopens the untouched app
  /// 2. Moves the app to `.backup`, then the staged app into place
  /// 3. Writes `pending` to [handshakePath], opens the app, and waits up to
  ///    [launchTimeoutSeconds] for the new app to rewrite it as `started`
  ///    once it has rendered its first frame (see `MacosUpdate`)
  /// 4. Marker seen: deletes the backup. Marker missing and a process still
  ///    runs from the new bundle: the new app is alive, so nothing is touched
  ///    and the backup is left for the next launch to clean up. Otherwise (or
  ///    if `open` or any move fails): moves the new app aside, restores the
  ///    backup and opens it
  ///
  /// Every step is appended to [logPath]. Returns the path to the `.sh` file.
  static Future<String> writeMacosScript({
    required String workDir,
    required String targetPath,
    required String stagingPath,
    required int pid,
    required String handshakePath,
    required String logPath,
    int exitWaitSeconds = 20,
    int launchTimeoutSeconds = 30,
  }) async {
    final scriptPath = p.join(workDir, 'navis_update.sh');
    final t = _shEsc(targetPath);
    final s = _shEsc(stagingPath);
    final b = _shEsc('$targetPath.backup');
    final f = _shEsc('$targetPath.failed');
    final h = _shEsc(handshakePath);
    final l = _shEsc(logPath);

    final script =
        '''
#!/usr/bin/env bash
LOG=$l
mkdir -p -- "\$(dirname -- "\$LOG")" 2>/dev/null
# Keep the log small: drop all but the tail once it passes ~100 KB.
if [ -f "\$LOG" ] && [ "\$(wc -c < "\$LOG")" -gt 100000 ]; then
  tail -n 200 "\$LOG" > "\$LOG.tmp" 2>/dev/null && mv -f "\$LOG.tmp" "\$LOG"
fi
log() { printf '%s %s\\n' "\$(date '+%Y-%m-%dT%H:%M:%S')" "\$*" >> "\$LOG" 2>/dev/null || true; }
finish() { rm -- "\$0" 2>/dev/null; exit "\$1"; }
# True while any process runs from the (new) bundle's executable directory.
running() {
  /bin/ps -axo comm= 2>/dev/null | P=$t/Contents/MacOS/ awk 'index(\$0, ENVIRON["P"]) == 1 { f = 1 } END { exit !f }'
}
# Put the old app back (whatever state the moves reached) and open it. The
# handshake says rollback first so a late-starting new app cannot confirm.
restore() {
  printf rollback > $h 2>/dev/null
  if [ -e $b ]; then
    rm -rf -- $f
    if [ -e $t ]; then
      if [ -e $f ] || ! mv $t $f; then rm -rf -- $t; fi
    fi
    if [ -e $t ]; then
      log "could not clear the new app; backup kept"
    elif mv $b $t; then
      log "restored previous app"
      rm -rf -- $f
    else
      log "restore FAILED; backup and failed app kept"
    fi
  fi
  rm -f -- $h
  open $t || log "open of restored app failed"
}
log "update started; waiting for pid $pid"
i=0
while kill -0 $pid 2>/dev/null; do
  if [ \$i -ge ${exitWaitSeconds * 5} ]; then
    log "old app still running after ${exitWaitSeconds}s; aborting without changes"
    open $t || log "open failed"
    finish 1
  fi
  sleep 0.2; i=\$((i + 1))
done
rm -rf -- $b
if [ -e $b ]; then
  log "could not clear the previous backup; keeping the old app"
  open $t || log "open failed"
  finish 1
fi
if ! mv $t $b; then
  log "could not move the old app aside; keeping it"
  open $t || log "open failed"
  finish 1
fi
if ! mv $s $t; then
  log "could not move the new app into place"
  restore
  finish 1
fi
mkdir -p -- "\$(dirname -- $h)" 2>/dev/null
if ! printf pending > $h; then
  log "could not write the launch handshake"
  restore
  finish 1
fi
if open $t; then
  log "opened new app; waiting for its launch marker"
else
  log "open of new app failed"
fi
i=0
while [ \$i -lt ${launchTimeoutSeconds * 5} ]; do
  if [ "\$(cat -- $h 2>/dev/null)" = started ]; then
    rm -f -- $h
    rm -rf -- $b
    log "new app started; update complete"
    finish 0
  fi
  sleep 0.2; i=\$((i + 1))
done
if running; then
  log "no launch marker after ${launchTimeoutSeconds}s but the new app is running; leaving it and the backup in place"
  finish 0
fi
log "new app did not start within ${launchTimeoutSeconds}s; rolling back"
restore
finish 1
''';

    await File(scriptPath).writeAsString(script);
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
  /// with a caret (^); percent signs are doubled to suppress batch expansion.
  static String _winEsc(String path) {
    return '"${path.replaceAll('%', '%%').replaceAll('"', '^"')}"';
  }

  /// Wraps a Unix path in single quotes; internal single quotes are closed,
  /// escaped with a backslash, and reopened.
  static String _shEsc(String path) {
    return "'${path.replaceAll("'", r"'\''")}'";
  }
}

/// Copies and verifies a package under elevation before invoking its installer.
/// Arguments are the source path, expected SHA-256, and package kind (deb/rpm).
const String linuxPackageInstallScript = r'''
set -eu
d=$(mktemp -d "${NAVIS_UPDATE_TMP:-/var/tmp}/navis-update.XXXXXX")
trap 'rm -rf -- "$d"' EXIT
cp -- "$1" "$d/pkg"
chmod 0644 "$d/pkg"
actual=$(sha256sum < "$d/pkg")
[ "${actual%% *}" = "$2" ] || exit 10
case "$3" in
  deb)
    command -v apt-get >/dev/null 2>&1 || exit 11
    mv -- "$d/pkg" "$d/pkg.deb"
    apt-get -o DPkg::Lock::Timeout=120 install -y --no-install-recommends "$d/pkg.deb"
    ;;
  rpm)
    command -v dnf >/dev/null 2>&1 || exit 11
    mv -- "$d/pkg" "$d/pkg.rpm"
    dnf install -y "$d/pkg.rpm"
    ;;
  *) exit 11 ;;
esac
''';
