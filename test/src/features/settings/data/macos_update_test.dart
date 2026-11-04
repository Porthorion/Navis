import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/settings/data/macos_update.dart';
import 'package:navis/src/features/settings/data/update_scripts.dart';
import 'package:navis/src/features/settings/data/update_service.dart';
import 'package:path/path.dart' as p;

/// Runs the generated macOS updater script (bash, so it works on Linux CI too)
/// against temp dirs, with stub `open` and `mv` first on PATH.
void main() {
  group('macOS updater script', () {
    late Directory root;
    late String appPath;
    late String backupPath;
    late String stagingPath;
    late String handshake;
    late String logPath;
    late String openLog;
    late Directory bin;

    String version(String app) =>
        File(p.join(app, 'version')).readAsStringSync();

    setUp(() async {
      // Spaces and a quote exercise the shell escaping on every path.
      root = await Directory.systemTemp.createTemp("navis mac's update ");
      final apps = await Directory(p.join(root.path, "My Apps")).create();
      appPath = p.join(apps.path, "Nav's is.app");
      backupPath = '$appPath.backup';
      await Directory(appPath).create();
      await File(p.join(appPath, 'version')).writeAsString('old');
      final work = await Directory(p.join(root.path, 'work dir')).create();
      stagingPath = p.join(work.path, 'staging', "Nav's is.app");
      await Directory(stagingPath).create(recursive: true);
      await File(p.join(stagingPath, 'version')).writeAsString('new');
      handshake = p.join(root.path, 'support dir', 'handshake');
      await Directory(p.dirname(handshake)).create();
      logPath = p.join(root.path, 'logs', 'update.log');
      openLog = p.join(root.path, 'open.log');
      bin = await Directory(p.join(root.path, 'bin')).create();
      // `open <app>` records the call. A "new" app that STUB_START allows
      // rewrites the handshake as started, like MacosUpdate.startupHandshake;
      // it records whether the backup still existed at that moment.
      final open = File(p.join(bin.path, 'open'));
      await open.writeAsString(r'''#!/bin/bash
echo "$1" >> "$STUB_OPEN_LOG"
if [ "$STUB_START" = 1 ] && [ "$(cat "$1/version")" = new ]; then
  (
    sleep 0.4
    if [ "$(cat "$STUB_HANDSHAKE")" = pending ]; then
      [ -d "$1.backup" ] && echo backup-present-at-marker >> "$STUB_OPEN_LOG"
      printf started > "$STUB_HANDSHAKE"
    fi
  ) >/dev/null 2>&1 &
fi
exit 0
''');
      // Fails any rename onto `*.backup`, like a read-only parent would.
      final mv = File(p.join(bin.path, 'mv'));
      await mv.writeAsString(r'''#!/bin/bash
for a; do last=$a; done
if [ "$STUB_FAIL_BACKUP" = 1 ]; then case "$last" in *.backup) exit 1;; esac; fi
exec /bin/mv "$@"
''');
      await Process.run('chmod', ['755', open.path, mv.path]);
    });

    tearDown(() => root.delete(recursive: true));

    Future<ProcessResult> run({
      bool start = true,
      bool failBackupMove = false,
      int pid = 0,
      int launchTimeout = 5,
    }) async {
      final script = await UpdateScripts.writeMacosScript(
        workDir: p.dirname(p.dirname(stagingPath)),
        targetPath: appPath,
        stagingPath: stagingPath,
        // pid 0 is rejected by `kill -0`, i.e. "already exited".
        pid: pid == 0 ? 2147483646 : pid,
        handshakePath: handshake,
        logPath: logPath,
        exitWaitSeconds: 5,
        launchTimeoutSeconds: launchTimeout,
      );
      return Process.run(
        'bash',
        [script],
        environment: {
          'PATH': '${bin.path}:${Platform.environment['PATH']}',
          'STUB_OPEN_LOG': openLog,
          'STUB_HANDSHAKE': handshake,
          'STUB_START': start ? '1' : '0',
          'STUB_FAIL_BACKUP': failBackupMove ? '1' : '0',
        },
      );
    }

    List<String> opens() => File(openLog).readAsLinesSync();

    test('keeps the backup until the new app confirms its launch', () async {
      final result = await run();
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(version(appPath), 'new');
      expect(Directory(backupPath).existsSync(), isFalse);
      expect(File(handshake).existsSync(), isFalse);
      // The new app saw the backup still in place when it wrote the marker.
      expect(opens(), [appPath, 'backup-present-at-marker']);
      expect(File(logPath).readAsStringSync(), contains('update complete'));
    });

    test('no marker: restores and reopens the previous app', () async {
      final result = await run(start: false, launchTimeout: 1);
      expect(result.exitCode, 1);
      expect(version(appPath), 'old');
      expect(Directory(backupPath).existsSync(), isFalse);
      expect(Directory('$appPath.failed').existsSync(), isFalse);
      expect(File(handshake).existsSync(), isFalse);
      expect(opens(), [appPath, appPath]);
      expect(File(logPath).readAsStringSync(), contains('rolling back'));
    });

    test('failed backup rename keeps and reopens the old app', () async {
      final result = await run(failBackupMove: true);
      expect(result.exitCode, 1);
      expect(version(appPath), 'old');
      expect(Directory(stagingPath).existsSync(), isTrue);
      expect(opens(), [appPath]);
    });

    test('failed install move restores and reopens the old app', () async {
      await Directory(stagingPath).delete(recursive: true);
      final result = await run();
      expect(result.exitCode, 1);
      expect(version(appPath), 'old');
      expect(Directory(backupPath).existsSync(), isFalse);
      expect(opens(), [appPath]);
      expect(File(logPath).readAsStringSync(), contains('restored previous'));
    });

    test('waits for the old process to exit before moving anything', () async {
      final sleeper = await Process.start('sleep', ['1']);
      final started = DateTime.now();
      final result = await run(pid: sleeper.pid);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(
        DateTime.now().difference(started),
        greaterThan(const Duration(milliseconds: 800)),
      );
      expect(version(appPath), 'new');
    });

    test('a hung old process aborts without touching the install', () async {
      final sleeper = await Process.start('sleep', ['30']);
      addTearDown(sleeper.kill);
      final script = await UpdateScripts.writeMacosScript(
        workDir: p.dirname(p.dirname(stagingPath)),
        targetPath: appPath,
        stagingPath: stagingPath,
        pid: sleeper.pid,
        handshakePath: handshake,
        logPath: logPath,
        exitWaitSeconds: 1,
      );
      final result = await Process.run('bash', [script]);
      expect(result.exitCode, 1);
      expect(version(appPath), 'old');
      expect(Directory(stagingPath).existsSync(), isTrue);
    });

    test('appends to the log and trims it when large', () async {
      await Directory(p.dirname(logPath)).create();
      await File(logPath).writeAsString('${'x' * 120}\n' * 1000);
      await run();
      final lines = File(logPath).readAsLinesSync();
      expect(lines.length, lessThan(300));
      expect(lines.last, contains('update complete'));
    });
  }, skip: Platform.isWindows);

  group('macOS startup handshake', () {
    late Directory root;
    late String bundle;
    late File handshake;
    late Directory backup;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('navis_handshake_');
      bundle = p.join(root.path, 'Navis.app');
      backup = await Directory('$bundle.backup').create();
      handshake = File(p.join(root.path, MacosUpdate.handshakeFileName));
    });

    tearDown(() => root.delete(recursive: true));

    Future<void> start({DateTime? now}) => MacosUpdate.startupHandshake(
      supportDir: root.path,
      bundlePath: bundle,
      now: now,
    );

    test('no update running: removes the leftover backup', () async {
      await start();
      expect(backup.existsSync(), isFalse);
    });

    test('script waiting: confirms the launch and keeps the backup', () async {
      await handshake.writeAsString('pending');
      await start();
      expect(await handshake.readAsString(), 'started');
      expect(backup.existsSync(), isTrue);
    });

    test('script finishing: leaves both alone', () async {
      await handshake.writeAsString('started');
      await start();
      expect(await handshake.readAsString(), 'started');
      expect(backup.existsSync(), isTrue);
    });

    test(
      'a stale handshake from a killed script does not pin the backup',
      () async {
        await handshake.writeAsString('pending');
        await start(now: DateTime.now().add(const Duration(minutes: 10)));
        expect(handshake.existsSync(), isFalse);
        expect(backup.existsSync(), isFalse);
      },
    );
  });

  group('macOS bundle location', () {
    test('finds the .app ancestor of the executable', () {
      expect(
        MacosUpdate.bundlePathOf(
          '/Applications/Navis.app/Contents/MacOS/Navis',
        ),
        '/Applications/Navis.app',
      );
      expect(MacosUpdate.bundlePathOf('/usr/bin/flutter_tester'), isNull);
    });

    test('flags translocated and disk-image copies only', () {
      expect(
        MacosUpdate.isTranslocatedOrOnVolume(
          '/private/var/folders/ab/T/AppTranslocation/1234-UUID/d/Navis.app',
        ),
        isTrue,
      );
      expect(
        MacosUpdate.isTranslocatedOrOnVolume('/Volumes/Navis/Navis.app'),
        isTrue,
      );
      expect(
        MacosUpdate.isTranslocatedOrOnVolume('/Applications/Navis.app'),
        isFalse,
      );
      expect(
        MacosUpdate.isTranslocatedOrOnVolume(
          '/Users/me/Applications/Navis.app',
        ),
        isFalse,
      );
    });
  });

  group('staged macOS bundle check', () {
    late Directory root;
    late String staged;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('navis_staged_');
      staged = p.join(root.path, 'Navis.app');
    });

    tearDown(() => root.delete(recursive: true));

    test('a missing staged app is refused without running codesign', () async {
      final service = UpdateService(
        processRunner: (_, _) async => fail('codesign must not run'),
      );
      await expectLater(
        service.verifyStagedMacosBundle(staged),
        throwsA(isA<UpdateIntegrityException>()),
      );
    });

    test('a failing codesign verification is refused', () async {
      await Directory(staged).create();
      final service = UpdateService(
        processRunner: (_, _) async =>
            ProcessResult(1, 1, '', 'a sealed resource is missing'),
      );
      await expectLater(
        service.verifyStagedMacosBundle(staged),
        throwsA(isA<UpdateIntegrityException>()),
      );
    });

    test('a valid staged app passes with deep strict verification', () async {
      await Directory(staged).create();
      List<String>? args;
      final service = UpdateService(
        processRunner: (exe, a) async {
          args = [exe, ...a];
          return ProcessResult(1, 0, '', '');
        },
      );
      await service.verifyStagedMacosBundle(staged);
      expect(args, [
        '/usr/bin/codesign',
        '--verify',
        '--deep',
        '--strict',
        staged,
      ]);
    });
  });
}
