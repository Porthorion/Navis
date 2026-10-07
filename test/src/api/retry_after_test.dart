import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/retry_after.dart';

void main() {
  final now = DateTime.utc(2026, 10, 7, 12);
  test('delta seconds use injected clock including zero', () {
    expect(
      parseRetryAfter(' 120 ', now: () => now),
      now.add(const Duration(seconds: 120)),
    );
    expect(parseRetryAfter('0', now: () => now), now);
  });
  test('HTTP dates retain the server deadline', () {
    final deadline = now.add(const Duration(minutes: 2));
    expect(
      parseRetryAfter(HttpDate.format(deadline), now: () => now),
      deadline,
    );
  });
  test('missing malformed and negative values are ignored', () {
    for (final value in [null, '', 'invalid', '-1', '1.5']) {
      expect(parseRetryAfter(value, now: () => now), isNull);
    }
  });
}
