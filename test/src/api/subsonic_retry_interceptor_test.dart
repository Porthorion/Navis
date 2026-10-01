import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/subsonic_retry_interceptor.dart';

void main() {
  group('SubsonicRetryInterceptor', () {
    test(
      'retries on transient socket errors and eventually succeeds',
      () async {
        final dio = Dio(BaseOptions(baseUrl: 'https://example.com'));
        var attempts = 0;

        dio.interceptors
          ..add(
            SubsonicRetryInterceptor(dio: dio, backoff: (_) => Duration.zero),
          )
          ..add(
            InterceptorsWrapper(
              onRequest: (options, handler) {
                attempts += 1;
                if (attempts < 2) {
                  handler.reject(
                    DioException(
                      requestOptions: options,
                      type: DioExceptionType.connectionError,
                      error: const SocketException('offline'),
                    ),
                    true,
                  );
                  return;
                }

                handler.resolve(
                  Response<dynamic>(
                    requestOptions: options,
                    statusCode: 200,
                    data: const <String, dynamic>{'ok': true},
                  ),
                );
              },
            ),
          );

        final response = await dio.get<dynamic>('/rest/ping.view');

        expect(response.statusCode, 200);
        expect(attempts, 2);
      },
    );

    test('does not retry on 4xx responses', () async {
      final dio = Dio(BaseOptions(baseUrl: 'https://example.com'));
      var attempts = 0;

      dio.interceptors
        ..add(SubsonicRetryInterceptor(dio: dio, backoff: (_) => Duration.zero))
        ..add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              attempts += 1;
              handler.reject(
                DioException(
                  requestOptions: options,
                  type: DioExceptionType.badResponse,
                  response: Response<dynamic>(
                    requestOptions: options,
                    statusCode: 400,
                    data: const <String, dynamic>{'error': 'bad request'},
                  ),
                ),
                true,
              );
            },
          ),
        );

      await expectLater(
        dio.get<dynamic>('/rest/ping.view'),
        throwsA(isA<DioException>()),
      );
      expect(attempts, 1);
    });

    test('retries on 530 responses and eventually succeeds', () async {
      final dio = Dio(BaseOptions(baseUrl: 'https://example.com'));
      var attempts = 0;

      dio.interceptors
        ..add(SubsonicRetryInterceptor(dio: dio, backoff: (_) => Duration.zero))
        ..add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              attempts += 1;
              if (attempts < 2) {
                handler.reject(
                  DioException(
                    requestOptions: options,
                    type: DioExceptionType.badResponse,
                    response: Response<dynamic>(
                      requestOptions: options,
                      statusCode: 530,
                      data: const <String, dynamic>{'error': 'origin down'},
                    ),
                  ),
                  true,
                );
                return;
              }

              handler.resolve(
                Response<dynamic>(
                  requestOptions: options,
                  statusCode: 200,
                  data: const <String, dynamic>{'ok': true},
                ),
              );
            },
          ),
        );

      final response = await dio.get<dynamic>('/rest/ping.view');

      expect(response.statusCode, 200);
      expect(attempts, 2);
    });
  });
}
