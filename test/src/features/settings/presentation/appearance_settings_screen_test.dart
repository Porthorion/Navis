import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/common_widgets/new_feature_tag.dart';
import 'package:navis/src/features/onboarding/domain/setup_highlights.dart';
import 'package:navis/src/features/onboarding/presentation/setup_highlights_provider.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/features/settings/domain/navis_density.dart';
import 'package:navis/src/features/settings/domain/now_playing_background.dart';
import 'package:navis/src/features/settings/presentation/appearance_settings_screen.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/theme/navis_corner_style.dart';
import 'package:navis/src/theme/navis_theme.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

import '../../../../helpers/adaptive_test_harness.dart';
import '../../../../helpers/test_database.dart';
import '../../../../helpers/test_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ProviderContainer> pumpAppearance(
    WidgetTester tester, {
    int? colorSeed,
    List<int> customPresets = const <int>[],
    bool dynamicAlbumColorEnabled = false,
    AdaptiveContext? adaptiveContext,
    TextScaler textScaler = TextScaler.noScaling,
    List<String>? homeSectionOrder,
    String? themeMode,
    bool nightScheduleEnabled = false,
    int? nightStartMinutes,
    int? nightEndMinutes,
    Set<SetupHighlight> highlights = const <SetupHighlight>{},
    bool settle = true,
    NowPlayingBackground? nowPlayingBackground,
  }) async {
    if (adaptiveContext == null &&
        tester.view.physicalSize / tester.view.devicePixelRatio ==
            const Size(800, 600)) {
      // Tall enough that the style tiles, schedule rows and colour grid build.
      tester.view.physicalSize = const Size(800, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }
    final database = createTestDatabase();
    await tester.runAsync(database.appSettingsDao.getSettings);
    final settings = const AppSettingsModel.defaults().copyWith(
      colorSchemeSeed: colorSeed,
      dynamicAlbumColorEnabled: dynamicAlbumColorEnabled,
      homeSectionOrder: homeSectionOrder,
      themeMode: themeMode,
      nowPlayingBackground: nowPlayingBackground,
      nightScheduleEnabled: nightScheduleEnabled,
      nightScheduleStartMinutes: nightStartMinutes,
      nightScheduleEndMinutes: nightEndMinutes,
    );
    final container = ProviderContainer(
      overrides: withTestDatabase(
        database,
        overrides: <Override>[
          appSettingsProvider.overrideWithValue(AsyncData(settings)),
          pendingSetupHighlightsProvider.overrideWithValue(highlights),
          customColorPresetsProvider.overrideWithValue(
            AsyncData(customPresets),
          ),
        ],
      ),
    );
    addTearDown(() async {
      container.dispose();
      await database.close();
    });

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: navisLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: testTheme(buildLightTheme(defaultColorSchemeSeedColor)),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: textScaler),
            child: child!,
          ),
          home: adaptiveContext == null
              ? const AppearanceSettingsScreen()
              : AdaptiveContextScope(
                  adaptiveContext: adaptiveContext,
                  child: const AppearanceSettingsScreen(),
                ),
        ),
      ),
    );
    if (adaptiveContext == null && settle) {
      await tester.pumpAndSettle();
    } else if (adaptiveContext == null) {
      await tester.pump(const Duration(milliseconds: 500));
    } else {
      await tester.pump();
    }
    return container;
  }

  AnimatedContainer chip(WidgetTester tester, String key) {
    return tester.widget<AnimatedContainer>(
      find.byKey(ValueKey<String>('colorChip-$key')),
    );
  }

  BoxDecoration chipDecoration(WidgetTester tester, String key) {
    return chip(tester, key).decoration! as BoxDecoration;
  }

  testWidgets('theme selector stays horizontal on a phone-width surface', (
    tester,
  ) async {
    setAdaptiveTestViewport(tester, const Size(390, 844));
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: navisLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ThemeModeSelector(currentMode: 'system', onChanged: (_) {}),
        ),
      ),
    );

    final selector = tester.widget<SegmentedButton<String>>(
      find.byType(SegmentedButton<String>),
    );
    expect(selector.direction, Axis.horizontal);
    expect(find.text('Light'), findsOneWidget);
    expect(find.text('Dark'), findsOneWidget);
    expect(find.text('OLED'), findsOneWidget);
    expect(find.text('Auto'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('uses white for implicit default', (tester) async {
    await pumpAppearance(tester);

    final defaultDecoration = chipDecoration(tester, 'default');
    expect((defaultDecoration.border! as Border).top.width, 3);

    final orangeValue = Colors.orange.toARGB32();
    final orangeKey = 'preset-$orangeValue';
    final orangeDecoration = chipDecoration(tester, orangeKey);
    expect((orangeDecoration.border! as Border).top.width, 1);
  });

  testWidgets('uses default chip for explicit saved white', (tester) async {
    await pumpAppearance(
      tester,
      colorSeed: defaultColorSchemeSeedColor.toARGB32(),
    );

    final defaultDecoration = chipDecoration(tester, 'default');
    expect((defaultDecoration.border! as Border).top.width, 3);
  });

  testWidgets('keeps explicit orange distinct from default', (tester) async {
    final orangeValue = Colors.orange.toARGB32();
    final orangeKey = 'preset-$orangeValue';

    await pumpAppearance(tester, colorSeed: orangeValue);
    await tester.pumpAndSettle();

    final explicitDefaultDecoration = chipDecoration(tester, 'default');
    final explicitOrangeDecoration = chipDecoration(tester, orangeKey);
    expect((explicitDefaultDecoration.border! as Border).top.width, 1);
    expect((explicitOrangeDecoration.border! as Border).top.width, 3);
  });

  testWidgets('default white chip has a visible contrast treatment', (
    tester,
  ) async {
    final whiteValue = Colors.white.toARGB32();
    await pumpAppearance(tester, colorSeed: whiteValue);

    final decoration = chipDecoration(tester, 'default');
    expect((decoration.border! as Border).top.width, 3);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('colorChip-default')),
        matching: find.byIcon(Icons.check_rounded),
      ),
      findsOneWidget,
    );
  });

  testWidgets('does not render a separate white preset chip', (tester) async {
    await pumpAppearance(tester);

    expect(
      find.byKey(
        ValueKey<String>(
          'colorChip-preset-${defaultColorSchemeSeedColor.toARGB32()}',
        ),
      ),
      findsNothing,
    );
  });

  testWidgets('custom colors merge into gradient order and show named badge', (
    tester,
  ) async {
    final customWarm = const Color(0xFFFFB000).toARGB32();
    final customGrey = const Color(0xFF777777).toARGB32();
    final customCoral = const Color(0xFFFF7F50).toARGB32();
    await pumpAppearance(
      tester,
      customPresets: <int>[
        customWarm,
        Colors.orange.toARGB32(),
        defaultColorSchemeSeedColor.toARGB32(),
        customCoral,
        customGrey,
        customGrey,
      ],
    );

    final orangeFinder = find.byKey(
      ValueKey<String>('colorChip-preset-${Colors.orange.toARGB32()}'),
    );
    final customWarmFinder = find.byKey(
      ValueKey<String>('colorChip-custom-$customWarm'),
    );
    final amberFinder = find.byKey(
      ValueKey<String>('colorChip-preset-${Colors.amber.toARGB32()}'),
    );

    expect(customWarmFinder, findsOneWidget);
    expect(
      find.byKey(ValueKey<String>('customColorBadge-custom-$customWarm')),
      findsOneWidget,
    );
    expect(
      find.byKey(
        ValueKey<String>('customColorBadge-custom-${Colors.orange.toARGB32()}'),
      ),
      findsNothing,
    );
    expect(
      find.byKey(
        ValueKey<String>(
          'customColorBadge-custom-${defaultColorSchemeSeedColor.toARGB32()}',
        ),
      ),
      findsNothing,
    );
    expect(
      find.byKey(ValueKey<String>('colorChip-custom-$customGrey')),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(
        lookupAppLocalizations(const Locale('en'))
            .appearanceColorCustomSemantics('Custom: Coral'),
      ),
      findsOneWidget,
    );

    final orangeX = tester.getTopLeft(orangeFinder).dx;
    final customX = tester.getTopLeft(customWarmFinder).dx;
    final amberX = tester.getTopLeft(amberFinder).dx;
    expect(orangeX, lessThan(customX));
    expect(customX, lessThan(amberX));
  });

  testWidgets('saving exact default white stores null seed and no preset', (
    tester,
  ) async {
    final container = await pumpAppearance(
      tester,
      colorSeed: Colors.orange.toARGB32(),
    );

    // Scroll only as far as the custom-colour chip so the continuously
    // animating shape previews further down stay unbuilt.
    await tester.ensureVisible(find.byIcon(Icons.add));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.add));
    // Shape previews animate continuously once scrolled near; wait only for
    // finite transitions.
    await tester.pump(const Duration(milliseconds: 500));
    final l10n = lookupAppLocalizations(const Locale('en'));
    await tester.enterText(
      find.widgetWithText(TextField, l10n.appearanceColorPickerHexLabel),
      'FFFFFF',
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text(l10n.appearanceColorPickerSave));
    await tester.pump(const Duration(milliseconds: 500));

    final database = container.read(navisDatabaseProvider);
    final settings = await database.appSettingsDao.getSettings();
    expect(settings?.colorSchemeSeed, isNull);
    expect(settings?.customColorPresets, isNull);
  });

  testWidgets('color style tiles fit a phone and save the chosen style', (
    tester,
  ) async {
    setAdaptiveTestViewport(tester, const Size(360, 800));
    final container = await pumpAppearance(tester);

    final tiles = <Finder>[
      for (final key in <String>['neutral', 'pastel', 'immersive', 'night'])
        find.byKey(ValueKey<String>('colorStyleTile-$key')),
    ];
    for (final tile in tiles) {
      expect(tile, findsOneWidget);
    }
    // Four tiles share one row at phone width.
    final firstTop = tester.getTopLeft(tiles.first).dy;
    for (final tile in tiles.skip(1)) {
      expect(tester.getTopLeft(tile).dy, firstTop);
    }
    expect(tester.getTopRight(tiles.last).dx, lessThanOrEqualTo(360));

    await tester.tap(tiles[1]);
    await tester.pump();
    final database = container.read(navisDatabaseProvider);
    final settings = await tester.runAsync(database.appSettingsDao.getSettings);
    expect(settings?.colorStyle, 'pastel');
  });

  testWidgets('dynamic album color explains selected color fallback', (
    tester,
  ) async {
    await pumpAppearance(tester, dynamicAlbumColorEnabled: true);

    final l10n = lookupAppLocalizations(const Locale('en'));
    await tester.scrollUntilVisible(
      find.text(l10n.appearanceDynamicAlbumColorEnabledSub),
      200,
      scrollable: find.byType(Scrollable).first,
    );

    expect(
      find.text(l10n.appearanceDynamicAlbumColorEnabledSub),
      findsOneWidget,
    );
    expect(find.text(l10n.appearanceColorSchemeDynamicSub), findsOneWidget);
  });

  testWidgets('artwork choices wrap and save on a phone with large text', (
    tester,
  ) async {
    setAdaptiveTestViewport(tester, const Size(320, 800));
    final container = await pumpAppearance(
      tester,
      textScaler: const TextScaler.linear(2),
    );
    // Shape previews animate continuously; wait only for finite transitions.
    final small = find.widgetWithText(ChoiceChip, 'Small');
    await tester.scrollUntilVisible(
      small,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(small);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final row = (await tester.runAsync(
      () => container
          .read(navisDatabaseProvider)
          .appSettingsDao
          .watchSettings()
          .firstWhere((row) => row?.gridArtworkSize == 'small')
          .timeout(const Duration(seconds: 2)),
    ))!;
    expect(row.gridArtworkSize, 'small');
    expect(row.homeRecommendationsAutoAdvance, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'mobile Home offers an automatic recommendation preference off by default',
    (tester) async {
      setAdaptiveTestViewport(tester, const Size(390, 844));
      final container = await pumpAppearance(tester);
      final home = find.text('Home Sections');
      await tester.scrollUntilVisible(
        home,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(home);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final control = find.widgetWithText(
        SwitchListTile,
        'Automatically advance recommendations',
      );
      await tester.scrollUntilVisible(
        control,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.widget<SwitchListTile>(control).value, isFalse);
      await tester.tap(control);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final row = (await tester.runAsync(
        () => container
            .read(navisDatabaseProvider)
            .appSettingsDao
            .watchSettings()
            .firstWhere((row) => row?.homeRecommendationsAutoAdvance == true)
            .timeout(const Duration(seconds: 2)),
      ))!;
      expect(row.homeRecommendationsAutoAdvance, isTrue);
      expect(row.gridArtworkSize, 'auto');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('desktop appearance uses a focused settings workspace', (
    tester,
  ) async {
    setAdaptiveTestViewport(tester, const Size(1280, 800));
    await pumpAppearance(
      tester,
      adaptiveContext: resolveAdaptiveContext(
        desktopRuntime: true,
        viewportSize: const Size(1280, 800),
        safePadding: EdgeInsets.zero,
      ),
    );

    expect(find.byTooltip('Back'), findsOneWidget);
    expect(tester.getSize(find.byType(ListView)).width, 1040);
    await expectLater(
      find.byType(AppearanceSettingsScreen),
      matchesGoldenFile('goldens/appearance_settings_desktop_workspace.png'),
    );
  });

  testWidgets(
    'a saved Home order lists New Releases right under You Might Like',
    (tester) async {
      // Saved by 1.4.2, before New Releases existed.
      await pumpAppearance(
        tester,
        homeSectionOrder: const <String>[
          'recently_added',
          'random_albums',
          'recently_liked_albums',
          'liked_tracks',
          'recently_played',
          'most_played',
          'recently_played_tracks',
          'frequent_albums',
        ],
      );
      final page = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(
        find.text('Home Sections'),
        200,
        scrollable: page,
      );
      await tester.tap(find.text('Home Sections'));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.scrollUntilVisible(
        find.text('New Releases'),
        200,
        scrollable: page,
      );
      await tester.pump(const Duration(milliseconds: 500));

      final random = tester.getTopLeft(find.text('You Might Like').last).dy;
      final releases = tester.getTopLeft(find.text('New Releases')).dy;
      final liked = tester
          .getTopLeft(find.text('Recently Liked Albums').last)
          .dy;
      expect(releases, greaterThan(random));
      expect(releases, lessThan(liked));
    },
  );

  group('appearance switches', () {
    final l10n = lookupAppLocalizations(const Locale('en'));

    Future<void> reveal(WidgetTester tester, Finder finder) async {
      await tester.ensureVisible(finder);
      await tester.pump();
    }

    Future<void> scrollTo(WidgetTester tester, Finder finder) =>
        tester.scrollUntilVisible(
          finder,
          200,
          scrollable: find.byType(Scrollable).first,
        );

    testWidgets('OLED switch is hidden outside Auto', (tester) async {
      await pumpAppearance(tester);
      expect(find.text(l10n.appearanceOledForAutoLabel), findsNothing);
    });

    testWidgets('OLED switch saves in Auto', (tester) async {
      final container = await pumpAppearance(tester, themeMode: 'system');
      final finder = find.text(l10n.appearanceOledForAutoLabel);
      expect(finder, findsOneWidget);
      await tester.tap(finder);
      await tester.pump(const Duration(milliseconds: 100));
      final settings = await tester.runAsync(
        container.read(navisDatabaseProvider).appSettingsDao.getSettings,
      );
      expect(settings?.oledForAuto, isTrue);
    });

    testWidgets('Night schedule switch saves', (tester) async {
      final container = await pumpAppearance(tester);
      final finder = find.text(l10n.appearanceNightScheduleLabel);
      await reveal(tester, finder);
      expect(find.byIcon(Icons.bedtime_outlined), findsNothing);
      await tester.tap(finder);
      await tester.pump(const Duration(milliseconds: 100));
      final settings = await tester.runAsync(
        container.read(navisDatabaseProvider).appSettingsDao.getSettings,
      );
      expect(settings?.nightScheduleEnabled, isTrue);
    });

    testWidgets('enabled schedule shows one row of time pills', (tester) async {
      await pumpAppearance(tester, nightScheduleEnabled: true);
      await reveal(tester, find.byIcon(Icons.bedtime_outlined));
      expect(find.byType(ActionChip), findsNWidgets(2));
      expect(find.byIcon(Icons.arrow_forward), findsOneWidget);
      final start = find.byType(ActionChip).first;
      final end = find.byType(ActionChip).last;
      expect(
        tester.getCenter(start).dy,
        moreOrLessEquals(tester.getCenter(end).dy),
      );
      expect(find.text(l10n.appearanceNightScheduleSameTimes), findsNothing);
    });

    testWidgets('time pills open the picker', (tester) async {
      await pumpAppearance(tester, nightScheduleEnabled: true);
      await reveal(tester, find.byType(ActionChip).first);
      expect(find.bySemanticsLabel(RegExp('^Starts at ')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('^Ends at ')), findsOneWidget);
      await tester.tap(find.byType(ActionChip).first);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(TimePickerDialog), findsOneWidget);
    });

    testWidgets('dependent options are inset as sub-options', (tester) async {
      await pumpAppearance(
        tester,
        themeMode: 'system',
        nightScheduleEnabled: true,
      );
      final parent = tester.getTopLeft(
        find.text(l10n.appearanceNightScheduleLabel),
      );
      final oled = tester.getTopLeft(
        find.text(l10n.appearanceOledForAutoLabel),
      );
      final modeSwitch = tester.getTopLeft(
        find.text(l10n.appearanceColorStyleLabel),
      );
      expect(oled.dx, greaterThan(modeSwitch.dx + 8));
      await reveal(tester, find.byType(ActionChip).first);
      final pill = tester.getTopLeft(find.byType(ActionChip).first);
      final icon = tester.getTopLeft(find.byIcon(Icons.bedtime_outlined));
      expect(icon.dx, greaterThanOrEqualTo(32));
      expect(pill.dx, greaterThan(icon.dx));
      expect(parent.dx, lessThan(icon.dx));
    });

    testWidgets('accent section uses the Accent Color header', (tester) async {
      await pumpAppearance(tester);
      expect(l10n.appearanceColorSchemeLabel, 'Accent Color');
      await reveal(tester, find.text('Accent Color'));
      expect(find.text('Accent Color'), findsOneWidget);
      expect(find.text('Color Scheme'), findsNothing);
    });

    testWidgets('equal start and end show the helper text', (tester) async {
      await pumpAppearance(
        tester,
        nightScheduleEnabled: true,
        nightStartMinutes: 600,
        nightEndMinutes: 600,
      );
      await reveal(tester, find.text(l10n.appearanceNightScheduleSameTimes));
      expect(find.text(l10n.appearanceNightScheduleSameTimes), findsOneWidget);
    });

    testWidgets('Flat Surfaces switch saves', (tester) async {
      final container = await pumpAppearance(tester);
      final finder = find.text(l10n.appearanceFlatSurfacesLabel);
      await reveal(tester, finder);
      await tester.tap(finder);
      await tester.pump(const Duration(milliseconds: 100));
      final settings = await tester.runAsync(
        container.read(navisDatabaseProvider).appSettingsDao.getSettings,
      );
      expect(settings?.flatSurfaces, isTrue);
    });

    // The provider is overridden with defaults (Rounded), so only the
    // changes away from Rounded fire a selection.
    for (final style in <NavisCornerStyle>[
      NavisCornerStyle.soft,
      NavisCornerStyle.square,
    ]) {
      testWidgets('Corner Style ${style.name} saves', (tester) async {
        final container = await pumpAppearance(tester);
        final selector = find.byKey(
          const ValueKey<String>('cornerStyleSelector'),
        );
        await scrollTo(tester, selector);
        expect(
          find.textContaining(l10n.appearanceCornerStyleArtworkNote),
          findsOneWidget,
        );
        expect(
          find.textContaining(l10n.appearanceCornerStyleRoundedSub),
          findsOneWidget,
        );
        await tester.tap(
          find.text(
            style == NavisCornerStyle.soft
                ? l10n.appearanceCornerStyleSoft
                : l10n.appearanceCornerStyleSquare,
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));
        final settings = await tester.runAsync(
          container.read(navisDatabaseProvider).appSettingsDao.getSettings,
        );
        expect(settings?.cornerStyle, style.name);
      });
    }

    for (final look in NowPlayingBackground.values) {
      testWidgets('Now Playing Background describes ${look.name}', (
        tester,
      ) async {
        final descriptions = <NowPlayingBackground, String>{
          NowPlayingBackground.tinted:
              l10n.appearanceNowPlayingBackgroundTintedSub,
          NowPlayingBackground.artwork:
              l10n.appearanceNowPlayingBackgroundArtworkSub,
          NowPlayingBackground.plain:
              l10n.appearanceNowPlayingBackgroundPlainSub,
        };
        await pumpAppearance(tester, nowPlayingBackground: look);
        await scrollTo(
          tester,
          find.byKey(const ValueKey<String>('nowPlayingBackgroundSelector')),
        );
        for (final entry in descriptions.entries) {
          expect(
            find.text(entry.value),
            entry.key == look ? findsOneWidget : findsNothing,
          );
        }
      });
    }

    testWidgets('Now Playing Background saves the chosen look', (tester) async {
      final container = await pumpAppearance(tester);
      await scrollTo(
        tester,
        find.byKey(const ValueKey<String>('nowPlayingBackgroundSelector')),
      );
      final artwork = find.descendant(
        of: find.byKey(const ValueKey<String>('nowPlayingBackgroundSelector')),
        matching: find.text(l10n.appearanceNowPlayingBackgroundArtwork),
      );
      await tester.ensureVisible(artwork);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(artwork);
      await tester.pump(const Duration(milliseconds: 100));
      final settings = await tester.runAsync(
        container.read(navisDatabaseProvider).appSettingsDao.getSettings,
      );
      expect(settings?.nowPlayingBackground, 'artwork');
    });

    testWidgets('Density sits beside Artwork Size, not in Home Sections', (
      tester,
    ) async {
      final container = await pumpAppearance(tester);
      final selector = find.byKey(const ValueKey<String>('densitySelector'));
      await scrollTo(tester, selector);
      expect(find.text(l10n.appearanceDensityLabel), findsOneWidget);
      expect(find.text(l10n.appearanceDensitySub), findsOneWidget);
      expect(find.text('Home Density'), findsNothing);
      await tester.tap(find.text(l10n.appearanceDensityCompact));
      await tester.pump(const Duration(milliseconds: 100));
      final settings = await tester.runAsync(
        container.read(navisDatabaseProvider).appSettingsDao.getSettings,
      );
      expect(settings?.homeDensity, NavisDensity.compact.storageKey);
      expect(NowPlayingBackground.values, hasLength(3));
    });

    group('New tags', () {
      void tallView(WidgetTester tester) {
        tester.view.physicalSize = const Size(800, 2400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
      }

      testWidgets('mark every pending option', (tester) async {
        tallView(tester);
        await pumpAppearance(
          tester,
          themeMode: 'system',
          highlights: SetupHighlight.values.toSet(),
          settle: false,
        );
        expect(find.byType(NewFeatureTag), findsNWidgets(7));
        for (final label in <String>[
          l10n.appearanceColorStyleLabel,
          l10n.appearanceOledForAutoLabel,
          l10n.appearanceNightScheduleLabel,
          l10n.appearanceFlatSurfacesLabel,
          l10n.appearanceCornerStyleLabel,
          l10n.appearanceNowPlayingBackgroundLabel,
          l10n.appearanceDensityLabel,
        ]) {
          final row = find.ancestor(
            of: find.text(label),
            matching: find.byType(Row),
          );
          expect(
            find.descendant(
              of: row.first,
              matching: find.byType(NewFeatureTag),
            ),
            findsOneWidget,
            reason: label,
          );
        }
      });

      testWidgets('only the pending ones', (tester) async {
        tallView(tester);
        await pumpAppearance(
          tester,
          highlights: <SetupHighlight>{
            SetupHighlight.density,
            SetupHighlight.nowPlayingBackground,
          },
          settle: false,
        );
        expect(find.byType(NewFeatureTag), findsNWidgets(2));
      });

      testWidgets('absent when nothing is pending', (tester) async {
        tallView(tester);
        await pumpAppearance(tester, themeMode: 'system', settle: false);
        expect(find.byType(NewFeatureTag), findsNothing);
      });
    });
  });
}
