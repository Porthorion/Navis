import 'package:flutter/foundation.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/features/player/presentation/playback_recovery_provider.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/database/daos/network_usage_dao.dart';
import 'package:navis/src/features/settings/data/settings_repository.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/features/settings/domain/update_delivery.dart';
import 'package:navis/src/features/settings/domain/update_info.dart';
import 'package:navis/src/features/settings/presentation/about_screen.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../../../helpers/adaptive_test_harness.dart';
import '../../../../helpers/fake_url_launcher.dart';

class _MockSettingsRepository extends Mock implements SettingsRepository;

class _CopyRecovery extends Fake implements PlaybackRecoveryService {
  int copies = 0;
  @override
  Future<void> copyDetails() async => copies++;
}

void main() {
  setUpAll(() {
    registerFallbackValue(const AppSettingsModel.defaults());
  });

  group('AboutScreen update controls', () {
    late _MockSettingsRepository repository;

    const settings = AppSettingsModel(
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
    });

    Future<void> pumpAbout(
      WidgetTester tester, {
      required UpdateInfo? updateInfo,
      bool desktopMode = false,
      TextScaler? textScaler,
      AppSettingsModel? storedSettings,
      PlaybackRecoveryService? recovery,
      AppNoticeController? notices,
      bool updateFails = false,
    }) async {
      await tester.binding.setSurfaceSize(
        desktopMode ? const Size(1280, 800) : const Size(900, 1200),
      );
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            if (recovery != null)
              playbackRecoveryServiceProvider.overrideWithValue(recovery),
            settingsRepositoryProvider.overrideWithValue(repository),
            appSettingsProvider.overrideWith(
              (ref) => Stream.value(storedSettings ?? settings),
            ),
            packageInfoProvider.overrideWith(
              (ref) async => PackageInfo(
                appName: 'Navis',
                packageName: 'com.navis.app.navis',
                version: '1.0.0',
                buildNumber: '1',
              ),
            ),
            updateProvider.overrideWith((ref) async {
              if (updateFails) throw Exception('offline');
              return updateInfo;
            }),
            networkUsageTotalProvider(1).overrideWith(
              (ref) => Stream.value(
                const NetworkUsageTotal(bytes: 0, requestCount: 0),
              ),
            ),
            networkUsageTotalProvider(7).overrideWith(
              (ref) => Stream.value(
                const NetworkUsageTotal(bytes: 0, requestCount: 0),
              ),
            ),
            networkUsageTotalProvider(30).overrideWith(
              (ref) => Stream.value(
                const NetworkUsageTotal(bytes: 0, requestCount: 0),
              ),
            ),
            networkUsageCategoryTotalsProvider(7).overrideWith(
              (ref) => Stream.value(const <NetworkUsageCategoryTotal>[]),
            ),
          ],
          child: MaterialApp(
            localizationsDelegates: navisLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: textScaler == null
                ? null
                : (context, child) => MediaQuery(
                    data: MediaQuery.of(context)
                        .copyWith(textScaler: textScaler),
                    child: child!,
                  ),
            home: desktopMode
                ? AdaptiveContextScope(
                    adaptiveContext: resolveAdaptiveContext(
                      desktopRuntime: true,
                      viewportSize: const Size(1280, 800),
                      safePadding: EdgeInsets.zero,
                    ),
                    child: const AboutScreen(),
                  )
                : notices == null
                ? const AboutScreen()
                : AppNoticeScope(notifier: notices, child: const AboutScreen()),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets(
      'hidden version long-press copies startup details and shows an app notice',
      (tester) async {
        final recovery = _CopyRecovery();
        final notices = AppNoticeController();
        addTearDown(notices.dispose);
        await pumpAbout(
          tester,
          updateInfo: null,
          recovery: recovery,
          notices: notices,
        );
        await tester.longPress(
          find.byKey(const ValueKey<String>('about-startup-details')),
        );
        await tester.pump();
        expect(recovery.copies, 1);
        expect(notices.notice?.message, 'Startup details copied');
        notices.dismiss();
      },
    );

    testWidgets('a failed Check now shows an error notice and subtitle', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final notices = AppNoticeController();
      addTearDown(notices.dispose);
      try {
        await pumpAbout(
          tester,
          updateInfo: null,
          notices: notices,
          updateFails: true,
        );
        final l10n = lookupAppLocalizations(const Locale('en'));
        expect(find.text(l10n.updateCheckFailedSub), findsOneWidget);
        expect(notices.notice, isNull);

        await tester.tap(find.widgetWithText(ListTile, l10n.updateCheckTitle));
        await tester.pumpAndSettle();

        expect(notices.notice?.message, l10n.updateCheckFailed);
        expect(notices.notice?.level, AppNoticeLevel.error);
        expect(find.text(l10n.updateCheckFailedSub), findsOneWidget);
        notices.dismiss();
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('licence page receives the Porthorion copyright', (
      tester,
    ) async {
      LicenseRegistry.reset();
      addTearDown(LicenseRegistry.reset);
      await pumpAbout(tester, updateInfo: null);
      final l10n = lookupAppLocalizations(const Locale('en'));
      final licenses = find.widgetWithText(ListTile, l10n.aboutLicenses);
      await tester.ensureVisible(licenses);
      await tester.tap(licenses);
      await tester.pumpAndSettle();

      final page = tester.widget<LicensePage>(find.byType(LicensePage));
      expect(page.applicationLegalese, '© 2026 Porthorion');
      expect(find.text('© 2026 Porthorion'), findsOneWidget);
    });

    testWidgets(
      'links to the website, source, issues, support, policy and licence',
      (tester) async {
        final launcher = FakeUrlLauncher.install();
        await pumpAbout(tester, updateInfo: null);

        for (final title in <String>[
          'Website',
          'Source Code',
          'Report a Bug',
          'Contact Support',
          'Privacy Policy',
          'License',
        ]) {
          final tile = find.widgetWithText(ListTile, title);
          await tester.scrollUntilVisible(tile, 200);
          await tester.pumpAndSettle();
          await tester.tap(tile);
          await tester.pumpAndSettle();
        }

        expect(launcher.launched, <String>[
          'https://navis.porthorion.com',
          'https://github.com/Porthorion/Navis',
          'https://github.com/Porthorion/Navis/issues',
          'mailto:support@porthorion.com',
          'https://navis.porthorion.com/privacy/app',
          'https://github.com/Porthorion/Navis/blob/main/LICENSE',
        ]);
      },
    );

    testWidgets('shows update section on Android', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        await pumpAbout(tester, updateInfo: null);

        final l10n = lookupAppLocalizations(const Locale('en'));
        expect(find.text(l10n.updatesSettingsSectionLabel), findsOneWidget);
        expect(find.text(l10n.updateCheckTitle), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('the automatic check moved to Integrations', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        await pumpAbout(tester, updateInfo: null);

        expect(find.byType(SwitchListTile), findsNothing);
        expect(find.widgetWithText(ListTile, 'Integrations'), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    for (final entry in <String, ({AppSettingsModel stored, bool allowed})>{
      'only automatic checks are off': (
        stored: settings.copyWith(updateCheckEnabled: false),
        allowed: true,
      ),
      'update checks are off': (
        stored: settings.copyWith(disabledIntegrations: '["updates"]'),
        allowed: false,
      ),
      'Online services are off': (
        stored: settings.copyWith(externalIntegrationsEnabled: false),
        allowed: false,
      ),
    }.entries) {
      testWidgets('Check now follows the updates service when '
          '${entry.key}', (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        try {
          await pumpAbout(
            tester,
            updateInfo: null,
            storedSettings: entry.value.stored,
          );

          final l10n = lookupAppLocalizations(const Locale('en'));
          final checkNow = tester.widget<ListTile>(
            find.widgetWithText(ListTile, l10n.updateCheckTitle),
          );
          expect(checkNow.enabled, entry.value.allowed);
          expect(
            find.text('Update checks are off in Integrations.'),
            entry.value.allowed ? findsNothing : findsOneWidget,
          );
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }

    testWidgets('desktop About keeps a Settings return path', (tester) async {
      setAdaptiveTestViewport(tester, const Size(1280, 800));
      await pumpAbout(tester, updateInfo: null, desktopMode: true);

      expect(find.byTooltip('Back'), findsOneWidget);
      expect(find.text('Navis'), findsOneWidget);
    });

    testWidgets('wide desktop About uses the available canvas in columns', (
      tester,
    ) async {
      setAdaptiveTestViewport(tester, const Size(1280, 800));
      await pumpAbout(tester, updateInfo: null, desktopMode: true);

      final l10n = lookupAppLocalizations(const Locale('en'));
      final dataUsage = find.text(l10n.aboutDataUsageTitle);
      final licenses = find.text(l10n.aboutLicenses);

      expect(tester.getTopLeft(licenses).dx, greaterThan(700));
      expect(
        tester.getTopLeft(dataUsage).dx,
        lessThan(tester.getTopLeft(licenses).dx),
      );
    });

    testWidgets('wide desktop About remains usable at 200 percent text', (
      tester,
    ) async {
      setAdaptiveTestViewport(tester, const Size(1280, 800));
      await pumpAbout(
        tester,
        updateInfo: null,
        desktopMode: true,
        textScaler: const TextScaler.linear(2),
      );

      final l10n = lookupAppLocalizations(const Locale('en'));
      expect(find.text(l10n.aboutDataUsageTitle), findsOneWidget);
      expect(find.text(l10n.updateCheckTitle), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('shows Play Store action for store redirect updates', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        await pumpAbout(
          tester,
          updateInfo: const UpdateInfo(
            sha256: null,
            size: null,
            tagName: 'v2.0.0',
            htmlUrl: 'https://example.com/release',
            delivery: UpdateDelivery.storeRedirect,
          ),
        );

        final l10n = lookupAppLocalizations(const Locale('en'));
        expect(find.text(l10n.updateOpenPlayStore), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}
