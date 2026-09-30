import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/api/sync_request_scope.dart';

void main() {
  SyncRequestScope scope({
    int requests = 10,
    int bytes = 10000,
    bool Function()? allowed,
  }) => SyncRequestScope(
    allowedEndpoints: {'getPlaylists'},
    maxRequests: requests,
    maxNewestPages: 1,
    maxAlbumHydrations: 1,
    maxResponseBytes: bytes,
    maxTotalBytes: bytes,
    maxConcurrency: 2,
    maxDuration: const Duration(seconds: 30),
    canRequest: allowed ?? () => true,
  );
  SubsonicApiClient client(Dio dio) => SubsonicApiClient(
    baseUrl: 'https://example.test',
    authConfig: const SubsonicAuthConfig(
      username: 'fixture',
      password: 'fixture',
      apiVersion: '1.16.1',
    ),
    dio: dio,
    enableLogging: false,
  );

  test(
    'retry telemetry joins attempts without retaining payloads or credentials',
    () async {
      final dio = Dio();
      var calls = 0;
      final failed = {'error': 'private-response-body'};
      final accepted = {
        'subsonic-response': {
          'status': 'ok',
          'playlists': {'playlist': <Object?>[]},
        },
      };
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (calls++ == 0) {
              handler.reject(
                DioException(
                  requestOptions: options,
                  type: DioExceptionType.badResponse,
                  response: Response<dynamic>(
                    requestOptions: options,
                    statusCode: 503,
                    data: failed,
                    headers: Headers.fromMap({
                      'retry-after': ['0'],
                    }),
                  ),
                ),
                true,
              );
            } else {
              handler.resolve(
                Response<dynamic>(
                  requestOptions: options,
                  statusCode: 200,
                  data: accepted,
                ),
                true,
              );
            }
          },
        ),
      );
      final budget = scope();
      await budget.run(() => client(dio).getPlaylists());
      final telemetry = budget.transportTelemetry();
      final attempts = telemetry['attempts']! as List;
      expect(budget.requestCount, 2);
      expect(budget.retryCount, 1);
      expect(telemetry['failed'], 1);
      expect(telemetry['envelopeAccepted'], 1);
      expect(telemetry['running'], 0);
      expect(
        budget.byteCount,
        utf8.encode(jsonEncode(failed)).length +
            utf8.encode(jsonEncode(accepted)).length,
      );
      expect(attempts.map((e) => e['requestOrdinal']), [1, 1]);
      expect(attempts.map((e) => e['retry']), [0, 1]);
      expect(attempts.map((e) => e['outcome']), ['failed', 'envelopeAccepted']);
      expect(telemetry['endpointBytes'], {'getPlaylists': budget.byteCount});
      expect(jsonEncode(telemetry), isNot(contains('private-response-body')));
      expect(jsonEncode(telemetry), isNot(contains('example.test')));
      expect(jsonEncode(telemetry), isNot(contains('fixture')));
    },
  );

  test('bounded attempt traces retain complete aggregate accounting', () {
    final budget = scope(requests: 200, bytes: 100000);
    for (var i = 1; i <= 150; i++) {
      final attempt = budget.beginTransport('getPlaylists');
      attempt.observe(i);
      attempt.observe(i - 1);
      attempt.finish(succeeded: true);
    }
    final telemetry = budget.transportTelemetry();
    expect(telemetry['attempts'], hasLength(128));
    expect(telemetry['omittedAttempts'], 22);
    expect(telemetry['requests'], 150);
    expect(telemetry['envelopeAccepted'], 150);
    expect(telemetry['running'], 0);
    expect(telemetry['bytes'], 11325);
  });

  test(
    'concurrency is bounded and a policy stop releases all waiters',
    () async {
      var allowed = true;
      var active = 0;
      var maximum = 0;
      final gate = Completer<void>();
      final budget = scope(allowed: () => allowed);
      final work = budget.run(
        () => Future.wait(
          List.generate(20, (_) async {
            try {
              await budget.request('getPlaylists', () async {
                active++;
                if (active > maximum) maximum = active;
                await gate.future;
                active--;
              });
            } on SubsonicSyncLimitException {
              /* Deferred work is expected. */
            }
          }),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(maximum, 2);
      allowed = false;
      gate.complete();
      await work.timeout(const Duration(seconds: 2));
      expect(budget.stopped?.reason, 'networkPolicy');
    },
  );

  test('unplanned endpoints never reach transport', () async {
    final budget = scope();
    var called = false;
    await expectLater(
      budget.run(
        () => budget.request('getArtists', () async {
          called = true;
        }),
      ),
      throwsA(isA<SubsonicSyncLimitException>()),
    );
    expect(called, isFalse);
  });

  test('the scan-status observation is permitted inside every plan', () async {
    final budget = scope();
    var called = false;
    await budget.run(
      () => budget.request('getScanStatus', () async {
        called = true;
      }),
    );
    expect(called, isTrue);
    expect(budget.stopped, isNull);
  });

  test(
    'response bytes are attributed only inside the operation and enforce a cap',
    () async {
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: 200,
                data: {
                  'subsonic-response': {
                    'status': 'ok',
                    'playlists': {
                      'playlist': [
                        {'id': 'p1', 'name': 'Fixture'},
                      ],
                    },
                  },
                },
              ),
              true,
            );
          },
        ),
      );
      final api = client(dio);
      final budget = scope();
      await budget.run(() => api.getPlaylists());
      expect(budget.requestCount, 1);
      expect(budget.byteCount, greaterThan(0));
      final bytes = budget.byteCount;
      await api.getPlaylists();
      expect(budget.requestCount, 1);
      expect(budget.byteCount, bytes);
      final tiny = scope(bytes: 8);
      await expectLater(
        tiny.run(() => api.getPlaylists()),
        throwsA(isA<SubsonicSyncLimitException>()),
      );
      expect(tiny.stopped?.reason, 'byteBudget');
    },
  );

  test(
    'an immediate retry is stopped before exceeding the request cap',
    () async {
      final dio = Dio();
      var attempts = 0;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            attempts++;
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.badResponse,
                response: Response<dynamic>(
                  requestOptions: options,
                  statusCode: 503,
                  data: {'error': 'fixture'},
                  headers: Headers.fromMap({
                    'retry-after': ['0'],
                  }),
                ),
              ),
              true,
            );
          },
        ),
      );
      final budget = scope(requests: 1);
      await expectLater(
        budget.run(() => client(dio).getPlaylists()),
        throwsA(isA<SubsonicSyncLimitException>()),
      );
      expect(attempts, 1);
      expect(budget.requestCount, 1);
      expect(budget.byteCount, greaterThan(0));
    },
  );

  test(
    'long Retry-After is returned for durable scheduling without sleeping',
    () async {
      final dio = Dio();
      var attempts = 0;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            attempts++;
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.badResponse,
                response: Response<dynamic>(
                  requestOptions: options,
                  statusCode: 503,
                  headers: Headers.fromMap({
                    'retry-after': ['120'],
                  }),
                ),
              ),
              true,
            );
          },
        ),
      );
      final before = DateTime.now().toUtc();
      await expectLater(
        client(dio).getPlaylists().timeout(const Duration(seconds: 2)),
        throwsA(
          isA<SubsonicGenericException>().having(
            (error) => error.retryAt?.isAfter(
              before.add(const Duration(seconds: 119)),
            ),
            'retryAt',
            isTrue,
          ),
        ),
      );
      expect(attempts, 1);
    },
  );
}
