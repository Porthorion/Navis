import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart'
    as platform;

const _offset = Duration(seconds: 120);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _OffsetPlatform native;

  setUp(() {
    native = _OffsetPlatform();
    final previous = platform.JustAudioPlatform.instance;
    platform.JustAudioPlatform.instance = native;
    addTearDown(() => platform.JustAudioPlatform.instance = previous);
  });

  AudioPlayer newPlayer() {
    final player = AudioPlayer(activateAudioSession: (active) async => true);
    addTearDown(player.dispose);
    return player;
  }

  UriAudioSource offsetSource([Duration positionOffset = _offset]) =>
      AudioSource.uri(
        Uri.parse('https://music.example.invalid/rest/stream.view?id=1'),
        positionOffset: positionOffset,
      );

  UriAudioSource plainSource() =>
      AudioSource.uri(Uri.parse('https://music.example.invalid/rest/b.view'));

  test('live radio can retain the default Android retry policy', () async {
    final player = newPlayer();
    await player.setAudioSource(
      AudioSource.uri(
        Uri.parse('https://radio.example.invalid/live'),
        options: const ProgressiveAudioSourceOptions(
          androidUseDefaultLoadErrorHandling: true,
        ),
      ),
    );
    final playlist =
        native.player.loads.last.audioSourceMessage
            as platform.ConcatenatingAudioSourceMessage;
    final source = playlist.children.single.toMap();
    expect(
      (source['options']
          as Map<Object?, Object?>)['androidUseDefaultLoadErrorHandling'],
      isTrue,
    );
  });

  group('header proxy routing (user agent set)', () {
    Future<Map<Object?, Object?>> loadedSource(
      Uri uri, {
      Map<String, String>? headers,
      String? userAgent,
    }) async {
      final player = AudioPlayer(
        userAgent: userAgent,
        activateAudioSession: (active) async => true,
      );
      addTearDown(player.dispose);
      await player.setAudioSource(AudioSource.uri(uri, headers: headers));
      final playlist =
          native.player.loads.last.audioSourceMessage
              as platform.ConcatenatingAudioSourceMessage;
      return playlist.children.single.toMap();
    }

    const agent = 'NavisTest/1.0';

    test('a content:// download is never routed through the proxy', () async {
      final source = await loadedSource(
        Uri.parse('content://tree/primary%3AMusic/document/a.opus'),
        userAgent: agent,
      );
      expect(source['uri'], 'content://tree/primary%3AMusic/document/a.opus');
    });

    test('file:// stays direct and http(s) is still proxied', () async {
      final file = await loadedSource(
        Uri.parse('file:///music/a.opus'),
        userAgent: agent,
      );
      expect(file['uri'], 'file:///music/a.opus');
      for (final url in [
        'https://music.example.invalid/a',
        'HTTP://x.invalid/a',
      ]) {
        final source = await loadedSource(Uri.parse(url), userAgent: agent);
        expect(source['uri'], startsWith('http://127.0.0.1:'), reason: url);
      }
    });

    test('http with headers and no user agent is still proxied', () async {
      final source = await loadedSource(
        Uri.parse('https://music.example.invalid/a'),
        headers: {'X-Test': '1'},
      );
      expect(source['uri'], startsWith('http://127.0.0.1:'));
    });

    test('content:// with headers and no user agent stays direct', () async {
      final source = await loadedSource(
        Uri.parse('content://tree/doc/a.opus'),
        headers: {'X-Test': '1'},
      );
      expect(source['uri'], 'content://tree/doc/a.opus');
    });
  });

  test('inbound position, buffered and duration gain the offset', () async {
    final player = newPlayer();
    await player.setAudioSource(offsetSource());
    native.player.emit(
      position: const Duration(seconds: 2),
      buffered: const Duration(seconds: 5),
      duration: const Duration(seconds: 60),
    );
    await pumpEventQueue();
    expect(
      player.playbackEvent.updatePosition,
      _offset + const Duration(seconds: 2),
    );
    expect(player.bufferedPosition, _offset + const Duration(seconds: 5));
    expect(player.duration, _offset + const Duration(seconds: 60));
    expect(player.position, _offset + const Duration(seconds: 2));
  });

  test('a later event without a duration keeps the translated one', () async {
    final player = newPlayer();
    await player.setAudioSource(offsetSource());
    native.player.emit(duration: const Duration(seconds: 60));
    await pumpEventQueue();
    native.player.emit(position: const Duration(seconds: 3));
    await pumpEventQueue();
    expect(player.duration, _offset + const Duration(seconds: 60));
  });

  test(
    'the idle platform does not add the offset to the duration twice',
    () async {
      final player = newPlayer();
      await player.setAudioSource(offsetSource());
      native.player.emit(
        position: const Duration(seconds: 4),
        duration: const Duration(seconds: 60),
      );
      await pumpEventQueue();
      native.player.emit(
        position: const Duration(seconds: 4),
        state: platform.ProcessingStateMessage.idle,
      );
      await pumpEventQueue();
      expect(player.processingState, ProcessingState.idle);
      expect(player.duration, _offset + const Duration(seconds: 60));
      expect(
        player.playbackEvent.updatePosition,
        _offset + const Duration(seconds: 4),
      );
    },
  );

  test('seek sends the position relative to the offset stream', () async {
    final player = newPlayer();
    await player.setAudioSource(offsetSource());
    await player.seek(_offset + const Duration(seconds: 10));
    expect(native.player.seeks.single.position, const Duration(seconds: 10));
    expect(player.position, _offset + const Duration(seconds: 10));
    // Before the offset the linear stream can only restart at its own zero.
    await player.seek(const Duration(seconds: 30));
    expect(native.player.seeks.last.position, Duration.zero);
  });

  test('a null seek position still means the head of a live stream', () async {
    final player = newPlayer();
    await player.setAudioSource(offsetSource());
    await player.seek(null);
    expect(native.player.seeks.single.position, isNull);
  });

  test('the next item plays from its own zero after an auto-advance', () async {
    final player = newPlayer();
    await player.setAudioSources([offsetSource(), plainSource()]);
    native.player.emit(position: const Duration(seconds: 59), index: 0);
    await pumpEventQueue();
    expect(player.position, _offset + const Duration(seconds: 59));
    native.player.emit(
      position: const Duration(seconds: 1),
      duration: const Duration(seconds: 200),
      index: 1,
    );
    await pumpEventQueue();
    expect(player.currentIndex, 1);
    expect(player.playbackEvent.updatePosition, const Duration(seconds: 1));
    expect(player.duration, const Duration(seconds: 200));
    await player.seek(const Duration(seconds: 7), index: 1);
    expect(native.player.seeks.last.position, const Duration(seconds: 7));
  });

  test('initialPosition is sent relative to the initial offset item', () async {
    final player = newPlayer();
    await player.setAudioSources([
      offsetSource(),
    ], initialPosition: _offset + const Duration(seconds: 5));
    expect(
      native.player.loads.last.initialPosition,
      const Duration(seconds: 5),
    );
    await player.setAudioSources([offsetSource()], initialPosition: _offset);
    expect(native.player.loads.last.initialPosition, Duration.zero);
    await player.setAudioSources([
      offsetSource(),
    ], initialPosition: const Duration(seconds: 10));
    expect(native.player.loads.last.initialPosition, Duration.zero);
  });

  for (final knownDuration in [true, false]) {
    test(
      'a loop of an offset stream is an autoAdvance discontinuity from sparse '
      'events (duration known: $knownDuration)',
      () async {
        final player = newPlayer();
        await player.setAudioSource(offsetSource());
        await player.setLoopMode(LoopMode.one);
        unawaited(player.play());
        await pumpEventQueue();
        final discontinuities = <PositionDiscontinuity>[];
        final subscription = player.positionDiscontinuityStream.listen(
          discontinuities.add,
        );
        addTearDown(subscription.cancel);
        final duration = knownDuration ? const Duration(seconds: 60) : null;

        // ExoPlayer reports almost nothing during steady playback: one event
        // after the load, then one after the native loop.
        native.player.emit(
          duration: duration,
          at: DateTime.now().subtract(const Duration(seconds: 60)),
        );
        await pumpEventQueue();
        native.player.emit(
          position: const Duration(milliseconds: 50),
          duration: duration,
        );
        await pumpEventQueue();

        expect(discontinuities.map((d) => d.reason), [
          PositionDiscontinuityReason.autoAdvance,
        ]);
      },
    );
  }

  for (final offset in [Duration.zero, _offset]) {
    for (final index in [1, 2]) {
      for (final knownDuration in [false, true]) {
        test('owned HTTP restart keeps one same-index loop event: '
            'offset=$offset, index=$index, known=$knownDuration', () async {
          final player = newPlayer();
          await player.setAudioSources([
            plainSource(),
            offsetSource(offset),
            offsetSource(offset),
          ], initialIndex: index);
          await player.setLoopMode(LoopMode.one);
          unawaited(player.play());
          await pumpEventQueue();
          final discontinuities = <PositionDiscontinuity>[];
          final subscription = player.positionDiscontinuityStream.listen(
            discontinuities.add,
          );
          addTearDown(subscription.cancel);
          final duration = knownDuration ? const Duration(seconds: 60) : null;
          // Android publishes the tail before its owned seek, without completed.
          native.player.emit(
            position: const Duration(seconds: 60),
            duration: duration,
            index: index,
          );
          await pumpEventQueue();
          native.player.emit(
            duration: duration,
            state: platform.ProcessingStateMessage.buffering,
          );
          await pumpEventQueue();
          native.player.emit(duration: duration);
          await pumpEventQueue();
          expect(player.loopMode, LoopMode.one);
          expect(player.currentIndex, index);
          expect(player.processingState, ProcessingState.ready);
          expect(discontinuities, hasLength(1));
          final event = discontinuities.single;
          expect(event.reason, PositionDiscontinuityReason.autoAdvance);
          expect(event.previousEvent.currentIndex, index);
          expect(event.event.currentIndex, index);
          expect(event.event.updatePosition, offset);
        });
      }
    }
  }

  test(
    'a position jump back on an offset stream mid-song is no loop',
    () async {
      final player = newPlayer();
      await player.setAudioSource(offsetSource());
      await player.setLoopMode(LoopMode.one);
      unawaited(player.play());
      await pumpEventQueue();
      final discontinuities = <PositionDiscontinuity>[];
      final subscription = player.positionDiscontinuityStream.listen(
        discontinuities.add,
      );
      addTearDown(subscription.cancel);
      native.player.emit(
        position: const Duration(seconds: 10),
        duration: const Duration(seconds: 60),
      );
      await pumpEventQueue();
      native.player.emit(
        position: const Duration(milliseconds: 50),
        duration: const Duration(seconds: 60),
      );
      await pumpEventQueue();
      expect(discontinuities, isEmpty);
    },
  );

  test(
    'an event with the old index during a queue edit keeps its own offset',
    () async {
      final player = newPlayer();
      await player.setAudioSource(offsetSource());
      native.player.emit(position: const Duration(seconds: 2));
      await pumpEventQueue();
      final gate = native.player.insertGate = Completer<void>();

      // The fill inserts songs before the current one at index 0: the Dart
      // sequence changes now, the platform's indices only once it applies it.
      final insert = player.insertAudioSource(0, plainSource());
      await pumpEventQueue();
      expect(
        (player.sequence.first as UriAudioSource).positionOffset,
        Duration.zero,
      );
      native.player.emit(
        position: const Duration(seconds: 3),
        buffered: const Duration(seconds: 6),
        duration: const Duration(seconds: 60),
        index: 0,
      );
      await pumpEventQueue();

      expect(
        player.playbackEvent.updatePosition,
        _offset + const Duration(seconds: 3),
      );
      expect(player.bufferedPosition, _offset + const Duration(seconds: 6));
      expect(player.duration, _offset + const Duration(seconds: 60));
      // The duration lands on the offset item, not the inserted one.
      expect(player.sequence[0].duration, isNull);
      expect(
        player.sequence[1].duration,
        _offset + const Duration(seconds: 60),
      );

      gate.complete();
      await insert;
      // After the edit the platform reports the shifted index.
      native.player.emit(position: const Duration(seconds: 4), index: 1);
      await pumpEventQueue();
      expect(
        player.playbackEvent.updatePosition,
        _offset + const Duration(seconds: 4),
      );
      expect(player.currentIndex, 1);
    },
  );

  test('a zero offset leaves positions and seeks untouched', () async {
    final player = newPlayer();
    await player.setAudioSources([
      plainSource(),
    ], initialPosition: const Duration(seconds: 9));
    expect(
      native.player.loads.last.initialPosition,
      const Duration(seconds: 9),
    );
    native.player.emit(
      position: const Duration(seconds: 2),
      buffered: const Duration(seconds: 5),
      duration: const Duration(seconds: 60),
    );
    await pumpEventQueue();
    expect(player.playbackEvent.updatePosition, const Duration(seconds: 2));
    expect(player.bufferedPosition, const Duration(seconds: 5));
    expect(player.duration, const Duration(seconds: 60));
    await player.seek(const Duration(seconds: 30));
    expect(native.player.seeks.single.position, const Duration(seconds: 30));
  });
}

class _OffsetPlatform extends platform.JustAudioPlatform {
  late _OffsetPlayer player;
  int initializations = 0;

  @override
  Future<platform.AudioPlayerPlatform> init(
    platform.InitRequest request,
  ) async {
    initializations++;
    return player = _OffsetPlayer(request.id);
  }

  @override
  Future<platform.DisposeAllPlayersResponse> disposeAllPlayers(
    platform.DisposeAllPlayersRequest request,
  ) async => platform.DisposeAllPlayersResponse();

  @override
  Future<platform.DisposePlayerResponse> disposePlayer(
    platform.DisposePlayerRequest request,
  ) async => platform.DisposePlayerResponse();
}

class _OffsetPlayer extends platform.AudioPlayerPlatform {
  new(super.id);

  /// While set, `concatenatingInsertAll` waits for it: the window in which
  /// the platform has not applied a playlist edit yet.
  Completer<void>? insertGate;
  final loads = <platform.LoadRequest>[];
  final seeks = <platform.SeekRequest>[];
  final _events = StreamController<platform.PlaybackEventMessage>.broadcast();
  var _index = 0;

  @override
  Stream<platform.PlaybackEventMessage> get playbackEventMessageStream =>
      _events.stream;

  void emit({
    Duration position = Duration.zero,
    Duration buffered = Duration.zero,
    Duration? duration,
    int? index,
    DateTime? at,
    platform.ProcessingStateMessage state =
        platform.ProcessingStateMessage.ready,
  }) {
    _index = index ?? _index;
    _events.add(
      platform.PlaybackEventMessage(
        processingState: state,
        updateTime: at ?? DateTime.now(),
        updatePosition: position,
        bufferedPosition: buffered,
        duration: duration,
        icyMetadata: null,
        currentIndex: _index,
        androidAudioSessionId: null,
      ),
    );
  }

  @override
  Future<platform.LoadResponse> load(platform.LoadRequest request) async {
    loads.add(request);
    _index = request.initialIndex ?? 0;
    emit(position: request.initialPosition ?? Duration.zero);
    return platform.LoadResponse(duration: null);
  }

  @override
  Future<platform.ConcatenatingInsertAllResponse> concatenatingInsertAll(
    platform.ConcatenatingInsertAllRequest request,
  ) async {
    await insertGate?.future;
    return platform.ConcatenatingInsertAllResponse();
  }

  @override
  Future<platform.SeekResponse> seek(platform.SeekRequest request) async {
    seeks.add(request);
    return platform.SeekResponse();
  }

  @override
  Future<platform.PlayResponse> play(platform.PlayRequest request) async =>
      platform.PlayResponse();

  @override
  Future<platform.PauseResponse> pause(platform.PauseRequest request) async =>
      platform.PauseResponse();

  @override
  Future<platform.SetVolumeResponse> setVolume(
    platform.SetVolumeRequest request,
  ) async => platform.SetVolumeResponse();

  @override
  Future<platform.SetSpeedResponse> setSpeed(
    platform.SetSpeedRequest request,
  ) async => platform.SetSpeedResponse();

  @override
  Future<platform.SetLoopModeResponse> setLoopMode(
    platform.SetLoopModeRequest request,
  ) async => platform.SetLoopModeResponse();

  @override
  Future<platform.SetShuffleModeResponse> setShuffleMode(
    platform.SetShuffleModeRequest request,
  ) async => platform.SetShuffleModeResponse();
}
