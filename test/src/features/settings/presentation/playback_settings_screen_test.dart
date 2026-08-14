import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/settings/data/settings_repository.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/features/settings/presentation/playback_settings_screen.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';

import '../../../../helpers/adaptive_test_harness.dart';
import '../../../../helpers/test_theme.dart';

class _MockSettingsRepository extends Mock implements SettingsRepository {}

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
      equalizerEnabled: false,
      equalizerBandGains: <double>[],
      loudnessEnabled: false,
      loudnessTargetGainDb: 0,
      wifiOnlyDownloads: false,
      autoDownloadStarredOnWifi: false,
      customDownloadFolderEnabled: false,
      customDownloadFolderPath: null,
      themeMode: 'dark',
      colorSchemeSeed: null,
      appLocale: null,
      crossfadeEnabled: false,
      crossfadeDurationSeconds: 5,
      crossfadeType: 'normal',
      artTintedNowPlaying: true,
      dynamicAlbumColorEnabled: false,
      updateCheckEnabled: true,
      updateChannel: 'stable',
      audioMuseServerUrl: null,
      audioMuseApiKey: null,
      audioMuseEnabled: false,
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
      when(() => repository.resetDefaults()).thenAnswer((_) async {});
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

      expect(find.text('Wi-Fi streaming'), findsOneWidget);
      expect(find.text('Cellular streaming'), findsOneWidget);
      expect(find.text('Cached First'), findsOneWidget);
      expect(find.text('Enable scrobbling'), findsOneWidget);
      expect(find.text('Enable gapless playback'), findsOneWidget);
      expect(find.text('Show Radio page'), findsNothing);
      expect(find.text('Skip silence when possible'), findsNothing);
      expect(find.text('Changes save automatically'), findsOneWidget);
      expect(find.text('Reset defaults'), findsOneWidget);
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

      expect(find.byTooltip('Back to Settings'), findsOneWidget);
      expect(find.text('Wi-Fi streaming'), findsOneWidget);
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
        'Enable scrobbling',
      );
      final cachedFirstToggle = find.widgetWithText(
        SwitchListTile,
        'Cached First',
      );
      final gaplessToggle = find.widgetWithText(
        SwitchListTile,
        'Enable gapless playback',
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

      final resetDefaults = find.text('Reset defaults');
      await tester.ensureVisible(resetDefaults);
      await tester.pumpAndSettle();
      await tester.tap(resetDefaults);
      await tester.pumpAndSettle();

      verify(() => repository.resetDefaults()).called(1);
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
        'Enable gapless playback',
      );
      const crossfadeText = 'Enable cross-fade';
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
      expect(
        find.textContaining('These features conflict'),
        findsNothing,
      );

      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();

      expect(savedModel, isNotNull);
      expect(savedModel!.crossfadeEnabled, isTrue);
      expect(savedModel!.gaplessEnabled, isTrue);
    });

    testWidgets('legacy instant mix persists when leaving before debounce', (
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
            lastFmApiKeyProvider.overrideWithValue('test-key'),
            appSettingsProvider.overrideWithValue(
              const AsyncData(initialSettings),
            ),
          ],
          child: _buildTestApp(),
        ),
      );
      await tester.pumpAndSettle();

      final legacyToggle = find.widgetWithText(
        SwitchListTile,
        'Legacy Instant Mix',
      );
      await tester.ensureVisible(legacyToggle);
      await tester.pumpAndSettle();
      await tester.tap(legacyToggle);
      await tester.pump();

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();

      verify(() => repository.saveSettings(any())).called(greaterThan(0));
      expect(savedModel, isNotNull);
      expect(savedModel!.legacyInstantMixEnabled, isTrue);
      expect(tester.takeException(), isNull);
    });
  });
}

Widget _buildTestApp({bool desktopMode = false}) {
  return MaterialApp(
    theme: testTheme(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
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
