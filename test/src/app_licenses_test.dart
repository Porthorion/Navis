import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/app_licenses.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'every Windows Rust crate references bundled full licence text',
    () async {
      final notices = await rootBundle.loadString(
        'assets/licenses/windows-smtc-crates.txt',
      );
      expect(notices, isNot(contains('No licence file found')));
      final inventory = notices.split('Distinct licence texts').first;
      for (final block
          in inventory
              .split('\n\n')
              .skip(1)
              .where((block) => block.trim().isNotEmpty)) {
        final references = RegExp('licence text ([0-9a-f]{64})')
            .allMatches(block)
            .toList();
        expect(references, isNotEmpty, reason: block.split('\n').first);
        for (final reference in references) {
          expect(notices, contains('Licence text ${reference.group(1)}'));
        }
      }
      expect(
        notices,
        contains('Copyright (c) the flutter_rust_bridge authors'),
      );
      expect(
        notices,
        contains('Copyright (c) the flutter_rust_bridge_macros authors'),
      );
      expect(notices, contains('SPDX Apache-2.0 template: licence text'));
    },
  );

  setUp(LicenseRegistry.reset);
  tearDown(LicenseRegistry.reset);

  Future<List<LicenseEntryWithLineBreaks>> entries({
    required TargetPlatform platform,
    bool isWeb = false,
    bool? bundlesLgplLibmpv,
  }) async {
    if (bundlesLgplLibmpv == null) {
      registerBundledLicenses(platform: platform, isWeb: isWeb);
    } else {
      registerBundledLicenses(
        platform: platform,
        isWeb: isWeb,
        bundlesLgplLibmpv: bundlesLgplLibmpv,
      );
    }
    return (await LicenseRegistry.licenses.toList())
        .cast<LicenseEntryWithLineBreaks>();
  }

  for (final platform in TargetPlatform.values) {
    test(
      'registers bundled assets and correct native notices on $platform',
      () async {
        final licenses = await entries(platform: platform);
        final packages = licenses.expand((entry) => entry.packages).toSet();
        expect(
          packages,
          containsAll(['Navis', 'Inter font', 'AutoEq', 'color-names']),
        );
        expect(packages.contains('mimalloc'), platform == TargetPlatform.linux);
        expect(
          packages.contains('Rust crates (Windows media controls)'),
          platform == TargetPlatform.windows,
        );
        final bundlesLibmpv =
            platform == TargetPlatform.linux ||
            platform == TargetPlatform.windows ||
            platform == TargetPlatform.macOS;
        expect(packages.contains('libmpv'), bundlesLibmpv);
        expect(packages.contains('FFmpeg'), bundlesLibmpv);
        for (final license in licenses) {
          expect(license.text.trim(), isNotEmpty);
        }
      },
    );
  }

  test('Navis itself is registered under the bundled GPL text', () async {
    final licenses = await entries(platform: TargetPlatform.android);
    final navis = licenses.singleWhere((e) => e.packages.contains('Navis'));
    expect(navis.text, contains('GNU GENERAL PUBLIC LICENSE'));
  });

  test(
    'macOS lists the bundled libmpv, FFmpeg and Mbed TLS licences',
    () async {
      final licenses = await entries(platform: TargetPlatform.macOS);
      final license = licenses.singleWhere(
        (entry) => entry.packages.contains('libmpv'),
      );
      expect(license.packages, ['libmpv', 'FFmpeg']);
      final texts = [
        for (final asset in [
          'libmpv-macos-NOTICE.txt',
          'LGPL-2.1.txt',
          'LGPL-3.0.txt',
          'Apache-2.0.txt',
        ])
          await rootBundle.loadString('assets/licenses/$asset'),
      ];
      expect(license.text, texts.join('\n\n'));
      expect(license.text, contains('support@porthorion.com'));
      expect(license.text, contains('can be replaced'));
      expect(license.text, contains('Navis.app/Contents/Frameworks'));
      expect(license.text, contains('libmpv-darwin-build/releases/tag/v0.6.0'));
      expect(license.text, contains('Mbed TLS 3.4.1'));
      expect(license.text, contains('Apache License'));
      expect(license.text, contains('GNU LESSER GENERAL PUBLIC LICENSE'));
      expect(license.text, isNot(contains('libmpv-windows-x86_64')));
      expect(license.text, isNot(contains('libmpv-linux-x86_64')));
    },
  );

  for (final platform in [TargetPlatform.linux, TargetPlatform.windows]) {
    test(
      'enabled LGPL notice includes the source offer and full licence on $platform',
      () async {
        final licenses = await entries(platform: platform);
        final license = licenses.singleWhere(
          (entry) => entry.packages.contains('libmpv'),
        );
        expect(license.packages, ['libmpv', 'FFmpeg']);
        final notice = await rootBundle.loadString(
          'assets/licenses/libmpv-ffmpeg-NOTICE.txt',
        );
        final lgpl = await rootBundle.loadString(
          'assets/licenses/LGPL-2.1.txt',
        );
        expect(license.text, '$notice\n\n$lgpl');
        expect(license.text, contains('support@porthorion.com'));
        expect(license.text, contains('can be replaced'));
        expect(license.text, contains('libmpv-windows-x86_64-lgpl-20261013'));
        expect(license.text, contains('libmpv-linux-x86_64-lgpl-20261007'));
        expect(license.text, isNot(contains('Mbed TLS')));
      },
    );
  }

  for (final platform in [
    TargetPlatform.linux,
    TargetPlatform.windows,
    TargetPlatform.macOS,
  ]) {
    test(
      'system-libmpv builds can disable the bundle notice on $platform',
      () async {
        final licenses = await entries(
          platform: platform,
          bundlesLgplLibmpv: false,
        );
        expect(
          licenses.expand((entry) => entry.packages),
          isNot(contains('libmpv')),
        );
      },
    );

    test(
      'web excludes native notices even when the LGPL flag is enabled on $platform',
      () async {
        final licenses = await entries(
          platform: platform,
          isWeb: true,
          bundlesLgplLibmpv: true,
        );
        expect(
          licenses.expand((entry) => entry.packages),
          unorderedEquals(['Navis', 'Inter font', 'AutoEq', 'color-names']),
        );
      },
    );
  }

  test('LGPL flag does not add notices on Android', () async {
    final licenses = await entries(
      platform: TargetPlatform.android,
      bundlesLgplLibmpv: true,
    );
    expect(
      licenses.expand((entry) => entry.packages),
      unorderedEquals(['Navis', 'Inter font', 'AutoEq', 'color-names']),
    );
  });
}
