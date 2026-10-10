import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/common_widgets/new_feature_tag.dart';
import 'package:navis/src/common_widgets/preset_picker.dart';
import 'package:navis/src/common_widgets/quick_panel.dart';
import 'package:navis/src/database/daos/app_settings_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/onboarding/domain/setup_highlights.dart';
import 'package:navis/src/features/onboarding/presentation/setup_highlights_provider.dart';
import 'package:navis/src/features/player/presentation/adjustment_ruler.dart';
import 'package:navis/src/features/settings/presentation/appearance_settings_screen.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/theme/color_adjustment.dart';
import 'package:navis/src/theme/dynamic_accent_provider.dart';
import 'package:navis/src/theme/navis_color_style.dart';
import 'package:navis/src/theme/navis_style_schemes.dart';
import 'package:navis/src/theme/navis_theme.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../../../helpers/adaptive_test_harness.dart';
import '../../../../helpers/test_database.dart';

/// Appearance > Color > Fine-Tune Colors against a real settings stream: the
/// summary row, the panel it opens (a sheet on touch, a popover on desktop),
/// its rulers and Light and Dark brightness, with the app
/// recolouring around it as it does at runtime.
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

  Future<void> pumpScreen(
    WidgetTester tester, {
    bool desktop = false,
    String mode = 'dark',
    String style = 'pastel',
    Size? size,
    Set<SetupHighlight> highlights = const <SetupHighlight>{},
    NavisColorStyle? effectiveStyle,
    Future<void> Function(AppSettingsDao dao)? seed,
    double textScale = 1,
  }) async {
    setAdaptiveTestViewport(
      tester,
      size ?? (desktop ? const Size(1280, 800) : const Size(390, 1500)),
    );
    database = createTestDatabase();
    await tester.runAsync(() async {
      await database.appSettingsDao.getSettings();
      await database.appSettingsDao.updateThemeMode(mode);
      await database.appSettingsDao.updateColorStyle(style);
      await seed?.call(database.appSettingsDao);
    });
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
          dynamicAccentSeedColorProvider.overrideWith(
            (ref) => ref.watch(_dynamicSeed),
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
        child: _App(desktop: desktop, textScale: textScale),
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
  final row = find.byKey(const ValueKey<String>('colorTuningOption'));
  final panel = find.byKey(const ValueKey<String>('colorTuningPanel'));
  final popover = find.byKey(const ValueKey<String>('desktopAnchoredPopover'));

  Future<void> openPanel(WidgetTester tester) async {
    await tester.ensureVisible(row);
    await tester.tap(row);
    await tester.pumpAndSettle();
  }

  String summary(WidgetTester tester) => tester
      .widget<Text>(
        find.byKey(const ValueKey<String>('colorTuningOption-summary')),
      )
      .data!;

  String readout(WidgetTester tester, String axis) =>
      tester.widget<Text>(key('$axis-value')).data!;

  Future<void> seedTuning(WidgetTester tester, ColorTuning tuning) async {
    await tester.runAsync(
      () => database.appSettingsDao.updateColorTuning(tuning),
    );
    await settleWrites(tester);
  }

  RulerBand band(WidgetTester tester, String name) =>
      tester.widget<AdjustmentRuler>(key('$name-ruler')).band!;

  group('row', () {
    testWidgets('sits under Color Style, above Night Schedule, and holds '
        'no rulers', (tester) async {
      await pumpScreen(tester);
      double top(String text) => tester.getTopLeft(find.text(text)).dy;
      expect(top('Fine-Tune Colors'), greaterThan(top('Color Style')));
      expect(top('Fine-Tune Colors'), lessThan(top('Night Schedule')));
      expect(summary(tester), 'Default');
      expect(key('color-ruler'), findsNothing);
      expect(
        find.descendant(of: row, matching: find.byIcon(Icons.chevron_right)),
        findsOneWidget,
      );
    });

    testWidgets('sums up the non-zero steps for the mode shown', (
      tester,
    ) async {
      await pumpScreen(tester);
      await seedTuning(
        tester,
        const ColorTuning(vividness: 2, lightDepth: 3, darkDepth: -1),
      );
      expect(summary(tester), 'Intensity +2 · Brightness −1');

      await seedTuning(tester, const ColorTuning(vividness: -3));
      expect(summary(tester), 'Intensity −3');

      // Only the other mode is adjusted: say which one.
      await seedTuning(tester, const ColorTuning(lightDepth: 3));
      expect(summary(tester), 'Light Brightness +3');
    });

    testWidgets('follows Light brightness in Light mode', (tester) async {
      await pumpScreen(tester, mode: 'light');
      await seedTuning(
        tester,
        const ColorTuning(vividness: 2, lightDepth: 3, darkDepth: -1),
      );
      expect(summary(tester), 'Intensity +2 · Brightness +3');
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

    testWidgets('the band uses the active Night style during the schedule', (
      tester,
    ) async {
      await pumpScreen(tester, effectiveStyle: NavisColorStyle.night);
      await openPanel(tester);
      final night = buildStyledColorScheme(
        seed: resolveColorSchemeSeedColor(null),
        brightness: Brightness.dark,
        oled: false,
        style: NavisColorStyle.night,
      );
      expect(band(tester, 'color').colors[5], night.primary);
    });
  });

  group('panel', () {
    testWidgets('opens as a sheet on a phone', (tester) async {
      await pumpScreen(tester);
      await openPanel(tester);
      expect(panel, findsOneWidget);
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(popover, findsNothing);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('quickPanelTitle'))).data,
        'Fine-Tune Colors',
      );
      await tester.tap(find.byKey(const ValueKey('quickPanelClose')));
      await tester.pumpAndSettle();
      expect(panel, findsNothing);
    });

    testWidgets('opens as an anchored popover on desktop', (tester) async {
      await pumpScreen(tester, desktop: true);
      await openPanel(tester);
      expect(panel, findsOneWidget);
      expect(popover, findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      final card = tester.getRect(popover);
      expect(card.width, 440);
      expect(card.height, lessThanOrEqualTo(680));
    });

    testWidgets('pins the title, a live summary and Reset', (tester) async {
      await pumpScreen(tester);
      await openPanel(tester);
      expect(find.byKey(const ValueKey('quickPanelFooter')), findsOneWidget);
      String headerSummary() => tester.widget<Text>(key('summary')).data!;
      expect(headerSummary(), 'Default');
      expect(
        tester.widget<TextButton>(key('reset')).onPressed,
        isNull,
        reason: 'nothing to reset yet',
      );

      await tester.tap(key('color-plus'));
      await tester.pumpAndSettle();
      await settleWrites(tester);
      expect(headerSummary(), 'Intensity +1');
      expect(tester.widget<TextButton>(key('reset')).onPressed, isNotNull);
    });

    testWidgets('a drag recolours the app live, release saves it, then the '
        'preview hands over to the saved value', (tester) async {
      await pumpScreen(tester);
      await openPanel(tester);
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

      final saved = await tester.runAsync(database.appSettingsDao.getSettings);
      expect(saved?.colorVividness, live.vividness);
      expect(saved?.surfaceDepthDark, 0);
      expect(container.read(colorTuningProvider), live);
      expect(container.read(colorTuningPreviewProvider), isNull);
      expect(container.read(effectiveColorTuningProvider), live);
      expect(seenPreviews.last, isNull);
    });

    testWidgets('closing the panel mid-drag drops the preview', (tester) async {
      await pumpScreen(tester);
      await openPanel(tester);
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

    testWidgets('stepper and Reset save, and Reset glides the rulers back', (
      tester,
    ) async {
      await pumpScreen(tester);
      await openPanel(tester);

      await tester.tap(key('brightness-plus'));
      await tester.pumpAndSettle();
      await settleWrites(tester);
      expect(
        container.read(colorTuningProvider),
        const ColorTuning(darkDepth: 1),
      );
      expect(container.read(colorTuningPreviewProvider), isNull);

      await tester.tap(key('reset'));
      await tester.pumpAndSettle();
      await settleWrites(tester);
      expect(container.read(colorTuningProvider), ColorTuning.none);
      expect(container.read(colorTuningPreviewProvider), isNull);
      expect(readout(tester, 'brightness'), 'Default');
      expect(readout(tester, 'color'), 'Default');
    });

    testWidgets('Escape closes the desktop popover and keeps the value', (
      tester,
    ) async {
      await pumpScreen(tester, desktop: true);
      await openPanel(tester);
      await tester.tap(key('color-plus'));
      await tester.pumpAndSettle();
      await settleWrites(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(panel, findsNothing);
      expect(container.read(colorTuningProvider).vividness, 1);
      expect(summary(tester), 'Intensity +1');
    });
  });

  group('dynamic album colour', () {
    testWidgets('moves the open panel\'s strips, needle and hint with the '
        'track', (tester) async {
      await pumpScreen(tester);
      await openPanel(tester);
      ColorScheme pastel(Color seed) => buildStyledColorScheme(
        seed: seed,
        brightness: Brightness.dark,
        oled: false,
        style: NavisColorStyle.pastel,
      );
      final white = resolveColorSchemeSeedColor(null);
      expect(band(tester, 'color').colors[5], pastel(white).primary);

      const red = Color(0xFFE53935);
      container.read(_dynamicSeed.notifier).set(red.toARGB32());
      await tester.pumpAndSettle();
      expect(band(tester, 'color').colors[5], pastel(red).primary);
      expect(band(tester, 'brightness').colors[5], pastel(red).surface);
      expect(
        tester.widget<AdjustmentRuler>(key('color-ruler')).accent,
        pastel(red).primary,
      );
      // Pastel dark with a saturated seed barely moves: the hint explains.
      expect(
        tester.widget<Text>(key('color-hint')).data,
        'This style is already close to its most colorful here.',
      );

      container.read(_dynamicSeed.notifier).set(null);
      await tester.pumpAndSettle();
      expect(band(tester, 'color').colors[5], pastel(white).primary);
    });
  });

  group('Light and Dark brightness', () {
    for (final mode in <String>['light', 'dark', 'oled']) {
      testWidgets('start on the mode shown ($mode), with no caption', (
        tester,
      ) async {
        await pumpScreen(tester, mode: mode);
        await openPanel(tester);
        final selected = tester
            .widget<SegmentedButton<bool>>(key('mode'))
            .selected
            .single;
        expect(selected, mode != 'light');
        expect(key('applies'), findsNothing);
      });
    }

    testWidgets('Light edits only Light brightness, and the caption says '
        'where it applies', (tester) async {
      await pumpScreen(tester);
      await seedTuning(tester, const ColorTuning(darkDepth: 3));
      await openPanel(tester);
      expect(readout(tester, 'brightness'), '+3');

      await tester.tap(find.text('Light'));
      await tester.pumpAndSettle();
      expect(readout(tester, 'brightness'), 'Default');
      expect(tester.widget<Text>(key('applies')).data, 'Applies in Light mode');

      await tester.tap(key('brightness-plus'));
      await tester.pumpAndSettle();
      await settleWrites(tester);
      expect(
        container.read(colorTuningProvider),
        const ColorTuning(lightDepth: 1, darkDepth: 3),
      );
      expect(readout(tester, 'brightness'), '+1');

      // Back to the mode shown: Dark's value, no caption.
      await tester.tap(find.text('Dark'));
      await tester.pumpAndSettle();
      expect(readout(tester, 'brightness'), '+3');
      expect(key('applies'), findsNothing);
    });

    testWidgets('Dark names OLED too when Light is shown', (tester) async {
      await pumpScreen(tester, mode: 'light');
      await openPanel(tester);
      await tester.tap(find.text('Dark'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(key('applies')).data,
        'Applies in Dark and OLED',
      );
      await tester.tap(key('brightness-minus'));
      await tester.pumpAndSettle();
      await settleWrites(tester);
      expect(
        container.read(colorTuningProvider),
        const ColorTuning(darkDepth: -1),
      );
    });

    for (final mode in <String>['light', 'dark', 'oled']) {
      testWidgets('the strip shows the surfaces of the selected mode from '
          '$mode', (tester) async {
        await pumpScreen(tester, mode: mode);
        await openPanel(tester);
        final seed = resolveColorSchemeSeedColor(null);

        void expectStrip({required bool dark, required bool oled}) {
          final strip = band(tester, 'brightness');
          for (var step = -5; step <= 5; step++) {
            final scheme = buildStyledColorScheme(
              seed: seed,
              brightness: dark ? Brightness.dark : Brightness.light,
              oled: oled,
              style: NavisColorStyle.pastel,
              adjustment: ColorAdjustment(depth: step),
            );
            expect(
              strip.colors[step + 5],
              oled ? scheme.surfaceContainerHigh : scheme.surface,
              reason: '${dark ? 'dark' : 'light'} oled=$oled step $step',
            );
          }
        }

        expectStrip(dark: mode != 'light', oled: mode == 'oled');
        await tester.tap(find.text(mode == 'light' ? 'Dark' : 'Light'));
        await tester.pumpAndSettle();
        expectStrip(dark: mode == 'light', oled: false);
      });
    }

    testWidgets('Intensity keeps painting the mode shown', (tester) async {
      await pumpScreen(tester);
      await openPanel(tester);
      final before = band(tester, 'color');
      await tester.tap(find.text('Light'));
      await tester.pumpAndSettle();
      expect(band(tester, 'color'), before);
    });
  });

  group('layout', () {
    for (final scale in <double>[1.3, 2]) {
      testWidgets('fits a phone at ${scale * 100}% text', (tester) async {
        await pumpScreen(tester, textScale: scale);
        await seedTuning(
          tester,
          const ColorTuning(vividness: -3, lightDepth: 1, darkDepth: 2),
        );
        await openPanel(tester);
        expect(tester.takeException(), isNull);
        expect(find.byType(PresetPicker), findsNothing);
        expect(find.byType(QuickPanelScaffold), findsOneWidget);
      });
    }
  });

  group('goldens', () {
    for (final mode in <String>['light', 'dark', 'oled']) {
      testWidgets('panel in $mode (Pastel)', (tester) async {
        const soft = ColorTuning(vividness: -2, lightDepth: 1, darkDepth: 1);
        await pumpScreen(tester, mode: mode, size: const Size(390, 844));
        await seedTuning(tester, soft);
        await openPanel(tester);
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/color_tuning_panel_$mode.png'),
        );
      });
    }

    testWidgets('panel with the Intensity hint (Neutral, no accent)', (
      tester,
    ) async {
      await pumpScreen(tester, style: 'neutral', size: const Size(390, 844));
      await seedTuning(tester, const ColorTuning(darkDepth: 1));
      await openPanel(tester);
      expect(key('color-hint'), findsOneWidget);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/color_tuning_panel_hint.png'),
      );
    });

    testWidgets('panel on desktop with the other mode selected', (
      tester,
    ) async {
      await pumpScreen(tester, desktop: true);
      await seedTuning(tester, const ColorTuning(vividness: 3, lightDepth: -2));
      await openPanel(tester);
      await tester.tap(find.text('Light'));
      await tester.pumpAndSettle();
      await expectLater(
        popover,
        matchesGoldenFile('goldens/color_tuning_panel_desktop.png'),
      );
    });
  });
}

class _DynamicSeed extends Notifier<int?> {
  @override
  int? build() => null;

  void set(int? seed) => state = seed;
}

final _dynamicSeed = NotifierProvider<_DynamicSeed, int?>(_DynamicSeed.new);

/// The app around the screen: MaterialApp themed from the saved settings and
/// the live tuning, so a preview recolours the page as it does at runtime.
class _App extends ConsumerWidget {
  const new({required this.desktop, required this.textScale});

  final bool desktop;
  final double textScale;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    final style = ref.watch(colorStyleProvider);
    final seed = resolveColorSchemeSeedColor(
      ref.watch(effectiveColorSchemeSeedProvider),
    );
    final tuning = ref.watch(effectiveColorTuningProvider);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      localizationsDelegates: navisLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: buildLightTheme(
        seed,
        style: style,
        adjustment: tuning.forMode(dark: false),
      ),
      darkTheme: mode == 'oled'
          ? buildOledTheme(
              seed,
              style: style,
              adjustment: tuning.forMode(dark: true),
            )
          : buildDarkTheme(
              seed,
              style: style,
              adjustment: tuning.forMode(dark: true),
            ),
      themeMode: mode == 'light' ? ThemeMode.light : ThemeMode.dark,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          platformBrightness: mode == 'light'
              ? Brightness.light
              : Brightness.dark,
        ),
        child: AdaptiveContextScope(
          adaptiveContext: resolveAdaptiveContext(
            desktopRuntime: desktop,
            viewportSize: MediaQuery.sizeOf(context),
            safePadding: EdgeInsets.zero,
          ),
          child: child!,
        ),
      ),
      home: const AppearanceSettingsScreen(),
    );
  }
}
