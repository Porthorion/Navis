import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  const assets = [
    'navis-v1.5.0.apk',
    'navis-v1.5.0-android-arm64-v8a.apk',
    'navis-v1.5.0-android-armeabi-v7a.apk',
    'navis-v1.5.0-android-x86_64.apk',
    'navis-v1.5.0-linux.tar.gz',
    'navis-v1.5.0-linux-amd64.deb',
    'navis-v1.5.0-linux-x86_64.rpm',
    'navis-v1.5.0-windows-installer.exe',
  ];
  const sourceCommit = '1111111111111111111111111111111111111111';
  const buildArgs = [
    'v1.5.0',
    '--build-only',
    '--skip-checks',
    '--targets=android,linux,windows',
    '--linux-package=all',
    '--windows-package=exe',
    '--windows-ssh=fixture@builder',
    '--forgejo',
  ];
  late Directory fixture;

  Future<void> write(String path, String contents) async {
    final file = File(p.join(fixture.path, path));
    await file.parent.create(recursive: true);
    await file.writeAsString(contents);
  }

  Future<void> executable(String path, String contents) async {
    await write(path, '#!/bin/bash\nset -euo pipefail\n$contents');
    final result = await Process.run('/bin/chmod', [
      '+x',
      p.join(fixture.path, path),
    ]);
    expect(result.exitCode, 0);
  }

  Future<ProcessResult> run(
    List<String> args, {
    Map<String, String> environment = const {},
  }) => Process.run(
    '/bin/bash',
    [p.join(fixture.path, 'tool', 'release.sh'), ...args],
    workingDirectory: fixture.path,
    includeParentEnvironment: false,
    environment: {
      'PATH': '${p.join(fixture.path, 'bin')}:/usr/bin:/bin',
      'HOME': fixture.path,
      'FIXTURE': fixture.path,
      'ANDROID_SDK_ROOT': p.join(fixture.path, 'sdk'),
      'NAVIS_LASTFM_API_KEY': 'fixture-key',
      'SOURCE_COMMIT': sourceCommit,
      ...environment,
    },
  );

  Future<List<String>> log() async {
    final file = File(p.join(fixture.path, 'log'));
    return file.existsSync() ? await file.readAsLines() : [];
  }

  Future<void> build({List<String> extra = const []}) async {
    final result = await run([...buildArgs, ...extra]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  }

  void expectNoReleaseActions(List<String> calls) {
    expect(calls.where((line) => line.startsWith('r2:')), isEmpty);
    expect(calls.where((line) => line.startsWith('curl:')), isEmpty);
    expect(
      calls.where(
        (line) => RegExp(
          r'^git:(tag|push|fetch|ls-remote|merge|checkout|commit|add)\b',
        ).hasMatch(line),
      ),
      isEmpty,
    );
  }

  setUp(() async {
    fixture = await Directory.systemTemp.createTemp('navis-dist-test-');
    // Copy only public scripts. Never copy release.env, keys or real builders.
    for (final script in [
      'tool/release.sh',
      'tool/release_tag_guard.sh',
      'tool/lib/release_dist.sh',
      'tool/lib/lastfm_key_defines.sh',
      'tool/lib/r2_tags.sh',
    ]) {
      await write(script, File(script).readAsStringSync());
    }
    final chmod = await Process.run('/bin/chmod', [
      '+x',
      p.join(fixture.path, 'tool', 'release_tag_guard.sh'),
    ]);
    expect(chmod.exitCode, 0);
    await write('pubspec.yaml', 'version: 1.5.0+10500\n');
    await write(
      'android/key.properties',
      'storeFile=fixture.jks\nstorePassword=fixture\nkeyAlias=fixture\n',
    );
    await write('tool/lib/scan_artifact_secret.sh', r'''
scan_artifact_for_secret() {
  echo "scan:$(basename "$1")" >> "$FIXTURE/log"
  [[ "$(basename "$1")" != "${BAD_SCAN:-}" ]]
}
''');
    await executable('bin/git', r'''
echo "git:$*" >> "$FIXTURE/log"
case "$1" in
  status) [[ "${DIRTY:-false}" != true ]] || echo ' M source.dart' ;;
  branch) echo fixture-branch ;;
  rev-parse)
    if [[ "$2" == HEAD ]]; then echo "$SOURCE_COMMIT"
    elif [[ "$2" == *'^{commit}' ]]; then echo "${TAG_COMMIT:-$SOURCE_COMMIT}"
    else [[ "${LOCAL_TAG:-false}" == true ]]; fi ;;
  ls-remote) [[ "${REMOTE_FAIL:-false}" != true ]] ;;
  diff) exit 0 ;;
  *) [[ "${ALLOW_PUBLISH_FLOW:-false}" == true ]] || exit 90 ;;
esac
''');
    await executable('bin/flutter', r'''
echo "flutter:$*" >> "$FIXTURE/log"
[[ "$*" == *'--obfuscate'* && "$*" == *'--dart-define=NAVIS_SELF_UPDATE=true'* ]]
for arg in "$@"; do
  if [[ "$arg" == --dart-define-from-file=* ]]; then
    jq -e 'has("NAVIS_LASTFM_API_KEY_MASKED") and has("NAVIS_LASTFM_API_KEY_PAD")' "${arg#*=}" >/dev/null
  fi
done
python3 - "$@" <<'PY'
import os, pathlib, sys, zipfile
root = pathlib.Path(os.environ['FIXTURE']) / 'build/app/outputs/flutter-apk'
root.mkdir(parents=True, exist_ok=True)
names = ['app-sideload-release.apk']
if '--split-per-abi' in sys.argv:
    names = [f'app-{abi}-sideload-release.apk' for abi in ['arm64-v8a', 'armeabi-v7a', 'x86_64']]
for name in names:
    with zipfile.ZipFile(root / name, 'w') as apk:
        apk.writestr('libapp.so', 'Album Queue enabled for top tracks\n')
PY
''');
    await executable('bin/dart', 'echo "Fixture release notes"\n');
    await executable('bin/keytool', "echo 'SHA256: AB:CD:EF'\n");
    await executable('sdk/build-tools/fixture/aapt', r'''
echo "metadata:$(basename "$3")" >> "$FIXTURE/log"
echo "package: name='com.navis.app.navis${NAVIS_APP_ID_SUFFIX:-}' versionCode='10500' versionName='1.5.0'"
''');
    await executable('sdk/build-tools/fixture/apksigner', r'''
echo "signing:$(basename "$3")" >> "$FIXTURE/log"
echo 'Signer #1 certificate SHA-256 digest: abcdef'
''');
    await executable('tool/linux/build_in_container.sh', r'''
echo "linux:$*" >> "$FIXTURE/log"
[[ "$*" == *'--package=all'* && "$*" == *'--obfuscate'* ]]
prefix=navis
[[ "$*" != *'--asset-prefix=navis-dev'* ]] || prefix=navis-dev
for suffix in linux.tar.gz linux-amd64.deb linux-x86_64.rpm; do
  echo "$suffix fixture" > "$FIXTURE/$prefix-v1.5.0-$suffix"
done
''');
    await executable('tool/remote_build_windows.sh', r'''
echo "windows:$*" >> "$FIXTURE/log"
[[ "$*" == *'--ssh=fixture@builder'* && "$*" == *'--package=exe'* ]]
prefix=navis
[[ "$*" != *'--asset-prefix=navis-dev'* ]] || prefix=navis-dev
echo 'fixture installer' > "$FIXTURE/$prefix-v1.5.0-windows-installer.exe"
''');
    for (final command in ['ssh', 'scp']) {
      await executable('bin/$command', 'exit 90\n');
    }
    await executable('bin/curl', r'''
echo "curl:$*" >> "$FIXTURE/log"
[[ "${ALLOW_PUBLISH_FLOW:-false}" == true ]] || exit 90
echo '{"id":42}'
''');
    await executable('tool/r2_publish.sh', r'''
echo "r2:$*" >> "$FIXTURE/log"
[[ "${ALLOW_PUBLISH_FLOW:-false}" == true ]] || exit 90
if [[ "$1" == publish ]]; then
  for arg in "$@"; do
    case "$arg" in
      --notes-file=*) cp "${arg#*=}" "$FIXTURE/published-notes" ;;
      "$FIXTURE"/dist/*) sha256sum "$arg" >> "$FIXTURE/published-sums" ;;
    esac
  done
fi
''');
    // A fixture gate fails closed if a test forgets --skip-checks.
    await executable('tool/check.sh', 'exit 90\n');
  });

  tearDown(() => fixture.delete(recursive: true));

  test(
    'build-only stages eight assets and never invokes release actions',
    () async {
      final result = await run(buildArgs);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      final dist = p.join(fixture.path, 'dist', 'v1.5.0');
      expect(await File(p.join(dist, 'assets.txt')).readAsLines(), assets);
      final verified = await Process.run('/usr/bin/sha256sum', [
        '-c',
        'SHA256SUMS',
      ], workingDirectory: dist);
      expect(verified.exitCode, 0, reason: verified.stderr.toString());
      expect(
        result.stdout,
        contains('--publish-from=dist/v1.5.0 --skip-checks --forgejo'),
      );
      expect(
        await File(p.join(fixture.path, 'pubspec.yaml')).readAsString(),
        'version: 1.5.0+10500\n',
      );
      final calls = await log();
      expectNoReleaseActions(calls);
      for (final name in assets) {
        expect(calls, contains('scan:$name'));
        if (name.endsWith('.apk')) {
          expect(calls, containsAll(['metadata:$name', 'signing:$name']));
        }
      }
      final builds = calls.where((line) => line.startsWith('flutter:'));
      expect(builds, hasLength(2));
      expect(
        builds.where((line) => line.contains('--split-per-abi')),
        hasLength(1),
      );
      expect(
        Directory(p.join(fixture.path, 'build')).listSync().where(
          (entry) => p.basename(entry.path).startsWith('navis-secrets.'),
        ),
        isEmpty,
      );
    },
  );

  test(
    'publish-from uses staged bytes and notes without any builder',
    () async {
      await build();
      await write('log', '');
      // Stale root outputs cannot enter the publication asset list.
      for (final name in assets) {
        await write(name, 'different root artifact');
      }
      await File(p.join(fixture.path, 'android', 'key.properties')).delete();
      final result = await run(
        ['v1.5.0', '--publish-from=dist/v1.5.0', '--skip-checks', '--forgejo'],
        environment: {
          'ALLOW_PUBLISH_FLOW': 'true',
          'NAVIS_LASTFM_API_KEY': '',
          'FORGEJO_URL': 'https://fixture.invalid',
          'FORGEJO_REPO': 'fixture/Navis',
          'FORGEJO_TOKEN': 'fixture-token',
        },
      );
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      final calls = await log();
      expect(
        calls.where(
          (line) => RegExp('^(flutter|linux|windows|scan):').hasMatch(line),
        ),
        isEmpty,
      );
      expect(calls, contains('git:tag -a v1.5.0 -m Release v1.5.0 (stable)'));
      expect(calls, contains('git:push origin v1.5.0'));
      final publish = calls.singleWhere(
        (line) => line.startsWith('r2:publish'),
      );
      final uploads = calls.where((line) => line.startsWith('curl:'));
      expect(uploads, hasLength(assets.length + 1));
      final sums = await File(p.join(fixture.path, 'published-sums'))
          .readAsLines();
      expect(sums, hasLength(assets.length));
      for (final name in assets) {
        final path = p.join(fixture.path, 'dist', 'v1.5.0', name);
        expect(publish, contains(path));
        expect(
          uploads.any((line) => line.contains('attachment=@$path')),
          isTrue,
        );
        expect(File(path).existsSync(), isTrue);
        final checksum = await Process.run('/usr/bin/sha256sum', [path]);
        expect(sums, contains((checksum.stdout as String).trim()));
      }
      expect(
        await File(p.join(fixture.path, 'published-notes')).readAsString(),
        'Fixture release notes\n',
      );
    },
  );

  for (final (args, message) in [
    (['--build-only', '--publish-from=dist/v1.5.0'], 'cannot be combined'),
    (['--publish-from='], 'requires a directory'),
    (['--publish-from=dist/v1.5.0', '--targets=linux'], 'build options'),
    (['--build-only', '--targets=plan9'], 'Unsupported target'),
    (['--build-only', '--channel=invalid'], '--channel must'),
  ]) {
    test('rejects incompatible or invalid flags: $args', () async {
      final result = await run(['v1.5.0', ...args]);
      expect(result.exitCode, 1);
      expect(result.stdout, contains(message));
      expect(await log(), isEmpty);
    });
  }

  for (final file in [
    assets.first,
    'release.json',
    'assets.txt',
    'release-notes.md',
  ]) {
    test('checksum mismatch in $file blocks release actions', () async {
      await build();
      final target = File(p.join(fixture.path, 'dist', 'v1.5.0', file));
      await target.writeAsBytes([...await target.readAsBytes(), 10]);
      await write('log', '');
      final result = await run([
        'v1.5.0',
        '--publish-from=dist/v1.5.0',
        '--skip-checks',
      ]);
      expect(result.exitCode, 1);
      expect(result.stdout, contains('Error:'));
      expectNoReleaseActions(await log());
    });
  }

  for (final (environment, message) in [
    (
      {'SOURCE_COMMIT': '2222222222222222222222222222222222222222'},
      'HEAD differs',
    ),
    ({'DIRTY': 'true'}, 'Working tree is not clean'),
  ]) {
    test('$message blocks publication', () async {
      await build();
      await write('log', '');
      final result = await run([
        'v1.5.0',
        '--publish-from=dist/v1.5.0',
        '--skip-checks',
      ], environment: environment);
      expect(result.exitCode, 1);
      expect(result.stdout, contains(message));
      expectNoReleaseActions(await log());
    });
  }

  test('never overwrites an existing staged bundle', () async {
    await build();
    await write('log', '');
    final result = await run(buildArgs);
    expect(result.exitCode, 1);
    expect(result.stdout, contains('already exists'));
    expect((await log()).where((line) => line.startsWith('flutter:')), isEmpty);
    expectNoReleaseActions(await log());
  });

  test('failed secret scan never stages or publishes', () async {
    final result = await run(
      buildArgs,
      environment: {'BAD_SCAN': assets.first},
    );
    expect(result.exitCode, 1);
    expect(result.stdout, contains('contains the plaintext Last.fm API key'));
    expect(
      Directory(p.join(fixture.path, 'dist', 'v1.5.0')).existsSync(),
      isFalse,
    );
    expectNoReleaseActions(await log());
  });

  test(
    'local-only tag guard refuses existing tags without contacting origin',
    () async {
      final result = await run(buildArgs, environment: {'LOCAL_TAG': 'true'});
      expect(result.exitCode, 1);
      expect(result.stderr, contains('already released'));
      expectNoReleaseActions(await log());
    },
  );

  test('build-only requires the committed release version', () async {
    await write('pubspec.yaml', 'version: 1.4.3+10403\n');
    final result = await run(buildArgs);
    expect(result.exitCode, 1);
    expect(result.stdout, contains('commit that version before building'));
    expectNoReleaseActions(await log());
  });

  test('dev bundle retains channel and prerelease metadata', () async {
    await build(extra: ['--channel=dev']);
    final metadata = jsonDecode(
      await File(p.join(fixture.path, 'dist', 'v1.5.0', 'release.json'))
          .readAsString(),
    ) as Map<String, dynamic>;
    expect(metadata['channel'], 'dev');
    expect(metadata['prerelease'], true);
    await write('log', '');
    final mismatch = await run([
      'v1.5.0',
      '--publish-from=dist/v1.5.0',
      '--channel=stable',
      '--skip-checks',
    ]);
    expect(mismatch.exitCode, 1);
    expect(mismatch.stdout, contains('--channel differs'));
    expectNoReleaseActions(await log());
    final result = await run(
      ['v1.5.0', '--publish-from=dist/v1.5.0', '--skip-checks'],
      environment: {'ALLOW_PUBLISH_FLOW': 'true'},
    );
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(
      (await log()).singleWhere((line) => line.startsWith('r2:publish')),
      contains('--channel=dev'),
    );
  });

  for (final (contents, message) in [
    ('../outside.apk\n', 'Invalid staged asset name'),
    ('${assets.first}\n${assets.first}\n', 'Duplicate staged asset'),
    ('', 'Empty staged asset list'),
  ]) {
    test('$message fails closed', () async {
      await build();
      await write('dist/v1.5.0/assets.txt', contents);
      await write('log', '');
      final result = await run([
        'v1.5.0',
        '--publish-from=dist/v1.5.0',
        '--skip-checks',
      ]);
      expect(result.exitCode, 1);
      expect(result.stdout, contains(message));
      expectNoReleaseActions(await log());
    });
  }

  test('missing asset fails before release actions', () async {
    await build();
    await File(p.join(fixture.path, 'dist', 'v1.5.0', assets.first)).delete();
    await write('log', '');
    final result = await run([
      'v1.5.0',
      '--publish-from=dist/v1.5.0',
      '--skip-checks',
    ]);
    expect(result.exitCode, 1);
    expect(result.stdout, contains('Missing, empty or symlinked staged asset'));
    expectNoReleaseActions(await log());
  });

  test('symlinked asset fails before release actions', () async {
    await build();
    final path = p.join(fixture.path, 'dist', 'v1.5.0', assets.first);
    await File(path).delete();
    await Link(path).create(p.join(fixture.path, assets.first));
    await write('log', '');
    final result = await run([
      'v1.5.0',
      '--publish-from=dist/v1.5.0',
      '--skip-checks',
    ]);
    expect(result.exitCode, 1);
    expect(result.stdout, contains('symlinked staged asset'));
    expectNoReleaseActions(await log());
  });

  test('retry rejects a tag pointing at different source', () async {
    await build();
    await write('log', '');
    final result = await run(
      [
        'v1.5.0',
        '--publish-from=dist/v1.5.0',
        '--skip-checks',
        '--allow-existing-version',
      ],
      environment: {
        'LOCAL_TAG': 'true',
        'TAG_COMMIT': '2222222222222222222222222222222222222222',
      },
    );
    expect(result.exitCode, 1);
    expect(result.stdout, contains('Existing tag v1.5.0 differs'));
    final calls = await log();
    expect(calls.where((line) => line.startsWith('r2:')), isEmpty);
    expect(calls.where((line) => line.startsWith('git:push')), isEmpty);
  });

  test('retry reuses the correct source tag and preserves dist', () async {
    await build();
    await write('log', '');
    final result = await run(
      [
        'v1.5.0',
        '--publish-from=dist/v1.5.0',
        '--skip-checks',
        '--allow-existing-version',
      ],
      environment: {'LOCAL_TAG': 'true', 'ALLOW_PUBLISH_FLOW': 'true'},
    );
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    final calls = await log();
    expect(calls.where((line) => line.startsWith('git:tag ')), isEmpty);
    expect(calls, contains('git:push origin v1.5.0'));
    expect(
      File(p.join(fixture.path, 'dist', 'v1.5.0', assets.first)).existsSync(),
      isTrue,
    );
  });
}
