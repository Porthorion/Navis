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
        expect(packages, containsAll(['Inter font', 'AutoEq', 'color-names']));
        expect(packages.contains('mimalloc'), platform == TargetPlatform.linux);
        expect(
          packages.contains('Rust crates (Windows media controls)'),
          platform == TargetPlatform.windows,
        );
        final bundlesLibmpv =
            platform == TargetPlatform.linux ||
            platform == TargetPlatform.windows;
        expect(packages.contains('libmpv'), bundlesLibmpv);
        expect(packages.contains('FFmpeg'), bundlesLibmpv);
        for (final license in licenses) {
          expect(license.text.trim(), isNotEmpty);
        }
      },
    );
  }

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
        expect(license.text, contains('libmpv-windows-x86_64-lgpl-20261006'));
        expect(license.text, contains('libmpv-linux-x86_64-lgpl-20261007'));
      },
    );

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
          unorderedEquals(['Inter font', 'AutoEq', 'color-names']),
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
      unorderedEquals(['Inter font', 'AutoEq', 'color-names']),
    );
  });
}
