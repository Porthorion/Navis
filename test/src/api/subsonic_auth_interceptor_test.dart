import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:uuid/uuid.dart';

class _MockUuid extends Mock implements Uuid;

void main() {
  test('subsonicClientName names the platform', () {
    expect(
      subsonicClientName,
      'Navis [${Platform.isLinux
          ? 'Linux'
          : Platform.isWindows
          ? 'Windows'
          : 'macOS'}]',
    );
  });

  group('buildSubsonicAuthQuery', () {
    test(
      'uses the first 12 UUID hex characters and hashes password plus salt',
      () {
        final uuid = _MockUuid();
        when(uuid.v4).thenReturn('01234567-89ab-4cde-8f01-23456789abcd');
        final query = buildSubsonicAuthQuery(
          const SubsonicAuthConfig(
            username: 'alice',
            password: 'secret',
            apiVersion: '1.16.1',
            client: 'test-client',
          ),
          uuid,
        );
        expect(query, <String, String>{
          'u': 'alice',
          'v': '1.16.1',
          'c': 'test-client',
          'f': 'json',
          's': '0123456789ab',
          't': '153fdc65fca186543501149f7814a247',
        });
        verify(uuid.v4).called(1);
      },
    );

    test(
      'encodes the legacy password as lowercase UTF-8 hex without a UUID',
      () {
        final uuid = _MockUuid();
        final query = buildSubsonicAuthQuery(
          const SubsonicAuthConfig(
            username: 'bob',
            password: 'päss🔒',
            apiVersion: '1.12.0',
            authType: SubsonicAuthType.legacyPassword,
          ),
          uuid,
        );
        expect(query, <String, String>{
          'u': 'bob',
          'v': '1.12.0',
          'c': subsonicClientName,
          'f': 'json',
          'p': 'enc:70c3a47373f09f9492',
        });
        verifyNever(uuid.v4);
      },
    );
  });

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

      await dio.get<dynamic>(
        '/rest/ping.view',
        queryParameters: <String, dynamic>{
          'id': 'track-1',
          'u': 'old-user',
          'v': 'old-version',
          'c': 'old-client',
          'f': 'xml',
          'p': 'old-password',
          't': 'old-token',
          's': 'old-salt',
        },
      );

      expect(captured.queryParameters['id'], 'track-1');
      expect(captured.queryParameters['u'], 'alice');
      expect(captured.queryParameters['c'], subsonicClientName);
      expect(captured.queryParameters['s'], isNot('old-salt'));
      expect(captured.queryParameters['t'], isNot('old-token'));
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

      await dio.get<dynamic>(
        '/rest/ping.view',
        queryParameters: <String, dynamic>{
          'id': 'track-1',
          'u': 'old-user',
          'v': 'old-version',
          'c': 'old-client',
          'f': 'xml',
          'p': 'old-password',
          't': 'old-token',
          's': 'old-salt',
        },
      );

      expect(captured.queryParameters['id'], 'track-1');
      expect(captured.queryParameters['u'], 'bob');
      expect(captured.queryParameters['v'], '1.12.0');
      expect(captured.queryParameters['c'], subsonicClientName);
      expect(captured.queryParameters['p'], 'enc:68756e74657232');
      expect(captured.queryParameters['f'], 'json');
      expect('${captured.queryParameters['p']}', startsWith('enc:'));
      expect(captured.queryParameters.containsKey('t'), isFalse);
      expect(captured.queryParameters.containsKey('s'), isFalse);
    });
  });
}
