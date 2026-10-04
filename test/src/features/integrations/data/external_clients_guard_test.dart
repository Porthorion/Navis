import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/lastfm_api_client.dart';
import 'package:navis/src/api/listenbrainz_api_client.dart';
import 'package:navis/src/api/lrclib_client.dart';
import 'package:navis/src/features/equalizer/data/autoeq_catalogue.dart';
import 'package:navis/src/features/integrations/data/external_dio.dart';
import 'package:navis/src/features/integrations/data/integration_call_recorder.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';

class _Adapter implements HttpClientAdapter {
  final requested = <Uri>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requested.add(options.uri);
    final body = options.uri.host.contains('lrclib')
        ? '[]'
        : jsonEncode(<String, Object?>{
            'valid': true,
            'user_name': 'alice',
            'toptracks': <String, Object?>{'track': <Object?>[]},
          });
    return ResponseBody.fromString(
      body,
      200,
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
  late _Adapter adapter;

  Dio guarded(IntegrationService service, BaseOptions options) {
    return createExternalDio(
      service,
      readPolicy: () => policy,
      recorder: recorder,
      options: options,
    )..httpClientAdapter = adapter;
  }

  setUp(() {
    policy = const IntegrationPolicy();
    recorder = IntegrationCallRecorder(logCalls: false);
    adapter = _Adapter();
  });

  group('Last.fm', () {
    LastFmApiClient client() => LastFmApiClient(
      apiKey: 'SECRETKEY',
      dio: guarded(IntegrationService.lastFm, LastFmApiClient.baseOptions),
    );

    test('automatic lookups are blocked while the service is off', () async {
      policy = const IntegrationPolicy(disabledKeys: {'lastfm'});
      await client().getArtistTopTracks(artist: 'Someone');
      expect(adapter.requested, isEmpty);
      expect(
        recorder.recentCalls().single.outcome,
        IntegrationCallOutcome.blocked,
      );
    });

    test('key validation still works while the service is off', () async {
      policy = const IntegrationPolicy(disabledKeys: {'lastfm'});
      final result = await client().validateApiKey();
      expect(result.valid, isTrue);
      expect(adapter.requested, hasLength(1));
    });

    test('key validation is blocked while the master switch is off', () async {
      policy = const IntegrationPolicy(masterEnabled: false);
      final result = await client().validateApiKey();
      expect(result.valid, isFalse);
      expect(adapter.requested, isEmpty);
    });

    test('the key is sent but never recorded', () async {
      await client().validateApiKey();
      expect(adapter.requested.single.queryParameters['api_key'], 'SECRETKEY');
      expect(jsonEncode(recorder.toJson()), isNot(contains('SECRETKEY')));
    });
  });

  group('ListenBrainz', () {
    ListenBrainzApiClient client() => ListenBrainzApiClient(
      dio: guarded(
        IntegrationService.listenBrainz,
        ListenBrainzApiClient.baseOptions,
      ),
    );

    test(
      'a validation the user asked for works while the service is off',
      () async {
        policy = const IntegrationPolicy(disabledKeys: {'listenbrainz'});
        final details = await client().validateTokenDetails(
          'TOKEN-SECRET',
          userInitiated: true,
        );
        expect(details.valid, isTrue);
        expect(adapter.requested, hasLength(1));
        expect(jsonEncode(recorder.toJson()), isNot(contains('TOKEN-SECRET')));
      },
    );

    test(
      'automatic revalidation is blocked while the service is off',
      () async {
        policy = const IntegrationPolicy(disabledKeys: {'listenbrainz'});
        await expectLater(
          client().validateTokenDetails('TOKEN-SECRET'),
          throwsA(isA<DioException>()),
        );
        expect(adapter.requested, isEmpty);
      },
    );

    test(
      'token validation is blocked while the master switch is off',
      () async {
        policy = const IntegrationPolicy(masterEnabled: false);
        await expectLater(
          client().validateTokenDetails('TOKEN-SECRET', userInitiated: true),
          throwsA(isA<DioException>()),
        );
        expect(adapter.requested, isEmpty);
      },
    );

    test('other calls are blocked while the service is off', () async {
      policy = const IntegrationPolicy(disabledKeys: {'listenbrainz'});
      await expectLater(
        client().getRecommendationPlaylists(
          userName: 'alice',
          userToken: 'TOKEN-SECRET',
        ),
        throwsA(isA<DioException>()),
      );
      expect(adapter.requested, isEmpty);
    });
  });

  group('LRCLIB', () {
    test('lookups are blocked while the service is off', () async {
      policy = const IntegrationPolicy(disabledKeys: {'lrclib'});
      final client = LrclibClient(
        dio: guarded(IntegrationService.lrclib, LrclibClient.baseOptions),
      );
      await expectLater(
        client.searchLyrics(artist: 'A', title: 'T'),
        throwsA(isA<DioException>()),
      );
      expect(adapter.requested, isEmpty);

      policy = const IntegrationPolicy();
      expect(await client.searchLyrics(artist: 'A', title: 'T'), isEmpty);
      expect(adapter.requested.single.host, 'lrclib.net');
    });
  });

  group('AutoEQ', () {
    test(
      'explicit refresh and download are blocked only by the master switch',
      () async {
        policy = const IntegrationPolicy(masterEnabled: false);
        final catalogue = AutoEqCatalogue(
          client: guarded(
            IntegrationService.autoEq,
            AutoEqCatalogue.baseOptions,
          ),
        );
        await expectLater(catalogue.refresh(), throwsA(isA<DioException>()));
        expect(adapter.requested, isEmpty);

        // With only the AutoEQ service off, the user's refresh still reaches
        // the network (it fails here on the stub's body, after the request).
        policy = const IntegrationPolicy(disabledKeys: {'autoeq'});
        await expectLater(catalogue.refresh(), throwsA(anything));
        expect(adapter.requested, isNotEmpty);
      },
    );
  });
}
