import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/equalizer/data/eq_platform_support.dart';

void main() {
  bool supported({
    bool android = false,
    bool linux = false,
    bool windows = false,
    bool macos = false,
    bool mediaKit = false,
  }) => navisEqualizerSupportedOn(
    android: android,
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

  test('other platforms do not', () {
    expect(supported(mediaKit: true), isFalse);
    expect(supported(), isFalse);
  });
}
