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
      final source = file.readAsStringSync();
      for (final match in RegExp(
        r'(?<![A-Za-z0-9_.])FlutterSecureStorage[(]',
      ).allMatches(source)) {
        if (!_balanced(
          source,
          match.end - 1,
        ).contains('mOptions: macOsLoginKeychain')) {
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
