import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
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

  group('Linux package installer', () {
    late Directory bin;
    late Directory rootTemp;
    late File artifact;
    late File arguments;
    late String hash;

    setUp(() async {
      bin = await Directory(p.join(workDir.path, 'bin')).create();
      rootTemp = await Directory(p.join(workDir.path, 'root temp')).create();
      arguments = File(p.join(workDir.path, 'installer args'));
      artifact = File(p.join(workDir.path, r'package $(touch INJECTED).deb'));
      await artifact.writeAsString('verified package');
      hash = crypto.sha256.convert(await artifact.readAsBytes()).toString();
      for (final command in [
        'mktemp',
        'cp',
        'chmod',
        'sha256sum',
        'mv',
        'rm',
      ]) {
        await Link(p.join(bin.path, command)).create('/usr/bin/$command');
      }
    });

    Future<void> installer(String command) async {
      final stub = File(p.join(bin.path, command));
      await stub.writeAsString(
        r'''
#!/bin/sh
printf '%s\n' "$@" >> "$NAVIS_TEST_INSTALL_ARGS"
exit "${NAVIS_TEST_INSTALL_EXIT:-0}"
'''
            .trimLeft(),
      );
      expect((await Process.run('chmod', ['700', stub.path])).exitCode, 0);
    }

    Future<ProcessResult> run({
      String kind = 'deb',
      String? expectedHash,
      int installerExit = 0,
    }) => Process.run(
      '/bin/sh',
      [
        '-c',
        linuxPackageInstallScript,
        'navis-update',
        artifact.path,
        expectedHash ?? hash,
        kind,
      ],
      environment: {
        'PATH': bin.path,
        'NAVIS_UPDATE_TMP': rootTemp.path,
        'TMPDIR': '/does-not-exist',
        'NAVIS_TEST_INSTALL_ARGS': arguments.path,
        'NAVIS_TEST_INSTALL_EXIT': '$installerExit',
      },
    );

    for (final kind in ['deb', 'rpm']) {
      test(
        '$kind installs a literal path from a fresh copy and cleans up',
        () async {
          await installer(kind == 'deb' ? 'apt-get' : 'dnf');
          final result = await run(kind: kind);
          expect(result.exitCode, 0, reason: '${result.stderr}');
          final args = await arguments.readAsLines();
          expect(args, [
            if (kind == 'deb') ...[
              '-o',
              'DPkg::Lock::Timeout=120',
              'install',
              '-y',
              '--no-install-recommends',
            ] else ...[
              'install',
              '-y',
            ],
            args.last,
          ]);
          expect(args.last, isNot(artifact.path));
          expect(p.isWithin(rootTemp.path, args.last), isTrue);
          expect(p.basename(args.last), 'pkg.$kind');
          expect(Directory(p.dirname(args.last)).existsSync(), isFalse);
          expect(rootTemp.listSync(), isEmpty);
          expect(await artifact.readAsString(), 'verified package');
          expect(File(p.join(workDir.path, 'INJECTED')).existsSync(), isFalse);
        },
      );
    }

    test('wrong hash refuses the installer and cleans up', () async {
      await installer('apt-get');
      expect((await run(expectedHash: '0' * 64)).exitCode, 10);
      expect(arguments.existsSync(), isFalse);
      expect(rootTemp.listSync(), isEmpty);
    });

    test('artifact changed after caller verification is refused', () async {
      await installer('apt-get');
      await artifact.writeAsString('swapped package');
      expect((await run()).exitCode, 10);
      expect(arguments.existsSync(), isFalse);
      expect(rootTemp.listSync(), isEmpty);
    });

    for (final kind in ['deb', 'rpm', 'unsupported']) {
      test('missing or unsupported installer $kind returns 11', () async {
        expect((await run(kind: kind)).exitCode, 11);
        expect(arguments.existsSync(), isFalse);
        expect(rootTemp.listSync(), isEmpty);
      });
    }

    test('installer failure preserves its exit code and cleans up', () async {
      await installer('apt-get');
      expect((await run(installerExit: 23)).exitCode, 23);
      expect(rootTemp.listSync(), isEmpty);
    });
  }, skip: !Platform.isLinux);
}
