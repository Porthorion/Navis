import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/equalizer/data/eq_platform_support.dart';

void main() {
  bool supported({
    bool android = false,
    bool ios = false,
    bool linux = false,
    bool windows = false,
    bool macos = false,
    bool mediaKit = false,
  }) => navisEqualizerSupportedOn(
    android: android,
    ios: ios,
    linux: linux,
    windows: windows,
    macos: macos,
    mediaKitRegistered: mediaKit,
  );

  test('Android always supports the equalizer', () {
    expect(supported(android: true), isTrue);
  });

  test('Linux, Windows and macOS need the media_kit backend', () {
    expect(supported(linux: true, mediaKit: true), isTrue);
    expect(supported(windows: true, mediaKit: true), isTrue);
    expect(supported(macos: true, mediaKit: true), isTrue);
    expect(supported(linux: true), isFalse);
    expect(supported(windows: true), isFalse);
    expect(supported(macos: true), isFalse);
  });

  test('iOS always supports the equalizer (native tap, not media_kit)', () {
    expect(supported(ios: true), isTrue);
    expect(supported(ios: true, mediaKit: true), isTrue);
  });

  test('other platforms do not', () {
    expect(supported(mediaKit: true), isFalse);
    expect(supported(), isFalse);
  });

  test('fast seeking: Linux and Windows regardless of media_kit', () {
    for (final p in [TargetPlatform.linux, TargetPlatform.windows]) {
      for (final mk in [true, false]) {
        expect(
          navisFastSeekSupportedOn(platform: p, mediaKitRegistered: mk),
          isTrue,
        );
      }
    }
  });

  test('fast seeking: macOS only with media_kit registered', () {
    expect(
      navisFastSeekSupportedOn(
        platform: TargetPlatform.macOS,
        mediaKitRegistered: true,
      ),
      isTrue,
    );
    expect(
      navisFastSeekSupportedOn(
        platform: TargetPlatform.macOS,
        mediaKitRegistered: false,
      ),
      isFalse,
    );
  });

  test('fast seeking: Android and iOS never', () {
    for (final p in [TargetPlatform.android, TargetPlatform.iOS]) {
      expect(
        navisFastSeekSupportedOn(platform: p, mediaKitRegistered: true),
        isFalse,
      );
    }
  });
}
