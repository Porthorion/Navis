import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/equalizer/domain/eq_configuration.dart';
import 'package:navis/src/features/equalizer/presentation/eq_controller.dart';
import 'package:navis/src/features/equalizer/presentation/eq_quick_panel.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/presentation/now_playing_screen.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:riverpod/src/framework.dart' show Override;

import '../../../../helpers/adaptive_test_harness.dart';
import '../../../../helpers/fake_eq_controller.dart';
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

double _contrastRatio(Color a, Color b) {
  final first = a.computeLuminance();
  final second = b.computeLuminance();
  final lighter = first > second ? first : second;
  final darker = first > second ? second : first;
  return (lighter + 0.05) / (darker + 0.05);
}

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
  Brightness brightness = Brightness.light,
  TargetPlatform platform = TargetPlatform.linux,
  bool settle = true,
}) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: ThemeData(
          platform: platform,
          brightness: brightness,
        ),
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
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
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

  testWidgets(
    'full player marks transcoded output with an accessible transform icon',
    (tester) async {
      if (!sqliteAvailable) {
        return;
      }
      setAdaptiveTestViewport(tester, const Size(390, 844));
      final container = _createContainer(
        overrides: <Override>[
          currentMediaItemProvider.overrideWithValue(
            const AsyncData(
              MediaItem(
                id: 'song-1',
                title: 'Track',
                extras: <String, dynamic>{
                  'resolvedFormat': 'opus',
                  'resolvedBitRate': 320,
                  'transcodingApplied': true,
                },
              ),
            ),
          ),
        ],
      );
      container.read(_testPlaybackProvider.notifier).state = _songPlayback;

      await _pumpNowPlaying(tester, container);

      expect(find.byIcon(Icons.transform), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Semantics &&
              widget.properties.label == 'Transcoded playback',
        ),
        findsOneWidget,
      );
      expect(find.text('OPUS • 320 Kb/s'), findsOneWidget);
      expect(find.text('Transcoded'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('full player keeps original playback quality unmarked', (
    tester,
  ) async {
    if (!sqliteAvailable) {
      return;
    }
    setAdaptiveTestViewport(tester, const Size(390, 844));
    final container = _createContainer(
      overrides: <Override>[
        currentMediaItemProvider.overrideWithValue(
          const AsyncData(
            MediaItem(
              id: 'song-1',
              title: 'Track',
              extras: <String, dynamic>{
                'resolvedFormat': 'flac',
                'resolvedBitRate': 900,
                'transcodingApplied': false,
              },
            ),
          ),
        ),
      ],
    );
    container.read(_testPlaybackProvider.notifier).state = _songPlayback;

    await _pumpNowPlaying(tester, container);

    expect(find.byIcon(Icons.transform), findsNothing);
    expect(find.text('FLAC • 900 Kb/s'), findsOneWidget);
    expect(find.bySemanticsLabel('Transcoded playback'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('full player retains the icon for bitrate-only transcoding', (
    tester,
  ) async {
    if (!sqliteAvailable) {
      return;
    }
    setAdaptiveTestViewport(tester, const Size(390, 844));
    final container = _createContainer(
      overrides: <Override>[
        currentMediaItemProvider.overrideWithValue(
          const AsyncData(
            MediaItem(
              id: 'song-1',
              title: 'Track',
              extras: <String, dynamic>{
                'resolvedFormat': 'transcoded',
                'resolvedBitRate': 192,
                'transcodingApplied': true,
              },
            ),
          ),
        ),
      ],
    );
    container.read(_testPlaybackProvider.notifier).state = _songPlayback;

    await _pumpNowPlaying(tester, container);

    expect(find.byIcon(Icons.transform), findsOneWidget);
    expect(find.text('192 Kb/s'), findsOneWidget);
    expect(find.text('Transcoded'), findsNothing);
    expect(tester.takeException(), isNull);
  });

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
      expect(find.byTooltip('Pause'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('groupListeningSessionButton')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('fullscreen remote loading stays visible against play button', (
    tester,
  ) async {
    if (!sqliteAvailable) {
      return;
    }
    setAdaptiveTestViewport(tester, const Size(390, 844));
    final container = _createContainer(
      overrides: <Override>[
        songByIdProvider.overrideWith(
          (ref, id) => Stream<SongsTableData?>.value(
            const SongsTableData(
              id: 'song-1',
              title: 'Remote fixture',
              isProvisional: false,
              isExternal: true,
            ),
          ),
        ),
      ],
    );
    container.read(_testPlaybackProvider.notifier).state = _songPlayback
        .copyWith(
          isLoading: true,
          loadingSongId: 'song-1',
          processingState: AudioProcessingState.loading,
        );

    final indicatorFinder = find.byKey(
      const ValueKey<String>('remote-playback-loading-indicator'),
    );
    for (final brightness in <Brightness>[
      Brightness.light,
      Brightness.dark,
    ]) {
      await _pumpNowPlaying(
        tester,
        container,
        brightness: brightness,
        platform: TargetPlatform.android,
        settle: false,
      );
      await tester.pump();
      expect(indicatorFinder, findsOneWidget);
      final indicator = tester.widget<CircularProgressIndicator>(
        indicatorFinder,
      );
      expect(
        find.ancestor(
          of: indicatorFinder,
          matching: find.byType(FilledButton),
        ),
        findsOneWidget,
      );
      final colors = Theme.of(tester.element(indicatorFinder)).colorScheme;
      expect(
        indicator.color,
        colors.onPrimary,
      );
      expect(
        _contrastRatio(indicator.color!, colors.primary),
        greaterThanOrEqualTo(3),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(indicatorFinder, findsOneWidget);
    }

    container.read(_testPlaybackProvider.notifier).state = _songPlayback;
    await tester.pump();
    expect(indicatorFinder, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('landscape remote loading stays inside the play button', (
    tester,
  ) async {
    if (!sqliteAvailable) {
      return;
    }
    setAdaptiveTestViewport(tester, const Size(844, 390));
    final container = _createContainer(
      overrides: <Override>[
        songByIdProvider.overrideWith(
          (ref, id) => Stream<SongsTableData?>.value(
            const SongsTableData(
              id: 'song-1',
              title: 'Remote fixture',
              isProvisional: false,
              isExternal: true,
            ),
          ),
        ),
      ],
    );
    container.read(_testPlaybackProvider.notifier).state = _songPlayback
        .copyWith(
          isLoading: true,
          loadingSongId: 'song-1',
          processingState: AudioProcessingState.loading,
        );
    await _pumpNowPlaying(
      tester,
      container,
      wideEmbeddedMode: true,
      compactWideLandscapeMode: true,
      platform: TargetPlatform.android,
      settle: false,
    );
    await tester.pump();

    final indicatorFinder = find.byKey(
      const ValueKey<String>('remote-playback-loading-indicator'),
    );
    expect(indicatorFinder, findsOneWidget);
    expect(
      find.ancestor(of: indicatorFinder, matching: find.byType(FilledButton)),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

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

  group('mobile settings sheet Sound section', () {
    Future<ProviderContainer> openSheet(
      WidgetTester tester, {
      required bool eqSupported,
    }) async {
      setAdaptiveTestViewport(tester, const Size(390, 844));
      final container = _createContainer(
        overrides: [
          eqCapabilitiesProvider.overrideWithValue(
            eqSupported ? EqCapabilities.available : EqCapabilities.unavailable,
          ),
          if (eqSupported)
            equalizerProvider.overrideWith(
              () => FakeEqController(
                initial: EqState(
                  configuration: EqConfiguration.flat().copyWith(
                    enabled: true,
                  ),
                  presets: const [],
                  selectedPresetId: 'builtin:bass',
                ),
              ),
            ),
        ],
      );
      container.read(_testPlaybackProvider.notifier).state = _songPlayback;
      await _pumpNowPlaying(
        tester,
        container,
        platform: TargetPlatform.android,
      );
      await tester.tap(find.byKey(const ValueKey('nowPlayingSettingsAction')));
      await tester.pumpAndSettle();
      return container;
    }

    testWidgets('shows the inline mini equalizer under Sound', (tester) async {
      if (!sqliteAvailable) {
        return;
      }
      await openSheet(tester, eqSupported: true);
      expect(
        find.byKey(const ValueKey('nowPlayingSettingsSheet')),
        findsOneWidget,
      );
      expect(find.text('Sound'), findsOneWidget);
      expect(find.byType(EqQuickCard), findsOneWidget);
      expect(find.byKey(const ValueKey('eq-quick-preset')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(BottomSheet),
        matchesGoldenFile('goldens/now_playing_settings_sound_390x844.png'),
      );
    });

    testWidgets('Speed & Pitch opens after the settings sheet closes', (
      tester,
    ) async {
      if (!sqliteAvailable) {
        return;
      }
      await openSheet(tester, eqSupported: true);
      await tester.tap(
        find.byKey(const ValueKey('playbackAdjustmentEntryPoint')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('nowPlayingSettingsSheet')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('playbackAdjustmentQuickPanel')),
        findsOneWidget,
      );
    });

    testWidgets('unsupported backends keep the explanatory Equalizer row', (
      tester,
    ) async {
      if (!sqliteAvailable) {
        return;
      }
      await openSheet(tester, eqSupported: false);
      expect(find.byType(EqQuickCard), findsNothing);
      expect(find.byKey(const ValueKey('equalizerEntryPoint')), findsOneWidget);
    });
  });

  for (final eqSupported in [true, false]) {
    for (final width in [320.0, 360.0, 412.0]) {
      testWidgets(
        'transport keeps Play centred at $width px (EQ supported: $eqSupported)',
        (tester) async {
          if (!sqliteAvailable) {
            return;
          }
          setAdaptiveTestViewport(tester, Size(width, 860));
          final container = _createContainer(
            overrides: [
              eqCapabilitiesProvider.overrideWithValue(
                eqSupported
                    ? EqCapabilities.available
                    : EqCapabilities.unavailable,
              ),
              if (eqSupported)
                equalizerProvider.overrideWith(FakeEqController.new),
            ],
          );
          container.read(_testPlaybackProvider.notifier).state = _songPlayback;
          await _pumpNowPlaying(
            tester,
            container,
            platform: TargetPlatform.android,
          );
          final play = find.descendant(
            of: find.byTooltip('Pause'),
            matching: find.byType(FilledButton),
          );
          final eq = find.byKey(const ValueKey('nowPlayingEqualizerButton'));
          final speed = find.byKey(const ValueKey('nowPlayingSpeedButton'));
          expect(tester.getCenter(play).dx, closeTo(width / 2, 0.5));
          expect(tester.takeException(), isNull);
          if (width < 360) {
            // Very small screens keep the core transport only; Speed and EQ
            // stay reachable from the settings sheet.
            expect(eq, findsNothing);
            expect(speed, findsNothing);
            return;
          }
          // The flanking quick actions are mirror images of each other.
          expect(
            tester.getSize(eq).width,
            closeTo(tester.getSize(speed).width, 0.01),
          );
          expect(
            tester.getCenter(play).dx - tester.getCenter(eq).dx,
            closeTo(
              tester.getCenter(speed).dx - tester.getCenter(play).dx,
              0.5,
            ),
          );
          expect(
            find.byKey(const ValueKey('equalizerQuickPlaceholder')),
            eqSupported ? findsNothing : findsOneWidget,
          );
        },
      );
    }
  }
}
