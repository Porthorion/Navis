import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_media_kit/mediakit_player.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:media_kit/media_kit.dart';
import 'package:mocktail/mocktail.dart';

class _Player extends Mock implements Player;

class _Streams extends Mock implements PlayerStream;

void main() {
  late _Player player;
  late MediaKitPlayer adapter;
  late StreamController<Duration> duration;
  late PlayerState state;

  setUp(() async {
    player = _Player();
    final streams = _Streams();
    duration = StreamController<Duration>.broadcast();
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
    when(() => streams.completed).thenAnswer((_) => const Stream.empty());
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
    when(() => player.seek(any())).thenAnswer((_) async {});
    when(player.dispose).thenAnswer((_) async {});
    adapter = MediaKitPlayer('test', player: player);
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
  });

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
}
