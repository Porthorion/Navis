import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';

void main() {
  group('SubsonicAuthInterceptor', () {
    test('injects token auth params and forces json format', () async {
      final dio = Dio(BaseOptions(baseUrl: 'https://example.com'));
      final interceptor = SubsonicAuthInterceptor(
        config: const SubsonicAuthConfig(
          username: 'alice',
          password: 'secret',
          apiVersion: '1.16.1',
        ),
      );

      late RequestOptions captured;
      dio.interceptors
        ..add(interceptor)
        ..add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              captured = options;
              handler.resolve(
                Response<dynamic>(
                  requestOptions: options,
                  statusCode: 200,
                  data: const <String, dynamic>{},
                ),
              );
            },
          ),
        );

      await dio.get<dynamic>('/rest/ping.view');

      expect(captured.queryParameters['u'], 'alice');
      expect(captured.queryParameters['v'], '1.16.1');
      expect(captured.queryParameters['f'], 'json');
      expect(captured.queryParameters['s'], isNotNull);
      expect(captured.queryParameters['t'], isNotNull);
      expect(captured.queryParameters.containsKey('p'), isFalse);
    });

    test('injects legacy password auth when configured', () async {
      final dio = Dio(BaseOptions(baseUrl: 'https://example.com'));
      final interceptor = SubsonicAuthInterceptor(
        config: const SubsonicAuthConfig(
          username: 'bob',
          password: 'hunter2',
          apiVersion: '1.12.0',
          authType: SubsonicAuthType.legacyPassword,
        ),
      );

      late RequestOptions captured;
      dio.interceptors
        ..add(interceptor)
        ..add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              captured = options;
              handler.resolve(
                Response<dynamic>(
                  requestOptions: options,
                  statusCode: 200,
                  data: const <String, dynamic>{},
                ),
              );
            },
          ),
        );

      await dio.get<dynamic>('/rest/ping.view');

      expect(captured.queryParameters['u'], 'bob');
      expect(captured.queryParameters['f'], 'json');
      expect('${captured.queryParameters['p']}', startsWith('enc:'));
      expect(captured.queryParameters.containsKey('t'), isFalse);
      expect(captured.queryParameters.containsKey('s'), isFalse);
    });
  });
}
