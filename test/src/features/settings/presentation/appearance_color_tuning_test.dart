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
    final seenPreviews = <ColorAdjustment?>[];
    container.listen(
      colorAdjustmentPreviewProvider,
      (_, next) => seenPreviews.add(next),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(key('color-ruler')),
    );
    for (var i = 0; i < 8; i++) {
      await gesture.moveBy(const Offset(-16, 0));
      await tester.pump();
    }
    final live = container.read(effectiveColorAdjustmentProvider);
    expect(live.vividness, greaterThanOrEqualTo(3));
    expect(live.depth, 0);
    expect(
      container.read(colorAdjustmentProvider),
      ColorAdjustment.none,
      reason: 'nothing is saved mid-drag',
    );
    final steps = seenPreviews.whereType<ColorAdjustment>().toList();
    expect(steps.map((p) => p.vividness), [
      for (var v = 1; v <= live.vividness; v++) v,
    ]);

    await gesture.up();
    await tester.pumpAndSettle();
    await settleWrites(tester);

    final row = await tester.runAsync(database.appSettingsDao.getSettings);
    expect(row?.colorVividness, live.vividness);
    expect(row?.surfaceDepth, 0);
    expect(container.read(colorAdjustmentProvider), live);
    expect(container.read(colorAdjustmentPreviewProvider), isNull);
    expect(container.read(effectiveColorAdjustmentProvider), live);
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
      container.read(colorAdjustmentProvider),
      const ColorAdjustment(depth: 1),
    );
    expect(container.read(colorAdjustmentPreviewProvider), isNull);
    expect(key('reset'), findsOneWidget);

    await tester.tap(key('reset'));
    await tester.pumpAndSettle();
    await settleWrites(tester);
    expect(container.read(colorAdjustmentProvider), ColorAdjustment.none);
    expect(container.read(colorAdjustmentPreviewProvider), isNull);
    expect(key('reset'), findsNothing);
  });

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
    expect(container.read(colorAdjustmentPreviewProvider), isNotNull);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(container.read(colorAdjustmentPreviewProvider), isNull);
    await gesture.up();
  });
}
