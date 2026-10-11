import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

import '../../../../helpers/now_playing_harness.dart';
import '../../../../helpers/test_database.dart';

const PlaybackSnapshot _song1Playback = PlaybackSnapshot(
  queueSongIds: <String>['song-1', 'song-2'],
  currentSongId: 'song-1',
  currentIndex: 0,
  playing: true,
  processingState: AudioProcessingState.ready,
  position: Duration(seconds: 42),
  duration: Duration(minutes: 3, seconds: 30),
  bufferedPosition: Duration(minutes: 1),
  shuffleMode: AudioServiceShuffleMode.none,
  repeatMode: AudioServiceRepeatMode.none,
);

const PlaybackSnapshot _song2Playback = PlaybackSnapshot(
  queueSongIds: <String>['song-1', 'song-2'],
  currentSongId: 'song-2',
  currentIndex: 1,
  playing: true,
  processingState: AudioProcessingState.ready,
  position: Duration.zero,
  duration: Duration(minutes: 4),
  bufferedPosition: Duration.zero,
  shuffleMode: AudioServiceShuffleMode.none,
  repeatMode: AudioServiceRepeatMode.none,
);

ProviderContainer _createContainer({
  required Stream<TransportVisualCue> cueStream,
  PlaybackBufferState bufferState = const PlaybackBufferState.idle(),
}) => createNowPlayingContainer(
  overrides: <Override>[
    transportVisualCueProvider.overrideWith((ref) => cueStream),
    playbackBufferStateProvider.overrideWithValue(AsyncData(bufferState)),
  ],
);

Finder _findValueKeyPrefix(String prefix) {
  return find.byWidgetPredicate((widget) {
    final key = widget.key;
    return key is ValueKey<String> && key.value.startsWith(prefix);
  });
}

Finder _findNonZeroSlideTransitionAncestors(Finder target) {
  return find.ancestor(
    of: target,
    matching: find.byWidgetPredicate((widget) {
      if (widget is! SlideTransition) {
        return false;
      }
      final dx = widget.position.value.dx;
      return dx.abs() > 0.0001;
    }),
  );
}

Finder _findActiveHorizontalSlideTransitions() {
  return find.byWidgetPredicate((widget) {
    if (widget is! SlideTransition) {
      return false;
    }
    final dx = widget.position.value.dx;
    return dx.abs() > 0.0001;
  });
}

void main() {
  testWidgets('repeat one seek settlement resumes live progress and wraps', (
    tester,
  ) async {
    final positions = StreamController<Duration>.broadcast();
    addTearDown(positions.close);
    final container = createNowPlayingContainer(
      overrides: [
        playbackPositionProvider.overrideWith((ref) => positions.stream),
      ],
    );
    final repeating = _song1Playback.copyWith(
      repeatMode: AudioServiceRepeatMode.one,
    );
    emitNowPlayingPlayback(container, repeating);
    await pumpPlainNowPlayingScreen(
      tester,
      container,
      viewport: const Size(390, 844),
    );
    await tester.pumpAndSettle();
    double displayed() =>
        tester.widget<Slider>(find.byType(Slider).first).value;
    positions.add(const Duration(seconds: 43));
    await tester.pump();
    await tester.pump();
    expect(displayed(), 43000);

    emitNowPlayingPlayback(
      container,
      repeating.copyWith(pendingSeekPosition: const Duration(seconds: 196)),
    );
    await tester.pump();
    await tester.pump();
    positions.add(const Duration(seconds: 197));
    await tester.pump();
    await tester.pump();
    expect(displayed(), 196000);

    emitNowPlayingPlayback(
      container,
      repeating.copyWith(
        position: const Duration(seconds: 197),
        pendingSeekPosition: null,
      ),
    );
    await tester.pump();
    await tester.pump();
    positions.add(const Duration(seconds: 198));
    await tester.pump();
    await tester.pump();
    expect(displayed(), 198000);
    // Loop one emits timeline changes without new song metadata.
    positions.add(const Duration(seconds: 1));
    await tester.pump();
    await tester.pump();
    expect(displayed(), 1000);
    positions.add(const Duration(seconds: 2));
    await tester.pump();
    await tester.pump();
    expect(displayed(), 2000);
  }, skip: !sqliteAvailable);

  testWidgets('seek bar shows buffered audio as a secondary track', (
    tester,
  ) async {
    final container = _createContainer(
      cueStream: const Stream<TransportVisualCue>.empty(),
      bufferState: const PlaybackBufferState(
        songId: 'song-1',
        bufferedPosition: Duration(minutes: 1, seconds: 20),
      ),
    );

    await pumpPlainNowPlayingScreen(tester, container);

    emitNowPlayingPlayback(container, _song1Playback);
    await tester.pumpAndSettle();

    final seekSlider = tester.widget<Slider>(find.byType(Slider).first);
    expect(seekSlider.max, _song1Playback.duration.inMilliseconds);
    expect(seekSlider.secondaryTrackValue, 80000);
    expect(seekSlider.secondaryActiveColor, isNotNull);
  }, skip: !sqliteAvailable);

  testWidgets('manual song changes swap to the new cover-art child', (
    tester,
  ) async {
    final cueController = StreamController<TransportVisualCue>.broadcast();
    addTearDown(cueController.close);

    final container = _createContainer(cueStream: cueController.stream);

    await pumpPlainNowPlayingScreen(tester, container);

    emitNowPlayingPlayback(container, _song1Playback);
    await tester.pumpAndSettle();

    cueController.add(
      const TransportVisualCue(
        token: 1,
        intent: TransportVisualIntent.next,
        fromSongId: 'song-1',
      ),
    );
    await tester.pump();
    emitNowPlayingPlayback(container, _song2Playback);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    final incomingCover = _findValueKeyPrefix('cover-song:song-2:');
    expect(incomingCover, findsOneWidget);
    expect(find.byKey(const ValueKey<String>('art-shell')), findsOneWidget);
  }, skip: !sqliteAvailable);

  testWidgets('automatic advances avoid directional artwork travel', (
    tester,
  ) async {
    final container = _createContainer(
      cueStream: const Stream<TransportVisualCue>.empty(),
    );
    await pumpPlainNowPlayingScreen(tester, container);
    emitNowPlayingPlayback(container, _song1Playback);
    await tester.pumpAndSettle();
    emitNowPlayingPlayback(container, _song2Playback);
    await tester.pump(const Duration(milliseconds: 16));

    expect(_findActiveHorizontalSlideTransitions(), findsNothing);
  }, skip: !sqliteAvailable);

  testWidgets(
    'lyrics close stays neutral even after manual direction was latched',
    (tester) async {
      final cueController = StreamController<TransportVisualCue>.broadcast();
      addTearDown(cueController.close);

      final container = _createContainer(cueStream: cueController.stream);

      await pumpPlainNowPlayingScreen(tester, container);

      emitNowPlayingPlayback(container, _song1Playback);
      await tester.pumpAndSettle();

      cueController.add(
        const TransportVisualCue(
          token: 1,
          intent: TransportVisualIntent.next,
          fromSongId: 'song-1',
        ),
      );
      await tester.pump();
      emitNowPlayingPlayback(container, _song2Playback);
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.lyrics_outlined));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.lyrics));
      await tester.pump(const Duration(milliseconds: 16));

      final artShell = find.byKey(const ValueKey<String>('art-shell'));
      expect(artShell, findsOneWidget);
      expect(_findActiveHorizontalSlideTransitions(), findsNothing);
      expect(_findNonZeroSlideTransitionAncestors(artShell), findsNothing);
    },
    skip: !sqliteAvailable,
  );

  testWidgets('transport outcomes use quiet rewind and edge feedback', (
    tester,
  ) async {
    final cueController = StreamController<TransportVisualCue>.broadcast();
    addTearDown(cueController.close);
    final container = _createContainer(cueStream: cueController.stream);

    await pumpPlainNowPlayingScreen(tester, container);

    emitNowPlayingPlayback(container, _song1Playback);
    await tester.pumpAndSettle();

    cueController.add(
      const TransportVisualCue(
        token: 1,
        intent: TransportVisualIntent.restartCurrent,
        fromSongId: 'song-1',
      ),
    );
    await tester.pump(const Duration(milliseconds: 48));

    expect(
      find.byKey(
        const ValueKey<String>('track-navigation-feedback-restartCurrent'),
      ),
      findsOneWidget,
    );

    await tester.pumpAndSettle();
    expect(
      find.byKey(
        const ValueKey<String>('track-navigation-feedback-restartCurrent'),
      ),
      findsNothing,
    );

    cueController.add(
      const TransportVisualCue(
        token: 2,
        intent: TransportVisualIntent.unavailablePrevious,
        fromSongId: 'song-1',
      ),
    );
    await tester.pump(const Duration(milliseconds: 48));

    expect(
      find.byKey(
        const ValueKey<String>('track-navigation-feedback-unavailablePrevious'),
      ),
      findsOneWidget,
    );

    await tester.pumpAndSettle();
    cueController.add(
      const TransportVisualCue(
        token: 3,
        intent: TransportVisualIntent.unavailableNext,
        fromSongId: 'song-1',
      ),
    );
    await tester.pump(const Duration(milliseconds: 48));

    expect(
      find.byKey(
        const ValueKey<String>('track-navigation-feedback-unavailableNext'),
      ),
      findsOneWidget,
    );

    await tester.pumpAndSettle();
    expect(
      find.byKey(
        const ValueKey<String>('track-navigation-feedback-unavailableNext'),
      ),
      findsNothing,
    );
  }, skip: !sqliteAvailable);
}
