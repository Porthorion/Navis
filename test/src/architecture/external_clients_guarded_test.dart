import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every client of an external service takes its `Dio` from
/// `externalDioFactoryProvider`, so `IntegrationGuardInterceptor` stands
/// between the app and the network. A client constructed without one falls
/// back to a plain `Dio` and bypasses the policy. See "External integration
/// policy" in `docs/architecture.md`.
const _clients = <String, String>{
  'LastFmApiClient': 'dio',
  'ListenBrainzApiClient': 'dio',
  'LrclibClient': 'dio',
  'UpdateRepository': 'dio',
  'UpdateService': 'dio',
  'AutoEqCatalogue': 'client',
  'RadioMetadataService': 'dio',
};

void main() {
  test('external clients are built with a guarded Dio in application code', () {
    final violations = <String>[];
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'));
    for (final file in files) {
      final source = file.readAsStringSync();
      for (final entry in _clients.entries) {
        final constructor = RegExp('(?<![A-Za-z0-9_.])${entry.key}[(]');
        for (final match in constructor.allMatches(source)) {
          final call = _balanced(source, match.end - 1);
          // `new(` declarations and tear-offs do not match; a call without the
          // named argument does.
          if (!RegExp('\\b${entry.value}:').hasMatch(call)) {
            final line =
                '\n'.allMatches(source.substring(0, match.start)).length + 1;
            violations.add(
              '${file.path}:$line builds ${entry.key} without ${entry.value}:',
            );
          }
        }
      }
    }
    expect(violations, isEmpty, reason: violations.join('\n'));
  });

  test('the scan recognises an unguarded construction', () {
    const unguarded = 'final client = LastFmApiClient(apiKey: key);';
    final match = RegExp('LastFmApiClient[(]').firstMatch(unguarded)!;
    expect(
      RegExp(r'\bdio:').hasMatch(_balanced(unguarded, match.end - 1)),
      isFalse,
    );
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
