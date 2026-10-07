import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('Android release signing scripts', () {
    late Directory fixture;
    const shellPath = '/usr/bin:/bin';

    setUp(() async {
      fixture = await Directory.systemTemp.createTemp('navis-signing-test-');
      await Directory(p.join(fixture.path, 'tool', 'lib'))
          .create(recursive: true);
    });
    tearDown(() => fixture.delete(recursive: true));

    Future<String> copyScript(String name) async {
      final destination = p.join(fixture.path, 'tool', name);
      await File(p.join('tool', name)).copy(destination);
      return destination;
    }

    for (final optIn in [null, '1']) {
      test(
        'publication rejects missing keys with local opt-in $optIn',
        () async {
          final script = await copyScript('release.sh');
          // The rejection must precede sourcing any secrets or invoking builds.
          final result = await Process.run(
            '/bin/bash',
            [script, 'v1.4.3', '--targets=android', '--skip-checks'],
            includeParentEnvironment: false,
            environment: {
              'PATH': shellPath,
              'NAVIS_ALLOW_DEBUG_SIGNED_RELEASE': ?optIn,
            },
          );
          expect(result.exitCode, 1);
          expect(
            result.stderr,
            contains('android/key.properties is required for Android releases'),
          );
          expect(result.stdout, isNot(contains('Building Android')));
        },
      );
    }

    for (final optIn in [null, '0']) {
      test('local dev APK passes opt-in ${optIn ?? '1 by default'} to Flutter', () async {
        final script = await copyScript('dev_app.sh');
        await File(p.join(fixture.path, 'tool', 'lib', 'lastfm_key_defines.sh'))
            .writeAsString('');
        final bin = Directory(p.join(fixture.path, 'bin'));
        await bin.create();
        // A fake Flutter captures the environment; no app or build is started.
        final flutter = File(p.join(bin.path, 'flutter'));
        await flutter.writeAsString(
          r'''
#!/bin/bash
printf 'debug-signing=%s\n' "$NAVIS_ALLOW_DEBUG_SIGNED_RELEASE"
printf 'args=%s\n' "$*"
'''
              .trimLeft(),
        );
        final chmod = await Process.run('/bin/chmod', ['+x', flutter.path]);
        expect(chmod.exitCode, 0);
        final result = await Process.run(
          '/bin/bash',
          [script, 'apk'],
          includeParentEnvironment: false,
          environment: {
            'PATH': '${bin.path}:$shellPath',
            'NAVIS_ALLOW_DEBUG_SIGNED_RELEASE': ?optIn,
          },
        );
        expect(result.exitCode, 0, reason: result.stderr.toString());
        expect(result.stdout, contains('debug-signing=${optIn ?? '1'}'));
        expect(result.stdout, contains('args=build apk --release'));
      });
    }
  }, skip: !Platform.isLinux && !Platform.isMacOS);
}
