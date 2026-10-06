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
  final listeners = <String, Future<void> Function(String)>{};
  String path = '';
  String title = 'Artist - Song';

  @override
  Future<String> read(String property) async => switch (property) {
    'path' => path,
    'metadata/by-key/icy-title' => title,
    'metadata/by-key/icy-name' => 'Station',
    _ => '',
  };
  @override
  Future<void> observe(
    String property,
    Future<void> Function(String) listener,
  ) async {
    listeners[property] = listener;
  }

  @override
  Future<void> unobserve(String property) async {
    listeners.remove(property);
  }
}

void main() {
  test('adapter publishes ICY changes and clears them on a new load', () async {
    final player = _Player();
    final streams = _Streams();
    final properties = _Properties();
    final playlist = StreamController<Playlist>.broadcast();
    var state = const PlayerState();
    registerFallbackValue(Media('https://stream.example.invalid/fallback'));
    when(() => player.stream).thenReturn(streams);
    when(() => player.state).thenAnswer((_) => state);
    when(() => streams.audioParams).thenAnswer((_) => const Stream.empty());
    when(() => streams.duration).thenAnswer((_) => const Stream.empty());
    when(() => streams.position).thenAnswer((_) => const Stream.empty());
    when(() => streams.buffering).thenAnswer((_) => const Stream.empty());
    when(() => streams.buffer).thenAnswer((_) => const Stream.empty());
    when(() => streams.volume).thenAnswer((_) => const Stream.empty());
    when(() => streams.completed).thenAnswer((_) => const Stream.empty());
    when(() => streams.playing).thenAnswer((_) => const Stream.empty());
    when(() => streams.error).thenAnswer((_) => const Stream.empty());
    when(() => streams.playlist).thenAnswer((_) => playlist.stream);
    when(() => streams.playlistMode).thenAnswer((_) => const Stream.empty());
    when(() => streams.pitch).thenAnswer((_) => const Stream.empty());
    when(() => streams.rate).thenAnswer((_) => const Stream.empty());
    when(() => streams.log).thenAnswer((_) => const Stream.empty());
    when(player.dispose).thenAnswer((_) async {});
    final entered = Completer<void>();
    final gate = Completer<void>();
    when(() => player.open(any(), play: any(named: 'play')))
        .thenAnswer((call) async {
          final playable = call.positionalArguments.single;
          if (playable is Playlist) {
            state = PlayerState(playlist: playable);
            properties.path = playable.medias.firstOrNull?.uri ?? '';
            return;
          }
          final media = playable as Media;
          if (media.uri.endsWith('/b')) {
            entered.complete();
            await gate.future;
          }
          properties.path = media.uri;
          state = PlayerState(playlist: Playlist([media]));
        });
    final adapter = MediaKitPlayer(
      'test',
      player: player,
      icyPropertySource: properties,
    );
    final events = <PlaybackEventMessage>[];
    final subscription = adapter.playbackEventMessageStream.listen(events.add);
    addTearDown(() async {
      if (!gate.isCompleted) gate.complete();
      await adapter.release();
      await subscription.cancel();
      await playlist.close();
    });
    LoadRequest load(String station) => LoadRequest(
      audioSourceMessage: ProgressiveAudioSourceMessage(
        id: station,
        uri: 'https://stream.example.invalid/$station',
        headers: null,
      ),
      initialPosition: null,
      initialIndex: null,
    );
    await adapter.load(load('a'));
    await Future<void>.delayed(Duration.zero);
    expect(events.last.icyMetadata?.info?.title, 'Artist - Song');
    final count = events.length;
    await properties.listeners['metadata']!('');
    await Future<void>.delayed(Duration.zero);
    expect(events, hasLength(count));
    properties.title = 'Next Song';
    await properties.listeners['metadata']!('');
    await Future<void>.delayed(Duration.zero);
    expect(events.last.icyMetadata?.info?.title, 'Next Song');
    final switching = adapter.load(load('b'));
    await entered.future;
    await Future<void>.delayed(Duration.zero);
    expect(events.last.icyMetadata, isNull);
    await properties.listeners['metadata']!('');
    await Future<void>.delayed(Duration.zero);
    expect(events.last.icyMetadata, isNull);
    properties.title = 'Station B Song';
    gate.complete();
    await switching;
    await Future<void>.delayed(Duration.zero);
    expect(events.last.icyMetadata?.info?.title, 'Station B Song');
    final replacement = Media('https://stream.example.invalid/c');
    properties.path = replacement.uri;
    properties.title = 'Station C Song';
    state = PlayerState(playlist: Playlist([replacement]));
    playlist.add(state.playlist);
    await Future<void>.delayed(Duration.zero);
    expect(events.last.icyMetadata?.info?.title, 'Station C Song');
    await adapter.load(
      LoadRequest(
        audioSourceMessage: ConcatenatingAudioSourceMessage(
          id: 'empty',
          children: [],
          useLazyPreparation: false,
          shuffleOrder: [],
        ),
        initialPosition: null,
        initialIndex: null,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(events.last.icyMetadata, isNull);
  });
}
