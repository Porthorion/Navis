import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

// Windows, Linux and macOS bundles ship dynamically linked LGPL libmpv/FFmpeg.
const bool _bundlesLgplLibmpv = true;

/// Registers bundled assets and native libraries absent from Dart notices.
///
/// Platform and bundle flags can be overridden for licence-page tests.
void registerBundledLicenses({
  TargetPlatform? platform,
  bool isWeb = kIsWeb,
  bool bundlesLgplLibmpv = _bundlesLgplLibmpv,
}) {
  final target = platform ?? defaultTargetPlatform;
  LicenseRegistry.addLicense(() async* {
    for (final (packages, asset) in const <(List<String>, String)>[
      (['Navis'], 'LICENSE'),
      (['Inter font'], 'assets/fonts/OFL.txt'),
      (['AutoEq'], 'assets/autoeq/LICENSE'),
      (['color-names'], 'assets/licenses/color-names-MIT.txt'),
    ]) {
      yield LicenseEntryWithLineBreaks(
        packages,
        await rootBundle.loadString(asset),
      );
    }
    if (!isWeb && target == TargetPlatform.linux) {
      yield LicenseEntryWithLineBreaks(const [
        'mimalloc',
      ], await rootBundle.loadString('assets/licenses/mimalloc-MIT.txt'));
    }
    if (!isWeb && target == TargetPlatform.windows) {
      yield LicenseEntryWithLineBreaks(
        const ['Rust crates (Windows media controls)'],
        await rootBundle.loadString('assets/licenses/windows-smtc-crates.txt'),
      );
    }
    if (bundlesLgplLibmpv &&
        !isWeb &&
        (target == TargetPlatform.windows ||
            target == TargetPlatform.linux ||
            target == TargetPlatform.macOS)) {
      // macOS ships the media-kit build: FFmpeg is LGPL-3.0 and Mbed TLS is
      // Apache-2.0, so those texts follow the LGPL-2.1 one.
      final macOS = target == TargetPlatform.macOS;
      final notice = await rootBundle.loadString(
        macOS
            ? 'assets/licenses/libmpv-macos-NOTICE.txt'
            : 'assets/licenses/libmpv-ffmpeg-NOTICE.txt',
      );
      final licenses = [
        await rootBundle.loadString('assets/licenses/LGPL-2.1.txt'),
        if (macOS) ...[
          await rootBundle.loadString('assets/licenses/LGPL-3.0.txt'),
          await rootBundle.loadString('assets/licenses/Apache-2.0.txt'),
        ],
      ];
      yield LicenseEntryWithLineBreaks(const [
        'libmpv',
        'FFmpeg',
      ], [notice, ...licenses].join('\n\n'));
    }
  });
}
