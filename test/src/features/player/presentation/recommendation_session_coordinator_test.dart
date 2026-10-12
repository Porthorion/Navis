import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/player/presentation/recommendation_session_coordinator.dart';
import 'package:navis/src/providers/app_providers.dart';

import '../../../../helpers/recommendation_test_harness.dart';

class _Adapter implements HttpClientAdapter {
  final tokens = <CancelToken>[];
  Future<void> Function()? beforeResponse;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    tokens.add(options.cancelToken!);
    await beforeResponse?.call();
    return ResponseBody.fromString('fixture', 200);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('completed and failed requests release their tokens', () async {
    final container = createRecommendationContainer(
      overrides: [
        audioHandlerProvider.overrideWithValue(null),
        subsonicApiProvider.overrideWithValue(null),
      ],
    );
    final coordinator = container.read(recommendationSessionProvider.notifier);
    final session = coordinator.start(RecommendationMode.personalRadio);
    final tokens = <CancelToken>[];
    for (var i = 0; i < 3; i++) {
      expect(
        await session.withCancelToken((token) async {
          tokens.add(token);
          return i;
        }),
        i,
      );
    }
    await expectLater(
      session.withCancelToken<void>((token) async {
        tokens.add(token);
        throw StateError('fixture failure');
      }),
      throwsStateError,
    );

    coordinator.stop(session);
    expect(Set<CancelToken>.identity()..addAll(tokens), hasLength(4));
    expect(tokens.every((token) => !token.isCancelled), isTrue);
  });

  for (final action in ['stopped', 'replaced', 'disposed']) {
    test('$action sessions cancel in-flight and later requests', () async {
      final container = createRecommendationContainer(
        overrides: [
          audioHandlerProvider.overrideWithValue(null),
          subsonicApiProvider.overrideWithValue(null),
        ],
      );
      final coordinator = container.read(
        recommendationSessionProvider.notifier,
      );
      final session = coordinator.start(RecommendationMode.serverMix);
      final adapter = _Adapter();
      final dio = Dio()..httpClientAdapter = adapter;
      addTearDown(() => dio.close(force: true));
      Future<Response<String>> request() => session.withCancelToken(
        (token) => dio.get<String>('https://example.com', cancelToken: token),
      );
      final started = Completer<void>();
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      adapter.beforeResponse = () {
        if (adapter.tokens.length == 2) started.complete();
        return release.future;
      };
      final cancelled = throwsA(
        isA<DioException>()
            .having((error) => error.type, 'type', DioExceptionType.cancel)
            .having(
              (error) => error.error,
              'reason',
              'recommendation session $action',
            ),
      );
      final first = expectLater(request(), cancelled);
      final second = expectLater(request(), cancelled);
      await started.future;

      switch (action) {
        case 'stopped':
          coordinator.stop(session);
        case 'replaced':
          coordinator.start(RecommendationMode.personalRadio);
        case 'disposed':
          container.dispose();
      }
      await Future.wait([first, second]);
      expect(session.isCancelled, isTrue);
      expect(adapter.tokens.every((token) => token.isCancelled), isTrue);
      expect(Set<CancelToken>.identity()..addAll(adapter.tokens), hasLength(2));

      await expectLater(request(), cancelled);
      await expectLater(request(), cancelled);
      // Dio rejects pre-cancelled tokens before dispatching to the adapter.
      expect(adapter.tokens, hasLength(2));
    });
  }

  test('stopping a replaced session preserves the new session', () async {
    final container = createRecommendationContainer(
      overrides: [
        audioHandlerProvider.overrideWithValue(null),
        subsonicApiProvider.overrideWithValue(null),
      ],
    );
    final coordinator = container.read(recommendationSessionProvider.notifier);
    final oldSession = coordinator.start(RecommendationMode.serverMix);
    final current = coordinator.start(RecommendationMode.personalRadio);
    coordinator.stop(oldSession);

    expect(coordinator.owns(oldSession), isFalse);
    expect(coordinator.owns(current), isTrue);
    await current.withCancelToken((token) async {
      expect(token.isCancelled, isFalse);
    });
  });
}
