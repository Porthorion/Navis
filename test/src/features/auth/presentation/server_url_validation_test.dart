import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations_en.dart';
import 'package:navis/src/features/auth/presentation/server_url_validation.dart';

void main() {
  final l10n = AppLocalizationsEn();

  test('normalizeServerUrl trims whitespace and one trailing slash', () {
    expect(normalizeServerUrl('  https://a.example/  '), 'https://a.example');
    expect(normalizeServerUrl('https://a.example//'), 'https://a.example/');
    expect(normalizeServerUrl('https://a.example/x'), 'https://a.example/x');
  });

  test('parseServerUrl requires a scheme and a host', () {
    expect(parseServerUrl('https://a.example/')?.host, 'a.example');
    expect(parseServerUrl('HTTPS://A.example')?.scheme, 'https');
    expect(parseServerUrl('a.example'), isNull);
    expect(parseServerUrl('a.example:4533'), isNull);
    expect(parseServerUrl('https://'), isNull);
    expect(parseServerUrl(''), isNull);
  });

  test('validateServerUrl', () {
    expect(
      validateServerUrl(null, l10n),
      l10n.loginValidationServerUrlRequired,
    );
    expect(
      validateServerUrl('  ', l10n),
      l10n.loginValidationServerUrlRequired,
    );
    expect(
      validateServerUrl('a.example', l10n),
      l10n.loginValidationServerUrlInvalid,
    );
    expect(
      validateServerUrl('ftp://a.example', l10n),
      l10n.loginValidationServerUrlInvalid,
    );
    expect(validateServerUrl(' HTTP://a.example/ ', l10n), isNull);
    expect(validateServerUrl('https://a.example', l10n), isNull);
  });

  test('isInsecureHttpUrl is true for any http host, any case', () {
    expect(isInsecureHttpUrl('http://a.example'), isTrue);
    expect(isInsecureHttpUrl('HTTP://a.example'), isTrue);
    expect(isInsecureHttpUrl('http://localhost'), isTrue);
    expect(isInsecureHttpUrl('https://a.example'), isFalse);
    expect(isInsecureHttpUrl('a.example'), isFalse);
  });

  group('isInsecureRemoteHttpUrl', () {
    const loopback = [
      'http://localhost',
      'http://LOCALHOST:4533/',
      'http://127.0.0.1',
      'http://127.1.2.3:4533',
      'http://[::1]',
      'http://[::1]:4533/',
      ' HTTP://127.0.0.1/ ',
    ];
    for (final url in loopback) {
      test('loopback is not remote: $url', () {
        expect(isInsecureRemoteHttpUrl(url), isFalse);
      });
    }

    const remote = [
      'http://a.example',
      'http://192.168.1.10:4533',
      'http://10.0.0.5',
      'http://172.16.0.1',
      'http://8.8.8.8',
      'http://navidrome.local',
      'http://127.0.0.1.evil.example',
      'http://localhost.evil.example',
      'http://0.0.0.0',
      'http://[::ffff:8.8.8.8]',
    ];
    for (final url in remote) {
      test('remote over http is flagged: $url', () {
        expect(isInsecureRemoteHttpUrl(url), isTrue);
      });
    }

    test('https and unparseable input are never flagged', () {
      expect(isInsecureRemoteHttpUrl('https://a.example'), isFalse);
      expect(isInsecureRemoteHttpUrl('https://192.168.1.10'), isFalse);
      expect(isInsecureRemoteHttpUrl('a.example'), isFalse);
      expect(isInsecureRemoteHttpUrl(''), isFalse);
    });

    // Pins current behaviour: a trailing dot is not recognised as localhost.
    test('localhost. (trailing dot) is treated as remote', () {
      expect(isInsecureRemoteHttpUrl('http://localhost.'), isTrue);
    });
  });
}
