import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/features/settings/data/settings_repository.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/features/settings/presentation/playback_settings_screen.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';

import '../../../../helpers/adaptive_test_harness.dart';
import '../../../../helpers/test_theme.dart';

class _MockSettingsRepository extends Mock implements SettingsRepository;

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

      expect(find.text('Wi-Fi Streaming'), findsOneWidget);
      expect(find.text('Cellular Streaming'), findsOneWidget);
      expect(find.text('Cached First'), findsOneWidget);
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
        'Cached First',
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

      verify(() => repository.resetDefaults()).called(1);
      expect(tester.takeException(), isNull);
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
      await tester.tap(find.text('Original quality').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String?>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Server default').last);
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
        'Last.fm · Same Vibes',
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

    for (final locked in <String, AppSettingsModel>{
      'the master switch is off': initialSettings.copyWith(
        externalIntegrationsEnabled: false,
      ),
      'the Last.fm service is off': initialSettings.copyWith(
        disabledIntegrations: '["lastfm"]',
      ),
    }.entries) {
      testWidgets('autosave while ${locked.key} keeps Same Vibes reversible', (
        tester,
      ) async {
        AppSettingsModel? savedModel;
        when(() => repository.saveSettings(any())).thenAnswer((
          invocation,
        ) async {
          savedModel = invocation.positionalArguments.first as AppSettingsModel;
        });

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              settingsRepositoryProvider.overrideWithValue(repository),
              lastFmApiKeyProvider.overrideWithValue('test-key'),
              appSettingsProvider.overrideWithValue(AsyncData(locked.value)),
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
        // The lock must not rewrite storage as Server Mix.
        expect(savedModel!.legacyInstantMixEnabled, isFalse);
        // Switching the integrations back on finds Same Vibes still on.
        final reopened = integrationPolicyFromSettings(
          savedModel!.copyWith(
            externalIntegrationsEnabled: true,
            disabledIntegrations: '[]',
          ),
          lastFmVerified: true,
        );
        expect(reopened.allows(IntegrationFeature.lastFmSameVibes), isTrue);
        expect(tester.takeException(), isNull);
      });
    }
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
