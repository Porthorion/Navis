import 'package:audio_service/audio_service.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/equalizer/domain/eq_configuration.dart';
import 'package:navis/src/features/equalizer/presentation/eq_controller.dart';
import 'package:navis/src/features/equalizer/presentation/eq_quick_panel.dart';
import 'package:navis/src/api/models/models.dart' show LyricsList;
import 'package:navis/src/features/player/domain/lyrics_resolution.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/presentation/instant_mix_notifier.dart';
import 'package:navis/src/features/player/presentation/now_playing_screen.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/theme/artwork_shape.dart';
import 'package:navis/src/theme/navis_theme.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

import '../../../../helpers/adaptive_test_harness.dart';
import '../../../../helpers/fake_eq_controller.dart';
import '../../../../helpers/library_copy_api.dart';
import '../../../../helpers/now_playing_harness.dart';
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

class _SpyInstantMixNotifier extends InstantMixNotifier {
  final activations = <String>[];

  @override
  Future<void> activate(String seedSongId) async {
    activations.add(seedSongId);
  }
}

double _contrastRatio(Color a, Color b) {
  final first = a.computeLuminance();
  final second = b.computeLuminance();
  final lighter = first > second ? first : second;
  final darker = first > second ? second : first;
  return (lighter + 0.05) / (darker + 0.05);
}

ProviderContainer _createContainer({List<Override> overrides = const []}) =>
    createNowPlayingContainer(overrides: overrides);

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
  ThemeData? theme,
  bool settle = true,
  AppNoticeController? notices,
}) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme:
            theme?.copyWith(platform: platform) ??
            ThemeData(platform: platform, brightness: brightness),
        localizationsDelegates: navisLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(disableAnimations: reduceMotion, textScaler: textScaler),
          child: notices == null
              ? child!
              : AppNoticeScope(notifier: notices, child: child!),
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
  testWidgets('Server Mix starts from a remote song with a library copy', (
    tester,
  ) async {
    setAdaptiveTestViewport(tester, const Size(390, 844));
    final spy = _SpyInstantMixNotifier();
    final container = _createContainer(
      overrides: <Override>[
        preferredMixModeProvider.overrideWithValue(
          PreferredMixMode.legacyInstantMix,
        ),
        instantMixProvider.overrideWith(() => spy),
        subsonicApiProvider.overrideWithValue(
          LibraryCopyApiClient(const {'ext-remote-1': 'copy-1'}),
        ),
      ],
    );
    container
        .read(nowPlayingTestPlaybackProvider.notifier)
        .state = _songPlayback.copyWith(
      queueSongIds: const <String>['ext-remote-1'],
      currentSongId: 'ext-remote-1',
    );
    await _pumpNowPlaying(tester, container);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('nowPlayingMixButton')));
    await tester.pump();

    expect(spy.activations, <String>['ext-remote-1']);
    expect(
      find.text('Instant Mix requires a locally scanned track.'),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  }, skip: !sqliteAvailable);

  testWidgets('Server Mix stays unavailable for a remote song without a '
      'library copy', (tester) async {
    setAdaptiveTestViewport(tester, const Size(390, 844));
    final spy = _SpyInstantMixNotifier();
    final container = _createContainer(
      overrides: <Override>[
        preferredMixModeProvider.overrideWithValue(
          PreferredMixMode.legacyInstantMix,
        ),
        instantMixProvider.overrideWith(() => spy),
        subsonicApiProvider.overrideWithValue(LibraryCopyApiClient(const {})),
      ],
    );
    container
        .read(nowPlayingTestPlaybackProvider.notifier)
        .state = _songPlayback.copyWith(
      queueSongIds: const <String>['ext-remote-1'],
      currentSongId: 'ext-remote-1',
    );
    final notices = AppNoticeController();
    addTearDown(notices.dispose);
    await _pumpNowPlaying(tester, container, notices: notices);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('nowPlayingMixButton')));
    await tester.pump();

    expect(spy.activations, isEmpty);
    expect(
      notices.notice?.message,
      'Instant Mix requires a locally scanned track.',
    );
    expect(tester.takeException(), isNull);
  }, skip: !sqliteAvailable);

  testWidgets(
    'desktop runtime follows width parity for now playing wide mode',
    (tester) async {
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
    skip: !sqliteAvailable,
  );

  testWidgets('the cover follows Now Playing Art Shape', (tester) async {
    setAdaptiveTestViewport(tester, const Size(390, 844));
    final container = _createContainer();
    container.read(nowPlayingTestPlaybackProvider.notifier).state =
        _songPlayback;
    await container
        .read(navisDatabaseProvider)
        .appSettingsDao
        .updateNowPlayingArtShape('circle');
    await _pumpNowPlaying(tester, container);

    final cover = find.byWidgetPredicate(
      (widget) =>
          widget is CoverArtImage &&
          widget.shape == ArtworkShapeRole.nowPlaying,
    );
    expect(cover, findsOneWidget);
    // Without a server the cover shows its placeholder tile, which carries
    // the cover's shape (1.4.0 drew song covers square whatever the setting).
    final tile = tester.widget<Container>(
      find.descendant(of: cover, matching: find.byType(Container)).first,
    );
    expect((tile.decoration! as BoxDecoration).shape, BoxShape.circle);
    expect(tester.takeException(), isNull);
  }, skip: !sqliteAvailable);

  testWidgets('split layout lyrics action opens fullscreen lyrics page', (
    tester,
  ) async {
    setAdaptiveTestViewport(tester, const Size(1000, 900));
    final container = _createContainer();
    container.read(nowPlayingTestPlaybackProvider.notifier).state =
        _songPlayback;
    await _pumpNowPlaying(tester, container);

    expect(find.text('Lyrics'), findsNothing);
    await tester.tap(find.byTooltip('Lyrics').first);
    await tester.pumpAndSettle();

    expect(find.text('Lyrics'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, skip: !sqliteAvailable);

  testWidgets('fullscreen lyrics follow the song that is playing', (
    tester,
  ) async {
    setAdaptiveTestViewport(tester, const Size(1000, 900));
    final container = _createContainer(
      overrides: <Override>[
        lyricsProvider.overrideWith(
          (ref, songId) async => LyricsResolution(
            lyrics: LyricsList(value: 'Words of $songId'),
            source: LyricsSource.serverPlain,
          ),
        ),
      ],
    );
    container.read(nowPlayingTestPlaybackProvider.notifier).state =
        _songPlayback;
    await _pumpNowPlaying(tester, container);
    await tester.tap(find.byTooltip('Lyrics').first);
    await tester.pumpAndSettle();
    expect(find.text('Words of song-1'), findsOneWidget);

    container
        .read(nowPlayingTestPlaybackProvider.notifier)
        .state = _songPlayback.copyWith(
      queueSongIds: const <String>['song-1', 'song-2'],
      currentSongId: 'song-2',
      currentIndex: 1,
    );
    await tester.pumpAndSettle();

    expect(find.text('Words of song-2'), findsOneWidget);
    expect(find.text('Words of song-1'), findsNothing);
    expect(tester.takeException(), isNull);
  }, skip: !sqliteAvailable);

  testWidgets(
    'now playing info changes without decorative motion when reduced',
    (tester) async {
      setAdaptiveTestViewport(tester, const Size(390, 844));
      final container = _createContainer();
      container.read(nowPlayingTestPlaybackProvider.notifier).state =
          _songPlayback;
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
              find.byKey(const ValueKey<String>('nowPlayingArtLyricsSwitcher')),
            )
            .duration,
        Duration.zero,
      );
      expect(
        tester
            .widget<AnimatedSwitcher>(
              find.byKey(const ValueKey<String>('nowPlayingTrackInfoSwitcher')),
            )
            .duration,
        Duration.zero,
      );
      expect(
        find.byKey(const ValueKey<String>('nowPlayingLikeFeedbackScale')),
        findsNothing,
      );
    },
    skip: !sqliteAvailable,
  );

  testWidgets(
    'full player marks transcoded output with an accessible transform icon',
    (tester) async {
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
      container.read(nowPlayingTestPlaybackProvider.notifier).state =
          _songPlayback;

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
    skip: !sqliteAvailable,
  );

  testWidgets('full player keeps original playback quality unmarked', (
    tester,
  ) async {
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
    container.read(nowPlayingTestPlaybackProvider.notifier).state =
        _songPlayback;

    await _pumpNowPlaying(tester, container);

    expect(find.byIcon(Icons.transform), findsNothing);
    expect(find.text('FLAC • 900 Kb/s'), findsOneWidget);
    expect(find.bySemanticsLabel('Transcoded playback'), findsNothing);
    expect(tester.takeException(), isNull);
  }, skip: !sqliteAvailable);

  testWidgets('full player retains the icon for bitrate-only transcoding', (
    tester,
  ) async {
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
    container.read(nowPlayingTestPlaybackProvider.notifier).state =
        _songPlayback;

    await _pumpNowPlaying(tester, container);

    expect(find.byIcon(Icons.transform), findsOneWidget);
    expect(find.text('192 Kb/s'), findsOneWidget);
    expect(find.text('Transcoded'), findsNothing);
    expect(tester.takeException(), isNull);
  }, skip: !sqliteAvailable);

  testWidgets('Now Playing Like feedback retains its normal motion', (
    tester,
  ) async {
    setAdaptiveTestViewport(tester, const Size(390, 844));
    final container = _createContainer();
    container.read(nowPlayingTestPlaybackProvider.notifier).state =
        _songPlayback;

    await _pumpNowPlaying(tester, container);

    expect(
      find.byKey(const ValueKey<String>('nowPlayingLikeFeedbackScale')),
      findsOneWidget,
    );
  }, skip: !sqliteAvailable);

  testWidgets('Now Playing surface tint uses the shared surface timing', (
    tester,
  ) async {
    setAdaptiveTestViewport(tester, const Size(390, 844));
    final container = _createContainer();
    container.read(nowPlayingTestPlaybackProvider.notifier).state =
        _songPlayback;
    await _pumpNowPlaying(tester, container);

    expect(
      tester
          .widget<AnimatedContainer>(
            find.byKey(const ValueKey<String>('nowPlayingSurfaceTint')),
          )
          .duration,
      const Duration(milliseconds: 180),
    );
  }, skip: !sqliteAvailable);

  testWidgets('fullscreen action row hides retired Listen Together control', (
    tester,
  ) async {
    setAdaptiveTestViewport(tester, const Size(390, 844));
    final container = _createContainer();
    container.read(nowPlayingTestPlaybackProvider.notifier).state =
        _songPlayback;
    await _pumpNowPlaying(tester, container);

    expect(find.byTooltip('Queue'), findsOneWidget);
    expect(find.byTooltip('Pause'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('groupListeningSessionButton')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  }, skip: !sqliteAvailable);

  testWidgets('fullscreen remote loading stays visible against play button', (
    tester,
  ) async {
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
    container
        .read(nowPlayingTestPlaybackProvider.notifier)
        .state = _songPlayback.copyWith(
      isLoading: true,
      loadingSongId: 'song-1',
      processingState: AudioProcessingState.loading,
    );

    final indicatorFinder = find.byKey(
      const ValueKey<String>('remote-playback-loading-indicator'),
    );
    for (final brightness in <Brightness>[Brightness.light, Brightness.dark]) {
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
        find.ancestor(of: indicatorFinder, matching: find.byType(FilledButton)),
        findsOneWidget,
      );
      final colors = Theme.of(tester.element(indicatorFinder)).colorScheme;
      expect(indicator.color, colors.onPrimary);
      expect(
        _contrastRatio(indicator.color!, colors.primary),
        greaterThanOrEqualTo(3),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(indicatorFinder, findsOneWidget);
    }

    container.read(nowPlayingTestPlaybackProvider.notifier).state =
        _songPlayback;
    await tester.pump();
    expect(indicatorFinder, findsNothing);
    expect(tester.takeException(), isNull);
  }, skip: !sqliteAvailable);

  testWidgets('landscape remote loading stays inside the play button', (
    tester,
  ) async {
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
    container
        .read(nowPlayingTestPlaybackProvider.notifier)
        .state = _songPlayback.copyWith(
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
  }, skip: !sqliteAvailable);

  testWidgets('phone now playing remains usable at 200 percent text scale', (
    tester,
  ) async {
    setAdaptiveTestViewport(tester, const Size(390, 844));
    final container = _createContainer();
    container.read(nowPlayingTestPlaybackProvider.notifier).state =
        _songPlayback;

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
  }, skip: !sqliteAvailable);

  testWidgets(
    'compact-wide player hides retired Listen Together settings entry',
    (tester) async {
      setAdaptiveTestViewport(tester, const Size(560, 360));
      final container = _createContainer();
      container.read(nowPlayingTestPlaybackProvider.notifier).state =
          _songPlayback;

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: ThemeData(platform: TargetPlatform.linux),
            localizationsDelegates: navisLocalizationsDelegates,
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
    skip: !sqliteAvailable,
  );

  testWidgets(
    'compact-wide panels skip travel and fade when reduced motion is enabled',
    (tester) async {
      setAdaptiveTestViewport(tester, const Size(560, 360));
      final container = _createContainer();
      container.read(nowPlayingTestPlaybackProvider.notifier).state =
          _songPlayback;

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
        find.ancestor(of: panel, matching: find.byType(FractionalTranslation)),
        findsNothing,
      );

      await tester.tap(find.byTooltip('Back').first);
      await tester.pump();
      await tester.pump();

      expect(panel, findsNothing);
      expect(tester.takeException(), isNull);
    },
    skip: !sqliteAvailable,
  );

  testWidgets('compact-wide panels retain travel with normal motion', (
    tester,
  ) async {
    setAdaptiveTestViewport(tester, const Size(560, 360));
    final container = _createContainer();
    container.read(nowPlayingTestPlaybackProvider.notifier).state =
        _songPlayback;

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
  }, skip: !sqliteAvailable);

  group('mobile settings sheet Sound section', () {
    Future<ProviderContainer> openSheet(
      WidgetTester tester, {
      required bool eqSupported,
      ThemeData? theme,
      TextScaler? textScaler,
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
                  configuration: EqConfiguration.flat().copyWith(enabled: true),
                  presets: const [],
                  selectedPresetId: 'builtin:bass',
                ),
              ),
            ),
        ],
      );
      container.read(nowPlayingTestPlaybackProvider.notifier).state =
          _songPlayback;
      await _pumpNowPlaying(
        tester,
        container,
        platform: TargetPlatform.android,
        theme: theme,
        textScaler: textScaler,
      );
      await tester.tap(find.byKey(const ValueKey('nowPlayingSettingsAction')));
      await tester.pumpAndSettle();
      return container;
    }

    testWidgets('shows the inline mini equalizer under Sound', (tester) async {
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
    }, skip: !sqliteAvailable);

    for (final scale in <double>[1, 1.3, 2]) {
      testWidgets('the volume level stays on one line at ${scale}x text', (
        tester,
      ) async {
        // The bundled Inter font with tabular figures made "100%" wider than
        // its old fixed 40 px slot from about 1.13x text scale (1.4.0).
        final inter = FontLoader(navisFontFamily)
          ..addFont(rootBundle.load('assets/fonts/InterVariable.ttf'));
        await inter.load();
        await openSheet(
          tester,
          eqSupported: false,
          theme: buildLightTheme(Colors.indigo),
          textScaler: TextScaler.linear(scale),
        );

        final paragraph = tester.renderObject<RenderParagraph>(
          find.text('100%'),
        );
        final oneLine = TextPainter(
          text: paragraph.text,
          textDirection: TextDirection.ltr,
          textScaler: paragraph.textScaler,
        )..layout();
        expect(paragraph.size.height, closeTo(oneLine.height, 0.5));
        oneLine.dispose();
        expect(tester.takeException(), isNull);
      }, skip: !sqliteAvailable);
    }

    testWidgets('Speed & Pitch opens after the settings sheet closes', (
      tester,
    ) async {
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
    }, skip: !sqliteAvailable);

    testWidgets('unsupported backends keep the explanatory Equalizer row', (
      tester,
    ) async {
      await openSheet(tester, eqSupported: false);
      expect(find.byType(EqQuickCard), findsNothing);
      expect(find.byKey(const ValueKey('equalizerEntryPoint')), findsOneWidget);
    }, skip: !sqliteAvailable);
  });

  for (final eqSupported in [true, false]) {
    for (final width in [320.0, 360.0, 412.0]) {
      testWidgets(
        'transport keeps Play centred at $width px (EQ supported: $eqSupported)',
        (tester) async {
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
          container.read(nowPlayingTestPlaybackProvider.notifier).state =
              _songPlayback;
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
        skip: !sqliteAvailable,
      );
    }
  }
}
