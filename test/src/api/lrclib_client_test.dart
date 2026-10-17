import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:navis/src/api/request_limiter.dart';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/lrclib_client.dart';

void main() {
  group('LrclibClient', () {
    for (final status in [429, 503]) {
      for (final header in ['30', 'date', null, 'malformed']) {
        test(
          'cooldown status=$status header=$header blocks both calls and recovers',
          () async {
            var now = DateTime.utc(2026, 10, 7, 12);
            final initial = now;
            final seconds = header == '30' || header == 'date' ? 30 : 60;
            var requests = 0;
            final dio = Dio();
            addTearDown(dio.close);
            dio.interceptors.add(
              InterceptorsWrapper(
                onRequest: (options, handler) {
                  requests++;
                  if (requests == 1) {
                    handler.reject(
                      DioException(
                        requestOptions: options,
                        response: Response<dynamic>(
                          requestOptions: options,
                          statusCode: status,
                          headers: Headers.fromMap({
                            if (header != null)
                              'retry-after': [
                                if (header == 'date')
                                  HttpDate.format(
                                    initial.add(const Duration(seconds: 30)),
                                  )
                                else
                                  header,
                              ],
                          }),
                        ),
                      ),
                    );
                  } else {
                    handler.resolve(
                      Response<dynamic>(
                        requestOptions: options,
                        statusCode: 200,
                        data: options.path == '/api/search'
                            ? <dynamic>[]
                            : <String, dynamic>{},
                      ),
                    );
                  }
                },
              ),
            );
            final client = LrclibClient(dio: dio, now: () => now);
            await expectLater(
              client.getLyrics(artist: 'Fixture', title: 'Track'),
              throwsA(isA<LrclibRateLimitedException>()),
            );
            expect(client.isRateLimited, isTrue);
            await expectLater(
              client.getLyrics(artist: 'Fixture', title: 'Track'),
              throwsA(isA<LrclibRateLimitedException>()),
            );
            await expectLater(
              client.searchLyrics(artist: 'Fixture', title: 'Track'),
              throwsA(isA<LrclibRateLimitedException>()),
            );
            expect(requests, 1);
            now = initial.add(Duration(seconds: seconds));
            expect(client.isRateLimited, isFalse);
            expect(
              await client.searchLyrics(artist: 'Fixture', title: 'Track'),
              isEmpty,
            );
            expect(requests, 2);
          },
        );
      }
    }
    test('Retry-After is capped at ten minutes', () async {
      var now = DateTime.utc(2026, 10, 18);
      final dio = Dio();
      addTearDown(dio.close);
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (o, h) {
            h.resolve(
              Response<dynamic>(
                requestOptions: o,
                statusCode: 429,
                headers: Headers.fromMap({
                  'retry-after': ['36000'],
                }),
              ),
            );
          },
        ),
      );
      final client = LrclibClient(dio: dio, now: () => now);
      await expectLater(
        client.searchLyrics(artist: 'Artist', title: 'Track'),
        throwsA(isA<LrclibRateLimitedException>()),
      );
      now = now.add(const Duration(minutes: 10));
      expect(client.isRateLimited, isFalse);
    });

    test('Retry-After zero still pauses before retrying', () async {
      var now = DateTime.utc(2026, 10, 18);
      final dio = Dio();
      addTearDown(dio.close);
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (o, h) {
            h.resolve(
              Response<dynamic>(
                requestOptions: o,
                statusCode: 429,
                headers: Headers.fromMap({
                  'retry-after': ['0'],
                }),
              ),
            );
          },
        ),
      );
      final client = LrclibClient(dio: dio, now: () => now);
      await expectLater(
        client.searchLyrics(artist: 'Artist', title: 'Track'),
        throwsA(isA<LrclibRateLimitedException>()),
      );
      expect(client.isRateLimited, isTrue);
      now = now.add(const Duration(seconds: 1));
      expect(client.isRateLimited, isFalse);
    });

    test(
      'headerless cooldown doubles to the cap and success resets it',
      () async {
        var now = DateTime.utc(2026, 10, 18);
        final initial = now;
        var status = 503;
        final dio = Dio();
        addTearDown(dio.close);
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (o, h) {
              h.resolve(
                Response<dynamic>(
                  requestOptions: o,
                  statusCode: status,
                  data: <dynamic>[],
                ),
              );
            },
          ),
        );
        final client = LrclibClient(
          dio: dio,
          now: () => now,
          limiter: RequestLimiter(elapsed: () => now.difference(initial)),
        );
        Future<void> limited() => expectLater(
          client.searchLyrics(artist: 'Artist', title: 'Track'),
          throwsA(isA<LrclibRateLimitedException>()),
        );
        for (final seconds in [60, 120, 240, 480, 600, 600]) {
          await limited();
          now = now.add(Duration(seconds: seconds - 1));
          expect(client.isRateLimited, isTrue);
          now = now.add(const Duration(seconds: 1));
          expect(client.isRateLimited, isFalse);
        }
        status = 200;
        await client.searchLyrics(artist: 'Artist', title: 'Track');
        status = 503;
        await limited();
        now = now.add(const Duration(seconds: 60));
        expect(client.isRateLimited, isFalse);
      },
    );

    test('foreground lookups overtake paced background requests', () {
      fakeAsync((async) {
        final starts = <String>[];
        final dio = Dio();
        addTearDown(dio.close);
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (o, h) {
              starts.add(o.queryParameters['track_name'] as String);
              h.resolve(
                Response<dynamic>(
                  requestOptions: o,
                  statusCode: 200,
                  data: <dynamic>[],
                ),
              );
            },
          ),
        );
        final client = LrclibClient(
          dio: dio,
          limiter: RequestLimiter(
            maxPerWindow: 2,
            maxBackgroundPerWindow: 1,
            maxInFlight: 2,
            elapsed: () => async.elapsed,
          ),
        );
        unawaited(
          client.searchLyrics(
            artist: 'Artist',
            title: 'background 1',
            background: true,
          ),
        );
        unawaited(
          client.searchLyrics(
            artist: 'Artist',
            title: 'background 2',
            background: true,
          ),
        );
        async.elapse(Duration.zero);
        expect(starts, ['background 1']);
        unawaited(client.searchLyrics(artist: 'Artist', title: 'foreground'));
        async.elapse(Duration.zero);
        expect(starts, ['background 1', 'foreground']);
        async.elapse(const Duration(seconds: 1));
        expect(starts, ['background 1', 'foreground', 'background 2']);
      });
    });

    test('queued background lookups can be cancelled before they start', () {
      fakeAsync((async) {
        var starts = 0;
        var cancelled = false;
        final dio = Dio();
        addTearDown(dio.close);
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (o, h) {
              starts++;
              h.resolve(
                Response<dynamic>(
                  requestOptions: o,
                  statusCode: 200,
                  data: <dynamic>[],
                ),
              );
            },
          ),
        );
        final client = LrclibClient(
          dio: dio,
          limiter: RequestLimiter(
            maxBackgroundPerWindow: 1,
            elapsed: () => async.elapsed,
          ),
        );
        unawaited(
          client.searchLyrics(
            artist: 'Artist',
            title: 'first',
            background: true,
          ),
        );
        async.elapse(Duration.zero);
        final token = CancelToken();
        unawaited(
          client
              .searchLyrics(
                artist: 'Artist',
                title: 'queued',
                background: true,
                cancelToken: token,
              )
              .then<void>(
                (_) => fail('started'),
                onError: (Object error) {
                  expect(error, isA<DioException>());
                  expect(CancelToken.isCancel(error as DioException), isTrue);
                  cancelled = true;
                },
              ),
        );
        token.cancel();
        async.elapse(Duration.zero);
        expect(cancelled, isTrue);
        expect(starts, 1);
        async.elapse(const Duration(seconds: 1));
        expect(starts, 1);
      });
    });

    test('search treats 404 as no results and 429 as cooldown', () async {
      var status = 404;
      final dio = Dio();
      addTearDown(dio.close);
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.reject(
              DioException(
                requestOptions: options,
                response: Response<dynamic>(
                  requestOptions: options,
                  statusCode: status,
                ),
              ),
            );
          },
        ),
      );
      final client = LrclibClient(dio: dio);
      expect(
        await client.searchLyrics(artist: 'Fixture', title: 'Track'),
        isEmpty,
      );
      status = 429;
      await expectLater(
        client.searchLyrics(artist: 'Fixture', title: 'Track'),
        throwsA(isA<LrclibRateLimitedException>()),
      );
      expect(client.isRateLimited, isTrue);
    });

    test('getLyrics returns null for exact lookup 404', () async {
      final dio = Dio(BaseOptions(baseUrl: 'https://lrclib.example'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.reject(
              DioException(
                requestOptions: options,
                response: Response<dynamic>(
                  requestOptions: options,
                  statusCode: 404,
                ),
                type: DioExceptionType.badResponse,
              ),
            );
          },
        ),
      );
      final client = LrclibClient(dio: dio);

      final lyrics = await client.getLyrics(
        artist: 'Evanescence',
        title: 'Bring Me To Life',
      );

      expect(lyrics, isNull);
    });

    test('getLyrics rethrows non-404 Dio failures', () async {
      final dio = Dio(BaseOptions(baseUrl: 'https://lrclib.example'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.reject(
              DioException(
                requestOptions: options,
                response: Response<dynamic>(
                  requestOptions: options,
                  statusCode: 500,
                ),
                type: DioExceptionType.badResponse,
              ),
            );
          },
        ),
      );
      final client = LrclibClient(dio: dio);

      await expectLater(
        client.getLyrics(artist: 'Evanescence', title: 'Bring Me To Life'),
        throwsA(isA<DioException>()),
      );
    });
  });
}
