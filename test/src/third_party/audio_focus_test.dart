import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart'
    as platform;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'denial abandons the cached request and completes after three attempts',
    () async {
      final calls = <bool>[];
      final player = AudioPlayer(
        activateAudioSession: (active) async {
          calls.add(active);
          return !active;
        },
      );
      addTearDown(player.dispose);
      await expectLater(
        player.play().timeout(const Duration(seconds: 2)),
        throwsA(isA<AudioFocusDeniedException>()),
      );
      expect(calls, [true, false, true, false, true, false]);
      expect(player.playing, isFalse);
    },
  );

  test('retry requests fresh focus before reporting playing', () async {
    var cached = false;
    var requests = 0;
    final player = AudioPlayer(
      activateAudioSession: (active) async {
        if (!active) {
          cached = false;
          return true;
        }
        if (cached) return true; // audio_session's denied-request cache.
        cached = true;
        return ++requests >= 2;
      },
    );
    addTearDown(player.dispose);
    unawaited(player.play());
    await Future<void>.delayed(const Duration(milliseconds: 350));
    expect(requests, 2);
    expect(player.playing, isTrue);
    await player.pause();
  });

  test(
    'a superseded denial cannot abandon focus acquired by a newer Play',
    () async {
      final firstRequest = Completer<bool>();
      final firstEntered = Completer<void>();
      final secondEntered = Completer<void>();
      final calls = <bool>[];
      final player = AudioPlayer(
        activateAudioSession: (active) async {
          calls.add(active);
          if (calls.length == 1) {
            firstEntered.complete();
            return firstRequest.future;
          }
          if (active && !secondEntered.isCompleted) secondEntered.complete();
          return true;
        },
      );
      addTearDown(player.dispose);
      final firstPlay = player.play();
      await firstEntered.future;
      await player.pause();
      unawaited(player.play());
      await secondEntered.future;
      firstRequest.complete(false);
      await firstPlay;
      expect(calls, [true, true]);
      expect(player.playing, isTrue);
      await player.pause();
    },
  );

  test('denied focus never reports playing', () async {
    final player = AudioPlayer(activateAudioSession: (active) async => !active);
    addTearDown(player.dispose);
    final reported = <bool>[];
    final subscription = player.playingStream.listen(reported.add);
    addTearDown(subscription.cancel);
    await expectLater(player.play(), throwsA(isA<AudioFocusDeniedException>()));
    expect(reported, isNot(contains(true)));
  });

  test('a load while focus is pending cannot start native playback', () async {
    final native = _FocusPlatform();
    final previous = platform.JustAudioPlatform.instance;
    platform.JustAudioPlatform.instance = native;
    addTearDown(() => platform.JustAudioPlatform.instance = previous);
    final focus = Completer<bool>();
    final player = AudioPlayer(
      activateAudioSession: (active) =>
          active ? focus.future : Future.value(true),
    );
    addTearDown(player.dispose);
    unawaited(player.play());
    await player.setAudioSource(
      AudioSource.uri(Uri.parse('https://radio.example.invalid/live')),
    );
    await pumpEventQueue();
    expect(native.plays, 0);
    expect(player.playing, isFalse);
    focus.complete(true);
    await pumpEventQueue();
    expect(native.plays, 1);
    expect(player.playing, isTrue);
    await player.pause();
  });

  test('Pause cancels a pending denied focus retry', () async {
    var requests = 0;
    final denied = Completer<void>();
    final player = AudioPlayer(
      activateAudioSession: (active) async {
        if (active) {
          requests++;
          if (!denied.isCompleted) denied.complete();
        }
        return !active;
      },
    );
    addTearDown(player.dispose);
    final play = player.play();
    await denied.future;
    await player.pause();
    await play.timeout(const Duration(seconds: 1));
    expect(requests, 1);
    expect(player.playing, isFalse);
  });
}

class _FocusPlatform extends platform.JustAudioPlatform {
  final players = <_FocusPlayer>[];

  int get plays => players.fold(0, (sum, player) => sum + player.plays);

  @override
  Future<platform.AudioPlayerPlatform> init(
    platform.InitRequest request,
  ) async {
    final player = _FocusPlayer(request.id);
    players.add(player);
    return player;
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

class _FocusPlayer extends platform.AudioPlayerPlatform {
  new(super.id);

  int plays = 0;
  final _events = StreamController<platform.PlaybackEventMessage>.broadcast();

  @override
  Stream<platform.PlaybackEventMessage> get playbackEventMessageStream =>
      _events.stream;

  @override
  Future<platform.LoadResponse> load(platform.LoadRequest request) async {
    _events.add(
      platform.PlaybackEventMessage(
        processingState: platform.ProcessingStateMessage.ready,
        updateTime: DateTime.now(),
        updatePosition: Duration.zero,
        bufferedPosition: Duration.zero,
        duration: null,
        icyMetadata: null,
        currentIndex: 0,
        androidAudioSessionId: null,
      ),
    );
    return platform.LoadResponse(duration: null);
  }

  @override
  Future<platform.PlayResponse> play(platform.PlayRequest request) async {
    plays++;
    return platform.PlayResponse();
  }

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
