import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/common_widgets/new_feature_tag.dart';
import 'package:navis/src/features/onboarding/domain/setup_highlights.dart';
import 'package:navis/src/features/onboarding/presentation/setup_highlights_provider.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/features/settings/presentation/interface_settings_screen.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../../../helpers/adaptive_test_harness.dart';
import '../../../../helpers/test_database.dart';
import '../../../../helpers/test_theme.dart';

import 'package:navis/src/theme/navis_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final seenOptions = <SetupHighlight>[];
  final l10n = lookupAppLocalizations(const Locale('en'));

  setUp(() {
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
    seenOptions.clear();
  });

  void tallView(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Future<ProviderContainer> pumpInterface(
    WidgetTester tester, {
    AdaptiveContext? adaptiveContext,
    TextScaler textScaler = TextScaler.noScaling,
    List<String>? homeSectionOrder,
    Set<SetupHighlight> highlights = const <SetupHighlight>{},
    bool focusLibraryPages = false,
  }) async {
    final database = createTestDatabase();
    await tester.runAsync(database.appSettingsDao.getSettings);
    final settings = const AppSettingsModel.defaults().copyWith(
      homeSectionOrder: homeSectionOrder,
    );
    final container = ProviderContainer(
      overrides: withTestDatabase(
        database,
        overrides: <Override>[
          appSettingsProvider.overrideWithValue(AsyncData(settings)),
          pendingSetupHighlightsProvider.overrideWithValue(highlights),
          setupHighlightsServiceProvider.overrideWith(
            (ref) => SetupHighlightsService(() async {}, () async {}, (
              option,
            ) async {
              seenOptions.add(option);
            }),
          ),
        ],
      ),
    );
    addTearDown(() async {
      container.dispose();
      await database.close();
    });

    final screen = InterfaceSettingsScreen(
      focusLibraryPages: focusLibraryPages,
    );
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
              ? screen
              : AdaptiveContextScope(
                  adaptiveContext: adaptiveContext,
                  child: screen,
                ),
        ),
      ),
    );
    // The Page Visibility icon blinks forever, so the page never settles.
    if (adaptiveContext == null) {
      await tester.pump(const Duration(milliseconds: 500));
    } else {
      await tester.pump();
    }
    return container;
  }

  testWidgets('a phone shows Home Sections and Page Visibility, never empty', (
    tester,
  ) async {
    setAdaptiveTestViewport(tester, const Size(390, 844));
    await pumpInterface(tester);
    expect(find.text('Interface'), findsOneWidget); // the AppBar title
    expect(find.text(l10n.appearanceHomeSectionsLabel), findsOneWidget);
    expect(find.text(l10n.appearancePagesSectionLabel), findsOneWidget);
    expect(find.text(l10n.desktopNavbarSectionLabel), findsNothing);
    // Nothing a Look saves lives here.
    expect(find.text(l10n.appearanceThemeModeLabel), findsNothing);
    expect(find.text(l10n.appearanceDensityLabel), findsNothing);
  });

  testWidgets('desktop adds Desktop Navigation, keeps the back button and '
      'the 1040 width', (tester) async {
    setAdaptiveTestViewport(tester, const Size(1280, 800));
    await pumpInterface(
      tester,
      adaptiveContext: resolveAdaptiveContext(
        desktopRuntime: true,
        viewportSize: const Size(1280, 800),
        safePadding: EdgeInsets.zero,
      ),
    );

    expect(find.byTooltip('Back'), findsOneWidget);
    expect(tester.getSize(find.byType(ListView)).width, 1040);
    expect(find.text(l10n.desktopNavbarSectionLabel), findsOneWidget);
    await expectLater(
      find.byType(InterfaceSettingsScreen),
      matchesGoldenFile('goldens/interface_settings_desktop_workspace.png'),
    );
  });

  testWidgets('Home Sections, Page Visibility and Desktop Navigation keep '
      'their order', (tester) async {
    tallView(tester);
    await pumpInterface(
      tester,
      adaptiveContext: resolveAdaptiveContext(
        desktopRuntime: true,
        viewportSize: const Size(800, 3200),
        safePadding: EdgeInsets.zero,
      ),
    );
    double top(String text) => tester.getTopLeft(find.text(text).first).dy;
    expect(
      top(l10n.appearancePagesSectionLabel),
      greaterThan(top(l10n.appearanceHomeSectionsLabel)),
    );
    expect(
      top(l10n.desktopNavbarSectionLabel),
      greaterThan(top(l10n.appearancePagesSectionLabel)),
    );
  });

  testWidgets('fits a phone at 2.0x text without overflow', (tester) async {
    setAdaptiveTestViewport(tester, const Size(390, 844));
    await pumpInterface(tester, textScaler: const TextScaler.linear(2));
    await tester.tap(find.text(l10n.appearanceHomeSectionsLabel));
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.takeException(), isNull);
  });

  group('focus=libraryPages deep link', () {
    final genresRow = find.byKey(const ValueKey<String>('library-page-genres'));

    Material material(WidgetTester tester) =>
        tester.widget<Material>(genresRow);

    testWidgets(
      'opens Library pages, scrolls to the Genres row and highlights it',
      (tester) async {
        setAdaptiveTestViewport(tester, const Size(390, 844));
        // The group's eye icon blinks forever, so pump by time, not settle.
        await pumpInterface(
          tester,
          focusLibraryPages: true,
          highlights: const <SetupHighlight>{SetupHighlight.genresPage},
        );
        await tester.pump(const Duration(milliseconds: 500));

        expect(genresRow, findsOneWidget);
        final rect = tester.getRect(genresRow);
        expect(rect.top, greaterThanOrEqualTo(0));
        expect(rect.bottom, lessThanOrEqualTo(844));
        expect(genresRow.hitTestable(), findsOneWidget);
        expect(
          find.descendant(of: genresRow, matching: find.byType(NewFeatureTag)),
          findsOneWidget,
        );
        final colors = Theme.of(tester.element(genresRow)).colorScheme;
        expect(material(tester).color, colors.primary.withValues(alpha: 0.22));

        await tester.pump(const Duration(seconds: 3));
        expect(material(tester).color, Colors.transparent);
      },
    );

    testWidgets('works on the desktop layout too', (tester) async {
      setAdaptiveTestViewport(tester, const Size(1280, 800));
      await pumpInterface(
        tester,
        focusLibraryPages: true,
        highlights: const <SetupHighlight>{SetupHighlight.genresPage},
        adaptiveContext: resolveAdaptiveContext(
          desktopRuntime: true,
          viewportSize: const Size(1280, 800),
          safePadding: EdgeInsets.zero,
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));

      expect(genresRow, findsOneWidget);
      final rect = tester.getRect(genresRow);
      expect(rect.top, greaterThanOrEqualTo(0));
      expect(rect.bottom, lessThanOrEqualTo(800));
      expect(genresRow.hitTestable(), findsOneWidget);
      final colors = Theme.of(tester.element(genresRow)).colorScheme;
      expect(material(tester).color, colors.primary.withValues(alpha: 0.22));
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('without the link the group stays closed', (tester) async {
      setAdaptiveTestViewport(tester, const Size(390, 844));
      await pumpInterface(tester);

      expect(genresRow.hitTestable(), findsNothing);
    });
  });

  testWidgets(
    'mobile Home offers an automatic recommendation preference off by default',
    (tester) async {
      setAdaptiveTestViewport(tester, const Size(390, 844));
      final container = await pumpInterface(tester);
      final home = find.text('Home Sections');
      await tester.scrollUntilVisible(
        home,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(home);
      await tester.pump();
      await tester.tap(home);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final control = find.widgetWithText(
        SwitchListTile,
        'Automatically Advance Recommendations',
      );
      await tester.scrollUntilVisible(
        control,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.widget<SwitchListTile>(control).value, isFalse);
      await tester.ensureVisible(control);
      await tester.pump();
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

  testWidgets(
    'a saved Home order lists New Releases right under You Might Like',
    (tester) async {
      // Saved by 1.4.2, before New Releases existed.
      await pumpInterface(
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

  group('New tags', () {
    testWidgets('the Library pages group header carries the Genres tag', (
      tester,
    ) async {
      tallView(tester);
      final header = find
          .ancestor(
            of: find.text(l10n.appearancePagesSectionLabel),
            matching: find.byType(InkWell),
          )
          .first;
      await pumpInterface(
        tester,
        highlights: <SetupHighlight>{SetupHighlight.genresPage},
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        find.descendant(of: header, matching: find.byType(NewFeatureTag)),
        findsOneWidget,
      );
    });

    testWidgets('the group header has no tag when nothing is pending', (
      tester,
    ) async {
      tallView(tester);
      await pumpInterface(tester);
      await tester.pump(const Duration(milliseconds: 500));
      final header = find
          .ancestor(
            of: find.text(l10n.appearancePagesSectionLabel),
            matching: find.byType(InkWell),
          )
          .first;
      expect(
        find.descendant(of: header, matching: find.byType(NewFeatureTag)),
        findsNothing,
      );
    });

    testWidgets('the Genres tag clears only once its group is open', (
      tester,
    ) async {
      tallView(tester);
      await pumpInterface(
        tester,
        highlights: <SetupHighlight>{SetupHighlight.genresPage},
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(seenOptions, isEmpty);

      await tester.ensureVisible(find.text(l10n.appearancePagesSectionLabel));
      await tester.tap(find.text(l10n.appearancePagesSectionLabel));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(seenOptions, <SetupHighlight>[SetupHighlight.genresPage]);
    });
  });
}
