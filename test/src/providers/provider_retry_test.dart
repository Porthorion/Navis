import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/providers/provider_retry.dart';

void main() {
  group('navisProviderRetry', () {
    test('never retries an error the server returned', () {
      for (final error in <Object>[
        const SubsonicNotFoundException(message: 'Not supported'),
        const SubsonicAuthException(message: 'Wrong password'),
        const SubsonicForbiddenException(message: 'Forbidden'),
        const SubsonicGenericException(message: 'Bad request', code: 400),
        const SubsonicGenericException(message: 'No code'),
        const SubsonicIncompleteResponseException('Partial'),
        StateError('bug'),
        const FormatException('bad json'),
      ]) {
        expect(navisProviderRetry(0, error), isNull, reason: '$error');
      }
    });

    test('retries a passing failure three times with growing delays', () {
      for (final error in <Object>[
        const SubsonicConnectionException('offline'),
        const SubsonicGenericException(message: 'Busy', code: 503),
        const SubsonicGenericException(message: 'Too many', code: 429),
        const SocketException('reset'),
        TimeoutException('slow'),
      ]) {
        expect(
          <Duration?>[for (var i = 0; i < 4; i++) navisProviderRetry(i, error)],
          const <Duration?>[
            Duration(milliseconds: 200),
            Duration(milliseconds: 400),
            Duration(milliseconds: 800),
            null,
          ],
          reason: '$error',
        );
      }
    });
  });

  test('a container with the policy shows a server error at once', () async {
    var calls = 0;
    final provider = FutureProvider<int>((ref) async {
      calls++;
      throw const SubsonicNotFoundException(message: 'Not supported');
    });
    final container = ProviderContainer(retry: navisProviderRetry);
    addTearDown(container.dispose);
    final subscription = container.listen(provider, (_, _) {});
    addTearDown(subscription.close);

    await expectLater(container.read(provider.future), throwsA(anything));
    await Future<void>.delayed(const Duration(milliseconds: 500));

    final state = container.read(provider);
    expect(state, isA<AsyncError<int>>());
    expect(state.isLoading, isFalse);
    expect(calls, 1);
  });
}
