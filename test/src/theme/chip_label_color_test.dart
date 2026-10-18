import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/theme/color_adjustment.dart';
import 'package:navis/src/theme/navis_color_style_data.dart';
import 'package:navis/src/theme/navis_theme.dart';

// The chip never resolves a WidgetStateTextStyle labelStyle, so under White
// controls the label colour was null and painted the engine's default white.
void main() {
  const adjustment = ColorAdjustment(controls: NavisControlColor.white);
  for (final dark in [false, true]) {
    final theme = dark
        ? buildDarkTheme(Colors.teal, adjustment: adjustment)
        : buildLightTheme(Colors.teal, adjustment: adjustment);
    for (final selected in [false, true]) {
      testWidgets(
        'ChoiceChip label uses its intended ink, ${dark ? 'dark' : 'light'}, '
        '${selected ? 'selected' : 'unselected'}',
        (tester) async {
          await tester.pumpWidget(
            MaterialApp(
              theme: theme,
              home: Scaffold(
                body: ChoiceChip(
                  label: const Text('Chip'),
                  selected: selected,
                  onSelected: (_) {},
                ),
              ),
            ),
          );
          final scheme = theme.colorScheme;
          final expected = selected
              ? theme.extension<NavisColorStyleData>()!.onTonalControlFill(
                  scheme,
                )
              : scheme.onSurface;
          final text = tester.widget<RichText>(
            find.descendant(
              of: find.byType(ChoiceChip),
              matching: find.byType(RichText),
            ),
          );
          expect(text.text.style?.color, expected);
          expect(text.text.style?.fontSize, isNotNull);
        },
      );
    }
  }
}
