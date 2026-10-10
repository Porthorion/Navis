import 'package:navis/src/features/settings/presentation/color_tuning_option.dart';
import 'package:navis/src/theme/navis_color_style.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/common_widgets/new_feature_tag.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/onboarding/domain/setup_highlights.dart';
import 'package:navis/src/features/onboarding/presentation/setup_highlights_provider.dart';
import 'package:navis/src/features/settings/presentation/appearance_settings_screen.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/theme/color_adjustment.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../../../helpers/test_database.dart';

/// Appearance > Color > Fine-Tune Colors against a real settings stream, so
/// the preview provider can be seen handing over to the saved value.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final seen = <SetupHighlight>[];
  late NavisDatabase database;
  late ProviderContainer container;

  setUp(() {
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
    seen.clear();
  });

  Future<void> pumpScreen(
    WidgetTester tester, {
    Set<SetupHighlight> highlights = const <SetupHighlight>{},
    NavisColorStyle? effectiveStyle,
  }) async {
    tester.view
      ..physicalSize = const Size(800, 1300)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    database = createTestDatabase();
    await tester.runAsync(database.appSettingsDao.getSettings);
    container = ProviderContainer(
      overrides: withTestDatabase(
        database,
        overrides: <Override>[
          pendingSetupHighlightsProvider.overrideWithValue(highlights),
          if (effectiveStyle != null)
            effectiveColorStyleProvider.overrideWithValue(effectiveStyle),
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
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          localizationsDelegates: navisLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: AppearanceSettingsScreen(),
        ),
      ),
    );
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 500));
  }

  // Flush Drift's invalidations in the fake async zone between real writes.
  Future<void> settleWrites(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
  }

  Finder key(String name) => find.byKey(ValueKey<String>('colorTuning-$name'));

  testWidgets('sits directly under Color Style, above Night Schedule', (
    tester,
  ) async {
    await pumpScreen(tester);
    double top(String text) => tester.getTopLeft(find.text(text)).dy;
    expect(top('Fine-Tune Colors'), greaterThan(top('Color Style')));
    expect(top('Fine-Tune Colors'), lessThan(top('Night Schedule')));
  });

  testWidgets('a drag recolours the app live, release saves it, then the '
      'preview hands over to the saved value', (tester) async {
    await pumpScreen(tester);
    final seenPreviews = <ColorTuning?>[];
    container.listen(
      colorTuningPreviewProvider,
      (_, next) => seenPreviews.add(next),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(key('color-ruler')),
    );
    for (var i = 0; i < 8; i++) {
      await gesture.moveBy(const Offset(-32, 0));
      await tester.pump();
    }
    final live = container.read(effectiveColorTuningProvider);
    expect(live.vividness, greaterThanOrEqualTo(3));
    expect(live.darkDepth, 0);
    expect(
      container.read(colorTuningProvider),
      ColorTuning.none,
      reason: 'nothing is saved mid-drag',
    );
    final steps = seenPreviews.whereType<ColorTuning>().toList();
    expect(steps.map((p) => p.vividness), [
      for (var v = 1; v <= live.vividness; v++) v,
    ]);

    await gesture.up();
    await tester.pumpAndSettle();
    await settleWrites(tester);

    final row = await tester.runAsync(database.appSettingsDao.getSettings);
    expect(row?.colorVividness, live.vividness);
    expect(row?.surfaceDepthDark, 0);
    expect(container.read(colorTuningProvider), live);
    expect(container.read(colorTuningPreviewProvider), isNull);
    expect(container.read(effectiveColorTuningProvider), live);
    expect(seenPreviews.last, isNull);
  });

  testWidgets('stepper and Reset save, and Reset only shows when needed', (
    tester,
  ) async {
    await pumpScreen(tester);
    expect(key('reset'), findsNothing);

    await tester.tap(key('brightness-plus'));
    await tester.pumpAndSettle();
    await settleWrites(tester);
    expect(
      container.read(colorTuningProvider),
      const ColorTuning(darkDepth: 1),
    );
    expect(container.read(colorTuningPreviewProvider), isNull);
    expect(key('reset'), findsOneWidget);

    await tester.tap(key('reset'));
    await tester.pumpAndSettle();
    await settleWrites(tester);
    expect(container.read(colorTuningProvider), ColorTuning.none);
    expect(container.read(colorTuningPreviewProvider), isNull);
    expect(key('reset'), findsNothing);
  });

  testWidgets(
    'Fine-Tune band uses the active Night style during the schedule',
    (tester) async {
      // The schedule provider's boundary timer is covered separately; simulate
      // its active style while exercising the real caller and saved settings.
      await pumpScreen(tester, effectiveStyle: NavisColorStyle.night);
      await tester.runAsync(
        () => database.appSettingsDao.updateColorStyle('pastel'),
      );
      await settleWrites(tester);
      await tester.runAsync(
        () => database.appSettingsDao.updateNightSchedule(
          enabled: true,
          startMinutes: 1320,
          endMinutes: 420,
        ),
      );
      await settleWrites(tester);
      expect(container.read(colorStyleProvider), NavisColorStyle.pastel);
      expect(
        tester.widget<ColorTuningOption>(find.byType(ColorTuningOption)).style,
        NavisColorStyle.night,
      );
    },
  );

  testWidgets(
    'Light edits retain Dark/OLED brightness and mode switches resolve it',
    (tester) async {
      await pumpScreen(tester);
      await tester.runAsync(
        () => database.appSettingsDao.updateColorTuning(
          const ColorTuning(darkDepth: 3),
        ),
      );
      await settleWrites(tester);
      await tester.runAsync(
        () => database.appSettingsDao.updateThemeMode('light'),
      );
      await settleWrites(tester);
      await tester.tap(key('brightness-plus'));
      await tester.pumpAndSettle();
      await settleWrites(tester);
      final tuning = container.read(colorTuningProvider);
      expect(tuning, const ColorTuning(lightDepth: 1, darkDepth: 3));
      for (final mode in ['dark', 'oled']) {
        await tester.runAsync(
          () => database.appSettingsDao.updateThemeMode(mode),
        );
        await settleWrites(tester);
        expect(
          tester
              .widget<ColorTuningOption>(find.byType(ColorTuningOption))
              .value
              .depth,
          3,
        );
      }
    },
  );

  testWidgets('shows its New tag and clears it through the seen mechanism', (
    tester,
  ) async {
    await pumpScreen(
      tester,
      highlights: <SetupHighlight>{SetupHighlight.colorTuning},
    );
    final tag = find.descendant(
      of: find
          .ancestor(
            of: find.text('Fine-Tune Colors'),
            matching: find.byType(Row),
          )
          .first,
      matching: find.byType(NewFeatureTag),
    );
    expect(tag, findsOneWidget);
    expect(seen, <SetupHighlight>[SetupHighlight.colorTuning]);
  });

  testWidgets('leaving mid-drag drops the preview', (tester) async {
    await pumpScreen(tester);
    final gesture = await tester.startGesture(
      tester.getCenter(key('color-ruler')),
    );
    for (var i = 0; i < 4; i++) {
      await gesture.moveBy(const Offset(-20, 0));
      await tester.pump();
    }
    expect(container.read(colorTuningPreviewProvider), isNotNull);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(container.read(colorTuningPreviewProvider), isNull);
    await gesture.up();
  });
}
