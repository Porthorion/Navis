import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';

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
