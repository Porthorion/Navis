import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_media_kit/mediakit_player.dart';
import 'package:just_audio_media_kit/src/icy_metadata.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:media_kit/media_kit.dart';
import 'package:mocktail/mocktail.dart';

class _Player extends Mock implements Player;

class _Streams extends Mock implements PlayerStream;

class _Properties implements IcyPropertySource {
  String inputRate = '';
  int inputReads = 0;

  @override
  Future<String> read(String property) async {
    if (property != 'cache-speed') return '';
    inputReads++;
    return inputRate;
  }

  @override
  Future<void> observe(
    String property,
    Future<void> Function(String) listener,
  ) async {}

  @override
  Future<void> unobserve(String property) async {}
}

void main() {
  late _Player player;
  late MediaKitPlayer adapter;
  late _Properties properties;
  late StreamController<Duration> duration;
  late StreamController<bool> completed;
  late PlayerState state;

  setUp(() async {
    player = _Player();
    final streams = _Streams();
    duration = StreamController<Duration>.broadcast();
    completed = StreamController<bool>.broadcast();
    final playlist = Playlist([
      Media('https://stream.example.invalid/a'),
      Media('https://stream.example.invalid/b'),
    ]);
    state = PlayerState(
      playlist: playlist,
      duration: const Duration(minutes: 2),
    );
    registerFallbackValue(playlist);
    registerFallbackValue(Duration.zero);
    when(() => player.stream).thenReturn(streams);
    when(() => player.state).thenAnswer((_) => state);
    when(() => streams.audioParams).thenAnswer((_) => const Stream.empty());
    when(() => streams.duration).thenAnswer((_) => duration.stream);
    when(() => streams.position).thenAnswer((_) => const Stream.empty());
    when(() => streams.buffering).thenAnswer((_) => const Stream.empty());
    when(() => streams.buffer).thenAnswer((_) => const Stream.empty());
    when(() => streams.volume).thenAnswer((_) => const Stream.empty());
    when(() => streams.completed).thenAnswer((_) => completed.stream);
    when(() => streams.error).thenAnswer((_) => const Stream.empty());
    when(() => streams.playlist).thenAnswer((_) => const Stream.empty());
    when(() => streams.playlistMode).thenAnswer((_) => const Stream.empty());
    when(() => streams.pitch).thenAnswer((_) => const Stream.empty());
    when(() => streams.rate).thenAnswer((_) => const Stream.empty());
    when(() => streams.log).thenAnswer((_) => const Stream.empty());
    when(() => player.open(any(), play: any(named: 'play')))
        .thenAnswer((_) async {});
    when(() => player.jump(any())).thenAnswer((call) async {
      // media_kit may still expose the previous duration when jump returns.
      state = state.copyWith(
        playlist: playlist.copyWith(
          index: call.positionalArguments.single as int,
        ),
      );
    });
    when(player.pause).thenAnswer((_) async {});
    when(player.play).thenAnswer((_) async {});
    when(() => player.seek(any())).thenAnswer((_) async {});
    when(player.dispose).thenAnswer((_) async {});
    properties = _Properties();
    adapter = MediaKitPlayer(
      'test',
      player: player,
      icyPropertySource: properties,
    );
    await adapter.load(
      LoadRequest(
        audioSourceMessage: ConcatenatingAudioSourceMessage(
          id: 'queue',
          children: [
            for (final media in playlist.medias)
              ProgressiveAudioSourceMessage(
                id: media.uri,
                uri: media.uri,
                headers: null,
              ),
          ],
          useLazyPreparation: false,
          shuffleOrder: [0, 1],
        ),
        initialIndex: 0,
        initialPosition: null,
      ),
    );
    duration.add(state.duration);
    await Future<void>.delayed(Duration.zero);
  });

  tearDown(() async {
    await adapter.release();
    await duration.close();
    await completed.close();
  });

  test(
    'buffering current-track seek uses native position with no input polling',
    () async {
      state = state.copyWith(buffering: true);
      properties.inputRate = '187496';
      const target = Duration(seconds: 30);
      await adapter.seek(SeekRequest(index: null, position: target));
      verify(() => player.seek(target)).called(1);
      expect(state.position, Duration.zero);
      expect(state.buffer, Duration.zero);
      expect(properties.inputReads, 0);
    },
  );

  test(
    'jump with zero position issues no native seek, even after ready',
    () async {
      await adapter.seek(SeekRequest(index: 1, position: Duration.zero));
      verify(() => player.jump(1)).called(1);
      verify(() => player.pause()).called(1);
      verifyNever(() => player.seek(any()));
      duration.add(state.duration);
      await Future<void>.delayed(Duration.zero);
      verifyNever(() => player.seek(any()));
      expect(adapter.debugTransportState['pendingPosition'], isFalse);
    },
  );

  test('jump with 30 seconds waits for the new entry to be ready', () async {
    const target = Duration(seconds: 30);
    await adapter.seek(SeekRequest(index: 1, position: target));
    verify(() => player.jump(1)).called(1);
    verifyNever(() => player.seek(any()));
    expect(adapter.debugTransportState['pendingPosition'], isTrue);
    state = state.copyWith(duration: Duration.zero);
    duration.add(state.duration);
    await Future<void>.delayed(Duration.zero);
    verifyNever(() => player.seek(any()));
    state = state.copyWith(duration: const Duration(minutes: 2));
    duration.add(state.duration);
    await Future<void>.delayed(Duration.zero);
    verify(() => player.seek(target)).called(1);
    expect(adapter.debugTransportState['pendingPosition'], isFalse);
  });

  test('a zero-position jump clears a previous deferred seek', () async {
    await adapter.seek(
      SeekRequest(index: 1, position: const Duration(seconds: 30)),
    );
    await adapter.seek(SeekRequest(index: 0, position: Duration.zero));
    duration.add(state.duration);
    await Future<void>.delayed(Duration.zero);
    verifyNever(() => player.seek(any()));
    expect(adapter.debugTransportState['pendingPosition'], isFalse);
  });

  for (final target in [Duration.zero, const Duration(seconds: 30)]) {
    test('current-track seek to $target still issues a native seek', () async {
      await adapter.seek(SeekRequest(index: null, position: target));
      verifyNever(() => player.jump(any()));
      verify(() => player.seek(target)).called(1);
      expect(adapter.debugTransportState['pendingPosition'], isFalse);
    });
  }

  for (final target in [Duration.zero, const Duration(seconds: 30)]) {
    test(
      'seeking the playing entry by index to $target is a plain seek',
      () async {
        // Previous restarts the current song with seek(0, index: current);
        // mpv ignores a jump to the entry already playing.
        await adapter.seek(SeekRequest(index: 0, position: target));
        verifyNever(() => player.jump(any()));
        verify(() => player.seek(target)).called(1);
        expect(adapter.debugTransportState['pendingPosition'], isFalse);
      },
    );
  }

  group('seek out of a finished queue', () {
    // A one-song queue whose only entry has played to the end. mpv keeps the
    // file open and paused at EOF, which media_kit reports as completed.
    Future<void> finishOneSongQueue({required bool playing}) async {
      final one = Playlist([Media('https://stream.example.invalid/a')]);
      state = state.copyWith(playlist: one);
      await adapter.load(
        LoadRequest(
          audioSourceMessage: ConcatenatingAudioSourceMessage(
            id: 'queue',
            children: [
              ProgressiveAudioSourceMessage(
                id: 'a',
                uri: one.medias.single.uri,
                headers: null,
              ),
            ],
            useLazyPreparation: false,
            shuffleOrder: [0],
          ),
          initialIndex: 0,
          initialPosition: null,
        ),
      );
      duration.add(state.duration);
      await Future<void>.delayed(Duration.zero);
      if (playing) await adapter.play(PlayRequest());
      state = state.copyWith(completed: true, playing: false);
      completed.add(true);
      await Future<void>.delayed(Duration.zero);
      expect(adapter.debugTransportState['processingState'], 'completed');
      clearInteractions(player);
    }

    for (final (name, request) in [
      ('restart by index', SeekRequest(index: 0, position: Duration.zero)),
      (
        'seek bar',
        SeekRequest(index: null, position: const Duration(seconds: 5)),
      ),
    ]) {
      test('$name resumes the paused-at-EOF player', () async {
        await finishOneSongQueue(playing: true);
        await adapter.seek(request);
        verify(() => player.play()).called(1);
        verify(() => player.seek(any())).called(1);
        expect(
          adapter.debugTransportState['processingState'],
          isNot('completed'),
        );
      });
    }

    test('a paused queue leaves completed but stays silent', () async {
      await finishOneSongQueue(playing: false);
      await adapter.seek(SeekRequest(index: 0, position: Duration.zero));
      verifyNever(() => player.play());
      verify(() => player.seek(any())).called(1);
      expect(
        adapter.debugTransportState['processingState'],
        isNot('completed'),
      );
    });
  });
}
