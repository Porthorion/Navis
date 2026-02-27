import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/settings/data/settings_repository.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/features/settings/presentation/playback_settings_screen.dart';
import 'package:navis/src/providers/app_providers.dart';

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
      showRadioPage: true,
      showPlaylistsPage: true,
      showArtistsPage: true,
      equalizerEnabled: false,
      equalizerBandGains: <double>[],
      loudnessEnabled: false,
      loudnessTargetGainDb: 0,
      wifiOnlyDownloads: false,
      themeMode: 'dark',
      colorSchemeSeed: null,
      crossfadeEnabled: false,
      crossfadeDurationSeconds: 5,
      crossfadeType: 'normal',
      artTintedNowPlaying: true,
      updateCheckEnabled: true,
      updateChannel: 'stable',
      audioMuseServerUrl: null,
      audioMuseApiKey: null,
      audioMuseEnabled: false,
      syncIntervalMinutes: 60,
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
      expect(find.text('Enable scrobbling'), findsOneWidget);
      expect(find.text('Enable gapless playback'), findsOneWidget);
      expect(find.text('Show Radio page'), findsNothing);
      expect(find.text('Skip silence when possible'), findsNothing);
      expect(find.text('Save'), findsOneWidget);
      expect(find.text('Reset defaults'), findsOneWidget);
    });

    testWidgets('save persists values and reset triggers defaults', (
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
      final gaplessToggle = find.widgetWithText(
        SwitchListTile,
        'Enable gapless playback',
      );

      await tester.ensureVisible(scrobbleToggle);
      await tester.pumpAndSettle();
      await tester.tap(scrobbleToggle);
      await tester.pumpAndSettle();
      await tester.ensureVisible(gaplessToggle);
      await tester.pumpAndSettle();
      await tester.tap(gaplessToggle);
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Save'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      verify(() => repository.saveSettings(any())).called(1);
      expect(savedModel, isNotNull);
      expect(savedModel!.wifiMaxBitRate, 320);
      expect(savedModel!.wifiFormat, 'opus');
      expect(savedModel!.scrobbleEnabled, isFalse);
      expect(savedModel!.gaplessEnabled, isFalse);
      expect(savedModel!.skipSilenceEnabled, isFalse);
      // showRadioPage, showPlaylistsPage, showArtistsPage are now read from
      // their respective providers (managed in Appearance settings).
      expect(savedModel!.showRadioPage, isTrue);
      expect(find.text('Playback settings saved.'), findsOneWidget);

      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView), const Offset(0, -300));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reset defaults'));
      await tester.pumpAndSettle();

      verify(() => repository.resetDefaults()).called(1);
      expect(find.text('Playback settings reset to defaults.'), findsOneWidget);
    });
  });
}

Widget _buildTestApp() {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: const PlaybackSettingsScreen(),
  );
}
