import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/presentation/now_playing_screen.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:riverpod/src/framework.dart' show Override;

import '../../../../helpers/test_database.dart';
import '../../../../helpers/test_theme.dart';

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

class _TestPlaybackNotifier extends Notifier<PlaybackSnapshot> {
  @override
  PlaybackSnapshot build() => const PlaybackSnapshot.idle();
}

final _testPlaybackProvider =
    NotifierProvider<_TestPlaybackNotifier, PlaybackSnapshot>(
      _TestPlaybackNotifier.new,
    );

ProviderContainer _createContainer({
  required Stream<ManualTrackChangeCue> cueStream,
  PlaybackBufferState bufferState = const PlaybackBufferState.idle(),
}) {
  final database = createTestDatabase();
  final container = ProviderContainer(
    overrides: withTestDatabase(
      database,
      overrides: <Override>[
        playerStateProvider.overrideWith(
          (ref) => ref.watch(_testPlaybackProvider),
        ),
        manualTrackChangeCueProvider.overrideWith((ref) => cueStream),
        playbackBufferStateProvider.overrideWithValue(AsyncData(bufferState)),
      ],
    ),
  );

  addTearDown(() async {
    container.dispose();
    await database.close();
  });

  return container;
}

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
  testWidgets('seek bar shows buffered audio as a secondary track', (
    tester,
  ) async {
    if (!sqliteAvailable) {
      return;
    }

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(880, 1200);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final container = _createContainer(
      cueStream: const Stream<ManualTrackChangeCue>.empty(),
      bufferState: const PlaybackBufferState(
        songId: 'song-1',
        bufferedPosition: Duration(minutes: 1, seconds: 20),
      ),
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: testTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: NowPlayingScreen()),
        ),
      ),
    );

    container.read(_testPlaybackProvider.notifier).state = _song1Playback;
    await tester.pumpAndSettle();

    final seekSlider = tester.widget<Slider>(find.byType(Slider).first);
    expect(seekSlider.max, _song1Playback.duration.inMilliseconds);
    expect(seekSlider.secondaryTrackValue, 80000);
    expect(seekSlider.secondaryActiveColor, isNotNull);
  });

  testWidgets(
    'manual song changes swap to the new cover-art child',
    (tester) async {
      if (!sqliteAvailable) {
        return;
      }

      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(880, 1200);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final cueController = StreamController<ManualTrackChangeCue>.broadcast();
      addTearDown(cueController.close);

      final container = _createContainer(cueStream: cueController.stream);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: testTheme(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(body: NowPlayingScreen()),
          ),
        ),
      );

      container.read(_testPlaybackProvider.notifier).state = _song1Playback;
      await tester.pumpAndSettle();

      cueController.add(
        const ManualTrackChangeCue(
          token: 1,
          direction: ManualTrackChangeDirection.next,
          fromSongId: 'song-1',
        ),
      );
      await tester.pump();
      container.read(_testPlaybackProvider.notifier).state = _song2Playback;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      final incomingCover = _findValueKeyPrefix('cover-song:song-2:');
      expect(incomingCover, findsOneWidget);
      expect(find.byKey(const ValueKey<String>('art-shell')), findsOneWidget);
    },
  );

  testWidgets(
    'lyrics close stays neutral even after manual direction was latched',
    (tester) async {
      if (!sqliteAvailable) {
        return;
      }

      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(880, 1200);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final cueController = StreamController<ManualTrackChangeCue>.broadcast();
      addTearDown(cueController.close);

      final container = _createContainer(cueStream: cueController.stream);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: testTheme(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(body: NowPlayingScreen()),
          ),
        ),
      );

      container.read(_testPlaybackProvider.notifier).state = _song1Playback;
      await tester.pumpAndSettle();

      cueController.add(
        const ManualTrackChangeCue(
          token: 1,
          direction: ManualTrackChangeDirection.next,
          fromSongId: 'song-1',
        ),
      );
      await tester.pump();
      container.read(_testPlaybackProvider.notifier).state = _song2Playback;
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
  );

  testWidgets(
    'queue boundary actions use replay and no-next feedback',
    (tester) async {
      if (!sqliteAvailable) {
        return;
      }

      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(880, 1200);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final cueController = StreamController<ManualTrackChangeCue>.broadcast();
      addTearDown(cueController.close);
      final container = _createContainer(cueStream: cueController.stream);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: testTheme(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(body: NowPlayingScreen()),
          ),
        ),
      );

      container.read(_testPlaybackProvider.notifier).state = _song1Playback;
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.skip_previous));
      await tester.pump(const Duration(milliseconds: 48));

      expect(
        find.byKey(
          const ValueKey<String>(
            'track-navigation-feedback-replayCurrent',
          ),
        ),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.replay_rounded), findsOneWidget);

      await tester.pumpAndSettle();
      expect(
        find.byKey(
          const ValueKey<String>(
            'track-navigation-feedback-replayCurrent',
          ),
        ),
        findsNothing,
      );

      container.read(_testPlaybackProvider.notifier).state = _song2Playback
          .copyWith(position: const Duration(seconds: 42));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.skip_previous));
      await tester.pump(const Duration(milliseconds: 48));

      expect(
        find.byKey(
          const ValueKey<String>(
            'track-navigation-feedback-replayCurrent',
          ),
        ),
        findsOneWidget,
      );

      await tester.pumpAndSettle();
      container.read(_testPlaybackProvider.notifier).state = _song2Playback;
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.skip_next).first);
      await tester.pump(const Duration(milliseconds: 48));

      expect(
        find.byKey(
          const ValueKey<String>('track-navigation-feedback-noNext'),
        ),
        findsOneWidget,
      );

      await tester.pumpAndSettle();
      expect(
        find.byKey(
          const ValueKey<String>('track-navigation-feedback-noNext'),
        ),
        findsNothing,
      );
    },
  );
}
