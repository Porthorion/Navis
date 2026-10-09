import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/settings/data/update_scripts.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory workDir;

  setUp(() async {
    workDir = await Directory.systemTemp.createTemp('navis_script_test_');
    if (!Platform.isWindows) {
      final result = await Process.run('chmod', ['700', workDir.path]);
      expect(result.exitCode, 0);
    }
  });

  tearDown(() async {
    await workDir.delete(recursive: true);
  });

  test(
    'Windows copy failure restores backup and exits before relaunch',
    () async {
      final target = p.join(workDir.path, 'Navis');
      final staging = p.join(workDir.path, 'staging');
      final scriptPath = await UpdateScripts.writeWindowsPortableScript(
        workDir: workDir.path,
        targetDir: target,
        stagingDir: staging,
        appExeName: 'navis.exe',
      );
      final script = await File(scriptPath).readAsString();
      expect(p.dirname(scriptPath), workDir.path);
      final backupRename = script.indexOf('ren "$target" "Navis.backup"');
      final copy = script.indexOf('robocopy ');
      final failure = script.indexOf('if errorlevel 8 (');
      final failureEnd = script.indexOf('\n)', failure);
      final branch = script.substring(failure, failureEnd);
      expect(backupRename, greaterThan(-1));
      expect(copy, greaterThan(backupRename));
      expect(
        script.substring(backupRename, copy),
        contains('if errorlevel 1 ('),
      );
      expect(failure, greaterThan(copy));
      expect(branch, contains('rd /s /q "$target" 2>nul'));
      expect(branch, contains('ren "$target.backup" "Navis"'));
      expect(branch, contains('rd /s /q "$staging" 2>nul'));
      expect(branch, contains('del "%~f0"'));
      expect(branch, contains('exit /b 1'));
      expect(branch, isNot(contains('start ')));
      expect(branch, isNot(contains('rd /s /q "$target.backup"')));
      final backupDeletion = script.indexOf(
        'rd /s /q "$target.backup"',
        backupRename,
      );
      expect(backupDeletion, greaterThan(failureEnd));
      expect(script.indexOf('start ""'), greaterThan(failureEnd));
    },
  );

  test(
    'Windows paths escape percent expansion including rename basenames',
    () async {
      final target = p.join(workDir.path, 'Navis%PATH%');
      final staging = p.join(workDir.path, 'staging%TEMP%');
      final scriptPath = await UpdateScripts.writeWindowsPortableScript(
        workDir: workDir.path,
        targetDir: target,
        stagingDir: staging,
        appExeName: 'navis%NAME%.exe',
      );
      final script = await File(scriptPath).readAsString();
      expect(script, contains('Navis%%PATH%%'));
      expect(script, contains('staging%%TEMP%%'));
      expect(script, contains('navis%%NAME%%.exe'));
      expect(script, contains('"Navis%%PATH%%.backup"'));
      expect(script, contains('"Navis%%PATH%%"'));
      expect(script, isNot(contains('Navis%PATH%')));
      expect(script, isNot(contains('staging%TEMP%')));
      expect(script, isNot(contains('navis%NAME%.exe')));
      // cmd's own parameter expansion must remain intact for self-deletion.
      expect(script, contains('del "%~f0"'));
    },
  );

  for (final isMacos in [false, true]) {
    test(
      'Unix script and staging paths stay in private work dir (macOS: $isMacos)',
      () async {
        final staging = p.join(workDir.path, 'staging');
        final scriptPath = await UpdateScripts.writeUnixScript(
          workDir: workDir.path,
          targetPath: '/opt/Navis',
          stagingPath: staging,
          isMacos: isMacos,
          relaunchCommand: '/opt/Navis/navis',
        );
        final script = File(scriptPath);
        expect(p.dirname(scriptPath), workDir.path);
        expect(
          await script.readAsString(),
          contains("mv '$staging' '/opt/Navis'"),
        );
        expect(script.statSync().mode & 0x1ff, 0x1c0);
      },
      skip: Platform.isWindows,
    );
  }
}
