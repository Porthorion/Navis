import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_media_kit/src/tls_options.dart';

void main() {
  test('verification off sets nothing', () {
    expect(tlsProperties(verify: false), isEmpty);
  });

  test('verification on leaves the CA source to libmpv', () {
    expect(tlsProperties(verify: true), {'tls-verify': 'yes'});
  });
}
