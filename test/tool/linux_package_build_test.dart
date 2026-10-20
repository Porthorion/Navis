import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  for (final mode in ['release', 'profile']) {
    test(
      'container builder forwards $mode and embedded test version',
      () async {
        final fixture = await Directory.systemTemp.createTemp(
          'navis-package-build-',
        );
        addTearDown(() => fixture.delete(recursive: true));
        final tool = Directory(p.join(fixture.path, 'tool', 'linux'));
        await tool.create(recursive: true);
        await File('tool/linux/build_in_container.sh')
            .copy(p.join(tool.path, 'build_in_container.sh'));
        await File(p.join(fixture.path, 'pubspec.yaml'))
            .writeAsString('version: 1.5.1+10501\n');
        final sources = File(p.join(fixture.path, 'sources.txt'));
        await sources.writeAsString('pubspec.yaml\n');
        final bin = await Directory(p.join(fixture.path, 'bin')).create();
        final docker = File(p.join(bin.path, 'docker'));
        await docker.writeAsString(
          '#!/bin/sh\nprintf "%s\\n" "\$@" >> "\$BUILD_LOG"\n',
        );
        expect((await Process.run('chmod', ['+x', docker.path])).exitCode, 0);
        final log = File(p.join(fixture.path, 'docker.log'));
        final result = await Process.run(
          'bash',
          [
            p.join(tool.path, 'build_in_container.sh'),
            '--source-list=${sources.path}',
            if (mode == 'profile') '--build-mode=profile',
            '--package=all',
            '--version=v1.4.123456',
            '--build-name=1.4.123456',
            '--build-number=1',
            '--dart-define=NAVIS_UPDATE_CHANNEL=staging',
          ],
          environment: {
            'PATH': '${bin.path}:${Platform.environment['PATH']}',
            'NAVIS_FLUTTER_SDK': fixture.path,
            'BUILD_LOG': log.path,
          },
        );
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
        final arguments = await log.readAsLines();
        expect(arguments, contains('NAVIS_LINUX_BUILD_MODE=$mode'));
        expect(arguments, contains('--build-name=1.4.123456'));
        expect(arguments, contains('--build-number=1'));
        expect(
          arguments,
          contains('--dart-define=NAVIS_UPDATE_CHANNEL=staging'),
        );
      },
      skip: !Platform.isLinux,
    );
  }

  test('R2 handshake helpers source without running diagnostics', () async {
    final fixture = await Directory.systemTemp.createTemp('navis-handshake-');
    addTearDown(() => fixture.delete(recursive: true));
    final handshake = File(p.join(fixture.path, 'handshake.json'));
    await handshake.writeAsString('{"port":4321,"token":"fixture","pid":42}');
    final result = await Process.run('bash', [
      '-euo',
      'pipefail',
      '-c',
      r'''
source "$1"
HANDSHAKE="$2"
read_handshake
[[ "$TOKEN" == fixture ]]
declare -F wait_handshake api field >/dev/null
printf '%s %s\n' "$PORT" "$APP_PID"
''',
      'test',
      p.absolute('tool/r2_update_diagnostics.sh'),
      handshake.path,
    ], workingDirectory: fixture.path);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(result.stdout, '4321 42\n');
    expect(await fixture.list().length, 1);
  }, skip: Platform.isWindows);
}
