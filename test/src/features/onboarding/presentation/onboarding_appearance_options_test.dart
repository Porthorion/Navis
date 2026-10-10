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
import 'package:navis/src/features/onboarding/domain/setup_highlights.dart';
import 'package:navis/src/features/onboarding/presentation/onboarding_provider.dart';
import 'package:navis/src/features/onboarding/presentation/setup_highlights_provider.dart';
import 'package:navis/src/features/onboarding/presentation/onboarding_screen.dart';
import 'package:navis/src/features/settings/data/external_scrobble_credentials.dart';
import 'package:navis/src/features/settings/presentation/appearance_options.dart';
import 'package:navis/src/features/settings/presentation/color_style_selector.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/app_routes.dart';
import 'package:navis/src/theme/navis_color_style.dart';
import 'package:navis/src/theme/navis_corner_style.dart';
import 'package:navis/src/theme/navis_shape_data.dart';
import 'package:navis/src/theme/navis_theme.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:visibility_detector/visibility_detector.dart';

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

/// Options reported as shown, in order.
final _shownOptions = <SetupHighlight>[];

/// [updatedUser] seeds a completed setup, as for someone updating the app.
/// Shown options are recorded in [_shownOptions]; they only clear their tags
/// when [clearTagsWhenShown] is set, so tag counts stay stable.
Future<_Harness> _pump(
  WidgetTester tester, {
  bool updatedUser = true,
  bool reviewMode = true,
  bool clearTagsWhenShown = false,
  Future<void> Function(AppSettingsDao dao)? seed,
}) async {
  setAdaptiveTestViewport(tester, const Size(500, 3000));
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
        setupHighlightsServiceProvider.overrideWith((ref) {
          final repository = ref.watch(settingsRepositoryProvider);
          return SetupHighlightsService(
            () => repository.updateSetupHighlightsSeenRelease('1.5.0'),
            () => repository.updateSetupCardDismissedRelease('1.5.0'),
            (option) async {
              _shownOptions.add(option);
              if (clearTagsWhenShown) {
                await repository.markSetupHighlightSeen(option.storageKey);
              }
            },
          );
        }),
        packageInfoProvider.overrideWith(
          (ref) async => PackageInfo(
            appName: 'Navis',
            packageName: 'test.navis',
            version: '1.5.0',
            buildNumber: '10500',
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
  setUp(() {
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
    _shownOptions.clear();
  });

  testWidgets('marks every visible option New for an updated user', (
    tester,
  ) async {
    await _pump(tester, seed: (d) => d.updateThemeMode('system'));

    // The Flat areas only show, and so only carry their tag, while Flat is on.
    expect(find.byType(NewFeatureTag), findsNWidgets(7));
    expect(find.text('New'), findsNWidgets(7));
    expect(
      find.descendant(
        of: find.byType(NewFeatureTag),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Semantics && widget.properties.label == 'New option',
        ),
      ),
      findsNWidgets(7),
    );
  });

  testWidgets('hides the OLED option, and its tag, outside Auto mode', (
    tester,
  ) async {
    await _pump(tester);

    expect(find.text('Use OLED When Dark'), findsNothing);
    expect(find.byType(NewFeatureTag), findsNWidgets(6));
  });

  testWidgets('shows no tags on a fresh install', (tester) async {
    final h = await _pump(
      tester,
      updatedUser: false,
      reviewMode: false,
      seed: (d) => d.updateThemeMode('system'),
    );

    expect(find.byType(NewFeatureTag), findsNothing);
    expect(find.text('Night Schedule'), findsOneWidget);
    await h.tap(find.text('More appearance options'));
    expect(find.text('Flat Surfaces'), findsOneWidget);
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
    expect(row.setupHighlightsSeenRelease, '1.5.0');
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
          NavisCornerStyle.rounded => 'Pill',
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
    expect(await h.row().then((r) => r.setupHighlightsSeenRelease), '1.5.0');
  });

  testWidgets('a night schedule does not switch the preview by time', (
    tester,
  ) async {
    final h = await _pump(tester);
    final before = h.previewTheme.colorScheme.surface;

    await h.tap(find.text('Night Schedule'));

    expect(h.previewTheme.colorScheme.surface, before);
  });

  group('Flat areas', () {
    const areas = <String>[
      'Panels and Shadows',
      'Now Playing',
      'Text Over Artwork',
    ];

    testWidgets('reveal with Flat Surfaces and save on Finish', (tester) async {
      final h = await _pump(tester);
      for (final label in areas) {
        expect(find.text(label), findsNothing, reason: label);
      }

      await h.tap(find.text('Flat Surfaces'));
      for (final label in areas) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      await h.tap(find.text('Text Over Artwork'));
      await h.tap(find.text('Now Playing'));
      expect((await h.row()).flatAreas, 7);

      await h.finish();
      final row = await h.row();
      expect(row.flatSurfaces, isTrue);
      expect(row.flatAreas, 1);
    });

    testWidgets('the preview follows the selected areas', (tester) async {
      final h = await _pump(tester);
      await h.tap(find.text('Flat Surfaces'));
      expect(h.previewTheme.shadowColor, Colors.transparent);

      await h.tap(find.text('Panels and Shadows'));
      expect(h.previewTheme.shadowColor, isNot(Colors.transparent));
    });

    testWidgets('an open group shows a pending tag for them', (tester) async {
      await _pump(
        tester,
        seed: (d) async {
          await d.updateFlatSurfaces(enabled: true);
          for (final option in SetupHighlight.values) {
            if (option != SetupHighlight.flatAreas) {
              await d.markSetupHighlightSeen(option.storageKey);
            }
          }
        },
      );

      expect(find.text('Panels and Shadows'), findsOneWidget);
      expect(find.byType(NewFeatureTag), findsOneWidget);
    });
  });

  group('Album Art Shade', () {
    final shadeKey = find.byKey(const ValueKey<String>('albumArtShadeSwitch'));
    final coverKey = find.byKey(
      const ValueKey<String>('albumArtCoverColorSwitch'),
    );
    SwitchListTile switchOf(WidgetTester tester, Finder finder) =>
        tester.widget(finder);

    testWidgets('sits outside More appearance options and saves on Finish', (
      tester,
    ) async {
      final h = await _pump(tester, updatedUser: false, reviewMode: false);
      expect(find.text('Album Art Shade'), findsOneWidget);
      expect(
        find.text('A solid shade behind album titles for easier reading.'),
        findsOneWidget,
      );
      expect(find.text('Corner Style'), findsNothing);
      // Use Cover Color only appears once Shade is on.
      expect(find.text('Use Cover Color'), findsNothing);

      await h.tap(shadeKey);
      expect(find.text('Use Cover Color'), findsOneWidget);
      expect(
        find.text('Tint the shade with a color from each cover.'),
        findsOneWidget,
      );
      await h.tap(coverKey);
      var row = await h.row();
      expect(row.albumArtShade, isFalse);
      expect(row.albumArtColoredShade, isFalse);
      await h.finish();
      row = await h.row();
      expect(row.albumArtShade, isTrue);
      expect(row.albumArtColoredShade, isTrue);
    });

    testWidgets('both are disabled with a note under Flat text over art', (
      tester,
    ) async {
      final h = await _pump(tester);
      const note =
          'Album titles sit below the art while Flat text over '
          'artwork is on.';
      expect(find.text(note), findsNothing);
      expect(switchOf(tester, shadeKey).onChanged, isNotNull);
      await h.tap(shadeKey);
      expect(switchOf(tester, coverKey).onChanged, isNotNull);

      await h.tap(find.text('Flat Surfaces'));
      expect(find.text(note), findsOneWidget);
      expect(switchOf(tester, shadeKey).onChanged, isNull);
      expect(switchOf(tester, coverKey).onChanged, isNull);

      await h.tap(find.text('Text Over Artwork'));
      expect(find.text(note), findsNothing);
      expect(switchOf(tester, shadeKey).onChanged, isNotNull);
      expect(switchOf(tester, coverKey).onChanged, isNotNull);
    });
  });

  group('More appearance options', () {
    const expanderKey = ValueKey<String>('onboarding-more-appearance-options');

    testWidgets('keeps Theme Mode, Color Style and Accent Color visible', (
      tester,
    ) async {
      await _pump(tester, updatedUser: false, reviewMode: false);

      expect(find.text('Light'), findsOneWidget);
      expect(find.text('Color Style'), findsOneWidget);
      expect(find.text('Night Schedule'), findsOneWidget);
      expect(find.text('Accent Color'), findsOneWidget);
      expect(find.text('More appearance options'), findsOneWidget);
      for (final hidden in <String>[
        'Flat Surfaces',
        'Corner Style',
        'Density',
        'Now Playing Background',
      ]) {
        expect(find.text(hidden), findsNothing, reason: hidden);
      }
    });

    testWidgets('is closed for an updated user with nothing pending', (
      tester,
    ) async {
      await _pump(
        tester,
        seed: (d) => d.updateSetupHighlightsSeenRelease('1.5.0'),
      );

      expect(find.byKey(expanderKey), findsOneWidget);
      expect(find.text('Corner Style'), findsNothing);
    });

    testWidgets('opens by itself while an option is tagged', (tester) async {
      await _pump(tester);

      expect(find.text('Corner Style'), findsOneWidget);
      expect(find.text('Flat Surfaces'), findsOneWidget);
      expect(find.text('Density'), findsOneWidget);
      expect(find.text('Use OLED When Dark'), findsNothing);
    });

    testWidgets('lists the options in Settings order', (tester) async {
      await _pump(tester, seed: (d) => d.updateThemeMode('system'));

      final labels = <String>[
        'Use OLED When Dark',
        'Flat Surfaces',
        'Corner Style',
        'Density',
        'Now Playing Background',
      ];
      double top(String text) => tester.getTopLeft(find.text(text)).dy;
      for (var i = 1; i < labels.length; i++) {
        expect(top(labels[i]), greaterThan(top(labels[i - 1])));
      }
      // Night Schedule sits beside Color Style, above the collapsed group.
      expect(
        top('Night Schedule'),
        greaterThan(top('Color Style')),
        reason: 'Night Schedule follows Color Style',
      );
      expect(top('Night Schedule'), lessThan(top('Use OLED When Dark')));
      expect(
        find.ancestor(
          of: find.text('Night Schedule'),
          matching: find.byKey(
            const ValueKey<String>('onboarding-more-appearance-options'),
          ),
        ),
        findsNothing,
      );
      expect(AppearanceOptionKind.values.map((kind) => kind.name), <String>[
        'oledForAuto',
        'nightSchedule',
        'flatSurfaces',
        'cornerStyle',
        'density',
        'nowPlayingBackground',
      ]);
    });

    testWidgets('headings and controls share one left edge', (tester) async {
      await _pump(tester, updatedUser: false, reviewMode: false);

      final edge = tester.getTopLeft(find.text('Choose Your Look')).dx;
      expect(tester.getTopLeft(find.text('Color Style')).dx, edge);
      expect(tester.getTopLeft(find.text('Accent Color')).dx, edge);
      expect(tester.getTopLeft(find.byType(SegmentedButton<String>)).dx, edge);
      expect(tester.getTopLeft(find.byType(ColorStyleSelector)).dx, edge);
    });

    testWidgets('shows the scroll hint when the first step overflows', (
      tester,
    ) async {
      setAdaptiveTestViewport(tester, const Size(500, 500));
      await _pump(tester, updatedUser: false, reviewMode: false);
      setAdaptiveTestViewport(tester, const Size(500, 500));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('onboarding-scroll-hint')),
        findsOneWidget,
      );
    });

    testWidgets('tagged options mark themselves seen once shown', (
      tester,
    ) async {
      await _pump(
        tester,
        seed: (d) async {
          await d.updateThemeMode('system');
          await d.updateFlatSurfaces(enabled: true);
        },
      );

      expect(_shownOptions.toSet(), <SetupHighlight>{
        for (final highlight in SetupHighlight.values) highlight,
      });
      expect(_shownOptions, hasLength(SetupHighlight.values.length));
    });

    testWidgets('the hidden OLED and Flat area options are not marked seen', (
      tester,
    ) async {
      await _pump(tester);

      expect(_shownOptions, isNot(contains(SetupHighlight.oledForAuto)));
      expect(_shownOptions, isNot(contains(SetupHighlight.flatAreas)));
      expect(_shownOptions, hasLength(SetupHighlight.values.length - 2));
    });

    testWidgets(
      'cleared tags stay visible for the visit and Finish still saves',
      (tester) async {
        final h = await _pump(
          tester,
          clearTagsWhenShown: true,
          seed: (d) => d.updateThemeMode('system'),
        );

        // The tags were recorded as seen, yet stay for this visit.
        expect(_shownOptions, isNotEmpty);
        expect(find.byType(NewFeatureTag), findsWidgets);
        // The group is open because the visit snapshot had tagged options.
        expect(find.text('Corner Style'), findsOneWidget);
        await h.tap(find.text('Flat Surfaces'));
        await h.tap(find.text('Square'));
        await h.finish();
        final row = await h.row();
        expect(row.flatSurfaces, isTrue);
        expect(row.cornerStyle, 'square');
      },
    );
  });
}
