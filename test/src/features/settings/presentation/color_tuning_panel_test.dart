import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/features/player/presentation/adjustment_ruler.dart';
import 'package:navis/src/features/settings/presentation/color_tuning_panel.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/theme/color_adjustment.dart';
import 'package:navis/src/theme/navis_color_style.dart';
import 'package:navis/src/theme/navis_style_schemes.dart';
import 'package:navis/src/theme/navis_theme.dart';

import '../../../../helpers/adaptive_test_harness.dart';

const _seed = Color(0xFF3F7BE0);

/// The panel with a plain host: no presets, a notifier for the live tuning and
/// recorded callbacks, the way setup drives it from its draft.
class _Host extends StatefulWidget {
  const new({
    required this.live,
    required this.previews,
    required this.commits,
    this.previewEnds,
    this.dark = true,
    this.textScale = 1,
    this.textDirection = TextDirection.ltr,
  });

  final ValueNotifier<ColorTuning> live;
  final List<ColorTuning> previews;
  final List<ColorTuning> commits;
  final List<int>? previewEnds;
  final bool dark;
  final double textScale;
  final TextDirection textDirection;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      localizationsDelegates: navisLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: widget.dark
          ? buildDarkTheme(_seed, style: NavisColorStyle.pastel)
          : buildLightTheme(_seed, style: NavisColorStyle.pastel),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(widget.textScale)),
        child: Directionality(
          textDirection: widget.textDirection,
          child: AdaptiveContextScope(
            adaptiveContext: resolveAdaptiveContext(
              desktopRuntime: false,
              viewportSize: MediaQuery.sizeOf(context),
              safePadding: EdgeInsets.zero,
            ),
            child: child!,
          ),
        ),
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            key: const ValueKey('open'),
            onPressed: () => showColorTuningPanel(
              context,
              basis: ColorTuningBasis(
                seed: _seed,
                style: NavisColorStyle.pastel,
                brightness: widget.dark ? Brightness.dark : Brightness.light,
                oled: false,
                darkIsOled: false,
              ),
              tuning: widget.live,
              onPreview: (tuning) {
                widget.previews.add(tuning);
                widget.live.value = tuning;
              },
              onCommit: (tuning) {
                widget.commits.add(tuning);
                widget.live.value = tuning;
              },
              onPreviewEnd: () => widget.previewEnds?.add(1),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
  }
}

Finder _key(String name) => find.byKey(ValueKey<String>('colorTuning-$name'));
Finder _ruler(String name) => _key('$name-ruler');

void main() {
  late ValueNotifier<ColorTuning> live;
  late List<ColorTuning> previews;
  late List<ColorTuning> commits;
  late List<int> previewEnds;

  setUp(() {
    live = ValueNotifier<ColorTuning>(ColorTuning.none);
    previews = <ColorTuning>[];
    commits = <ColorTuning>[];
    previewEnds = <int>[];
    addTearDown(live.dispose);
  });

  Future<void> open(
    WidgetTester tester, {
    ColorTuning tuning = ColorTuning.none,
    bool dark = true,
    double textScale = 1,
    TextDirection textDirection = TextDirection.ltr,
    Size size = const Size(390, 844),
  }) async {
    live.value = tuning;
    setAdaptiveTestViewport(tester, size);
    await tester.pumpWidget(
      _Host(
        live: live,
        previews: previews,
        commits: commits,
        previewEnds: previewEnds,
        dark: dark,
        textScale: textScale,
        textDirection: textDirection,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();
  }

  group('colorTuningSummary', () {
    late AppLocalizations l10n;
    setUpAll(() => l10n = lookupAppLocalizations(const Locale('en')));

    String summary(ColorTuning tuning, {bool dark = true}) =>
        colorTuningSummary(l10n, tuning, dark: dark);

    test('is Default for no tuning', () {
      expect(summary(ColorTuning.none), 'Default');
    });

    test('lists the steps that are not zero, with a true minus', () {
      expect(
        summary(const ColorTuning(vividness: 2, darkDepth: -1)),
        'Intensity +2 · Brightness −1',
      );
      expect(summary(const ColorTuning(vividness: -5)), 'Intensity −5');
      expect(summary(const ColorTuning(darkDepth: 4)), 'Brightness +4');
    });

    test('Brightness is the mode shown', () {
      const tuning = ColorTuning(lightDepth: 3, darkDepth: -2);
      expect(summary(tuning), 'Brightness −2');
      expect(summary(tuning, dark: false), 'Brightness +3');
    });

    test('names the other mode when only it is adjusted', () {
      expect(summary(const ColorTuning(lightDepth: 3)), 'Light Brightness +3');
      expect(
        summary(const ColorTuning(darkDepth: -1), dark: false),
        'Dark Brightness −1',
      );
    });
  });

  group('without presets', () {
    testWidgets('shows no picker, Default readouts and a disabled Reset', (
      tester,
    ) async {
      await open(tester);
      expect(find.byType(DropdownMenu<String>), findsNothing);
      expect(find.text('Preset'), findsNothing);
      expect(find.text('Default'), findsNWidgets(3));
      expect(tester.widget<TextButton>(_key('reset')).onPressed, isNull);
    });

    testWidgets('previews every whole step while dragging, commits on '
        'release', (tester) async {
      await open(tester);
      final gesture = await tester.startGesture(
        tester.getCenter(_ruler('color')),
      );
      for (var i = 0; i < 8; i++) {
        await gesture.moveBy(const Offset(-32, 0));
        await tester.pump();
      }
      expect(commits, isEmpty, reason: 'nothing is committed mid-drag');
      expect(previews, isNotEmpty);
      final steps = previews.map((p) => p.vividness).toList();
      for (var i = 1; i < steps.length; i++) {
        expect(steps[i], steps[i - 1] + 1, reason: 'one preview per step');
      }
      expect(previews.map((p) => p.lightDepth), everyElement(0));
      expect(previews.map((p) => p.darkDepth), everyElement(0));

      await gesture.up();
      await tester.pumpAndSettle();
      expect(commits, hasLength(1));
      expect(commits.single, previews.last);
      expect(previewEnds, isEmpty);
    });

    testWidgets('steppers commit each press and stop at the ends', (
      tester,
    ) async {
      await open(tester, tuning: const ColorTuning(vividness: 4));
      await tester.tap(_key('color-plus'));
      await tester.pumpAndSettle();
      expect(commits.last, const ColorTuning(vividness: 5));
      IconButton button(String name) => tester.widget<IconButton>(
        find.descendant(of: _key(name), matching: find.byType(IconButton)),
      );
      expect(button('color-plus').onPressed, isNull);
      expect(button('color-minus').onPressed, isNotNull);
      expect(button('brightness-plus').onPressed, isNotNull);
    });

    testWidgets('arrow keys step and Home resets', (tester) async {
      await open(tester);
      await tester.tap(_ruler('color'));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(commits.last, const ColorTuning(vividness: 2));

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(commits.last, const ColorTuning(vividness: 1));

      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.pumpAndSettle();
      expect(commits.last, ColorTuning.none);
    });

    testWidgets('Reset commits Default and the rulers glide back', (
      tester,
    ) async {
      await open(
        tester,
        tuning: const ColorTuning(vividness: -3, lightDepth: 1, darkDepth: 4),
      );
      expect(tester.widget<Text>(_key('color-value')).data, '−3');
      await tester.tap(_key('reset'));
      await tester.pumpAndSettle();
      expect(commits.single, ColorTuning.none);
      expect(tester.widget<Text>(_key('color-value')).data, 'Default');
      expect(tester.widget<Text>(_key('brightness-value')).data, 'Default');
      expect(tester.widget<Text>(_key('summary')).data, 'Default');
    });

    testWidgets('a value changed elsewhere moves the rulers and the summary', (
      tester,
    ) async {
      await open(tester);
      live.value = const ColorTuning(darkDepth: 4);
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(_key('brightness-value')).data, '+4');
      expect(tester.widget<Text>(_key('summary')).data, 'Brightness +4');
    });

    testWidgets('closing mid-drag tells the host to drop its preview', (
      tester,
    ) async {
      await open(tester);
      final gesture = await tester.startGesture(
        tester.getCenter(_ruler('color')),
      );
      for (var i = 0; i < 4; i++) {
        await gesture.moveBy(const Offset(-20, 0));
        await tester.pump();
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(previewEnds, [1]);
      await gesture.up();
    });

    testWidgets('closing after a commit does not', (tester) async {
      await open(tester);
      await tester.tap(_key('color-plus'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('quickPanelClose')));
      await tester.pumpAndSettle();
      expect(previewEnds, isEmpty);
    });
  });

  group('Brightness switch', () {
    testWidgets('edits the selected mode and keeps the rest', (tester) async {
      await open(
        tester,
        tuning: const ColorTuning(vividness: 1, lightDepth: -2, darkDepth: 3),
      );
      await tester.tap(find.text('Light'));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(_key('brightness-value')).data, '−2');
      await tester.tap(_key('brightness-plus'));
      await tester.pumpAndSettle();
      expect(
        commits.last,
        const ColorTuning(vividness: 1, lightDepth: -1, darkDepth: 3),
      );

      await tester.tap(find.text('Dark'));
      await tester.pumpAndSettle();
      await tester.tap(_key('brightness-minus'));
      await tester.pumpAndSettle();
      expect(
        commits.last,
        const ColorTuning(vividness: 1, lightDepth: -1, darkDepth: 2),
      );
    });

    testWidgets('does not change the tuning by itself', (tester) async {
      await open(tester, tuning: const ColorTuning(darkDepth: 3));
      await tester.tap(find.text('Light'));
      await tester.pumpAndSettle();
      expect(previews, isEmpty);
      expect(commits, isEmpty);
    });

    testWidgets('Dark strip is OLED only when Dark would be', (tester) async {
      Future<RulerBand> darkStrip({required bool darkIsOled}) async {
        live.value = ColorTuning.none;
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: navisLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Builder(
              builder: (context) => TextButton(
                key: const ValueKey('open'),
                onPressed: () => showColorTuningPanel(
                  context,
                  basis: ColorTuningBasis(
                    seed: _seed,
                    style: NavisColorStyle.pastel,
                    brightness: Brightness.light,
                    oled: false,
                    darkIsOled: darkIsOled,
                  ),
                  tuning: live,
                  onPreview: (_) {},
                  onCommit: (_) {},
                ),
                child: const Text('open'),
              ),
            ),
          ),
        );
        await tester.tap(find.byKey(const ValueKey('open')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Dark'));
        await tester.pumpAndSettle();
        final band = tester.widget<AdjustmentRuler>(_ruler('brightness')).band!;
        await tester.pumpWidget(const SizedBox());
        return band;
      }

      setAdaptiveTestViewport(tester, const Size(390, 844));
      final oled = await darkStrip(darkIsOled: true);
      final dark = await darkStrip(darkIsOled: false);
      ColorScheme scheme({required bool oled}) => buildStyledColorScheme(
        seed: _seed,
        brightness: Brightness.dark,
        oled: oled,
        style: NavisColorStyle.pastel,
      );
      expect(oled.colors[5], scheme(oled: true).surfaceContainerHigh);
      expect(dark.colors[5], scheme(oled: false).surface);
    });
  });

  group('swatches', () {
    for (final dark in <bool>[false, true]) {
      testWidgets('Intensity is the real primary at every step '
          '(${dark ? 'dark' : 'light'})', (tester) async {
        const adjustment = ColorAdjustment(vividness: 1, depth: -2);
        await open(
          tester,
          dark: dark,
          tuning: ColorTuning(
            vividness: 1,
            lightDepth: dark ? 0 : -2,
            darkDepth: dark ? -2 : 0,
          ),
        );
        final base = buildStyledColorScheme(
          seed: _seed,
          brightness: dark ? Brightness.dark : Brightness.light,
          oled: false,
          style: NavisColorStyle.pastel,
        );
        final strip = tester.widget<AdjustmentRuler>(_ruler('color')).band!;
        for (var step = -5; step <= 5; step++) {
          final tuned = adjustColorScheme(
            base,
            ColorAdjustment(vividness: step, depth: adjustment.depth),
            dark: dark,
            oled: false,
          );
          expect(strip.colors[step + 5], tuned.primary, reason: 'step $step');
          expect(strip.inks[step + 5], tuned.onPrimary, reason: 'ink $step');
        }
        expect(strip.colors.first, isNot(strip.colors.last));
      });
    }

    testWidgets('hold still while the theme recolours around them', (
      tester,
    ) async {
      await open(tester);
      final before = tester.widget<AdjustmentRuler>(_ruler('color')).band;
      await tester.tap(_key('brightness-plus'));
      await tester.pumpAndSettle();
      expect(tester.widget<AdjustmentRuler>(_ruler('color')).band, before);
    });
  });

  group('semantics and layout', () {
    testWidgets('rulers expose their value and the next steps', (tester) async {
      final handle = tester.ensureSemantics();
      await open(tester, tuning: const ColorTuning(vividness: -2));
      final data = tester.getSemantics(_ruler('color')).getSemanticsData();
      expect(data.label, 'Intensity');
      expect(data.value, '−2');
      expect(data.increasedValue, '−1');
      expect(data.decreasedValue, '−3');
      expect(find.byTooltip('Make colors more muted'), findsOneWidget);
      expect(find.byTooltip('Make colors more vivid'), findsOneWidget);
      expect(find.byTooltip('Make backgrounds lighter'), findsOneWidget);
      expect(find.byTooltip('Make backgrounds deeper'), findsOneWidget);
      handle.dispose();
    });

    for (final scale in <double>[1.3, 2]) {
      testWidgets('fits a small phone at ${scale * 100}% text', (tester) async {
        await open(
          tester,
          tuning: const ColorTuning(vividness: -3, lightDepth: 2),
          textScale: scale,
          size: const Size(320, 640),
        );
        // Light is not the mode shown, so the caption is in play too.
        await tester.ensureVisible(find.text('Light'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Light'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        // Whatever does not fit scrolls under the pinned header and footer.
        expect(find.byKey(const ValueKey('quickPanelFooter')), findsOneWidget);
      });
    }

    testWidgets('stays left-to-right like Speed and Pitch', (tester) async {
      await open(tester, textDirection: TextDirection.rtl);
      expect(
        tester.getCenter(_key('color-minus')).dx,
        lessThan(tester.getCenter(_ruler('color')).dx),
      );
      expect(
        tester.getCenter(_key('color-plus')).dx,
        greaterThan(tester.getCenter(_ruler('color')).dx),
      );
      expect(
        tester.getTopLeft(find.text('Muted')).dx,
        lessThan(tester.getTopLeft(find.text('Vivid')).dx),
      );
    });
  });
}
