import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/equalizer/data/eq_platform_support.dart';

void main() {
  bool supported({
    bool android = false,
    bool linux = false,
    bool windows = false,
    bool mediaKit = false,
  }) => navisEqualizerSupportedOn(
    android: android,
    linux: linux,
    windows: windows,
    mediaKitRegistered: mediaKit,
  );

  test('Android always supports the equalizer', () {
    expect(supported(android: true), isTrue);
  });

  test('Linux and Windows need the media_kit backend', () {
    expect(supported(linux: true, mediaKit: true), isTrue);
    expect(supported(windows: true, mediaKit: true), isTrue);
    expect(supported(linux: true), isFalse);
    expect(supported(windows: true), isFalse);
  });

  test('macOS and other platforms do not', () {
    expect(supported(mediaKit: true), isFalse);
    expect(supported(), isFalse);
  });
}
