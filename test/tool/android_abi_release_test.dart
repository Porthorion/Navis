import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _abis = ['arm64-v8a', 'armeabi-v7a', 'x86_64'];
final _assetNames = [
  'navis-v1.5.0.apk',
  for (final abi in _abis) 'navis-v1.5.0-android-$abi.apk',
];

void main() {
  // Execute only extracted local build functions with fake tools. Never execute
  // release.sh's gates, tag/push/publish flow, or load release.env/real keys.
  final source = File('tool/release.sh').readAsStringSync();
  final cleanupFunctions = source.substring(
    source.indexOf('remove_release_asset() {'),
    source.indexOf('validate_apk_strings() {'),
  );
  final androidBuild = source.substring(
    source.indexOf('ASSET_FILES=()'),
    source.indexOf(r'''
if [[ "${BUILD_IOS}" == "true" ]]; then
  echo'''),
  );
  late Directory fixture;

  setUp(() async {
    fixture = await Directory.systemTemp.createTemp('navis-abi-test-');
    for (final directory in ['tool', 'android', 'sdk/build-tools/fixture']) {
      await Directory(p.join(fixture.path, directory)).create(recursive: true);
    }
    await File(p.join(fixture.path, 'android', 'key.properties')).writeAsString(
      'storeFile=fixture.jks\nstorePassword=fixture\nkeyAlias=fixture\n',
    );
    final toolsDir = p.join(fixture.path, 'sdk', 'build-tools', 'fixture');
    await File(p.join(toolsDir, 'aapt')).writeAsString(
      r'''
#!/bin/bash
set -eu
name="$(basename "$3")"
echo "metadata:$name" >> "$FIXTURE/log"
package=com.navis.app.navis code=10500 version=1.5.0
if [[ "$name" == "${BAD_APK:-}" ]]; then
  case "${BAD_FIELD:-}" in
    package) package=wrong ;;
    code) code=11500 ;;
    version) version=1.4.0 ;;
  esac
fi
echo "package: name='$package' versionCode='$code' versionName='$version'"
'''
          .trimLeft(),
    );
    await File(p.join(toolsDir, 'apksigner')).writeAsString(
      r'''
#!/bin/bash
set -eu
name="$(basename "$3")"
echo "signing:$name" >> "$FIXTURE/log"
cert=abcdef
if [[ "$name" == "${BAD_APK:-}" && "${BAD_FIELD:-}" == signer ]]; then cert=bad; fi
echo "Signer #1 certificate SHA-256 digest: $cert"
'''
          .trimLeft(),
    );
    final chmod = await Process.run('chmod', [
      '+x',
      p.join(toolsDir, 'aapt'),
      p.join(toolsDir, 'apksigner'),
    ]);
    expect(chmod.exitCode, 0);
  });
  tearDown(() => fixture.delete(recursive: true));

  Future<ProcessResult> build({String? badApk, String? badField}) async {
    final harness = File(p.join(fixture.path, 'harness.sh'));
    await harness.writeAsString(
      r'''
set -euo pipefail
SCRIPT_DIR="$FIXTURE/tool"
VERSION=v1.5.0 SEMVER=1.5.0 BUILD_NUMBER=10500 ASSET_PREFIX=navis
BUILD_ANDROID=true
DART_DEFINE_ARGS=(--dart-define=NAVIS_UPDATE_CHANNEL=stable '--dart-define-from-file=fixture with spaces.json')
scan_release_artifact() { echo "scan:$(basename "$1")" >> "$FIXTURE/log"; }
validate_apk_strings() { echo "strings:$(basename "$1")" >> "$FIXTURE/log"; }
keytool() { echo 'SHA256: AB:CD:EF'; }
flutter() {
  printf '%s\n' "$@" >> "$FIXTURE/args"
  local variant=universal symbols='' arg
  for arg in "$@"; do
    case "$arg" in
      --split-per-abi) variant=split ;;
      --split-debug-info=*) symbols="${arg#--split-debug-info=}" ;;
    esac
  done
  local outputs="$FIXTURE/build/app/outputs/flutter-apk"
  mkdir -p "$outputs"
  echo "$variant symbols" > "$symbols/app.android-arm64.symbols"
  if [[ "$variant" == universal ]]; then
    echo universal > "$outputs/app-sideload-release.apk"
  else
    # The universal must already have been preserved before cleanup/rebuild.
    [[ ! -f "$outputs/app-sideload-release.apk" ]]
    [[ "$(cat "$FIXTURE/navis-v1.5.0.apk")" == universal ]]
    local abi
    for abi in arm64-v8a armeabi-v7a x86_64; do
      echo "$abi" > "$outputs/app-$abi-sideload-release.apk"
    done
  fi
}
''' +
          cleanupFunctions +
          androidBuild +
          r'''
printf "%s\n" "${ASSET_NAMES[@]}" > "$FIXTURE/assets"
''',
    );
    return await Process.run(
      '/bin/bash',
      [harness.path],
      includeParentEnvironment: false,
      environment: {
        'PATH': '/usr/bin:/bin',
        'FIXTURE': fixture.path,
        'ANDROID_SDK_ROOT': p.join(fixture.path, 'sdk'),
        'BAD_APK': ?badApk,
        'BAD_FIELD': ?badField,
      },
    );
  }

  test(
    'stages four APKs with common flags, checks and separate symbols',
    () async {
      final result = await build();
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      final assets = await File(p.join(fixture.path, 'assets')).readAsLines();
      expect(assets, _assetNames);
      final log = await File(p.join(fixture.path, 'log')).readAsLines();
      for (final asset in _assetNames) {
        expect(
          log,
          containsAll([
            'scan:$asset',
            'metadata:$asset',
            'signing:$asset',
            'strings:$asset',
          ]),
        );
        expect(File(p.join(fixture.path, asset)).existsSync(), isTrue);
      }
      final args = await File(p.join(fixture.path, 'args')).readAsLines();
      for (final flag in [
        '--release',
        'sideload',
        '--dart-define=NAVIS_UPDATE_CHANNEL=stable',
        '--dart-define=NAVIS_SELF_UPDATE=true',
        '--dart-define-from-file=fixture with spaces.json',
      ]) {
        expect(args.where((arg) => arg == flag), hasLength(2));
      }
      expect(args, isNot(contains('--obfuscate')));
      expect(args.where((arg) => arg == '--split-per-abi'), hasLength(1));
      for (final (variant, contents) in [
        ('universal', 'universal symbols\n'),
        ('split-per-abi', 'split symbols\n'),
      ]) {
        final symbols = File(
          p.join(
            fixture.path,
            'build',
            'symbols',
            'android',
            'v1.5.0',
            variant,
            'app.android-arm64.symbols',
          ),
        );
        expect(await symbols.readAsString(), contents);
      }
    },
  );

  for (final asset in _assetNames) {
    for (final (field, message) in [
      ('package', 'APK package mismatch'),
      ('code', 'APK versionCode mismatch'),
      ('version', 'APK versionName mismatch'),
      ('signer', 'APK signer mismatch'),
    ]) {
      test('$asset rejects wrong $field', () async {
        final result = await build(badApk: asset, badField: field);
        expect(result.exitCode, 1);
        expect(result.stdout, contains(message));
      });
    }
  }

  test('R2 asset mapping keeps split keys distinct from universal', () async {
    final publisher = File('tool/r2_publish.sh').readAsStringSync();
    final mapping = publisher.substring(
      publisher.indexOf('asset_key_for() {'),
      publisher.indexOf('semver_core() {'),
    );
    final result = await Process.run('/bin/bash', [
      '-c',
      '$mapping\nfor name in "\$@"; do asset_key_for "\$name"; done',
      'asset-mapping-test',
      ..._assetNames,
      'navis-dev-v1.5.0-android-arm64-v8a.apk',
      'Navis-Dev-1.5.0-10500001-arm64.apk',
    ]);
    expect(result.exitCode, 0);
    expect((result.stdout as String).trim().split('\n'), [
      'androidApk',
      for (final abi in _abis) 'androidApk-$abi',
      'androidApk-arm64-v8a',
      'androidApk',
    ]);
  });

  test('Android Gradle configuration disables ABI version-code offsets', () {
    expect(
      File('android/gradle.properties').readAsLinesSync(),
      contains('force-version-code-ignoring-abi=true'),
    );
  });
}
