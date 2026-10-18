import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/features/equalizer/presentation/eq_entry.dart';
import 'package:navis/src/features/equalizer/domain/eq_configuration.dart';
import 'package:navis/src/features/equalizer/presentation/eq_controller.dart';
import 'package:navis/src/features/player/presentation/playback_adjustment_controller.dart';
import 'package:navis/src/features/settings/data/settings_repository.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/features/settings/presentation/playback_settings_screen.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';

import '../../../../helpers/adaptive_test_harness.dart';
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

    testWidgets('desktop playback settings keep a Settings return path', (
      tester,
    ) async {
      setAdaptiveTestViewport(tester, const Size(1280, 800));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
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
            settingsRepositoryProvider.overrideWithValue(repository),
            appSettingsProvider.overrideWithValue(
              const AsyncData(initialSettings),
            ),
          ],
          child: _buildTestApp(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(DropdownButtonFormField<int?>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('320 kbps').last);
      await tester.pumpAndSettle();

      await tester.tap(find.byType(DropdownButtonFormField<String?>).first);
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
        await tester.tap(find.byType(DropdownButtonFormField<int?>).first);
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

      await tester.tap(find.byType(DropdownButtonFormField<int?>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Original Quality').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String?>).first);
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
            settingsRepositoryProvider.overrideWithValue(repository),
            appSettingsProvider.overrideWithValue(
              const AsyncData(initialSettings),
            ),
          ],
          child: _buildTestApp(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(DropdownButtonFormField<String?>).first);
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

Widget _buildTestApp({bool desktopMode = false}) {
  return MaterialApp(
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
            child: const PlaybackSettingsScreen(),
          )
        : const PlaybackSettingsScreen(),
  );
}
