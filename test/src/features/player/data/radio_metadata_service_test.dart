import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/features/integrations/data/external_dio.dart';
import 'package:navis/src/features/integrations/data/integration_call_recorder.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/player/data/radio_metadata_service.dart';

class _MockHandler extends Mock implements NavisPlaybackHandler;

class _MockPlayer extends Mock implements AudioPlayer;

class _CountingAdapter implements HttpClientAdapter {
  final requested = <Uri>[];
  Duration? lastConnectTimeout;
  Duration? lastReceiveTimeout;
  String? body;
  int statusCode = 200;
  DioExceptionType? failure;
  Completer<ResponseBody>? pending;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requested.add(options.uri);
    lastConnectTimeout = options.connectTimeout;
    lastReceiveTimeout = options.receiveTimeout;
    if (pending case final request?) return await request.future;
    if (failure case final type?) {
      throw DioException(requestOptions: options, type: type);
    }
    return ResponseBody.fromString(
      body ??
          jsonEncode(<String, Object?>{
            'now_playing': {
              'song': {'title': 'Song', 'artist': 'Artist', 'art': null},
            },
          }),
      statusCode,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Dio schedules its request on the event loop, so microtasks alone do not
/// let it reach the adapter.
void settle(FakeAsync async) {
  async.elapse(const Duration(milliseconds: 1));
  async.flushMicrotasks();
}

void main() {
  late _MockHandler handler;
  late _MockPlayer player;
  late _CountingAdapter adapter;
  late IntegrationPolicy policy;
  late IntegrationCallRecorder recorder;

  RadioMetadataService build() {
    final dio = Dio();
    dio.httpClientAdapter = adapter;
    return RadioMetadataService(
      handler: handler,
      player: player,
      dio: dio,
      isAllowed: () => policy.allows(IntegrationFeature.radioNowPlaying),
    );
  }

  setUp(() {
    handler = _MockHandler();
    player = _MockPlayer();
    adapter = _CountingAdapter();
    policy = const IntegrationPolicy();
    recorder = IntegrationCallRecorder(logCalls: false);
    when(() => player.icyMetadataStream)
        .thenAnswer((_) => const Stream<IcyMetadata?>.empty());
    when(() => player.icyMetadata).thenReturn(null);
    when(
      () => handler.updateRadioMetadata(
        title: any(named: 'title'),
        artist: any(named: 'artist'),
        artUrl: any(named: 'artUrl'),
        replaceMetadata: any(named: 'replaceMetadata'),
      ),
    ).thenReturn(null);
  });

  void listen(RadioMetadataService service) => service.startListening(
    stationId: 'station',
    azuracastApiUrl: 'https://radio.example.invalid',
    stationShortName: 'main',
  );

  for (final failure in ['http', 'timeout', 'non-json', 'shape']) {
    test('falls back to cached ICY after two initial $failure failures', () {
      switch (failure) {
        case 'http':
          adapter.statusCode = 404;
        case 'timeout':
          adapter.failure = DioExceptionType.receiveTimeout;
        case 'non-json':
          adapter.body = '<html>Not an API</html>';
        case 'shape':
          adapter.body = '{"station": "ordinary Icecast"}';
      }
      when(() => player.icyMetadata).thenReturn(
        IcyMetadata(
          info: IcyInfo(title: 'ICY Artist - ICY Song', url: null),
          headers: null,
        ),
      );
      fakeAsync((async) {
        final service = build();
        listen(service);
        settle(async);
        if (failure == 'timeout') {
          expect(adapter.lastConnectTimeout, const Duration(seconds: 10));
          expect(adapter.lastReceiveTimeout, const Duration(seconds: 10));
        }
        verifyNever(
          () => handler.updateRadioMetadata(
            title: 'ICY Song',
            artist: 'ICY Artist',
            replaceMetadata: true,
          ),
        );
        async.elapse(RadioMetadataService.pollingInterval);
        settle(async);
        verify(
          () => handler.updateRadioMetadata(
            title: 'ICY Song',
            artist: 'ICY Artist',
            replaceMetadata: true,
          ),
        ).called(1);
        async.elapse(RadioMetadataService.pollingInterval * 6);
        settle(async);
        expect(adapter.requested, hasLength(2));
        service.dispose();
      });
    });
  }

  test('keeps polling through failures after an Azuracast success', () {
    fakeAsync((async) {
      final service = build();
      listen(service);
      settle(async);
      expect(service.metadataSource, RadioMetadataSource.azuracast);
      adapter.statusCode = 503;
      async.elapse(RadioMetadataService.pollingInterval * 3);
      settle(async);
      expect(adapter.requested, hasLength(4));
      expect(service.metadataSource, RadioMetadataSource.azuracast);
      adapter.statusCode = 200;
      async.elapse(RadioMetadataService.pollingInterval);
      settle(async);
      verify(
        () => handler.updateRadioMetadata(
          title: 'Song',
          artist: 'Artist',
          artUrl: null,
        ),
      ).called(2);
      service.dispose();
    });
  });

  test(
    'fallback applies ICY received while the initial API probe was active',
    () {
      fakeAsync((async) {
        final icy = StreamController<IcyMetadata?>.broadcast();
        when(() => player.icyMetadataStream).thenAnswer((_) => icy.stream);
        adapter.statusCode = 404;
        final service = build();
        listen(service);
        settle(async);
        icy.add(
          IcyMetadata(
            info: IcyInfo(title: 'Stream Artist - Stream Song', url: null),
            headers: null,
          ),
        );
        settle(async);
        verifyNever(
          () => handler.updateRadioMetadata(
            title: 'Stream Song',
            artist: 'Stream Artist',
            replaceMetadata: true,
          ),
        );
        async.elapse(RadioMetadataService.pollingInterval);
        settle(async);
        verify(
          () => handler.updateRadioMetadata(
            title: 'Stream Song',
            artist: 'Stream Artist',
            replaceMetadata: true,
          ),
        ).called(1);
        expect(service.metadataSource, RadioMetadataSource.icy);
        service.dispose();
        unawaited(icy.close());
      });
    },
  );

  test('station switch rejects a late response and resets metadata source', () {
    fakeAsync((async) {
      final pending = Completer<ResponseBody>();
      adapter.pending = pending;
      final service = build();
      listen(service);
      settle(async);
      service.startListening(stationId: 'icy-station');
      pending.complete(
        ResponseBody.fromString(
          '{"now_playing":{"song":{"title":"Old Station"}}}',
          200,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
          },
        ),
      );
      settle(async);
      expect(service.metadataSource, RadioMetadataSource.none);
      verifyNever(
        () => handler.updateRadioMetadata(
          title: 'Old Station',
          artist: null,
          artUrl: null,
        ),
      );
      service.dispose();
    });
  });

  test('disabling lookups without ICY clears the Azuracast source', () {
    fakeAsync((async) {
      final service = build();
      listen(service);
      settle(async);
      expect(service.metadataSource, RadioMetadataSource.azuracast);
      policy = const IntegrationPolicy(disabledKeys: {'radio.nowPlaying'});
      service.refreshPolicy();
      expect(service.metadataSource, RadioMetadataSource.none);
      service.dispose();
    });
  });

  test('policy re-enable gives an unconfirmed API a fresh failure budget', () {
    adapter.statusCode = 404;
    fakeAsync((async) {
      final service = build();
      listen(service);
      settle(async);
      expect(adapter.requested, hasLength(1));
      policy = const IntegrationPolicy(disabledKeys: {'radio.nowPlaying'});
      service.refreshPolicy();
      policy = const IntegrationPolicy();
      service.refreshPolicy();
      settle(async);
      expect(adapter.requested, hasLength(2));
      adapter.statusCode = 200;
      async.elapse(RadioMetadataService.pollingInterval);
      settle(async);
      expect(adapter.requested, hasLength(3));
      expect(service.metadataSource, RadioMetadataSource.azuracast);
      service.dispose();
    });
  });

  test('policy re-enable does not retry a rejected candidate API', () {
    adapter.statusCode = 404;
    fakeAsync((async) {
      final service = build();
      listen(service);
      settle(async);
      async.elapse(RadioMetadataService.pollingInterval);
      settle(async);
      policy = const IntegrationPolicy(disabledKeys: {'radio.nowPlaying'});
      service.refreshPolicy();
      policy = const IntegrationPolicy();
      service.refreshPolicy();
      async.elapse(RadioMetadataService.pollingInterval * 3);
      settle(async);
      expect(adapter.requested, hasLength(2));
      service.dispose();
    });
  });

  test(
    'late response from before policy disable cannot publish after re-enable',
    () {
      fakeAsync((async) {
        final pending = Completer<ResponseBody>();
        adapter.pending = pending;
        final service = build();
        listen(service);
        settle(async);
        policy = const IntegrationPolicy(disabledKeys: {'radio.nowPlaying'});
        service.refreshPolicy();
        policy = const IntegrationPolicy();
        adapter.pending = null;
        service.refreshPolicy();
        settle(async);
        pending.complete(
          ResponseBody.fromString(
            '{"now_playing":{"song":{"title":"Stale"}}}',
            200,
            headers: {
              Headers.contentTypeHeader: ['application/json'],
            },
          ),
        );
        settle(async);
        verifyNever(
          () => handler.updateRadioMetadata(
            title: 'Stale',
            artist: null,
            artUrl: null,
          ),
        );
        expect(adapter.requested, hasLength(2));
        service.dispose();
      });
    },
  );

  test('polls Azuracast every interval while allowed', () {
    fakeAsync((async) {
      final service = build();
      listen(service);
      settle(async);
      expect(adapter.requested, hasLength(1));
      async.elapse(RadioMetadataService.pollingInterval * 3);
      settle(async);
      expect(adapter.requested.length, greaterThanOrEqualTo(3));
      service.dispose();
    });
  });

  test('a slow Azuracast response never overlaps the next poll', () {
    fakeAsync((async) {
      final pending = Completer<ResponseBody>();
      adapter.pending = pending;
      final service = build();
      listen(service);
      settle(async);
      async.elapse(RadioMetadataService.pollingInterval * 3);
      settle(async);
      expect(adapter.requested, hasLength(1));

      adapter.pending = null;
      pending.complete(
        ResponseBody.fromString(
          '{"now_playing":{"song":{"title":"Song"}}}',
          200,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
          },
        ),
      );
      settle(async);
      async.elapse(RadioMetadataService.pollingInterval);
      settle(async);
      expect(adapter.requested, hasLength(2));
      service.dispose();
    });
  });

  test(
    "a station switch is not blocked by the previous station's slow poll",
    () {
      fakeAsync((async) {
        adapter.pending = Completer<ResponseBody>();
        final service = build();
        listen(service);
        settle(async);
        expect(adapter.requested, hasLength(1));

        service.startListening(
          stationId: 'other',
          azuracastApiUrl: 'https://other.example.invalid',
          stationShortName: 'second',
        );
        settle(async);
        expect(adapter.requested, hasLength(2));
        expect(adapter.requested.last.host, 'other.example.invalid');
        service.dispose();
      });
    },
  );

  test('does not poll at all when radio lookups are off at the start', () {
    policy = const IntegrationPolicy(disabledKeys: {'radio.nowPlaying'});
    fakeAsync((async) {
      final service = build();
      listen(service);
      async.elapse(RadioMetadataService.pollingInterval * 3);
      settle(async);
      expect(adapter.requested, isEmpty);
      service.dispose();
    });
  });

  for (final entry in <String, IntegrationPolicy>{
    'the radio switch': const IntegrationPolicy(
      disabledKeys: {'radio.nowPlaying'},
    ),
    'the radio service': const IntegrationPolicy(disabledKeys: {'radio'}),
    'the master switch': const IntegrationPolicy(masterEnabled: false),
  }.entries) {
    test('polling stops when ${entry.key} is turned off mid-station', () {
      fakeAsync((async) {
        final service = build();
        listen(service);
        settle(async);
        async.elapse(RadioMetadataService.pollingInterval);
        settle(async);
        final before = adapter.requested.length;
        expect(before, greaterThanOrEqualTo(1));

        policy = entry.value;
        async.elapse(RadioMetadataService.pollingInterval * 6);
        settle(async);

        expect(
          adapter.requested.length,
          before,
          reason: 'no request after the switch is off',
        );
        service.dispose();
      });
    });
  }

  test('the guarded Dio blocks the poll even if the callback were wrong', () {
    policy = const IntegrationPolicy(disabledKeys: {'radio'});
    fakeAsync((async) {
      final dio = createExternalDio(
        IntegrationService.radioMetadata,
        readPolicy: () => policy,
        recorder: recorder,
      )..httpClientAdapter = adapter;
      final service = RadioMetadataService(
        handler: handler,
        player: player,
        dio: dio,
        // Deliberately permissive: only the interceptor stands in the way.
        isAllowed: () => true,
      );
      listen(service);
      settle(async);
      expect(adapter.requested, isEmpty);
      expect(
        recorder.recentCalls().single.outcome,
        IntegrationCallOutcome.blocked,
      );
      service.dispose();
    });
  });
}
