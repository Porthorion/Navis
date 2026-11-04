import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_media_kit/src/tls_options.dart';

void main() {
  test('verification off sets nothing, even with a CA file', () {
    expect(tlsProperties(verify: false), isEmpty);
    expect(tlsProperties(verify: false, caFile: '/etc/ssl/cert.pem'), isEmpty);
  });

  test('verification on without a CA file leaves the CA source to libmpv', () {
    expect(tlsProperties(verify: true), {'tls-verify': 'yes'});
  });

  test('a CA file is passed to libmpv only when set', () {
    expect(tlsProperties(verify: true, caFile: '/etc/ssl/cert.pem'), {
      'tls-verify': 'yes',
      'tls-ca-file': '/etc/ssl/cert.pem',
    });
  });
}
