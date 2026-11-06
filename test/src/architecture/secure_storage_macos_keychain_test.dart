import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/auth/data/secure_credential_store.dart';

/// The plugin defaults macOS to the data-protection keychain, which needs a
/// `keychain-access-groups` entitlement no Navis build has: every write fails
/// with -34018 and the credential lasts only for the session. Each
/// `FlutterSecureStorage` Navis builds must pass `macOsLoginKeychain`
/// (`mOptions` only affects macOS).
void main() {
  test('every FlutterSecureStorage is built with the login keychain', () {
    final violations = <String>[];
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'));
    for (final file in files) {
      // Whole-line comments only; line numbers stay intact.
      final source = file.readAsStringSync().replaceAll(
        RegExp(r'^\s*//.*$', multiLine: true),
        '',
      );
      for (final match in RegExp(
        r'\bFlutterSecureStorage(\.new)?\s*\(',
      ).allMatches(source)) {
        if (!RegExp(r'\bmOptions:\s*macOsLoginKeychain\b')
            .hasMatch(_balanced(source, match.end - 1))) {
          final line =
              '\n'.allMatches(source.substring(0, match.start)).length + 1;
          violations.add(
            '${file.path}:$line lacks mOptions: macOsLoginKeychain',
          );
        }
      }
    }
    expect(violations, isEmpty, reason: violations.join('\n'));
  });

  test('every credential FlutterSecureStorage is built with iosKeychain', () {
    // The desktop shortcut store never runs on iOS, so it is exempt.
    final violations = <String>[];
    for (final path in [
      'lib/src/features/auth/data/secure_credential_store.dart',
      'lib/src/features/settings/data/external_scrobble_credentials.dart',
    ]) {
      final source = File(path).readAsStringSync();
      for (final match in RegExp(
        r'\bFlutterSecureStorage(\.new)?\s*\(',
      ).allMatches(source)) {
        if (!RegExp(r'\biOptions:\s*iosKeychain\b')
            .hasMatch(_balanced(source, match.end - 1))) {
          violations.add('$path lacks iOptions: iosKeychain');
        }
      }
    }
    expect(violations, isEmpty, reason: violations.join('\n'));
  });

  test(
    'iosKeychain is readable after first unlock under the Navis service',
    () {
      final map = iosKeychain.toMap();
      expect(map['accessibility'], 'first_unlock');
      expect(map['accountName'], 'com.navis.app.navis');
      expect(IOSOptions.defaultOptions.toMap()['accessibility'], 'unlocked');
    },
  );

  test('durable credentials are required on Android and iOS only', () {
    bool required({bool isAndroid = false, bool isIOS = false}) =>
        mustPersistDurableCredentialsOn(isAndroid: isAndroid, isIOS: isIOS);
    expect(required(isAndroid: true), isTrue);
    expect(required(isIOS: true), isTrue);
    expect(required(), isFalse);
  });

  test('macOsLoginKeychain opts out of the data-protection keychain', () {
    expect(macOsLoginKeychain.usesDataProtectionKeychain, isFalse);
    expect(const MacOsOptions().usesDataProtectionKeychain, isTrue);
  });
}

/// The text of the parenthesised argument list that opens at [open].
String _balanced(String source, int open) {
  var depth = 0;
  for (var i = open; i < source.length; i++) {
    final char = source[i];
    if (char == '(') depth++;
    if (char == ')') {
      depth--;
      if (depth == 0) return source.substring(open, i + 1);
    }
  }
  return source.substring(open);
}
