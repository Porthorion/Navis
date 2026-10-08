import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_color_utilities/material_color_utilities.dart'
    show Hct;
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/features/home/presentation/cover_colour_field.dart';
import 'package:navis/src/features/home/presentation/home_screen.dart';
import 'package:navis/src/theme/navis_color_style.dart';
import 'package:navis/src/theme/navis_color_style_data.dart';
import 'package:navis/src/theme/navis_theme.dart';
import 'package:navis/src/theme/navis_tokens.dart';

const _seed = Color(0xFF009688);

CoverColourField _field() => CoverColourField(const <Color>[
  Color(0xFFD32F2F),
  Color(0xFFD32F2F),
  Color(0xFF1976D2),
  Color(0xFFD32F2F),
  Color(0xFF388E3C),
  Color(0xFF1976D2),
  Color(0xFF388E3C),
  Color(0xFF388E3C),
  Color(0xFF1976D2),
]);

Future<ThemeData> _pump(
  WidgetTester tester, {
  required bool flat,
  required NavisColorStyle style,
  CoverColourField? field,
}) async {
  final theme = buildDarkTheme(_seed, style: style, flat: flat);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        coverColourFieldProvider.overrideWith((ref, id) async => field),
      ],
      child: MaterialApp(
        theme: theme,
        home: const Scaffold(
          body: SizedBox(
            width: 300,
            height: 200,
            child: ShowcaseColourWash(coverArtId: 'cover-1'),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return theme;
}

void main() {
  const flatFill = ValueKey<String>('home-showcase-wash-flat');

  for (final style in NavisColorStyle.values) {
    testWidgets('Flat ${style.name} paints one solid adapted average', (
      tester,
    ) async {
      final theme = await _pump(
        tester,
        flat: true,
        style: style,
        field: _field(),
      );

      expect(
        find.byType(CustomPaint).evaluate().where((e) {
          final w = e.widget as CustomPaint;
          return w.painter is CoverColourFieldPainter;
        }),
        isEmpty,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey<String>('home-showcase-wash')),
          matching: find.byType(DecoratedBox),
        ),
        // Only the solid panel itself: no gradient veil.
        findsOneWidget,
      );
      final box =
          tester.widget<DecoratedBox>(find.byKey(flatFill)).decoration
              as BoxDecoration;

      final data = theme.extension<NavisColorStyleData>()!;
      final cells = _field().colors;
      final average = Color.from(
        alpha: 1,
        red: cells.fold<double>(0, (s, c) => s + c.r) / cells.length,
        green: cells.fold<double>(0, (s, c) => s + c.g) / cells.length,
        blue: cells.fold<double>(0, (s, c) => s + c.b) / cells.length,
      );
      var adapted = data.adaptArtColor(average);
      if (Hct.fromInt(adapted.toARGB32()).chroma < 6) {
        adapted = Color.lerp(
          adapted,
          theme.colorScheme.secondaryContainer,
          .25,
        )!;
      }
      final expected = Color.alphaBlend(
        adapted.withValues(alpha: 1 - data.artWashVeil(subtle: false)),
        theme.scaffoldBackgroundColor,
      );
      expect(box.color, expected);
      expect(box.borderRadius, NavisRadius.xlAll);
      // Inset to the content margins, not full-bleed.
      expect(tester.getTopLeft(find.byKey(flatFill)).dx, NavisSpace.md);
      expect(
        tester.getSize(find.byKey(flatFill)).width,
        300 - 2 * NavisSpace.md,
      );
    });
  }

  testWidgets('Flat without a cover is the plain background', (tester) async {
    final theme = await _pump(
      tester,
      flat: true,
      style: NavisColorStyle.pastel,
    );
    expect(
      (tester.widget<DecoratedBox>(find.byKey(flatFill)).decoration
              as BoxDecoration)
          .color,
      theme.scaffoldBackgroundColor,
    );
  });

  for (final style in NavisColorStyle.values) {
    testWidgets('Flat ${style.name} grey cover takes the style chroma floor', (
      tester,
    ) async {
      final theme = await _pump(
        tester,
        flat: true,
        style: style,
        field: CoverColourField(List<Color>.filled(9, const Color(0xFF808080))),
      );
      final data = theme.extension<NavisColorStyleData>()!;
      final adapted = Color.lerp(
        data.adaptArtColor(const Color(0xFF808080)),
        theme.colorScheme.secondaryContainer,
        0.25,
      )!;
      final expected = Color.alphaBlend(
        adapted.withValues(alpha: 1 - data.artWashVeil(subtle: false)),
        theme.scaffoldBackgroundColor,
      );
      final box =
          tester.widget<DecoratedBox>(find.byKey(flatFill)).decoration
              as BoxDecoration;
      expect(box.color, expected);
    });
  }

  testWidgets('Flat off keeps the shaded mesh and veil', (tester) async {
    await _pump(
      tester,
      flat: false,
      style: NavisColorStyle.pastel,
      field: _field(),
    );
    expect(find.byKey(flatFill), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('home-showcase-wash')),
        matching: find.byType(DecoratedBox),
      ),
      findsWidgets,
    );
  });
}
