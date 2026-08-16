import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/presentation/now_playing_screen.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:riverpod/src/framework.dart' show Override;

import '../../../../helpers/adaptive_test_harness.dart';
import '../../../../helpers/test_database.dart';

const PlaybackSnapshot _songPlayback = PlaybackSnapshot(
  queueSongIds: <String>['song-1'],
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

class _TestPlaybackNotifier extends Notifier<PlaybackSnapshot> {
  @override
  PlaybackSnapshot build() => const PlaybackSnapshot.idle();
}

final _testPlaybackProvider =
    NotifierProvider<_TestPlaybackNotifier, PlaybackSnapshot>(
      _TestPlaybackNotifier.new,
    );

ProviderContainer _createContainer({List<Override> overrides = const []}) {
  final database = createTestDatabase();
  final container = ProviderContainer(
    overrides: withTestDatabase(
      database,
      overrides: <Override>[
        playerStateProvider.overrideWith(
          (ref) => ref.watch(_testPlaybackProvider),
        ),
        ...overrides,
      ],
    ),
  );
  addTearDown(() async {
    container.dispose();
    await database.close();
  });
  return container;
}

Finder _findNowPlayingHandle() {
  return find.byWidgetPredicate((widget) {
    if (widget is! Container) {
      return false;
    }
    final constraints = widget.constraints;
    if (constraints == null ||
        constraints.minWidth != 36 ||
        constraints.maxWidth != 36 ||
        constraints.minHeight != 4 ||
        constraints.maxHeight != 4) {
      return false;
    }
    final decoration = widget.decoration;
    return decoration is BoxDecoration && decoration.borderRadius != null;
  });
}

Future<void> _pumpNowPlaying(
  WidgetTester tester,
  ProviderContainer container, {
  bool reduceMotion = false,
  bool wideEmbeddedMode = false,
  bool compactWideLandscapeMode = false,
  TextScaler? textScaler,
}) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: ThemeData(platform: TargetPlatform.linux),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data:
              MediaQuery.of(
                context,
              ).copyWith(
                disableAnimations: reduceMotion,
                textScaler: textScaler,
              ),
          child: child!,
        ),
        home: Scaffold(
          body: NowPlayingScreen(
            wideEmbeddedMode: wideEmbeddedMode,
            compactWideLandscapeMode: compactWideLandscapeMode,
            onCollapse: _noopCollapse,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void _noopCollapse() {}

void main() {
  testWidgets(
    'desktop runtime follows width parity for now playing wide mode',
    (tester) async {
      if (!sqliteAvailable) {
        return;
      }
      setAdaptiveTestViewport(tester, const Size(840, 1000));
      final container = _createContainer();
      await _pumpNowPlaying(tester, container);

      expect(_findNowPlayingHandle(), findsOneWidget);
      expect(find.byKey(const Key('nowPlayingCloseButton')), findsOneWidget);
      expect(tester.takeException(), isNull);

      tester.view.physicalSize = const Size(1200, 1000);
      await tester.pumpAndSettle();

      expect(_findNowPlayingHandle(), findsNothing);
      expect(find.byKey(const Key('nowPlayingCloseButton')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('split layout lyrics action opens fullscreen lyrics page', (
    tester,
  ) async {
    if (!sqliteAvailable) {
      return;
    }
    setAdaptiveTestViewport(tester, const Size(1000, 900));
    final container = _createContainer();
    container.read(_testPlaybackProvider.notifier).state = _songPlayback;
    await _pumpNowPlaying(tester, container);

    expect(find.text('Lyrics'), findsNothing);
    await tester.tap(find.byTooltip('Lyrics').first);
    await tester.pumpAndSettle();

    expect(find.text('Lyrics'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'now playing info changes without decorative motion when reduced',
    (
      tester,
    ) async {
      if (!sqliteAvailable) {
        return;
      }
      setAdaptiveTestViewport(tester, const Size(390, 844));
      final container = _createContainer();
      container.read(_testPlaybackProvider.notifier).state = _songPlayback;
      await _pumpNowPlaying(tester, container, reduceMotion: true);

      expect(
        tester
            .widget<AnimatedSwitcher>(
              find.byKey(const ValueKey<String>('nowPlayingInfoSwitcher')),
            )
            .duration,
        Duration.zero,
      );
      expect(
        tester
            .widget<AnimatedContainer>(
              find.byKey(const ValueKey<String>('nowPlayingSurfaceTint')),
            )
            .duration,
        Duration.zero,
      );
      expect(
        tester
            .widget<AnimatedSize>(
              find.byKey(const ValueKey<String>('nowPlayingInfoSize')),
            )
            .duration,
        Duration.zero,
      );
      expect(
        tester
            .widget<AnimatedSwitcher>(
              find.byKey(
                const ValueKey<String>('nowPlayingArtLyricsSwitcher'),
              ),
            )
            .duration,
        Duration.zero,
      );
      expect(
        tester
            .widget<AnimatedSwitcher>(
              find.byKey(
                const ValueKey<String>('nowPlayingTrackInfoSwitcher'),
              ),
            )
            .duration,
        Duration.zero,
      );
      expect(
        find.byKey(const ValueKey<String>('nowPlayingLikeFeedbackScale')),
        findsNothing,
      );
    },
  );

  testWidgets('Now Playing Like feedback retains its normal motion', (
    tester,
  ) async {
    if (!sqliteAvailable) {
      return;
    }
    setAdaptiveTestViewport(tester, const Size(390, 844));
    final container = _createContainer();
    container.read(_testPlaybackProvider.notifier).state = _songPlayback;

    await _pumpNowPlaying(tester, container);

    expect(
      find.byKey(const ValueKey<String>('nowPlayingLikeFeedbackScale')),
      findsOneWidget,
    );
  });

  testWidgets('Now Playing surface tint uses the shared surface timing', (
    tester,
  ) async {
    if (!sqliteAvailable) {
      return;
    }
    setAdaptiveTestViewport(tester, const Size(390, 844));
    final container = _createContainer();
    container.read(_testPlaybackProvider.notifier).state = _songPlayback;
    await _pumpNowPlaying(tester, container);

    expect(
      tester
          .widget<AnimatedContainer>(
            find.byKey(const ValueKey<String>('nowPlayingSurfaceTint')),
          )
          .duration,
      const Duration(milliseconds: 180),
    );
  });

  testWidgets(
    'fullscreen action row hides retired Listen Together control',
    (
      tester,
    ) async {
      if (!sqliteAvailable) {
        return;
      }
      setAdaptiveTestViewport(tester, const Size(390, 844));
      final container = _createContainer();
      container.read(_testPlaybackProvider.notifier).state = _songPlayback;
      await _pumpNowPlaying(tester, container);

      expect(find.byTooltip('Queue'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('groupListeningSessionButton')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('phone now playing remains usable at 200 percent text scale', (
    tester,
  ) async {
    if (!sqliteAvailable) {
      return;
    }
    setAdaptiveTestViewport(tester, const Size(390, 844));
    final container = _createContainer();
    container.read(_testPlaybackProvider.notifier).state = _songPlayback;

    await _pumpNowPlaying(
      tester,
      container,
      textScaler: const TextScaler.linear(2),
    );

    expect(find.byKey(const Key('nowPlayingCloseButton')), findsOneWidget);
    expect(find.byTooltip('Queue'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(NowPlayingScreen),
      matchesGoldenFile('goldens/now_playing_text_scale_200.png'),
    );
  });

  testWidgets(
    'compact-wide player hides retired Listen Together settings entry',
    (tester) async {
      if (!sqliteAvailable) {
        return;
      }
      setAdaptiveTestViewport(tester, const Size(560, 360));
      final container = _createContainer();
      container.read(_testPlaybackProvider.notifier).state = _songPlayback;

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: ThemeData(platform: TargetPlatform.linux),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(
              body: NowPlayingScreen(
                wideEmbeddedMode: true,
                compactWideLandscapeMode: true,
                onCollapse: _noopCollapse,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('groupListeningSessionButton')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);

      await tester.tap(find.byTooltip('Settings').first);
      await tester.pumpAndSettle();

      expect(find.text('Listen Together'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'compact-wide panels skip travel and fade when reduced motion is enabled',
    (tester) async {
      if (!sqliteAvailable) {
        return;
      }
      setAdaptiveTestViewport(tester, const Size(560, 360));
      final container = _createContainer();
      container.read(_testPlaybackProvider.notifier).state = _songPlayback;

      await _pumpNowPlaying(
        tester,
        container,
        reduceMotion: true,
        wideEmbeddedMode: true,
        compactWideLandscapeMode: true,
      );

      await tester.tap(find.byTooltip('Settings').first);
      await tester.pump();

      final panel = find.byKey(
        const ValueKey<String>('compact-wide-now-playing-panel'),
      );
      expect(panel, findsOneWidget);
      expect(
        find.ancestor(of: panel, matching: find.byType(Opacity)),
        findsNothing,
      );
      expect(
        find.ancestor(
          of: panel,
          matching: find.byType(FractionalTranslation),
        ),
        findsNothing,
      );

      await tester.tap(find.byTooltip('Back').first);
      await tester.pump();
      await tester.pump();

      expect(panel, findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('compact-wide panels retain travel with normal motion', (
    tester,
  ) async {
    if (!sqliteAvailable) {
      return;
    }
    setAdaptiveTestViewport(tester, const Size(560, 360));
    final container = _createContainer();
    container.read(_testPlaybackProvider.notifier).state = _songPlayback;

    await _pumpNowPlaying(
      tester,
      container,
      wideEmbeddedMode: true,
      compactWideLandscapeMode: true,
    );

    await tester.tap(find.byTooltip('Settings').first);
    await tester.pump();

    final panel = find.byKey(
      const ValueKey<String>('compact-wide-now-playing-panel'),
    );
    final translation = find.ancestor(
      of: panel,
      matching: find.byType(FractionalTranslation),
    );
    expect(translation, findsOneWidget);
    expect(
      tester.widget<FractionalTranslation>(translation).translation.dy,
      greaterThan(0),
    );
    expect(tester.takeException(), isNull);
  });
}
