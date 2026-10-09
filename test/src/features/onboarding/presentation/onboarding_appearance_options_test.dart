import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/common_widgets/new_feature_tag.dart';
import 'package:navis/src/database/daos/app_settings_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/onboarding/presentation/onboarding_provider.dart';
import 'package:navis/src/features/onboarding/presentation/onboarding_screen.dart';
import 'package:navis/src/features/settings/data/external_scrobble_credentials.dart';
import 'package:navis/src/features/settings/presentation/color_style_selector.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/app_routes.dart';
import 'package:navis/src/theme/navis_color_style.dart';
import 'package:navis/src/theme/navis_corner_style.dart';
import 'package:navis/src/theme/navis_shape_data.dart';
import 'package:navis/src/theme/navis_theme.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../../../helpers/adaptive_test_harness.dart';
import '../../../../helpers/test_database.dart';

class _MemoryCredentialStore implements ExternalScrobbleCredentialStore {
  @override
  Future<void> clearListenBrainzToken() async {}

  @override
  Future<String?> readListenBrainzToken() async => null;

  @override
  Future<void> saveListenBrainzToken(String value) async {}
}

class _Harness {
  const new(this.tester, this.database);

  final WidgetTester tester;
  final NavisDatabase database;

  Future<AppSettingsTableData> row() async =>
      (await tester.runAsync(database.appSettingsDao.getSettings))!;

  Future<void> settle() async {
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
  }

  Future<void> tap(Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    await settle();
  }

  Future<void> finish() async {
    for (var step = 0; step < 3; step++) {
      await tap(find.text('Continue'));
    }
    await tap(find.text('Finish'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 300));
    await settle();
  }

  Future<void> skip() async {
    await tap(find.text('Skip setup'));
    await tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Skip setup'),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 300));
    await settle();
  }

  ThemeData get previewTheme =>
      Theme.of(tester.element(find.byType(ColorStyleSelector)));
}

/// [updatedUser] seeds a completed setup, as for someone updating the app.
Future<_Harness> _pump(
  WidgetTester tester, {
  bool updatedUser = true,
  bool reviewMode = true,
  Future<void> Function(AppSettingsDao dao)? seed,
}) async {
  setAdaptiveTestViewport(tester, const Size(500, 2400));
  final database = createTestDatabase();
  await tester.runAsync(() async {
    await database.appSettingsDao.getSettings();
    if (updatedUser) {
      await database.appSettingsDao.completeOnboarding(
        currentOnboardingVersion,
      );
    }
    await seed?.call(database.appSettingsDao);
  });
  final container = ProviderContainer(
    overrides: withTestDatabase(
      database,
      overrides: <Override>[
        externalScrobbleCredentialStoreProvider.overrideWithValue(
          _MemoryCredentialStore(),
        ),
        packageInfoProvider.overrideWith(
          (ref) async => PackageInfo(
            appName: 'Navis',
            packageName: 'test.navis',
            version: '1.4.3',
            buildNumber: '10403',
          ),
        ),
      ],
    ),
  );
  final router = GoRouter(
    initialLocation: AppRoutes.onboarding,
    routes: [
      GoRoute(
        path: AppRoutes.onboarding,
        builder: (_, _) => OnboardingScreen(reviewMode: reviewMode),
      ),
      GoRoute(
        path: AppRoutes.settings,
        builder: (_, _) => const Scaffold(body: Text('Settings stub')),
      ),
      GoRoute(
        path: AppRoutes.home,
        builder: (_, _) => const Scaffold(body: Text('Home stub')),
      ),
    ],
  );
  addTearDown(() async {
    router.dispose();
    container.dispose();
    await database.close();
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: navisLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  final harness = _Harness(tester, database);
  await harness.settle();
  return harness;
}

void main() {
  testWidgets('marks all six options New for an updated user', (tester) async {
    await _pump(tester, seed: (d) => d.updateThemeMode('system'));

    expect(find.byType(NewFeatureTag), findsNWidgets(6));
    expect(find.text('New'), findsNWidgets(6));
    expect(
      find.descendant(
        of: find.byType(NewFeatureTag),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Semantics && widget.properties.label == 'New option',
        ),
      ),
      findsNWidgets(6),
    );
  });

  testWidgets('hides the OLED option, and its tag, outside Auto mode', (
    tester,
  ) async {
    await _pump(tester);

    expect(find.text('Use OLED When Dark'), findsNothing);
    expect(find.byType(NewFeatureTag), findsNWidgets(5));
  });

  testWidgets('shows no tags on a fresh install', (tester) async {
    await _pump(
      tester,
      updatedUser: false,
      reviewMode: false,
      seed: (d) => d.updateThemeMode('system'),
    );

    expect(find.text('Night Schedule'), findsOneWidget);
    expect(find.byType(NewFeatureTag), findsNothing);
  });

  testWidgets('Finish saves the new options and clears the tags', (
    tester,
  ) async {
    final h = await _pump(tester, seed: (d) => d.updateThemeMode('system'));

    await h.tap(find.text('Use OLED When Dark'));
    await h.tap(find.text('Night Schedule'));
    await h.tap(find.text('Flat Surfaces'));
    await h.tap(find.text('Square'));
    await h.tap(find.text('Artwork'));
    await h.tap(find.text('Compact'));
    expect(find.byType(ActionChip), findsNWidgets(2));

    // Nothing is saved until Finish.
    var row = await h.row();
    expect(row.oledForAuto, isFalse);
    expect(row.nightScheduleEnabled, isFalse);
    expect(row.flatSurfaces, isFalse);
    expect(row.cornerStyle, 'rounded');
    expect(row.nowPlayingBackground, 'tinted');
    expect(row.homeDensity, 'comfortable');

    await h.finish();
    row = await h.row();
    expect(row.oledForAuto, isTrue);
    expect(row.nightScheduleEnabled, isTrue);
    expect(row.nightScheduleStartMinutes, 1320);
    expect(row.flatSurfaces, isTrue);
    expect(row.cornerStyle, 'square');
    expect(row.nowPlayingBackground, 'artwork');
    expect(row.homeDensity, 'compact');
    expect(row.setupHighlightsSeenRelease, '1.4.3');
  });

  testWidgets('Skip in review keeps the tags pending', (tester) async {
    final h = await _pump(tester, seed: (d) => d.updateThemeMode('system'));

    await h.tap(find.text('Flat Surfaces'));
    await h.skip();

    final row = await h.row();
    expect(row.flatSurfaces, isFalse);
    expect(row.setupHighlightsSeenRelease, isNull);
  });

  testWidgets('the preview goes OLED for Auto with OLED When Dark', (
    tester,
  ) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    final h = await _pump(tester, seed: (d) => d.updateThemeMode('system'));
    final seed = resolveColorSchemeSeedColor(null);
    const style = NavisColorStyle.neutral;

    expect(
      h.previewTheme.colorScheme.surface,
      buildDarkTheme(seed, style: style).colorScheme.surface,
    );
    await h.tap(find.text('Use OLED When Dark'));
    expect(
      h.previewTheme.colorScheme.surface,
      buildOledTheme(seed, style: style).colorScheme.surface,
    );
    expect(
      buildOledTheme(seed, style: style).colorScheme.surface,
      isNot(buildDarkTheme(seed, style: style).colorScheme.surface),
    );
  });

  testWidgets('the preview goes flat with Flat Surfaces', (tester) async {
    final h = await _pump(tester);

    expect(h.previewTheme.shadowColor, isNot(Colors.transparent));
    await h.tap(find.text('Flat Surfaces'));
    expect(h.previewTheme.shadowColor, Colors.transparent);
  });

  for (final style in NavisCornerStyle.values) {
    testWidgets(
      'Corner Style ${style.name} drafts, previews and saves on Finish',
      (tester) async {
        final h = await _pump(tester);
        final label = switch (style) {
          NavisCornerStyle.rounded => 'Rounded',
          NavisCornerStyle.soft => 'Soft',
          NavisCornerStyle.square => 'Square',
        };
        // Pick another style first so every option is a real change.
        await h.tap(
          find.text(style == NavisCornerStyle.soft ? 'Square' : 'Soft'),
        );
        await h.tap(find.text(label));

        expect(h.previewTheme.extension<NavisShapeData>()?.style, style);
        expect((await h.row()).cornerStyle, 'rounded');
        expect(find.byType(NewFeatureTag), findsWidgets);

        await h.finish();
        expect((await h.row()).cornerStyle, style.name);
      },
    );
  }

  testWidgets('Corner Style is tagged New and Finish marks the release seen', (
    tester,
  ) async {
    final h = await _pump(tester);
    final tag = find.descendant(
      of: find
          .ancestor(of: find.text('Corner Style'), matching: find.byType(Row))
          .first,
      matching: find.byType(NewFeatureTag),
    );
    expect(tag, findsOneWidget);
    await h.finish();
    expect(await h.row().then((r) => r.setupHighlightsSeenRelease), '1.4.3');
  });

  testWidgets('a night schedule does not switch the preview by time', (
    tester,
  ) async {
    final h = await _pump(tester);
    final before = h.previewTheme.colorScheme.surface;

    await h.tap(find.text('Night Schedule'));

    expect(h.previewTheme.colorScheme.surface, before);
  });
}
