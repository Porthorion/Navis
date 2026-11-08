import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart'
    as platform;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Platform native;

  setUp(() {
    native = _Platform();
    final previous = platform.JustAudioPlatform.instance;
    platform.JustAudioPlatform.instance = native;
    addTearDown(() => platform.JustAudioPlatform.instance = previous);
  });

  AudioPlayer newPlayer() {
    final player = AudioPlayer(activateAudioSession: (active) async => true);
    addTearDown(player.dispose);
    return player;
  }

  UriAudioSource song(String name) =>
      AudioSource.uri(Uri.parse('https://music.example.invalid/$name'));

  test(
    'the same correcting map is sent again after sources are reloaded',
    () async {
      final player = newPlayer();
      final a = song('a');
      final b = song('b');
      final levels = {a: -4.0, b: -4.0};
      // The sources are stamped -10, then corrected by a push.
      a.replayGainDb = -10;
      b.replayGainDb = -10;
      await player.setAudioSources([a, b]);
      await player.setReplayGainLevels(bySource: levels);
      await player.setReplayGainLevels(bySource: levels);
      expect(
        native.player.levels,
        hasLength(1),
        reason: 'identical is skipped',
      );
      // Re-loading re-sends the stamped -10: the same map is news again.
      a.replayGainDb = -10;
      b.replayGainDb = -10;
      await player.setAudioSources([a, b]);
      await player.setReplayGainLevels(bySource: levels);
      expect(native.player.levels, hasLength(2));
    },
  );

  test('an insert also makes the same map news', () async {
    final player = newPlayer();
    final a = song('a');
    await player.setAudioSources([a]);
    await player.setReplayGainLevels(bySource: {a: -4});
    await player.insertAudioSources(0, [song('b')]);
    await player.setReplayGainLevels(bySource: {a: -4});
    expect(native.player.levels, hasLength(2));
  });

  group('clipping', () {
    ClippingAudioSource clip({double? clipDb, double? childDb}) {
      final child = song('c')..replayGainDb = childDb;
      return ClippingAudioSource(
        child: child,
        start: Duration.zero,
        end: const Duration(seconds: 5),
      )..replayGainDb = clipDb;
    }

    Future<double?> loadedGain(ClippingAudioSource source) async {
      final player = newPlayer();
      await player.setAudioSource(source);
      final playlist =
          native.player.loads.last.audioSourceMessage
              as platform.ConcatenatingAudioSourceMessage;
      final message =
          playlist.children.single as platform.ClippingAudioSourceMessage;
      return message.child.replayGainDb;
    }

    test('the level stamped on the clip wins over its child\'s', () async {
      expect(await loadedGain(clip(clipDb: -10, childDb: -3)), -10);
    });

    test('without one the child\'s travels', () async {
      expect(await loadedGain(clip(childDb: -3)), -3);
    });

    test('a push keys a clip by its child\'s id and URI', () async {
      // Native tags the child item with the child's id, so a push under the
      // clip's own id would never find a key.
      final player = newPlayer();
      final clipped = clip(childDb: -3);
      final plain = song('p');
      await player.setAudioSources([clipped, plain]);
      await player.setReplayGainLevels(bySource: {clipped: -7, plain: -2});
      final request = native.player.levels.single;
      final loaded =
          (native.player.loads.last.audioSourceMessage
                  as platform.ConcatenatingAudioSourceMessage)
              .children;
      final child = (loaded.first as platform.ClippingAudioSourceMessage).child;
      expect(request.byId[child.id], -7);
      expect(request.byId[loaded.first.id], isNull);
      expect(request.byId[loaded.last.id], -2);
      expect(request.byId, hasLength(2));
      expect(request.byUri[child.uri], -7);
    });
  });
}

class _Platform extends platform.JustAudioPlatform {
  late _Player player;

  @override
  Future<platform.AudioPlayerPlatform> init(
    platform.InitRequest request,
  ) async => player = _Player(request.id);

  @override
  Future<platform.DisposeAllPlayersResponse> disposeAllPlayers(
    platform.DisposeAllPlayersRequest request,
  ) async => platform.DisposeAllPlayersResponse();

  @override
  Future<platform.DisposePlayerResponse> disposePlayer(
    platform.DisposePlayerRequest request,
  ) async => platform.DisposePlayerResponse();
}

class _Player extends platform.AudioPlayerPlatform {
  _Player(super.id);

  final loads = <platform.LoadRequest>[];
  final levels = <platform.SetReplayGainLevelsRequest>[];

  final _events = StreamController<platform.PlaybackEventMessage>.broadcast();

  @override
  Stream<platform.PlaybackEventMessage> get playbackEventMessageStream =>
      _events.stream;

  @override
  Future<platform.LoadResponse> load(platform.LoadRequest request) async {
    loads.add(request);
    _events.add(
      platform.PlaybackEventMessage(
        processingState: platform.ProcessingStateMessage.ready,
        updateTime: DateTime.now(),
        updatePosition: Duration.zero,
        bufferedPosition: Duration.zero,
        duration: null,
        icyMetadata: null,
        currentIndex: request.initialIndex ?? 0,
        androidAudioSessionId: null,
      ),
    );
    return platform.LoadResponse(duration: null);
  }

  @override
  Future<void> setReplayGainLevels(
    platform.SetReplayGainLevelsRequest request,
  ) async => levels.add(request);

  @override
  Future<platform.ConcatenatingInsertAllResponse> concatenatingInsertAll(
    platform.ConcatenatingInsertAllRequest request,
  ) async => platform.ConcatenatingInsertAllResponse();

  @override
  Future<platform.SetShuffleModeResponse> setShuffleMode(
    platform.SetShuffleModeRequest request,
  ) async => platform.SetShuffleModeResponse();

  @override
  Future<platform.SetLoopModeResponse> setLoopMode(
    platform.SetLoopModeRequest request,
  ) async => platform.SetLoopModeResponse();

  @override
  Future<platform.SetVolumeResponse> setVolume(
    platform.SetVolumeRequest request,
  ) async => platform.SetVolumeResponse();

  @override
  Future<platform.SetSpeedResponse> setSpeed(
    platform.SetSpeedRequest request,
  ) async => platform.SetSpeedResponse();
}
