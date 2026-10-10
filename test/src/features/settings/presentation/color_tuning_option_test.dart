import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/features/player/presentation/adjustment_ruler.dart';
import 'package:navis/src/features/settings/presentation/color_tuning_option.dart';
import 'package:navis/src/theme/color_adjustment.dart';
import 'package:navis/src/theme/navis_color_style.dart';
import 'package:navis/src/theme/navis_style_schemes.dart';
import 'package:navis/src/theme/navis_theme.dart';

const _seed = Color(0xFF3F7BE0);

enum _Mode { light, dark, oled }

ThemeData _theme(_Mode mode, NavisColorStyle style, ColorAdjustment adj) =>
    switch (mode) {
      _Mode.light => buildLightTheme(_seed, style: style, adjustment: adj),
      _Mode.dark => buildDarkTheme(_seed, style: style, adjustment: adj),
      _Mode.oled => buildOledTheme(_seed, style: style, adjustment: adj),
    };

/// Hosts the option the way Settings does: previews recolour the surrounding
/// theme, commits are recorded.
class _Harness extends StatefulWidget {
  const new({
    required this.mode,
    this.initial = ColorAdjustment.none,
    this.previews,
    this.commits,
    this.textScale = 1,
    this.textDirection = TextDirection.ltr,
  });

  final _Mode mode;
  final ColorAdjustment initial;
  final List<ColorAdjustment>? previews;
  final List<ColorAdjustment>? commits;
  final double textScale;
  final TextDirection textDirection;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  late ColorAdjustment saved = widget.initial;
  ColorAdjustment? preview;

  @override
  Widget build(BuildContext context) {
    final shown = preview ?? saved;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      localizationsDelegates: navisLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: _theme(widget.mode, NavisColorStyle.pastel, shown),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(widget.textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: SingleChildScrollView(
          child: ColorTuningOption(
            value: saved,
            seed: _seed,
            style: NavisColorStyle.pastel,
            brightness: widget.mode == _Mode.light
                ? Brightness.light
                : Brightness.dark,
            oled: widget.mode == _Mode.oled,
            onPreview: (next) {
              widget.previews?.add(next);
              setState(() => preview = next);
            },
            onChanged: (next) {
              widget.commits?.add(next);
              setState(() {
                saved = next;
                preview = null;
              });
            },
          ),
        ),
      ),
    );
  }
}

Finder _ruler(String name) =>
    find.byKey(ValueKey<String>('colorTuning-$name-ruler'));

RulerBand _band(WidgetTester tester, String name) =>
    tester.widget<AdjustmentRuler>(_ruler(name)).band!;

void main() {
  setUpAll(() async {
    final inter = FontLoader(navisFontFamily)
      ..addFont(rootBundle.load('assets/fonts/InterVariable.ttf'));
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await Future.wait([inter.load(), icons.load()]);
  });

  Future<void> pump(
    WidgetTester tester,
    _Harness harness, {
    Size size = const Size(390, 420),
  }) async {
    tester.view
      ..devicePixelRatio = 2
      ..physicalSize = size * 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(harness);
    await tester.pumpAndSettle();
  }

  Finder key(String name) => find.byKey(ValueKey<String>('colorTuning-$name'));

  for (final mode in _Mode.values) {
    testWidgets('golden: Color and Brightness rulers in ${mode.name}', (
      tester,
    ) async {
      await pump(
        tester,
        _Harness(
          mode: mode,
          initial: const ColorAdjustment(vividness: -2, depth: 1),
        ),
      );
      await expectLater(
        find.byType(Scaffold),
        matchesGoldenFile('goldens/color_tuning_${mode.name}.png'),
      );
    });
  }

  group('swatches', () {
    for (final mode in _Mode.values) {
      testWidgets('are the real scheme at every step in ${mode.name}', (
        tester,
      ) async {
        const adjustment = ColorAdjustment(vividness: 1, depth: -2);
        await pump(tester, _Harness(mode: mode, initial: adjustment));
        final dark = mode != _Mode.light;
        final oled = mode == _Mode.oled;
        final base = buildStyledColorScheme(
          seed: _seed,
          brightness: dark ? Brightness.dark : Brightness.light,
          oled: oled,
          style: NavisColorStyle.pastel,
        );
        ColorScheme at(ColorAdjustment adj) =>
            adjustColorScheme(base, adj, dark: dark, oled: oled);

        final color = _band(tester, 'color');
        final brightness = _band(tester, 'brightness');
        for (var step = -5; step <= 5; step++) {
          final index = step + 5;
          final tuned = at(ColorAdjustment(vividness: step, depth: -2));
          expect(color.colors[index], tuned.primary, reason: 'color $step');
          expect(color.inks[index], tuned.onPrimary, reason: 'ink $step');
          final deep = at(ColorAdjustment(vividness: 1, depth: step));
          expect(
            brightness.colors[index],
            oled ? deep.surfaceContainerHigh : deep.surface,
            reason: 'brightness $step',
          );
        }
        // The ends differ visibly: muted is not vivid, lighter is not deeper.
        expect(color.colors.first, isNot(color.colors.last));
        expect(brightness.colors.first, isNot(brightness.colors.last));
        if (oled) {
          // OLED's surface stays black; its panels carry the scale.
          expect(
            at(const ColorAdjustment(depth: 5)).surface,
            const Color(0xFF000000),
          );
          expect(
            brightness.colors.toSet(),
            hasLength(greaterThan(1)),
            reason: 'panels move',
          );
        }
      });
    }

    testWidgets('hold still while the theme recolours around them', (
      tester,
    ) async {
      await pump(tester, _Harness(mode: _Mode.dark));
      final before = _band(tester, 'color');

      // A Brightness change recolours every surface around the swatches, but
      // not the accents they show.
      await tester.tap(key('brightness-plus'));
      await tester.pumpAndSettle();
      expect(_band(tester, 'color'), before);
    });
  });

  group('Color ruler', () {
    testWidgets('previews every whole step while dragging, saves on release', (
      tester,
    ) async {
      final previews = <ColorAdjustment>[];
      final commits = <ColorAdjustment>[];
      await pump(
        tester,
        _Harness(mode: _Mode.dark, previews: previews, commits: commits),
      );

      final gesture = await tester.startGesture(
        tester.getCenter(_ruler('color')),
      );
      for (var i = 0; i < 8; i++) {
        await gesture.moveBy(const Offset(-16, 0));
        await tester.pump();
      }
      expect(commits, isEmpty, reason: 'nothing is saved mid-drag');
      expect(previews, isNotEmpty);
      final steps = previews.map((p) => p.vividness).toList();
      for (var i = 1; i < steps.length; i++) {
        expect(steps[i], steps[i - 1] + 1, reason: 'one preview per step');
      }
      expect(previews.map((p) => p.depth), everyElement(0));

      await gesture.up();
      await tester.pumpAndSettle();
      expect(commits, hasLength(1));
      expect(commits.single.vividness, steps.last);
      expect(commits.single.vividness, greaterThanOrEqualTo(3));
      expect(key('color-value'), findsOneWidget);
      expect(tester.widget<Text>(key('color-value')).data, '+${steps.last}');
    });

    testWidgets('steppers step once, preview and save', (tester) async {
      final previews = <ColorAdjustment>[];
      final commits = <ColorAdjustment>[];
      await pump(
        tester,
        _Harness(mode: _Mode.dark, previews: previews, commits: commits),
      );

      await tester.tap(key('color-plus'));
      await tester.pumpAndSettle();
      expect(previews, const [ColorAdjustment(vividness: 1)]);
      expect(commits, const [ColorAdjustment(vividness: 1)]);

      await tester.tap(key('color-minus'));
      await tester.pumpAndSettle();
      await tester.tap(key('color-minus'));
      await tester.pumpAndSettle();
      expect(commits.last, const ColorAdjustment(vividness: -1));
      expect(tester.widget<Text>(key('color-value')).data, '−1');
    });

    testWidgets('steppers stop at the ends', (tester) async {
      await pump(
        tester,
        _Harness(
          mode: _Mode.dark,
          initial: const ColorAdjustment(vividness: 5, depth: -5),
        ),
      );
      IconButton button(String name) => tester.widget<IconButton>(
        find.descendant(of: key(name), matching: find.byType(IconButton)),
      );
      expect(button('color-plus').onPressed, isNull);
      expect(button('color-minus').onPressed, isNotNull);
      expect(button('brightness-minus').onPressed, isNull);
      expect(button('brightness-plus').onPressed, isNotNull);
    });

    testWidgets('arrow keys step and Home resets', (tester) async {
      final commits = <ColorAdjustment>[];
      await pump(tester, _Harness(mode: _Mode.dark, commits: commits));

      await tester.tap(_ruler('color'));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(commits.last, const ColorAdjustment(vividness: 2));

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(commits.last, const ColorAdjustment(vividness: 1));

      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.pumpAndSettle();
      expect(commits.last, ColorAdjustment.none);
    });

    testWidgets('exposes its value and the next steps to semantics', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pump(
        tester,
        _Harness(
          mode: _Mode.dark,
          initial: const ColorAdjustment(vividness: -2),
        ),
      );
      final data = tester.getSemantics(_ruler('color')).getSemanticsData();
      expect(data.label, 'Color');
      expect(data.value, '−2');
      expect(data.increasedValue, '−1');
      expect(data.decreasedValue, '−3');
      expect(find.byTooltip('Make colors more muted'), findsOneWidget);
      expect(find.byTooltip('Make colors more vivid'), findsOneWidget);
      expect(find.byTooltip('Make backgrounds lighter'), findsOneWidget);
      expect(find.byTooltip('Make backgrounds deeper'), findsOneWidget);
      handle.dispose();
    });
  });

  group('Brightness ruler', () {
    testWidgets('keeps the other axis when it moves', (tester) async {
      final commits = <ColorAdjustment>[];
      await pump(
        tester,
        _Harness(
          mode: _Mode.light,
          initial: const ColorAdjustment(vividness: 3),
          commits: commits,
        ),
      );
      await tester.tap(key('brightness-minus'));
      await tester.pumpAndSettle();
      expect(commits.single, const ColorAdjustment(vividness: 3, depth: -1));
    });
  });

  group('Reset', () {
    testWidgets('shows only while a value is not Default and clears both', (
      tester,
    ) async {
      final commits = <ColorAdjustment>[];
      await pump(tester, _Harness(mode: _Mode.dark, commits: commits));
      expect(key('reset'), findsNothing);
      expect(find.text('Default'), findsNWidgets(2));

      await tester.tap(key('color-plus'));
      await tester.pumpAndSettle();
      expect(key('reset'), findsOneWidget);
      await tester.tap(key('brightness-minus'));
      await tester.pumpAndSettle();

      await tester.tap(key('reset'));
      await tester.pumpAndSettle();
      expect(commits.last, ColorAdjustment.none);
      expect(key('reset'), findsNothing);
      expect(find.text('Default'), findsNWidgets(2));
    });

    testWidgets('a value changed elsewhere moves the rulers', (tester) async {
      await pump(tester, _Harness(mode: _Mode.dark));
      final state = tester.state<_HarnessState>(find.byType(_Harness));
      // The harness plays the saved value changing from outside.
      // ignore: invalid_use_of_protected_member
      state.setState(() => state.saved = const ColorAdjustment(depth: 4));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(key('brightness-value')).data, '+4');
    });
  });

  group('layout', () {
    for (final scale in <double>[1.3, 2]) {
      testWidgets('fits a phone at ${scale * 100}% text', (tester) async {
        await pump(
          tester,
          _Harness(
            mode: _Mode.dark,
            initial: const ColorAdjustment(vividness: -3, depth: 2),
            textScale: scale,
          ),
          size: const Size(320, 900),
        );
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('stays left-to-right like Speed and Pitch', (tester) async {
      await pump(
        tester,
        _Harness(mode: _Mode.dark, textDirection: TextDirection.rtl),
      );
      expect(
        tester.getCenter(key('color-minus')).dx,
        lessThan(tester.getCenter(_ruler('color')).dx),
      );
      expect(
        tester.getCenter(key('color-plus')).dx,
        greaterThan(tester.getCenter(_ruler('color')).dx),
      );
      expect(
        tester.getTopLeft(find.text('Muted')).dx,
        lessThan(tester.getTopLeft(find.text('Vivid')).dx),
      );
    });
  });
}
