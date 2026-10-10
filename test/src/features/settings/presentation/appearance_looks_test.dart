import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/common/preset_names.dart';
import 'package:navis/src/common_widgets/new_feature_tag.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/onboarding/domain/setup_highlights.dart';
import 'package:navis/src/features/onboarding/presentation/setup_highlights_provider.dart';
import 'package:navis/src/features/settings/domain/appearance_presets.dart';
import 'package:navis/src/features/settings/domain/navis_density.dart';
import 'package:navis/src/features/settings/presentation/appearance_preset_controller.dart';
import 'package:navis/src/features/settings/presentation/appearance_preset_pickers.dart';
import 'package:navis/src/features/settings/presentation/appearance_settings_screen.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/theme/color_adjustment.dart';
import 'package:navis/src/theme/navis_color_style.dart';
import 'package:navis/src/theme/navis_theme.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../../../helpers/adaptive_test_harness.dart';
import '../../../../helpers/test_database.dart';

/// Looks at the top of Appearance: saved snapshots of the whole appearance in
/// a picker, acting through the Looks controller against a real settings
/// stream.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final seen = <SetupHighlight>[];
  late NavisDatabase database;
  late ProviderContainer container;

  setUpAll(() async {
    final inter = FontLoader(navisFontFamily)
      ..addFont(rootBundle.load('assets/fonts/InterVariable.ttf'));
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await Future.wait([inter.load(), icons.load()]);
  });

  setUp(() {
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
    seen.clear();
  });

  /// The option alone, or the whole Appearance screen when [screen] is set.
  Future<void> pump(
    WidgetTester tester, {
    bool screen = false,
    Set<SetupHighlight> highlights = const <SetupHighlight>{},
    Future<void> Function()? seed,
  }) async {
    setAdaptiveTestViewport(
      tester,
      screen ? const Size(390, 1500) : const Size(390, 400),
    );
    database = createTestDatabase();
    await tester.runAsync(() async {
      await database.appSettingsDao.getSettings();
      await database.appSettingsDao.updateColorStyle('pastel');
      await database.appSettingsDao.updateThemeMode('dark');
    });
    container = ProviderContainer(
      overrides: withTestDatabase(
        database,
        overrides: <Override>[
          pendingSetupHighlightsProvider.overrideWithValue(highlights),
          nowProvider.overrideWithValue(() => DateTime(2026, 10, 10, 23)),
          setupHighlightsServiceProvider.overrideWith(
            (ref) => SetupHighlightsService(
              () async {},
              () async {},
              (option) async => seen.add(option),
            ),
          ),
          customColorPresetsProvider.overrideWithValue(
            const AsyncData(<int>[]),
          ),
        ],
      ),
    );
    addTearDown(() async {
      container.dispose();
      await database.close();
    });
    if (seed != null) await tester.runAsync(seed);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          localizationsDelegates: navisLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: buildDarkTheme(
            resolveColorSchemeSeedColor(null),
            style: NavisColorStyle.pastel,
          ),
          home: screen
              ? const AppearanceSettingsScreen()
              : Scaffold(
                  body: Align(
                    alignment: Alignment.topCenter,
                    child: RepaintBoundary(
                      key: const ValueKey<String>('looksShot'),
                      child: Builder(
                        builder: (context) => ColoredBox(
                          color: Theme.of(context).colorScheme.surface,
                          child: const AppearanceLooksOption(),
                        ),
                      ),
                    ),
                  ),
                ),
        ),
      ),
    );
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> settleWrites(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
  }

  /// Changes appearance settings the way Settings does. Each write gets its
  /// own turn so the stream's re-query, which lives in the fake-async zone,
  /// runs before the next write queues behind it.
  Future<void> change(
    WidgetTester tester,
    List<Future<void> Function()> writes,
  ) async {
    for (final write in writes) {
      await tester.runAsync(write);
      await settleWrites(tester);
    }
    await tester.pumpAndSettle();
  }

  AppearanceLooksState looks() =>
      container.read(appearanceLooksControllerProvider);

  /// Saves the current appearance as a Look through the controller. The write
  /// finishes when the settings stream, which lives in the fake-async zone,
  /// has delivered the row, so the test pumps while it waits.
  Future<void> saveLook(WidgetTester tester, String name) async {
    var done = false;
    final saving = container
        .read(appearanceLooksControllerProvider.notifier)
        .saveAsNew(name)
        .whenComplete(() => done = true);
    for (var i = 0; i < 20 && !done; i++) {
      await settleWrites(tester);
    }
    await saving;
    await tester.pumpAndSettle();
  }

  /// The option's own height, so the golden holds the option and little else.
  Future<void> shrinkToOption(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 156);
    await tester.pumpAndSettle();
  }

  final dropdown = find.byKey(const ValueKey<String>('appearanceLookDropdown'));
  final input = find.byKey(const ValueKey<String>('appearanceLookNameInput'));

  String pickerText(WidgetTester tester) => tester
      .widget<TextField>(
        find.descendant(of: dropdown, matching: find.byType(TextField)),
      )
      .controller!
      .text;

  Future<void> menu(WidgetTester tester, String action) async {
    await tester.tap(
      find.byKey(const ValueKey<String>('appearanceLookActions')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey<String>('appearanceLook$action')));
    await tester.pumpAndSettle();
  }

  Future<String?> submitName(WidgetTester tester, String name) async {
    await tester.enterText(input, name);
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pump();
    await settleWrites(tester);
    await tester.pumpAndSettle();
    if (input.evaluate().isEmpty) return null;
    return tester.widget<TextField>(input).decoration?.errorText;
  }

  Future<void> chooseLook(WidgetTester tester, String name) async {
    await tester.tap(dropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text(name).last);
    await tester.pump();
    await settleWrites(tester);
    await tester.pumpAndSettle();
  }

  group('empty state', () {
    testWidgets('reads Custom and points at the menu for the first save', (
      tester,
    ) async {
      await pump(tester);
      expect(find.text('Looks'), findsOneWidget);
      expect(pickerText(tester), 'Custom');
      expect(
        find.text(
          'Save your whole appearance from the menu, then switch back to it '
          'any time.',
        ),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('appearanceLookActions')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Save Current as New Look'), findsOneWidget);
      for (final action in <String>['Update', 'Rename', 'Delete']) {
        expect(
          find.byKey(ValueKey<String>('appearanceLook$action')),
          findsNothing,
          reason: action,
        );
      }
    });

    testWidgets('golden: empty', (tester) async {
      await pump(tester);
      await shrinkToOption(tester);
      await expectLater(
        find.byKey(const ValueKey<String>('looksShot')),
        matchesGoldenFile('goldens/appearance_looks_empty.png'),
      );
    });
  });

  group('saving', () {
    testWidgets('Save Current as New Look captures the whole appearance and '
        'selects it', (tester) async {
      await pump(tester);
      await menu(tester, 'SaveNew');
      expect(find.text('Look name'), findsOneWidget);
      expect(await submitName(tester, '  Evening  '), isNull);

      final saved = looks();
      expect(saved.looks.single.name, 'Evening');
      expect(saved.selectedLookId, saved.looks.single.id);
      final settings = container.read(appSettingsProvider).requireValue;
      expect(saved.looks.single.snapshot, AppearanceSnapshot.capture(settings));
      expect(pickerText(tester), 'Evening');
      expect(
        find.text('Save and switch your whole appearance.'),
        findsOneWidget,
      );
    });

    testWidgets('names are validated inline', (tester) async {
      await pump(tester);
      await saveLook(tester, 'Evening');
      await menu(tester, 'SaveNew');
      expect(await submitName(tester, ' '), 'Enter a name.');
      expect(
        await submitName(tester, 'evening'),
        'That name is already in use.',
      );
      expect(
        await submitName(tester, 'Default'),
        'Default is reserved. Choose another name.',
      );
      expect(looks().looks, hasLength(1));
    });
  });

  group('with Looks', () {
    testWidgets('golden: a Look selected', (tester) async {
      await pump(tester);
      await saveLook(tester, 'Evening');
      await shrinkToOption(tester);
      await expectLater(
        find.byKey(const ValueKey<String>('looksShot')),
        matchesGoldenFile('goldens/appearance_looks_selected.png'),
      );
    });

    testWidgets('choosing a Look applies all of it', (tester) async {
      await pump(tester);
      await change(tester, [
        () => database.appSettingsDao.updateCornerStyle('square'),
        () => database.appSettingsDao.updateDensity(NavisDensity.compact),
        () => database.appSettingsDao.updateColorTuning(
          const ColorTuning(vividness: 2, darkDepth: -1),
        ),
      ]);
      await saveLook(tester, 'Crisp');
      await change(tester, [
        () => database.appSettingsDao.updateCornerStyle('rounded'),
        () => database.appSettingsDao.updateColorTuning(ColorTuning.none),
      ]);
      expect(pickerText(tester), 'Custom');
      expect(looks().selectedLookId, isNull);

      await chooseLook(tester, 'Crisp');
      final settings = container.read(appSettingsProvider).requireValue;
      expect(settings.cornerStyle.name, 'square');
      expect(
        settings.colorTuning,
        const ColorTuning(vividness: 2, darkDepth: -1),
      );
      expect(pickerText(tester), 'Crisp');
    });

    testWidgets('changing anything afterwards reads Custom', (tester) async {
      await pump(tester);
      await saveLook(tester, 'Evening');
      expect(pickerText(tester), 'Evening');
      await change(tester, [
        () => database.appSettingsDao.updateCornerStyle('square'),
      ]);
      expect(pickerText(tester), 'Custom');
    });

    testWidgets('Update saves the current appearance over the Look it came '
        'from', (tester) async {
      await pump(tester);
      await saveLook(tester, 'Evening');
      await change(tester, [
        () => database.appSettingsDao.updateCornerStyle('square'),
      ]);
      expect(pickerText(tester), 'Custom');

      await menu(tester, 'Update');
      await settleWrites(tester);
      await tester.pumpAndSettle();
      expect(pickerText(tester), 'Evening');
      expect(looks().looks.single.snapshot.cornerStyle, 'square');
    });

    testWidgets('Rename keeps the snapshot and validates the name', (
      tester,
    ) async {
      await pump(tester);
      await saveLook(tester, 'Evening');
      await change(tester, [
        () => database.appSettingsDao.updateCornerStyle('square'),
      ]);
      await saveLook(tester, 'Crisp');
      await chooseLook(tester, 'Evening');
      final before = looks().looks.first.snapshot;

      await menu(tester, 'Rename');
      expect(await submitName(tester, 'crisp'), 'That name is already in use.');
      expect(await submitName(tester, 'Night Drive'), isNull);
      expect(looks().looks.first.name, 'Night Drive');
      expect(looks().looks.first.snapshot, before);
      expect(pickerText(tester), 'Night Drive');
    });

    testWidgets('Delete asks first and leaves the appearance as it is', (
      tester,
    ) async {
      await pump(tester);
      await saveLook(tester, 'Evening');
      await menu(tester, 'Delete');
      expect(find.text('Delete “Evening”?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(looks().looks, hasLength(1));

      await menu(tester, 'Delete');
      await tester.tap(
        find.byKey(const ValueKey<String>('appearanceLookDeleteConfirm')),
      );
      await tester.pump();
      await settleWrites(tester);
      await tester.pumpAndSettle();
      expect(looks().looks, isEmpty);
      expect(pickerText(tester), 'Custom');
      expect(
        find.text(
          'Save your whole appearance from the menu, then switch back to it '
          'any time.',
        ),
        findsOneWidget,
      );
    });
  });

  group('on the Appearance screen', () {
    testWidgets('sits at the top, above the Theme section', (tester) async {
      await pump(tester, screen: true);
      double top(String text) => tester.getTopLeft(find.text(text)).dy;
      expect(top('Looks'), lessThan(top('Theme')));
      expect(find.byType(AppearanceLooksOption), findsOneWidget);
    });

    testWidgets('shows its New tag and clears it through the seen mechanism', (
      tester,
    ) async {
      await pump(
        tester,
        screen: true,
        highlights: <SetupHighlight>{SetupHighlight.appearanceLooks},
      );
      final tag = find.descendant(
        of: find
            .ancestor(of: find.text('Looks'), matching: find.byType(Row))
            .first,
        matching: find.byType(NewFeatureTag),
      );
      expect(tag, findsOneWidget);
      expect(seen, <SetupHighlight>[SetupHighlight.appearanceLooks]);
    });

    testWidgets('has no tag when nothing is pending', (tester) async {
      await pump(tester, screen: true);
      expect(find.byType(NewFeatureTag), findsNothing);
      expect(seen, isEmpty);
    });
  });

  test('every failure has words, for Looks and for presets', () {
    final l10n = lookupAppLocalizations(const Locale('en'));
    for (final failure in PresetFailure.values) {
      expect(presetFailureMessage(l10n, failure), isNotEmpty);
      expect(presetFailureMessage(l10n, failure, look: true), isNotEmpty);
    }
    expect(
      presetFailureMessage(l10n, PresetFailure.notFound, look: true),
      'That Look no longer exists.',
    );
    expect(
      presetFailureMessage(l10n, PresetFailure.notFound),
      'That preset no longer exists.',
    );
  });
}
