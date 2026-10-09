import 'dart:io';

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
