// The Now Playing info chips respond to holds anywhere on the chip, and
// holding ReplayGain lands on its section of Playback settings.
//
// They mount the real NowPlayingScreen inside the real ExpandablePlayerSheet
// (expanded, as on an Android phone) with Android's touch slop, and drive the
// info line the way a thumb does: anywhere on the visible chip, with a few
// pixels of drift.
import 'dart:ui' as ui;

import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/common_widgets/expandable_player_sheet.dart';
import 'package:navis/src/common_widgets/song_download_status_icon.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/presentation/media_info.dart';
import 'package:navis/src/features/player/presentation/now_playing_screen.dart';
import 'package:navis/src/features/player/presentation/player_sheet_provider.dart';
import 'package:navis/src/features/player/presentation/replay_gain_untagged_provider.dart';
import 'package:navis/src/features/settings/presentation/playback_settings_screen.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/app_routes.dart';

import 'package:navis/src/common_widgets/navis_haptics.dart';
import 'package:navis/src/features/settings/domain/haptics_prefs.dart';

import '../../../../helpers/adaptive_test_harness.dart';
import '../../../../helpers/haptics_spy.dart';
import '../../../../helpers/now_playing_harness.dart';
import '../../../../helpers/test_database.dart';

const _playback = PlaybackSnapshot(
  queueSongIds: <String>['s1'],
  currentSongId: 's1',
  currentIndex: 0,
  playing: true,
  processingState: AudioProcessingState.ready,
  position: Duration(seconds: 42),
  duration: Duration(minutes: 3),
  bufferedPosition: Duration(minutes: 1),
  shuffleMode: AudioServiceShuffleMode.none,
  repeatMode: AudioServiceRepeatMode.none,
);

const _song = SongsTableData(
  id: 's1',
  title: 'Aurora',
  artistName: 'Some Artist',
  albumName: 'Some Album',
  suffix: 'flac',
  bitRate: 900,
  size: 30 * 1024 * 1024,
  duration: 180,
  isProvisional: false,
  isExternal: false,
);

const _decision = ReplayGainDecision(
  mode: 'smart',
  resolvedMode: 'album',
  cutDb: -6.2,
  source: ReplayGainSource.album,
);

const _quality = 'FLAC • 900 Kb/s';
const _settingsStub = 'Playback settings page';

/// Android reports ViewConfiguration.getScaledTouchSlop() (8 dp) as the
/// physical touch slop; Flutter's drag recognizers use it, while tap and long
/// press keep their fixed 18 px tolerance.
const double _androidTouchSlop = 8;

final _switcher = find.byKey(const ValueKey('nowPlayingInfoSwitcher'));
final _infoText = find
    .descendant(of: _switcher, matching: find.byType(Text))
    .first;
final _infoIcon = find
    .descendant(of: _switcher, matching: find.byType(Icon))
    .first;

void main() {
  late ProviderContainer container;
  late GoRouter router;

  Future<void> pumpSheet(
    WidgetTester tester, {
    bool realPlaybackSettings = false,
    bool withSheet = true,
    bool wideEmbeddedMode = false,
    bool compactWide = false,
    Size size = const Size(390, 844),
    VoidCallback? onCollapse,
  }) async {
    setAdaptiveTestViewport(tester, size);
    tester.view.gestureSettings = const ui.GestureSettings(
      physicalTouchSlop: _androidTouchSlop,
    );
    addTearDown(tester.view.resetGestureSettings);
    container = createNowPlayingContainer(
      overrides: <Override>[
        songByIdProvider.overrideWith((ref, id) => Stream.value(_song)),
        songServerDetailsProvider.overrideWith((ref, id) async => null),
        songDownloadStateProvider.overrideWith(
          (ref, id) => SongDownloadState.none,
        ),
        serverUserIsAdminProvider.overrideWith((ref) async => false),
        nowPlayingReplayGainProvider.overrideWith((ref) => _decision),
        replayGainLibraryGainsProvider.overrideWith(
          (ref) async => (count: 0, median: null, total: 0, withData: 0),
        ),
      ],
    );
    container.read(nowPlayingTestPlaybackProvider.notifier).state = _playback;
    router = GoRouter(
      routes: <RouteBase>[
        GoRoute(
          path: AppRoutes.home,
          builder: (context, state) => Scaffold(
            body: withSheet
                ? ExpandablePlayerSheet(
                    isExpanded: true,
                    onExpand: () {},
                    onCollapse: onCollapse ?? () {},
                    miniPlayer: const SizedBox(height: 64),
                    fullPlayer: NowPlayingScreen(onCollapse: () {}),
                  )
                : NowPlayingScreen(
                    onCollapse: () {},
                    wideEmbeddedMode: wideEmbeddedMode,
                    compactWideLandscapeMode: compactWide,
                  ),
          ),
        ),
        GoRoute(
          path: SettingsPage.playback.location,
          builder: (context, state) => realPlaybackSettings
              ? PlaybackSettingsScreen(
                  focusReplayGain:
                      state.uri.queryParameters[AppRoutes.playbackFocusParam] ==
                      AppRoutes.playbackFocusReplayGain,
                )
              : const Scaffold(body: Text(_settingsStub)),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          theme: ThemeData(platform: TargetPlatform.android),
          localizationsDelegates: navisLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Cycles to the ReplayGain page (right after Quality).
  Future<void> showReplayGainPage(WidgetTester tester) async {
    await tester.tap(_infoText);
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(_infoText).data, contains(' dB '));
  }

  /// A thumb hold: down at [at], drifts [drift] over the first 150 ms, stays
  /// for [hold] in total, then lifts.
  Future<void> hold(
    WidgetTester tester,
    Offset at, {
    Offset drift = Offset.zero,
    Duration hold = const Duration(milliseconds: 700),
  }) async {
    final gesture = await tester.startGesture(at);
    if (drift != Offset.zero) {
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 30));
        await gesture.moveBy(drift / 5);
      }
      await tester.pump(hold - const Duration(milliseconds: 150));
    } else {
      await tester.pump(hold);
    }
    await gesture.up();
    await tester.pumpAndSettle();
  }

  /// Cycles to the page whose icon is [icon].
  Future<void> showPageWithIcon(WidgetTester tester, IconData icon) async {
    for (var i = 0; i < 8; i++) {
      if (tester.widget<Icon>(_infoIcon).icon == icon) return;
      await tester.tap(_infoText);
      await tester.pumpAndSettle();
    }
    fail('no page with icon $icon');
  }

  bool queueOpen() => container
      .read(playerOverlayStackProvider)
      .contains(PlayerOverlayRoute.queue);
  bool speedPanelOpen() => find
      .byKey(const ValueKey('playbackAdjustmentQuickPanel'))
      .evaluate()
      .isNotEmpty;
  bool settingsOpen() => find.text(_settingsStub).evaluate().isNotEmpty;
  bool mediaInfoOpen() =>
      find.byKey(const ValueKey('mediaInfoSheet')).evaluate().isNotEmpty;

  group('holding anywhere on the chip', () {
    for (final scale in <double>[1.0, 1.3]) {
      testWidgets('holding the Rating chip at 320x568 (text x$scale) opens '
          'the inline editor without overflow or a taller chip', (
        tester,
      ) async {
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await pumpSheet(tester, size: const Size(320, 568));
        await showPageWithIcon(tester, Icons.star_border);
        final before = tester.getSize(_switcher).height;
        await tester.longPress(_infoText);
        await tester.pumpAndSettle();
        expect(find.bySemanticsLabel('Rate 5 stars'), findsOneWidget);
        expect(tester.takeException(), isNull);
        expect(tester.getSize(_switcher).height, lessThanOrEqualTo(before + 2));
      }, skip: !sqliteAvailable);
    }

    testWidgets('holding the ReplayGain chip on its icon opens settings', (
      tester,
    ) async {
      await pumpSheet(tester);
      await showReplayGainPage(tester);
      await hold(tester, tester.getCenter(_infoIcon));
      expect(settingsOpen(), isTrue);
    }, skip: !sqliteAvailable);

    testWidgets('holding the ReplayGain chip just below its text opens '
        'settings', (tester) async {
      await pumpSheet(tester);
      await showReplayGainPage(tester);
      final text = tester.getRect(_infoText);
      await hold(tester, Offset(text.center.dx, text.bottom + 4));
      expect(settingsOpen(), isTrue);
    }, skip: !sqliteAvailable);

    testWidgets('holding the Quality chip on its icon opens track info '
        '', (tester) async {
      await pumpSheet(tester);
      expect(tester.widget<Text>(_infoText).data, _quality);
      await hold(tester, tester.getCenter(_infoIcon));
      expect(mediaInfoOpen(), isTrue);
    }, skip: !sqliteAvailable);
  });

  // Drift: Android's 8 dp touch slop (ViewConfiguration.getScaledTouchSlop,
  // passed as physicalTouchSlop) is also the tap and long-press tolerance, so
  // a hold that drifts past 8 px is cancelled with or without the sheet, the
  // same as on native Android. Within the slop the sheet does not interfere;
  // these guard that after the fix.
  group('drift within the Android slop', () {
    testWidgets('holding ReplayGain with 6 px of drift opens settings', (
      tester,
    ) async {
      await pumpSheet(tester);
      await showReplayGainPage(tester);
      await hold(
        tester,
        tester.getCenter(_infoText),
        drift: const Offset(0, 6),
      );
      expect(settingsOpen(), isTrue);
    }, skip: !sqliteAvailable);

    testWidgets('a tap with 6 px of drift pages', (tester) async {
      await pumpSheet(tester);
      final gesture = await tester.startGesture(tester.getCenter(_infoText));
      await tester.pump(const Duration(milliseconds: 30));
      await gesture.moveBy(const Offset(0, 6));
      await tester.pump(const Duration(milliseconds: 60));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(_infoText).data, contains(' dB '));
    }, skip: !sqliteAvailable);

    testWidgets('a 10 px hold without the sheet is cancelled too (platform '
        'slop, not the sheet)', (tester) async {
      await pumpSheet(tester, withSheet: false);
      await showReplayGainPage(tester);
      await hold(
        tester,
        tester.getCenter(_infoText),
        drift: const Offset(0, 10),
      );
      expect(settingsOpen(), isFalse);
    }, skip: !sqliteAvailable);
  });

  testWidgets('holding ReplayGain shows the ReplayGain section of Playback '
      'settings', (tester) async {
    await pumpSheet(tester, realPlaybackSettings: true);
    await showReplayGainPage(tester);
    await tester.longPress(_infoText);
    await tester.pumpAndSettle();
    expect(find.byType(PlaybackSettingsScreen), findsOneWidget);
    final title = find.text('Volume Normalization (ReplayGain)');
    expect(title, findsOneWidget);
    final rect = tester.getRect(title);
    expect(rect.top, inInclusiveRange(0, 844 - rect.height));
  }, skip: !sqliteAvailable);

  group('holding the Speed & Pitch and Queue chips', () {
    testWidgets('holding Speed & Pitch opens the speed and pitch panel', (
      tester,
    ) async {
      await pumpSheet(tester);
      await showPageWithIcon(tester, Icons.speed_outlined);
      expect(speedPanelOpen(), isFalse);
      await tester.longPress(_infoText);
      await tester.pumpAndSettle();
      expect(speedPanelOpen(), isTrue);
    }, skip: !sqliteAvailable);

    testWidgets('holding Queue opens the queue', (tester) async {
      await pumpSheet(tester);
      await showPageWithIcon(tester, Icons.queue_music_outlined);
      expect(queueOpen(), isFalse);
      await tester.longPress(_infoText);
      await tester.pumpAndSettle();
      expect(queueOpen(), isTrue);
    }, skip: !sqliteAvailable);

    testWidgets('an empty queue has nothing to open', (tester) async {
      await pumpSheet(tester);
      await showPageWithIcon(tester, Icons.queue_music_outlined);
      emitNowPlayingPlayback(
        container,
        const PlaybackSnapshot(
          queueSongIds: <String>[],
          currentSongId: 's1',
          currentIndex: null,
          playing: false,
          processingState: AudioProcessingState.idle,
          position: Duration.zero,
          duration: Duration.zero,
          bufferedPosition: Duration.zero,
          shuffleMode: AudioServiceShuffleMode.none,
          repeatMode: AudioServiceRepeatMode.none,
        ),
      );
      await tester.pumpAndSettle();
      await tester.longPress(_infoText);
      await tester.pumpAndSettle();
      expect(queueOpen(), isFalse);
    }, skip: !sqliteAvailable);

    testWidgets('the desktop cells open them (hold the queue, tap speed)', (
      tester,
    ) async {
      await pumpSheet(tester, withSheet: false, size: const Size(1000, 900));
      await tester.longPress(find.text('Playing 1 of 1'));
      await tester.pumpAndSettle();
      expect(queueOpen(), isTrue);
      expect(speedPanelOpen(), isFalse);
      await tester.tap(find.text('Speed & Pitch'));
      await tester.pumpAndSettle();
      expect(speedPanelOpen(), isTrue);
    }, skip: !sqliteAvailable);
  });

  group(
    'in the embedded wide layouts the holds open what the buttons open',
    () {
      final embeddedQueue = find.byKey(
        const ValueKey('right-pane-panel-queue'),
      );

      testWidgets(
        'split: holding the Queue cell opens the embedded queue panel '
        'like the Queue button',
        (tester) async {
          await pumpSheet(
            tester,
            withSheet: false,
            wideEmbeddedMode: true,
            size: const Size(1400, 900),
          );
          await tester.longPress(find.text('Playing 1 of 1'));
          await tester.pumpAndSettle();
          expect(embeddedQueue, findsOneWidget);
          expect(queueOpen(), isFalse);
        },
        skip: !sqliteAvailable,
      );

      testWidgets('split: the Queue button opens the same panel', (
        tester,
      ) async {
        await pumpSheet(
          tester,
          withSheet: false,
          wideEmbeddedMode: true,
          size: const Size(1400, 900),
        );
        // The split pane scrolls; a full-width cover puts the controls below the fold.
        await tester.ensureVisible(find.byTooltip('Queue').first);
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Queue').first);
        await tester.pumpAndSettle();
        expect(embeddedQueue, findsOneWidget);
        expect(queueOpen(), isFalse);
      }, skip: !sqliteAvailable);

      testWidgets('split: holding Speed & Pitch opens the quick panel the '
          'speed control opens', (tester) async {
        await pumpSheet(
          tester,
          withSheet: false,
          wideEmbeddedMode: true,
          size: const Size(1400, 900),
        );
        await tester.longPress(find.text('Speed & Pitch'));
        await tester.pumpAndSettle();
        expect(speedPanelOpen(), isTrue);
      }, skip: !sqliteAvailable);

      testWidgets('compact wide: holding the Queue line opens the compact '
          'queue panel', (tester) async {
        await pumpSheet(
          tester,
          withSheet: false,
          wideEmbeddedMode: true,
          compactWide: true,
          size: const Size(800, 400),
        );
        await showPageWithIcon(tester, Icons.queue_music_outlined);
        await tester.longPress(_infoText);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('compact-wide-queue')), findsWidgets);
        expect(queueOpen(), isFalse);
      }, skip: !sqliteAvailable);
    },
  );

  group('the chip keeps its other gestures', () {
    testWidgets('a tap still pages and a hold does not also page', (
      tester,
    ) async {
      await pumpSheet(tester);
      await hold(tester, tester.getCenter(_infoIcon));
      expect(mediaInfoOpen(), isTrue);
      expect(tester.widget<Text>(_infoText).data, _quality);
      await tester.tap(find.byKey(const ValueKey('mediaInfoClose')));
      await tester.pumpAndSettle();
      await showReplayGainPage(tester);
    }, skip: !sqliteAvailable);

    testWidgets('dragging down from the chip still collapses the sheet', (
      tester,
    ) async {
      var collapsed = false;
      await pumpSheet(tester, onCollapse: () => collapsed = true);
      await tester.fling(_infoText, const Offset(0, 300), 1200);
      await tester.pumpAndSettle();
      expect(collapsed, isTrue);
    }, skip: !sqliteAvailable);
  });

  group('a hold is a Lists & Menus haptic', () {
    // The framework's own long-press vibration is off, so the master switch
    // and the category decide.
    Future<void> checkHold(WidgetTester tester, Finder target) async {
      final spy = HapticsSpy.install(tester);
      NavisHaptics.prefs = HapticsPrefs.fromColumns(
        true,
        HapticCategory.listsAndMenus.bit,
      );
      await tester.longPress(target);
      await tester.pumpAndSettle();
      expect(mediaInfoOpen(), isTrue);
      expect(await spy.take(tester), isEmpty, reason: 'category off');
      expect(spy.takeFramework(), isEmpty);
      await tester.tap(find.byKey(const ValueKey('mediaInfoClose')));
      await tester.pumpAndSettle();

      NavisHaptics.prefs = HapticsPrefs.fromColumns(
        true,
        HapticCategory.playerGestures.bit,
      );
      await tester.longPress(target);
      await tester.pumpAndSettle();
      expect(await spy.take(tester), ['longPress'], reason: 'category on');
      expect(spy.takeFramework(), isEmpty);
    }

    testWidgets('the phone info chip', (tester) async {
      await pumpSheet(tester);
      await checkHold(tester, _infoText);
    }, skip: !sqliteAvailable);

    testWidgets('a desktop info-grid cell', (tester) async {
      await pumpSheet(tester, withSheet: false, size: const Size(1000, 900));
      await checkHold(tester, find.text(_quality));
    }, skip: !sqliteAvailable);
  });

  group('desktop info grid', () {
    const desktop = Size(1000, 900);

    testWidgets('the Quality cell opens track info on click and hold', (
      tester,
    ) async {
      await pumpSheet(tester, withSheet: false, size: desktop);
      expect(_switcher, findsNothing);
      await tester.tap(find.text(_quality));
      await tester.pumpAndSettle();
      expect(mediaInfoOpen(), isTrue);
    }, skip: !sqliteAvailable);

    testWidgets('holding the Quality cell opens track info', (tester) async {
      await pumpSheet(tester, withSheet: false, size: desktop);
      await tester.longPress(find.text(_quality));
      await tester.pumpAndSettle();
      expect(mediaInfoOpen(), isTrue);
    }, skip: !sqliteAvailable);

    testWidgets('the ReplayGain cell opens settings on click and hold', (
      tester,
    ) async {
      await pumpSheet(tester, withSheet: false, size: desktop);
      final value = find.textContaining(' dB ');
      expect(value, findsOneWidget);
      await tester.tap(value);
      await tester.pumpAndSettle();
      expect(settingsOpen(), isTrue);
      router.go(AppRoutes.home);
      await tester.pumpAndSettle();
      await tester.longPress(find.textContaining(' dB '));
      await tester.pumpAndSettle();
      expect(settingsOpen(), isTrue);
    }, skip: !sqliteAvailable);

    testWidgets('other cells stay inert', (tester) async {
      await pumpSheet(tester, withSheet: false, size: desktop);
      await tester.tap(find.text('Some Album').first);
      await tester.pumpAndSettle();
      expect(mediaInfoOpen(), isFalse);
      expect(settingsOpen(), isFalse);
    }, skip: !sqliteAvailable);
  });
}
