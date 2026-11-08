import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/auth/domain/server_identity_url.dart';

void main() {
  group('canonicalServerIdentityUrl', () {
    const cases = <String, String>{
      'https://music.example.test/': 'https://music.example.test',
      'https://music.example.test///': 'https://music.example.test',
      'HTTPS://Music.Example.test': 'https://music.example.test',
      'https://music.example.test:443/': 'https://music.example.test',
      'http://music.example.test:80/': 'http://music.example.test',
      'https://music.example.test:8443/': 'https://music.example.test:8443',
      'https://music.example.test/subsonic/rest///':
          'https://music.example.test/subsonic/rest',
      '  https://music.example.test/rest/  ': 'https://music.example.test/rest',
      ' music.example.test/rest/// ': 'music.example.test/rest',
      ' https://[invalid/// ': 'https://[invalid',
      'https:///rest///': 'https:///rest',
      'https://user:password@music.example.test/rest/?query=value#fragment':
          'https://music.example.test/rest',
    };

    for (final entry in cases.entries) {
      test('canonicalises ${entry.key}', () {
        expect(canonicalServerIdentityUrl(entry.key), entry.value);
      });
    }
  });
}
