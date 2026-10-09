import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/features/auth/data/server_connection_service.dart';

void main() {
  Future<void> probe({
    required int? errorCode,
    required String url,
    String version = '1.16.1',
    required bool legacyExpected,
  }) async {
    final requests = <Map<String, dynamic>>[];
    final service = SubsonicServerConnectionService(
      createDio: (url) {
        final dio = Dio(BaseOptions(baseUrl: url));
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (request, handler) {
              requests.add(Map<String, dynamic>.of(request.queryParameters));
              handler.next(request);
            },
          ),
        );
        // Respond after SubsonicAuthInterceptor has added authentication.
        dio.httpClientAdapter = _Adapter((request) {
          requests.last.addAll(request.queryParameters);
          final failed =
              request.path.contains('ping') &&
              !request.queryParameters.containsKey('p') &&
              errorCode != null;
          return {
            'subsonic-response': {
              'status': failed ? 'failed' : 'ok',
              'version': version,
              if (failed)
                'error': {'code': errorCode, 'message': 'fixture error'},
              if (request.path.contains('getOpenSubsonicExtensions'))
                'openSubsonicExtensions': <dynamic>[],
            },
          };
        });
        return dio;
      },
    );
    final result = service.probe(
      url: url,
      username: 'fixture',
      password: 'fixture-password',
    );
    if (errorCode == 40) {
      await expectLater(result, throwsA(isA<SubsonicAuthException>()));
    } else if (errorCode == 41 && url == 'http://example.com') {
      await expectLater(
        result,
        throwsA(isA<SubsonicInsecureLegacyAuthException>()),
      );
    } else {
      expect((await result).useLegacyAuth, legacyExpected);
    }
    expect(requests.any((request) => request.containsKey('p')), legacyExpected);
    expect(requests.first.containsKey('t'), isTrue);
    expect(requests.first.containsKey('p'), isFalse);
  }

  test(
    'wrong password never retries reversible password',
    () =>
        probe(errorCode: 40, url: 'https://example.com', legacyExpected: false),
  );
  test(
    'code 41 alone permits legacy fallback over HTTPS',
    () =>
        probe(errorCode: 41, url: 'https://example.com', legacyExpected: true),
  );
  test(
    'legacy fallback refuses remote HTTP before sending password',
    () =>
        probe(errorCode: 41, url: 'http://example.com', legacyExpected: false),
  );
  for (final host in ['localhost', '127.0.0.1', '[::1]']) {
    test(
      'loopback HTTP permits code 41 fallback: $host',
      () => probe(errorCode: 41, url: 'http://$host', legacyExpected: true),
    );
  }
  test(
    'old reported version keeps token auth for capabilities',
    () => probe(
      errorCode: null,
      url: 'https://example.com',
      version: '1.12.0',
      legacyExpected: false,
    ),
  );
}

class _Adapter implements HttpClientAdapter {
  new(this.respond);
  final Map<String, dynamic> Function(RequestOptions request) respond;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString(
    jsonEncode(respond(options)),
    200,
    headers: {
      Headers.contentTypeHeader: ['application/json'],
    },
  );

  @override
  void close({bool force = false}) {}
}
