import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/lrclib_client.dart';

void main() {
  group('LrclibClient', () {
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
