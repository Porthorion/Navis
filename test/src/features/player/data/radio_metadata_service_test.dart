import 'dart:convert';
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
  String? body;
  int statusCode = 200;
  DioExceptionType? failure;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requested.add(options.uri);
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
        verifyNever(
          () => handler.updateRadioMetadata(
            title: 'ICY Song',
            artist: 'ICY Artist',
          ),
        );
        async.elapse(RadioMetadataService.pollingInterval);
        settle(async);
        verify(
          () => handler.updateRadioMetadata(
            title: 'ICY Song',
            artist: 'ICY Artist',
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
      adapter.statusCode = 503;
      async.elapse(RadioMetadataService.pollingInterval * 3);
      settle(async);
      expect(adapter.requested, hasLength(4));
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
