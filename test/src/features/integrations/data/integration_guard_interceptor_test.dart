import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/integrations/data/external_dio.dart';
import 'package:navis/src/features/integrations/data/integration_call_recorder.dart';
import 'package:navis/src/features/integrations/data/integration_guard_interceptor.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';

class _RecordingAdapter implements HttpClientAdapter {
  new({this.status = 200});

  final int status;
  final requested = <Uri>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requested.add(options.uri);
    return ResponseBody.fromString(
      jsonEncode(<String, Object?>{'ok': true}),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late IntegrationPolicy policy;
  late IntegrationCallRecorder recorder;
  late _RecordingAdapter adapter;

  Dio build(IntegrationService service, {int status = 200}) {
    adapter = _RecordingAdapter(status: status);
    return createExternalDio(
      service,
      readPolicy: () => policy,
      recorder: recorder,
      options: BaseOptions(baseUrl: 'https://example.invalid/api'),
    )..httpClientAdapter = adapter;
  }

  setUp(() {
    policy = const IntegrationPolicy();
    recorder = IntegrationCallRecorder(logCalls: false);
  });

  test('allows a request for an enabled service and records it', () async {
    final dio = build(IntegrationService.lrclib);
    final response = await dio.get<Object?>('/get');
    expect(response.statusCode, 200);
    expect(adapter.requested, hasLength(1));
    final call = recorder.recentCalls().single;
    expect(call.service, IntegrationService.lrclib);
    expect(call.outcome, IntegrationCallOutcome.ok);
    expect(call.statusCode, 200);
    expect(call.path, '/api/get');
  });

  test('blocks a disabled service before it leaves the device', () async {
    policy = const IntegrationPolicy(disabledKeys: {'lrclib'});
    final dio = build(IntegrationService.lrclib);
    await expectLater(
      dio.get<Object?>('/get'),
      throwsA(
        isA<DioException>().having(
          (e) => e.error,
          'error',
          isA<IntegrationBlockedException>().having(
            (e) => e.service,
            'service',
            IntegrationService.lrclib,
          ),
        ),
      ),
    );
    expect(adapter.requested, isEmpty);
  });

  test('blocks every service while the master switch is off', () async {
    policy = const IntegrationPolicy(masterEnabled: false);
    for (final service in IntegrationService.values) {
      final dio = build(service);
      await expectLater(dio.get<Object?>('/x'), throwsA(isA<DioException>()));
      expect(adapter.requested, isEmpty, reason: service.key);
    }
  });

  test('one service switch does not block another service', () async {
    policy = const IntegrationPolicy(disabledKeys: {'lastfm'});
    final dio = build(IntegrationService.listenBrainz);
    await dio.get<Object?>('/x');
    expect(adapter.requested, hasLength(1));
  });

  test('does not require a verified credential', () async {
    // The service level only: key and token checks happen at call sites, and
    // validating a credential must be able to reach the service.
    final dio = build(IntegrationService.lastFm);
    await dio.get<Object?>('/validate');
    expect(adapter.requested, hasLength(1));
  });

  test(
    'records a blocked call with the blocked outcome and no duration',
    () async {
      policy = const IntegrationPolicy(disabledKeys: {'lrclib'});
      final dio = build(IntegrationService.lrclib);
      await expectLater(dio.get<Object?>('/get'), throwsA(isA<DioException>()));
      final call = recorder.recentCalls().single;
      expect(call.outcome, IntegrationCallOutcome.blocked);
      expect(call.statusCode, isNull);
      expect(recorder.countersFor(IntegrationService.lrclib).blocked, 1);
      expect(recorder.countersFor(IntegrationService.lrclib).requests, 0);
    },
  );

  test('reads the policy on every request', () async {
    final dio = build(IntegrationService.updates);
    await dio.get<Object?>('/a');
    policy = const IntegrationPolicy(disabledKeys: {'updates'});
    await expectLater(dio.get<Object?>('/b'), throwsA(isA<DioException>()));
    policy = const IntegrationPolicy();
    await dio.get<Object?>('/c');
    expect(adapter.requested.map((u) => u.path), ['/api/a', '/api/c']);
  });

  group('user-initiated requests', () {
    test('bypass a disabled service switch', () async {
      policy = const IntegrationPolicy(disabledKeys: {'lastfm'});
      final dio = build(IntegrationService.lastFm);
      await dio.get<Object?>('/validate', options: userInitiatedOptions());
      expect(adapter.requested, hasLength(1));
      expect(recorder.recentCalls().single.outcome, IntegrationCallOutcome.ok);
    });

    test('are still blocked while the master switch is off', () async {
      policy = const IntegrationPolicy(masterEnabled: false);
      final dio = build(IntegrationService.lastFm);
      await expectLater(
        dio.get<Object?>('/validate', options: userInitiatedOptions()),
        throwsA(isA<DioException>()),
      );
      expect(adapter.requested, isEmpty);
      expect(
        recorder.recentCalls().single.outcome,
        IntegrationCallOutcome.blocked,
      );
    });

    test(
      'the extra key can be set directly and merges with other options',
      () async {
        policy = const IntegrationPolicy(disabledKeys: {'autoeq'});
        final dio = build(IntegrationService.autoEq);
        await dio.get<Object?>(
          '/index',
          options: Options(extra: {navisUserInitiatedExtraKey: true}),
        );
        expect(adapter.requested, hasLength(1));

        final merged = userInitiatedOptions(
          Options(headers: {'X-Test': '1'}, extra: {'other': 1}),
        );
        expect(merged.headers, {'X-Test': '1'});
        expect(merged.extra, {'other': 1, navisUserInitiatedExtraKey: true});
      },
    );
  });

  test('records failures with their status and the error outcome', () async {
    final dio = build(IntegrationService.lastFm, status: 500);
    await expectLater(dio.get<Object?>('/x'), throwsA(isA<DioException>()));
    final call = recorder.recentCalls().single;
    expect(call.outcome, IntegrationCallOutcome.error);
    expect(call.statusCode, 500);
    expect(recorder.countersFor(IntegrationService.lastFm).errors, 1);
  });

  test(
    'a secret query value and an Authorization header are never recorded',
    () async {
      const secret = 'TOPSECRETVALUE';
      final dio = build(IntegrationService.listenBrainz);
      await dio.get<Object?>(
        '/validate-token',
        queryParameters: {'api_key': secret},
        options: Options(headers: {'Authorization': 'Token $secret'}),
      );
      policy = const IntegrationPolicy(disabledKeys: {'listenbrainz'});
      await expectLater(
        dio.get<Object?>(
          '/validate-token',
          queryParameters: {'api_key': secret},
          options: Options(headers: {'Authorization': 'Token $secret'}),
        ),
        throwsA(isA<DioException>()),
      );
      final output = jsonEncode(recorder.toJson());
      expect(output, isNot(contains(secret)));
      expect(output, isNot(contains('Authorization')));
      expect(output, isNot(contains('api_key')));
      expect(output, contains('/api/validate-token'));
    },
  );

  test('the guard works without a recorder', () async {
    adapter = _RecordingAdapter();
    final dio = createExternalDio(
      IntegrationService.deezer,
      readPolicy: () => const IntegrationPolicy(),
    )..httpClientAdapter = adapter;
    await dio.get<Object?>('https://api.deezer.com/artist/1');
    expect(adapter.requested, hasLength(1));
  });
}
