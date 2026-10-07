import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/app_licenses.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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
        expect(packages, isNot(contains('libmpv')));
        expect(packages, isNot(contains('FFmpeg')));
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
        final licenses = await entries(
          platform: platform,
          bundlesLgplLibmpv: true,
        );
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
