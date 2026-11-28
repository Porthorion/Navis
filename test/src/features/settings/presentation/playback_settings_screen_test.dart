import 'dart:async';
import 'dart:ui' show SemanticsAction;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/navis_section_header.dart';
import 'package:navis/src/common_widgets/navis_slider.dart';
import 'package:navis/src/common_widgets/new_feature_tag.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/database/daos/library_dao.dart';
import 'package:navis/src/features/equalizer/presentation/eq_entry.dart';
import 'package:navis/src/features/equalizer/domain/eq_configuration.dart';
import 'package:navis/src/features/equalizer/presentation/eq_controller.dart';
import 'package:navis/src/features/onboarding/domain/setup_highlights.dart';
import 'package:navis/src/features/onboarding/presentation/setup_highlights_provider.dart';
import 'package:navis/src/features/player/presentation/adjustment_ruler.dart';
import 'package:navis/src/features/player/presentation/playback_adjustment_controller.dart';
import 'package:navis/src/features/player/presentation/replay_gain_untagged_provider.dart';
import 'package:navis/src/features/settings/data/settings_repository.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/features/settings/presentation/playback_settings_screen.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../../../helpers/adaptive_test_harness.dart';
import '../../../../helpers/fake_playback_handler.dart';
import '../../../../helpers/test_theme.dart';

class _MockSettingsRepository extends Mock implements SettingsRepository;

/// Reset-path stand-ins: the screen only needs these controllers to accept
/// the reset calls, not to touch storage or the audio engine.
class _FakeAdjustments extends PlaybackAdjustmentController {
  @override
  Future<PlaybackAdjustmentState> build() async => PlaybackAdjustmentState();

  @override
  Future<bool> selectPreset(String id) async => true;
}

class _FakeEq extends EqController {
  @override
  Future<EqState> build() async =>
      EqState(configuration: EqConfiguration.flat(), presets: const []);

  @override
  Future<void> reset() async {}
}

void main() {
  setUpAll(() {
    registerFallbackValue(const AppSettingsModel.defaults());
  });

  group('PlaybackSettingsScreen', () {
    late _MockSettingsRepository repository;
    const initialSettings = AppSettingsModel(
      wifiMaxBitRate: null,
      wifiFormat: null,
      cellularMaxBitRate: 192,
      cellularFormat: 'mp3',
      scrobbleEnabled: true,
      gaplessEnabled: true,
      skipSilenceEnabled: false,
      showAlbumsPage: true,
      showRadioPage: true,
      showPlaylistsPage: true,
      showArtistsPage: true,
      showLikedPage: true,

      wifiOnlyDownloads: false,
      autoDownloadStarredOnWifi: false,
      customDownloadFolderEnabled: false,
      customDownloadFolderPath: null,
      themeMode: 'dark',
      colorStyle: 'neutral',
      oledForAuto: false,
      nightScheduleEnabled: false,
      nightScheduleStartMinutes: 1320,
      nightScheduleEndMinutes: 420,
      flatSurfaces: false,
      colorSchemeSeed: null,
      appLocale: null,
      crossfadeEnabled: false,
      crossfadeDurationSeconds: 5,
      crossfadeType: 'normal',
      dynamicAlbumColorEnabled: false,
      updateCheckEnabled: true,
      updateChannel: 'stable',
      syncIntervalMinutes: 60,
      useLrclib: true,
      legacyInstantMixEnabled: false,
      replayGainMode: 'off',
      replayGainPreamp: 0,
      playbackSpeed: 1,
      albumGridDensity: null,
      coverArtShape: 'rounded',
      nowPlayingArtShape: 'rounded',
      artistCardShape: 'circle',
      artistViewMode: 'grid',
      homeSectionOrder: null,
      homeSectionsHidden: null,
      libraryPageOrder: null,
    );

    setUp(() {
      repository = _MockSettingsRepository();
      when(() => repository.saveSettings(any())).thenAnswer((_) async {});
      when(() => repository.resetPlaybackDefaults()).thenAnswer((_) async {});
    });

    testWidgets('renders playback settings controls', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            replayGainLibraryGainsProvider.overrideWith(
              (ref) async => (count: 0, median: null, total: 0, withData: 0),
            ),
            settingsRepositoryProvider.overrideWithValue(repository),
            appSettingsProvider.overrideWithValue(
              const AsyncData(initialSettings),
            ),
          ],
          child: _buildTestApp(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Wi-Fi Streaming'), findsOneWidget);
      expect(find.text('Cellular Streaming'), findsOneWidget);
      expect(find.text('Play Cached Copies at Any Quality'), findsOneWidget);
      expect(find.text('Enable Scrobbling'), findsOneWidget);
      expect(find.text('Enable Gapless Playback'), findsOneWidget);
      expect(find.text('Experimental'), findsOneWidget);
      expect(find.text('Show Radio page'), findsNothing);
      expect(find.text('Skip silence when possible'), findsNothing);
      expect(find.text('Changes save automatically'), findsOneWidget);
      expect(find.text('Reset Defaults'), findsOneWidget);
    });

    group('sections', () {
      Future<void> pumpPlayback(
        WidgetTester tester, {
        Size viewport = const Size(800, 6000),
        bool focusReplayGain = false,
      }) async {
        setAdaptiveTestViewport(tester, viewport);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              replayGainLibraryGainsProvider.overrideWith(
                (ref) async => (count: 0, median: null, total: 0, withData: 0),
              ),
              settingsRepositoryProvider.overrideWithValue(repository),
              appSettingsProvider.overrideWithValue(
                AsyncData(
                  initialSettings.copyWith(
                    albumQueueEnabled: true,
                    crossfadeEnabled: true,
                    replayGainMode: 'track',
                  ),
                ),
              ),
              playbackAdjustmentsProvider.overrideWith(_FakeAdjustments.new),
              equalizerProvider.overrideWith(_FakeEq.new),
            ],
            child: _buildTestApp(focusReplayGain: focusReplayGain),
          ),
        );
        await tester.pumpAndSettle();
      }

      Finder header(String title) => find.byWidgetPredicate(
        (w) => w is NavisSectionHeader && w.title == title,
      );

      testWidgets('headed sections and their controls run in plan order', (
        tester,
      ) async {
        await pumpPlayback(tester);
        final l10n = AppLocalizations.of(
          tester.element(find.byType(PlaybackSettingsScreen)),
        )!;
        double top(Finder f) => tester.getTopLeft(f.first).dy;
        final ordered = <Finder>[
          header(l10n.playbackSettingsQueueSectionTitle),
          find.text(l10n.playbackSettingsQueueEndLabel),
          find.text(l10n.playbackSettingsAlbumQueueTitle),
          find.text(l10n.playbackSettingsLikedQueueTitle),
          header(l10n.playbackSettingsTransitionsSectionTitle),
          find.text(l10n.playbackSettingsGaplessTitle),
          find.text(l10n.playbackSettingsCrossfadeEnableTitle),
          find.text(l10n.playbackSettingsCrossfadeTypeLabel),
          header(l10n.playbackSettingsVolumeSectionTitle),
          find.text(l10n.playbackSettingsReplayGainModeLabel),
          header(l10n.playbackSpeedPitchTitle),
          header(l10n.playbackSettingsStreamingSectionTitle),
          find.text(l10n.playbackSettingsWifiSectionTitle),
          find.text(l10n.playbackSettingsCellularSectionTitle),
          find.text(l10n.playbackSettingsCachedFirstTitle),
          find.text(l10n.playbackSettingsPrefetchNextTitle),
          header(l10n.playbackSettingsLyricsSectionTitle),
          find.text(l10n.playbackSettingsFullscreenLyricsTitle),
          header(l10n.playbackSettingsScrobblingSectionTitle),
          find.text(l10n.playbackSettingsScrobbleTitle),
          find.text(l10n.playbackSettingsExperimentalTitle),
          find.text(l10n.playbackSettingsFooterIdle),
          find.text(l10n.playbackSettingsResetAction),
        ];
        for (var i = 0; i < ordered.length; i++) {
          expect(ordered[i], findsWidgets, reason: 'control $i');
        }
        for (var i = 1; i < ordered.length; i++) {
          expect(
            top(ordered[i]),
            greaterThan(top(ordered[i - 1])),
            reason: 'control $i below control ${i - 1}',
          );
        }
      });

      testWidgets('?focus=replayGain scrolls to the Volume section', (
        tester,
      ) async {
        await pumpPlayback(
          tester,
          viewport: const Size(800, 600),
          focusReplayGain: true,
        );
        final volume = header('Volume');
        expect(volume, findsOneWidget);
        expect(tester.getTopLeft(volume).dy, lessThan(100));
      });
    });

    group('ReplayGain untagged songs', () {
      AppSettingsModel? saved;

      Future<void> pump(
        WidgetTester tester, {
        String mode = 'track',
        double? untaggedDb,
        Size viewport = const Size(1280, 1400),
        double textScale = 1,
        Future<double> Function()? auto,
        AppSettingsModel? afterReset,
      }) async {
        setAdaptiveTestViewport(tester, viewport);
        when(() => repository.getSettings())
            .thenAnswer((_) async => afterReset ?? initialSettings);
        saved = null;
        when(() => repository.saveSettings(any()))
            .thenAnswer((invocation) async {
              saved = invocation.positionalArguments.first as AppSettingsModel;
            });
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              replayGainLibraryGainsProvider.overrideWith(
                (ref) async => (count: 0, median: null, total: 0, withData: 0),
              ),
              settingsRepositoryProvider.overrideWithValue(repository),
              appSettingsProvider.overrideWithValue(
                AsyncData(
                  initialSettings.copyWith(
                    replayGainMode: mode,
                    replayGainUntaggedDb: untaggedDb,
                  ),
                ),
              ),
              replayGainAutoUntaggedDbProvider.overrideWith(
                (ref) => auto == null ? Future.value(-9.1) : auto(),
              ),
              playbackAdjustmentsProvider.overrideWith(_FakeAdjustments.new),
              equalizerProvider.overrideWith(_FakeEq.new),
            ],
            child: _buildTestApp(
              desktopMode: viewport.width > 600,
              textScale: textScale,
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      final switchFinder = find.byKey(
        const ValueKey('replayGainUntagged-automatic'),
      );
      final rulerFinder = find.byKey(
        const ValueKey('replayGainUntagged-ruler'),
      );

      AdjustmentRuler ruler(WidgetTester tester) =>
          tester.widget<AdjustmentRuler>(rulerFinder);

      // The ruler counts in tens of dB so its hundredths are 0.1 dB steps and
      // its tenths are whole dB; see `_buildUntaggedLevel`.
      double rulerDb(WidgetTester tester) => ruler(tester).value * 10;

      // 80 px a dB (800 px a ruler unit), and dragging right lowers the value.
      Future<TestGesture> dragRuler(WidgetTester tester, double dx) async {
        await tester.ensureVisible(rulerFinder);
        await tester.pumpAndSettle();
        final gesture = await tester.startGesture(
          tester.getCenter(rulerFinder),
        );
        // The first move only starts the drag.
        await gesture.moveBy(Offset(dx.sign * 100, 0));
        await gesture.moveBy(Offset(dx, 0));
        await tester.pump();
        return gesture;
      }

      Future<void> release(WidgetTester tester, TestGesture gesture) async {
        await gesture.up();
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 600));
      }

      Future<void> toggleAutomatic(WidgetTester tester) async {
        await tester.ensureVisible(switchFinder);
        await tester.pumpAndSettle();
        await tester.tap(switchFinder);
        await tester.pumpAndSettle(const Duration(milliseconds: 600));
      }

      testWidgets(
        'Automatic is on with a read-only ruler at the library level',
        (tester) async {
          await pump(tester);
          expect(find.text('Untagged songs'), findsOneWidget);
          expect(find.text('Automatic (-9.1 dB)'), findsOneWidget);
          expect(tester.widget<SwitchListTile>(switchFinder).value, isTrue);
          expect(rulerDb(tester), closeTo(-9.1, 1e-9));
          expect(ruler(tester).readOnly, isTrue);
          expect(ruler(tester).enabled, isFalse);
        },
      );

      testWidgets('is hidden while ReplayGain is off', (tester) async {
        await pump(tester, mode: 'off');
        expect(find.text('Untagged songs'), findsNothing);
      });

      testWidgets(
        'a stored fixed level shows the switch off and the ruler there',
        (tester) async {
          await pump(tester, untaggedDb: -12);
          expect(find.text('-12 dB'), findsOneWidget);
          expect(tester.widget<SwitchListTile>(switchFinder).value, isFalse);
          expect(rulerDb(tester), closeTo(-12, 1e-9));
          expect(ruler(tester).readOnly, isFalse);
          expect(ruler(tester).enabled, isTrue);
        },
      );

      testWidgets('turning Automatic off starts at the automatic level', (
        tester,
      ) async {
        await pump(tester);
        await toggleAutomatic(tester);
        expect(saved?.replayGainUntaggedDb, -9.1);
        expect(rulerDb(tester), closeTo(-9.1, 1e-9));
        expect(ruler(tester).enabled, isTrue);
      });

      testWidgets('turning Automatic off rounds the level to 0.1 dB', (
        tester,
      ) async {
        await pump(tester, auto: () async => -9.16);
        await toggleAutomatic(tester);
        expect(saved?.replayGainUntaggedDb, -9.2);
      });

      testWidgets('the automatic ruler sits where Automatic off will store', (
        tester,
      ) async {
        // -1.45 / 10 and -1.45 * 10 round differently in binary floats.
        await pump(tester, auto: () async => -1.45);
        final shown = rulerDb(tester);
        await toggleAutomatic(tester);
        expect(saved?.replayGainUntaggedDb, closeTo(shown, 1e-9));
      });

      testWidgets('an automatic level just below 0 reads 0 dB, not -0.0', (
        tester,
      ) async {
        await pump(tester, auto: () async => -0.04);
        expect(find.text('Automatic (0 dB)'), findsOneWidget);
      });

      testWidgets('turning Automatic back on clears the stored level', (
        tester,
      ) async {
        await pump(tester, untaggedDb: -6);
        await toggleAutomatic(tester);
        expect(saved?.replayGainUntaggedDb, isNull);
        expect(ruler(tester).readOnly, isTrue);
      });

      testWidgets('a ruler drag saves only when it ends', (tester) async {
        await pump(tester, untaggedDb: -10);
        await tester.ensureVisible(rulerFinder);
        await tester.pumpAndSettle();
        final gesture = await dragRuler(tester, 160);
        await tester.pump(const Duration(milliseconds: 600));
        expect(saved, isNull);
        await release(tester, gesture);
        expect(saved?.replayGainUntaggedDb, -12);
      });

      testWidgets('a drag lands on a tenth of a dB and saves it exactly', (
        tester,
      ) async {
        await pump(tester, untaggedDb: -10);
        // 64 px left is +0.8 dB.
        final gesture = await dragRuler(tester, -64);
        expect(find.text('-9.2 dB'), findsOneWidget);
        await release(tester, gesture);
        expect(saved?.replayGainUntaggedDb, -9.2);
        expect(find.text('-9.2 dB'), findsOneWidget);
      });

      testWidgets('a stored tenth of a dB is kept and shown with a decimal', (
        tester,
      ) async {
        await pump(tester, untaggedDb: -9.2);
        expect(find.text('-9.2 dB'), findsOneWidget);
        expect(rulerDb(tester), closeTo(-9.2, 1e-9));
      });

      testWidgets('a stored level beyond the ruler is clamped', (tester) async {
        await pump(tester, untaggedDb: -20);
        expect(find.text('-15 dB'), findsOneWidget);
      });

      testWidgets('a drag stops at 0 dB and at the minimum', (tester) async {
        await pump(tester, untaggedDb: -1);
        var gesture = await dragRuler(tester, -400);
        expect(find.text('0 dB'), findsOneWidget);
        await release(tester, gesture);
        expect(saved?.replayGainUntaggedDb, 0);

        gesture = await dragRuler(tester, 2000);
        expect(find.text('-15 dB'), findsOneWidget);
        await release(tester, gesture);
        expect(saved?.replayGainUntaggedDb, -15);
      });

      testWidgets('the arrow keys move the level 0.1 dB, Shift a dB', (
        tester,
      ) async {
        await pump(tester, untaggedDb: -10);
        await tester.ensureVisible(rulerFinder);
        await tester.pumpAndSettle();
        await tester.tap(rulerFinder);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        expect(saved?.replayGainUntaggedDb, -9.9);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        expect(saved?.replayGainUntaggedDb, -10.9);
      });

      testWidgets('holding a stepper to the limit stops there and saves', (
        tester,
      ) async {
        await pump(tester, untaggedDb: -3);
        await tester.ensureVisible(rulerFinder);
        await tester.pumpAndSettle();
        final gesture = await tester.startGesture(
          tester.getCenter(
            find.byKey(const ValueKey('replayGainUntagged-plus')),
          ),
        );
        // Long press at 500 ms, then repeats every 120 ms: -3 reaches 0 well
        // inside the hold.
        for (var i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        await gesture.up();
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 600));
        expect(tester.takeException(), isNull);
        expect(saved?.replayGainUntaggedDb, 0);
      });

      testWidgets('an interrupted drag leaves no stale level after a reset', (
        tester,
      ) async {
        await pump(
          tester,
          untaggedDb: -10,
          afterReset: initialSettings.copyWith(replayGainMode: 'track'),
        );
        await tester.ensureVisible(rulerFinder);
        await tester.pumpAndSettle();
        final gesture = await tester.startGesture(
          tester.getCenter(rulerFinder),
        );
        await gesture.moveBy(const Offset(100, 0));
        await gesture.moveBy(const Offset(160, 0));
        await tester.pump();
        expect(rulerDb(tester), closeTo(-12, 1e-9));

        final resetDefaults = find.text('Reset Defaults');
        await tester.ensureVisible(resetDefaults);
        await tester.pumpAndSettle();
        await tester.tap(resetDefaults);
        await tester.pumpAndSettle();

        expect(tester.widget<SwitchListTile>(switchFinder).value, isTrue);
        expect(rulerDb(tester), closeTo(-9.1, 1e-9));
        expect(ruler(tester).readOnly, isTrue);
        await gesture.up();
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 600));
        expect(tester.widget<SwitchListTile>(switchFinder).value, isTrue);
        expect(rulerDb(tester), closeTo(-9.1, 1e-9));
      });

      testWidgets('Automatic stays on until the library level is known', (
        tester,
      ) async {
        final auto = Completer<double>();
        await tester.runAsync(() async {});
        await pump(tester, auto: () => auto.future);
        // pumpAndSettle in pump() returns with the future still pending.
        expect(tester.widget<SwitchListTile>(switchFinder).onChanged, isNull);
        auto.complete(-9.1);
        await tester.pumpAndSettle();
        expect(
          tester.widget<SwitchListTile>(switchFinder).onChanged,
          isNotNull,
        );
      });

      for (final scale in [2.0, 3.0]) {
        testWidgets('the level rows fit 320 dp at ${scale}x text', (
          tester,
        ) async {
          final errors = <FlutterErrorDetails>[];
          final previous = FlutterError.onError;
          FlutterError.onError = errors.add;
          addTearDown(() => FlutterError.onError = previous);
          await pump(
            tester,
            untaggedDb: -12,
            viewport: const Size(320, 1400),
            textScale: scale,
          );
          await tester.ensureVisible(rulerFinder);
          await tester.pumpAndSettle();
          FlutterError.onError = previous;

          // Other rows may overflow at this size; the new ones may not.
          final label = tester.getRect(find.text('Untagged songs'));
          final readout = tester.getRect(find.text('-12 dB'));
          final row = tester.getRect(rulerFinder);
          expect(readout.right, lessThanOrEqualTo(320));
          expect(label.right, lessThanOrEqualTo(readout.left + 0.5));
          expect(row.left, greaterThanOrEqualTo(0));
          expect(row.right, lessThanOrEqualTo(320));
          for (final e in errors) {
            expect(
              e.toString(),
              isNot(contains('replayGainUntagged')),
              reason: 'new rows must not raise layout errors',
            );
          }
        });
      }

      testWidgets('the mode list offers Smart, explains it and saves it', (
        tester,
      ) async {
        await pump(tester);
        final modeField = find.byType(DropdownButtonFormField<String>);
        await tester.ensureVisible(modeField);
        await tester.tap(modeField);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Smart').last);
        await tester.pumpAndSettle(const Duration(milliseconds: 600));
        expect(saved?.replayGainMode, 'smart');
        expect(
          find.text(
            'Uses album levels when songs from one album play in a row, and '
            'track levels otherwise.',
          ),
          findsOneWidget,
        );
      });

      testWidgets('the steppers move the level a dB and stop at the limits', (
        tester,
      ) async {
        await pump(tester, untaggedDb: -1);
        await tester.ensureVisible(rulerFinder);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('replayGainUntagged-plus')));
        await tester.pumpAndSettle(const Duration(milliseconds: 600));
        expect(saved?.replayGainUntaggedDb, 0);
        // A tap at the limit changes nothing.
        saved = null;
        await tester.tap(find.byKey(const ValueKey('replayGainUntagged-plus')));
        await tester.pumpAndSettle(const Duration(milliseconds: 600));
        expect(saved, isNull);
        expect(rulerDb(tester), 0);
        await tester.tap(
          find.byKey(const ValueKey('replayGainUntagged-minus')),
        );
        await tester.pumpAndSettle(const Duration(milliseconds: 600));
        expect(saved?.replayGainUntaggedDb, -1);
      });

      testWidgets('a stepper keeps the tenths and clamps to the limits', (
        tester,
      ) async {
        // Like the pitch and speed steppers, it moves a whole labelled step
        // from wherever the ruler sits and stops at the range end.
        await pump(tester, untaggedDb: -14.5);
        await tester.ensureVisible(rulerFinder);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('replayGainUntagged-plus')));
        await tester.pumpAndSettle(const Duration(milliseconds: 600));
        expect(saved?.replayGainUntaggedDb, -13.5);
        await tester.tap(
          find.byKey(const ValueKey('replayGainUntagged-minus')),
        );
        await tester.pumpAndSettle(const Duration(milliseconds: 600));
        await tester.tap(
          find.byKey(const ValueKey('replayGainUntagged-minus')),
        );
        await tester.pumpAndSettle(const Duration(milliseconds: 600));
        expect(saved?.replayGainUntaggedDb, -15);
      });
    });

    group('Loudness presets', () {
      const minus = '−';
      AppSettingsModel? saved;
      var saves = 0;
      final seenOptions = <SetupHighlight>[];

      setUp(() {
        VisibilityDetectorController.instance.updateInterval = Duration.zero;
      });

      Future<void> pump(
        WidgetTester tester, {
        String mode = 'smart',
        ReplayGainLoudness loudness = ReplayGainLoudness.normal,
        double preamp = 0,
        bool boost = true,
        bool limiter = true,
        Size viewport = const Size(1280, 4000),
        double textScale = 1,
        Set<SetupHighlight> highlights = const <SetupHighlight>{},
      }) async {
        setAdaptiveTestViewport(tester, viewport);
        saved = null;
        saves = 0;
        _BoostHandler.applied = 0;
        seenOptions.clear();
        when(() => repository.getSettings())
            .thenAnswer((_) async => initialSettings);
        when(() => repository.saveSettings(any())).thenAnswer((call) async {
          saved = call.positionalArguments.first as AppSettingsModel;
          saves++;
        });
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              settingsRepositoryProvider.overrideWithValue(repository),
              appSettingsProvider.overrideWithValue(
                AsyncData(
                  initialSettings.copyWith(
                    replayGainMode: mode,
                    replayGainLoudness: loudness,
                    replayGainPreamp: preamp,
                  ),
                ),
              ),
              if (boost || limiter)
                audioHandlerProvider.overrideWithValue(
                  limiter ? _LimiterHandler() : _BoostHandler(),
                ),
              pendingSetupHighlightsProvider.overrideWithValue(highlights),
              setupHighlightsServiceProvider.overrideWith(
                (ref) => SetupHighlightsService(
                  () async {},
                  () async {},
                  (option) async => seenOptions.add(option),
                ),
              ),
              replayGainLibraryGainsProvider.overrideWith(
                (ref) async => (count: 0, median: null, total: 0, withData: 0),
              ),
              replayGainAutoUntaggedDbProvider.overrideWith(
                (ref) async => -9.1,
              ),
              playbackAdjustmentsProvider.overrideWith(_FakeAdjustments.new),
              equalizerProvider.overrideWith(_FakeEq.new),
            ],
            child: _buildTestApp(
              desktopMode: viewport.width > 600,
              textScale: textScale,
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      Finder tile(String name) => find.byKey(ValueKey('loudness-$name'));
      // "Custom" also names a crossfade type elsewhere on the page.
      Finder inGroup(String text) => find.descendant(
        of: find.byType(RadioGroup<ReplayGainLoudness>),
        matching: find.text(text),
      );
      final slider = find.byKey(const ValueKey('loudness-custom-slider'));

      String? selected(WidgetTester tester) => tester
          .widget<RadioGroup<ReplayGainLoudness>>(
            find.byType(RadioGroup<ReplayGainLoudness>),
          )
          .groupValue
          ?.name;

      Future<void> choose(WidgetTester tester, String name) async {
        await _tapVisible(tester, tile(name));
        await tester.pumpAndSettle();
      }

      Future<void> settleSave(WidgetTester tester) async {
        await tester.pump(const Duration(milliseconds: 700));
        await tester.pumpAndSettle();
      }

      testWidgets('four tiles with their subtitles, Normal by default', (
        tester,
      ) async {
        await pump(tester);
        expect(find.text('Loudness'), findsOneWidget);
        expect(selected(tester), 'normal');
        for (final text in [
          'Quiet',
          '${minus}18 LUFS · ReplayGain reference level, most headroom',
          'Normal',
          "${minus}14 LUFS · Like Spotify and YouTube's default level",
          'Loud',
          '${minus}11 LUFS · A limiter keeps peaks from clipping',
          'Custom',
          // Custom starts from where Normal sits: +4 dB.
          '${minus}14.0 LUFS · +4.0 dB from the ReplayGain reference',
        ]) {
          expect(inGroup(text), findsOneWidget, reason: text);
        }
        expect(slider, findsNothing);
        expect(find.textContaining('Pre-Amp'), findsNothing);
      });

      testWidgets('an unknown stored preset reads as Normal', (tester) async {
        await pump(tester, loudness: ReplayGainLoudness.parse('turbo'));
        expect(selected(tester), 'normal');
      });

      testWidgets('is hidden while ReplayGain is off', (tester) async {
        await pump(tester, mode: 'off');
        expect(find.text('Loudness'), findsNothing);
        expect(tile('normal'), findsNothing);
      });

      testWidgets('a device that cannot boost says so; one that can, not', (
        tester,
      ) async {
        const line =
            'This device can only turn songs down, so louder presets reduce '
            'the turn-down.';
        await pump(tester, boost: false, limiter: false);
        expect(find.text(line), findsOneWidget);
        // The shared line above explains the limits, so Loud is just its level.
        expect(inGroup('${minus}11 LUFS'), findsOneWidget);
        expect(find.textContaining('Raises songs'), findsNothing);
      });

      testWidgets('with boost but no confirmed limiter Loud says so', (
        tester,
      ) async {
        await pump(tester, limiter: false);
        expect(
          find.text(
            '${minus}11 LUFS · Raises songs as far as their peaks allow',
          ),
          findsOneWidget,
        );
        expect(find.textContaining('A limiter keeps'), findsNothing);
        expect(find.textContaining('only turn songs down'), findsNothing);
      });

      testWidgets('choosing Custom seeds the slider from Normal: +4 dB', (
        tester,
      ) async {
        // The stored pre-amp (2 dB) is not remembered.
        await pump(tester, preamp: 2);
        await choose(tester, 'custom');
        expect(tester.widget<NavisSlider>(slider).value, 4);
        expect(
          find.text(
            '${minus}14.0 LUFS · +4.0 dB from the ReplayGain reference',
          ),
          findsOneWidget,
        );
        await settleSave(tester);
        expect(saved?.replayGainLoudness, ReplayGainLoudness.custom);
        expect(saved?.replayGainPreamp, 4);
      });

      testWidgets('Custom seeds from the preset that was selected', (
        tester,
      ) async {
        await pump(tester, loudness: ReplayGainLoudness.loud);
        await choose(tester, 'custom');
        expect(tester.widget<NavisSlider>(slider).value, 7);
        await settleSave(tester);
        expect(saved?.replayGainPreamp, 7);
      });

      testWidgets('Custom from Quiet starts at 0, not the stored pre-amp', (
        tester,
      ) async {
        await pump(tester, loudness: ReplayGainLoudness.quiet, preamp: 5);
        await choose(tester, 'custom');
        expect(tester.widget<NavisSlider>(slider).value, 0);
      });

      testWidgets('a stored Custom keeps its offset and shows the slider', (
        tester,
      ) async {
        await pump(tester, loudness: ReplayGainLoudness.custom, preamp: -2.5);
        expect(selected(tester), 'custom');
        final widget = tester.widget<NavisSlider>(slider);
        expect(widget.value, -2.5);
        expect(widget.min, -6);
        expect(widget.max, 8);
        expect(widget.divisions, 28);
        expect(
          find.text(
            '${minus}20.5 LUFS · $minus'
            '2.5 dB from the ReplayGain '
            'reference',
          ),
          findsOneWidget,
        );
      });

      testWidgets('moving the slider updates the readout and saves', (
        tester,
      ) async {
        await pump(tester, loudness: ReplayGainLoudness.custom, preamp: 4);
        tester.widget<NavisSlider>(slider).onChanged!(8);
        await tester.pump();
        expect(
          find.text(
            '${minus}10.0 LUFS · +8.0 dB from the ReplayGain reference',
          ),
          findsOneWidget,
        );
        await settleSave(tester);
        expect(saved?.replayGainLoudness, ReplayGainLoudness.custom);
        expect(saved?.replayGainPreamp, 8);
        tester.widget<NavisSlider>(slider).onChanged!(-6);
        await tester.pump();
        expect(
          find.text(
            '${minus}24.0 LUFS · $minus'
            '6.0 dB from the ReplayGain '
            'reference',
          ),
          findsOneWidget,
        );
      });

      testWidgets('the slider hides again on a preset', (tester) async {
        await pump(tester, loudness: ReplayGainLoudness.custom, preamp: 1);
        await choose(tester, 'quiet');
        expect(slider, findsNothing);
        await settleSave(tester);
        expect(saved?.replayGainLoudness, ReplayGainLoudness.quiet);
      });

      testWidgets('autosave persists the chosen preset', (tester) async {
        await pump(tester);
        await choose(tester, 'loud');
        await settleSave(tester);
        expect(saved?.replayGainLoudness, ReplayGainLoudness.loud);
        expect(saved?.replayGainMode, 'smart');
        expect(saves, 1);
      });

      testWidgets('leaving within the debounce still saves and applies', (
        tester,
      ) async {
        await pump(tester);
        await tester.tap(tile('loud'));
        await tester.pump(const Duration(milliseconds: 100));
        expect(saves, 0);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        expect(saves, 1);
        expect(saved?.replayGainLoudness, ReplayGainLoudness.loud);
        expect(_BoostHandler.applied, 1);
      });

      testWidgets('leaving during a save still writes the newer choice', (
        tester,
      ) async {
        await pump(tester);
        final writes = <ReplayGainLoudness>[];
        final gate = Completer<void>();
        when(() => repository.saveSettings(any())).thenAnswer((call) async {
          final model = call.positionalArguments.first as AppSettingsModel;
          writes.add(model.replayGainLoudness);
          if (writes.length == 1) {
            await gate.future;
          }
        });
        await choose(tester, 'loud');
        await tester.pump(const Duration(milliseconds: 700));
        expect(writes, [ReplayGainLoudness.loud]);
        // Not choose(): the in-flight save keeps a spinner animating.
        await tester.tap(tile('quiet'));
        await tester.pump(const Duration(milliseconds: 700));
        await tester.pumpWidget(const SizedBox());
        gate.complete();
        await tester.pumpAndSettle();
        expect(writes.last, ReplayGainLoudness.quiet);
      });

      testWidgets('the Custom slider is named and reads out its dB', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        await pump(tester, loudness: ReplayGainLoudness.custom, preamp: 4);
        // Not "57%": the value is the offset, announced under the label.
        expect(find.semantics.byValue('+4.0 dB'), findsOneWidget);
        expect(find.semantics.byValue('57%'), findsNothing);
        expect(tester.getSemantics(slider).label, 'Loudness');
        handle.dispose();
      });

      testWidgets('rapid switching saves once, with the last choice', (
        tester,
      ) async {
        await pump(tester);
        await tester.tap(tile('quiet'));
        await tester.pump(const Duration(milliseconds: 100));
        await tester.tap(tile('loud'));
        await tester.pump(const Duration(milliseconds: 100));
        await tester.tap(tile('custom'));
        await tester.pump(const Duration(milliseconds: 100));
        expect(saves, 0);
        await settleSave(tester);
        expect(saves, 1);
        expect(saved?.replayGainLoudness, ReplayGainLoudness.custom);
        // Seeded from Loud, the preset selected just before.
        expect(saved?.replayGainPreamp, 7);
      });

      testWidgets('switching away and back before the save writes nothing', (
        tester,
      ) async {
        await pump(tester);
        await tester.tap(tile('loud'));
        await tester.pump(const Duration(milliseconds: 100));
        await tester.tap(tile('normal'));
        // The frame that rebuilds the form is what cancels the pending save.
        await tester.pump();
        await settleSave(tester);
        expect(saves, 0);
      });

      testWidgets(
        'the tiles are one radio group, each named with its subtitle',
        (tester) async {
          final handle = tester.ensureSemantics();
          await pump(tester);
          for (final (name, title, subtitle) in [
            ('quiet', 'Quiet', 'ReplayGain reference level'),
            ('normal', 'Normal', "Spotify and YouTube's default level"),
            ('loud', 'Loud', 'A limiter keeps peaks'),
            ('custom', 'Custom', 'from the ReplayGain reference'),
          ]) {
            final node = tester.getSemantics(tile(name));
            expect(node.label, contains(title));
            expect(node.label, contains(subtitle));
            expect(
              node.getSemanticsData().hasAction(SemanticsAction.tap),
              isTrue,
            );
          }
          handle.dispose();
        },
      );

      testWidgets('large text and a landscape phone do not overflow', (
        tester,
      ) async {
        await pump(
          tester,
          loudness: ReplayGainLoudness.custom,
          preamp: -6,
          viewport: const Size(800, 360),
          textScale: 2,
        );
        await choose(tester, 'loud');
        await choose(tester, 'custom');
        expect(tester.takeException(), isNull);
        await pump(tester, viewport: const Size(360, 700), textScale: 2);
        await choose(tester, 'custom');
        expect(tester.takeException(), isNull);
        expect(tile('custom').hitTestable(), findsOneWidget);
      });

      testWidgets('the New tag sits on the Loudness label and clears', (
        tester,
      ) async {
        await pump(
          tester,
          highlights: const <SetupHighlight>{SetupHighlight.loudnessPresets},
        );
        final label = find
            .ancestor(of: find.text('Loudness'), matching: find.byType(Row))
            .first;
        expect(
          find.descendant(of: label, matching: find.byType(NewFeatureTag)),
          findsOneWidget,
        );
        await tester.pump(const Duration(milliseconds: 500));
        expect(seenOptions, <SetupHighlight>[SetupHighlight.loudnessPresets]);
        // The tag stays for the visit even though the option is now cleared.
        expect(find.byType(NewFeatureTag), findsOneWidget);
      });

      testWidgets('there is no tag when nothing is pending', (tester) async {
        await pump(tester);
        expect(find.byType(NewFeatureTag), findsNothing);
        await tester.pump(const Duration(milliseconds: 500));
        expect(seenOptions, isEmpty);
      });
    });

    group('ReplayGain guidance', () {
      Future<void> pump(
        WidgetTester tester, {
        String mode = 'smart',
        double preamp = 0,
        double? untaggedDb,
        LibraryGainStats? stats,
        bool boost = false,
        bool limiter = false,
      }) async {
        setAdaptiveTestViewport(tester, const Size(1280, 1800));
        when(() => repository.getSettings())
            .thenAnswer((_) async => initialSettings);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              settingsRepositoryProvider.overrideWithValue(repository),
              appSettingsProvider.overrideWithValue(
                AsyncData(
                  initialSettings.copyWith(
                    replayGainMode: mode,
                    replayGainPreamp: preamp,
                    replayGainUntaggedDb: untaggedDb,
                  ),
                ),
              ),
              if (boost || limiter)
                audioHandlerProvider.overrideWithValue(
                  limiter ? _LimiterHandler() : _BoostHandler(),
                ),
              replayGainLibraryGainsProvider.overrideWith(
                (ref) async =>
                    stats ?? (count: 3, median: -9.0, total: 100, withData: 82),
              ),
              replayGainAutoUntaggedDbProvider.overrideWith(
                (ref) async => -9.1,
              ),
              playbackAdjustmentsProvider.overrideWith(_FakeAdjustments.new),
              equalizerProvider.overrideWith(_FakeEq.new),
            ],
            child: _buildTestApp(desktopMode: true),
          ),
        );
        await tester.pumpAndSettle();
      }

      testWidgets('the intro mentions the Loud limiter where one exists', (
        tester,
      ) async {
        await pump(tester, limiter: true);
        expect(
          find.text(
            'ReplayGain plays every song at a similar volume. It turns loud '
            'songs down, and turns quiet songs up only as far as their peak '
            'level allows without distortion. Loud goes further, using a '
            'limiter to keep peaks from clipping. Songs without ReplayGain '
            'data are never turned up.',
          ),
          findsOneWidget,
        );
        expect(find.textContaining('never turns songs up'), findsNothing);
      });

      testWidgets('the intro makes no limiter claim without a limiter', (
        tester,
      ) async {
        await pump(tester, boost: true);
        expect(
          find.text(
            'ReplayGain plays every song at a similar volume. It turns loud '
            'songs down, and turns quiet songs up only as far as their peak '
            'level allows without distortion. Songs without ReplayGain data '
            'are never turned up.',
          ),
          findsOneWidget,
        );
        expect(find.textContaining('limiter'), findsNothing);
      });

      testWidgets('the intro says it only turns songs down', (tester) async {
        await pump(tester);
        expect(
          find.text(
            'ReplayGain turns loud songs down so they all play at a similar '
            'volume. It never turns songs up, so overall volume may sound '
            'lower: turn the volume up to compensate.',
          ),
          findsOneWidget,
        );
      });

      for (final (mode, text) in [
        ('off', 'No volume normalization applied.'),
        (
          'track',
          'Every song is levelled on its own. Best for shuffle and playlists.',
        ),
        (
          'album',
          'A whole album is levelled together, so its quiet and loud songs '
              'stay as the artist set them. Best for playing whole albums.',
        ),
        (
          'smart',
          'Uses album levels when songs from one album play in a row, and '
              'track levels otherwise.',
        ),
      ]) {
        testWidgets('the $mode mode explains itself', (tester) async {
          await pump(tester, mode: mode);
          expect(find.text(text), findsOneWidget);
        });
      }

      testWidgets('coverage names the share, the tools and the Automatic '
          'level', (tester) async {
        await pump(tester);
        expect(
          find.text('82% of your songs have ReplayGain data (82 of 100).'),
          findsOneWidget,
        );
        expect(
          find.text('The rest, and online songs, play at -9.1 dB (Automatic).'),
          findsOneWidget,
        );
        expect(
          find.text(
            'Tag your files with rsgain or MusicBrainz Picard, then rescan '
            'your library, to cover the rest.',
          ),
          findsOneWidget,
        );
      });

      testWidgets('coverage names a fixed level', (tester) async {
        await pump(tester, untaggedDb: -12);
        expect(
          find.text(
            'The rest, and online songs, play at -12 dB (fixed level).',
          ),
          findsOneWidget,
        );
      });

      testWidgets('coverage floors the percentage and says when off', (
        tester,
      ) async {
        await pump(
          tester,
          mode: 'off',
          stats: (count: 0, median: null, total: 3, withData: 2),
        );
        expect(
          find.text('66% of your songs have ReplayGain data (2 of 3).'),
          findsOneWidget,
        );
        expect(find.text('ReplayGain is off.'), findsOneWidget);
        expect(find.textContaining('online songs'), findsNothing);
      });

      testWidgets('full coverage needs no tagging tip', (tester) async {
        await pump(
          tester,
          stats: (count: 5, median: -9.0, total: 5, withData: 5),
        );
        expect(
          find.text('100% of your songs have ReplayGain data (5 of 5).'),
          findsOneWidget,
        );
        expect(find.textContaining('rsgain'), findsNothing);
      });

      testWidgets('one song reads in the singular', (tester) async {
        await pump(
          tester,
          stats: (count: 0, median: null, total: 1, withData: 0),
        );
        expect(
          find.text('0% of your song has ReplayGain data (0 of 1).'),
          findsOneWidget,
        );
      });

      testWidgets('coverage is hidden for an empty library', (tester) async {
        await pump(
          tester,
          stats: (count: 0, median: null, total: 0, withData: 0),
        );
        expect(find.textContaining('have ReplayGain data'), findsNothing);
        expect(find.textContaining('rsgain'), findsNothing);
      });
    });

    for (final platform in [
      TargetPlatform.linux,
      TargetPlatform.windows,
      TargetPlatform.android,
      TargetPlatform.macOS,
    ]) {
      testWidgets('Fast Seeking is desktop only and persists on $platform', (
        tester,
      ) async {
        setAdaptiveTestViewport(tester, const Size(1280, 1000));
        AppSettingsModel? saved;
        when(() => repository.saveSettings(any()))
            .thenAnswer((invocation) async {
              saved = invocation.positionalArguments.first as AppSettingsModel;
            });
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              replayGainLibraryGainsProvider.overrideWith(
                (ref) async => (count: 0, median: null, total: 0, withData: 0),
              ),
              settingsRepositoryProvider.overrideWithValue(repository),
              appSettingsProvider.overrideWithValue(
                const AsyncData(initialSettings),
              ),
            ],
            child: _buildTestApp(desktopMode: true),
          ),
        );
        await tester.pumpAndSettle();
        final toggle = find.widgetWithText(SwitchListTile, 'Fast Seeking');
        // macOS shows it only with media_kit registered, which the unit test
        // environment never does (see eq_platform_support_test.dart).
        if (platform == TargetPlatform.android ||
            platform == TargetPlatform.macOS) {
          expect(toggle, findsNothing);
        } else {
          await tester.ensureVisible(toggle);
          await tester.pumpAndSettle();
          expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
          await tester.tap(toggle);
          await tester.pumpAndSettle(const Duration(milliseconds: 500));
          expect(saved?.fastSeekingEnabled, isFalse);
        }
      }, variant: TargetPlatformVariant({platform}));
    }

    group('when the queue ends', () {
      AppSettingsModel? saved;
      final dropdown = find.byKey(const ValueKey('playbackSettingsQueueEnd'));

      Future<void> pump(
        WidgetTester tester, {
        required bool startAgain,
        AppSettingsModel? afterReset,
      }) async {
        setAdaptiveTestViewport(tester, const Size(1280, 1400));
        saved = null;
        when(() => repository.getSettings())
            .thenAnswer((_) async => afterReset ?? initialSettings);
        when(() => repository.saveSettings(any()))
            .thenAnswer((invocation) async {
              saved = invocation.positionalArguments.first as AppSettingsModel;
            });
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              replayGainLibraryGainsProvider.overrideWith(
                (ref) async => (count: 0, median: null, total: 0, withData: 0),
              ),
              settingsRepositoryProvider.overrideWithValue(repository),
              appSettingsProvider.overrideWithValue(
                AsyncData(
                  initialSettings.copyWith(queueEndStartAgain: startAgain),
                ),
              ),
              playbackAdjustmentsProvider.overrideWith(_FakeAdjustments.new),
              equalizerProvider.overrideWith(_FakeEq.new),
            ],
            child: _buildTestApp(desktopMode: true),
          ),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(dropdown);
      }

      testWidgets('shows Start again from the top by default', (tester) async {
        await pump(tester, startAgain: true);
        expect(
          find.descendant(
            of: dropdown,
            matching: find.text('Start again from the top'),
          ),
          findsOneWidget,
        );
        expect(find.text('When the queue ends'), findsOneWidget);
      });

      testWidgets('choosing Stop autosaves it', (tester) async {
        await pump(tester, startAgain: true);
        await tester.tap(dropdown);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Stop').last);
        await tester.pumpAndSettle(const Duration(milliseconds: 500));
        expect(saved?.queueEndStartAgain, isFalse);
      });

      testWidgets('Reset Defaults restores Start again from the top', (
        tester,
      ) async {
        await pump(
          tester,
          startAgain: false,
          afterReset: initialSettings.copyWith(queueEndStartAgain: true),
        );
        expect(
          find.descendant(of: dropdown, matching: find.text('Stop')),
          findsOneWidget,
        );
        final resetDefaults = find.text('Reset Defaults');
        await tester.ensureVisible(resetDefaults);
        await tester.pumpAndSettle();
        await tester.tap(resetDefaults);
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: dropdown,
            matching: find.text('Start again from the top'),
          ),
          findsOneWidget,
        );
      });
    });

    group('prefetch next song on mobile data', () {
      const title = 'Prefetch the next song on mobile data';
      AppSettingsModel? saved;

      Future<Finder> pumpToggle(
        WidgetTester tester, {
        required bool enabled,
      }) async {
        setAdaptiveTestViewport(tester, const Size(1280, 1000));
        saved = null;
        when(() => repository.saveSettings(any()))
            .thenAnswer((invocation) async {
              saved = invocation.positionalArguments.first as AppSettingsModel;
            });
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              replayGainLibraryGainsProvider.overrideWith(
                (ref) async => (count: 0, median: null, total: 0, withData: 0),
              ),
              settingsRepositoryProvider.overrideWithValue(repository),
              appSettingsProvider.overrideWithValue(
                AsyncData(
                  initialSettings.copyWith(prefetchNextOnMobileData: enabled),
                ),
              ),
            ],
            child: _buildTestApp(desktopMode: true),
          ),
        );
        await tester.pumpAndSettle();
        final toggle = find.widgetWithText(SwitchListTile, title);
        await tester.ensureVisible(toggle);
        await tester.pumpAndSettle();
        return toggle;
      }

      testWidgets('is on by default', (tester) async {
        final toggle = await pumpToggle(tester, enabled: true);
        expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
        expect(
          const AppSettingsModel.defaults().prefetchNextOnMobileData,
          isTrue,
        );
      });

      testWidgets('turning it off asks first', (tester) async {
        final toggle = await pumpToggle(tester, enabled: true);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(find.text('Turn off prefetching?'), findsOneWidget);
        expect(find.text('Turn off'), findsOneWidget);
      });

      testWidgets('Cancel keeps it on', (tester) async {
        final toggle = await pumpToggle(tester, enabled: true);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle(const Duration(milliseconds: 500));
        expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
        expect(saved, isNull);
      });

      testWidgets('confirming turns it off', (tester) async {
        final toggle = await pumpToggle(tester, enabled: true);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Turn off'));
        await tester.pumpAndSettle(const Duration(milliseconds: 500));
        expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
        expect(saved?.prefetchNextOnMobileData, isFalse);
      });

      testWidgets('turning it on needs no dialog', (tester) async {
        final toggle = await pumpToggle(tester, enabled: false);
        await tester.tap(toggle);
        await tester.pumpAndSettle(const Duration(milliseconds: 500));
        expect(find.text('Turn off prefetching?'), findsNothing);
        expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
        expect(saved?.prefetchNextOnMobileData, isTrue);
      });
    });

    testWidgets('desktop playback settings keep a Settings return path', (
      tester,
    ) async {
      setAdaptiveTestViewport(tester, const Size(1280, 800));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            replayGainLibraryGainsProvider.overrideWith(
              (ref) async => (count: 0, median: null, total: 0, withData: 0),
            ),
            settingsRepositoryProvider.overrideWithValue(repository),
            appSettingsProvider.overrideWithValue(
              const AsyncData(initialSettings),
            ),
          ],
          child: _buildTestApp(desktopMode: true),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byTooltip('Back'), findsOneWidget);
      expect(find.text('Wi-Fi Streaming'), findsOneWidget);
    });

    testWidgets('autosave persists values and reset triggers defaults', (
      tester,
    ) async {
      AppSettingsModel? savedModel;
      when(() => repository.saveSettings(any())).thenAnswer((invocation) async {
        savedModel = invocation.positionalArguments.first as AppSettingsModel;
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            replayGainLibraryGainsProvider.overrideWith(
              (ref) async => (count: 0, median: null, total: 0, withData: 0),
            ),
            settingsRepositoryProvider.overrideWithValue(repository),
            appSettingsProvider.overrideWithValue(
              const AsyncData(initialSettings),
            ),
          ],
          child: _buildTestApp(),
        ),
      );
      await tester.pumpAndSettle();

      await _tapVisible(
        tester,
        find.byType(DropdownButtonFormField<int?>).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('320 kbps').last);
      await tester.pumpAndSettle();

      await _tapVisible(
        tester,
        find.byType(DropdownButtonFormField<String?>).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('OPUS').last);
      await tester.pumpAndSettle();

      final scrobbleToggle = find.widgetWithText(
        SwitchListTile,
        'Enable Scrobbling',
      );
      final cachedFirstToggle = find.widgetWithText(
        SwitchListTile,
        'Play Cached Copies at Any Quality',
      );
      final gaplessToggle = find.widgetWithText(
        SwitchListTile,
        'Enable Gapless Playback',
      );

      await tester.ensureVisible(cachedFirstToggle);
      await tester.pumpAndSettle();
      await tester.tap(cachedFirstToggle);
      await tester.pumpAndSettle();
      await tester.ensureVisible(scrobbleToggle);
      await tester.pumpAndSettle();
      await tester.tap(scrobbleToggle);
      await tester.pumpAndSettle();
      await tester.ensureVisible(gaplessToggle);
      await tester.pumpAndSettle();
      await tester.tap(gaplessToggle);
      await tester.pumpAndSettle();

      // Autosave is debounced in the UI.
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();

      verify(() => repository.saveSettings(any())).called(greaterThan(0));
      expect(savedModel, isNotNull);
      expect(savedModel!.wifiMaxBitRate, 320);
      expect(savedModel!.wifiFormat, 'opus');
      expect(savedModel!.cachedPlaybackFirst, isTrue);
      expect(savedModel!.scrobbleEnabled, isFalse);
      expect(savedModel!.gaplessEnabled, isFalse);
      expect(savedModel!.skipSilenceEnabled, isFalse);
      // showRadioPage, showPlaylistsPage, showArtistsPage are now read from
      // their respective providers (managed in Appearance settings).
      expect(savedModel!.showRadioPage, isTrue);

      final resetDefaults = find.text('Reset Defaults');
      await tester.ensureVisible(resetDefaults);
      await tester.pumpAndSettle();
      await tester.tap(resetDefaults);
      await tester.pumpAndSettle();

      verify(() => repository.resetPlaybackDefaults()).called(1);
      expect(tester.takeException(), isNull);
    });

    group('reset vs autosave', () {
      late AppSettingsModel stored;
      late List<String> events;
      Completer<void>? saveGate;

      setUp(() {
        stored = initialSettings;
        events = <String>[];
        saveGate = null;
        when(() => repository.getSettings()).thenAnswer((_) async => stored);
        when(() => repository.saveSettings(any()))
            .thenAnswer((invocation) async {
              events.add('save:begin');
              await saveGate?.future;
              stored = invocation.positionalArguments.first as AppSettingsModel;
              events.add('save:end');
            });
        when(() => repository.resetPlaybackDefaults()).thenAnswer((_) async {
          events.add('reset');
          stored = initialSettings;
        });
      });

      Future<void> pumpScreen(WidgetTester tester) async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              replayGainLibraryGainsProvider.overrideWith(
                (ref) async => (count: 0, median: null, total: 0, withData: 0),
              ),
              settingsRepositoryProvider.overrideWithValue(repository),
              appSettingsProvider.overrideWithValue(
                const AsyncData(initialSettings),
              ),
              playbackAdjustmentsProvider.overrideWith(_FakeAdjustments.new),
              equalizerProvider.overrideWith(_FakeEq.new),
            ],
            child: _buildTestApp(),
          ),
        );
        await tester.pumpAndSettle();
      }

      Future<void> editWifiBitRate(WidgetTester tester) async {
        await _tapVisible(
          tester,
          find.byType(DropdownButtonFormField<int?>).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('320 kbps').last);
        // No settle: the 420 ms autosave debounce stays pending.
        await tester.pump(const Duration(milliseconds: 50));
      }

      Future<void> tapReset(WidgetTester tester) async {
        final resetDefaults = find.text('Reset Defaults');
        await tester.ensureVisible(resetDefaults);
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tap(resetDefaults);
      }

      testWidgets('reset cancels a pending autosave and shows persisted '
          'defaults', (tester) async {
        await pumpScreen(tester);
        await editWifiBitRate(tester);

        await tapReset(tester);
        await tester.pump(const Duration(seconds: 2));
        await tester.pumpAndSettle();

        expect(events, ['reset']);
        expect(stored.wifiMaxBitRate, initialSettings.wifiMaxBitRate);
        final wifiField = tester.widget<DropdownButtonFormField<int?>>(
          find.byType(DropdownButtonFormField<int?>).first,
        );
        expect(wifiField.initialValue, initialSettings.wifiMaxBitRate);
      });

      testWidgets('reset waits for an in-flight autosave and is not '
          'overwritten by it', (tester) async {
        saveGate = Completer<void>();
        await pumpScreen(tester);
        await editWifiBitRate(tester);
        await tester.pump(const Duration(milliseconds: 500));
        expect(events, ['save:begin']);

        await tapReset(tester);
        await tester.pump(const Duration(milliseconds: 100));
        expect(events, ['save:begin'], reason: 'reset must wait for the save');

        saveGate!.complete();
        await tester.pump(const Duration(seconds: 2));
        await tester.pumpAndSettle();

        expect(events, ['save:begin', 'save:end', 'reset']);
        expect(stored.wifiMaxBitRate, initialSettings.wifiMaxBitRate);
        final wifiField = tester.widget<DropdownButtonFormField<int?>>(
          find.byType(DropdownButtonFormField<int?>).first,
        );
        expect(wifiField.initialValue, initialSettings.wifiMaxBitRate);
      });
      testWidgets('leaving the page while a save drains still resets', (
        tester,
      ) async {
        saveGate = Completer<void>();
        final showScreen = ValueNotifier<bool>(true);
        addTearDown(showScreen.dispose);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              replayGainLibraryGainsProvider.overrideWith(
                (ref) async => (count: 0, median: null, total: 0, withData: 0),
              ),
              settingsRepositoryProvider.overrideWithValue(repository),
              appSettingsProvider.overrideWithValue(
                const AsyncData(initialSettings),
              ),
              playbackAdjustmentsProvider.overrideWith(_FakeAdjustments.new),
              equalizerProvider.overrideWith(_FakeEq.new),
            ],
            // The app-level scope outlives the page, as in navigation.
            child: ValueListenableBuilder<bool>(
              valueListenable: showScreen,
              builder: (_, show, _) =>
                  show ? _buildTestApp() : const SizedBox.shrink(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await editWifiBitRate(tester);
        await tester.pump(const Duration(milliseconds: 500));
        expect(events, ['save:begin']);

        await tapReset(tester);
        await tester.pump(const Duration(milliseconds: 100));
        showScreen.value = false;
        await tester.pump();

        saveGate!.complete();
        await tester.pump(const Duration(seconds: 2));
        await tester.pumpAndSettle();

        expect(events, ['save:begin', 'save:end', 'reset']);
        expect(tester.takeException(), isNull);
      });
    });

    testWidgets('fullscreen lyrics switch persists and is shown', (
      tester,
    ) async {
      AppSettingsModel? savedModel;
      when(() => repository.saveSettings(any())).thenAnswer((invocation) async {
        savedModel = invocation.positionalArguments.first as AppSettingsModel;
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            replayGainLibraryGainsProvider.overrideWith(
              (ref) async => (count: 0, median: null, total: 0, withData: 0),
            ),
            settingsRepositoryProvider.overrideWithValue(repository),
            appSettingsProvider.overrideWithValue(
              const AsyncData(initialSettings),
            ),
          ],
          child: _buildTestApp(),
        ),
      );
      await tester.pumpAndSettle();

      final fullscreenToggle = find.widgetWithText(
        SwitchListTile,
        'Fullscreen Mode Lyrics',
      );
      await tester.ensureVisible(fullscreenToggle);
      await tester.pumpAndSettle();
      await tester.tap(fullscreenToggle);
      await tester.pump(); // build schedules the debounce
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();

      expect(savedModel?.skipSilenceEnabled, isTrue);
    });

    testWidgets('autosave preserves settings owned by other screens', (
      tester,
    ) async {
      final storedSettings = initialSettings.copyWith(
        wifiMaxBitRate: 256,
        wifiFormat: 'opus',
        showRadioPage: false,
        backgroundSyncUnmeteredOnly: false,
        listenBrainzScrobblingEnabled: true,
        listenBrainzTokenValid: true,
        listenBrainzUserName: 'navis-listener',
        desktopPlaybackVolume: 0.4,
        desktopLastAudibleVolume: 0.6,
        playbackPitchSemitones: 2,
        lockPitchToSpeed: true,
        selectedPlaybackPresetId: 'preset-1',
      );
      AppSettingsModel? savedModel;
      when(() => repository.saveSettings(any())).thenAnswer((invocation) async {
        savedModel = invocation.positionalArguments.first as AppSettingsModel;
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            replayGainLibraryGainsProvider.overrideWith(
              (ref) async => (count: 0, median: null, total: 0, withData: 0),
            ),
            settingsRepositoryProvider.overrideWithValue(repository),
            appSettingsProvider.overrideWithValue(AsyncData(storedSettings)),
          ],
          child: _buildTestApp(),
        ),
      );
      await tester.pumpAndSettle();

      final scrobbleToggle = find.widgetWithText(
        SwitchListTile,
        'Enable Scrobbling',
      );
      await tester.ensureVisible(scrobbleToggle);
      await tester.pumpAndSettle();
      await tester.tap(scrobbleToggle);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();

      expect(savedModel, isNotNull);
      expect(savedModel!.scrobbleEnabled, isFalse);
      expect(savedModel!.wifiMaxBitRate, 256);
      expect(savedModel!.wifiFormat, 'opus');
      expect(savedModel!.showRadioPage, isFalse);
      expect(savedModel!.backgroundSyncUnmeteredOnly, isFalse);
      expect(savedModel!.listenBrainzScrobblingEnabled, isTrue);
      expect(savedModel!.listenBrainzTokenValid, isTrue);
      expect(savedModel!.listenBrainzUserName, 'navis-listener');
      expect(savedModel!.desktopPlaybackVolume, 0.4);
      expect(savedModel!.desktopLastAudibleVolume, 0.6);
      expect(savedModel!.playbackPitchSemitones, 2);
      expect(savedModel!.lockPitchToSpeed, isTrue);
      expect(savedModel!.selectedPlaybackPresetId, 'preset-1');
      expect(tester.takeException(), isNull);
    });

    testWidgets('autosave clears wifi limits reset to original quality', (
      tester,
    ) async {
      AppSettingsModel? savedModel;
      when(() => repository.saveSettings(any())).thenAnswer((invocation) async {
        savedModel = invocation.positionalArguments.first as AppSettingsModel;
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            replayGainLibraryGainsProvider.overrideWith(
              (ref) async => (count: 0, median: null, total: 0, withData: 0),
            ),
            settingsRepositoryProvider.overrideWithValue(repository),
            appSettingsProvider.overrideWithValue(
              AsyncData(
                initialSettings.copyWith(
                  wifiMaxBitRate: 256,
                  wifiFormat: 'opus',
                ),
              ),
            ),
          ],
          child: _buildTestApp(),
        ),
      );
      await tester.pumpAndSettle();

      await _tapVisible(
        tester,
        find.byType(DropdownButtonFormField<int?>).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Original Quality').last);
      await tester.pumpAndSettle();
      await _tapVisible(
        tester,
        find.byType(DropdownButtonFormField<String?>).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Server Default').last);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();

      expect(savedModel, isNotNull);
      expect(savedModel!.wifiMaxBitRate, isNull);
      expect(savedModel!.wifiFormat, isNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('autosave persists Vorbis as a streaming transcode format', (
      tester,
    ) async {
      AppSettingsModel? savedModel;
      when(() => repository.saveSettings(any())).thenAnswer((invocation) async {
        savedModel = invocation.positionalArguments.first as AppSettingsModel;
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            replayGainLibraryGainsProvider.overrideWith(
              (ref) async => (count: 0, median: null, total: 0, withData: 0),
            ),
            settingsRepositoryProvider.overrideWithValue(repository),
            appSettingsProvider.overrideWithValue(
              const AsyncData(initialSettings),
            ),
          ],
          child: _buildTestApp(),
        ),
      );
      await tester.pumpAndSettle();

      await _tapVisible(
        tester,
        find.byType(DropdownButtonFormField<String?>).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('VORBIS').last);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();

      expect(savedModel, isNotNull);
      expect(savedModel!.wifiFormat, 'vorbis');
      expect(tester.takeException(), isNull);
    });

    testWidgets('cross-fade controls depend on gapless playback', (
      tester,
    ) async {
      AppSettingsModel? savedModel;
      when(() => repository.saveSettings(any())).thenAnswer((invocation) async {
        savedModel = invocation.positionalArguments.first as AppSettingsModel;
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            replayGainLibraryGainsProvider.overrideWith(
              (ref) async => (count: 0, median: null, total: 0, withData: 0),
            ),
            settingsRepositoryProvider.overrideWithValue(repository),
            appSettingsProvider.overrideWithValue(
              AsyncData(initialSettings.copyWith(gaplessEnabled: false)),
            ),
          ],
          child: _buildTestApp(),
        ),
      );
      await tester.pumpAndSettle();

      final gaplessToggle = find.widgetWithText(
        SwitchListTile,
        'Enable Gapless Playback',
      );
      const crossfadeText = 'Enable Cross-Fade';
      final fullscreenToggle = find.widgetWithText(
        SwitchListTile,
        'Fullscreen Mode Lyrics',
      );

      expect(find.widgetWithText(SwitchListTile, crossfadeText), findsNothing);

      await tester.ensureVisible(gaplessToggle);
      await tester.pumpAndSettle();
      await tester.tap(gaplessToggle);
      await tester.pumpAndSettle();

      final crossfadeToggle = find.widgetWithText(
        SwitchListTile,
        crossfadeText,
      );
      expect(crossfadeToggle, findsOneWidget);
      expect(fullscreenToggle, findsOneWidget);
      expect(
        tester.getTopLeft(crossfadeToggle).dy,
        lessThan(tester.getTopLeft(fullscreenToggle).dy),
      );

      await tester.ensureVisible(crossfadeToggle);
      await tester.pumpAndSettle();
      await tester.tap(crossfadeToggle);
      await tester.pumpAndSettle();

      final gaplessTile = tester.widget<SwitchListTile>(gaplessToggle);
      expect(gaplessTile.value, isTrue);
      expect(find.textContaining('These features conflict'), findsNothing);

      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();

      expect(savedModel, isNotNull);
      expect(savedModel!.crossfadeEnabled, isTrue);
      expect(savedModel!.gaplessEnabled, isTrue);
    });

    testWidgets('integration switches and the Equalizer are not on Playback', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            replayGainLibraryGainsProvider.overrideWith(
              (ref) async => (count: 0, median: null, total: 0, withData: 0),
            ),
            settingsRepositoryProvider.overrideWithValue(repository),
            appSettingsProvider.overrideWithValue(
              const AsyncData(initialSettings),
            ),
          ],
          child: _buildTestApp(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('LRCLIB'), findsNothing);
      expect(find.textContaining('Same Vibes'), findsNothing);
      expect(find.text('Server Mix'), findsNothing);
      // Settings › Equalizer is the single settings entry for it.
      expect(find.byType(EqualizerEntry), findsNothing);
    });

    testWidgets('autosave cannot revert a choice made in Integrations', (
      tester,
    ) async {
      final settings = StreamController<AppSettingsModel>();
      addTearDown(settings.close);
      AppSettingsModel? savedModel;
      when(() => repository.saveSettings(any())).thenAnswer((invocation) async {
        savedModel = invocation.positionalArguments.first as AppSettingsModel;
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            replayGainLibraryGainsProvider.overrideWith(
              (ref) async => (count: 0, median: null, total: 0, withData: 0),
            ),
            settingsRepositoryProvider.overrideWithValue(repository),
            appSettingsProvider.overrideWith((_) => settings.stream),
          ],
          child: _buildTestApp(),
        ),
      );
      settings.add(initialSettings);
      await tester.pumpAndSettle();

      // Integrations switches LRCLIB, Same Vibes and automatic update checks
      // off while Playback is open.
      settings.add(
        initialSettings.copyWith(
          useLrclib: false,
          legacyInstantMixEnabled: true,
          updateCheckEnabled: false,
        ),
      );
      await tester.pumpAndSettle();

      final scrobbleToggle = find.widgetWithText(
        SwitchListTile,
        'Enable Scrobbling',
      );
      await tester.ensureVisible(scrobbleToggle);
      await tester.pumpAndSettle();
      await tester.tap(scrobbleToggle);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();

      expect(savedModel, isNotNull);
      expect(savedModel!.scrobbleEnabled, isFalse);
      expect(savedModel!.useLrclib, isFalse);
      expect(savedModel!.legacyInstantMixEnabled, isTrue);
      expect(savedModel!.updateCheckEnabled, isFalse);
      expect(tester.takeException(), isNull);
    });
  });
}

/// Scrolls [target] into view and lets the layout settle before it is tapped:
/// the Playback page is longer than the default test viewport.
Future<void> _tapVisible(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
}

Widget _buildTestApp({
  bool desktopMode = false,
  double textScale = 1,
  bool focusReplayGain = false,
}) {
  return MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    theme: testTheme(),
    localizationsDelegates: navisLocalizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: desktopMode
        ? AdaptiveContextScope(
            adaptiveContext: resolveAdaptiveContext(
              desktopRuntime: true,
              viewportSize: const Size(1280, 800),
              safePadding: EdgeInsets.zero,
            ),
            child: PlaybackSettingsScreen(focusReplayGain: focusReplayGain),
          )
        : PlaybackSettingsScreen(focusReplayGain: focusReplayGain),
  );
}

class _BoostHandler extends InertPlaybackHandler {
  /// How many times the settings were applied to the player, across handlers.
  static int applied = 0;

  @override
  bool get replayGainBoostSupported => true;

  @override
  Future<void> applyRuntimeSettings() async => applied++;
}

class _LimiterHandler extends _BoostHandler {
  @override
  bool get replayGainLimiterSupported => true;
}
